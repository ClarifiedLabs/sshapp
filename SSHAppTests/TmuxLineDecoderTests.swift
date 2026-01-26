import XCTest
@testable import SSHApp

/// Tests for `TmuxLineDecoder`, the byte-level DCS detector + line splitter
/// used to bracket tmux -CC control mode within an SSH stream.
///
/// Pre-DCS bytes are returned as `.passthrough`. Post-DCS bytes accumulate
/// into newline-terminated `.line` outputs (with `\r` stripped per iTerm2's
/// `VT100TmuxParser.m:51` lesson). After a `%exit` line or ST sequence
/// (`ESC \`), the decoder reverts to passthrough.
final class TmuxLineDecoderTests: XCTestCase {

    // MARK: - 1. Pre-DCS passthrough

    func testPreDCSPassthrough() {
        var decoder = TmuxLineDecoder()
        let outputs = decoder.feed(Data("hello\n".utf8))
        XCTAssertEqual(outputs, [.passthrough(Data("hello\n".utf8))])
        XCTAssertFalse(decoder.isHooked)
    }

    // MARK: - 2. DCS detection in single feed

    func testDCSDetectionSingleFeed() {
        var decoder = TmuxLineDecoder()
        let outputs = decoder.feed(Data("\u{1B}P1000p%output %3 a\n".utf8))
        XCTAssertEqual(outputs, [.line(Data("%output %3 a".utf8))])
        XCTAssertTrue(decoder.isHooked)
    }

    // MARK: - 3. DCS detection split across two feeds

    func testDCSDetectionSplitAcrossFeeds() {
        var decoder = TmuxLineDecoder()
        let first = decoder.feed(Data("\u{1B}P10".utf8))
        XCTAssertEqual(first, [])
        XCTAssertFalse(decoder.isHooked)

        let second = decoder.feed(Data("00p%window-add @5\n".utf8))
        XCTAssertEqual(second, [.line(Data("%window-add @5".utf8))])
        XCTAssertTrue(decoder.isHooked)
    }

    // MARK: - 4. Partial line buffered across feeds

    func testPartialLineBufferedAcrossFeeds() {
        var decoder = TmuxLineDecoder()
        let first = decoder.feed(Data("\u{1B}P1000p%output %3 ab".utf8))
        XCTAssertEqual(first, [])
        XCTAssertTrue(decoder.isHooked)

        let second = decoder.feed(Data("cd\n".utf8))
        XCTAssertEqual(second, [.line(Data("%output %3 abcd".utf8))])
    }

    // MARK: - 5. \r stripping

    func testCRStripping() {
        var decoder = TmuxLineDecoder()
        let outputs = decoder.feed(Data("\u{1B}P1000p%output %3 a\rb\rc\r\n".utf8))
        XCTAssertEqual(outputs, [.line(Data("%output %3 abc".utf8))])
    }

    func testCRStrippingWithMultipleCRBeforeLF() {
        var decoder = TmuxLineDecoder()
        let outputs = decoder.feed(Data("\u{1B}P1000p\r\rfoo\r\r\nbar\r\n".utf8))
        XCTAssertEqual(outputs, [
            .line(Data("foo".utf8)),
            .line(Data("bar".utf8)),
        ])
    }

    // MARK: - 6. Multiple lines in one feed

    func testMultipleLinesInOneFeed() {
        var decoder = TmuxLineDecoder()
        let outputs = decoder.feed(Data("\u{1B}P1000p%begin 1 1 0\nfoo\n%end 1 1 0\n".utf8))
        XCTAssertEqual(outputs, [
            .line(Data("%begin 1 1 0".utf8)),
            .line(Data("foo".utf8)),
            .line(Data("%end 1 1 0".utf8)),
        ])
    }

    // MARK: - 7. Mixed passthrough + DCS in one feed

    func testMixedPassthroughAndDCSInOneFeed() {
        var decoder = TmuxLineDecoder()
        let outputs = decoder.feed(Data("hello\u{1B}P1000p%foo\n".utf8))
        XCTAssertEqual(outputs, [
            .passthrough(Data("hello".utf8)),
            .line(Data("%foo".utf8)),
        ])
    }

    // MARK: - 8. Aborted DCS

    func testAbortedDCSEmitsBytesAsPassthrough() {
        var decoder = TmuxLineDecoder()
        let outputs = decoder.feed(Data("\u{1B}Px".utf8))
        XCTAssertEqual(outputs, [.passthrough(Data("\u{1B}Px".utf8))])
        XCTAssertFalse(decoder.isHooked)
    }

    func testAbortedDCSThenSuccessfulDCS() {
        var decoder = TmuxLineDecoder()
        let aborted = decoder.feed(Data("\u{1B}Px".utf8))
        XCTAssertEqual(aborted, [.passthrough(Data("\u{1B}Px".utf8))])

        let good = decoder.feed(Data("\u{1B}P1000p%window-add @1\n".utf8))
        XCTAssertEqual(good, [.line(Data("%window-add @1".utf8))])
        XCTAssertTrue(decoder.isHooked)
    }

