import UIKit
import Vision
import XCTest

struct LiveSSHTestConfiguration {
    enum CredentialPersistence {
        case decline
        case savePassword
    }

    let destination: String
    let password: String?
    let acceptUnknownHost: Bool
    let credentialPersistence: CredentialPersistence
    let enableDefaultTmuxStartup: Bool
    let connectionTimeout: TimeInterval

    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> LiveSSHTestConfiguration {
        guard let destination = nonemptyValue(
            environment["SSHAPP_LIVE_SSH_DESTINATION"]
        ) else {
            throw XCTSkip(
                "Set SSHAPP_LIVE_SSH_DESTINATION to run opt-in live SSH UI tests."
            )
        }

        let timeout = environment["SSHAPP_LIVE_SSH_TIMEOUT"]
            .flatMap(TimeInterval.init) ?? 45

        return LiveSSHTestConfiguration(
            destination: destination,
            password: passwordValue(environment["SSHAPP_LIVE_SSH_PASSWORD"]),
            acceptUnknownHost: booleanValue(
                environment["SSHAPP_LIVE_SSH_ACCEPT_UNKNOWN_HOST"]
            ),
            credentialPersistence: booleanValue(
                environment["SSHAPP_LIVE_SSH_SAVE_PASSWORD"]
            ) ? .savePassword : .decline,
            enableDefaultTmuxStartup: booleanValue(
                environment["SSHAPP_LIVE_SSH_ENABLE_DEFAULT_TMUX"]
            ),
            connectionTimeout: timeout
        )
    }

    private static func nonemptyValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func booleanValue(_ value: String?) -> Bool {
        guard let value else { return false }
        return ["1", "true", "yes", "on"].contains(value.lowercased())
    }

    private static func passwordValue(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

/// Reusable driver for opt-in UI tests that connect to a real SSH host.
///
/// The harness deliberately reads credentials only from the test process
/// environment. It never stores them in source, attachments, or failure
/// messages, and clears the simulator pasteboard after each terminal write.
@MainActor
final class LiveSSHUITestHarness {
    let app = XCUIApplication()

    private unowned let testCase: XCTestCase

    init(testCase: XCTestCase) {
        self.testCase = testCase
    }

    func launch(resetState: Bool = true) {
        app.launchArguments = ["--sshapp-in-memory-store"]
        if resetState {
            app.launchArguments.append("--sshapp-reset-state")
        }
        app.launch()

        // Ghostty's display link continuously redraws terminal surfaces. XCTest
        // would otherwise wait forever for the app to become "idle" before and
        // after synthesized events.
        app.setValue(NSNumber(value: 3), forKey: "currentInteractionOptions")
    }

    func terminate() {
        if app.state != .notRunning {
            app.terminate()
        }
        UIPasteboard.general.string = nil
    }

    func createConnectionAndAuthenticate(
        using configuration: LiveSSHTestConfiguration
    ) throws {
        let newConnection = app.buttons["connection.new"]
        try waitForElement(
            newConnection,
            description: "New Connection button"
        )
        newConnection.tap()

        let destination = app.textFields["connection.destination"]
        try waitForElement(destination, description: "connection destination")
        destination.tap()
        destination.typeText(configuration.destination)

        if configuration.enableDefaultTmuxStartup {
            setSwitch(
                app.switches["connection.autoRunCommand.enabled"],
                enabled: true
            )
        }

        let connect = app.buttons["connection.connect"]
        try waitForElement(connect, description: "Connect button")
        XCTAssertTrue(connect.isEnabled)
        connect.tap()

        try completeAuthentication(using: configuration)
    }

    func sendCommand(
        _ command: String,
        to terminalCoordinate: CGVector = CGVector(dx: 0.5, dy: 0.6)
    ) throws {
        try sendRawText("\(command)\n", to: terminalCoordinate)
    }

    func sendRawText(
        _ text: String,
        to terminalCoordinate: CGVector = CGVector(dx: 0.5, dy: 0.6)
    ) throws {
        let terminal = terminalView(at: terminalCoordinate)
        try waitForElement(terminal, description: "terminal surface")
        terminal.tap()

        UIPasteboard.general.string = text
        let paste = app.buttons.matching(
            NSPredicate(format: "identifier == %@", "doc.on.clipboard")
        ).firstMatch
        try waitForElement(paste, timeout: 3, description: "terminal Paste button")
        paste.tap()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allowPaste = springboard.buttons["Allow Paste"]
        if allowPaste.waitForExistence(timeout: 1) {
            allowPaste.tap()
        }

        wait(seconds: 0.4)
        UIPasteboard.general.string = nil
    }

    @discardableResult
    func assertScreen(
        containsExactPhrase words: [String],
        timeout: TimeInterval = 15,
        attachmentName: String
    ) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var latest = ""

        while Date() < deadline {
            latest = try recognizedScreenText()
            if containsExactPhrase(words, in: latest) {
                recordScreen(
                    name: attachmentName,
                    recognizedText: latest
                )
                return latest
            }
            wait(seconds: 0.5)
        }

        recordScreen(
            name: "\(attachmentName)-timeout",
            recognizedText: latest
        )
        XCTFail(
            "Timed out waiting for screen phrase \(words.joined(separator: " "))."
        )
        throw LiveSSHUITestHarnessError.assertionFailed
    }

    func revealScrollback(
        containingExactPhrase words: [String],
        inPaneAt paneCoordinate: CGVector,
        attempts: Int = 12,
        attachmentName: String
    ) throws {
        for _ in 0..<attempts {
            dragBackInTerminal(at: paneCoordinate)
            wait(seconds: 0.3)

            let text = try recognizedScreenText()
            if containsExactPhrase(words, in: text) {
                recordScreen(
                    name: attachmentName,
                    recognizedText: text
                )
                return
            }
        }

        recordScreen(name: "\(attachmentName)-not-found")
        XCTFail(
            "Did not find scrollback phrase \(words.joined(separator: " "))."
        )
        throw LiveSSHUITestHarnessError.assertionFailed
    }

    func tmuxWindowTabs(expectedCount: Int? = nil) throws -> [XCUIElement] {
        let matches = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier MATCHES %@",
                #"^tmux[.]window[.]tab[.][0-9]+$"#
            )
        ).allElementsBoundByIndex
        let grouped = Dictionary(grouping: matches, by: \.identifier)
        let tabs = grouped.values.compactMap { duplicates in
            duplicates.first(where: \.isHittable) ?? duplicates.first
        }.sorted { $0.identifier < $1.identifier }

