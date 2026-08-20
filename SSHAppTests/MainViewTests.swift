import XCTest

/// Regression tests for the structure of the main connection UI: the no-tabs
/// saved-connections home screen, the connection editor sheet, and the
/// disconnected-terminal placeholder.
final class MainViewTests: XCTestCase {
    // MARK: - Connection sheet

    func testConnectionSheetUsesToolbarSaveAndConnectActions() throws {
        let source = try readSourceFile("SSHApp/Views/ConnectionSheet.swift")
        let connectBody = try extractMethodBody(from: source, methodName: "private func connect")
        let applyBody = try extractMethodBody(from: source, methodName: "private func applyForm")

        XCTAssertTrue(
            source.contains("ToolbarItemGroup(placement: .topBarTrailing)"),
            "ConnectionSheet must place primary actions in the toolbar so they remain visible above the form"
        )
        XCTAssertTrue(
            source.contains("Button(\"Save\", action: save)"),
            "ConnectionSheet must expose a Save action for persisting a new connection without connecting"
        )
        XCTAssertTrue(
            source.contains("Button(\"Connect\", action: connect)"),
            "ConnectionSheet must expose a Connect action for starting a session from the entered details"
        )
        XCTAssertFalse(
            source.contains("Save & Connect"),
            "ConnectionSheet must not rely on the old bottom-of-list Save & Connect action"
        )
        XCTAssertTrue(
            connectBody.contains("persistForm(saveNewConnection: true)"),
            "Connect must persist a new connection before opening the session"
        )
        XCTAssertTrue(
            source.contains("TextField(\"Destination\", text: $destination, prompt: Text(\"[user@]hostname\"))"),
            "ConnectionSheet must expose a single Destination field with a [user@]hostname prompt"
        )
        XCTAssertTrue(
            source.contains("@FocusState private var isDestinationFocused")
                && source.contains(".focused($isDestinationFocused)")
                && source.contains("isDestinationFocused = editingConnection == nil"),
            "The new-connection sheet should focus the Destination field automatically"
        )
        XCTAssertTrue(
            source.contains(".accessibilityIdentifier(\"connection.destination\")"),
            "The Destination field must have a stable UI automation identifier"
        )
        XCTAssertTrue(
            source.contains("TextField(\"Name\", text: $name, prompt: Text(\"Connection Name (Optional)\"))"),
            "ConnectionSheet must expose an optional Name field with a descriptive placeholder"
        )
        XCTAssertTrue(
            source.contains(".accessibilityIdentifier(\"connection.name\")"),
            "The Name field must have a stable UI automation identifier"
        )
        XCTAssertTrue(
            source.contains("name: normalizedName"),
            "Saving must persist the trimmed name, normalizing blank input to nil"
        )
        XCTAssertFalse(
            source.contains("TextField(\"Host\""),
            "ConnectionSheet must not expose the removed Host field"
        )
        XCTAssertFalse(
            source.contains("TextField(\"Username\""),
            "ConnectionSheet must not expose the removed Username field"
        )
        XCTAssertTrue(
            source.contains("ConnectionDestination.parse(destination)"),
            "ConnectionSheet must parse Destination as [user@]hostname"
        )
        XCTAssertTrue(
            applyBody.contains("connectionIdentityChanged"),
            "Editing a connection's host, port, or username must invalidate any saved password for the old connection identity"
        )
        XCTAssertTrue(
            applyBody.contains("KeychainService.deletePassword(forConnectionId: connection.id)"),
            "ConnectionSheet must clear a stored password when the connection identity changes"
        )
        let identityBody = try extractMethodBody(
            from: source,
            methodName: "private func connectionIdentityChanged"
        )
        XCTAssertFalse(
            identityBody.contains("connection.name") || identityBody.contains("normalizedName"),
            "Renaming a connection must not change its identity: a rename must not delete the stored password"
        )
    }

