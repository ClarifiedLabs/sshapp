import Foundation
import os

private let channelLogger = Logger(subsystem: "dev.sshapp.sshapp", category: "SSHChannel")
private let tmuxAttachFallbackDelayNanos: UInt64 = 250_000_000

enum SSHChannelRemoteCloseReason: Sendable, Equatable {
    case orderlyExit
    case transportFailure
}

@MainActor
@Observable
final class SSHChannel {
    struct TerminalOutputReceiverToken: Hashable {
        fileprivate let id = UUID()
    }

    let id = UUID()

    private let transport: any SSHChannelTransport
    private weak var owner: SSHSession?
    private var transportChannelID: SSHTransportChannelID?
    private var openingGeneration: UUID?
    private var activeGeneration: UUID?
    private var pendingOpeningClose: (generation: UUID, reason: SSHTransportChannelCloseReason)?
    private var openWasCancelled = false

    private(set) var isOpen = false
    private(set) var terminalCols: Int = 80
    private(set) var terminalRows: Int = 24
    var terminalGridSize: TerminalGridSize {
        TerminalGridSize(cols: terminalCols, rows: terminalRows) ?? .fallback
    }

    /// Current input routing mode for this shell channel.
    private(set) var inputMode: InputMode = .normal

    private var tmuxLineDecoder = TmuxLineDecoder()
    private(set) var tmuxGateway: TmuxGateway?
    private(set) var tmuxController: TmuxController?
    private var tmuxRetainedController: TmuxController?
    private var tmuxGatewaySetupTask: Task<Void, Never>?
    private var tmuxAttachTask: Task<Void, Never>?
    private var tmuxAttachFallbackTask: Task<Void, Never>?
    private var tmuxLineDeliveryTask: Task<Void, Never>?
    var tmuxSettings: TmuxSettings

    private let terminalOutputDelivery: TerminalOutputDeliveryQueue
    private var terminalOutputReceiverToken: TerminalOutputReceiverToken?
    var onRemoteDisconnected: (@MainActor (SSHChannelRemoteCloseReason) -> Void)?

    init(
        transport: any SSHChannelTransport,
        owner: SSHSession,
        tmuxSettings: TmuxSettings,
        terminalOutputDelivery: TerminalOutputDeliveryQueue? = nil
    ) {
        self.transport = transport
        self.owner = owner
        self.tmuxSettings = tmuxSettings
        self.terminalOutputDelivery = terminalOutputDelivery
            ?? TerminalOutputDeliveryQueue(
                label: "dev.sshapp.sshapp.channel-terminal-output"
            )
    }

    func openShell(termType: String = "xterm-256color", cols: Int = 80, rows: Int = 24) async throws {
        guard transportChannelID == nil else { return }
        guard !openWasCancelled else { throw CancellationError() }
        guard openingGeneration == nil else { throw SSHError.alreadyConnected }

        let generation = UUID()
        openingGeneration = generation
        terminalCols = cols
        terminalRows = rows

        let id: SSHTransportChannelID
        do {
            id = try await transport.openShellChannel(
                term: termType,
                cols: cols,
                rows: rows,
                onDataReceived: { [weak self] data in
                    self?.handleTransportData(data, generation: generation)
                },
                onClosed: { [weak self] reason in
                    self?.handleTransportClosed(reason: reason, generation: generation)
                }
            )
        } catch {
            if let pendingOpeningClose,
               pendingOpeningClose.generation == generation {
                finishTransportClosed(reason: pendingOpeningClose.reason)
                throw CancellationError()
            }
            guard openingGeneration == generation, !openWasCancelled else {
                throw CancellationError()
            }
            openingGeneration = nil
            throw error
        }

        guard openingGeneration == generation, !openWasCancelled else {
            transport.closeChannel(id)
            throw CancellationError()
        }
        if let pendingOpeningClose,
           pendingOpeningClose.generation == generation {
            transport.closeChannel(id)
            finishTransportClosed(reason: pendingOpeningClose.reason)
            throw CancellationError()
        }
        openingGeneration = nil
        activeGeneration = generation
        transportChannelID = id
        isOpen = true
    }

    func write(_ data: Data) async throws {
        guard let transportChannelID, isOpen else {
            throw SSHError.shellNotOpen
        }
        transport.write(data, to: transportChannelID)
    }

    func writeTerminalCommand(_ command: String) async throws {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var normalized = command
            .replacingOccurrences(of: "\r\n", with: "\r")
            .replacingOccurrences(of: "\n", with: "\r")
        if !normalized.hasSuffix("\r") {
            normalized.append("\r")
        }
        guard let data = normalized.data(using: .utf8) else { return }
        try await write(data)
    }

    func resizeTerminal(cols: Int, rows: Int) {
        terminalCols = cols
        terminalRows = rows
        if let transportChannelID {
            transport.resizePTY(channel: transportChannelID, cols: cols, rows: rows)
        }
        tmuxController?.refreshClient(cols: cols, rows: rows)
    }

