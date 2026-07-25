import XCTest
@testable import SSHApp

/// Tests for `TmuxLineParser` — pure-function `Data → TmuxLineEvent` for one
/// line of tmux -CC control-mode output.
///
/// `TmuxLineEvent` is not `Equatable` (it carries `Data`), so each test
/// pattern-matches the case it expects rather than using `XCTAssertEqual`.
final class TmuxLineParserTests: XCTestCase {

    // MARK: - Block markers

    func testParsesBeginBlock() {
        let event = TmuxLineParser.parseLine(Data("%begin 1234 7 3".utf8))
        guard case let .beginBlock(timestamp, num, flags) = event else {
            return XCTFail("expected .beginBlock, got \(event)")
        }
        XCTAssertEqual(timestamp, 1234)
        XCTAssertEqual(num, 7)
        XCTAssertEqual(flags, 3)
    }

    func testParsesEndBlockNotError() {
        let event = TmuxLineParser.parseLine(Data("%end 1234 7 3".utf8))
        guard case let .endBlock(timestamp, num, flags, isError) = event else {
            return XCTFail("expected .endBlock, got \(event)")
        }
        XCTAssertEqual(timestamp, 1234)
        XCTAssertEqual(num, 7)
        XCTAssertEqual(flags, 3)
        XCTAssertFalse(isError)
    }

    func testParsesEndBlockError() {
        let event = TmuxLineParser.parseLine(Data("%error 1234 7 3".utf8))
        guard case let .endBlock(timestamp, num, flags, isError) = event else {
            return XCTFail("expected .endBlock, got \(event)")
        }
        XCTAssertEqual(timestamp, 1234)
        XCTAssertEqual(num, 7)
        XCTAssertEqual(flags, 3)
        XCTAssertTrue(isError)
    }

    // MARK: - %output

    func testParsesPlainOutput() {
        let event = TmuxLineParser.parseLine(Data("%output %3 hello".utf8))
        guard case let .output(paneID, data) = event else {
            return XCTFail("expected .output, got \(event)")
        }
        XCTAssertEqual(paneID, TmuxPaneID(rawValue: 3))
        XCTAssertEqual(data, Data("hello".utf8))
    }

    func testParsesOutputWithOctalLineFeed() {
        // \012 is octal for 0x0A.
        let event = TmuxLineParser.parseLine(Data("%output %3 a\\012b".utf8))
        guard case let .output(paneID, data) = event else {
            return XCTFail("expected .output, got \(event)")
        }
        XCTAssertEqual(paneID, TmuxPaneID(rawValue: 3))
        XCTAssertEqual(data, Data([0x61, 0x0A, 0x62]))
    }

    func testParsesOutputWithLiteralBackslash() {
        // Wire bytes: %output %3 a\\b  (i.e. `a` then `\\` then `b`)
        // After unescape: a, \, b = [0x61, 0x5C, 0x62].
        let bytes: [UInt8] = Array("%output %3 a".utf8) + [0x5C, 0x5C] + Array("b".utf8)
        let event = TmuxLineParser.parseLine(Data(bytes))
        guard case let .output(paneID, data) = event else {
            return XCTFail("expected .output, got \(event)")
        }
        XCTAssertEqual(paneID, TmuxPaneID(rawValue: 3))
        XCTAssertEqual(data, Data([0x61, 0x5C, 0x62]))
    }

    func testParsesOutputWithOctalEscape() {
        // \033 is octal for 0x1B (ESC).
        let event = TmuxLineParser.parseLine(Data("%output %3 a\\033b".utf8))
        guard case let .output(paneID, data) = event else {
            return XCTFail("expected .output, got \(event)")
        }
        XCTAssertEqual(paneID, TmuxPaneID(rawValue: 3))
        XCTAssertEqual(data, Data([0x61, 0x1B, 0x62]))
    }

