#include "VTInternal.h"
#include <stdlib.h>
#include <string.h>

// Events belong to one admitted write, not to a visual snapshot. The actor
// drains them before returning that write's result. No callback schedules UI.
static uint8_t *copy_string(GhosttyString value) {
    if (!value.len) return NULL;
    uint8_t *copy = malloc(value.len);
    if (copy) memcpy(copy, value.ptr, value.len);
    return copy;
}

static void append(VTHandle *handle, int kind, GhosttyString first, GhosttyString second,
                   int state, int percent) {
    if (handle->failed) return;
    VTNativeEvent event = {.kind = kind, .first_count = first.len, .second_count = second.len,
                     .state = state, .percent = percent};
    event.first = copy_string(first);
    event.second = copy_string(second);
    if ((first.len && !event.first) || (second.len && !event.second)) goto failure;
    if (handle->event_count == handle->event_capacity) {
        if (handle->event_capacity > SIZE_MAX / 2 / sizeof(VTNativeEvent)) goto failure;
        size_t capacity = handle->event_capacity ? handle->event_capacity * 2 : 8;
        VTNativeEvent *events = realloc(handle->events, capacity * sizeof(*events));
        if (!events) goto failure;
        handle->events = events;
        handle->event_capacity = capacity;
    }
    handle->events[handle->event_count++] = event;
    return;
failure:
    free(event.first); free(event.second);
    handle->failed = true; // Never report a successful write with lost events.
}

static void title_changed(GhosttyTerminal terminal, void *userdata) {
    VTHandle *handle = userdata;
    GhosttyString value = {0};
    if (ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_TITLE, &value) != GHOSTTY_SUCCESS) {
        handle->failed = true; return;
    }
    append(handle, VT_EVENT_TITLE, value, (GhosttyString){0}, 0, 0);
}

static void pwd_changed(GhosttyTerminal terminal, void *userdata) {
    VTHandle *handle = userdata;
    GhosttyString value = {0};
    if (ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_PWD, &value) != GHOSTTY_SUCCESS) {
        handle->failed = true; return;
    }
    append(handle, VT_EVENT_DIRECTORY, value, (GhosttyString){0}, 0, 0);
}

static void bell(GhosttyTerminal terminal, void *userdata) {
    (void)terminal;
    append(userdata, VT_EVENT_BELL, (GhosttyString){0}, (GhosttyString){0}, 0, 0);
}

static void notification(GhosttyTerminal terminal, void *userdata,
                          const GhosttyTerminalDesktopNotification *value) {
    (void)terminal;
    if (!value || value->size < sizeof(*value)) { ((VTHandle *)userdata)->failed = true; return; }
    append(userdata, VT_EVENT_NOTIFICATION, value->title, value->body, 0, 0);
}

static void progress(GhosttyTerminal terminal, void *userdata, const GhosttyTerminalProgressReport *value) {
    (void)terminal;
    if (!value || value->size < sizeof(*value)) { ((VTHandle *)userdata)->failed = true; return; }
    append(userdata, VT_EVENT_PROGRESS, (GhosttyString){0}, (GhosttyString){0}, value->state, value->progress);
}

int vt_events_initialize(VTHandle *handle) {
    GhosttyResult result;
#define CHECK(call) do { result = (call); if (result != GHOSTTY_SUCCESS) return result; } while (0)
    CHECK(ghostty_terminal_set(handle->terminal, GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, title_changed));
    CHECK(ghostty_terminal_set(handle->terminal, GHOSTTY_TERMINAL_OPT_PWD_CHANGED, pwd_changed));
    CHECK(ghostty_terminal_set(handle->terminal, GHOSTTY_TERMINAL_OPT_BELL, bell));
    CHECK(ghostty_terminal_set(handle->terminal, GHOSTTY_TERMINAL_OPT_DESKTOP_NOTIFICATION, notification));
    CHECK(ghostty_terminal_set(handle->terminal, GHOSTTY_TERMINAL_OPT_PROGRESS_REPORT, progress));
    return GHOSTTY_SUCCESS;
#undef CHECK
}

void vt_free_events(VTNativeEvent *events, size_t count) {
    for (size_t i = 0; i < count; ++i) { free(events[i].first); free(events[i].second); }
    free(events);
}

int vt_take_events(VTHandle *handle, VTNativeEvent **events, size_t *count) {
    *events = NULL; *count = 0;
    if (!handle || handle->failed) return GHOSTTY_INVALID_VALUE;
    *events = handle->events;
    *count = handle->event_count;
    handle->events = NULL;
    handle->event_count = handle->event_capacity = 0;
    return GHOSTTY_SUCCESS;
}
