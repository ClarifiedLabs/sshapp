#include "VTInternal.h"
#include <stdlib.h>
#include <string.h>

void vt_receive_reply(GhosttyTerminal terminal, void *userdata,
                          const uint8_t *bytes, size_t count) {
    (void)terminal;
    VTHandle *handle = userdata;
    if (handle->failed || count == 0) return;
    if (count > SIZE_MAX - handle->reply_count) {
        handle->failed = true;
        return;
    }
    uint8_t *buffer = realloc(handle->replies, handle->reply_count + count);
    if (!buffer) {
        handle->failed = true;
        return;
    }
    handle->replies = buffer;
    memcpy(buffer + handle->reply_count, bytes, count);
    handle->reply_count += count;
}

int vt_create(uint16_t columns, uint16_t rows, size_t scrollback_bytes,
              uint64_t image_storage_bytes, const VTImageBudget *image_budget,
              size_t image_budget_bytes, VTHandle **out_handle) {
    *out_handle = NULL;
    if (!columns || !rows) return GHOSTTY_INVALID_VALUE;
    VTHandle *handle = calloc(1, sizeof(*handle));
    if (!handle) return GHOSTTY_OUT_OF_MEMORY;
    handle->png_decode_limit = image_storage_bytes < SIZE_MAX ? (size_t)image_storage_bytes : SIZE_MAX;
    if (image_budget && image_budget_bytes < handle->png_decode_limit) handle->png_decode_limit = image_budget_bytes;
    GhosttyResult result = vt_graphics_initialize();
    if (result == GHOSTTY_SUCCESS) result = ghostty_terminal_new(NULL, &handle->terminal, columns, rows);
    if (result == GHOSTTY_SUCCESS) result = ghostty_terminal_set(handle->terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &scrollback_bytes);
    if (result == GHOSTTY_SUCCESS) result = ghostty_terminal_set(handle->terminal, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT, &image_storage_bytes);
    if (result == GHOSTTY_SUCCESS && image_budget) {
        GhosttyKittyImageBudget budget = {
            .size = sizeof(budget), .userdata = image_budget->userdata,
            .reserve = image_budget->reserve, .release = image_budget->release
        };
        result = ghostty_terminal_set(handle->terminal, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_BUDGET, &budget);
    }
    // SSH graphics arrive in-band. A peer must never ask the iOS process to
    // read or unlink a local file, or open local shared memory.
    bool local_media = false;
    if (result == GHOSTTY_SUCCESS) result = ghostty_terminal_set(handle->terminal, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_FILE, &local_media);
    if (result == GHOSTTY_SUCCESS) result = ghostty_terminal_set(handle->terminal, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_TEMP_FILE, NULL);
    if (result == GHOSTTY_SUCCESS) result = ghostty_terminal_set(handle->terminal, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_SHARED_MEM, &local_media);
    if (result == GHOSTTY_SUCCESS) result = ghostty_render_state_new(NULL, &handle->render);
    if (result == GHOSTTY_SUCCESS) result = ghostty_key_encoder_new(NULL, &handle->key_encoder);
    if (result == GHOSTTY_SUCCESS) result = ghostty_mouse_encoder_new(NULL, &handle->mouse_encoder);
    if (result == GHOSTTY_SUCCESS) result = ghostty_selection_gesture_new(NULL, &handle->selection_gesture);
    if (result == GHOSTTY_SUCCESS) {
        bool track_cell = true;
        ghostty_mouse_encoder_setopt(handle->mouse_encoder, GHOSTTY_MOUSE_ENCODER_OPT_TRACK_LAST_CELL, &track_cell);
        handle->mouse_options_dirty = true;
    }
    if (result == GHOSTTY_SUCCESS) result = ghostty_terminal_set(handle->terminal, GHOSTTY_TERMINAL_OPT_USERDATA, handle);
    if (result == GHOSTTY_SUCCESS) result = ghostty_terminal_set(handle->terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY, vt_receive_reply);
    if (result == GHOSTTY_SUCCESS) result = vt_events_initialize(handle);
    if (result == GHOSTTY_SUCCESS) result = vt_configuration_initialize(handle);
    // Match the shipped renderer's grapheme-width-method=unicode default.
    // VT alone defaults mode 2027 off. Set its reset default as well as current
    // value, while still allowing a remote application to change the mode.
    GhosttyTerminalModeConfig graphemes = {.mode = GHOSTTY_MODE_GRAPHEME_CLUSTER, .value = true};
    if (result == GHOSTTY_SUCCESS) result = ghostty_terminal_set(handle->terminal, GHOSTTY_TERMINAL_OPT_MODE_DEFAULT, &graphemes);
    // No clipboard callbacks are installed: remote OSC 52 never reaches UIKit.
    if (result != GHOSTTY_SUCCESS) {
        vt_destroy(handle);
        return result;
    }
    *out_handle = handle;
    return GHOSTTY_SUCCESS;
}