    func testParsesOutputToleratesCarriageReturnInsideOctalEscape() {
        // tmux's line driver may inject a `\r` mid-escape; the unescaper
        // skips it while accumulating digits. Per iTerm2 TmuxGateway.m:162.
        // Bytes: "%output %3 a\" + "\r" + "012b"
        let bytes: [UInt8] =
            [0x25, 0x6F, 0x75, 0x74, 0x70, 0x75, 0x74, 0x20] // "%output "
            + [0x25, 0x33, 0x20]                              // "%3 "
            + [0x61, 0x5C, 0x0D, 0x30, 0x31, 0x32, 0x62]      // "a\\<CR>012b"
        let event = TmuxLineParser.parseLine(Data(bytes))
        guard case let .output(paneID, data) = event else {
            return XCTFail("expected .output, got \(event)")
        }
        XCTAssertEqual(paneID, TmuxPaneID(rawValue: 3))
        XCTAssertEqual(data, Data([0x61, 0x0A, 0x62]))
    }

    func testParsesOutputPreservesUTF8MultiByte() {
        // 'é' = 0xC3 0xA9 in UTF-8 — keep as-is.
        let bytes: [UInt8] = Array("%output %3 ".utf8) + [0xC3, 0xA9]
        let event = TmuxLineParser.parseLine(Data(bytes))
        guard case let .output(paneID, data) = event else {
            return XCTFail("expected .output, got \(event)")
        }
        XCTAssertEqual(paneID, TmuxPaneID(rawValue: 3))
        XCTAssertEqual(data, Data([0xC3, 0xA9]))
    }

    func testParsesOutputPreservesNonUTF8OctalByte() {
        let event = TmuxLineParser.parseLine(Data("%output %3 \\377".utf8))
        guard case let .output(paneID, data) = event else {
            return XCTFail("expected .output, got \(event)")
        }
        XCTAssertEqual(paneID, TmuxPaneID(rawValue: 3))
        XCTAssertEqual(data, Data([0xFF]))
    }

    // MARK: - %extended-output

    func testParsesExtendedOutput() {
        let event = TmuxLineParser.parseLine(Data("%extended-output %3 42 : foo".utf8))
        guard case let .extendedOutput(paneID, data) = event else {
            return XCTFail("expected .extendedOutput, got \(event)")
        }
        XCTAssertEqual(paneID, TmuxPaneID(rawValue: 3))
        XCTAssertEqual(data, Data("foo".utf8))
    }

    // MARK: - Pane-id overflow (malicious server DoS regression)

    func testOutputWithOverflowingPaneIdBecomesUnrecognizedNotCrash() {
        // Regression: an unchecked `value * 10 + digit` accumulator traps
        // (SIGILL) on a long digit run. A hostile tmux server could crash the
        // app with a single line; it must degrade to `.unrecognized` instead.
        let hugePaneId = String(repeating: "9", count: 40)
        let event = TmuxLineParser.parseLine(Data("%output %\(hugePaneId) hi".utf8))
        guard case .unrecognized = event else {
            return XCTFail("expected .unrecognized for overflowing pane id, got \(event)")
        }
    }

    func testExtendedOutputWithOverflowingPaneIdBecomesUnrecognizedNotCrash() {
        let hugePaneId = String(repeating: "9", count: 40)
        let event = TmuxLineParser.parseLine(Data("%extended-output %\(hugePaneId) 42 : hi".utf8))
        guard case .unrecognized = event else {
            return XCTFail("expected .unrecognized for overflowing pane id, got \(event)")
        }
    }

    func testOutputWithLargeButInRangePaneIdStillParses() {
        // A big-but-valid pane id must still parse (no over-eager rejection).
        let event = TmuxLineParser.parseLine(Data("%output %2000000000 hi".utf8))
        guard case let .output(paneID, data) = event else {
            return XCTFail("expected .output, got \(event)")
        }
        XCTAssertEqual(paneID, TmuxPaneID(rawValue: 2_000_000_000))
        XCTAssertEqual(data, Data("hi".utf8))
    }

    // MARK: - Window lifecycle

    func testParsesWindowAdd() {
        let event = TmuxLineParser.parseLine(Data("%window-add @5".utf8))
        guard case let .windowAdd(id) = event else {
            return XCTFail("expected .windowAdd, got \(event)")
        }
        XCTAssertEqual(id, TmuxWindowID(rawValue: 5))
    }