    func testConnectionSheetExposesStartupCommandControlsAndPersistsValues() throws {
        let source = try readSourceFile("SSHApp/Views/ConnectionSheet.swift")
        let makeBody = try extractMethodBody(from: source, methodName: "private func makeConnection")
        let applyBody = try extractMethodBody(from: source, methodName: "private func applyForm")

        XCTAssertTrue(
            source.contains("@State private var autoRunCommandEnabled = false")
                && source.contains("@State private var autoRunCommand = SavedConnection.defaultAutoRunCommand"),
            "ConnectionSheet must own startup command form state with safe defaults"
        )
        XCTAssertTrue(
            source.contains("Toggle(\"Automatically run command after connecting?\", isOn: $autoRunCommandEnabled)"),
            "ConnectionSheet must expose an enable toggle for the startup command"
        )
        XCTAssertTrue(
            source.contains("TextEditor(text: $autoRunCommand)"),
            "ConnectionSheet must expose a multiline editor for the startup command"
        )
        XCTAssertTrue(
            source.contains(".accessibilityIdentifier(\"connection.autoRunCommand.enabled\")")
                && source.contains(".accessibilityIdentifier(\"connection.autoRunCommand.text\")"),
            "Startup command controls must have stable UI automation identifiers"
        )

        guard let startupRange = source.range(of: "TextEditor(text: $autoRunCommand)"),
              let tmuxRange = source.range(of: "Section(\"Tmux (per-host)\")") else {
            XCTFail("ConnectionSheet must place the startup command section before tmux settings")
            return
        }
        let startupSection = String(source[startupRange.lowerBound..<tmuxRange.lowerBound])
        XCTAssertFalse(
            startupSection.contains(".disabled"),
            "The command text editor must remain editable even while automatic sending is disabled"
        )
        XCTAssertTrue(
            makeBody.contains("autoRunCommandEnabled: autoRunCommandEnabled")
                && makeBody.contains("autoRunCommand: autoRunCommand"),
            "New saved connections must persist both startup command fields"
        )
        XCTAssertTrue(
            applyBody.contains("connection.autoRunCommandEnabled = autoRunCommandEnabled")
                && applyBody.contains("connection.autoRunCommand = autoRunCommand"),
            "Edited saved connections must persist both startup command fields"
        )
        XCTAssertTrue(
            applyBody.contains("connectionIdentityChanged"),
            "Startup command edits must not broaden the password-clearing identity-change logic"
        )
    }

    func testConnectionSheetExposesAutomaticReconnectToggleAndPersistsNormalizedValue() throws {
        let source = try readSourceFile("SSHApp/Views/ConnectionSheet.swift")
        let makeBody = try extractMethodBody(from: source, methodName: "private func makeConnection")
        let applyBody = try extractMethodBody(from: source, methodName: "private func applyForm")

        XCTAssertTrue(
            source.contains("@State private var autoReconnectOnBackgroundDisconnect = false")
                && source.contains("@State private var hasStoredPassword = false"),
            "ConnectionSheet must track reconnect toggle and saved-password state"
        )
        XCTAssertTrue(
            source.contains("Toggle(\"Automatically reconnect after background disconnect\", isOn: autoReconnectToggleBinding)")
                && source.contains(".accessibilityIdentifier(\"connection.autoReconnectAfterBackgroundDisconnect\")"),
            "ConnectionSheet must expose the automatic reconnect toggle with a stable UI identifier"
        )
        XCTAssertTrue(
            source.contains("private var autoReconnectToggleBinding: Binding<Bool>")
                && source.contains("autoReconnectIsEligible ? autoReconnectOnBackgroundDisconnect : false")
                && source.contains(".disabled(!autoReconnectIsEligible)"),
            "ConnectionSheet must preserve the user's reconnect choice across transient ineligible edits"
        )
        XCTAssertFalse(
            source.contains(".onChange(of: autoReconnectIsEligible)"),
            "ConnectionSheet must not one-way clear reconnect state while the user is still editing"
        )
        XCTAssertTrue(
            source.contains("AutomaticReconnectPolicy.isEligible")
                && source.contains("AutomaticReconnectPolicy.unavailableReason"),
            "ConnectionSheet must use the shared pure policy for UI gating and footer copy"
        )
        XCTAssertTrue(
            makeBody.contains("autoReconnectOnBackgroundDisconnect: AutomaticReconnectPolicy.normalizedEnabled(")
                && makeBody.contains("hasStoredPassword: false")
                && makeBody.contains("hasUsableKey: hasUsableSelectedKey"),
            "New connections must persist only an eligible normalized reconnect setting"
        )
        XCTAssertTrue(
            applyBody.contains("connection.autoReconnectOnBackgroundDisconnect = AutomaticReconnectPolicy.normalizedEnabled(")
                && applyBody.contains("effectiveHasStoredPassword")
                && applyBody.contains("hasUsableKey: hasUsableSelectedKey"),
            "Edited connections must normalize reconnect after identity/password/key changes"
        )
    }

