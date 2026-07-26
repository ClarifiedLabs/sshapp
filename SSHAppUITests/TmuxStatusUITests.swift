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
        app.launch()

        let stalledBanner = app.descendants(matching: .any)["tmux.pane.stalledBanner"]
        let resumeButton = app.descendants(matching: .any)["tmux.pane.stalledBanner.action"]
        XCTAssertTrue(stalledBanner.waitForExistence(timeout: 5))
        XCTAssertTrue(resumeButton.waitForExistence(timeout: 5))
        XCTAssertTrue(resumeButton.isHittable)

        let messageBanner = app.descendants(matching: .any)["tmux.session.messageBanner"]
        let dismissButton = app.descendants(matching: .any)["tmux.session.messageBanner.dismiss"]
        XCTAssertTrue(messageBanner.waitForExistence(timeout: 5))
        XCTAssertTrue(dismissButton.waitForExistence(timeout: 5))
        XCTAssertTrue(dismissButton.isHittable)

        dismissButton.tap()
        XCTAssertTrue(messageBanner.waitForNonExistence(timeout: 2))

        resumeButton.tap()
        XCTAssertTrue(stalledBanner.waitForNonExistence(timeout: 2))
    }
}