    func testParsesWindowClose() {
        let event = TmuxLineParser.parseLine(Data("%window-close @9".utf8))
        guard case let .windowClose(id) = event else {
            return XCTFail("expected .windowClose, got \(event)")
        }
        XCTAssertEqual(id, TmuxWindowID(rawValue: 9))
    }

    func testParsesUnlinkedWindowAdd() {
        let event = TmuxLineParser.parseLine(Data("%unlinked-window-add @4".utf8))
        guard case let .unlinkedWindowAdd(id) = event else {
            return XCTFail("expected .unlinkedWindowAdd, got \(event)")
        }
        XCTAssertEqual(id, TmuxWindowID(rawValue: 4))
    }

    func testParsesUnlinkedWindowClose() {
        let event = TmuxLineParser.parseLine(Data("%unlinked-window-close @6".utf8))
        guard case let .unlinkedWindowClose(id) = event else {
            return XCTFail("expected .unlinkedWindowClose, got \(event)")
        }
        XCTAssertEqual(id, TmuxWindowID(rawValue: 6))
    }

    func testParsesWindowRenamedWithMultiwordName() {
        let event = TmuxLineParser.parseLine(Data("%window-renamed @5 dev shell".utf8))
        guard case let .windowRenamed(id, name) = event else {
            return XCTFail("expected .windowRenamed, got \(event)")
        }
        XCTAssertEqual(id, TmuxWindowID(rawValue: 5))
        XCTAssertEqual(name, "dev shell")
    }

    func testParsesUnlinkedWindowRenamedWithMultiwordName() {
        let event = TmuxLineParser.parseLine(Data("%unlinked-window-renamed @24 tmux shell".utf8))
        guard case let .windowRenamed(id, name) = event else {
            return XCTFail("expected .windowRenamed, got \(event)")
        }
        XCTAssertEqual(id, TmuxWindowID(rawValue: 24))
        XCTAssertEqual(name, "tmux shell")
    }

    // MARK: - %layout-change

    func testParsesLayoutChangeWithoutVisibleOrFlags() {
        let event = TmuxLineParser.parseLine(Data("%layout-change @5 abcd,80x24,0,0,3".utf8))
        guard case let .layoutChange(window, layout, visible, flags) = event else {
            return XCTFail("expected .layoutChange, got \(event)")
        }
        XCTAssertEqual(window, TmuxWindowID(rawValue: 5))
        XCTAssertEqual(layout, "abcd,80x24,0,0,3")
        XCTAssertNil(visible)
        XCTAssertEqual(flags, [])
    }

    /// The flags field is a run of symbols, not a number. Line is a verbatim
    /// capture from tmux 3.7b with the active pane zoomed.
    func testParsesLayoutChangeZoomedFlags() {
        let event = TmuxLineParser.parseLine(
            Data("%layout-change @0 c195,80x24,0,0[80x12,0,0,0,80x11,0,13,1] b25e,80x24,0,0,1 *Z".utf8)
        )
        guard case let .layoutChange(window, layout, visible, flags) = event else {
            return XCTFail("expected .layoutChange, got \(event)")
        }
        XCTAssertEqual(window, TmuxWindowID(rawValue: 0))
        XCTAssertEqual(layout, "c195,80x24,0,0[80x12,0,0,0,80x11,0,13,1]")
        // tmux reports the zoomed single-pane layout as the *visible* layout.
        XCTAssertEqual(visible, "b25e,80x24,0,0,1")
        XCTAssertEqual(flags, [.current, .zoomed])
        XCTAssertTrue(flags.contains(.zoomed))
    }

    /// Verbatim capture: activity alert on the last-used window. `#` arrives
    /// unescaped in notifications (single `#`, not `##`).
    func testParsesLayoutChangeActivityAndLastFlags() {
        let event = TmuxLineParser.parseLine(
            Data("%layout-change @0 4196,80x24,0,0[80x12,0,0,0,80x11,0,13,2] 4196,80x24,0,0[80x12,0,0,0,80x11,0,13,2] #-".utf8)
        )
        guard case let .layoutChange(_, _, _, flags) = event else {
            return XCTFail("expected .layoutChange, got \(event)")
        }
        XCTAssertEqual(flags, [.activity, .last])
        XCTAssertTrue(flags.hasAlert)
        XCTAssertFalse(flags.contains(.zoomed))
    }