    func testNewConnectionSheetDoesNotListSavedConnections() throws {
        let source = try readSourceFile("SSHApp/Views/ConnectionSheet.swift")

        XCTAssertTrue(
            source.contains(".navigationTitle(editingConnection == nil ? \"New Connection\" : \"Edit Connection\")"),
            "Creating a connection must present a dedicated New Connection sheet"
        )
        XCTAssertFalse(
            source.contains("Section(\"Saved Connections\")"),
            "The New Connection sheet must not list saved connections"
        )
        XCTAssertFalse(
            source.contains("SavedConnectionRow"),
            "Saved connection selection must live outside the New Connection sheet"
        )
        XCTAssertFalse(
            source.contains("loadSavedConnections"),
            "The New Connection sheet must not fetch saved connections for selection"
        )
    }

    func testEditingConnectionSheetExposesBottomDeleteAction() throws {
        let source = try readSourceFile("SSHApp/Views/ConnectionSheet.swift")
        let deleteBody = try extractMethodBody(from: source, methodName: "private func deleteEditingConnection")

        guard let tmuxSectionRange = source.range(of: "Section(\"Tmux (per-host)\")") else {
            XCTFail("ConnectionSheet must keep the tmux section before the bottom delete action")
            return
        }
        guard let deleteButtonRange = source.range(of: "Button(role: .destructive, action: confirmDeleteConnection)") else {
            XCTFail("Editing a connection must expose a destructive delete action")
            return
        }

        XCTAssertLessThan(
            tmuxSectionRange.lowerBound,
            deleteButtonRange.lowerBound,
            "Connection deletion must remain at the bottom of the edit form"
        )
        XCTAssertTrue(
            source.contains("if editingConnection != nil"),
            "Connection deletion must only be shown while editing an existing connection"
        )
        XCTAssertTrue(
            source.contains(".accessibilityIdentifier(\"connection.delete\")"),
            "The delete action must have a stable UI automation identifier"
        )
        XCTAssertTrue(
            source.contains(".alert(\"Delete Connection?\""),
            "Deleting a connection must require confirmation"
        )
        XCTAssertTrue(
            deleteBody.contains("connectionStore.delete(connection)"),
            "Confirmed deletion must use ConnectionStore so saved passwords are cleaned up"
        )
        XCTAssertTrue(
            deleteBody.contains("dismiss()"),
            "The edit sheet must close after deleting the connection"
        )
    }

    // MARK: - No-tabs home

    func testAddTabDoesNotCreatePlaceholderTabBeforeConnectionSelection() throws {
        let source = try readSourceFile("SSHApp/Views/MainView.swift")
        let body = try extractMethodBody(from: source, methodName: "private func addNewTab")

        XCTAssertTrue(
            body.contains("connectionSheet = .new"),
            "addNewTab must present the connection sheet"
        )
        XCTAssertFalse(
            body.contains("Tab("),
            "addNewTab must not create a placeholder terminal tab before a connection is selected"
        )
    }