    func testAbortedDCSMidSequenceResumes() {
        // Match ESC P 1 0 0, then a non-`0` byte aborts. The five matched
        // bytes flush as passthrough; the aborting byte is also passthrough.
        var decoder = TmuxLineDecoder()
        let outputs = decoder.feed(Data("\u{1B}P100x".utf8))
        XCTAssertEqual(outputs, [.passthrough(Data("\u{1B}P100x".utf8))])
        XCTAssertFalse(decoder.isHooked)
    }

    func testNewESCStartsFreshCandidateAfterAbort() {
        // ESC P 1 0 then ESC — the ESC restarts a candidate match without
        // being emitted to passthrough yet.
        var decoder = TmuxLineDecoder()
        let outputs = decoder.feed(Data("\u{1B}P10\u{1B}P1000p%a\n".utf8))
        // The first ESC P 1 0 (4 bytes) becomes passthrough when the
        // following ESC restarts candidacy. Then the full DCS matches and
        // we're in line mode.
        XCTAssertEqual(outputs, [
            .passthrough(Data("\u{1B}P10".utf8)),
            .line(Data("%a".utf8)),
        ])
    }

    // MARK: - 9. %exit reverts to passthrough

    func testExitRevertsToPassthrough() {
        var decoder = TmuxLineDecoder()
        let outputs = decoder.feed(Data("\u{1B}P1000p%window-add @5\n%exit\nhello".utf8))
        XCTAssertEqual(outputs, [
            .line(Data("%window-add @5".utf8)),
            .line(Data("%exit".utf8)),
            .passthrough(Data("hello".utf8)),
        ])
        XCTAssertFalse(decoder.isHooked)
    }

    // MARK: - 10. %exit with reason

    func testExitWithReason() {
        var decoder = TmuxLineDecoder()
        let outputs = decoder.feed(Data("\u{1B}P1000p%exit detached\n".utf8))
        XCTAssertEqual(outputs, [.line(Data("%exit detached".utf8))])
        XCTAssertFalse(decoder.isHooked)
    }

    func testExitWithReasonThenPassthroughBytes() {
        var decoder = TmuxLineDecoder()
        let outputs = decoder.feed(Data("\u{1B}P1000p%exit normal exit\nbye".utf8))
        XCTAssertEqual(outputs, [
            .line(Data("%exit normal exit".utf8)),
            .passthrough(Data("bye".utf8)),
        ])
    }

    func testExitPrefixOnlyDoesNotMatchAsExit() {
        // "%exitfoo" is NOT an exit line (the prefix must be exactly `%exit`
        // or `%exit ` followed by a reason).
        var decoder = TmuxLineDecoder()
        let outputs = decoder.feed(Data("\u{1B}P1000p%exitfoo\nbar\n".utf8))
        XCTAssertEqual(outputs, [
            .line(Data("%exitfoo".utf8)),
            .line(Data("bar".utf8)),
        ])
        XCTAssertTrue(decoder.isHooked)
    }

    // MARK: - 11. ST terminator

    func testSTTerminatorWithEmptyLineBuffer() {
        var decoder = TmuxLineDecoder()
        let outputs = decoder.feed(Data("\u{1B}P1000p%foo\n\u{1B}\\post".utf8))
        XCTAssertEqual(outputs, [
            .line(Data("%foo".utf8)),
            .passthrough(Data("post".utf8)),
        ])
        XCTAssertFalse(decoder.isHooked)
    }

    func testSTTerminatorMidLine() {
        var decoder = TmuxLineDecoder()
        let outputs = decoder.feed(Data("\u{1B}P1000p%foo\u{1B}\\post".utf8))
        XCTAssertEqual(outputs, [
            .line(Data("%foo".utf8)),
            .passthrough(Data("post".utf8)),
        ])
        XCTAssertFalse(decoder.isHooked)
    }

    func testSTOnEmptyBufferDoesNotEmitEmptyLine() {
        // ST with no buffered bytes should NOT emit an empty `.line`.
        var decoder = TmuxLineDecoder()
        let outputs = decoder.feed(Data("\u{1B}P1000p\u{1B}\\after".utf8))
        XCTAssertEqual(outputs, [.passthrough(Data("after".utf8))])
        XCTAssertFalse(decoder.isHooked)
    }

    // MARK: - 12. Reset

    func testResetAfterPartialLine() {
        var decoder = TmuxLineDecoder()
        _ = decoder.feed(Data("\u{1B}P1000p%output %3 partial".utf8))
        XCTAssertTrue(decoder.isHooked)

        decoder.reset()
        XCTAssertFalse(decoder.isHooked)

        let outputs = decoder.feed(Data("hello\n".utf8))
        XCTAssertEqual(outputs, [.passthrough(Data("hello\n".utf8))])
    }

