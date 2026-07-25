//
//  TmuxPaneSnapshot.swift
//  SSHApp
//
//  Utilities for rebuilding a pane from tmux control-mode snapshots.
//

import Foundation

struct TmuxPaneState: Equatable, Sendable {
    let paneID: TmuxPaneID
    /// Pane geometry as of the state probe, which runs immediately before the
    /// `capture-pane` calls. Rendering at the pane's *cached* size instead let a
    /// resize between attach and capture skew every restored row.
    let cols: Int
    let rows: Int
    let alternateOn: Bool
    let alternateSavedX: Int
    let alternateSavedY: Int
    let cursorX: Int
    let cursorY: Int
    let scrollRegionUpper: Int
    let scrollRegionLower: Int
    let tabStops: [Int]
    let cursorVisible: Bool
    let insertMode: Bool
    let applicationCursorKeys: Bool
    let keypadMode: Bool
    let wrapMode: Bool
    let mouseStandardMode: Bool
    let mouseButtonMode: Bool
    let mouseAnyMode: Bool
    let mouseUTF8Mode: Bool
    let mouseSGRMode: Bool
    let bracketedPasteMode: Bool
    let paneKeyMode: String

    static let format = [
        "pane_id=#{pane_id}",
        "pane_width=#{pane_width}",
        "pane_height=#{pane_height}",
        "alternate_on=#{alternate_on}",
        "alternate_saved_x=#{alternate_saved_x}",
        "alternate_saved_y=#{alternate_saved_y}",
        "cursor_x=#{cursor_x}",
        "cursor_y=#{cursor_y}",
        "scroll_region_upper=#{scroll_region_upper}",
        "scroll_region_lower=#{scroll_region_lower}",
        "pane_tabs=#{pane_tabs}",
        "cursor_flag=#{cursor_flag}",
        "insert_flag=#{insert_flag}",
        "keypad_cursor_flag=#{keypad_cursor_flag}",
        "keypad_flag=#{keypad_flag}",
        "wrap_flag=#{wrap_flag}",
        "mouse_standard_flag=#{mouse_standard_flag}",
        "mouse_button_flag=#{mouse_button_flag}",
        "mouse_any_flag=#{mouse_any_flag}",
        "mouse_utf8_flag=#{mouse_utf8_flag}",
        "mouse_sgr_flag=#{mouse_sgr_flag}",
        "bracket_paste_flag=#{bracket_paste_flag}",
        "pane_key_mode=#{pane_key_mode}",
    ].joined(separator: "\t")

    static func parse(from data: Data, paneID expectedPaneID: TmuxPaneID) -> TmuxPaneState? {
        parse(from: String(data: data, encoding: .utf8) ?? "", paneID: expectedPaneID)
    }

    static func parse(from string: String, paneID expectedPaneID: TmuxPaneID) -> TmuxPaneState? {
        for line in string.split(separator: "\n", omittingEmptySubsequences: false) {
            let fields = parseFields(String(line))
            guard fields["pane_id"] == expectedPaneID.wire else { continue }

            return TmuxPaneState(
                paneID: expectedPaneID,
                cols: max(intValue(fields["pane_width"]), 0),
                rows: max(intValue(fields["pane_height"]), 0),
                alternateOn: boolValue(fields["alternate_on"]),
                alternateSavedX: intValue(fields["alternate_saved_x"]),
                alternateSavedY: intValue(fields["alternate_saved_y"]),
                cursorX: intValue(fields["cursor_x"]),
                cursorY: intValue(fields["cursor_y"]),
                scrollRegionUpper: intValue(fields["scroll_region_upper"]),
                scrollRegionLower: intValue(fields["scroll_region_lower"]),
                tabStops: tabStopValues(fields["pane_tabs"]),
                cursorVisible: boolValue(fields["cursor_flag"], defaultValue: true),
                insertMode: boolValue(fields["insert_flag"]),
                applicationCursorKeys: boolValue(fields["keypad_cursor_flag"]),
                keypadMode: boolValue(fields["keypad_flag"]),
                wrapMode: boolValue(fields["wrap_flag"], defaultValue: true),
                mouseStandardMode: boolValue(fields["mouse_standard_flag"]),
                mouseButtonMode: boolValue(fields["mouse_button_flag"]),
                mouseAnyMode: boolValue(fields["mouse_any_flag"]),
                mouseUTF8Mode: boolValue(fields["mouse_utf8_flag"]),
                mouseSGRMode: boolValue(fields["mouse_sgr_flag"]),
                bracketedPasteMode: boolValue(fields["bracket_paste_flag"]),
                paneKeyMode: fields["pane_key_mode"] ?? ""
            )
        }
        return nil
    }

    private static func parseFields(_ line: String) -> [String: String] {
        var result: [String: String] = [:]
        for field in line.split(separator: "\t", omittingEmptySubsequences: false) {
            let parts = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            result[String(parts[0])] = String(parts[1])
        }
        return result
    }

