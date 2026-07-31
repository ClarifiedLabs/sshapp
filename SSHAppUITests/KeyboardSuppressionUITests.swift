import XCTest

@MainActor
final class KeyboardSuppressionUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testHideReclaimsTerminalAndSurvivesTerminalInteractionsUntilShow() throws {
        let app = launchHarness()
        defer { app.terminate() }

        let terminalArea = app.descendants(matching: .any)["keyboard.suppression.terminalArea"]
        let hideKeyboard = app.buttons["terminal.keyboard.hide"]
        XCTAssertTrue(terminalArea.waitForExistence(timeout: 8))
        XCTAssertTrue(hideKeyboard.waitForExistence(timeout: 8))
        XCTAssertTrue(hideKeyboard.isHittable)
        let originalTerminalFrame = terminalArea.frame

        hideKeyboard.tap()

        let showKeyboard = app.buttons["terminal.keyboard.show"]
        XCTAssertTrue(showKeyboard.waitForExistence(timeout: 5))
        XCTAssertFalse(hideKeyboard.exists)
        XCTAssertTrue(showKeyboard.isHittable)
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                terminalArea.frame.height >= originalTerminalFrame.height + terminalKeyboardBarFrameExpectation
            },
            "Hiding must release the full keyboard-bar reservation back to the terminal"
        )

        // Ordinary responder and selection gestures must not leave explicit mode.
        terminalArea.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.4)).tap()
        let selectionStart = terminalArea.coordinate(
            withNormalizedOffset: CGVector(dx: 0.05, dy: 0.04)
        )
        let selectionEnd = terminalArea.coordinate(
            withNormalizedOffset: CGVector(dx: 0.65, dy: 0.04)
        )
        selectionStart.press(forDuration: 0.7, thenDragTo: selectionEnd)

        let copyMenuItem = try XCTUnwrap(waitForCopyMenuItem(in: app, timeout: 3))
        copyMenuItem.tap()
        terminalArea.swipeUp()
        XCTAssertTrue(showKeyboard.exists)

        showKeyboard.tap()

        XCTAssertTrue(showKeyboard.waitForNonExistence(timeout: 5))
        XCTAssertTrue(hideKeyboard.waitForExistence(timeout: 5))
    }

    func testSuppressionPersistsAcrossRetainedDirectAndTmuxSurfaces() {
        let app = launchHarness()
        defer { app.terminate() }

        let hideKeyboard = app.buttons["terminal.keyboard.hide"]
        XCTAssertTrue(hideKeyboard.waitForExistence(timeout: 8))
        hideKeyboard.tap()

        let showKeyboard = app.buttons["terminal.keyboard.show"]
        let switchSurface = app.buttons["keyboard.suppression.switchSurface"]
        let activeSurface = app.staticTexts["keyboard.suppression.activeSurface"]
        let terminalArea = app.otherElements["keyboard.suppression.terminalArea"]
        XCTAssertTrue(showKeyboard.waitForExistence(timeout: 5))

        for expectedSurface in ["tmux-window-1", "tmux-window-2", "direct"] {
            switchSurface.tap()
            XCTAssertTrue(waitForLabel(expectedSurface, on: activeSurface, timeout: 5))
            terminalArea.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.4)).tap()
            terminalArea.swipeUp()
            XCTAssertTrue(showKeyboard.exists)
            XCTAssertTrue(showKeyboard.isHittable)
            XCTAssertFalse(app.keyboards.firstMatch.exists)
        }

        let toggleBarPreference = app.buttons["keyboard.suppression.toggleBarPreference"]
        toggleBarPreference.tap()
        XCTAssertTrue(showKeyboard.exists, "Restore must ignore the Keyboard Bar preference")

        showKeyboard.tap()

        XCTAssertTrue(showKeyboard.waitForNonExistence(timeout: 5))
        XCTAssertFalse(
            app.buttons["terminal.keyboard.hide"].exists,
            "Restoring with the Keyboard Bar preference disabled must not restore the full bar"
        )

        toggleBarPreference.tap()
        XCTAssertTrue(app.buttons["terminal.keyboard.hide"].waitForExistence(timeout: 5))
    }

    private func launchHarness() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--sshapp-in-memory-store",
            "--sshapp-reset-state",
            "--sshapp-ui-test-keyboard-suppression",
            "--ui-testing",
        ]
        app.launch()

        // Ghostty redraws continuously, so XCTest must not wait for app idleness.
        app.setValue(NSNumber(value: 3), forKey: "currentInteractionOptions")
        return app
    }

    private func waitForCopyMenuItem(
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> XCUIElement? {
        let legacyMenuItem = app.menuItems["Copy"].firstMatch
        let button = app.buttons["Copy"].firstMatch
        guard waitUntil(timeout: timeout, condition: {
            legacyMenuItem.exists || button.exists
        }) else {
            return nil
        }
        return legacyMenuItem.exists ? legacyMenuItem : button
    }

    private func waitForLabel(
        _ label: String,
        on element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        guard element.waitForExistence(timeout: timeout) else { return false }
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", label),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitUntil(
        timeout: TimeInterval,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }
}

private let terminalKeyboardBarFrameExpectation: CGFloat = 40
