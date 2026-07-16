//
//  ConnectionSwitcherView.swift
//  SSHApp
//
//  Native touch-first connection switcher used by the compact top bar.
//

import SwiftUI

enum ConnectionSwitcherPresentationStyle {
    case sheet
    case popover

    fileprivate var metrics: ConnectionSwitcherMetrics {
        switch self {
        case .sheet:
            ConnectionSwitcherMetrics(
                rowMinHeight: 46,
                horizontalPadding: 24,
                titleFontSize: 17,
                badgeFontSize: 11
            )
        case .popover:
            ConnectionSwitcherMetrics(
                rowMinHeight: 40,
                horizontalPadding: 18,
                titleFontSize: 15,
                badgeFontSize: 10
            )
        }
    }
}

private struct ConnectionSwitcherMetrics {
    let rowMinHeight: CGFloat
    let horizontalPadding: CGFloat
    let titleFontSize: CGFloat
    let badgeFontSize: CGFloat
}

struct ConnectionSwitcherView: View {
    let tabs: [Tab]
    let selectedTab: Tab
    let savedConnections: [SavedConnection]
    let showsShortcutHints: Bool
    let presentationStyle: ConnectionSwitcherPresentationStyle
    let onSelectTab: (Tab) -> Void
    let onCloseTab: (Tab) -> Void
    let onAddTab: () -> Void
    let onNewTerminalForTab: (Tab) -> Void
    let onConnectSavedConnection: (SavedConnection) -> Void
    let onDismiss: () -> Void
    let onInstallSSHKey: (Tab) -> Void

    @State private var expandedActionsWindowID: TmuxWindowID?