    func testResetClearsLineBuffer() {
        var decoder = TmuxLineDecoder()
        _ = decoder.feed(Data("\u{1B}P1000p%output %3 partial".utf8))
        decoder.reset()

        // Re-enter DCS and feed a new line — must NOT include the discarded buffer.
        let outputs = decoder.feed(Data("\u{1B}P1000p%window-add @1\n".utf8))
        XCTAssertEqual(outputs, [.line(Data("%window-add @1".utf8))])
    }

    // MARK: - 13. isHooked flag transitions

    func testIsHookedFlagTransitions() {
        var decoder = TmuxLineDecoder()
        XCTAssertFalse(decoder.isHooked, "starts false")

        _ = decoder.feed(Data("\u{1B}P1000p".utf8))
        XCTAssertTrue(decoder.isHooked, "true after DCS")

        _ = decoder.feed(Data("%exit\n".utf8))
        XCTAssertFalse(decoder.isHooked, "false after %exit")

        _ = decoder.feed(Data("\u{1B}P1000p".utf8))
        XCTAssertTrue(decoder.isHooked, "true after re-entering DCS")

        decoder.reset()
        XCTAssertFalse(decoder.isHooked, "false after reset")
    }

    // MARK: - 14. UTF-8 split across feeds in line mode

    func testUTF8SplitAcrossFeedsInLineMode() {
        // Feed an incomplete UTF-8 sequence in the first feed (raw 0xC3),
        // then complete it in the second feed (0xA9). The decoder must NOT
        // try to interpret bytes as UTF-8 — it returns Data unchanged.
        // (Note: we build Data byte-by-byte rather than via `"\u{C3}"`
        // because Swift's `\u{C3}` is the U+00C3 codepoint, which encodes
        // as two UTF-8 bytes 0xC3 0x83 — not the single byte 0xC3 we want.)
        var decoder = TmuxLineDecoder()

        var prefix = Data()
        prefix.append(contentsOf: [0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70]) // ESC P 1 0 0 0 p
        prefix.append(contentsOf: Data("%output %3 ".utf8))
        prefix.append(0xC3) // first byte of `é` (U+00E9 = C3 A9)

        let firstOutputs = decoder.feed(prefix)
        XCTAssertEqual(firstOutputs, [], "incomplete UTF-8 byte should buffer, not emit")

        var continuation = Data()
        continuation.append(0xA9) // second byte of `é`
        continuation.append(0x0A) // \n

        let secondOutputs = decoder.feed(continuation)

        var expectedLine = Data("%output %3 ".utf8)
        expectedLine.append(0xC3)
        expectedLine.append(0xA9)
        XCTAssertEqual(secondOutputs, [.line(expectedLine)])
    }

    // MARK: - Additional edge cases

    func testEmptyFeedReturnsEmpty() {
        var decoder = TmuxLineDecoder()
        XCTAssertEqual(decoder.feed(Data()), [])
    }

    func testEmptyLineInDCS() {
        var decoder = TmuxLineDecoder()
        let outputs = decoder.feed(Data("\u{1B}P1000p\nfoo\n".utf8))
        XCTAssertEqual(outputs, [
            .line(Data()),
            .line(Data("foo".utf8)),
        ])
    }

    func testESCNotFollowedByBackslashIsLiteralInLineMode() {
        // ESC followed by a non-backslash byte should keep ESC as part of the line.
        var decoder = TmuxLineDecoder()
        var input = Data()
        input.append(contentsOf: [0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70]) // DCS hook
        input.append(contentsOf: Data("%foo".utf8))
        input.append(0x1B) // ESC
        input.append(0x5B) // [   (NOT a backslash — should not trigger ST)
        input.append(contentsOf: Data("bar\n".utf8))

        let outputs = decoder.feed(input)
        var expected = Data("%foo".utf8)
        expected.append(0x1B)
        expected.append(0x5B)
        expected.append(contentsOf: Data("bar".utf8))
        XCTAssertEqual(outputs, [.line(expected)])
    }

    func testDCSHookByteByByteFeed() {
        var decoder = TmuxLineDecoder()
        let bytes: [UInt8] = [0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70]
        for byte in bytes {
            let outputs = decoder.feed(Data([byte]))
            XCTAssertEqual(outputs, [], "DCS bytes should accumulate silently byte-by-byte")
        }
        XCTAssertTrue(decoder.isHooked)

        let final = decoder.feed(Data("hi\n".utf8))
        XCTAssertEqual(final, [.line(Data("hi".utf8))])
    }

    func testAbortedDCSStartsWithFreshESC() {
        // Sequence: ESC ESC P 1 0 0 0 p
        // First ESC starts candidate (matchLen=1). Second ESC: byte 0x1B != expected 0x50,
        // mismatch — flush the matched ESC as passthrough. Then re-test current byte
        // 0x1B against position 0: it matches, so a new candidate begins.
        var decoder = TmuxLineDecoder()
        var input = Data([0x1B, 0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        input.append(contentsOf: Data("%a\n".utf8))

        let outputs = decoder.feed(input)
        XCTAssertEqual(outputs, [
            .passthrough(Data([0x1B])),
            .line(Data("%a".utf8)),
        ])
    }
}
