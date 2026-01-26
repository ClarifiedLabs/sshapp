//
//  TmuxLineDecoder.swift
//  SSHApp
//
//  Byte-level DCS (Device Control String) detection for tmux -CC control mode.
//  Splits the SSH read stream into pre-DCS passthrough bytes and post-DCS
//  newline-terminated lines suitable for handing to a higher-level parser.
//
//  Detection sequence: ESC P 1 0 0 0 p (0x1B 0x50 0x31 0x30 0x30 0x30 0x70).
//  Termination: a complete line of `%exit` (or `%exit <reason>`), or the
//  ST sequence ESC \ (0x1B 0x5C). After termination we revert to passthrough
//  for the (typically brief) tail before the SSH channel closes.
//
//  Per iTerm2's `VT100TmuxParser.m:51`: tmux's line driver may inject `\r`
//  bytes at arbitrary positions. We strip every `\r` while in line-accumulation
//  mode regardless of where it appears.
//

import Foundation

/// Outputs from feeding bytes to the decoder.
enum TmuxDecoderOutput: Equatable {
    /// Pre-DCS or post-`%exit` bytes — feed to the regular terminal.
    case passthrough(Data)
    /// One complete tmux protocol line, NO trailing newline, NO `\r`.
    case line(Data)
}

/// Stateful byte-level decoder that splits an SSH stream into
/// `passthrough` bytes (regular terminal output) and `line` bytes
/// (one tmux control-mode line at a time).
///
/// Pure value type: no async, no actors, no callbacks. Caller owns
/// the instance and feeds it bytes as they arrive.
struct TmuxLineDecoder {

    // MARK: - DCS sequence constants

    /// `ESC P 1 0 0 0 p` — the DCS hook tmux emits on `tmux -CC` startup.
    private static let dcsHook: [UInt8] = [0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70]

    /// `%exit` literal — when this is the entire line (or followed by ` <reason>`),
    /// the DCS hook ends.
    private static let exitPrefix: [UInt8] = [0x25, 0x65, 0x78, 0x69, 0x74] // "%exit"

    private static let cr: UInt8 = 0x0D
    private static let lf: UInt8 = 0x0A
    private static let esc: UInt8 = 0x1B
    private static let backslash: UInt8 = 0x5C
    private static let space: UInt8 = 0x20

    // MARK: - State

    private enum Mode {
        /// Bytes flow through as passthrough. We are scanning for the DCS hook.
        case passthrough
        /// We are inside the DCS hook. Bytes accumulate into lines.
        case line
    }

    private var mode: Mode = .passthrough

    /// How many bytes of `dcsHook` we've matched so far in passthrough mode.
    /// 0 means no candidate match in progress.
    private var dcsMatchLen: Int = 0

    /// Accumulated bytes for the current in-flight line (line mode only).
    private var lineBuffer: Data = Data()

    /// True iff we just saw an ESC byte while in line mode (candidate ST start).
    private var lineModeSawEsc: Bool = false

    // MARK: - Public API

    /// True iff we are currently inside a DCS hook (i.e. emitting `.line` for received bytes).
    var isHooked: Bool {
        if case .line = mode { return true }
        return false
    }

    init() {}

    /// Reset to initial (un-hooked) state. Drops any pending line buffer.
    mutating func reset() {
        mode = .passthrough
        dcsMatchLen = 0
        lineBuffer = Data()
        lineModeSawEsc = false
    }

    /// Feed bytes from the SSH channel. Returns zero or more outputs.
    /// Caller must drain the result before next feed.
    mutating func feed(_ data: Data) -> [TmuxDecoderOutput] {
        guard !data.isEmpty else { return [] }

        var outputs: [TmuxDecoderOutput] = []
        // Pending passthrough run we're building up before flushing as one Data.
        var passthroughRun = Data()

        func flushPassthrough() {
            if !passthroughRun.isEmpty {
                outputs.append(.passthrough(passthroughRun))
                passthroughRun = Data()
            }
        }

        for byte in data {
            switch mode {
            case .passthrough:
                processPassthroughByte(byte, into: &passthroughRun)
            case .line:
                // If we have any queued passthrough (e.g. produced earlier in
                // this feed) flush it before we start emitting line events.
                flushPassthrough()
                processLineByte(byte, into: &outputs)
            }
        }

        flushPassthrough()
        return outputs
    }

