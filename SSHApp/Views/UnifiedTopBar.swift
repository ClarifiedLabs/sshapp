//
//  UnifiedTopBar.swift
//  SSHApp
//
//  Single top bar combining connection switching, session/window tabs, and
//  toolbar actions. The connection is a compact menu pill on the left. When a
//  tmux -CC session is attached, its windows own the shared tab area and the
//  tmux pill doubles as the split-pane menu. The connection menu is flat: one
//  section per connection whose tabs and tmux windows are directly tappable
//  rows, so any destination is two taps away.
//

import SwiftUI
import UIKit
import os

private let logger = Logger(subsystem: "dev.sshapp.sshapp.tmux", category: "top-bar")

private enum TabPillLayout {
    static let shortcutSpacing: CGFloat = 6
    static let horizontalPadding: CGFloat = 10
    static let verticalPadding: CGFloat = 6
    static let maximumWidth: CGFloat = 180
}

enum MenuShortcutHintTitle {
    struct RenderedTitle: Equatable {
        let title: String
        let hint: String?
    }

    static let compactMenuTitleWidth: CGFloat = 150
    static let noBreakSpace = "\u{00A0}"
    static let narrowNoBreakSpace = "\u{202F}"
    static let wordJoiner = "\u{2060}"

    static func text(
        _ title: String,
        _ hint: String,
        alignedAfter siblingTitles: [String],
        horizontalSizeClass: UserInterfaceSizeClass?,
        font: UIFont = .preferredFont(forTextStyle: .body)
    ) -> Text {
        let rendered = renderedTitle(
            title,
            hint,
            alignedAfter: siblingTitles,
            maximumWidth: maximumWidth(horizontalSizeClass: horizontalSizeClass),
            font: font
        )

        guard let hint = rendered.hint else {
            return Text(rendered.title)
        }

        return Text(rendered.title) + Text(hint).foregroundColor(.secondary)
    }

    static func maximumWidth(horizontalSizeClass: UserInterfaceSizeClass?) -> CGFloat? {
        guard horizontalSizeClass == .compact else { return nil }
        return compactMenuTitleWidth
    }

    static func renderedTitle(
        _ title: String,
        _ hint: String,
        alignedAfter siblingTitles: [String],
        maximumWidth: CGFloat?,
        font: UIFont
    ) -> RenderedTitle {
        let paddedTitle = paddedTitle(
            title,
            hint: hint,
            alignedAfter: siblingTitles,
            font: font
        )
        let hintedWidth = width(paddedTitle + hint, font: font)

        if let maximumWidth, hintedWidth > maximumWidth {
            return RenderedTitle(title: title, hint: nil)
        }

        return RenderedTitle(title: paddedTitle, hint: hint)
    }

    static func width(_ string: String, font: UIFont) -> CGFloat {
        (string as NSString).size(withAttributes: [.font: font]).width
    }

    private static func paddedTitle(
        _ title: String,
        hint: String,
        alignedAfter siblingTitles: [String],
        font: UIFont
    ) -> String {
        let hintEnd = siblingTitles.map { width($0, font: font) }.max() ?? 0
        let target = max(
            hintEnd - width(hint, font: font),
            width(title + noBreakSpace, font: font)
        )
        var padded = title

        for pad in [noBreakSpace, narrowNoBreakSpace] {
            while width(padded + pad, font: font) <= target {
                padded += pad
            }
        }

        if padded == title {
            padded += narrowNoBreakSpace
        }

        return padded + wordJoiner
    }
}

