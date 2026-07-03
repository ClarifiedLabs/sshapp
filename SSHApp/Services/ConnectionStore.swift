import Foundation
import SwiftData
import os

private let connectionStoreLogger = Logger(subsystem: "dev.sshapp.sshapp", category: "ConnectionStore")

/// Service for managing saved SSH connections
@Observable
final class ConnectionStore {
    private var modelContext: ModelContext?
    private let syncStore: ConnectionSyncStore

    init(syncStore: ConnectionSyncStore = .shared) {
        self.syncStore = syncStore
    }

    /// Set the model context (called from view layer)
    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
        syncStore.setModelContext(context)
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
        connection.updatedAt = Date()
        modelContext.insert(connection)
        try? modelContext.save()
        syncStore.save(connection)
    }

    /// Delete a connection
    func delete(_ connection: SavedConnection) {
        guard let modelContext else { return }
        syncStore.delete(connection)
        KeychainService.deletePassword(forConnectionId: connection.id)
        modelContext.delete(connection)
        try? modelContext.save()
    }

    /// Persist edits to existing connections.
    func saveChanges(touching connection: SavedConnection? = nil) {
        if let connection {
            connection.updatedAt = Date()
        }
        try? modelContext?.save()
        if let connection {
            syncStore.save(connection)
        }
    }

    /// Update last connected timestamp
    func updateLastConnected(_ connection: SavedConnection) {
        connection.lastConnected = Date()
        connection.updatedAt = Date()
        try? modelContext?.save()
        syncStore.save(connection)
    }
}
