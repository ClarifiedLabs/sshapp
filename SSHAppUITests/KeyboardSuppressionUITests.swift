import UIKit
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
        let directTerminal = app.textViews.firstMatch
        let hideKeyboard = app.buttons["terminal.keyboard.hide"]
        XCTAssertTrue(terminalArea.waitForExistence(timeout: 8))
        XCTAssertTrue(directTerminal.waitForExistence(timeout: 8))
        XCTAssertTrue(hideKeyboard.waitForExistence(timeout: 8))
        XCTAssertTrue(hideKeyboard.isHittable)
        let originalTerminalFrame = directTerminal.frame

        hideKeyboard.tap()

        let showKeyboard = app.buttons["terminal.keyboard.show"]
        XCTAssertTrue(showKeyboard.waitForExistence(timeout: 5))
        XCTAssertFalse(hideKeyboard.exists)
        XCTAssertTrue(showKeyboard.isHittable)
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                directTerminal.frame.height
                    >= originalTerminalFrame.height + terminalKeyboardBarFrameExpectation
            },
            "Hiding must release TerminalTab's keyboard-bar reservation back to its terminal"
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

    func testResponderResigningSystemDismissEntersPersistentSuppression() {
        let app = launchHarness(simulatesSystemResign: true)
        defer { app.terminate() }

        let terminalArea = app.descendants(matching: .any)["keyboard.suppression.terminalArea"]
        let directTerminal = app.textViews.firstMatch
        let hideKeyboard = app.buttons["terminal.keyboard.hide"]
        let showKeyboard = app.buttons["terminal.keyboard.show"]
        let softwareKeyboard = app.keyboards.firstMatch
        let simulateSystemResign = app.buttons["keyboard.suppression.simulateSystemResign"]

        require(
            terminalArea.waitForExistence(timeout: 8)
                && directTerminal.waitForExistence(timeout: 8),
            "The production direct terminal must exist",
            in: app
        )
        require(
            hideKeyboard.waitForExistence(timeout: 8) && hideKeyboard.isHittable,
            "The app keyboard bar must expose its hide control",
            in: app
        )
        require(
            waitForFullSoftwareKeyboardToBeOnscreen(softwareKeyboard, in: app, timeout: 8),
            "The focused terminal must present a full onscreen software keyboard",
            in: app
        )
        require(
            simulateSystemResign.waitForExistence(timeout: 5) && simulateSystemResign.isHittable,
            "The opt-in harness must expose the responder-resigning system path",
            in: app
        )
        let originalTerminalFrame = directTerminal.frame

        simulateSystemResign.tap()

        require(
            showKeyboard.waitForExistence(timeout: 5) && showKeyboard.isHittable,
            "A bare responder resignation followed by keyboard hide must reveal restore",
            in: app
        )
        require(
            hideKeyboard.waitForNonExistence(timeout: 5),
            "Persistent suppression must remove the app hide control",
            in: app
        )
        require(
            waitForSoftwareKeyboardToBeOffscreen(softwareKeyboard, in: app, timeout: 5),
            "The software keyboard must move offscreen after responder resignation",
            in: app
        )
        require(
            waitUntil(timeout: 5) {
                directTerminal.frame.height
                    >= originalTerminalFrame.height + terminalKeyboardBarFrameExpectation
            },
            "Persistent suppression must reclaim the app keyboard-bar reservation",
            in: app
        )

        let switchSurface = app.buttons["keyboard.suppression.switchSurface"]
        let activeSurface = app.staticTexts["keyboard.suppression.activeSurface"]
        switchSurface.tap()
        require(
            waitForLabel("tmux-window-1", on: activeSurface, timeout: 5),
            "Suppression must survive switching to a retained tmux surface",
            in: app
        )
        terminalArea.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.4)).tap()
        terminalArea.swipeUp()
        require(
            showKeyboard.exists && showKeyboard.isHittable,
            "Ordinary tmux terminal interactions must preserve suppression",
            in: app
        )
        require(
            waitForSoftwareKeyboardToBeOffscreen(softwareKeyboard, in: app, timeout: 5),
            "Ordinary terminal interactions must not reopen the software keyboard",
            in: app
        )

        showKeyboard.tap()

        require(
            showKeyboard.waitForNonExistence(timeout: 5),
            "Restore must leave suppression mode",
            in: app
        )
        require(
            hideKeyboard.waitForExistence(timeout: 5),
            "Restore must bring back the full app keyboard bar",
            in: app
        )
        require(
            waitForFullSoftwareKeyboardToBeOnscreen(softwareKeyboard, in: app, timeout: 8),
            "Restore must reopen the full software keyboard on the active tmux surface",
            in: app
        )
        require(
            waitForLabel("tmux-window-1", on: activeSurface, timeout: 5),
            "Restore must not change the active retained surface",
            in: app
        )
    }

    func testSystemKeyboardDismissEntersSuppressionAcrossRetainedSurfaces() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("The native software-keyboard dismiss key is iPad-only")
        }

        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launchHarness()
        defer {
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }

        let appWindow = app.windows.firstMatch
        require(
            appWindow.waitForExistence(timeout: 8)
                && waitUntil(timeout: 8) {
                    let frame = appWindow.frame
                    return frame.width > frame.height
                },
            "The native-dismiss regression must run with a landscape app window",
            in: app
        )

        let terminalArea = app.descendants(matching: .any)["keyboard.suppression.terminalArea"]
        let hideKeyboard = app.buttons["terminal.keyboard.hide"]
        let showKeyboard = app.buttons["terminal.keyboard.show"]
        let softwareKeyboard = app.keyboards.firstMatch
        require(
            terminalArea.waitForExistence(timeout: 8),
            "The production TerminalTab surface must exist",
            in: app
        )
        require(
            hideKeyboard.waitForExistence(timeout: 8) && hideKeyboard.isHittable,
            "The app keyboard bar must expose its distinct hide control",
            in: app
        )

        require(
            waitForFullSoftwareKeyboardToBeOnscreen(softwareKeyboard, in: app, timeout: 8),
            "The focused terminal must present a full onscreen software keyboard",
            in: app
        )

        guard let systemDismiss = systemKeyboardDismissButton(in: app, timeout: 3) else {
            require(
                false,
                "The exact iPad simulator must expose a native keyboard dismiss key",
                in: app
            )
            return
        }
        require(
            systemDismiss.exists && systemDismiss.isHittable,
            "The native keyboard dismiss candidate must exist and be hittable",
            in: app
        )
        require(
            systemDismiss.identifier != hideKeyboard.identifier,
            "The native key must be distinct from terminal.keyboard.hide",
            in: app
        )
        systemDismiss.tap()

        require(
            showKeyboard.waitForExistence(timeout: 5) && showKeyboard.isHittable,
            "The native key must reveal terminal.keyboard.show",
            in: app
        )
        require(
            hideKeyboard.waitForNonExistence(timeout: 5),
            "The app hide control must disappear in suppression mode",
            in: app
        )
        require(
            waitForSoftwareKeyboardToBeOffscreen(softwareKeyboard, in: app, timeout: 5),
            "The full software keyboard must move offscreen after native dismissal",
            in: app
        )

        let switchSurface = app.buttons["keyboard.suppression.switchSurface"]
        let activeSurface = app.staticTexts["keyboard.suppression.activeSurface"]
        for expectedSurface in ["tmux-window-1", "tmux-window-2", "direct"] {
            switchSurface.tap()
            require(
                waitForLabel(expectedSurface, on: activeSurface, timeout: 5),
                "Suppression must survive switching to retained surface \(expectedSurface)",
                in: app
            )
            terminalArea.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.4)).tap()
            terminalArea.swipeUp()
            require(
                showKeyboard.exists && showKeyboard.isHittable,
                "Terminal gestures must not leave suppression on \(expectedSurface)",
                in: app
            )
            require(
                waitForSoftwareKeyboardToBeOffscreen(softwareKeyboard, in: app, timeout: 5),
                "Terminal gestures must not reopen the keyboard on \(expectedSurface)",
                in: app
            )
        }

        let suppressedTerminalFrame = app.textViews.firstMatch.frame
        showKeyboard.tap()

        require(
            showKeyboard.waitForNonExistence(timeout: 5),
            "Restoring must leave suppression mode",
            in: app
        )
        require(
            hideKeyboard.waitForExistence(timeout: 5),
            "Restoring on the active direct surface must restore the app hide control",
            in: app
        )
        require(
            waitForLabel("direct", on: activeSurface, timeout: 5),
            "Keyboard restoration must not change the active surface",
            in: app
        )
        require(
            waitUntil(timeout: 5) {
                app.textViews.firstMatch.frame.height
                    <= suppressedTerminalFrame.height - terminalKeyboardBarFrameExpectation
            },
            "Restoring must re-reserve the keyboard bar on the active direct terminal",
            in: app
        )
    }

    private func launchHarness(simulatesSystemResign: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--sshapp-in-memory-store",
            "--sshapp-reset-state",
            "--sshapp-ui-test-keyboard-suppression",
            "--ui-testing",
        ]
        if simulatesSystemResign {
            app.launchArguments.append("--sshapp-ui-test-keyboard-suppression-system-resign")
        }
        app.launch()

        // Ghostty redraws continuously, so XCTest must not wait for app idleness.
        app.setValue(NSNumber(value: 3), forKey: "currentInteractionOptions")
        return app
    }

    private func waitForFullSoftwareKeyboardToBeOnscreen(
        _ keyboard: XCUIElement,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        waitUntil(timeout: timeout) {
            let window = app.windows.firstMatch
            guard keyboard.exists, window.exists else { return false }
            let keyboardFrame = keyboard.frame
            return keyboardFrame.height > fullSoftwareKeyboardHeightThreshold
                && keyboardFrame.intersects(window.frame)
        }
    }

    private func waitForSoftwareKeyboardToBeOffscreen(
        _ keyboard: XCUIElement,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        waitUntil(timeout: timeout) {
            guard keyboard.exists else { return true }
            let keyboardFrame = keyboard.frame
            let windowFrame = app.windows.firstMatch.frame
            return keyboardFrame.minY >= windowFrame.maxY
        }
    }

    private func require(
        _ condition: @autoclosure () -> Bool,
        _ message: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard condition() else {
            attachKeyboardSuppressionFailureDiagnostics(app, reason: message)
            XCTFail(message, file: file, line: line)
            return
        }
    }

    private func attachKeyboardSuppressionFailureDiagnostics(
        _ app: XCUIApplication,
        reason: String
    ) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "keyboard-suppression-failure-screenshot"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let hierarchy = XCTAttachment(
            string: "reason: \(reason)\n\n\(app.debugDescription)"
        )
        hierarchy.name = "keyboard-suppression-accessibility-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }

    private func systemKeyboardDismissButton(
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> XCUIElement? {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.waitForExistence(timeout: timeout) else { return nil }

        for label in ["Hide keyboard", "Dismiss keyboard", "Hide Keyboard", "Dismiss Keyboard"] {
            let candidate = keyboard.buttons[label].firstMatch
            if candidate.exists, candidate.isHittable {
                return candidate
            }
        }

        let predicate = NSPredicate(
            format: "(label CONTAINS[c] %@ OR label CONTAINS[c] %@) AND label CONTAINS[c] %@",
            "hide",
            "dismiss",
            "keyboard"
        )
        let candidates = keyboard.buttons.matching(predicate)
        guard waitUntil(timeout: timeout, condition: { candidates.firstMatch.exists }) else {
            return nil
        }
        return candidates.allElementsBoundByIndex.first(where: { $0.isHittable })
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
private let fullSoftwareKeyboardHeightThreshold: CGFloat = 120