    private var palette: AppPalette { TerminalRuntime.shared.appPalette }
    private var metrics: ConnectionSwitcherMetrics { presentationStyle.metrics }
    private var groups: [TerminalTabGroup] { TerminalTabGrouping.groups(for: tabs) }
    private var favoriteConnections: [SavedConnection] { ConnectionMenuModel.favorites(savedConnections) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(groups) { group in
                    connectionSection(group)
                }

                if !favoriteConnections.isEmpty {
                    favoritesSection
                }

                newConnectionSection
            }
            .padding(.vertical, 16)
        }
        .background(palette.surface)
        .accessibilityIdentifier("connection.switcher")
    }

    private func connectionSection(_ group: TerminalTabGroup) -> some View {
        let groupMenu = ConnectionMenuModel.groupMenu(
            for: group,
            selectedTabID: selectedTab.id,
            tmuxSession: tmuxMenuSnapshot(for:)
        )

        return VStack(alignment: .leading, spacing: 4) {
            sectionHeader(for: group)

            ForEach(groupMenu.entries) { entry in
                entryRows(entry, in: group)
            }

            newTabRow(
                for: group,
                showsShortcutHint: showsShortcutHints && groupMenu.newTabShowsShortcutHint
            )

            connectionActionsRow(for: group)
        }
    }

    private func sectionHeader(for group: TerminalTabGroup) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor(for: group.primaryTab.connectionState))
                .frame(width: 8, height: 8)

            Text(sectionTitle(for: group).uppercased())
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(palette.secondaryText)
                .lineLimit(1)

            if group.containsAttachedTmux {
                Text("tmux")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(palette.secondaryText)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(palette.surfaceHigh)
                    .clipShape(Capsule())
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, metrics.horizontalPadding)
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private func entryRows(
        _ entry: ConnectionMenuModel.Entry,
        in group: TerminalTabGroup
    ) -> some View {
        switch entry {
        case .tab(let tabID, let title, let isSelected):
            if let tab = group.tabs.first(where: { $0.id == tabID }) {
                tabRow(tab: tab, title: title, isSelected: isSelected)
            }
        case .tmuxSession(let tabID, let title, let isSelected, let windows):
            if let tab = group.tabs.first(where: { $0.id == tabID }),
               let controller = tab.tmuxController {
                tmuxSessionRow(tab: tab, title: title, isSelected: isSelected)

                ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                    tmuxWindowRow(
                        window,
                        index: index,
                        windowCount: windows.count,
                        tab: tab,
                        controller: controller,
                        isSelectedSession: isSelected
                    )

                    if window.isCurrent,
                       expandedActionsWindowID == window.id,
                       let tmuxWindow = controller.windows[window.id] {
                        tmuxActionsRow(
                            window: tmuxWindow,
                            isCurrentWindow: true,
                            controller: controller
                        )
                    }
                }

                newTmuxWindowRow(
                    tab: tab,
                    controller: controller,
                    showsShortcutHint: showsShortcutHints && isSelected
                )
            }
        }
    }

    private func tabRow(tab: Tab, title: String, isSelected: Bool) -> some View {
        Button {
            onSelectTab(tab)
            onDismiss()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "terminal")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(palette.secondaryText)
                    .frame(width: 18)

                Text(title)
                    .font(.system(size: metrics.titleFontSize, weight: .regular))
                    .foregroundColor(palette.primaryText)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if let stateText = liveStateText(for: tab.connectionState) {
                    Text(stateText)
                        .font(.system(size: metrics.badgeFontSize, weight: .semibold))
                        .foregroundColor(liveStateColor(for: tab.connectionState))
                        .lineLimit(1)
                }

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(palette.accent)
                }
            }
            .rowChrome(metrics: metrics)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("connection.switcher.tab.select.\(tab.id.uuidString)")
    }

    private func tmuxSessionRow(tab: Tab, title: String, isSelected: Bool) -> some View {
        Button {
            onSelectTab(tab)
            onDismiss()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.split.3x1")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(palette.secondaryText)
                    .frame(width: 18)

                Text(title)
                    .font(.system(size: metrics.titleFontSize, weight: .regular))
                    .foregroundColor(palette.primaryText)
                    .lineLimit(1)

                Text("tmux")
                    .font(.system(size: metrics.badgeFontSize, weight: .semibold))
                    .foregroundColor(palette.secondaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(palette.surfaceHigh)
                    .clipShape(Capsule())

                Spacer(minLength: 8)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(palette.accent)
                }
            }
            .rowChrome(metrics: metrics)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("connection.switcher.tab.select.\(tab.id.uuidString)")
    }

    private func tmuxWindowRow(
        _ window: ConnectionMenuModel.Window,
        index: Int,
        windowCount: Int,
        tab: Tab,
        controller: TmuxController,
        isSelectedSession: Bool
    ) -> some View {
        let paneCount = controller.windows[window.id]?.paneIDs.count ?? 0
        let shortcutHint = tmuxShortcutHint(
            forWindowAt: index,
            windowCount: windowCount,
            isSelectedSession: isSelectedSession
        )

        return HStack(spacing: 10) {
            Button {
                onSelectTab(tab)
                Task { await controller.selectWindow(window.id) }
                onDismiss()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(palette.secondaryText)
                        .frame(width: 18)

                    Text(window.title)
                        .font(.system(size: metrics.titleFontSize, weight: .regular))
                        .foregroundColor(palette.primaryText)
                        .lineLimit(1)

                    if paneCount > 1 {
                        Text("\(paneCount)")
                            .font(.system(size: metrics.badgeFontSize, weight: .semibold))
                            .foregroundColor(palette.secondaryText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(palette.surfaceHigh)
                            .clipShape(Capsule())
                    }

                    Spacer(minLength: 8)

                    if let shortcutHint {
                        shortcutHintText(shortcutHint)
                    }

                    if window.isCurrent {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(palette.accent)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("connection.switcher.tmux.window.select.\(window.id.rawValue)")

            if window.isCurrent {
                Button {
                    toggleActions(for: window.id)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(palette.secondaryText)
                        .frame(width: 28, height: 28)
                        .background(palette.surfaceHigh)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("connection.switcher.tmux.actions.\(window.id.rawValue)")
                .accessibilityLabel("tmux window actions")
            }
        }
        .rowChrome(metrics: metrics)
    }

    private func tmuxActionsRow(
        window: TmuxWindow,
        isCurrentWindow: Bool,
        controller: TmuxController
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                actionChip(
                    "Split Right",
                    systemImage: "rectangle.split.2x1",
                    accessibilityIdentifier: "connection.switcher.tmux.split.right.\(window.id.rawValue)"
                ) {
                    Task { await controller.splitPane(.right, target: window.activePaneID) }
                    onDismiss()
                }

                actionChip(
                    "Split Down",
                    systemImage: "rectangle.split.1x2",
                    accessibilityIdentifier: "connection.switcher.tmux.split.down.\(window.id.rawValue)"
                ) {
                    Task { await controller.splitPane(.down, target: window.activePaneID) }
                    onDismiss()
                }

                actionChip(
                    "Detach",
                    systemImage: "rectangle.portrait.and.arrow.right",
                    accessibilityIdentifier: "connection.switcher.tmux.detach.\(window.id.rawValue)"
                ) {
                    Task { await controller.detach() }
                    onDismiss()
                }

                if controller.windowOrder.count > 1 {
                    actionChip(
                        "Close",
                        systemImage: "xmark",
                        role: .destructive,
                        accessibilityIdentifier: "connection.switcher.tmux.close.\(window.id.rawValue)"
                    ) {
                        closeWindow(window, isCurrentWindow: isCurrentWindow, controller: controller)
                        onDismiss()
                    }
                }
            }
            .padding(.horizontal, metrics.horizontalPadding)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func newTabRow(for group: TerminalTabGroup, showsShortcutHint: Bool) -> some View {
        if group.canOpenNewTerminal, let sourceTab = group.newTerminalSourceTab {
            Button {
                onNewTerminalForTab(sourceTab)
                onDismiss()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "terminal")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(palette.secondaryText)
                        .frame(width: 18)

                    Text("New Tab")
                        .font(.system(size: metrics.titleFontSize, weight: .regular))
                        .foregroundColor(palette.primaryText)

                    Spacer(minLength: 8)

                    if showsShortcutHint {
                        shortcutHintText("⌘T")
                    }
                }
                .rowChrome(metrics: metrics)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("connection.switcher.connection.newTerminal.\(group.primaryTab.id.uuidString)")
        }
    }

    private func newTmuxWindowRow(
        tab: Tab,
        controller: TmuxController,
        showsShortcutHint: Bool
    ) -> some View {
        Button {
            onSelectTab(tab)
            Task { await controller.newWindow() }
            onDismiss()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(palette.secondaryText)
                    .frame(width: 18)

                Text("New tmux Tab")
                    .font(.system(size: metrics.titleFontSize, weight: .regular))
                    .foregroundColor(palette.primaryText)

                Spacer(minLength: 8)

                if showsShortcutHint {
                    shortcutHintText("⌘T")
                }
            }
            .rowChrome(metrics: metrics)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("connection.switcher.tmux.window.new.\(tab.id.uuidString)")
    }

    private func connectionActionsRow(for group: TerminalTabGroup) -> some View {
        HStack(spacing: 8) {
            if let installSourceTab = installSSHKeySourceTab(in: group) {
                actionChip(
                    "Install SSH Key",
                    systemImage: "key",
                    accessibilityIdentifier: "connection.switcher.connection.installSSHKey.\(group.primaryTab.id.uuidString)"
                ) {
                    onInstallSSHKey(installSourceTab)
                    onDismiss()
                }
            }

            actionChip(
                "Disconnect",
                systemImage: "xmark",
                role: .destructive,
                accessibilityIdentifier: "connection.switcher.connection.disconnect.\(group.primaryTab.id.uuidString)"
            ) {
                group.tabs.forEach { tab in
                    onCloseTab(tab)
                }
                onDismiss()
            }
        }
        .padding(.horizontal, metrics.horizontalPadding)
        .padding(.vertical, 4)
    }

    private var favoritesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            plainSectionHeader("Favorites")

            ForEach(favoriteConnections) { connection in
                favoriteRow(connection)
            }
        }
    }

    private func favoriteRow(_ connection: SavedConnection) -> some View {
        Button {
            onConnectSavedConnection(connection)
            onDismiss()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "star.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(palette.warning)
                    .frame(width: 18)

                Text(connection.displayDestination)
                    .font(.system(size: metrics.titleFontSize, weight: .regular))
                    .foregroundColor(palette.primaryText)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text("Connect")
                    .font(.system(size: metrics.badgeFontSize, weight: .semibold))
                    .foregroundColor(palette.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(palette.accentChip)
                    .clipShape(Capsule())
            }
            .rowChrome(metrics: metrics)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("connection.switcher.favorite.connect.\(connection.id.uuidString)")
    }

    private var newConnectionSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            plainSectionHeader("Connection")

            Button {
                onAddTab()
                onDismiss()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(palette.accent)
                        .frame(width: 18)

                    Text("New Connection")
                        .font(.system(size: metrics.titleFontSize, weight: .regular))
                        .foregroundColor(palette.accent)

                    Spacer(minLength: 8)

                    if showsShortcutHints {
                        shortcutHintText("⌘N")
                    }
                }
                .rowChrome(metrics: metrics)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("connection.switcher.newConnection")
        }
    }

    private func plainSectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(palette.secondaryText)
            .padding(.horizontal, metrics.horizontalPadding)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private func actionChip(
        _ title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: metrics.badgeFontSize, weight: .semibold))
                .foregroundColor(role == .destructive ? palette.error : palette.primaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(palette.surfaceHigh)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private func shortcutHintText(_ hint: String) -> some View {
        Text(hint)
            .font(.system(size: metrics.badgeFontSize, weight: .semibold))
            .foregroundColor(palette.secondaryText)
            .lineLimit(1)
            .accessibilityHidden(true)
    }

    private func toggleActions(for windowID: TmuxWindowID) {
        if expandedActionsWindowID == windowID {
            expandedActionsWindowID = nil
        } else {
            expandedActionsWindowID = windowID
        }
    }

    private func closeWindow(
        _ window: TmuxWindow,
        isCurrentWindow: Bool,
        controller: TmuxController
    ) {
        Task {
            if isCurrentWindow {
                await controller.selectPreviousWindow()
            }
            await controller.killWindow(window.id)
        }
    }

    private func tmuxShortcutHint(
        forWindowAt index: Int,
        windowCount: Int,
        isSelectedSession: Bool
    ) -> String? {
        guard showsShortcutHints, isSelectedSession else { return nil }
        return IndexedTabNavigation.shortcutDigit(
            forItemAt: index,
            itemCount: windowCount
        ).map { "⌘\($0)" }
    }

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

    private func sectionTitle(for group: TerminalTabGroup) -> String {
        group.title.isEmpty ? group.primaryTab.connectionDisplayTitle : group.title
    }

    private func installSSHKeySourceTab(in group: TerminalTabGroup) -> Tab? {
        group.tabs.first { tab in
            tab.connectionState == .connected && tab.session?.canOpenChannel == true
        }
    }

    private func liveStateText(for state: ConnectionState) -> String? {
        switch state {
        case .connected:
            nil
        case .connecting:
            "Connecting"
        case .awaitingInput:
            "Awaiting"
        case .failed:
            "Failed"
        case .disconnected:
            "Disconnected"
        }
    }

    private func liveStateColor(for state: ConnectionState) -> Color {
        switch state {
        case .connected:
            palette.success
        case .connecting, .awaitingInput:
            palette.warning
        case .failed:
            palette.error
        case .disconnected:
            palette.secondaryText
        }
    }

    private func statusColor(for state: ConnectionState) -> Color {
        switch state {
        case .connected:
            palette.success
        case .connecting, .awaitingInput:
            palette.warning
        case .failed:
            palette.error
        case .disconnected:
            palette.secondaryText
        }
    }
}

private extension View {
    func rowChrome(metrics: ConnectionSwitcherMetrics) -> some View {
        self
            .padding(.horizontal, metrics.horizontalPadding)
            .frame(minHeight: metrics.rowMinHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }
}
