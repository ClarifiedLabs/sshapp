import XCTest

@MainActor
final class TerminalProgressUITests: XCTestCase {
    func testRemoteProgressUpdatesAndRemovalStayLocal() throws {
        continueAfterFailure = false
        let harness = TerminalSelectionUITestHarness(testCase: self)
        defer { harness.restorePortraitAndTerminate() }
        // The shared driver does not expose arbitrary launch flags. Use its
        // network-free standard fixture and the same device-safe launch path.
        harness.app.launchArguments = [
            "--sshapp-in-memory-store",
            "--sshapp-reset-state",
            "--ui-testing",
            "--sshapp-ui-test-terminal-selection",
            "--sshapp-ui-test-terminal-selection-scenario=standard",
            "--sshapp-ui-test-terminal-progress",
        ]
        UITestDeviceHealth.launch(harness.app, for: self, disablesIdleWait: true)
        DeviceOrientationSettle.request(.portrait)

        do {
            _ = try harness.waitForFixtureStatus(timeout: 12) {
                $0.phase == .ready && $0.scenario == "standard"
            }
            _ = try harness.waitForPackageSnapshot {
                $0.surfaceReady && $0.gridReady
            }
            let progress = harness.exactDescendant(identifier: "terminal.progress")
            let next = harness.app.buttons["terminal.progress.next"]
            try harness.require(!progress.exists, "Progress pill appeared before remote progress output")
            try harness.require(next.waitForExistence(timeout: 5) && next.isHittable,
                                "Next progress control is unavailable")

            for expected in ["Working 42%", "Working", "Paused 42%", "Error 75%"] {
                try advance(next, harness: harness)
                let updated = XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "exists == true AND value == %@", expected),
                    object: progress
                )
                try harness.require(XCTWaiter.wait(for: [updated], timeout: 5) == .completed,
                                    "Expected terminal progress '\(expected)', got '\(String(describing: progress.value))'",
                                    relevantElements: [progress])
                try harness.assertNoClientWrites()

                let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                screenshot.name = "terminal-progress-\(expected)"
                screenshot.lifetime = .keepAlways
                add(screenshot)
            }

            try advance(next, harness: harness)
            let removed = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"), object: progress
            )
            try harness.require(XCTWaiter.wait(for: [removed], timeout: 5) == .completed,
                                "OSC progress removal did not dismiss the pill",
                                relevantElements: [progress])
            try harness.assertNoClientWrites()
        } catch {
            harness.attachFailureDiagnostics(reason: "Terminal progress: \(error)")
            throw error
        }
    }

    private func advance(_ next: XCUIElement, harness: TerminalSelectionUITestHarness) throws {
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: next
        )
        try harness.require(XCTWaiter.wait(for: [ready], timeout: 5) == .completed,
                            "Progress fixture is not ready for the next remote update",
                            relevantElements: [next])
        next.tap()
    }
}
