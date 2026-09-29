#include "VTInternal.h"

static GhosttyPoint viewport(uint16_t column, uint16_t row) {
    return (GhosttyPoint){.tag = GHOSTTY_POINT_TAG_VIEWPORT,
        .value.coordinate = {.x = column, .y = row}};
}

int vt_pointer_viewport(VTHandle *handle, VTViewportScalars *out) {
    *out = (VTViewportScalars){0};
    if (!handle || handle->failed) return GHOSTTY_INVALID_VALUE;
    GhosttyTerminalScrollbar scrollbar;
    GhosttyResult result = ghostty_terminal_get(handle->terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &scrollbar);
    if (result != GHOSTTY_SUCCESS) return result;
    *out = (VTViewportScalars){scrollbar.total, scrollbar.offset, scrollbar.len};
    return GHOSTTY_SUCCESS;
}

int vt_pointer_modes(VTHandle *handle, VTPointerModes *out) {
    *out = (VTPointerModes){0};
    if (!handle || handle->failed) return GHOSTTY_INVALID_VALUE;
    GhosttyResult result = ghostty_terminal_get(handle->terminal, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &out->tracking);
    if (result != GHOSTTY_SUCCESS) return result;
    result = ghostty_terminal_get(handle->terminal, GHOSTTY_TERMINAL_DATA_MOUSE_SHIFT_CAPTURE, &out->shift_capture);
    if (result != GHOSTTY_SUCCESS && result != GHOSTTY_NO_VALUE) return result;
    GhosttyTerminalScreen screen;
    result = ghostty_terminal_get(handle->terminal, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen);
    if (result != GHOSTTY_SUCCESS) return result;
    out->alternate = screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE;
    GhosttyTerminalModeConfig mode = {.mode = GHOSTTY_MODE_ALT_SCROLL};
    result = ghostty_terminal_get(handle->terminal, GHOSTTY_TERMINAL_DATA_MODE, &mode);
    if (result == GHOSTTY_SUCCESS) out->alternate_scroll = mode.value;
    return result;
}

int vt_selection_contains(VTHandle *handle, uint16_t column, uint16_t row, bool *out) {
    *out = false;
    if (!handle || handle->failed) return GHOSTTY_INVALID_VALUE;
    GhosttySelection selection = GHOSTTY_INIT_SIZED(GhosttySelection);
    GhosttyResult result = ghostty_terminal_get(handle->terminal, GHOSTTY_TERMINAL_DATA_SELECTION, &selection);
    if (result == GHOSTTY_NO_VALUE) return GHOSTTY_SUCCESS;
    if (result != GHOSTTY_SUCCESS) return result;
    return ghostty_terminal_selection_contains(handle->terminal, &selection, viewport(column, row), out);
}

void vt_selection_gesture_reset(VTHandle *handle) {
    if (!handle) return;
    ghostty_selection_gesture_reset(handle->selection_gesture, handle->terminal);
    handle->selection_press_time = 0;
}

