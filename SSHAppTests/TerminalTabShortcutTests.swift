import XCTest
import UIKit
@testable import SSHApp

final class TerminalTabShortcutTests: XCTestCase {
    func testHostTabArrowShortcuts() {
        XCTAssertEqual(
            TerminalTabShortcut.shortcut(
                input: UIKeyCommand.inputLeftArrow,
                modifierFlags: [.command]
            ),
            .previousHostTab
        )
        XCTAssertEqual(
            TerminalTabShortcut.shortcut(
                input: UIKeyCommand.inputRightArrow,
                modifierFlags: [.command]
            ),
            .nextHostTab
        )
    }

    func testHostTabBracketShortcuts() {
        XCTAssertEqual(
            TerminalTabShortcut.shortcut(input: "[", modifierFlags: [.command, .shift]),
            .previousHostTab
        )
        XCTAssertEqual(
            TerminalTabShortcut.shortcut(input: "]", modifierFlags: [.command, .shift]),
            .nextHostTab
        )
    }

    func testHostTabNumberShortcuts() {
        XCTAssertEqual(
            TerminalTabShortcut.shortcut(input: "1", modifierFlags: [.command]),
            .selectHostTab(1)
        )
        XCTAssertEqual(
            TerminalTabShortcut.shortcut(input: "9", modifierFlags: [.command]),
            .selectHostTab(9)
        )
    }

    func testCommandTOpensContextualNewTerminal() {
        XCTAssertEqual(
            TerminalTabShortcut.shortcut(input: "t", modifierFlags: [.command]),
            .newTerminal
        )
    }

    func testTmuxWindowShortcutsUseCommandOption() {
        XCTAssertEqual(
            TerminalTabShortcut.shortcut(
                input: UIKeyCommand.inputLeftArrow,
                modifierFlags: [.command, .alternate]
            ),
            .previousTmuxWindow
        )
        XCTAssertEqual(
            TerminalTabShortcut.shortcut(
                input: UIKeyCommand.inputRightArrow,
                modifierFlags: [.command, .alternate]
            ),
            .nextTmuxWindow
        )
        XCTAssertEqual(
            TerminalTabShortcut.shortcut(input: "9", modifierFlags: [.command, .alternate]),
            .selectTmuxWindow(9)
        )
    }

    func testScopesFilterUnavailableShortcuts() {
        XCTAssertNil(
            TerminalTabShortcut.shortcut(
                input: UIKeyCommand.inputRightArrow,
                modifierFlags: [.command, .alternate],
                enabledScopes: [.hostTabs]
            )
        )
        XCTAssertEqual(
            TerminalTabShortcut.shortcut(
                input: UIKeyCommand.inputRightArrow,
                modifierFlags: [.command],
                enabledScopes: [.hostTabs]
            ),
            .nextHostTab
        )
    }
}