void vt_destroy(VTHandle *handle) {
    if (!handle) return;
    if (handle->key_encoder) ghostty_key_encoder_free(handle->key_encoder);
    if (handle->mouse_encoder) ghostty_mouse_encoder_free(handle->mouse_encoder);
    if (handle->selection_gesture) ghostty_selection_gesture_free(handle->selection_gesture, handle->terminal);
    if (handle->render) ghostty_render_state_free(handle->render);
    if (handle->terminal) ghostty_terminal_free(handle->terminal);
    free(handle->replies);
    vt_free_events(handle->events, handle->event_count);
    free(handle);
}

int vt_write(VTHandle *handle, const uint8_t *bytes, size_t count) {
    if (!handle || handle->failed || (count && !bytes)) return GHOSTTY_INVALID_VALUE;
    if (count) {
        size_t previous = vt_png_decode_limit;
        vt_png_decode_limit = handle->png_decode_limit;
        ghostty_terminal_vt_write(handle->terminal, bytes, count);
        vt_png_decode_limit = previous;
        // Any admitted output may change mouse modes, including a sequence
        // split across writes. Refresh before the next input, never from UI's
        // potentially older displayed snapshot.
        handle->mouse_options_dirty = true;
    }
    // Success means consumed. A failure raised while parsing (for example a
    // reply allocation) poisons the handle and surfaces on the next call; an
    // error here would make the caller re-feed bytes the parser already took.
    return GHOSTTY_SUCCESS;
}

int vt_resize(VTHandle *handle, uint16_t columns, uint16_t rows,
              uint32_t cell_width, uint32_t cell_height) {
    if (!handle || handle->failed) return GHOSTTY_INVALID_VALUE;
    vt_selection_gesture_reset(handle);
    GhosttyResult result = ghostty_terminal_resize(handle->terminal, columns, rows, cell_width, cell_height);
    handle->mouse_options_dirty = true;
    return handle->failed ? GHOSTTY_OUT_OF_MEMORY : result;
}

int vt_scroll(VTHandle *handle, intptr_t delta) {
    if (!handle || handle->failed) return GHOSTTY_INVALID_VALUE;
    GhosttyTerminalScrollViewport behavior = {
        .tag = GHOSTTY_SCROLL_VIEWPORT_DELTA, .value = {.delta = delta}
    };
    ghostty_terminal_scroll_viewport(handle->terminal, behavior);
    return GHOSTTY_SUCCESS;
}

int vt_scroll_to_bottom(VTHandle *handle) {
    if (!handle || handle->failed) return GHOSTTY_INVALID_VALUE;
    ghostty_terminal_scroll_viewport(handle->terminal, (GhosttyTerminalScrollViewport){
        .tag = GHOSTTY_SCROLL_VIEWPORT_BOTTOM
    });
    return GHOSTTY_SUCCESS;
}

void vt_free_frame(VTFrame *frame) {
    if (!frame) return;
    if (frame->cells) {
        for (size_t i = 0; i < (size_t)frame->columns * frame->rows; ++i) free(frame->cells[i].text);
        free(frame->cells);
    }
    for (size_t i = 0; i < frame->image_count; ++i) free(frame->images[i].rgba);
    free(frame->images);
    free(frame->placements);
    free(frame);
}

static VTRGB rgb(GhosttyColorRgb color) {
    return (VTRGB){color.r, color.g, color.b};
}

