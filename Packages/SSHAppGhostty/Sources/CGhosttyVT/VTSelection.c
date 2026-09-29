#include "VTInternal.h"
#include <limits.h>
#include <stdlib.h>

static GhosttyPoint viewport(uint16_t x, uint16_t y) {
    return (GhosttyPoint){.tag = GHOSTTY_POINT_TAG_VIEWPORT, .value.coordinate = {.x = x, .y = y}};
}

int vt_select(VTHandle *handle, int kind, uint16_t column, uint16_t row) {
    if (!handle || handle->failed) return GHOSTTY_INVALID_VALUE;
    // Explicit selection/Copy supersedes a held pointer's tracked anchor.
    // Later queued motion must not recreate the selection that was replaced.
    vt_selection_gesture_reset(handle);
    if (kind == 0) return ghostty_terminal_set(handle->terminal, GHOSTTY_TERMINAL_OPT_SELECTION, NULL);
    GhosttySelection selection = GHOSTTY_INIT_SIZED(GhosttySelection);
    GhosttyGridRef ref = GHOSTTY_INIT_SIZED(GhosttyGridRef);
    GhosttyResult result;
    if (kind == 3) {
        result = ghostty_terminal_select_all(handle->terminal, &selection);
    } else {
        result = ghostty_terminal_grid_ref(handle->terminal, viewport(column, row), &ref);
        if (result != GHOSTTY_SUCCESS) return result;
        switch (kind) {
        case 1: {
            GhosttyTerminalSelectWordOptions options = GHOSTTY_INIT_SIZED(GhosttyTerminalSelectWordOptions);
            options.ref = ref;
            result = ghostty_terminal_select_word(handle->terminal, &options, &selection);
            break;
        }
        case 2: {
            GhosttyTerminalSelectLineOptions options = GHOSTTY_INIT_SIZED(GhosttyTerminalSelectLineOptions);
            options.ref = ref;
            result = ghostty_terminal_select_line(handle->terminal, &options, &selection);
            break;
        }
        case 4: result = ghostty_terminal_select_output(handle->terminal, ref, &selection); break;
        default: return GHOSTTY_INVALID_VALUE;
        }
    }
    if (result == GHOSTTY_NO_VALUE) return ghostty_terminal_set(handle->terminal, GHOSTTY_TERMINAL_OPT_SELECTION, NULL);
    if (result != GHOSTTY_SUCCESS) return result;
    // The terminal immediately converts the snapshots to its own tracked refs.
    return ghostty_terminal_set(handle->terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &selection);
}

int vt_move_selection(VTHandle *handle, bool start, uint16_t column, uint16_t row) {
    if (!handle || handle->failed) return GHOSTTY_INVALID_VALUE;
    vt_selection_gesture_reset(handle);
    GhosttySelection selection = GHOSTTY_INIT_SIZED(GhosttySelection);
    GhosttyResult result = ghostty_terminal_get(handle->terminal, GHOSTTY_TERMINAL_DATA_SELECTION, &selection);
    if (result == GHOSTTY_NO_VALUE) return GHOSTTY_SUCCESS;
    if (result != GHOSTTY_SUCCESS) return result;
    // Read fresh endpoints after every mutation; never retain raw refs across calls.
    result = ghostty_terminal_grid_ref(handle->terminal, viewport(column, row), start ? &selection.start : &selection.end);
    if (result != GHOSTTY_SUCCESS) return result;
    return ghostty_terminal_set(handle->terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &selection);
}

int vt_has_selection(VTHandle *handle, bool *out) {
    if (!out) return GHOSTTY_INVALID_VALUE;
    *out = false;
    if (!handle || handle->failed) return GHOSTTY_INVALID_VALUE;
    GhosttySelection selection = GHOSTTY_INIT_SIZED(GhosttySelection);
    GhosttyResult result = ghostty_terminal_get(handle->terminal, GHOSTTY_TERMINAL_DATA_SELECTION, &selection);
    if (result == GHOSTTY_NO_VALUE) return GHOSTTY_SUCCESS;
    if (result != GHOSTTY_SUCCESS) return result;
    *out = true;
    return GHOSTTY_SUCCESS;
}

