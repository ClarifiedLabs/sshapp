import SwiftUI
import SwiftData

/// View for managing saved SSH credentials.
struct CredentialsView: View {
    let keyStore: KeyStore
    let savedConnections: [SavedConnection]

    @Environment(\.modelContext) private var modelContext
    @State private var sheet: CredentialsSheet?
    @State private var storedPasswordConnectionIds: Set<UUID> = []
    @State private var isProtectionEnabled = false
    @State private var isPasscodeFallbackEnabled = false
    @State private var isCredentialICloudSyncConfigured = false
    @State private var isCredentialICloudSyncEnabled = false
    @State private var biometricAvailability: CredentialBiometricAvailability = .unknown
    @State private var deviceOwnerAvailability: CredentialDeviceOwnerAuthenticationAvailability = .unknown
    @State private var hasStoredCredentials = false
    @State private var isChangingCredentialICloudSync = false
    @State private var isConfirmingCredentialICloudSyncDisable = false
    @State private var isChangingProtection = false
    @State private var isAppLaunchPasscodeEnabled = false
    @State private var hasAppLaunchPasscode = false
    @State private var appLaunchGracePeriodSeconds = AppLaunchPasscodeSettings.defaultGracePeriodSeconds
    @State private var alert: CredentialAlert?

    private var palette: AppPalette { TerminalRuntime.shared.appPalette }

