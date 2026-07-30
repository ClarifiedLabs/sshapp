import XCTest

/// Regression tests for the unified top bar, connection switcher, and command menu.
final class UnifiedTopBarTests: XCTestCase {
    /// Split-pane actions now live on tmux window chips and in the connection
    /// switcher; the standalone tmux mode indicator was removed for compactness.
    func testUnifiedBarExposesSplitPaneActionsWithoutTmuxModeIndicator() throws {
        let barSource = try readSourceFile("SSHApp/Views/UnifiedTopBar.swift")
        let switcherSource = try readSourceFile("SSHApp/Views/ConnectionSwitcherView.swift")

        XCTAssertFalse(
            barSource.contains("private func tmuxModeIndicator(controller: TmuxController)")
                || barSource.contains("tmux.mode.indicator"),
            "The compact bar must not render a standalone tmux mode indicator"
        )
        XCTAssertTrue(
            barSource.contains("Label(\"Split Right\", systemImage: \"rectangle.split.2x1\")")
                && barSource.contains("Label(\"Split Down\", systemImage: \"rectangle.split.1x2\")"),
            "Tmux window chip context menus must keep split actions"
        )
        XCTAssertTrue(
            switcherSource.contains("controller.splitPane(.right, target: window.activePaneID)")
                && switcherSource.contains("controller.splitPane(.down, target: window.activePaneID)"),
            "The connection switcher must target split actions at the chosen window's active pane"
        )
        XCTAssertTrue(
            switcherSource.contains("connection.switcher.tmux.split.right")
                && switcherSource.contains("connection.switcher.tmux.split.down"),
            "Switcher split actions must have stable accessibility identifiers"
        )
        XCTAssertTrue(
            barSource.contains("\"tmux.window.new\""),
            "The new-window control must remain available"
        )
        XCTAssertFalse(
            barSource.contains(".disabled(controller.activePaneID == nil)"),
            "Split actions should reach the controller so missing active-pane state is logged instead of silently disabling the button"
        )
    }

    func testUnifiedBarNewTabButtonWorksInBothModes() throws {
        let barSource = try readSourceFile("SSHApp/Views/UnifiedTopBar.swift")
        let topBarBody = try extractMethodBody(
            from: barSource,
            methodName: "var body"
        )
        let hostSessionPillsBody = try extractMethodBody(
            from: barSource,
            methodName: "private var hostSessionPills"
        )
        let tmuxWindowPillsBody = try extractMethodBody(
            from: barSource,
            methodName: "private func tmuxWindowPills"
        )
        let newTabButtonBody = try extractMethodBody(
            from: barSource,
            methodName: "private var newTabButton"
        )

        XCTAssertFalse(
            topBarBody.contains("newTabButton"),
            "The + button must not be a standalone trailing top-bar item"
        )
        XCTAssertTrue(
            hostSessionPillsBody.contains("if !tabs.isEmpty")
                && hostSessionPillsBody.contains("newTabButton"),
            "The host-tab + button must be hidden on the no-tabs home screen and appear immediately after the host tabs"
        )
        XCTAssertTrue(
            tmuxWindowPillsBody.contains("if !tabs.isEmpty")
                && tmuxWindowPillsBody.contains("newTabButton"),
            "The tmux-window + button must be hidden on the no-tabs home screen and appear immediately after the tmux windows"
        )
        XCTAssertTrue(
            hostSessionPillsBody.contains("ForEach(Array(tabs.enumerated()), id: \\.element.id)")
                && hostSessionPillsBody.contains("shortcutHint: hostShortcutHint(forTabAt: index)"),
            "Host tabs must render their command-number shortcut hint from tab order"
        )
        XCTAssertTrue(
            tmuxWindowPillsBody.contains("ForEach(Array(controller.windowOrder.enumerated()), id: \\.element)")
                && tmuxWindowPillsBody.contains("shortcutHint: tmuxShortcutHint("),
            "tmux windows must render their command-number shortcut hint from visible window order"
        )

        XCTAssertTrue(
            newTabButtonBody.contains("Task { await controller.newWindow() }"),
            "The + button must create a tmux window while a tmux -CC session is attached"
        )
        XCTAssertTrue(
            newTabButtonBody.contains("onNewTerminalForTab(selectedTab)"),
            "The + button must open a new shared terminal tab on the current connection outside tmux mode"
        )
        XCTAssertTrue(
            newTabButtonBody.contains("onAddTab()"),
            "The + button must fall back to the new-connection sheet when the selected tab can't host a shared terminal"
        )
        XCTAssertTrue(
            barSource.contains(".accessibilityIdentifier(attachedController != nil ? \"tmux.window.new\" : \"host.session.new\")"),
            "The + button must expose mode-specific accessibility identifiers"
        )
    }

