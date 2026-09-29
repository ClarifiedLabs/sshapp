#include "VTInternal.h"
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

// The exact pin's Kitty decoder limits, checked before ImageIO decompresses.
// Native storage has its own configurable per-screen limit and eviction policy.
static const size_t max_image_bytes = 400 * 1024 * 1024;
static const uint32_t max_dimension = 10000;

_Thread_local size_t vt_png_decode_limit = 0;

static uint32_t big_endian(const uint8_t *p) {
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

static bool decode_png(void *userdata, const GhosttyAllocator *allocator,
                       const uint8_t *data, size_t count, GhosttySysImage *out) {
    (void)userdata;
    const uint8_t signature[] = {137, 80, 78, 71, 13, 10, 26, 10};
    if (count < 33 || count > max_image_bytes || memcmp(data, signature, 8) ||
        big_endian(data + 8) != 13 || memcmp(data + 12, "IHDR", 4)) return false;
    uint32_t width = big_endian(data + 16), height = big_endian(data + 20);
    // Reject from the header, before any pixel allocation or decompression,
    // an image the writing terminal's storage or shared budget cannot retain.
    if (!width || !height || width > max_dimension || height > max_dimension ||
        (size_t)width * height > max_image_bytes / 4 ||
        (size_t)width * height > vt_png_decode_limit / 4) return false;
    size_t length = (size_t)width * height * 4;
    bool success = false;
    uint8_t *rgba = NULL;
    CFDataRef bytes = NULL;
    CFDictionaryRef options = NULL;
    CGImageSourceRef source = NULL;
    CGImageRef image = NULL;
    CGColorSpaceRef space = NULL;
    CGContextRef context = NULL;
    bytes = CFDataCreateWithBytesNoCopy(NULL, data, count, kCFAllocatorNull);
    const void *keys[] = {kCGImageSourceShouldCache};
    const void *values[] = {kCFBooleanFalse};
    options = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks,
                                 &kCFTypeDictionaryValueCallBacks);
    if (!bytes || !options) goto cleanup;
    source = CGImageSourceCreateWithData(bytes, options);
    if (!source || CGImageSourceGetStatus(source) != kCGImageStatusComplete) goto cleanup;
    image = CGImageSourceCreateImageAtIndex(source, 0, options);
    if (!image || CGImageGetWidth(image) != width || CGImageGetHeight(image) != height ||
        CGImageSourceGetStatusAtIndex(source, 0) != kCGImageStatusComplete) goto cleanup;
    space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    if (!space) goto cleanup;
    // Allocate only after ImageIO accepted the complete source. No zero fill:
    // copy-mode drawing of the full integral rect replaces every pixel,
    // including fully transparent ones.
    rgba = ghostty_alloc(allocator, length);
    if (!rgba) goto cleanup;
    context = CGBitmapContextCreate(rgba, width, height, 8, (size_t)width * 4, space,
                                    kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (!context) goto cleanup;
    CGContextSetBlendMode(context, kCGBlendModeCopy);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
    // Kitty stores straight RGBA. ImageIO/CoreGraphics produces premultiplied
    // bytes; restore straight alpha before returning ownership to native VT.
    for (size_t i = 0; i < length; i += 4) {
        unsigned alpha = rgba[i + 3];
        for (size_t c = 0; c < 3; ++c) {
            unsigned channel = alpha ? (rgba[i + c] * 255U + alpha / 2) / alpha : 0;
            rgba[i + c] = channel > 255 ? 255 : channel;
        }
    }
    *out = (GhosttySysImage){.width = width, .height = height, .data = rgba, .data_len = length};
    success = true;
cleanup:
    if (context) CGContextRelease(context);
    if (space) CGColorSpaceRelease(space);
    if (image) CGImageRelease(image);
    if (source) CFRelease(source);
    if (options) CFRelease(options);
    if (bytes) CFRelease(bytes);
    if (!success && rgba) ghostty_free(allocator, rgba, length);
    return success;
}

static pthread_once_t decoder_once = PTHREAD_ONCE_INIT;
static GhosttyResult decoder_result = GHOSTTY_INVALID_VALUE;
static void install_decoder(void) {
    decoder_result = ghostty_sys_set(GHOSTTY_SYS_OPT_DECODE_PNG, (const void *)decode_png);
}
int vt_graphics_initialize(void) {
    // Process-global sys settings are never rewritten by concurrent terminals.
    if (pthread_once(&decoder_once, install_decoder)) return GHOSTTY_INVALID_VALUE;
    return decoder_result;
}

static GhosttyResult copy_image(GhosttyKittyGraphicsImage image, VTImage *out,
                                const uint64_t *cached, size_t cached_count) {
    GhosttyKittyImageFormat format;
    const uint8_t *bytes = NULL;
    size_t length = 0;
    const GhosttyKittyGraphicsImageData keys[] = {
        GHOSTTY_KITTY_IMAGE_DATA_GENERATION, GHOSTTY_KITTY_IMAGE_DATA_WIDTH,
        GHOSTTY_KITTY_IMAGE_DATA_HEIGHT, GHOSTTY_KITTY_IMAGE_DATA_FORMAT,
        GHOSTTY_KITTY_IMAGE_DATA_DATA_LEN, GHOSTTY_KITTY_IMAGE_DATA_DATA_PTR
    };
    void *values[] = {&out->generation, &out->width, &out->height, &format, &length, &bytes};
    GhosttyResult result = ghostty_kitty_graphics_image_get_multi(image, 6, keys, values, NULL);
    if (result != GHOSTTY_SUCCESS) return result;
    size_t channels;
    switch (format) {
        case GHOSTTY_KITTY_IMAGE_FORMAT_RGB: channels = 3; break;
        case GHOSTTY_KITTY_IMAGE_FORMAT_RGBA: channels = 4; break;
        case GHOSTTY_KITTY_IMAGE_FORMAT_GRAY_ALPHA: channels = 2; break;
        case GHOSTTY_KITTY_IMAGE_FORMAT_GRAY: channels = 1; break;
        default: return GHOSTTY_INVALID_VALUE;
    }
    if (!out->width || !out->height || out->width > max_dimension || out->height > max_dimension)
        return GHOSTTY_INVALID_VALUE;
    size_t pixels = (size_t)out->width * out->height;
    if (pixels > max_image_bytes / 4 || pixels * channels != length || !bytes) return GHOSTTY_INVALID_VALUE;
    out->byte_count = pixels * 4;
    for (size_t i = 0; i < cached_count; ++i) if (cached[i] == out->generation) return GHOSTTY_SUCCESS;
    out->rgba = malloc(out->byte_count);
    if (!out->rgba) return GHOSTTY_OUT_OF_MEMORY;
    for (size_t i = 0; i < pixels; ++i) {
        const uint8_t *src = bytes + i * channels;
        uint8_t *dst = out->rgba + i * 4;
        uint8_t alpha = channels == 2 ? src[1] : (channels == 4 ? src[3] : 255);
        for (size_t c = 0; c < 3; ++c) dst[c] = (src[channels < 3 ? 0 : c] * alpha + 127U) / 255;
        dst[3] = alpha;
    }
    return GHOSTTY_SUCCESS;
}

// The iterator resolves native placeholder/relative semantics while the actor
// holds exclusive terminal access. Only owned pixels and value geometry escape.
typedef struct {
    VTFrame *frame;
    GhosttyKittyGraphics graphics;
    const uint64_t *cached_images;
    size_t cached_image_count;
    size_t image_capacity;
    size_t placement_capacity;
} GraphicsCopyContext;

static GhosttyResult copy_placement(void *userdata, const GhosttyKittyGraphicsRenderPlacement *native) {
    GraphicsCopyContext *context = userdata;
    VTFrame *frame = context->frame;
    GhosttyKittyGraphicsImage image = ghostty_kitty_graphics_image(context->graphics, native->image_id);
    if (!image) return GHOSTTY_SUCCESS;
    uint64_t generation;
    GhosttyResult result = ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_GENERATION, &generation);
    if (result != GHOSTTY_SUCCESS) return result;
    size_t index = 0;
    for (; index < frame->image_count; ++index) if (frame->images[index].generation == generation) break;
    if (index == frame->image_count) {
        VTImage owned = {0};
        result = copy_image(image, &owned, context->cached_images, context->cached_image_count);
        if (result == GHOSTTY_NO_VALUE) return GHOSTTY_SUCCESS;
        if (result != GHOSTTY_SUCCESS) return result;
        if (index == context->image_capacity) {
            if (context->image_capacity > SIZE_MAX / 2 / sizeof(VTImage)) {
                free(owned.rgba); return GHOSTTY_OUT_OF_MEMORY;
            }
            size_t capacity = context->image_capacity ? context->image_capacity * 2 : 4;
            VTImage *images = realloc(frame->images, capacity * sizeof(*images));
            if (!images) { free(owned.rgba); return GHOSTTY_OUT_OF_MEMORY; }
            frame->images = images;
            context->image_capacity = capacity;
        }
        frame->images[index] = owned;
        ++frame->image_count;
    }
    if (frame->placement_count == context->placement_capacity) {
        if (context->placement_capacity > SIZE_MAX / 2 / sizeof(VTImagePlacement)) return GHOSTTY_OUT_OF_MEMORY;
        size_t capacity = context->placement_capacity ? context->placement_capacity * 2 : 16;
        VTImagePlacement *placements = realloc(frame->placements, capacity * sizeof(*placements));
        if (!placements) return GHOSTTY_OUT_OF_MEMORY;
        frame->placements = placements;
        context->placement_capacity = capacity;
    }
    frame->placements[frame->placement_count++] = (VTImagePlacement){
        .image_index = index,
        .image_id = native->image_id, .placement_id = native->placement_id,
        .is_unicode = native->is_unicode,
        .z = native->z, .column = native->column, .row = native->row,
        .offset_x = native->offset_x, .offset_y = native->offset_y,
        .pixel_width = native->pixel_width, .pixel_height = native->pixel_height,
        .source_x = native->source_x, .source_y = native->source_y,
        .source_width = native->source_width, .source_height = native->source_height,
    };
    return GHOSTTY_SUCCESS;
}

int vt_graphics_frame(VTHandle *handle, VTFrame *frame,
                      const uint64_t *cached_images, size_t cached_image_count) {
    GraphicsCopyContext context = {.frame = frame, .cached_images = cached_images,
                                   .cached_image_count = cached_image_count};
    GhosttyResult result = ghostty_terminal_get(handle->terminal, GHOSTTY_TERMINAL_DATA_KITTY_IMAGE_STORAGE_LIMIT,
                                               &frame->image_storage_limit);
    if (result != GHOSTTY_SUCCESS) return result;
    result = ghostty_terminal_get(handle->terminal, GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS, &context.graphics);
    if (result != GHOSTTY_SUCCESS) return result;
    // The caller frees any partial frame if allocation or native iteration fails.
    return ghostty_kitty_graphics_render_iterate(handle->terminal, copy_placement, &context,
                                                &frame->virtual_placement_count);
}
