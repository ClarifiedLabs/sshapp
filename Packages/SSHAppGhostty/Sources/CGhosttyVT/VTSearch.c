#include "VTInternal.h"
#include <stdatomic.h>
#include <stdlib.h>

// A dense query must not grow a second unbounded history. This accounts for
// search-owned allocations, not the terminal's separately bounded page storage.
static _Atomic size_t search_bytes = 0;
static bool reserve(VTHandle *handle, size_t bytes) {
    size_t limit = 16 * 1024 * 1024;
#ifdef VT_TEST_HOOKS
    if (handle->search_test_limit) limit = handle->search_test_limit;
#endif
    if (handle->search_bytes > limit || bytes > limit - handle->search_bytes) goto limit;
    size_t current = atomic_load(&search_bytes);
    do {
        if (bytes > 64 * 1024 * 1024 - current) goto limit;
    } while (!atomic_compare_exchange_weak(&search_bytes, &current, current + bytes));
    handle->search_bytes += bytes;
    return true;
limit:
    handle->search_limit_reached = true;
    return false;
}
static void release(VTHandle *handle, size_t bytes) {
    handle->search_bytes -= bytes;
    atomic_fetch_sub(&search_bytes, bytes);
}
static void *search_alloc(void *ctx, size_t len, uint8_t alignment, uintptr_t caller) {
    (void)caller;
    if (!reserve(ctx, len)) return NULL;
    // This pinned implementation forwards Zig's log2 alignment enum. History
    // search copies whole aligned pages, so malloc's 16-byte guarantee is not enough.
    void *memory = NULL;
    if (alignment < sizeof(size_t) * 8) {
        size_t bytes = (size_t)1 << alignment;
        if (bytes < sizeof(void *)) bytes = sizeof(void *);
        if (posix_memalign(&memory, bytes, len) != 0) memory = NULL;
    }
    if (!memory) { release(ctx, len); ((VTHandle *)ctx)->search_limit_reached = true; }
    return memory;
}
static bool search_resize(void *ctx, void *memory, size_t old, uint8_t alignment, size_t next, uintptr_t caller) {
    (void)ctx; (void)memory; (void)alignment; (void)caller;
    return next == old; // remap handles growth/shrink and exact accounting.
}
static void *search_remap(void *ctx, void *memory, size_t old, uint8_t alignment, size_t next, uintptr_t caller) {
    (void)ctx; (void)memory; (void)old; (void)alignment; (void)next; (void)caller;
    // Let Zig perform aligned alloc/copy/free; never lose page alignment in realloc.
    return NULL;
}
static void search_free(void *ctx, void *memory, size_t len, uint8_t alignment, uintptr_t caller) {
    (void)alignment; (void)caller;
    free(memory);
    release(ctx, len);
}
static const GhosttyAllocatorVtable allocator_vtable = {
    .alloc = search_alloc, .resize = search_resize, .remap = search_remap, .free = search_free
};

void vt_search_destroy(VTHandle *handle) {
    ghostty_search_free(handle->search);
    handle->search = NULL;
    handle->search_limit_reached = false;
}

int vt_search_end(VTHandle *handle) {
    if (!handle) return GHOSTTY_INVALID_VALUE;
    vt_search_destroy(handle);
    return vt_select(handle, 0, 0, 0);
}

#ifdef VT_TEST_HOOKS
void vt_test_search_limit(VTHandle *handle, size_t bytes) { handle->search_test_limit = bytes; }
#endif

int vt_search_set_query(VTHandle *handle, const uint8_t *bytes, size_t count) {
    if (!handle || handle->failed || count > 4096 || (count && !bytes)) return GHOSTTY_INVALID_VALUE;
    if (!handle->search) {
        handle->search_allocator = (GhosttyAllocator){.ctx = handle, .vtable = &allocator_vtable};
        GhosttyResult result = ghostty_search_new(&handle->search_allocator, &handle->search, handle->terminal);
        if (result != GHOSTTY_SUCCESS) { vt_search_destroy(handle); return result; }
    }
    GhosttyString needle = {.ptr = bytes, .len = count};
    GhosttyResult result = ghostty_search_set(handle->search, GHOSTTY_SEARCH_OPT_NEEDLE, &needle);
    if (handle->search_limit_reached) result = GHOSTTY_LIMIT_EXCEEDED;
    if (result != GHOSTTY_SUCCESS) { vt_search_end(handle); return result; }
    return vt_select(handle, 0, 0, 0);
}

