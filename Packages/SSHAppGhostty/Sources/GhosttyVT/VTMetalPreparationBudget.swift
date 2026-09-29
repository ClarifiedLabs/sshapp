import Foundation

/// Weighted admission for planned raster storage across panes. This is neither
/// a process-memory ceiling nor a substitute for native/snapshot image budgets.
/// A request larger than the allowance runs exclusively and is reported as such.
@MainActor
final class VTMetalPreparationBudget {
    static let shared = VTMetalPreparationBudget(limitBytes: 64 * 1024 * 1024)

    struct Permit {
        fileprivate let id: UUID
        /// Original admission metadata, not the mutable active reservation.
        let bytes: Int
    }
    struct Metrics: Codable, Equatable {
        let limitBytes: Int
        let reservedBytes: Int
        let activeLeases: Int
        let waitingLeases: Int
        let peakReservedBytes: Int
        let peakActiveLeases: Int
        let oversizedAdmissions: Int
    }
    private struct Waiter {
        let id: UUID
        let bytes: Int
        let continuation: CheckedContinuation<Permit, any Error>
    }
    let limitBytes: Int
    private var active: [UUID: Int] = [:]
    private var waiters: [Waiter] = []
    private var peakReservedBytes = 0
    private var peakActiveLeases = 0
    private var oversizedAdmissions = 0
    private var reservedBytes: Int { active.values.reduce(0, +) }
    var metrics: Metrics {
        Metrics(limitBytes: limitBytes, reservedBytes: reservedBytes,
                activeLeases: active.count, waitingLeases: waiters.count,
                peakReservedBytes: peakReservedBytes, peakActiveLeases: peakActiveLeases,
                oversizedAdmissions: oversizedAdmissions)
    }

    init(limitBytes: Int) {
        precondition(limitBytes > 0)
        self.limitBytes = limitBytes
    }

    /// Never bypass an older waiter, including one waiting for exclusive use.
    func tryAcquire(bytes: Int) -> Permit? {
        precondition(bytes > 0)
        guard waiters.isEmpty, canAdmit(bytes) else { return nil }
        return admit(id: UUID(), bytes: bytes)
    }

    /// There is at most one request per scheduler lease, not per output event.
    /// Waiting slots may retain separately idle-charged, evictable glyph state,
    /// never transient textures/scratch. Requests cover cold reconstruction too;
    /// terminal bytes and opaque CoreText overhead remain separate.
    func acquire(bytes: Int) async throws -> Permit {
        try Task.checkCancellation()
        if let permit = tryAcquire(bytes: bytes) { return permit }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, bytes: bytes, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id) }
        }
    }

    /// Return finished scratch capacity without ending the resource lease.
    /// Stale tokens and increases cannot restore an earlier charge. Originally
    /// oversized admissions stay exclusive until release, even after GPU drain.
    func reduce(_ permit: Permit, to bytes: Int) {
        guard let current = active[permit.id], permit.bytes <= limitBytes,
              bytes >= 0, bytes < current else { return }
        active[permit.id] = bytes
        drain()
    }

    func release(_ permit: Permit) {
        guard active.removeValue(forKey: permit.id) != nil else { return }
        drain()
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
        drain()
    }

    private func canAdmit(_ bytes: Int) -> Bool {
        if active.isEmpty { return true }
        // Oversized requests run alone. Smaller requests cannot bypass one
        // already admitted, and subtraction avoids overflowing a byte sum.
        let reserved = reservedBytes
        return bytes <= limitBytes && reserved <= limitBytes && bytes <= limitBytes - reserved
    }

    private func admit(id: UUID, bytes: Int) -> Permit {
        active[id] = bytes
        peakReservedBytes = max(peakReservedBytes, reservedBytes)
        peakActiveLeases = max(peakActiveLeases, active.count)
        if bytes > limitBytes { oversizedAdmissions += 1 }
        return Permit(id: id, bytes: bytes)
    }

    private func drain() {
        while let first = waiters.first, canAdmit(first.bytes) {
            waiters.removeFirst()
            first.continuation.resume(returning: admit(id: first.id, bytes: first.bytes))
        }
    }
}
