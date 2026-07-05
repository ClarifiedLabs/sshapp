import SwiftUI
import SwiftData

/// Sheet for creating or editing an SSH connection.
struct ConnectionSheet: View {
    let connectionStore: ConnectionStore
    let keyStore: KeyStore
    let editingConnection: SavedConnection?
    let onConnect: (SavedConnection) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingDelete = false

    // New connection form fields
    @State private var destination = ""
    @State private var port = "22"
    @State private var selectedKeyId: UUID?
    @State private var autoReconnectOnBackgroundDisconnect = false
    @State private var hasStoredPassword = false
    @State private var autoRunCommandEnabled = false
    @State private var autoRunCommand = SavedConnection.defaultAutoRunCommand

    // Per-host tmux overrides for the new connection
    @State private var tmuxBackfillOverride: TmuxOverride = .inherit
    @State private var tmuxPauseModeOverride: TmuxOverride = .inherit
    @FocusState private var isDestinationFocused: Bool

    init(
        connectionStore: ConnectionStore,
        keyStore: KeyStore,
        editingConnection: SavedConnection? = nil,
        onConnect: @escaping (SavedConnection) -> Void
    ) {
        self.connectionStore = connectionStore
        self.keyStore = keyStore
        self.editingConnection = editingConnection
        self.onConnect = onConnect

        _destination = State(initialValue: editingConnection?.destinationFieldValue ?? "")
        _port = State(initialValue: editingConnection.map { String($0.port) } ?? "22")
        _selectedKeyId = State(initialValue: editingConnection?.sshKeyId)
        _autoReconnectOnBackgroundDisconnect = State(initialValue: editingConnection?.autoReconnectOnBackgroundDisconnect ?? false)
        _hasStoredPassword = State(initialValue: editingConnection.map { KeychainService.hasPassword(forConnectionId: $0.id) } ?? false)
        _autoRunCommandEnabled = State(initialValue: editingConnection?.autoRunCommandEnabled ?? false)
        _autoRunCommand = State(initialValue: editingConnection?.autoRunCommand ?? SavedConnection.defaultAutoRunCommand)
        _tmuxBackfillOverride = State(initialValue: TmuxOverride(boolValue: editingConnection?.tmuxBackfillOverride))
        _tmuxPauseModeOverride = State(initialValue: TmuxOverride(boolValue: editingConnection?.tmuxPauseModeOverride))
    }

    private var palette: AppPalette { TerminalRuntime.shared.appPalette }

