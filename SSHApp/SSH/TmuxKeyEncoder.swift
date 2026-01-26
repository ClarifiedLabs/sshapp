//
//  TmuxKeyEncoder.swift
//  SSHApp
//
//  Encodes raw input bytes destined for a tmux pane into one or more
//  `send-keys` commands, classifying each byte into one of three encodings
//  and run-length-grouping consecutive same-encoding bytes.
//
//  Lessons mined from iTerm2's TmuxGateway.m:1031
//  (`encodingForCodePoint:useLiteralByteForControl:`):
//
//  - Literal class: printable ASCII / printable UTF-8 — `send -lt %N "text"`.
//  - C0 control class (0x00–0x1F, 0x7F): `send -H -t %N NN NN ...` on tmux
//    3.0a+. The `-H` flag is required because tmux 3.5 with `modifyOtherKeys`
//    rewrites unflagged control bytes as the literal text "0x01" (issue
//    12845). Older tmux without `-H` falls back to `send -t %N 0xNN`.
//  - Hex value class (0x80+ standalone): `send -t %N 0xNN 0xNN ...`. This
//    path runs through tmux's UTF-8 encoder and is reserved for orphaned
//    high bytes that didn't decode as a valid UTF-8 scalar.
//
//  Each command is hard-capped at 1024 bytes per iTerm2's tmux 1.8 crash
//  workaround — runs that would exceed the cap are split.
//

import Foundation
import os

struct TmuxKeyEncoder {

    private static let logger = Logger(subsystem: "dev.sshapp.sshapp.tmux", category: "key-encoder")

    /// Maximum length, in bytes, of any individual command string emitted.
    /// Above this, tmux 1.8 crashed when receiving the command line.
    private static let commandByteCap = 1024

    /// Encode raw input bytes destined for the given pane into one or more
    /// `send-keys` commands respecting the server's version capabilities.
    ///
    /// - Parameters:
    ///   - data: raw bytes the user typed (already encoded as UTF-8 for printable text).
    ///   - paneID: target pane.
    ///   - version: parsed server version, used to gate `-H`.
    /// - Returns: an array of `String` commands, each terminated WITHOUT a trailing newline.
    ///   The caller (gateway) is responsible for joining with `\n` when batching.
    static func encode(data: Data, to paneID: TmuxPaneID, version: TmuxVersion) -> [String] {
        guard !data.isEmpty else { return [] }

        let units = classify(bytes: Array(data))
        let runs = runLengthGroup(units)
        let supportsHex = version.supportsHexInput

        var commands: [String] = []
        for run in runs {
            switch run.encoding {
            case .literal:
                commands.append(contentsOf: literalCommands(for: run.bytes, paneID: paneID))
            case .control:
                if supportsHex {
                    commands.append(contentsOf: hexHCommands(for: run.bytes, paneID: paneID))
                } else {
                    logger.warning("tmux \(version.description, privacy: .public) lacks send -H; falling back to 0xNN form for \(run.bytes.count) control bytes")
                    commands.append(contentsOf: hex0xCommands(for: run.bytes, paneID: paneID))
                }
            case .hexValue:
                commands.append(contentsOf: hex0xCommands(for: run.bytes, paneID: paneID))
            }
        }
        return commands
    }

    // MARK: - Classification

    private enum Encoding {
        /// Printable scalar — emitted via `send -l` inside `"..."`.
        case literal
        /// C0 control byte (0x00–0x1F) or 0x7F.
        case control
        /// Standalone byte 0x80+ that wasn't part of a valid UTF-8 scalar.
        case hexValue
    }

    /// One run of consecutive same-encoding input bytes.
    private struct ByteUnit {
        let bytes: [UInt8]
        let encoding: Encoding
    }

    private struct Run {
        var bytes: [UInt8]
        let encoding: Encoding
    }

    /// Walk the byte stream, decoding multi-byte UTF-8 scalars together so
    /// printable code points stay in the literal class as one unit.
    private static func classify(bytes: [UInt8]) -> [ByteUnit] {
        var units: [ByteUnit] = []
        var index = 0
        while index < bytes.count {
            let first = bytes[index]

            // Single-byte ASCII printable
            if first >= 0x20 && first < 0x7F {
                units.append(ByteUnit(bytes: [first], encoding: .literal))
                index += 1
                continue
            }

            // C0 control or DEL
            if first < 0x20 || first == 0x7F {
                units.append(ByteUnit(bytes: [first], encoding: .control))
                index += 1
                continue
            }

            // first >= 0x80: try to consume a UTF-8 multi-byte scalar.
            let scalarLength = utf8ScalarLength(starting: first)
            if scalarLength > 1, index + scalarLength <= bytes.count {
                let slice = Array(bytes[index..<(index + scalarLength)])
                if isValidUTF8Continuation(slice), let scalar = decodeUTF8(slice), isPrintableScalar(scalar) {
                    units.append(ByteUnit(bytes: slice, encoding: .literal))
                    index += scalarLength
                    continue
                }
            }

            // Orphan or non-printable high byte.
            units.append(ByteUnit(bytes: [first], encoding: .hexValue))
            index += 1
        }
        return units
    }

