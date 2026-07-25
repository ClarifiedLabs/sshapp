//
//  TmuxPaneSnapshotTests.swift
//  SSHAppTests
//
//  Regression tests for tmux -CC pane snapshot restoration.
//

import XCTest
@testable import SSHApp

final class TmuxPaneSnapshotTests: XCTestCase {
    func testPaneStateParsesITermStyleFormatLine() {
        let line = [
            "pane_id=%7",
            "alternate_on=1",
            "alternate_saved_x=4",
            "alternate_saved_y=5",
            "cursor_x=12",
            "cursor_y=3",
            "scroll_region_upper=1",
            "scroll_region_lower=22",
            "pane_tabs=0,8,16",
            "cursor_flag=1",
            "insert_flag=1",
            "keypad_cursor_flag=1",
            "keypad_flag=1",
            "wrap_flag=0",
            "mouse_standard_flag=1",
            "mouse_button_flag=1",
            "mouse_any_flag=0",
            "mouse_utf8_flag=0",
            "mouse_sgr_flag=1",
            "bracket_paste_flag=1",
            "pane_key_mode=vi",
        ].joined(separator: "\t")

        let state = TmuxPaneState.parse(
            from: line,
            paneID: TmuxPaneID(rawValue: 7)
        )

        XCTAssertEqual(state?.alternateOn, true)
        XCTAssertEqual(state?.alternateSavedX, 4)
        XCTAssertEqual(state?.alternateSavedY, 5)
        XCTAssertEqual(state?.cursorX, 12)
        XCTAssertEqual(state?.cursorY, 3)
        XCTAssertEqual(state?.scrollRegionUpper, 1)
        XCTAssertEqual(state?.scrollRegionLower, 22)
        XCTAssertEqual(state?.tabStops, [0, 8, 16])
        XCTAssertEqual(state?.cursorVisible, true)
        XCTAssertEqual(state?.insertMode, true)
        XCTAssertEqual(state?.applicationCursorKeys, true)
        XCTAssertEqual(state?.keypadMode, true)
        XCTAssertEqual(state?.wrapMode, false)
        XCTAssertEqual(state?.mouseStandardMode, true)
        XCTAssertEqual(state?.mouseButtonMode, true)
        XCTAssertEqual(state?.mouseAnyMode, false)
        XCTAssertEqual(state?.mouseUTF8Mode, false)
        XCTAssertEqual(state?.mouseSGRMode, true)
        XCTAssertEqual(state?.bracketedPasteMode, true)
        XCTAssertEqual(state?.paneKeyMode, "vi")
    }

    func testRendererConvertsCapturedLineFeedsToCarriageReturnLineFeeds() throws {
        let snapshot = TmuxPaneSnapshot(
            primaryHistory: Data("scrollback\ndemo@foo:~$ ".utf8),
            visibleScreen: Data("demo@foo:~$ ".utf8),
            state: makeState(cursorX: 12, cursorY: 0, scrollRegionLower: 1),
            pendingOutput: Data()
        )

        let rendered = TmuxPaneSnapshotRenderer.render(snapshot, cols: 62, rows: 1)
        let renderedString = try XCTUnwrap(String(data: rendered, encoding: .utf8))

        XCTAssertTrue(renderedString.contains("scrollback\r\n"))
        XCTAssertTrue(renderedString.contains("demo@foo:~$ "))
        XCTAssertTrue(renderedString.contains("\u{1B}[1;13H"))
        assertNoBareLineFeeds(rendered)
    }

    func testRendererRestoresAlternateScreenAndCursor() throws {
        let snapshot = TmuxPaneSnapshot(
            primaryHistory: Data("shell".utf8),
            visibleScreen: Data("top".utf8),
            state: makeState(
                alternateOn: true,
                alternateSavedX: 6,
                alternateSavedY: 7,
                cursorX: 4,
                cursorY: 2,
                scrollRegionLower: 23
            ),
            pendingOutput: Data()
        )

        let rendered = TmuxPaneSnapshotRenderer.render(snapshot, cols: 80, rows: 24)
        let renderedString = try XCTUnwrap(String(data: rendered, encoding: .utf8))

        XCTAssertTrue(renderedString.contains("\u{1B}[8;7H"))
        XCTAssertTrue(renderedString.contains("\u{1B}[?1049h"))
        XCTAssertTrue(renderedString.contains("top"))
        XCTAssertTrue(renderedString.contains("\u{1B}[3;5H"))
    }

