import XCTest
import UIKit
@testable import GhosttyTerminal
@testable import SSHApp

final class TerminalTabShortcutTests: XCTestCase {
    @MainActor
    func testHiddenHostRejectsDirectSoftwareInputButKeepsTerminalReplies() async throws {
        let recorder = ByteRecorder()
        let session = VTTerminalSession(write: { recorder.append($0) }, resize: { _ in })
        defer { session.finish() }
        let mounted = try mountVTTerminal(session: session)
        defer { unmountTerminal(mounted) }
        let host = mounted.terminal
        var returns = 0
        var shortcuts = 0
        host.onSoftwareKeyboardReturn = { returns += 1 }
        host.enabledShortcutScopes = [.hostTabs]
        host.onShortcut = { _ in shortcuts += 1 }
        host.isHostVisible = false
        host.insertText("hidden")
        host.insertText("\n")
        host.handleShortcutKeyCommand(UIKeyCommand(input: "t", modifierFlags: .command,
            action: #selector(ShortcutAwareTerminalView.handleShortcutKeyCommand(_:))))
        session.receive(Data("\u{1B}[5n".utf8))
        try await drainInput(session)
        XCTAssertEqual(recorder.data, Data("\u{1B}[0n".utf8), "Hidden terminal replies must remain ordered and deliverable")
        XCTAssertEqual(returns, 0)
        XCTAssertEqual(shortcuts, 0)
        host.isHostVisible = true
        host.insertText("visible")
        try await drainInput(session)
        XCTAssertEqual(recorder.data, Data("\u{1B}[0nvisible".utf8))
    }

    @MainActor
    func testKeyboardBarPasteDeliversTextAndReturnThroughVTInput() async throws {
        let recorder = ByteRecorder()
        let terminalSession = VTTerminalSession(
            write: { recorder.append($0) }, resize: { _ in }
        )
        defer { terminalSession.finish() }
        let mounted = try mountVTTerminal(session: terminalSession)
        defer { unmountTerminal(mounted) }
        let terminalView = mounted.terminal
        let target = TerminalKeyboardBarTarget()
        target.attach(terminalView)
        // The remote application enables native bracketed paste before multiline input.
        terminalSession.receive(Data("\u{1B}[?2004h".utf8))
        UIPasteboard.general.string = "synthetic response\n"
        defer {
            UIPasteboard.general.items = []
            target.detach(terminalView)
        }

        target.perform(.paste)

        try await drainInput(terminalSession)
        XCTAssertEqual(recorder.data, Data("\u{1B}[200~synthetic response\n\u{1B}[201~".utf8))
    }

    @MainActor
    func testSystemPastePayloadIsUsedWithoutReadingClipboardAgain() async throws {
        let recorder = ByteRecorder()
        let terminalSession = VTTerminalSession(
            write: { recorder.append($0) }, resize: { _ in }
        )
        defer { terminalSession.finish() }
        let mounted = try mountVTTerminal(session: terminalSession)
        defer { unmountTerminal(mounted) }
        let terminalView = mounted.terminal
        let target = TerminalKeyboardBarTarget()
        target.attach(terminalView)
        // The remote application enables native bracketed paste before multiline input.
        terminalSession.receive(Data("\u{1B}[?2004h".utf8))
        UIPasteboard.general.string = "different clipboard value"
        defer {
            UIPasteboard.general.items = []
            target.detach(terminalView)
        }
        target.perform(.ctrl)

        target.paste("synthetic response\n", into: target.pasteDestination)

        try await drainInput(terminalSession)
        XCTAssertEqual(recorder.data, Data("\u{1B}[200~synthetic response\n\u{1B}[201~".utf8))
        XCTAssertEqual(target.ctrlActivation, .inactive)
    }

    @MainActor
    func testSafePasteWithoutBracketedModeDoesNotRequireConfirmation() async throws {
        let recorder = ByteRecorder()
        let terminalSession = VTTerminalSession(write: { recorder.append($0) }, resize: { _ in })
        defer { terminalSession.finish() }
        let mounted = try mountVTTerminal(session: terminalSession)
        defer { unmountTerminal(mounted) }
        let target = TerminalKeyboardBarTarget()
        target.attach(mounted.terminal)
        defer { target.detach(mounted.terminal) }

        target.paste("safe single-line text", into: target.pasteDestination)

        try await drainInput(terminalSession)
        XCTAssertEqual(recorder.data, Data("safe single-line text".utf8))
        XCTAssertNil(mounted.presenter.presentedAlert)
    }

    @MainActor
    func testUnsafePasteWithoutConfirmationDoesNotWriteForEitherEntryPoint() async throws {
        for usesKeyboardBarButton in [false, true] {
            let recorder = ByteRecorder()
            let terminalSession = VTTerminalSession(write: { recorder.append($0) }, resize: { _ in })
            defer { terminalSession.finish() }
            let mounted = try mountVTTerminal(session: terminalSession)
            defer { unmountTerminal(mounted) }
            let target = TerminalKeyboardBarTarget()
            target.attach(mounted.terminal)
            UIPasteboard.general.string = "unconfirmed command\n"
            defer {
                UIPasteboard.general.items = []
                target.detach(mounted.terminal)
            }
            let confirmationRequested = expectation(
                description: "Unsafe paste requests confirmation (keyboard bar button: \(usesKeyboardBarButton))"
            )
            mounted.presenter.onPresentation = { confirmationRequested.fulfill() }
            target.perform(.ctrl)

            if usesKeyboardBarButton {
                target.perform(.paste)
            } else {
                target.paste("unconfirmed command\n", into: target.pasteDestination)
            }

            await fulfillment(of: [confirmationRequested], timeout: 1)
            let alert = try XCTUnwrap(mounted.presenter.presentedAlert)
            XCTAssertEqual(alert.title, "Paste potentially unsafe text?")
            XCTAssertEqual(alert.actions.map(\.title), ["Cancel", "Paste"])
            XCTAssertEqual(alert.actions.first?.style, .cancel)
            // Merely requesting paste is not consent to unsafe input. Do not invoke Paste.
            try await drainInput(terminalSession)
            XCTAssertTrue(recorder.data.isEmpty, "Unconfirmed paste must not write partial input")
            XCTAssertEqual(target.ctrlActivation, .inactive)
        }
    }

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
    func testSoftwareKeyboardTextUsesDirectVTInputRoute() async {
        let terminalView = ShortcutAwareTerminalView(frame: .zero)
        let recorder = ByteRecorder()
        let terminalSession = VTTerminalSession(
            write: { data in recorder.append(data) },
            resize: { _ in }
        )
        terminalView.configuration = TerminalSurfaceOptions(backend: .vt(terminalSession))
        defer { terminalSession.finish() }

        terminalView.insertText("ls")

        _ = try? await terminalSession.enqueueSelectedText()?.value
        XCTAssertEqual(recorder.data, Data("ls".utf8))
    }

    @MainActor
    func testKeyboardBarControlModifiesNextSoftwareKeyboardCharacter() async throws {
        let recorder = ByteRecorder()
        let terminalSession = VTTerminalSession(
            write: { data in recorder.append(data) },
            resize: { _ in }
        )
        defer { terminalSession.finish() }
        let mounted = try mountVTTerminal(session: terminalSession)
        defer { unmountTerminal(mounted) }
        let terminalView = mounted.terminal
        let keyboardBarTarget = TerminalKeyboardBarTarget()
        keyboardBarTarget.attach(terminalView)
        defer { keyboardBarTarget.detach(terminalView) }

        keyboardBarTarget.perform(.ctrl)
        XCTAssertEqual(keyboardBarTarget.ctrlActivation, .armed)

        terminalView.insertText("c")
        terminalView.insertText("d")

        try await drainInput(terminalSession)
        XCTAssertEqual(
            Array(recorder.data),
            [0x03, UInt8(ascii: "d")],
            "Armed Control must modify exactly one software-keyboard character"
        )
        XCTAssertEqual(keyboardBarTarget.ctrlActivation, .inactive)
    }

    @MainActor
    func testKeyboardBarControlModifiesPlainMarkedTextCharacter() async throws {
        let recorder = ByteRecorder()
        let terminalSession = VTTerminalSession(
            write: { data in recorder.append(data) },
            resize: { _ in }
        )
        defer { terminalSession.finish() }
        let mounted = try mountVTTerminal(session: terminalSession)
        defer { unmountTerminal(mounted) }
        let terminalView = mounted.terminal
        let keyboardBarTarget = TerminalKeyboardBarTarget()
        keyboardBarTarget.attach(terminalView)
        defer { keyboardBarTarget.detach(terminalView) }

        keyboardBarTarget.perform(.ctrl)
        terminalView.setMarkedText("d", selectedRange: NSRange(location: 1, length: 0))

        try await drainInput(terminalSession)
        XCTAssertEqual(Array(recorder.data), [0x04])
        XCTAssertEqual(keyboardBarTarget.ctrlActivation, .inactive)
    }

    @MainActor
    func testKeyboardBarAltAndCommandAreConsumedBySoftwareKeyboardText() throws {
        let terminalSession = VTTerminalSession(write: { _ in }, resize: { _ in })
        defer { terminalSession.finish() }
        let mounted = try mountVTTerminal(session: terminalSession)
        defer { unmountTerminal(mounted) }
        let terminalView = mounted.terminal
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
    func testLockedKeyboardBarControlModifiesEverySoftwareKeyboardCharacter() async throws {
        let recorder = ByteRecorder()
        let terminalSession = VTTerminalSession(
            write: { data in recorder.append(data) },
            resize: { _ in }
        )
        defer { terminalSession.finish() }
        let mounted = try mountVTTerminal(session: terminalSession)
        defer { unmountTerminal(mounted) }
        let terminalView = mounted.terminal
        let keyboardBarTarget = TerminalKeyboardBarTarget()
        keyboardBarTarget.attach(terminalView)
        defer { keyboardBarTarget.detach(terminalView) }

        keyboardBarTarget.perform(.ctrl)
        keyboardBarTarget.perform(.ctrl)
        XCTAssertEqual(keyboardBarTarget.ctrlActivation, .locked)

        terminalView.insertText("c")
        terminalView.insertText("d")

        try await drainInput(terminalSession)
        XCTAssertEqual(Array(recorder.data), [0x03, 0x04])
        XCTAssertEqual(keyboardBarTarget.ctrlActivation, .locked)
    }

    @MainActor
    func testStickyModifierSkipsDirectSoftwareReturnHandler() throws {
        let terminalSession = VTTerminalSession(write: { _ in }, resize: { _ in })
        defer { terminalSession.finish() }
        let mounted = try mountVTTerminal(session: terminalSession)
        defer { unmountTerminal(mounted) }
        let terminalView = mounted.terminal
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
        let recorder = ByteRecorder()
        let inputReceived = expectation(description: "Control-C reaches the host session")
        let terminalSession = VTTerminalSession(
            write: { data in
                recorder.append(data)
                inputReceived.fulfill()
            },
            resize: { _ in }
        )
        terminalView.configuration = TerminalSurfaceOptions(backend: .vt(terminalSession))
        defer { terminalSession.finish() }
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
        terminalView.handleKeyPress(key, action: .press)
        terminalView.handleKeyPress(key, action: .release)
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
    private func mountVTTerminal(session: VTTerminalSession) throws -> MountedShortcutTerminal {
        let terminal = ShortcutAwareTerminalView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 600)
        )
        let mounted = try mountTerminal(terminal)
        terminal.configuration = TerminalSurfaceOptions(backend: .vt(session))
        terminal.controller = TerminalController()
        do {
            _ = try XCTUnwrap(terminal.surface, "A mounted VT terminal must have an input surface")
        } catch {
            unmountTerminal(mounted)
            throw error
        }
        terminal.setTerminalSurfaceFocused(true)
        return mounted
    }

    // Exercises the existing custom UITextInput document, not installed-keyboard
    // candidate selection, which still requires physical Japanese IME coverage.
    @MainActor
    func testSingleASCIIPreeditStaysLocalThenJapaneseCommitIsSentExactlyOnce() async throws {
        let recorder = ByteRecorder()
        let session = VTTerminalSession(write: { recorder.append($0) }, resize: { _ in })
        defer { session.finish() }
        let mounted = try mountVTTerminal(session: session)
        defer { unmountTerminal(mounted) }
        let terminal = mounted.terminal

        terminal.setMarkedText("n", selectedRange: NSRange(location: 1, length: 0))
        let markedRange = try XCTUnwrap(terminal.markedTextRange)
        XCTAssertEqual(terminal.text(in: markedRange), "n")
        try await drainInput(session)
        XCTAssertTrue(recorder.data.isEmpty, "A single ASCII Romaji preedit must not reach SSH")

        terminal.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0))
        XCTAssertEqual(terminal.text(in: try XCTUnwrap(terminal.markedTextRange)), "にほん")
        try await drainInput(session)
        XCTAssertTrue(recorder.data.isEmpty, "Updated Japanese preedit must remain local")

        terminal.insertText("日本")
        terminal.unmarkText()
        terminal.unmarkText()
        try await drainInput(session)
        XCTAssertEqual(recorder.data, Data("日本".utf8))
        XCTAssertNil(terminal.markedTextRange)
        XCTAssertEqual(terminal.offset(from: terminal.beginningOfDocument, to: terminal.endOfDocument), 0)
    }