    func testNoTabsHomeExposesSavedConnectionActionsAndNewConnectionRow() throws {
        let source = try readSourceFile("SSHApp/Views/MainView.swift")
        let tabSource = try readSourceFile("SSHApp/Views/TerminalTab.swift")

        XCTAssertTrue(
            source.contains("NoTabsConnectionHomeView"),
            "MainView must render a dedicated no-tabs home screen"
        )
        XCTAssertTrue(
            source.contains("SavedConnectionHomeRow"),
            "The no-tabs home screen must render saved connection rows"
        )
        XCTAssertTrue(
            source.contains("Image(systemName: \"pencil\")"),
            "Saved connection rows must expose an icon-only edit button"
        )
        XCTAssertTrue(
            source.contains("Button(\"Connect\", action: onConnect)"),
            "Saved connection rows must expose a Connect action"
        )
        XCTAssertTrue(
            source.contains("onNewConnection: {"),
            "The no-tabs home screen must receive an action for creating a connection"
        )
        XCTAssertTrue(
            source.contains("Label(\"New Connection\", systemImage: \"plus\")"),
            "The no-tabs home screen must expose a + New Connection row"
        )
        XCTAssertTrue(
            source.contains(".accessibilityIdentifier(\"connection.new\")"),
            "The new-connection row must have a stable UI automation identifier"
        )
        if let listRange = source.range(of: "Section(\"Saved Connections\")") {
            let sectionSource = source[listRange.lowerBound...]
            let rowsIndex = sectionSource.range(of: "ForEach(savedConnections)")?.lowerBound
            let newConnectionIndex = sectionSource.range(of: "Label(\"New Connection\"")?.lowerBound
            XCTAssertNotNil(rowsIndex)
            XCTAssertNotNil(newConnectionIndex)
            if let rowsIndex, let newConnectionIndex {
                XCTAssertLessThan(
                    rowsIndex,
                    newConnectionIndex,
                    "The + New Connection row must come after the saved connection rows"
                )
            }
        } else {
            XCTFail("The no-tabs home screen must keep the Saved Connections section")
        }
        XCTAssertFalse(
            source.contains("\"Tap + to add a new connection\""),
            "The no-tabs home screen must not show the legacy blank empty prompt"
        )
        XCTAssertFalse(
            tabSource.contains("\"Tap + to add a new connection\""),
            "Disconnected terminal placeholders must not reference the removed menu-bar + button"
        )
        XCTAssertFalse(
            source.contains("ContentUnavailableView"),
            "The no-tabs home screen must stay on the saved-connections list even when it is empty"
        )
    }

    func testRenamingAConnectionRefreshesTabTitlesItStillOwns() throws {
        let source = try readSourceFile("SSHApp/Views/MainView.swift")

        XCTAssertTrue(
            source.contains(".onChange(of: savedConnectionDisplayNames) { _, _ in")
                && source.contains("refreshConnectionOwnedTabTitles()"),
            "MainView must refresh connection-owned tab titles when a saved connection's display name changes"
        )
        XCTAssertTrue(
            source.contains("tab.refreshConnectionTitle()"),
            "The refresh must route through Tab.refreshConnectionTitle so terminal-owned titles survive"
        )
        XCTAssertTrue(
            source.contains("tab.isTitleOwnedByTerminal = false"),
            "Reconnecting must release terminal title ownership so the new session's connection label is used"
        )
    }

    func testSavedConnectionHomeRowsShowDestinationUnderCustomNames() throws {
        let source = try readSourceFile("SSHApp/Views/MainView.swift")

        XCTAssertTrue(
            source.contains("connection.usesCustomName ? connection.displayDestination : (usesAvailableKey ? \"SSH key\" : \"Password\")"),
            "Saved connection rows must show the destination as the secondary line when a custom name replaces the default label"
        )
    }

    func testCredentialRowsShowDestinationUnderCustomNames() throws {
        let source = try readSourceFile("SSHApp/Views/CredentialsView.swift")

        XCTAssertTrue(
            source.contains("connection.usesCustomName ? connection.displayDestination : \"Saved password\""),
            "Password credential rows must show the destination as the secondary line when a custom name replaces the default label"
        )
    }

