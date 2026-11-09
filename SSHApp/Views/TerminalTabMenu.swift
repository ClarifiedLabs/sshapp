import SwiftUI
import UIKit

struct TerminalTabMenuAction: Identifiable {
    let title: String
    let systemImage: String
    let isDestructive: Bool
    let accessibilityIdentifier: String
    let action: @MainActor () -> Void

    var id: String { accessibilityIdentifier }
}

enum TerminalTabMenuItem {
    case action(TerminalTabMenuAction)
    case separator
}

/// Shared actions for horizontal tab pills and native tab context menus.
@MainActor
enum TerminalTabMenu {
    static func host(
        tab: Tab,
        onClose: @escaping @MainActor () -> Void,
        onNewTerminal: (@MainActor () -> Void)?,
        onFind: (@MainActor () -> Void)?,
        onResetFontSize: (@MainActor () -> Void)?
    ) -> [TerminalTabMenuItem] {
        var items: [TerminalTabMenuItem] = []
        if tab.session?.canOpenChannel == true, tab.connection != nil, let onNewTerminal {
            items.append(.action(TerminalTabMenuAction(
                title: "New Tab", systemImage: "plus", isDestructive: false,
                accessibilityIdentifier: "host.session.tab.newTerminal.\(tab.id.uuidString)",
                action: onNewTerminal
            )))
        }
        if ownsLiveDirectTerminal(tab) {
            if let onFind {
                items.append(.action(TerminalTabMenuAction(
                    title: "Find in Terminal…", systemImage: "magnifyingglass", isDestructive: false,
                    accessibilityIdentifier: "terminal.hostTab.context.find.\(tab.id.uuidString)",
                    action: onFind
                )))
            }
            if let onResetFontSize {
                items.append(.action(TerminalTabMenuAction(
                    title: "Reset Font Size", systemImage: "textformat.size", isDestructive: false,
                    accessibilityIdentifier: "terminal.hostTab.context.resetFontSize.\(tab.id.uuidString)",
                    action: onResetFontSize
                )))
            }
        }
        if !items.isEmpty { items.append(.separator) }
        items.append(.action(TerminalTabMenuAction(
            title: "Close Tab", systemImage: "xmark", isDestructive: true,
            accessibilityIdentifier: "host.session.tab.close.\(tab.id.uuidString)",
            action: onClose
        )))
        return items
    }

    static func tmux(
        window: TmuxWindow,
        controller: TmuxController,
        onFind: @escaping @MainActor (TmuxPaneID) -> Void,
        onResetFontSize: @escaping @MainActor (TmuxPaneID) -> Void
    ) -> [TerminalTabMenuItem] {
        var items: [TerminalTabMenuItem] = [
            .action(TerminalTabMenuAction(
                title: "New Window", systemImage: "plus", isDestructive: false,
                accessibilityIdentifier: "tmux.window.tab.new.\(window.id.rawValue)",
                action: { Task { await controller.newWindow() } }
            )),
            .action(TerminalTabMenuAction(
                title: "Split Right", systemImage: "rectangle.split.2x1", isDestructive: false,
                accessibilityIdentifier: "tmux.window.tab.split.right.\(window.id.rawValue)",
                action: { Task { await controller.splitPane(.right, target: window.activePaneID) } }
            )),
            .action(TerminalTabMenuAction(
                title: "Split Down", systemImage: "rectangle.split.1x2", isDestructive: false,
                accessibilityIdentifier: "tmux.window.tab.split.down.\(window.id.rawValue)",
                action: { Task { await controller.splitPane(.down, target: window.activePaneID) } }
            )),
        ]
        if let activePaneID = window.activePaneID {
            items.append(.action(TerminalTabMenuAction(
                title: "Find in Terminal…", systemImage: "magnifyingglass", isDestructive: false,
                accessibilityIdentifier: "terminal.tmuxWindow.context.find.\(window.id.rawValue)",
                action: { onFind(activePaneID) }
            )))
            items.append(.action(TerminalTabMenuAction(
                title: "Reset Font Size", systemImage: "textformat.size", isDestructive: false,
                accessibilityIdentifier: "terminal.tmuxWindow.context.resetFontSize.\(window.id.rawValue)",
                action: { onResetFontSize(activePaneID) }
            )))
        }
        items.append(.separator)
        items.append(.action(TerminalTabMenuAction(
            title: "Detach tmux", systemImage: "rectangle.portrait.and.arrow.right", isDestructive: false,
            accessibilityIdentifier: "tmux.window.tab.detach.\(window.id.rawValue)",
            action: { Task { await controller.detach() } }
        )))
        if controller.windowOrder.count > 1 {
            items.append(.action(TerminalTabMenuAction(
                title: "Close Window", systemImage: "xmark", isDestructive: true,
                accessibilityIdentifier: "tmux.window.tab.close.\(window.id.rawValue)",
                action: {
                    Task {
                        if window.id == controller.activeWindowID {
                            await controller.selectPreviousWindow()
                        }
                        await controller.killWindow(window.id)
                    }
                }
            )))
        }
        return items
    }

    /// UIKit represents separators with untitled inline menu groups.
    static func uiMenuElements(_ items: [TerminalTabMenuItem]) -> [UIMenuElement] {
        var groups: [[UIMenuElement]] = [[]]
        for item in items {
            switch item {
            case .action(let action):
                let element = UIAction(
                    title: action.title,
                    image: UIImage(systemName: action.systemImage),
                    identifier: UIAction.Identifier(action.id),
                    attributes: action.isDestructive ? .destructive : []
                ) { _ in action.action() }
                element.accessibilityIdentifier = action.accessibilityIdentifier
                groups[groups.count - 1].append(element)
            case .separator:
                if !groups[groups.count - 1].isEmpty { groups.append([]) }
            }
        }
        let nonemptyGroups = groups.filter { !$0.isEmpty }
        guard nonemptyGroups.count > 1 else { return nonemptyGroups.first ?? [] }
        return nonemptyGroups.map { UIMenu(title: "", options: .displayInline, children: $0) }
    }

    private static func ownsLiveDirectTerminal(_ tab: Tab) -> Bool {
        guard tab.session != nil else { return false }
        if let controller = tab.tmuxController, controller.state.isAttached {
            return false
        }
        switch tab.connectionState {
        case .awaitingInput, .connected:
            return true
        case .disconnected, .connecting, .failed:
            return false
        }
    }
}

private struct TerminalTabMenuProviderKey: EnvironmentKey {
    static let defaultValue: @MainActor @Sendable () -> [TerminalTabMenuItem] = { [] }
}

extension EnvironmentValues {
    var terminalTabMenu: @MainActor @Sendable () -> [TerminalTabMenuItem] {
        get { self[TerminalTabMenuProviderKey.self] }
        set { self[TerminalTabMenuProviderKey.self] = newValue }
    }
}

struct TerminalTabMenuContent: View {
    let items: [TerminalTabMenuItem]

    var body: some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            switch item {
            case .action(let action):
                Button(role: action.isDestructive ? .destructive : nil, action: action.action) {
                    Label(action.title, systemImage: action.systemImage)
                }
                .accessibilityIdentifier(action.accessibilityIdentifier)
            case .separator:
                Divider()
            }
        }
    }
}
