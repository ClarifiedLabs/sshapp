import Foundation

/// Synthetic streams. No session recordings or network access.
/// Keep the exact bytes stable so results stay comparable.
enum TerminalReplayFixtures {
    struct Fixture: Sendable {
        let name: String
        let bytes: Data
        let expectedText: [String]
        let absentText: [String]
    }

    static let semantic: [Fixture] = [
        Fixture(
            name: "unicode-and-styles",
            bytes: Data((reset
                + "ASCII alpha 0123456789\r\n"
                + "Wide: 日本語 中文\r\n"
                + "Combining: e\u{301} a\u{308}\r\n"
                + "Emoji: 😀 👩🏽‍💻 🇺🇳\r\n"
                + "\u{1B}[1;31mBOLD RED\u{1B}[0m \u{1B}[3;4mitalic underline\u{1B}[0m\r\n"
                + "\u{1B}[38;2;32;160;224mTRUECOLOR\u{1B}[0m\r\n"
                + "┌────┐\r\n│ VT │\r\n└────┘\r\n").utf8),
            expectedText: ["ASCII alpha 0123456789", "日本語 中文", "e\u{301} a\u{308}",
                           "😀 👩🏽‍💻 🇺🇳", "BOLD RED", "italic underline", "TRUECOLOR", "│ VT │"],
            absentText: []
        ),
        Fixture(
            name: "alternate-screen-and-editing",
            bytes: Data((reset + "PRIMARY KEPT\r\n"
                + "\u{1B}[?1049hALTERNATE DISCARDED\u{1B}[?1049l"
                + "overwrite me\r\u{1B}[2KREPLACED\r\n").utf8),
            expectedText: ["PRIMARY KEPT", "REPLACED"],
            absentText: ["ALTERNATE DISCARDED", "overwrite me"]
        ),
        Fixture(
            name: "wrap-and-scrollback",
            bytes: Data((reset + (0..<120).map {
                "row-\($0): " + String(repeating: "0123456789", count: 9) + "\r\n"
            }.joined() + "SCROLLBACK END").utf8),
            expectedText: ["row-0:", "row-119:", "SCROLLBACK END"],
            absentText: []
        ),
    ]

    static let reset = "\u{1B}c"

    /// 128 styled rows per batch, fixed width and payload across all runs.
    static let denseBatch = Data((0..<128).map {
        "\u{1B}[\(31 + $0 % 7)mrow-\($0) 0123456789 abcdefghijklmnopqrstuvwxyz\u{1B}[0m\r\n"
    }.joined().utf8)
}
