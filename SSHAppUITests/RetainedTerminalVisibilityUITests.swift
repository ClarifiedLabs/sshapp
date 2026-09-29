import UIKit
import Vision
import XCTest

/// Strict network-free reproducer, not an expected failure or an AX workaround.
/// Keep the unfiltered hittable TextView count even if native flags are correct.
@MainActor
final class RetainedTerminalVisibilityUITests: XCTestCase {
    private let alphaTop = "retained.terminal.alpha.top"
    private let alphaBottom = "retained.terminal.alpha.bottom"
    private let bravo = "retained.terminal.bravo"

    func testRetainedTmuxHostsExposeOnlyVisibleTextViews() throws {
        try exerciseRetainedHosts(softwareKeyboard: false)
    }

    func testVisibleKeyboardDoesNotPreventSwitchingRetainedSplitFocus() throws {
        try exerciseRetainedHosts(softwareKeyboard: true)
    }

    func testPaneScreenshotCoordinatesFollowBothLandscapeOrientations() throws {
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launchArguments += ["--sshapp-in-memory-store", "--sshapp-ui-test-retained-terminal-visibility"]
        UITestDeviceHealth.launch(app, for: self)
        // Rotates back to portrait while foreground, then terminates and settles.
        defer { DeviceOrientationSettle.restorePortraitAndTerminate(app) }
        XCTAssertTrue(app.staticTexts["retained.native.status"].waitForExistence(timeout: 10))
        let harness = LiveSSHUITestHarness(testCase: self)
        let status = app.staticTexts["retained.native.status"]
        for orientation: UIDeviceOrientation in [.portrait, .landscapeLeft, .landscapeRight, .portrait] {
            DeviceOrientationSettle.request(orientation)
            let landscape = orientation.isLandscape
            // UIDevice and UIWindowScene use opposite landscape naming.
            let expectedInterface: UIInterfaceOrientation = orientation == .landscapeLeft
                ? .landscapeRight : (orientation == .landscapeRight ? .landscapeLeft : .portrait)
            var previousFrames: [CGRect] = []
            var stableSince = Date()
            let settled = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
                let frame = app.frame
                let panes = app.textViews.allElementsBoundByIndex.filter(\.isHittable)
                let frames = panes.map(\.frame)
                if frames != previousFrames {
                    previousFrames = frames
                    stableSince = Date()
                }
                return (try? readState(status).interfaceOrientation) == expectedInterface.rawValue
                    && (frame.width > frame.height) == landscape && panes.count == 2
                    && Date().timeIntervalSince(stableSince) >= 0.5
            }, object: app)
            XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 10), .completed)
            let appImage = app.screenshot().image
            let screenImage = XCUIScreen.main.screenshot().image
            attach("device=\(orientation.rawValue); appFrame=\(app.frame); appImage=\(appImage.size) scale=\(appImage.scale) orientation=\(appImage.imageOrientation.rawValue) pixels=\(appImage.cgImage?.width ?? 0)x\(appImage.cgImage?.height ?? 0); screenImage=\(screenImage.size) scale=\(screenImage.scale) orientation=\(screenImage.imageOrientation.rawValue) pixels=\(screenImage.cgImage?.width ?? 0)x\(screenImage.cgImage?.height ?? 0)", name: "orientation-\(orientation.rawValue)-capture-metadata")
            for (identifier, expected, forbidden) in [(alphaTop, "AMBERORCHARD", "COPPERMEADOW"),
                                                       (alphaBottom, "COPPERMEADOW", "AMBERORCHARD")] {
                let pane = app.textViews[identifier]
                let text = try harness.recognizedScreenText(inPane: pane)
                    .filter { !$0.isWhitespace }.uppercased()
                let matches = text.contains(expected) && !text.contains(forbidden)
                harness.recordScreen(name: "orientation-\(orientation.rawValue)-\(identifier)" + (matches ? "" : "-timeout"),
                                     recognizedText: text)
                XCTAssertTrue(text.contains(expected), "Own pane marker missing: \(text)")
                XCTAssertFalse(text.contains(forbidden), "Neighbor marker entered pane crop: \(text)")
            }
        }
    }

    private func exerciseRetainedHosts(softwareKeyboard: Bool) throws {
        // Collect ALL three checkpoints even when the initial AX gate fails.
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launchArguments += ["--sshapp-in-memory-store", "--sshapp-ui-test-retained-terminal-visibility"]
        if softwareKeyboard { app.launchArguments.append("--sshapp-ui-test-retained-terminal-keyboard") }
        UITestDeviceHealth.launch(app, for: self)
        defer { UITestDeviceHealth.terminate(app) }
        let status = app.staticTexts["retained.native.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        if softwareKeyboard { XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10)) }

        let initial = try checkpoint("initial-Alpha", group: "Alpha", visibleIDs: [alphaTop, alphaBottom],
                                     app: app, status: status)
        for cycle in 1...3 {
            try tapSplit(alphaBottom, previous: readState(status), app: app, status: status)
            if softwareKeyboard { XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10)) }
            app.buttons["retained.switch.Bravo"].tap()
            let switched = try checkpoint("retained-Bravo-\(cycle)", group: "Bravo", visibleIDs: [bravo],
                                          app: app, status: status)
            app.buttons["retained.switch.Alpha"].tap()
            let returned = try checkpoint("returned-Alpha-\(cycle)", group: "Alpha", visibleIDs: [alphaTop, alphaBottom],
                                          app: app, status: status)
            try tapSplit(alphaTop, previous: returned, app: app, status: status)
            if softwareKeyboard { XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10)) }
            for state in [switched, returned] {
                XCTAssertEqual(state.hosts.count, initial.hosts.count)
                for host in initial.hosts {
                    XCTAssertEqual(state.hosts.first { $0.id == host.id }?.hostID, host.hostID,
                                   "Switching must retain the same UIKit host for \(host.id)")
                }
            }
        }
    }

    private struct NativeState: Decodable {
        let activeGroup: String
        let interfaceOrientation: Int
        let logicalFocusedID: String
        let hostCount: Int
        let visibleHostCount: Int
        let firstResponderCount: Int
        let focusCount: Int
        let focusSourceHostID: String
        let hosts: [Host]
    }

    private struct Host: Decodable {
        let id: String
        let hostID: String
        let isHostVisible: Bool
        let isHidden: Bool
        let isFirstResponder: Bool
        let canBecomeFirstResponder: Bool
        let accessibilityElementsHidden: Bool
        let x: Double, y: Double, width: Double, height: Double
    }

    private func readState(_ status: XCUIElement) throws -> NativeState {
        let value = try XCTUnwrap(status.value as? String)
        return try JSONDecoder().decode(NativeState.self, from: Data(value.utf8))
    }

    private func waitForState(_ status: XCUIElement,
                              matching predicate: @escaping (NativeState) -> Bool) throws -> NativeState {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            guard let state = try? readState(status) else { return false }
            return predicate(state)
        }, object: status)
        let result = XCTWaiter.wait(for: [expectation], timeout: 10)
        XCTAssertEqual(result, .completed, "Native state did not settle: \(status.value ?? "missing")")
        return try readState(status)
    }

    private func checkpoint(_ name: String, group: String, visibleIDs: Set<String>,
                            app: XCUIApplication, status: XCUIElement) throws -> NativeState {
        let state = try waitForState(status) { state in
            state.activeGroup == group && state.hostCount == 3 && state.hosts.count == 3
                && state.firstResponderCount == 1 && state.visibleHostCount == visibleIDs.count
                && state.hosts.allSatisfy { host in
                    let visible = visibleIDs.contains(host.id)
                    return host.isHostVisible == visible && host.isHidden == !visible
                        && host.canBecomeFirstResponder == visible
                        && host.accessibilityElementsHidden == !visible
                        && host.isFirstResponder == (host.id == state.logicalFocusedID)
                }
        }
        attach("\(status.value ?? "missing")", name: "\(name)-native-flags")
        XCTAssertEqual(Set(state.hosts.map(\.id)), [alphaTop, alphaBottom, bravo])
        XCTAssertEqual(Set(state.hosts.filter(\.isHostVisible).map(\.id)), visibleIDs)
        try verifyPixels(name, group: group, app: app)

        // DO NOT filter by identifier first: unexpected stale/duplicate proxy
        // TextViews are precisely the regression this fixture must expose.
        let visibleTextViews = app.textViews.allElementsBoundByIndex.filter(\.isHittable)
        XCTAssertEqual(visibleTextViews.count, visibleIDs.count,
                       "\(name): strict visible TextView count must be \(visibleIDs.count)")
        XCTAssertEqual(Set(visibleTextViews.map(\.identifier)), visibleIDs)
        let markers = [alphaTop: "AMBERORCHARD", alphaBottom: "COPPERMEADOW", bravo: "VIOLETHARBOR"]
        let harness = LiveSSHUITestHarness(testCase: self)
        for pane in visibleTextViews {
            let text = try harness.recognizedScreenText(inPane: pane)
                .filter { !$0.isWhitespace }.uppercased()
            XCTAssertTrue(text.contains(try XCTUnwrap(markers[pane.identifier])),
                          "\(name): composited pane crop must contain its own marker")
            for (identifier, marker) in markers where identifier != pane.identifier {
                XCTAssertFalse(text.contains(marker), "Pane crop must not include another pane's marker")
            }
        }
        attach(app.debugDescription, name: "\(name)-accessibility-tree")
        return state
    }

    private func tapSplit(_ identifier: String, previous: NativeState,
                          app: XCUIApplication, status: XCUIElement) throws {
        let host = try XCTUnwrap(previous.hosts.first { $0.id == identifier })
        XCTAssertFalse(host.isFirstResponder, "Tap must exercise a visible NONfocused split")
        XCTAssertTrue(host.isHostVisible)
        XCTAssertGreaterThan(host.width, 0)
        XCTAssertGreaterThan(host.height, 0)
        // A real coordinate tap, not element.tap(), becomeFirstResponder(), or
        // an action that could bypass native hit testing through a stale proxy.
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
            dx: host.x + host.width / 2 - app.frame.minX,
            dy: host.y + host.height / 2 - app.frame.minY)).tap()
        let focused = try waitForState(status) { state in
            state.focusCount > previous.focusCount && state.logicalFocusedID == identifier
                && state.focusSourceHostID == host.hostID && state.firstResponderCount == 1
                && state.hosts.first { $0.id == identifier }?.isFirstResponder == true
        }
        XCTAssertEqual(focused.focusSourceHostID, host.hostID)
        attach("\(status.value ?? "missing")", name: "tap-\(identifier)-native-focus")
    }

    private func verifyPixels(_ name: String, group: String, app: XCUIApplication) throws {
        let expected = group == "Alpha" ? ["AMBERORCHARD", "COPPERMEADOW"] : ["VIOLETHARBOR"]
        let forbidden = group == "Alpha" ? ["VIOLETHARBOR"] : ["AMBERORCHARD", "COPPERMEADOW"]
        let deadline = Date().addingTimeInterval(5)
        var text = ""
        var screenshot = app.screenshot()
        repeat {
            screenshot = app.screenshot()
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: XCTUnwrap(screenshot.image.cgImage)).perform([request])
            text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            let normalized = text.filter { !$0.isWhitespace }.uppercased()
            if expected.allSatisfy({ normalized.contains($0) })
                && forbidden.allSatisfy({ !normalized.contains($0) }) { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        let pixels = XCTAttachment(screenshot: screenshot)
        pixels.name = "\(name)-visible-pixels"
        pixels.lifetime = .keepAlways
        add(pixels)
        attach(text, name: "\(name)-ocr")
        let normalized = text.filter { !$0.isWhitespace }.uppercased()
        for marker in expected { XCTAssertTrue(normalized.contains(marker), "\(name): missing visible \(marker); OCR: \(text)") }
        for marker in forbidden { XCTAssertFalse(normalized.contains(marker), "\(name): hidden \(marker) rendered") }
    }

    private func attach(_ text: String, name: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