    func testLayoutChangeFlagsIgnoreUnknownSymbols() {
        // A future tmux flag must not make an otherwise-valid line unparseable.
        let event = TmuxLineParser.parseLine(
            Data("%layout-change @5 abcd,80x24,0,0,3 abcd,80x24,0,0,3 *Q".utf8)
        )
        guard case let .layoutChange(_, _, _, flags) = event else {
            return XCTFail("expected .layoutChange, got \(event)")
        }
        XCTAssertEqual(flags, [.current])
    }

    func testLayoutChangeFlagsAcceptDoubledActivityHash() {
        // Format expansion (`#{window_flags}` via list-windows) escapes `#` as
        // `##`; parsing must be idempotent across both forms.
        XCTAssertEqual(TmuxWindowFlags(wire: "##"), TmuxWindowFlags(wire: "#"))
        XCTAssertEqual(TmuxWindowFlags(wire: "*##"), [.current, .activity])
    }

    func testParsesWindowPaneChanged() {
        let event = TmuxLineParser.parseLine(Data("%window-pane-changed @5 %3".utf8))
        guard case let .windowPaneChanged(window, pane) = event else {
            return XCTFail("expected .windowPaneChanged, got \(event)")
        }
        XCTAssertEqual(window, TmuxWindowID(rawValue: 5))
        XCTAssertEqual(pane, TmuxPaneID(rawValue: 3))
    }

    // MARK: - Sessions

    func testParsesSessionsChanged() {
        let event = TmuxLineParser.parseLine(Data("%sessions-changed".utf8))
        guard case .sessionsChanged = event else {
            return XCTFail("expected .sessionsChanged, got \(event)")
        }
    }

    func testParsesSessionChanged() {
        let event = TmuxLineParser.parseLine(Data("%session-changed $1 main".utf8))
        guard case let .sessionChanged(id, name) = event else {
            return XCTFail("expected .sessionChanged, got \(event)")
        }
        XCTAssertEqual(id, TmuxSessionID(rawValue: 1))
        XCTAssertEqual(name, "main")
    }

    func testParsesSessionWindowChanged() {
        let event = TmuxLineParser.parseLine(Data("%session-window-changed $1 @5".utf8))
        guard case let .sessionWindowChanged(session, window) = event else {
            return XCTFail("expected .sessionWindowChanged, got \(event)")
        }
        XCTAssertEqual(session, TmuxSessionID(rawValue: 1))
        XCTAssertEqual(window, TmuxWindowID(rawValue: 5))
    }

    /// tmux sends the session id first, contrary to the man page's
    /// `%session-renamed name`. Verbatim capture from 3.7b:
    /// `%session-renamed $0 renamed`. Parsing per the man page folded the id into
    /// the name and lost the scope needed to ignore other sessions' renames.
    func testParsesSessionRenamedWithSessionID() {
        let event = TmuxLineParser.parseLine(Data("%session-renamed $0 renamed".utf8))
        guard case let .sessionRenamed(id, name) = event else {
            return XCTFail("expected .sessionRenamed, got \(event)")
        }
        XCTAssertEqual(id, TmuxSessionID(rawValue: 0))
        XCTAssertEqual(name, "renamed")
    }

    func testParsesSessionRenamedWithSpacesInName() {
        let event = TmuxLineParser.parseLine(Data("%session-renamed $3 my dev box".utf8))
        guard case let .sessionRenamed(id, name) = event else {
            return XCTFail("expected .sessionRenamed, got \(event)")
        }
        XCTAssertEqual(id, TmuxSessionID(rawValue: 3))
        XCTAssertEqual(name, "my dev box")
    }