int vt_search_step(VTHandle *handle, int direction, VTSearchState *out) {
    if (!handle || handle->failed || !handle->search || !out || direction < -1 || direction > 1)
        return GHOSTTY_INVALID_VALUE;
    *out = (VTSearchState){0};
    GhosttyResult result;
#define CHECK(call) do { result = (call); if (result != GHOSTTY_SUCCESS) goto failure; } while (0)
    GhosttyTerminalScrollbar before, after;
    CHECK(ghostty_terminal_get(handle->terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &before));
    // Never run-to-completion: yield the actor/FIFO between bounded native steps.
    CHECK(ghostty_search_feed(handle->search));
    GhosttySearchStatus status;
    CHECK(ghostty_search_tick(handle->search, &status));
    size_t selected = 0;
    result = ghostty_search_get(handle->search, GHOSTTY_SEARCH_DATA_SELECTED_INDEX, &selected);
    if (result != GHOSTTY_SUCCESS && result != GHOSTTY_NO_VALUE) goto failure;
    if (direction != 0 || result == GHOSTTY_NO_VALUE) {
        result = ghostty_search_set(handle->search, direction < 0 ? GHOSTTY_SEARCH_OPT_SELECT_PREV
            : GHOSTTY_SEARCH_OPT_SELECT_NEXT, NULL);
        if (result != GHOSTTY_SUCCESS && result != GHOSTTY_NO_VALUE) goto failure;
    }
    if (handle->search_limit_reached) { result = GHOSTTY_LIMIT_EXCEEDED; goto failure; }
    CHECK(ghostty_search_get(handle->search, GHOSTTY_SEARCH_DATA_STATUS, &status));
    out->complete = status == GHOSTTY_SEARCH_STATUS_COMPLETE;
    CHECK(ghostty_search_get(handle->search, GHOSTTY_SEARCH_DATA_TOTAL_MATCHES, &out->total_matches));
    result = ghostty_search_get(handle->search, GHOSTTY_SEARCH_DATA_SELECTED_INDEX, &out->selected_index);
    if (result != GHOSTTY_SUCCESS && result != GHOSTTY_NO_VALUE) goto failure;
    out->has_selected = result == GHOSTTY_SUCCESS;
    GhosttySelection match = GHOSTTY_INIT_SIZED(GhosttySelection);
    GhosttySelection current = GHOSTTY_INIT_SIZED(GhosttySelection);
    result = ghostty_terminal_get(handle->terminal, GHOSTTY_TERMINAL_DATA_SELECTION, &current);
    if (result != GHOSTTY_SUCCESS && result != GHOSTTY_NO_VALUE) goto failure;
    bool has_current = result == GHOSTTY_SUCCESS, equal = false;
    if (out->has_selected) {
        CHECK(ghostty_search_get(handle->search, GHOSTTY_SEARCH_DATA_SELECTED_MATCH, &match));
        if (has_current) CHECK(ghostty_terminal_selection_equal(handle->terminal, &current, &match, &equal));
        if (!equal) CHECK(ghostty_terminal_set(handle->terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &match));
        out->presentation_changed = !equal;
    } else if (has_current) {
        CHECK(ghostty_terminal_set(handle->terminal, GHOSTTY_TERMINAL_OPT_SELECTION, NULL));
        out->presentation_changed = true;
    }
    CHECK(ghostty_terminal_get(handle->terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &after));
    out->presentation_changed |= before.offset != after.offset;
    return GHOSTTY_SUCCESS;
failure:
    // Native search may recover internally from OOM; never report its partial
    // results as a complete successful search. The terminal itself stays usable.
    if (handle->search_limit_reached) result = GHOSTTY_LIMIT_EXCEEDED;
    vt_search_end(handle);
    return result;
#undef CHECK
}
