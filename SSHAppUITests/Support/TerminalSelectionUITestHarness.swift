import Foundation
import UIKit
import XCTest

enum TerminalSelectionUITestScenario: String {
    case standard
    case mouseCaptured = "mouse-captured"
    case captureDuringLongPress = "capture-during-long-press"
    case remountDuringHandleDrag = "remount-during-handle-drag"
}

enum TerminalSelectionHarnessPhase: String, Decodable {
    case mounting
    case waitingForMetrics
    case opening
    case feeding
    case ready
    case failed
}

struct TerminalSelectionGridAnchor: Decodable, Equatable {
    let column: Int
    let row: Int
}

struct TerminalSelectionFixture: Decodable, Equatable {
    let rows: Int
    let columns: Int
    let fixtureRow: Int
    let anchors: [String: TerminalSelectionGridAnchor]
    let expectedStrings: [String: String]
}

struct TerminalSelectionOpenArguments: Decodable, Equatable {
    let terminalType: String
    let columns: Int
    let rows: Int
}

struct TerminalSelectionResizeArguments: Decodable, Equatable {
    let columns: Int
    let rows: Int
}

struct TerminalSelectionDebugPoint: Decodable, Equatable {
    let x: Double
    let y: Double
}

struct TerminalSelectionDebugRect: Decodable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

enum TerminalSelectionOwnership: String, Decodable {
    case none
    case touch
    case pointer
}

enum TerminalSelectionHandleMode: String, Decodable {
    case none
    case adjustingStart
    case adjustingEnd
}

struct TerminalSelectionDebugSnapshot: Decodable, Equatable {
    let schemaVersion: Int
    let revision: UInt64
    let surfaceReady: Bool
    let gridReady: Bool
    let selectedText: String?
    let nativeSelectionExists: Bool?
    let viewportCellOffsetStart: UInt32?
    let viewportCellOffsetLength: UInt32?
    let selectionOwnership: TerminalSelectionOwnership
    let touchHandlesVisible: Bool
    let displayStartEndpoint: TerminalSelectionDebugPoint?
    let displayEndEndpoint: TerminalSelectionDebugPoint?
    let mouseStartEndpoint: TerminalSelectionDebugPoint?
    let mouseEndEndpoint: TerminalSelectionDebugPoint?
    let startHandleFrame: TerminalSelectionDebugRect?
    let endHandleFrame: TerminalSelectionDebugRect?
    let loupeVisible: Bool
    let loupeFrame: TerminalSelectionDebugRect?
    let isMouseCaptured: Bool?
    let gestureStartIsMouseCaptured: Bool?
    let syntheticLeftButtonDown: Bool
    let activePointerButton: Int?
    let handleMode: TerminalSelectionHandleMode
    let terminalBounds: TerminalSelectionDebugRect
    let terminalViewportBounds: TerminalSelectionDebugRect
    let gridColumns: UInt16?
    let gridRows: UInt16?
    let gridWidthPixels: UInt32?
    let gridHeightPixels: UInt32?
    let cellWidthPixels: UInt32?
    let cellHeightPixels: UInt32?
    let displayScale: Double?
    let resolvedGridOrigin: TerminalSelectionDebugPoint?
    let cellWidthPoints: Double?
    let cellHeightPoints: Double?
}

struct TerminalSelectionGenerationLatches: Decodable, Equatable {
    let generation: Int
    let latestSnapshotRevision: UInt64
    let sawGridReady: Bool
    let sawPostFlushDraw: Bool
    let sawSyntheticButtonDown: Bool
    let sawLoupeVisible: Bool
    let sawAdjustingStart: Bool
    let sawAdjustingEnd: Bool
    let sawMouseCaptured: Bool
    let sawSurfaceRetirementCleanup: Bool
    let interruptionTriggerSnapshotRevision: UInt64?
}

struct TerminalSelectionFixtureStatus: Decodable, Equatable {
    let schemaVersion: Int
    let generation: Int
    let phase: TerminalSelectionHarnessPhase
    let scenario: String
    let error: String?
    let actualRows: Int?
    let actualColumns: Int?
    let fixture: TerminalSelectionFixture?
    let transportEventRevision: UInt64
    let openArguments: TerminalSelectionOpenArguments?
    let latestResize: TerminalSelectionResizeArguments?
    let clientWriteHex: String
    let interruptionArmed: Bool
    let interruptionFired: Bool
    let interruptionComplete: Bool
    let interruptionOutcome: String?
    let triggeringSnapshot: TerminalSelectionDebugSnapshot?
    let latestPackageSnapshot: TerminalSelectionDebugSnapshot?
    let generationLatches: [TerminalSelectionGenerationLatches]

    func latches(for targetGeneration: Int) -> TerminalSelectionGenerationLatches? {
        generationLatches.first { $0.generation == targetGeneration }
    }
}

struct TerminalSelectionTransportStatus: Decodable, Equatable {
    let schemaVersion: Int
    let eventRevision: UInt64
    let openArguments: TerminalSelectionOpenArguments?
    let latestResize: TerminalSelectionResizeArguments?
    let activeChannelCount: Int
    let pendingCallbackCount: Int
    let pendingRequestCount: Int
    let clientWriteHex: String
    let ledger: [String]
}

enum TerminalSelectionHandleEndpoint {
    case start
    case end

