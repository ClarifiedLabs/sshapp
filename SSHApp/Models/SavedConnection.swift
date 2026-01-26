import Foundation
import SwiftData

/// Represents a saved SSH connection configuration
@Model
final class SavedConnection {
    var id: UUID
    var host: String
    var port: Int
    var username: String?
    /// Optional reference to a stored SSH key. If nil, go straight to terminal password prompt.
    /// If set, try key auth first, then fall back to password.
    var sshKeyId: UUID?
    var lastConnected: Date?
    var createdAt: Date
    /// User chose "Don't Ask Again" on the save-username prompt.
    var neverAskSaveUsername: Bool = false
    /// User chose "Don't Ask Again" on the save-password prompt.
    var neverAskSavePassword: Bool = false

    // MARK: - tmux per-host overrides (nil = inherit global)

    /// Override for `AppSettings.tmuxBackfillEnabled`. nil inherits.
    var tmuxBackfillOverride: Bool?
    /// Override for `AppSettings.tmuxPauseModeEnabled`. nil inherits.
    var tmuxPauseModeOverride: Bool?

    init(
        id: UUID = UUID(),
        host: String,
        port: Int = 22,
        username: String? = nil,
        sshKeyId: UUID? = nil,
        lastConnected: Date? = nil,
        createdAt: Date = Date(),
        neverAskSaveUsername: Bool = false,
        neverAskSavePassword: Bool = false,
        tmuxBackfillOverride: Bool? = nil,
        tmuxPauseModeOverride: Bool? = nil
    ) {
        self.id = id
        self.host = host
        self.port = port
        self.username = username
        self.sshKeyId = sshKeyId
        self.lastConnected = lastConnected
        self.createdAt = createdAt
        self.neverAskSaveUsername = neverAskSaveUsername
        self.neverAskSavePassword = neverAskSavePassword
        self.tmuxBackfillOverride = tmuxBackfillOverride
        self.tmuxPauseModeOverride = tmuxPauseModeOverride
    }

    var destinationFieldValue: String {
        ConnectionDestination(username: username, host: host).fieldValue
    }

    var displayDestination: String {
        ConnectionDestination.display(username: username, host: host, port: port)
    }
}

struct ConnectionDestination: Equatable {
    let username: String?
    let host: String

    init(username: String?, host: String) {
        let trimmedUsername = username?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.username = trimmedUsername?.isEmpty == false ? trimmedUsername : nil
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var fieldValue: String {
        guard let username else {
            return host
        }
        return "\(username)@\(host)"
    }

    static func parse(_ value: String) -> ConnectionDestination? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let parts = trimmed.split(separator: "@", omittingEmptySubsequences: false)
        switch parts.count {
        case 1:
            let host = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty else {
                return nil
            }
            return ConnectionDestination(username: nil, host: host)
        case 2:
            let username = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let host = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !username.isEmpty, !host.isEmpty else {
                return nil
            }
            return ConnectionDestination(username: username, host: host)
        default:
            return nil
        }
    }

    static func display(username: String?, host: String, port: Int) -> String {
        var label = ConnectionDestination(username: username, host: host).fieldValue
        if port != 22 {
            label += ":\(port)"
        }
        return label
    }
}
