import XCTest
@testable import SSHApp

/// Tests for `TmuxKeyEncoder.encode(data:to:version:)`. Verifies the
/// three-class send-keys encoding (literal, -H hex, 0x hex), version-gated
/// fallback, run grouping, escaping, and the 1024-byte command cap.
final class TmuxKeyEncoderTests: XCTestCase {

    private let pane3 = TmuxPaneID(rawValue: 3)
    private let v30a = TmuxVersion(major: 3, minor: 0, letterOffset: 1)
    private let v29 = TmuxVersion(major: 2, minor: 9)

    // MARK: - 1. Empty input

    func testEmptyInputReturnsNoCommands() {
        let result = TmuxKeyEncoder.encode(data: Data(), to: pane3, version: v30a)
        XCTAssertEqual(result, [])
    }

    // MARK: - 2. Single printable ASCII

    func testSinglePrintableAsciiByteProducesLiteralCommand() {
        let result = TmuxKeyEncoder.encode(data: Data([UInt8(ascii: "x")]), to: pane3, version: v30a)
        XCTAssertEqual(result, ["send -lt %3 \"x\""])
    }

    // MARK: - 3. Single C0 byte on 3.0a uses -H

    func testSingleC0ByteOn30aUsesHFlag() {
        let result = TmuxKeyEncoder.encode(data: Data([0x01]), to: pane3, version: v30a)
        XCTAssertEqual(result, ["send -H -t %3 01"])
    }

    // MARK: - 4. Single C0 byte on 2.9 falls back to 0x form

    func testSingleC0ByteOn29UsesFallback0xForm() {
        let result = TmuxKeyEncoder.encode(data: Data([0x01]), to: pane3, version: v29)
        XCTAssertEqual(result, ["send -t %3 0x01"])
    }

    // MARK: - 5. Mixed run "abc\u{01}\u{02}xyz" on 3.0a → three commands

    func testMixedLiteralAndControlRunProducesThreeCommands() {
        var bytes: [UInt8] = []
        bytes.append(contentsOf: "abc".utf8)
        bytes.append(0x01)
        bytes.append(0x02)
        bytes.append(contentsOf: "xyz".utf8)

        let result = TmuxKeyEncoder.encode(data: Data(bytes), to: pane3, version: v30a)
        XCTAssertEqual(result, [
            "send -lt %3 \"abc\"",
            "send -H -t %3 01 02",
            "send -lt %3 \"xyz\"",
        ])
    }

    // MARK: - 6. UTF-8 multi-byte printable scalar stays literal

    func testUTF8MultiByteCharStaysLiteral() {
        // "é" = 0xC3 0xA9 in UTF-8.
        let data = "é".data(using: .utf8)!
        XCTAssertEqual(Array(data), [0xC3, 0xA9])

        let result = TmuxKeyEncoder.encode(data: data, to: pane3, version: v30a)
        XCTAssertEqual(result, ["send -lt %3 \"é\""])
    }

    // MARK: - 7. Quote escaping inside literal

    func testDoubleQuoteIsEscapedInLiteralCommand() {
        let data = "a\"b".data(using: .utf8)!
        let result = TmuxKeyEncoder.encode(data: data, to: pane3, version: v30a)
        XCTAssertEqual(result, ["send -lt %3 \"a\\\"b\""])
    }

    func testBackslashIsEscapedInLiteralCommand() {
        let data = "a\\b".data(using: .utf8)!
        let result = TmuxKeyEncoder.encode(data: data, to: pane3, version: v30a)
        XCTAssertEqual(result, ["send -lt %3 \"a\\\\b\""])
    }

    // MARK: - 8. 0x7F (DEL) treated as control class on 3.0a

    func testDELByteIsControlClassWithHFlagOn30a() {
        let result = TmuxKeyEncoder.encode(data: Data([0x7F]), to: pane3, version: v30a)
        XCTAssertEqual(result, ["send -H -t %3 7f"])
    }

    func testDELByteIsControlClassWithFallbackOn29() {
        let result = TmuxKeyEncoder.encode(data: Data([0x7F]), to: pane3, version: v29)
        XCTAssertEqual(result, ["send -t %3 0x7f"])
    }

    // MARK: - 9. 1024-byte cap

