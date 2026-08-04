#if DEBUG && canImport(UIKit) && !targetEnvironment(macCatalyst)
import UIKit
import XCTest
@testable import GhosttyTerminal

@MainActor
final class TerminalSelectionDebugAccessibilityTests: XCTestCase {
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
        XCTAssertNil(startHandle.superview)
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
        terminal.touchSelectionAnchorMousePoint = CGPoint(x: 20, y: 32)
        terminal.touchSelectionActiveEndMousePoint = CGPoint(x: 140, y: 68)
        terminal.selectionHandlesVisible = true
        terminal.selectionStartHandle?.frame = CGRect(x: 1, y: 12, width: 48, height: 48)
        terminal.selectionEndHandle?.frame = CGRect(x: 121, y: 48, width: 48, height: 48)
        terminal.selectionStartHandle?.setVisible(true)
        terminal.selectionEndHandle?.setVisible(true)
        terminal.syntheticLeftButtonDown = true
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
        XCTAssertEqual(snapshot.mouseStartEndpoint, .init(CGPoint(x: 20, y: 32)))
        XCTAssertEqual(snapshot.mouseEndEndpoint, .init(CGPoint(x: 140, y: 68)))
        XCTAssertEqual(
            snapshot.startHandleFrame,
            .init(CGRect(x: 1, y: 12, width: 48, height: 48))
        )
        XCTAssertEqual(
            snapshot.endHandleFrame,
            .init(CGRect(x: 121, y: 48, width: 48, height: 48))
        )
        XCTAssertTrue(snapshot.touchHandlesVisible)
        XCTAssertTrue(snapshot.syntheticLeftButtonDown)
        XCTAssertEqual(snapshot.handleMode, .adjustingEnd)
        XCTAssertFalse(snapshot.surfaceReady)
        XCTAssertFalse(snapshot.gridReady)
        XCTAssertNil(snapshot.selectedText)
        XCTAssertNil(snapshot.nativeSelectionExists)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
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

        terminal.syntheticLeftButtonDown = true
        let held = try XCTUnwrap(recorder.snapshots.last)
        XCTAssertEqual(held.revision, initial.revision + 1)
        XCTAssertTrue(held.syntheticLeftButtonDown)

        terminal.syntheticLeftButtonDown = true
        terminal.refreshSelectionDebugSnapshot()
        XCTAssertEqual(recorder.snapshots.count, initialCount + 1)

        terminal.syntheticLeftButtonDown = false
        let released = try XCTUnwrap(recorder.snapshots.last)
        XCTAssertEqual(released.revision, held.revision + 1)
        XCTAssertFalse(released.syntheticLeftButtonDown)
        XCTAssertEqual(recorder.snapshots.count, initialCount + 2)
    }

    func testRemovingConfigurationDiscardsProbeIdentifiersCallbackAndRetention() throws {
        let terminal = makeTerminal()
        let recorder = SelectionSnapshotRecorder()
        var callbackOwner: CallbackOwner? = CallbackOwner()
        weak var weakCallbackOwner = callbackOwner
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

        terminal.syntheticLeftButtonDown = true
        terminal.refreshSelectionDebugSnapshot()
        XCTAssertEqual(recorder.snapshots.count, callbackCount)
    }

    func testSnapshotCallbackObservesHeldButtonLoupeAndHandleModeTransitions() throws {
        let terminal = makeTerminal()
        let recorder = SelectionSnapshotRecorder()
        terminal.selectionDebugConfiguration = .init(
            accessibilityIdentifierPrefix: "selection-transitions",
            snapshotCallback: { recorder.append($0) }
        )

        terminal.syntheticLeftButtonDown = true
        terminal.selectionHandleMode = .adjustingStart
        terminal.showSelectionMagnifier(at: CGPoint(x: 100, y: 120))

        XCTAssertTrue(recorder.snapshots.contains { $0.syntheticLeftButtonDown })
        XCTAssertTrue(recorder.snapshots.contains { $0.handleMode == .adjustingStart })
        XCTAssertTrue(recorder.snapshots.contains { $0.loupeVisible && $0.loupeFrame != nil })
        let held = try XCTUnwrap(recorder.snapshots.last)
        XCTAssertTrue(held.syntheticLeftButtonDown)
        XCTAssertEqual(held.handleMode, .adjustingStart)
        XCTAssertTrue(held.loupeVisible)

        terminal.hideSelectionMagnifier()
        terminal.syntheticLeftButtonDown = false
        terminal.selectionHandleMode = .none
        let released = try XCTUnwrap(recorder.snapshots.last)
        XCTAssertFalse(released.syntheticLeftButtonDown)
        XCTAssertFalse(released.loupeVisible)
        XCTAssertEqual(released.handleMode, .none)
    }

    func testBackgroundNotificationClearsHeldButtonLoupeHandlesAndEndpoints() throws {
        let terminal = makeTerminal()
        let recorder = SelectionSnapshotRecorder()
        terminal.selectionDebugConfiguration = .init(
            accessibilityIdentifierPrefix: "selection-background",
            snapshotCallback: { recorder.append($0) }
        )
        terminal.touchSelectionAnchorPoint = CGPoint(x: 30, y: 40)
        terminal.touchSelectionActiveEndPoint = CGPoint(x: 130, y: 80)
        terminal.touchSelectionAnchorMousePoint = CGPoint(x: 28, y: 38)
        terminal.touchSelectionActiveEndMousePoint = CGPoint(x: 128, y: 78)
        terminal.selectionHandlesVisible = true
        terminal.selectionStartHandle?.setVisible(true)
        terminal.selectionEndHandle?.setVisible(true)
        terminal.syntheticLeftButtonDown = true
        terminal.selectionHandleMode = .adjustingEnd
        terminal.showSelectionMagnifier(at: CGPoint(x: 130, y: 80))
        terminal.refreshSelectionDebugSnapshot()
        XCTAssertTrue(recorder.snapshots.contains { $0.syntheticLeftButtonDown })

        NotificationCenter.default.post(
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )

        XCTAssertFalse(terminal.syntheticLeftButtonDown)
        XCTAssertFalse(terminal.selectionHandlesVisible)
        XCTAssertTrue(terminal.selectionStartHandle?.isHidden == true)
        XCTAssertTrue(terminal.selectionEndHandle?.isHidden == true)
        XCTAssertTrue(terminal.selectionMagnifier?.isHidden == true)
        XCTAssertEqual(terminal.selectionHandleMode, .none)
        XCTAssertNil(terminal.touchSelectionAnchorPoint)
        XCTAssertNil(terminal.touchSelectionActiveEndPoint)
        XCTAssertNil(terminal.touchSelectionAnchorMousePoint)
        XCTAssertNil(terminal.touchSelectionActiveEndMousePoint)

        let snapshot = try XCTUnwrap(recorder.snapshots.last)
        XCTAssertFalse(snapshot.syntheticLeftButtonDown)
        XCTAssertFalse(snapshot.touchHandlesVisible)
        XCTAssertFalse(snapshot.loupeVisible)
        XCTAssertEqual(snapshot.handleMode, .none)
        XCTAssertNil(snapshot.displayStartEndpoint)
        XCTAssertNil(snapshot.displayEndEndpoint)
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

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}
#endif