    func testRendererDrawsCapturedVisibleRowsAfterEnteringAlternateScreen() throws {
        let snapshot = TmuxPaneSnapshot(
            primaryHistory: Data(),
            visibleScreen: Data("codex\n  running".utf8),
            state: makeState(
                alternateOn: true,
                cursorX: 8,
                cursorY: 1,
                scrollRegionLower: 23
            ),
            pendingOutput: Data()
        )

        let rendered = TmuxPaneSnapshotRenderer.render(snapshot, cols: 80, rows: 24)
        let renderedString = try XCTUnwrap(String(data: rendered, encoding: .utf8))
        let alternateStart = try XCTUnwrap(renderedString.range(of: "\u{1B}[?1049h"))
        let visibleContent = try XCTUnwrap(renderedString.range(of: "codex"))

        XCTAssertLessThan(alternateStart.lowerBound, visibleContent.lowerBound)
        // Rows are positioned absolutely with NO per-row SGR reset: `capture-pane
        // -e` emits SGR as deltas against the previous line, so a reset per row
        // dropped colour on every continuation line. One reset per capture
        // response is emitted instead.
        XCTAssertTrue(renderedString.contains("\u{1B}[2;1H  running"))
        XCTAssertFalse(renderedString.contains("\u{1B}[2;1H\u{1B}[0m"))
        XCTAssertTrue(renderedString.contains("\u{1B}[2;9H"))
    }

    func testRendererAppendsPendingOutputAfterStateRestore() {
        var pending = Data([0x1B])
        pending.append(Data("]0;title".utf8))
        pending.append(0x07)
        let snapshot = TmuxPaneSnapshot(
            primaryHistory: Data("demo@foo:~$ ".utf8),
            visibleScreen: Data("demo@foo:~$ ".utf8),
            state: makeState(cursorX: 12, cursorY: 0, scrollRegionLower: 23),
            pendingOutput: pending
        )

        let rendered = TmuxPaneSnapshotRenderer.render(snapshot, cols: 80, rows: 24)

        XCTAssertTrue(rendered.suffix(pending.count).elementsEqual(pending))
    }

    func testRendererDropsCapturedNestedTmuxControlModeLines() throws {
        let history = [
            "before",
            "%client-session-changed /dev/pts/1 $21 ssh-app-session",
            "%unlinked-window-renamed @24 tmux",
            "demo@foo:~$ ",
        ].joined(separator: "\n")
        let snapshot = TmuxPaneSnapshot(
            primaryHistory: Data(history.utf8),
            visibleScreen: Data("%client-session-changed /dev/pts/1 $21 ssh-app-session".utf8),
            state: makeState(alternateOn: true, cursorX: 12, cursorY: 0, scrollRegionLower: 23),
            pendingOutput: Data("%client-session-changed /dev/pts/1 $21 ssh-app-session\n".utf8)
        )

        let rendered = TmuxPaneSnapshotRenderer.render(snapshot, cols: 80, rows: 24)
        let renderedString = try XCTUnwrap(String(data: rendered, encoding: .utf8))

        XCTAssertTrue(renderedString.contains("before"))
        XCTAssertTrue(renderedString.contains("demo@foo:~$ "))
        XCTAssertFalse(renderedString.contains("%client-session-changed"))
        XCTAssertFalse(renderedString.contains("%unlinked-window-renamed"))
    }

