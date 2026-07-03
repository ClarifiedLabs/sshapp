//
//  TmuxLineParser.swift
//  SSHApp
//
//  Line-level parser for tmux -CC control-mode notifications.
//
//  Input is one complete tmux protocol line (raw bytes, no trailing `\n`,
//  no `\r` — `TmuxLineDecoder` already strips those). Output is exactly one
//  `TmuxLineEvent`. Unknown notifications never fail; they become
//  `.unrecognized(line:)` so the caller can log/forward them.
//
//  `%output` and `%extended-output` payloads are kept as `Data` end-to-end
//  because tmux passes through whatever bytes the application emits — these
//  may contain non-UTF-8 (binary tools, CJK split mid-codepoint across
//  output frames, raw escape sequences, etc.). Decoding to `String` here
//  would silently corrupt them.
//
//  Payload escaping rules (per tmux `cmd-queue.c` / iTerm2 `TmuxGateway.m:162`):
//    `\\`         → literal backslash
//    `\NNN`       → byte with octal value `NNN` (1-3 digits)
//    stray `\r`   → tolerated (skipped) inside a multi-digit octal escape
//    bytes < 0x20 appearing literally → dropped (tmux escapes all control
//                  bytes; literals here mean a malformed frame)
//

import Foundation

enum TmuxLineParser {

    // MARK: - Public API

    /// Parse one tmux protocol line into a `TmuxLineEvent`.
    ///
    /// The input is the raw bytes of the line, without a trailing newline
    /// and with `\r` already stripped by the upstream byte decoder.
    /// Lines that do not start with `%` are treated as command-response
    /// body lines (`.bodyLine`).
    static func parseLine(_ data: Data) -> TmuxLineEvent {
        // Empty line → empty body line. (An empty line cannot be a notification
        // because notifications all start with `%`.)
        guard let first = data.first else {
            return .bodyLine(Data())
        }

        // Body-line fast path: anything that doesn't start with `%` is part
        // of a command response body.
        guard first == 0x25 /* '%' */ else {
            return .bodyLine(data)
        }

        // %output / %extended-output payloads stay as Data — bytewise scan.
        if let event = parseOutputBytewise(data) {
            return event
        }

        // For all other notifications, decode the line as text. Use UTF-8
        // first; fall back to ASCII if the bytes happen to contain invalid
        // UTF-8 sequences (which shouldn't happen for these verbs in
        // practice but keeps us robust).
        let line = stringForLine(data)
        return parseTextLine(line, originalBytes: data)
    }

    /// Decode `%output` payload escaping rules in reverse.
    ///
    /// See file header for the full ruleset. Returns a fresh `Data` that
    /// contains only the unescaped payload bytes.
    static func unescapeOutputPayload(_ data: Data) -> Data {
        var result = Data()
        result.reserveCapacity(data.count)

        let bytes = [UInt8](data)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]

            if b == 0x5C /* '\' */ {
                // Need to look ahead — but \r may be sprinkled mid-escape.
                // Find the next non-`\r` byte after the backslash.
                var j = i + 1
                while j < bytes.count, bytes[j] == 0x0D /* '\r' */ {
                    j += 1
                }
                guard j < bytes.count else {
                    // Trailing backslash with no follow-up; emit it literally
                    // (defensive — shouldn't happen with well-formed tmux output).
                    result.append(0x5C)
                    i += 1
                    continue
                }
                let next = bytes[j]
                if next == 0x5C {
                    // `\\` → '\'
                    result.append(0x5C)
                    i = j + 1
                } else if isOctalDigit(next) {
                    // `\NNN` — collect up to 3 octal digits, skipping any
                    // injected `\r` bytes between digits.
                    var value: Int = 0
                    var digitsRead = 0
                    var k = j
                    while k < bytes.count, digitsRead < 3 {
                        let c = bytes[k]
                        if c == 0x0D {
                            k += 1
                            continue
                        }
                        if !isOctalDigit(c) {
                            break
                        }
                        value = (value << 3) | Int(c - 0x30)
                        digitsRead += 1
                        k += 1
                    }
                    if digitsRead == 0 {
                        // Should be unreachable because we entered this branch
                        // only after seeing one octal digit at `j`.
                        result.append(0x5C)
                        i += 1
                    } else {
                        result.append(UInt8(truncatingIfNeeded: value))
                        i = k
                    }
                } else {
                    // Backslash followed by something else — emit literally.
                    result.append(0x5C)
                    i += 1
                }
                continue
            }

