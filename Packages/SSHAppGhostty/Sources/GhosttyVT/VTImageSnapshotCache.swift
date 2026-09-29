import Foundation
import os

/// Shared retention for immutable adapter copies, independent of native image
/// storage and frames already leased to views/GPU work. No terminal handle or
/// actor is accessed under this lock, and pixel conversion stays outside it.
public final class VTImageSnapshotCache: Sendable {
    public static let shared = VTImageSnapshotCache(limitBytes: 64 * 1024 * 1024, limitImages: 1024)

    struct Metrics: Codable, Equatable, Sendable {
        let limitBytes: Int
        let limitImages: Int
        let retainedBytes: Int
        let retainedImages: Int
        let registeredOwners: Int
        let trackedImages: Int
        /// Live weak registrations only, not a global image census. Removing an
        /// owner removes its evidence even when an external frame still lives.
        /// Includes retained bytes; overlaps frame diagnostics and is not additive.
        let liveTrackedImageBytes: Int
        /// Live registrations whose cache retention is nil, not all external owners.
        let externalOnlyImageBytes: Int
        let externalOnlyImages: Int
        let evictions: Int
    }

    /// Owns only a registration, never its terminal. Destruction removes the
    /// cache even if the caller drops a terminal without explicitly retiring it.
    final class Owner: Sendable {
        private let cache: VTImageSnapshotCache
        private let id = UUID()

        fileprivate init(cache: VTImageSnapshotCache) {
            self.cache = cache
            cache.state.withLock { $0.owners[id] = [:] }
        }
        deinit { remove() }

        var retainedBytes: Int {
            cache.state.withLock { state in
                state.owners[id]?.values.reduce(0) { $0 + ($1.retained?.rgba.count ?? 0) } ?? 0
            }
        }

        /// This owned checkout protects every advertised generation through the
        /// synchronous native copy, even if another terminal evicts its cache.
        func checkout() -> [UInt64: VTImageValue] {
            cache.state.withLock { state in
                state.prune()
                return state.owners[id]?.compactMapValues(\.image) ?? [:]
            }
        }

        func retainViewport(_ images: [UInt64: VTImageValue]) {
            cache.state.withLock { state in
                guard var entries = state.owners[id] else { return }
                // Old frames may still own prior generations. Keep only weak
                // reuse records for them, not an additional strong cache lease.
                for generation in entries.keys { entries[generation]?.retained = nil }
                for (generation, image) in images.sorted(by: { $0.key < $1.key }) {
                    state.clock &+= 1
                    entries[generation] = Entry(image: image,
                        retained: image.rgba.count <= state.limitBytes ? image : nil, lastUse: state.clock)
                }
                state.owners[id] = entries
                state.enforceLimit()
            }
        }

        func releaseRetained() {
            cache.state.withLock { state in
                guard let entries = state.owners[id] else { return }
                for generation in entries.keys { state.owners[id]?[generation]?.retained = nil }
                state.prune()
            }
        }

        func remove() { _ = cache.state.withLock { $0.owners.removeValue(forKey: id) } }
    }

    private struct Entry: Sendable {
        weak var image: VTImageValue?
        var retained: VTImageValue?
        let lastUse: UInt64
    }
    private struct State: Sendable {
        var limitBytes: Int
        var limitImages: Int
        var owners: [UUID: [UInt64: Entry]] = [:]
        var clock: UInt64 = 0
        var evictions = 0

        mutating func prune() {
            for owner in owners.keys { owners[owner] = owners[owner]?.filter { $0.value.image != nil } }
        }

        mutating func enforceLimit() {
            var candidates: [(owner: UUID, generation: UInt64, bytes: Int, lastUse: UInt64)] = []
            for (owner, entries) in owners {
                for (generation, entry) in entries {
                    if let image = entry.retained {
                        candidates.append((owner, generation, image.rgba.count, entry.lastUse))
                    }
                }
            }
            var bytes = candidates.reduce(0) { $0 + $1.bytes }, count = candidates.count
            for entry in candidates.sorted(by: { $0.lastUse < $1.lastUse }) {
                guard bytes > limitBytes || count > limitImages else { break }
                owners[entry.owner]?[entry.generation]?.retained = nil
                bytes -= entry.bytes
                count -= 1
                evictions += 1
            }
            prune()
        }

        var metrics: Metrics {
            var bytes = 0, images = 0, tracked = 0
            var liveBytes = 0, externalBytes = 0, externalImages = 0
            for entries in owners.values {
                for entry in entries.values {
                    // One weak promotion per entry, held only for this scalar read.
                    guard let image = entry.image else { continue }
                    let imageBytes = image.rgba.count
                    tracked += 1
                    liveBytes += imageBytes
                    if entry.retained != nil {
                        bytes += imageBytes
                        images += 1
                    } else {
                        externalBytes += imageBytes
                        externalImages += 1
                    }
                }
            }
            return Metrics(limitBytes: limitBytes, limitImages: limitImages, retainedBytes: bytes,
                           retainedImages: images, registeredOwners: owners.count,
                           trackedImages: tracked, liveTrackedImageBytes: liveBytes,
                           externalOnlyImageBytes: externalBytes, externalOnlyImages: externalImages,
                           evictions: evictions)
        }
    }

    private let state: OSAllocatedUnfairLock<State>

    init(limitBytes: Int, limitImages: Int = 1024) {
        precondition(limitBytes >= 0 && limitImages >= 0)
        state = OSAllocatedUnfairLock(initialState: State(limitBytes: limitBytes, limitImages: limitImages))
    }

    func makeOwner() -> Owner { Owner(cache: self) }

    func setLimits(bytes: Int, images: Int) {
        precondition(bytes >= 0 && images >= 0)
        state.withLock { state in
            state.limitBytes = bytes
            state.limitImages = images
            state.enforceLimit()
        }
    }

    var metrics: Metrics { state.withLock { $0.metrics } }
}
