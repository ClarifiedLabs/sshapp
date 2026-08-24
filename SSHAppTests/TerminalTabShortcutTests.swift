import XCTest
import UIKit
import GhosttyKit
@testable import GhosttyTerminal
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

    @MainActor
    func testKeyboardBarControlModifiesNextSoftwareKeyboardCharacter() {
        let terminalView = ShortcutAwareTerminalView(frame: .zero)
        let recorder = TerminalInputRecorder()
        let terminalSession = InMemoryTerminalSession(
            write: { data in recorder.append(data) },
            resize: { _ in }
        )
        terminalView.configuration = TerminalSurfaceOptions(backend: .inMemory(terminalSession))
        let keyboardBarTarget = TerminalKeyboardBarTarget()
        keyboardBarTarget.attach(terminalView)
        defer { keyboardBarTarget.detach(terminalView) }

        keyboardBarTarget.perform(.ctrl)
        XCTAssertEqual(keyboardBarTarget.ctrlActivation, .armed)

        terminalView.insertText("c")
        terminalView.insertText("d")

        XCTAssertEqual(
            Array(recorder.data),
            [0x03, UInt8(ascii: "d")],
            "Armed Control must modify exactly one software-keyboard character"
        )
        XCTAssertEqual(keyboardBarTarget.ctrlActivation, .inactive)
    }

    @MainActor
    func testKeyboardBarControlModifiesPlainMarkedTextCharacter() {
        let terminalView = ShortcutAwareTerminalView(frame: .zero)
        let recorder = TerminalInputRecorder()
        let terminalSession = InMemoryTerminalSession(
            write: { data in recorder.append(data) },
            resize: { _ in }
        )
        terminalView.configuration = TerminalSurfaceOptions(backend: .inMemory(terminalSession))
        let keyboardBarTarget = TerminalKeyboardBarTarget()
        keyboardBarTarget.attach(terminalView)
        defer { keyboardBarTarget.detach(terminalView) }

        keyboardBarTarget.perform(.ctrl)
        terminalView.setMarkedText("d", selectedRange: NSRange(location: 1, length: 0))

        XCTAssertEqual(Array(recorder.data), [0x04])
        XCTAssertEqual(keyboardBarTarget.ctrlActivation, .inactive)
    }

    @MainActor
    func testKeyboardBarAltAndCommandAreConsumedBySoftwareKeyboardText() {
        let terminalView = ShortcutAwareTerminalView(frame: .zero)
        let keyboardBarTarget = TerminalKeyboardBarTarget()
        keyboardBarTarget.attach(terminalView)
        defer { keyboardBarTarget.detach(terminalView) }

        keyboardBarTarget.perform(.alt)
        XCTAssertEqual(keyboardBarTarget.altActivation, .armed)
        terminalView.insertText("x")
        XCTAssertEqual(keyboardBarTarget.altActivation, .inactive)

        keyboardBarTarget.perform(.command)
        XCTAssertEqual(keyboardBarTarget.commandActivation, .armed)
        terminalView.insertText("x")
        XCTAssertEqual(terminalView.stickyActivation(for: .command), .inactive)
        XCTAssertEqual(keyboardBarTarget.commandActivation, .inactive)
    }

    @MainActor
    func testLockedKeyboardBarControlModifiesEverySoftwareKeyboardCharacter() {
        let terminalView = ShortcutAwareTerminalView(frame: .zero)
        let recorder = TerminalInputRecorder()
        let terminalSession = InMemoryTerminalSession(
            write: { data in recorder.append(data) },
            resize: { _ in }
        )
        terminalView.configuration = TerminalSurfaceOptions(backend: .inMemory(terminalSession))
        let keyboardBarTarget = TerminalKeyboardBarTarget()
        keyboardBarTarget.attach(terminalView)
        defer { keyboardBarTarget.detach(terminalView) }

        keyboardBarTarget.perform(.ctrl)
        keyboardBarTarget.perform(.ctrl)
        XCTAssertEqual(keyboardBarTarget.ctrlActivation, .locked)

        terminalView.insertText("c")
        terminalView.insertText("d")

        XCTAssertEqual(Array(recorder.data), [0x03, 0x04])
        XCTAssertEqual(keyboardBarTarget.ctrlActivation, .locked)
    }

    @MainActor
    func testStickyModifierSkipsDirectSoftwareReturnHandler() {
        let terminalView = ShortcutAwareTerminalView(frame: .zero)
        let keyboardBarTarget = TerminalKeyboardBarTarget()
        keyboardBarTarget.attach(terminalView)
        defer { keyboardBarTarget.detach(terminalView) }
        var returnCount = 0
        terminalView.onSoftwareKeyboardReturn = { returnCount += 1 }

        keyboardBarTarget.perform(.ctrl)
        terminalView.insertText("\n")

        XCTAssertEqual(returnCount, 0)
        XCTAssertEqual(keyboardBarTarget.ctrlActivation, .inactive)
    }

    @MainActor
    func testKeyboardBarControlModifiesNextHardwareKeyboardCharacter() async throws {
        let terminalView = ShortcutAwareTerminalView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 600)
        )
        let mounted = try mountTerminal(terminalView)
        defer { unmountTerminal(mounted) }
        let recorder = TerminalInputRecorder()
        let inputReceived = expectation(description: "Control-C reaches the host session")
        let terminalSession = InMemoryTerminalSession(
            write: { data in
                recorder.append(data)
                inputReceived.fulfill()
            },
            resize: { _ in }
        )
        terminalView.configuration = TerminalSurfaceOptions(backend: .inMemory(terminalSession))
        terminalView.controller = TerminalController()
        XCTAssertNotNil(terminalView.surface)
        terminalView.setTerminalSurfaceFocused(true)

        let keyboardBarTarget = TerminalKeyboardBarTarget()
        keyboardBarTarget.attach(terminalView)
        defer { keyboardBarTarget.detach(terminalView) }
        let key = TerminalUIKitKeyPress(
            keyCode: UIKeyboardHIDUsage(rawValue: 0x06)!,
            characters: "c"
        )

        keyboardBarTarget.perform(.ctrl)
        terminalView.handleKeyPress(key, action: GHOSTTY_ACTION_PRESS)
        terminalView.handleKeyPress(key, action: GHOSTTY_ACTION_RELEASE)
        await fulfillment(of: [inputReceived], timeout: 1)

        XCTAssertEqual(
            Array(TerminalInputNormalizer.normalize(recorder.data)),
            [0x03]
        )
        XCTAssertEqual(keyboardBarTarget.ctrlActivation, .inactive)
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

    @MainActor
    private func mountTerminal(
        _ terminal: ShortcutAwareTerminalView
    ) throws -> MountedShortcutTerminal {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else {
            throw XCTSkip("The app-hosted unit test has no UIWindowScene")
        }

        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let rootViewController = UIViewController()
        rootViewController.view.frame = terminal.frame
        rootViewController.view.addSubview(terminal)
        window.rootViewController = rootViewController
        window.frame = scene.coordinateSpace.bounds
        window.makeKeyAndVisible()
        rootViewController.view.layoutIfNeeded()

        return MountedShortcutTerminal(
            terminal: terminal,
            window: window,
            previousKeyWindow: previousKeyWindow
        )
    }

    @MainActor
    private func unmountTerminal(_ mounted: MountedShortcutTerminal) {
        mounted.terminal.controller = nil
        mounted.terminal.removeFromSuperview()
        mounted.window.isHidden = true
        mounted.previousKeyWindow?.makeKey()
    }
}

@MainActor
private struct MountedShortcutTerminal {
    let terminal: ShortcutAwareTerminalView
    let window: UIWindow
    let previousKeyWindow: UIWindow?
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
