#ifndef SSHAPP_VT_BRIDGE_H
#define SSHAPP_VT_BRIDGE_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Private to the development app. Only VTTerminal's actor may access a handle.
typedef struct VTHandle VTHandle;
enum { VT_EVENT_TITLE, VT_EVENT_DIRECTORY, VT_EVENT_BELL, VT_EVENT_PROGRESS, VT_EVENT_NOTIFICATION };
typedef struct {
    int kind;
    uint8_t *first, *second;
    size_t first_count, second_count;
    int state, percent;
} VTNativeEvent;
int vt_take_events(VTHandle *handle, VTNativeEvent **events, size_t *count);
void vt_free_events(VTNativeEvent *events, size_t count);
typedef struct {
    uint16_t column, row, width;
    size_t offset, count;
} VTLinkMapEntry;
typedef struct {
    uint8_t *uri, *line;
    size_t uri_count, line_count, hit_start, hit_end;
    VTLinkMapEntry *map;
    size_t map_count;
} VTLinkContext;
int vt_copy_link_context(VTHandle *handle, uint16_t column, uint16_t row,
                         bool geometry, VTLinkContext *out);
void vt_free_link_context(VTLinkContext *context);
typedef struct { uint8_t r, g, b; } VTRGB;
typedef struct { uint8_t index; VTRGB color; } VTPaletteEntry;
typedef struct {
    VTRGB foreground, background, cursor;
    bool has_cursor, cursor_blink, dark;
    int cursor_style;
    const VTPaletteEntry *palette;
    size_t palette_count;
} VTConfiguration;
int vt_configure(VTHandle *handle, const VTConfiguration *configuration);
typedef struct {
    uint8_t *text;
    size_t text_length;
    uint8_t width; // 0 for a wide-cell spacer; 1 or 2 for a leading cell.
    VTRGB foreground, background;
    bool bold, italic, faint, invisible, blink, overline, strikethrough, selected;
    int underline_style;
    VTRGB underline_color;
    bool underline_color_explicit;
    bool image_placeholder;
} VTCell;
typedef struct { uint16_t column; int64_t row; bool visible; } VTPoint;
typedef struct {
    uint64_t generation;
    uint32_t width, height;
    // Owned premultiplied RGBA8, top row first. NULL when already in the
    // caller's immutable generation cache. Never a pointer into VT storage.
    uint8_t *rgba;
    size_t byte_count;
} VTImage;
typedef struct {
    size_t image_index;
    uint32_t image_id, placement_id;
    int32_t z, column, row;
    double offset_x, offset_y, pixel_width, pixel_height;
    double source_x, source_y, source_width, source_height;
    bool is_unicode;
} VTImagePlacement;
typedef struct {
    uint16_t columns, rows, cursor_column, cursor_row;
    bool cursor_visible, cursor_blinking, cursor_wide_tail;
    int cursor_style;
    VTRGB foreground, background, cursor_color;
    size_t scrollback_rows, scrollback_limit_bytes;
    uint64_t viewport_total, viewport_offset, viewport_rows;
    VTCell *cells;
    bool has_selection, selection_reversed, mouse_tracking;
    VTPoint selection_start, selection_end;
    uint8_t kitty_keyboard_flags;
    VTImage *images;
    size_t image_count;
    VTImagePlacement *placements;
    size_t placement_count, virtual_placement_count;
    uint64_t image_storage_limit;
} VTFrame;

typedef struct {
    void *userdata;
    bool (*reserve)(void *userdata, size_t bytes);
    void (*release)(void *userdata, size_t bytes);
} VTImageBudget;
int vt_create(uint16_t columns, uint16_t rows, size_t scrollback_bytes,
              uint64_t image_storage_bytes, const VTImageBudget *image_budget,
              size_t image_budget_bytes, VTHandle **out_handle);
void vt_destroy(VTHandle *handle);
int vt_write(VTHandle *handle, const uint8_t *bytes, size_t count);
int vt_resize(VTHandle *handle, uint16_t columns, uint16_t rows,
              uint32_t cell_width, uint32_t cell_height);
