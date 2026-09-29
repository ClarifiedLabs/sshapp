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
/// messages, and clears the clipboard after each terminal write.
@MainActor
final class LiveSSHUITestHarness {
    let app = XCUIApplication()

    private unowned let testCase: XCTestCase
    private var lastPaneOCRCapture: (image: CGImage, geometry: String)?

    init(testCase: XCTestCase) {
        self.testCase = testCase
    }

    func launch(resetState: Bool = true, simulatedAuthentication: Bool = false) {
        app.launchArguments = ["--sshapp-in-memory-store", "--sshapp-ui-test-live-ssh"]
        if resetState {
            app.launchArguments.append("--sshapp-reset-state")
        }
        if simulatedAuthentication {
            app.launchArguments.append("--sshapp-ui-test-authentication")
        }
        // Ghostty's display link continuously redraws terminal surfaces. XCTest
        // would otherwise wait forever for the app to become "idle" before and
        // after synthesized events.
        // A reset launch always shows the no-tabs home and its New Connection
        // button; a wedged launch leaves that button at hit point {-1,-1}.
        UITestDeviceHealth.launch(app, for: testCase, disablesIdleWait: true,
                                  rootElement: resetState ? { $0.buttons["connection.new"] } : nil)
    }

    func terminate() {
        // Clear the test pasteboard only after SpringBoard has settled.
        UITestDeviceHealth.terminate(app)
        TestPasteboard.setText(nil, returningTo: app)
    }

    /// Prepares the real connection sheet without saving, connecting, or authenticating.
    func prepareConnectionForm(
        using configuration: LiveSSHTestConfiguration,
        startupCommand: String? = nil
    ) throws {
        let newConnection = app.buttons["connection.new"]
        try waitForElement(
            newConnection,
            description: "New Connection button"
        )
        newConnection.tap()

        let destination = app.textFields["connection.destination"]
        try waitForElement(destination, description: "connection destination")
        try typeVerified(configuration.destination, into: destination, description: "connection destination")

        if startupCommand != nil || configuration.enableDefaultTmuxStartup {
            // Wait for the destination keyboard before measuring the exposed form.
            try waitForElement(app.keyboards.firstMatch, description: "connection keyboard")
            try setSwitch(
                app.switches["connection.autoRunCommand.enabled"],
                enabled: true
            )
        }

        if let startupCommand {
            try replaceStartupCommand(with: startupCommand)
        }
    }

    func createConnectionAndAuthenticate(
        using configuration: LiveSSHTestConfiguration,
        startupCommand: String? = nil
    ) throws {
        do {
            try connectAndAuthenticate(using: configuration, startupCommand: startupCommand)
        } catch LiveSSHUITestHarnessError.localNetworkPermissionGranted {
            // Close the attempt that failed behind the prompt, then connect once more.
            let close = app.buttons["terminal.error.close"]
            try waitForElement(close, description: "failed connection Close button")
            close.tap()
            try connectAndAuthenticate(using: configuration, startupCommand: startupCommand)
        }
    }

