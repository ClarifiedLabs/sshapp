import XCTest
@testable import SSHApp

final class TabSelectionHistoryTests: XCTestCase {
    func testMostRecentActiveTabUsesLastSelection() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        var history = TabSelectionHistory()

        history.recordSelection(first)
        history.recordSelection(second)
        history.recordSelection(third)

        XCTAssertEqual(
            history.mostRecentActiveTabId(activeTabIds: [first, second, third]),
            third
        )
    }

    func testMostRecentActiveTabSkipsClosedTabs() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        var history = TabSelectionHistory()

        history.recordSelection(first)
        history.recordSelection(second)
        history.recordSelection(third)
        history.remove(third)

        XCTAssertEqual(
            history.mostRecentActiveTabId(activeTabIds: [first, second]),
            second
        )
    }

    func testPruneRemovesInactiveTabIds() {
        let active = UUID()
        let closed = UUID()
        var history = TabSelectionHistory()

        history.recordSelection(closed)
        history.recordSelection(active)
        history.prune(activeTabIds: [active])

        XCTAssertEqual(history.orderedTabIds, [active])
    }
}