    func testSavedConnectionRowsExposeSwipeToDelete() throws {
        let source = try readSourceFile("SSHApp/Views/MainView.swift")

        XCTAssertTrue(
            source.contains(".swipeActions"),
            "Saved connection rows must expose a swipe-to-delete affordance"
        )
        XCTAssertTrue(
            source.contains("Button(\"Delete\", role: .destructive)"),
            "The swipe action must be a destructive Delete button"
        )
        XCTAssertTrue(
            source.contains(".accessibilityIdentifier(\"savedConnection.delete.\\(connection.id.uuidString)\")"),
            "The swipe Delete button must have a stable UI automation identifier"
        )
        XCTAssertTrue(
            source.contains("let onDelete: (SavedConnection) -> Void"),
            "NoTabsConnectionHomeView must receive an onDelete closure"
        )
        XCTAssertEqual(
            source.components(separatedBy: "onDelete: { connection in").count - 1,
            2,
            "Both NoTabsConnectionHomeView call sites must wire the onDelete closure"
        )
        if let listRange = source.range(of: "Section(\"Saved Connections\")") {
            let sectionSource = source[listRange.lowerBound...]
            let rowsIndex = sectionSource.range(of: "ForEach(savedConnections)")?.lowerBound
            let swipeIndex = sectionSource.range(of: ".swipeActions")?.lowerBound
            let newConnectionIndex = sectionSource.range(of: "Label(\"New Connection\"")?.lowerBound
            XCTAssertNotNil(rowsIndex)
            XCTAssertNotNil(swipeIndex)
            XCTAssertNotNil(newConnectionIndex)
            if let rowsIndex, let swipeIndex, let newConnectionIndex {
                XCTAssertLessThan(
                    rowsIndex,
                    swipeIndex,
                    "The swipe action must attach to the saved connection rows"
                )
                XCTAssertLessThan(
                    swipeIndex,
                    newConnectionIndex,
                    "The + New Connection row must not get a delete swipe action"
                )
            }
        } else {
            XCTFail("The no-tabs home screen must keep the Saved Connections section")
        }
    }

    func testSwipeDeleteRequiresConfirmationInsteadOfDeletingImmediately() throws {
        let source = try readSourceFile("SSHApp/Views/MainView.swift")
        let homeBody = try extractMethodBody(from: source, methodName: "struct NoTabsConnectionHomeView")

        // The swipe action must stage a pending deletion for confirmation, not
        // delete immediately.
        XCTAssertTrue(
            homeBody.contains("connectionPendingDeletion = PendingConnectionDeletion("),
            "Swiping must stage a pending deletion instead of deleting immediately"
        )
        guard let swipeRange = homeBody.range(of: ".swipeActions"),
              let alertRange = homeBody.range(of: ".alert(") else {
            XCTFail("NoTabsConnectionHomeView must present a confirmation alert for deletion")
            return
        }
        let swipeButtonBody = String(homeBody[swipeRange.lowerBound..<alertRange.lowerBound])
        XCTAssertFalse(
            swipeButtonBody.contains("onDelete(")
                || swipeButtonBody.contains("onCloseTabsAndDelete("),
            "The swipe button must not invoke deletion directly; it must route through the confirmation alert"
        )

        // The confirmation alert must gate both destructive branches.
        XCTAssertTrue(
            homeBody.contains("\"Delete Connection?\""),
            "Deletion must require a confirmation alert"
        )
        XCTAssertTrue(
            homeBody.contains("onDelete(pending.connection)"),
            "Confirming a plain deletion must route through the onDelete closure"
        )
        XCTAssertTrue(
            homeBody.contains("Button(\"Cancel\", role: .cancel)"),
            "The confirmation alert must offer a Cancel button"
        )
        XCTAssertTrue(
            source.contains(".accessibilityIdentifier(\"savedConnection.delete.confirm.delete\")")
                && source.contains(".accessibilityIdentifier(\"savedConnection.delete.confirm.cancel\")"),
            "The confirmation buttons must expose stable UI automation identifiers"
        )
    }