int vt_scroll(VTHandle *handle, intptr_t delta);
int vt_scroll_to_bottom(VTHandle *handle);
// Frames and replies are independent owned allocations, never VT borrowed data.
int vt_copy_frame(VTHandle *handle, const uint64_t *cached_images,
                  size_t cached_image_count, VTFrame **out_frame);
void vt_free_frame(VTFrame *frame);
int vt_take_replies(VTHandle *handle, uint8_t **bytes, size_t *count);
void vt_free_bytes(uint8_t *bytes);
/// Test seam: put a handle in the failed state reached after native allocation
/// or event failures, which cannot be provoked deterministically. Defined only
/// with VT_TEST_HOOKS; Swift calls it only under the same condition.
void vt_test_mark_failed(VTHandle *handle);
// Selection kinds: 0 clear, 1 word, 2 line, 3 all, 4 command output.
int vt_select(VTHandle *handle, int kind, uint16_t column, uint16_t row);
int vt_move_selection(VTHandle *handle, bool start, uint16_t column, uint16_t row);
int vt_adjust_selection(VTHandle *handle, bool start, bool forward, bool *out_changed);
int vt_drag_selection(VTHandle *handle, bool start, uint16_t column, uint16_t row,
                       intptr_t scroll_rows, bool *out_active);
int vt_copy_selection(VTHandle *handle, uint8_t **bytes, size_t *count);
// Presence only: no frame, text formatting, allocation, or selection mutation.
int vt_has_selection(VTHandle *handle, bool *out);
typedef struct {
    bool tracking, shift_capture, alternate, alternate_scroll;
} VTPointerModes;
typedef struct {
    int32_t kind;
    uint16_t column, row;
    double x, y;
    uint32_t columns, cell_width, padding, screen_height;
    uint64_t time;
    bool word, rectangle, extend;
} VTGestureInput;
typedef struct {
    bool active, dragged;
    uint8_t clicks;
    int32_t autoscroll;
} VTGestureResult;
int vt_pointer_modes(VTHandle *handle, VTPointerModes *out);
// Scalar-only viewport read for an opt-in DEBUG release boundary. No render
// state update, frame extraction, allocation, or terminal mutation.
typedef struct { uint64_t total, offset, rows; } VTViewportScalars;
int vt_pointer_viewport(VTHandle *handle, VTViewportScalars *out);
int vt_selection_contains(VTHandle *handle, uint16_t column, uint16_t row, bool *out);
int vt_selection_gesture(VTHandle *handle, const VTGestureInput *input, VTGestureResult *out);
void vt_selection_gesture_reset(VTHandle *handle);
int vt_key(VTHandle *handle, uint16_t hid, int action, uint16_t mods,
           uint16_t consumed_mods, uint32_t unshifted, const uint8_t *text, size_t count);
// Host clear-screen action, never parser input. Alternate screen is unhandled.
int vt_clear_screen(VTHandle *handle, bool *handled, bool *needs_form_feed);
int vt_focus(VTHandle *handle, bool focused);
int vt_paste(VTHandle *handle, const uint8_t *bytes, size_t count, bool allow_unsafe);
int vt_mouse(VTHandle *handle, int action, int button, uint16_t mods,
             double x, double y, uint32_t width, uint32_t height,
             uint32_t cell_width, uint32_t cell_height, uint32_t padding, bool pressed);
uint64_t vt_process_footprint(void);
// Development-only process diagnostics. Malloc reservations are not resident
// memory, and separately sampled counters are not an atomic allocation census.
typedef struct {
    bool valid;
    uint64_t footprint, resident, internal, compressed;
    uint64_t reusable, device, footprint_peak;
    int64_t graphics_footprint, graphics_compressed, purgeable_nonvolatile;
    uint64_t malloc_in_use, malloc_reserved;
} VTMemoryMetrics;
VTMemoryMetrics vt_memory_metrics(void);
// Explicit diagnostic intervention, not an application memory-warning policy.
uint64_t vt_allocator_pressure_relief(void);
#endif
