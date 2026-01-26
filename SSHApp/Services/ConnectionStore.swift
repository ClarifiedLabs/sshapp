import Foundation
import SwiftData
import os

private let connectionStoreLogger = Logger(subsystem: "dev.sshapp.sshapp", category: "ConnectionStore")

/// Service for managing saved SSH connections
@Observable
final class ConnectionStore {
    private var modelContext: ModelContext?

    init() {}

    /// Set the model context (called from view layer)
    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
    }

    /// Fetch all saved connections
    func fetchAll() -> [SavedConnection] {
        guard let modelContext else { return [] }

        let descriptor = FetchDescriptor<SavedConnection>(
            sortBy: [
                SortDescriptor(\.lastConnected, order: .reverse),
                SortDescriptor(\.createdAt, order: .reverse)
            ]
        )

        do {
            return try modelContext.fetch(descriptor)
        } catch {
            connectionStoreLogger.error("Failed to fetch connections: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Save a new connection
    func save(_ connection: SavedConnection) {
        guard let modelContext else { return }
        modelContext.insert(connection)
        try? modelContext.save()
    }

    /// Delete a connection
    func delete(_ connection: SavedConnection) {
        guard let modelContext else { return }
        KeychainService.deletePassword(forConnectionId: connection.id)
        modelContext.delete(connection)
        try? modelContext.save()
    }

    /// Persist edits to existing connections.
    func saveChanges() {
        try? modelContext?.save()
    }

    /// Update last connected timestamp
    func updateLastConnected(_ connection: SavedConnection) {
        connection.lastConnected = Date()
        try? modelContext?.save()
    }
}
