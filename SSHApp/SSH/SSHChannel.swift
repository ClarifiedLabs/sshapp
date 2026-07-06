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
    let id = UUID()

    private let transport: SSH2Transport
    private weak var owner: SSHSession?
    private var transportChannelID: SSHTransportChannelID?

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

    var onDataReceived: (@MainActor (Data) -> Void)?
    var onRemoteDisconnected: (@MainActor (SSHChannelRemoteCloseReason) -> Void)?

    init(transport: SSH2Transport, owner: SSHSession, tmuxSettings: TmuxSettings) {
        self.transport = transport
        self.owner = owner
        self.tmuxSettings = tmuxSettings
    }

    func openShell(termType: String = "xterm-256color", cols: Int = 80, rows: Int = 24) async throws {
        guard transportChannelID == nil else { return }

        terminalCols = cols
        terminalRows = rows

        let id = try await transport.openShellChannel(
            term: termType,
            cols: cols,
            rows: rows,
            onDataReceived: { [weak self] data in
                self?.processIncomingBytes(data)
            },
            onClosed: { [weak self] reason in
                self?.handleTransportClosed(reason: reason)
            }
        )
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
        transportChannelID = nil
        isOpen = false
        endTmuxControlMode()
        tmuxLineDecoder.reset()
        tmuxLineDeliveryTask?.cancel()
        tmuxLineDeliveryTask = nil
        owner?.channelDidClose(self)

        if let channelID {
            transport.closeChannel(channelID)
        }
    }

    func markClosedBySessionDisconnect() {
        transportChannelID = nil
        isOpen = false
        endTmuxControlMode()
        tmuxLineDecoder.reset()
        tmuxLineDeliveryTask?.cancel()
        tmuxLineDeliveryTask = nil
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
                    onDataReceived?(bytes)
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

    private func handleTransportClosed(reason: SSHTransportChannelCloseReason) {
        guard isOpen || transportChannelID != nil else { return }

        channelLogger.info("SSH channel closed by remote")
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
