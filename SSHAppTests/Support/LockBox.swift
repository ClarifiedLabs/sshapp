import Foundation

/// Lock-guarded value shared with callbacks that may run on other threads.
/// Use `mutate` for read-modify-write; `get`/`set` are separate acquisitions.
final class LockBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(_ value: T) {
        self.value = value
    }

    func get() -> T {
        lock.withLock { value }
    }

    func set(_ value: T) {
        lock.withLock { self.value = value }
    }

    func mutate(_ body: (inout T) -> Void) {
        lock.withLock { body(&value) }
    }
}

final class WeakReference<Value: AnyObject> {
    weak var value: Value?

    init(_ value: Value?) {
        self.value = value
    }
}