    var body: some View {
        NavigationStack {
            List {
                Section(editingConnection == nil ? "New Connection" : "Connection") {
                    TextField("Destination", text: $destination, prompt: Text("[user@]hostname"))
                        .textContentType(.URL)
                        .autocapitalization(.none)
                        .keyboardType(.URL)
                        .focused($isDestinationFocused)
                        .accessibilityIdentifier("connection.destination")

                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("connection.port")

                    Picker("SSH Key", selection: $selectedKeyId) {
                        Text("None").tag(nil as UUID?)
                        ForEach(keyStore.keys) { key in
                            Text("\(key.name) (\(key.keyType.displayName))").tag(key.id as UUID?)
                        }
                    }
                }
                .themedListRow(palette)

                Section {
                    Toggle("Automatically reconnect after background disconnect", isOn: $autoReconnectOnBackgroundDisconnect)
                        .disabled(!autoReconnectIsEligible)
                        .accessibilityIdentifier("connection.autoReconnectAfterBackgroundDisconnect")
                } footer: {
                    Text(autoReconnectFooterText)
                }
                .themedListRow(palette)

                Section {
                    Toggle("Automatically run command after connecting?", isOn: $autoRunCommandEnabled)
                        .accessibilityIdentifier("connection.autoRunCommand.enabled")

                    TextEditor(text: $autoRunCommand)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 96)
                        .accessibilityIdentifier("connection.autoRunCommand.text")
                } header: {
                    Text("Startup Command")
                } footer: {
                    Text("When enabled, this command is sent after the initial shell opens. The command remains editable while disabled.")
                }
                .themedListRow(palette)

                Section("Tmux (per-host)") {
                    Picker("Scrollback Backfill", selection: $tmuxBackfillOverride) {
                        ForEach(TmuxOverride.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Pause-mode", selection: $tmuxPauseModeOverride) {
                        ForEach(TmuxOverride.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
                .themedListRow(palette)

                if editingConnection != nil {
                    Section {
                        Button(role: .destructive, action: confirmDeleteConnection) {
                            Label("Delete Connection", systemImage: "trash")
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                        .accessibilityIdentifier("connection.delete")
                    }
                    .listRowBackground(palette.surface)
                }
            }
            .themedListBackground(palette)
            .navigationTitle(editingConnection == nil ? "New Connection" : "Edit Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Save", action: save)
                        .disabled(!isFormValid)
                        .accessibilityIdentifier("connection.save")

                    Button("Connect", action: connect)
                        .fontWeight(.semibold)
                        .disabled(!isFormValid)
                        .accessibilityIdentifier("connection.connect")
                }
            }
            .alert("Delete Connection?", isPresented: $isConfirmingDelete, presenting: editingConnection) { connection in
                Button("Delete", role: .destructive) {
                    deleteEditingConnection(connection)
                }
                Button("Cancel", role: .cancel) {}
            } message: { connection in
                Text("This removes \(connection.displayDestination) and any saved password.")
            }
            .onAppear {
                isDestinationFocused = editingConnection == nil
                if !autoReconnectIsEligible {
                    autoReconnectOnBackgroundDisconnect = false
                }
            }
            .onChange(of: autoReconnectIsEligible) { _, isEligible in
                if !isEligible {
                    autoReconnectOnBackgroundDisconnect = false
                }
            }
        }
    }

    private var isFormValid: Bool {
        parsedDestination != nil && parsedPort != nil
    }

    private var parsedDestination: ConnectionDestination? {
        ConnectionDestination.parse(destination)
    }

    private var hasUsableSelectedKey: Bool {
        selectedKeyId.flatMap { keyStore.key(withId: $0) } != nil
    }

    private var hasStoredPasswordForCurrentIdentity: Bool {
        guard let editingConnection,
              let parsedDestination,
              let parsedPort else {
            return false
        }
        return hasStoredPassword
            && !connectionIdentityChanged(
                for: editingConnection,
                destination: parsedDestination,
                parsedPort: parsedPort
            )
    }

    private var autoReconnectIsEligible: Bool {
        AutomaticReconnectPolicy.isEligible(
            username: parsedDestination?.username,
            hasStoredPassword: hasStoredPasswordForCurrentIdentity,
            hasUsableKey: hasUsableSelectedKey
        )
    }

    private var autoReconnectFooterText: String {
        let base = "Opens a fresh connection after this app returns from a background disconnect. It uses only saved credentials and only reconnects when the known host key still matches."
        if let reason = AutomaticReconnectPolicy.unavailableReason(
            username: parsedDestination?.username,
            hasStoredPassword: hasStoredPasswordForCurrentIdentity,
            hasUsableKey: hasUsableSelectedKey
        ) {
            return "\(reason) \(base)"
        }
        return base
    }

    private var trimmedPort: String {
        port.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var parsedPort: Int? {
        guard let value = Int(trimmedPort), (1...65535).contains(value) else {
            return nil
        }
        return value
    }

    private func confirmDeleteConnection() {
        isConfirmingDelete = true
    }

    private func deleteEditingConnection(_ connection: SavedConnection) {
        connectionStore.delete(connection)
        dismiss()
    }

    private func connect() {
        guard let connection = persistForm(saveNewConnection: true) else { return }

        onConnect(connection)
        dismiss()
    }

    private func save() {
        guard persistForm(saveNewConnection: true) != nil else { return }

        dismiss()
    }

    private func persistForm(saveNewConnection: Bool) -> SavedConnection? {
        guard let parsedDestination, let parsedPort else { return nil }

        if let editingConnection {
            applyForm(to: editingConnection, destination: parsedDestination, parsedPort: parsedPort)
            connectionStore.saveChanges(touching: editingConnection)
            return editingConnection
        }

        let connection = makeConnection(destination: parsedDestination, parsedPort: parsedPort)
        if saveNewConnection {
            connectionStore.save(connection)
        }
        return connection
    }

    private func makeConnection(destination: ConnectionDestination, parsedPort: Int) -> SavedConnection {
        return SavedConnection(
            host: destination.host,
            port: parsedPort,
            username: destination.username,
            sshKeyId: selectedKeyId,
            autoReconnectOnBackgroundDisconnect: AutomaticReconnectPolicy.normalizedEnabled(
                autoReconnectOnBackgroundDisconnect,
                username: destination.username,
                hasStoredPassword: false,
                hasUsableKey: hasUsableSelectedKey
            ),
            autoRunCommandEnabled: autoRunCommandEnabled,
            autoRunCommand: autoRunCommand,
            tmuxBackfillOverride: tmuxBackfillOverride.boolValue,
            tmuxPauseModeOverride: tmuxPauseModeOverride.boolValue
        )
    }

    private func applyForm(
        to connection: SavedConnection,
        destination: ConnectionDestination,
        parsedPort: Int
    ) {
        let connectionIdentityChanged = connectionIdentityChanged(
            for: connection,
            destination: destination,
            parsedPort: parsedPort
        )
        let effectiveHasStoredPassword = connectionIdentityChanged ? false : hasStoredPassword

        connection.host = destination.host
        connection.port = parsedPort
        connection.username = destination.username
        connection.sshKeyId = selectedKeyId
        connection.autoReconnectOnBackgroundDisconnect = AutomaticReconnectPolicy.normalizedEnabled(
            autoReconnectOnBackgroundDisconnect,
            username: destination.username,
            hasStoredPassword: effectiveHasStoredPassword,
            hasUsableKey: hasUsableSelectedKey
        )
        connection.autoRunCommandEnabled = autoRunCommandEnabled
        connection.autoRunCommand = autoRunCommand
        connection.tmuxBackfillOverride = tmuxBackfillOverride.boolValue
        connection.tmuxPauseModeOverride = tmuxPauseModeOverride.boolValue

        if connectionIdentityChanged {
            KeychainService.deletePassword(forConnectionId: connection.id)
            hasStoredPassword = false
        }
    }

    private func connectionIdentityChanged(
        for connection: SavedConnection,
        destination: ConnectionDestination,
        parsedPort: Int
    ) -> Bool {
        connection.host != destination.host
            || connection.port != parsedPort
            || connection.username != destination.username
    }
}

/// Three-way override picker mapping to `Bool?` (nil = inherit global default).
enum TmuxOverride: String, CaseIterable, Identifiable {
    case inherit = "Default"
    case forceOn = "On"
    case forceOff = "Off"

    var id: String { rawValue }

    var boolValue: Bool? {
        switch self {
        case .inherit: return nil
        case .forceOn: return true
        case .forceOff: return false
        }
    }

    init(boolValue: Bool?) {
        switch boolValue {
        case .none:
            self = .inherit
        case .some(true):
            self = .forceOn
        case .some(false):
            self = .forceOff
        }
    }
}

#Preview {
    ConnectionSheet(
        connectionStore: ConnectionStore(),
        keyStore: KeyStore(),
        onConnect: { _ in }
    )
}