    /// Regression: connections and tmux windows share a single top bar. The
    /// tmux controls must only render for an attached tmux controller, and
    /// TerminalTab must no longer stack its own toolbar above the panes.
    func testUnifiedBarMergesConnectionAndTmuxRows() throws {
        let barSource = try readSourceFile("SSHApp/Views/UnifiedTopBar.swift")
        let switcherSource = try readSourceFile("SSHApp/Views/ConnectionSwitcherView.swift")
        let mainSource = try readSourceFile("SSHApp/Views/MainView.swift")
        let tabSource = try readSourceFile("SSHApp/Views/TerminalTab.swift")

        XCTAssertTrue(
            barSource.contains("controller.state.isAttached"),
            "Tmux controls must be gated on an attached tmux controller"
        )
        XCTAssertTrue(
            barSource.contains("TmuxWindowTabPill"),
            "Tmux windows must own the shared tab area as pills while attached"
        )
        XCTAssertTrue(
            barSource.contains("private func tmuxShortcutHint(forWindowAt index: Int, windowCount: Int) -> String?")
                && barSource.contains("guard hardwareKeyboardMonitor.isAttached else { return nil }"),
            "tmux window pill shortcut hints must be derived from indexed-tab mapping and gated by hardware keyboard attachment"
        )
        XCTAssertTrue(
            switcherSource.contains("private func connectionSection(_ group: TerminalTabGroup)")
                && switcherSource.contains("ConnectionMenuModel.groupMenu("),
            "Each connection must render as a switcher section composed from ConnectionMenuModel"
        )
        XCTAssertFalse(
            barSource.contains("tmuxSessionMenu"),
            "tmux windows must not regress to a nested per-session submenu"
        )
        XCTAssertTrue(
            switcherSource.contains("Task { await controller.selectWindow(window.id) }"),
            "Selecting a window row must route through TmuxController"
        )
        XCTAssertTrue(
            switcherSource.contains("connection.switcher.tmux.window.select"),
            "tmux window switcher entries must have stable accessibility identifiers"
        )
        XCTAssertFalse(
            barSource.contains("tmux.window.picker") || mainSource.contains("TmuxWindowPicker"),
            "The window picker sheet is gone; windows are reachable as pills and via the connection switcher"
        )
        XCTAssertFalse(
            barSource.contains("tmuxModeIndicator") || barSource.contains("tmux.mode.indicator"),
            "The compact top bar must not show a separate tmux indicator"
        )
        XCTAssertTrue(
            barSource.contains("hostSessionPills"),
            "Normal SSH sessions must render as top-bar host-session tabs"
        )
        XCTAssertTrue(
            barSource.contains(".accessibilityIdentifier(\"host.session.tabs\")"),
            "The normal host-session tab area must have a stable accessibility identifier"
        )
        XCTAssertTrue(
            mainSource.contains("UnifiedTopBar("),
            "MainView must render the unified top bar"
        )
        XCTAssertFalse(
            tabSource.contains("TmuxWindowTabBar"),
            "TerminalTab must not stack a second toolbar above the tmux panes"
        )
    }

