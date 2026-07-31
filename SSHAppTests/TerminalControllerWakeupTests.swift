import XCTest
@testable import GhosttyTerminal

final class TerminalControllerWakeupTests: XCTestCase {
    @MainActor
    func testWakeupTicksOnceAndNotifiesEveryRenderableSubscriber() {
        let controller = TerminalController()
        var events: [String] = []

        _ = controller.registerWakeupHandler(
            shouldProcess: { true },
            onWakeup: { events.append("first") }
        )
        _ = controller.registerWakeupHandler(
            shouldProcess: { false },
            onWakeup: { events.append("suspended") }
        )
        _ = controller.registerWakeupHandler(
            shouldProcess: { true },
            onWakeup: { events.append("second") }
        )

        controller.handleWakeup {
            events.append("tick")
        }

        XCTAssertEqual(events, ["tick", "first", "second"])
    }

    @MainActor
    func testUnregisterRemovesOnlyMatchingSubscriberAndIsIdempotent() {
        let controller = TerminalController()
        var firstCount = 0
        var secondCount = 0
        var tickCount = 0

        let firstToken = controller.registerWakeupHandler(
            shouldProcess: { true },
            onWakeup: { firstCount += 1 }
        )
        _ = controller.registerWakeupHandler(
            shouldProcess: { true },
            onWakeup: { secondCount += 1 }
        )

        controller.unregisterWakeupHandler(firstToken)
        controller.unregisterWakeupHandler(firstToken)
        controller.handleWakeup { tickCount += 1 }

        XCTAssertEqual(tickCount, 1)
        XCTAssertEqual(firstCount, 0)
        XCTAssertEqual(secondCount, 1)
    }

    @MainActor
    func testAllSuspendedSkipsTickWhileNoRegistrationsUsesFallbackTick() {
        let suspendedController = TerminalController()
        var suspendedTickCount = 0
        var suspendedCallbackCount = 0
        _ = suspendedController.registerWakeupHandler(
            shouldProcess: { false },
            onWakeup: { suspendedCallbackCount += 1 }
        )

        suspendedController.handleWakeup { suspendedTickCount += 1 }

        XCTAssertEqual(suspendedTickCount, 0)
        XCTAssertEqual(suspendedCallbackCount, 0)

        let emptyController = TerminalController()
        var fallbackTickCount = 0
        emptyController.handleWakeup { fallbackTickCount += 1 }
        XCTAssertEqual(fallbackTickCount, 1)
    }

    @MainActor
    func testUnregistrationDuringSharedTickSkipsRemovedCallback() {
        let controller = TerminalController()
        var callbacks: [String] = []

        _ = controller.registerWakeupHandler(
            shouldProcess: { true },
            onWakeup: { callbacks.append("first") }
        )
        let removedToken = controller.registerWakeupHandler(
            shouldProcess: { true },
            onWakeup: { callbacks.append("removed") }
        )

        controller.handleWakeup {
            controller.unregisterWakeupHandler(removedToken)
        }

        XCTAssertEqual(callbacks, ["first"])
    }

    @MainActor
    func testSelfUnregisterAndRegistrationDuringCallbackAreReentrantSafe() {
        let controller = TerminalController()
        var events: [String] = []
        var selfToken: TerminalController.WakeupHandlerToken?
        var registeredLateSubscriber = false

        selfToken = controller.registerWakeupHandler(
            shouldProcess: { true },
            onWakeup: {
                events.append("self")
                if let selfToken {
                    controller.unregisterWakeupHandler(selfToken)
                }
                guard !registeredLateSubscriber else { return }
                registeredLateSubscriber = true
                _ = controller.registerWakeupHandler(
                    shouldProcess: { true },
                    onWakeup: { events.append("late") }
                )
            }
        )
        _ = controller.registerWakeupHandler(
            shouldProcess: { true },
            onWakeup: { events.append("stable") }
        )

        controller.handleWakeup {}
        XCTAssertEqual(events, ["self", "stable"])

        events.removeAll()
        controller.handleWakeup {}
        XCTAssertEqual(events, ["stable", "late"])
    }

    @MainActor
    func testClearSurfaceDoesNotBlockCallerWhileReceiveOwnsSurfaceLock() {
        let validationEntered = DispatchSemaphore(value: 0)
        let releaseValidation = DispatchSemaphore(value: 0)
        let receiveFinished = expectation(description: "receive finished")
        let clearFinished = expectation(description: "clear finished")
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })

        DispatchQueue.global(qos: .userInitiated).async {
            _ = session.receiveIfSurfaceAttached(Data([0x41])) {
                validationEntered.signal()
                releaseValidation.wait()
                return false
            }
            receiveFinished.fulfill()
        }
        XCTAssertEqual(validationEntered.wait(timeout: .now() + 1), .success)

        // A watchdog prevents a regressed synchronous clear from deadlocking
        // the test runner while still making that regression measurably fail.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2) {
            releaseValidation.signal()
        }
        let start = Date()
        session.clearSurface(ifMatches: nil) {
            clearFinished.fulfill()
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(start),
            0.5,
            "surface teardown must not wait on an in-flight Ghostty write"
        )

        releaseValidation.signal()
        wait(for: [receiveFinished, clearFinished], timeout: 2)
    }

    func testSurfaceCoordinatorSynchronizesMetricsBeforeAttachAndOwnsExactWakeupToken() throws {
        let source = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Surface/TerminalSurfaceCoordinator.swift"
        )
        let rebuildStart = try XCTUnwrap(source.range(of: "func rebuildIfReady"))
        let retirementStart = try XCTUnwrap(source.range(of: "private func beginSurfaceRetirement"))
        let nextMethodStart = try XCTUnwrap(source.range(of: "private func handleCellSizeChange"))
        let rebuildBody = String(source[rebuildStart.lowerBound..<retirementStart.lowerBound])
        let retirementBody = String(source[retirementStart.lowerBound..<nextMethodStart.lowerBound])

        let metricsRange = try XCTUnwrap(rebuildBody.range(of: "synchronizeMetrics()"))
        let attachRange = try XCTUnwrap(rebuildBody.range(of: ".terminalDidAttachSurface"))
        XCTAssertLessThan(
            rebuildBody.distance(from: rebuildBody.startIndex, to: metricsRange.lowerBound),
            rebuildBody.distance(from: rebuildBody.startIndex, to: attachRange.lowerBound),
            "initial resize must reach delegates before raw surface attachment is announced"
        )
        XCTAssertTrue(rebuildBody.contains("registerWakeupHandler"))
        XCTAssertTrue(
            retirementBody.contains("if let token = wakeupHandlerToken")
                && retirementBody.contains("retiringController?.unregisterWakeupHandler(token)")
        )
        XCTAssertTrue(retirementBody.contains("retiringSession.clearSurface"))
        XCTAssertTrue(retirementBody.contains("completion: finishRetirement"))
        XCTAssertTrue(source.contains("private let controller: TerminalController?"))
        XCTAssertTrue(source.contains("private let platformOwner: AnyObject?"))
        XCTAssertTrue(retirementBody.contains("controller: retiringController"))
        XCTAssertTrue(retirementBody.contains("platformOwner: retiringPlatformOwner"))
        XCTAssertFalse(source.contains("controller?.onWakeup = nil"))
        XCTAssertFalse(source.contains("controller?.shouldProcessWakeup = nil"))
    }
}
