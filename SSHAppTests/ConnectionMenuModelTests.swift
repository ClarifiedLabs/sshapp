import XCTest
@testable import SSHApp

@MainActor
final class ConnectionMenuModelTests: XCTestCase {
    private func provider(_ snapshots: [UUID: TmuxMenuSessionSnapshot]) -> (Tab) -> TmuxMenuSessionSnapshot? {
        { tab in snapshots[tab.id] }
    }

    func testPlainGroupListsTabsWithSelectionCheckmark() {
        let session = SSHSession()
        let first = Tab(title: "shell", session: session)
        let second = Tab(title: "logs", session: session)
        let group = TerminalTabGrouping.groups(for: [first, second])[0]

        let menu = ConnectionMenuModel.groupMenu(
            for: group,
            selectedTabID: second.id,
            tmuxSession: { _ in nil }
        )

        XCTAssertEqual(menu.entries, [
            .tab(tabID: first.id, title: "shell", isSelected: false),
            .tab(tabID: second.id, title: "logs", isSelected: true),
        ])
        XCTAssertTrue(menu.newTabShowsShortcutHint, "⌘T opens a shared channel here while a plain tab is selected")
    }

    func testTmuxTabRendersAsSessionEntryWithWindows() {
        let tab = Tab(title: "demo@foo: ~", session: SSHSession())
        let group = TerminalTabGrouping.groups(for: [tab])[0]
        let snapshot = TmuxMenuSessionSnapshot(windows: [
            .init(id: TmuxWindowID(rawValue: 1), name: "bash", isActive: true),
            .init(id: TmuxWindowID(rawValue: 2), name: "vim", isActive: false),
        ])

        let menu = ConnectionMenuModel.groupMenu(
            for: group,
            selectedTabID: tab.id,
            tmuxSession: provider([tab.id: snapshot])
        )

        XCTAssertEqual(menu.entries, [
            .tmuxSession(
                tabID: tab.id,
                title: "demo@foo: ~",
                isSelected: true,
                windows: [
                    .init(id: TmuxWindowID(rawValue: 1), title: "bash", isCurrent: true),
                    .init(id: TmuxWindowID(rawValue: 2), title: "vim", isCurrent: false),
                ]
            ),
        ])
        XCTAssertFalse(
            menu.newTabShowsShortcutHint,
            "⌘T creates a tmux window while a tmux tab is selected, so the plain New Tab row shows no hint"
        )
    }

    func testMixedGroupKeepsTabOrderAndSelectedTmuxSessionCarriesHint() {
        let session = SSHSession()
        let tmux = Tab(title: "demo@foo: ~", session: session)
        let plain = Tab(title: "shell", session: session)
        let group = TerminalTabGrouping.groups(for: [tmux, plain])[0]
        let snapshot = TmuxMenuSessionSnapshot(windows: [
            .init(id: TmuxWindowID(rawValue: 3), name: "bash", isActive: true),
        ])

        let menu = ConnectionMenuModel.groupMenu(
            for: group,
            selectedTabID: tmux.id,
            tmuxSession: provider([tmux.id: snapshot])
        )

        XCTAssertEqual(menu.entries, [
            .tmuxSession(
                tabID: tmux.id,
                title: "demo@foo: ~",
                isSelected: true,
                windows: [
                    .init(id: TmuxWindowID(rawValue: 3), title: "bash", isCurrent: true),
                ]
            ),
            .tab(tabID: plain.id, title: "shell", isSelected: false),
        ])
        XCTAssertFalse(menu.newTabShowsShortcutHint)
    }

    func testInactiveGroupShowsNoNewTabHint() {
        let session = SSHSession()
        let tab = Tab(title: "shell", session: session)
        let group = TerminalTabGrouping.groups(for: [tab])[0]

        let menu = ConnectionMenuModel.groupMenu(
            for: group,
            selectedTabID: UUID(),
            tmuxSession: { _ in nil }
        )

        XCTAssertFalse(menu.newTabShowsShortcutHint, "⌘T targets the selected connection, not this one")
    }

    func testMultipleTmuxSessionsKeepTheirOwnWindowBlocks() {
        let session = SSHSession()
        let first = Tab(title: "work", session: session)
        let second = Tab(title: "scratch", session: session)
        let group = TerminalTabGrouping.groups(for: [first, second])[0]
        let snapshots: [UUID: TmuxMenuSessionSnapshot] = [
            first.id: TmuxMenuSessionSnapshot(windows: [
                .init(id: TmuxWindowID(rawValue: 1), name: "bash", isActive: true),
            ]),
            second.id: TmuxMenuSessionSnapshot(windows: [
                .init(id: TmuxWindowID(rawValue: 7), name: "top", isActive: true),
            ]),
        ]

        let menu = ConnectionMenuModel.groupMenu(
            for: group,
            selectedTabID: first.id,
            tmuxSession: provider(snapshots)
        )

        XCTAssertEqual(menu.entries, [
            .tmuxSession(
                tabID: first.id,
                title: "work",
                isSelected: true,
                windows: [
                    .init(id: TmuxWindowID(rawValue: 1), title: "bash", isCurrent: true),
                ]
            ),
            .tmuxSession(
                tabID: second.id,
                title: "scratch",
                isSelected: false,
                windows: [
                    .init(id: TmuxWindowID(rawValue: 7), title: "top", isCurrent: false),
                ]
            ),
        ])
    }

    func testWindowTitleFallsBackToWireIDWhenNameIsEmpty() {
        let tab = Tab(title: "demo", session: SSHSession())
        let group = TerminalTabGrouping.groups(for: [tab])[0]
        let snapshot = TmuxMenuSessionSnapshot(windows: [
            .init(id: TmuxWindowID(rawValue: 4), name: "", isActive: false),
        ])

        let menu = ConnectionMenuModel.groupMenu(
            for: group,
            selectedTabID: nil,
            tmuxSession: provider([tab.id: snapshot])
        )

        guard case .tmuxSession(_, _, _, let windows) = menu.entries[0] else {
            return XCTFail("Expected a tmux session entry")
        }
        XCTAssertEqual(windows.map(\.title), ["@4"])
    }

    func testActiveWindowIsNotCurrentWhenItsTabIsNotSelected() {
        let session = SSHSession()
        let plain = Tab(title: "shell", session: session)
        let tmux = Tab(title: "demo", session: session)
        let group = TerminalTabGrouping.groups(for: [plain, tmux])[0]
        let snapshot = TmuxMenuSessionSnapshot(windows: [
            .init(id: TmuxWindowID(rawValue: 1), name: "bash", isActive: true),
        ])

        let menu = ConnectionMenuModel.groupMenu(
            for: group,
            selectedTabID: plain.id,
            tmuxSession: provider([tmux.id: snapshot])
        )

        guard case .tmuxSession(_, _, _, let windows) = menu.entries[1] else {
            return XCTFail("Expected a tmux session entry")
        }
        XCTAssertFalse(windows[0].isCurrent, "Only the selected tab's active window is the user's location")
    }

    func testFavoritesFilterKeepsOrderAndDefaultsOff() {
        let plain = SavedConnection(host: "example.com", username: "dev")
        let starred = SavedConnection(host: "prod.example.com", username: "ops", isFavorite: true)
        let alsoStarred = SavedConnection(host: "pi.local", username: "pi", isFavorite: true)

        XCTAssertFalse(plain.isFavorite, "isFavorite must default to false")
        XCTAssertEqual(
            ConnectionMenuModel.favorites([plain, starred, alsoStarred]).map(\.host),
            ["prod.example.com", "pi.local"]
        )
    }
}
