import XCTest
@testable import SSHApp

private extension TmuxLineDecoder {
    mutating func feed(_ data: Data) -> [TmuxDecoderOutput] {
        feedEvents(data).compactMap { event in
            if case .output(let output) = event {
                return output
            }
            return nil
        }
    }
}

/// Tests for `TmuxLineDecoder`, the byte-level DCS detector + line splitter
/// used to bracket tmux -CC control mode within an SSH stream.
///
/// Pre-DCS bytes are returned as `.passthrough`. Post-DCS bytes accumulate
/// into newline-terminated `.line` outputs (with `\r` stripped per iTerm2's
/// `VT100TmuxParser.m:51` lesson). After a `%exit` line followed by ST
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

    // MARK: - 2b. Nested tmux output suppression

    func testControlModeOutputSuppressorPassesPlainPaneOutput() {
        var suppressor = TmuxControlModeOutputSuppressor()
        let output = suppressor.filter(Data("hello\n\u{1B}[31mred\u{1B}[0m\n".utf8))
        XCTAssertEqual(output, Data("hello\n\u{1B}[31mred\u{1B}[0m\n".utf8))
    }

    func testControlModeOutputSuppressorDropsNestedTmuxTranscript() {
        var suppressor = TmuxControlModeOutputSuppressor()
        let transcript = Data(
            (
                "before\n" +
                "\u{1B}P1000p" +
                "%begin 1783229769 2313 1\n" +
                "%end 1783229769 2313 1\n" +
                "%unlinked-window-renamed @24 tmux\n" +
                "%exit\n" +
                "\u{1B}\\" +
                "after\n"
            ).utf8
        )

        let output = suppressor.filter(transcript)

        XCTAssertEqual(output, Data("before\nafter\n".utf8))
    }

    func testControlModeOutputSuppressorReportsNestedControlModeStart() {
        var suppressor = TmuxControlModeOutputSuppressor()

        let first = suppressor.filterWithResult(Data(
            "before\n\u{1B}P1000p%client-session-changed /dev/pts/1 $21 ssh-app-session\n".utf8
        ))
        let second = suppressor.filterWithResult(Data(
            "%client-session-changed /dev/pts/1 $21 ssh-app-session\n".utf8
        ))

        XCTAssertEqual(first.data, Data("before\n".utf8))
        XCTAssertTrue(first.didStartControlMode)
        XCTAssertTrue(second.data.isEmpty)
        XCTAssertFalse(second.didStartControlMode)
    }

    func testControlModeOutputSuppressorHandlesDCSHookSplitAcrossChunks() {
        var suppressor = TmuxControlModeOutputSuppressor()

        let first = suppressor.filter(Data("pre \u{1B}P10".utf8))
        let second = suppressor.filter(Data("00p%exit\n\u{1B}\\post".utf8))

        XCTAssertEqual(first, Data("pre ".utf8))
        XCTAssertEqual(second, Data("post".utf8))
    }

    func testControlModeOutputSuppressorPassesAbortedDCSCandidate() {
        var suppressor = TmuxControlModeOutputSuppressor()

        let first = suppressor.filter(Data("hello \u{1B}P10".utf8))
        let second = suppressor.filter(Data("x world".utf8))

        XCTAssertEqual(first, Data("hello ".utf8))
        XCTAssertEqual(second, Data("\u{1B}P10x world".utf8))
    }

    @MainActor
    func testTmuxPaneFeedSuppressesNestedControlModeBeforeSink() {
        let pane = TmuxPane(id: TmuxPaneID(rawValue: 62), windowID: TmuxWindowID(rawValue: 28))
        var received = Data()
        _ = pane.setSink { data in
            received.append(data)
        }

        pane.feed(Data("prompt\n\u{1B}P10".utf8))
        pane.feed(Data(
            (
                "00p" +
                "%begin 1783229769 2313 1\n" +
                "%end 1783229769 2313 1\n" +
                "%unlinked-window-renamed @24 tmux\n" +
                "%exit\n" +
                "\u{1B}\\after\n"
            ).utf8
        ))

        XCTAssertEqual(received, Data("prompt\nafter\n".utf8))
    }

    @MainActor
    func testTmuxPaneFeedReportsNestedControlModeOnlyAsSuppressed() {
        let pane = TmuxPane(id: TmuxPaneID(rawValue: 61), windowID: TmuxWindowID(rawValue: 21))
        var received = Data()
        _ = pane.setSink { data in
            received.append(data)
        }

        let result = pane.feedResult(Data(
            "\u{1B}P1000p%client-session-changed /dev/pts/1 $21 ssh-app-session\n".utf8
        ))

        XCTAssertFalse(result.deliveredDisplayBytes)
        XCTAssertTrue(result.didStartNestedControlMode)
        XCTAssertTrue(received.isEmpty)
    }

    @MainActor
    func testTmuxPaneSnapshotFeedDoesNotInheritLiveNestedControlModeState() {
        let pane = TmuxPane(id: TmuxPaneID(rawValue: 61), windowID: TmuxWindowID(rawValue: 21))
        var received = Data()
        _ = pane.setSink { data in
            received.append(data)
        }

        XCTAssertFalse(pane.feed(Data(
            "\u{1B}P1000p%client-session-changed /dev/pts/1 $21 ssh-app-session\n".utf8
        )))
        XCTAssertTrue(pane.feedSnapshot(Data(
            "demo@foo:~$ \u{1B}P1000p%client-session-changed /dev/pts/1 $21 ssh-app-session\n".utf8
        )))

        XCTAssertEqual(received, Data("demo@foo:~$ ".utf8))
    }

    func testFailedNewThenFallbackAttachReportsControlModeRestartInOneFeed() {
        var decoder = TmuxLineDecoder()
        let transcript = Data(
            (
                "\u{1B}P1000p%begin 1783208454 308 0\n" +
                "duplicate session: ssh-app-session\n" +
                "%error 1783208454 308 0\n" +
                "%exit\n" +
                "\u{1B}\\\u{1B}P1000p%begin 1783208454 310 0\n" +
                "%end 1783208454 310 0\n" +
                "%session-changed $0 ssh-app-session\n"
            ).utf8
        )

        let events = decoder.feedEvents(transcript)

        XCTAssertEqual(events, [
            .controlModeStarted,
            .output(.line(Data("%begin 1783208454 308 0".utf8))),
            .output(.line(Data("duplicate session: ssh-app-session".utf8))),
            .output(.line(Data("%error 1783208454 308 0".utf8))),
            .output(.line(Data("%exit".utf8))),
            .controlModeEnded,
            .controlModeStarted,
            .output(.line(Data("%begin 1783208454 310 0".utf8))),
            .output(.line(Data("%end 1783208454 310 0".utf8))),
            .output(.line(Data("%session-changed $0 ssh-app-session".utf8))),
        ])
        XCTAssertTrue(decoder.isHooked)
    }

    func testEscapedNestedTmuxExitInsideOutputDoesNotEndOuterControlMode() {
        var decoder = TmuxLineDecoder()
        let transcript = Data(
            (
                "\u{1B}P1000p%session-changed $21 ssh-app-session\n" +
                "%output %61 %exit\\015\\012\\033\\134\n" +
                "%client-detached /dev/pts/1\n"
            ).utf8
        )

        let events = decoder.feedEvents(transcript)

        XCTAssertEqual(events, [
            .controlModeStarted,
            .output(.line(Data("%session-changed $21 ssh-app-session".utf8))),
            .output(.line(Data("%output %61 %exit\\015\\012\\033\\134".utf8))),
            .output(.line(Data("%client-detached /dev/pts/1".utf8))),
        ])
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

    // MARK: - 9. %exit stays in line mode

    func testExitLineDoesNotRevertToPassthrough() {
        var decoder = TmuxLineDecoder()
        let outputs = decoder.feed(Data("\u{1B}P1000p%window-add @5\n%exit\nhello\n".utf8))
        XCTAssertEqual(outputs, [
            .line(Data("%window-add @5".utf8)),
            .line(Data("%exit".utf8)),
            .line(Data("hello".utf8)),
        ])
        XCTAssertTrue(decoder.isHooked)
    }

    // MARK: - 10. %exit with reason

    func testExitWithReasonStaysHooked() {
        var decoder = TmuxLineDecoder()
        let outputs = decoder.feed(Data("\u{1B}P1000p%exit detached\n".utf8))
        XCTAssertEqual(outputs, [.line(Data("%exit detached".utf8))])
        XCTAssertTrue(decoder.isHooked)
    }

    func testExitWithReasonThenSTAllowsPassthroughBytes() {
        var decoder = TmuxLineDecoder()
        let outputs = decoder.feed(Data("\u{1B}P1000p%exit normal exit\n\u{1B}\\bye".utf8))
        XCTAssertEqual(outputs, [
            .line(Data("%exit normal exit".utf8)),
            .passthrough(Data("bye".utf8)),
        ])
        XCTAssertFalse(decoder.isHooked)
    }

    func testExitPrefixLineStaysHooked() {
        var decoder = TmuxLineDecoder()
        let outputs = decoder.feed(Data("\u{1B}P1000p%exitfoo\nbar\n".utf8))
        XCTAssertEqual(outputs, [
            .line(Data("%exitfoo".utf8)),
            .line(Data("bar".utf8)),
        ])
        XCTAssertTrue(decoder.isHooked)
    }

    // MARK: - 11. ST handling

    func testSTBeforeExitWithEmptyLineBufferIsLiteral() {
        var decoder = TmuxLineDecoder()
        let outputs = decoder.feed(Data("\u{1B}P1000p%foo\n\u{1B}\\post".utf8))
        XCTAssertEqual(outputs, [
            .line(Data("%foo".utf8)),
        ])
        XCTAssertTrue(decoder.isHooked)
    }

    func testSTBeforeExitMidLineIsLiteral() {
        var decoder = TmuxLineDecoder()
        let outputs = decoder.feed(Data("\u{1B}P1000p%foo\u{1B}\\post\n%exit\n\u{1B}\\after".utf8))
        var literalSTLine = Data("%foo".utf8)
        literalSTLine.append(0x1B)
        literalSTLine.append(0x5C)
        literalSTLine.append(contentsOf: Data("post".utf8))
        XCTAssertEqual(outputs, [
            .line(literalSTLine),
            .line(Data("%exit".utf8)),
            .passthrough(Data("after".utf8)),
        ])
        XCTAssertFalse(decoder.isHooked)
    }

    func testSTAfterExitOnEmptyBufferDoesNotEmitEmptyLine() {
        // ST after `%exit` with no buffered bytes should NOT emit an empty `.line`.
        var decoder = TmuxLineDecoder()
        let outputs = decoder.feed(Data("\u{1B}P1000p%exit\n\u{1B}\\after".utf8))
        XCTAssertEqual(outputs, [
            .line(Data("%exit".utf8)),
            .passthrough(Data("after".utf8)),
        ])
        XCTAssertFalse(decoder.isHooked)
    }

    func testSTInsideCommandResponseBodyDoesNotUnhook() {
        var decoder = TmuxLineDecoder()
        let outputs = decoder.feed(Data("\u{1B}P1000p%begin 1 2 1\nbefore \u{1B}\\ after\n%end 1 2 1\n%exit\n\u{1B}\\tail".utf8))

        var bodyLine = Data("before ".utf8)
        bodyLine.append(0x1B)
        bodyLine.append(0x5C)
        bodyLine.append(contentsOf: Data(" after".utf8))

        XCTAssertEqual(outputs, [
            .line(Data("%begin 1 2 1".utf8)),
            .line(bodyLine),
            .line(Data("%end 1 2 1".utf8)),
            .line(Data("%exit".utf8)),
            .passthrough(Data("tail".utf8)),
        ])
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
        XCTAssertTrue(decoder.isHooked, "true after protocol %exit line")

        _ = decoder.feed(Data("\u{1B}\\".utf8))
        XCTAssertFalse(decoder.isHooked, "false after ST")

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
