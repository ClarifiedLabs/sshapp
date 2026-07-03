import Foundation

@MainActor
final class AppSettingsSyncStore {
    static let shared = AppSettingsSyncStore()

    private enum ValueKind {
        case string
        case bool
        case int
        case double
    }

    private struct SyncedSetting {
        let localKey: String
        let cloudKey: String
        let kind: ValueKind
    }

    private nonisolated static let defaultCloudKeyPrefix = "dev.sshapp.sshapp.settings."

    private let ubiquitous: NSUbiquitousKeyValueStore
    private let defaults: UserDefaults
    private let deviceClassOverride: SyncedDeviceClass?
    private let cloudKeyPrefix: String

    private var observerTokens: [NSObjectProtocol] = []
    private var isStarted = false
    private var isApplyingCloudValues = false

    init(
        ubiquitous: NSUbiquitousKeyValueStore = .default,
        defaults: UserDefaults = .standard,
        deviceClass: SyncedDeviceClass? = nil,
        cloudKeyPrefix: String = AppSettingsSyncStore.defaultCloudKeyPrefix
    ) {
        self.ubiquitous = ubiquitous
        self.defaults = defaults
        self.deviceClassOverride = deviceClass
        self.cloudKeyPrefix = cloudKeyPrefix
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true

        ubiquitous.synchronize()
        reconcileCloudAndLocalValues()

        let defaultsToken = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.syncLocalChangesToCloud()
            }
        }

        let cloudToken = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: ubiquitous,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.applyCloudChangesToLocalDefaults()
            }
        }

        observerTokens = [defaultsToken, cloudToken]
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
        }
        observerTokens = []
    }

    func reconcileCloudAndLocalValues() {
        isApplyingCloudValues = true
        defer {
            isApplyingCloudValues = false
            applyRuntimeSideEffects()
        }

        var didUpdateCloud = reconcile(settings: alwaysSyncedSettings)
        if CredentialICloudSyncSettings.isConfiguredEnabled(defaults: defaults) {
            didUpdateCloud = reconcile(settings: credentialSyncedSettings) || didUpdateCloud
        }

        if didUpdateCloud {
            ubiquitous.synchronize()
        }
    }

    func syncLocalChangesToCloud() {
        guard !isApplyingCloudValues else { return }

        var didUpdateCloud = false
        for setting in syncableSettings {
            guard let localValue = localObject(for: setting) else { continue }
            if !valuesEqual(localValue, cloudObject(for: setting), kind: setting.kind) {
                ubiquitous.set(localValue, forKey: setting.cloudKey)
                didUpdateCloud = true
            }
        }

        if didUpdateCloud {
            ubiquitous.synchronize()
        }
    }

    func applyCloudChangesToLocalDefaults() {
        isApplyingCloudValues = true
        defer {
            isApplyingCloudValues = false
            applyRuntimeSideEffects()
        }

        applyCloudValues(settings: alwaysSyncedSettings)
        if CredentialICloudSyncSettings.isConfiguredEnabled(defaults: defaults) {
            applyCloudValues(settings: credentialSyncedSettings)
        }
    }

    nonisolated static func clearSyncedValues(
        ubiquitous: NSUbiquitousKeyValueStore = .default,
        cloudKeyPrefix: String = AppSettingsSyncStore.defaultCloudKeyPrefix
    ) {
        for key in ubiquitous.dictionaryRepresentation.keys where key.hasPrefix(cloudKeyPrefix) {
            ubiquitous.removeObject(forKey: key)
        }
    }

    private var deviceClass: SyncedDeviceClass {
        deviceClassOverride ?? SyncedDeviceClass.current
    }

    private var syncableSettings: [SyncedSetting] {
        var settings = alwaysSyncedSettings
        if CredentialICloudSyncSettings.isConfiguredEnabled(defaults: defaults) {
            settings += credentialSyncedSettings
        }
        return settings
    }

    private var alwaysSyncedSettings: [SyncedSetting] {
        let classSuffix = deviceClass.rawValue
        return [
            setting(AppSettingsKey.appearanceMode, kind: .string),
            setting(AppSettingsKey.tmuxBackfillEnabled, kind: .bool),
            setting(AppSettingsKey.tmuxPauseModeEnabled, kind: .bool),
            setting(AppSettingsKey.tmuxScrollbackLines, kind: .int),
            setting(AppSettingsKey.tmuxPauseAfterSeconds, kind: .int),
            setting(AppSettingsKey.terminalLightTheme, kind: .string),
            setting(AppSettingsKey.terminalDarkTheme, kind: .string),
            setting(AppSettingsKey.terminalFontFamily, kind: .string),
            setting(AppSettingsKey.terminalFontSize, cloudSuffix: classSuffix, kind: .double),
            setting(AppSettingsKey.credentialICloudSyncEnabled, kind: .bool),
            setting(AppSettingsKey.showKeyboardBar, cloudSuffix: classSuffix, kind: .bool)
        ]
    }

    private var credentialSyncedSettings: [SyncedSetting] {
        [
            setting(AppSettingsKey.credentialBiometricProtectionEnabled, kind: .bool),
            setting(AppSettingsKey.credentialPasscodeFallbackEnabled, kind: .bool),
            setting(AppSettingsKey.appLaunchPasscodeRequired, kind: .bool),
            setting(AppSettingsKey.appLaunchPasscodeGracePeriodSeconds, kind: .double)
        ]
    }

    private func setting(_ localKey: String, cloudSuffix: String? = nil, kind: ValueKind) -> SyncedSetting {
        let suffix = cloudSuffix.map { ".\($0)" } ?? ""
        return SyncedSetting(
            localKey: localKey,
            cloudKey: "\(cloudKeyPrefix)\(localKey)\(suffix)",
            kind: kind
        )
    }

    private func reconcile(settings: [SyncedSetting]) -> Bool {
        var didUpdateCloud = false
        for setting in settings {
            if let cloudValue = cloudObject(for: setting) {
                apply(cloudValue, toLocal: setting)
            } else if let localValue = localObject(for: setting) {
                ubiquitous.set(localValue, forKey: setting.cloudKey)
                didUpdateCloud = true
            }
        }
        return didUpdateCloud
    }

    private func applyCloudValues(settings: [SyncedSetting]) {
        for setting in settings {
            guard let cloudValue = cloudObject(for: setting) else { continue }
            apply(cloudValue, toLocal: setting)
        }
    }

    private func localObject(for setting: SyncedSetting) -> Any? {
        switch setting.kind {
        case .string:
            return defaults.string(forKey: setting.localKey)
        case .bool:
            guard defaults.object(forKey: setting.localKey) != nil else { return nil }
            return defaults.bool(forKey: setting.localKey)
        case .int:
            guard let value = defaults.object(forKey: setting.localKey) as? NSNumber else { return nil }
            return value.intValue
        case .double:
            guard let value = defaults.object(forKey: setting.localKey) as? NSNumber else { return nil }
            return value.doubleValue
        }
    }

    private func cloudObject(for setting: SyncedSetting) -> Any? {
        guard let value = ubiquitous.object(forKey: setting.cloudKey) else { return nil }
        return coercedValue(value, kind: setting.kind)
    }

    private func apply(_ value: Any, toLocal setting: SyncedSetting) {
        guard let coerced = coercedValue(value, kind: setting.kind),
              !valuesEqual(localObject(for: setting), coerced, kind: setting.kind) else {
            return
        }
        defaults.set(coerced, forKey: setting.localKey)
    }

    private func coercedValue(_ value: Any, kind: ValueKind) -> Any? {
        switch kind {
        case .string:
            return value as? String
        case .bool:
            if let value = value as? Bool { return value }
            return (value as? NSNumber)?.boolValue
        case .int:
            return (value as? NSNumber)?.intValue
        case .double:
            return (value as? NSNumber)?.doubleValue
        }
    }

    private func valuesEqual(_ lhs: Any?, _ rhs: Any?, kind: ValueKind) -> Bool {
        switch kind {
        case .string:
            return lhs as? String == rhs as? String
        case .bool:
            return (lhs as? Bool) == (rhs as? Bool)
        case .int:
            return (lhs as? Int) == (rhs as? Int)
        case .double:
            return (lhs as? Double) == (rhs as? Double)
        }
    }

    private func applyRuntimeSideEffects() {
        guard defaults === UserDefaults.standard else { return }

        TerminalRuntime.shared.reloadPersistedSettings()
        AppearanceMode.resolve(defaults.string(forKey: AppSettingsKey.appearanceMode)).applyToWindows()
    }
}
