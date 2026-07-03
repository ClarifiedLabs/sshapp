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
        let connection = SavedConnection(host: "mini-m4", username: "twt")
        let tab = Tab(title: connection.displayDestination, connectionState: .connected, connection: connection)

        tab.title = "Title"

        XCTAssertEqual(tab.connectionDisplayTitle, "twt@mini-m4")
        XCTAssertEqual(TerminalTabGrouping.groups(for: [tab])[0].title, "twt@mini-m4")
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
