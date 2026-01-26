import Foundation

/// Groups open terminal tabs by the live SSH connection they share.
struct TerminalTabGroup: Identifiable {
    enum ID: Hashable {
        case session(ObjectIdentifier)
        case standalone(UUID)
    }

    let id: ID
    let title: String
    var tabs: [Tab]
    var containsAttachedTmux: Bool
    var newTerminalSourceTab: Tab?

    var primaryTab: Tab {
        tabs[0]
    }

    var canOpenNewTerminal: Bool {
        newTerminalSourceTab != nil
    }
}

enum TerminalTabGrouping {
    @MainActor
    static func groups(for tabs: [Tab]) -> [TerminalTabGroup] {
        var groups: [TerminalTabGroup] = []
        var sessionIndexes: [ObjectIdentifier: Int] = [:]

        for tab in tabs {
            if let session = tab.session {
                let id = ObjectIdentifier(session)
                if let index = sessionIndexes[id] {
                    var group = groups[index]
                    group.tabs.append(tab)
                    group.containsAttachedTmux = group.containsAttachedTmux || isAttachedToTmux(tab)
                    if group.newTerminalSourceTab == nil, canOpenNewTerminal(from: tab) {
                        group.newTerminalSourceTab = tab
                    }
                    groups[index] = group
                } else {
                    sessionIndexes[id] = groups.count
                    groups.append(
                        TerminalTabGroup(
                            id: .session(id),
                            title: connectionTitle(for: tab),
                            tabs: [tab],
                            containsAttachedTmux: isAttachedToTmux(tab),
                            newTerminalSourceTab: canOpenNewTerminal(from: tab) ? tab : nil
                        )
                    )
                }
            } else {
                groups.append(
                    TerminalTabGroup(
                        id: .standalone(tab.id),
                        title: tab.title,
                        tabs: [tab],
                        containsAttachedTmux: false,
                        newTerminalSourceTab: nil
                    )
                )
            }
        }

        return groups
    }

    @MainActor
    private static func connectionTitle(for tab: Tab) -> String {
        tab.connection?.displayDestination ?? tab.title
    }

    @MainActor
    private static func canOpenNewTerminal(from tab: Tab) -> Bool {
        tab.session?.canOpenChannel == true && tab.connection != nil
    }

    @MainActor
    private static func isAttachedToTmux(_ tab: Tab) -> Bool {
        tab.tmuxController?.state.isAttached == true
    }
}
