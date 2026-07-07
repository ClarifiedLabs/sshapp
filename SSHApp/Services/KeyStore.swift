import Foundation

enum SSHKeyMetadataStorage {
    static let canonicalSyncedKeysKey = "dev.sshapp.sshapp.sshKeys"
    static let canonicalLocalKeysKey = "dev.sshapp.sshapp.localSSHKeys"

    static func keyType(
        for id: UUID,
        ubiquitous: NSUbiquitousKeyValueStore = .default,
        localDefaults: UserDefaults = .standard
    ) -> SSHKey.KeyType? {
        for key in loadKeys(from: localDefaults.data(forKey: canonicalLocalKeysKey))
            + loadKeys(from: ubiquitous.data(forKey: canonicalSyncedKeysKey)) where key.id == id {
            return key.keyType
        }
        return nil
    }

    private static func loadKeys(from data: Data?) -> [SSHKey] {
        guard let data,
              let keys = try? JSONDecoder().decode([SSHKey].self, from: data) else {
            return []
        }
        return keys
    }
}

/// Service for managing SSH key metadata.
///
/// Private-key material lives in `KeychainService`. When credential iCloud
/// sync is enabled, Ed25519 metadata is stored in
/// `NSUbiquitousKeyValueStore`; otherwise metadata stays in local defaults.
/// Secure Enclave metadata is always local because the backing key is
/// device-local and non-exportable.
@MainActor
@Observable
final class KeyStore {
    enum KeyStoreError: LocalizedError {
        case invalidKeyName
        case keyNotFound

        var errorDescription: String? {
            switch self {
            case .invalidKeyName:
                return "Enter a key name."
            case .keyNotFound:
                return "SSH key not found."
            }
        }
    }

    /// Current ubiquitous-store key for key metadata.
    private let keysKey: String
    private let localKeysKey: String

    private let ubiquitous: NSUbiquitousKeyValueStore
    private let localDefaults: UserDefaults

    private(set) var keys: [SSHKey] = []

    /// Production initializer. Uses the default ubiquitous store under the
    /// canonical metadata key.
    init() {
        self.keysKey = SSHKeyMetadataStorage.canonicalSyncedKeysKey
        self.localKeysKey = SSHKeyMetadataStorage.canonicalLocalKeysKey
        self.ubiquitous = .default
        self.localDefaults = .standard
        loadKeys()
        observeExternalChanges()
    }

    /// Test/internal initializer allowing a custom ubiquitous store and key
    /// so tests can exercise round-trips without clobbering real data.
    init(
        ubiquitous: NSUbiquitousKeyValueStore,
        keysKey: String,
        localDefaults: UserDefaults = .standard,
        localKeysKey: String? = nil
    ) {
        self.keysKey = keysKey
        self.localKeysKey = localKeysKey ?? "\(keysKey).local"
        self.ubiquitous = ubiquitous
        self.localDefaults = localDefaults
        loadKeys()
        observeExternalChanges()
    }

    /// Background task iterating external-change notifications. Assigned only on
    /// the main actor; read once from `deinit` when no other references remain.
    /// `@ObservationIgnored` keeps the `@Observable` macro from generating
    /// tracking accessors for this internal bookkeeping property.
    @ObservationIgnored private nonisolated(unsafe) var observerTask: Task<Void, Never>?
    @ObservationIgnored private nonisolated(unsafe) var defaultsObserverTask: Task<Void, Never>?

    deinit {
        observerTask?.cancel()
        defaultsObserverTask?.cancel()
    }

    // MARK: - Loading / Saving

    /// Load all saved keys from synced and device-local metadata stores.
    func loadKeys() {
        if isCredentialSyncEnabled {
            keys = mergedKeys(loadSyncedKeys() + loadLocalKeys())
        } else {
            keys = loadLocalKeys()
        }
    }

    /// Save keys to the appropriate metadata store.
    private func saveKeys() {
        saveKeys(credentialSyncEnabled: isCredentialSyncEnabled)
    }

    private func saveKeys(credentialSyncEnabled: Bool) {
        if credentialSyncEnabled {
            saveSyncedKeys(keys.filter(\.keyType.canSyncWithICloud))
            saveLocalKeys(keys.filter { !$0.keyType.canSyncWithICloud })
        } else {
            saveLocalKeys(keys)
        }
    }

    private func loadSyncedKeys() -> [SSHKey] {
        guard let data = ubiquitous.data(forKey: keysKey),
              let savedKeys = try? JSONDecoder().decode([SSHKey].self, from: data) else {
            return []
        }
        return savedKeys
    }

