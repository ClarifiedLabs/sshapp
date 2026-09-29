import UIKit
import Vision
import XCTest

@MainActor
final class PromptTransitionUITests: XCTestCase {
    private let normalPrompt = "NORMALPROMPTALPHA"
    private let tmuxPrompt = "TMUXPROMPTBRAVO"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testNormalToTmuxPromptAppearsExactlyOnceAfterViewportSettles() throws {
        let app = launchHarness(startingInTmux: false)
        defer { UITestDeviceHealth.terminate(app) }

        try waitForSettledSurface("normal", in: app)
        try assertVisiblePrompt(normalPrompt, excluding: tmuxPrompt)

        for expectedSurface in ["tmux", "normal", "tmux"] {
            app.buttons["prompt.transition.switch"].tap()
            try waitForSettledSurface(expectedSurface, in: app)
            if expectedSurface == "tmux" {
                try assertVisiblePrompt(tmuxPrompt, excluding: normalPrompt)
            } else {
                try assertVisiblePrompt(normalPrompt, excluding: tmuxPrompt)
            }
        }
    }

    func testTmuxToNormalPromptAppearsExactlyOnceAfterViewportSettles() throws {
        let app = launchHarness(startingInTmux: true)
        defer { UITestDeviceHealth.terminate(app) }

        try waitForSettledSurface("tmux", in: app)
        try assertVisiblePrompt(tmuxPrompt, excluding: normalPrompt)

        for expectedSurface in ["normal", "tmux", "normal"] {
            app.buttons["prompt.transition.switch"].tap()
            try waitForSettledSurface(expectedSurface, in: app)
            if expectedSurface == "normal" {
                try assertVisiblePrompt(normalPrompt, excluding: tmuxPrompt)
            } else {
                try assertVisiblePrompt(tmuxPrompt, excluding: normalPrompt)
            }
        }
    }