    private func connectAndAuthenticate(
        using configuration: LiveSSHTestConfiguration,
        startupCommand: String?
    ) throws {
        try prepareConnectionForm(using: configuration, startupCommand: startupCommand)
        let destination = app.textFields["connection.destination"]
        let connect = app.buttons["connection.connect"]
        for attempt in 1...2 {
            try waitForStableHittable(connect, description: "Connect button")
            if attempt == 1 {
                connect.tap()
            } else {
                connect.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
            if waitUntil(timeout: 5, { !destination.exists }) { break }
            // Retry only while the original form is still present and no
            // connection has appeared. Never submit a second connection.
            guard attempt == 1, destination.exists,
                  !app.buttons["connection.pill"].exists else {
                try fail("Connect did not dismiss the connection sheet.")
            }
        }
        guard waitUntil(timeout: 10, { self.app.buttons["connection.pill"].exists }) else {
            try fail("The connection sheet closed, but no session appeared.")
        }
        try completeAuthentication(using: configuration)
    }

    /// Uses native editing actions, not typing, so smart quotes/autocapitalization
    /// cannot rewrite shell syntax. No connection is attempted on any mismatch.
    func replaceStartupCommand(with command: String) throws {
        let editor = app.textViews["connection.autoRunCommand.text"]
        try waitForElement(editor, description: "startup command editor")
        // The destination field is still focused. Wait for its keyboard before
        // choosing coordinates; app activation can briefly omit it from AX.
        try waitForElement(app.keyboards.firstMatch, description: "connection keyboard")
        try revealFormElement(editor, description: "startup command editor")

        guard let previous = editor.value as? String else {
            XCTFail("Startup command editor has no readable value; refusing to connect.")
            throw LiveSSHUITestHarnessError.assertionFailed
        }
        if !previous.isEmpty {
            // Show the insertion-point menu in the blank area below the text.
            // Select All makes deletion independent of caret position/text length.
            let insertionPoint = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.95))
            insertionPoint.tap()
            // Native iPad keyboard dismissal survives between app launches. On
            // focus, the destination's full keyboard can collapse to its input
            // assistant and animate the sheet downward. AX already reports the
            // final frame while that animation is still moving the hit target;
            // a press immediately after the focus tap opens no edit menu.
            // Revalidate exposed, settled geometry before resolving coordinates.
            try revealFormElement(editor, description: "focused startup command editor")
            editor.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.95))
                .press(forDuration: 1)
            try startupEditMenuAction("Select All").tap()
            editor.typeText(XCUIKeyboardKey.delete.rawValue)
        }
        try assertStartupCommandEquals("")

        TestPasteboard.setText(command, returningTo: app)
        defer { TestPasteboard.setText(nil, returningTo: app) }
        try waitForElement(app.keyboards.firstMatch, description: "startup editor keyboard")
        try waitForStableHittable(editor, description: "startup editor after clipboard activation")
        editor.press(forDuration: 1)
        try startupEditMenuAction("Paste").tap()
        // Paste once only; wait for the resulting value (and OS paste permission).
        try assertStartupCommandEquals(command)
    }

    func assertStartupCommandEquals(_ expected: String) throws {
        let editor = app.textViews["connection.autoRunCommand.text"]
        guard waitUntil(timeout: 5, {
            self.allowPasteIfNeeded()
            return editor.value as? String == expected
        }) else {
            let actual = editor.value as? String
            let hasCurlyQuotes = actual?.contains(where: { "‘’“”".contains($0) }) ?? false
            let initialLetterCapitalized = actual?.first != expected.first
                && actual?.first?.lowercased() == expected.first?.lowercased()
                && actual?.first?.isUppercase == true
            // Do not use XCTAssertEqual(String, String) or fail(): either can
            // expose the command through assertion output or a screenshot.
            XCTFail("Startup command mismatch; refusing to connect. "
                + "expectedLength=\(expected.count); actualLength=\(actual?.count ?? -1); "
                + "hasCurlyQuotes=\(hasCurlyQuotes); initialLetterCapitalized=\(initialLetterCapitalized)")
            throw LiveSSHUITestHarnessError.assertionFailed
        }
    }

    private func startupEditMenuAction(_ title: String) throws -> XCUIElement {
        let button = app.buttons[title]
        let menuItem = app.menuItems[title]
        guard waitUntil(timeout: 5, {
            (button.exists && button.isHittable) || (menuItem.exists && menuItem.isHittable)
        }) else {
            // No screenshot: the startup editor may contain private command text.
            XCTFail("Startup editor \(title) action unavailable; refusing to connect.")
            throw LiveSSHUITestHarnessError.assertionFailed
        }
        return button.exists && button.isHittable ? button : menuItem
    }

    func sendCommand(
        _ command: String,
        to terminal: XCUIElement? = nil
    ) throws {
        // A shell with bracketed paste inserts pasted newlines without executing
        // them. Paste only the command, then send a real Return key exactly once.
        let target = terminal ?? defaultTerminalView
        try sendRawText(command, to: target)
        // Clearing the device clipboard foregrounds the test runner, then
        // reactivates this app. Idleness is disabled: do not type Return into
        // the app-switch animation before the terminal regains keyboard focus.
        try waitForTerminalFocus(target)
        guard authenticationIsComplete else {
            try fail("Connection changed before command submission.")
        }
        try pressReturn()
    }

    /// After the clipboard app switch, the out-of-process keyboard can still be
    /// reconnecting, and a synthesized `typeText("\n")` is silently dropped.
    /// Tap the keyboard's own Return key once it is hittable, like a user.
    private func pressReturn() throws {
        let returnKey = app.keyboards.buttons["Return"]
        if returnKey.waitForExistence(timeout: 2) {
            try waitForStableHittable(returnKey, description: "keyboard Return key")
            returnKey.tap()
        } else {
            // A connected hardware keyboard hides the software keyboard.
            app.typeText("\n")
        }
    }

    func sendRawText(
        _ text: String,
        to terminal: XCUIElement? = nil,
        authenticationStatus: LiveSSHUIStatus? = nil
    ) throws {
        let target = terminal ?? defaultTerminalView
        try waitForElement(target, description: "terminal surface")
        TestPasteboard.setText(text, returningTo: app)
        defer { TestPasteboard.setText(nil, returningTo: app) }
        // Keep the pane element, not a screen coordinate that can move across
        // splits when keyboard geometry changes during clipboard reactivation.
        try waitForStableHittable(target, description: "target terminal after clipboard activation")
        // Tapping an already focused terminal can dismiss its keyboard.
        if target.value(forKey: "hasKeyboardFocus") as? Bool != true { target.tap() }
        try failIfHardwareKeyboardConnected()
        try restoreSoftwareKeyboardIfSuppressed()
        try waitForTerminalFocus(target)
        let paste = app.buttons["terminal.keyboard.paste"]
        try revealPasteButton(paste)
        try waitForStableHittable(paste, description: "terminal Paste button")
        guard let before = status else { try fail("Missing live SSH input observations.") }
        if let expected = authenticationStatus {
            guard before.prompt == expected.prompt,
                  before.promptRevision == expected.promptRevision,
                  before.submissionRevision == expected.submissionRevision else {
                try fail("Authentication prompt changed before input; refusing to paste.")
            }
        }
        let acknowledgment = LiveSSHInputAcknowledgment(
            before: before, authenticating: authenticationStatus != nil
        )
        guard let current = status, acknowledgment.canStartSubmission(current) else {
            try fail("Input state changed before submission.")
        }
        paste.tap()
        // System PasteButton loads its payload asynchronously. Never tap it a
        // second time: a delayed first callback could otherwise duplicate a password.
        var confirmedUnsafePaste = false
        var confirmationStability = LiveSSHPasteConfirmationStability()
        guard waitUntil(timeout: 10, {
            if self.status.map(acknowledgment.isComplete) == true { return true }
            self.allowPasteIfNeeded()
            // Authentication responses and explicitly multiline payloads include
            // Return. Confirm this one payload, never retry Paste or approve
            // a delayed confirmation after the authentication prompt changes.
            let confirmation = self.app.alerts["Paste potentially unsafe text?"]
            if !confirmedUnsafePaste {
                let confirm = confirmation.buttons["Paste"]
                let eligible = confirmation.exists && confirm.isEnabled && confirm.isHittable
                    && self.status.map(acknowledgment.canConfirmPendingPaste) == true
                let stable = confirmationStability.isReady(
                    frame: eligible ? confirm.frame : nil,
                    at: ProcessInfo.processInfo.systemUptime
                )
                // Revalidate after geometry queries. Settling never authorizes
                // input for a changed prompt or retries an attempted confirmation.
                if stable, let current = self.status,
                   acknowledgment.canConfirmPendingPaste(current) {
                    confirmedUnsafePaste = true
                    confirm.tap()
                }
            }
            return false
        }) else {
            let confirmation = app.alerts["Paste potentially unsafe text?"]
            // Scalar-only diagnostics: alert contents may contain credentials.
            try fail("Terminal input was not acknowledged. Status: \(statusDescription); "
                + "safetyConfirmationVisible=\(confirmation.exists); "
                + "safetyConfirmationAttempted=\(confirmedUnsafePaste)")
        }
    }

    /// A hardware keyboard replaces the software keyboard with iPadOS's
    /// minimized keyboard pill, which can sit over the app's Show Keyboard
    /// control, so the keyboard bar this harness pastes through never appears.
    /// That is a device setup problem, not an app failure: say so immediately.
    ///
    /// Device only: the Simulator bridges the Mac keyboard into GameController
    /// even with "Connect Hardware Keyboard" off, while still presenting the
    /// software keyboard, so the signal is meaningless there.
    private func failIfHardwareKeyboardConnected() throws {
        #if !targetEnvironment(simulator)
        guard status?.hardwareKeyboardConnected == true else { return }
        try fail(Self.hardwareKeyboardMessage)
        #endif
    }

    static let hardwareKeyboardMessage =
        "Disconnect the hardware keyboard: live SSH tests need the software keyboard."

    /// Software-keyboard suppression is session state: a native dismissal
    /// the app classifies as the user's leaves the terminal suppressed, with
    /// a Show Keyboard control in place of the keyboard bar.
    ///
    /// The app clears the input-assistant shortcuts while suppressed and keeps
    /// the control above any keyboard UI (the iPadOS 26+ minimized pill used to
    /// cover it on 13-inch iPads), so an ordinary centre tap must restore.
    private func restoreSoftwareKeyboardIfSuppressed() throws {
        let showKeyboard = app.buttons["terminal.keyboard.show"]
        guard showKeyboard.exists else { return }
        try waitForStableHittable(showKeyboard, description: "Show Keyboard control")
        showKeyboard.tap()
        if waitUntil(timeout: 3, {
            !showKeyboard.exists && self.status?.softwareKeyboardSuppressed != true
        }) {
            return
        }
        attachKeyboardDiagnostics(name: "show-keyboard-not-restored")
        try fail("Show Keyboard did not restore the software keyboard. Status: \(statusDescription)")
    }

    /// Scalar app keyboard state plus the accessibility trees that can explain
    /// a missing keyboard bar: the app's keyboard window and SpringBoard/InputUI
    /// keyboard elements. Values are omitted: terminal text can echo input.
    private func attachKeyboardDiagnostics(name: String) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let sections = [
            "status: \(statusDescription)",
            "app.keyboards.count: \(app.keyboards.count)",
            "terminal.keyboard.show: \(elementSummary(app.buttons["terminal.keyboard.show"]))",
            "terminal.keyboard.hide: \(elementSummary(app.buttons["terminal.keyboard.hide"]))",
            "terminal.keyboard.paste: \(elementSummary(app.buttons["terminal.keyboard.paste"]))",
            "app.debugDescription:\n" + redactedTree(app.debugDescription),
            "springboard keyboard elements:\n" + redactedTree(springboard.debugDescription, keyboardOnly: true),
        ]
        let attachment = XCTAttachment(string: sections.joined(separator: "\n\n"))
        attachment.name = name
        attachment.lifetime = .keepAlways
        testCase.add(attachment)
    }

    private func elementSummary(_ element: XCUIElement) -> String {
        guard element.exists else { return "absent" }
        return "frame=\(element.frame) hittable=\(element.isHittable)"
    }

    private func redactedTree(_ tree: String, keyboardOnly: Bool = false) -> String {
        tree.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                guard !keyboardOnly else {
                    let lowered = line.lowercased()
                    return ["keyboard", "inputui", "assistant", "dictation", "pill"]
                        .contains { lowered.contains($0) }
                }
                return true
            }
            .map { line -> String in
                // Drop accessibility values; keep element type, frame, identifier, label.
                guard let range = line.range(of: ", value: ") else { return String(line) }
                return String(line[..<range.lowerBound]) + ", value: <redacted>"
            }
            .joined(separator: "\n")
    }

    private func revealPasteButton(_ paste: XCUIElement) throws {
        let hideKeyboard = app.buttons["terminal.keyboard.hide"]
        do {
            try waitForStableHittable(hideKeyboard, description: "keyboard bar anchor")
        } catch {
            attachKeyboardDiagnostics(name: "keyboard-bar-anchor-missing")
            // Re-check: the keyboard may have connected after input started.
            try failIfHardwareKeyboardConnected()
            throw error
        }
        let window = app.windows.firstMatch
        for _ in 0..<8 {
            if paste.exists, paste.isHittable { return }
            // SwiftUI's scroll-view accessibility bounds can extend into the
            // software keyboard. Anchor the drag to the fixed Hide button's
            // row, where the visible shortcut bar actually is.
            let viewport = CGRect(
                x: window.frame.minX + 8,
                y: hideKeyboard.frame.minY,
                width: hideKeyboard.frame.minX - window.frame.minX - 8,
                height: hideKeyboard.frame.height
            )
            guard viewport.width > 60, viewport.height > 0 else {
                try fail("Keyboard action bar has no usable viewport.")
            }
            let origin = window.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(
                dx: viewport.maxX - window.frame.minX - 20,
                dy: viewport.midY - window.frame.minY
            ))
            let end = origin.withOffset(CGVector(
                dx: viewport.minX - window.frame.minX + 20,
                dy: viewport.midY - window.frame.minY
            ))
            start.press(forDuration: 0.05, thenDragTo: end)
            var lastFrame = paste.frame
            var stableSince = Date()
            _ = waitUntil(timeout: 2, {
                let frame = paste.frame
                if frame != lastFrame {
                    lastFrame = frame
                    stableSince = Date()
                }
                return Date().timeIntervalSince(stableSince) >= 0.3
            })
        }
        try fail("Could not reveal terminal Paste button. Anchor: \(hideKeyboard.frame), Paste: \(paste.frame)")
    }

    private var status: LiveSSHUIStatus? {
        let element = app.staticTexts["liveSSH.status"]
        guard element.exists else { return nil }
        return try? JSONDecoder().decode(LiveSSHUIStatus.self, from: Data(element.label.utf8))
    }

    /// XCTest's idle wait is disabled, so status labels can lag the action
    /// that changes them. Poll until the published status satisfies `predicate`.
    func waitForStatus(
        _ description: String,
        timeout: TimeInterval = 10,
        where predicate: @escaping (LiveSSHUIStatus) -> Bool
    ) throws -> LiveSSHUIStatus {
        var matched: LiveSSHUIStatus?
        _ = waitUntil(timeout: timeout) {
            matched = self.status.flatMap { predicate($0) ? $0 : nil }
            return matched != nil
        }
        guard let matched else { try fail("Timed out waiting for \(description): \(statusDescription)") }
        return matched
    }

    func waitForLabel(_ element: XCUIElement, equals expected: String, timeout: TimeInterval = 10) throws {
        guard waitUntil(timeout: timeout, { element.exists && element.label == expected }) else {
            try fail("Timed out waiting for \(element.identifier) to read \(expected)")
        }
    }

    private var statusDescription: String {
        let element = app.staticTexts["liveSSH.status"]
        return element.exists ? element.label : "unavailable"
    }

    private func allowPasteIfNeeded() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for application in [app, springboard] {
            let allow = application.buttons["Allow Paste"]
            if allow.exists, allow.isHittable { allow.tap(); return }
        }
    }

    @discardableResult
    func assertScreen(
        containsExactPhrase words: [String],
        timeout: TimeInterval = 15,
        inPane pane: XCUIElement? = nil,
        attachmentName: String
    ) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var latest = ""

        while Date() < deadline {
            latest = try recognizedScreenText(inPane: pane)
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
        inPane pane: XCUIElement,
        attempts: Int = 12,
        attachmentName: String
    ) throws {
        for _ in 0..<attempts {
            dragBackInTerminal(pane)
            wait(seconds: 0.3)

            let text = try recognizedScreenText(inPane: pane)
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

    func recognizedScreenText(inPane pane: XCUIElement? = nil) throws -> String {
        let image: CGImage
        if let pane {
            let appFrame = app.frame
            let paneFrame = pane.frame.intersection(appFrame)
            // XCTest's app screenshot can have landscape CG dimensions but a
            // portrait oriented UIImage. Use the actual full-screen capture,
            // normalized once, then crop strictly to this pane's screen bounds.
            let screenshot = XCUIScreen.main.screenshot().image
            let captureFrame = CGRect(origin: .zero, size: screenshot.size)
            guard let fullImage = TerminalScreenshotCrop.normalizedImage(screenshot),
                  let crop = TerminalScreenshotCrop.pixelRect(
                    region: paneFrame, captureFrame: captureFrame,
                    pixelSize: CGSize(width: fullImage.width, height: fullImage.height)),
                  let cropped = fullImage.cropping(to: crop),
                  let recognitionImage = TerminalScreenshotCrop.imageForRecognition(cropped) else {
                throw LiveSSHUITestHarnessError.missingImage
            }
            lastPaneOCRCapture = (recognitionImage, "source=normalized-screen; captureFrame=\(captureFrame); appFrame=\(appFrame); paneFrame=\(paneFrame); sourceOrientation=\(screenshot.imageOrientation.rawValue); imagePixels=\(fullImage.width)x\(fullImage.height); crop=\(crop)")
            return try TerminalScreenshotCrop.recognizedText(in: recognitionImage)
        } else {
            lastPaneOCRCapture = nil
            guard let fullImage = TerminalScreenshotCrop.normalizedImage(XCUIScreen.main.screenshot().image) else {
                throw LiveSSHUITestHarnessError.missingImage
            }
            image = fullImage
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        // Terminal text is ASCII; auto-detection can return Cyrillic look-alikes.
        request.automaticallyDetectsLanguage = false
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: image).perform([request])

        let fragments = (request.results ?? []).compactMap { observation -> TerminalOCRReadingOrder.Observation? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            return .init(text: text, boundingBox: observation.boundingBox)
        }
        return TerminalOCRReadingOrder.text(from: fragments)
    }

    func recordScreen(name: String, recognizedText: String? = nil) {
        if name.hasSuffix("-timeout"), let capture = lastPaneOCRCapture {
            let pixels = XCTAttachment(image: UIImage(cgImage: capture.image))
            pixels.name = "\(name)-actual-ocr-crop"
            pixels.lifetime = .keepAlways
            testCase.add(pixels)
            let geometry = XCTAttachment(string: capture.geometry)
            geometry.name = "\(name)-crop-geometry"
            geometry.lifetime = .keepAlways
            testCase.add(geometry)
        }
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

    /// A fresh install (device-test bundle IDs are distinct from the shipped
    /// app) triggers the system Local Network prompt on its first connection.
    /// Grant it so unattended device runs don't depend on someone tapping Allow.
    private func allowLocalNetworkIfPrompted() -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "local network")
        ).firstMatch
        guard alert.exists else { return false }
        let allow = alert.buttons["Allow"]
        guard allow.exists, allow.isHittable else { return false }
        allow.tap()
        return true
    }

    private func completeAuthentication(
        using configuration: LiveSSHTestConfiguration
    ) throws {
        let deadline = Date().addingTimeInterval(configuration.connectionTimeout)
        var acceptedHost = false
        var submittedPassword = false
        var allowedLocalNetwork = false

        while Date() < deadline {
            if authenticationIsComplete {
                return
            }

            if allowLocalNetworkIfPrompted() {
                allowedLocalNetwork = true
                wait(seconds: 1)
                continue
            }

            if credentialPromptIsVisible {
                try resolveCredentialPrompt(
                    persistence: configuration.credentialPersistence
                )
                wait(seconds: 0.5)
                continue
            }

            let observed = status
            let kind = observed?.prompt ?? "none"
            if kind == "changedHostKey" {
                XCTFail("The server's host key changed; refusing automatic acceptance.")
                throw LiveSSHUITestHarnessError.assertionFailed
            }
            if kind == "unknownHost", !acceptedHost {
                guard configuration.acceptUnknownHost else {
                    recordScreen(
                        name: "live-ssh-unknown-host",
                        recognizedText: nil
                    )
                    XCTFail(
                        "The host is unknown. Verify its fingerprint, then set "
                            + "SSHAPP_LIVE_SSH_ACCEPT_UNKNOWN_HOST=1 to accept it."
                    )
                    throw LiveSSHUITestHarnessError.assertionFailed
                }

                try sendRawText("yes\n", authenticationStatus: observed)
                acceptedHost = true
                wait(seconds: 1)
                continue
            }

            if kind == "password", !submittedPassword {
                guard let password = configuration.password else {
                    recordScreen(name: "live-ssh-password-required")
                    XCTFail(
                        "The host requested a password, but "
                            + "SSHAPP_LIVE_SSH_PASSWORD is not set."
                    )
                    throw LiveSSHUITestHarnessError.assertionFailed
                }

                try sendRawText("\(password)\n", authenticationStatus: observed)
                submittedPassword = true
                wait(seconds: 1)
                continue
            }

            let pill = app.buttons["connection.pill"]
            if pill.exists, pill.value as? String == "Failed" {
                // The attempt that raised the Local Network prompt fails while
                // the prompt is pending; the caller retries once after closing it.
                if allowedLocalNetwork {
                    throw LiveSSHUITestHarnessError.localNetworkPermissionGranted
                }
                recordScreen(name: "live-ssh-authentication-failed")
                XCTFail("The SSH connection failed during authentication.")
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
        return LiveSSHAuthenticationText.authenticationIsComplete(
            connectionPillValue: pill.value as? String
        )
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
                try setSwitch(saveUsername, enabled: true)
            }

            let savePassword = app.switches["credentialSave.password"]
            try waitForElement(
                savePassword,
                description: "Save Password toggle"
            )
            try setSwitch(savePassword, enabled: true)

            let save = app.buttons["Save"]
            try waitForElement(save, description: "credential Save button")
            XCTAssertTrue(save.isEnabled)
            save.tap()
        }
    }

    private func revealFormElement(_ element: XCUIElement, description: String) throws {
        let form = [app.collectionViews, app.tables, app.scrollViews].map {
            $0.containing(element.elementType, identifier: element.identifier).firstMatch
        }.first(where: \.exists)
        // Resolve the form once: after a scroll the element's cell can be
        // recycled, and `containing` would then no longer match the list.
        let formFrame = form?.frame

        // The AX keyboard frame excludes the iPad input assistant bar
        // (undo/redo, predictions, ~57pt), which still covers the form.
        let inputAssistantHeight: CGFloat = 64

        func visibleBounds() -> (top: CGFloat, bottom: CGFloat) {
            let frame = formFrame ?? app.frame
            let keyboard = app.keyboards.firstMatch
            let navigationBar = app.navigationBars.firstMatch
            let top = max(frame.minY, navigationBar.exists ? navigationBar.frame.maxY : frame.minY) + 24
            let bottom = min(frame.maxY, keyboard.exists
                ? keyboard.frame.minY - inputAssistantHeight : app.frame.maxY)
            return (top, bottom)
        }

        // Never ask for hittability of a recycled or off-screen row: XCTest
        // records "Activation point invalid" as a test failure instead of
        // returning false. Check the AX frame against the exposed band first.
        func elementFrame() -> CGRect? {
            guard element.exists else { return nil }
            let frame = element.frame
            return frame.isEmpty ? nil : frame
        }

        func isFullyVisible(_ frame: CGRect?) -> Bool {
            guard let frame else { return false }
            let bounds = visibleBounds()
            return frame.minY >= bounds.top - 12 && frame.maxY < bounds.bottom - 12
                && element.isHittable
        }

        // A short iPad landscape sheet exposes only ~200pt above the keyboard.
        // Fixed-length fast drags fling the list past small rows (recycling
        // them), so scroll by the measured offset and hold before lifting.
        var lastFrame = elementFrame()
        var lastScrollDown: Bool?
        for _ in 0..<6 {
            let frame = settledElementFrame(elementFrame)
            if isFullyVisible(frame) { break }
            guard let formFrame else { break }
            let bounds = visibleBounds()
            let top = bounds.top
            let bottom = bounds.bottom - 8
            guard bottom - top > 80 else { break }
            let scrollDown: Bool
            let needed: CGFloat
            if let frame {
                lastFrame = frame
                scrollDown = frame.minY < top - 12
                needed = scrollDown
                    ? (top + 12) - frame.minY
                    : frame.maxY - (bottom - 16)
            } else if let lastScrollDown {
                // The row was recycled by the previous drag: it overshot, so
                // reverse by a small step.
                scrollDown = !lastScrollDown
                needed = 60
            } else {
                scrollDown = (lastFrame?.minY ?? .greatestFiniteMagnitude) < top
                needed = 60
            }
            // UIScrollView consumes ~10pt of touch slop before panning.
            let distance = min(max(needed + 24, 40), bottom - top)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            // The list gutter cannot start an inner TextEditor scroll.
            let x = formFrame.minX - app.frame.minX + max(8, formFrame.width * 0.015)
            let startY = scrollDown ? top : bottom
            let endY = scrollDown ? top + distance : bottom - distance
            origin.withOffset(CGVector(dx: x, dy: startY - app.frame.minY)).press(
                forDuration: 0.05,
                thenDragTo: origin.withOffset(CGVector(dx: x, dy: endY - app.frame.minY)),
                withVelocity: .slow,
                thenHoldForDuration: 0.3
            )
            lastScrollDown = scrollDown
        }
        try waitForStableHittable(element, description: "fully visible \(description)")
        guard isFullyVisible(elementFrame()) else {
            // No screenshot: the form may contain private startup text or credentials.
            XCTFail("\(description) remains obscured; refusing to continue.")
            throw LiveSSHUITestHarnessError.assertionFailed
        }
    }

    /// Returns the element frame once it stops moving (scroll deceleration or
    /// keyboard/sheet animation), or nil if the row is not in the AX tree.
    private func settledElementFrame(_ frame: () -> CGRect?) -> CGRect? {
        var previous = frame()
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            wait(seconds: 0.2)
            let current = frame()
            if current == previous { return current }
            previous = current
        }
        return previous
    }

    private func setSwitch(_ element: XCUIElement, enabled: Bool) throws {
        try waitForElement(element, description: "switch \(element.identifier)")
        let expectedValue = enabled ? "1" : "0"
        if element.value as? String != expectedValue {
            try revealFormElement(element, description: "switch \(element.identifier)")
            element.coordinate(
                withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)
            ).tap()
        }
        // Tap once and wait for SwiftUI to publish the value. Never continue to
        // editing, connecting, or saving credentials after a failed toggle.
        guard waitUntil(timeout: 5, { element.value as? String == expectedValue }) else {
            XCTFail("Switch \(element.identifier) did not reach its expected value.")
            throw LiveSSHUITestHarnessError.assertionFailed
        }
    }

    private var defaultTerminalView: XCUIElement {
        let visible = app.textViews.allElementsBoundByIndex.filter(\.isHittable)
        return visible.first { $0.value(forKey: "hasKeyboardFocus") as? Bool == true }
            ?? visible.first ?? app.textViews.firstMatch
    }

    private func waitForTerminalFocus(_ terminal: XCUIElement) throws {
        guard waitUntil(timeout: 10, {
            terminal.exists && terminal.isHittable
                && terminal.value(forKey: "hasKeyboardFocus") as? Bool == true
        }) else { try fail("Target terminal did not regain keyboard focus.") }
        try waitForStableHittable(terminal, description: "target terminal keyboard focus")
        guard terminal.value(forKey: "hasKeyboardFocus") as? Bool == true else {
            try fail("Target terminal lost keyboard focus before input.")
        }
    }

    private func dragBackInTerminal(_ terminal: XCUIElement) {
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
            // A mid-test SpringBoard wedge looks like a missing element; mark
            // the run so the device runner stops instead of cascading.
            UITestDeviceHealth.recheckAfterTimeout(app, for: testCase)
            XCTFail("Timed out waiting for \(description).")
            throw LiveSSHUITestHarnessError.assertionFailed
        }
    }

    /// Types into a text field and verifies the value arrived. On iPad the
    /// first keystrokes can be swallowed while the software keyboard (or an
    /// AutoFill callout) is still appearing, so wait for a hittable keyboard
    /// first, then clear and retype once if the value does not match.
    func typeVerified(_ text: String, into field: XCUIElement, description: String) throws {
        try Self.typeVerified(text, into: field, in: app, description: description)
    }

    static func typeVerified(
        _ text: String, into field: XCUIElement, in app: XCUIApplication, description: String
    ) throws {
        for attempt in 1...2 {
            // A retry taps the trailing edge so deletion starts after the last character.
            if attempt == 1 {
                field.tap()
            } else {
                field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
            }
            let keyboard = app.keyboards.firstMatch
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline, !(keyboard.exists && keyboard.isHittable) {
                RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            }
            if attempt > 1, let current = field.value as? String, !current.isEmpty,
               current != field.placeholderValue {
                field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
            }
            field.typeText(text)
            let valueDeadline = Date().addingTimeInterval(2)
            while Date() < valueDeadline, field.value as? String != text {
                RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            }
            if field.value as? String == text { return }
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "typed-\(description.replacingOccurrences(of: " ", with: "-"))-mismatch-\(attempt)"
            screenshot.lifetime = .keepAlways
            XCTContext.runActivity(named: "Typed \(description) did not arrive (attempt \(attempt))") {
                $0.add(screenshot)
            }
        }
        XCTFail("Typed \(description) did not arrive after one retry.")
        throw LiveSSHUITestHarnessError.assertionFailed
    }

    private func waitForStableHittable(
        _ element: XCUIElement, description: String, timeout: TimeInterval = 10
    ) throws {
        var previousFrame = CGRect.null
        var stableSince = Date()
        guard waitUntil(timeout: timeout, {
            guard element.exists, element.isEnabled, element.isHittable else {
                stableSince = Date()
                return false
            }
            let frame = element.frame
            if frame != previousFrame {
                previousFrame = frame
                stableSince = Date()
            }
            return Date().timeIntervalSince(stableSince) >= 0.5
        }) else { try fail("Timed out waiting for a stable \(description). Status: \(statusDescription)") }
    }

    private func waitUntil(timeout: TimeInterval, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if predicate() { return true }
            wait(seconds: 0.15)
        } while Date() < deadline
        return predicate()
    }

    private func fail(_ message: String) throws -> Never {
        recordScreen(name: "live-ssh-harness-failure")
        XCTFail(message)
        throw LiveSSHUITestHarnessError.assertionFailed
    }

    private func wait(seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}

private enum LiveSSHUITestHarnessError: Error {
    case assertionFailed
    case missingImage
    case localNetworkPermissionGranted
}