    var body: some View {
        List {
            Section {
                Toggle(isOn: credentialICloudSyncBinding) {
                    Text("iCloud Sync to Other Devices")
                        .foregroundStyle(isCredentialICloudSyncUnavailable ? .secondary : .primary)
                        .strikethrough(isCredentialICloudSyncUnavailable)
                }
                .disabled(isCredentialICloudSyncToggleDisabled)
                .accessibilityIdentifier("credentials.iCloudSync")

                if isChangingCredentialICloudSync {
                    ProgressView()
                        .accessibilityIdentifier("credentials.iCloudSync.progress")
                }
            } footer: {
                Text(credentialICloudSyncFooterText)
            }
            .themedListRow(palette)

            Section {
                Toggle(isOn: protectionBinding) {
                    Text("Require Face ID/Touch ID")
                        .foregroundStyle(isBiometricProtectionUnavailable ? .secondary : .primary)
                        .strikethrough(isBiometricProtectionUnavailable)
                }
                    .disabled(isProtectionToggleDisabled)
                    .accessibilityIdentifier("credentials.biometricProtection")

                if isProtectionEnabled {
                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                            .accessibilityHidden(true)

                        Toggle(isOn: passcodeFallbackBinding) {
                            Text("Fall back to device passcode")
                                .foregroundStyle(isPasscodeFallbackUnavailable ? .secondary : .primary)
                        }
                        .disabled(isPasscodeFallbackToggleDisabled)
                        .accessibilityIdentifier("credentials.passcodeFallback")
                    }
                    .padding(.leading, 18)
                }

                if isChangingProtection {
                    ProgressView()
                        .accessibilityIdentifier("credentials.biometricProtection.progress")
                }
            } header: {
                Text("Credential Protection")
            } footer: {
                Text(credentialProtectionFooterText)
            }
            .themedListRow(palette)

            Section {
                Toggle(isOn: appLaunchPasscodeBinding) {
                    Text("Require Passcode on App Launch")
                        .foregroundStyle(isAppLaunchPasscodeUnavailable ? .secondary : .primary)
                        .strikethrough(isAppLaunchPasscodeUnavailable)
                }
                    .disabled(isAppLaunchPasscodeToggleDisabled)
                    .accessibilityIdentifier("credentials.appLaunchPasscode")

                if isAppLaunchPasscodeEnabled {
                    if hasAppLaunchPasscode {
                        HStack {
                            Text("Require again after backgrounding")
                            Spacer()
                            Text(AppLaunchPasscodeSettings.gracePeriodDisplayText(appLaunchGracePeriodSeconds))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            Button {
                                sheet = .editAppLock
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Edit app lock")
                            .accessibilityIdentifier("credentials.appLaunchPasscode.edit")
                        }
                    } else {
                        HStack {
                            Text("App passcode")
                            Spacer()
                            Text("Not Available")
                                .foregroundStyle(.secondary)
                            Button {
                                sheet = .setAppLockPasscode
                            } label: {
                                Image(systemName: "plus.circle")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Set app passcode")
                            .accessibilityIdentifier("credentials.appLaunchPasscode.set")
                        }
                    }
                }
            } header: {
                Text("App Lock")
            } footer: {
                Text(appLaunchPasscodeFooterText)
            }
            .themedListRow(palette)

            Section {
                ForEach(keyStore.keys) { key in
                    Button {
                        sheet = .editKey(key)
                    } label: {
                        SSHKeyCredentialRow(
                            key: key,
                            usedConnections: connectionsUsingKey(key),
                            showsUnsyncableIndicator: isCredentialICloudSyncEnabled && !key.keyType.canSyncWithICloud
                        )
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button("Delete", role: .destructive) {
                            deleteKey(key)
                        }
                    }
                }

                Button(action: { sheet = .generateKey }) {
                    Label("Generate New Key", systemImage: "plus.circle")
                }
            } header: {
                Text("SSH Keys")
            }
            .themedListRow(palette)

            Section {
                if storedPasswordConnections.isEmpty {
                    Text("Saved passwords will appear here")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(storedPasswordConnections) { connection in
                        PasswordCredentialRow(
                            connection: connection,
                            onChange: { sheet = .changePassword(connection) },
                            onDelete: { deletePassword(for: connection) }
                        )
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                deletePassword(for: connection)
                            }
                        }
                    }
                }
            } header: {
                Text("Passwords")
            } footer: {
                Text("Saved passwords are stored in Keychain and are never displayed here.")
            }
            .themedListRow(palette)

            Section {
                LabeledContent("Biometrics", value: biometricAvailability.statusText)
                LabeledContent("SSH keys", value: "\(keyStore.keys.count)")
                LabeledContent("Saved passwords", value: "\(storedPasswordConnections.count)")
                LabeledContent("Stored credentials", value: hasStoredCredentials ? "Present" : "None")
            } header: {
                Text("Status")
            }
            .themedListRow(palette)
        }
        .themedListBackground(palette)
        .navigationTitle("Credentials")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: refreshStateKey) {
            await refreshState()
        }
        .sheet(item: $sheet) { destination in
            Group {
                switch destination {
                case .generateKey:
                    GenerateKeySheet(keyStore: keyStore)
                        .onDisappear {
                            Task { await refreshState() }
                        }
                case .editKey(let key):
                    EditSSHKeySheet(
                        keyStore: keyStore,
                        key: key,
                        usedConnections: connectionsUsingKey(key),
                        onDelete: { deleteKey(key) }
                    )
                case .changePassword(let connection):
                    ChangePasswordSheet(connection: connection) {
                        Task { await refreshState() }
                    }
                case .setAppLockPasscode:
                    AppLockPasscodeSheet(mode: .set) {
                        refreshAppLockState()
                    }
                case .editAppLock:
                    AppLockPasscodeSheet(mode: .edit) {
                        refreshAppLockState()
                    }
                case .disableAppLock:
                    AppLockPasscodeSheet(mode: .disable) {
                        KeychainService.deleteAppLockPasscode()
                        AppLaunchPasscodeSettings.setEnabled(false)
                        refreshAppLockState()
                    }
                }
            }
            .tint(palette.accent)
        }
        .alert(item: $alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .confirmationDialog(
            "Keep a local copy of credentials?",
            isPresented: $isConfirmingCredentialICloudSyncDisable,
            titleVisibility: .visible
        ) {
            Button("Keep Local Copy") {
                updateCredentialICloudSyncEnabled(false, retainLocalCopy: true)
            }
            Button("Delete From This Device", role: .destructive) {
                updateCredentialICloudSyncEnabled(false, retainLocalCopy: false)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Disabling iCloud sync stops credential settings, App Lock, syncable SSH keys, and saved passwords from syncing to other devices.")
        }
    }

    private var storedPasswordConnections: [SavedConnection] {
        savedConnections.filter { storedPasswordConnectionIds.contains($0.id) }
    }

    private var refreshStateKey: String {
        let connectionKey = savedConnections.map { connection in
            [
                connection.id.uuidString,
                connection.displayDestination,
                connection.sshKeyId?.uuidString ?? "password"
            ].joined(separator: ":")
        }
        .joined(separator: "|")

        let keyStoreKey = keyStore.keys.map { key in
            "\(key.id.uuidString):\(key.name)"
        }
        .joined(separator: "|")

        return "\(connectionKey)#\(keyStoreKey)"
    }

    private var protectionBinding: Binding<Bool> {
        Binding {
            isProtectionEnabled
        } set: { newValue in
            updateProtectionEnabled(newValue)
        }
    }

    private var passcodeFallbackBinding: Binding<Bool> {
        Binding {
            isPasscodeFallbackEnabled
        } set: { newValue in
            updatePasscodeFallbackEnabled(newValue)
        }
    }

    private var credentialICloudSyncBinding: Binding<Bool> {
        Binding {
            isCredentialICloudSyncEnabled
        } set: { newValue in
            if newValue {
                updateCredentialICloudSyncEnabled(true, retainLocalCopy: true)
            } else {
                isConfirmingCredentialICloudSyncDisable = true
            }
        }
    }

    private var appLaunchPasscodeBinding: Binding<Bool> {
        Binding {
            isAppLaunchPasscodeEnabled
        } set: { newValue in
            updateAppLaunchPasscodeEnabled(newValue)
        }
    }

    private var isBiometricProtectionUnavailable: Bool {
        !isProtectionEnabled && !CredentialProtectionSettings.canEnableProtection(for: biometricAvailability)
    }

    private var isProtectionToggleDisabled: Bool {
        isChangingProtection
            || (!isProtectionEnabled && !CredentialProtectionSettings.canEnableProtection(for: biometricAvailability))
    }

    private var isPasscodeFallbackUnavailable: Bool {
        !isPasscodeFallbackEnabled && !deviceOwnerAvailability.canAuthenticate
    }

    private var isPasscodeFallbackToggleDisabled: Bool {
        isChangingProtection
            || (!isPasscodeFallbackEnabled && !deviceOwnerAvailability.canAuthenticate)
    }

    private var isAppLaunchPasscodeUnavailable: Bool {
        false
    }

    private var isAppLaunchPasscodeToggleDisabled: Bool {
        false
    }

    private var isCredentialICloudSyncUnavailable: Bool {
        credentialICloudSyncSecurityBlocked
    }

    private var isCredentialICloudSyncToggleDisabled: Bool {
        isChangingCredentialICloudSync || credentialICloudSyncSecurityBlocked
    }

    private var credentialICloudSyncSecurityBlocked: Bool {
        CredentialProtectionSettings.isEnabled(availability: biometricAvailability)
            && !CredentialProtectionSettings.canEnableProtection(for: biometricAvailability)
    }

    private var credentialICloudSyncFooterText: String {
        if credentialICloudSyncSecurityBlocked {
            return "Face ID/Touch ID needs to be set up first because synced credentials require biometric protection."
        }

        if isCredentialICloudSyncEnabled {
            return "Credential settings, App Lock, Ed25519 SSH keys, and saved passwords sync to your other devices. Secure Enclave keys stay on this device."
        }

        if isCredentialICloudSyncConfigured {
            return "iCloud sync is configured for credentials, but it is off on this device."
        }

        return "Credential settings, App Lock, SSH keys, and saved passwords stay on this device."
    }

    private var credentialProtectionFooterText: String {
        if !isProtectionEnabled,
           !CredentialProtectionSettings.canEnableProtection(for: biometricAvailability) {
            if biometricAvailability == .notAvailable {
                return "Face ID or Touch ID is unavailable on this device."
            }

            return "Set up Face ID or Touch ID to enable saved credential protection."
        }

        if isProtectionEnabled && isPasscodeFallbackEnabled {
            return "Saved passwords and SSH keys require Face ID or Touch ID before use, with device passcode as a fallback."
        }

        if isProtectionEnabled && !deviceOwnerAvailability.canAuthenticate {
            return "Saved passwords and SSH keys require Face ID or Touch ID before use. Set a device passcode to enable fallback."
        }

        if isProtectionEnabled {
            return "Saved passwords and SSH keys require Face ID or Touch ID before use."
        }

        return "Saved passwords and SSH keys can be used without Face ID or Touch ID."
    }

    private var appLaunchPasscodeFooterText: String {
        if isAppLaunchPasscodeEnabled {
            guard hasAppLaunchPasscode else {
                if isCredentialICloudSyncEnabled {
                    return "App Lock is enabled, but no app passcode is available on this device yet. It will lock after the passcode arrives from iCloud Keychain or you set one here."
                }

                return "App Lock is enabled, but no app passcode is set on this device yet."
            }

            let timeoutText = AppLaunchPasscodeSettings.clampedGracePeriod(appLaunchGracePeriodSeconds) == 0
                ? "immediately"
                : "after \(AppLaunchPasscodeSettings.gracePeriodDisplayText(appLaunchGracePeriodSeconds))"
            return "Opening SSH App requires the app passcode. Returning from the background requires it again \(timeoutText)."
        }

        return "Opening SSH App does not require an app passcode. This setting is independent of saved credential protection."
    }

    @MainActor
    private func refreshState() async {
        let availability = BiometricCredentialAuthorizer.biometricAvailability()
        let deviceAvailability = BiometricCredentialAuthorizer.deviceOwnerAuthenticationAvailability()
        keyStore.loadKeys()
        let connectionIds = savedConnections.map(\.id)
        let passwordIds = await Task.detached(priority: .userInitiated) {
            Set(connectionIds.filter { KeychainService.hasPassword(forConnectionId: $0) })
        }.value
        let credentialsExist = await Task.detached(priority: .userInitiated) {
            KeychainService.hasStoredCredentials()
        }.value

        biometricAvailability = availability
        deviceOwnerAvailability = deviceAvailability
        isCredentialICloudSyncConfigured = CredentialICloudSyncSettings.isConfiguredEnabled()
        isCredentialICloudSyncEnabled = CredentialICloudSyncSettings.isEnabled(availability: availability)
        isProtectionEnabled = CredentialProtectionSettings.isEnabled(availability: availability)
        isPasscodeFallbackEnabled = CredentialProtectionSettings.isPasscodeFallbackEnabled()
        isAppLaunchPasscodeEnabled = AppLaunchPasscodeSettings.isEnabled()
        hasAppLaunchPasscode = KeychainService.hasAppLockPasscode()
        appLaunchGracePeriodSeconds = AppLaunchPasscodeSettings.gracePeriodSeconds()
        storedPasswordConnectionIds = passwordIds
        hasStoredCredentials = credentialsExist
    }

    private func refreshAppLockState() {
        isAppLaunchPasscodeEnabled = AppLaunchPasscodeSettings.isEnabled()
        hasAppLaunchPasscode = KeychainService.hasAppLockPasscode()
        appLaunchGracePeriodSeconds = AppLaunchPasscodeSettings.gracePeriodSeconds()
    }

    private func updateCredentialICloudSyncEnabled(_ newValue: Bool, retainLocalCopy: Bool) {
        guard newValue != isCredentialICloudSyncEnabled || isCredentialICloudSyncConfigured != newValue else {
            return
        }

        if newValue, credentialICloudSyncSecurityBlocked {
            alert = CredentialAlert(
                title: "Credentials",
                message: "Face ID/Touch ID needs to be set up first because synced credentials require biometric protection."
            )
            return
        }

        Task { @MainActor in
            guard !isChangingCredentialICloudSync else {
                return
            }

            isChangingCredentialICloudSync = true
            defer { isChangingCredentialICloudSync = false }

            do {
                if newValue {
                    try CredentialICloudSyncService.enable(keyStore: keyStore)
                } else {
                    try CredentialICloudSyncService.disable(
                        keyStore: keyStore,
                        retainLocalCopy: retainLocalCopy
                    )
                }
                await refreshState()
            } catch {
                alert = CredentialAlert(title: "iCloud Sync", message: error.localizedDescription)
                await refreshState()
            }
        }
    }

    private func updateProtectionEnabled(_ newValue: Bool) {
        guard newValue != isProtectionEnabled else {
            return
        }

        if newValue {
            guard CredentialProtectionSettings.canEnableProtection(for: biometricAvailability) else {
                alert = CredentialAlert(
                    title: "Credentials",
                    message: "Set up Face ID or Touch ID before enabling saved credential protection."
                )
                return
            }

            CredentialProtectionSettings.setEnabled(true)
            isProtectionEnabled = true
            return
        }

        Task {
            await disableProtection()
        }
    }

    private func updatePasscodeFallbackEnabled(_ newValue: Bool) {
        guard newValue != isPasscodeFallbackEnabled else {
            return
        }

        if newValue {
            guard isProtectionEnabled else {
                alert = CredentialAlert(
                    title: "Credentials",
                    message: "Enable Face ID or Touch ID protection before adding a passcode fallback."
                )
                return
            }

            guard deviceOwnerAvailability.canAuthenticate else {
                alert = CredentialAlert(
                    title: "Credentials",
                    message: "Set a device passcode before enabling passcode fallback."
                )
                return
            }
        }

        CredentialProtectionSettings.setPasscodeFallbackEnabled(newValue)
        isPasscodeFallbackEnabled = newValue
    }

    private func updateAppLaunchPasscodeEnabled(_ newValue: Bool) {
        guard newValue != isAppLaunchPasscodeEnabled else {
            return
        }

        if newValue {
            sheet = .setAppLockPasscode
            return
        }

        if KeychainService.hasAppLockPasscode() {
            sheet = .disableAppLock
        } else {
            AppLaunchPasscodeSettings.setEnabled(false)
            isAppLaunchPasscodeEnabled = false
        }
    }

    @MainActor
    private func disableProtection() async {
        guard !isChangingProtection else {
            return
        }

        isChangingProtection = true
        defer { isChangingProtection = false }

        let latestAvailability = BiometricCredentialAuthorizer.biometricAvailability()
        biometricAvailability = latestAvailability
        let credentialsExist = await Task.detached(priority: .userInitiated) {
            KeychainService.hasStoredCredentials()
        }.value
        hasStoredCredentials = credentialsExist

        let requirement = CredentialProtectionSettings.disableAuthorizationRequirement(
            hasStoredCredentials: credentialsExist,
            availability: latestAvailability
        )

        let result: CredentialAuthorizationResult
        switch requirement {
        case .none:
            result = .authorized
        case .biometrics:
            result = await BiometricCredentialAuthorizer.authorizeSettingsChangeWithBiometrics(
                reason: "Disable biometric protection for saved SSH credentials."
            )
        case .deviceOwner:
            result = await BiometricCredentialAuthorizer.authorizeSettingsChangeWithDeviceOwner(
                reason: "Disable saved SSH credential protection."
            )
        }

        guard result.isAuthorized else {
            alert = CredentialAlert(
                title: "Credentials",
                message: result.message ?? "Authentication is required to change this setting."
            )
            return
        }

        CredentialProtectionSettings.setEnabled(false)
        CredentialProtectionSettings.setPasscodeFallbackEnabled(false)
        isProtectionEnabled = false
        isPasscodeFallbackEnabled = false
    }

    private func connectionsUsingKey(_ key: SSHKey) -> [SavedConnection] {
        savedConnections.filter { $0.sshKeyId == key.id }
    }

    private func deleteKey(_ key: SSHKey) {
        do {
            try keyStore.deleteKey(key)
            for connection in savedConnections where connection.sshKeyId == key.id {
                connection.sshKeyId = nil
                connection.updatedAt = Date()
                ConnectionSyncStore.shared.save(connection)
            }
            try? modelContext.save()
            Task { await refreshState() }
        } catch {
            alert = CredentialAlert(title: "Could Not Delete Key", message: error.localizedDescription)
        }
    }

    private func deletePassword(for connection: SavedConnection) {
        KeychainService.deletePassword(forConnectionId: connection.id)
        storedPasswordConnectionIds.remove(connection.id)
        Task { await refreshState() }
    }
}