        if let expectedCount, tabs.count != expectedCount {
            recordScreen(name: "unexpected-tmux-window-tab-count")
            XCTFail(
                "Expected \(expectedCount) tmux window tabs, found \(tabs.count)."
            )
            throw LiveSSHUITestHarnessError.assertionFailed
        }
        return tabs
    }

    func recognizedScreenText() throws -> String {
        let screenshot = XCUIScreen.main.screenshot()
        guard let image = screenshot.image.cgImage else {
            throw LiveSSHUITestHarnessError.missingImage
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])

        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    func recordScreen(name: String, recognizedText: String? = nil) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        testCase.add(screenshot)

        if let recognizedText {
            let text = XCTAttachment(string: recognizedText)
            text.name = "\(name)-ocr"
            text.lifetime = .keepAlways
            testCase.add(text)
        }
    }

    private func completeAuthentication(
        using configuration: LiveSSHTestConfiguration
    ) throws {
        let deadline = Date().addingTimeInterval(configuration.connectionTimeout)
        var acceptedHost = false
        var submittedPassword = false

        while Date() < deadline {
            if authenticationIsComplete {
                return
            }

            if credentialPromptIsVisible {
                try resolveCredentialPrompt(
                    persistence: configuration.credentialPersistence
                )
                wait(seconds: 0.5)
                continue
            }

            let text = try recognizedScreenText()
            if isUnknownHostPrompt(text), !acceptedHost {
                guard configuration.acceptUnknownHost else {
                    recordScreen(
                        name: "live-ssh-unknown-host",
                        recognizedText: text
                    )
                    XCTFail(
                        "The host is unknown. Verify its fingerprint, then set "
                            + "SSHAPP_LIVE_SSH_ACCEPT_UNKNOWN_HOST=1 to accept it."
                    )
                    throw LiveSSHUITestHarnessError.assertionFailed
                }

                try sendRawText("yes\n")
                acceptedHost = true
                wait(seconds: 1)
                continue
            }

            if isPasswordPrompt(text), !submittedPassword {
                guard let password = configuration.password else {
                    recordScreen(name: "live-ssh-password-required")
                    XCTFail(
                        "The host requested a password, but "
                            + "SSHAPP_LIVE_SSH_PASSWORD is not set."
                    )
                    throw LiveSSHUITestHarnessError.assertionFailed
                }

                try sendRawText("\(password)\n")
                submittedPassword = true
                wait(seconds: 1)
                continue
            }

            if isAuthenticationFailure(text) {
                recordScreen(
                    name: "live-ssh-authentication-failed",
                    recognizedText: text
                )
                XCTFail("The live SSH host rejected authentication.")
                throw LiveSSHUITestHarnessError.assertionFailed
            }

            wait(seconds: 0.5)
        }

        recordScreen(name: "live-ssh-authentication-timeout")
        XCTFail("Timed out while authenticating to the live SSH host.")
        throw LiveSSHUITestHarnessError.assertionFailed
    }

    private var credentialPromptIsVisible: Bool {
        app.descendants(matching: .any)["credentialSave.username"].exists
            || app.descendants(matching: .any)["credentialSave.password"].exists
    }

    private var authenticationIsComplete: Bool {
        let pill = app.buttons["connection.pill"]
        guard pill.exists else { return false }
        return Self.authenticationIsComplete(
            connectionPillValue: pill.value as? String
        )
    }

    static func authenticationIsComplete(connectionPillValue: String?) -> Bool {
        connectionPillValue?.caseInsensitiveCompare("Connected") == .orderedSame
    }

    private func resolveCredentialPrompt(
        persistence: LiveSSHTestConfiguration.CredentialPersistence
    ) throws {
        switch persistence {
        case .decline:
            let notNow = app.buttons["Not Now"]
            try waitForElement(notNow, description: "Not Now button")
            notNow.tap()

        case .savePassword:
            let saveUsername = app.switches["credentialSave.username"]
            if saveUsername.exists {
                setSwitch(saveUsername, enabled: true)
            }

            let savePassword = app.switches["credentialSave.password"]
            try waitForElement(
                savePassword,
                description: "Save Password toggle"
            )
            setSwitch(savePassword, enabled: true)

            let save = app.buttons["Save"]
            try waitForElement(save, description: "credential Save button")
            XCTAssertTrue(save.isEnabled)
            save.tap()
        }
    }

    private func setSwitch(_ element: XCUIElement, enabled: Bool) {
        guard element.exists else {
            XCTFail("Expected switch \(element.identifier) to exist.")
            return
        }

        let currentValue = element.value as? String
        let expectedValue = enabled ? "1" : "0"
        if currentValue != expectedValue {
            element.coordinate(
                withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)
            ).tap()
        }
        XCTAssertEqual(element.value as? String, expectedValue)
    }

    private func terminalView(at coordinate: CGVector) -> XCUIElement {
        let window = app.windows.firstMatch
        let frame = window.frame
        let point = CGPoint(
            x: frame.minX + (frame.width * coordinate.dx),
            y: frame.minY + (frame.height * coordinate.dy)
        )
        return app.textViews.allElementsBoundByIndex.first(where: {
            $0.frame.contains(point)
        }) ?? app.textViews.firstMatch
    }

    private func dragBackInTerminal(at coordinate: CGVector) {
        let terminal = terminalView(at: coordinate)
        let start = terminal.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)
        )
        let end = terminal.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)
        )
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    private func containsExactPhrase(_ words: [String], in text: String) -> Bool {
        normalized(text).contains(
            normalized(words.joined(separator: " "))
        )
    }

    private func normalized(_ text: String) -> String {
        text
            .uppercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private func isUnknownHostPrompt(_ text: String) -> Bool {
        let normalizedText = normalized(text)
        return normalizedText.contains("ARE YOU SURE YOU WANT TO CONTINUE")
            || (
                normalizedText.contains("AUTHENTICITY OF HOST")
                    && normalizedText.contains("ESTABLISHED")
            )
    }

    private func isPasswordPrompt(_ text: String) -> Bool {
        normalized(text).contains("PASSWORD")
    }

    private func isAuthenticationFailure(_ text: String) -> Bool {
        let normalizedText = normalized(text)
        return normalizedText.contains("PERMISSION DENIED")
            || normalizedText.contains("AUTHENTICATION FAILED")
            || normalizedText.contains("CONNECTION REFUSED")
    }

    private func waitForElement(
        _ element: XCUIElement,
        timeout: TimeInterval = 10,
        description: String
    ) throws {
        guard element.waitForExistence(timeout: timeout) else {
            recordScreen(
                name: "missing-\(description.replacingOccurrences(of: " ", with: "-"))"
            )
            XCTFail("Timed out waiting for \(description).")
            throw LiveSSHUITestHarnessError.assertionFailed
        }
    }

    private func wait(seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}

private enum LiveSSHUITestHarnessError: Error {
    case assertionFailed
    case missingImage
}
