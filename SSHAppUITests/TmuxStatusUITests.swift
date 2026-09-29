import XCTest

@MainActor
final class TmuxStatusUITests: XCTestCase {
    func testFallbackPaneStatusAndAttachedMessageAreInteractive() {
        continueAfterFailure = false

        let app = XCUIApplication()
        app.launchArguments = [
            "--sshapp-in-memory-store",
            "--sshapp-reset-state",
            "--sshapp-ui-test-tmux-status",
        ]
        UITestDeviceHealth.launch(app, for: self)

        let stalledBanner = app.descendants(matching: .any)["tmux.pane.stalledBanner"]
        let resumeButton = app.descendants(matching: .any)["tmux.pane.stalledBanner.action"]
        XCTAssertTrue(stalledBanner.waitForExistence(timeout: 5))
        XCTAssertTrue(resumeButton.waitForExistence(timeout: 5))

        let messageBanner = app.descendants(matching: .any)["tmux.session.messageBanner"]
        let dismissButton = app.descendants(matching: .any)["tmux.session.messageBanner.dismiss"]
        XCTAssertTrue(messageBanner.waitForExistence(timeout: 5))
        XCTAssertTrue(dismissButton.waitForExistence(timeout: 5))

        // The focused terminal presents the software keyboard right after
        // launch; on iPad that moves the bottom banner and re-lays out the
        // overlay. Tap each control only once its frame has settled.
        // Regression: a 13x12pt X on a physical iPad Pro let the tap fall through
        // to the terminal (dismissing the keyboard) instead of the banner.
        for control in [dismissButton, resumeButton] {
            XCTAssertGreaterThanOrEqual(control.frame.width, 44, "\(control.identifier) touch target")
            XCTAssertGreaterThanOrEqual(control.frame.height, 44, "\(control.identifier) touch target")
        }

        XCTAssertTrue(waitForSettledHittable(dismissButton), "Dismiss never settled hittable")
        dismissButton.tap()
        XCTAssertTrue(messageBanner.waitForNonExistence(timeout: 2))

        XCTAssertTrue(waitForSettledHittable(resumeButton), "Resume never settled hittable")
        resumeButton.tap()
        XCTAssertTrue(stalledBanner.waitForNonExistence(timeout: 2))
    }

    private func waitForSettledHittable(_ element: XCUIElement, timeout: TimeInterval = 8) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var previousFrame = CGRect.null
        var stableSince = Date()
        while Date() < deadline {
            if element.exists, element.isHittable {
                let frame = element.frame
                if frame != previousFrame {
                    previousFrame = frame
                    stableSince = Date()
                } else if Date().timeIntervalSince(stableSince) >= 0.75 {
                    return true
                }
            } else {
                previousFrame = .null
                stableSince = Date()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
        return false
    }
}
