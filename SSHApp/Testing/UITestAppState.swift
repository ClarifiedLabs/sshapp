#if DEBUG
import Foundation

enum UITestAppState {
    static var usesInMemoryStore: Bool {
        ProcessInfo.processInfo.arguments.contains("--sshapp-in-memory-store")
    }

    static var usesTmuxResizeHarness: Bool {
        ProcessInfo.processInfo.arguments.contains("--sshapp-ui-test-tmux-resize")
    }

    static func resetIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--sshapp-reset-state") else {
            return
        }

        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? FileManager.default.removeItem(at: documentsDirectory.appendingPathComponent("known_hosts"))

        // Clear current metadata keys in UserDefaults and the ubiquitous store,
        // plus the keyboard-bar preference.
        let defaults = UserDefaults.standard
        let ubiquitous = NSUbiquitousKeyValueStore.default

        for key in [
            "dev.sshapp.sshapp.sshKeys",
            AppSettingsKey.showKeyboardBar,
            AppSettingsKey.appearanceMode,
            AppSettingsKey.tmuxBackfillEnabled,
            AppSettingsKey.tmuxPauseModeEnabled,
            AppSettingsKey.tmuxScrollbackLines,
            AppSettingsKey.tmuxPauseAfterSeconds,
            AppSettingsKey.terminalLightTheme,
            AppSettingsKey.terminalDarkTheme,
            AppSettingsKey.terminalFontFamily,
            AppSettingsKey.terminalFontSize,
            AppSettingsKey.connectionsAndSettingsICloudSyncEnabled,
            AppSettingsKey.credentialICloudSyncEnabled,
            AppSettingsKey.credentialBiometricProtectionEnabled,
            AppSettingsKey.credentialPasscodeFallbackEnabled,
            AppSettingsKey.appLaunchPasscodeRequired,
            AppSettingsKey.appLaunchPasscodeGracePeriodSeconds
        ] {
            defaults.removeObject(forKey: key)
            ubiquitous.removeObject(forKey: key)
        }
        AppSettingsSyncStore.clearSyncedValues(ubiquitous: ubiquitous)
        ConnectionSyncStore.clearSyncedValues(ubiquitous: ubiquitous)
        KnownHostsSyncStore.clearSyncedValues(ubiquitous: ubiquitous)
        KeychainService.deleteAppLockPasscode()
        KeychainService.deleteSyncedAppLockPasscode()
        ubiquitous.synchronize()
    }
}
#endif
