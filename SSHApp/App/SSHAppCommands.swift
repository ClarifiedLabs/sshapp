import SwiftUI

struct SSHAppCommandActions {
    var newConnection: () -> Void
    var newTab: () -> Void
    var closeTab: () -> Void
    var previousHostTab: () -> Void
    var nextHostTab: () -> Void
    var previousTmuxTab: () -> Void
    var nextTmuxTab: () -> Void
    var selectIndexedTab: (Int) -> Void
    var canSelectIndexedTab: (Int) -> Bool

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

            Divider()

            ForEach(IndexedTabNavigation.shortcutDigits, id: \.self) { digit in
                Button(indexedTabCommandTitle(for: digit, isTmuxAttached: actions?.isTmuxAttached == true)) {
                    actions?.selectIndexedTab(digit)
                }
                .keyboardShortcut(KeyEquivalent(Character(String(digit))), modifiers: .command)
                .disabled(actions?.canSelectIndexedTab(digit) != true)
            }
        }
    }

    private func indexedTabCommandTitle(for digit: Int, isTmuxAttached: Bool) -> String {
        let label = isTmuxAttached ? "tmux Tab" : "Tab"
        return "\(label) \(tabNumber(forShortcutDigit: digit))"
    }

    private func tabNumber(forShortcutDigit digit: Int) -> Int {
        guard let index = IndexedTabNavigation.itemIndex(forShortcutDigit: digit) else {
            return digit
        }
        return index + 1
    }
}