    /// Regression: the connection pill opens a native switcher, not a SwiftUI
    /// Menu, while preserving switch, close, favorite, new-tab, and key-install
    /// semantics from the shipped connection menu.
    func testUnifiedBarConnectionSwitcherActions() throws {
        let barSource = try readSourceFile("SSHApp/Views/UnifiedTopBar.swift")
        let switcherSource = try readSourceFile("SSHApp/Views/ConnectionSwitcherView.swift")
        let mainSource = try readSourceFile("SSHApp/Views/MainView.swift")
        let installSheetSource = try readSourceFile("SSHApp/Views/InstallSSHKeySheet.swift")
        let sectionBody = try extractMethodBody(
            from: switcherSource,
            methodName: "private func connectionSection"
        )
        let entryRowsBody = try extractMethodBody(
            from: switcherSource,
            methodName: "private func entryRows"
        )
        let actionsRowBody = try extractMethodBody(
            from: switcherSource,
            methodName: "private func connectionActionsRow"
        )
        let newTabRowBody = try extractMethodBody(
            from: switcherSource,
            methodName: "private func newTabRow(for"
        )
        let newTmuxWindowRowBody = try extractMethodBody(
            from: switcherSource,
            methodName: "private func newTmuxWindowRow"
        )

        XCTAssertTrue(
            barSource.contains("private func connectionPillButton(for selectedTab: Tab) -> some View"),
            "The connection pill must stay a compact SwiftUI view"
        )
        XCTAssertFalse(
            barSource.contains("private struct ConnectionMenuPill: View")
                || barSource.contains(".accessibilityIdentifier(\"connection.menu\")"),
            "The connection pill must no longer be a SwiftUI Menu"
        )
        XCTAssertTrue(
            barSource.contains("@State private var isSwitcherPresented = false")
                && barSource.contains(".presentationDetents([.medium, .large])")
                && barSource.contains(".popover("),
            "The switcher must present as a compact sheet and regular-width popover"
        )
        XCTAssertTrue(
            switcherSource.contains(".accessibilityIdentifier(\"connection.switcher\")"),
            "The switcher must expose a stable root accessibility identifier"
        )
        XCTAssertTrue(
            barSource.contains("private func connectionPillTitle(for tab: Tab) -> String")
                && barSource.contains("connection.port == 22")
                && barSource.contains("connection.host"),
            "The connection pill must show host-only text while preserving non-22 ports"
        )
        XCTAssertFalse(
            barSource.contains("Text(selectedTab.connectionDisplayTitle)")
                || barSource.contains("Text(selectedTab.title)"),
            "OSC title changes and usernames must not rename the compact connection pill"
        )
        XCTAssertTrue(
            switcherSource.contains("onAddTab()")
                && switcherSource.contains(".accessibilityIdentifier(\"connection.switcher.newConnection\")"),
            "New Connection must remain reachable from the switcher"
        )
        XCTAssertTrue(
            actionsRowBody.contains("actionChip(")
                && actionsRowBody.contains("\"Disconnect\"")
                && actionsRowBody.contains("role: .destructive"),
            "Each connection's actions affordance must expose its own Disconnect action"
        )
        XCTAssertTrue(
            switcherSource.contains("onSelectTab(tab)")
                && switcherSource.contains("connection.switcher.tab.select"),
            "The connection switcher must switch between open connections"
        )
        XCTAssertTrue(
            switcherSource.contains("TerminalTabGrouping.groups(for: tabs)"),
            "The connection switcher must group open sessions by their live SSH connection"
        )
        XCTAssertTrue(
            sectionBody.contains("ConnectionMenuModel.groupMenu("),
            "Connection sections must be composed from ConnectionMenuModel"
        )
        XCTAssertTrue(
            switcherSource.contains("connection.switcher.connection.newTerminal"),
            "Reusable connection groups must expose their own New Tab action"
        )
        XCTAssertTrue(
            newTabRowBody.contains("onNewTerminalForTab(sourceTab)")
                && newTabRowBody.contains("group.canOpenNewTerminal"),
            "The section's New Tab row must open a plain shared channel even when a tmux session is attached"
        )
        XCTAssertTrue(
            newTabRowBody.contains("showsShortcutHint")
                && switcherSource.contains("showsShortcutHints && groupMenu.newTabShowsShortcutHint"),
            "The Cmd-T hint is contextual and gated by hardware keyboard state"
        )
        XCTAssertTrue(
            switcherSource.contains("showsShortcutHints && isSelected")
                && newTmuxWindowRowBody.contains("Task { await controller.newWindow() }")
                && newTmuxWindowRowBody.contains("onSelectTab(tab)"),
            "Each tmux session block must end with its own New tmux Tab row targeting that session"
        )
        XCTAssertFalse(
            switcherSource.contains("connecting…") || switcherSource.contains("connecting..."),
            "Favorite rows must keep current connect-and-dismiss semantics without inline connecting state"
        )
        XCTAssertTrue(
            switcherSource.contains("let savedConnections: [SavedConnection]"),
            "The connection switcher must receive saved connections from the app's query"
        )
        XCTAssertTrue(
            mainSource.contains("savedConnections: savedConnections"),
            "MainView must pass saved connections into the unified bar switcher"
        )
        XCTAssertTrue(
            switcherSource.contains("ForEach(favoriteConnections)")
                && switcherSource.contains("ConnectionMenuModel.favorites(savedConnections)")
                && switcherSource.contains("onConnectSavedConnection(connection)")
                && switcherSource.contains("connection.switcher.favorite.connect"),
            "Favorite saved connections must be one-tap connect rows in the switcher"
        )
        XCTAssertFalse(
            switcherSource.contains("onEditSavedConnection")
                || switcherSource.contains("savedConnectionsMenu"),
            "Editing stays in the Saved Connections manager rather than a nested switcher submenu"
        )
        XCTAssertTrue(
            actionsRowBody.contains("\"Install SSH Key\"")
                && actionsRowBody.contains("connection.switcher.connection.installSSHKey"),
            "Connected sessions must expose ssh-copy-id-style key installation"
        )
        XCTAssertTrue(
            switcherSource.contains("tab.connectionState == .connected && tab.session?.canOpenChannel == true"),
            "Install SSH Key must only be offered for live authenticated SSH sessions"
        )
        XCTAssertTrue(
            actionsRowBody.contains("onInstallSSHKey(installSourceTab)"),
            "Install SSH Key must target the tab belonging to that connection group"
        )
        XCTAssertTrue(
            actionsRowBody.contains("group.tabs.forEach")
                && actionsRowBody.contains("onCloseTab(tab)"),
            "Disconnect must operate on the selected connection group without switching tabs first"
        )
        XCTAssertTrue(
            mainSource.contains("InstallSSHKeySheet(tab: request.tab, keyStore: keyStore, connectionStore: connectionStore)"),
            "MainView must present the key installation sheet with the shared KeyStore and ConnectionStore"
        )
        XCTAssertTrue(
            installSheetSource.contains("GenerateKeySheet(keyStore: keyStore) { generatedKey in"),
            "The install sheet must allow generating a key and selecting it for installation"
        )
        let installSSHKeysSection = try XCTUnwrap(
            installSheetSource.range(of: #"Section("SSH Keys")"#),
            "The install sheet must present keys in the same named section as Credentials."
        )
        let installKeyRows = try XCTUnwrap(
            installSheetSource.range(of: "ForEach(keyStore.keys)", range: installSSHKeysSection.lowerBound..<installSheetSource.endIndex),
            "The install sheet SSH Keys section must list available keys as rows."
        )
        let installGenerateKeyAction = try XCTUnwrap(
            installSheetSource.range(of: #"Label("Generate New Key", systemImage: "plus.circle")"#),
            "The install sheet generate action must match the Credentials SSH Keys row style."
        )
        XCTAssertLessThan(
            installKeyRows.lowerBound,
            installGenerateKeyAction.lowerBound,
            "Generate New Key must stay as the last row in the install sheet SSH Keys section."
        )
        XCTAssertFalse(
            installSheetSource.contains("ContentUnavailableView")
                || installSheetSource.contains(#""No SSH Keys""#)
                || installSheetSource.contains("Generate a key to install on this host."),
            "The install sheet must not show an oversized empty-state card when there are no keys."
        )
        XCTAssertTrue(
            installSheetSource.contains("AuthorizedKeysInstaller.install(keys: [key], using: session)"),
            "The install sheet must install the selected public key through the connected session"
        )
        XCTAssertTrue(
            installSheetSource.contains("@State private var selectedKeyId: UUID?"),
            "The install sheet must allow selecting only a single SSH key"
        )
        XCTAssertFalse(
            installSheetSource.contains("Set<UUID>"),
            "The install sheet must not support multi-key selection"
        )

        let installBody = try extractMethodBody(
            from: installSheetSource,
            methodName: "private func installSelectedKey"
        )
        let authorizationIndex = try XCTUnwrap(
            installBody.range(of: "BiometricCredentialAuthorizer.authorizeStoredCredentialUse")?.lowerBound,
            "Key installation must honor credential protection with a biometric check"
        )
        let installIndex = try XCTUnwrap(
            installBody.range(of: "AuthorizedKeysInstaller.install")?.lowerBound,
            "installSelectedKey must run the remote installer"
        )
        XCTAssertTrue(
            installBody.contains("CredentialProtectionSettings.isEnabled()"),
            "The biometric check must be gated on the credential protection setting"
        )
        XCTAssertLessThan(
            authorizationIndex,
            installIndex,
            "The biometric check must run before the key is installed"
        )

        let associateBody = try extractMethodBody(
            from: installSheetSource,
            methodName: "private func associateInstalledKeyWithConnection"
        )
        XCTAssertTrue(
            installBody.contains("associateInstalledKeyWithConnection(key)"),
            "A successful install must associate the key with the saved connection"
        )
        XCTAssertTrue(
            associateBody.contains("connection.sshKeyId = key.id"),
            "The installed key must become the connection's SSH key"
        )
        XCTAssertTrue(
            associateBody.contains("connectionStore.saveChanges(touching: connection)"),
            "The key association must be persisted and marked for connection sync"
        )
        XCTAssertTrue(
            associateBody.contains("KeychainService.hasPassword(forConnectionId: connection.id)"),
            "The password-delete prompt must only appear when a password is saved"
        )
        XCTAssertTrue(
            installSheetSource.contains("\"Delete Saved Password?\""),
            "The install sheet must offer to delete a saved password after key installation"
        )
        XCTAssertTrue(
            installSheetSource.contains("KeychainService.deletePassword(forConnectionId: connection.id)"),
            "Confirming the prompt must delete the connection's saved password"
        )
    }

    func testCommandTRoutesContextually() throws {
        let shortcutSource = try readSourceFile("SSHApp/Views/TerminalTabShortcut.swift")
        let mainSource = try readSourceFile("SSHApp/Views/MainView.swift")
        let body = try extractMethodBody(from: mainSource, methodName: "private func openTerminalOnSelectedServer")

        XCTAssertTrue(
            shortcutSource.contains("case newTerminal"),
            "TerminalTabShortcut must expose a host-level new-terminal action"
        )
        XCTAssertTrue(
            shortcutSource.contains(".init(input: \"t\", modifierFlags: [.command], shortcut: .newTerminal)"),
            "Cmd-T must map to the new-terminal action"
        )
        XCTAssertTrue(
            body.contains("controller.state.isAttached"),
            "Cmd-T must prefer tmux window creation while attached to tmux control mode"
        )
        XCTAssertTrue(
            body.contains("await controller.newWindow()"),
            "Cmd-T in tmux mode must create a tmux window"
        )
        XCTAssertTrue(
            body.contains("session.canOpenChannel"),
            "Cmd-T outside tmux must require a reusable authenticated SSH session"
        )
        XCTAssertTrue(
            body.contains("openSharedChannelInNewTab"),
            "Cmd-T outside tmux must open another top-level tab on the same SSH session"
        )
    }

    func testNativeCommandMenuExposesTabShortcuts() throws {
        let appSource = try readSourceFile("SSHApp/App/SSHApp.swift")
        let commandSource = try readSourceFile("SSHApp/App/SSHAppCommands.swift")
        let mainSource = try readSourceFile("SSHApp/Views/MainView.swift")

        XCTAssertTrue(
            appSource.contains(".commands {"),
            "The app scene must install native SwiftUI commands for menu bar and shortcut HUD integration"
        )
        XCTAssertTrue(
            appSource.contains("SSHAppCommands()"),
            "The app scene must include the SSHApp command menu"
        )
        XCTAssertTrue(
            commandSource.contains("CommandMenu(\"Connection\")"),
            "Connection commands must be grouped in a native command menu"
        )
        XCTAssertTrue(
            commandSource.contains("@FocusedValue(\\.sshAppCommandActions)"),
            "Native commands must route through the focused MainView action bridge"
        )
        XCTAssertTrue(
            commandSource.contains("var selectIndexedTab: (Int) -> Void")
                && commandSource.contains("var canSelectIndexedTab: (Int) -> Bool"),
            "Native command-number shortcuts must route through MainView instead of depending on terminal first responder"
        )
        XCTAssertTrue(
            mainSource.contains(".focusedSceneValue(\\.sshAppCommandActions, appCommandActions)"),
            "MainView must publish command actions to the focused scene"
        )
        XCTAssertTrue(
            commandSource.contains("Button(actions?.isTmuxAttached == true ? \"New tmux Tab\" : \"New Tab\")"),
            "The native New Tab command must reflect tmux mode"
        )
        XCTAssertTrue(
            commandSource.contains(".keyboardShortcut(\"t\", modifiers: .command)"),
            "The native New Tab command must expose Cmd-T"
        )
        XCTAssertTrue(
            commandSource.contains("Button(\"Close Tab\")"),
            "The native command menu must expose Close Tab"
        )
        XCTAssertTrue(
            commandSource.contains(".keyboardShortcut(\"w\", modifiers: .command)"),
            "Close Tab must use Cmd-W"
        )
        XCTAssertTrue(
            commandSource.contains("ForEach(IndexedTabNavigation.shortcutDigits")
                && commandSource.contains(".keyboardShortcut(KeyEquivalent(Character(String(digit))), modifiers: .command)"),
            "Command-number shortcuts must be installed as native scene commands"
        )
        XCTAssertTrue(
            commandSource.contains("actions?.isTmuxAttached == true ? \"tmux Tab\" : \"Tab\"")
                || commandSource.contains("let label = isTmuxAttached ? \"tmux Tab\" : \"Tab\""),
            "Native command-number labels must reflect whether tmux controls own the tab strip"
        )
        XCTAssertTrue(
            mainSource.contains("private func selectIndexedTabShortcut")
                && mainSource.contains("controller.selectWindow(shortcutDigit: digit)")
                && mainSource.contains("IndexedTabNavigation.item(forShortcutDigit: digit, in: tabIDs)"),
            "Cmd-number must select tmux windows in tmux mode and host tabs outside tmux mode"
        )
        XCTAssertTrue(
            mainSource.contains("private func closeSelectedTab()"),
            "Cmd-W must close the selected tab through MainView"
        )
        XCTAssertTrue(
            commandSource.contains(".keyboardShortcut(\"[\", modifiers: [.command, .shift])"),
            "Previous host tab must use the existing Cmd-Shift-[ shortcut"
        )
        XCTAssertTrue(
            commandSource.contains(".keyboardShortcut(\"]\", modifiers: [.command, .shift])"),
            "Next host tab must use the existing Cmd-Shift-] shortcut"
        )
        XCTAssertTrue(
            commandSource.contains(".keyboardShortcut(\"[\", modifiers: [.command, .option])"),
            "Previous tmux tab must use the existing Cmd-Option-[ shortcut"
        )
        XCTAssertTrue(
            commandSource.contains(".keyboardShortcut(\"]\", modifiers: [.command, .option])"),
            "Next tmux tab must use the existing Cmd-Option-] shortcut"
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
