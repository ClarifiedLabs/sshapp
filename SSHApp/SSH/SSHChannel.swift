import Foundation
import os

private let channelLogger = Logger(subsystem: "dev.sshapp.sshapp", category: "SSHChannel")

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

    /// Current input routing mode for this shell channel.
    private(set) var inputMode: InputMode = .normal

    private var tmuxLineDecoder = TmuxLineDecoder()
    private(set) var tmuxGateway: TmuxGateway?
    private(set) var tmuxController: TmuxController?
    private var tmuxLineDeliveryTask: Task<Void, Never>?
    var tmuxSettings: TmuxSettings

    var onDataReceived: (@MainActor (Data) -> Void)?
    var onRemoteDisconnected: (@MainActor () -> Void)?

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
            onClosed: { [weak self] in
                self?.handleTransportClosed()
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
        let wasHooked = tmuxLineDecoder.isHooked
        let outputs = tmuxLineDecoder.feed(data)
        let nowHooked = tmuxLineDecoder.isHooked

        if !wasHooked && nowHooked {
            startTmuxControlMode()
        }

        for output in outputs {
            switch output {
            case .passthrough(let bytes):
                onDataReceived?(bytes)
            case .line(let lineBytes):
                if let gateway = tmuxGateway {
                    enqueueTmuxLine(lineBytes, gateway: gateway)
                } else {
                    channelLogger.warning("tmux line received with no gateway: \(lineBytes.count)B")
                }
            }
        }

        if wasHooked && !nowHooked {
            enqueueTmuxControlModeEnd()
        }
    }

    private func enqueueTmuxLine(_ lineBytes: Data, gateway: TmuxGateway) {
        let previous = tmuxLineDeliveryTask
        tmuxLineDeliveryTask = Task { [previous, gateway, lineBytes] in
            await previous?.value
            guard !Task.isCancelled else { return }
            await gateway.feedLine(lineBytes)
        }
    }

    private func enqueueTmuxControlModeEnd() {
        let previous = tmuxLineDeliveryTask
        tmuxLineDeliveryTask = Task { [weak self, previous] in
            await previous?.value
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.endTmuxControlMode()
            }
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
        inputMode = .tmuxControlMode

        let cols = terminalCols
        let rows = terminalRows
        Task {
            await gateway.setDelegate(controller)
            await controller.attach(initialCols: cols, initialRows: rows)
        }
    }

    private func endTmuxControlMode() {
        guard tmuxGateway != nil || tmuxController != nil || inputMode == .tmuxControlMode else {
            return
        }
        channelLogger.info("tmux control mode ended")
        let gateway = tmuxGateway
        tmuxGateway = nil
        tmuxController = nil
        if inputMode == .tmuxControlMode {
            inputMode = .normal
        }
        if let gateway {
            Task { await gateway.shutdown(reason: "DCS unhooked") }
        }
    }

    private func handleTransportClosed() {
        guard isOpen || transportChannelID != nil else { return }

        channelLogger.info("SSH channel closed by remote")
        transportChannelID = nil
        isOpen = false
        endTmuxControlMode()
        tmuxLineDecoder.reset()
        owner?.channelDidClose(self)
        onRemoteDisconnected?()
    }
}
