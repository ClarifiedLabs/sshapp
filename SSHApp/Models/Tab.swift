import Foundation

struct TerminalGridSize: Equatable, Sendable {
    static let fallback = TerminalGridSize(cols: 80, rows: 24)!

    let cols: Int
    let rows: Int

    init?(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return nil }
        self.cols = cols
        self.rows = rows
    }
}

/// Represents a terminal tab's state
@MainActor
@Observable
final class Tab: Identifiable {
    let id: UUID
    var title: String
    /// Whether the remote terminal owns this tab's title (OSC 0/2). While
    /// false, the title mirrors the connection's display name so renames are
    /// reflected; once the terminal sets a window title it takes ownership.
    var isTitleOwnedByTerminal: Bool = false
    var connectionState: ConnectionState
    var session: SSHSession?
    var channel: SSHChannel?
    var connection: SavedConnection?
    var pendingAutoRunCommand: String?
    var terminalGridSize: TerminalGridSize?
    @ObservationIgnored var connectionTask: Task<Void, Never>?

    /// Convenience: the tmux controller, if tmux -CC mode is active on this tab.
    /// Reaches through `channel?.tmuxController`. Nil for non-tmux tabs.
    var tmuxController: TmuxController? {
        channel?.tmuxController
    }

    /// Stable connection label for surfaces that identify the SSH connection
    /// rather than the terminal's current window title.
    var connectionDisplayTitle: String {
        connection?.displayName ?? title
    }

    /// Refreshes the tab title from its connection's display name unless the
    /// remote terminal has claimed title ownership with a window title.
    func refreshConnectionTitle() {
        guard !isTitleOwnedByTerminal, let connection else { return }
        title = connection.displayName
    }

    var currentTerminalGridSize: TerminalGridSize? {
        terminalGridSize ?? channel?.terminalGridSize
    }

    init(
        id: UUID = UUID(),
        title: String = "New Tab",
        connectionState: ConnectionState = .disconnected,
        session: SSHSession? = nil,
        channel: SSHChannel? = nil,
        connection: SavedConnection? = nil,
        pendingAutoRunCommand: String? = nil,
        terminalGridSize: TerminalGridSize? = nil
    ) {
        self.id = id
        self.title = title
        self.isTitleOwnedByTerminal = false
        self.connectionState = connectionState
        self.session = session
        self.channel = channel
        self.connection = connection
        self.pendingAutoRunCommand = pendingAutoRunCommand
        self.terminalGridSize = terminalGridSize
    }

    func consumePendingAutoRunCommand() -> String? {
        defer { pendingAutoRunCommand = nil }
        return pendingAutoRunCommand
    }
}

/// State of an SSH connection
enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case awaitingInput
    case connected
    case failed(String)
}