private enum CredentialsSheet: Identifiable {
    case generateKey
    case editKey(SSHKey)
    case changePassword(SavedConnection)
    case setAppLockPasscode
    case editAppLock
    case disableAppLock

    var id: String {
        switch self {
        case .generateKey:
            return "generate-key"
        case .editKey(let key):
            return "edit-key-\(key.id.uuidString)"
        case .changePassword(let connection):
            return "change-password-\(connection.id.uuidString)"
        case .setAppLockPasscode:
            return "set-app-lock-passcode"
        case .editAppLock:
            return "edit-app-lock"
        case .disableAppLock:
            return "disable-app-lock"
        }
    }
}

private struct CredentialAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// Row displaying a single SSH key.
private struct SSHKeyCredentialRow: View {
    let key: SSHKey
    let usedConnections: [SavedConnection]
    let showsUnsyncableIndicator: Bool

    private var palette: AppPalette { TerminalRuntime.shared.appPalette }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(key.name)
                    .font(.headline)

                Spacer()

                Text(key.keyType.displayName)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(palette.accentChip)
                    .cornerRadius(4)

                if showsUnsyncableIndicator {
                    Image(systemName: "icloud.slash")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Not synced with iCloud")
                        .help("Secure Enclave keys do not sync with iCloud")
                }
            }

            // Fingerprint (truncated for display)
            Text(truncatedFingerprint)
                .font(.caption)
                .foregroundColor(palette.secondaryText)
                .lineLimit(1)

            // Created date
            Text("Created \(key.createdAt.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption2)
                .foregroundColor(palette.secondaryText)

            Text(usageSummary)
                .font(.caption)
                .foregroundColor(palette.secondaryText)
                .lineLimit(2)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var truncatedFingerprint: String {
        // Show abbreviated fingerprint
        let fingerprint = key.fingerprint
        if fingerprint.count > 30 {
            return String(fingerprint.prefix(30)) + "..."
        }
        return fingerprint
    }

    private var usageSummary: String {
        switch usedConnections.count {
        case 0:
            return "Not used by saved hosts"
        case 1:
            return "Used by \(usedConnections[0].displayDestination)"
        default:
            let visibleHosts = usedConnections.prefix(3).map(\.displayDestination).joined(separator: ", ")
            let remainingCount = usedConnections.count - 3
            if remainingCount > 0 {
                return "Used by \(visibleHosts), and \(remainingCount) more"
            }
            return "Used by \(visibleHosts)"
        }
    }
}

