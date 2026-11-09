import UIKit
import XCTest
@testable import SSHApp

@MainActor
final class TerminalTabMenuGestureTests: XCTestCase {
    func testTwoFingerHoldCoexistsWithExistingTerminalGestures() throws {
        let terminal = ShortcutAwareTerminalView(frame: .zero)
        let hold = try XCTUnwrap(terminal.tabMenuLongPressGesture)
        XCTAssertTrue(hold.view === terminal)
        XCTAssertTrue(hold.delegate === terminal)
        XCTAssertEqual(hold.numberOfTouchesRequired, 2)
        XCTAssertEqual(hold.minimumPressDuration, 0.5)
        XCTAssertEqual(hold.allowableMovement, 10)
        XCTAssertEqual(hold.allowedTouchTypes, [NSNumber(value: UITouch.TouchType.direct.rawValue)])
        let gestures = terminal.gestureRecognizers ?? []
        XCTAssertEqual(gestures.compactMap { $0 as? UILongPressGestureRecognizer }
            .filter { $0.numberOfTouchesRequired == 1 }.count, 1)
        XCTAssertEqual(gestures.compactMap { $0 as? UIPinchGestureRecognizer }.count, 1)
        XCTAssertEqual(gestures.compactMap { $0 as? UITapGestureRecognizer }
            .filter { $0.numberOfTouchesRequired == 2 && $0.numberOfTapsRequired == 1 }.count, 1)
        for gesture in gestures where gesture is UIPinchGestureRecognizer || gesture is UITapGestureRecognizer {
            XCTAssertFalse(terminal.gestureRecognizer(hold, shouldRecognizeSimultaneouslyWith: gesture))
        }
    }

    func testHoldDisabledWithoutMenuAndForHiddenTerminal() throws {
        let terminal = ShortcutAwareTerminalView(frame: .zero)
        let hold = try XCTUnwrap(terminal.tabMenuLongPressGesture)
        XCTAssertFalse(terminal.gestureRecognizerShouldBegin(hold))
        terminal.tabMenuItems = { [] }
        XCTAssertTrue(terminal.gestureRecognizerShouldBegin(hold))
        terminal.isHostVisible = false
        XCTAssertFalse(terminal.gestureRecognizerShouldBegin(hold))
        terminal.isHostVisible = true
        terminal.tabMenuItems = nil
        XCTAssertFalse(terminal.gestureRecognizerShouldBegin(hold))
    }

    func testMenuUsesFreshProviderAndNeverIncludesSuggestedTextActions() throws {
        let terminal = ShortcutAwareTerminalView(frame: .zero)
        let interaction = try XCTUnwrap(terminal.subviews.flatMap(\.interactions)
            .compactMap { $0 as? UIEditMenuInteraction }.last)
        let host = try XCTUnwrap(interaction.view)
        XCTAssertFalse(host === terminal, "Edit menus must not install secondary-click handling on the terminal")
        XCTAssertFalse(host.isUserInteractionEnabled)
        XCTAssertFalse(terminal.interactions.contains { $0 is UIEditMenuInteraction })
        let configuration = UIEditMenuConfiguration(identifier: "terminal.tabMenu" as NSString, sourcePoint: .zero)
        var title = "First"
        terminal.tabMenuItems = {
            [.action(TerminalTabMenuAction(title: title, systemImage: "plus", isDestructive: false,
                accessibilityIdentifier: "test.action", action: {}))]
        }
        func requestedMenu() -> UIMenu? {
            terminal.editMenuInteraction(interaction, menuFor: configuration,
                suggestedActions: [UIAction(title: "Paste", handler: { _ in XCTFail("Unexpected text action") })])
        }
        XCTAssertNil(terminal.editMenuInteraction(interaction,
            menuFor: UIEditMenuConfiguration(identifier: nil, sourcePoint: .zero), suggestedActions: []),
            "Only the explicit two-finger hold may request the tab menu")
        XCTAssertEqual(requestedMenu()?.children.map(\.title), ["First"])
        title = "Updated"
        XCTAssertEqual(requestedMenu()?.children.map(\.title), ["Updated"])
        terminal.isHostVisible = false
        XCTAssertNil(requestedMenu())
        terminal.isHostVisible = true
        terminal.tabMenuItems = { [] }
        XCTAssertNil(requestedMenu())
        terminal.tabMenuItems = nil
        XCTAssertNil(requestedMenu())
    }
}
