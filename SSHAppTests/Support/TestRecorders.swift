import Foundation

/// Accumulates bytes written from any thread, in arrival order.
final class ByteRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()

    func append(_ data: Data) { lock.withLock { bytes.append(data) } }
    var data: Data { lock.withLock { bytes } }
}

/// Suspends waiters until opened; once open, later waits return immediately.
actor OpenOnceGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if !opened { await withCheckedContinuation { waiters.append($0) } }
    }

    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
