import SwiftUI

struct ICloudSyncView: View {
    let keyStore: KeyStore

    @State private var isConnectionsAndSettingsSyncEnabled = false
    @State private var isCredentialSyncConfigured = false
    @State private var isCredentialSyncEnabled = false
    @State private var biometricAvailability: CredentialBiometricAvailability = .unknown
    @State private var isChangingSync = false
    @State private var isConfirmingCredentialSyncDisable = false
    @State private var isConfirmingAllSyncDisable = false
    @State private var isConfirmingCloudDataDeletion = false
    @State private var alert: ICloudSyncAlert?

    private var palette: AppPalette { TerminalRuntime.shared.appPalette }

    var body: some View {
        List {
            Section {
                Toggle("Sync Connections & Settings", isOn: connectionsAndSettingsBinding)
                    .disabled(isChangingSync)
                    .accessibilityIdentifier("iCloudSync.connectionsAndSettings")

                if isChangingSync {
                    ProgressView()
                        .accessibilityIdentifier("iCloudSync.progress")
                }
            } footer: {
                Text("Syncs saved connections, known hosts, app preferences, App Lock settings, and its salted passcode verifier through your iCloud account.")
            }
            .themedListRow(palette)

            Section {
                Toggle(isOn: credentialSyncBinding) {
                    Text("Sync Credentials")
                        .foregroundStyle(isCredentialSyncUnavailable ? .secondary : .primary)
                        .strikethrough(credentialSyncSecurityBlocked)
                }
                .disabled(isCredentialSyncToggleDisabled)
                .accessibilityIdentifier("iCloudSync.credentials")
            } footer: {
                Text(credentialSyncFooterText)
            }
            .themedListRow(palette)

            Section("Status") {
                LabeledContent(
                    "Connections & Settings",
                    value: isConnectionsAndSettingsSyncEnabled ? "Synced" : "Not Synced"
                )
                LabeledContent(
                    "Credentials",
                    value: isCredentialSyncEnabled ? "Synced" : "Not Synced"
                )
            }
            .themedListRow(palette)

            Section {
                Button("Delete Data from iCloud", role: .destructive) {
                    isConfirmingCloudDataDeletion = true
                }
                .disabled(isConnectionsAndSettingsSyncEnabled || isChangingSync)
                .accessibilityIdentifier("iCloudSync.deleteCloudData")
            } footer: {
                Text(cloudDataFooterText)
            }
            .themedListRow(palette)
        }
        .themedListBackground(palette)
        .navigationTitle("iCloud Sync")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            refreshState()
        }
        .confirmationDialog(
            "Keep a local copy of credentials?",
            isPresented: $isConfirmingCredentialSyncDisable,
            titleVisibility: .visible
        ) {
            Button("Keep Local Copy") {
                updateCredentialSyncEnabled(false, retainLocalCopy: true)
            }
            Button("Delete From This Device", role: .destructive) {
                updateCredentialSyncEnabled(false, retainLocalCopy: false)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Disabling credential sync stops credential-protection settings, syncable SSH keys, and saved passwords from syncing. Existing iCloud copies are kept until you delete them separately.")
        }
        .confirmationDialog(
            "Turn off all iCloud sync?",
            isPresented: $isConfirmingAllSyncDisable,
            titleVisibility: .visible
        ) {
            Button("Turn Off Sync", role: .destructive) {
                disableAllSync()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Connections, known hosts, settings, App Lock, and credentials will stop syncing. Local copies remain on this device, and existing iCloud copies are kept until you delete them separately.")
        }
        .confirmationDialog(
            "Delete all SSH App data from iCloud?",
            isPresented: $isConfirmingCloudDataDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete from iCloud", role: .destructive) {
                deleteCloudData()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes SSH App's synced connections, known hosts, settings, App Lock verifier, passwords, and eligible SSH keys from iCloud. Local data on this device is not deleted.")
        }
        .alert(item: $alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var connectionsAndSettingsBinding: Binding<Bool> {
        Binding {
            isConnectionsAndSettingsSyncEnabled
        } set: { newValue in
            if newValue {
                updateConnectionsAndSettingsSyncEnabled(true)
            } else {
                isConfirmingAllSyncDisable = true
            }
        }
    }

    private var credentialSyncBinding: Binding<Bool> {
        Binding {
            isConnectionsAndSettingsSyncEnabled && isCredentialSyncConfigured
        } set: { newValue in
            if newValue {
                updateCredentialSyncEnabled(true, retainLocalCopy: true)
            } else {
                isConfirmingCredentialSyncDisable = true
            }
        }
    }

    private var credentialSyncSecurityBlocked: Bool {
        CredentialICloudSyncSettings.isBlockedByCredentialProtection(
            availability: biometricAvailability
        )
    }

    private var isCredentialSyncUnavailable: Bool {
        !isConnectionsAndSettingsSyncEnabled || credentialSyncSecurityBlocked
    }

    private var isCredentialSyncToggleDisabled: Bool {
        isChangingSync
            || !isConnectionsAndSettingsSyncEnabled
            || (credentialSyncSecurityBlocked && !isCredentialSyncConfigured)
    }

    private var cloudDataFooterText: String {
        if isConnectionsAndSettingsSyncEnabled {
            return "Turn off iCloud sync before deleting existing cloud copies."
        }
        return "Turning off sync keeps existing iCloud copies. Delete them separately here without deleting local data."
    }

    private var credentialSyncFooterText: String {
        if !isConnectionsAndSettingsSyncEnabled {
            return "Turn on Connections & Settings sync first."
        }

        if credentialSyncSecurityBlocked {
            return "Face ID/Touch ID needs to be set up first because synced credentials require biometric protection."
        }

        if isCredentialSyncEnabled {
            return "Credential-protection settings, Ed25519 SSH keys, and saved passwords sync to your other devices. Secure Enclave keys stay on this device."
        }

        if isCredentialSyncConfigured {
            return "Credential sync is configured, but unavailable on this device."
        }

        return "SSH keys, saved passwords, and credential-protection settings stay on this device."
    }

    private func refreshState() {
        biometricAvailability = BiometricCredentialAuthorizer.biometricAvailability()
        isConnectionsAndSettingsSyncEnabled = ConnectionsAndSettingsICloudSyncSettings.isEnabled()
        isCredentialSyncConfigured = CredentialICloudSyncSettings.isConfiguredEnabled()
        isCredentialSyncEnabled = CredentialICloudSyncSettings.isEnabled(
            availability: biometricAvailability
        )
        keyStore.loadKeys()
    }

    private func updateConnectionsAndSettingsSyncEnabled(_ enabled: Bool) {
        guard enabled != isConnectionsAndSettingsSyncEnabled else { return }

        performSyncChange {
            if enabled {
                try ConnectionsAndSettingsICloudSyncService.enable()
            } else {
                try ConnectionsAndSettingsICloudSyncService.disable(keyStore: keyStore)
            }
        }
    }

    private func updateCredentialSyncEnabled(_ enabled: Bool, retainLocalCopy: Bool) {
        guard enabled != isCredentialSyncEnabled || isCredentialSyncConfigured != enabled else {
            return
        }

        if enabled, credentialSyncSecurityBlocked {
            alert = ICloudSyncAlert(
                title: "iCloud Sync",
                message: "Face ID/Touch ID needs to be set up first because synced credentials require biometric protection."
            )
            return
        }

        performSyncChange {
            if enabled {
                try CredentialICloudSyncService.enable(keyStore: keyStore)
            } else {
                try CredentialICloudSyncService.disable(
                    keyStore: keyStore,
                    retainLocalCopy: retainLocalCopy
                )
            }
        }
    }

    private func disableAllSync() {
        performSyncChange {
            try ConnectionsAndSettingsICloudSyncService.disable(keyStore: keyStore)
        }
    }

    private func deleteCloudData() {
        performSyncChange {
            try ConnectionsAndSettingsICloudSyncService.deleteCloudData(keyStore: keyStore)
            alert = ICloudSyncAlert(
                title: "iCloud Data Deleted",
                message: "SSH App's iCloud data was deleted. Local data remains on this device."
            )
        }
    }

    private func performSyncChange(_ change: @escaping @MainActor () throws -> Void) {
        Task { @MainActor in
            guard !isChangingSync else { return }
            isChangingSync = true
            defer { isChangingSync = false }

            do {
                try change()
            } catch {
                alert = ICloudSyncAlert(title: "iCloud Sync", message: error.localizedDescription)
            }
            refreshState()
        }
    }
}

private struct ICloudSyncAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

#Preview {
    NavigationStack {
        ICloudSyncView(keyStore: KeyStore())
    }
}