// All C queries and copying happen synchronously while the owning actor holds
// exclusive terminal/render-state access. No iterator or cell pointer escapes.
int vt_copy_frame(VTHandle *handle, const uint64_t *cached_images,
                  size_t cached_image_count, VTFrame **out_frame) {
    *out_frame = NULL;
    if (!handle || handle->failed) return GHOSTTY_INVALID_VALUE;
    GhosttyResult result = GHOSTTY_SUCCESS;
    VTFrame *frame = calloc(1, sizeof(*frame));
    if (!frame) return GHOSTTY_OUT_OF_MEMORY;
    GhosttyRenderStateRowIterator rows = NULL;
    GhosttyRenderStateRowCells cells = NULL;
    GhosttyRenderStateColors colors = GHOSTTY_INIT_SIZED(GhosttyRenderStateColors);
    GhosttyRenderStateCursor cursor = GHOSTTY_INIT_SIZED(GhosttyRenderStateCursor);
#define CHECK(call) do { result = (call); if (result != GHOSTTY_SUCCESS) goto cleanup; } while (0)
    CHECK(ghostty_render_state_update(handle->render, handle->terminal));
    CHECK(ghostty_render_state_get(handle->render, GHOSTTY_RENDER_STATE_DATA_COLS, &frame->columns));
    CHECK(ghostty_render_state_get(handle->render, GHOSTTY_RENDER_STATE_DATA_ROWS, &frame->rows));
    CHECK(ghostty_render_state_get(handle->render, GHOSTTY_RENDER_STATE_DATA_COLORS, &colors));
    CHECK(ghostty_render_state_get(handle->render, GHOSTTY_RENDER_STATE_DATA_CURSOR, &cursor));
    CHECK(ghostty_terminal_get(handle->terminal, GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS, &frame->scrollback_rows));
    CHECK(ghostty_terminal_get(handle->terminal, GHOSTTY_TERMINAL_DATA_SCROLLBACK_MAX_BYTES, &frame->scrollback_limit_bytes));
    GhosttyTerminalScrollbar scrollbar;
    CHECK(ghostty_terminal_get(handle->terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &scrollbar));
    frame->viewport_total = scrollbar.total;
    frame->viewport_offset = scrollbar.offset;
    frame->viewport_rows = scrollbar.len;
    CHECK(vt_selection_frame(handle, frame));
    // This query returns bool, not GhosttyMouseTrackingMode. Reading an enum
    // after the one-byte write would include uninitialized stack bytes.
    bool tracking = false;
    CHECK(ghostty_terminal_get(handle->terminal, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &tracking));
    frame->mouse_tracking = tracking;
    CHECK(ghostty_terminal_get(handle->terminal, GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS, &frame->kitty_keyboard_flags));
    frame->foreground = rgb(colors.foreground);
    frame->background = rgb(colors.background);
    frame->cursor_color = rgb(colors.cursor_has_value ? colors.cursor : colors.foreground);
    frame->cursor_visible = cursor.visible && cursor.viewport_has_value;
    frame->cursor_blinking = cursor.blinking;
    frame->cursor_style = cursor.visual_style;
    if (cursor.viewport_has_value) {
        frame->cursor_column = cursor.viewport_x;
        frame->cursor_row = cursor.viewport_y;
        frame->cursor_wide_tail = cursor.wide_tail;
    }
    frame->cells = calloc((size_t)frame->columns * frame->rows, sizeof(VTCell));
    if (!frame->cells) { result = GHOSTTY_OUT_OF_MEMORY; goto cleanup; }
    CHECK(ghostty_render_state_row_iterator_new(NULL, &rows));
    CHECK(ghostty_render_state_row_cells_new(NULL, &cells));
    CHECK(ghostty_render_state_get(handle->render, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &rows));
    size_t y = 0;
    // Copy every row, including clean rows. Dropping an older visual snapshot
    // can never discard a dirty-row delta from the terminal stream.
    while (ghostty_render_state_row_iterator_next(rows)) {
        if (y >= frame->rows) { result = GHOSTTY_INVALID_VALUE; goto cleanup; }
        CHECK(ghostty_render_state_row_get(rows, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cells));
        GhosttyRenderStateRowSelection selection = GHOSTTY_INIT_SIZED(GhosttyRenderStateRowSelection);
        result = ghostty_render_state_row_get(rows, GHOSTTY_RENDER_STATE_ROW_DATA_SELECTION, &selection);
        bool selected = result == GHOSTTY_SUCCESS;
        if (result != GHOSTTY_SUCCESS && result != GHOSTTY_NO_VALUE) goto cleanup;
        size_t x = 0;
        while (ghostty_render_state_row_cells_next(cells)) {
            if (x >= frame->columns) { result = GHOSTTY_INVALID_VALUE; goto cleanup; }
            VTCell *cell = &frame->cells[y * frame->columns + x++];
            cell->selected = selected && x - 1 >= selection.start_x && x - 1 <= selection.end_x;
            GhosttyStyle style = GHOSTTY_INIT_SIZED(GhosttyStyle);
            GhosttyCell raw;
            GhosttyCellWide wide;
            GhosttyColorRgb fg = colors.foreground, bg = colors.background;
            CHECK(ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style));
            CHECK(ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw));
            CHECK(ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide));
            uint32_t codepoint = 0;
            CHECK(ghostty_cell_get(raw, GHOSTTY_CELL_DATA_CODEPOINT, &codepoint));
            cell->image_placeholder = codepoint == 0x10EEEE;
            // The color queries document INVALID_VALUE for an absent explicit
            // color; preserve the terminal default for that case.
            result = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &fg);
            if (result != GHOSTTY_SUCCESS && result != GHOSTTY_INVALID_VALUE) goto cleanup;
            result = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &bg);
            if (result != GHOSTTY_SUCCESS && result != GHOSTTY_INVALID_VALUE) goto cleanup;
            cell->foreground = rgb(style.inverse ? bg : fg);
            // Placeholder foreground/underline colors encode image IDs. Other
            // text attributes are reserved; only the actual background paints.
            cell->background = rgb(style.inverse && !cell->image_placeholder ? fg : bg);
            cell->width = wide == GHOSTTY_CELL_WIDE_WIDE ? 2 : (wide == GHOSTTY_CELL_WIDE_NARROW ? 1 : 0);
            cell->bold = style.bold; cell->italic = style.italic;
            cell->faint = style.faint; cell->invisible = style.invisible;
            cell->blink = style.blink; cell->overline = style.overline;
            cell->underline_style = style.underline; cell->strikethrough = style.strikethrough;
            cell->underline_color = cell->foreground;
            cell->underline_color_explicit = style.underline_color.tag == GHOSTTY_STYLE_COLOR_RGB ||
                                             style.underline_color.tag == GHOSTTY_STYLE_COLOR_PALETTE;
            switch (style.underline_color.tag) {
                case GHOSTTY_STYLE_COLOR_RGB:
                    cell->underline_color = rgb(style.underline_color.value.rgb);
                    break;
                case GHOSTTY_STYLE_COLOR_PALETTE:
                    cell->underline_color = rgb(colors.palette[style.underline_color.value.palette]);
                    break;
                default: break;
            }
            GhosttyBuffer buffer = {0};
            result = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, &buffer);
            if (result == GHOSTTY_OUT_OF_SPACE) {
                cell->text = malloc(buffer.len);
                if (!cell->text) { result = GHOSTTY_OUT_OF_MEMORY; goto cleanup; }
                buffer.ptr = cell->text; buffer.cap = buffer.len;
                CHECK(ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, &buffer));
            } else if (result != GHOSTTY_SUCCESS) goto cleanup;
            cell->text_length = buffer.len;
        }
        if (x != frame->columns) { result = GHOSTTY_INVALID_VALUE; goto cleanup; }
        ++y;
    }
    if (y != frame->rows) { result = GHOSTTY_INVALID_VALUE; goto cleanup; }
    CHECK(vt_graphics_frame(handle, frame, cached_images, cached_image_count));
    CHECK(ghostty_render_state_clean(handle->render));
    *out_frame = frame;
    frame = NULL;
cleanup:
    if (cells) ghostty_render_state_row_cells_free(cells);
    if (rows) ghostty_render_state_row_iterator_free(rows);
    vt_free_frame(frame);
    return result;
#undef CHECK
}

int vt_take_replies(VTHandle *handle, uint8_t **bytes, size_t *count) {
    if (!handle || handle->failed) return GHOSTTY_INVALID_VALUE;
    *bytes = handle->replies; *count = handle->reply_count;
    handle->replies = NULL; handle->reply_count = 0;
    return GHOSTTY_SUCCESS;
}

void vt_free_bytes(uint8_t *bytes) { free(bytes); }

#ifdef VT_TEST_HOOKS
void vt_test_mark_failed(VTHandle *handle) { if (handle) handle->failed = true; }
#endif
