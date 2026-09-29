import XCTest
@testable import GhosttyVT

/// Holds publication after GPU completion so tests can inspect leases that
/// are still in flight, then release them one at a time or all at once.
@MainActor
final class PresentationGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    private(set) var entries = 0
    var waiting: Int { continuations.count }

    func wait() async {
        entries += 1
        if isOpen { return }
        return await withCheckedContinuation { continuations.append($0) }
    }

    func releaseNext() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }

    func open() {
        isOpen = true
        while !continuations.isEmpty { releaseNext() }
    }
}

@MainActor
func assertDrained(_ budget: VTMetalPreparationBudget,
                   file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(budget.metrics.activeLeases, 0, file: file, line: line)
    XCTAssertEqual(budget.metrics.waitingLeases, 0, file: file, line: line)
    XCTAssertEqual(budget.metrics.reservedBytes, 0, file: file, line: line)
}

/// Routes terminal lifecycle observers to a private center for one test, so
/// synthetic resign/activate/memory events never reach the rest of the process.
/// Install before creating views; restore in tearDown.
@MainActor
final class PrivateLifecycleNotifications {
    let center = NotificationCenter()
    private let previous: NotificationCenter

    init() {
        previous = VTLifecycleNotifications.center
        VTLifecycleNotifications.center = center
    }

    func restore() { VTLifecycleNotifications.center = previous }

    func post(_ name: Notification.Name, object: Any? = nil) { center.post(name: name, object: object) }
}
