import UIKit
import XCTest

/// Production SSH/tmux acceptance, not a replay or a test-host terminal fixture.
/// Requires SSHAPP_LIVE_SSH_ENABLE_DEFAULT_TMUX=1 plus the live SSH environment.
/// This existing runner-forwarded opt-in uses a unique owned session, not the default session.
@MainActor
final class LiveTmuxAcceptanceUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        // XCTest teardown runs even when a UI interaction aborts the test.
        // Only a device that is not portrait already is rotated back.
        addTeardownBlock { @MainActor in
            DeviceOrientationSettle.normalizePortrait()
        }
    }

    func testLiveTmuxRetainsHiddenPanesAcrossResizeAndBackground() throws {
        let configuration = try LiveSSHTestConfiguration.fromEnvironment()
        guard configuration.enableDefaultTmuxStartup else {
            throw XCTSkip("Set SSHAPP_LIVE_SSH_ENABLE_DEFAULT_TMUX=1 to opt in to live tmux acceptance.")
        }
        let fixture = LiveTmuxFixture()
        let harness = LiveSSHUITestHarness(testCase: self)
        // Throwing assertions below preserve defer cleanup on ordinary failures.
        continueAfterFailure = true
        harness.launch()
        var attached = false
        var cleanupAttempted = false
        defer {
            if attached && !cleanupAttempted {
                // One attempt only. The startup shell also owns an EXIT/HUP trap;
                // loss of the transport can still leave this unique session behind.
                do { try harness.sendCommand(fixture.cleanupCommand) }
                catch { XCTFail("Could not submit owned-session cleanup; transport may be unavailable.") }
            }
            // Rotate back while the app is foreground, then terminate and settle.
            DeviceOrientationSettle.restorePortraitAndTerminate(harness.app)
            harness.terminate()
        }

        try harness.createConnectionAndAuthenticate(
            using: configuration, startupCommand: fixture.startupCommand
        )
        try wait(timeout: configuration.connectionTimeout, message: "Production tmux did not attach") {
            (try? harness.tmuxWindowTabs().count) == 1
        }
        attached = true
        try harness.sendCommand(fixture.setupCommand)
        try harness.assertScreen(containsExactPhrase: ["SETUP", "READY", "0001"], attachmentName: "live-tmux-setup")
        try wait(message: "Expected two production tmux windows") {
            (try? harness.tmuxWindowTabs().count) == 2
        }
        let alpha = try window(named: "Alpha", harness: harness)
        let bravo = try window(named: "Bravo", harness: harness)

        // Seed independently identifiable history in both split panes.
        for (index, name) in [(0, "TOP"), (1, "BOTTOM")] {
            let point = try pane(index, count: 2, harness: harness)
            try harness.sendCommand(fixture.marker("ALPHA", name, "HISTORY", number: 1), to: point)
            try harness.assertScreen(
                containsExactPhrase: ["ALPHA", name, "HISTORY", "0001"],
                inPane: pane(index, count: 2, harness: harness),
                attachmentName: "live-tmux-seed-\(name.lowercased())"
            )
        }

        bravo.tap()
        let bravoPoint = try pane(0, count: 1, harness: harness)
        try harness.sendCommand(fixture.marker("BRAVO", "ONLY", "HISTORY", number: 1), to: bravoPoint)
        try harness.assertScreen(
            containsExactPhrase: ["BRAVO", "ONLY", "HISTORY", "0001"],
            attachmentName: "live-tmux-bravo-seed"
        )
        // Both Alpha panes are unmounted/hidden before these bounded batches run.
        // No sleeps, background jobs, files, or persistent producers on the host.
        try harness.sendCommand(fixture.hiddenAlphaOutputCommand)
        try harness.assertScreen(containsExactPhrase: ["HIDDEN", "QUEUED", "0001"], attachmentName: "live-tmux-hidden-output")
        alpha.tap()
        for (index, name) in [(0, "TOP"), (1, "BOTTOM")] {
            let point = try pane(index, count: 2, harness: harness)
            try harness.assertScreen(
                containsExactPhrase: ["ALPHA", name, "LINE", "0032"], inPane: point,
                attachmentName: "live-tmux-hidden-progress-\(name.lowercased())"
            )
            try harness.revealScrollback(
                containingExactPhrase: ["ALPHA", name, "HISTORY", "0001"],
                inPane: point, attempts: 24,
                attachmentName: "live-tmux-retained-history-\(name.lowercased())"
            )
        }

        // Actual production keyboard/paste routing must target the bottom pane.
        let bottom = try pane(1, count: 2, harness: harness)
        try harness.sendCommand(fixture.marker("TARGET", "BOTTOM", "INPUT", number: 2), to: bottom)
        try harness.assertScreen(
            containsExactPhrase: ["TARGET", "BOTTOM", "INPUT", "0002"],
            inPane: pane(1, count: 2, harness: harness),
            attachmentName: "live-tmux-targeted-input"
        )
        let topText = try harness.recognizedScreenText(inPane: pane(0, count: 2, harness: harness))
        XCTAssertFalse(topText.contains("TARGET BOTTOM INPUT"), "Bottom-pane input leaked into the top pane")

        // Drive Bravo while hidden as well, then verify its new output on return.
        try harness.sendCommand(
            fixture.hiddenBravoOutputCommand, to: pane(1, count: 2, harness: harness)
        )
        bravo.tap()
        try harness.assertScreen(
            containsExactPhrase: ["BRAVO", "ONLY", "LINE", "0032"], attachmentName: "live-tmux-bravo-progress"
        )
        try harness.revealScrollback(
            containingExactPhrase: ["BRAVO", "ONLY", "HISTORY", "0001"],
            inPane: pane(0, count: 1, harness: harness), attempts: 24,
            attachmentName: "live-tmux-bravo-retained-history"
        )
        alpha.tap()

        let portraitColumns = try remoteColumns(label: "PORTRAIT", harness: harness)
        let before = try visiblePaneFrames(count: 2, harness: harness)
        DeviceOrientationSettle.request(.landscapeLeft)
        try wait(message: "Rotation did not resize production pane views") {
            let frames = harness.app.textViews.allElementsBoundByIndex.filter(\.isHittable).map(\.frame)
            return frames.count == 2 && frames.contains { frame in
                abs(frame.width - before[0].width) > 20
            }
        }
        let landscapeColumns = try remoteColumns(label: "LANDSCAPE", harness: harness)
        guard landscapeColumns != portraitColumns else {
            throw failure("Remote tmux pane columns did not change after rotation")
        }
        let landscapeBottom = try pane(1, count: 2, harness: harness)
        try harness.sendCommand(fixture.marker("RESIZE", "BOTTOM", "ROUNDTRIP", number: 3), to: landscapeBottom)
        try harness.assertScreen(
            containsExactPhrase: ["RESIZE", "BOTTOM", "ROUNDTRIP", "0003"],
            inPane: pane(1, count: 2, harness: harness),
            attachmentName: "live-tmux-rotation-round-trip"
        )
        DeviceOrientationSettle.request(.portrait)
        try wait(message: "Portrait geometry was not restored") {
            harness.app.windows.firstMatch.frame.height > harness.app.windows.firstMatch.frame.width
        }

        // Settings is a real second application; Home is ignored by some simulators.
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.activate()
        try wait(message: "SSHApp did not actually enter background") {
            harness.app.state == .runningBackground || harness.app.state == .runningBackgroundSuspended
        }
        harness.app.activate()
        try wait(message: "SSHApp did not reactivate") { harness.app.state == .runningForeground }
        try harness.assertScreen(
            containsExactPhrase: ["RESIZE", "BOTTOM", "ROUNDTRIP", "0003"],
            attachmentName: "live-tmux-retained-after-background"
        )
        try harness.sendCommand(
            fixture.marker("RESUME", "BOTTOM", "ROUNDTRIP", number: 4),
            to: pane(1, count: 2, harness: harness)
        )
        try harness.assertScreen(
            containsExactPhrase: ["RESUME", "BOTTOM", "ROUNDTRIP", "0004"],
            inPane: pane(1, count: 2, harness: harness), attachmentName: "live-tmux-reactivated-round-trip"
        )
        bravo.tap()
        try harness.sendCommand(fixture.marker("FINAL", "BRAVO", "ROUNDTRIP", number: 5))
        try harness.assertScreen(
            containsExactPhrase: ["FINAL", "BRAVO", "ROUNDTRIP", "0005"],
            attachmentName: "live-tmux-final-window-return"
        )

        // Submit once, then verify control-mode UI disappears. Never kill-server.
        cleanupAttempted = true
        try harness.sendCommand(fixture.cleanupCommand)
        try wait(message: "Owned tmux session did not exit after cleanup") {
            (try? harness.tmuxWindowTabs().isEmpty) == true
        }
    }

    /// Exercises the production editor and exact live fixture without any network
    /// submission, authentication simulation, or live-environment credentials.
    func testStartupCommandReplacesDefaultWithExactQuotedFixtureWithoutNetwork() throws {
        try assertExactStartupFixtureWithoutNetwork(orientation: .portrait)
    }

    func testStartupCommandReplacesDefaultWithExactQuotedFixtureWithoutNetworkInLandscape() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("Landscape startup-form regression requires iPad.")
        }
        try assertExactStartupFixtureWithoutNetwork(orientation: .landscapeLeft)
    }

    private func assertExactStartupFixtureWithoutNetwork(orientation: UIDeviceOrientation) throws {
        continueAfterFailure = true
        let harness = LiveSSHUITestHarness(testCase: self)
        harness.launch()
        defer {
            // Rotate back while the app is foreground, then terminate and settle.
            DeviceOrientationSettle.restorePortraitAndTerminate(harness.app)
            harness.terminate()
        }
        // Rotate only once the app is foreground, never while SpringBoard is launching it.
        DeviceOrientationSettle.request(orientation)
        try wait(message: "Startup form did not reach the requested orientation") {
            let frame = harness.app.windows.firstMatch.frame
            return orientation.isLandscape ? frame.width > frame.height : frame.height > frame.width
        }

        let command = LiveTmuxFixture().startupCommand
        XCTAssertGreaterThan(command.count, 300)
        XCTAssertTrue(command.contains("'"))
        XCTAssertTrue(command.contains("\""))
        try harness.prepareConnectionForm(using: LiveSSHTestConfiguration(
            destination: "demo@example.test", password: nil,
            acceptUnknownHost: false, credentialPersistence: .decline,
            enableDefaultTmuxStartup: true, connectionTimeout: 5
        ), startupCommand: command)
        try harness.assertStartupCommandEquals(command)
        // The destination row can leave the iPad list's accessibility window
        // after scrolling the editor into view; the sheet must still be open.
        XCTAssertTrue(harness.app.navigationBars["New Connection"].exists)
        XCTAssertTrue(harness.app.buttons["connection.connect"].exists)
        XCTAssertFalse(harness.app.buttons["connection.pill"].exists)
        // Never tap Save or Connect: form preparation is the entire regression.
    }

    private func remoteColumns(label: String, harness: LiveSSHUITestHarness) throws -> Int {
        // stty reads this pane's real remote PTY, not the local view's frame.
        // The echoed format contains %s, so it cannot satisfy the numeric match.
        try harness.sendCommand(
            "set -- $(stty size); printf '\\n\(label) COLUMNS %s\\n' \"$2\"",
            to: pane(1, count: 2, harness: harness)
        )
        var columns: Int?
        try wait(message: "Could not observe remote \(label.lowercased()) pane columns") {
            guard let text = try? harness.recognizedScreenText(),
                  let range = text.range(of: "\(label) COLUMNS [0-9]+", options: .regularExpression),
                  let number = text[range].split(separator: " ").last else { return false }
            columns = Int(number)
            return (columns ?? 0) > 0
        }
        return columns!
    }

    private func window(named name: String, harness: LiveSSHUITestHarness) throws -> XCUIElement {
        let tabs = try harness.tmuxWindowTabs(expectedCount: 2)
        guard let tab = tabs.first(where: { $0.label.contains(name) }) else {
            throw failure("Missing named production tmux window \(name)")
        }
        return tab
    }

    private func visiblePaneFrames(count: Int, harness: LiveSSHUITestHarness) throws -> [CGRect] {
        try visiblePanes(count: count, harness: harness).map(\.frame)
    }

    private func visiblePanes(count: Int, harness: LiveSSHUITestHarness) throws -> [XCUIElement] {
        var panes: [XCUIElement] = []
        var previousFrames: [CGRect] = []
        var stableSince = Date()
        do {
            try wait(message: "Expected \(count) visible terminal panes") {
                panes = harness.app.textViews.allElementsBoundByIndex.filter(\.isHittable)
                    .sorted { $0.frame.minY < $1.frame.minY }
                let frames = panes.map(\.frame)
                if frames != previousFrames {
                    previousFrames = frames
                    stableSince = Date()
                }
                return frames.count == count && frames.allSatisfy { $0.width > 40 && $0.height > 40 }
                    && Date().timeIntervalSince(stableSince) >= 0.5
            }
        } catch {
            harness.recordScreen(name: "live-tmux-pane-count-timeout")
            throw error
        }
        return panes
    }

    private func pane(_ index: Int, count: Int, harness: LiveSSHUITestHarness) throws -> XCUIElement {
        try visiblePanes(count: count, harness: harness)[index]
    }

    private func wait(timeout: TimeInterval = 15, message: String, until predicate: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if predicate() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        throw failure(message)
    }

    private func failure(_ message: String) -> NSError {
        XCTFail(message)
        return NSError(domain: "LiveTmuxAcceptance", code: 1)
    }
}