struct UnifiedTopBar: View {
    let tabs: [Tab]
    let selectedTab: Tab?
    let savedConnections: [SavedConnection]
    @Binding var showKeyboardBar: Bool
    let onAddTab: () -> Void
    let onNewTerminalForTab: (Tab) -> Void
    let onConnectSavedConnection: (SavedConnection) -> Void
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
                    onSelectTab: onSelectTab,
                    onCloseTab: onCloseTab,
                    onAddTab: onAddTab,
                    onNewTerminalForTab: onNewTerminalForTab,
                    onConnectSavedConnection: onConnectSavedConnection,
                    onInstallSSHKey: onInstallSSHKey,
                    onSettings: onSettings
                )
            }

            if let controller = attachedController {
                tmuxModeIndicator(controller: controller)
                tmuxWindowPills(controller: controller)
            } else {
                hostSessionPills
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
                ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                    HostSessionTabPill(
                        tab: tab,
                        isSelected: tab.id == selectedTab?.id,
                        shortcutHint: hostShortcutHint(forTabAt: index),
                        onSelect: {
                            onSelectTab(tab)
                        },
                        onClose: {
                            onCloseTab(tab)
                        },
                        onNewTerminal: tab.session?.canOpenChannel == true && tab.connection != nil
                            ? { onNewTerminalForTab(tab) }
                            : nil
                    )
                }

                if !tabs.isEmpty {
                    newTabButton
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
                ForEach(Array(controller.windowOrder.enumerated()), id: \.element) { index, windowID in
                    if let window = controller.windows[windowID] {
                        TmuxWindowTabPill(
                            window: window,
                            controller: controller,
                            isSelected: window.id == controller.activeWindowID,
                            shortcutHint: tmuxShortcutHint(
                                forWindowAt: index,
                                windowCount: controller.windowOrder.count
                            ),
                            onSelect: {
                                Task { await controller.selectWindow(window.id) }
                            }
                        )
                    }
                }

                if !tabs.isEmpty {
                    newTabButton
                }
            }
            .padding(.horizontal, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hostShortcutHint(forTabAt index: Int) -> String? {
        IndexedTabNavigation.shortcutDigit(forItemAt: index, itemCount: tabs.count).map { "⌘\($0)" }
    }

    private func tmuxShortcutHint(forWindowAt index: Int, windowCount: Int) -> String? {
        IndexedTabNavigation.shortcutDigit(forItemAt: index, itemCount: windowCount).map { "⌘\($0)" }
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
                onSettings(.connections)
            } label: {
                Label("Connections", systemImage: "bookmark")
            }
            .accessibilityIdentifier("settings.connections")

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

/// Compact pill showing the selected connection; tapping opens a flat menu:
/// one section per open connection whose tabs and tmux windows are directly
/// tappable rows, followed by New Connection, favorite saved connections,
/// and the Saved Connections manager. Rare per-connection actions (Install
/// SSH Key, Detach, Disconnect) live in a single Connection… submenu per
/// section so navigation stays one tap deep.
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
    let onSelectTab: (Tab) -> Void
    let onCloseTab: (Tab) -> Void
    let onAddTab: () -> Void
    let onNewTerminalForTab: (Tab) -> Void
    let onConnectSavedConnection: (SavedConnection) -> Void
    let onInstallSSHKey: (Tab) -> Void
    let onSettings: (SettingsDestination) -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var palette: AppPalette { TerminalRuntime.shared.appPalette }
    private var groups: [TerminalTabGroup] { TerminalTabGrouping.groups(for: tabs) }

    var body: some View {
        Menu {
            ForEach(groups) { group in
                connectionSection(group)
            }

            Section {
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

                ForEach(favoriteConnections) { connection in
                    Button {
                        onConnectSavedConnection(connection)
                    } label: {
                        Label(connection.displayDestination, systemImage: "star.fill")
                    }
                    .accessibilityIdentifier("savedConnection.connect.\(connection.id.uuidString)")
                }

                Button {
                    onSettings(.connections)
                } label: {
                    Label("Saved Connections…", systemImage: "bookmark")
                }
                .accessibilityIdentifier("savedConnections.open")
            }
        } label: {
            connectionPillLabel
        }
        .accessibilityIdentifier("connection.menu")
        .accessibilityLabel("Connection \(selectedTab.connectionDisplayTitle)")
    }

    /// Indent prefix that tucks tmux window rows under their session row.
    private var tmuxWindowIndent: String { "\u{2003}" }

    /// One connection's menu section: every tab is a direct row (tmux tabs
    /// expand their windows in place), followed by the plain New Tab row and
    /// the Connection… actions submenu.
    private func connectionSection(_ group: TerminalTabGroup) -> some View {
        let groupMenu = ConnectionMenuModel.groupMenu(
            for: group,
            selectedTabID: selectedTab.id,
            tmuxSession: tmuxMenuSnapshot(for:)
        )

        return Section(group.title) {
            ForEach(groupMenu.entries) { entry in
                entryRows(entry, in: group)
            }

            newTabRow(for: group, showsShortcutHint: groupMenu.newTabShowsShortcutHint)

            connectionActionsMenu(for: group)
        }
    }

    @ViewBuilder
    private func entryRows(_ entry: ConnectionMenuModel.Entry, in group: TerminalTabGroup) -> some View {
        switch entry {
        case .tab(let tabID, let title, let isSelected):
            if let tab = group.tabs.first(where: { $0.id == tabID }) {
                Button {
                    onSelectTab(tab)
                } label: {
                    Label(title, systemImage: isSelected ? "checkmark" : "terminal")
                }
                .accessibilityIdentifier("tab.select.\(tabID.uuidString)")
            }
        case .tmuxSession(let tabID, let title, let isSelected, let windows):
            if let tab = group.tabs.first(where: { $0.id == tabID }),
               let controller = tab.tmuxController {
                Menu {
                    Button {
                        Task { await controller.detach() }
                    } label: {
                        Label("Detach tmux", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .accessibilityIdentifier("tmux.detach.\(tabID.uuidString)")
                } label: {
                    // Two Texts render as title + subtitle in menu rows; the
                    // subtitle marks the tab as a tmux -CC session. Tapping
                    // the row expands the session's action menu — nested
                    // menus ignore primaryAction on tap (verified on 26.5),
                    // so it is kept only for platforms that split the row.
                    // Switching to the session happens via its window rows.
                    Text(title)
                    Text("tmux")
                    Image(systemName: "rectangle.split.3x1")
                } primaryAction: {
                    onSelectTab(tab)
                }
                .accessibilityIdentifier("tab.select.\(tabID.uuidString)")

                windowRows(windows, tab: tab, controller: controller)

                newTmuxWindowRow(tab: tab, controller: controller, showsShortcutHint: isSelected)
            }
        }
    }

    /// Window rows indented under their tmux session row; tapping selects
    /// the session's tab and window in one go.
    private func windowRows(
        _ windows: [ConnectionMenuModel.Window],
        tab: Tab,
        controller: TmuxController
    ) -> some View {
        ForEach(windows) { window in
            Button {
                onSelectTab(tab)
                Task { await controller.selectWindow(window.id) }
            } label: {
                Label(
                    tmuxWindowIndent + window.title,
                    systemImage: window.isCurrent ? "checkmark" : "arrow.turn.down.right"
                )
            }
            .accessibilityIdentifier("tmux.windows.menu.select.\(window.id.rawValue)")
        }
    }

    /// "New tmux Tab" directly under a session's windows; ⌘T targets it only
    /// while that session's tab is selected.
    private func newTmuxWindowRow(
        tab: Tab,
        controller: TmuxController,
        showsShortcutHint: Bool
    ) -> some View {
        Button {
            onSelectTab(tab)
            Task { await controller.newWindow() }
        } label: {
            Label {
                newTabRowTitle(tmuxWindowIndent + "New tmux Tab", showsShortcutHint: showsShortcutHint)
            } icon: {
                Image(systemName: "plus")
            }
        }
        .accessibilityIdentifier("tmux.window.menu.new.\(tab.id.uuidString)")
    }

    /// The section's plain New Tab row: opens a normal shared SSH channel on
    /// the group's connection, even when a tmux session is also attached.
    @ViewBuilder
    private func newTabRow(for group: TerminalTabGroup, showsShortcutHint: Bool) -> some View {
        if group.canOpenNewTerminal, let sourceTab = group.newTerminalSourceTab {
            Button {
                onNewTerminalForTab(sourceTab)
            } label: {
                Label {
                    newTabRowTitle("New Tab", showsShortcutHint: showsShortcutHint)
                } icon: {
                    Image(systemName: "terminal")
                }
            }
            .accessibilityIdentifier("connection.group.newTerminal.\(group.primaryTab.id.uuidString)")
        }
    }

    /// ⌘T is contextual (`openTerminalOnSelectedServer`), so only the row it
    /// would actually trigger right now carries the hint.
    private func newTabRowTitle(_ title: String, showsShortcutHint: Bool) -> Text {
        guard showsShortcutHint else {
            return Text(title)
        }
        return titleWithShortcutHint(title, "⌘T", alignedAfter: groupMenuActionTitles(newTabTitle: title))
    }

    /// Rare per-connection actions collapsed into one submenu so they don't
    /// clutter the section's navigation rows. tmux-session actions (Detach)
    /// live on the session's own row instead.
    private func connectionActionsMenu(for group: TerminalTabGroup) -> some View {
        Menu {
            if let installSourceTab = installSSHKeySourceTab(in: group) {
                Button {
                    onInstallSSHKey(installSourceTab)
                } label: {
                    Label("Install SSH Key", systemImage: "key")
                }
                .accessibilityIdentifier("connection.installSSHKey.\(group.primaryTab.id.uuidString)")
            }

            Divider()

            Button(role: .destructive) {
                group.tabs.forEach { tab in
                    onCloseTab(tab)
                }
            } label: {
                Label("Disconnect", systemImage: "xmark")
            }
            .accessibilityIdentifier("connection.group.disconnect.\(group.primaryTab.id.uuidString)")
        } label: {
            Label("Connection…", systemImage: "ellipsis.circle")
        }
        .accessibilityIdentifier("connection.group.actions.\(group.primaryTab.id.uuidString)")
    }

    /// Snapshot of an attached tmux session for menu building; nil when the
    /// tab has no attached tmux -CC controller.
    private func tmuxMenuSnapshot(for tab: Tab) -> TmuxMenuSessionSnapshot? {
        guard let controller = tab.tmuxController, controller.state.isAttached else {
            return nil
        }
        return TmuxMenuSessionSnapshot(
            windows: controller.windowOrder.compactMap { windowID in
                controller.windows[windowID].map { window in
                    TmuxMenuSessionSnapshot.Window(
                        id: windowID,
                        name: window.name,
                        isActive: windowID == controller.activeWindowID
                    )
                }
            }
        )
    }

    /// User-pinned saved connections surfaced as one-tap connect rows.
    private var favoriteConnections: [SavedConnection] {
        ConnectionMenuModel.favorites(savedConnections)
    }

    /// Menu-row title with the "⌘T"-style hint on the same line, aligned to a
    /// shared trailing column. iPadOS draws no key-equivalent column in in-app
    /// menus and strips custom trailing views, badges, and `LabeledContent`
    /// values from menu rows, so the title text itself is the only way to put
    /// the hint to the right of the label. It also strips color, font, and
    /// weight styling from title text (verified on 26.5), so the hint cannot
    /// be dimmed — `.secondary` is kept for OS versions that honor it.
    ///
    /// To line hints up in a column, each hinted title is padded with
    /// nonbreaking spaces so the hint's trailing edge matches the trailing
    /// edge of the widest sibling title passed in `alignedAfter` (the menu's
    /// static action titles — dynamic host names are excluded so the column
    /// doesn't jump as connections change). On compact phone-width menus, the
    /// hint is omitted when it cannot fit on the title line.
    private func titleWithShortcutHint(
        _ title: String,
        _ hint: String,
        alignedAfter siblingTitles: [String]
    ) -> Text {
        MenuShortcutHintTitle.text(
            title,
            hint,
            alignedAfter: siblingTitles,
            horizontalSizeClass: horizontalSizeClass
        )
    }

    /// Static action titles of the pill's root menu, used to place the
    /// shortcut-hint column.
    private var rootMenuActionTitles: [String] {
        ["New Connection", "Saved Connections…"]
    }

    /// Static action titles of a connection's menu section, used to place
    /// the shortcut-hint column. Disconnect and Install SSH Key live in the
    /// Connection… submenu, so only its label shares the section's column.
    private func groupMenuActionTitles(newTabTitle: String) -> [String] {
        [newTabTitle, "Connection…"]
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

            Text(selectedTab.connectionDisplayTitle)
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
    let shortcutHint: String?
    let onSelect: () -> Void
    let onClose: () -> Void
    /// nil when the tab's session cannot host another shared terminal.
    let onNewTerminal: (() -> Void)?

    private var palette: AppPalette { TerminalRuntime.shared.appPalette }

    var body: some View {
        HStack(spacing: TabPillLayout.shortcutSpacing) {
            if let statusColor {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
            }

            Text(tab.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(palette.primaryText)
                .lineLimit(1)
                .layoutPriority(1)

            if let shortcutHint {
                Text(shortcutHint)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(palette.secondaryText)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: TabPillLayout.maximumWidth, alignment: .leading)
        .padding(.horizontal, TabPillLayout.horizontalPadding)
        .padding(.vertical, TabPillLayout.verticalPadding)
        .background(isSelected ? palette.accentChip : palette.surface)
        .clipShape(Capsule())
        .contentShape(Capsule())
        .onTapGesture(perform: onSelect)
        .contextMenu {
            if let onNewTerminal {
                Button(action: onNewTerminal) {
                    Label("New Tab", systemImage: "plus")
                }
                .accessibilityIdentifier("host.session.tab.newTerminal.\(tab.id.uuidString)")
            }

            Button(role: .destructive, action: onClose) {
                Label("Close Tab", systemImage: "xmark")
            }
            .accessibilityIdentifier("host.session.tab.close.\(tab.id.uuidString)")
        }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("host.session.tab.\(tab.id.uuidString)")
    }

    private var accessibilityLabel: String {
        guard let shortcutHint else { return tab.title }
        return "\(tab.title), \(shortcutHint)"
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
    let controller: TmuxController
    let isSelected: Bool
    let shortcutHint: String?
    let onSelect: () -> Void

    private var palette: AppPalette { TerminalRuntime.shared.appPalette }

    var body: some View {
        HStack(spacing: TabPillLayout.shortcutSpacing) {
            Text(displayName)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(palette.primaryText)
                .lineLimit(1)
                .layoutPriority(1)

            if window.paneIDs.count > 1 {
                Text("\(window.paneIDs.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(palette.secondaryText)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(palette.surfaceHigh)
                    .clipShape(Capsule())
            }

            if let shortcutHint {
                Text(shortcutHint)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(palette.secondaryText)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: TabPillLayout.maximumWidth, alignment: .leading)
        .padding(.horizontal, TabPillLayout.horizontalPadding)
        .padding(.vertical, TabPillLayout.verticalPadding)
        .background(isSelected ? palette.accentChip : palette.surface)
        .clipShape(Capsule())
        .contentShape(Capsule())
        .onTapGesture(perform: onSelect)
        .contextMenu {
            Button {
                Task { await controller.newWindow() }
            } label: {
                Label("New Window", systemImage: "plus")
            }
            .accessibilityIdentifier("tmux.window.tab.new.\(window.id.rawValue)")

            Button {
                Task { await controller.splitPane(.right, target: window.activePaneID) }
            } label: {
                Label("Split Right", systemImage: "rectangle.split.2x1")
            }
            .accessibilityIdentifier("tmux.window.tab.split.right.\(window.id.rawValue)")

            Button {
                Task { await controller.splitPane(.down, target: window.activePaneID) }
            } label: {
                Label("Split Down", systemImage: "rectangle.split.1x2")
            }
            .accessibilityIdentifier("tmux.window.tab.split.down.\(window.id.rawValue)")

            Divider()

            Button {
                Task { await controller.detach() }
            } label: {
                Label("Detach tmux", systemImage: "rectangle.portrait.and.arrow.right")
            }
            .accessibilityIdentifier("tmux.window.tab.detach.\(window.id.rawValue)")

            Button(role: .destructive) {
                Task { await controller.killWindow(window.id) }
            } label: {
                Label("Close Window", systemImage: "xmark")
            }
            .accessibilityIdentifier("tmux.window.tab.close.\(window.id.rawValue)")
        }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("tmux.window.tab.\(window.id.rawValue)")
    }

    private var displayName: String {
        window.name.isEmpty ? window.id.wire : window.name
    }

    private var accessibilityLabel: String {
        guard let shortcutHint else { return displayName }
        return "\(displayName), \(shortcutHint)"
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
