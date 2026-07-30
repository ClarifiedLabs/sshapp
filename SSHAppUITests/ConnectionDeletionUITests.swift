import XCTest

/// UI coverage for swipe-to-delete on saved connection rows.
///
/// `testSwipeDeleteRequiresConfirmationAndCanCancel` runs offline: it seeds a
/// saved connection through the connection sheet (no SSH server needed) and
/// verifies the confirmation alert gates deletion and that Cancel is honored.
///
/// `testDeletingActiveConnectionOffersCloseAndDelete` is opt-in and requires a
/// live SSH host (it reuses `LiveSSHTestConfiguration`/`LiveSSHUITestHarness`);
/// it skips automatically when `SSHAPP_LIVE_SSH_DESTINATION` is unset. Only a
/// live connection produces the open tab that triggers the active-tab guard.
@MainActor
final class ConnectionDeletionUITests: XCTestCase {
    private let destination = "demo@uitest.delete"

    func testSwipeDeleteRequiresConfirmationAndCanCancel() throws {
        continueAfterFailure = false

        let app = XCUIApplication()
        app.launchArguments = [
            "--sshapp-in-memory-store",
            "--sshapp-reset-state",
        ]
        app.launch()

        seedSavedConnection(in: app)

        let row = app.staticTexts[destination]
        XCTAssertTrue(
            row.waitForExistence(timeout: 10),
            "Saved connection row should appear after saving"
        )

        // Swiping must NOT delete immediately: it must surface a confirmation
        // alert while leaving the connection in place.
        revealSwipeDelete(for: destination, in: app).tap()

        let confirmAlert = app.alerts["Delete Connection?"]
        XCTAssertTrue(
            confirmAlert.waitForExistence(timeout: 5),
            "Swipe-to-delete must ask for confirmation before removing a connection"
        )
        XCTAssertTrue(
            app.staticTexts[destination].exists,
            "The connection must survive until deletion is confirmed"
        )

        // Cancel keeps the connection.
        confirmAlert.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(
            app.staticTexts[destination].waitForExistence(timeout: 5),
            "Cancelling the confirmation must keep the saved connection"
        )

        // Confirming removes it.
        revealSwipeDelete(for: destination, in: app).tap()
        let confirmAgain = app.alerts["Delete Connection?"]
        XCTAssertTrue(confirmAgain.waitForExistence(timeout: 5))
        confirmAgain.buttons["Delete"].firstMatch.tap()

        XCTAssertTrue(
            app.staticTexts[destination].waitForNonExistence(timeout: 5),
            "Confirming deletion must remove the saved connection row"
        )
    }

    func testDeletingActiveConnectionOffersCloseAndDelete() throws {
        continueAfterFailure = false

        // Skips unless SSHAPP_LIVE_SSH_DESTINATION (and related vars) are set.
        let configuration = try LiveSSHTestConfiguration.fromEnvironment()
        let harness = LiveSSHUITestHarness(testCase: self)
        harness.launch()
        defer { harness.terminate() }

        try harness.createConnectionAndAuthenticate(using: configuration)
        let app = harness.app

        // Open Settings > Connections, where the now-active connection is listed.
        let settings = app.buttons["settings.open"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()

        let connections = app.buttons["settings.connections"]
        XCTAssertTrue(connections.waitForExistence(timeout: 5))
        connections.tap()

        // Swipe the single saved-connection row and request deletion.
        let row = app.cells.firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.swipeLeft()
        let swipeDelete = app.buttons["Delete"].firstMatch
        XCTAssertTrue(swipeDelete.waitForExistence(timeout: 5))
        swipeDelete.tap()

        // Because the connection still backs an open tab, deletion must be
        // gated by the active-tab guard rather than the plain confirmation.
        let guardAlert = app.alerts["Close Tabs & Delete?"]
        XCTAssertTrue(
            guardAlert.waitForExistence(timeout: 5),
            "Deleting a connection with an open tab must warn and offer Close & Delete"
        )
        XCTAssertFalse(
            app.alerts["Delete Connection?"].exists,
            "The plain delete confirmation must not be used while a tab is open"
        )

        guardAlert.buttons["Close & Delete"].firstMatch.tap()

        // The connection row is gone from the list...
        XCTAssertTrue(
            app.cells.firstMatch.waitForNonExistence(timeout: 10),
            "Close & Delete must remove the saved connection"
        )

        // ...and closing the settings sheet returns to the no-tabs home, proving
        // the open tab was closed.
        let done = app.buttons["Done"]
        if done.waitForExistence(timeout: 3) {
            done.tap()
        }
        XCTAssertTrue(
            app.buttons["connection.new"].waitForExistence(timeout: 10),
            "Closing the active connection's tab must return to the no-tabs home screen"
        )
    }

    // MARK: - Helpers

    /// Creates and saves a connection through the connection sheet without
    /// connecting, so the offline test has a row to delete.
    private func seedSavedConnection(in app: XCUIApplication) {
        let newConnection = app.buttons["connection.new"]
        XCTAssertTrue(
            newConnection.waitForExistence(timeout: 10),
            "New Connection button should be visible on the no-tabs home"
        )
        newConnection.tap()

        let destinationField = app.textFields["connection.destination"]
        XCTAssertTrue(destinationField.waitForExistence(timeout: 5))
        destinationField.tap()
        destinationField.typeText(destination)

        let save = app.buttons["connection.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(save.isEnabled, "Save should be enabled for a valid destination")
        save.tap()
    }

    /// Swipes the row for `destination` to reveal its trailing Delete action and
    /// returns that button.
    private func revealSwipeDelete(
        for destination: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        let row = app.staticTexts[destination]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.swipeLeft()
        let swipeDelete = app.buttons["Delete"].firstMatch
        XCTAssertTrue(
            swipeDelete.waitForExistence(timeout: 5),
            "Swiping a saved connection row should reveal a Delete action"
        )
        return swipeDelete
    }
}