    func testParsesSessionRenamedWithoutSessionIDFallsBackToNameOnly() {
        // Tolerate the man-page shape rather than dropping the event.
        let event = TmuxLineParser.parseLine(Data("%session-renamed dev".utf8))
        guard case let .sessionRenamed(id, name) = event else {
            return XCTFail("expected .sessionRenamed, got \(event)")
        }
        XCTAssertNil(id)
        XCTAssertEqual(name, "dev")
    }

    func testParsesClientSessionChanged() {
        let event = TmuxLineParser.parseLine(Data("%client-session-changed /dev/pts/22 $25 25".utf8))
        guard case let .clientSessionChanged(clientName, session, sessionName) = event else {
            return XCTFail("expected .clientSessionChanged, got \(event)")
        }
        XCTAssertEqual(clientName, "/dev/pts/22")
        XCTAssertEqual(session, TmuxSessionID(rawValue: 25))
        XCTAssertEqual(sessionName, "25")
    }

    // MARK: - Client detached

    func testParsesClientDetachedNoName() {
        let event = TmuxLineParser.parseLine(Data("%client-detached".utf8))
        guard case let .clientDetached(name) = event else {
            return XCTFail("expected .clientDetached, got \(event)")
        }
        XCTAssertNil(name)
    }

    func testParsesClientDetachedWithName() {
        let event = TmuxLineParser.parseLine(Data("%client-detached client-1".utf8))
        guard case let .clientDetached(name) = event else {
            return XCTFail("expected .clientDetached, got \(event)")
        }
        XCTAssertEqual(name, "client-1")
    }

    // MARK: - Pause / Continue

    func testParsesPauseWithoutPane() {
        let event = TmuxLineParser.parseLine(Data("%pause".utf8))
        guard case let .pause(pane) = event else {
            return XCTFail("expected .pause, got \(event)")
        }
        XCTAssertNil(pane)
    }

    func testParsesPauseWithPane() {
        let event = TmuxLineParser.parseLine(Data("%pause %3".utf8))
        guard case let .pause(pane) = event else {
            return XCTFail("expected .pause, got \(event)")
        }
        XCTAssertEqual(pane, TmuxPaneID(rawValue: 3))
    }

    func testParsesContinueWithoutPane() {
        let event = TmuxLineParser.parseLine(Data("%continue".utf8))
        guard case let .continueProcessing(pane) = event else {
            return XCTFail("expected .continueProcessing, got \(event)")
        }
        XCTAssertNil(pane)
    }

    func testParsesContinueWithPane() {
        let event = TmuxLineParser.parseLine(Data("%continue %5".utf8))
        guard case let .continueProcessing(pane) = event else {
            return XCTFail("expected .continueProcessing, got \(event)")
        }
        XCTAssertEqual(pane, TmuxPaneID(rawValue: 5))
    }

    // MARK: - Pane mode change

    func testParsesPaneModeChanged() {
        let event = TmuxLineParser.parseLine(Data("%pane-mode-changed %7".utf8))
        guard case let .paneModeChanged(pane) = event else {
            return XCTFail("expected .paneModeChanged, got \(event)")
        }
        XCTAssertEqual(pane, TmuxPaneID(rawValue: 7))
    }

    // MARK: - Exit

    func testParsesExitNoReason() {
        let event = TmuxLineParser.parseLine(Data("%exit".utf8))
        guard case let .exit(reason) = event else {
            return XCTFail("expected .exit, got \(event)")
        }
        XCTAssertNil(reason)
    }

    func testParsesExitWithReason() {
        let event = TmuxLineParser.parseLine(Data("%exit detached".utf8))
        guard case let .exit(reason) = event else {
            return XCTFail("expected .exit, got \(event)")
        }
        XCTAssertEqual(reason, "detached")
    }

    // MARK: - Body / unrecognized / empty

    func testNonPercentLineIsBody() {
        let event = TmuxLineParser.parseLine(Data("foo bar".utf8))
        guard case let .bodyLine(data) = event else {
            return XCTFail("expected .bodyLine, got \(event)")
        }
        XCTAssertEqual(data, Data("foo bar".utf8))
    }

