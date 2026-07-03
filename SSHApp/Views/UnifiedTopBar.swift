//
//  UnifiedTopBar.swift
//  SSHApp
//
//  Single top bar combining connection switching, session/window tabs, and
//  toolbar actions. The connection is a compact menu pill on the left. When a
//  tmux -CC session is attached, its windows own the shared tab area, the
//  tmux pill doubles as the split-pane menu, and sibling sessions on the same
//  connection are reachable from the connection menu, where each tmux session
//  expands into its window list.
//

import SwiftUI
import UIKit
import os

private let logger = Logger(subsystem: "dev.sshapp.sshapp.tmux", category: "top-bar")

struct UnifiedTopBar: View {
    let tabs: [Tab]
    let selectedTab: Tab?
    let savedConnections: [SavedConnection]
    let keyStore: KeyStore
    @Binding var showKeyboardBar: Bool
    let onAddTab: () -> Void
    let onNewTerminalForTab: (Tab) -> Void
    let onConnectSavedConnection: (SavedConnection) -> Void
    let onEditSavedConnection: (SavedConnection) -> Void
    let onInstallSSHKey: (Tab) -> Void
    let onSelectTab: (Tab) -> Void
    let onCloseTab: (Tab) -> Void
    let onSettings: (SettingsDestination) -> Void

    /// The selected tab's tmux controller, only while attached in control mode.
    private var attachedController: TmuxController? {
        guard let controller = selectedTab?.tmuxController,
              controller.state.isAttached else {
            return nil
        }
        return controller
    }

    var body: some View {
        HStack(spacing: 8) {
            if let selectedTab {
                ConnectionMenuPill(
                    tabs: tabs,
                    selectedTab: selectedTab,
                    savedConnections: savedConnections,
                    keyStore: keyStore,
                    onSelectTab: onSelectTab,
                    onCloseTab: onCloseTab,
                    onAddTab: onAddTab,
                    onNewTerminalForTab: onNewTerminalForTab,
                    onConnectSavedConnection: onConnectSavedConnection,
                    onEditSavedConnection: onEditSavedConnection,
                    onInstallSSHKey: onInstallSSHKey
                )
            }

            if let controller = attachedController {
                tmuxModeIndicator(controller: controller)
                tmuxWindowPills(controller: controller)
            } else {
                hostSessionPills
            }

            if !tabs.isEmpty {
                newTabButton
            }

            settingsMenu
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(TerminalRuntime.shared.appPalette.background.opacity(0.95))
    }

    private var hostSessionPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(tabs) { tab in
                    HostSessionTabPill(
                        tab: tab,
                        isSelected: tab.id == selectedTab?.id,
                        onSelect: {
                            onSelectTab(tab)
                        }
                    )
                }
            }
            .padding(.horizontal, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("host.session.tabs")
    }