    private func launchHarness(startingInTmux: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--sshapp-in-memory-store",
            "--sshapp-reset-state",
            "--sshapp-ui-test-prompt-transition",
            "--ui-testing",
        ]
        if startingInTmux {
            app.launchArguments.append("--sshapp-ui-test-prompt-transition-start-tmux")
        }
        // Ghostty redraws continuously, so XCTest must not wait for app idleness.
        UITestDeviceHealth.launch(app, for: self, disablesIdleWait: true)
        return app
    }

    private func waitForSettledSurface(
        _ expectedSurface: String,
        in app: XCUIApplication
    ) throws {
        let settledSurface = app.staticTexts["prompt.transition.settledSurface"]
        guard settledSurface.waitForExistence(timeout: 8) else {
            attachSettleFailure(expectedSurface: expectedSurface, in: app)
            throw PromptTransitionUITestError.missingSettledSurface
        }

        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", expectedSurface),
            object: settledSurface
        )
        guard XCTWaiter.wait(for: [expectation], timeout: 8) == .completed else {
            attachSettleFailure(expectedSurface: expectedSurface, in: app)
            throw PromptTransitionUITestError.surfaceDidNotSettle(expectedSurface)
        }
    }

    private func attachSettleFailure(expectedSurface: String, in app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "prompt-transition-settle-timeout-\(expectedSurface)"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "prompt-transition-settle-timeout-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)

        if let text = try? recognizedScreenText() {
            let recognizedText = XCTAttachment(string: text)
            recognizedText.name = "prompt-transition-settle-timeout-ocr"
            recognizedText.lifetime = .keepAlways
            add(recognizedText)
        }
    }

    private func assertVisiblePrompt(
        _ expectedPrompt: String,
        excluding replacedPrompt: String,
        timeout: TimeInterval = 10
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var latestText = ""
        var latestRecognition: ScreenRecognition?

        while Date() < deadline {
            let recognition = try recognizeScreen()
            latestRecognition = recognition
            latestText = recognition.text
            let canonicalText = canonicalized(latestText)
            if occurrenceCount(of: expectedPrompt, in: canonicalText) == 1,
               occurrenceCount(of: replacedPrompt, in: canonicalText) == 0 {
                // Recheck after another display interval so a delayed replay
                // cannot turn the first visible prompt into a duplicate.
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                let stableText = try recognizedScreenText()
                let stableCanonicalText = canonicalized(stableText)
                XCTAssertEqual(occurrenceCount(of: expectedPrompt, in: stableCanonicalText), 1)
                XCTAssertEqual(occurrenceCount(of: replacedPrompt, in: stableCanonicalText), 0)
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }

        if let latestRecognition {
            // The exact image Vision read, not a later screenshot.
            let ocrImage = XCTAttachment(image: latestRecognition.image)
            ocrImage.name = "prompt-transition-timeout-ocr-image"
            ocrImage.lifetime = .keepAlways
            add(ocrImage)
        }
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "prompt-transition-timeout"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let recognizedText = XCTAttachment(string: latestText)
        recognizedText.name = "prompt-transition-timeout-ocr"
        recognizedText.lifetime = .keepAlways
        add(recognizedText)

        let observations = XCTAttachment(
            string: latestRecognition.map { recognition in
                "expected=\(expectedPrompt) excluded=\(replacedPrompt)\n"
                    + "canonical=\(canonicalized(recognition.text))\n"
                    + recognition.observationReport
            } ?? "no recognition"
        )
        observations.name = "prompt-transition-timeout-ocr-observations"
        observations.lifetime = .keepAlways
        add(observations)

        XCTFail("Expected exactly one visible \(expectedPrompt) and no \(replacedPrompt)")
        throw PromptTransitionUITestError.promptNotVisible(expectedPrompt)
    }

    private struct ScreenRecognition {
        let image: UIImage
        let text: String
        /// Per observation: normalized bounding box, pixel box, and top candidates
        /// with confidence and Unicode scalars (to expose lookalike scripts).
        let observationReport: String
    }

    private func recognizedScreenText() throws -> String {
        try recognizeScreen().text
    }

    private func recognizeScreen() throws -> ScreenRecognition {
        let screenshot = XCUIScreen.main.screenshot()
        guard let image = screenshot.image.cgImage else {
            throw PromptTransitionUITestError.missingScreenshotImage
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        // Prompts are ASCII. With automatic language detection, Vision reads
        // the iPad terminal's monospaced "M" as Cyrillic "м", so a correctly
        // rendered TMUXPROMPTBRAVO never matched on iPads.
        request.automaticallyDetectsLanguage = false
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        let results = request.results ?? []
        let text = results
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
        let width = Double(image.width)
        let height = Double(image.height)
        let report = results.enumerated().map { index, observation in
            let box = observation.boundingBox
            let pixelBox = String(
                format: "px(x=%.0f y=%.0f w=%.0f h=%.0f)",
                box.minX * width, (1 - box.maxY) * height, box.width * width, box.height * height
            )
            let candidates = observation.topCandidates(3).map { candidate in
                let scalars = candidate.string.unicodeScalars
                    .filter { $0.value > 0x7F }
                    .map { String(format: "U+%04X", $0.value) }
                    .joined(separator: ",")
                return String(format: "  %.2f %@", candidate.confidence, candidate.string)
                    + (scalars.isEmpty ? "" : " nonASCII=[\(scalars)]")
            }.joined(separator: "\n")
            return String(
                format: "#%d norm(x=%.4f y=%.4f w=%.4f h=%.4f) ",
                index, box.minX, box.minY, box.width, box.height
            ) + pixelBox + " image=\(image.width)x\(image.height)\n" + candidates
        }.joined(separator: "\n")
        return ScreenRecognition(
            image: UIImage(cgImage: image),
            text: text,
            observationReport: report
        )
    }

    private func canonicalized(_ text: String) -> String {
        TerminalOCRPromptMatcher.canonicalized(text)
    }

    private func occurrenceCount(of needle: String, in haystack: String) -> Int {
        TerminalOCRPromptMatcher.occurrenceCount(of: needle, in: haystack)
    }
}

private enum PromptTransitionUITestError: Error {
    case missingSettledSurface
    case surfaceDidNotSettle(String)
    case missingScreenshotImage
    case promptNotVisible(String)
}
