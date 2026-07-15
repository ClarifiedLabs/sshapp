//
//  AppSettings.swift
//  SSHApp
//
//  Centralised storage keys for user-tunable global flags. Views read these
//  via @AppStorage; non-view code (e.g. TmuxController bootstrap) reads via
//  the helper functions below.
//

import SwiftUI
import UIKit
import GhosttyTerminal

enum AppSettingsKey {
    static let showKeyboardBar = "dev.sshapp.sshapp.showKeyboardBar"

    // App-wide light/dark/system appearance override.
    static let appearanceMode = "appearance.mode"

    // tmux features (global; per-host overrides on SavedConnection)
    static let tmuxBackfillEnabled = "tmux.backfillEnabled"
    static let tmuxPauseModeEnabled = "tmux.pauseModeEnabled"
    static let tmuxScrollbackLines = "tmux.scrollbackLines"
    static let tmuxPauseAfterSeconds = "tmux.pauseAfterSeconds"

    // Terminal appearance — names of the selected Ghostty color themes for
    // light/dark mode (see GhosttyThemeCatalog).
    static let terminalLightTheme = "terminal.lightTheme"
    static let terminalDarkTheme = "terminal.darkTheme"
    static let terminalFontFamily = "terminal.fontFamily"
    static let terminalFontSize = "terminal.fontSize"
    static let terminalKeyRepeatEnabled = "terminal.keyRepeat.enabled"
    static let terminalKeyRepeatDelayMilliseconds = "terminal.keyRepeat.delayMilliseconds"
    static let terminalKeyRepeatIntervalMilliseconds = "terminal.keyRepeat.intervalMilliseconds"

    // iCloud sync choices. Connections/settings are the parent tier;
    // credential sync can only be effective while that tier is enabled.
    static let connectionsAndSettingsICloudSyncEnabled = "iCloud.connectionsAndSettingsSyncEnabled"
    static let credentialICloudSyncEnabled = "credentials.iCloudSyncEnabled"
    static let credentialBiometricProtectionEnabled = "credentials.biometricProtectionEnabled"
    static let credentialPasscodeFallbackEnabled = "credentials.passcodeFallbackEnabled"

    // App launch protection.
    static let appLaunchPasscodeRequired = "appLaunch.passcodeRequired"
    static let appLaunchPasscodeGracePeriodSeconds = "appLaunch.passcodeGracePeriodSeconds"
}

enum SyncedDeviceClass: String, Sendable {
    case phone
    case pad

    @MainActor
    static var current: SyncedDeviceClass {
        UIDevice.current.userInterfaceIdiom == .pad ? .pad : .phone
    }
}

enum CredentialBiometricAvailability: Equatable, Sendable {
    case available
    case lockedOut
    case notEnrolled
    case notAvailable
    case passcodeNotSet
    case unknown

    var statusText: String {
        switch self {
        case .available:
            "Available"
        case .lockedOut:
            "Locked"
        case .notEnrolled:
            "Not Set Up"
        case .notAvailable:
            "Unavailable"
        case .passcodeNotSet:
            "No Passcode"
        case .unknown:
            "Unknown"
        }
    }
}

enum CredentialProtectionDisableAuthorizationRequirement: Equatable, Sendable {
    case none
    case biometrics
    case deviceOwner
}

enum CredentialProtectionSettings {
    static func defaultEnabled(for availability: CredentialBiometricAvailability) -> Bool {
        canEnableProtection(for: availability)
    }

    static func canEnableProtection(for availability: CredentialBiometricAvailability) -> Bool {
        switch availability {
        case .available, .lockedOut:
            true
        case .notEnrolled, .notAvailable, .passcodeNotSet, .unknown:
            false
        }
    }

    static func isEnabled(
        defaults: UserDefaults = .standard,
        availability: CredentialBiometricAvailability = BiometricCredentialAuthorizer.biometricAvailability()
    ) -> Bool {
        defaults.object(forKey: AppSettingsKey.credentialBiometricProtectionEnabled) as? Bool
            ?? defaultEnabled(for: availability)
    }

    static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: AppSettingsKey.credentialBiometricProtectionEnabled)
    }

    static func isPasscodeFallbackEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: AppSettingsKey.credentialPasscodeFallbackEnabled) as? Bool ?? false
    }

    static func setPasscodeFallbackEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: AppSettingsKey.credentialPasscodeFallbackEnabled)
    }

    static func disableAuthorizationRequirement(
        hasStoredCredentials: Bool,
        availability: CredentialBiometricAvailability
    ) -> CredentialProtectionDisableAuthorizationRequirement {
        guard hasStoredCredentials else {
            return .none
        }

        return availability == .available ? .biometrics : .deviceOwner
    }
}

enum ICloudSyncStatus: Equatable, Sendable {
    case off
    case connectionsAndSettings
    case allData