    /// tmux windows own the shared tab area while attached in control mode;
    /// sibling sessions on the same connection live in the connection menu.
    private func tmuxWindowPills(controller: TmuxController) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(controller.windowOrder, id: \.self) { windowID in
                    if let window = controller.windows[windowID] {
                        TmuxWindowTabPill(
                            window: window,
                            isSelected: window.id == controller.activeWindowID,
                            onSelect: {
                                Task { await controller.selectWindow(window.id) }
                            }
                        )
                    }
                }
            }
            .padding(.horizontal, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The "tmux" pill: indicates control mode and opens the split-pane menu.
    private func tmuxModeIndicator(controller: TmuxController) -> some View {
        Menu {
            Button {
                splitPane(.right, controller: controller)
            } label: {
                Label("Split Right", systemImage: "rectangle.split.2x1")
            }
            .accessibilityIdentifier("tmux.pane.split.right")

            Button {
                splitPane(.down, controller: controller)
            } label: {
                Label("Split Down", systemImage: "rectangle.split.1x2")
            }
            .accessibilityIdentifier("tmux.pane.split.down")
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "rectangle.split.3x1")
                    .font(.system(size: 11, weight: .semibold))

                Text("tmux")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(TerminalRuntime.shared.appPalette.secondaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(TerminalRuntime.shared.appPalette.surfaceHigh)
            .clipShape(Capsule())
        }
        .accessibilityIdentifier("tmux.mode.indicator")
        .accessibilityLabel("tmux, split pane")
    }

    /// New-tab button: a new tmux window while attached in control mode, a new
    /// shared terminal on the current connection otherwise, falling back to
    /// the new-connection sheet when the selected tab can't host one.
    private var newTabButton: some View {
        CircleIconButton(systemImage: "plus", size: 16, filled: true) {
            if let controller = attachedController {
                Task { await controller.newWindow() }
            } else if let selectedTab,
                      selectedTab.session?.canOpenChannel == true,
                      selectedTab.connection != nil {
                onNewTerminalForTab(selectedTab)
            } else {
                onAddTab()
            }
        }
        .accessibilityIdentifier(attachedController != nil ? "tmux.window.new" : "host.session.new")
        .accessibilityLabel(attachedController != nil ? "New tmux window" : "New tab")
    }

    private var settingsMenu: some View {
        Menu {
            Toggle(isOn: $showKeyboardBar) {
                Label("Keyboard Bar", systemImage: "keyboard")
            }
            .accessibilityIdentifier("keyboard.toggle")

            Divider()

            Button {
                onSettings(.credentials)
            } label: {
                Label("Credentials", systemImage: "key")
            }
            .accessibilityIdentifier("settings.credentials")

            Button {
                onSettings(.font)
            } label: {
                Label("Font", systemImage: "textformat.size")
            }
            .accessibilityIdentifier("settings.font")

            Button {
                onSettings(.theme)
            } label: {
                Label("Theme", systemImage: "paintpalette")
            }
            .accessibilityIdentifier("settings.theme")

            Button {
                onSettings(.tmux)
            } label: {
                Label("tmux", systemImage: "rectangle.split.3x1")
            }
            .accessibilityIdentifier("settings.tmux")

            Button {
                onSettings(.licenses)
            } label: {
                Label("Licenses", systemImage: "doc.text")
            }
            .accessibilityIdentifier("settings.licenses")
        } label: {
            CircleIcon(systemImage: "gearshape", size: 16, filled: false)
        }
        .accessibilityIdentifier("settings.open")
        .accessibilityLabel("Settings")
    }

    private func splitPane(_ direction: TmuxSplitDirection, controller: TmuxController) {
        logger.info("split-pane action selected direction=\(direction.description, privacy: .public) activePane=\(controller.activePaneID?.wire ?? "nil", privacy: .public)")
        Task { await controller.splitPane(direction) }
    }
}

/// Compact pill showing the selected connection; tapping opens a menu for
/// switching between open connections, adding, and closing.
///
/// The menu is a plain SwiftUI `Menu`, like the bar's settings and split
/// menus. iPadOS (verified on 26.5 with a hardware keyboard attached) draws
/// no key-equivalent column in ANY in-app menu — not for `UIKeyCommand` menu
/// elements, and `UIAction.subtitle` set from UIKit does not render in these
/// menus either. Menu rows draw only icon, title, and (via SwiftUI's
/// two-`Text` rows) a subtitle; custom trailing views, badges, and
/// `LabeledContent` values are stripped, so a right-aligned shortcut column
/// cannot be drawn. The "⌘T" hint therefore rides the title line itself
/// (`titleWithShortcutHint`). The shortcuts are owned by the menu-bar
/// commands (`SSHAppCommands`) and the terminal's key handling; the menu bar
/// is also the only surface where iPadOS shows the native shortcut column.
private struct ConnectionMenuPill: View {
    let tabs: [Tab]
    let selectedTab: Tab
    let savedConnections: [SavedConnection]
    let keyStore: KeyStore
    let onSelectTab: (Tab) -> Void
    let onCloseTab: (Tab) -> Void
    let onAddTab: () -> Void
    let onNewTerminalForTab: (Tab) -> Void
    let onConnectSavedConnection: (SavedConnection) -> Void
    let onEditSavedConnection: (SavedConnection) -> Void
    let onInstallSSHKey: (Tab) -> Void