    fileprivate var identifier: String {
        switch self {
        case .start: "terminal.selection.startHandle"
        case .end: "terminal.selection.endHandle"
        }
    }
}

private struct TerminalSelectionUITestHarnessError: Error, LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

/// Network-free UI-test driver for the app's terminal-selection fixture.
///
/// It intentionally derives every terminal gesture from app-published grid
/// geometry. Screenshots are diagnostics only; no visual/OCR output is used as
/// an assertion oracle.
@MainActor
final class TerminalSelectionUITestHarness {
    let app = XCUIApplication()

    private static let schemaVersion = 1
    private static let maximumJSONBytes = 1_000_000
    private static let maximumGridDimension = 16_384
    private static let pollInterval: TimeInterval = 0.05
    private static let gestureTransitionTimeout: TimeInterval = 1.5
    private static let gestureRetryPolicy = ZeroTransitionGestureRetryPolicy()

    private unowned let testCase: XCTestCase
    private var launchedScenario: TerminalSelectionUITestScenario?
    private var readyStatus: TerminalSelectionFixtureStatus?

    init(testCase: XCTestCase) {
        self.testCase = testCase
    }

    func launch(scenario: TerminalSelectionUITestScenario) {
        launchedScenario = scenario
        app.launchArguments = [
            "--sshapp-in-memory-store",
            "--sshapp-reset-state",
            "--sshapp-ui-test-terminal-selection",
            "--ui-testing",
            "--sshapp-ui-test-terminal-selection-scenario=\(scenario.rawValue)",
        ]
        app.launch()

        // Ghostty's display link prevents XCTest from observing normal idleness.
        // This must be the first operation after launch so all later waits and
        // synthesized events use the repository-standard workaround.
        app.setValue(NSNumber(value: 3), forKey: "currentInteractionOptions")
        XCUIDevice.shared.orientation = .portrait
    }

    func terminate() {
        if app.state != .notRunning {
            app.terminate()
        }
    }

    func clearPasteboard() {
        UIPasteboard.general.items = []
    }

    func setPasteboardText(_ text: String) {
        UIPasteboard.general.string = text
    }

    func waitForReady(timeout: TimeInterval = 12) throws -> TerminalSelectionFixtureStatus {
        guard let launchedScenario else {
            throw fail("Terminal selection harness was not launched")
        }

        let status: TerminalSelectionFixtureStatus = try waitForDecodedValue(
            identifier: "terminal.selection.fixture",
            description: "ready fixture status for scenario \(launchedScenario.rawValue)",
            timeout: timeout,
            validate: validateFixtureStatus
        ) { status in
            status.phase == .ready && status.scenario == launchedScenario.rawValue
        }
        guard status.error == nil else {
            throw fail("Ready fixture unexpectedly reported: \(status.error ?? "unknown error")")
        }
        guard let fixture = status.fixture,
              status.actualRows == fixture.rows,
              status.actualColumns == fixture.columns,
              let packageSnapshot = status.latestPackageSnapshot,
              Int(packageSnapshot.gridRows ?? 0) == fixture.rows,
              Int(packageSnapshot.gridColumns ?? 0) == fixture.columns,
              status.openArguments == TerminalSelectionOpenArguments(
                  terminalType: "xterm-256color",
                  columns: fixture.columns,
                  rows: fixture.rows
              ),
              status.latestResize == TerminalSelectionResizeArguments(
                  columns: fixture.columns,
                  rows: fixture.rows
              )
        else {
            throw fail("Ready fixture geometry/open/resize contract is inconsistent")
        }

        _ = try waitForPackageSnapshot(timeout: timeout) { snapshot in
            snapshot.surfaceReady
                && snapshot.gridReady
                && Int(snapshot.gridRows ?? 0) == fixture.rows
                && Int(snapshot.gridColumns ?? 0) == fixture.columns
        }
        readyStatus = status
        return status
    }

    func resetObservations(generation: Int, timeout: TimeInterval = 3) throws {
        let reset = exactDescendant(identifier: "terminal.selection.resetObservations")
        try waitForElement(
            reset,
            timeout: timeout,
            description: "Reset observations button"
        )
        try performGesture(
            description: "tap Reset observations",
            relevantElements: [reset]
        ) {
            reset.tap()
        }

        _ = try waitForFixtureStatus(timeout: timeout) { status in
            guard status.generation == generation,
                  let latches = status.latches(for: generation)
            else { return false }
            return !latches.sawSyntheticButtonDown
                && !latches.sawLoupeVisible
                && !latches.sawAdjustingStart
                && !latches.sawAdjustingEnd
        }
    }

    func armInterruption(generation: Int, timeout: TimeInterval = 3) throws {
        let arm = exactDescendant(identifier: "terminal.selection.armInterruption")
        try waitForElement(arm, timeout: timeout, description: "Arm interruption button")
        try performGesture(description: "tap Arm interruption", relevantElements: [arm]) {
            arm.tap()
        }
        _ = try waitForFixtureStatus(timeout: timeout) { status in
            status.generation == generation
                && status.interruptionArmed
                && !status.interruptionFired
                && !status.interruptionComplete
        }
    }

