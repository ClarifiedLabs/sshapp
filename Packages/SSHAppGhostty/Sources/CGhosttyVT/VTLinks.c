#include "VTInternal.h"
#include <stdlib.h>
#include <string.h>

void vt_free_link_context(VTLinkContext *context) {
    free(context->uri); free(context->line); free(context->map);
    *context = (VTLinkContext){0};
}

static GhosttyResult format(VTHandle *handle, const GhosttySelection *selection,
                             uint8_t *bytes, size_t capacity, size_t *count) {
    GhosttyTerminalSelectionFormatOptions options = GHOSTTY_INIT_SIZED(GhosttyTerminalSelectionFormatOptions);
    options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN;
    options.unwrap = true;
    options.trim = false;
    options.selection = selection;
    return ghostty_terminal_selection_format_buf(handle->terminal, options, bytes, capacity, count);
}

typedef struct {
    VTHandle *handle;
    VTLinkContext *out;
    size_t line_capacity, map_capacity;
    uint16_t column, row, columns, rows;
} MappedContext;

static GhosttyResult append_map(MappedContext *context, uint16_t column, uint16_t row,
                                uint16_t width, size_t offset, size_t count) {
    VTLinkContext *out = context->out;
    if (out->map_count == context->map_capacity) {
        size_t capacity = context->map_capacity ? context->map_capacity * 2 : 32;
        if (capacity < context->map_capacity || capacity > SIZE_MAX / sizeof(VTLinkMapEntry)) return GHOSTTY_OUT_OF_MEMORY;
        VTLinkMapEntry *map = realloc(out->map, capacity * sizeof(*map));
        if (!map) return GHOSTTY_OUT_OF_MEMORY;
        out->map = map; context->map_capacity = capacity;
    }
    out->map[out->map_count++] = (VTLinkMapEntry){column, row, width, offset, count};
    return GHOSTTY_SUCCESS;
}

static GhosttyResult mapped_text(void *userdata, const GhosttyGridRef *ref,
                                 const uint8_t *bytes, size_t count, size_t offset) {
    MappedContext *context = userdata;
    VTLinkContext *out = context->out;
    if (offset != out->line_count || count > SIZE_MAX - offset) return GHOSTTY_INVALID_VALUE;
    size_t needed = offset + count;
    if (needed > context->line_capacity) {
        size_t capacity = context->line_capacity;
        if (capacity <= SIZE_MAX / 2) capacity *= 2;
        if (capacity < needed) capacity = needed;
        uint8_t *line = realloc(out->line, capacity);
        if (!line) return GHOSTTY_OUT_OF_MEMORY;
        out->line = line; context->line_capacity = capacity;
    }
    memcpy(out->line + offset, bytes, count);
    out->line_count = needed;
    GhosttyPointCoordinate point;
    GhosttyResult result = ghostty_terminal_point_from_grid_ref(context->handle->terminal, ref, GHOSTTY_POINT_TAG_VIEWPORT, &point);
    if (result == GHOSTTY_NO_VALUE) return GHOSTTY_SUCCESS;
    if (result != GHOSTTY_SUCCESS) return result;
    // Viewport coordinates are relative to its top and can include rows below
    // its bottom while scrolled back. Keep their bytes for URL detection, but
    // publish geometry only for visible cells.
    if (point.x >= context->columns || point.y >= context->rows) return GHOSTTY_SUCCESS;
    GhosttyCell cell;
    GhosttyCellWide wide;
    result = ghostty_grid_ref_cell(ref, &cell);
    if (result != GHOSTTY_SUCCESS) return result;
    result = ghostty_cell_get(cell, GHOSTTY_CELL_DATA_WIDE, &wide);
    if (result != GHOSTTY_SUCCESS) return result;
    if (wide == GHOSTTY_CELL_WIDE_SPACER_HEAD || wide == GHOSTTY_CELL_WIDE_SPACER_TAIL) return GHOSTTY_SUCCESS;
    if (point.x == context->column && point.y == context->row) {
        out->hit_start = offset; out->hit_end = needed;
    }
    return append_map(context, point.x, (uint16_t)point.y, wide == GHOSTTY_CELL_WIDE_WIDE ? 2 : 1, offset, count);
}

