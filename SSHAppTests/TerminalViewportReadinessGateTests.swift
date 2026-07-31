import XCTest
@testable import SSHApp

final class TerminalViewportReadinessGateTests: XCTestCase {
    @MainActor
    private final class ManualScheduler {
        private var actions: [TerminalViewportReadinessGate.ScheduledAction] = []

        var pendingCount: Int {
            actions.count
        }

        func schedule(_ action: @escaping TerminalViewportReadinessGate.ScheduledAction) {
            actions.append(action)
        }

        @discardableResult
        func runNext() -> Bool {
            guard !actions.isEmpty else { return false }
            let action = actions.removeFirst()
            action()
            return true
        }

        func runAll(limit: Int = 20) {
            var remaining = limit
            while runNext() {
                remaining -= 1
                precondition(remaining > 0, "readiness gate did not quiesce")
            }
        }
    }

    @MainActor
    func testRawAttachDoesNotBecomeReadyUntilMeasuredGridSurvivesTwoTurns() {
        let scheduler = ManualScheduler()
        let gate = TerminalViewportReadinessGate(schedule: scheduler.schedule)
        var fitCount = 0
        var readyGenerations: [Int] = []

        let generation = gate.begin(
            fitViewport: { fitCount += 1 },
            onReady: { readyGenerations.append($0) }
        )

        XCTAssertEqual(scheduler.pendingCount, 1)
        XCTAssertTrue(scheduler.runNext())
        XCTAssertEqual(fitCount, 1)
        XCTAssertTrue(readyGenerations.isEmpty)
        XCTAssertEqual(scheduler.pendingCount, 0)

        gate.measurementDidChange()
        XCTAssertTrue(scheduler.runNext())
        XCTAssertEqual(fitCount, 2)
        XCTAssertTrue(readyGenerations.isEmpty)
        XCTAssertEqual(scheduler.pendingCount, 1)

        XCTAssertTrue(scheduler.runNext())
        XCTAssertEqual(fitCount, 3)
        XCTAssertEqual(readyGenerations, [generation])

        gate.measurementDidChange()
        XCTAssertEqual(scheduler.pendingCount, 0)
        XCTAssertEqual(readyGenerations, [generation])
    }

    @MainActor
    func testMeasurementChurnInvalidatesOlderSettleTurn() {
        let scheduler = ManualScheduler()
        let gate = TerminalViewportReadinessGate(schedule: scheduler.schedule)
        var fitCount = 0
        var readyCount = 0

        gate.measurementDidChange()
        gate.begin(
            fitViewport: { fitCount += 1 },
            onReady: { _ in readyCount += 1 }
        )

        XCTAssertTrue(scheduler.runNext())
        XCTAssertEqual(fitCount, 1)
        XCTAssertEqual(scheduler.pendingCount, 1)

        gate.measurementDidChange()
        XCTAssertEqual(scheduler.pendingCount, 2)

        XCTAssertTrue(scheduler.runNext(), "stale second turn should still leave the scheduler")
        XCTAssertEqual(fitCount, 1, "stale work must not fit or release output")
        XCTAssertEqual(readyCount, 0)

        scheduler.runAll()
        XCTAssertEqual(fitCount, 3)
        XCTAssertEqual(readyCount, 1)
    }

    @MainActor
    func testDetachInvalidatesScheduledReadiness() {
        let scheduler = ManualScheduler()
        let gate = TerminalViewportReadinessGate(schedule: scheduler.schedule)
        var fitCount = 0
        var readyCount = 0

        gate.measurementDidChange()
        gate.begin(
            fitViewport: { fitCount += 1 },
            onReady: { _ in readyCount += 1 }
        )
        gate.invalidate()
        scheduler.runAll()

        XCTAssertEqual(fitCount, 0)
        XCTAssertEqual(readyCount, 0)
    }

    @MainActor
    func testLogicalReplacementOnlyCompletesNewestGeneration() {
        let scheduler = ManualScheduler()
        let gate = TerminalViewportReadinessGate(schedule: scheduler.schedule)
        var firstReadyCount = 0
        var secondReadyGenerations: [Int] = []

        gate.measurementDidChange()
        let firstGeneration = gate.begin(
            fitViewport: {},
            onReady: { _ in firstReadyCount += 1 }
        )
        let secondGeneration = gate.begin(
            fitViewport: {},
            onReady: { secondReadyGenerations.append($0) }
        )
        scheduler.runAll()

        XCTAssertNotEqual(firstGeneration, secondGeneration)
        XCTAssertEqual(firstReadyCount, 0)
        XCTAssertEqual(secondReadyGenerations, [secondGeneration])
    }
}
