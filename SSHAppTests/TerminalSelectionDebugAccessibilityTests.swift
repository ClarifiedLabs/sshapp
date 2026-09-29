#if DEBUG && canImport(UIKit) && !targetEnvironment(macCatalyst)
import UIKit
import XCTest
import GhosttyVT
@testable import GhosttyTerminal

@MainActor
final class TerminalSelectionDebugAccessibilityTests: XCTestCase {
    /// Synthetic app lifecycle events go to a private center, not the process.
    private var lifecycle: PrivateLifecycleNotifications!
    private weak var previousKeyWindow: UIWindow?

    override func setUp() async throws {
        try await super.setUp()
        lifecycle = PrivateLifecycleNotifications()
    }

    override func tearDown() async throws {
        lifecycle.restore()
        previousKeyWindow?.makeKey()
        previousKeyWindow = nil
        try await super.tearDown()
    }

    func testDebugProbeIsStrictlyOptInAndDefaultViewExposesNoSnapshotText() {
        let terminal = makeTerminal()

        XCTAssertNil(terminal.selectionDebugConfiguration)
        XCTAssertNil(terminal.selectionDebugProbe)
        XCTAssertFalse(terminal.subviews.contains { $0 is TerminalSelectionDebugProbe })
        XCTAssertNil(terminal.accessibilityValue)
        XCTAssertFalse(terminal.isAccessibilityElement)
    }

    func testDebugTimingOverrideSeparatesAutomationTapFromIntentionalLongPress() {
        let terminal = makeTerminal()
        let productionDuration = UITerminalView.defaultTouchSelectionLongPressMinimumDuration
        XCTAssertEqual(
            terminal.touchSelectionLongPressGesture?.minimumPressDuration,
            productionDuration
        )

        terminal.selectionDebugConfiguration = .init(
            accessibilityIdentifierPrefix: "selection-timing",
            touchSelectionLongPressMinimumDuration: 1.0
        )
        XCTAssertEqual(terminal.touchSelectionLongPressGesture?.minimumPressDuration, 1.0)

        terminal.selectionDebugConfiguration = nil
        XCTAssertEqual(
            terminal.touchSelectionLongPressGesture?.minimumPressDuration,
            productionDuration
        )
    }

    func testOptInCreatesViewportProbeAndIndependentAccessibleHandles() throws {
        let terminal = makeTerminal()
        terminal.selectionDebugConfiguration = .init(
            accessibilityIdentifierPrefix: "selection-test"
        )

        let probe = try XCTUnwrap(terminal.selectionDebugProbe)
        let startHandle = try XCTUnwrap(terminal.selectionStartHandle)
        let endHandle = try XCTUnwrap(terminal.selectionEndHandle)
        XCTAssertTrue(probe.superview === terminal)
        XCTAssertEqual(probe.frame, terminal.terminalViewportBounds)
        XCTAssertEqual(probe.accessibilityIdentifier, "selection-test.state")
        XCTAssertEqual(startHandle.accessibilityIdentifier, "selection-test.startHandle")
        XCTAssertEqual(endHandle.accessibilityIdentifier, "selection-test.endHandle")
        XCTAssertEqual(startHandle.accessibilityLabel, "Selection start")
        XCTAssertEqual(endHandle.accessibilityLabel, "Selection end")
        XCTAssertEqual(startHandle.accessibilityHint, "Drag to adjust")
        XCTAssertTrue(startHandle.accessibilityTraits.contains(.adjustable))
        XCTAssertTrue(endHandle.accessibilityTraits.contains(.adjustable))
        XCTAssertEqual(startHandle.bounds.size, CGSize(width: 48, height: 48))
        XCTAssertEqual(endHandle.bounds.size, CGSize(width: 48, height: 48))

        XCTAssertFalse(terminal.isAccessibilityElement)
        XCTAssertFalse(terminal.accessibilityElementsHidden)
        XCTAssertTrue(probe.isAccessibilityElement)
        XCTAssertNil(startHandle.superview, "Hidden handles are detached from the accessibility hierarchy")
        XCTAssertNil(endHandle.superview)
        XCTAssertFalse(startHandle.isAccessibilityElement)
        XCTAssertFalse(endHandle.isAccessibilityElement)

        terminal.addSubview(startHandle)
        terminal.addSubview(endHandle)
        startHandle.setVisible(true)
        endHandle.setVisible(true)
        XCTAssertTrue(startHandle.isAccessibilityElement)
        XCTAssertTrue(endHandle.isAccessibilityElement)
        XCTAssertTrue(startHandle.superview === terminal)
        XCTAssertTrue(endHandle.superview === terminal)
        XCTAssertFalse(probe.isUserInteractionEnabled)
        XCTAssertFalse(probe.point(inside: probe.bounds.center, with: nil))
    }