    var menuText: String {
        switch self {
        case .off:
            "Off"
        case .connectionsAndSettings:
            "Connections & Settings"
        case .allData:
            "All Data"
        }
    }

    var systemImage: String {
        switch self {
        case .off:
            "icloud.slash"
        case .connectionsAndSettings:
            "icloud"
        case .allData:
            "checkmark.icloud"
        }
    }
}

enum ConnectionsAndSettingsICloudSyncSettings {
    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: AppSettingsKey.connectionsAndSettingsICloudSyncEnabled) as? Bool ?? false
    }

    static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: AppSettingsKey.connectionsAndSettingsICloudSyncEnabled)
    }

    static func migrateLegacyCredentialSyncIfNeeded(defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: AppSettingsKey.connectionsAndSettingsICloudSyncEnabled) == nil,
              CredentialICloudSyncSettings.isConfiguredEnabled(defaults: defaults) else {
            return
        }
        setEnabled(true, defaults: defaults)
    }

    static func status(
        defaults: UserDefaults = .standard,
        availability: CredentialBiometricAvailability = BiometricCredentialAuthorizer.biometricAvailability()
    ) -> ICloudSyncStatus {
        guard isEnabled(defaults: defaults) else { return .off }
        return CredentialICloudSyncSettings.isEnabled(defaults: defaults, availability: availability)
            ? .allData
            : .connectionsAndSettings
    }
}

enum CredentialICloudSyncSettings {
    static func isConfiguredEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: AppSettingsKey.credentialICloudSyncEnabled) as? Bool ?? false
    }

    static func setConfiguredEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: AppSettingsKey.credentialICloudSyncEnabled)
    }

    static func isEnabled(
        defaults: UserDefaults = .standard,
        availability: CredentialBiometricAvailability = BiometricCredentialAuthorizer.biometricAvailability()
    ) -> Bool {
        ConnectionsAndSettingsICloudSyncSettings.isEnabled(defaults: defaults)
            && isConfiguredEnabled(defaults: defaults)
            && !isBlockedByCredentialProtection(defaults: defaults, availability: availability)
    }

    static func isEnabledForCurrentDevice(defaults: UserDefaults = .standard) -> Bool {
        isEnabled(defaults: defaults, availability: BiometricCredentialAuthorizer.biometricAvailability())
    }

    static func isBlockedByCredentialProtection(
        defaults: UserDefaults = .standard,
        availability: CredentialBiometricAvailability
    ) -> Bool {
        isConfiguredEnabled(defaults: defaults)
            && CredentialProtectionSettings.isEnabled(defaults: defaults, availability: availability)
            && !CredentialProtectionSettings.canEnableProtection(for: availability)
    }
}

enum CredentialDeviceOwnerAuthenticationAvailability: Equatable, Sendable {
    case available
    case passcodeNotSet
    case unavailable
    case unknown

    var canAuthenticate: Bool {
        self == .available
    }
}

enum AppLaunchPasscodeSettings {
    static let defaultGracePeriodSeconds: Double = 0
    static let gracePeriodRange: ClosedRange<Double> = 0...300
    static let gracePeriodStep: Double = 15

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: AppSettingsKey.appLaunchPasscodeRequired) as? Bool ?? false
    }

    static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: AppSettingsKey.appLaunchPasscodeRequired)
    }

    static func gracePeriodSeconds(defaults: UserDefaults = .standard) -> Double {
        let raw = defaults.object(forKey: AppSettingsKey.appLaunchPasscodeGracePeriodSeconds) as? NSNumber
        return clampedGracePeriod(raw?.doubleValue ?? defaultGracePeriodSeconds)
    }

    static func setGracePeriodSeconds(_ seconds: Double, defaults: UserDefaults = .standard) {
        defaults.set(clampedGracePeriod(seconds), forKey: AppSettingsKey.appLaunchPasscodeGracePeriodSeconds)
    }

    static func clampedGracePeriod(_ seconds: Double) -> Double {
        min(max(seconds, gracePeriodRange.lowerBound), gracePeriodRange.upperBound)
    }

    static func shouldRequireAuthenticationAfterBackgrounding(
        backgroundedAt: Date?,
        now: Date = Date(),
        gracePeriodSeconds: Double
    ) -> Bool {
        guard let backgroundedAt else {
            return true
        }

        return now.timeIntervalSince(backgroundedAt) >= clampedGracePeriod(gracePeriodSeconds)
    }

    static func gracePeriodDisplayText(_ seconds: Double) -> String {
        let clamped = Int(clampedGracePeriod(seconds).rounded())
        if clamped == 0 {
            return "Immediately"
        }

        if clamped < 60 {
            return "\(clamped)s"
        }

        let minutes = clamped / 60
        let remainingSeconds = clamped % 60
        if remainingSeconds == 0 {
            return "\(minutes)m"
        }

        return "\(minutes)m \(remainingSeconds)s"
    }
}

