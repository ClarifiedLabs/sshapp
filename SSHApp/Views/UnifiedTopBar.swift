//
//  UnifiedTopBar.swift
//  SSHApp
//
//  Single compact top bar combining connection switching, session/window tabs,
//  and toolbar actions. The leading connection pill opens a native switcher:
//  a half sheet on compact width and a popover on regular width.
//

import SwiftUI

private enum TabPillLayout {
    static let shortcutSpacing: CGFloat = 6
    static let horizontalPadding: CGFloat = 10
    static let verticalPadding: CGFloat = 6
    static let maximumWidth: CGFloat = 110
}

struct UnifiedTopBar: View {
    let tabs: [Tab]
    let selectedTab: Tab?
    @Binding var showKeyboardBar: Bool
    let showsShortcutHints: Bool
    @Binding var isSwitcherPresented: Bool
    let switcherContent: (ConnectionSwitcherPresentationStyle) -> AnyView
    let onOpenSwitcher: () -> Void
    let onNewTab: () -> Void
    let onNewTerminalForTab: (Tab) -> Void
    let onSelectTab: (Tab) -> Void
    let onCloseTab: (Tab) -> Void
    let onFindHostTab: (Tab) -> Void
    let onFindTmuxWindow: (UUID, TmuxWindowID, TmuxPaneID) -> Void
    let onResetHostTabFontSize: (UUID) -> Void
    let onResetTmuxPaneFontSize: (UUID, TmuxPaneID) -> Void
    let onSettings: (SettingsDestination) -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var palette: AppPalette { TerminalRuntime.shared.appPalette }

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
                connectionPillButton(for: selectedTab)
                    .popover(
                        isPresented: regularSwitcherPresentation,
                        attachmentAnchor: .rect(.bounds),
                        arrowEdge: .top
                    ) {
                        switcherContent(.popover)
                            .frame(width: 360)
                    }
            }

            if let controller = attachedController, let selectedTab {
                tmuxWindowPills(controller: controller, hostTabID: selectedTab.id)
            } else {
                hostSessionPills
            }

            settingsMenu
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(palette.background.opacity(0.95))
    }

    private var hostSessionPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
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
                        onNewTerminal: { onNewTerminalForTab(tab) },
                        onFind: { onFindHostTab(tab) },
                        onResetFontSize: { onResetHostTabFontSize(tab.id) }
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
    /// sibling sessions on the same connection live in the connection switcher.
    private func tmuxWindowPills(controller: TmuxController, hostTabID: UUID) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
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
                            },
                            onFind: { paneID in
                                onFindTmuxWindow(hostTabID, window.id, paneID)
                            },
                            onResetFontSize: { paneID in
                                onResetTmuxPaneFontSize(hostTabID, paneID)
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
        guard showsShortcutHints else { return nil }
        return IndexedTabNavigation.shortcutDigit(forItemAt: index, itemCount: tabs.count).map { "⌘\($0)" }
    }

    private func tmuxShortcutHint(forWindowAt index: Int, windowCount: Int) -> String? {
        guard showsShortcutHints else { return nil }
        return IndexedTabNavigation.shortcutDigit(forItemAt: index, itemCount: windowCount).map { "⌘\($0)" }
    }

    /// New-tab button: a new tmux window while attached in control mode, a new
    /// shared terminal on the current connection otherwise, falling back to
    /// the new-connection sheet when the selected tab can't host one.
    private var newTabButton: some View {
        CircleIconButton(systemImage: "plus", size: 16, frameSize: 28, filled: true) {
            onNewTab()
        }
        .accessibilityIdentifier(attachedController != nil ? "tmux.window.new" : "host.session.new")
        .accessibilityLabel(attachedController != nil ? "New tmux window" : "New tab")
    }

    private func connectionPillButton(for selectedTab: Tab) -> some View {
        Button(action: onOpenSwitcher) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor(for: selectedTab.connectionState))
                    .frame(width: 8, height: 8)

                Text(connectionPillTitle(for: selectedTab))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(palette.primaryText)
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(palette.secondaryText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(palette.surface)
            .clipShape(Capsule())
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("connection.pill")
        .accessibilityLabel("Connection \(connectionPillTitle(for: selectedTab))")
        .accessibilityValue(connectionStateAccessibilityValue(for: selectedTab.connectionState))
    }

    private var regularSwitcherPresentation: Binding<Bool> {
        Binding(
            get: { isSwitcherPresented && horizontalSizeClass != .compact },
            set: { isPresented in
                if !isPresented { isSwitcherPresented = false }
            }
        )
    }

    private func connectionStateAccessibilityValue(for state: ConnectionState) -> String {
        switch state {
        case .disconnected:
            "Disconnected"
        case .connecting:
            "Connecting"
        case .awaitingInput:
            "Awaiting input"
        case .connected:
            "Connected"
        case .failed:
            "Failed"
        }
    }

    private func connectionPillTitle(for tab: Tab) -> String {
        guard let connection = tab.connection else {
            return tab.connectionDisplayTitle
        }

        if connection.port == 22 {
            return connection.host
        }
        return "\(connection.host):\(connection.port)"
    }

    private func statusColor(for state: ConnectionState) -> Color {
        switch state {
        case .disconnected:
            palette.secondaryText
        case .connecting, .awaitingInput:
            palette.warning
        case .connected:
            palette.success
        case .failed:
            palette.error
        }
    }

    private var settingsMenu: some View {
        SessionSettingsMenu(
            showKeyboardBar: $showKeyboardBar,
            showsTitle: false,
            onSettings: onSettings
        )
    }
}

