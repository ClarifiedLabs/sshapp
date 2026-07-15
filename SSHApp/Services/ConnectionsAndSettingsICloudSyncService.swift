import Foundation

@MainActor
enum ConnectionsAndSettingsICloudSyncService {
    enum SyncError: LocalizedError {
        case syncMustBeOffBeforeDeletingCloudData

        var errorDescription: String? {
            "Turn off iCloud sync before deleting its cloud data."
        }
    }

    static func enable() throws {
        guard !ConnectionsAndSettingsICloudSyncSettings.isEnabled() else {
            refreshStores()
            return
        }

        ConnectionsAndSettingsICloudSyncSettings.setEnabled(true)
        do {
            try KeychainService.setAppLockPasscodeSynchronizable(true)
        } catch {
            ConnectionsAndSettingsICloudSyncSettings.setEnabled(false)
            refreshStores()
            throw error
        }
        refreshStores()
    }

    static func disable(keyStore: KeyStore) throws {
        if CredentialICloudSyncSettings.isConfiguredEnabled() {
            try CredentialICloudSyncService.disable(keyStore: keyStore, retainLocalCopy: true)
        }

        guard ConnectionsAndSettingsICloudSyncSettings.isEnabled() else {
            refreshStores()
            return
        }

        try KeychainService.copyAppLockPasscodeToLocal()
        ConnectionsAndSettingsICloudSyncSettings.setEnabled(false)
        refreshStores()
    }

    static func deleteCloudData(keyStore: KeyStore) throws {
        guard !ConnectionsAndSettingsICloudSyncSettings.isEnabled(),
              !CredentialICloudSyncSettings.isConfiguredEnabled() else {
            throw SyncError.syncMustBeOffBeforeDeletingCloudData
        }

        CredentialICloudSyncService.deleteSyncedCredentialData(keyStore: keyStore)
        KeychainService.deleteSyncedAppLockPasscode()
        AppSettingsSyncStore.clearSyncedValues()
        ConnectionSyncStore.clearSyncedValues()
        KnownHostsSyncStore.clearSyncedValues()
        NSUbiquitousKeyValueStore.default.synchronize()
    }

    static func refreshStores() {
        AppSettingsSyncStore.shared.start()
        AppSettingsSyncStore.shared.refreshSyncState()
        ConnectionSyncStore.shared.refreshSyncState()
        KnownHostsSyncStore.shared.refreshSyncState()
    }
}
