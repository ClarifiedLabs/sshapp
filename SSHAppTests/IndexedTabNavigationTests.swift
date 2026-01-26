import XCTest
@testable import SSHApp

final class IndexedTabNavigationTests: XCTestCase {
    func testPreviousWrapsToLastItem() {
        XCTAssertEqual(
            IndexedTabNavigation.previous(in: [1, 2, 3], selected: 1),
            3
        )
    }

    func testNextWrapsToFirstItem() {
        XCTAssertEqual(
            IndexedTabNavigation.next(in: [1, 2, 3], selected: 3),
            1
        )
    }

    func testMissingSelectedFallsBackByDirection() {
        XCTAssertEqual(
            IndexedTabNavigation.previous(in: [1, 2, 3], selected: 9),
            3
        )
        XCTAssertEqual(
            IndexedTabNavigation.next(in: [1, 2, 3], selected: 9),
            1
        )
    }

    func testDirectShortcutSlotUsesTabOrder() {
        XCTAssertEqual(
            IndexedTabNavigation.item(forShortcutSlot: 2, in: ["first", "second", "third"]),
            "second"
        )
    }

    func testShortcutSlotNineSelectsLastItem() {
        XCTAssertEqual(
            IndexedTabNavigation.item(forShortcutSlot: 9, in: ["first", "second", "third"]),
            "third"
        )
    }

    func testOutOfBoundsShortcutSlotIsNoOp() {
        XCTAssertNil(IndexedTabNavigation.item(forShortcutSlot: 4, in: [1, 2, 3]))
        XCTAssertNil(IndexedTabNavigation.item(forShortcutSlot: 0, in: [1, 2, 3]))
        XCTAssertNil(IndexedTabNavigation.next(in: [Int](), selected: nil))
        XCTAssertNil(IndexedTabNavigation.previous(in: [Int](), selected: nil))
    }
}
