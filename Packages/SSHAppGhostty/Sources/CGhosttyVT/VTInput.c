#include "VTInternal.h"
#include <stdlib.h>

// USB HID usages from UIKit map directly to VT keys.
static GhosttyKey key_for_hid(uint16_t hid) {
    if (hid >= 4 && hid <= 29) return GHOSTTY_KEY_A + (hid - 4);
    if (hid >= 58 && hid <= 69) return GHOSTTY_KEY_F1 + (hid - 58);
    if (hid >= 104 && hid <= 115) return GHOSTTY_KEY_F13 + (hid - 104);
    if (hid >= 30 && hid <= 38) return GHOSTTY_KEY_DIGIT_1 + (hid - 30);
    if (hid >= 89 && hid <= 97) return GHOSTTY_KEY_NUMPAD_1 + (hid - 89);
    switch (hid) {
    case 39: return GHOSTTY_KEY_DIGIT_0;
    case 40: return GHOSTTY_KEY_ENTER;
    case 41: return GHOSTTY_KEY_ESCAPE;
    case 42: return GHOSTTY_KEY_BACKSPACE;
    case 43: return GHOSTTY_KEY_TAB;
    case 44: return GHOSTTY_KEY_SPACE;
    case 45: return GHOSTTY_KEY_MINUS;
    case 46: return GHOSTTY_KEY_EQUAL;
    case 47: return GHOSTTY_KEY_BRACKET_LEFT;
    case 48: return GHOSTTY_KEY_BRACKET_RIGHT;
    case 49: return GHOSTTY_KEY_BACKSLASH;
    case 51: return GHOSTTY_KEY_SEMICOLON;
    case 52: return GHOSTTY_KEY_QUOTE;
    case 53: return GHOSTTY_KEY_BACKQUOTE;
    case 54: return GHOSTTY_KEY_COMMA;
    case 55: return GHOSTTY_KEY_PERIOD;
    case 56: return GHOSTTY_KEY_SLASH;
    case 57: return GHOSTTY_KEY_CAPS_LOCK;
    case 70: return GHOSTTY_KEY_PRINT_SCREEN;
    case 71: return GHOSTTY_KEY_SCROLL_LOCK;
    case 72: return GHOSTTY_KEY_PAUSE;
    case 73: return GHOSTTY_KEY_INSERT;
    case 74: return GHOSTTY_KEY_HOME;
    case 75: return GHOSTTY_KEY_PAGE_UP;
    case 76: return GHOSTTY_KEY_DELETE;
    case 77: return GHOSTTY_KEY_END;
    case 78: return GHOSTTY_KEY_PAGE_DOWN;
    case 79: return GHOSTTY_KEY_ARROW_RIGHT;
    case 80: return GHOSTTY_KEY_ARROW_LEFT;
    case 81: return GHOSTTY_KEY_ARROW_DOWN;
    case 82: return GHOSTTY_KEY_ARROW_UP;
    case 83: return GHOSTTY_KEY_NUM_LOCK;
    case 84: return GHOSTTY_KEY_NUMPAD_DIVIDE;
    case 85: return GHOSTTY_KEY_NUMPAD_MULTIPLY;
    case 86: return GHOSTTY_KEY_NUMPAD_SUBTRACT;
    case 87: return GHOSTTY_KEY_NUMPAD_ADD;
    case 88: return GHOSTTY_KEY_NUMPAD_ENTER;
    case 98: return GHOSTTY_KEY_NUMPAD_0;
    case 99: return GHOSTTY_KEY_NUMPAD_DECIMAL;
    case 100: return GHOSTTY_KEY_INTL_BACKSLASH;
    case 101: return GHOSTTY_KEY_CONTEXT_MENU;
    case 103: return GHOSTTY_KEY_NUMPAD_EQUAL;
    case 117: return GHOSTTY_KEY_HELP;
    case 123: return GHOSTTY_KEY_CUT;
    case 124: return GHOSTTY_KEY_COPY;
    case 125: return GHOSTTY_KEY_PASTE;
    case 127: return GHOSTTY_KEY_AUDIO_VOLUME_MUTE;
    case 128: return GHOSTTY_KEY_AUDIO_VOLUME_UP;
    case 129: return GHOSTTY_KEY_AUDIO_VOLUME_DOWN;
    // HID modifier order differs from GhosttyKey; preserve each physical side.
    case 0xE0: return GHOSTTY_KEY_CONTROL_LEFT;
    case 0xE1: return GHOSTTY_KEY_SHIFT_LEFT;
    case 0xE2: return GHOSTTY_KEY_ALT_LEFT;
    case 0xE3: return GHOSTTY_KEY_META_LEFT;
    case 0xE4: return GHOSTTY_KEY_CONTROL_RIGHT;
    case 0xE5: return GHOSTTY_KEY_SHIFT_RIGHT;
    case 0xE6: return GHOSTTY_KEY_ALT_RIGHT;
    case 0xE7: return GHOSTTY_KEY_META_RIGHT;
    default: return GHOSTTY_KEY_UNIDENTIFIED;
    }
}

