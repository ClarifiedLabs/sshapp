import XCTest

final class TerminalOCRPromptMatcherTests: XCTestCase {
    /// Regression: r10 on iPad mini A17 Pro and iPad Pro M4 (iPadOS 27.0.1)
    /// rendered TMUXPROMPTBRAVO correctly, but Vision returned
    /// "tмuxpromptbravo $" (Cyrillic U+043C) despite en-US, so the
    /// PromptTransition UI test counted zero prompts.
    func testFoldsCyrillicLookalikeFromPhysicalIPadOCR() {
        XCTAssertEqual(
            TerminalOCRPromptMatcher.occurrenceCount(
                of: "TMUXPROMPTBRAVO",
                inRecognizedText: "• SSHAppUITests-Runner 17:17 Wed Sep 30 SSH App\nSwitch surface\ntмuxpromptbravo $\n•| 100\ntmux"
            ),
            1
        )
        XCTAssertEqual(
            TerminalOCRPromptMatcher.occurrenceCount(
                of: "NORMALPROMPTALPHA",
                inRecognizedText: "tмuxpromptbravo $"
            ),
            0
        )
    }

    func testFoldsGreekLookalikesAndZero() {
        XCTAssertEqual(
            TerminalOCRPromptMatcher.occurrenceCount(of: "NORMALPROMPTALPHA", inRecognizedText: "ΝΟRΜΑLPRΟΜPTΑLPΗΑ"),
            1
        )
        XCTAssertEqual(
            TerminalOCRPromptMatcher.occurrenceCount(of: "TMUXPROMPTBRAVO", inRecognizedText: "TMUXPROMPTBRAV0 $"),
            1
        )
        XCTAssertEqual(TerminalOCRPromptMatcher.canonicalized("SSH Аpp"), "SSHAPP")
    }

    func testCountsDuplicatesAndIgnoresUnrelatedScripts() {
        XCTAssertEqual(
            TerminalOCRPromptMatcher.occurrenceCount(
                of: "TMUXPROMPTBRAVO",
                inRecognizedText: "TMUXPROMPTBRAVO $\ntmuxpromptbravo $"
            ),
            2
        )
        XCTAssertEqual(TerminalOCRPromptMatcher.canonicalized("日本 ж"), "")
    }
}