    /// Expected UTF-8 scalar length for the given lead byte. 1 means "not a
    /// multi-byte lead" (could be ASCII or an invalid continuation/overlong byte).
    private static func utf8ScalarLength(starting first: UInt8) -> Int {
        if first < 0x80 { return 1 }
        if first < 0xC0 { return 1 } // continuation byte without lead — treat as orphan
        if first < 0xE0 { return 2 }
        if first < 0xF0 { return 3 }
        if first < 0xF8 { return 4 }
        return 1
    }

    private static func isValidUTF8Continuation(_ bytes: [UInt8]) -> Bool {
        guard !bytes.isEmpty else { return false }
        for byte in bytes.dropFirst() {
            if (byte & 0xC0) != 0x80 { return false }
        }
        return true
    }

    private static func decodeUTF8(_ bytes: [UInt8]) -> UnicodeScalar? {
        var iterator = bytes.makeIterator()
        var decoder = UTF8()
        switch decoder.decode(&iterator) {
        case .scalarValue(let scalar):
            return scalar
        default:
            return nil
        }
    }

    private static func isPrintableScalar(_ scalar: UnicodeScalar) -> Bool {
        // Printable: anything that isn't a C0/C1 control and isn't DEL.
        let value = scalar.value
        if value < 0x20 { return false }
        if value == 0x7F { return false }
        if value >= 0x80 && value < 0xA0 { return false } // C1 controls
        return true
    }

    // MARK: - Run-length grouping

    private static func runLengthGroup(_ units: [ByteUnit]) -> [Run] {
        var runs: [Run] = []
        for unit in units {
            if var last = runs.last, last.encoding == unit.encoding {
                runs.removeLast()
                last.bytes.append(contentsOf: unit.bytes)
                runs.append(last)
            } else {
                runs.append(Run(bytes: unit.bytes, encoding: unit.encoding))
            }
        }
        return runs
    }

    // MARK: - Command builders

    /// Build one or more literal commands from a run of literal-class bytes,
    /// splitting if any single command would exceed `commandByteCap`.
    private static func literalCommands(for bytes: [UInt8], paneID: TmuxPaneID) -> [String] {
        guard let asString = String(bytes: bytes, encoding: .utf8) else {
            // Should not happen: literal-class bytes are validated UTF-8 by classify().
            // Fall through and treat each byte via the 0x form for safety.
            return hex0xCommands(for: bytes, paneID: paneID)
        }

        let prefix = "send -lt \(paneID.wire) \""
        let suffix = "\""
        let envelopeBytes = prefix.utf8.count + suffix.utf8.count
        let payloadCap = commandByteCap - envelopeBytes

        var commands: [String] = []
        var current = ""
        var currentByteCount = 0

        for character in asString {
            let escaped = escapeForLiteralQuoted(character)
            let escapedByteCount = escaped.utf8.count
            if currentByteCount + escapedByteCount > payloadCap, !current.isEmpty {
                commands.append(prefix + current + suffix)
                current = ""
                currentByteCount = 0
            }
            // Edge case: a single character whose escaped form alone exceeds
            // the cap — emit it on its own; tmux will likely truncate but
            // this is the best we can do without dropping the input.
            current += escaped
            currentByteCount += escapedByteCount
        }
        if !current.isEmpty {
            commands.append(prefix + current + suffix)
        }
        return commands
    }

    /// Escape a single character for placement inside a `"..."` literal payload.
    /// Per task spec: only `"` and `\` need escaping.
    private static func escapeForLiteralQuoted(_ character: Character) -> String {
        var result = ""
        for scalar in character.unicodeScalars {
            switch scalar {
            case "\\":
                result += "\\\\"
            case "\"":
                result += "\\\""
            default:
                result += String(scalar)
            }
        }
        return result
    }

    /// `send -H -t %N NN NN ...` — bytes as 2-digit lowercase hex, no `0x`.
    private static func hexHCommands(for bytes: [UInt8], paneID: TmuxPaneID) -> [String] {
        let prefix = "send -H -t \(paneID.wire)"
        return packHexCommands(bytes: bytes, prefix: prefix, perByteFormat: { String(format: "%02x", $0) })
    }

    /// `send -t %N 0xNN 0xNN ...` — bytes as `0x` + 2-digit lowercase hex.
    private static func hex0xCommands(for bytes: [UInt8], paneID: TmuxPaneID) -> [String] {
        let prefix = "send -t \(paneID.wire)"
        return packHexCommands(bytes: bytes, prefix: prefix, perByteFormat: { String(format: "0x%02x", $0) })
    }

    /// Pack hex-formatted bytes into commands, each prefixed with the given
    /// `prefix` and bounded by `commandByteCap`. Each byte is appended with a
    /// leading space.
    private static func packHexCommands(
        bytes: [UInt8],
        prefix: String,
        perByteFormat: (UInt8) -> String
    ) -> [String] {
        var commands: [String] = []
        var current = prefix
        for byte in bytes {
            let formatted = perByteFormat(byte)
            // " " + formatted appended to current.
            let additional = 1 + formatted.utf8.count
            if current.utf8.count + additional > commandByteCap, current != prefix {
                commands.append(current)
                current = prefix
            }
            current += " " + formatted
        }
        if current != prefix {
            commands.append(current)
        }
        return commands
    }
}
