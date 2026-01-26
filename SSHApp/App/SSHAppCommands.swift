import SwiftUI

struct SSHAppCommandActions {
    var newConnection: () -> Void
    var newTab: () -> Void
    var closeTab: () -> Void
    var previousHostTab: () -> Void
    var nextHostTab: () -> Void
    var previousTmuxTab: () -> Void
    var nextTmuxTab: () -> Void

    var isTmuxAttached: Bool
    var canOpenNewTab: Bool
    var canCloseTab: Bool
    var canNavigateHostTabs: Bool
    var canNavigateTmuxTabs: Bool
}

private struct SSHAppCommandActionsKey: FocusedValueKey {
    typealias Value = SSHAppCommandActions
}

extension FocusedValues {
    var sshAppCommandActions: SSHAppCommandActions? {
        get { self[SSHAppCommandActionsKey.self] }
        set { self[SSHAppCommandActionsKey.self] = newValue }
    }
}

struct SSHAppCommands: Commands {
    @FocusedValue(\.sshAppCommandActions) private var actions

    var body: some Commands {
        CommandMenu("Connection") {
            Button("New Connection") {
                actions?.newConnection()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(actions == nil)

            Button(actions?.isTmuxAttached == true ? "New tmux Tab" : "New Tab") {
                actions?.newTab()
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(actions?.canOpenNewTab != true)

            Button("Close Tab") {
                actions?.closeTab()
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(actions?.canCloseTab != true)

            Divider()

            Button("Previous Tab") {
                actions?.previousHostTab()
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])
            .disabled(actions?.canNavigateHostTabs != true)

            Button("Next Tab") {
                actions?.nextHostTab()
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])
            .disabled(actions?.canNavigateHostTabs != true)

            Divider()

            Button("Previous tmux Tab") {
                actions?.previousTmuxTab()
            }
            .keyboardShortcut("[", modifiers: [.command, .option])
            .disabled(actions?.canNavigateTmuxTabs != true)

            Button("Next tmux Tab") {
                actions?.nextTmuxTab()
            }
            .keyboardShortcut("]", modifiers: [.command, .option])
            .disabled(actions?.canNavigateTmuxTabs != true)
        }
    }
}
