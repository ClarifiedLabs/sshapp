import Foundation

@MainActor
enum CredentialICloudSyncService {
    static func enable(keyStore: KeyStore) throws {
        CredentialICloudSyncSettings.setConfiguredEnabled(true)
        keyStore.applyCredentialICloudSync(enabled: true, retainLocalCopy: true)

        try KeychainService.setPrivateKeysSynchronizable(
            true,
            forKeyIds: syncableKeyIds(in: keyStore)
        )
        try KeychainService.setStoredPasswordsSynchronizable(true)
        try KeychainService.setAppLockPasscodeSynchronizable(true)

        AppSettingsSyncStore.shared.syncLocalChangesToCloud()
        keyStore.loadKeys()
    }

    static func disable(keyStore: KeyStore, retainLocalCopy: Bool) throws {
        let keyIds = syncableKeyIds(in: keyStore)
        CredentialICloudSyncSettings.setConfiguredEnabled(false)

        if retainLocalCopy {
            try KeychainService.setPrivateKeysSynchronizable(false, forKeyIds: keyIds)
            try KeychainService.setStoredPasswordsSynchronizable(false)
            try KeychainService.setAppLockPasscodeSynchronizable(false)
            keyStore.applyCredentialICloudSync(enabled: false, retainLocalCopy: true)
        } else {
            try KeychainService.deletePrivateKeys(forKeyIds: keyIds)
            KeychainService.deleteStoredPasswords()
            KeychainService.deleteAppLockPasscode()
            CredentialProtectionSettings.setEnabled(false)
            CredentialProtectionSettings.setPasscodeFallbackEnabled(false)
            AppLaunchPasscodeSettings.setEnabled(false)
            AppLaunchPasscodeSettings.setGracePeriodSeconds(AppLaunchPasscodeSettings.defaultGracePeriodSeconds)
            keyStore.applyCredentialICloudSync(enabled: false, retainLocalCopy: false)
        }

        AppSettingsSyncStore.shared.syncLocalChangesToCloud()
        keyStore.loadKeys()
    }

    private static func syncableKeyIds(in keyStore: KeyStore) -> [UUID] {
        keyStore.keys
            .filter(\.keyType.canSyncWithICloud)
            .map(\.id)
    }
}
