import Foundation

/// Shared retention policy for drained raster slots, not an allocation budget
/// for active frames or total process memory. The 64 MiB cap is provisional;
/// revisit it with device memory measurements.
@MainActor
final class VTMetalIdleCacheBudget {
    static let shared = VTMetalIdleCacheBudget(limitBytes: 64 * 1024 * 1024)

    struct Metrics: Codable, Equatable {
        let limitBytes: Int
        let retainedBytes: Int
        let slots: Int
        let evictions: Int
    }

    private struct Entry {
        weak var renderer: VTMetalRasterizer?
        let bytes: Int
    }
    private var entries: [Entry] = []
    private var evictions = 0
    var limitBytes: Int {
        didSet {
            precondition(limitBytes >= 0)
            enforceLimit()
        }
    }
    var metrics: Metrics {
        prune()
        return Metrics(limitBytes: limitBytes, retainedBytes: retainedBytes,
                       slots: entries.count, evictions: evictions)
    }
    private var retainedBytes: Int { entries.reduce(0) { $0 + $1.bytes } }

    init(limitBytes: Int) {
        precondition(limitBytes >= 0)
        self.limitBytes = limitBytes
    }

    /// Call after acquiring preparation admission, before starting its worker.
    /// Published gauges cease to be stable until GPU and presentation drain.
    func remove(_ renderer: VTMetalRasterizer) {
        entries.removeAll { $0.renderer == nil || $0.renderer === renderer }
    }

    /// Resource-drained slots include glyph-only preparation waiters even while
    /// they hold a scheduler lease, but never admitted or presentation-held work.
    /// Weak entries must not keep a detached pipeline or its resources alive.
    func retainDrained(_ renderer: VTMetalRasterizer) {
        remove(renderer)
        let bytes = renderer.retainedTextureBytes
        guard bytes > 0 else { return }
        entries.append(Entry(renderer: renderer, bytes: bytes))
        enforceLimit()
    }

    private func prune() { entries.removeAll { $0.renderer == nil } }

    private func enforceLimit() {
        prune()
        // Entries are ordered by last completed use. Only drained slots enter
        // this list; removal and eviction are synchronous on their owner's actor.
        while retainedBytes > limitBytes, !entries.isEmpty {
            let entry = entries.removeFirst()
            guard let renderer = entry.renderer else { continue }
            renderer.releaseResources()
            evictions += 1
        }
    }
}
