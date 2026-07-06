import Foundation

/// Value snapshot of an attached tmux -CC session used to build the
/// connection menu. The view layer builds it from a `TmuxController`; tests
/// build it from literals, keeping row composition a pure function.
struct TmuxMenuSessionSnapshot: Equatable {
    struct Window: Equatable {
        let id: TmuxWindowID
        let name: String
        let isActive: Bool
    }

    var windows: [Window]
}

/// Composes the flattened connection menu: one section per open connection
/// group whose entries are directly tappable tabs and tmux windows, so any
/// destination is reachable in two taps instead of walking nested submenus.
enum ConnectionMenuModel {
    /// One connection group's menu section content.
    struct GroupMenu: Equatable {
        let entries: [Entry]
        /// Whether the section's plain "New Tab" row carries the ⌘T hint:
        /// the selected tab lives in this group and is not a tmux session,
        /// so ⌘T opens a shared channel here. tmux sessions carry the hint
        /// on their own "New tmux Tab" row instead (`Entry.isSelected`).
        let newTabShowsShortcutHint: Bool
    }

    /// One entry of a connection group's menu section, in `group.tabs` order.
    enum Entry: Equatable, Identifiable {
        /// A terminal tab without an attached tmux -CC session.
        case tab(tabID: UUID, title: String, isSelected: Bool)
        /// A tab with an attached tmux -CC session: rendered as a tab row
        /// with a "tmux" subtitle whose expansion menu holds the session's
        /// rare actions (Detach), its windows indented beneath it, and its
        /// own "New tmux Tab" row closing the block.
        case tmuxSession(tabID: UUID, title: String, isSelected: Bool, windows: [Window])

        var id: UUID {
            switch self {
            case .tab(let tabID, _, _), .tmuxSession(let tabID, _, _, _):
                tabID
            }
        }

        var isSelected: Bool {
            switch self {
            case .tab(_, _, let isSelected), .tmuxSession(_, _, let isSelected, _):
                isSelected
            }
        }
    }

    struct Window: Equatable, Identifiable {
        let id: TmuxWindowID
        let title: String
        /// Whether this window is where the user currently is: its session
        /// tab is selected and it is the session's active window. Only one
        /// window across the whole menu can be current, mirroring the single
        /// checkmark a selected plain tab gets.
        let isCurrent: Bool
    }

    @MainActor
    static func groupMenu(
        for group: TerminalTabGroup,
        selectedTabID: UUID?,
        tmuxSession: (Tab) -> TmuxMenuSessionSnapshot?
    ) -> GroupMenu {
        let entries = group.tabs.map { tab -> Entry in
            let isSelected = tab.id == selectedTabID
            guard let snapshot = tmuxSession(tab) else {
                return .tab(tabID: tab.id, title: tab.title, isSelected: isSelected)
            }

            let windows = snapshot.windows.map { window in
                Window(
                    id: window.id,
                    title: window.name.isEmpty ? window.id.wire : window.name,
                    isCurrent: isSelected && window.isActive
                )
            }
            return .tmuxSession(
                tabID: tab.id,
                title: tab.title,
                isSelected: isSelected,
                windows: windows
            )
        }

        let selectedIsPlainTab = entries.contains { entry in
            if case .tab(_, _, true) = entry {
                return true
            }
            return false
        }

        return GroupMenu(
            entries: entries,
            newTabShowsShortcutHint: selectedIsPlainTab
        )
    }

    /// User-pinned favorites surfaced as one-tap connect rows at the menu's
    /// root, in saved-connection order.
    static func favorites(_ savedConnections: [SavedConnection]) -> [SavedConnection] {
        savedConnections.filter(\.isFavorite)
    }
}
