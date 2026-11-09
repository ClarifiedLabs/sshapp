import XCTest

/// Explicit opt-in Duo coverage. These tests avoid Device Health's portrait
/// restoration because the Duo-only runtime does not support rotating to a
/// standard portrait/landscape pair.
@MainActor
final class DuoLayoutUITests: XCTestCase {
    func testNoTabsConnectionEditorAndSettingsActionsRemainReachable() throws {
        try requireExplicitDuoRun()
        let app = launch()
        let newConnection = try requireVisible("connection.new", in: app)
        capture("Duo no-tabs home", app)

        newConnection.tap()
        let cancel = try requireVisible("connection.cancel", in: app)
        _ = try requireVisible("connection.save", in: app)
        _ = try requireVisible("connection.connect", in: app)
        capture("Duo connection editor", app)
        cancel.tap()

        let settings = try requireVisible("settings.open", in: app)
        settings.tap()
        let theme = try requireVisible("settings.theme", in: app)
        theme.tap()
        let done = try requireVisible("settings.done", in: app)
        capture("Duo settings sheet", app)
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 5))
    }

    func testSecondaryModalActionsRemainReachableAtCompactHeight() throws {
        try requireExplicitDuoRun()
        let fixtures = [
            (fixture: "credential-save", actions: ["Not Now", "Save"]),
            (fixture: "install-key", actions: ["Cancel", "Install"]),
            (fixture: "generate-key", actions: ["Cancel", "Generate Key"]),
            (fixture: "edit-key", actions: ["Cancel", "Save"]),
            (fixture: "change-password", actions: ["Cancel", "Save"]),
            (fixture: "app-lock", actions: ["Cancel", "Enable"])
        ]

        for fixture in fixtures {
            let app = launch(modal: fixture.fixture)
            for action in fixture.actions {
                if fixture.fixture == "generate-key" && action == "Generate Key" {
                    try requireButtonReachable(action, in: app)
                } else {
                    try requireButtonVisible(action, in: app)
                }
            }
            capture("Duo modal \(fixture.fixture)", app)
            UITestDeviceHealth.terminateDuo(app)
        }
    }

    func testDirectTerminalSwitcherAndKeyboardAccessoryRemainReachable() throws {
        try requireExplicitDuoRun()
        let app = launch(surface: "direct")
        let switcherButton = try requireVisible("connection.pill", in: app)
        let newTabButton = try requireVisible("host.session.new", in: app)
        _ = try requireVisible("settings.open", in: app)
        _ = try requireVisible("terminal.keyboard.bar", in: app)
        _ = try requireVisible("terminal.keyboard.hide", in: app)
        capture("Duo direct terminal", app)

        // This unauthenticated fixture follows the shared action's new-connection
        // fallback; live SSH coverage exercises the shared-channel branch.
        newTabButton.tap()
        let cancelNewConnection = try requireVisible("connection.cancel", in: app)
        cancelNewConnection.tap()

        switcherButton.tap()
        _ = try requireVisible("connection.switcher", in: app)
        let selectionRows = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "connection.switcher.tab.select.")
        )
        XCTAssertGreaterThan(selectionRows.count, 0)
        capture("Duo connection switcher", app)
    }

    func testTmuxTerminalAndKeyboardAccessoryRemainReachable() throws {
        try requireExplicitDuoRun()
        let app = launch(surface: "tmux")
        let switcherButton = try requireVisible("connection.pill", in: app)
        _ = try requireVisible("tmux.window.new", in: app)
        _ = try requireVisible("terminal.keyboard.bar", in: app)
        _ = try requireVisible("terminal.keyboard.hide", in: app)
        capture("Duo tmux terminal", app)

        switcherButton.tap()
        _ = try requireVisible("connection.switcher.tmux.window.select.1", in: app)
        capture("Duo tmux connection switcher", app)
    }

    private func requireExplicitDuoRun() throws {
        guard ProcessInfo.processInfo.environment["SSHAPP_DUO_LAYOUT_TESTS"] == "1" else {
            throw XCTSkip("Duo layout tests run only through SSHAppDuoLayoutTests.xctestplan")
        }
        continueAfterFailure = false
    }

    private func launch(surface: String? = nil, modal: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--sshapp-in-memory-store", "--sshapp-reset-state"]
        if let surface {
            app.launchArguments.append("--sshapp-ui-test-duo-layout=\(surface)")
        }
        if let modal {
            app.launchArguments.append("--sshapp-ui-test-duo-modal=\(modal)")
        }
        UITestDeviceHealth.launchDuo(app, for: self, disablesIdleWait: true)
        addTeardownBlock { @MainActor in
            UITestDeviceHealth.terminateDuo(app)
        }
        return app
    }

    @discardableResult
    private func requireVisible(
        _ identifier: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> XCUIElement {
        let element = app.descendants(matching: .any)[identifier]
        XCTAssertTrue(element.waitForExistence(timeout: 12), "Missing \(identifier)", file: file, line: line)
        XCTAssertTrue(element.isHittable, "\(identifier) is not visible and tappable", file: file, line: line)
        return element
    }

    private func requireButtonVisible(
        _ label: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let element = app.buttons[label].firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 12), "Missing \(label) action", file: file, line: line)
        XCTAssertTrue(element.isHittable, "\(label) action is not visible and tappable", file: file, line: line)
    }

    private func requireButtonReachable(
        _ label: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let element = app.buttons[label].firstMatch
        for _ in 0..<4 where !element.exists || !element.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(element.exists, "Missing \(label) action", file: file, line: line)
        XCTAssertTrue(element.isHittable, "\(label) action is not reachable", file: file, line: line)
    }

    private func capture(_ name: String, _ app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