    func testCanonicalSnapshotJSONContainsSchemaGeometryStateAndExplicitNulls() throws {
        let terminal = makeTerminal()
        terminal.selectionDebugConfiguration = .init(
            accessibilityIdentifierPrefix: "selection-json"
        )
        terminal.touchSelectionAnchorPoint = CGPoint(x: 25, y: 36)
        terminal.touchSelectionActiveEndPoint = CGPoint(x: 145, y: 72)
        terminal.selectionHandlesVisible = true
        terminal.selectionStartHandle?.frame = CGRect(x: 1, y: 12, width: 48, height: 48)
        terminal.selectionEndHandle?.frame = CGRect(x: 121, y: 48, width: 48, height: 48)
        terminal.selectionStartHandle?.setVisible(true)
        terminal.selectionEndHandle?.setVisible(true)
        terminal.selectionGestureActive = true
        terminal.selectionHandleMode = .adjustingEnd
        terminal.refreshSelectionDebugSnapshot()

        let probe = try XCTUnwrap(terminal.selectionDebugProbe)
        let json = try XCTUnwrap(probe.canonicalJSONValue)
        XCTAssertEqual(probe.accessibilityValue, json)
        let data = try XCTUnwrap(json.data(using: .utf8))
        let snapshot = try JSONDecoder().decode(
            TerminalSelectionDebugSnapshot.self,
            from: data
        )
        XCTAssertEqual(snapshot.schemaVersion, TerminalSelectionDebugSnapshot.currentSchemaVersion)
        XCTAssertEqual(
            snapshot.terminalBounds,
            .init(CGRect(x: 0, y: 0, width: 320, height: 480))
        )
        XCTAssertEqual(
            snapshot.terminalViewportBounds,
            .init(CGRect(x: 0, y: 0, width: 320, height: 480))
        )
        XCTAssertEqual(snapshot.displayStartEndpoint, .init(CGPoint(x: 25, y: 36)))
        XCTAssertEqual(snapshot.displayEndEndpoint, .init(CGPoint(x: 145, y: 72)))
        XCTAssertNil(snapshot.nativeStartCellCenter)
        XCTAssertNil(snapshot.nativeEndCellCenter)
        XCTAssertEqual(
            snapshot.startHandleFrame,
            .init(CGRect(x: 1, y: 12, width: 48, height: 48))
        )
        XCTAssertEqual(
            snapshot.endHandleFrame,
            .init(CGRect(x: 121, y: 48, width: 48, height: 48))
        )
        XCTAssertTrue(snapshot.touchHandlesVisible)
        XCTAssertTrue(snapshot.selectionGestureActive)
        XCTAssertEqual(snapshot.handleMode, .adjustingEnd)
        XCTAssertFalse(snapshot.surfaceReady)
        XCTAssertFalse(snapshot.gridReady)
        XCTAssertNil(snapshot.selectedText)
        XCTAssertNil(snapshot.nativeSelectionExists)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["schemaVersion"] as? Int, 2)
        XCTAssertTrue(object["nativeStartCellCenter"] is NSNull)
        XCTAssertTrue(object["nativeEndCellCenter"] is NSNull)
        XCTAssertEqual(object["selectionGestureActive"] as? Bool, true)
        XCTAssertNil(object["syntheticLeftButtonDown"])
        XCTAssertNil(object["mouseStartEndpoint"])
        XCTAssertTrue(object["selectedText"] is NSNull)
        XCTAssertTrue(object["nativeSelectionExists"] is NSNull)
        XCTAssertTrue(object["gridColumns"] is NSNull)
    }

    func testRevisionAndCallbackAdvanceOnlyForSemanticChanges() throws {
        let terminal = makeTerminal()
        let recorder = SelectionSnapshotRecorder()
        terminal.selectionDebugConfiguration = .init(
            accessibilityIdentifierPrefix: "selection-revision",
            snapshotCallback: { recorder.append($0) }
        )
        let initial = try XCTUnwrap(recorder.snapshots.last)
        let initialCount = recorder.snapshots.count

        terminal.refreshSelectionDebugSnapshot()
        terminal.refreshSelectionDebugSnapshot()
        XCTAssertEqual(recorder.snapshots.count, initialCount)
        XCTAssertEqual(terminal.selectionDebugProbe?.snapshot?.revision, initial.revision)

        terminal.selectionGestureActive = true
        let held = try XCTUnwrap(recorder.snapshots.last)
        XCTAssertEqual(held.revision, initial.revision + 1)
        XCTAssertTrue(held.selectionGestureActive)

        terminal.selectionGestureActive = true
        terminal.refreshSelectionDebugSnapshot()
        XCTAssertEqual(recorder.snapshots.count, initialCount + 1)

        terminal.selectionGestureActive = false
        let released = try XCTUnwrap(recorder.snapshots.last)
        XCTAssertEqual(released.revision, held.revision + 1)
        XCTAssertFalse(released.selectionGestureActive)
        XCTAssertEqual(recorder.snapshots.count, initialCount + 2)
    }

    func testRemovingConfigurationDiscardsProbeIdentifiersCallbackAndRetention() throws {
        let terminal = makeTerminal()
        let recorder = SelectionSnapshotRecorder()
        var callbackOwner: CallbackOwner? = CallbackOwner()
        weak let weakCallbackOwner = callbackOwner
        terminal.selectionDebugConfiguration = makeConfiguration(
            prefix: "selection-removal",
            callbackOwner: try XCTUnwrap(callbackOwner),
            recorder: recorder
        )
        callbackOwner = nil

        let probe = try XCTUnwrap(terminal.selectionDebugProbe)
        let callbackCount = recorder.snapshots.count
        XCTAssertNotNil(weakCallbackOwner)
        XCTAssertNotNil(probe.canonicalJSONValue)

        terminal.selectionDebugConfiguration = nil

        XCTAssertNil(weakCallbackOwner)
        XCTAssertNil(terminal.selectionDebugProbe)
        XCTAssertNil(probe.superview)
        XCTAssertNil(probe.snapshot)
        XCTAssertNil(probe.canonicalJSONValue)
        XCTAssertNil(probe.accessibilityValue)
        XCTAssertNil(probe.accessibilityIdentifier)
        XCTAssertNil(terminal.selectionStartHandle?.accessibilityIdentifier)
        XCTAssertNil(terminal.selectionEndHandle?.accessibilityIdentifier)

        terminal.selectionGestureActive = true
        terminal.refreshSelectionDebugSnapshot()
        XCTAssertEqual(recorder.snapshots.count, callbackCount)
    }

    func testNativeGesturesPublishCompleteBeginReleaseCancellationAndBackgroundStates() async throws {
        let terminal = makeTerminal()
        let window = try await mountSelectionWindow(terminal)
        let session = VTTerminalSession(write: { _ in }, resize: { _ in })
        terminal.configuration = .init(backend: .vt(session))
        terminal.controller = TerminalController()
        terminal.layoutIfNeeded()
        lifecycle.post(UIApplication.didBecomeActiveNotification, object: nil)
        defer {
            terminal.controller = nil
            window.isHidden = true
            session.finish()
        }
        let recorder = SelectionSnapshotRecorder()
        terminal.selectionDebugConfiguration = .init(
            accessibilityIdentifierPrefix: "selection-native-transitions",
            snapshotCallback: { recorder.append($0) }
        )
        try await waitUntil { terminal.surface?.frameValue != nil }
        session.deliver(Data("alpha bravo charlie".utf8), ifCurrent: { true }, completion: { _ in })
        try await waitUntil { terminal.surface?.frameValue?.line(0).hasPrefix("alpha bravo") == true }
        let frame = try XCTUnwrap(terminal.surface?.frameValue)
        let rect = frame.layout.rect(column: 8, row: 0)
        let point = CGPoint(x: rect.midX, y: rect.midY)

        terminal.nativeInteraction.wordSelection(state: .began, at: point, modifiers: [])
        XCTAssertTrue(terminal.selectionGestureActive, "Admission must publish synchronously")
        XCTAssertTrue(try XCTUnwrap(recorder.snapshots.last).selectionGestureActive)
        try await waitUntil {
            terminal.selectionDebugProbe?.snapshot?.selectedText == "bravo"
                && terminal.selectionDebugProbe?.snapshot?.loupeVisible == true
        }
        let selectedFrame = try XCTUnwrap(terminal.surface?.frameValue)
        let selection = try XCTUnwrap(selectedFrame.selection)
        let startRect = selectedFrame.layout.rect(column: selection.startEndpoint.position.column,
                                                  row: selection.startEndpoint.position.row)
        let endRect = selectedFrame.layout.rect(column: selection.endEndpoint.position.column,
                                                row: selection.endEndpoint.position.row)
        let held = try XCTUnwrap(recorder.snapshots.last)
        XCTAssertEqual(held.nativeStartCellCenter, .init(CGPoint(x: startRect.midX, y: startRect.midY)))
        XCTAssertEqual(held.nativeEndCellCenter, .init(CGPoint(x: endRect.midX, y: endRect.midY)))
        XCTAssertTrue(held.loupeVisible)
        terminal.nativeInteraction.wordSelection(state: .ended, at: point, modifiers: [])
        XCTAssertFalse(terminal.selectionGestureActive, "Do not wait for the native release response")
        XCTAssertFalse(try XCTUnwrap(recorder.snapshots.last).loupeVisible)
        try await waitUntil { !terminal.nativeInteraction.wordDragging }

        let handlePoint = try XCTUnwrap(terminal.selectionEndHandle).center
        let beforeHandle = recorder.snapshots.count
        terminal.nativeInteraction.beginSelectionDrag(start: false, at: handlePoint)
        let dragging = try XCTUnwrap(recorder.snapshots.last)
        XCTAssertTrue(dragging.selectionGestureActive)
        XCTAssertEqual(dragging.handleMode, .adjustingEnd)
        XCTAssertTrue(dragging.loupeVisible)
        XCTAssertNil(dragging.activePointerButton, "Native handles do not synthesize mouse input")
        XCTAssertTrue(recorder.snapshots.dropFirst(beforeHandle).allSatisfy {
            $0.selectionGestureActive && $0.handleMode == .adjustingEnd && $0.loupeVisible
        }, "Observers must not see a partially installed handle gesture")
        terminal.nativeInteraction.endSelectionDrag(at: handlePoint)
        let released = try XCTUnwrap(recorder.snapshots.last)
        XCTAssertFalse(released.selectionGestureActive)
        XCTAssertFalse(released.loupeVisible)
        XCTAssertEqual(released.handleMode, .none)
        XCTAssertEqual(released.nativeStartCellCenter, dragging.nativeStartCellCenter)
        XCTAssertEqual(released.nativeEndCellCenter, dragging.nativeEndCellCenter)

        terminal.nativeInteraction.beginSelectionDrag(start: false, at: handlePoint)
        let movedPoint = CGPoint(x: handlePoint.x + frame.layout.cellWidth, y: handlePoint.y)
        terminal.nativeInteraction.moveSelectionDrag(to: movedPoint)
        terminal.nativeInteraction.endSelectionDrag(at: movedPoint)
        XCTAssertFalse(terminal.selectionGestureActive, "A queued native move must not extend UIKit lifetime")
        XCTAssertFalse(try XCTUnwrap(recorder.snapshots.last).loupeVisible)
        try await waitUntil { terminal.selectionHandleMode == .none }
        XCTAssertFalse(try XCTUnwrap(recorder.snapshots.last).selectionGestureActive)

        terminal.nativeInteraction.beginSelectionDrag(start: true, at: handlePoint)
        terminal.nativeInteraction.cancelSelectionDrag()
        XCTAssertFalse(try XCTUnwrap(recorder.snapshots.last).selectionGestureActive)
        XCTAssertEqual(recorder.snapshots.last?.handleMode, TerminalSelectionDebugSnapshot.HandleMode.none)

        for state: UIGestureRecognizer.State in [.cancelled, .failed] {
            terminal.nativeInteraction.wordSelection(state: .began, at: point, modifiers: [])
            XCTAssertTrue(terminal.selectionGestureActive)
            terminal.nativeInteraction.wordSelection(state: state, at: point, modifiers: [])
            let cancelled = try XCTUnwrap(recorder.snapshots.last)
            XCTAssertFalse(cancelled.selectionGestureActive)
            XCTAssertFalse(cancelled.loupeVisible)
            XCTAssertNil(cancelled.activePointerButton)
        }

        terminal.nativeInteraction.beginSelectionDrag(start: false, at: handlePoint)
        XCTAssertTrue(terminal.selectionGestureActive)
        // Real lifecycle order discards the content frame at willResignActive.
        // Clearing only through that frame silently leaves native selection alive.
        lifecycle.post(UIApplication.willResignActiveNotification, object: nil)
        lifecycle.post(UIApplication.didEnterBackgroundNotification, object: nil)
        let background = try XCTUnwrap(recorder.snapshots.last)
        XCTAssertFalse(background.selectionGestureActive)
        XCTAssertFalse(background.touchHandlesVisible)
        XCTAssertFalse(background.loupeVisible)
        XCTAssertEqual(background.handleMode, .none)
        XCTAssertNil(background.displayStartEndpoint)
        XCTAssertNil(background.displayEndEndpoint)
        lifecycle.post(UIApplication.didBecomeActiveNotification, object: nil)
        try await waitUntil {
            terminal.surface?.frameValue != nil
                && terminal.selectionDebugProbe?.snapshot?.nativeSelectionExists == false
        }
        XCTAssertFalse(terminal.selectionHandlesVisible)
        terminal.nativeInteraction.wordSelection(state: .began, at: point, modifiers: [])
        try await waitUntil { terminal.selectionDebugProbe?.snapshot?.selectedText == "bravo" }
        terminal.nativeInteraction.wordSelection(state: .ended, at: point, modifiers: [])
        try await waitUntil { !terminal.nativeInteraction.wordDragging }
        XCTAssertTrue(terminal.selectionHandlesVisible)
    }

    func testCaptureActivationRevokesHeldWordSelectionWithoutRemoteRelease() async throws {
        let terminal = makeTerminal()
        let window = try await mountSelectionWindow(terminal)
        let writes = SelectionWriteRecorder()
        let session = VTTerminalSession(write: { writes.append($0) }, resize: { _ in })
        terminal.configuration = .init(backend: .vt(session))
        terminal.controller = TerminalController()
        terminal.selectionDebugConfiguration = .init(accessibilityIdentifierPrefix: "selection-capture")
        lifecycle.post(UIApplication.didBecomeActiveNotification, object: nil)
        defer {
            terminal.controller = nil
            window.isHidden = true
            session.finish()
        }
        try await waitUntil { terminal.surface?.frameValue != nil }
        session.deliver(Data("ALPHA BRAVO CHARLIE".utf8), ifCurrent: { true }, completion: { _ in })
        try await waitUntil { terminal.surface?.frameValue?.line(0).hasPrefix("ALPHA BRAVO") == true }
        let frame = try XCTUnwrap(terminal.surface?.frameValue)
        let rect = frame.layout.rect(column: 8, row: 0)
        let point = CGPoint(x: rect.midX, y: rect.midY)
        terminal.nativeInteraction.wordSelection(state: .began, at: point, modifiers: [])
        try await waitUntil { terminal.selectionDebugProbe?.snapshot?.selectedText == "BRAVO" }
        session.deliver(Data("\u{1B}[?1000h\u{1B}[?1006h".utf8), ifCurrent: { true }, completion: { _ in })
        try await waitUntil {
            terminal.selectionDebugProbe?.snapshot?.isMouseCaptured == true
                && terminal.selectionDebugProbe?.snapshot?.nativeSelectionExists == false
                && !terminal.nativeInteraction.wordDragging
        }
        terminal.nativeInteraction.wordSelection(state: .changed, at: point, modifiers: [])
        terminal.nativeInteraction.wordSelection(state: .ended, at: point, modifiers: [])
        XCTAssertFalse(terminal.selectionGestureActive)
        XCTAssertNil(terminal.activePointerButton)
        XCTAssertFalse(terminal.selectionHandlesVisible)
        XCTAssertTrue(terminal.selectionMagnifier?.isHidden == true)
        XCTAssertTrue(writes.isEmpty, "A revoked local gesture must not emit an unmatched remote release")

        // Capture already active is not a transition: native Shift override
        // remains allowed and must not be cleared on every captured frame.
        terminal.nativeInteraction.wordSelection(state: .began, at: point, modifiers: [.shift])
        try await waitUntil { terminal.selectionDebugProbe?.snapshot?.selectedText == "BRAVO" }
        terminal.nativeInteraction.wordSelection(state: .ended, at: point, modifiers: [.shift])
        try await waitUntil { !terminal.nativeInteraction.wordDragging }
        XCTAssertTrue(terminal.selectionHandlesVisible)
        XCTAssertTrue(writes.isEmpty)
    }

    func testTypingRevokesStationaryHeldWordSelectionAndClearsMountedOverlaysAtViewportBottom() async throws {
        let writes = SelectionWriteRecorder()
        let expectedInput = Data("typed".utf8)
        let inputWritten = expectation(description: "Typed input is written exactly once")
        inputWritten.expectedFulfillmentCount = 1
        inputWritten.assertForOverFulfill = true
        let session = VTTerminalSession(write: { bytes in
            writes.append(bytes)
            XCTAssertEqual(bytes, expectedInput, "Local selection must not emit remote pointer bytes")
            inputWritten.fulfill()
        }, resize: { _ in })
        let (terminal, window) = try await mountSelectionHost(session)
        defer { terminal.controller = nil; window.isHidden = true; session.finish() }
        let recorder = SelectionSnapshotRecorder()
        terminal.selectionDebugConfiguration = .init(
            accessibilityIdentifierPrefix: "selection-typing",
            snapshotCallback: { recorder.append($0) }
        )
        let initial = try XCTUnwrap(terminal.surface?.frameValue)
        let lines = (0..<(initial.viewport.rows + 60)).map {
            "ALPHA BRAVO CHARLIE \($0)\r\n"
        }.joined()
        session.receive(Data((lines + "prompt> ").utf8))
        let bottom = try await session.snapshot()
        XCTAssertGreaterThan(bottom.scrollbackRows, 0)
        XCTAssertFalse(bottom.viewport.canScrollDown)
        try await waitUntil { terminal.surface?.frameValue?.viewport == bottom.viewport }
        let scroll = try XCTUnwrap(session.enqueueScrollPointer(.init(
            terminalID: bottom.terminalID, generation: bottom.layout.generation,
            point: terminal.bounds.center, delta: CGPoint(x: 0, y: 10_000), modifiers: []
        )))
        let scrollBytes = try await scroll.value
        XCTAssertTrue(scrollBytes.isEmpty)
        try await waitUntil {
            terminal.surface?.frameValue?.viewport.offset == 0
                && terminal.surface?.frameValue?.viewport.canScrollDown == true
        }
        let history = try XCTUnwrap(terminal.surface?.frameValue)
        // Stay away from viewport edges so no move or autoscroll can end the held press.
        let row = history.layout.rows / 2
        let rect = history.layout.rect(column: 8, row: row)
        let point = CGPoint(x: rect.midX, y: rect.midY)
        terminal.nativeInteraction.wordSelection(state: .began, at: point, modifiers: [])
        try await waitUntil {
            terminal.selectionDebugProbe?.snapshot?.selectedText == "BRAVO"
                && terminal.nativeInteraction.wordDragging
                && terminal.selectionGestureActive
                && terminal.selectionDebugProbe?.snapshot?.loupeVisible == true
        }
        XCTAssertFalse(try XCTUnwrap(terminal.selectionMagnifier).isHidden)
        XCTAssertTrue(writes.isEmpty)

        // No changed/ended event or remote echo: the production frame must revoke UIKit's hold.
        let input = try XCTUnwrap(session.enqueueInput(.text("typed")))
        let inputBytes = try await input.value
        XCTAssertEqual(inputBytes, expectedInput)
        try await waitUntil {
            terminal.selectionDebugProbe?.snapshot?.nativeSelectionExists == false
                && !terminal.nativeInteraction.wordDragging
                && !terminal.selectionGestureActive
                && terminal.selectionDebugProbe?.snapshot?.selectionGestureActive == false
                && terminal.selectionDebugProbe?.snapshot?.loupeVisible == false
                && terminal.selectionMagnifier?.isHidden == true
                && terminal.surface?.frameValue?.viewport == bottom.viewport
        }
        let cleared = try XCTUnwrap(terminal.surface?.frameValue)
        XCTAssertNil(cleared.selection)
        XCTAssertNotNil(cleared.revokedSelectionPointerID)
        XCTAssertFalse(cleared.viewport.canScrollDown)
        XCTAssertEqual((0..<cleared.layout.rows).map { cleared.line($0) },
                       (0..<bottom.layout.rows).map { bottom.line($0) },
                       "Typing must reveal the prompt without remote echo")
        XCTAssertFalse(terminal.selectionHandlesVisible)
        XCTAssertNil(terminal.activePointerButton)

        let beforeLateEvents = recorder.snapshots.count
        let lateRect = history.layout.rect(column: 16, row: row)
        let latePoint = CGPoint(x: lateRect.midX, y: lateRect.midY)
        terminal.nativeInteraction.wordSelection(state: .changed, at: latePoint, modifiers: [])
        terminal.nativeInteraction.wordSelection(state: .ended, at: latePoint, modifiers: [])
        let afterLateEvents = try await session.snapshot() // FIFO barrier for any accidental pointer input.
        XCTAssertNil(afterLateEvents.selection)
        XCTAssertEqual(afterLateEvents.viewport, bottom.viewport)
        XCTAssertFalse(terminal.nativeInteraction.wordDragging)
        XCTAssertFalse(terminal.selectionGestureActive)
        XCTAssertFalse(terminal.selectionHandlesVisible)
        XCTAssertTrue(terminal.selectionMagnifier?.isHidden == true)
        XCTAssertNil(terminal.activePointerButton)
        XCTAssertTrue(recorder.snapshots.dropFirst(beforeLateEvents).allSatisfy {
            $0.nativeSelectionExists == false && !$0.selectionGestureActive && !$0.loupeVisible
        }, "Late gesture events must not restore selection or overlays")
        await fulfillment(of: [inputWritten], timeout: 5)
    }

    func testHostRemountClearsSharedSessionSelectionAndAllowsFreshGesture() async throws {
        let terminal = makeTerminal()
        let window = try await mountSelectionWindow(terminal)
        let root = try XCTUnwrap(window.rootViewController)
        let session = VTTerminalSession(write: { _ in }, resize: { _ in })
        terminal.configuration = .init(backend: .vt(session))
        terminal.controller = TerminalController()
        terminal.selectionDebugConfiguration = .init(accessibilityIdentifierPrefix: "selection-remount")
        lifecycle.post(UIApplication.didBecomeActiveNotification, object: nil)
        defer {
            terminal.controller = nil
            window.isHidden = true
            session.finish()
        }
        try await waitUntil { terminal.surface?.frameValue != nil }
        session.deliver(Data("ALPHA BRAVO CHARLIE".utf8), ifCurrent: { true }, completion: { _ in })
        try await waitUntil { terminal.surface?.frameValue?.line(0).hasPrefix("ALPHA BRAVO") == true }
        let frame = try XCTUnwrap(terminal.surface?.frameValue)
        let rect = frame.layout.rect(column: 8, row: 0)
        let point = CGPoint(x: rect.midX, y: rect.midY)
        terminal.nativeInteraction.wordSelection(state: .began, at: point, modifiers: [])
        try await waitUntil { terminal.selectionDebugProbe?.snapshot?.selectedText == "BRAVO" }
        terminal.nativeInteraction.wordSelection(state: .ended, at: point, modifiers: [])
        try await waitUntil { !terminal.nativeInteraction.wordDragging }
        let pickup = try XCTUnwrap(terminal.selectionEndHandle).center
        terminal.nativeInteraction.beginSelectionDrag(start: false, at: pickup)
        terminal.nativeInteraction.moveSelectionDrag(to: CGPoint(x: pickup.x + frame.layout.cellWidth, y: pickup.y))
        XCTAssertTrue(terminal.nativeInteraction.isDraggingSelection)
        terminal.removeFromSuperview()
        XCTAssertNil(terminal.surface)
        root.view.addSubview(terminal)
        try await waitUntil {
            terminal.surface?.frameValue != nil
                && terminal.selectionDebugProbe?.snapshot?.nativeSelectionExists == false
        }
        XCTAssertEqual(terminal.surface?.frameValue?.terminalID, frame.terminalID,
            "Remount must retain the engine while discarding host selection")
        XCTAssertFalse(terminal.selectionGestureActive)
        XCTAssertFalse(terminal.selectionHandlesVisible)
        XCTAssertEqual(terminal.selectionHandleMode, .none)
        terminal.nativeInteraction.wordSelection(state: .began, at: point, modifiers: [])
        try await waitUntil { terminal.selectionDebugProbe?.snapshot?.selectedText == "BRAVO" }
        terminal.nativeInteraction.wordSelection(state: .ended, at: point, modifiers: [])
        try await waitUntil { !terminal.nativeInteraction.wordDragging }
        XCTAssertTrue(terminal.selectionHandlesVisible)
    }

    private func mountSelectionWindow(_ terminal: UITerminalView) async throws -> UIWindow {
        // The production loupe snapshots and edit menu require a real scene.
        // Scene-less fixtures repeatedly suspended presentation during selection
        // snapshotting, leaving the probe without an accepted grid.
        try await waitUntil("active selection scene") {
            UIApplication.shared.connectedScenes.contains { ($0 as? UIWindowScene)?.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        if previousKeyWindow == nil { previousKeyWindow = scene.windows.first { $0.isKeyWindow } }
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let root = UIViewController()
        window.rootViewController = root
        root.view.addSubview(terminal)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        root.view.layoutIfNeeded()
        terminal.layoutIfNeeded()
        return window
    }

    private func mountSelectionHost(_ session: VTTerminalSession) async throws -> (UITerminalView, UIWindow) {
        let terminal = makeTerminal()
        let window = try await mountSelectionWindow(terminal)
        terminal.configuration = .init(backend: .vt(session))
        terminal.controller = TerminalController()
        terminal.layoutIfNeeded()
        lifecycle.post(UIApplication.didBecomeActiveNotification, object: nil)
        try await waitUntil { terminal.surface?.frameValue != nil }
        return (terminal, window)
    }

    func testOverlappingHostReplacementClearsOldHostsSelectionBeforeRetirement() async throws {
        let session = VTTerminalSession(write: { _ in }, resize: { _ in })
        let (oldHost, oldWindow) = try await mountSelectionHost(session)
        defer { oldHost.controller = nil; oldWindow.isHidden = true; session.finish() }
        session.receive(Data("ALPHA BRAVO CHARLIE".utf8))
        let frame = try await session.snapshot()
        await session.select(.word, at: .init(column: 8, row: 0), generation: frame.layout.generation)
        let selected = await session.selectedText()
        XCTAssertEqual(selected, "BRAVO")

        let (newHost, newWindow) = try await mountSelectionHost(session)
        defer { newHost.controller = nil; newWindow.isHidden = true }
        let replaced = try await session.snapshot()
        XCTAssertNil(replaced.selection, "Ownership transfer must clear A before any B input")
        oldHost.removeFromSuperview()
        XCTAssertNil(oldHost.surface)
        let retired = try await session.snapshot()
        XCTAssertNil(retired.selection)
        let text = await session.selectedText()
        XCTAssertEqual(text, "")
    }

    func testOverlappingHostRetirementDoesNotClearNewHostsSelection() async throws {
        let session = VTTerminalSession(write: { _ in }, resize: { _ in })
        let (oldHost, oldWindow) = try await mountSelectionHost(session)
        let (newHost, newWindow) = try await mountSelectionHost(session)
        defer {
            oldHost.controller = nil
            newHost.controller = nil
            oldWindow.isHidden = true
            newWindow.isHidden = true
            session.finish()
        }
        session.receive(Data("ALPHA BRAVO CHARLIE".utf8))
        let frame = try await session.snapshot()
        await session.select(.word, at: .init(column: 8, row: 0), generation: frame.layout.generation)
        oldHost.removeFromSuperview() // Actual late onSurfaceFreed(A), after B attaches/selects.
        XCTAssertNil(oldHost.surface)
        let after = try await session.snapshot()
        XCTAssertEqual(after.selectedText(), "BRAVO")
        let text = await session.selectedText()
        XCTAssertEqual(text, "BRAVO")
    }

    func testShiftSelectionAfterModeBytesSurvivesDelayedCaptureFrame() async throws {
        let session = VTTerminalSession(write: { _ in }, resize: { _ in })
        let (terminal, window) = try await mountSelectionHost(session)
        defer { terminal.controller = nil; window.isHidden = true; session.finish() }
        session.receive(Data("ALPHA BRAVO CHARLIE".utf8))
        try await waitUntil { terminal.surface?.frameValue?.line(0).hasPrefix("ALPHA BRAVO") == true }
        let surface = try XCTUnwrap(terminal.surface)
        let old = try XCTUnwrap(surface.frameValue)
        terminal.nativeInteraction.update(old)
        let rect = old.layout.rect(column: 8, row: 0)
        let point = CGPoint(x: rect.midX, y: rect.midY)
        terminal.nativeInteraction.wordSelection(state: .began, at: point, modifiers: [])
        try await waitUntil { await session.selectedText() == "BRAVO" }
        surface.contentView.onFrame = nil // Hold interaction presentation, not native ingestion.
        session.receive(Data("\u{1B}[?1000h\u{1B}[?1006h".utf8))
        let modeFrame = try await session.snapshot()
        XCTAssertTrue(modeFrame.mouseTracking)
        XCTAssertNil(modeFrame.selection, "Ingestion itself revokes the pretransition selection")
        XCTAssertNotNil(modeFrame.revokedSelectionPointerID)
        // Rare full-suite timeout (never reproduced in isolation): keep the
        // pointer request/response trace so a failure shows where B stalled.
        var pointerTrace = ""
        terminal.nativePointer.onDiagnostic = { pointerTrace = $0 }
        terminal.nativeInteraction.wordSelection(state: .began, at: point, modifiers: [.shift])
        try await waitUntil("Shift word selection after mode bytes", diagnostics: {
            "wordDragging=\(terminal.nativeInteraction.wordDragging) pressed=\(terminal.nativePointer.isPressed)\n\(pointerTrace)"
        }) { await session.selectedText() == "BRAVO" }
        let selected = try await session.snapshot()
        terminal.nativeInteraction.update(modeFrame) // Delayed frame must not revoke new identity.
        terminal.nativeInteraction.update(selected)
        let text = await session.selectedText()
        XCTAssertEqual(text, "BRAVO")
        XCTAssertTrue(terminal.nativeInteraction.wordDragging)
        XCTAssertTrue(terminal.selectionHandlesVisible)
        terminal.nativeInteraction.wordSelection(state: .ended, at: point, modifiers: [.shift])
    }

    func testIndirectShiftPointerSurvivesDelayedRevocationOfOldWordGesture() async throws {
        let writes = SelectionWriteRecorder()
        let session = VTTerminalSession(write: { writes.append($0) }, resize: { _ in })
        let (terminal, window) = try await mountSelectionHost(session)
        defer { terminal.controller = nil; window.isHidden = true; session.finish() }
        session.receive(Data("ALPHA BRAVO CHARLIE".utf8))
        try await waitUntil { terminal.surface?.frameValue?.line(0).hasPrefix("ALPHA BRAVO") == true }
        let surface = try XCTUnwrap(terminal.surface)
        let frame = try XCTUnwrap(surface.frameValue)
        func point(_ column: Int) -> CGPoint {
            let rect = frame.layout.rect(column: column, row: 0)
            return CGPoint(x: rect.midX, y: rect.midY)
        }
        terminal.nativeInteraction.wordSelection(state: .began, at: point(8), modifiers: [])
        try await waitUntil { await session.selectedText() == "BRAVO" }
        surface.contentView.onFrame = nil
        session.receive(Data("\u{1B}[?1000h\u{1B}[?1006h".utf8))
        let modeFrame = try await session.snapshot()
        let revoked = try XCTUnwrap(modeFrame.revokedSelectionPointerID)
        XCTAssertNil(modeFrame.selection)

        // End A and admit indirect pointer B synchronously, before A's release
        // completion can reset wordPointerID. B is deliberately not a word gesture.
        terminal.nativeInteraction.wordSelection(state: .ended, at: point(8), modifiers: [])
        let pointerID = try XCTUnwrap(terminal.nativePointer.begin(at: point(6),
            modifiers: [.shift], source: .pointer))
        XCTAssertNotEqual(pointerID, revoked)
        terminal.nativePointer.move(to: point(14), modifiers: [.shift])
        // No suspension yet: A's queued release has not completed, so the
        // delayed revocation arrives while A's word identity is still live.
        XCTAssertTrue(terminal.nativeInteraction.wordDragging, "A's word identity is still awaiting completion")
        terminal.nativeInteraction.update(modeFrame)
        let selected = try await session.snapshot()
        XCTAssertNotNil(selected.selection)
        terminal.nativeInteraction.update(selected)
        XCTAssertFalse(terminal.nativeInteraction.wordDragging)
        XCTAssertTrue(terminal.nativePointer.isPressed, "Revoking A must not cancel indirect pointer B")
        XCTAssertNotNil(terminal.activePointerButton)
        let retained = await session.selectedText()
        XCTAssertEqual(retained, selected.selectedText())
        terminal.nativePointer.move(to: point(18), modifiers: [.shift])
        let extended = try await session.snapshot()
        XCTAssertNotEqual(extended.selectedText(), retained, "B must continue extending native selection")
        terminal.nativePointer.end(at: point(18), modifiers: [.shift])
        let released = try await session.snapshot()
        XCTAssertEqual(released.selectedText(), extended.selectedText())
        XCTAssertFalse(terminal.nativePointer.isPressed)
        XCTAssertTrue(writes.isEmpty, "Neither revoked A nor Shift-local B may emit remote mouse bytes")
    }

    private actor SelectionClearGate {
        var entered = false
        private var opened = false
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            entered = true
            guard !opened else { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func open() { opened = true; continuation?.resume(); continuation = nil }
    }

    func testGatedPreclearSnapshotCannotRestoreHandlesBeforeOrAfterClearCompletion() async throws {
        let session = VTTerminalSession(write: { _ in }, resize: { _ in })
        let (terminal, window) = try await mountSelectionHost(session)
        defer { terminal.controller = nil; window.isHidden = true; session.finish() }
        session.receive(Data("ALPHA BRAVO CHARLIE".utf8))
        let initial = try await session.snapshot()
        await session.select(.word, at: .init(column: 8, row: 0), generation: initial.layout.generation)
        try await waitUntil { terminal.selectionHandlesVisible }
        let content = try XCTUnwrap(terminal.surface?.contentView)
        // Do not let an earlier extraction (or cursor blink) occupy the one
        // snapshot task behind the gate before the explicit request below.
        content.terminalFocused = false
        try await waitUntil("selection fixture drained before admission gate") {
            !content.hasPendingSnapshotWorkForDiagnostics
                && content.metalRenderer?.inFlightCount == 0 && content.metalRenderer?.pendingCount == 0
        }
        let displayed = try XCTUnwrap(content.frameValue)
        let gate = SelectionClearGate()
        defer {
            session.beforeDelivery = nil
            Task { await gate.open() }
        }
        let extraction = content.snapshotExtractions
        session.beforeDelivery = { await gate.wait() }
        // Admit delivery and request its snapshot without yielding. Otherwise
        // an automatic request can already be blocked behind delivery when we
        // sample the counter, and our request only sets the coalesced dirty bit.
        // This increments the native revision without changing selected text.
        session.deliver(Data("\u{1B}[0m".utf8), ifCurrent: { true }, completion: { _ in })
        content.requestFrame()
        try await waitUntil("snapshot admitted behind held delivery", diagnostics: { content.renderDiagnostics }) {
            await gate.entered && content.snapshotExtractions > extraction
        }
        session.beforeDelivery = nil
        var staleFrame: GhosttyVT.VTFrameValue?
        content.onFrame = { frame in
            terminal.nativeInteraction.update(frame)
            if frame.hasSelection {
                staleFrame = frame
                XCTAssertGreaterThan(frame.revision, displayed.revision)
                XCTAssertFalse(terminal.selectionHandlesVisible,
                    "An already-admitted N+1 snapshot cannot undo immediate clear feedback")
            }
        }
        terminal.nativeInteraction.clearSelection()
        XCTAssertTrue(terminal.nativeInteraction.isSelectionClearPending)
        XCTAssertFalse(terminal.selectionHandlesVisible)
        await gate.open()
        try await waitUntil { staleFrame != nil && !terminal.nativeInteraction.isSelectionClearPending }
        terminal.nativeInteraction.update(try XCTUnwrap(staleFrame))
        XCTAssertFalse(terminal.selectionHandlesVisible,
            "After completion the ordered clear revision must still reject a late preclear frame")
        let cleared = try await session.snapshot()
        XCTAssertNil(cleared.selection)
        content.onFrame = nil
        await session.select(.word, at: .init(column: 8, row: 0), generation: cleared.layout.generation)
        terminal.nativeInteraction.update(try await session.snapshot())
        XCTAssertTrue(terminal.selectionHandlesVisible, "A genuine post-clear selection is allowed")
        content.onFrame = nil
    }

    func testHandlePanTouchDownSurvivesHandleMovementAndResetsForNextGesture() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let terminal = UIView(frame: CGRect(x: 0, y: 114, width: 400, height: 600))
        let handle = TerminalSelectionHandleView(endpoint: .end)
        window.addSubview(terminal)
        terminal.addSubview(handle)
        let pan = handle.panGesture
        XCTAssertFalse(pan.hasReceivedTouches)
        XCTAssertNil(pan.touchDownLocation(in: terminal))

        // Exact screen coordinates from the failing UI drag's event plist.
        let origin = CGPoint(x: 57, y: 478.6666666666667)
        pan.recordTouchDown(at: origin, in: window)
        handle.center = CGPoint(x: 87, y: 364.6666666666667)
        pan.recordTouchDown(at: CGPoint(x: 67, y: origin.y), in: window)
        let touchDown = try XCTUnwrap(pan.touchDownLocation(in: terminal))
        XCTAssertEqual(touchDown.x, 57)
        XCTAssertEqual(touchDown.y, origin.y - 114, accuracy: 0.0001)
        XCTAssertTrue(pan.hasReceivedTouches)
        XCTAssertEqual(CGFloat(97) - touchDown.x, 40,
            "All eight cells of actual finger movement survive recognition and handle movement")

        terminal.frame.origin.x = 20
        XCTAssertEqual(try XCTUnwrap(pan.touchDownLocation(in: terminal)).x, 37,
            "Convert the fixed window origin into the current destination coordinate space")
        pan.reset()
        XCTAssertFalse(pan.hasReceivedTouches)
        XCTAssertNil(pan.touchDownLocation(in: terminal))
        pan.recordTouchDown(at: CGPoint(x: 120, y: 300), in: window)
        XCTAssertEqual(pan.touchDownLocation(in: terminal), CGPoint(x: 100, y: 186))
    }

    func testHandlePanDoesNotRebaseMissingOrReplacedTouchWindow() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let otherWindow = UIWindow(frame: window.frame)
        let terminal = UIView(frame: window.bounds)
        let handle = TerminalSelectionHandleView(endpoint: .end)
        window.addSubview(terminal)
        terminal.addSubview(handle)
        let pan = handle.panGesture
        pan.recordTouchDown(at: CGPoint(x: 57, y: 400), in: window)
        otherWindow.addSubview(terminal)
        XCTAssertNil(pan.touchDownLocation(in: terminal))
        XCTAssertTrue(pan.hasReceivedTouches, "Lost origins must not enter the synthetic translation fallback")

        pan.reset()
        pan.recordTouchDown(at: .zero, in: nil)
        XCTAssertTrue(pan.hasReceivedTouches)
        XCTAssertNil(pan.touchDownLocation(in: terminal))
    }

    func testHandlePanDoesNotRetainTouchWindow() {
        let handle = TerminalSelectionHandleView(endpoint: .end)
        let pan = handle.panGesture
        weak var releasedWindow: UIWindow?
        autoreleasepool {
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
            releasedWindow = window
            window.addSubview(handle)
            pan.recordTouchDown(at: CGPoint(x: 57, y: 400), in: window)
            handle.removeFromSuperview()
        }
        XCTAssertNil(releasedWindow)
        XCTAssertTrue(pan.hasReceivedTouches)
        XCTAssertNil(pan.touchDownLocation(in: handle))
    }

    func testHandleDragPreservesRecognitionTranslationWithoutPickupOrReleaseJumps() async throws {
        let terminal = makeTerminal()
        let window = try await mountSelectionWindow(terminal)
        let session = VTTerminalSession(write: { _ in }, resize: { _ in })
        terminal.configuration = .init(backend: .vt(session))
        terminal.controller = TerminalController()
        terminal.layoutIfNeeded()
        lifecycle.post(UIApplication.didBecomeActiveNotification, object: nil)
        defer {
            terminal.controller = nil
            window.isHidden = true
            session.finish()
        }
        terminal.selectionDebugConfiguration = .init(accessibilityIdentifierPrefix: "selection-pan-slop")
        try await waitUntil { terminal.surface?.frameValue != nil }
        session.deliver(Data("ALPHA BRAVO CHARLIE".utf8), ifCurrent: { true }, completion: { _ in })
        try await waitUntil { terminal.surface?.frameValue?.line(0).hasPrefix("ALPHA BRAVO") == true }

        // Keep scalar diagnostics for this async gesture boundary. A native
        // selection and its UIKit completion are different readiness conditions.
        var pointerTrace = ""
        terminal.nativePointer.onDiagnostic = { pointerTrace = $0 }
        defer { terminal.nativePointer.onDiagnostic = nil }
        // Same physical drag in both runs: recognition happens two cells after
        // touch-down, then the finger reaches CHARLIE's final cell (column 18).
        for preserveTranslation in [false, true] {
            let frame = try XCTUnwrap(terminal.surface?.frameValue)
            let wordRect = frame.layout.rect(column: 8, row: 0)
            let wordPoint = CGPoint(x: wordRect.midX, y: wordRect.midY)
            terminal.nativeInteraction.wordSelection(state: .began, at: wordPoint, modifiers: [])
            try await waitUntil("word selection before handle drag, preserveTranslation=\(preserveTranslation)", diagnostics: {
                "wordDragging=\(terminal.nativeInteraction.wordDragging) pressed=\(terminal.nativePointer.isPressed) "
                    + "scene=\(String(describing: window.windowScene?.activationState)) "
                    + "snapshot=\(String(describing: terminal.selectionDebugProbe?.snapshot))\n"
                    + "\(terminal.surface?.contentView.renderDiagnostics ?? "no-content")\n\(pointerTrace)"
            }) { terminal.selectionDebugProbe?.snapshot?.selectedText == "BRAVO" }
            terminal.nativeInteraction.wordSelection(state: .ended, at: wordPoint, modifiers: [])
            try await waitUntil { !terminal.nativeInteraction.wordDragging }
            let original = try XCTUnwrap(terminal.surface?.frameValue?.selection)
            XCTAssertEqual(original.startEndpoint.position.column, 6)
            XCTAssertEqual(original.endEndpoint.position.column, 10)
            let handle = try XCTUnwrap(terminal.selectionEndHandle)
            // A noncentral pickup also exercises finger-to-cell offset rather
            // than incorrectly mapping the displayed handle or finger itself.
            let touchDown = CGPoint(x: handle.center.x + 7, y: handle.center.y - 3)
            let slop = CGPoint(x: 2 * frame.layout.cellWidth, y: 0)
            let recognized = CGPoint(x: touchDown.x + slop.x, y: touchDown.y)
            let destination = CGPoint(x: touchDown.x + 8 * frame.layout.cellWidth, y: touchDown.y)

            terminal.nativeInteraction.beginSelectionDrag(start: false, at: touchDown)
            XCTAssertNil(terminal.nativeInteraction.pendingDragRequest)
            terminal.nativeInteraction.endSelectionDrag(at: touchDown)
            XCTAssertFalse(terminal.nativeInteraction.isDraggingSelection)
            XCTAssertEqual(terminal.surface?.frameValue?.selection, original,
                "Stationary pickup/release must not snap to the handle's display position")

            for invalid in [CGPoint(x: CGFloat.nan, y: 0), CGPoint(x: 0, y: CGFloat.nan),
                            CGPoint(x: CGFloat.infinity, y: 0), CGPoint(x: 0, y: -CGFloat.infinity)] {
                terminal.nativeInteraction.beginSelectionDrag(start: false, at: recognized, initialTranslation: invalid)
                XCTAssertFalse(terminal.nativeInteraction.isDraggingSelection)
                XCTAssertFalse(terminal.selectionGestureActive)
                XCTAssertNil(terminal.nativeInteraction.pendingDragRequest)
                XCTAssertEqual(terminal.surface?.frameValue?.selection, original)
            }

            terminal.nativeInteraction.beginSelectionDrag(start: false, at: recognized,
                initialTranslation: preserveTranslation ? slop : .zero)
            let initialRequest = terminal.nativeInteraction.pendingDragRequest
            if preserveTranslation {
                let request = try XCTUnwrap(initialRequest)
                XCTAssertEqual(request.terminalID, frame.terminalID)
                XCTAssertEqual(request.generation, frame.layout.generation)
                XCTAssertFalse(request.start)
                XCTAssertEqual(request.position.column, 12, "Recognized movement must be submitted immediately")
                XCTAssertEqual(request.position.row, 0, "Clamped handle display must not introduce a row jump")
                try await waitUntil {
                    terminal.surface?.frameValue?.selection?.endEndpoint.position.column == 12
                        && terminal.nativeInteraction.pendingDragRequest == nil
                }
            } else {
                XCTAssertNil(terminal.nativeInteraction.pendingDragRequest)
                XCTAssertEqual(terminal.surface?.frameValue?.selection, original,
                    "Zero translation is a stationary pickup, even away from the handle center")
            }
            XCTAssertEqual(terminal.surface?.frameValue?.selection?.startEndpoint, original.startEndpoint)

            terminal.nativeInteraction.moveSelectionDrag(to: destination)
            let finalRequest = try XCTUnwrap(terminal.nativeInteraction.pendingDragRequest)
            let expectedColumn = preserveTranslation ? 18 : 16
            XCTAssertEqual(finalRequest.position.column, expectedColumn)
            XCTAssertEqual(finalRequest.position.row, 0)
            XCTAssertEqual(finalRequest.terminalID, frame.terminalID)
            XCTAssertEqual(finalRequest.generation, frame.layout.generation)
            if let initialRequest {
                XCTAssertEqual(finalRequest.gestureID, initialRequest.gestureID)
            }
            terminal.nativeInteraction.endSelectionDrag(at: destination)
            try await waitUntil {
                !terminal.nativeInteraction.isDraggingSelection
                    && terminal.selectionDebugProbe?.snapshot?.selectedText
                        == (preserveTranslation ? "BRAVO CHARLIE" : "BRAVO CHARL")
            }
            let result = try XCTUnwrap(terminal.surface?.frameValue?.selection)
            XCTAssertEqual(result.startEndpoint, original.startEndpoint, "Only the dragged native endpoint moves")
            XCTAssertEqual(result.endEndpoint.position.column, expectedColumn,
                "Release must neither lose nor double-apply the recognition translation")
            XCTAssertEqual(result.endEndpoint.position.row, 0)
            XCTAssertFalse(terminal.selectionGestureActive)
            XCTAssertNil(terminal.nativeInteraction.pendingDragRequest)
        }
    }

    func testUnadmittedGesturesDoNotPublishActiveSelection() throws {
        let terminal = makeTerminal()
        terminal.selectionDebugConfiguration = .init(accessibilityIdentifierPrefix: "selection-unready")
        terminal.nativeInteraction.wordSelection(state: .began, at: .zero, modifiers: [])
        terminal.nativeInteraction.beginSelectionDrag(start: true, at: .zero)
        XCTAssertFalse(terminal.selectionGestureActive)
        XCTAssertFalse(try XCTUnwrap(terminal.selectionDebugProbe?.snapshot).selectionGestureActive)
    }

    func testHandleAccessibilityAdjustmentsEmitSingleCellDeltas() throws {
        let terminal = makeTerminal()
        let startHandle = try XCTUnwrap(terminal.selectionStartHandle)
        let endHandle = try XCTUnwrap(terminal.selectionEndHandle)
        var startDeltas: [Int] = []
        var endDeltas: [Int] = []
        startHandle.onAccessibilityNudge = { startDeltas.append($0) }
        endHandle.onAccessibilityNudge = { endDeltas.append($0) }

        startHandle.accessibilityIncrement()
        startHandle.accessibilityDecrement()
        XCTAssertTrue(startHandle.accessibilityActivate())
        endHandle.accessibilityIncrement()
        endHandle.accessibilityDecrement()
        XCTAssertTrue(endHandle.accessibilityActivate())

        XCTAssertEqual(startDeltas, [1, -1, -1])
        XCTAssertEqual(endDeltas, [1, -1, 1])
        XCTAssertTrue(startDeltas.allSatisfy { abs($0) == 1 })
        XCTAssertTrue(endDeltas.allSatisfy { abs($0) == 1 })
    }

    private func makeTerminal() -> UITerminalView {
        let terminal = UITerminalView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480)
        )
        terminal.layoutIfNeeded()
        return terminal
    }

    private func makeConfiguration(
        prefix: String,
        callbackOwner: CallbackOwner,
        recorder: SelectionSnapshotRecorder
    ) -> TerminalSelectionDebugConfiguration {
        TerminalSelectionDebugConfiguration(
            accessibilityIdentifierPrefix: prefix,
            snapshotCallback: { [callbackOwner] snapshot in
                callbackOwner.callbackCount += 1
                recorder.append(snapshot)
            }
        )
    }
}

@MainActor
private final class SelectionSnapshotRecorder {
    private(set) var snapshots: [TerminalSelectionDebugSnapshot] = []

    func append(_ snapshot: TerminalSelectionDebugSnapshot) {
        snapshots.append(snapshot)
    }
}

@MainActor
private final class CallbackOwner {
    var callbackCount = 0
}

private final class SelectionWriteRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ bytes: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(bytes)
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return data.isEmpty
    }
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}
#endif