int vt_copy_selection(VTHandle *handle, uint8_t **bytes, size_t *count) {
    *bytes = NULL; *count = 0;
    if (!handle || handle->failed) return GHOSTTY_INVALID_VALUE;
    GhosttyTerminalSelectionFormatOptions options = GHOSTTY_INIT_SIZED(GhosttyTerminalSelectionFormatOptions);
    options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN;
    options.unwrap = true; options.trim = true;
    GhosttyResult result = ghostty_terminal_selection_format_buf(handle->terminal, options, NULL, 0, count);
    if (result == GHOSTTY_NO_VALUE) { *count = 0; return GHOSTTY_SUCCESS; }
    if (result != GHOSTTY_OUT_OF_SPACE) return result;
    if (*count == 0) return GHOSTTY_SUCCESS;
    uint8_t *buffer = malloc(*count);
    if (!buffer) return GHOSTTY_OUT_OF_MEMORY;
    result = ghostty_terminal_selection_format_buf(handle->terminal, options, buffer, *count, count);
    if (result != GHOSTTY_SUCCESS) { free(buffer); return result; }
    *bytes = buffer;
    return GHOSTTY_SUCCESS;
}

int vt_drag_selection(VTHandle *handle, bool start, uint16_t column, uint16_t row,
                       intptr_t scroll_rows, bool *out_active) {
    *out_active = false;
    if (!handle || handle->failed) return GHOSTTY_INVALID_VALUE;
    // Output may have cleared selection after UIKit admitted this drag. Do not
    // scroll or create a replacement selection in that case.
    GhosttySelection selection = GHOSTTY_INIT_SIZED(GhosttySelection);
    GhosttyResult result = ghostty_terminal_get(handle->terminal, GHOSTTY_TERMINAL_DATA_SELECTION, &selection);
    if (result == GHOSTTY_NO_VALUE) return GHOSTTY_SUCCESS;
    if (result != GHOSTTY_SUCCESS) return result;
    result = vt_scroll(handle, scroll_rows);
    if (result != GHOSTTY_SUCCESS) return result;
    // vt_move_selection reads fresh native endpoints AFTER the scroll. Never
    // reuse the selection/grid snapshots obtained before a mutation.
    result = vt_move_selection(handle, start, column, row);
    if (result == GHOSTTY_SUCCESS) *out_active = true;
    return result;
}

static int endpoint(VTHandle *handle, const VTFrame *frame, const GhosttyGridRef *ref, VTPoint *out) {
    GhosttyPointCoordinate point;
    GhosttyResult result = ghostty_terminal_point_from_grid_ref(handle->terminal, ref, GHOSTTY_POINT_TAG_SCREEN, &point);
    if (result != GHOSTTY_SUCCESS) return result;
    if (frame->viewport_offset > INT64_MAX) return GHOSTTY_INVALID_VALUE;
    // Keep signed, owned geometry even above/below the viewport. Display
    // clamping must not replace the native tracked endpoint with an edge cell.
    int64_t row = (int64_t)point.y - (int64_t)frame->viewport_offset;
    *out = (VTPoint){.column = point.x, .row = row,
        .visible = point.x < frame->columns && row >= 0 && row < frame->rows};
    return GHOSTTY_SUCCESS;
}