int vt_selection_gesture(VTHandle *handle, const VTGestureInput *input, VTGestureResult *out) {
    if (!out) return GHOSTTY_INVALID_VALUE;
    *out = (VTGestureResult){0};
    if (!handle || handle->failed || !input || input->kind < 0 || input->kind > 3) return GHOSTTY_INVALID_VALUE;
    GhosttyResult result;
    GhosttySelectionGestureEvent event = NULL;
    GhosttySelectionGestureEventType kind = input->kind;
    GhosttyGridRef ref = GHOSTTY_INIT_SIZED(GhosttyGridRef);
    GhosttySelection selection = GHOSTTY_INIT_SIZED(GhosttySelection);
    // Shift extends a previous pointer selection after the repeat-click
    // interval, preserving the native tracked anchor and selection behavior.
    if (kind == GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_PRESS && input->extend &&
        input->time > handle->selection_press_time && input->time - handle->selection_press_time > 500000000) {
        uint8_t clicks = 0;
        result = ghostty_selection_gesture_get(handle->selection_gesture, handle->terminal,
            GHOSTTY_SELECTION_GESTURE_DATA_CLICK_COUNT, &clicks);
        if (result != GHOSTTY_SUCCESS) return result;
        result = ghostty_terminal_get(handle->terminal, GHOSTTY_TERMINAL_DATA_SELECTION, &selection);
        if (result != GHOSTTY_SUCCESS && result != GHOSTTY_NO_VALUE) return result;
        if (clicks > 0 && result == GHOSTTY_SUCCESS) kind = GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_DRAG;
    }
    if (kind != GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_PRESS) {
        result = ghostty_selection_gesture_get(handle->selection_gesture, handle->terminal,
            GHOSTTY_SELECTION_GESTURE_DATA_ANCHOR, &ref);
        if (result == GHOSTTY_NO_VALUE) { vt_selection_gesture_reset(handle); return GHOSTTY_SUCCESS; }
        if (result != GHOSTTY_SUCCESS) return result;
    }
#define CHECK(call) do { result = (call); if (result != GHOSTTY_SUCCESS) goto cleanup; } while (0)
    CHECK(ghostty_selection_gesture_event_new(NULL, &event, kind));
    if (kind == GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_AUTOSCROLL_TICK) {
        GhosttyPointCoordinate point = {.x = input->column, .y = input->row};
        CHECK(ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_VIEWPORT, &point));
    } else {
        // Resolve immediately before use. No event containing a borrowed ref
        // survives this operation or any intervening terminal mutation.
        CHECK(ghostty_terminal_grid_ref(handle->terminal, viewport(input->column, input->row), &ref));
        CHECK(ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref));
    }
    if (kind != GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_RELEASE) {
        GhosttySurfacePosition position = {.x = input->x, .y = input->y};
        CHECK(ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &position));
        if (kind == GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_PRESS) {
            if (input->word) {
                // Direct semantic long-press: native word anchors, reversal,
                // wrapped rows and autoscroll, without a fake click sequence.
                GhosttySelectionGestureBehaviors behaviors = {
                    .single_click = GHOSTTY_SELECTION_GESTURE_BEHAVIOR_WORD,
                    .double_click = GHOSTTY_SELECTION_GESTURE_BEHAVIOR_WORD,
                    .triple_click = GHOSTTY_SELECTION_GESTURE_BEHAVIOR_WORD,
                };
                CHECK(ghostty_selection_gesture_event_set(event,
                    GHOSTTY_SELECTION_GESTURE_EVENT_OPT_BEHAVIORS, &behaviors));
            }
            uint64_t interval = 500000000;
            double distance = input->cell_width;
            CHECK(ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_TIME_NS, &input->time));
            CHECK(ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_INTERVAL_NS, &interval));
            CHECK(ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_DISTANCE, &distance));
            handle->selection_press_time = input->time;
        } else {
            GhosttySelectionGestureGeometry geometry = {.columns = input->columns, .cell_width = input->cell_width,
                .padding_left = input->padding, .screen_height = input->screen_height};
            CHECK(ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_GEOMETRY, &geometry));
            CHECK(ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_RECTANGLE, &input->rectangle));
        }
    }
    result = ghostty_selection_gesture_event(handle->selection_gesture, handle->terminal, event, &selection);
    ghostty_selection_gesture_event_free(event);
    event = NULL;
    if (result != GHOSTTY_SUCCESS && result != GHOSTTY_NO_VALUE) goto cleanup;
    if (kind != GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_RELEASE) {
        // Installing the result immediately converts it to terminal-owned
        // tracked refs. Release updates gesture state and preserves selection.
        CHECK(ghostty_terminal_set(handle->terminal, GHOSTTY_TERMINAL_OPT_SELECTION,
            result == GHOSTTY_SUCCESS ? &selection : NULL));
    }
    CHECK(ghostty_selection_gesture_get(handle->selection_gesture, handle->terminal,
        GHOSTTY_SELECTION_GESTURE_DATA_CLICK_COUNT, &out->clicks));
    CHECK(ghostty_selection_gesture_get(handle->selection_gesture, handle->terminal,
        GHOSTTY_SELECTION_GESTURE_DATA_DRAGGED, &out->dragged));
    GhosttySelectionGestureAutoscroll autoscroll;
    CHECK(ghostty_selection_gesture_get(handle->selection_gesture, handle->terminal,
        GHOSTTY_SELECTION_GESTURE_DATA_AUTOSCROLL, &autoscroll));
    out->autoscroll = autoscroll;
    out->active = out->clicks > 0;
    result = GHOSTTY_SUCCESS;
cleanup:
    ghostty_selection_gesture_event_free(event);
    return handle->failed ? GHOSTTY_OUT_OF_MEMORY : result;
#undef CHECK
}
