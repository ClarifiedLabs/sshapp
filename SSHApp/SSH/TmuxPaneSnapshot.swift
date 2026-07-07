//
//  TmuxPaneSnapshot.swift
//  SSHApp
//
//  Utilities for rebuilding a pane from tmux control-mode snapshots.
//

import Foundation

struct TmuxPaneState: Equatable, Sendable {
    let paneID: TmuxPaneID
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

enum TmuxPaneSnapshotRenderer {
    static func render(_ snapshot: TmuxPaneSnapshot, cols: Int, rows: Int) -> Data {
        let cols = max(cols, 1)
        let rows = max(rows, 1)
        var output = Data()

        output.appendEscape("[?25l")
        output.appendEscape("[?1049l")
        output.appendEscape("[0m")
        output.appendEscape("[H")
        output.appendEscape("[2J")
        output.appendEscape("[3J")

        let primaryHistoryLines = splitLines(
            TmuxControlModeTextScrubber.scrubCapturedHistory(snapshot.primaryHistory)
        )
        let visibleScreenLines = splitLines(
            TmuxControlModeTextScrubber.scrubCapturedHistory(snapshot.visibleScreen)
        )

        if snapshot.state.alternateOn {
            drawPrimary(
                historyLines: primaryHistoryLines,
                visibleLines: [],
                rows: rows,
                into: &output
            )
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
                historyLines: primaryHistoryLines,
                visibleLines: visibleScreenLines,
                rows: rows,
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

    private static func drawPrimary(
        historyLines: [Data],
        visibleLines: [Data],
        rows: Int,
        into output: inout Data
    ) {
        let visibleCount = min(rows, historyLines.count)
        let scrollbackCount = max(historyLines.count - visibleCount, 0)

        if scrollbackCount > 0 {
            for line in historyLines.prefix(scrollbackCount) {
                output.appendEscape("[0m")
                output.append(line)
                output.append(contentsOf: [0x0D, 0x0A])
            }
        }

        output.appendEscape("[0m")
        output.appendEscape("[H")
        output.appendEscape("[2J")
        let screenLines: [Data]
        if visibleLines.isEmpty {
            screenLines = Array(historyLines.suffix(visibleCount))
        } else {
            screenLines = visibleLines
        }
        drawVisible(lines: screenLines, rows: rows, into: &output)
    }

    private static func drawVisible(lines: [Data], rows: Int, into output: inout Data) {
        for (index, line) in lines.prefix(rows).enumerated() {
            output.appendEscape("[\(index + 1);1H")
            output.appendEscape("[0m")
            output.append(line)
            output.appendEscape("[0m")
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