int vt_key(VTHandle *handle, uint16_t hid, int action, uint16_t mods,
           uint16_t consumed_mods, uint32_t unshifted, const uint8_t *text, size_t count) {
    if (!handle || handle->failed || action < 0 || action > 2 || (count && !text)) return GHOSTTY_INVALID_VALUE;
    GhosttyKeyEvent event = NULL;
    GhosttyResult result = ghostty_key_event_new(NULL, &event);
    if (result != GHOSTTY_SUCCESS) return result;
    ghostty_key_event_set_action(event, action);
    ghostty_key_event_set_key(event, key_for_hid(hid));
    ghostty_key_event_set_mods(event, mods);
    ghostty_key_event_set_consumed_mods(event, consumed_mods);
    ghostty_key_event_set_unshifted_codepoint(event, unshifted);
    ghostty_key_event_set_utf8(event, (const char *)text, count);
    ghostty_key_encoder_setopt_from_terminal(handle->key_encoder, handle->terminal);
    GhosttyOptionAsAlt alt = GHOSTTY_OPTION_AS_ALT_TRUE;
    ghostty_key_encoder_setopt(handle->key_encoder, GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT, &alt);
    size_t size = 0;
    result = ghostty_key_encoder_encode(handle->key_encoder, event, NULL, 0, &size);
    if (result == GHOSTTY_OUT_OF_SPACE && size > 0) {
        char *buffer = malloc(size);
        if (!buffer) result = GHOSTTY_OUT_OF_MEMORY;
        else {
            result = ghostty_key_encoder_encode(handle->key_encoder, event, buffer, size, &size);
            if (result == GHOSTTY_SUCCESS) vt_receive_reply(handle->terminal, handle, (uint8_t *)buffer, size);
            free(buffer);
        }
    } else if (size == 0 && result == GHOSTTY_OUT_OF_SPACE) result = GHOSTTY_SUCCESS;
    ghostty_key_event_free(event);
    return handle->failed ? GHOSTTY_OUT_OF_MEMORY : result;
}

int vt_clear_screen(VTHandle *handle, bool *handled, bool *needs_form_feed) {
    if (!handle || handle->failed) return GHOSTTY_INVALID_VALUE;
    GhosttyResult result = ghostty_terminal_clear_screen(handle->terminal, handled, needs_form_feed);
    if (result == GHOSTTY_SUCCESS && *handled) vt_selection_gesture_reset(handle);
    return result;
}

int vt_focus(VTHandle *handle, bool focused) {
    if (!handle || handle->failed) return GHOSTTY_INVALID_VALUE;
    GhosttyTerminalModeConfig mode = {.mode = GHOSTTY_MODE_FOCUS_EVENT};
    GhosttyResult result = ghostty_terminal_get(handle->terminal, GHOSTTY_TERMINAL_DATA_MODE, &mode);
    if (result != GHOSTTY_SUCCESS || !mode.value) return result;
    char bytes[3]; size_t size = 0;
    result = ghostty_focus_encode(focused ? GHOSTTY_FOCUS_GAINED : GHOSTTY_FOCUS_LOST, bytes, sizeof(bytes), &size);
    if (result == GHOSTTY_SUCCESS) vt_receive_reply(handle->terminal, handle, (uint8_t *)bytes, size);
    return handle->failed ? GHOSTTY_OUT_OF_MEMORY : result;
}