static GhosttyResult explicit_map(MappedContext *context, const GhosttyGridRef *hit) {
    uint16_t columns, rows;
    GhosttyResult result = ghostty_terminal_get(context->handle->terminal, GHOSTTY_TERMINAL_DATA_COLS, &columns);
    if (result != GHOSTTY_SUCCESS) return result;
    result = ghostty_terminal_get(context->handle->terminal, GHOSTTY_TERMINAL_DATA_ROWS, &rows);
    if (result != GHOSTTY_SUCCESS) return result;
    for (uint16_t y = 0; y < rows; y++) {
        GhosttyPoint point = {.tag = GHOSTTY_POINT_TAG_VIEWPORT, .value.coordinate = {.x = 0, .y = y}};
        GhosttyGridRef ref = GHOSTTY_INIT_SIZED(GhosttyGridRef);
        result = ghostty_terminal_grid_ref(context->handle->terminal, point, &ref);
        if (result != GHOSTTY_SUCCESS) return result;
        GhosttyRow row;
        bool links = false;
        result = ghostty_grid_ref_row(&ref, &row);
        if (result != GHOSTTY_SUCCESS) return result;
        result = ghostty_row_get(row, GHOSTTY_ROW_DATA_HYPERLINK, &links);
        if (result != GHOSTTY_SUCCESS) return result;
        if (!links) continue;
        for (uint16_t x = 0; x < columns; x++) {
            point.value.coordinate.x = x;
            result = ghostty_terminal_grid_ref(context->handle->terminal, point, &ref);
            if (result != GHOSTTY_SUCCESS) return result;
            GhosttyCell cell;
            GhosttyCellWide wide;
            result = ghostty_grid_ref_cell(&ref, &cell);
            if (result != GHOSTTY_SUCCESS) return result;
            result = ghostty_cell_get(cell, GHOSTTY_CELL_DATA_WIDE, &wide);
            if (result != GHOSTTY_SUCCESS) return result;
            if (wide == GHOSTTY_CELL_WIDE_SPACER_HEAD || wide == GHOSTTY_CELL_WIDE_SPACER_TAIL) continue;
            bool equal = false;
            result = ghostty_grid_ref_hyperlink_equal(hit, &ref, &equal);
            if (result != GHOSTTY_SUCCESS) return result;
            if (equal) {
                result = append_map(context, x, y, wide == GHOSTTY_CELL_WIDE_WIDE && x + 1 < columns ? 2 : 1, 0, 0);
                if (result != GHOSTTY_SUCCESS) return result;
            }
        }
    }
    return GHOSTTY_SUCCESS;
}

