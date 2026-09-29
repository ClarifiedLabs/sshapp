#if DEBUG
import Foundation

enum TerminalSelectionUITestScenario: String, CaseIterable, Codable, Sendable {
    case standard
    case mouseCaptured = "mouse-captured"
    case captureDuringLongPress = "capture-during-long-press"
    case remountDuringHandleDrag = "remount-during-handle-drag"
}

struct TerminalSelectionUITestScenarioArgumentError: Error, CustomStringConvertible, Sendable {
    let description: String
}

enum TerminalLifecycleScenario: String, Codable, Sendable {
    case graphicsBackground = "graphics-background"
    case graphicsSystem = "graphics-system"
    case scrollMomentum = "scroll-momentum"
}

enum UITestAppState {
    private static let terminalSelectionScenarioPrefix =
        "--sshapp-ui-test-terminal-selection-scenario="
    static var terminalLifecycleArgument: Result<TerminalLifecycleScenario?, TerminalSelectionUITestScenarioArgumentError> {
        parseTerminalLifecycleArguments(ProcessInfo.processInfo.arguments)
    }

    static func parseTerminalLifecycleArguments(_ arguments: [String])
        -> Result<TerminalLifecycleScenario?, TerminalSelectionUITestScenarioArgumentError> {
        let prefix = "--sshapp-ui-test-terminal-lifecycle"
        let matches = arguments.filter { $0.hasPrefix(prefix) }
        guard !matches.isEmpty else { return .success(nil) }
        guard matches.count == 1, matches[0].hasPrefix(prefix + "="),
              let mode = TerminalLifecycleScenario(rawValue: String(matches[0].dropFirst(prefix.count + 1))),
              arguments.filter({ $0 == "--sshapp-ui-test-terminal-selection" }).count == 1,
              arguments.filter({ $0.hasPrefix(terminalSelectionScenarioPrefix) }) == [terminalSelectionScenarioPrefix + "standard"],
              !arguments.contains(where: { $0.hasPrefix("--sshapp-ui-test-terminal-loupe") || $0.hasPrefix("--sshapp-ui-test-terminal-ime") }) else {
            return .failure(.init(description: "Invalid or conflicting terminal lifecycle launch contract"))
        }
        return .success(mode)
    }

    static var usesLiveSSHHarness: Bool {
        ProcessInfo.processInfo.arguments.contains("--sshapp-ui-test-live-ssh")
    }

    static var usesLiveSSHAuthenticationHarness: Bool {
        ProcessInfo.processInfo.arguments.contains("--sshapp-ui-test-authentication")
    }

    static var usesInMemoryStore: Bool {
        ProcessInfo.processInfo.arguments.contains("--sshapp-in-memory-store")
    }

    static var usesTmuxResizeHarness: Bool {
        ProcessInfo.processInfo.arguments.contains("--sshapp-ui-test-tmux-resize")
    }

    static var usesTmuxStatusHarness: Bool {
        ProcessInfo.processInfo.arguments.contains("--sshapp-ui-test-tmux-status")
    }

    static var usesPromptTransitionHarness: Bool {
        ProcessInfo.processInfo.arguments.contains("--sshapp-ui-test-prompt-transition")
    }

    static var usesKeyboardSuppressionHarness: Bool {
        ProcessInfo.processInfo.arguments.contains("--sshapp-ui-test-keyboard-suppression")
    }

    static var simulatesKeyboardSuppressionSystemResign: Bool {
        ProcessInfo.processInfo.arguments.contains(
            "--sshapp-ui-test-keyboard-suppression-system-resign"
        )
    }

    static var usesRetainedTerminalVisibilityFixture: Bool {
        ProcessInfo.processInfo.arguments.contains("--sshapp-ui-test-retained-terminal-visibility")
    }

    static var usesTerminalSelectionHarness: Bool {
        ProcessInfo.processInfo.arguments.contains("--sshapp-ui-test-terminal-selection")
            || ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--sshapp-ui-test-terminal-lifecycle") }
    }

    /// Strictly accepts one `--...-scenario=<known-value>` argument. Invalid
    /// launch contracts are rendered by the harness as an accessible failure.
    static var terminalSelectionScenarioArgument:
        Result<TerminalSelectionUITestScenario, TerminalSelectionUITestScenarioArgumentError> {
        let scenarioArguments = ProcessInfo.processInfo.arguments.filter {
            $0.hasPrefix(terminalSelectionScenarioPrefix)
        }
        guard scenarioArguments.count == 1 else {
            return .failure(TerminalSelectionUITestScenarioArgumentError(
                description: "Expected exactly one terminal selection scenario argument; "
                    + "received \(scenarioArguments.count)"
            ))
        }

        let rawValue = String(scenarioArguments[0].dropFirst(terminalSelectionScenarioPrefix.count))
        guard let scenario = TerminalSelectionUITestScenario(rawValue: rawValue) else {
            let validValues = TerminalSelectionUITestScenario.allCases
                .map(\.rawValue)
                .joined(separator: ", ")
            return .failure(TerminalSelectionUITestScenarioArgumentError(
                description: "Unknown terminal selection scenario '\(rawValue)'; "
                    + "expected one of: \(validValues)"
            ))
        }
        return .success(scenario)
    }

    static var promptTransitionStartsInTmux: Bool {
        ProcessInfo.processInfo.arguments.contains("--sshapp-ui-test-prompt-transition-start-tmux")
    }

    static func shouldResetState(arguments: [String]) -> Bool {
        arguments.contains("--sshapp-reset-state")
            && !arguments.contains("--sshapp-ui-test-terminal-lifecycle=graphics-system")
    }

    static func resetIfRequested() {
        // Physical system acceptance is non-destructive even if an old manual
        // Xcode launch configuration still includes the reset argument.
        guard shouldResetState(arguments: ProcessInfo.processInfo.arguments) else {
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
            AppSettingsKey.keepScreenAwake,
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
