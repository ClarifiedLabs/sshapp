import Foundation

/// Counts ASCII prompt markers in Vision text. Vision on iPadOS 27 returns
/// Cyrillic/Greek lookalikes (e.g. "tмuxpromptbravo") or a zero for the
/// monospaced terminal glyphs even with en-US pinned, so lookalikes are folded
/// to Latin before matching. Only uppercased ASCII letters are compared.
enum TerminalOCRPromptMatcher {
    static func canonicalized(_ text: String) -> String {
        String(text.map { latinLookalikes[$0] ?? $0 })
            .uppercased()
            .filter { $0.isASCII && $0.isLetter }
    }

    /// Non-overlapping occurrences of an already canonical needle.
    static func occurrenceCount(of needle: String, in haystack: String) -> Int {
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

    static func occurrenceCount(of prompt: String, inRecognizedText text: String) -> Int {
        occurrenceCount(of: canonicalized(prompt), in: canonicalized(text))
    }

    private static let latinLookalikes: [Character: Character] = [
        // Cyrillic
        "А": "A", "а": "a", "В": "B", "Е": "E", "е": "e", "К": "K", "к": "k",
        "М": "M", "м": "m", "Н": "H", "н": "h", "О": "O", "о": "o", "Р": "P",
        "р": "p", "С": "C", "с": "c", "Т": "T", "т": "t", "У": "Y", "у": "y",
        "Х": "X", "х": "x", "Ѕ": "S", "ѕ": "s", "І": "I", "і": "i", "Ј": "J",
        "ј": "j", "Ԁ": "D", "ԁ": "d", "Ү": "Y", "ү": "y",
        // Greek
        "Α": "A", "Β": "B", "Ε": "E", "Ζ": "Z", "Η": "H", "Ι": "I", "Κ": "K",
        "Μ": "M", "Ν": "N", "Ο": "O", "ο": "o", "Ρ": "P", "ρ": "p", "Τ": "T",
        "Υ": "Y", "Χ": "X", "ν": "v",
        // Monospaced digit/letter confusion
        "0": "O",
    ]
}
