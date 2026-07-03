import Foundation
import SwiftData

final class ConnectionSyncStore: @unchecked Sendable {
    static let shared = ConnectionSyncStore()

    private struct ConnectionSyncIndex: Codable {
        var ids: [UUID] = []
    }

    private struct SyncedConnectionRecord: Codable {
        let id: UUID
        let host: String
        let port: Int
        let username: String?
        let sshKeyId: UUID?
        let lastConnected: Date?
        let createdAt: Date
        let updatedAt: Date
        let neverAskSaveUsername: Bool
        let neverAskSavePassword: Bool
        let tmuxBackfillOverride: Bool?
        let tmuxPauseModeOverride: Bool?

        init(connection: SavedConnection) {
            self.id = connection.id
            self.host = connection.host
            self.port = connection.port
            self.username = connection.username
            self.sshKeyId = connection.sshKeyId
            self.lastConnected = connection.lastConnected
            self.createdAt = connection.createdAt
            self.updatedAt = connection.updatedAt
            self.neverAskSaveUsername = connection.neverAskSaveUsername
            self.neverAskSavePassword = connection.neverAskSavePassword
            self.tmuxBackfillOverride = connection.tmuxBackfillOverride
            self.tmuxPauseModeOverride = connection.tmuxPauseModeOverride
        }

        func makeConnection() -> SavedConnection {
            SavedConnection(
                id: id,
                host: host,
                port: port,
                username: username,
                sshKeyId: sshKeyId,
                lastConnected: lastConnected,
                createdAt: createdAt,
                updatedAt: updatedAt,
                neverAskSaveUsername: neverAskSaveUsername,
                neverAskSavePassword: neverAskSavePassword,
                tmuxBackfillOverride: tmuxBackfillOverride,
                tmuxPauseModeOverride: tmuxPauseModeOverride
            )
        }

        func apply(to connection: SavedConnection) {
            connection.host = host
            connection.port = port
            connection.username = username
            connection.sshKeyId = sshKeyId
            connection.lastConnected = lastConnected
            connection.createdAt = createdAt
            connection.updatedAt = updatedAt
            connection.neverAskSaveUsername = neverAskSaveUsername
            connection.neverAskSavePassword = neverAskSavePassword
            connection.tmuxBackfillOverride = tmuxBackfillOverride
            connection.tmuxPauseModeOverride = tmuxPauseModeOverride
        }
    }

    private struct SyncedConnectionTombstone: Codable {
        let id: UUID
        let deletedAt: Date
    }

    private static let defaultKeyPrefix = "dev.sshapp.sshapp.connections"

    private let ubiquitous: NSUbiquitousKeyValueStore
    private let keyPrefix: String
    private var modelContext: ModelContext?
    private var observerToken: NSObjectProtocol?
    private var isApplyingCloudChanges = false

    init(
        ubiquitous: NSUbiquitousKeyValueStore = .default,
        keyPrefix: String = ConnectionSyncStore.defaultKeyPrefix
    ) {
        self.ubiquitous = ubiquitous
        self.keyPrefix = keyPrefix
    }

    deinit {
        if let observerToken {
            NotificationCenter.default.removeObserver(observerToken)
        }
    }

    func setModelContext(_ context: ModelContext) {
        modelContext = context
        startObservingCloudChanges()
        synchronize()
    }

    func save(_ connection: SavedConnection) {
        guard !isApplyingCloudChanges else { return }
        writeRecord(SyncedConnectionRecord(connection: connection))
    }

    func delete(_ connection: SavedConnection, deletedAt: Date = Date()) {
        guard !isApplyingCloudChanges else { return }
        writeTombstone(SyncedConnectionTombstone(id: connection.id, deletedAt: deletedAt))
    }

    func synchronize() {
        ubiquitous.synchronize()
        importCloudChanges()
        exportLocalConnectionsMissingFromCloud()
    }

    static func clearSyncedValues(
        ubiquitous: NSUbiquitousKeyValueStore = .default,
        keyPrefix: String = defaultKeyPrefix
    ) {
        for key in ubiquitous.dictionaryRepresentation.keys where key.hasPrefix(keyPrefix) {
            ubiquitous.removeObject(forKey: key)
        }
    }

