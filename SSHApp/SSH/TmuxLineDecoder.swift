//
//  TmuxLineDecoder.swift
//  SSHApp
//
//  Byte-level DCS (Device Control String) detection for tmux -CC control mode.
//  Splits the SSH read stream into pre-DCS passthrough bytes and post-DCS
//  newline-terminated lines suitable for handing to a higher-level parser.
//
//  Detection sequence: ESC P 1 0 0 0 p (0x1B 0x50 0x31 0x30 0x30 0x30 0x70).
//  Termination: a `%exit` tmux protocol line followed by the ST sequence ESC \
//  (0x1B 0x5C). Before `%exit`, ST and other escape sequences are literal tmux
//  input; command responses such as `capture-pane` may contain raw terminal
//  escape sequences and protocol-looking text.
//
//  Per iTerm2's `VT100TmuxParser.m:51`: tmux's line driver may inject `\r`
//  bytes at arbitrary positions. We strip every `\r` while in line-accumulation
//  mode regardless of where it appears.
//

import Foundation

/// Outputs from feeding bytes to the decoder.
enum TmuxDecoderOutput: Equatable {
    /// Pre-DCS or post-ST bytes — feed to the regular terminal.
    case passthrough(Data)
    /// One complete tmux protocol line, NO trailing newline, NO `\r`.
    case line(Data)
}

/// Ordered decoder events, including control-mode lifecycle boundaries.
enum TmuxDecoderEvent: Equatable {
    case controlModeStarted
    case output(TmuxDecoderOutput)
    case controlModeEnded
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

    private static let cr: UInt8 = 0x0D
    private static let lf: UInt8 = 0x0A
    private static let esc: UInt8 = 0x1B
    private static let backslash: UInt8 = 0x5C

    // MARK: - State

    private struct ActiveBlock: Equatable {
        let timestamp: Int
        let commandNumber: Int
        let flags: Int

        func matches(timestamp: Int, commandNumber: Int, flags: Int) -> Bool {
            self.timestamp == timestamp &&
                self.commandNumber == commandNumber &&
                self.flags == flags
        }
    }

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

    /// Current `%begin/%end` command response block, if any. While this is set,
    /// raw `ESC \` bytes belong to command output rather than DCS framing.
    private var activeBlock: ActiveBlock?

    /// True after a real tmux `%exit` notification outside a command response.
    /// iTerm2's DCS parser uses the same model: tmux mode is terminated by
    /// `%exit` followed by ST, not by ST alone.
    private var exitLineSeen = false

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
        activeBlock = nil
        exitLineSeen = false
    }

    /// Feed bytes from the SSH channel. Returns ordered lifecycle and output
    /// events so callers can handle DCS end/start pairs that arrive in one
    /// transport read.
    mutating func feedEvents(_ data: Data) -> [TmuxDecoderEvent] {
        guard !data.isEmpty else { return [] }

        var events: [TmuxDecoderEvent] = []
        // Pending passthrough run we're building up before flushing as one Data.
        var passthroughRun = Data()

        func flushPassthrough() {
            if !passthroughRun.isEmpty {
                events.append(.output(.passthrough(passthroughRun)))
                passthroughRun = Data()
            }
        }

        for byte in data {
            switch mode {
            case .passthrough:
                let expected = Self.dcsHook[dcsMatchLen]
                if byte == expected {
                    dcsMatchLen += 1
                    if dcsMatchLen == Self.dcsHook.count {
                        // Full DCS hook matched. Bytes consumed silently.
                        dcsMatchLen = 0
                        mode = .line
                        lineBuffer.removeAll(keepingCapacity: true)
                        lineModeSawEsc = false
                        flushPassthrough()
                        events.append(.controlModeStarted)
                    }
                    continue
                }

                // Mismatch. The bytes we matched so far were not part of a
                // real DCS, so they belong to passthrough output. Re-emit
                // them, then re-test the *current* byte.
                if dcsMatchLen > 0 {
                    passthroughRun.append(contentsOf: Self.dcsHook.prefix(dcsMatchLen))
                    dcsMatchLen = 0
                }

                // The current byte might itself start a fresh candidate (e.g.
                // a brand new ESC after an aborted run). Re-test from
                // position 0.
                if byte == Self.dcsHook[0] {
                    dcsMatchLen = 1
                } else {
                    passthroughRun.append(byte)
                }
            case .line:
                // If we have any queued passthrough (e.g. produced earlier in
                // this feed) flush it before we start emitting line events.
                flushPassthrough()
                processLineByte(byte, into: &events)
            }
        }

        flushPassthrough()
        return events
    }

    // MARK: - Line mode

    /// Process one byte while in line mode. Handles `\r` stripping, line
    /// boundary detection, and ST termination.
    private mutating func processLineByte(
        _ byte: UInt8,
        into events: inout [TmuxDecoderEvent]
    ) {
        // Handle ST detection: if the previous byte was ESC, this byte
        // determines whether we have ESC \ (terminator) or just a stray ESC.
        if lineModeSawEsc {
            lineModeSawEsc = false
            if byte == Self.backslash {
                // iTerm2 keeps the DCS hook alive until tmux emits `%exit`.
                // Before that, ESC \ is just data in a tmux line, commonly from
                // captured scrollback containing terminal control sequences.
                if !exitLineSeen {
                    lineBuffer.append(Self.esc)
                    lineBuffer.append(Self.backslash)
                    return
                }
                // After `%exit`, ESC \ is the DCS terminator. Finalize any
                // buffered tail line, then return subsequent bytes to the
                // regular terminal parser.
                if !lineBuffer.isEmpty {
                    emitLine(into: &events)
                }
                mode = .passthrough
                dcsMatchLen = 0
                lineBuffer.removeAll(keepingCapacity: true)
                activeBlock = nil
                exitLineSeen = false
                events.append(.controlModeEnded)
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
            emitLine(into: &events)
        case Self.esc:
            // Defer until we see the next byte to detect ST.
            lineModeSawEsc = true
        default:
            lineBuffer.append(byte)
        }
    }

    /// Emit the accumulated line buffer as `.line`.
    private mutating func emitLine(into events: inout [TmuxDecoderEvent]) {
        let line = lineBuffer
        lineBuffer.removeAll(keepingCapacity: true)
        events.append(.output(.line(line)))
        observeProtocolLine(line)
    }

    private mutating func observeProtocolLine(_ line: Data) {
        let event = TmuxLineParser.parseLine(line)
        if let block = activeBlock {
            if case .endBlock(let timestamp, let commandNumber, let flags, _) = event,
               block.matches(timestamp: timestamp, commandNumber: commandNumber, flags: flags) {
                activeBlock = nil
            }
            return
        }

        if case .beginBlock(let timestamp, let commandNumber, let flags) = event {
            activeBlock = ActiveBlock(
                timestamp: timestamp,
                commandNumber: commandNumber,
                flags: flags
            )
        } else if case .exit = event {
            exitLineSeen = true
        }
    }
}
