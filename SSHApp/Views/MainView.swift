import SwiftUI
import SwiftData
import UIKit

/// Main view containing the tab bar and terminal views
struct MainView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [
        SortDescriptor(\SavedConnection.lastConnected, order: .reverse),
        SortDescriptor(\SavedConnection.createdAt, order: .reverse)
    ]) private var savedConnections: [SavedConnection]

    @State private var tabs: [Tab] = []
    @State private var selectedTabId: UUID?
    @State private var tabSelectionHistory = TabSelectionHistory()
    @State private var connectionSheet: ConnectionSheetDestination?
    @State private var installSSHKeyRequest: InstallSSHKeyRequest?
    @State private var settingsSheet: SettingsDestination?
    @State private var connectionStore = ConnectionStore()
    @State private var keyStore = KeyStore()
    @State private var credentialSavePrompt: CredentialSavePrompt?
    @State private var queuedCredentialSavePrompts: [CredentialSavePrompt] = []
    @State private var isResolvingCredentialSavePrompt = false
    @AppStorage(AppSettingsKey.showKeyboardBar) private var showKeyboardBar = true

    private var palette: AppPalette { TerminalRuntime.shared.appPalette }

    var body: some View {
        VStack(spacing: 0) {
            // Unified bar at top: connection menu, host session tabs, tools
                UnifiedTopBar(
                    tabs: tabs,
                    selectedTab: selectedTab,
                    savedConnections: savedConnections,
                    keyStore: keyStore,
                    showKeyboardBar: $showKeyboardBar,
                onAddTab: { addNewTab() },
                onNewTerminalForTab: { tab in
                    openSharedTerminal(for: tab)
                },
                onConnectSavedConnection: { connection in
                    openConnectionInNewTab(connection)
                },
                onEditSavedConnection: { connection in
                    connectionSheet = .edit(connection)
                },
                onInstallSSHKey: { tab in
                    installSSHKeyRequest = InstallSSHKeyRequest(tab: tab)
                },
                onSelectTab: { selectTab($0) },
                onCloseTab: { closeTab($0) },
                onSettings: { settingsSheet = $0 }
            )

            // Terminal area
            Group {
                if tabs.isEmpty {
                    NoTabsConnectionHomeView(
                        savedConnections: savedConnections,
                        keyStore: keyStore,
                        onNewConnection: {
                            connectionSheet = .new
                        },
                        onConnect: { connection in
                            openConnectionInNewTab(connection)
                        },
                        onEdit: { connection in
                            connectionSheet = .edit(connection)
                        }
                    )
                } else {
                    ZStack {
                        ForEach(tabs) { tab in
                            let isSelected = tab.id == selectedTabId
                            TerminalTab(
                                tab: tab,
                                isHostTabActive: isSelected,
                                showsKeyboardBar: showKeyboardBar,
                                onHostShortcut: { handleHostTabShortcut($0) },
                                onRemoteChannelClosed: { closedTab in
                                    closeTab(closedTab, disconnectSession: false)
                                }
                            )
                                .opacity(isSelected ? 1 : 0)
                                .allowsHitTesting(isSelected)
                                .accessibilityHidden(!isSelected)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(palette.background)
        .focusedSceneValue(\.sshAppCommandActions, appCommandActions)
        .sheet(item: $connectionSheet) { sheet in
            Group {
                switch sheet {
                case .new:
                    ConnectionSheet(
                        connectionStore: connectionStore,
                        keyStore: keyStore,
                        onConnect: { connection in
                            openConnectionInNewTab(connection)
                        }
                    )
                case .edit(let connection):
                    ConnectionSheet(
                        connectionStore: connectionStore,
                        keyStore: keyStore,
                        editingConnection: connection,
                        onConnect: { connection in
                            openConnectionInNewTab(connection)
                        }
                    )
                }
            }
            .tint(palette.accent)
        }
        .sheet(item: $installSSHKeyRequest) { request in
            InstallSSHKeySheet(tab: request.tab, keyStore: keyStore, connectionStore: connectionStore)
                .tint(palette.accent)
        }
        .sheet(item: $settingsSheet) { destination in
            SettingsSheet {
                switch destination {
                case .credentials:
                    CredentialsView(keyStore: keyStore, savedConnections: savedConnections)
                case .tmux:
                    TmuxSettingsView()
                case .font:
                    FontSettingsView()
                case .theme:
                    ThemeSettingsView()
                case .licenses:
                    OpenSourceLicensesView()
                }
            }
            .tint(palette.accent)
        }
        .sheet(
            item: Binding(
                get: { credentialSavePrompt },
                set: { newValue in
                    if newValue == nil {
                        dismissCredentialSavePrompt()
                    }
                }
            )
        ) { prompt in
            CredentialSaveSheet(
                rows: prompt.rows,
                username: prompt.offer.username,
                hostLabel: prompt.hostLabel,
                connectionLabel: prompt.connectionLabel
            ) { decision in
                resolveCredentialSavePrompt(decision: decision)
            }
            .presentationDetents([.medium])
            .tint(palette.accent)
        }
        .onAppear {
            connectionStore.setModelContext(modelContext)
            restoreMostRecentlyUsedTab()
        }
    }

    private var selectedTab: Tab? {
        tabs.first { $0.id == selectedTabId }
    }

    private var selectedAttachedTmuxController: TmuxController? {
        guard let controller = selectedTab?.tmuxController,
              controller.state.isAttached else {
            return nil
        }
        return controller
    }

    private var appCommandActions: SSHAppCommandActions {
        SSHAppCommandActions(
            newConnection: {
                addNewTab()
            },
            newTab: {
                openTerminalOnSelectedServer()
            },
            closeTab: {
                closeSelectedTab()
            },
            previousHostTab: {
                selectPreviousHostTab()
            },
            nextHostTab: {
                selectNextHostTab()
            },
            previousTmuxTab: {
                selectPreviousTmuxTab()
            },
            nextTmuxTab: {
                selectNextTmuxTab()
            },
            isTmuxAttached: selectedAttachedTmuxController != nil,
            canOpenNewTab: canOpenNewTabFromSelectedContext,
            canCloseTab: selectedTab != nil,
            canNavigateHostTabs: tabs.count > 1,
            canNavigateTmuxTabs: (selectedAttachedTmuxController?.windowOrder.count ?? 0) > 1
        )
    }

    private var canOpenNewTabFromSelectedContext: Bool {
        if selectedAttachedTmuxController != nil {
            return true
        }

        guard let selectedTab else { return false }
        return selectedTab.session?.canOpenChannel == true && selectedTab.connection != nil
    }

    private func addNewTab() {
        connectionSheet = .new
    }

    private func openConnectionInNewTab(_ connection: SavedConnection) {
        let newTab = Tab(
            title: connection.displayDestination,
            connectionState: .disconnected,
            connection: connection
        )
        tabs.append(newTab)
        selectTab(newTab)

        Task {
            await connectSession(tab: newTab, connection: connection)
        }
    }

    private func openTerminalOnSelectedServer() {
        guard let selectedTab else { return }

        if let controller = selectedTab.tmuxController, controller.state.isAttached {
            Task { await controller.newWindow() }
            return
        }

        guard let session = selectedTab.session,
              session.canOpenChannel,
              let connection = selectedTab.connection else {
            return
        }

        openSharedChannelInNewTab(session: session, connection: connection)
    }

    private func openSharedTerminal(for tab: Tab) {
        guard let session = tab.session,
              session.canOpenChannel,
              let connection = tab.connection else {
            return
        }

        openSharedChannelInNewTab(session: session, connection: connection)
    }

    private func openSharedChannelInNewTab(session: SSHSession, connection: SavedConnection) {
        let newTab = Tab(
            title: connection.displayDestination,
            connectionState: .connected,
            session: session,
            connection: connection
        )
        tabs.append(newTab)
        selectTab(newTab)
    }

    private func selectTab(_ tab: Tab) {
        selectedTabId = tab.id
        tabSelectionHistory.recordSelection(tab.id)
    }

    private func selectTab(withId tabID: UUID?) {
        guard let tabID,
              let tab = tabs.first(where: { $0.id == tabID })
        else {
            return
        }
        selectTab(tab)
    }

    private func closeSelectedTab() {
        guard let selectedTab else { return }
        closeTab(selectedTab)
    }

    private func selectPreviousHostTab() {
        selectTab(withId: IndexedTabNavigation.previous(in: tabs.map(\.id), selected: selectedTabId))
    }

    private func selectNextHostTab() {
        selectTab(withId: IndexedTabNavigation.next(in: tabs.map(\.id), selected: selectedTabId))
    }

    private func selectPreviousTmuxTab() {
        guard let controller = selectedAttachedTmuxController else { return }
        Task { await controller.selectPreviousWindow() }
    }

    private func selectNextTmuxTab() {
        guard let controller = selectedAttachedTmuxController else { return }
        Task { await controller.selectNextWindow() }
    }

    private func handleHostTabShortcut(_ shortcut: TerminalTabShortcut) {
        let tabIDs = tabs.map(\.id)

        switch shortcut {
        case .newTerminal:
            openTerminalOnSelectedServer()
        case .previousHostTab:
            selectTab(withId: IndexedTabNavigation.previous(in: tabIDs, selected: selectedTabId))
        case .nextHostTab:
            selectTab(withId: IndexedTabNavigation.next(in: tabIDs, selected: selectedTabId))
        case .selectHostTab(let digit):
            selectTab(withId: IndexedTabNavigation.item(forShortcutDigit: digit, in: tabIDs))
        case .previousTmuxWindow, .nextTmuxWindow, .selectTmuxWindow:
            break
        }
    }

    private func closeTab(_ tab: Tab, disconnectSession: Bool = true) {
        if disconnectSession {
            if let channel = tab.channel {
                channel.close()
            } else {
                tab.session?.disconnect()
            }
        }

        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else {
            return
        }

        tabs.remove(at: index)
        tabSelectionHistory.remove(tab.id)

        if selectedTabId == tab.id || !hasTab(withId: selectedTabId) {
            restoreMostRecentlyUsedTab()
        }
    }

    private func restoreMostRecentlyUsedTab() {
        let activeTabIds = Set(tabs.map(\.id))
        tabSelectionHistory.prune(activeTabIds: activeTabIds)

        guard !tabs.isEmpty else {
            selectedTabId = nil
            return
        }

        if hasTab(withId: selectedTabId) {
            if let selectedTabId {
                tabSelectionHistory.recordSelection(selectedTabId)
            }
            return
        }

        if let recentTabId = tabSelectionHistory.mostRecentActiveTabId(activeTabIds: activeTabIds) {
            selectedTabId = recentTabId
        } else {
            selectedTabId = tabs.last?.id
        }

        if let selectedTabId {
            tabSelectionHistory.recordSelection(selectedTabId)
        }
    }

    private func hasTab(withId tabId: UUID?) -> Bool {
        guard let tabId else { return false }
        return tabs.contains { $0.id == tabId }
    }

    @MainActor
    private func connectSession(tab: Tab, connection: SavedConnection) async {
        let session = SSHSession()
        // Resolve tmux settings (global + per-host overrides) before any DCS detection.
        session.tmuxSettings = TmuxSettings.resolve(connection: connection)
        tab.session = session
        tab.connectionState = .awaitingInput

        session.onStateChanged = { [weak tab] state in
            tab?.connectionState = state
        }
        do {
            try await session.connectAndAuthenticate(
                host: connection.host,
                port: UInt16(connection.port),
                username: connection.username,
                keyId: connection.sshKeyId,
                keyStore: keyStore,
                connectionId: connection.id,
                promptToSaveCredentials: { offer in
                    let rows = CredentialSavePolicy.rowsToOffer(
                        offer: offer,
                        hasSavedUsername: connection.username?.isEmpty == false,
                        neverAskUsername: connection.neverAskSaveUsername,
                        neverAskPassword: connection.neverAskSavePassword
                    )
                    guard !rows.isEmpty else { return .declined }

                    let decision = await promptToSaveCredentials(
                        connection: connection, offer: offer, rows: rows
                    )

                    // SwiftData writes happen here; the keychain write is
                    // applied by SSHSession from the returned decision.
                    if decision.saveUsername, let username = offer.username {
                        connection.username = username
                    }
                    if decision.neverAskUsername {
                        connection.neverAskSaveUsername = true
                    }
                    if decision.neverAskPassword
                        || CredentialSavePolicy.shouldSuppressFuturePassword(rows: rows, decision: decision) {
                        connection.neverAskSavePassword = true
                    }
                    connectionStore.saveChanges(touching: connection)
                    return decision
                },
                onSavedCredentialsDeclined: {
                    connection.username = nil
                    connectionStore.saveChanges(touching: connection)
                }
            )
            connectionStore.updateLastConnected(connection)
            tab.title = connection.displayDestination
        } catch {
            // Clean up SSH transport resources and resume any pending continuations
            // before showing the error. Without this, the transport's read loop and
            // socket remain alive, and the session holds stale state.
            session.disconnect()
            tab.connectionState = .failed(error.localizedDescription)
        }
    }

    @MainActor
    private func promptToSaveCredentials(
        connection: SavedConnection,
        offer: CredentialSaveOffer,
        rows: CredentialSaveRows
    ) async -> CredentialSaveDecision {
        await withCheckedContinuation { continuation in
            let hostLabel = ConnectionDestination.display(
                username: nil,
                host: connection.host,
                port: connection.port
            )
            let prompt = CredentialSavePrompt(
                rows: rows,
                offer: offer,
                hostLabel: hostLabel,
                connectionLabel: connection.displayDestination,
                continuation: continuation
            )

            if credentialSavePrompt == nil {
                credentialSavePrompt = prompt
            } else {
                queuedCredentialSavePrompts.append(prompt)
            }
        }
    }

    @MainActor
    private func resolveCredentialSavePrompt(decision: CredentialSaveDecision) {
        guard let prompt = credentialSavePrompt else { return }

        isResolvingCredentialSavePrompt = true
        credentialSavePrompt = nil
        prompt.continuation.resume(returning: decision)

        Task { @MainActor in
            await Task.yield()
            isResolvingCredentialSavePrompt = false
            presentNextCredentialSavePrompt()
        }
    }

    @MainActor
    private func dismissCredentialSavePrompt() {
        guard !isResolvingCredentialSavePrompt else { return }
        resolveCredentialSavePrompt(decision: .declined)
    }

    @MainActor
    private func presentNextCredentialSavePrompt() {
        guard credentialSavePrompt == nil,
              !queuedCredentialSavePrompts.isEmpty else {
            return
        }
        credentialSavePrompt = queuedCredentialSavePrompts.removeFirst()
    }
}

private enum ConnectionSheetDestination: Identifiable {
    case new
    case edit(SavedConnection)

    var id: String {
        switch self {
        case .new:
            "new"
        case .edit(let connection):
            "edit-\(connection.id.uuidString)"
        }
    }
}

private struct InstallSSHKeyRequest: Identifiable {
    let tab: Tab

    var id: UUID {
        tab.id
    }
}

private struct CredentialSavePrompt: Identifiable {
    let id = UUID()
    let rows: CredentialSaveRows
    let offer: CredentialSaveOffer
    let hostLabel: String
    let connectionLabel: String
    let continuation: CheckedContinuation<CredentialSaveDecision, Never>
}

/// Landing screen shown when there are no active terminal tabs.
struct NoTabsConnectionHomeView: View {
    let savedConnections: [SavedConnection]
    let keyStore: KeyStore
    let onNewConnection: () -> Void
    let onConnect: (SavedConnection) -> Void
    let onEdit: (SavedConnection) -> Void

    private var palette: AppPalette { TerminalRuntime.shared.appPalette }

    var body: some View {
        List {
            Section("Saved Connections") {
                ForEach(savedConnections) { connection in
                    SavedConnectionHomeRow(
                        connection: connection,
                        usesAvailableKey: connection.sshKeyId.flatMap { keyStore.key(withId: $0) } != nil,
                        onConnect: { onConnect(connection) },
                        onEdit: { onEdit(connection) }
                    )
                }

                Button(action: onNewConnection) {
                    Label("New Connection", systemImage: "plus")
                        .foregroundColor(palette.accent)
                }
                .accessibilityIdentifier("connection.new")
            }
            .themedListRow(palette)
        }
        .listStyle(.insetGrouped)
        .themedListBackground(palette)
    }
}

/// Saved connection row for the no-tabs home screen.
struct SavedConnectionHomeRow: View {
    let connection: SavedConnection
    let usesAvailableKey: Bool
    let onConnect: () -> Void
    let onEdit: () -> Void

    private var palette: AppPalette { TerminalRuntime.shared.appPalette }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(connection.displayDestination)
                    .font(.headline)
                    .foregroundColor(palette.primaryText)
                    .lineLimit(1)

                Text(usesAvailableKey ? "SSH key" : "Password")
                    .font(.caption)
                    .foregroundColor(palette.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Edit \(connection.displayDestination)")

            Button("Connect", action: onConnect)
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Connect to \(connection.displayDestination)")
        }
        .padding(.vertical, 4)
    }
}

/// A settings destination reachable directly from the gear menu.
enum SettingsDestination: String, Identifiable {
    case credentials, tmux, font, theme, licenses
    var id: String { rawValue }
}

/// Sheet container for a settings destination: provides the navigation stack
/// and a Done button to dismiss.
struct SettingsSheet<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
        }
        .presentationSizing(.page)
    }
}

#Preview {
    MainView()
        .modelContainer(for: SavedConnection.self, inMemory: true)
}