    private var palette: AppPalette { TerminalRuntime.shared.appPalette }
    private var groups: [TerminalTabGroup] { TerminalTabGrouping.groups(for: tabs) }

    var body: some View {
        Menu {
            ForEach(groups) { group in
                connectionGroupMenu(group)
            }

            Divider()

            Button {
                onAddTab()
            } label: {
                Label {
                    titleWithShortcutHint("New Connection", "⌘N", alignedAfter: rootMenuActionTitles)
                } icon: {
                    Image(systemName: "plus")
                }
            }
            .accessibilityIdentifier("tab.add")

            if !savedConnections.isEmpty {
                savedConnectionsMenu
            }
        } label: {
            connectionPillLabel
        }
        .accessibilityIdentifier("connection.menu")
        .accessibilityLabel("Connection \(selectedTab.title)")
    }

    private func connectionGroupMenu(_ group: TerminalTabGroup) -> some View {
        Menu {
            ForEach(group.tabs) { tab in
                if let controller = tab.tmuxController, controller.state.isAttached {
                    tmuxSessionMenu(for: tab, controller: controller)
                } else {
                    Button {
                        onSelectTab(tab)
                    } label: {
                        Label(tab.title, systemImage: tabIcon(for: tab))
                    }
                    .accessibilityIdentifier("tab.select.\(tab.id.uuidString)")
                }
            }

            Divider()

            newTabMenuItem(for: group)

            if let installSourceTab = installSSHKeySourceTab(in: group) {
                Button {
                    onInstallSSHKey(installSourceTab)
                } label: {
                    Label("Install SSH Key", systemImage: "key")
                }
                .accessibilityIdentifier("connection.installSSHKey.\(group.primaryTab.id.uuidString)")
            }

            Button(role: .destructive) {
                group.tabs.forEach { tab in
                    onCloseTab(tab)
                }
            } label: {
                Label("Disconnect", systemImage: "xmark")
            }
            .accessibilityIdentifier("connection.group.disconnect.\(group.primaryTab.id.uuidString)")
        } label: {
            Label(group.title, systemImage: group.containsAttachedTmux ? "rectangle.split.3x1" : "terminal")
        }
        .accessibilityIdentifier("connection.group.\(group.primaryTab.id.uuidString)")
    }

    /// Row for a tmux-attached session inside a connection group's submenu.
    /// The session expands into its tmux window list; tapping a window
    /// selects the session and window.
    private func tmuxSessionMenu(for tab: Tab, controller: TmuxController) -> some View {
        Menu {
            ForEach(controller.windowOrder, id: \.self) { windowID in
                if let window = controller.windows[windowID] {
                    Button {
                        onSelectTab(tab)
                        Task { await controller.selectWindow(window.id) }
                    } label: {
                        Label(
                            window.name.isEmpty ? window.id.wire : window.name,
                            systemImage: window.id == controller.activeWindowID ? "checkmark" : "terminal"
                        )
                    }
                    .accessibilityIdentifier("tmux.windows.menu.select.\(window.id.rawValue)")
                }
            }

            Divider()

            Button {
                Task { await controller.detach() }
            } label: {
                Label("Detach tmux", systemImage: "rectangle.portrait.and.arrow.right")
            }
            .accessibilityIdentifier("tmux.detach")
        } label: {
            Label(tab.title, systemImage: tabIcon(for: tab))
        }
        .accessibilityIdentifier("tmux.windows.menu.\(tab.id.uuidString)")
    }