    // MARK: - Passthrough mode

    /// Process one byte while in passthrough mode. Handles incremental
    /// matching of the DCS hook sequence. On full match, switches to line mode.
    /// On mismatch mid-candidate, the previously-buffered candidate bytes are
    /// flushed back to passthrough and detection resumes from the current byte.
    private mutating func processPassthroughByte(
        _ byte: UInt8,
        into passthroughRun: inout Data
    ) {
        let expected = Self.dcsHook[dcsMatchLen]
        if byte == expected {
            dcsMatchLen += 1
            if dcsMatchLen == Self.dcsHook.count {
                // Full DCS hook matched. Bytes consumed silently.
                dcsMatchLen = 0
                mode = .line
                lineBuffer.removeAll(keepingCapacity: true)
                lineModeSawEsc = false
            }
            return
        }

        // Mismatch. The bytes we matched so far were not part of a real DCS,
        // so they belong to passthrough output. Re-emit them, then re-test
        // the *current* byte.
        if dcsMatchLen > 0 {
            passthroughRun.append(contentsOf: Self.dcsHook.prefix(dcsMatchLen))
            dcsMatchLen = 0
        }

        // The current byte might itself start a fresh candidate (e.g. a
        // brand new ESC after an aborted run). Re-test from position 0.
        if byte == Self.dcsHook[0] {
            dcsMatchLen = 1
        } else {
            passthroughRun.append(byte)
        }
    }

    // MARK: - Line mode

    /// Process one byte while in line mode. Handles `\r` stripping, line
    /// boundary detection, ST termination, and `%exit` termination.
    private mutating func processLineByte(
        _ byte: UInt8,
        into outputs: inout [TmuxDecoderOutput]
    ) {
        // Handle ST detection: if the previous byte was ESC, this byte
        // determines whether we have ESC \ (terminator) or just a stray ESC.
        if lineModeSawEsc {
            lineModeSawEsc = false
            if byte == Self.backslash {
                // ESC \ is a String Terminator. Finalize current line buffer
                // (without the ESC \ bytes) if non-empty, then revert to
                // passthrough. An empty buffer at ST time means we already
                // emitted the line on a preceding `\n`, so we don't emit an
                // empty line here.
                if !lineBuffer.isEmpty {
                    emitLineAndCheckExit(into: &outputs)
                }
                mode = .passthrough
                dcsMatchLen = 0
                lineBuffer.removeAll(keepingCapacity: true)
                return
            } else {
                // Not an ST. The ESC byte we deferred is a literal in the line.
                lineBuffer.append(Self.esc)
                // Fall through to process this byte normally.
            }
        }

        switch byte {
        case Self.cr:
            // Strip every `\r` regardless of position (iTerm2 lesson).
            return
        case Self.lf:
            emitLineAndCheckExit(into: &outputs)
        case Self.esc:
            // Defer until we see the next byte to detect ST.
            lineModeSawEsc = true
        default:
            lineBuffer.append(byte)
        }
    }

    /// Emit the accumulated line buffer as `.line`, then check whether it was
    /// the `%exit` sentinel. If so, switch back to passthrough mode.
    private mutating func emitLineAndCheckExit(into outputs: inout [TmuxDecoderOutput]) {
        let line = lineBuffer
        lineBuffer.removeAll(keepingCapacity: true)
        outputs.append(.line(line))

        if isExitLine(line) {
            mode = .passthrough
            dcsMatchLen = 0
            lineModeSawEsc = false
        }
    }

    /// True iff `line` is exactly `%exit` or starts with `%exit ` (followed by reason).
    private func isExitLine(_ line: Data) -> Bool {
        let prefix = Self.exitPrefix
        guard line.count >= prefix.count else { return false }
        for (i, expected) in prefix.enumerated() where line[line.startIndex + i] != expected {
            return false
        }
        if line.count == prefix.count { return true }
        // Followed by space + reason
        return line[line.startIndex + prefix.count] == Self.space
    }
}
