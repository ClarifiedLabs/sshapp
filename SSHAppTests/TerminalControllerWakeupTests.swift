import UIKit
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

    @MainActor
    func testClearSurfaceWaitsForActiveWriteWhenPointerWasReplacedDuringRetirement() async throws {
        let writeEntered = DispatchSemaphore(value: 0)
        let releaseWrite = DispatchSemaphore(value: 0)
        let clearCompleted = NSLock()
        let clearFinished = expectation(description: "clear finished after active write drains")
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        let surfaceA = UnsafeMutableRawPointer(bitPattern: 0x1000)!
        let surfaceB = UnsafeMutableRawPointer(bitPattern: 0x2000)!
        let clearCompletedSemaphore = DispatchSemaphore(value: 0)
        session.setSurface(surfaceA)
        session.surfaceWrite = { _, _ in
            writeEntered.signal()
            releaseWrite.wait()
        }

        let receiveTask = Task.detached {
            session.receive(Data([0x41]))
        }
        XCTAssertEqual(writeEntered.wait(timeout: .now() + 1), .success)

        // Model the old reentrant mismatch: retirement of A swapped the
        // session's current pointer to B while A's write is still inside
        // Ghostty. The clear must not treat the mismatch as proof the write
        // has drained.
        session.setSurface(surfaceB)
        session.clearSurface(ifMatches: surfaceA) {
            clearCompletedSemaphore.signal()
            clearCompleted.withLock {
                clearFinished.fulfill()
            }
        }

        XCTAssertEqual(
            clearCompletedSemaphore.wait(timeout: .now() + 0.3),
            .timedOut,
            "clear must wait for the accepted write against surface A to drain"
        )

        releaseWrite.signal()
        await fulfillment(of: [clearFinished], timeout: 2)
        await receiveTask.value

        // A mismatch with no active call still completes immediately.
        let immediateClear = expectation(description: "mismatched clear with no active call completes")
        session.setSurface(surfaceB)
        session.clearSurface(ifMatches: surfaceA) {
            immediateClear.fulfill()
        }
        await fulfillment(of: [immediateClear], timeout: 1)
    }

    /// Regression: a reentrant lifecycle delegate that changes configuration
    /// from `terminalDidDetachSurface` must not build a replacement surface
    /// that races the in-flight clear. `beginSurfaceRetirement` publishes
    /// `activeRetirement` before invoking any external callback, so nested
    /// rebuilds queue behind the active retirement and the replacement only
    /// attaches once the retiring write has drained.
    @MainActor
    func testDetachReconfigurationDuringActiveWriteDefersReplacementSurface() async throws {
        let mounted = try mountTerminal()
        defer { unmountTerminal(mounted) }

        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        let writeEntered = DispatchSemaphore(value: 0)
        let releaseWrite = DispatchSemaphore(value: 0)
        session.surfaceWrite = { _, _ in
            writeEntered.signal()
            releaseWrite.wait()
        }

        let terminal = mounted.terminal
        let controller = TerminalController()
        let delegate = RecordingLifecycleDelegate()
        terminal.delegate = delegate
        terminal.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        terminal.controller = controller

        await waitUntil("initial surface attaches") { delegate.attachedSurfaces.count == 1 }
        XCTAssertEqual(delegate.attachedSurfaces.count, 1)
        XCTAssertEqual(delegate.detachCount, 0)

        var didReconfigure = false
        delegate.onDetach = {
            guard !didReconfigure else { return }
            didReconfigure = true
            // Reenter the coordinator from the detach callback; the
            // replacement rebuild must queue behind the active retirement.
            terminal.configuration = TerminalSurfaceOptions(backend: .inMemory(session), fontSize: 14)
        }

        let receiveTask = Task.detached {
            session.receive(Data([0x41]))
        }
        XCTAssertEqual(writeEntered.wait(timeout: .now() + 2), .success)

        // Retire the current surface via a configuration change while the
        // write is still inside Ghostty; the reentrant detach callback above
        // applies a further configuration change that must stay deferred.
        terminal.configuration = TerminalSurfaceOptions(backend: .inMemory(session), fontSize: 13)
        XCTAssertEqual(delegate.detachCount, 1)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(
            delegate.attachedSurfaces.count,
            1,
            "no replacement surface may attach while the retiring write is still inside Ghostty"
        )

        releaseWrite.signal()
        await waitUntil("replacement surface attaches after retirement drains") {
            delegate.attachedSurfaces.count == 2
        }
        await receiveTask.value

        XCTAssertEqual(delegate.attachedSurfaces.count, 2)
        XCTAssertEqual(delegate.detachCount, 1)
        XCTAssertTrue(
            delegate.attachedSurfaces[1] === terminal.surface,
            "the deferred rebuild must publish the view's current surface"
        )
    }

    /// Regression: metrics synchronization invokes external resize delegates
    /// that may synchronously retire the freshly built surface. The attach
    /// announcement is guarded so a retired surface is never announced
    /// attached; the deferred retirement rebuild publishes the replacement.
    @MainActor
    func testSurfaceRetiredDuringMetricsSyncIsNeverAnnouncedAttached() async throws {
        let mounted = try mountTerminal()
        defer { unmountTerminal(mounted) }

        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        let terminal = mounted.terminal
        let controller = TerminalController()
        let delegate = RecordingLifecycleDelegate()
        terminal.delegate = delegate
        terminal.configuration = TerminalSurfaceOptions(backend: .inMemory(session))

        var didReconfigure = false
        delegate.onResize = {
            guard !didReconfigure else { return }
            didReconfigure = true
            // Retire the freshly built surface from inside its own initial
            // metrics synchronization.
            terminal.configuration = TerminalSurfaceOptions(backend: .inMemory(session), fontSize: 14)
        }

        terminal.controller = controller

        await waitUntil("replacement surface attaches after metrics-sync retirement") {
            delegate.attachedSurfaces.count == 1
        }

        XCTAssertEqual(
            delegate.attachedSurfaces.count,
            1,
            "the surface retired during metrics synchronization must never be announced"
        )
        XCTAssertEqual(delegate.detachCount, 1)
        guard let announced = delegate.attachedSurfaces.first else {
            XCTFail("a replacement surface must eventually attach")
            return
        }
        XCTAssertTrue(
            announced === terminal.surface,
            "the only announced surface must be the view's current surface"
        )
    }

    // MARK: - Surface lifecycle helpers

    @MainActor
    private final class RecordingLifecycleDelegate: NSObject, TerminalSurfaceLifecycleDelegate, TerminalSurfaceGridResizeDelegate {
        var onDetach: (() -> Void)?
        var onResize: (() -> Void)?
        var attachedSurfaces: [TerminalSurface] = []
        var detachCount = 0

        func terminalDidAttachSurface(_ surface: TerminalSurface) {
            attachedSurfaces.append(surface)
        }

        func terminalDidDetachSurface() {
            detachCount += 1
            onDetach?()
        }

        func terminalDidResize(_ size: TerminalGridMetrics) {
            onResize?()
        }
    }

    @MainActor
    private struct MountedTerminal {
        let terminal: UITerminalView
        let window: UIWindow
        let previousKeyWindow: UIWindow?
    }

    @MainActor
    private func mountTerminal() throws -> MountedTerminal {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else {
            throw XCTSkip("The app-hosted unit test has no UIWindowScene")
        }

        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let rootViewController = UIViewController()
        let terminal = UITerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        rootViewController.view.frame = terminal.frame
        rootViewController.view.addSubview(terminal)
        window.rootViewController = rootViewController
        window.frame = scene.coordinateSpace.bounds
        window.makeKeyAndVisible()
        rootViewController.view.layoutIfNeeded()

        return MountedTerminal(
            terminal: terminal,
            window: window,
            previousKeyWindow: previousKeyWindow
        )
    }

    @MainActor
    private func unmountTerminal(_ mounted: MountedTerminal) {
        mounted.terminal.removeFromSuperview()
        mounted.window.isHidden = true
        mounted.previousKeyWindow?.makeKey()
    }

    @MainActor
    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("Timed out waiting for \(description)", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