enum TerminalKeyRepeatSettings {
    static let defaultEnabled = TerminalHardwareKeyRepeatConfiguration.defaultEnabled
    static let defaultDelayMilliseconds = TerminalHardwareKeyRepeatConfiguration.defaultDelayMilliseconds
    static let defaultIntervalMilliseconds = TerminalHardwareKeyRepeatConfiguration.defaultIntervalMilliseconds
    static let delayRange = TerminalHardwareKeyRepeatConfiguration.delayRange
    static let intervalRange = TerminalHardwareKeyRepeatConfiguration.intervalRange
    static let delayStep = 25.0
    static let intervalStep = 5.0

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: AppSettingsKey.terminalKeyRepeatEnabled) as? Bool ?? defaultEnabled
    }

    static func delayMilliseconds(defaults: UserDefaults = .standard) -> Double {
        let raw = defaults.object(forKey: AppSettingsKey.terminalKeyRepeatDelayMilliseconds) as? NSNumber
        return TerminalHardwareKeyRepeatConfiguration.clampedDelay(raw?.doubleValue ?? defaultDelayMilliseconds)
    }

    static func intervalMilliseconds(defaults: UserDefaults = .standard) -> Double {
        let raw = defaults.object(forKey: AppSettingsKey.terminalKeyRepeatIntervalMilliseconds) as? NSNumber
        return TerminalHardwareKeyRepeatConfiguration.clampedInterval(raw?.doubleValue ?? defaultIntervalMilliseconds)
    }

    static func configuration(defaults: UserDefaults = .standard) -> TerminalHardwareKeyRepeatConfiguration {
        TerminalHardwareKeyRepeatConfiguration(
            enabled: isEnabled(defaults: defaults),
            delayMilliseconds: delayMilliseconds(defaults: defaults),
            intervalMilliseconds: intervalMilliseconds(defaults: defaults)
        )
    }

    static func displayMilliseconds(_ milliseconds: Double) -> String {
        "\(Int(milliseconds.rounded())) ms"
    }
}

/// App-wide appearance override: force light or dark, or follow the OS.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var systemImage: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    /// nil for `.system` so the OS keeps driving live light/dark switches.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var uiStyle: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }

    static func resolve(_ raw: String?) -> AppearanceMode {
        raw.flatMap(AppearanceMode.init(rawValue:)) ?? .system
    }

    /// Force every window to this appearance. Window-level
    /// `overrideUserInterfaceStyle` is used instead of SwiftUI's
    /// `preferredColorScheme` because the trait cascade reliably reaches
    /// sheets, alerts, dynamic UIColors, and hosted terminal views, and
    /// `.unspecified` cleanly hands control back to the OS.
    @MainActor
    func applyToWindows() {
        for case let windowScene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = uiStyle
            }
        }
    }
}

extension UserDefaults {
    /// Read a bool with an explicit fallback when the key is unset (because
    /// `bool(forKey:)` returns false rather than nil for missing keys).
    func tmuxBool(_ key: String, default fallback: Bool) -> Bool {
        object(forKey: key) as? Bool ?? fallback
    }

    /// Read an int with an explicit positive fallback (because `integer(forKey:)`
    /// returns 0 for unset keys, which is rarely a sensible default for sizes).
    func tmuxInt(_ key: String, default fallback: Int) -> Int {
        let raw = object(forKey: key) as? Int ?? fallback
        return raw > 0 ? raw : fallback
    }

    /// Read a persisted terminal font size with clamping so an invalid defaults
    /// value cannot produce an unusably small or large terminal.
    func terminalFontSize(_ key: String, default fallback: Double) -> Double {
        let raw = object(forKey: key) as? NSNumber
        return TerminalFontSize.clamped(raw?.doubleValue ?? fallback)
    }
}

extension TmuxSettings {
    /// Resolve effective settings for a connection: per-host override wins,
    /// otherwise global UserDefaults, otherwise the static default.
    static func resolve(
        connection: SavedConnection?,
        defaults: UserDefaults = .standard
    ) -> TmuxSettings {
        var s = TmuxSettings.default
        s.backfillEnabled = connection?.tmuxBackfillOverride
            ?? defaults.tmuxBool(AppSettingsKey.tmuxBackfillEnabled, default: s.backfillEnabled)
        s.pauseModeEnabled = connection?.tmuxPauseModeOverride
            ?? defaults.tmuxBool(AppSettingsKey.tmuxPauseModeEnabled, default: s.pauseModeEnabled)
        s.scrollbackLines = defaults.tmuxInt(
            AppSettingsKey.tmuxScrollbackLines,
            default: s.scrollbackLines
        )
        s.pauseAfterSeconds = defaults.tmuxInt(
            AppSettingsKey.tmuxPauseAfterSeconds,
            default: s.pauseAfterSeconds
        )
        return s
    }
}
