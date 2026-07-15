import Foundation

@MainActor
enum CredentialICloudSyncService {
    enum SyncError: LocalizedError {
        case connectionsAndSettingsRequired

        var errorDescription: String? {
            "Turn on Connections & Settings sync before syncing credentials."
        }
    }

    static func enable(keyStore: KeyStore) throws {
        guard ConnectionsAndSettingsICloudSyncSettings.isEnabled() else {
            throw SyncError.connectionsAndSettingsRequired
        }

        keyStore.applyCredentialICloudSync(enabled: true, retainLocalCopy: true)

        try KeychainService.setPrivateKeysSynchronizable(
            true,
            forKeyIds: syncableKeyIds(in: keyStore)
        )
        try KeychainService.setStoredPasswordsSynchronizable(true)
        CredentialICloudSyncSettings.setConfiguredEnabled(true)

        AppSettingsSyncStore.shared.syncLocalChangesToCloud()
        keyStore.loadKeys()
    }

    static func disable(keyStore: KeyStore, retainLocalCopy: Bool) throws {
        let keyIds = syncableKeyIds(in: keyStore)

        if retainLocalCopy {
            try KeychainService.copyPrivateKeysToLocal(forKeyIds: keyIds)
            try KeychainService.copyStoredPasswordsToLocal()
            keyStore.applyCredentialICloudSync(enabled: false, retainLocalCopy: true)
        } else {
            try KeychainService.deleteLocalPrivateKeys(forKeyIds: keyIds)
            KeychainService.deleteLocalStoredPasswords()
            CredentialProtectionSettings.setEnabled(false)
            CredentialProtectionSettings.setPasscodeFallbackEnabled(false)
            keyStore.applyCredentialICloudSync(enabled: false, retainLocalCopy: false)
        }

        CredentialICloudSyncSettings.setConfiguredEnabled(false)
        AppSettingsSyncStore.shared.syncLocalChangesToCloud()
        keyStore.loadKeys()
    }

    static func deleteSyncedCredentialData(keyStore: KeyStore) {
        KeychainService.deleteSyncedPrivateKeys()
        KeychainService.deleteSyncedStoredPasswords()
        keyStore.deleteSyncedCredentialMetadata()
    }

    private static func syncableKeyIds(in keyStore: KeyStore) -> [UUID] {
        keyStore.keys
            .filter(\.keyType.canSyncWithICloud)
            .map(\.id)
    }
}
