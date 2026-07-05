//
//  TmuxGateway.swift
//  SSHApp
//
//  Protocol-aware bridge between raw tmux protocol lines and the controller.
//  Owns the FIFO of pending commands awaiting their `%begin/%end` round-trip
//  response, the body accumulator for the in-flight response, and the byte
//  writer that delivers commands back to the SSH channel.
//
//  Caller (session) is responsible for DCS detection / line decoding upstream
//  via `TmuxLineDecoder`. Each line fed in here is one complete tmux protocol
//  line with no trailing `\n` and `\r` already stripped.
//
//  Edge cases (mined from iTerm2's TmuxGateway.m):
//   1. tmux guarantees in-order command responses, so we DON'T match `%begin`
//      IDs against the queue — we use the FIFO head and assert the ID matches
//      as a sanity check.
//   2. tmux notifications never occur inside a `%begin/%end` block, so lines
//      that look like protocol notifications while a response is active are
//      command output unless they are the matching `%end` or `%error`.
//   3. Server-originated commands (begin flag bit 0 == 0) — emit the response
//      as a free-standing `.commandResponse` to the delegate; no continuation.
//

import Foundation
import os

/// Async writer the gateway uses to push command bytes back over the SSH channel.
typealias TmuxByteWriter = @Sendable (Data) async throws -> Void

/// Delegate that receives high-level controller events and shutdown notifications.
protocol TmuxGatewayDelegate: AnyObject, Sendable {
    func gateway(_ gateway: TmuxGateway, didReceive event: TmuxControllerEvent) async
    func gatewayDidShutDown(_ gateway: TmuxGateway, reason: String?) async
}

