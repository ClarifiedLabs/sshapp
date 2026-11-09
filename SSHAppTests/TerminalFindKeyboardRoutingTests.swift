import UIKit
import XCTest
@testable import GhosttyTerminal
@testable import SSHApp

@MainActor
private final class FindRoutingKey: UIKey {
    private let usage: UIKeyboardHIDUsage
    private let text: String
    private let modifiers: UIKeyModifierFlags

    init(usage: UIKeyboardHIDUsage, text: String, modifiers: UIKeyModifierFlags = []) {
        self.usage = usage
        self.text = text
        self.modifiers = modifiers
        super.init()
    }

    required init?(coder: NSCoder) { fatalError("Not used by this fixture") }
    override var keyCode: UIKeyboardHIDUsage { usage }
    override var characters: String { text }
    override var charactersIgnoringModifiers: String { text }
    override var modifierFlags: UIKeyModifierFlags { modifiers }
}

@MainActor
private final class FindRoutingPress: UIPress {
    private let testKey: UIKey

    init(_ key: UIKey) {
        testKey = key
        super.init()
    }

    override var key: UIKey? { testKey }
}

@MainActor
private final class FindPressRecordingView: UIView {
    var phases: [String] = []

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        phases.append("began")
    }

    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        phases.append("changed")
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        phases.append("ended")
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        phases.append("cancelled")
    }
}

@MainActor
final class TerminalFindKeyboardRoutingTests: XCTestCase {
    func testFindHardwarePressesStayInNativeResponderChainForBaseAndProductionHost() async throws {
        for host in [UITerminalView(), ShortcutAwareTerminalView()] {
            let writes = ByteRecorder()
            let session = VTTerminalSession(write: { writes.append($0) }, resize: { _ in })
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
            let root = UIViewController()
            let recorder = FindPressRecordingView(frame: window.bounds)
            root.view = recorder
            window.rootViewController = root
            host.frame = recorder.bounds
            recorder.addSubview(host)
            window.isHidden = false
            host.configuration = .init(backend: .vt(session))
            host.controller = TerminalController()
            host.findApplicationActive = true
            host.hardwareKeyRepeatConfiguration = .init(enabled: true)
            defer {
                host.dismissFind(restoringFocus: false)
                host.controller = nil
                window.isHidden = true
                session.finish()
            }
            var shortcuts = 0
            if let productionHost = host as? ShortcutAwareTerminalView {
                productionHost.enabledShortcutScopes = [.hostTabs, .tmuxWindows]
                productionHost.onShortcut = { _ in shortcuts += 1 }
            }
            host.presentFind()
            let find = try XCTUnwrap(host.findController)
            XCTAssertTrue(find.field.isFirstResponder)

            // These physical events can bubble through the ancestor terminal
            // before UIKit completes the native text field's editing.
            for key in [
                FindRoutingKey(usage: .keyboardA, text: "a"),
                FindRoutingKey(usage: .keyboardDeleteOrBackspace, text: ""),
                FindRoutingKey(usage: .keyboardLeftArrow, text: UIKeyCommand.inputLeftArrow, modifiers: .command),
            ] {
                recorder.phases = []
                let presses: Set<UIPress> = [FindRoutingPress(key)]
                host.pressesBegan(presses, with: nil)
                host.pressesChanged(presses, with: nil)
                host.pressesEnded(presses, with: nil)
                host.pressesCancelled(presses, with: nil)
                XCTAssertEqual(recorder.phases, ["began", "changed", "ended", "cancelled"])
            }
            XCTAssertTrue(host.findKeyCodes.isEmpty, "Ordinary field keys must not become terminal-owned HID lifecycles")
            XCTAssertNil(host.hardwareKeyRepeatTask)
            XCTAssertFalse(host.hardwareKeyHandled)
            XCTAssertEqual(shortcuts, 0, "Command-arrow must edit the query, not switch tabs")
            XCTAssertTrue((host.keyCommands ?? []).isEmpty, "Ancestor tab commands must not override Find editing")

            find.field.insertText("native query")
            XCTAssertEqual(find.field.text, "native query")
            find.field.deleteBackward()
            XCTAssertEqual(find.field.text, "native quer")
            find.field.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0))
            XCTAssertNotNil(find.field.markedTextRange)
            find.field.unmarkText()