    /// Regression: the renderer wrote the scrollback lines and then issued
    /// `ESC[H ESC[2J` before drawing the visible screen. `ESC[2J` erases in place
    /// rather than scrolling, so every scrollback line still on screen was
    /// destroyed — and with fewer than `rows` scrollback lines, that was all of
    /// them. Scrollback and visible screen must stream continuously, because the
    /// trailing visible rows are what push the scrollback above the top.
    func testRendererDoesNotEraseRestoredScrollback() throws {
        let historyLines = (1...6).map { "history\($0)" }
        let snapshot = TmuxPaneSnapshot(
            primaryHistory: Data(historyLines.joined(separator: "\n").utf8),
            visibleScreen: Data("visible1\nvisible2".utf8),
            state: makeState(cursorY: 1),
            pendingOutput: Data()
        )

        let rendered = TmuxPaneSnapshotRenderer.render(snapshot, cols: 80, rows: 24)
        let text = try XCTUnwrap(String(data: rendered, encoding: .utf8))

        for line in historyLines {
            XCTAssertTrue(text.contains(line), "\(line) must survive the restore")
        }

        let historyEnd = try XCTUnwrap(text.range(of: "history6")).upperBound
        let visibleStart = try XCTUnwrap(text.range(of: "visible1")).lowerBound
        XCTAssertLessThan(historyEnd, visibleStart)
        // Nothing may sit between the scrollback and the visible screen that
        // would erase what was just written.
        XCTAssertEqual(String(text[historyEnd..<visibleStart]), "\r\n")
    }

    /// Regression: `capture-pane -e` expresses SGR as deltas against the last
    /// cell of the previous line, so injecting `ESC[0m` per line dropped colour on
    /// every continuation line.
    func testRendererDoesNotResetSGRBetweenLines() throws {
        let snapshot = TmuxPaneSnapshot(
            primaryHistory: Data("\u{1B}[31mred one\nstill red two".utf8),
            visibleScreen: Data("visible".utf8),
            state: makeState(),
            pendingOutput: Data()
        )

        let rendered = TmuxPaneSnapshotRenderer.render(snapshot, cols: 80, rows: 24)
        let text = try XCTUnwrap(String(data: rendered, encoding: .utf8))

        let firstEnd = try XCTUnwrap(text.range(of: "red one")).upperBound
        let secondStart = try XCTUnwrap(text.range(of: "still red two")).lowerBound
        XCTAssertEqual(String(text[firstEnd..<secondStart]), "\r\n")
    }

    func testPaneStateParsesGeometry() {
        let line = [
            "pane_id=%7",
            "pane_width=137",
            "pane_height=42",
            "alternate_on=0",
            "cursor_x=3",
            "cursor_y=4",
        ].joined(separator: "\t")

        let state = TmuxPaneState.parse(from: line, paneID: TmuxPaneID(rawValue: 7))
        XCTAssertEqual(state?.cols, 137)
        XCTAssertEqual(state?.rows, 42)
    }

    private func makeState(
        cols: Int = 80,
        rows: Int = 24,
        alternateOn: Bool = false,
        alternateSavedX: Int = 0,
        alternateSavedY: Int = 0,
        cursorX: Int = 0,
        cursorY: Int = 0,
        scrollRegionLower: Int = 23
    ) -> TmuxPaneState {
        TmuxPaneState(
            paneID: TmuxPaneID(rawValue: 7),
            cols: cols,
            rows: rows,
            alternateOn: alternateOn,
            alternateSavedX: alternateSavedX,
            alternateSavedY: alternateSavedY,
            cursorX: cursorX,
            cursorY: cursorY,
            scrollRegionUpper: 0,
            scrollRegionLower: scrollRegionLower,
            tabStops: [],
            cursorVisible: true,
            insertMode: false,
            applicationCursorKeys: false,
            keypadMode: false,
            wrapMode: true,
            mouseStandardMode: false,
            mouseButtonMode: false,
            mouseAnyMode: false,
            mouseUTF8Mode: false,
            mouseSGRMode: false,
            bracketedPasteMode: false,
            paneKeyMode: "emacs"
        )
    }

    private func assertNoBareLineFeeds(
        _ data: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let bytes = Array(data)
        for index in bytes.indices where bytes[index] == 0x0A {
            XCTAssertGreaterThan(index, bytes.startIndex, file: file, line: line)
            XCTAssertEqual(bytes[index - 1], 0x0D, file: file, line: line)
        }
    }
}