    @ViewBuilder
    private func newTabMenuItem(for group: TerminalTabGroup) -> some View {
        if let tmuxSourceTab = attachedTmuxSourceTab(in: group),
           let controller = tmuxSourceTab.tmuxController {
            Button {
                onSelectTab(tmuxSourceTab)
                Task { await controller.newWindow() }
            } label: {
                Label {
                    titleWithShortcutHint(
                        "New tmux Tab",
                        "⌘T",
                        alignedAfter: groupMenuActionTitles(for: group, newTabTitle: "New tmux Tab")
                    )
                } icon: {
                    Image(systemName: "terminal")
                }
            }
            .accessibilityIdentifier("connection.group.newTerminal.\(group.primaryTab.id.uuidString)")
        } else if group.canOpenNewTerminal, let sourceTab = group.newTerminalSourceTab {
            Button {
                onNewTerminalForTab(sourceTab)
            } label: {
                Label {
                    titleWithShortcutHint(
                        "New Tab",
                        "⌘T",
                        alignedAfter: groupMenuActionTitles(for: group, newTabTitle: "New Tab")
                    )
                } icon: {
                    Image(systemName: "terminal")
                }
            }
            .accessibilityIdentifier("connection.group.newTerminal.\(group.primaryTab.id.uuidString)")
        }
    }

