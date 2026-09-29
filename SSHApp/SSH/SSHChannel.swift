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
    private weak var persistentOutputReceiver: (any TerminalOutputReceiver)?
    private var persistentOutputReady = false
    /// Latest flow-control decision from `terminalOutputDelivery`. Replayed to
    /// the transport once the channel ID exists.
    private(set) var isTransportReadPaused = false
    var onRemoteDisconnected: (@MainActor (SSHChannelRemoteCloseReason) -> Void)?
    /// Model-owned retirement callback, independent of the current UIKit host.
    @ObservationIgnored var onTerminalClosed: (@MainActor () -> Void)?

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
        // Live shell output is bounded by pausing channel reads, never by
        // trimming bytes that a visible VT engine is parsing. Unread data stays
        // in libssh2 and the remote stalls once its channel window is spent.
        self.terminalOutputDelivery.setFlowControlHandler { [weak self] paused in
            self?.setTransportReadPaused(paused)
        }
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
        if isTransportReadPaused {
            transport.setReadPaused(true, channel: id)
        }
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
        onTerminalClosed?()
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
        onTerminalClosed?()
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
        if persistentOutputReceiver !== receiver {
            persistentOutputReady = false
            terminalOutputDelivery.setReady(false)
        }
        persistentOutputReceiver = receiver.preservesStateAcrossReadinessChanges ? receiver : nil
        terminalOutputDelivery.setReceiverPreservingPendingOutput(receiver)
        return token
    }

    func setTerminalOutputReady(
        _ ready: Bool,
        token: TerminalOutputReceiverToken,
        onFirstDrain completion: (@Sendable () -> Void)? = nil,
        onDrain: (@Sendable () -> Void)? = nil
    ) {
        guard terminalOutputReceiverToken == token else { return }
        if persistentOutputReceiver != nil {
            guard ready || !persistentOutputReady else { return }
            if ready { persistentOutputReady = true }
        }
        terminalOutputDelivery.setReady(ready, onFirstDrain: completion)
        if ready, let onDrain {
            terminalOutputDelivery.notifyWhenDrained(onDrain)
        }
    }

    func unregisterTerminalOutputReceiver(_ token: TerminalOutputReceiverToken) {
        guard terminalOutputReceiverToken == token else { return }
        terminalOutputReceiverToken = nil
        // The token owns only host callbacks. Keep the model-owned VT receiver
        // bound even while a committed ingest is completing its event fan-out.
        guard persistentOutputReceiver == nil else { return }
        terminalOutputDelivery.setReady(false)
        terminalOutputDelivery.setReceiverPreservingPendingOutput(nil)
    }

    /// The model-owned engine retired (logical close). Its unread output can
    /// never be shown: drop it and release backpressure rather than retrying
    /// a finished engine. A replacement engine registers afresh.
    func retireTerminalOutputReceiver(_ receiver: any TerminalOutputReceiver) {
        guard persistentOutputReceiver === receiver else { return }
        persistentOutputReceiver = nil
        persistentOutputReady = false
        terminalOutputReceiverToken = nil
        terminalOutputDelivery.setReady(false)
        terminalOutputDelivery.resetPendingOutput()
        terminalOutputDelivery.setReceiver(nil)
    }

    func deliverTerminalOutput(_ data: Data) {
        terminalOutputDelivery.enqueue(data)
    }

    private func setTransportReadPaused(_ paused: Bool) {
        guard isTransportReadPaused != paused else { return }
        isTransportReadPaused = paused
        if let transportChannelID {
            transport.setReadPaused(paused, channel: transportChannelID)
        }
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
        onTerminalClosed?()
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
    /// Output backpressure. While paused the transport stops consuming this
    /// channel's data (so the SSH window, not app memory, bounds the remote);
    /// writes, resizes and other channels are unaffected. Calls apply in order.
    func setReadPaused(_ paused: Bool, channel id: SSHTransportChannelID)
    func closeChannel(_ id: SSHTransportChannelID)
    /// Aborts any in-flight shell channel setup (open/PTY/startup retry loops)
    /// so a locally closed tab does not keep libssh2 setup alive. Setups that
    /// begin after the cancellation are unaffected.
    func cancelOpeningShellChannel()
}

extension SSH2Transport: SSHChannelTransport {}