private struct PasswordCredentialRow: View {
    let connection: SavedConnection
    let onChange: () -> Void
    let onDelete: () -> Void

    private var palette: AppPalette { TerminalRuntime.shared.appPalette }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(connection.displayDestination)
                    .font(.headline)
                    .foregroundColor(palette.primaryText)
                    .lineLimit(1)

                Text("Saved password")
                    .font(.caption)
                    .foregroundColor(palette.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Change", action: onChange)
                .buttonStyle(.borderless)
                .accessibilityLabel("Change password for \(connection.displayDestination)")

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 15, weight: .medium))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Delete password for \(connection.displayDestination)")
        }
        .padding(.vertical, 4)
    }
}

private struct EditSSHKeySheet: View {
    let keyStore: KeyStore
    let key: SSHKey
    let usedConnections: [SavedConnection]
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var keyName: String
    @State private var errorMessage: String?
    @State private var showCopyAlert = false
    @State private var showDeleteConfirmation = false

    private var palette: AppPalette { TerminalRuntime.shared.appPalette }

    init(keyStore: KeyStore, key: SSHKey, usedConnections: [SavedConnection], onDelete: @escaping () -> Void) {
        self.keyStore = keyStore
        self.key = key
        self.usedConnections = usedConnections
        self.onDelete = onDelete
        _keyName = State(initialValue: key.name)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Key Name", text: $keyName)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                }
                .themedListRow(palette)

                Section("Public Key") {
                    Button {
                        UIPasteboard.general.string = key.publicKey
                        showCopyAlert = true
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Text(key.publicKey)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(palette.secondaryText)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(palette.accent)
                                .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Copy Public Key")
                }
                .themedListRow(palette)

                Section("Used By") {
                    if usedConnections.isEmpty {
                        Text("Not used by saved hosts")
                            .foregroundColor(palette.secondaryText)
                    } else {
                        ForEach(usedConnections) { connection in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(connection.displayDestination)
                                    .foregroundColor(palette.primaryText)
                                if let username = connection.username {
                                    Text(username)
                                        .font(.caption)
                                        .foregroundColor(palette.secondaryText)
                                }
                            }
                        }
                    }
                }
                .themedListRow(palette)

                Section("Key Details") {
                    LabeledContent("Type", value: key.keyType.displayName)
                    LabeledContent("Created", value: key.createdAt.formatted(date: .abbreviated, time: .omitted))
                    Text(key.fingerprint)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(palette.secondaryText)
                        .textSelection(.enabled)
                }
                .themedListRow(palette)

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundColor(palette.error)
                    }
                    .themedListRow(palette)
                }

                Section {
                    Button("Delete Key", role: .destructive) {
                        showDeleteConfirmation = true
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("editSSHKey.delete")
                }
                .themedListRow(palette)
            }
            .themedListBackground(palette)
            .navigationTitle("Edit SSH Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save", action: save)
                        .disabled(isSaveDisabled)
                }
            }
            .alert("Public Key Copied", isPresented: $showCopyAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("The public key for '\(key.name)' has been copied to clipboard.")
            }
            .confirmationDialog(
                "Delete '\(key.name)'?",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete Key", role: .destructive) {
                    dismiss()
                    onDelete()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(deleteConfirmationMessage)
            }
        }
        .presentationSizing(.page)
    }

    private var trimmedKeyName: String {
        keyName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSaveDisabled: Bool {
        trimmedKeyName.isEmpty || trimmedKeyName == key.name
    }

    private var deleteConfirmationMessage: String {
        if usedConnections.isEmpty {
            return "The private key will be permanently deleted. This cannot be undone."
        }

        let hostList = usedConnections.map(\.displayDestination).joined(separator: ", ")
        return "This key is used by \(hostList). Those hosts will fall back to password authentication. The private key will be permanently deleted. This cannot be undone."
    }

    private func save() {
        do {
            _ = try keyStore.renameKey(key, to: trimmedKeyName)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ChangePasswordSheet: View {
    let connection: SavedConnection
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var isPasswordVisible = false
    @State private var errorMessage: String?

    private var palette: AppPalette { TerminalRuntime.shared.appPalette }

    var body: some View {
        NavigationStack {
            Form {
                Section("Host") {
                    LabeledContent("Connection", value: connection.displayDestination)
                }
                .themedListRow(palette)

                Section {
                    HStack {
                        Group {
                            if isPasswordVisible {
                                TextField("Password", text: $password)
                            } else {
                                SecureField("Password", text: $password)
                            }
                        }
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                        Button {
                            isPasswordVisible.toggle()
                        } label: {
                            Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(isPasswordVisible ? "Hide password" : "Show password")
                    }
                } header: {
                    Text("New Password")
                } footer: {
                    Text("The current password is not shown.")
                }
                .themedListRow(palette)

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundColor(palette.error)
                    }
                    .themedListRow(palette)
                }
            }
            .themedListBackground(palette)
            .navigationTitle("Change Password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save", action: save)
                        .disabled(isSaveDisabled)
                }
            }
        }
    }

    private var isSaveDisabled: Bool {
        password.isEmpty
    }

    private func save() {
        do {
            try KeychainService.savePassword(password, forConnectionId: connection.id)
            onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private enum AppLockPasscodeSheetMode {
    case set
    case edit
    case disable

    var title: String {
        switch self {
        case .set:
            return "Set App Passcode"
        case .edit:
            return "Edit App Lock"
        case .disable:
            return "Disable App Lock"
        }
    }

    var currentPasscodeSectionTitle: String {
        switch self {
        case .set:
            return "App Passcode"
        case .edit:
            return "Current App Passcode"
        case .disable:
            return "Current App Passcode"
        }
    }

    var currentPasscodeFooterText: String {
        switch self {
        case .set:
            return "This passcode is only for SSH App."
        case .edit:
            return "Enter the app passcode before editing App Lock."
        case .disable:
            return "Enter the app passcode to turn off App Lock."
        }
    }
}

private struct AppLockPasscodeSheet: View {
    let mode: AppLockPasscodeSheetMode
    let onComplete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var currentPasscode = ""
    @State private var newPasscode = ""
    @State private var isPasscodeVisible = false
    @State private var hasVerifiedCurrentPasscode = false
    @State private var isEditingPasscode = false
    @State private var gracePeriodSeconds: Double
    @State private var errorMessage: String?
    @FocusState private var focusedField: AppLockPasscodeFocusedField?

    private var palette: AppPalette { TerminalRuntime.shared.appPalette }

    init(mode: AppLockPasscodeSheetMode, onComplete: @escaping () -> Void) {
        self.mode = mode
        self.onComplete = onComplete
        _gracePeriodSeconds = State(
            initialValue: AppLaunchPasscodeSettings.gracePeriodSeconds()
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                if shouldRequestCurrentPasscode {
                    currentPasscodeSection
                } else {
                    switch mode {
                    case .set:
                        newPasscodeSection(
                            title: "App Passcode",
                            footer: "This passcode is only for SSH App."
                        )
                        gracePeriodSection
                    case .edit:
                        Section {
                            HStack {
                                Text("App passcode")
                                Spacer()
                                Text(isEditingPasscode ? "Changing" : "Change")
                                    .foregroundStyle(.secondary)
                                Button {
                                    isEditingPasscode = true
                                    Task {
                                        await Task.yield()
                                        focusedField = .newPasscode
                                    }
                                } label: {
                                    Image(systemName: "pencil")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Change app passcode")
                                .accessibilityIdentifier("appLockPasscode.change")
                            }

                            if isEditingPasscode {
                                newPasscodeField
                            }
                        } header: {
                            Text("App Passcode")
                        }
                        .themedListRow(palette)

                        gracePeriodSection
                    case .disable:
                        EmptyView()
                    }
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
            .navigationTitle(mode.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button(actionTitle, action: submit)
                        .disabled(isSubmitDisabled)
                }
            }
            .task {
                await Task.yield()
                focusedField = mode == .set ? .newPasscode : .currentPasscode
            }
        }
    }

    private var currentPasscodeSection: some View {
        Section {
            passcodeField(
                "Passcode",
                text: $currentPasscode,
                isVisible: false,
                field: .currentPasscode,
                allowsReveal: false,
                submitLabel: mode == .edit ? .continue : .done,
                onSubmit: mode == .edit ? { submit() } : nil
            )
        } header: {
            Text(mode.currentPasscodeSectionTitle)
        } footer: {
            Text(mode.currentPasscodeFooterText)
        }
        .themedListRow(palette)
    }

    private func newPasscodeSection(title: String, footer: String) -> some View {
        Section {
            newPasscodeField
        } header: {
            Text(title)
        } footer: {
            Text(footer)
        }
        .themedListRow(palette)
    }

    private var newPasscodeField: some View {
        passcodeField(
            "Passcode",
            text: $newPasscode,
            isVisible: isPasscodeVisible,
            field: .newPasscode,
            allowsReveal: true
        )
    }

    private var gracePeriodSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Require again after backgrounding")
                    Spacer()
                    Text(AppLaunchPasscodeSettings.gracePeriodDisplayText(gracePeriodSeconds))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Slider(
                    value: $gracePeriodSeconds,
                    in: AppLaunchPasscodeSettings.gracePeriodRange,
                    step: AppLaunchPasscodeSettings.gracePeriodStep
                )
                .accessibilityIdentifier("credentials.appLaunchPasscode.gracePeriod")
            }
        } header: {
            Text("Background Timeout")
        }
        .themedListRow(palette)
    }

    private func passcodeField(
        _ placeholder: String,
        text: Binding<String>,
        isVisible: Bool,
        field: AppLockPasscodeFocusedField,
        allowsReveal: Bool,
        submitLabel: SubmitLabel = .done,
        onSubmit: (() -> Void)? = nil
    ) -> some View {
        HStack {
            Group {
                if isVisible {
                    TextField(placeholder, text: text)
                } else {
                    SecureField(placeholder, text: text)
                }
            }
            .textContentType(.password)
            .submitLabel(submitLabel)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($focusedField, equals: field)
            .onSubmit {
                onSubmit?()
            }

            if allowsReveal {
                Button {
                    isPasscodeVisible.toggle()
                } label: {
                    Image(systemName: isPasscodeVisible ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(isPasscodeVisible ? "Hide passcode" : "Show passcode")
            }
        }
    }

    private var shouldRequestCurrentPasscode: Bool {
        switch mode {
        case .set:
            return false
        case .edit:
            return !hasVerifiedCurrentPasscode
        case .disable:
            return true
        }
    }

    private var actionTitle: String {
        switch mode {
        case .set:
            return "Enable"
        case .edit:
            return hasVerifiedCurrentPasscode ? "Save" : "Continue"
        case .disable:
            return "Disable"
        }
    }

    private var isSubmitDisabled: Bool {
        switch mode {
        case .set:
            return !AppLockPasscodePolicy.isValid(newPasscode)
        case .edit:
            if !hasVerifiedCurrentPasscode {
                return currentPasscode.isEmpty
            }
            return isEditingPasscode && !AppLockPasscodePolicy.isValid(newPasscode)
        case .disable:
            return currentPasscode.isEmpty
        }
    }

    private func submit() {
        guard !isSubmitDisabled else {
            return
        }

        switch mode {
        case .set:
            if let validationMessage = AppLockPasscodePolicy.validationMessage(passcode: newPasscode) {
                errorMessage = validationMessage
                return
            }

            do {
                try KeychainService.saveAppLockPasscode(newPasscode)
                AppLaunchPasscodeSettings.setGracePeriodSeconds(gracePeriodSeconds)
                AppLaunchPasscodeSettings.setEnabled(true)
                onComplete()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        case .edit:
            if !hasVerifiedCurrentPasscode {
                guard KeychainService.verifyAppLockPasscode(currentPasscode) else {
                    errorMessage = "Incorrect app passcode."
                    currentPasscode = ""
                    return
                }

                errorMessage = nil
                currentPasscode = ""
                hasVerifiedCurrentPasscode = true
                return
            }

            if isEditingPasscode {
                if let validationMessage = AppLockPasscodePolicy.validationMessage(passcode: newPasscode) {
                    errorMessage = validationMessage
                    return
                }

                do {
                    try KeychainService.saveAppLockPasscode(newPasscode)
                } catch {
                    errorMessage = error.localizedDescription
                    return
                }
            }

            AppLaunchPasscodeSettings.setGracePeriodSeconds(gracePeriodSeconds)
            onComplete()
            dismiss()
        case .disable:
            guard KeychainService.verifyAppLockPasscode(currentPasscode) else {
                errorMessage = "Incorrect app passcode."
                currentPasscode = ""
                return
            }

            onComplete()
            dismiss()
        }
    }
}

private enum AppLockPasscodeFocusedField: Hashable {
    case currentPasscode
    case newPasscode
}

@MainActor
enum GeneratedSSHKeyCopyAction {
    static func copyPublicKey(
        _ publicKey: String,
        writeToPasteboard: (String) -> Void = { UIPasteboard.general.string = $0 },
        dismiss: () -> Void
    ) {
        writeToPasteboard(publicKey)
        dismiss()
    }
}

/// Sheet for generating a new SSH key
struct GenerateKeySheet: View {
    let keyStore: KeyStore
    let onGenerated: (SSHKey) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var keyName = ""
    @State private var selectedKeyType: SSHKey.KeyType
    @State private var isGenerating = false
    @State private var generatedKey: SSHKey?
    @State private var errorMessage: String?

    private let keyTypes: [SSHKey.KeyType] = [.secureEnclaveECDSA, .ed25519]
    private var palette: AppPalette { TerminalRuntime.shared.appPalette }

    init(keyStore: KeyStore, onGenerated: @escaping (SSHKey) -> Void = { _ in }) {
        self.keyStore = keyStore
        self.onGenerated = onGenerated
        _selectedKeyType = State(initialValue: SSHKeyGenerator.defaultKeyType)
    }

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    if let generatedKey {
                        // Success state
                        Section("Key Generated") {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(palette.success)
                                    Text(generatedKey.name)
                                        .font(.headline)
                                }

                                Text(generatedKey.keyType.displayName)
                                    .font(.caption)
                                    .foregroundColor(palette.secondaryText)

                                Text("Fingerprint:")
                                    .font(.caption)
                                    .foregroundColor(palette.secondaryText)
                                Text(generatedKey.fingerprint)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(palette.secondaryText)
                            }
                        }

                        Section("Public Key") {
                            Text(generatedKey.publicKey)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }

                        Section {
                            Button("Copy Public Key") {
                                GeneratedSSHKeyCopyAction.copyPublicKey(generatedKey.publicKey) {
                                    dismiss()
                                }
                            }

                            Button("Done") {
                                dismiss()
                            }
                        }
                    } else {
                        // Input state
                        Section("Key Name") {
                            TextField("e.g., work-laptop", text: $keyName)
                                .autocapitalization(.none)
                                .autocorrectionDisabled()
                        }

                        Section {
                            Picker("Type", selection: $selectedKeyType) {
                                ForEach(keyTypes, id: \.rawValue) { keyType in
                                    Text(keyType.displayName)
                                        .tag(keyType)
                                        .disabled(!SSHKeyGenerator.isAvailable(keyType))
                                }
                            }
                        } header: {
                            Text("Key Type")
                        } footer: {
                            Text(keyTypeDescription)
                        }

                        Section {
                            Text(storageDescription)
                                .font(.caption)
                                .foregroundColor(palette.secondaryText)
                        }

                        if let errorMessage {
                            Section {
                                Text(errorMessage)
                                    .foregroundColor(palette.error)
                            }
                        }

                        Section {
                            Button(action: generateKey) {
                                if isGenerating {
                                    HStack {
                                        ProgressView()
                                        Text("Generating...")
                                    }
                                } else {
                                    Text("Generate Key")
                                }
                            }
                            .disabled(isGenerateDisabled)
                        }
                    }
                }
                .themedListRow(palette)
            }
            .themedListBackground(palette)
            .navigationTitle("Generate SSH Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if generatedKey == nil {
                        Button("Cancel") {
                            dismiss()
                        }
                    }
                }
            }
        }
    }

    private var trimmedKeyName: String {
        keyName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isGenerateDisabled: Bool {
        trimmedKeyName.isEmpty || isGenerating || !SSHKeyGenerator.isAvailable(selectedKeyType)
    }

    private var keyTypeDescription: String {
        if selectedKeyType == .secureEnclaveECDSA, !SSHKeyGenerator.isAvailable(selectedKeyType) {
            return CredentialICloudSyncSettings.isEnabledForCurrentDevice()
                ? "Secure Enclave is not available on this device. iCloud Ed25519 remains available."
                : "Secure Enclave is not available on this device. Ed25519 remains available."
        }
        if CredentialICloudSyncSettings.isEnabledForCurrentDevice() {
            return "Secure Enclave ECDSA is device-only and non-exportable. Ed25519 syncs through iCloud Keychain."
        }
        return "Secure Enclave ECDSA is device-only and non-exportable. Ed25519 stays on this device."
    }

    private var storageDescription: String {
        switch selectedKeyType {
        case .secureEnclaveECDSA:
            return "A new ECDSA key pair will be generated in Secure Enclave. The private key is non-exportable and stays on this device."
        case .ed25519:
            if CredentialICloudSyncSettings.isEnabledForCurrentDevice() {
                return "A new Ed25519 key pair will be generated. The private key is stored in iCloud Keychain and can sync to your Apple devices."
            }
            return "A new Ed25519 key pair will be generated. The private key is stored in Keychain on this device."
        }
    }

    private func generateKey() {
        isGenerating = true
        errorMessage = nil

        Task {
            do {
                let key = try keyStore.generateKey(name: trimmedKeyName, keyType: selectedKeyType)
                await MainActor.run {
                    onGenerated(key)
                    generatedKey = key
                    isGenerating = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isGenerating = false
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        CredentialsView(keyStore: KeyStore(), savedConnections: [])
    }
    .modelContainer(for: SavedConnection.self, inMemory: true)
}