    private var savedConnectionsMenu: some View {
        Menu {
            ForEach(savedConnections) { connection in
                Menu {
                    Button {
                        onConnectSavedConnection(connection)
                    } label: {
                        Label("Connect", systemImage: "terminal")
                    }
                    .accessibilityIdentifier("savedConnection.connect.\(connection.id.uuidString)")

                    Button {
                        onEditSavedConnection(connection)
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .accessibilityIdentifier("savedConnection.edit.\(connection.id.uuidString)")
                } label: {
                    Label(connection.displayDestination, systemImage: hasUsableKey(connection) ? "key" : "lock")
                }
            }
        } label: {
            Label("Saved Connections", systemImage: "bookmark")
        }
        .accessibilityIdentifier("savedConnections.menu")
    }

    private func hasUsableKey(_ connection: SavedConnection) -> Bool {
        connection.sshKeyId.flatMap { keyStore.key(withId: $0) } != nil
    }

    /// Menu-row title with the "⌘T"-style hint on the same line, aligned to a
    /// shared trailing column. iPadOS draws no key-equivalent column in in-app
    /// menus and strips custom trailing views, badges, and `LabeledContent`
    /// values from menu rows, so the title text itself is the only way to put
    /// the hint to the right of the label. It also strips color, font, and
    /// weight styling from title text (verified on 26.5), so the hint cannot
    /// be dimmed — `.secondary` is kept for OS versions that honor it.
    ///
    /// To line hints up in a column, each hinted title is padded with spaces
    /// so the hint's trailing edge matches the trailing edge of the widest
    /// sibling title passed in `alignedAfter` (the menu's static action
    /// titles — dynamic host names are excluded so the column doesn't jump
    /// as connections change).
    private func titleWithShortcutHint(
        _ title: String,
        _ hint: String,
        alignedAfter siblingTitles: [String]
    ) -> Text {
        let font = UIFont.preferredFont(forTextStyle: .body)
        func width(_ string: String) -> CGFloat {
            (string as NSString).size(withAttributes: [.font: font]).width
        }

        // Right-align the hint's trailing edge with the widest sibling
        // title's trailing edge, like the macOS shortcut column. Padding then
        // never pushes a row wider than a title the menu already renders, so
        // it cannot introduce wrapping. If the hinted title itself is too
        // long for that column, fall back to a single em-space gap.
        let hintEnd = siblingTitles.map(width).max() ?? 0
        let target = max(hintEnd - width(hint), width(title) + width("\u{2003}"))
        var padded = title
        for pad in ["\u{2003}", "\u{2002}", "\u{2009}", "\u{200A}"] {
            while width(padded + pad) <= target {
                padded += pad
            }
        }
        return Text(padded) + Text(hint).foregroundColor(.secondary)
    }

    /// Static action titles of the pill's root menu, used to place the
    /// shortcut-hint column.
    private var rootMenuActionTitles: [String] {
        var titles = ["New Connection"]
        if !savedConnections.isEmpty {
            titles.append("Saved Connections")
        }
        return titles
    }

    /// Static action titles of a connection group's submenu, used to place
    /// the shortcut-hint column.
    private func groupMenuActionTitles(for group: TerminalTabGroup, newTabTitle: String) -> [String] {
        var titles = [newTabTitle, "Disconnect"]
        if installSSHKeySourceTab(in: group) != nil {
            titles.append("Install SSH Key")
        }
        return titles
    }

    private func tabIcon(for tab: Tab) -> String {
        if tab.id == selectedTab.id {
            return "checkmark"
        }

        if tab.tmuxController?.state.isAttached == true {
            return "rectangle.split.3x1"
        }

        return "terminal"
    }

    private func attachedTmuxSourceTab(in group: TerminalTabGroup) -> Tab? {
        group.tabs.first { tab in
            tab.tmuxController?.state.isAttached == true
        }
    }

    private func installSSHKeySourceTab(in group: TerminalTabGroup) -> Tab? {
        group.tabs.first { tab in
            tab.connectionState == .connected && tab.session?.canOpenChannel == true
        }
    }

    private var connectionPillLabel: some View {
        HStack(spacing: 6) {
            if let statusColor {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
            }

            Text(selectedTab.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(palette.primaryText)
                .lineLimit(1)

            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(palette.secondaryText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(palette.surface)
        .clipShape(Capsule())
        .fixedSize(horizontal: true, vertical: false)
    }

    private var statusColor: Color? {
        switch selectedTab.connectionState {
        case .disconnected: palette.secondaryText
        case .connecting, .awaitingInput: palette.warning
        case .connected: nil
        case .failed: palette.error
        }
    }
}

/// Host terminal session chip shown when tmux windows are not occupying the
/// shared tab area.
private struct HostSessionTabPill: View {
    let tab: Tab
    let isSelected: Bool
    let onSelect: () -> Void

    private var palette: AppPalette { TerminalRuntime.shared.appPalette }

    var body: some View {
        HStack(spacing: 6) {
            if let statusColor {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
            }

            Text(tab.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(palette.primaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isSelected ? palette.accentChip : palette.surface)
        .clipShape(Capsule())
        .contentShape(Capsule())
        .onTapGesture(perform: onSelect)
        .accessibilityIdentifier("host.session.tab.\(tab.id.uuidString)")
    }

    private var statusColor: Color? {
        switch tab.connectionState {
        case .disconnected: palette.secondaryText
        case .connecting, .awaitingInput: palette.warning
        case .connected: nil
        case .failed: palette.error
        }
    }
}

/// tmux window chip: window name and a pane-count badge for
/// windows with splits.
struct TmuxWindowTabPill: View {
    let window: TmuxWindow
    let isSelected: Bool
    let onSelect: () -> Void

    private var palette: AppPalette { TerminalRuntime.shared.appPalette }

    var body: some View {
        HStack(spacing: 6) {
            Text(displayName)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(palette.primaryText)
                .lineLimit(1)

            if window.paneIDs.count > 1 {
                Text("\(window.paneIDs.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(palette.secondaryText)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(palette.surfaceHigh)
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isSelected ? palette.accentChip : palette.surface)
        .clipShape(Capsule())
        .contentShape(Capsule())
        .onTapGesture(perform: onSelect)
        .accessibilityIdentifier("tmux.window.tab.\(window.id.rawValue)")
    }

    private var displayName: String {
        window.name.isEmpty ? window.id.wire : window.name
    }
}

/// Circular toolbar icon shared by the bar's trailing buttons.
private struct CircleIcon: View {
    let systemImage: String
    let size: CGFloat
    let filled: Bool

    private var palette: AppPalette { TerminalRuntime.shared.appPalette }

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size, weight: .medium))
            .foregroundColor(palette.primaryText)
            .frame(width: 32, height: 32)
            .background(filled ? palette.surface : .clear)
            .clipShape(Circle())
    }
}

private struct CircleIconButton: View {
    let systemImage: String
    let size: CGFloat
    let filled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            CircleIcon(systemImage: systemImage, size: size, filled: filled)
        }
        .buttonStyle(.plain)
    }
}