int vt_copy_link_context(VTHandle *handle, uint16_t column, uint16_t row,
                         bool geometry, VTLinkContext *out) {
    *out = (VTLinkContext){0};
    if (!handle || handle->failed) return GHOSTTY_INVALID_VALUE;
    GhosttyResult result;
    GhosttyPoint point = {.tag = GHOSTTY_POINT_TAG_VIEWPORT, .value.coordinate = {.x = column, .y = row}};
    GhosttyGridRef ref = GHOSTTY_INIT_SIZED(GhosttyGridRef);
#define CHECK(call) do { result = (call); if (result != GHOSTTY_SUCCESS) goto cleanup; } while (0)
    CHECK(ghostty_terminal_grid_ref(handle->terminal, point, &ref));
    GhosttyCell cell;
    GhosttyCellWide wide;
    CHECK(ghostty_grid_ref_cell(&ref, &cell));
    CHECK(ghostty_cell_get(cell, GHOSTTY_CELL_DATA_WIDE, &wide));
    if (wide == GHOSTTY_CELL_WIDE_SPACER_HEAD) return GHOSTTY_SUCCESS;
    if (wide == GHOSTTY_CELL_WIDE_SPACER_TAIL) {
        if (!column) return GHOSTTY_SUCCESS;
        point.value.coordinate.x -= 1;
        CHECK(ghostty_terminal_grid_ref(handle->terminal, point, &ref));
    }
    MappedContext mapped = {.handle = handle, .out = out, .column = point.value.coordinate.x, .row = row};
    if (geometry) {
        CHECK(ghostty_terminal_get(handle->terminal, GHOSTTY_TERMINAL_DATA_COLS, &mapped.columns));
        CHECK(ghostty_terminal_get(handle->terminal, GHOSTTY_TERMINAL_DATA_ROWS, &mapped.rows));
    }
    // OSC 8 has priority over text detection, including unsupported schemes.
    // Never reinterpret an explicit target by detecting its displayed label.
    result = ghostty_grid_ref_hyperlink_uri(&ref, NULL, 0, &out->uri_count);
    if (result == GHOSTTY_OUT_OF_SPACE && out->uri_count) {
        out->uri = malloc(out->uri_count);
        if (!out->uri) { result = GHOSTTY_OUT_OF_MEMORY; goto cleanup; }
        CHECK(ghostty_grid_ref_hyperlink_uri(&ref, out->uri, out->uri_count, &out->uri_count));
        if (geometry) CHECK(explicit_map(&mapped, &ref));
        return GHOSTTY_SUCCESS;
    }
    if (result != GHOSTTY_SUCCESS) goto cleanup;

    // Native line selection and formatting handle soft wraps, Unicode cell
    // allocation and scrollback. These are local snapshots, never installed as
    // the terminal's active selection and never retained beyond this call.
    GhosttyTerminalSelectLineOptions options = GHOSTTY_INIT_SIZED(GhosttyTerminalSelectLineOptions);
    options.ref = ref;
    GhosttySelection line = GHOSTTY_INIT_SIZED(GhosttySelection);
    result = ghostty_terminal_select_line(handle->terminal, &options, &line);
    if (result == GHOSTTY_NO_VALUE) return GHOSTTY_SUCCESS;
    if (result != GHOSTTY_SUCCESS) goto cleanup;
    // Line selection trims surrounding whitespace, so the hit cell can lie
    // outside it: indentation or trailing blanks are never part of a link.
    bool contains = false;
    CHECK(ghostty_terminal_selection_contains(handle->terminal, &line, point, &contains));
    if (!contains) return GHOSTTY_SUCCESS;
    if (geometry) {
        GhosttyTerminalSelectionFormatOptions format_options = GHOSTTY_INIT_SIZED(GhosttyTerminalSelectionFormatOptions);
        format_options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN;
        format_options.unwrap = true;
        format_options.selection = &line;
        CHECK(ghostty_terminal_selection_format_mapped(handle->terminal, format_options, mapped_text, &mapped));
        return GHOSTTY_SUCCESS;
    }
    result = format(handle, &line, NULL, 0, &out->line_count);
    if (result == GHOSTTY_SUCCESS && !out->line_count) return GHOSTTY_SUCCESS;
    if (result != GHOSTTY_OUT_OF_SPACE) goto cleanup;
    out->line = malloc(out->line_count);
    if (!out->line) { result = GHOSTTY_OUT_OF_MEMORY; goto cleanup; }
    CHECK(format(handle, &line, out->line, out->line_count, &out->line_count));
    GhosttySelection prefix = line;
    prefix.end = ref;
    result = format(handle, &prefix, NULL, 0, &out->hit_end);
    if (result != GHOSTTY_OUT_OF_SPACE && result != GHOSTTY_SUCCESS) goto cleanup;
    GhosttySelection current = prefix;
    current.start = ref;
    size_t current_count = 0;
    result = format(handle, &current, NULL, 0, &current_count);
    if (result != GHOSTTY_OUT_OF_SPACE && result != GHOSTTY_SUCCESS) goto cleanup;
    if (current_count > out->hit_end || out->hit_end > out->line_count) { result = GHOSTTY_INVALID_VALUE; goto cleanup; }
    out->hit_start = out->hit_end - current_count;
    return GHOSTTY_SUCCESS;
cleanup:
    vt_free_link_context(out);
    return result;
#undef CHECK
}