    func waitForFixtureStatus(
        timeout: TimeInterval = 5,
        predicate: @escaping (TerminalSelectionFixtureStatus) -> Bool
    ) throws -> TerminalSelectionFixtureStatus {
        try waitForDecodedValue(
            identifier: "terminal.selection.fixture",
            description: "terminal selection fixture predicate",
            timeout: timeout,
            validate: validateFixtureStatus,
            predicate: predicate
        )
    }

    func waitForPackageSnapshot(
        timeout: TimeInterval = 5,
        predicate: @escaping (TerminalSelectionDebugSnapshot) -> Bool
    ) throws -> TerminalSelectionDebugSnapshot {
        try waitForDecodedValue(
            identifier: "terminal.selection.state",
            description: "terminal package-state predicate",
            timeout: timeout,
            validate: validateSnapshot,
            predicate: predicate
        )
    }

    func waitForTransportStatus(
        timeout: TimeInterval = 5,
        predicate: @escaping (TerminalSelectionTransportStatus) -> Bool
    ) throws -> TerminalSelectionTransportStatus {
        try waitForDecodedValue(
            identifier: "terminal.selection.transport",
            description: "terminal transport predicate",
            timeout: timeout,
            validate: validateTransportStatus,
            predicate: predicate
        )
    }

    func exactDescendant(identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", identifier)
        ).firstMatch
    }

    func handle(_ endpoint: TerminalSelectionHandleEndpoint) -> XCUIElement {
        exactDescendant(identifier: endpoint.identifier)
    }

    func waitForVisibleHandles(timeout: TimeInterval = 3) throws -> (
        start: XCUIElement,
        end: XCUIElement
    ) {
        let start = handle(.start)
        let end = handle(.end)
        try waitForElement(start, timeout: timeout, description: "identified start handle")
        try waitForElement(end, timeout: timeout, description: "identified end handle")
        return (start, end)
    }

    func waitForHandlesToDisappear(timeout: TimeInterval = 3) throws {
        let start = handle(.start)
        let end = handle(.end)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !start.exists && !end.exists {
                return
            }
            spinRunLoop()
        }
        guard !start.exists && !end.exists else {
            throw fail(
                "Timed out waiting for both identified selection handles to disappear",
                relevantElements: [start, end]
            )
        }
    }

    func waitForCopy(timeout: TimeInterval = 3) throws -> XCUIElement {
        try waitForMenuAction("Copy", timeout: timeout)
    }

    func waitForPaste(timeout: TimeInterval = 3) throws -> XCUIElement {
        try waitForMenuAction("Paste", timeout: timeout)
    }

    func assertMenuActionAbsent(
        _ title: String,
        duration: TimeInterval = 0.75
    ) throws {
        let button = app.buttons[title].firstMatch
        let menuItem = app.menuItems[title].firstMatch
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            guard !button.exists, !menuItem.exists else {
                throw fail(
                    "Unexpected \(title) edit-menu action appeared",
                    relevantElements: [button, menuItem]
                )
            }
            spinRunLoop()
        }
    }

    func tapCopy(_ copy: XCUIElement) throws {
        try tapMenuAction(copy, title: "Copy")
    }

    func tapPaste(_ paste: XCUIElement) throws {
        try tapMenuAction(paste, title: "Paste")
    }

    func handleOptionalPastePermissionPrompt(timeout: TimeInterval = 1.5) {
        // The source app's main thread is blocked while iOS waits for this
        // system-owned prompt. Querying `app` here deadlocks XCUI snapshots.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allowPaste = springboard.buttons["Allow Paste"].firstMatch
        guard allowPaste.waitForExistence(timeout: timeout), allowPaste.isHittable else {
            return
        }
        allowPaste.tap()
    }

    private func waitForMenuAction(
        _ title: String,
        timeout: TimeInterval
    ) throws -> XCUIElement {
        // UIKit's modern edit menu publishes actions by label without assigning
        // accessibility identifiers; subscript lookup matches label or ID.
        let button = app.buttons[title].firstMatch
        let menuItem = app.menuItems[title].firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if button.exists { return button }
            if menuItem.exists { return menuItem }
            spinRunLoop()
        }
        if button.exists { return button }
        if menuItem.exists { return menuItem }
        throw fail(
            "Timed out waiting for \(title) as either a button or menu item",
            relevantElements: [button, menuItem]
        )
    }

    private func tapMenuAction(_ action: XCUIElement, title: String) throws {
        guard action.exists, action.isHittable else {
            throw fail("\(title) exists but is not hittable", relevantElements: [action])
        }
        try performGesture(description: "tap \(title)", relevantElements: [action]) {
            action.tap()
        }
    }

    func waitForTerminalAccessibilityValue(
        _ expectedValue: String,
        timeout: TimeInterval = 3
    ) throws -> XCUIElement {
        let element = app.descendants(matching: .any).matching(
            NSPredicate(format: "value == %@", expectedValue)
        ).firstMatch
        try waitForElement(
            element,
            timeout: timeout,
            description: "terminal post-Copy accessibility value '\(expectedValue)'"
        )
        return element
    }

    func tap(
        anchorNamed anchorName: String,
        fixtureStatus: TerminalSelectionFixtureStatus? = nil
    ) throws {
        let target = try gridCoordinate(
            anchorNamed: anchorName,
            fixtureStatus: fixtureStatus
        )
        try performGesture(
            description: "tap fixture anchor \(anchorName)",
            relevantElements: [target.probe]
        ) {
            // Keep fixture-grid taps explicitly below the terminal's 500 ms
            // selection threshold even when XCUI is running under load.
            target.coordinate.press(forDuration: 0.01)
        }
    }

    func drag(
        fromAnchor startName: String,
        toAnchor endName: String,
        fixtureStatus: TerminalSelectionFixtureStatus? = nil
    ) throws {
        let start = try gridCoordinate(anchorNamed: startName, fixtureStatus: fixtureStatus)
        let end = try gridCoordinate(anchorNamed: endName, fixtureStatus: fixtureStatus)
        try performGesture(
            description: "drag from fixture anchor \(startName) to \(endName)",
            relevantElements: [start.probe]
        ) {
            start.coordinate.press(forDuration: 0.05, thenDragTo: end.coordinate)
        }
    }

    func stationaryLongPress(
        anchorNamed anchorName: String,
        fixtureStatus: TerminalSelectionFixtureStatus? = nil,
        duration: TimeInterval = 1.25
    ) throws {
        guard duration >= 1.2 else {
            throw fail("Terminal word-selection long press must last at least 1.2 seconds")
        }
        let target = try gridCoordinate(
            anchorNamed: anchorName,
            fixtureStatus: fixtureStatus
        )
        try performGestureWithZeroTransitionRetry(
            description: "stationary long press at fixture anchor \(anchorName)",
            relevantElements: [target.probe]
        ) {
            target.coordinate.press(forDuration: duration)
        }
    }

    func longPressDrag(
        fromAnchor startName: String,
        toAnchor endName: String,
        fixtureStatus: TerminalSelectionFixtureStatus? = nil,
        holdDuration: TimeInterval = 1.25
    ) throws {
        guard holdDuration >= 1.2 else {
            throw fail("Terminal selection drag hold must last at least 1.2 seconds")
        }
        let start = try gridCoordinate(anchorNamed: startName, fixtureStatus: fixtureStatus)
        let end = try gridCoordinate(anchorNamed: endName, fixtureStatus: fixtureStatus)
        try performGestureWithZeroTransitionRetry(
            description: "long-press drag from \(startName) to \(endName)",
            relevantElements: [start.probe]
        ) {
            start.coordinate.press(forDuration: holdDuration, thenDragTo: end.coordinate)
        }
    }

    func dragHandle(
        _ endpoint: TerminalSelectionHandleEndpoint,
        toAnchor anchorName: String,
        horizontalCellOffset: Double = 0,
        verticalCellOffset: Double = 0,
        fixtureStatus: TerminalSelectionFixtureStatus? = nil,
        holdDuration: TimeInterval = 0.15
    ) throws {
        let handle = handle(endpoint)
        try waitForElement(handle, timeout: 3, description: "\(endpoint) selection handle")
        let destination = try gridCoordinate(
            anchorNamed: anchorName,
            horizontalCellOffset: horizontalCellOffset,
            verticalCellOffset: verticalCellOffset,
            fixtureStatus: fixtureStatus
        )
        let origin = try centerCoordinate(of: handle, description: "\(endpoint) selection handle")
        try performGestureWithZeroTransitionRetry(
            description: "drag \(endpoint) handle to fixture anchor \(anchorName)",
            relevantElements: [handle, destination.probe]
        ) {
            origin.press(
                forDuration: holdDuration,
                thenDragTo: destination.coordinate,
                withVelocity: .slow,
                thenHoldForDuration: 0.2
            )
        }
    }

    func pressAndReleaseHandle(
        _ endpoint: TerminalSelectionHandleEndpoint,
        duration: TimeInterval = 0.2
    ) throws {
        let handle = handle(endpoint)
        try waitForElement(handle, timeout: 3, description: "\(endpoint) selection handle")
        let coordinate = try centerCoordinate(
            of: handle,
            description: "\(endpoint) selection handle"
        )
        // This gesture is intentionally a semantic no-op, so an unchanged
        // diagnostic token cannot distinguish success from dropped input.
        try performGesture(
            description: "stationary press/release on \(endpoint) selection handle",
            relevantElements: [handle]
        ) {
            coordinate.press(forDuration: duration)
        }
    }

    func backgroundAndReactivate(timeout: TimeInterval = 5) throws {
        guard app.state == .runningForeground else {
            throw fail("Cannot background terminal harness from app state \(app.state.rawValue)")
        }

        XCUIDevice.shared.press(.home)
        let backgroundDeadline = Date().addingTimeInterval(timeout)
        while Date() < backgroundDeadline {
            if app.state == .runningBackground || app.state == .runningBackgroundSuspended {
                break
            }
            spinRunLoop()
        }
        guard app.state == .runningBackground || app.state == .runningBackgroundSuspended else {
            throw fail("Terminal harness did not enter the background")
        }

        app.activate()
        let foregroundDeadline = Date().addingTimeInterval(timeout)
        while Date() < foregroundDeadline, app.state != .runningForeground {
            spinRunLoop()
        }
        guard app.state == .runningForeground else {
            throw fail("Terminal harness did not return to the foreground")
        }

        // UIKit can restore the edit-menu presentation one runloop after the app
        // becomes active even though the terminal has already dismissed its
        // handles. Dismiss that system-owned overlay through the published
        // nonterminal probe so the next terminal gesture cannot be intercepted.
        let fixtureProbe = exactDescendant(identifier: "terminal.selection.fixture")
        try waitForElement(
            fixtureProbe,
            timeout: timeout,
            description: "reactivated terminal fixture probe"
        )
        if !fixtureProbe.isHittable {
            fixtureProbe.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
            ).tap()
            let hittableDeadline = Date().addingTimeInterval(timeout)
            while Date() < hittableDeadline, !fixtureProbe.isHittable {
                spinRunLoop()
            }
            guard fixtureProbe.isHittable else {
                throw fail(
                    "System edit-menu overlay still intercepted the app after activation",
                    relevantElements: [fixtureProbe]
                )
            }
        }
    }

    func assertNoClientWrites(timeout: TimeInterval = 3) throws {
        let fixture = try waitForFixtureStatus(timeout: timeout) { _ in true }
        let transport = try waitForTransportStatus(timeout: timeout) { _ in true }
        try require(
            fixture.clientWriteHex.isEmpty,
            "Fixture status recorded unexpected client bytes: \(fixture.clientWriteHex)"
        )
        try require(
            transport.clientWriteHex.isEmpty,
            "Transport recorded unexpected client bytes: \(transport.clientWriteHex)"
        )
    }

    @discardableResult
    func waitForExactClientWrites(
        _ expected: Data,
        timeout: TimeInterval = 5
    ) throws -> TerminalSelectionTransportStatus {
        let expectedHex = expected.map { String(format: "%02x", $0) }.joined()
        let fixture = try waitForFixtureStatus(timeout: timeout) { status in
            status.clientWriteHex == expectedHex
        }
        let transport = try waitForTransportStatus(timeout: timeout) { status in
            status.clientWriteHex == expectedHex
        }
        try require(
            fixture.clientWriteHex == expectedHex,
            "Fixture client bytes did not exactly match \(expectedHex)"
        )
        return transport
    }

    func require(
        _ condition: @autoclosure () -> Bool,
        _ message: String,
        relevantElements: [XCUIElement] = []
    ) throws {
        guard condition() else {
            throw fail(message, relevantElements: relevantElements)
        }
    }

    func attachFailureDiagnostics(
        reason: String,
        relevantElements: [XCUIElement] = []
    ) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "terminal-selection-failure-screenshot"
        screenshot.lifetime = .keepAlways
        testCase.add(screenshot)

        attachString(
            currentAccessibilityValue(identifier: "terminal.selection.fixture"),
            name: "terminal-selection-fixture-status-json"
        )
        attachString(
            currentAccessibilityValue(identifier: "terminal.selection.state"),
            name: "terminal-selection-package-snapshot-json"
        )

        let transportJSON = currentAccessibilityValue(identifier: "terminal.selection.transport")
        attachString(transportJSON, name: "terminal-selection-transport-status-json")
        attachString(
            transportDiagnosticSummary(from: transportJSON),
            name: "terminal-selection-transport-ledger-client-write"
        )

        let elements = diagnosticElements() + relevantElements
        let frames = elements.enumerated().map { index, element in
            elementDiagnostic(element, index: index)
        }.joined(separator: "\n")
        attachString("reason: \(reason)\n\(frames)", name: "terminal-selection-element-frames")
        attachString(app.debugDescription, name: "terminal-selection-accessibility-hierarchy")
    }

    private struct GridCoordinate {
        let coordinate: XCUICoordinate
        let probe: XCUIElement
    }

    private func gridCoordinate(
        anchorNamed anchorName: String,
        horizontalCellOffset: Double = 0,
        verticalCellOffset: Double = 0,
        fixtureStatus explicitStatus: TerminalSelectionFixtureStatus?
    ) throws -> GridCoordinate {
        guard let status = explicitStatus ?? readyStatus,
              let fixture = status.fixture,
              let anchor = fixture.anchors[anchorName]
        else {
            throw fail("Fixture does not publish grid anchor '\(anchorName)'")
        }
        let snapshot = try waitForPackageSnapshot { snapshot in
            snapshot.gridReady
                && Int(snapshot.gridRows ?? 0) == fixture.rows
                && Int(snapshot.gridColumns ?? 0) == fixture.columns
        }
        guard let gridOrigin = snapshot.resolvedGridOrigin,
              let cellWidth = snapshot.cellWidthPoints,
              let cellHeight = snapshot.cellHeightPoints
        else {
            throw fail("Package state lacks resolved grid origin/cell dimensions")
        }

        let probe = exactDescendant(identifier: "terminal.selection.state")
        try waitForElement(probe, timeout: 3, description: "terminal selection debug probe")
        let probeFrame = probe.frame
        guard validScreenFrame(probeFrame) else {
            throw fail("Debug probe has invalid frame \(probeFrame)", relevantElements: [probe])
        }

        // The probe frame is the terminal viewport in screen coordinates, while
        // the package geometry is terminal-local. Remove the viewport's local
        // origin, then add the exact zero-based cell center.
        let xInProbe = gridOrigin.x - snapshot.terminalViewportBounds.x
            + (Double(anchor.column) + 0.5 + horizontalCellOffset) * cellWidth
        let yInProbe = gridOrigin.y - snapshot.terminalViewportBounds.y
            + (Double(anchor.row) + 0.5 + verticalCellOffset) * cellHeight
        guard xInProbe.isFinite,
              yInProbe.isFinite,
              xInProbe >= 0,
              yInProbe >= 0,
              xInProbe <= probeFrame.width,
              yInProbe <= probeFrame.height
        else {
            throw fail(
                "Anchor \(anchorName) resolves outside probe frame: local=(\(xInProbe), "
                    + "\(yInProbe)), probe=\(probeFrame)",
                relevantElements: [probe]
            )
        }

        let probeOrigin = probe.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        return GridCoordinate(
            coordinate: probeOrigin.withOffset(CGVector(dx: xInProbe, dy: yInProbe)),
            probe: probe
        )
    }

    private func centerCoordinate(
        of element: XCUIElement,
        description: String
    ) throws -> XCUICoordinate {
        let frame = element.frame
        guard validScreenFrame(frame) else {
            throw fail("\(description) has invalid frame \(frame)", relevantElements: [element])
        }
        return element.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0)).withOffset(
            CGVector(dx: frame.width / 2, dy: frame.height / 2)
        )
    }

    private struct GestureTransitionToken: Equatable {
        let generation: Int
        let snapshotRevision: UInt64
    }

    private func performGestureWithZeroTransitionRetry(
        description: String,
        relevantElements: [XCUIElement],
        gesture: () -> Void
    ) throws {
        let baseline = try currentGestureTransitionToken()

        do {
            try Self.gestureRetryPolicy.perform { attempt in
                if attempt > 1 {
                    XCTContext.runActivity(
                        named: "Retrying \(description) after zero diagnostic transition"
                    ) { _ in }
                }
                try performGesture(
                    description: description,
                    relevantElements: relevantElements,
                    gesture: gesture
                )
            } waitForTransition: { _ in
                try waitForGestureTransition(
                    from: baseline,
                    timeout: Self.gestureTransitionTimeout
                )
            }
        } catch let exhaustion as ZeroTransitionGestureRetryPolicy.Exhausted {
            throw fail(
                "\(description) caused no terminal diagnostic transition after "
                    + "\(exhaustion.attempts) attempts",
                relevantElements: relevantElements
            )
        }
    }

    private func currentGestureTransitionToken() throws -> GestureTransitionToken {
        let status: TerminalSelectionFixtureStatus = try waitForDecodedValue(
            identifier: "terminal.selection.fixture",
            description: "gesture transition baseline",
            timeout: 3,
            validate: validateFixtureStatus
        ) { status in
            status.latestPackageSnapshot != nil
        }
        guard let token = gestureTransitionToken(from: status) else {
            throw fail("Terminal fixture did not publish a gesture transition token")
        }
        return token
    }

    private func waitForGestureTransition(
        from baseline: GestureTransitionToken,
        timeout: TimeInterval
    ) throws -> Bool {
        let fixture = exactDescendant(identifier: "terminal.selection.fixture")
        let deadline = Date().addingTimeInterval(timeout)
        var observedValidToken = false

        while Date() < deadline {
            if fixture.exists,
               let status: TerminalSelectionFixtureStatus = try? decodeAccessibilityJSON(
                   from: fixture
               ),
               validateFixtureStatus(status) == nil {
                if status.phase == .failed {
                    return true
                }
                if let current = gestureTransitionToken(from: status) {
                    observedValidToken = true
                    if current != baseline {
                        return true
                    }
                }
            }
            spinRunLoop()
        }

        guard observedValidToken else {
            throw fail(
                "Could not read a valid terminal gesture transition token",
                relevantElements: [fixture]
            )
        }
        return false
    }

    private func gestureTransitionToken(
        from status: TerminalSelectionFixtureStatus
    ) -> GestureTransitionToken? {
        guard let snapshot = status.latestPackageSnapshot else { return nil }
        return GestureTransitionToken(
            generation: status.generation,
            snapshotRevision: snapshot.revision
        )
    }

    private func performGesture(
        description: String,
        relevantElements: [XCUIElement],
        gesture: () -> Void
    ) throws {
        guard app.state == .runningForeground else {
            throw fail(
                "Cannot perform \(description): app state is \(app.state.rawValue)",
                relevantElements: relevantElements
            )
        }
        gesture()
    }

    private func waitForElement(
        _ element: XCUIElement,
        timeout: TimeInterval,
        description: String
    ) throws {
        guard element.waitForExistence(timeout: timeout) else {
            throw fail(
                "Timed out waiting for \(description)",
                relevantElements: [element]
            )
        }
    }

    private func waitForDecodedValue<Value: Decodable>(
        identifier: String,
        description: String,
        timeout: TimeInterval,
        validate: (Value) -> String?,
        predicate: @escaping (Value) -> Bool
    ) throws -> Value {
        let element = exactDescendant(identifier: identifier)
        let deadline = Date().addingTimeInterval(timeout)
        var lastProblem = "element did not exist"
        var latestValue: Value?

        while Date() < deadline {
            if element.exists {
                do {
                    let value: Value = try decodeAccessibilityJSON(from: element)
                    latestValue = value
                    if let validationFailure = validate(value) {
                        lastProblem = "schema validation failed: \(validationFailure)"
                    } else if let fixtureStatus = value as? TerminalSelectionFixtureStatus,
                              fixtureStatus.phase == .failed {
                        throw fail(
                            "App fixture entered failed phase: \(fixtureStatus.error ?? "unknown error")",
                            relevantElements: [element]
                        )
                    } else if predicate(value) {
                        return value
                    } else {
                        lastProblem = "latest decoded value did not satisfy predicate"
                    }
                } catch let error as TerminalSelectionUITestHarnessError {
                    throw error
                } catch {
                    lastProblem = error.localizedDescription
                }
            }
            spinRunLoop()
        }

        if let latestValue,
           validate(latestValue) == nil,
           predicate(latestValue) {
            return latestValue
        }
        throw fail(
            "Timed out waiting for \(description): \(lastProblem)",
            relevantElements: [element]
        )
    }

    private func decodeAccessibilityJSON<Value: Decodable>(
        from element: XCUIElement
    ) throws -> Value {
        guard let json = element.value as? String, !json.isEmpty else {
            throw TerminalSelectionUITestHarnessError(
                message: "\(element.identifier) has no string accessibility value"
            )
        }
        guard json.utf8.count <= Self.maximumJSONBytes else {
            throw TerminalSelectionUITestHarnessError(
                message: "\(element.identifier) JSON exceeds \(Self.maximumJSONBytes) bytes"
            )
        }
        guard let data = json.data(using: .utf8) else {
            throw TerminalSelectionUITestHarnessError(
                message: "\(element.identifier) accessibility value is not UTF-8"
            )
        }
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw TerminalSelectionUITestHarnessError(
                message: "Could not decode \(element.identifier) JSON: \(error)"
            )
        }
    }

    private func validateFixtureStatus(_ status: TerminalSelectionFixtureStatus) -> String? {
        guard status.schemaVersion == Self.schemaVersion else {
            return "fixture schemaVersion \(status.schemaVersion), expected \(Self.schemaVersion)"
        }
        guard status.generation > 0 else { return "generation must be positive" }
        guard status.clientWriteHex.isValidLowercaseHex else {
            return "fixture clientWriteHex is malformed"
        }
        guard Set(status.generationLatches.map(\.generation)).count
            == status.generationLatches.count
        else { return "generation latches contain duplicate generations" }
        if let fixture = status.fixture, let error = validateFixture(fixture) {
            return error
        }
        if let snapshot = status.triggeringSnapshot, let error = validateSnapshot(snapshot) {
            return "triggering snapshot: \(error)"
        }
        if let snapshot = status.latestPackageSnapshot, let error = validateSnapshot(snapshot) {
            return "latest package snapshot: \(error)"
        }
        if let rows = status.actualRows,
           !(1...Self.maximumGridDimension).contains(rows) {
            return "actualRows \(rows) is outside the accepted bounds"
        }
        if let columns = status.actualColumns,
           !(1...Self.maximumGridDimension).contains(columns) {
            return "actualColumns \(columns) is outside the accepted bounds"
        }
        return nil
    }

    private func validateFixture(_ fixture: TerminalSelectionFixture) -> String? {
        guard (1...Self.maximumGridDimension).contains(fixture.rows),
              (1...Self.maximumGridDimension).contains(fixture.columns)
        else { return "fixture grid dimensions are outside accepted bounds" }
        guard fixture.fixtureRow >= 0, fixture.fixtureRow < fixture.rows else {
            return "fixtureRow \(fixture.fixtureRow) is outside the grid"
        }
        guard !fixture.anchors.isEmpty, fixture.anchors.count <= 128 else {
            return "fixture anchor count is outside 1...128"
        }
        for (name, anchor) in fixture.anchors {
            guard !name.isEmpty,
                  anchor.column >= 0,
                  anchor.column < fixture.columns,
                  anchor.row >= 0,
                  anchor.row < fixture.rows
            else { return "fixture anchor '\(name)' is outside the grid" }
        }
        guard !fixture.expectedStrings.isEmpty, fixture.expectedStrings.count <= 128 else {
            return "fixture expected-string count is outside 1...128"
        }
        guard fixture.expectedStrings.allSatisfy({
            !$0.key.isEmpty && !$0.value.isEmpty && $0.value.utf8.count <= 4_096
        }) else { return "fixture contains an invalid expected string" }
        return nil
    }

    private func validateSnapshot(_ snapshot: TerminalSelectionDebugSnapshot) -> String? {
        guard snapshot.schemaVersion == Self.schemaVersion else {
            return "snapshot schemaVersion \(snapshot.schemaVersion), expected \(Self.schemaVersion)"
        }
        guard snapshot.revision > 0 else { return "snapshot revision must be positive" }
        for (name, rect) in [
            ("terminalBounds", snapshot.terminalBounds),
            ("terminalViewportBounds", snapshot.terminalViewportBounds),
        ] {
            guard rect.isFinite, rect.width >= 0, rect.height >= 0 else {
                return "\(name) is invalid"
            }
        }
        for (name, rect) in [
            ("startHandleFrame", snapshot.startHandleFrame),
            ("endHandleFrame", snapshot.endHandleFrame),
            ("loupeFrame", snapshot.loupeFrame),
        ] {
            if let rect, (!rect.isFinite || rect.width < 0 || rect.height < 0) {
                return "\(name) is invalid"
            }
        }
        for (name, point) in [
            ("displayStartEndpoint", snapshot.displayStartEndpoint),
            ("displayEndEndpoint", snapshot.displayEndEndpoint),
            ("mouseStartEndpoint", snapshot.mouseStartEndpoint),
            ("mouseEndEndpoint", snapshot.mouseEndEndpoint),
            ("resolvedGridOrigin", snapshot.resolvedGridOrigin),
        ] {
            if let point, (!point.x.isFinite || !point.y.isFinite) {
                return "\(name) is invalid"
            }
        }
        if snapshot.gridReady {
            guard snapshot.surfaceReady,
                  let columns = snapshot.gridColumns,
                  columns > 0,
                  Int(columns) <= Self.maximumGridDimension,
                  let rows = snapshot.gridRows,
                  rows > 0,
                  Int(rows) <= Self.maximumGridDimension,
                  snapshot.resolvedGridOrigin != nil,
                  let cellWidth = snapshot.cellWidthPoints,
                  cellWidth.isFinite,
                  cellWidth > 0,
                  let cellHeight = snapshot.cellHeightPoints,
                  cellHeight.isFinite,
                  cellHeight > 0,
                  let scale = snapshot.displayScale,
                  scale.isFinite,
                  scale > 0
            else { return "gridReady snapshot lacks valid grid geometry" }
        }
        return nil
    }

    private func validateTransportStatus(_ status: TerminalSelectionTransportStatus) -> String? {
        guard status.schemaVersion == Self.schemaVersion else {
            return "transport schemaVersion \(status.schemaVersion), expected \(Self.schemaVersion)"
        }
        guard status.activeChannelCount >= 0,
              status.pendingCallbackCount >= 0,
              status.pendingRequestCount >= 0
        else { return "transport counts must not be negative" }
        guard status.clientWriteHex.isValidLowercaseHex else {
            return "transport clientWriteHex is malformed"
        }
        guard status.ledger.count <= 100_000 else { return "transport ledger is unbounded" }
        return nil
    }

    private func validScreenFrame(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite
            && frame.origin.y.isFinite
            && frame.width.isFinite
            && frame.height.isFinite
            && frame.width > 0
            && frame.height > 0
    }

    private func fail(
        _ message: String,
        relevantElements: [XCUIElement] = []
    ) -> TerminalSelectionUITestHarnessError {
        attachFailureDiagnostics(reason: message, relevantElements: relevantElements)
        return TerminalSelectionUITestHarnessError(message: message)
    }

    private func currentAccessibilityValue(identifier: String) -> String {
        let element = exactDescendant(identifier: identifier)
        guard element.exists else { return "<missing \(identifier)>" }
        return element.value as? String ?? "<non-string value: \(String(describing: element.value))>"
    }

    private func transportDiagnosticSummary(from json: String) -> String {
        guard let data = json.data(using: .utf8),
              let status = try? JSONDecoder().decode(TerminalSelectionTransportStatus.self, from: data)
        else { return "Unable to decode transport status. Raw JSON is attached separately." }
        return "clientWriteHex: \(status.clientWriteHex)\nledger:\n\(status.ledger.joined(separator: "\n"))"
    }

    private func diagnosticElements() -> [XCUIElement] {
        var elements = [
            exactDescendant(identifier: "terminal.selection.fixture"),
            exactDescendant(identifier: "terminal.selection.state"),
            exactDescendant(identifier: "terminal.selection.transport"),
            exactDescendant(identifier: "terminal.selection.resetObservations"),
            handle(.start),
            handle(.end),
        ]
        elements.append(app.buttons.matching(
            NSPredicate(format: "identifier == %@", "Copy")
        ).firstMatch)
        elements.append(app.menuItems.matching(
            NSPredicate(format: "identifier == %@", "Copy")
        ).firstMatch)
        elements.append(app.buttons.matching(
            NSPredicate(format: "identifier == %@", "Paste")
        ).firstMatch)
        elements.append(app.menuItems.matching(
            NSPredicate(format: "identifier == %@", "Paste")
        ).firstMatch)
        return elements
    }

    private func elementDiagnostic(_ element: XCUIElement, index: Int) -> String {
        guard element.exists else {
            // Reading elementType, identifier, label, or frame from an unmatched
            // firstMatch records a new XCTest failure and can hide the original.
            return "element[\(index)] exists=false query=\(String(describing: element))"
        }
        return "element[\(index)] type=\(element.elementType.rawValue) "
            + "identifier=\(element.identifier.debugDescription) "
            + "label=\(element.label.debugDescription) exists=true "
            + "hittable=\(element.isHittable) frame=\(element.frame)"
    }

    private func attachString(_ string: String, name: String) {
        let attachment = XCTAttachment(string: string)
        attachment.name = name
        attachment.lifetime = .keepAlways
        testCase.add(attachment)
    }

    private func spinRunLoop() {
        RunLoop.current.run(until: Date().addingTimeInterval(Self.pollInterval))
    }
}

private extension TerminalSelectionDebugRect {
    var isFinite: Bool {
        x.isFinite && y.isFinite && width.isFinite && height.isFinite
    }
}

private extension String {
    var isValidLowercaseHex: Bool {
        count.isMultiple(of: 2) && unicodeScalars.allSatisfy {
            ("0"..."9").contains(Character($0)) || ("a"..."f").contains(Character($0))
        }
    }
}