    func testLongLiteralRunSplitsAcrossCommands() {
        // Build a 2000-byte ASCII literal run. Each command's envelope is
        // `send -lt %3 ""` = 14 bytes, so payload cap is 1010 bytes.
        // 2000 bytes should split into two commands.
        let payload = String(repeating: "a", count: 2000)
        let data = payload.data(using: .utf8)!

        let result = TmuxKeyEncoder.encode(data: data, to: pane3, version: v30a)
        XCTAssertEqual(result.count, 2, "Expected split into two commands, got \(result.count)")
        for command in result {
            XCTAssertLessThanOrEqual(command.utf8.count, 1024, "Command exceeded 1024-byte cap: \(command.utf8.count)")
            XCTAssertTrue(command.hasPrefix("send -lt %3 \""))
            XCTAssertTrue(command.hasSuffix("\""))
        }
        // Concatenated payload (between quotes) reassembles the original.
        let reconstructed = result.map { command -> String in
            let prefix = "send -lt %3 \""
            let trimmed = command.dropFirst(prefix.count).dropLast() // drop trailing quote
            return String(trimmed)
        }.joined()
        XCTAssertEqual(reconstructed, payload)
    }

    func testTwoDifferentClassRunsProduceMultipleCommands() {
        // 600 literal bytes followed by 600 control bytes. Even though
        // neither alone exceeds 1024, they're in different classes and
        // therefore must produce at least two commands.
        var bytes: [UInt8] = []
        bytes.append(contentsOf: Array(repeating: UInt8(ascii: "a"), count: 600))
        bytes.append(contentsOf: Array(repeating: UInt8(0x01), count: 600))

        let result = TmuxKeyEncoder.encode(data: Data(bytes), to: pane3, version: v30a)
        XCTAssertGreaterThanOrEqual(result.count, 2)
        XCTAssertTrue(result[0].hasPrefix("send -lt %3 \""))
        // Subsequent command(s) must be -H control commands.
        for command in result.dropFirst() {
            XCTAssertTrue(command.hasPrefix("send -H -t %3"), "Expected -H command, got: \(command)")
        }
        for command in result {
            XCTAssertLessThanOrEqual(command.utf8.count, 1024)
        }
    }

    func testLongHexHRunSplitsAcrossCommands() {
        // 600 control bytes — `send -H -t %3` prefix is 13 bytes, each byte
        // adds " NN" = 3 bytes, so 600 bytes ≈ 13 + 1800 = 1813 → must split.
        let bytes = Array(repeating: UInt8(0x01), count: 600)
        let result = TmuxKeyEncoder.encode(data: Data(bytes), to: pane3, version: v30a)
        XCTAssertGreaterThan(result.count, 1)
        for command in result {
            XCTAssertLessThanOrEqual(command.utf8.count, 1024)
            XCTAssertTrue(command.hasPrefix("send -H -t %3"))
        }
    }

    // MARK: - 10. Pane id formatting

    func testPaneIDFormattedWithPercentPrefix() {
        let pane7 = TmuxPaneID(rawValue: 7)
        let result = TmuxKeyEncoder.encode(data: Data([UInt8(ascii: "x")]), to: pane7, version: v30a)
        XCTAssertEqual(result, ["send -lt %7 \"x\""])

        // Also verify with a control byte.
        let controlResult = TmuxKeyEncoder.encode(data: Data([0x01]), to: pane7, version: v30a)
        XCTAssertEqual(controlResult, ["send -H -t %7 01"])

        // And with the fallback path.
        let fallbackResult = TmuxKeyEncoder.encode(data: Data([0x01]), to: pane7, version: v29)
        XCTAssertEqual(fallbackResult, ["send -t %7 0x01"])
    }

    // MARK: - Additional sanity checks

    func testHighByteWithoutValidUTF8FallsToHexValue() {
        // 0xFF alone is not a valid UTF-8 lead — should be classified as hex value.
        let result = TmuxKeyEncoder.encode(data: Data([0xFF]), to: pane3, version: v30a)
        XCTAssertEqual(result, ["send -t %3 0xff"])
    }

    func testConsecutiveControlBytesPackedIntoSingleCommand() {
        let result = TmuxKeyEncoder.encode(data: Data([0x01, 0x02, 0x03, 0x1B]), to: pane3, version: v30a)
        XCTAssertEqual(result, ["send -H -t %3 01 02 03 1b"])
    }
}
