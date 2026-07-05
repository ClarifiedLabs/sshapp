import SwiftUI

struct InstallSSHKeySheet: View {
    let tab: Tab
    let keyStore: KeyStore
    let connectionStore: ConnectionStore

    @Environment(\.dismiss) private var dismiss
    @State private var selectedKeyId: UUID?
    @State private var hasInitializedSelection = false
    @State private var isGeneratingKey = false
    @State private var isInstalling = false
    @State private var installResult: AuthorizedKeysInstallResult?
    @State private var errorMessage: String?
    @State private var isPromptingPasswordDelete = false

    private var palette: AppPalette { TerminalRuntime.shared.appPalette }

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    LabeledContent("Host", value: connectionLabel)
                }
                .themedListRow(palette)

                Section("SSH Keys") {
                    ForEach(keyStore.keys) { key in
                        Button {
                            select(key)
                        } label: {
                            SSHKeyInstallSelectionRow(
                                key: key,
                                isSelected: selectedKeyId == key.id
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("installSSHKey.key.\(key.id.uuidString)")
                    }

                    Button {
                        isGeneratingKey = true
                    } label: {
                        Label("Generate New Key", systemImage: "plus.circle")
                    }
                    .accessibilityIdentifier("installSSHKey.generate")
                }
                .themedListRow(palette)

                if let installResult {
                    Section {
                        Label(installResult.summary, systemImage: "checkmark.circle.fill")
                            .foregroundColor(palette.success)
                    }
                    .themedListRow(palette)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundColor(palette.error)
                    }
                    .themedListRow(palette)
                }
            }
            .themedListBackground(palette)
            .navigationTitle("Install SSH Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(installResult == nil ? "Cancel" : "Done") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        installSelectedKey()
                    } label: {
                        if isInstalling {
                            ProgressView()
                        } else {
                            Text("Install")
                        }
                    }
                    .disabled(isInstallDisabled)
                    .accessibilityIdentifier("installSSHKey.install")
                }
            }
        }
        .onAppear(perform: initializeSelectionIfNeeded)
        .sheet(isPresented: $isGeneratingKey) {
            GenerateKeySheet(keyStore: keyStore) { generatedKey in
                selectedKeyId = generatedKey.id
                installResult = nil
                errorMessage = nil
            }
            .tint(palette.accent)
        }
        .alert(
            "Delete Saved Password?",
            isPresented: $isPromptingPasswordDelete,
            presenting: tab.connection
        ) { connection in
            // Credential authorization for this deletion carries over from the
            // biometric check performed before the key installation.
            Button("Delete Password", role: .destructive) {
                KeychainService.deletePassword(forConnectionId: connection.id)
                normalizeAutoReconnectAfterPasswordDelete(for: connection)
            }
            Button("Keep Password", role: .cancel) {}
        } message: { connection in
            Text("This connection now uses an SSH key. Do you want to delete the saved password for \(connection.displayDestination)?")
        }
    }

    private var connectionLabel: String {
        tab.connection?.displayDestination ?? tab.title
    }

    private var selectedKey: SSHKey? {
        guard let selectedKeyId else { return nil }
        return keyStore.key(withId: selectedKeyId)
    }

    private var isInstallDisabled: Bool {
        selectedKey == nil || isInstalling || tab.session?.canOpenChannel != true
    }

    private func initializeSelectionIfNeeded() {
        guard !hasInitializedSelection else { return }
        hasInitializedSelection = true

        if let preferredKeyId = tab.connection?.sshKeyId,
           keyStore.key(withId: preferredKeyId) != nil {
            selectedKeyId = preferredKeyId
        } else if keyStore.keys.count == 1, let onlyKey = keyStore.keys.first {
            selectedKeyId = onlyKey.id
        }
    }

    private func select(_ key: SSHKey) {
        selectedKeyId = key.id
        installResult = nil
        errorMessage = nil
    }

    private func installSelectedKey() {
        guard let session = tab.session else {
            errorMessage = SSHError.notConnected.localizedDescription
            return
        }
        guard let key = selectedKey else {
            return
        }

        isInstalling = true
        installResult = nil
        errorMessage = nil

        Task { @MainActor in
            if CredentialProtectionSettings.isEnabled() {
                let authorization = await BiometricCredentialAuthorizer.authorizeStoredCredentialUse(
                    reason: "Authenticate to install an SSH key on \(connectionLabel).",
                    allowsPasscodeFallback: CredentialProtectionSettings.isPasscodeFallbackEnabled()
                )
                guard case .authorized = authorization else {
                    errorMessage = authorization.message
                    isInstalling = false
                    return
                }
            }

            do {
                let result = try await AuthorizedKeysInstaller.install(keys: [key], using: session)
                installResult = result
                isInstalling = false
                associateInstalledKeyWithConnection(key)
            } catch {
                errorMessage = error.localizedDescription
                isInstalling = false
            }
        }
    }

    private func associateInstalledKeyWithConnection(_ key: SSHKey) {
        guard let connection = tab.connection else { return }

        if connection.sshKeyId != key.id {
            connection.sshKeyId = key.id
            connectionStore.saveChanges(touching: connection)
        }

        if KeychainService.hasPassword(forConnectionId: connection.id) {
            isPromptingPasswordDelete = true
        }
    }

    private func normalizeAutoReconnectAfterPasswordDelete(for connection: SavedConnection) {
        let normalizedAutoReconnect = AutomaticReconnectPolicy.normalizedEnabled(
            for: connection,
            keyStore: keyStore,
            hasStoredPasswordOverride: false
        )
        guard connection.autoReconnectOnBackgroundDisconnect != normalizedAutoReconnect else {
            return
        }
        connection.autoReconnectOnBackgroundDisconnect = normalizedAutoReconnect
        connectionStore.saveChanges(touching: connection)
    }
}

private struct SSHKeyInstallSelectionRow: View {
    let key: SSHKey
    let isSelected: Bool

    private var palette: AppPalette { TerminalRuntime.shared.appPalette }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(isSelected ? palette.accent : palette.secondaryText)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(key.name)
                    .font(.headline)
                    .foregroundColor(palette.primaryText)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(key.keyType.displayName)
                    Text(key.fingerprint)
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundColor(palette.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
    }
}