static bool read_paste(void *userdata, GhosttyString mime, GhosttyWriter writer) {
    (void)mime;
    const GhosttyString *text = userdata;
    return !text->len || writer.write(writer.userdata, text->ptr, text->len);
}

int vt_paste(VTHandle *handle, const uint8_t *bytes, size_t count, bool allow_unsafe) {
    if (!handle || handle->failed || (count && !bytes)) return GHOSTTY_INVALID_VALUE;
    GhosttyString text = {.ptr = bytes, .len = count};
    GhosttyString mime = {.ptr = (const uint8_t *)"text/plain", .len = 10};
    GhosttyPaste paste = GHOSTTY_INIT_SIZED(GhosttyPaste);
    paste.source = GHOSTTY_PASTE_SOURCE_CLIPBOARD;
    paste.location = GHOSTTY_CLIPBOARD_LOCATION_STANDARD;
    paste.mimes = &mime; paste.mimes_len = 1;
    paste.reader = (GhosttyMimeReader){.read = read_paste, .userdata = &text};
    paste.allow_unsafe = allow_unsafe;
    GhosttyResult result = ghostty_terminal_paste(handle->terminal, &paste, NULL);
    return handle->failed ? GHOSTTY_OUT_OF_MEMORY : result;
}

int vt_mouse(VTHandle *handle, int action, int button, uint16_t mods,
             double x, double y, uint32_t width, uint32_t height,
             uint32_t cell_width, uint32_t cell_height, uint32_t padding, bool pressed) {
    if (!handle || handle->failed || action < 0 || action > 2 || button < 0 || button > 11) return GHOSTTY_INVALID_VALUE;
    GhosttyMouseEvent event = NULL;
    GhosttyResult result = ghostty_mouse_event_new(NULL, &event);
    if (result != GHOSTTY_SUCCESS) return result;
    ghostty_mouse_event_set_action(event, action);
    if (button) ghostty_mouse_event_set_button(event, button);
    ghostty_mouse_event_set_mods(event, mods);
    ghostty_mouse_event_set_position(event, (GhosttyMousePosition){.x = x, .y = y});
    // Both setopt_from_terminal and SIZE clear the pinned encoder's last-cell
    // state, even when values are unchanged. Refresh modes after terminal
    // mutation and geometry only when changed so consecutive motion can dedupe.
    if (handle->mouse_options_dirty) {
        ghostty_mouse_encoder_setopt_from_terminal(handle->mouse_encoder, handle->terminal);
        handle->mouse_options_dirty = false;
    }
    if (handle->mouse_width != width || handle->mouse_height != height ||
        handle->mouse_cell_width != cell_width || handle->mouse_cell_height != cell_height ||
        handle->mouse_padding != padding) {
        GhosttyMouseEncoderSize size = GHOSTTY_INIT_SIZED(GhosttyMouseEncoderSize);
        size.screen_width = width; size.screen_height = height;
        size.cell_width = cell_width; size.cell_height = cell_height;
        size.padding_top = size.padding_bottom = size.padding_left = size.padding_right = padding;
        ghostty_mouse_encoder_setopt(handle->mouse_encoder, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size);
        handle->mouse_width = width; handle->mouse_height = height;
        handle->mouse_cell_width = cell_width; handle->mouse_cell_height = cell_height;
        handle->mouse_padding = padding;
    }
    ghostty_mouse_encoder_setopt(handle->mouse_encoder, GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &pressed);
    // A complete mouse report with bounded 32-bit coordinates fits here. Never
    // retry a stateful motion encoder after successful emission/deduplication.
    char buffer[128]; size_t written = 0;
    result = ghostty_mouse_encoder_encode(handle->mouse_encoder, event, buffer, sizeof(buffer), &written);
    if (result == GHOSTTY_SUCCESS) vt_receive_reply(handle->terminal, handle, (uint8_t *)buffer, written);
    ghostty_mouse_event_free(event);
    return handle->failed ? GHOSTTY_OUT_OF_MEMORY : result;
}
