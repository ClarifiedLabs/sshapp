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

    func testDirectShortcutDigitUsesTabOrder() {
        XCTAssertEqual(
            IndexedTabNavigation.item(forShortcutDigit: 2, in: ["first", "second", "third"]),
            "second"
        )
    }

    func testShortcutDigitNineSelectsNinthItem() {
        let items = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth"]

        XCTAssertEqual(
            IndexedTabNavigation.item(forShortcutDigit: 9, in: items),
            "ninth"
        )
    }

    func testShortcutDigitZeroSelectsTenthItem() {
        let items = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth"]

        XCTAssertEqual(
            IndexedTabNavigation.item(forShortcutDigit: 0, in: items),
            "tenth"
        )
    }

    func testOutOfBoundsShortcutDigitIsNoOp() {
        XCTAssertNil(IndexedTabNavigation.item(forShortcutDigit: 4, in: [1, 2, 3]))
        XCTAssertNil(IndexedTabNavigation.item(forShortcutDigit: 0, in: [1, 2, 3]))
        XCTAssertNil(IndexedTabNavigation.item(forShortcutDigit: -1, in: [1, 2, 3]))
        XCTAssertNil(IndexedTabNavigation.next(in: [Int](), selected: nil))
        XCTAssertNil(IndexedTabNavigation.previous(in: [Int](), selected: nil))
    }

    func testShortcutDisplayDigitsFollowVisibleTabOrder() {
        XCTAssertEqual(
            (0..<10).compactMap { IndexedTabNavigation.shortcutDigit(forItemAt: $0, itemCount: 10) },
            [1, 2, 3, 4, 5, 6, 7, 8, 9, 0]
        )
    }

    func testShortcutDisplayDigitsStopAfterTenthItem() {
        XCTAssertEqual(IndexedTabNavigation.shortcutDigit(forItemAt: 0, itemCount: 11), 1)
        XCTAssertEqual(IndexedTabNavigation.shortcutDigit(forItemAt: 8, itemCount: 11), 9)
        XCTAssertEqual(IndexedTabNavigation.shortcutDigit(forItemAt: 9, itemCount: 11), 0)
        XCTAssertNil(IndexedTabNavigation.shortcutDigit(forItemAt: 10, itemCount: 11))
    }

    func testShortcutDisplayDigitRejectsInvalidIndexes() {
        XCTAssertNil(IndexedTabNavigation.shortcutDigit(forItemAt: -1, itemCount: 3))
        XCTAssertNil(IndexedTabNavigation.shortcutDigit(forItemAt: 3, itemCount: 3))
        XCTAssertNil(IndexedTabNavigation.shortcutDigit(forItemAt: 0, itemCount: 0))
    }
}
