import Foundation

/// Avoid the isolated-deinit back-deployment runtime on iOS 18. Callers must
/// capture owned resources, never the object whose deinitializer is running.
package nonisolated func cleanupOnMainActor(_ cleanup: @escaping @MainActor @Sendable () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated { cleanup() }
    } else {
        Task { @MainActor in cleanup() }
    }
}