actor TmuxGateway {

    // MARK: - Internal types

    /// Disposition for what to do with a command's response when it arrives.
    private enum ResponseHandler {
        /// Resolve a normal sendCommand caller's continuation.
        case continuation(CheckedContinuation<TmuxCommandResponse, Error>)
        /// Discard the response (used by sendKeysToPane).
        case discard
    }

    private struct PendingCommand {
        let command: String
        let timestamp: Date
        let handler: ResponseHandler
    }

    private struct ActiveResponse {
        let timestamp: Int
        let commandNumber: Int
        let flags: Int
        var bodyBytes: Data
        let handler: ResponseHandler?  // nil for server-originated responses

        func matches(timestamp: Int, commandNumber: Int, flags: Int) -> Bool {
            self.timestamp == timestamp &&
                self.commandNumber == commandNumber &&
                self.flags == flags
        }
    }

    // MARK: - State

    private let logger = Logger(subsystem: "dev.sshapp.sshapp.tmux", category: "gateway")
    private let writer: TmuxByteWriter
    private weak var delegate: TmuxGatewayDelegate?

    private var pendingCommands: [PendingCommand] = []
    private var activeResponse: ActiveResponse?
    private var isShutdown: Bool = false

    // MARK: - Init

    init(writer: @escaping TmuxByteWriter) {
        self.writer = writer
    }

    // MARK: - Configuration

    func setDelegate(_ delegate: TmuxGatewayDelegate?) {
        self.delegate = delegate
    }

    // MARK: - Line ingestion

    /// Feed one complete tmux protocol line (no trailing `\n`, `\r` already stripped).
    /// The caller is responsible for the line decoder upstream.
    func feedLine(_ line: Data) async {
        guard !isShutdown else { return }

        let event = TmuxLineParser.parseLine(line)
        if activeResponse != nil {
            switch event {
            case .endBlock(let timestamp, let commandNumber, let flags, let isError)
                where activeResponse?.matches(timestamp: timestamp, commandNumber: commandNumber, flags: flags) == true:
                await handleEndBlock(isError: isError)

            default:
                handleBodyLine(line)
            }
            return
        }

        switch event {
        case .beginBlock(let timestamp, let commandNumber, let flags):
            await handleBeginBlock(timestamp: timestamp, commandNumber: commandNumber, flags: flags)

        case .bodyLine(let data):
            handleBodyLine(data)

        case .endBlock:
            logger.warning("%end received without active response; dropping")

        case .exit(let reason):
            await handleExit(reason: reason)

        case .output(let paneID, let data):
            await emit(.output(paneID: paneID, data: data))
        case .extendedOutput(let paneID, let data):
            await emit(.extendedOutput(paneID: paneID, data: data))

        case .windowAdd(let id):
            await emit(.windowAdd(id))
        case .windowClose(let id):
            await emit(.windowClose(id))
        case .windowRenamed(let id, let name):
            await emit(.windowRenamed(id, name: name))
        case .unlinkedWindowAdd(let id):
            await emit(.unlinkedWindowAdd(id))
        case .unlinkedWindowClose(let id):
            await emit(.unlinkedWindowClose(id))
        case .layoutChange(let window, let layout, let visibleLayout, let flags):
            await emit(.layoutChange(window: window, layout: layout, visibleLayout: visibleLayout, flags: flags))
        case .windowPaneChanged(let window, let pane):
            await emit(.windowPaneChanged(window: window, pane: pane))

        case .sessionsChanged:
            await emit(.sessionsChanged)
        case .sessionChanged(let id, let name):
            await emit(.sessionChanged(id, name: name))
        case .sessionWindowChanged(let session, let window):
            await emit(.sessionWindowChanged(session: session, window: window))
        case .sessionRenamed(let name):
            await emit(.sessionRenamed(name: name))
        case .clientSessionChanged(let clientName, let session, let sessionName):
            await emit(.clientSessionChanged(
                clientName: clientName,
                session: session,
                sessionName: sessionName
            ))
        case .clientDetached(let name):
            await emit(.clientDetached(name: name))

        case .paneModeChanged(let id):
            await emit(.paneModeChanged(id))
        case .pause(let id):
            await emit(.pause(id))
        case .continueProcessing(let id):
            await emit(.continueProcessing(id))

        case .subscriptionChanged(let name, let sessionID, let windowID, let paneID, let body):
            await emit(.subscriptionChanged(
                name: name,
                sessionID: sessionID,
                windowID: windowID,
                paneID: paneID,
                body: body
            ))

        case .configError(let message):
            await emit(.configError(message: message))

        case .unrecognized(let line):
            logger.debug("unrecognized tmux line: \(line, privacy: .public)")
        }
    }

    // MARK: - Block handling

    private func handleBeginBlock(timestamp: Int, commandNumber: Int, flags: Int) async {
        if let prior = activeResponse {
            // Protocol error: a new %begin while a previous block is still open.
            // Synthesize an error end for the prior block before starting the new one.
            logger.warning(
                "%begin while active response (#\(prior.commandNumber)) is still open; closing prior with error"
            )
            await finalizeActiveResponse(synthesizedIsError: true, dispatchToDelegate: false)
        }

        let handler: ResponseHandler?
        if flags & 0x1 != 0 {
            // Client-originated — dequeue head.
            if pendingCommands.isEmpty {
                logger.warning(
                    "%begin \(commandNumber) flagged client-originated but pending queue is empty"
                )
                handler = nil
            } else {
                handler = pendingCommands.removeFirst().handler
            }
        } else {
            // Server-originated — no matching pending command.
            handler = nil
        }

        activeResponse = ActiveResponse(
            timestamp: timestamp,
            commandNumber: commandNumber,
            flags: flags,
            bodyBytes: Data(),
            handler: handler
        )
    }

    private func handleBodyLine(_ data: Data) {
        guard activeResponse != nil else {
            logger.warning("body line received outside %begin/%end block; dropping")
            return
        }
        activeResponse?.bodyBytes.append(data)
        activeResponse?.bodyBytes.append(0x0A) // re-add the `\n` stripped by the line decoder
    }

    private func handleEndBlock(isError: Bool) async {
        guard activeResponse != nil else {
            logger.warning("%end received without active response; dropping")
            return
        }
        await finalizeActiveResponse(synthesizedIsError: isError, dispatchToDelegate: true)
    }

    /// Build a `TmuxCommandResponse` from `activeResponse`, resolve its handler
    /// (if any), optionally dispatch the response to delegate, and clear state.
    @discardableResult
    private func finalizeActiveResponse(
        synthesizedIsError isError: Bool,
        dispatchToDelegate: Bool
    ) async -> TmuxCommandResponse? {
        guard let active = activeResponse else { return nil }

        // Trim the trailing `\n` we appended after the last body line (if any).
        var body = active.bodyBytes
        if body.last == 0x0A {
            body.removeLast()
        }

        let response = TmuxCommandResponse(
            commandNumber: active.commandNumber,
            body: body,
            isError: isError
        )

        activeResponse = nil

        // Resolve waiting handler, if any.
        if let handler = active.handler {
            resolveHandler(handler, response: response, isError: isError)
        }

        // Notify delegate of the response. We await inline so tests can deterministically
        // observe events after feedLine returns.
        if dispatchToDelegate, let delegate = delegate {
            await delegate.gateway(self, didReceive: .commandResponse(response))
        }
        return response
    }

    private func resolveHandler(_ handler: ResponseHandler, response: TmuxCommandResponse, isError: Bool) {
        switch handler {
        case .continuation(let continuation):
            if isError {
                continuation.resume(throwing: TmuxError.commandFailed(message: response.bodyString))
            } else {
                continuation.resume(returning: response)
            }

        case .discard:
            return
        }
    }

    private func failHandler(_ handler: ResponseHandler, with error: Error) {
        switch handler {
        case .continuation(let continuation):
            continuation.resume(throwing: error)
        case .discard:
            return
        }
    }

    private func handleExit(reason: String?) async {
        // Fail any in-flight response with disconnected.
        if let active = activeResponse {
            activeResponse = nil
            if let handler = active.handler {
                failHandler(handler, with: TmuxError.disconnected)
            }
        }
        // Drain the queue with disconnected errors.
        let queued = pendingCommands
        pendingCommands.removeAll()
        for command in queued {
            failHandler(command.handler, with: TmuxError.disconnected)
        }

        await emit(.exit(reason: reason))

        isShutdown = true
        if let delegate = delegate {
            await delegate.gatewayDidShutDown(self, reason: reason)
        }
    }

    private func emit(_ event: TmuxControllerEvent) async {
        if let delegate = delegate {
            await delegate.gateway(self, didReceive: event)
        }
    }

    // MARK: - Outgoing commands

    /// Send a single command. Awaits its `%begin/%end` round-trip and returns
    /// the response. Throws `.disconnected` if the gateway has shut down or
    /// `.commandFailed` if tmux replied with `%error`.
    func sendCommand(_ command: String) async throws -> TmuxCommandResponse {
        if isShutdown { throw TmuxError.disconnected }
        let payload = Data((command + "\n").utf8)
        let timestamp = Date()

        return try await withCheckedThrowingContinuation { continuation in
            // Reserve the response handler synchronously within the actor
            // before we issue the write — this guarantees that any %begin/%end
            // arriving via feedLine while the write is in flight will find a
            // matching pending entry to resolve.
            pendingCommands.append(
                PendingCommand(
                    command: command,
                    timestamp: timestamp,
                    handler: .continuation(continuation)
                )
            )

            // Kick off the write. We don't await inline because the closure
            // is non-async; writer errors hop back onto the actor via
            // failPending and resolve the continuation we just enqueued.
            Task { @Sendable [writer, weak self] in
                do {
                    try await writer(payload)
                } catch {
                    // Convert the (potentially non-Sendable) error to a
                    // sendable string so it can cross the actor hop.
                    let message = "\(error)"
                    await self?.failPending(matching: timestamp, command: command, message: message)
                }
            }
        }
    }

    /// Encode keystrokes for a pane and write them via `send-keys`. Errors
    /// propagate from the writer; per-command response errors are swallowed
    /// (fire-and-forget — `send-keys` produces empty `%begin/%end` responses
    /// the caller doesn't care about). Responses ARE consumed by the queue
    /// so subsequent commands stay correlated.
    func sendKeysToPane(_ paneID: TmuxPaneID, data: Data, version: TmuxVersion) async throws {
        if isShutdown { throw TmuxError.disconnected }
        let commands = TmuxKeyEncoder.encode(data: data, to: paneID, version: version)
        guard !commands.isEmpty else { return }

        let payload = Data((commands.joined(separator: "\n") + "\n").utf8)

        // Reserve a discarding handler for each command so the FIFO stays in
        // lockstep with the wire.
        let baseTimestamp = Date()
        var stamps: [Date] = []
        stamps.reserveCapacity(commands.count)
        for (offset, command) in commands.enumerated() {
            // Use `addingTimeInterval` to make timestamps unique within a batch.
            let stamp = baseTimestamp.addingTimeInterval(Double(offset) * 1e-9)
            stamps.append(stamp)
            pendingCommands.append(
                PendingCommand(command: command, timestamp: stamp, handler: .discard)
            )
        }

        do {
            try await writer(payload)
        } catch {
            // Drain the discarding entries we just reserved — the bytes never
            // hit the wire so there will be no response. Match by (stamp,
            // command) so we don't accidentally drain unrelated commands that
            // were enqueued by other callers while we were suspended.
            failBatchPending(stamps: stamps, commands: commands, message: "\(error)")
            throw error
        }
    }

    /// Request a clean detach. Sends literal `detach` and stops accepting commands.
    func detach() async throws {
        guard !isShutdown else { return }
        try await writer(Data("detach\n".utf8))
        isShutdown = true
        // Drain in-flight + queued with disconnected — tmux won't respond.
        if let active = activeResponse {
            activeResponse = nil
            if let handler = active.handler {
                failHandler(handler, with: TmuxError.disconnected)
            }
        }
        let queued = pendingCommands
        pendingCommands.removeAll()
        for command in queued {
            failHandler(command.handler, with: TmuxError.disconnected)
        }
    }

    /// Force shutdown — resolves all pending commands with `.disconnected`,
    /// drops state, and notifies the delegate.
    func shutdown(reason: String?) async {
        guard !isShutdown else { return }
        isShutdown = true

        if let active = activeResponse {
            activeResponse = nil
            if let handler = active.handler {
                failHandler(handler, with: TmuxError.disconnected)
            }
        }
        let queued = pendingCommands
        pendingCommands.removeAll()
        for command in queued {
            failHandler(command.handler, with: TmuxError.disconnected)
        }

        if let delegate = delegate {
            await delegate.gatewayDidShutDown(self, reason: reason)
        }
    }

    // MARK: - Internal helpers

    /// Find a pending command in the queue matching `(timestamp, command)`,
    /// remove it, and resolve its handler with a writer-failure error. Used
    /// when the writer fails before bytes reach tmux for a single
    /// sendCommand.
    private func failPending(matching timestamp: Date, command: String, message: String) {
        let error = TmuxError.commandFailed(message: "writer failed: \(message)")
        for index in pendingCommands.indices {
            let candidate = pendingCommands[index]
            if candidate.timestamp == timestamp && candidate.command == command {
                pendingCommands.remove(at: index)
                logger.error("writer failed for command: \(candidate.command, privacy: .public)")
                failHandler(candidate.handler, with: error)
                return
            }
        }
    }

    /// Same as `failPending` but for a sendKeysToPane batch.
    private func failBatchPending(stamps: [Date], commands: [String], message: String) {
        let error = TmuxError.commandFailed(message: "writer failed: \(message)")
        // Walk the queue and remove any entries whose (timestamp, command)
        // pair appears in our stamps list. Only remove the first match per
        // pair so we don't accidentally delete unrelated future commands.
        var pairs = Set<String>()
        for (i, command) in commands.enumerated() {
            pairs.insert("\(stamps[i].timeIntervalSince1970)|\(command)")
        }
        var i = 0
        while i < pendingCommands.count {
            let candidate = pendingCommands[i]
            let key = "\(candidate.timestamp.timeIntervalSince1970)|\(candidate.command)"
            if pairs.contains(key) {
                pairs.remove(key)
                pendingCommands.remove(at: i)
                failHandler(candidate.handler, with: error)
            } else {
                i += 1
            }
        }
    }

}
