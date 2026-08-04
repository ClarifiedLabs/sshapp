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

        XCTAssertTrue(terminal.resignFirstResponderForApplicationAction())
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

    func testSuppressedResponderAcquisitionReloadsInputViewsAfterResponderTransition() async throws {
        let terminal = InputViewReloadTrackingTerminalView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 600)
        )
        let mounted = try mountTerminal(terminal)
        defer { unmountTerminal(mounted) }

        terminal.suppressesSoftwareKeyboard = true
        let reloadCountBeforeFocus = terminal.reloadInputViewsCallCount

        XCTAssertTrue(terminal.becomeFirstResponder())
        let reloadCountAfterFocus = terminal.reloadInputViewsCallCount
        XCTAssertEqual(reloadCountAfterFocus, reloadCountBeforeFocus)

        await drainMainQueue()

        XCTAssertEqual(terminal.reloadInputViewsCallCount, reloadCountAfterFocus + 1)
        XCTAssertTrue(terminal.isFirstResponder)
        XCTAssertTrue(terminal.suppressesSoftwareKeyboard)

        let reloadCountBeforeRedundantFocus = terminal.reloadInputViewsCallCount
        XCTAssertTrue(terminal.becomeFirstResponder())
        await drainMainQueue()
        XCTAssertEqual(
            terminal.reloadInputViewsCallCount,
            reloadCountBeforeRedundantFocus,
            "An already-focused suppressed terminal must not queue another input-view reload"
        )
    }

    func testDeferredSuppressedInputViewReloadCancelsWhenSuppressionIsRestored() async throws {
        let terminal = InputViewReloadTrackingTerminalView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 600)
        )
        let mounted = try mountTerminal(terminal)
        defer { unmountTerminal(mounted) }

        terminal.suppressesSoftwareKeyboard = true
        XCTAssertTrue(terminal.becomeFirstResponder())
        terminal.suppressesSoftwareKeyboard = false
        let reloadCountAfterRestore = terminal.reloadInputViewsCallCount

        await drainMainQueue()

        XCTAssertEqual(terminal.reloadInputViewsCallCount, reloadCountAfterRestore)
        XCTAssertFalse(terminal.suppressesSoftwareKeyboard)
    }

    func testDeferredSuppressedInputViewReloadCancelsWhenFocusResigns() async throws {
        let terminal = InputViewReloadTrackingTerminalView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 600)
        )
        let mounted = try mountTerminal(terminal)
        defer { unmountTerminal(mounted) }

        terminal.suppressesSoftwareKeyboard = true
        XCTAssertTrue(terminal.becomeFirstResponder())
        XCTAssertTrue(terminal.resignFirstResponderForApplicationAction())
        let reloadCountAfterResign = terminal.reloadInputViewsCallCount

        await drainMainQueue()

        XCTAssertEqual(terminal.reloadInputViewsCallCount, reloadCountAfterResign)
        XCTAssertFalse(terminal.isFirstResponder)
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

    /// Regression: tapping the terminal to dismiss the software keyboard
    /// leaves it resigned while the host bar stays visible. Entering
    /// suppression must reclaim terminal focus so a hardware keyboard keeps
    /// working.
    func testSuppressionReclaimsFocusAfterIntentionalTerminalKeyboardDismissal() throws {
        let mounted = try mountTerminal()
        defer { unmountTerminal(mounted) }

        let terminal = mounted.terminal
        let target = TerminalKeyboardBarTarget()
        target.attach(terminal)
        XCTAssertTrue(terminal.becomeFirstResponder())
        XCTAssertTrue(terminal.isFirstResponder)

        // Model the intentional dismissal: tap-to-dismiss resigns the
        // terminal while the host keyboard bar remains visible.
        XCTAssertTrue(terminal.resignFirstResponderForApplicationAction())
        XCTAssertFalse(terminal.isFirstResponder)

        target.suppressSoftwareKeyboard()

        XCTAssertTrue(terminal.suppressesSoftwareKeyboard)
        XCTAssertTrue(
            terminal.isFirstResponder,
            "suppression must reclaim terminal focus after an intentional dismissal"
        )
        XCTAssertTrue(terminal.canBecomeFirstResponder)
        target.detach(terminal)
    }

    func testSuppressedTerminalIgnoresStaleKeyboardShowNotification() throws {
        let mounted = try mountTerminal()
        defer { unmountTerminal(mounted) }

        let terminal = mounted.terminal
        XCTAssertTrue(terminal.becomeFirstResponder())
        terminal.suppressesSoftwareKeyboard = true

        terminal.keyboardDidShow(keyboardNotification(height: 300))

        XCTAssertFalse(terminal.softwareKeyboardVisible)
        XCTAssertNil(terminal.keyboardFrameEndScreenRect)
        XCTAssertFalse(terminal.ownsFullSoftwareKeyboardPresentation)
        XCTAssertEqual(terminal.terminalViewportBounds, terminal.bounds)
    }

    func testOwnedFullKeyboardHideEmitsSystemDismissAfterClearingLocalState() throws {
        let mounted = try mountTerminal()
        defer { unmountTerminal(mounted) }

        let terminal = mounted.terminal
        XCTAssertTrue(terminal.becomeFirstResponder())
        var callbackCount = 0
        terminal.onSystemSoftwareKeyboardDismiss = {
            callbackCount += 1
            XCTAssertFalse(terminal.softwareKeyboardVisible)
            XCTAssertNil(terminal.keyboardFrameEndScreenRect)
            XCTAssertFalse(terminal.ownsFullSoftwareKeyboardPresentation)
        }

        terminal.keyboardDidShow(keyboardNotification(height: 300))
        XCTAssertTrue(terminal.ownsFullSoftwareKeyboardPresentation)

        terminal.keyboardDidHide(keyboardNotification(
            name: UIResponder.keyboardDidHideNotification,
            height: 0
        ))
        terminal.keyboardDidHide(keyboardNotification(
            name: UIResponder.keyboardDidHideNotification,
            height: 0
        ))

        XCTAssertEqual(callbackCount, 1, "owned presentation must be consumed exactly once")
    }

    func testKeyboardHideWithoutOwnedShowDoesNotEmitSystemDismiss() throws {
        let mounted = try mountTerminal()
        defer { unmountTerminal(mounted) }

        let terminal = mounted.terminal
        XCTAssertTrue(terminal.becomeFirstResponder())
        var callbackCount = 0
        terminal.onSystemSoftwareKeyboardDismiss = { callbackCount += 1 }

        terminal.keyboardDidHide(keyboardNotification(
            name: UIResponder.keyboardDidHideNotification,
            height: 0
        ))

        XCTAssertEqual(callbackCount, 0)
    }

    func testBareResignBeforeKeyboardHideDefersSystemDismissAndReclaimsFocus() async throws {
        let mounted = try mountTerminal()
        defer { unmountTerminal(mounted) }

        let terminal = mounted.terminal
        disableAutomaticKeyboardNotifications(for: terminal)
        let target = TerminalKeyboardBarTarget()
        target.attach(terminal)
        XCTAssertTrue(terminal.becomeFirstResponder())
        var callbackCount = 0
        let dismiss = expectation(description: "deferred bare-resign dismissal")
        terminal.onSystemSoftwareKeyboardDismiss = {
            callbackCount += 1
            XCTAssertFalse(terminal.softwareKeyboardVisible)
            XCTAssertNil(terminal.keyboardFrameEndScreenRect)
            XCTAssertFalse(terminal.ownsFullSoftwareKeyboardPresentation)
            target.suppressSoftwareKeyboard()
            dismiss.fulfill()
        }
        terminal.keyboardDidShow(keyboardNotification(height: 300))
        XCTAssertTrue(terminal.ownsFullSoftwareKeyboardPresentation)

        XCTAssertTrue(terminal.resignFirstResponder())
        XCTAssertEqual(terminal.softwareKeyboardDismissState, .systemResignPending)
        terminal.keyboardDidHide(keyboardNotification(
            name: UIResponder.keyboardDidHideNotification,
            height: 0
        ))
        terminal.keyboardDidHide(keyboardNotification(
            name: UIResponder.keyboardDidHideNotification,
            height: 0
        ))

        XCTAssertEqual(callbackCount, 0)
        XCTAssertFalse(terminal.suppressesSoftwareKeyboard)
        XCTAssertFalse(terminal.isFirstResponder)
        await fulfillment(of: [dismiss], timeout: 1)
        XCTAssertEqual(callbackCount, 1)
        XCTAssertTrue(terminal.suppressesSoftwareKeyboard)
        XCTAssertTrue(terminal.isFirstResponder)
        target.detach(terminal)
    }

    func testSynchronousHideDuringResponderResignDefersDismissAndAllowsLateAppIntent() async throws {
        let terminal = SynchronousKeyboardHideTerminalView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 600)
        )
        let mounted = try mountTerminal(terminal)
        defer { unmountTerminal(mounted) }

        disableAutomaticKeyboardNotifications(for: terminal)
        XCTAssertTrue(terminal.becomeFirstResponder())
        var callbackCount = 0
        let firstDismiss = expectation(description: "system dismissal callback")
        terminal.onSystemSoftwareKeyboardDismiss = {
            callbackCount += 1
            firstDismiss.fulfill()
        }
        terminal.keyboardDidShow(keyboardNotification(height: 300))
        terminal.sendsKeyboardHideWhenResigning = true

        XCTAssertTrue(terminal.resignFirstResponder())
        XCTAssertTrue(terminal.didSendKeyboardHideWhileCheckingCanResign)
        XCTAssertEqual(callbackCount, 0, "synchronous hide must defer until resignation completes")
        await fulfillment(of: [firstDismiss], timeout: 1)
        XCTAssertEqual(callbackCount, 1)

        XCTAssertTrue(terminal.becomeFirstResponder())
        terminal.keyboardDidShow(keyboardNotification(height: 300))
        terminal.sendsKeyboardHideWhenResigning = true
        terminal.onSystemSoftwareKeyboardDismiss = { callbackCount += 1 }

        XCTAssertTrue(terminal.resignFirstResponder())
        XCTAssertFalse(terminal.resignFirstResponderForApplicationAction())
        let nextMainTurn = expectation(description: "deferred dismissal cancellation")
        DispatchQueue.main.async { nextMainTurn.fulfill() }
        await fulfillment(of: [nextMainTurn], timeout: 1)

        XCTAssertEqual(callbackCount, 1, "late app intent must cancel the deferred system callback")
    }

    func testApplicationResignBeforeKeyboardHideDoesNotEmitSystemDismiss() throws {
        let mounted = try mountTerminal()
        defer { unmountTerminal(mounted) }

        let terminal = mounted.terminal
        disableAutomaticKeyboardNotifications(for: terminal)
        XCTAssertTrue(terminal.becomeFirstResponder())
        var callbackCount = 0
        terminal.onSystemSoftwareKeyboardDismiss = { callbackCount += 1 }
        terminal.keyboardDidShow(keyboardNotification(height: 300))

        XCTAssertTrue(terminal.resignFirstResponderForApplicationAction())
        XCTAssertEqual(terminal.softwareKeyboardDismissState, .applicationResignPending)
        terminal.keyboardDidHide(keyboardNotification(
            name: UIResponder.keyboardDidHideNotification,
            height: 0
        ))

        XCTAssertEqual(callbackCount, 0)
        XCTAssertEqual(terminal.softwareKeyboardDismissState, .idle)
    }

    func testLateApplicationIntentReclassifiesPendingSystemResign() throws {
        let mounted = try mountTerminal()
        defer { unmountTerminal(mounted) }

        let terminal = mounted.terminal
        disableAutomaticKeyboardNotifications(for: terminal)
        XCTAssertTrue(terminal.becomeFirstResponder())
        var callbackCount = 0
        terminal.onSystemSoftwareKeyboardDismiss = { callbackCount += 1 }
        terminal.keyboardDidShow(keyboardNotification(height: 300))

        XCTAssertTrue(terminal.resignFirstResponder())
        XCTAssertEqual(terminal.softwareKeyboardDismissState, .systemResignPending)
        XCTAssertFalse(terminal.resignFirstResponderForApplicationAction())
        XCTAssertEqual(terminal.softwareKeyboardDismissState, .applicationResignPending)
        terminal.keyboardDidHide(keyboardNotification(
            name: UIResponder.keyboardDidHideNotification,
            height: 0
        ))

        XCTAssertEqual(callbackCount, 0)
    }

    func testDeferredSystemDismissIsCancelledByNonSystemBoundaries() async throws {
        let terminal = SynchronousKeyboardHideTerminalView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 600)
        )
        let mounted = try mountTerminal(terminal)
        defer { unmountTerminal(mounted) }

        disableAutomaticKeyboardNotifications(for: terminal)
        var callbackCount = 0
        terminal.onSystemSoftwareKeyboardDismiss = { callbackCount += 1 }

        func prepareDeferredSystemDismiss() {
            terminal.suppressesSoftwareKeyboard = false
            XCTAssertTrue(terminal.becomeFirstResponder())
            terminal.keyboardDidShow(keyboardNotification(height: 300))
            terminal.sendsKeyboardHideWhenResigning = true
            XCTAssertTrue(terminal.resignFirstResponder())
            XCTAssertNotNil(terminal.deferredSystemSoftwareKeyboardDismissID)
        }

        prepareDeferredSystemDismiss()
        terminal.suppressesSoftwareKeyboard = true
        XCTAssertNil(terminal.deferredSystemSoftwareKeyboardDismissID)
        await drainMainQueue()
        XCTAssertEqual(callbackCount, 0)

        prepareDeferredSystemDismiss()
        terminal.usesSystemInputAccessory.toggle()
        XCTAssertNil(terminal.deferredSystemSoftwareKeyboardDismissID)
        await drainMainQueue()
        XCTAssertEqual(callbackCount, 0)

        prepareDeferredSystemDismiss()
        terminal.sceneWillDeactivate(Notification(
            name: UIScene.willDeactivateNotification,
            object: mounted.window.windowScene
        ))
        XCTAssertNil(terminal.deferredSystemSoftwareKeyboardDismissID)
        await drainMainQueue()
        XCTAssertEqual(callbackCount, 0)

        prepareDeferredSystemDismiss()
        terminal.applicationWillResignActive(Notification(
            name: UIApplication.willResignActiveNotification
        ))
        XCTAssertNil(terminal.deferredSystemSoftwareKeyboardDismissID)
        await drainMainQueue()
        XCTAssertEqual(callbackCount, 0)

        prepareDeferredSystemDismiss()
        XCTAssertTrue(terminal.becomeFirstResponder())
        terminal.keyboardDidShow(keyboardNotification(height: 300))
        XCTAssertNil(terminal.deferredSystemSoftwareKeyboardDismissID)
        await drainMainQueue()
        XCTAssertEqual(callbackCount, 0)
        XCTAssertTrue(terminal.resignFirstResponderForApplicationAction())
        terminal.keyboardDidHide(keyboardNotification(
            name: UIResponder.keyboardDidHideNotification,
            height: 0
        ))

        prepareDeferredSystemDismiss()
        terminal.removeFromSuperview()
        XCTAssertNil(terminal.deferredSystemSoftwareKeyboardDismissID)
        await drainMainQueue()
        XCTAssertEqual(callbackCount, 0)
    }

    func testShortKeyboardAccessoryPresentationDoesNotEmitSystemDismiss() throws {
        let mounted = try mountTerminal()
        defer { unmountTerminal(mounted) }

        let terminal = mounted.terminal
        XCTAssertTrue(terminal.becomeFirstResponder())
        var callbackCount = 0
        terminal.onSystemSoftwareKeyboardDismiss = { callbackCount += 1 }

        terminal.keyboardDidShow(keyboardNotification(height: 80))
        XCTAssertFalse(terminal.ownsFullSoftwareKeyboardPresentation)
        terminal.keyboardDidHide(keyboardNotification(
            name: UIResponder.keyboardDidHideNotification,
            height: 0
        ))

        XCTAssertEqual(callbackCount, 0)
    }

    func testInputAccessoryReloadsInvalidateOwnedPresentationBeforeStaleHide() throws {
        let mounted = try mountTerminal()
        defer { unmountTerminal(mounted) }

        let terminal = mounted.terminal
        XCTAssertTrue(terminal.becomeFirstResponder())
        var callbackCount = 0
        terminal.onSystemSoftwareKeyboardDismiss = { callbackCount += 1 }

        terminal.keyboardDidShow(keyboardNotification(height: 300))
        XCTAssertTrue(terminal.ownsFullSoftwareKeyboardPresentation)
        terminal.usesSystemInputAccessory = false
        XCTAssertFalse(terminal.ownsFullSoftwareKeyboardPresentation)

        terminal.keyboardDidShow(keyboardNotification(height: 300))
        XCTAssertTrue(terminal.ownsFullSoftwareKeyboardPresentation)
        terminal.inputAccessoryItems = []
        XCTAssertFalse(terminal.ownsFullSoftwareKeyboardPresentation)

        terminal.keyboardDidHide(keyboardNotification(
            name: UIResponder.keyboardDidHideNotification,
            height: 0
        ))
        XCTAssertEqual(callbackCount, 0)
    }

    func testPendingSystemResignIsCancelledByNonSystemBoundaries() throws {
        let mounted = try mountTerminal()
        defer { unmountTerminal(mounted) }

        let terminal = mounted.terminal
        disableAutomaticKeyboardNotifications(for: terminal)
        var callbackCount = 0
        terminal.onSystemSoftwareKeyboardDismiss = { callbackCount += 1 }

        func preparePendingSystemResign() {
            terminal.suppressesSoftwareKeyboard = false
            XCTAssertTrue(terminal.becomeFirstResponder())
            terminal.keyboardDidShow(keyboardNotification(height: 300))
            XCTAssertTrue(terminal.resignFirstResponder())
            XCTAssertEqual(terminal.softwareKeyboardDismissState, .systemResignPending)
        }

        func deliverHide() {
            terminal.keyboardDidHide(keyboardNotification(
                name: UIResponder.keyboardDidHideNotification,
                height: 0
            ))
            XCTAssertEqual(callbackCount, 0)
        }

        preparePendingSystemResign()
        terminal.suppressesSoftwareKeyboard = true
        XCTAssertEqual(terminal.softwareKeyboardDismissState, .idle)
        deliverHide()

        preparePendingSystemResign()
        terminal.usesSystemInputAccessory.toggle()
        XCTAssertEqual(terminal.softwareKeyboardDismissState, .idle)
        deliverHide()

        preparePendingSystemResign()
        terminal.sceneWillDeactivate(Notification(
            name: UIScene.willDeactivateNotification,
            object: mounted.window.windowScene
        ))
        XCTAssertEqual(terminal.softwareKeyboardDismissState, .idle)
        deliverHide()

        preparePendingSystemResign()
        terminal.applicationWillResignActive(Notification(name: UIApplication.willResignActiveNotification))
        XCTAssertEqual(terminal.softwareKeyboardDismissState, .idle)
        deliverHide()

        preparePendingSystemResign()
        terminal.removeFromSuperview()
        XCTAssertEqual(terminal.softwareKeyboardDismissState, .idle)
        deliverHide()
    }

    func testSuppressionReloadInvalidatesOwnedPresentationBeforeStaleHide() throws {
        let mounted = try mountTerminal()
        defer { unmountTerminal(mounted) }

        let terminal = mounted.terminal
        XCTAssertTrue(terminal.becomeFirstResponder())
        var callbackCount = 0
        terminal.onSystemSoftwareKeyboardDismiss = { callbackCount += 1 }
        terminal.keyboardDidShow(keyboardNotification(height: 300))
        XCTAssertTrue(terminal.ownsFullSoftwareKeyboardPresentation)

        terminal.suppressesSoftwareKeyboard = true
        XCTAssertFalse(terminal.ownsFullSoftwareKeyboardPresentation)
        terminal.keyboardDidHide(keyboardNotification(
            name: UIResponder.keyboardDidHideNotification,
            height: 0
        ))

        XCTAssertEqual(callbackCount, 0)
        XCTAssertTrue(terminal.suppressesSoftwareKeyboard)
        XCTAssertTrue(terminal.isFirstResponder)
    }

    private func drainMainQueue() async {
        let nextMainTurn = expectation(description: "next main queue turn")
        DispatchQueue.main.async { nextMainTurn.fulfill() }
        await fulfillment(of: [nextMainTurn], timeout: 1)
    }

    private func disableAutomaticKeyboardNotifications(for terminal: UITerminalView) {
        NotificationCenter.default.removeObserver(
            terminal,
            name: UIResponder.keyboardDidShowNotification,
            object: nil
        )
        NotificationCenter.default.removeObserver(
            terminal,
            name: UIResponder.keyboardDidHideNotification,
            object: nil
        )
    }

    private func keyboardNotification(
        name: Notification.Name = UIResponder.keyboardDidShowNotification,
        height: CGFloat
    ) -> Notification {
        Notification(
            name: name,
            object: nil,
            userInfo: [
                UIResponder.keyboardFrameEndUserInfoKey: CGRect(
                    x: 0,
                    y: 300,
                    width: 390,
                    height: height
                )
            ]
        )
    }

    private func mountTerminal(
        _ terminal: UITerminalView = UITerminalView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 600)
        )
    ) throws -> MountedTerminal {
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

        return MountedTerminal(
            terminal: terminal,
            window: window,
            previousKeyWindow: previousKeyWindow
        )
    }

    private func unmountTerminal(_ mounted: MountedTerminal) {
        _ = mounted.terminal.resignFirstResponderForApplicationAction()
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

@MainActor
private final class InputViewReloadTrackingTerminalView: UITerminalView {
    private(set) var reloadInputViewsCallCount = 0

    override func reloadInputViews() {
        reloadInputViewsCallCount += 1
        super.reloadInputViews()
    }
}

@MainActor
private final class SynchronousKeyboardHideTerminalView: UITerminalView {
    var sendsKeyboardHideWhenResigning = false
    private(set) var didSendKeyboardHideWhileCheckingCanResign = false

    override var canResignFirstResponder: Bool {
        if sendsKeyboardHideWhenResigning {
            sendsKeyboardHideWhenResigning = false
            didSendKeyboardHideWhileCheckingCanResign = true
            keyboardDidHide(Notification(name: UIResponder.keyboardDidHideNotification))
        }
        return super.canResignFirstResponder
    }
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
