#include "VTBridge.h"
#include <ghostty/vt.h>

// Private native storage. Only VTTerminal's serial executor calls this boundary.
struct VTHandle {
    GhosttyTerminal terminal;
    GhosttyRenderState render;
    GhosttyKeyEncoder key_encoder;
    GhosttyMouseEncoder mouse_encoder;
    GhosttySelectionGesture selection_gesture;
    uint64_t selection_press_time;
    bool mouse_options_dirty;
    uint32_t mouse_width, mouse_height, mouse_cell_width, mouse_cell_height, mouse_padding;
    uint8_t *replies;
    size_t reply_count;
    VTNativeEvent *events;
    size_t event_count, event_capacity;
    GhosttyColorRgb builtin_palette[256];
    bool scheme_known, dark;
    // Decoded PNG pixels this terminal could ever retain: the smaller of its
    // storage limit and the shared native image budget.
    size_t png_decode_limit;
    bool failed;
};
int vt_configuration_initialize(VTHandle *handle);
int vt_events_initialize(VTHandle *handle);
void vt_receive_reply(GhosttyTerminal terminal, void *userdata, const uint8_t *bytes, size_t count);
int vt_selection_frame(VTHandle *handle, VTFrame *frame);
int vt_graphics_initialize(void);
// The process-global PNG decoder has no terminal argument. vt_write publishes
// the writing terminal's limit on its own thread for the synchronous parse;
// decoding outside a write sees zero and is rejected.
extern _Thread_local size_t vt_png_decode_limit;
int vt_graphics_frame(VTHandle *handle, VTFrame *frame,
                      const uint64_t *cached_images, size_t cached_image_count);
