import XCTest
@testable import SSHApp

final class TerminalTabGroupingTests: XCTestCase {
    @MainActor
    func testTabsSharingLiveSessionUseOneGroup() {
        let session = SSHSession()
        let first = Tab(title: "shell", session: session)
        let second = Tab(title: "logs", session: session)

        let groups = TerminalTabGrouping.groups(for: [first, second])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].tabs.map(\.id), [first.id, second.id])
    }

    @MainActor
    func testSeparateSessionsToSameDestinationStaySeparateGroups() {
        let connection = SavedConnection(host: "example.com", username: "dev")
        let first = Tab(title: "dev@example.com", session: SSHSession(), connection: connection)
        let second = Tab(title: "dev@example.com", session: SSHSession(), connection: connection)

        let groups = TerminalTabGrouping.groups(for: [first, second])

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].tabs.map(\.id), [first.id])
        XCTAssertEqual(groups[1].tabs.map(\.id), [second.id])
        XCTAssertNotEqual(groups[0].id, groups[1].id)
    }

    @MainActor
    func testConnectionDisplayTitleIgnoresTerminalTitleChanges() {
        let connection = SavedConnection(host: "server.example.com", username: "developer")
        let tab = Tab(title: connection.displayName, connectionState: .connected, connection: connection)

        tab.title = "Title"

        XCTAssertEqual(tab.connectionDisplayTitle, "developer@server.example.com")
        XCTAssertEqual(TerminalTabGrouping.groups(for: [tab])[0].title, "developer@server.example.com")
    }

    @MainActor
    func testConnectionDisplayTitleUsesCustomNameWhenSet() {
        let connection = SavedConnection(host: "server.example.com", username: "developer", name: "Prod")
        let tab = Tab(title: connection.displayName, connectionState: .connected, connection: connection)

        XCTAssertEqual(tab.connectionDisplayTitle, "Prod")
        XCTAssertEqual(TerminalTabGrouping.groups(for: [tab])[0].title, "Prod")
        connection.name = "  Staging  "
        XCTAssertEqual(tab.connectionDisplayTitle, "Staging")
    }

    @MainActor
    func testRefreshConnectionTitleUpdatesTitleWhileTerminalHasNotClaimedOwnership() {
        let connection = SavedConnection(host: "server.example.com", username: "developer", name: "Prod")
        let tab = Tab(title: connection.displayName, connectionState: .connected, connection: connection)

        connection.name = "  Staging  "
        tab.refreshConnectionTitle()

        XCTAssertEqual(tab.title, "Staging", "A rename must refresh tabs that mirror the connection label")

        // Once the remote terminal sets a window title (OSC 0/2), it owns the
        // tab title and renames must not clobber it.
        tab.isTitleOwnedByTerminal = true
        connection.name = "Production"
        tab.refreshConnectionTitle()

        XCTAssertEqual(tab.title, "Staging", "Terminal-owned titles must survive connection renames")
    }

    @MainActor
    func testRefreshConnectionTitleRequiresConnection() {
        let tab = Tab(title: "connecting", connectionState: .connecting)

        tab.refreshConnectionTitle()

        XCTAssertEqual(tab.title, "connecting", "Tabs without a connection must keep their title")
    }

    @MainActor
    func testTabsWithoutSessionsRemainStandalone() {
        let first = Tab(title: "connecting")
        let second = Tab(title: "failed")

        let groups = TerminalTabGrouping.groups(for: [first, second])

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].tabs.map(\.id), [first.id])
        XCTAssertEqual(groups[1].tabs.map(\.id), [second.id])
    }

    @MainActor
    func testGroupOrderFollowsFirstTabAppearance() {
        let firstSession = SSHSession()
        let secondSession = SSHSession()
        let first = Tab(title: "shell", session: firstSession)
        let standalone = Tab(title: "connecting")
        let second = Tab(title: "logs", session: firstSession)
        let third = Tab(title: "prod", session: secondSession)

        let groups = TerminalTabGrouping.groups(for: [first, standalone, second, third])

        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups[0].tabs.map(\.id), [first.id, second.id])
        XCTAssertEqual(groups[1].tabs.map(\.id), [standalone.id])
        XCTAssertEqual(groups[2].tabs.map(\.id), [third.id])
    }
}
