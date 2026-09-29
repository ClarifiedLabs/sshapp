#include "VTInternal.h"
#include <string.h>

static bool color_scheme(GhosttyTerminal terminal, void *userdata, GhosttyColorScheme *out) {
    (void)terminal;
    VTHandle *handle = userdata;
    if (!handle->scheme_known) return false;
    *out = handle->dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT;
    return true;
}

int vt_configuration_initialize(VTHandle *handle) {
    GhosttyResult result = ghostty_terminal_get(handle->terminal,
        GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT, handle->builtin_palette);
    if (result == GHOSTTY_SUCCESS) result = ghostty_terminal_set(handle->terminal,
        GHOSTTY_TERMINAL_OPT_COLOR_SCHEME, color_scheme);
    return result;
}

static GhosttyColorRgb rgb(VTRGB value) {
    return (GhosttyColorRgb){.r = value.r, .g = value.g, .b = value.b};
}

int vt_configure(VTHandle *handle, const VTConfiguration *configuration) {
    if (!handle || handle->failed || !configuration) return GHOSTTY_INVALID_VALUE;
    const VTConfiguration *c = configuration;
    if (c->cursor_style < 0 || c->cursor_style > 3 || c->palette_count > 256 ||
        (c->palette_count && !c->palette)) return GHOSTTY_INVALID_VALUE;
    GhosttyColorRgb palette[256];
    memcpy(palette, handle->builtin_palette, sizeof(palette));
    for (size_t i = 0; i < c->palette_count; i++) palette[c->palette[i].index] = rgb(c->palette[i].color);
    // Change defaults rather than sending OSC sequences. The public API keeps
    // remote overrides intact, including palette entries omitted by a theme.
    // Apply the allocation-bearing palette update first. Any subsequent error
    // poisons this handle rather than publishing a partially configured frame.
    GhosttyResult result = ghostty_terminal_set(handle->terminal, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, palette);
    GhosttyColorRgb foreground = rgb(c->foreground), background = rgb(c->background), cursor = rgb(c->cursor);
    GhosttyTerminalCursorStyle style = (GhosttyTerminalCursorStyle)c->cursor_style;
    if (result == GHOSTTY_SUCCESS) result = ghostty_terminal_set(handle->terminal, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &foreground);
    if (result == GHOSTTY_SUCCESS) result = ghostty_terminal_set(handle->terminal, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &background);
    if (result == GHOSTTY_SUCCESS) result = ghostty_terminal_set(handle->terminal, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, c->has_cursor ? &cursor : NULL);
    if (result == GHOSTTY_SUCCESS) result = ghostty_terminal_set(handle->terminal, GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_STYLE, &style);
    if (result == GHOSTTY_SUCCESS) result = ghostty_terminal_set(handle->terminal, GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_BLINK, &c->cursor_blink);
    bool ignore_blink_mode = true; // The app always supplies an explicit blink default.
    if (result == GHOSTTY_SUCCESS) result = ghostty_terminal_set(handle->terminal, GHOSTTY_TERMINAL_OPT_IGNORE_CURSOR_BLINK_MODE, &ignore_blink_mode);
    GhosttyTerminalModeConfig mode = {.mode = GHOSTTY_MODE_COLOR_SCHEME_REPORT};
    if (result == GHOSTTY_SUCCESS) result = ghostty_terminal_get(handle->terminal, GHOSTTY_TERMINAL_DATA_MODE, &mode);
    bool changed = !handle->scheme_known || handle->dark != c->dark;
    if (result == GHOSTTY_SUCCESS) {
        handle->scheme_known = true;
        handle->dark = c->dark;
        if (changed && mode.value) {
            char bytes[32];
            size_t count = 0;
            result = ghostty_color_scheme_report_encode(c->dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT,
                                                        bytes, sizeof(bytes), &count);
            if (result == GHOSTTY_SUCCESS) vt_receive_reply(handle->terminal, handle, (const uint8_t *)bytes, count);
        }
    }
    if (result != GHOSTTY_SUCCESS || handle->failed) {
        handle->failed = true;
        return result == GHOSTTY_SUCCESS ? GHOSTTY_OUT_OF_MEMORY : result;
    }
    return GHOSTTY_SUCCESS;
}