    func testEmptyLineIsBody() {
        let event = TmuxLineParser.parseLine(Data())
        guard case let .bodyLine(data) = event else {
            return XCTFail("expected .bodyLine, got \(event)")
        }
        XCTAssertEqual(data, Data())
    }

    func testUnknownVerbBecomesUnrecognized() {
        let event = TmuxLineParser.parseLine(Data("%mystery 42".utf8))
        guard case let .unrecognized(line) = event else {
            return XCTFail("expected .unrecognized, got \(event)")
        }
        XCTAssertEqual(line, "%mystery 42")
    }

    // MARK: - %subscription-changed

    /// Verbatim capture from tmux 3.7b after
    /// `refresh-client -B mysub:%*:"#{pane_current_command}"`:
    ///   `%subscription-changed mysub $0 @0 0 %0 : zsh`
    /// Five fields then a standalone `:` — there is no quoted format string on
    /// the wire, and the fourth field is the window *index*, not the pane id.
    func testParsesSubscriptionChangedRealWireFormat() {
        let event = TmuxLineParser.parseLine(
            Data("%subscription-changed mysub $0 @0 0 %0 : zsh".utf8)
        )
        guard case let .subscriptionChanged(name, sid, wid, index, pid, body) = event else {
            return XCTFail("expected .subscriptionChanged, got \(event)")
        }
        XCTAssertEqual(name, "mysub")
        XCTAssertEqual(sid, TmuxSessionID(rawValue: 0))
        XCTAssertEqual(wid, TmuxWindowID(rawValue: 0))
        XCTAssertEqual(index, 0)
        XCTAssertEqual(pid, TmuxPaneID(rawValue: 0))
        XCTAssertEqual(body, "zsh")
    }

    func testParsesSubscriptionChangedValueContainingColons() {
        let event = TmuxLineParser.parseLine(
            Data("%subscription-changed sub1 $1 @5 2 %3 : 12:30:45 up".utf8)
        )
        guard case let .subscriptionChanged(_, _, _, index, _, body) = event else {
            return XCTFail("expected .subscriptionChanged, got \(event)")
        }
        XCTAssertEqual(index, 2)
        XCTAssertEqual(body, "12:30:45 up")
    }

    func testParsesSubscriptionChangedIgnoresReservedFieldsBeforeSeparator() {
        // man tmux: fields after the pane id up to a single `:` are reserved.
        let event = TmuxLineParser.parseLine(
            Data("%subscription-changed sub1 $1 @5 2 %3 future1 future2 : value".utf8)
        )
        guard case let .subscriptionChanged(name, _, _, _, pid, body) = event else {
            return XCTFail("expected .subscriptionChanged, got \(event)")
        }
        XCTAssertEqual(name, "sub1")
        XCTAssertEqual(pid, TmuxPaneID(rawValue: 3))
        XCTAssertEqual(body, "value")
    }

    func testParsesSubscriptionChangedNegativeIDsBecomeNil() {
        let event = TmuxLineParser.parseLine(
            Data("%subscription-changed sub1 $-1 @-1 -1 %-1 : body".utf8)
        )
        guard case let .subscriptionChanged(name, sid, wid, _, pid, body) = event else {
            return XCTFail("expected .subscriptionChanged, got \(event)")
        }
        XCTAssertEqual(name, "sub1")
        XCTAssertNil(sid)
        XCTAssertNil(wid)
        XCTAssertNil(pid)
        XCTAssertEqual(body, "body")
    }

    func testSubscriptionChangedWithoutSeparatorIsUnrecognized() {
        let event = TmuxLineParser.parseLine(
            Data("%subscription-changed sub1 $1 @5 2 %3 no-separator-here".utf8)
        )
        guard case .unrecognized = event else {
            return XCTFail("expected .unrecognized, got \(event)")
        }
    }

    func testSubscriptionChangedWithEmptyValue() {
        let event = TmuxLineParser.parseLine(Data("%subscription-changed sub1 $1 @5 2 %3 :".utf8))
        guard case let .subscriptionChanged(_, _, _, _, _, body) = event else {
            return XCTFail("expected .subscriptionChanged, got \(event)")
        }
        XCTAssertEqual(body, "")
    }

