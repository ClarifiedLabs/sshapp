import Foundation

/// Represents a terminal tab's state
@MainActor
@Observable
final class Tab: Identifiable {
    let id: UUID
    var title: String
    var connectionState: ConnectionState
    var session: SSHSession?
    var channel: SSHChannel?
    var connection: SavedConnection?

    /// Convenience: the tmux controller, if tmux -CC mode is active on this tab.
    /// Reaches through `channel?.tmuxController`. Nil for non-tmux tabs.
    var tmuxController: TmuxController? {
        channel?.tmuxController
    }

    init(
        id: UUID = UUID(),
        title: String = "New Tab",
        connectionState: ConnectionState = .disconnected,
        session: SSHSession? = nil,
        channel: SSHChannel? = nil,
        connection: SavedConnection? = nil
    ) {
        self.id = id
        self.title = title
        self.connectionState = connectionState
        self.session = session
        self.channel = channel
        self.connection = connection
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
