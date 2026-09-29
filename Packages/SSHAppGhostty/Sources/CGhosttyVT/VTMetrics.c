#include "VTBridge.h"
#include <mach/mach.h>
#include <malloc/malloc.h>

uint64_t vt_process_footprint(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return 0;
    return info.phys_footprint;
}

VTMemoryMetrics vt_memory_metrics(void) {
    task_vm_info_data_t info = {0};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    VTMemoryMetrics result = {0};
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS
        || count < TASK_VM_INFO_REV3_COUNT) return result;
    malloc_statistics_t heap = {0};
    malloc_zone_statistics(NULL, &heap);
    result.valid = true;
    result.footprint = info.phys_footprint;
    result.resident = info.resident_size;
    result.internal = info.internal;
    result.compressed = info.compressed;
    result.reusable = info.reusable;
    result.device = info.device;
    result.footprint_peak = info.ledger_phys_footprint_peak;
    result.graphics_footprint = info.ledger_tag_graphics_footprint;
    result.graphics_compressed = info.ledger_tag_graphics_footprint_compressed;
    result.purgeable_nonvolatile = info.ledger_purgeable_nonvolatile;
    result.malloc_in_use = heap.size_in_use;
    result.malloc_reserved = heap.size_allocated;
    return result;
}

uint64_t vt_allocator_pressure_relief(void) {
    return malloc_zone_pressure_relief(NULL, 0);
}