    func testDeletingConnectionWithOpenTabsClosesTabsFirst() throws {
        let source = try readSourceFile("SSHApp/Views/MainView.swift")
        let homeBody = try extractMethodBody(from: source, methodName: "struct NoTabsConnectionHomeView")

        // The alert must branch on whether the connection still backs open tabs
        // and, when it does, offer a Close & Delete action instead of a silent
        // dangling-model deletion.
        XCTAssertTrue(
            source.contains("let hasOpenTabs: (SavedConnection) -> Bool")
                && source.contains("let onCloseTabsAndDelete: (SavedConnection) -> Void"),
            "NoTabsConnectionHomeView must receive the active-tab guard closures"
        )
        XCTAssertTrue(
            homeBody.contains("pending.hasOpenTabs"),
            "The confirmation alert must branch on whether the connection has open tabs"
        )
        XCTAssertTrue(
            homeBody.contains("\"Close Tabs & Delete?\"")
                && homeBody.contains("Button(\"Close & Delete\", role: .destructive)"),
            "Deleting a connection with open tabs must offer to close those tabs first"
        )
        XCTAssertTrue(
            homeBody.contains("onCloseTabsAndDelete(pending.connection)"),
            "Confirming Close & Delete must route through the onCloseTabsAndDelete closure"
        )
        XCTAssertTrue(
            source.contains(".accessibilityIdentifier(\"savedConnection.delete.confirm.closeAndDelete\")"),
            "The Close & Delete button must expose a stable UI automation identifier"
        )

        // The alert must never dereference a possibly-deleted SwiftData model:
        // it renders from a snapshot captured at swipe time.
        XCTAssertTrue(
            source.contains("struct PendingConnectionDeletion")
                && source.contains("let displayName: String"),
            "The pending-deletion snapshot must carry a precomputed display name so the alert avoids the deleted model"
        )

        // Both call sites (no-tabs home and Settings > Connections) must supply
        // the guard, computed from the live tab list.
        XCTAssertEqual(
            source.components(separatedBy: "hasOpenTabs: { connection in").count - 1,
            2,
            "Both call sites must compute open-tab state from the live tab list"
        )
        XCTAssertEqual(
            source.components(separatedBy: "closeOpenTabsAndDelete(connection)").count - 1,
            2,
            "Both call sites must route Close & Delete through the MainView helper"
        )
        XCTAssertTrue(
            source.contains("tabs.contains { $0.connection?.id == connection.id }"),
            "Open-tab detection must match tabs whose saved connection is being deleted"
        )

        // The helper must close every referencing tab before deleting so no tab
        // is left holding a deleted SwiftData model, while still deleting through
        // the store (Keychain + iCloud-sync cleanup).
        let helperBody = try extractMethodBody(from: source, methodName: "private func closeOpenTabsAndDelete")
        XCTAssertTrue(
            helperBody.contains("tabs.filter { $0.connection?.id == connection.id }"),
            "closeOpenTabsAndDelete must find every tab backed by the connection"
        )
        XCTAssertTrue(
            helperBody.contains("closeConnection(for: tab)"),
            "closeOpenTabsAndDelete must close (and disconnect) each referencing tab"
        )
        XCTAssertTrue(
            helperBody.contains("connectionStore.delete(connection)"),
            "closeOpenTabsAndDelete must still delete through ConnectionStore for Keychain/iCloud cleanup"
        )
        XCTAssertLessThan(
            helperBody.range(of: "closeConnection(for: tab)")?.lowerBound ?? helperBody.endIndex,
            helperBody.range(of: "connectionStore.delete(connection)")?.lowerBound ?? helperBody.startIndex,
            "Referencing tabs must be closed before the connection is deleted"
        )
    }


    func testNewConnectionStaysInSavedConnectionsManagerAndActiveSwitcherRoutesThere() throws {
        let mainSource = try readSourceFile("SSHApp/Views/MainView.swift")
        let barSource = try readSourceFile("SSHApp/Views/UnifiedTopBar.swift")
        let switcherSource = try readSourceFile("SSHApp/Views/ConnectionSwitcherView.swift")
        let homeBody = try extractMethodBody(
            from: mainSource,
            methodName: "struct NoTabsConnectionHomeView"
        )
        let managerBody = try extractMethodBody(
            from: mainSource,
            methodName: "private struct ConnectionsSettingsView"
        )

        XCTAssertFalse(
            barSource.contains("if tabs.isEmpty"),
            "The no-tabs top bar must not show a standalone + button"
        )
        XCTAssertTrue(
            homeBody.contains("Label(\"New Connection\", systemImage: \"plus\")")
                && homeBody.contains("Button(action: onNewConnection)")
                && homeBody.contains("connection.new"),
            "The no-tabs saved-connections screen must retain its direct New Connection row"
        )
        XCTAssertTrue(
            managerBody.contains("NoTabsConnectionHomeView(")
                && managerBody.contains("connectionSheet = .new")
                && managerBody.contains("ConnectionSheet("),
            "ConnectionsSettingsView must reuse the saved-connections screen and its nested creation form"
        )
        XCTAssertTrue(
            switcherSource.contains("Text(\"Connections\")")
                && switcherSource.contains("onOpenConnections()")
                && switcherSource.contains("connection.switcher.connections"),
            "An active terminal's switcher must expose the Connections manager destination"
        )
        XCTAssertFalse(
            switcherSource.contains("New Connection")
                || switcherSource.contains("onAddTab")
                || switcherSource.contains("connection.switcher.newConnection"),
            "The active-terminal switcher must not open the creation form directly"
        )
        XCTAssertTrue(
            barSource.contains("onOpenConnections: { onSettings(.connections) }")
                && mainSource.contains("case .connections:")
                && mainSource.contains("ConnectionsSettingsView("),
            "The switcher callback must reach MainView's reusable Connections manager"
        )
    }

