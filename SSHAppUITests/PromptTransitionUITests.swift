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
        defer { app.terminate() }

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
        defer { app.terminate() }

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
        app.launch()

        // Ghostty redraws continuously, so XCTest must not wait for app idleness.
        app.setValue(NSNumber(value: 3), forKey: "currentInteractionOptions")
        return app
    }

    private func waitForSettledSurface(
        _ expectedSurface: String,
        in app: XCUIApplication
    ) throws {
        let settledSurface = app.staticTexts["prompt.transition.settledSurface"]
        guard settledSurface.waitForExistence(timeout: 8) else {
            throw PromptTransitionUITestError.missingSettledSurface
        }

        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", expectedSurface),
            object: settledSurface
        )
        guard XCTWaiter.wait(for: [expectation], timeout: 8) == .completed else {
            throw PromptTransitionUITestError.surfaceDidNotSettle(expectedSurface)
        }
    }

    private func assertVisiblePrompt(
        _ expectedPrompt: String,
        excluding replacedPrompt: String,
        timeout: TimeInterval = 10
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var latestText = ""

        while Date() < deadline {
            latestText = try recognizedScreenText()
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

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "prompt-transition-timeout"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let recognizedText = XCTAttachment(string: latestText)
        recognizedText.name = "prompt-transition-timeout-ocr"
        recognizedText.lifetime = .keepAlways
        add(recognizedText)

        XCTFail("Expected exactly one visible \(expectedPrompt) and no \(replacedPrompt)")
        throw PromptTransitionUITestError.promptNotVisible(expectedPrompt)
    }

    private func recognizedScreenText() throws -> String {
        let screenshot = XCUIScreen.main.screenshot()
        guard let image = screenshot.image.cgImage else {
            throw PromptTransitionUITestError.missingScreenshotImage
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    private func canonicalized(_ text: String) -> String {
        String(text.uppercased().filter(\.isLetter))
    }

    private func occurrenceCount(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchStart = haystack.startIndex

        while searchStart < haystack.endIndex,
              let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            count += 1
            searchStart = range.upperBound
        }
        return count
    }
}

private enum PromptTransitionUITestError: Error {
    case missingSettledSurface
    case surfaceDidNotSettle(String)
    case missingScreenshotImage
    case promptNotVisible(String)
}
