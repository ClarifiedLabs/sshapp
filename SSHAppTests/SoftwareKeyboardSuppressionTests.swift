import UIKit
import XCTest
@testable import GhosttyTerminal
@testable import SSHApp

@MainActor
final class SoftwareKeyboardSuppressionTests: XCTestCase {
    func testSuppressionReplacesInputViewWithoutResigningTerminal() throws {
        let mounted = try mountTerminal()
        defer { unmountTerminal(mounted) }

        let terminal = mounted.terminal
        XCTAssertTrue(terminal.becomeFirstResponder())
        XCTAssertTrue(terminal.isFirstResponder)
        XCTAssertNil(terminal.inputView)

        terminal.suppressesSoftwareKeyboard = true

        let suppressedInputView = try XCTUnwrap(terminal.inputView)
        XCTAssertTrue(terminal.isFirstResponder)
        XCTAssertTrue(terminal.canBecomeFirstResponder)
        XCTAssertEqual(suppressedInputView.bounds.height, 0)
        XCTAssertFalse(suppressedInputView.isUserInteractionEnabled)

        terminal.suppressesSoftwareKeyboard = true
        XCTAssertTrue(terminal.inputView === suppressedInputView)
        XCTAssertTrue(terminal.isFirstResponder)

        XCTAssertTrue(terminal.resignFirstResponder())
        terminal.showSelectionCopyMenu(at: CGPoint(x: 8, y: 8))
        XCTAssertTrue(terminal.isFirstResponder)
        XCTAssertTrue(terminal.inputView === suppressedInputView)

        terminal.suppressesSoftwareKeyboard = false
        XCTAssertTrue(terminal.isFirstResponder)
        XCTAssertNil(terminal.inputView)
    }

    func testSuppressionClearsCompositionModifiersAndPendingDismissal() throws {
        let mounted = try mountTerminal()
        defer { unmountTerminal(mounted) }

        let terminal = mounted.terminal
        XCTAssertTrue(terminal.becomeFirstResponder())
        terminal.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0))
        terminal.toggleStickyModifier(.ctrl)
        terminal.pendingKeyboardDismissOnTouchEnd = true
        terminal.touchDidScrollDuringCurrentTouch = true
        terminal.softwareKeyboardVisible = true
        terminal.keyboardFrameEndScreenRect = CGRect(x: 0, y: 300, width: 390, height: 300)

        terminal.suppressesSoftwareKeyboard = true

        XCTAssertNil(terminal.markedTextRange)
        XCTAssertFalse(terminal.hasActiveStickyModifiers)
        XCTAssertFalse(terminal.pendingKeyboardDismissOnTouchEnd)
        XCTAssertFalse(terminal.touchDidScrollDuringCurrentTouch)
        XCTAssertFalse(terminal.softwareKeyboardVisible)
        XCTAssertNil(terminal.keyboardFrameEndScreenRect)
        XCTAssertTrue(terminal.isFirstResponder)

        terminal.pendingKeyboardDismissOnTouchEnd = true
        terminal.touchesEnded([], with: nil)
        XCTAssertTrue(terminal.isFirstResponder)
    }

    func testSuppressionPreservesInMemoryTextInputRouting() {
        let terminal = ShortcutAwareTerminalView(frame: .zero)
        let recorder = SuppressionInputRecorder()
        let session = InMemoryTerminalSession(
            write: { recorder.append($0) },
            resize: { _ in }
        )
        terminal.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        terminal.suppressesSoftwareKeyboard = true

        terminal.insertText("ls")

        XCTAssertEqual(recorder.data, Data("ls".utf8))
        XCTAssertTrue(terminal.canBecomeFirstResponder)
    }

    func testKeyboardBarTargetRestoresAndFocusesAttachedTerminal() throws {
        let mounted = try mountTerminal()
        defer { unmountTerminal(mounted) }

        let terminal = mounted.terminal
        let target = TerminalKeyboardBarTarget()
        target.attach(terminal)
        target.suppressSoftwareKeyboard()
        XCTAssertTrue(terminal.suppressesSoftwareKeyboard)

        target.restoreSoftwareKeyboard()

        XCTAssertFalse(terminal.suppressesSoftwareKeyboard)
        XCTAssertTrue(terminal.isFirstResponder)
        target.detach(terminal)
    }

    func testSuppressedTerminalIgnoresStaleKeyboardShowNotification() throws {
        let mounted = try mountTerminal()
        defer { unmountTerminal(mounted) }

        let terminal = mounted.terminal
        XCTAssertTrue(terminal.becomeFirstResponder())
        terminal.suppressesSoftwareKeyboard = true

        terminal.keyboardDidShow(
            Notification(
                name: UIResponder.keyboardDidShowNotification,
                object: nil,
                userInfo: [
                    UIResponder.keyboardFrameEndUserInfoKey: CGRect(
                        x: 0,
                        y: 300,
                        width: 390,
                        height: 300
                    )
                ]
            )
        )

        XCTAssertFalse(terminal.softwareKeyboardVisible)
        XCTAssertNil(terminal.keyboardFrameEndScreenRect)
        XCTAssertEqual(terminal.terminalViewportBounds, terminal.bounds)
    }

    private func mountTerminal() throws -> MountedTerminal {
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
        let terminal = UITerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        rootViewController.view.frame = terminal.frame
        rootViewController.view.addSubview(terminal)
        window.rootViewController = rootViewController
        window.frame = scene.coordinateSpace.bounds
        window.makeKeyAndVisible()
        rootViewController.view.layoutIfNeeded()

        return MountedTerminal(
            terminal: terminal,
            window: window,
            previousKeyWindow: previousKeyWindow
        )
    }

    private func unmountTerminal(_ mounted: MountedTerminal) {
        _ = mounted.terminal.resignFirstResponder()
        mounted.window.isHidden = true
        mounted.previousKeyWindow?.makeKey()
    }
}

@MainActor
private struct MountedTerminal {
    let terminal: UITerminalView
    let window: UIWindow
    let previousKeyWindow: UIWindow?
}

private final class SuppressionInputRecorder: @unchecked Sendable {
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
