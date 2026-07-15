import SwiftUI

struct AppLockView: View {
    let keyStore: KeyStore

    @State private var isEnabled = false
    @State private var hasPasscode = false
    @State private var gracePeriodSeconds = AppLaunchPasscodeSettings.defaultGracePeriodSeconds
    @State private var sheet: AppLockSheet?
    @AppStorage(AppSettingsKey.connectionsAndSettingsICloudSyncEnabled)
    private var isConnectionsAndSettingsSyncEnabled = false

    private var palette: AppPalette { TerminalRuntime.shared.appPalette }

    var body: some View {
        List {
            Section {
                Toggle("Require Passcode on App Launch", isOn: enabledBinding)
                    .accessibilityIdentifier("appLock.enabled")

                if isEnabled {
                    if hasPasscode {
                        HStack {
                            Text("Require again after backgrounding")
                            Spacer()
                            Text(AppLaunchPasscodeSettings.gracePeriodDisplayText(gracePeriodSeconds))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            Button {
                                sheet = .edit
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Edit App Lock")
                            .accessibilityIdentifier("appLock.edit")
                        }
                    } else {
                        HStack {
                            Text("App passcode")
                            Spacer()
                            Text("Not Available")
                                .foregroundStyle(.secondary)
                            Button {
                                sheet = .setPasscode
                            } label: {
                                Image(systemName: "plus.circle")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Set app passcode")
                            .accessibilityIdentifier("appLock.setPasscode")
                        }
                    }
                }
            } header: {
                Text("App Lock")
            } footer: {
                Text(appLockFooterText)
            }
            .themedListRow(palette)

            Section {
                NavigationLink {
                    ICloudSyncView(keyStore: keyStore)
                } label: {
                    LabeledContent(
                        "iCloud Sync",
                        value: isConnectionsAndSettingsSyncEnabled ? "Synced" : "Not Synced"
                    )
                }
                .accessibilityIdentifier("appLock.iCloudSync")
            } footer: {
                Text(syncFooterText)
            }
            .themedListRow(palette)
        }
        .themedListBackground(palette)
        .navigationTitle("App Lock")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            refreshState()
        }
        .sheet(item: $sheet) { destination in
            Group {
                switch destination {
                case .setPasscode:
                    AppLockPasscodeSheet(mode: .set) {
                        refreshState()
                    }
                case .edit:
                    AppLockPasscodeSheet(mode: .edit) {
                        refreshState()
                    }
                case .disable:
                    AppLockPasscodeSheet(mode: .disable) {
                        KeychainService.deleteAppLockPasscode()
                        AppLaunchPasscodeSettings.setEnabled(false)
                        AppSettingsSyncStore.shared.syncLocalChangesToCloud()
                        refreshState()
                    }
                }
            }
            .tint(palette.accent)
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding {
            isEnabled
        } set: { newValue in
            updateEnabled(newValue)
        }
    }

    private var appLockFooterText: String {
        if isEnabled {
            guard hasPasscode else {
                if isConnectionsAndSettingsSyncEnabled {
                    return "App Lock is enabled, but no app passcode is available yet. It will lock after the passcode arrives from iCloud Keychain or you set one here."
                }
                return "App Lock is enabled, but no app passcode is set on this device yet."
            }

            let timeoutText = AppLaunchPasscodeSettings.clampedGracePeriod(gracePeriodSeconds) == 0
                ? "immediately"
                : "after \(AppLaunchPasscodeSettings.gracePeriodDisplayText(gracePeriodSeconds))"
            return "Opening SSH App requires the app passcode. Returning from the background requires it again \(timeoutText)."
        }

        return "Opening SSH App does not require an app passcode. App Lock is independent of saved credential protection."
    }

    private var syncFooterText: String {
        if isConnectionsAndSettingsSyncEnabled {
            return "App Lock settings and its salted passcode verifier sync through your iCloud account."
        }
        return "App Lock settings and passcode stay on this device."
    }

    private func refreshState() {
        isEnabled = AppLaunchPasscodeSettings.isEnabled()
        hasPasscode = KeychainService.hasAppLockPasscode()
        gracePeriodSeconds = AppLaunchPasscodeSettings.gracePeriodSeconds()
    }

    private func updateEnabled(_ newValue: Bool) {
        guard newValue != isEnabled else { return }

        if newValue {
            sheet = .setPasscode
        } else if KeychainService.hasAppLockPasscode() {
            sheet = .disable
        } else {
            AppLaunchPasscodeSettings.setEnabled(false)
            AppSettingsSyncStore.shared.syncLocalChangesToCloud()
            isEnabled = false
        }
    }
}

private enum AppLockSheet: Identifiable {
    case setPasscode
    case edit
    case disable

    var id: String {
        switch self {
        case .setPasscode:
            "set-passcode"
        case .edit:
            "edit"
        case .disable:
            "disable"
        }
    }
}

#Preview {
    NavigationStack {
        AppLockView(keyStore: KeyStore())
    }
}