    private static func boolValue(_ string: String?, defaultValue: Bool = false) -> Bool {
        guard let string else { return defaultValue }
        return string == "1" || string == "on" || string == "true"
    }

    private static func intValue(_ string: String?) -> Int {
        guard let string, let value = Int(string) else { return 0 }
        return value
    }

    private static func tabStopValues(_ string: String?) -> [Int] {
        guard let string, !string.isEmpty else { return [] }
        return string
            .split(separator: ",", omittingEmptySubsequences: true)
            .compactMap { Int($0) }
            .filter { $0 >= 0 }
    }
}

struct TmuxPaneSnapshot: Equatable, Sendable {
    let primaryHistory: Data
    let visibleScreen: Data
    let state: TmuxPaneState
    let pendingOutput: Data
}

/// How much of the pane a snapshot render is allowed to rebuild.
enum TmuxPaneRenderMode: Equatable, Sendable {
    /// Rebuild a pane from scratch onto a fresh surface: clears the screen and
    /// the scrollback first, then writes history followed by the visible screen.
    case freshAttach
    /// Correct the visible grid of a pane that is already live and already
    /// holds correct scrollback. Touches only the rows on screen — no screen
    /// clear, no `ESC[3J`, no alternate-screen switching — so local scrollback
    /// and the user's scroll position survive.
    case repaintVisible
}

enum TmuxPaneSnapshotRenderer {
    static func render(
        _ snapshot: TmuxPaneSnapshot,
        cols: Int,
        rows: Int,
        mode: TmuxPaneRenderMode = .freshAttach
    ) -> Data {
        let cols = max(cols, 1)
        let rows = max(rows, 1)
        var output = Data()

        let visibleScreenLines = splitLines(
            TmuxControlModeTextScrubber.scrubCapturedHistory(snapshot.visibleScreen)
        )

        if mode == .repaintVisible {
            // The pane is live: it is already on the correct screen (primary or
            // alternate) and its scrollback is already right. Only the rows are
            // stale, so repaint them in place and leave everything else alone.
            output.appendEscape("[?25l")
            drawVisible(lines: visibleScreenLines, rows: rows, eraseRowTails: true, into: &output)
            applyModes(from: snapshot.state, cols: cols, rows: rows, into: &output)
            moveCursor(
                x: snapshot.state.cursorX,
                y: snapshot.state.cursorY,
                cols: cols,
                rows: rows,
                into: &output
            )
            output.appendEscape(snapshot.state.cursorVisible ? "[?25h" : "[?25l")
            return output
        }

        output.appendEscape("[?25l")
        output.appendEscape("[?1049l")
        output.appendEscape("[0m")
        output.appendEscape("[H")
        output.appendEscape("[2J")
        output.appendEscape("[3J")

        let primaryHistoryLines = splitLines(
            TmuxControlModeTextScrubber.scrubCapturedHistory(snapshot.primaryHistory)
        )

        if snapshot.state.alternateOn {
            // The primary screen's visible rows are not capturable while the
            // alternate screen is active, so stream the scrollback alone. Its
            // tail legitimately stays on the primary screen: that is what the
            // user sees when the full-screen app exits.
            drawStream(lines: primaryHistoryLines, into: &output)
            moveCursor(
                x: snapshot.state.alternateSavedX,
                y: snapshot.state.alternateSavedY,
                cols: cols,
                rows: rows,
                into: &output
            )
            output.appendEscape("[?1049h")
            output.appendEscape("[0m")
            output.appendEscape("[H")
            output.appendEscape("[2J")
            drawVisible(lines: visibleScreenLines, rows: rows, into: &output)
        } else {
            drawPrimary(
                scrollbackLines: primaryHistoryLines,
                visibleLines: visibleScreenLines,
                into: &output
            )
        }

        applyModes(from: snapshot.state, cols: cols, rows: rows, into: &output)
        moveCursor(
            x: snapshot.state.cursorX,
            y: snapshot.state.cursorY,
            cols: cols,
            rows: rows,
            into: &output
        )
        output.appendEscape(snapshot.state.cursorVisible ? "[?25h" : "[?25l")
        output.append(TmuxControlModeTextScrubber.scrubCapturedHistory(snapshot.pendingOutput))
        return output
    }

    /// Restore the primary screen plus its scrollback.
    ///
    /// Content only reaches a terminal's scrollback by scrolling off the top, so
    /// the scrollback and the visible screen must be written as ONE continuous
    /// CRLF-separated stream: the trailing `rows` visible lines are precisely
    /// what push the scrollback lines above the top of the screen.
    ///
    /// The previous implementation wrote the scrollback lines, then issued
    /// `ESC[H ESC[2J`, then positioned the visible rows absolutely. `ESC[2J`
    /// erases in place instead of scrolling, so every scrollback line still on
    /// screen was destroyed — and with fewer than `rows` scrollback lines that
    /// was all of them. It also split `historyLines` by comparing a `-J`-joined
    /// line count against a grid-row count, which are different units.
    ///
    /// `primaryHistory` is now captured with `-E -1`, so it is pure scrollback
    /// with no overlap with the visible screen and no arithmetic is needed.
    private static func drawPrimary(
        scrollbackLines: [Data],
        visibleLines: [Data],
        into output: inout Data
    ) {
        drawStream(lines: scrollbackLines + visibleLines, into: &output)
    }