    // MARK: - %message and paste buffers

    func testParsesMessage() {
        let event = TmuxLineParser.parseLine(Data("%message hello from control".utf8))
        guard case let .message(text) = event else {
            return XCTFail("expected .message, got \(event)")
        }
        XCTAssertEqual(text, "hello from control")
    }

    func testParsesPasteBufferChanged() {
        let event = TmuxLineParser.parseLine(Data("%paste-buffer-changed mybuf".utf8))
        guard case let .pasteBufferChanged(name) = event else {
            return XCTFail("expected .pasteBufferChanged, got \(event)")
        }
        XCTAssertEqual(name, "mybuf")
    }

    func testParsesPasteBufferDeleted() {
        let event = TmuxLineParser.parseLine(Data("%paste-buffer-deleted mybuf".utf8))
        guard case let .pasteBufferDeleted(name) = event else {
            return XCTFail("expected .pasteBufferDeleted, got \(event)")
        }
        XCTAssertEqual(name, "mybuf")
    }

    // MARK: - %config-error

    func testParsesConfigError() {
        let event = TmuxLineParser.parseLine(Data("%config-error syntax error in line 3".utf8))
        guard case let .configError(message) = event else {
            return XCTFail("expected .configError, got \(event)")
        }
        XCTAssertEqual(message, "syntax error in line 3")
    }

    // MARK: - unescapeOutputPayload direct tests

    func testUnescapeOctalDigits() {
        // \012 → 0x0A
        let result = TmuxLineParser.unescapeOutputPayload(Data("a\\012b".utf8))
        XCTAssertEqual(result, Data([0x61, 0x0A, 0x62]))
    }

    func testUnescapeOctalEscapeChar() {
        let result = TmuxLineParser.unescapeOutputPayload(Data("a\\033b".utf8))
        XCTAssertEqual(result, Data([0x61, 0x1B, 0x62]))
    }

    func testUnescapeBackslash() {
        // `\\` → `\`
        let bytes: [UInt8] = [0x61, 0x5C, 0x5C, 0x62]
        let result = TmuxLineParser.unescapeOutputPayload(Data(bytes))
        XCTAssertEqual(result, Data([0x61, 0x5C, 0x62]))
    }

    func testUnescapeToleratesCarriageReturnMidOctal() {
        // a \ <CR> 0 1 2 b  → a <LF> b
        let bytes: [UInt8] = [0x61, 0x5C, 0x0D, 0x30, 0x31, 0x32, 0x62]
        let result = TmuxLineParser.unescapeOutputPayload(Data(bytes))
        XCTAssertEqual(result, Data([0x61, 0x0A, 0x62]))
    }

    func testUnescapeDropsLiteralControlBytes() {
        // a <NUL> b <BEL> c → "abc". Tmux escapes all control bytes; literal
        // ones in the payload mean a malformed frame and are dropped.
        let bytes: [UInt8] = [0x61, 0x00, 0x62, 0x07, 0x63]
        let result = TmuxLineParser.unescapeOutputPayload(Data(bytes))
        XCTAssertEqual(result, Data("abc".utf8))
    }

    func testUnescapePreservesPlainBytes() {
        let result = TmuxLineParser.unescapeOutputPayload(Data("hello".utf8))
        XCTAssertEqual(result, Data("hello".utf8))
    }

    func testUnescapePreservesUTF8MultiByte() {
        // 'é' = 0xC3 0xA9 — both bytes >= 0x20 so they pass through verbatim.
        let bytes: [UInt8] = [0xC3, 0xA9]
        let result = TmuxLineParser.unescapeOutputPayload(Data(bytes))
        XCTAssertEqual(result, Data(bytes))
    }

    func testUnescapeSingleOctalDigit() {
        // tmux emits 1-3 octal digits — we accept fewer if no more digits follow.
        // `\7` followed by `x` should yield byte 0x07 then 'x'.
        let result = TmuxLineParser.unescapeOutputPayload(Data("\\7x".utf8))
        XCTAssertEqual(result, Data([0x07, 0x78]))
    }
}