    @MainActor
    private func drainInput(_ session: VTTerminalSession) async throws {
        // Session admission is FIFO; this read completes after the preceding input writes.
        let operation = try XCTUnwrap(session.enqueueSelectedText())
        _ = try await operation.value
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
        let rootViewController = ShortcutPastePresenter()
        rootViewController.view.frame = terminal.frame
        rootViewController.view.addSubview(terminal)
        window.rootViewController = rootViewController
        window.frame = scene.coordinateSpace.bounds
        window.makeKeyAndVisible()
        rootViewController.view.layoutIfNeeded()

        return MountedShortcutTerminal(
            terminal: terminal,
            window: window,
            previousKeyWindow: previousKeyWindow,
            presenter: rootViewController
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
    let presenter: ShortcutPastePresenter
}

@MainActor
private final class ShortcutPastePresenter: UIViewController {
    var presentedAlert: UIAlertController?
    var onPresentation: (() -> Void)?

    override func present(
        _ viewControllerToPresent: UIViewController,
        animated flag: Bool,
        completion: (() -> Void)? = nil
    ) {
        // Observe the production confirmation request without implicitly accepting it
        // or introducing alert-animation timing into these input-policy tests.
        presentedAlert = viewControllerToPresent as? UIAlertController
        onPresentation?()
        completion?()
    }
}