    func close() {
        let channelID = transportChannelID
        openingGeneration = nil
        activeGeneration = nil
        pendingOpeningClose = nil
        openWasCancelled = true
        transportChannelID = nil
        isOpen = false
        endTmuxControlMode()
        tmuxLineDecoder.reset()
        tmuxLineDeliveryTask?.cancel()
        tmuxLineDeliveryTask = nil
        owner?.channelDidClose(self)

        // Cancel an in-flight native setup even though there is no channel ID
        // yet; the late-success close below remains as the race fallback.
        transport.cancelOpeningShellChannel()
        if let channelID {
            transport.closeChannel(channelID)
        }
    }

    func markClosedBySessionDisconnect() {
        openingGeneration = nil
        activeGeneration = nil
        pendingOpeningClose = nil
        openWasCancelled = true
        transportChannelID = nil
        isOpen = false
        endTmuxControlMode()
        tmuxLineDecoder.reset()
        tmuxLineDeliveryTask?.cancel()
        tmuxLineDeliveryTask = nil
    }

    // MARK: - Terminal output

    @discardableResult
    func registerTerminalOutputReceiver(
        _ receiver: any TerminalOutputReceiver
    ) -> TerminalOutputReceiverToken {
        let token = TerminalOutputReceiverToken()
        terminalOutputReceiverToken = token
        terminalOutputDelivery.setReady(false)
        terminalOutputDelivery.setReceiverPreservingPendingOutput(receiver)
        return token
    }

    func setTerminalOutputReady(
        _ ready: Bool,
        token: TerminalOutputReceiverToken,
        onFirstDrain completion: (@Sendable () -> Void)? = nil
    ) {
        guard terminalOutputReceiverToken == token else { return }
        terminalOutputDelivery.setReady(ready, onFirstDrain: completion)
    }

    func unregisterTerminalOutputReceiver(_ token: TerminalOutputReceiverToken) {
        guard terminalOutputReceiverToken == token else { return }
        terminalOutputReceiverToken = nil
        terminalOutputDelivery.setReady(false)
        terminalOutputDelivery.setReceiverPreservingPendingOutput(nil)
    }

    func deliverTerminalOutput(_ data: Data) {
        terminalOutputDelivery.enqueue(data)
    }

    // MARK: - tmux byte demux

    private func processIncomingBytes(_ data: Data) {
        let events = tmuxLineDecoder.feedEvents(data)

        for event in events {
            switch event {
            case .controlModeStarted:
                startTmuxControlMode()

            case .output(let output):
                switch output {
                case .passthrough(let bytes):
                    deliverTerminalOutput(bytes)
                case .line(let lineBytes):
                    if let gateway = tmuxGateway {
                        enqueueTmuxLine(lineBytes, gateway: gateway, setupTask: tmuxGatewaySetupTask)
                        startTmuxAttachBootstrapIfReady(for: lineBytes)
                    } else {
                        channelLogger.warning("tmux line received with no gateway: \(lineBytes.count)B")
                    }
                }

            case .controlModeEnded:
                finishDecodedTmuxControlMode()
            }
        }
    }

    private func enqueueTmuxLine(
        _ lineBytes: Data,
        gateway: TmuxGateway,
        setupTask: Task<Void, Never>?
    ) {
        let previous = tmuxLineDeliveryTask
        tmuxLineDeliveryTask = Task { [previous, setupTask, gateway, lineBytes] in
            await setupTask?.value
            await previous?.value
            guard !Task.isCancelled else { return }
            await gateway.feedLine(lineBytes)
        }
    }

    private func startTmuxControlMode() {
        guard tmuxController == nil else { return }
        channelLogger.info("DCS detected — entering tmux control mode")

        let gateway = TmuxGateway(writer: { [weak self] data in
            guard let self else { return }
            try await self.write(data)
        })
        let controller = TmuxController(gateway: gateway, settings: tmuxSettings)

        tmuxGateway = gateway
        tmuxController = controller
        tmuxRetainedController = controller
        inputMode = .tmuxControlMode

        tmuxGatewaySetupTask?.cancel()
        tmuxGatewaySetupTask = Task {
            await gateway.setDelegate(controller)
        }
    }

    private func startTmuxAttachBootstrapIfReady(for lineBytes: Data) {
        guard tmuxAttachTask == nil else { return }
        if case .sessionChanged = TmuxLineParser.parseLine(lineBytes) {
            startTmuxAttachBootstrap()
            return
        }
        scheduleTmuxAttachBootstrapFallbackIfNeeded()
    }

