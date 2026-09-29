import UIKit
import XCTest

@MainActor
final class KeyboardSuppressionUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        // XCTest can abort a test at an assertion before its local defer runs.
        MainActor.assumeIsolated {
            DeviceOrientationSettle.restorePortraitAndTerminate(XCUIApplication())
        }
        try super.tearDownWithError()
    }

    /// The next test class launches immediately. Give SpringBoard time to
    /// finish any display-transform work left by this class's landscape and
    /// keyboard presentation before another app launch reaches it.
    nonisolated override class func tearDown() {
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        super.tearDown()
    }

    func testCompactBarKeepsPasteClearOfHideKeyboard() {
        let app = launchHarness()
        defer { UITestDeviceHealth.terminate(app) }
        TestPasteboard.setText("keyboard bar layout fixture", returningTo: app)
        defer { TestPasteboard.setText(nil, returningTo: app) }

        let bar = app.descendants(matching: .any)["terminal.keyboard.bar"].firstMatch
        let hide = app.buttons["terminal.keyboard.hide"]
        let paste = app.buttons["terminal.keyboard.paste"]
        require(hide.waitForExistence(timeout: 8) && hide.isHittable,
                "The fixed keyboard button must be visible", in: app)
        require(bar.waitForExistence(timeout: 5), "The keyboard bar must exist", in: app)
        XCTAssertEqual(bar.frame.height, 44, accuracy: 1,
                       "The bar must not reserve excess terminal height on wide displays")
        let hideFrame = hide.frame

        // On a wide window everything fits. On a phone, drag only the action
        // strip, using Hide Keyboard's y coordinate to avoid the native keys.
        for _ in 0..<5 {
            if paste.exists && paste.isHittable
                && paste.frame.minX >= bar.frame.minX
                && paste.frame.maxX <= hide.frame.minX - 4 {
                break
            }
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: hide.frame.minX - 16, dy: hide.frame.midY))
            let end = origin.withOffset(CGVector(dx: bar.frame.minX + 24, dy: hide.frame.midY))
            start.press(forDuration: 0.05, thenDragTo: end)
        }

        require(paste.exists && paste.isHittable, "Paste must be reachable at scroll end", in: app)
        XCTAssertGreaterThanOrEqual(paste.frame.minX, bar.frame.minX)
        XCTAssertLessThanOrEqual(paste.frame.maxX, hide.frame.minX - 4,
                                 "The entire system Paste control must clear Hide Keyboard")
        XCTAssertGreaterThanOrEqual(paste.frame.minY, bar.frame.minY)
        XCTAssertLessThanOrEqual(paste.frame.maxY, bar.frame.maxY)
        XCTAssertEqual(hide.frame, hideFrame, "Scrolling actions must not move Hide Keyboard")

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "compact-keyboard-bar-paste-visible"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        hide.tap()
        XCTAssertTrue(app.buttons["terminal.keyboard.show"].waitForExistence(timeout: 5))
    }

    func testHideReclaimsTerminalAndSurvivesTerminalInteractionsUntilShow() throws {
        let app = launchHarness()
        defer { UITestDeviceHealth.terminate(app) }

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
        defer { UITestDeviceHealth.terminate(app) }

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
        defer { UITestDeviceHealth.terminate(app) }

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
            establishFullSoftwareKeyboard(in: app),
            "Explicit keyboard setup must present a full onscreen software keyboard",
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

        let app = launchHarness()
        // A teardown block, not a defer: continueAfterFailure = false can abort
        // the body at any assertion, and this must still run before
        // tearDownWithError on both the passing and failing paths.
        addTeardownBlock { @MainActor [self] in
            dismissKeyboardThenRotatePortraitAndTerminate(app)
        }
        // As in cleanup, never rotate with the software keyboard up: suppress
        // it, rotate, then restore it before the regression's own setup.
        let hideBeforeRotation = app.buttons["terminal.keyboard.hide"]
        require(hideBeforeRotation.waitForExistence(timeout: 8) && hideBeforeRotation.isHittable,
                "The app keyboard bar must expose its hide control before rotation", in: app)
        hideBeforeRotation.tap()
        require(waitForSoftwareKeyboardToBeOffscreen(app.keyboards.firstMatch, in: app, timeout: 5),
                "The software keyboard must be offscreen before rotating", in: app)
        DeviceOrientationSettle.request(.landscapeLeft)
        let showAfterRotation = app.buttons["terminal.keyboard.show"]
        require(showAfterRotation.waitForExistence(timeout: 5) && showAfterRotation.isHittable,
                "Suppression must survive rotation", in: app)
        showAfterRotation.tap()

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
            establishFullSoftwareKeyboard(in: app),
            "Explicit keyboard setup must present a full onscreen software keyboard",
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
            waitUntil(timeout: 5) { showKeyboard.exists && showKeyboard.isHittable },
            "The native key must reveal a hittable terminal.keyboard.show",
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
            waitForFullSoftwareKeyboardToBeOnscreen(softwareKeyboard, in: app, timeout: 8),
            "Restoring after native dismissal must reopen the full software keyboard, not just the app bar",
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
            "Restoring must re-reserve the keyboard bar on the active direct terminal; "
                + "suppressed=\(suppressedTerminalFrame), restored=\(app.textViews.firstMatch.frame)",
            in: app
        )
        let assistant = app.otherElements["SystemInputAssistantView"].firstMatch
        require(
            waitUntil(timeout: 5) {
                guard hideKeyboard.isHittable else { return false }
                guard assistant.exists, assistant.frame.intersects(appWindow.frame) else { return true }
                return hideKeyboard.frame.maxY <= assistant.frame.minY
            },
            "The restored app bar must not overlap the collapsed system input assistant",
            in: app
        )
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "native-dismiss-restored-bar-clear-of-assistant"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    /// Regression: on a 13" iPad the iPadOS 26+ minimized shortcut pill sat over
    /// the suppressed Show Keyboard control, so centre taps never reached it.
    /// In each orientation the control must be hittable at its centre, clear of
    /// every on-screen keyboard element, and restore the keyboard from a
    /// centre tap. Rotation happens only while suppressed (keyboard offscreen).
    func testShowKeyboardControlClearsKeyboardUIInPortraitAndLandscape() {
        let app = launchHarness()
        addTeardownBlock { @MainActor [self] in
            dismissKeyboardThenRotatePortraitAndTerminate(app)
        }

        let hideKeyboard = app.buttons["terminal.keyboard.hide"]
        let showKeyboard = app.buttons["terminal.keyboard.show"]
        let softwareKeyboard = app.keyboards.firstMatch
        let appWindow = app.windows.firstMatch

        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            let name = orientation == .portrait ? "portrait" : "landscape"
            require(hideKeyboard.waitForExistence(timeout: 8) && hideKeyboard.isHittable,
                    "The app keyboard bar must expose its hide control (\(name))", in: app)
            hideKeyboard.tap()
            require(showKeyboard.waitForExistence(timeout: 5),
                    "Hiding must reveal terminal.keyboard.show (\(name))", in: app)
            require(waitForSoftwareKeyboardToBeOffscreen(softwareKeyboard, in: app, timeout: 5),
                    "The software keyboard must be offscreen before rotating (\(name))", in: app)
            DeviceOrientationSettle.request(orientation)
            require(
                waitUntil(timeout: 8) {
                    guard appWindow.exists else { return false }
                    let frame = appWindow.frame
                    return orientation == .portrait
                        ? frame.height > frame.width
                        : frame.width > frame.height
                },
                "The app window must reach \(name)",
                in: app
            )

            var overlapping: [CGRect] = []
            let clear = waitUntil(timeout: 5) {
                guard showKeyboard.exists, showKeyboard.isHittable else { return false }
                overlapping = onscreenKeyboardUIFrames(in: app, window: appWindow.frame)
                    .filter { $0.intersects(showKeyboard.frame) }
                return overlapping.isEmpty
            }
            require(
                clear,
                "terminal.keyboard.show \(showKeyboard.frame) must be hittable and clear of keyboard UI "
                    + "\(overlapping) in \(name)",
                in: app
            )
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "show-keyboard-clear-of-keyboard-ui-\(name)"
            screenshot.lifetime = .keepAlways
            add(screenshot)

            showKeyboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            require(showKeyboard.waitForNonExistence(timeout: 5),
                    "A centre tap on terminal.keyboard.show must restore the keyboard (\(name))", in: app)
            require(hideKeyboard.waitForExistence(timeout: 5),
                    "Restoring must bring back the app keyboard bar (\(name))", in: app)
        }
    }

    /// Frames of keyboard UI drawn over the app: the app's keyboard window
    /// (keys, input assistant) plus SpringBoard/InputUI keyboard elements such
    /// as the minimized keyboard pill. Offscreen or empty frames are ignored.
    private func onscreenKeyboardUIFrames(in app: XCUIApplication, window: CGRect) -> [CGRect] {
        var candidates: [XCUIElement] = app.keyboards.allElementsBoundByIndex
        candidates += app.otherElements.matching(identifier: "SystemInputAssistantView").allElementsBoundByIndex
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        candidates += springboard.keyboards.allElementsBoundByIndex
        let keyboardUI = NSPredicate(
            format: "identifier CONTAINS[c] %@ OR identifier CONTAINS[c] %@ OR identifier CONTAINS[c] %@ "
                + "OR label CONTAINS[c] %@",
            "keyboard", "InputAssistant", "dictation", "keyboard"
        )
        candidates += springboard.otherElements.matching(keyboardUI).allElementsBoundByIndex
        candidates += springboard.buttons.matching(keyboardUI).allElementsBoundByIndex
        return candidates.compactMap { element -> CGRect? in
            guard element.exists, !element.identifier.hasPrefix("terminal.keyboard.") else { return nil }
            let frame = element.frame.intersection(window)
            guard !frame.isNull, frame.width > 0, frame.height > 0 else { return nil }
            // A whole-screen container is not keyboard UI covering the control.
            guard frame.width < window.width || frame.height < window.height else { return nil }
            return frame
        }
    }

    func testFullKeyboardSetupSurvivesNativeDismissAndRelaunch() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("The native software-keyboard dismiss key is iPad-only")
        }

        // Native dismissal can survive the app process. Prove that the next
        // test can establish its keyboard precondition without resetting the
        // simulator or assuming first-responder focus implies visible keys.
        for _ in 0..<2 {
            let app = launchHarness()
            defer { UITestDeviceHealth.terminate(app) }
            require(establishFullSoftwareKeyboard(in: app),
                "Keyboard setup must work after the preceding native dismissal", in: app)
            guard let dismiss = systemKeyboardDismissButton(in: app, timeout: 3) else {
                require(false, "The native keyboard dismiss key must be available", in: app)
                return
            }
            dismiss.tap()
            require(app.buttons["terminal.keyboard.show"].waitForExistence(timeout: 5),
                "Native dismissal must enter persistent suppression", in: app)
            require(waitForSoftwareKeyboardToBeOffscreen(app.keyboards.firstMatch, in: app, timeout: 5),
                "Native dismissal must hide the software keyboard before relaunch", in: app)
        }
    }

    /// iPadOS 27.0.1 SpringBoard asserted in its display-transform update (or
    /// left a permanent black overlay) when XCTest simulated portrait while the
    /// software keyboard was up in landscape and the app then terminated. Only
    /// rotate back with the keyboard fully offscreen, only terminate after the
    /// app window is portrait and quiet, and let SpringBoard settle afterwards.
    private func dismissKeyboardThenRotatePortraitAndTerminate(_ app: XCUIApplication) {
        if app.state == .runningForeground, !UITestDeviceHealth.isWedged {
            let softwareKeyboard = app.keyboards.firstMatch
            let hideKeyboard = app.buttons["terminal.keyboard.hide"]
            if hideKeyboard.exists, hideKeyboard.isHittable {
                hideKeyboard.tap()
            } else if softwareKeyboard.exists,
                      let systemDismiss = systemKeyboardDismissButton(in: app, timeout: 1) {
                systemDismiss.tap()
            }
            let keyboardOffscreen = waitForSoftwareKeyboardToBeOffscreen(
                softwareKeyboard, in: app, timeout: 5
            )
            if !keyboardOffscreen {
                // Never rotate with the keyboard up: terminate in landscape
                // and let the settle below rotate SpringBoard's home screen.
                XCTFail("Cleanup could not move the software keyboard offscreen before rotating")
            } else {
                DeviceOrientationSettle.request(.portrait)
                let window = app.windows.firstMatch
                _ = waitUntil(timeout: 8) {
                    guard window.exists else { return false }
                    let frame = window.frame
                    return frame.height > frame.width
                }
                RunLoop.current.run(until: Date().addingTimeInterval(2))
            }
        }
        // Terminates, restores portrait once SpringBoard is foreground, and
        // waits for SpringBoard's frame to stay unchanged before returning.
        UITestDeviceHealth.terminate(app)
    }

    /// Establish a prerequisite using the same explicit controls as a user.
    /// iPadOS remembers native keyboard dismissal across app launches even
    /// though the new terminal is first responder and app suppression is false.
    /// This runs BEFORE the action under test, never as a retry or recovery of
    /// its assertions. Keep subsequent dismissal/restoration checks unchanged.
    private func establishFullSoftwareKeyboard(in app: XCUIApplication) -> Bool {
        let hide = app.buttons["terminal.keyboard.hide"]
        guard hide.waitForExistence(timeout: 8), hide.isHittable else { return false }
        hide.tap()
        let show = app.buttons["terminal.keyboard.show"]
        guard show.waitForExistence(timeout: 5), show.isHittable else { return false }
        show.tap()
        return waitForFullSoftwareKeyboardToBeOnscreen(app.keyboards.firstMatch, in: app, timeout: 8)
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
        // Ghostty redraws continuously, so XCTest must not wait for app idleness.
        UITestDeviceHealth.launch(app, for: self, disablesIdleWait: true)
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
