import XCTest

@MainActor
final class TerminalBaselineUITests: XCTestCase {
    func testRecordInitialSelectionAndRotationBaseline() throws {
        continueAfterFailure = false
        let harness = TerminalSelectionUITestHarness(testCase: self)
        // Rotates back to portrait while foreground, then terminates and settles.
        defer { harness.restorePortraitAndTerminate() }
        harness.launch(scenario: .standard)
        let ready = try harness.waitForReady()
        recordScreenshot(name: "terminal-baseline-initial")

        try harness.stationaryLongPress(
            anchorNamed: "bravoCenter", fixtureStatus: ready, duration: 1.25
        )
        _ = try harness.waitForPackageSnapshot { snapshot in
            snapshot.selectedText == "BRAVO" && snapshot.touchHandlesVisible
                && !snapshot.selectionGestureActive && !snapshot.loupeVisible
        }
        recordScreenshot(name: "terminal-baseline-selection")

        // Without a portrait grid the column check below would pass vacuously.
        let portraitColumns = try XCTUnwrap(ready.latestPackageSnapshot?.gridColumns)
        DeviceOrientationSettle.request(.landscapeLeft)
        _ = try harness.waitForPackageSnapshot { snapshot in
            snapshot.gridReady && snapshot.gridColumns != portraitColumns
        }
        waitForSettledLandscapeFrame(harness.app)
        recordScreenshot(name: "terminal-baseline-landscape")
    }

    private func waitForSettledLandscapeFrame(_ app: XCUIApplication) {
        // The harness disables XCTest's normal idle wait. Grid resizing can
        // precede the UIKit rotation animation, so wait for stable host geometry
        // before capturing; otherwise the image contains a rotated partial view.
        // iPad's compositor can still be rotating after 0.6 seconds of stable
        // accessibility geometry, so allow its longer animation to finish.
        let deadline = Date().addingTimeInterval(5)
        var previousFrame = CGRect.zero
        var stableSince = Date()
        while Date() < deadline {
            let frame = app.frame
            if frame != previousFrame || frame.width <= frame.height {
                previousFrame = frame
                stableSince = Date()
            } else if Date().timeIntervalSince(stableSince) >= 1.5 {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("Landscape window geometry did not settle for the baseline capture")
    }

    private func recordScreenshot(name: String) {
        // Application-element captures can crop using stale portrait bounds
        // after rotation. Capture the screen in its current orientation.
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