    private func scheduleTmuxAttachBootstrapFallbackIfNeeded() {
        guard tmuxAttachTask == nil, tmuxAttachFallbackTask == nil else {
            return
        }
        tmuxAttachFallbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: tmuxAttachFallbackDelayNanos)
            guard !Task.isCancelled else { return }
            self?.tmuxAttachFallbackTask = nil
            self?.startTmuxAttachBootstrap()
        }
    }

    private func startTmuxAttachBootstrap() {
        guard tmuxGateway != nil,
              let controller = tmuxController,
              tmuxAttachTask == nil
        else {
            return
        }

        tmuxAttachFallbackTask?.cancel()
        tmuxAttachFallbackTask = nil

        let cols = terminalCols
        let rows = terminalRows
        let setupTask = tmuxGatewaySetupTask
        tmuxAttachTask = Task {
            await setupTask?.value
            guard !Task.isCancelled else { return }
            await controller.attach(initialCols: cols, initialRows: rows)
        }
    }

    private func finishDecodedTmuxControlMode() {
        let deliveryTask = tmuxLineDeliveryTask
        _ = clearTmuxControlModeReferences()
        releaseRetainedTmuxController(after: deliveryTask)
    }

    private func endTmuxControlMode() {
        let deliveryTask = tmuxLineDeliveryTask
        let gateway = clearTmuxControlModeReferences()
        guard let gateway else {
            releaseRetainedTmuxController(after: deliveryTask)
            return
        }

        let retainedController = tmuxRetainedController
        Task { [weak self, deliveryTask, gateway, retainedController] in
            await deliveryTask?.value
            await gateway.shutdown(reason: "DCS unhooked")
            await MainActor.run {
                guard let self else { return }
                if self.tmuxRetainedController === retainedController {
                    self.tmuxRetainedController = nil
                }
            }
        }
    }

    @discardableResult
    private func clearTmuxControlModeReferences() -> TmuxGateway? {
        guard tmuxGateway != nil || tmuxController != nil || inputMode == .tmuxControlMode else {
            return nil
        }
        channelLogger.info("tmux control mode ended")
        let gateway = tmuxGateway
        tmuxGatewaySetupTask?.cancel()
        tmuxGatewaySetupTask = nil
        tmuxAttachTask?.cancel()
        tmuxAttachTask = nil
        tmuxAttachFallbackTask?.cancel()
        tmuxAttachFallbackTask = nil
        tmuxGateway = nil
        tmuxController = nil
        if inputMode == .tmuxControlMode {
            inputMode = .normal
        }
        return gateway
    }

    private func releaseRetainedTmuxController(after task: Task<Void, Never>?) {
        let retainedController = tmuxRetainedController
        guard retainedController != nil else { return }
        Task { [weak self, task, retainedController] in
            await task?.value
            await MainActor.run {
                guard let self else { return }
                if self.tmuxRetainedController === retainedController {
                    self.tmuxRetainedController = nil
                }
            }
        }
    }

    private func handleTransportData(_ data: Data, generation: UUID) {
        guard pendingOpeningClose?.generation != generation else { return }
        guard openingGeneration == generation || activeGeneration == generation else { return }
        processIncomingBytes(data)
    }

    private func handleTransportClosed(
        reason: SSHTransportChannelCloseReason,
        generation: UUID
    ) {
        if openingGeneration == generation, transportChannelID == nil {
            pendingOpeningClose = (generation, reason)
            return
        }
        guard activeGeneration == generation else { return }
        finishTransportClosed(reason: reason)
    }

    private func finishTransportClosed(reason: SSHTransportChannelCloseReason) {
        channelLogger.info("SSH channel closed by remote")
        openingGeneration = nil
        activeGeneration = nil
        pendingOpeningClose = nil
        openWasCancelled = true
        transportChannelID = nil
        isOpen = false
        endTmuxControlMode()
        tmuxLineDecoder.reset()
        owner?.channelDidClose(self)

        switch reason {
        case .local:
            break
        case .remoteProcessExited:
            onRemoteDisconnected?(.orderlyExit)
        case .transportFailure:
            onRemoteDisconnected?(.transportFailure)
        }
    }
}

protocol SSHChannelTransport: Sendable {
    func openShellChannel(
        term: String,
        cols: Int,
        rows: Int,
        onDataReceived: @escaping @MainActor @Sendable (Data) -> Void,
        onClosed: @escaping @MainActor @Sendable (SSHTransportChannelCloseReason) -> Void
    ) async throws -> SSHTransportChannelID
    func write(_ data: Data, to id: SSHTransportChannelID)
    func resizePTY(channel id: SSHTransportChannelID, cols: Int, rows: Int)
    func closeChannel(_ id: SSHTransportChannelID)
    /// Aborts any in-flight shell channel setup (open/PTY/startup retry loops)
    /// so a locally closed tab does not keep libssh2 setup alive. Setups that
    /// begin after the cancellation are unaffected.
    func cancelOpeningShellChannel()
}

extension SSH2Transport: SSHChannelTransport {}