    /// Write lines as a continuous CRLF-separated stream.
    ///
    /// Emits a single `ESC[0m` up front rather than one per line: `capture-pane
    /// -e` expresses SGR as deltas against the last cell of the previous line
    /// (tmux threads one `lastgc` through the whole capture), so a per-line reset
    /// dropped colour on every continuation line. Each capture response starts
    /// from default attributes, so one reset per response is both necessary and
    /// sufficient.
    private static func drawStream(lines: [Data], into output: inout Data) {
        guard !lines.isEmpty else { return }

        output.appendEscape("[0m")
        for (index, line) in lines.enumerated() {
            if index > 0 {
                output.append(contentsOf: [0x0D, 0x0A])
            }
            output.append(line)
        }
    }

    /// Paint exactly the visible grid, positioning each row absolutely. Rows are
    /// row-exact because the visible capture omits `-J`.
    ///
    /// `eraseRowTails` is for repainting a live pane, where the screen was not
    /// cleared first and a previously-longer line would otherwise show through.
    /// The erase is emitted at column 1 *before* the row's content rather than
    /// after it: a line that exactly fills the width leaves the cursor in the
    /// pending-wrap state, where a trailing `ESC[K` would erase the last cell it
    /// just wrote.
    private static func drawVisible(
        lines: [Data],
        rows: Int,
        eraseRowTails: Bool = false,
        into output: inout Data
    ) {
        output.appendEscape("[0m")
        let drawn = lines.prefix(rows)
        for (index, line) in drawn.enumerated() {
            output.appendEscape("[\(index + 1);1H")
            if eraseRowTails {
                output.appendEscape("[K")
            }
            output.append(line)
        }
        // Clear any rows the capture did not cover, so stale content below the
        // restored screen cannot survive a repaint.
        if eraseRowTails, drawn.count < rows {
            output.appendEscape("[\(drawn.count + 1);1H")
            output.appendEscape("[J")
        }
    }

    private static func applyModes(from state: TmuxPaneState, cols: Int, rows: Int, into output: inout Data) {
        let top = clamped(state.scrollRegionUpper, min: 0, max: rows - 1) + 1
        let bottom = clamped(state.scrollRegionLower, min: 0, max: rows - 1) + 1
        if bottom >= top {
            output.appendEscape("[\(top);\(bottom)r")
        } else {
            output.appendEscape("[r")
        }

        output.appendEscape(state.wrapMode ? "[?7h" : "[?7l")
        output.appendEscape(state.insertMode ? "[4h" : "[4l")
        output.appendEscape(state.applicationCursorKeys ? "[?1h" : "[?1l")
        output.appendEscape(state.keypadMode ? "=" : ">")
        output.appendEscape(state.mouseStandardMode ? "[?1000h" : "[?1000l")
        output.appendEscape(state.mouseButtonMode ? "[?1002h" : "[?1002l")
        output.appendEscape(state.mouseAnyMode ? "[?1003h" : "[?1003l")
        output.appendEscape(state.mouseUTF8Mode ? "[?1005h" : "[?1005l")
        output.appendEscape(state.mouseSGRMode ? "[?1006h" : "[?1006l")
        output.appendEscape(state.bracketedPasteMode ? "[?2004h" : "[?2004l")

        output.appendEscape("[3g")
        for stop in state.tabStops {
            moveCursor(x: stop, y: 0, cols: cols, rows: rows, into: &output)
            output.appendEscape("H")
        }
    }

    private static func moveCursor(x: Int, y: Int, cols: Int, rows: Int, into output: inout Data) {
        let column = clamped(x, min: 0, max: cols - 1) + 1
        let row = clamped(y, min: 0, max: rows - 1) + 1
        output.appendEscape("[\(row);\(column)H")
    }

    private static func splitLines(_ data: Data) -> [Data] {
        guard !data.isEmpty else { return [] }

        var lines: [Data] = []
        var line = Data()
        for byte in data {
            if byte == 0x0A {
                lines.append(line)
                line.removeAll(keepingCapacity: true)
            } else {
                line.append(byte)
            }
        }
        lines.append(line)
        return lines
    }

    private static func clamped(_ value: Int, min minimum: Int, max maximum: Int) -> Int {
        Swift.max(minimum, Swift.min(value, maximum))
    }
}

private extension Data {
    mutating func appendEscape(_ suffix: String) {
        append(0x1B)
        append(contentsOf: suffix.utf8)
    }
}