int vt_adjust_selection(VTHandle *handle, bool start, bool forward, bool *out_changed) {
    *out_changed = false;
    if (!handle || handle->failed) return GHOSTTY_INVALID_VALUE;
    vt_selection_gesture_reset(handle);
    GhosttySelection selection = GHOSTTY_INIT_SIZED(GhosttySelection);
    GhosttyResult result = ghostty_terminal_get(handle->terminal, GHOSTTY_TERMINAL_DATA_SELECTION, &selection);
    if (result == GHOSTTY_NO_VALUE) return GHOSTTY_SUCCESS;
    if (result != GHOSTTY_SUCCESS) return result;
    GhosttySelectionOrder before, after;
    result = ghostty_terminal_selection_order(handle->terminal, &selection, &before);
    if (result != GHOSTTY_SUCCESS) return result;
    GhosttyPointCoordinate original, adjusted, fixed;
    result = ghostty_terminal_point_from_grid_ref(handle->terminal, start ? &selection.start : &selection.end,
                                                GHOSTTY_POINT_TAG_SCREEN, &original);
    if (result != GHOSTTY_SUCCESS) return result;
    result = ghostty_terminal_point_from_grid_ref(handle->terminal, start ? &selection.end : &selection.start,
                                                GHOSTTY_POINT_TAG_SCREEN, &fixed);
    if (result != GHOSTTY_SUCCESS) return result;
    // The public adjustment API moves logical end. Swap the snapshot locally
    // to adjust start, then restore identities before installing the selection.
    if (start) { GhosttyGridRef ref = selection.start; selection.start = selection.end; selection.end = ref; }
    result = ghostty_terminal_selection_adjust(handle->terminal, &selection,
        forward ? GHOSTTY_SELECTION_ADJUST_RIGHT : GHOSTTY_SELECTION_ADJUST_LEFT);
    if (result != GHOSTTY_SUCCESS) return result;
    if (start) { GhosttyGridRef ref = selection.start; selection.start = selection.end; selection.end = ref; }
    result = ghostty_terminal_selection_order(handle->terminal, &selection, &after);
    if (result != GHOSTTY_SUCCESS) return result;
    result = ghostty_terminal_point_from_grid_ref(handle->terminal, start ? &selection.start : &selection.end,
                                                GHOSTTY_POINT_TAG_SCREEN, &adjusted);
    if (result != GHOSTTY_SUCCESS) return result;
    // VoiceOver nudges may reach the other endpoint but cannot cross it.
    if (before != after && (adjusted.x != fixed.x || adjusted.y != fixed.y)) return GHOSTTY_SUCCESS;
    if (original.x == adjusted.x && original.y == adjusted.y) return GHOSTTY_SUCCESS;
    result = ghostty_terminal_set(handle->terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &selection);
    if (result != GHOSTTY_SUCCESS) return result;
    *out_changed = true;
    // Reveal the adjusted endpoint without retaining refs across the mutation.
    GhosttyTerminalScrollbar scrollbar;
    result = ghostty_terminal_get(handle->terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &scrollbar);
    if (result != GHOSTTY_SUCCESS) return result;
    if (scrollbar.offset > INT64_MAX || scrollbar.len == 0) return GHOSTTY_INVALID_VALUE;
    int64_t scroll = 0;
    if (adjusted.y < scrollbar.offset) scroll = (int64_t)adjusted.y - (int64_t)scrollbar.offset;
    else if (adjusted.y - scrollbar.offset >= scrollbar.len)
        scroll = (int64_t)(adjusted.y - scrollbar.offset - scrollbar.len + 1);
    return scroll ? vt_scroll(handle, scroll) : GHOSTTY_SUCCESS;
}

int vt_selection_frame(VTHandle *handle, VTFrame *frame) {
    GhosttySelection selection = GHOSTTY_INIT_SIZED(GhosttySelection);
    GhosttyResult result = ghostty_terminal_get(handle->terminal, GHOSTTY_TERMINAL_DATA_SELECTION, &selection);
    if (result == GHOSTTY_NO_VALUE) return GHOSTTY_SUCCESS;
    if (result != GHOSTTY_SUCCESS) return result;
    frame->has_selection = true;
    GhosttySelectionOrder order;
    result = ghostty_terminal_selection_order(handle->terminal, &selection, &order);
    if (result != GHOSTTY_SUCCESS) return result;
    frame->selection_reversed = order == GHOSTTY_SELECTION_ORDER_REVERSE;
    result = endpoint(handle, frame, &selection.start, &frame->selection_start);
    if (result != GHOSTTY_SUCCESS) return result;
    return endpoint(handle, frame, &selection.end, &frame->selection_end);
}
