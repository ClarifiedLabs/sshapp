import XCTest
import UIKit
import GhosttyTerminal
@testable import SSHApp

final class TerminalTabShortcutTests: XCTestCase {
    @MainActor
    func testSoftwareKeyboardReturnInvokesDirectReturnHandler() {
        let terminalView = ShortcutAwareTerminalView(frame: .zero)
        var returnCount = 0
        terminalView.onSoftwareKeyboardReturn = {
            returnCount += 1
        }

        terminalView.insertText("\n")
        terminalView.insertText("\r")

        XCTAssertEqual(returnCount, 2)
    }

    @MainActor
    func testSoftwareKeyboardReturnHandlerIgnoresNonReturnText() {
        let terminalView = ShortcutAwareTerminalView(frame: .zero)
        var returnCount = 0
        terminalView.onSoftwareKeyboardReturn = {
            returnCount += 1
        }

        terminalView.insertText("ls")

        XCTAssertEqual(returnCount, 0)
    }

    @MainActor
    func testSoftwareKeyboardTextUsesDirectInMemoryInputRoute() {
        let terminalView = ShortcutAwareTerminalView(frame: .zero)
        let recorder = TerminalInputRecorder()
        let terminalSession = InMemoryTerminalSession(
            write: { data in recorder.append(data) },
            resize: { _ in }
        )
        terminalView.configuration = TerminalSurfaceOptions(backend: .inMemory(terminalSession))

        terminalView.insertText("ls")

        XCTAssertEqual(recorder.data, Data("ls".utf8))
    }

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
        XCTAssertEqual(
            TerminalTabShortcut.shortcut(input: "0", modifierFlags: [.command]),
            .selectHostTab(0)
        )
    }

    func testTmuxModeCommandNumberShortcutsSelectTmuxWindows() {
        XCTAssertEqual(
            TerminalTabShortcut.shortcut(
                input: "1",
                modifierFlags: [.command],
                enabledScopes: [.hostTabs, .tmuxWindows],
                prefersTmuxWindowNumberShortcuts: true
            ),
            .selectTmuxWindow(1)
        )
        XCTAssertEqual(
            TerminalTabShortcut.shortcut(
                input: "0",
                modifierFlags: [.command],
                enabledScopes: [.hostTabs, .tmuxWindows],
                prefersTmuxWindowNumberShortcuts: true
            ),
            .selectTmuxWindow(0)
        )
    }

    func testTmuxModeCommandNumberPreferenceDoesNotStealHostOnlyScope() {
        XCTAssertEqual(
            TerminalTabShortcut.shortcut(
                input: "1",
                modifierFlags: [.command],
                enabledScopes: [.hostTabs],
                prefersTmuxWindowNumberShortcuts: true
            ),
            .selectHostTab(1)
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
            TerminalTabShortcut.shortcut(input: "0", modifierFlags: [.command, .alternate]),
            .selectTmuxWindow(0)
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

private final class TerminalInputRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
    }
}