    // MARK: - Disconnected placeholder

    func testDisconnectedTerminalOffersReconnectAndDisconnectActions() throws {
        let tabSource = try readSourceFile("SSHApp/Views/TerminalTab.swift")
        let mainSource = try readSourceFile("SSHApp/Views/MainView.swift")
        let disconnectedView = try extractMethodBody(from: tabSource, methodName: "struct DisconnectedView")
        let reconnectBody = try extractMethodBody(from: mainSource, methodName: "private func reconnectTab")
        let closeConnectionBody = try extractMethodBody(from: mainSource, methodName: "private func closeConnection")

        XCTAssertTrue(
            tabSource.contains("onReconnect: { onReconnect(tab) }")
                && tabSource.contains("onDisconnect: { onDisconnect(tab) }"),
            "Disconnected terminal placeholders must route action buttons back to MainView with the owning tab"
        )
        XCTAssertTrue(
            disconnectedView.contains("Label(\"Reconnect\", systemImage: \"arrow.clockwise\")")
                && disconnectedView.contains("Label(\"Disconnect\", systemImage: \"xmark\")")
                && disconnectedView.contains(".accessibilityIdentifier(\"terminal.disconnected.reconnect\")")
                && disconnectedView.contains(".accessibilityIdentifier(\"terminal.disconnected.disconnect\")"),
            "The disconnected placeholder must expose visible reconnect and disconnect controls"
        )
        XCTAssertTrue(
            reconnectBody.contains("guard let connection = tab.connection else { return }"),
            "Manual reconnect needs the saved connection from the stale tab"
        )
        XCTAssertLessThan(
            reconnectBody.range(of: "closeConnection(for: tab)")?.lowerBound ?? reconnectBody.endIndex,
            reconnectBody.range(of: "openConnectionInNewTab(connection)")?.lowerBound ?? reconnectBody.startIndex,
            "Manual reconnect must disconnect/close the stale tab before opening a fresh connection"
        )
        XCTAssertTrue(
            closeConnectionBody.contains("ObjectIdentifier(session)")
                && closeConnectionBody.contains("removeTabs(forSessionID: sessionID, disconnectSession: true)")
                && closeConnectionBody.contains("closeTab(tab)"),
            "Disconnect from the placeholder must close the whole shared connection when present, or the standalone tab otherwise"
        )
    }

    // MARK: - Helpers

    private func extractMethodBody(from source: String, methodName: String) throws -> String {
        guard let methodRange = source.range(of: methodName) else {
            throw NSError(domain: "Test", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Method '\(methodName)' not found"])
        }

        let afterMethod = source[methodRange.upperBound...]
        guard let braceStart = afterMethod.firstIndex(of: "{") else {
            throw NSError(domain: "Test", code: 2,
                         userInfo: [NSLocalizedDescriptionKey: "No opening brace for '\(methodName)'"])
        }

        var depth = 0
        var braceEnd: String.Index?
        var index = braceStart

        while index < afterMethod.endIndex {
            let char = afterMethod[index]
            if char == "{" { depth += 1 }
            if char == "}" {
                depth -= 1
                if depth == 0 {
                    braceEnd = index
                    break
                }
            }
            index = afterMethod.index(after: index)
        }

        guard let end = braceEnd else {
            throw NSError(domain: "Test", code: 3,
                         userInfo: [NSLocalizedDescriptionKey: "No matching brace for '\(methodName)'"])
        }

        return String(afterMethod[braceStart...end])
    }
}