    private var indexKey: String {
        "\(keyPrefix).index"
    }

    private func recordKey(for id: UUID) -> String {
        "\(keyPrefix).record.\(id.uuidString)"
    }

    private func tombstoneKey(for id: UUID) -> String {
        "\(keyPrefix).tombstone.\(id.uuidString)"
    }

    private func startObservingCloudChanges() {
        guard observerToken == nil else { return }
        observerToken = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: ubiquitous,
            queue: .main
        ) { [weak self] _ in
            self?.synchronize()
        }
    }

    private func importCloudChanges() {
        guard let modelContext else { return }

        isApplyingCloudChanges = true
        defer {
            isApplyingCloudChanges = false
            try? modelContext.save()
        }

        let index = readIndex()
        for id in index.ids {
            let record = readRecord(for: id)
            let tombstone = readTombstone(for: id)
            let local = localConnection(withId: id)

            if let tombstone,
               tombstone.deletedAt >= (record?.updatedAt ?? .distantPast) {
                if let local {
                    if tombstone.deletedAt >= local.updatedAt {
                        KeychainService.deletePassword(forConnectionId: local.id)
                        modelContext.delete(local)
                    } else {
                        writeRecord(SyncedConnectionRecord(connection: local))
                    }
                }
                continue
            }

            guard let record else { continue }
            if let local {
                if record.updatedAt > local.updatedAt {
                    record.apply(to: local)
                } else if local.updatedAt > record.updatedAt {
                    writeRecord(SyncedConnectionRecord(connection: local))
                }
            } else {
                modelContext.insert(record.makeConnection())
            }
        }
    }

    private func exportLocalConnectionsMissingFromCloud() {
        guard let modelContext else { return }

        let index = readIndex()
        let indexedIds = Set(index.ids)
        for connection in fetchLocalConnections(modelContext: modelContext) where !indexedIds.contains(connection.id) {
            writeRecord(SyncedConnectionRecord(connection: connection))
        }
    }

    private func localConnection(withId id: UUID) -> SavedConnection? {
        guard let modelContext else { return nil }
        return fetchLocalConnections(modelContext: modelContext).first { $0.id == id }
    }

    private func fetchLocalConnections(modelContext: ModelContext) -> [SavedConnection] {
        (try? modelContext.fetch(FetchDescriptor<SavedConnection>())) ?? []
    }

    private func readRecord(for id: UUID) -> SyncedConnectionRecord? {
        guard let data = ubiquitous.data(forKey: recordKey(for: id)) else { return nil }
        return try? JSONDecoder().decode(SyncedConnectionRecord.self, from: data)
    }

    private func readTombstone(for id: UUID) -> SyncedConnectionTombstone? {
        guard let data = ubiquitous.data(forKey: tombstoneKey(for: id)) else { return nil }
        return try? JSONDecoder().decode(SyncedConnectionTombstone.self, from: data)
    }

    private func writeRecord(_ record: SyncedConnectionRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        ubiquitous.set(data, forKey: recordKey(for: record.id))
        ubiquitous.removeObject(forKey: tombstoneKey(for: record.id))
        addToIndex(record.id)
        ubiquitous.synchronize()
    }

    private func writeTombstone(_ tombstone: SyncedConnectionTombstone) {
        guard let data = try? JSONEncoder().encode(tombstone) else { return }
        ubiquitous.set(data, forKey: tombstoneKey(for: tombstone.id))
        ubiquitous.removeObject(forKey: recordKey(for: tombstone.id))
        addToIndex(tombstone.id)
        ubiquitous.synchronize()
    }

    private func readIndex() -> ConnectionSyncIndex {
        guard let data = ubiquitous.data(forKey: indexKey),
              let index = try? JSONDecoder().decode(ConnectionSyncIndex.self, from: data) else {
            return ConnectionSyncIndex()
        }
        return index
    }

    private func writeIndex(_ index: ConnectionSyncIndex) {
        guard let data = try? JSONEncoder().encode(index) else { return }
        ubiquitous.set(data, forKey: indexKey)
    }

    private func addToIndex(_ id: UUID) {
        var index = readIndex()
        if !index.ids.contains(id) {
            index.ids.append(id)
            writeIndex(index)
        }
    }
}
