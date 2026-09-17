import XCTest
import UIKit
@testable import GhosttyTerminal
@testable import SSHApp

@MainActor
final class IOS27WindowTests: XCTestCase {
    func testCursorPasteMenuUsesTheSystemPasteActionIdentifier() throws {
        let previousItems = UIPasteboard.general.items
        defer { UIPasteboard.general.items = previousItems }
        UIPasteboard.general.string = "paste regression fixture"
        let terminal = UITerminalView(frame: .zero)
        let actions = terminal.terminalInputMenuElements()
        let paste = try XCTUnwrap(actions.first as? UIAction)
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(paste.identifier, .paste)
    }

    func testPrivacyCoverDoesNotAffectAnotherWindowsCover() {
        let first = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        let second = UIWindow(frame: first.frame)
        let firstContent = UIView(frame: first.bounds)
        let secondContent = UIView(frame: second.bounds)
        first.addSubview(firstContent)
        second.addSubview(secondContent)

        PrivacyScreen.show(in: [first])
        XCTAssertEqual(first.subviews.count, 2)
        XCTAssertEqual(second.subviews, [secondContent])
        let cover = first.subviews.last!
        PrivacyScreen.show(in: [first])
        XCTAssertEqual(first.subviews.count, 2, "Repeated inactive notifications must not stack covers")

        PrivacyScreen.show(in: [second])
        PrivacyScreen.hide(in: [second])
        XCTAssertTrue(first.subviews.last === cover, "Activating another scene must not expose this window")
        XCTAssertEqual(second.subviews, [secondContent])
        PrivacyScreen.hide(in: [first])
        XCTAssertEqual(first.subviews, [firstContent])
    }

    func testTerminalUsesItsDisplayTraitsWhenTheyDifferFromTheMainScreen() {
        let terminal = UITerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        let window = UIWindow(frame: terminal.frame)
        window.addSubview(terminal)
        defer { terminal.removeFromSuperview() }
        terminal.traitOverrides.displayScale = 1
        terminal.updateTraitsIfNeeded()
        terminal.updateDisplayScale()
        XCTAssertEqual(terminal.resolvedDisplayScale(), 1)
        XCTAssertEqual(terminal.layer.contentsScale, 1)

        terminal.traitOverrides.displayScale = 2
        terminal.updateTraitsIfNeeded()
        terminal.updateDisplayScale()
        XCTAssertEqual(terminal.resolvedDisplayScale(), 2)
        XCTAssertEqual(terminal.contentScaleFactor, 2)
    }
}
