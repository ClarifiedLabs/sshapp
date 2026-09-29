import UIKit
import Vision
import XCTest

/// Physical-device acceptance only: the installed Japanese Romaji keyboard and
/// its real candidate UI drive the production GhosttyTerminalView/SSHChannel.
@MainActor
final class TerminalIMEUITests: XCTestCase {
    func testPhysicalJapaneseIMECommitsCandidateWithoutChangingSettings() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical IME acceptance requires a device with Japanese Romaji and English (US) already installed; simulator skip is not IME coverage")
        #else
        let harness = TerminalSelectionUITestHarness(testCase: self)
        harness.launch(scenario: .standard, enablesIME: true)
        var needsEnglishRestore = false
        // Teardown also runs when XCTest aborts an Objective-C interaction and
        // bypasses Swift defer. Never opens Settings or edits installed keyboards.
        addTeardownBlock { @MainActor in
            defer { harness.terminate() }
            if needsEnglishRestore {
                try self.restoreEnglish(harness)
            }
        }
        defer {
            if needsEnglishRestore {
                do {
                    try restoreEnglish(harness)
                    needsEnglishRestore = false
                } catch {
                    XCTFail("Could not restore English app input mode: \(error)")
                }
            }
        }
        do {
            let ready = try harness.waitForReady()
            try harness.require(ready.imeEnabled, "IME launch flag did not enable the production keyboard fixture")
            try showKeyboard(harness)
            // Set before opening the chooser so every failure path restores it.
            needsEnglishRestore = true
            try selectKeyboard("日本語ローマ字", harness: harness)
            try waitForDocument(harness, text: "", marked: false)
            for (key, marked) in [("n", "n"), ("i", "に"), ("h", "にh"), ("o", "にほ"), ("n", "にほn")] {
                try tapKey(key, harness: harness)
                try waitForDocument(harness, text: marked, marked: true)
                try harness.assertNoClientWrites()
            }
            capture("marked-text", harness: harness)

            harness.exactDescendant(identifier: "terminal.ime.output").tap()
            _ = try harness.waitForFixtureStatus { $0.imeOutputComplete }
            try waitForVisibleOutput(harness)
            try waitForDocument(harness, text: "にほn", marked: true)
            try assertStableWrites("", harness: harness)
            capture("marked-during-output", harness: harness)

            let candidate = harness.app.cells["日本"].firstMatch
            try harness.require(candidate.waitForExistence(timeout: 5) && candidate.isHittable,
                                "Installed Japanese Romaji keyboard did not expose the actual 日本 candidate; no IME acceptance coverage")
            candidate.tap()
            let committed = Data("日本".utf8)
            _ = try harness.waitForExactClientWrites(committed)
            try waitForDocument(harness, text: "", marked: false)
            try assertStableWrites("e697a5e69cac", harness: harness)
            capture("candidate-committed", harness: harness)

            try tapKey("n", harness: harness)
            try tapKey("i", harness: harness)
            try waitForDocument(harness, text: "に", marked: true)
            try assertStableWrites("e697a5e69cac", harness: harness)
            let hide = harness.exactDescendant(identifier: "terminal.keyboard.hide")
            try harness.require(hide.exists && hide.isHittable, "Production Hide Keyboard bar action is unavailable")
            hide.tap()
            try waitUntil(harness, description: "software keyboard dismissal") {
                !harness.app.keyboards.firstMatch.exists
            }
            try waitForDocument(harness, text: "", marked: false)
            try assertStableWrites("e697a5e69cac", harness: harness)
            try showKeyboard(harness)
            try waitForDocument(harness, text: "", marked: false)
            try restoreEnglish(harness)
            needsEnglishRestore = false
            try assertStableWrites("e697a5e69cac", harness: harness)
            capture("cancelled-and-english-restored", harness: harness)
        } catch {
            harness.attachFailureDiagnostics(reason: "Physical Japanese IME: \(error)")
            capture("failure", harness: harness)
            throw error
        }
        #endif
    }

    private struct InputDocument: Decodable {
        let source: String
        let text: String
        let hasMarkedText: Bool
        let primaryLanguage: String
    }

    private func document(_ harness: TerminalSelectionUITestHarness) -> InputDocument? {
        let probe = harness.exactDescendant(identifier: "terminal.ime.inputDocument")
        guard probe.exists, let json = probe.value as? String,
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(InputDocument.self, from: data)
    }

    private func waitForDocument(_ harness: TerminalSelectionUITestHarness, text: String, marked: Bool) throws {
        try waitUntil(harness, description: "local input document \(text.debugDescription), marked=\(marked)") {
            guard let state = self.document(harness), state.text == text,
                  state.hasMarkedText == marked else { return false }
            // Prefer the real native accessibility document when present. The
            // DEBUG read-only snapshot explicitly reports the custom-input fallback.
            if state.source == "nativeTextView" {
                let native = harness.app.textViews.firstMatch
                return native.exists && native.value as? String == text
            }
            return state.source == "customUITextInput"
        }
    }

    private func showKeyboard(_ harness: TerminalSelectionUITestHarness) throws {
        if !harness.app.keyboards.firstMatch.exists {
            harness.exactDescendant(identifier: "terminal.ime.showKeyboard").tap()
        }
        try harness.require(harness.app.keyboards.firstMatch.waitForExistence(timeout: 5),
                            "Real software keyboard is unavailable (disconnect a hardware keyboard); no IME acceptance coverage")
    }

    private func selectKeyboard(_ language: String, harness: TerminalSelectionUITestHarness) throws {
        let app = harness.app
        let option = app.cells[language].firstMatch
        if !option.exists {
            let globe = app.buttons["Next keyboard"].firstMatch
            let switcher = globe.exists ? globe : app.buttons["emoji"].firstMatch
            try harness.require(switcher.exists && switcher.isHittable,
                                "Installed-keyboard chooser is unavailable; requires Japanese Romaji and English (US), without changing Settings")
            switcher.press(forDuration: 0.8)
        }
        try harness.require(option.waitForExistence(timeout: 5) && option.isHittable,
                            "Required installed keyboard '\(language)' is unavailable; no IME acceptance coverage (Settings is never modified)")
        option.tap()
    }

    private func restoreEnglish(_ harness: TerminalSelectionUITestHarness) throws {
        try showKeyboard(harness)
        if document(harness)?.primaryLanguage.hasPrefix("en") != true {
            try selectKeyboard("English (US)", harness: harness)
        }
        try waitUntil(harness, description: "English app input mode restored") {
            self.document(harness)?.primaryLanguage.hasPrefix("en") == true
        }
    }

    private func tapKey(_ key: String, harness: TerminalSelectionUITestHarness) throws {
        let element = harness.app.keyboards.keys[key].firstMatch
        try harness.require(element.waitForExistence(timeout: 3) && element.isHittable,
                            "Japanese Romaji software key '\(key)' is unavailable; not a synthetic Japanese typeText test")
        element.tap()
    }

    private func waitForVisibleOutput(_ harness: TerminalSelectionUITestHarness) throws {
        // OCR only terminal pixels, not fixture JSON, controls, or the keyboard.
        // Parser acceptance alone must not pass an output/rendering regression.
        let viewport = harness.exactDescendant(identifier: "terminal.selection.state")
        try harness.require(viewport.exists && !viewport.frame.isEmpty,
                            "Terminal viewport is unavailable for incoming-output pixel proof")
        let deadline = Date().addingTimeInterval(5)
        var latestText = ""
        repeat {
            try harness.assertNoClientWrites()
            let state = document(harness)
            try harness.require(state?.text == "にほn" && state?.hasMarkedText == true,
                                "Incoming output changed the local Japanese preedit")
            let screenshot = viewport.screenshot()
            let image = try XCTUnwrap(screenshot.image.cgImage)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: image).perform([request])
            latestText = (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
            // Ignore OCR whitespace only; the full final marker must match.
            if latestText.split(whereSeparator: \.isNewline).contains(where: {
                $0.filter { !$0.isWhitespace } == "IME-OUTPUT-011"
            }) {
                let pixels = XCTAttachment(screenshot: screenshot)
                pixels.name = "terminal-physical-ime-incoming-output-pixels"
                pixels.lifetime = .keepAlways
                add(pixels)
                let text = XCTAttachment(string: latestText)
                text.name = "terminal-physical-ime-incoming-output-ocr"
                text.lifetime = .keepAlways
                add(text)
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        try harness.require(false, "Native output was accepted but IME-OUTPUT-011 was not visible; OCR: \(latestText)")
    }

    private func assertStableWrites(_ hex: String, harness: TerminalSelectionUITestHarness) throws {
        let deadline = Date().addingTimeInterval(0.75)
        repeat {
            let status = try harness.waitForTransportStatus { _ in true }
            try harness.require(status.clientWriteHex == hex,
                                "Expected cumulative clientWriteHex=\(hex), received \(status.clientWriteHex) (duplicate/premature commit)")
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
    }

    private func waitUntil(_ harness: TerminalSelectionUITestHarness, description: String,
                           predicate: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            if predicate() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        try harness.require(false, "Timed out waiting for \(description)")
    }

    private func capture(_ phase: String, harness: TerminalSelectionUITestHarness) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "terminal-physical-ime-\(phase)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        for identifier in ["terminal.ime.inputDocument", "terminal.selection.fixture", "terminal.selection.transport"] {
            let element = harness.exactDescendant(identifier: identifier)
            let value = element.exists ? (element.value as? String ?? "<no string value>") : "<missing>"
            let attachment = XCTAttachment(string: value)
            attachment.name = "terminal-physical-ime-\(phase)-\(identifier).json"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