/// Shared settings menu for the custom horizontal bar and system vertical bar.
struct SessionSettingsMenu: View {
    @Binding var showKeyboardBar: Bool
    let showsTitle: Bool
    let onSettings: (SettingsDestination) -> Void

    @AppStorage(AppSettingsKey.keepScreenAwake) private var keepScreenAwake = false
    @AppStorage(AppSettingsKey.connectionsAndSettingsICloudSyncEnabled)
    private var isConnectionsAndSettingsICloudSyncEnabled = false
    @AppStorage(AppSettingsKey.credentialICloudSyncEnabled)
    private var isCredentialICloudSyncConfigured = false

    private var palette: AppPalette { TerminalRuntime.shared.appPalette }

    var body: some View {
        Menu {
            Toggle(isOn: $showKeyboardBar) {
                Label("Keyboard Bar", systemImage: "keyboard")
            }
            .accessibilityIdentifier("keyboard.toggle")

            Toggle(isOn: $keepScreenAwake) {
                Label("Keep Screen Awake", systemImage: "sun.max")
            }
            .accessibilityIdentifier("screenAwake.toggle")

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
                onSettings(.appLock)
            } label: {
                Label("App Lock", systemImage: "lock")
            }
            .accessibilityIdentifier("settings.appLock")

            Button {
                onSettings(.iCloudSync)
            } label: {
                Label("iCloud Sync — \(iCloudSyncStatus.menuText)", systemImage: iCloudSyncStatus.systemImage)
            }
            .accessibilityIdentifier("settings.iCloudSync")

            Divider()

            Button {
                onSettings(.keyboard)
            } label: {
                Label("Keyboard", systemImage: "keyboard")
            }
            .accessibilityIdentifier("settings.keyboard")

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
            if showsTitle {
                Label("Settings", systemImage: "gearshape")
            } else {
                CircleIcon(systemImage: "gearshape", size: 16, filled: false)
            }
        }
        .accessibilityIdentifier("settings.open")
        .accessibilityLabel("Settings")
    }

    private var iCloudSyncStatus: ICloudSyncStatus {
        // Read both AppStorage values so SwiftUI refreshes the menu as either
        // tier changes; the shared helper remains the source of status logic.
        _ = isConnectionsAndSettingsICloudSyncEnabled
        _ = isCredentialICloudSyncConfigured
        return ConnectionsAndSettingsICloudSyncSettings.status()
    }

}

/// Host terminal session chip shown when tmux windows are not occupying the
/// shared tab area.
struct HostSessionTabPill: View {
    let tab: Tab
    let isSelected: Bool
    let shortcutHint: String?
    let onSelect: () -> Void
    let onClose: @MainActor () -> Void
    /// Optional callbacks; the shared menu also checks terminal availability.
    let onNewTerminal: (@MainActor () -> Void)?
    let onFind: (@MainActor () -> Void)?
    let onResetFontSize: (@MainActor () -> Void)?

    private var palette: AppPalette { TerminalRuntime.shared.appPalette }

    var body: some View {
        HStack(spacing: TabPillLayout.shortcutSpacing) {
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
            TerminalTabMenuContent(items: TerminalTabMenu.host(
                tab: tab,
                onClose: onClose,
                onNewTerminal: onNewTerminal,
                onFind: onFind,
                onResetFontSize: onResetFontSize
            ))
        }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("host.session.tab.\(tab.id.uuidString)")
    }

    private var accessibilityLabel: String {
        guard let shortcutHint else { return tab.title }
        return "\(tab.title), \(shortcutHint)"
    }
}

/// tmux window chip: window name and a pane-count badge for windows with splits.
struct TmuxWindowTabPill: View {
    let window: TmuxWindow
    let controller: TmuxController
    let isSelected: Bool
    let shortcutHint: String?
    let onSelect: () -> Void
    let onFind: @MainActor (TmuxPaneID) -> Void
    let onResetFontSize: @MainActor (TmuxPaneID) -> Void

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
            TerminalTabMenuContent(items: TerminalTabMenu.tmux(
                window: window,
                controller: controller,
                onFind: onFind,
                onResetFontSize: onResetFontSize
            ))
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
    var frameSize: CGFloat = 32
    let filled: Bool

    private var palette: AppPalette { TerminalRuntime.shared.appPalette }

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size, weight: .medium))
            .foregroundColor(palette.primaryText)
            .frame(width: frameSize, height: frameSize)
            .background(filled ? palette.surface : .clear)
            .clipShape(Circle())
    }
}

private struct CircleIconButton: View {
    let systemImage: String
    let size: CGFloat
    var frameSize: CGFloat = 32
    let filled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            CircleIcon(systemImage: systemImage, size: size, frameSize: frameSize, filled: filled)
        }
        .buttonStyle(.plain)
    }
}