    private func loadLocalKeys() -> [SSHKey] {
        guard let data = localDefaults.data(forKey: localKeysKey),
              let savedKeys = try? JSONDecoder().decode([SSHKey].self, from: data) else {
            return []
        }
        return savedKeys
    }

    private func saveSyncedKeys(_ keys: [SSHKey]) {
        guard let data = try? JSONEncoder().encode(keys) else { return }
        ubiquitous.set(data, forKey: keysKey)
        ubiquitous.synchronize()
    }

    private func saveLocalKeys(_ keys: [SSHKey]) {
        guard let data = try? JSONEncoder().encode(keys) else { return }
        localDefaults.set(data, forKey: localKeysKey)
    }

    private var isCredentialSyncEnabled: Bool {
        CredentialICloudSyncSettings.isEnabledForCurrentDevice(defaults: localDefaults)
    }

    private func mergedKeys(_ keys: [SSHKey]) -> [SSHKey] {
        var seen: Set<UUID> = []
        return keys.filter { key in
            guard !seen.contains(key.id) else {
                return false
            }
            seen.insert(key.id)
            return true
        }
    }

    // MARK: - External Change Handling

    private func observeExternalChanges() {
        // Map to `Void` so the (non-Sendable) `Notification` never crosses the
        // actor boundary, and let the `Task` inherit `@MainActor` isolation.
        let changes = NotificationCenter.default
            .notifications(named: NSUbiquitousKeyValueStore.didChangeExternallyNotification)
            .map { _ in () }
        observerTask = Task { [weak self] in
            for await _ in changes {
                self?.loadKeys()
            }
        }

        let defaultsChanges = NotificationCenter.default
            .notifications(named: UserDefaults.didChangeNotification)
            .map { _ in () }
        defaultsObserverTask = Task { [weak self] in
            for await _ in defaultsChanges {
                self?.loadKeys()
            }
        }
    }

    // MARK: - Key Operations

    /// Generate and store a new SSH key.
    func generateKey(name: String, keyType: SSHKey.KeyType = .ed25519) throws -> SSHKey {
        let sshKey: SSHKey
        let privateKeyData: Data

        switch keyType {
        case .ed25519:
            (sshKey, privateKeyData) = try SSHKeyGenerator.generateEd25519Key(name: name)
            try KeychainService.savePrivateKey(
                privateKeyData,
                forKeyId: sshKey.id,
                synchronizable: isCredentialSyncEnabled
            )
        case .secureEnclaveECDSA:
            (sshKey, privateKeyData) = try SSHKeyGenerator.generateSecureEnclaveECDSAKey(name: name)
            try KeychainService.saveDevicePrivateKey(privateKeyData, forKeyId: sshKey.id)
        }

        // Store public key metadata.
        keys.append(sshKey)
        saveKeys()

        return sshKey
    }

    /// Delete a key.
    func deleteKey(_ key: SSHKey) throws {
        // Remove from Keychain.
        try KeychainService.deletePrivateKey(forKeyId: key.id)

        // Remove from storage.
        keys.removeAll { $0.id == key.id }
        saveKeys()
    }

    /// Rename a key by updating its persisted metadata. Private key material is unchanged.
    func renameKey(_ key: SSHKey, to name: String) throws -> SSHKey {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw KeyStoreError.invalidKeyName
        }

        guard let index = keys.firstIndex(where: { $0.id == key.id }) else {
            throw KeyStoreError.keyNotFound
        }

        let renamedKey = keys[index].renamed(to: trimmedName)
        keys[index] = renamedKey
        saveKeys()
        return renamedKey
    }

    /// Get private key data for a key.
    func getPrivateKey(for key: SSHKey) throws -> Data {
        return try KeychainService.loadPrivateKey(forKeyId: key.id)
    }

    /// Get a key by ID.
    func key(withId id: UUID) -> SSHKey? {
        return keys.first { $0.id == id }
    }

    func applyCredentialICloudSync(enabled: Bool, retainLocalCopy: Bool) {
        if enabled {
            keys = mergedKeys(loadLocalKeys() + loadSyncedKeys())
            saveKeys(credentialSyncEnabled: true)
            return
        }

        if retainLocalCopy {
            keys = mergedKeys(loadSyncedKeys() + loadLocalKeys())
        } else {
            keys = loadLocalKeys().filter { !$0.keyType.canSyncWithICloud }
        }
        saveKeys(credentialSyncEnabled: false)
        saveSyncedKeys([])
    }
}