            if b < 0x20 {
                // Stray control byte — drop. tmux escapes all control bytes,
                // so a literal one here is a protocol-framing bug.
                i += 1
                continue
            }

            result.append(b)
            i += 1
        }

        return result
    }

    // MARK: - Output / Extended-Output (bytewise)

    /// Bytewise dispatch for `%output` and `%extended-output`. Returns nil
    /// for any other line so the caller can fall through to text-based
    /// parsing.
    private static func parseOutputBytewise(_ data: Data) -> TmuxLineEvent? {
        // Cheapest possible detection: compare the verb byte-for-byte against
        // ASCII. We avoid building a String over the entire payload.
        let outputPrefix: [UInt8] = [0x25, 0x6F, 0x75, 0x74, 0x70, 0x75, 0x74, 0x20] // "%output "
        let extendedPrefix: [UInt8] = [
            0x25, 0x65, 0x78, 0x74, 0x65, 0x6E, 0x64, 0x65, 0x64, 0x2D,
            0x6F, 0x75, 0x74, 0x70, 0x75, 0x74, 0x20,
        ] // "%extended-output "

        let bytes = [UInt8](data)

        if hasPrefix(bytes, outputPrefix) {
            return parseOutput(bytes: bytes, dataStart: outputPrefix.count)
        }
        if hasPrefix(bytes, extendedPrefix) {
            return parseExtendedOutput(bytes: bytes, dataStart: extendedPrefix.count)
        }
        return nil
    }

    private static func parseOutput(bytes: [UInt8], dataStart: Int) -> TmuxLineEvent? {
        // Format: "%output %<paneId> <data>"
        // `dataStart` indexes the first byte after "%output ".
        guard dataStart < bytes.count, bytes[dataStart] == 0x25 /* '%' */ else {
            return .unrecognized(line: stringForLine(Data(bytes)))
        }
        var i = dataStart + 1
        var paneIdValue = 0
        var hasDigit = false
        while i < bytes.count, isAsciiDigit(bytes[i]) {
            paneIdValue = paneIdValue * 10 + Int(bytes[i] - 0x30)
            hasDigit = true
            i += 1
        }
        guard hasDigit else {
            return .unrecognized(line: stringForLine(Data(bytes)))
        }
        // Consume the single space separator between %paneId and payload.
        // If there's no space (extremely short line), the payload is empty.
        var payloadStart = i
        if payloadStart < bytes.count, bytes[payloadStart] == 0x20 {
            payloadStart += 1
        }
        let raw = Data(bytes[payloadStart..<bytes.count])
        let unescaped = unescapeOutputPayload(raw)
        return .output(paneID: TmuxPaneID(rawValue: paneIdValue), data: unescaped)
    }

    private static func parseExtendedOutput(bytes: [UInt8], dataStart: Int) -> TmuxLineEvent? {
        // Format: "%extended-output %<paneId> <ageMs> : <data>"
        guard dataStart < bytes.count, bytes[dataStart] == 0x25 /* '%' */ else {
            return .unrecognized(line: stringForLine(Data(bytes)))
        }
        var i = dataStart + 1
        var paneIdValue = 0
        var hasDigit = false
        while i < bytes.count, isAsciiDigit(bytes[i]) {
            paneIdValue = paneIdValue * 10 + Int(bytes[i] - 0x30)
            hasDigit = true
            i += 1
        }
        guard hasDigit, i < bytes.count, bytes[i] == 0x20 else {
            return .unrecognized(line: stringForLine(Data(bytes)))
        }
        i += 1 // skip space

        // Scan past the age field (decimal ms; unused, but must be present and
        // consumed to reach the ':' delimiter).
        var ageHasDigit = false
        while i < bytes.count, isAsciiDigit(bytes[i]) {
            ageHasDigit = true
            i += 1
        }
        guard ageHasDigit else {
            return .unrecognized(line: stringForLine(Data(bytes)))
        }

        // Skip whitespace, expect ':' separator, skip whitespace.
        while i < bytes.count, bytes[i] == 0x20 { i += 1 }
        guard i < bytes.count, bytes[i] == 0x3A /* ':' */ else {
            return .unrecognized(line: stringForLine(Data(bytes)))
        }
        i += 1
        if i < bytes.count, bytes[i] == 0x20 { i += 1 }

        let raw = Data(bytes[i..<bytes.count])
        let unescaped = unescapeOutputPayload(raw)
        return .extendedOutput(paneID: TmuxPaneID(rawValue: paneIdValue), data: unescaped)
    }

    // MARK: - Text-line dispatch

    private static func parseTextLine(_ line: String, originalBytes: Data) -> TmuxLineEvent {
        // Split the verb (first whitespace-delimited token) from the rest.
        let (verb, rest) = splitFirstToken(line)

        switch verb {
        case "%begin":
            return parseBeginEnd(rest: rest, isError: false, isEnd: false, originalBytes: originalBytes)
        case "%end":
            return parseBeginEnd(rest: rest, isError: false, isEnd: true, originalBytes: originalBytes)
        case "%error":
            return parseBeginEnd(rest: rest, isError: true, isEnd: true, originalBytes: originalBytes)

        case "%window-add":
            return parseSingleWindowID(rest: rest, originalBytes: originalBytes) { .windowAdd($0) }
        case "%window-close":
            return parseSingleWindowID(rest: rest, originalBytes: originalBytes) { .windowClose($0) }
        case "%unlinked-window-add":
            return parseSingleWindowID(rest: rest, originalBytes: originalBytes) { .unlinkedWindowAdd($0) }
        case "%unlinked-window-close":
            return parseSingleWindowID(rest: rest, originalBytes: originalBytes) { .unlinkedWindowClose($0) }

        case "%window-renamed":
            return parseWindowRenamed(rest: rest, originalBytes: originalBytes)

        case "%layout-change":
            return parseLayoutChange(rest: rest, originalBytes: originalBytes)

        case "%window-pane-changed":
            return parseWindowPaneChanged(rest: rest, originalBytes: originalBytes)

        case "%sessions-changed":
            return .sessionsChanged

        case "%session-changed":
            return parseSessionChanged(rest: rest, originalBytes: originalBytes)

        case "%session-window-changed":
            return parseSessionWindowChanged(rest: rest, originalBytes: originalBytes)

        case "%session-renamed":
            // Everything after the verb is the new session name.
            let trimmed = rest.trimmingCharacters(in: .whitespaces)
            return .sessionRenamed(name: trimmed)

        case "%client-detached":
            let trimmed = rest.trimmingCharacters(in: .whitespaces)
            return .clientDetached(name: trimmed.isEmpty ? nil : trimmed)

        case "%pane-mode-changed":
            return parsePaneModeChanged(rest: rest, originalBytes: originalBytes)

        case "%pause":
            return parseOptionalPaneID(rest: rest) { .pause($0) }
        case "%continue":
            return parseOptionalPaneID(rest: rest) { .continueProcessing($0) }

        case "%subscription-changed":
            return parseSubscriptionChanged(rest: rest, originalBytes: originalBytes)

        case "%config-error":
            // Everything after the verb is the message (preserve interior
            // whitespace exactly, only drop the leading single space).
            return .configError(message: dropLeadingSpace(rest))

        case "%exit":
            let trimmed = rest.trimmingCharacters(in: .whitespaces)
            return .exit(reason: trimmed.isEmpty ? nil : trimmed)

        default:
            return .unrecognized(line: line)
        }
    }

    // MARK: - Per-verb parsers

    private static func parseBeginEnd(
        rest: String,
        isError: Bool,
        isEnd: Bool,
        originalBytes: Data
    ) -> TmuxLineEvent {
        // Format: "<ts> <num> <flags>"
        let parts = rest.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 3,
              let timestamp = Int(parts[0]),
              let num = Int(parts[1]),
              let flags = Int(parts[2])
        else {
            return .unrecognized(line: stringForLine(originalBytes))
        }
        if isEnd {
            return .endBlock(timestamp: timestamp, commandNumber: num, flags: flags, isError: isError)
        }
        return .beginBlock(timestamp: timestamp, commandNumber: num, flags: flags)
    }

    private static func parseSingleWindowID(
        rest: String,
        originalBytes: Data,
        builder: (TmuxWindowID) -> TmuxLineEvent
    ) -> TmuxLineEvent {
        let token = rest.trimmingCharacters(in: .whitespaces)
        guard let id = TmuxWindowID(wire: token) else {
            return .unrecognized(line: stringForLine(originalBytes))
        }
        return builder(id)
    }

    private static func parseWindowRenamed(rest: String, originalBytes: Data) -> TmuxLineEvent {
        // Format: "@<id> <name with possible spaces>"
        let (idTok, nameRest) = splitFirstToken(rest)
        guard let id = TmuxWindowID(wire: idTok) else {
            return .unrecognized(line: stringForLine(originalBytes))
        }
        // The name is everything after the first space — preserve interior
        // whitespace, just strip a single leading space if present.
        let name = dropLeadingSpace(nameRest)
        return .windowRenamed(id, name: name)
    }

    private static func parseLayoutChange(rest: String, originalBytes: Data) -> TmuxLineEvent {
        // Format: "@<id> <layout> [<visibleLayout> [<flags>]]"
        let parts = rest.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2, let id = TmuxWindowID(wire: parts[0]) else {
            return .unrecognized(line: stringForLine(originalBytes))
        }
        let layout = parts[1]
        let visible: String? = parts.count >= 3 ? parts[2] : nil
        let flags: Int = (parts.count >= 4 ? Int(parts[3]) : nil) ?? 0
        return .layoutChange(window: id, layout: layout, visibleLayout: visible, flags: flags)
    }

    private static func parseWindowPaneChanged(rest: String, originalBytes: Data) -> TmuxLineEvent {
        // Format: "@<windowId> %<paneId>"
        let parts = rest.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2,
              let windowID = TmuxWindowID(wire: parts[0]),
              let paneID = TmuxPaneID(wire: parts[1])
        else {
            return .unrecognized(line: stringForLine(originalBytes))
        }
        return .windowPaneChanged(window: windowID, pane: paneID)
    }

    private static func parseSessionChanged(rest: String, originalBytes: Data) -> TmuxLineEvent {
        // Format: "$<id> <name>"
        let (idTok, nameRest) = splitFirstToken(rest)
        guard let id = TmuxSessionID(wire: idTok) else {
            return .unrecognized(line: stringForLine(originalBytes))
        }
        let name = dropLeadingSpace(nameRest)
        return .sessionChanged(id, name: name)
    }

    private static func parseSessionWindowChanged(rest: String, originalBytes: Data) -> TmuxLineEvent {
        // Format: "$<sessionId> @<windowId>"
        let parts = rest.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2,
              let sessionID = TmuxSessionID(wire: parts[0]),
              let windowID = TmuxWindowID(wire: parts[1])
        else {
            return .unrecognized(line: stringForLine(originalBytes))
        }
        return .sessionWindowChanged(session: sessionID, window: windowID)
    }

    private static func parsePaneModeChanged(rest: String, originalBytes: Data) -> TmuxLineEvent {
        let token = rest.trimmingCharacters(in: .whitespaces)
        guard let id = TmuxPaneID(wire: token) else {
            return .unrecognized(line: stringForLine(originalBytes))
        }
        return .paneModeChanged(id)
    }

    private static func parseOptionalPaneID(
        rest: String,
        builder: (TmuxPaneID?) -> TmuxLineEvent
    ) -> TmuxLineEvent {
        let token = rest.trimmingCharacters(in: .whitespaces)
        if token.isEmpty {
            return builder(nil)
        }
        return builder(TmuxPaneID(wire: token))
    }

    private static func parseSubscriptionChanged(rest: String, originalBytes: Data) -> TmuxLineEvent {
        // Format: `<name> $<sid> @<wid> %<pid> "<format>" : <body>`
        // The format string is wrapped in double-quotes (with `\"` permitted
        // for embedded quotes); we have to skip past it before looking for
        // the standalone `:` that separates from the body.

        let scalars = Array(rest)
        var i = 0
        let n = scalars.count

        func skipSpaces() {
            while i < n, scalars[i] == " " { i += 1 }
        }
        func nextToken() -> String? {
            skipSpaces()
            let start = i
            while i < n, scalars[i] != " " { i += 1 }
            return start == i ? nil : String(scalars[start..<i])
        }

        skipSpaces()
        guard let name = nextToken(),
              let sidTok = nextToken(),
              let widTok = nextToken(),
              let pidTok = nextToken()
        else {
            return .unrecognized(line: stringForLine(originalBytes))
        }
        skipSpaces()

        // Format string in double quotes.
        guard i < n, scalars[i] == "\"" else {
            return .unrecognized(line: stringForLine(originalBytes))
        }
        i += 1 // consume opening quote
        // Skip until matching unescaped quote.
        while i < n {
            let c = scalars[i]
            if c == "\\" && i + 1 < n {
                i += 2
                continue
            }
            if c == "\"" {
                break
            }
            i += 1
        }
        guard i < n, scalars[i] == "\"" else {
            return .unrecognized(line: stringForLine(originalBytes))
        }
        i += 1 // consume closing quote

        skipSpaces()
        guard i < n, scalars[i] == ":" else {
            return .unrecognized(line: stringForLine(originalBytes))
        }
        i += 1 // consume ':'
        if i < n, scalars[i] == " " { i += 1 } // skip single separator space

        let body = i <= n ? String(scalars[i..<n]) : ""

        return .subscriptionChanged(
            name: name,
            sessionID: parseOptionalSessionID(sidTok),
            windowID: parseOptionalWindowID(widTok),
            paneID: parseOptionalPaneID(pidTok),
            body: body
        )
    }

    // MARK: - Helpers

    private static func parseOptionalSessionID(_ token: String) -> TmuxSessionID? {
        guard let id = TmuxSessionID(wire: token) else { return nil }
        return id.rawValue < 0 ? nil : id
    }

    private static func parseOptionalWindowID(_ token: String) -> TmuxWindowID? {
        guard let id = TmuxWindowID(wire: token) else { return nil }
        return id.rawValue < 0 ? nil : id
    }

    private static func parseOptionalPaneID(_ token: String) -> TmuxPaneID? {
        guard let id = TmuxPaneID(wire: token) else { return nil }
        return id.rawValue < 0 ? nil : id
    }

    private static func splitFirstToken(_ line: String) -> (String, String) {
        guard let space = line.firstIndex(of: " ") else {
            return (line, "")
        }
        let verb = String(line[..<space])
        let rest = String(line[line.index(after: space)...])
        return (verb, rest)
    }

    private static func dropLeadingSpace(_ s: String) -> String {
        if s.first == " " { return String(s.dropFirst()) }
        return s
    }

    private static func stringForLine(_ data: Data) -> String {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .ascii)
            ?? ""
    }

    @inline(__always)
    private static func isAsciiDigit(_ b: UInt8) -> Bool {
        b >= 0x30 && b <= 0x39
    }

    @inline(__always)
    private static func isOctalDigit(_ b: UInt8) -> Bool {
        b >= 0x30 && b <= 0x37
    }

    private static func hasPrefix(_ bytes: [UInt8], _ prefix: [UInt8]) -> Bool {
        guard bytes.count >= prefix.count else { return false }
        for i in 0..<prefix.count where bytes[i] != prefix[i] { return false }
        return true
    }
}