            // Closing Find while a physical key is held must not leak its late
            // repeat or release into a remote Kitty/modifyOtherKeys lifecycle.
            let held: Set<UIPress> = [FindRoutingPress(FindRoutingKey(usage: .keyboardB, text: "b"))]
            host.pressesBegan(held, with: nil)
            host.dismissFind(restoringFocus: false)
            host.pressesChanged(held, with: nil)
            host.pressesEnded(held, with: nil)
            XCTAssertTrue(host.findKeyCodes.isEmpty)
            if host is ShortcutAwareTerminalView {
                XCTAssertFalse((host.keyCommands ?? []).isEmpty, "Tab commands must return after Find closes")
            }
            _ = try await session.snapshot()
            XCTAssertTrue(writes.data.isEmpty, "Find input must never reach SSH")

            // Also cover the opposite transition: a terminal-owned key released
            // inside Find must clear text-suppression state for typing afterward.
            let terminalHeld: Set<UIPress> = [FindRoutingPress(FindRoutingKey(usage: .keyboardC, text: "c"))]
            host.pressesBegan(terminalHeld, with: nil)
            host.presentFind()
            XCTAssertTrue(host.isFindPresented)
            host.pressesEnded(terminalHeld, with: nil)
            host.dismissFind(restoringFocus: false)
            try await Task.sleep(for: .milliseconds(150))
            host.insertText("z")
            _ = try await session.snapshot()
            XCTAssertEqual(writes.data, Data("cz".utf8))
        }
    }

    func testProductionDirectTextRouteCannotBypassFindInputIsolation() async throws {
        let writes = ByteRecorder()
        let session = VTTerminalSession(write: { writes.append($0) }, resize: { _ in })
        defer { session.finish() }
        let host = ShortcutAwareTerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let window = UIWindow(frame: host.bounds)
        let root = UIViewController()
        window.rootViewController = root
        root.view.addSubview(host)
        window.isHidden = false
        host.configuration = .init(backend: .vt(session))
        host.controller = TerminalController()
        host.findApplicationActive = true
        defer {
            host.dismissFind(restoringFocus: false)
            host.controller = nil
            window.isHidden = true
        }
        var returns = 0
        var shortcuts = 0
        host.onSoftwareKeyboardReturn = { returns += 1 }
        host.enabledShortcutScopes = [.hostTabs]
        host.onShortcut = { _ in shortcuts += 1 }
        host.presentFind()
        XCTAssertTrue(host.isFindPresented)

        host.insertText("private query must not be sent")
        host.insertText("\n")
        host.handleShortcutKeyCommand(UIKeyCommand(input: "t", modifierFlags: .command,
            action: #selector(ShortcutAwareTerminalView.handleShortcutKeyCommand(_:))))
        _ = try await session.snapshot()
        XCTAssertTrue(writes.data.isEmpty)
        XCTAssertEqual(returns, 0)
        XCTAssertEqual(shortcuts, 0)

        host.dismissFind(restoringFocus: false)
        let heldReturn: Set<UIPress> = [FindRoutingPress(FindRoutingKey(usage: .keyboardReturnOrEnter, text: "\r"))]
        host.pressesBegan(heldReturn, with: nil)
        host.presentFind()
        XCTAssertTrue(host.isFindPresented)
        host.pressesCancelled(heldReturn, with: nil)
        host.dismissFind(restoringFocus: false)
        try await Task.sleep(for: .milliseconds(150))
        _ = try await session.snapshot()
        let hardwareReturnBytes = writes.data
        host.insertText("\n")
        _ = try await session.snapshot()
        XCTAssertEqual(returns, 1, "Software Return must use its own callback after Find closes")
        XCTAssertEqual(writes.data, hardwareReturnBytes)
    }
}
