import SwiftUI

/// Combined post-login dialog offering to save the newly-typed username
/// and/or password. Shown once per successful login instead of separate
/// save-username and save-password alerts.
struct CredentialSaveSheet: View {
    let rows: CredentialSaveRows
    let username: String?
    let hostLabel: String
    let connectionLabel: String
    let onResolve: (CredentialSaveDecision) -> Void

    @State private var saveUsername = false
    @State private var savePassword = false

    /// The password toggle is gated on the username toggle unless a username
    /// is already saved for this connection.
    private var passwordEnabled: Bool {
        guard rows.showPasswordRow else { return false }
        return rows.passwordDependsOnUsername ? saveUsername : true
    }

    private var canSave: Bool {
        (rows.showUsernameRow && saveUsername) || (passwordEnabled && savePassword)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if rows.showUsernameRow {
                        Toggle(isOn: $saveUsername) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Save Username")
                                if let username {
                                    Text(username)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .accessibilityIdentifier("credentialSave.username")
                    }
                    if rows.showPasswordRow {
                        Toggle(isOn: $savePassword) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Save Password")
                                Text(passwordStorageText)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .disabled(!passwordEnabled)
                        .accessibilityIdentifier("credentialSave.password")
                    }
                } footer: {
                    Text("Saved credentials are used automatically the next time you connect to \(connectionLabel).")
                }

                Section {
                    Button("Don't Ask Again", role: .destructive) {
                        onResolve(.neverAsking(rows: rows))
                    }
                    .accessibilityIdentifier("credentialSave.neverAsk")
                }
            }
            .onChange(of: saveUsername) { _, isOn in
                if !isOn && rows.passwordDependsOnUsername {
                    savePassword = false
                }
            }
            .navigationTitle("Save Credentials?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not Now") {
                        onResolve(.declined)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onResolve(.saving(
                            username: rows.showUsernameRow && saveUsername,
                            password: passwordEnabled && savePassword
                        ))
                    }
                    .disabled(!canSave)
                }
            }
        }
    }

    private var passwordStorageText: String {
        CredentialICloudSyncSettings.isEnabledForCurrentDevice()
            ? "Stored in iCloud Keychain"
            : "Stored on this device"
    }
}
