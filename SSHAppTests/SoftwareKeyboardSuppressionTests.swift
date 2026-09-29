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

    /// Regression: iPadOS 26+ kept a minimized shortcut-bar pill over the
    /// suppressed terminal's Show Keyboard control. Suppression must empty the
    /// shortcut groups and restore the originals (by identity) on unsuppress.
    func testSuppressionEmptiesInputAssistantShortcutsAndRestoresThem() throws {
        let terminal = InputViewReloadTrackingTerminalView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 600)
        )
        let mounted = try mountTerminal(terminal)
        defer { unmountTerminal(mounted) }
        XCTAssertTrue(terminal.becomeFirstResponder())

        let leading = UIBarButtonItemGroup(
            barButtonItems: [UIBarButtonItem(title: "L", style: .plain, target: nil, action: nil)],
            representativeItem: nil
        )
        let trailing = UIBarButtonItemGroup(
            barButtonItems: [UIBarButtonItem(title: "T", style: .plain, target: nil, action: nil)],
            representativeItem: nil
        )
        let item = terminal.inputAssistantItem
        item.leadingBarButtonGroups = [leading]
        item.trailingBarButtonGroups = [trailing]

        var groupsAtReload: [(leading: Int, trailing: Int)] = []
        terminal.onReloadInputViews = { view in
            groupsAtReload.append((
                view.inputAssistantItem.leadingBarButtonGroups.count,
                view.inputAssistantItem.trailingBarButtonGroups.count
            ))
        }
        defer { terminal.onReloadInputViews = nil }

        terminal.suppressesSoftwareKeyboard = true
        XCTAssertTrue(item.leadingBarButtonGroups.isEmpty)
        XCTAssertTrue(item.trailingBarButtonGroups.isEmpty)
        XCTAssertFalse(groupsAtReload.isEmpty, "Suppression must reload input views")
        XCTAssertTrue(
            groupsAtReload.allSatisfy { $0.leading == 0 && $0.trailing == 0 },
            "Shortcuts must already be empty when UIKit reloads the suppressed input views"
        )

        // Re-asserting suppression must not overwrite the saved originals.
        terminal.suppressesSoftwareKeyboard = true
        XCTAssertTrue(item.leadingBarButtonGroups.isEmpty)

        groupsAtReload.removeAll()
        terminal.suppressesSoftwareKeyboard = false
        XCTAssertEqual(item.leadingBarButtonGroups.count, 1)
        XCTAssertEqual(item.trailingBarButtonGroups.count, 1)
        XCTAssertTrue(item.leadingBarButtonGroups.first === leading)
        XCTAssertTrue(item.trailingBarButtonGroups.first === trailing)
        XCTAssertTrue(
            groupsAtReload.allSatisfy { $0.leading == 1 && $0.trailing == 1 },
            "Unsuppressing must restore the shortcuts before reloading input views"
        )
        XCTAssertNil(terminal.inputView)
        XCTAssertTrue(terminal.isFirstResponder)
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

    /// Uses the custom UITextInput and production bar target. The reload callback
    /// models UIKit's unmark timing; physical Japanese IME remains device coverage.
    func testKeyboardBarHideCancelsPreeditBeforeReloadWithoutSendingBytes() async throws {
        let recorder = SuppressionInputRecorder()
        let session = VTTerminalSession(write: { recorder.append($0) }, resize: { _ in })
        defer { session.finish() }
        let terminal = InputViewReloadTrackingTerminalView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 600)
        )
        let mounted = try mountTerminal(terminal)
        defer { unmountTerminal(mounted) }
        terminal.configuration = TerminalSurfaceOptions(backend: .vt(session))
        terminal.controller = TerminalController()
        let surface = try XCTUnwrap(terminal.surface)
        terminal.setTerminalSurfaceFocused(true)
        XCTAssertTrue(terminal.becomeFirstResponder())
        let target = TerminalKeyboardBarTarget()
        target.attach(terminal)
        defer { target.detach(terminal) }

        func drainInput() async throws {
            // FIFO query completes only after all preceding input writes.
            let operation = try XCTUnwrap(session.enqueueSelectedText())
            _ = try await operation.value
        }

        terminal.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0))
        try await drainInput()
        XCTAssertTrue(recorder.data.isEmpty)
        terminal.insertText("日本")
        terminal.unmarkText()
        try await drainInput()
        XCTAssertEqual(recorder.data, Data("日本".utf8), "Candidate commit is sent exactly once")

        terminal.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertEqual(terminal.text(in: try XCTUnwrap(terminal.markedTextRange)), "に")
        XCTAssertEqual(surface.contentView.markedText, "に")
        try await drainInput()
        XCTAssertEqual(recorder.data, Data("日本".utf8), "Preedit stays local")

        terminal.onReloadInputViews = { view in
            XCTAssertNil(view.markedTextRange, "Cancel must precede UIKit's reload callback")
            XCTAssertEqual(surface.contentView.markedText, "")
            view.unmarkText()
        }
        defer { terminal.onReloadInputViews = nil }
        let reloadCount = terminal.reloadInputViewsCallCount
        target.suppressSoftwareKeyboard()
        XCTAssertGreaterThan(terminal.reloadInputViewsCallCount, reloadCount)
        XCTAssertTrue(terminal.suppressesSoftwareKeyboard)
        XCTAssertTrue(terminal.isFirstResponder)
        XCTAssertNil(terminal.markedTextRange)
        XCTAssertEqual(terminal.offset(from: terminal.beginningOfDocument, to: terminal.endOfDocument), 0)
        terminal.unmarkText() // A delayed callback must not resurrect the cancelled preedit.
        await drainMainQueue()
        try await drainInput()
        XCTAssertEqual(recorder.data, Data("日本".utf8), "Hide must not append the cancelled に")

        terminal.onReloadInputViews = nil
        target.restoreSoftwareKeyboard()
        terminal.setMarkedText("漢", selectedRange: NSRange(location: 1, length: 0))
        terminal.unmarkText()
        terminal.unmarkText()
        try await drainInput()
        XCTAssertEqual(recorder.data, Data("日本漢".utf8), "Ordinary unmark still commits exactly once")
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

    func testSuppressionPreservesVTTextInputRouting() async {
        let terminal = ShortcutAwareTerminalView(frame: .zero)
        let recorder = SuppressionInputRecorder()
        let session = VTTerminalSession(
            write: { recorder.append($0) },
            resize: { _ in }
        )
        terminal.configuration = TerminalSurfaceOptions(backend: .vt(session))
        terminal.suppressesSoftwareKeyboard = true

        terminal.insertText("ls")

        _ = try? await session.enqueueSelectedText()?.value
        session.finish()
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

    func testFullKeyboardCollapseToAssistantEmitsSystemDismissOnce() throws {
        let mounted = try mountTerminal()
        defer { unmountTerminal(mounted) }
        let terminal = mounted.terminal
        disableAutomaticKeyboardNotifications(for: terminal)
        XCTAssertTrue(terminal.becomeFirstResponder())
        var callbackCount = 0
        terminal.onSystemSoftwareKeyboardDismiss = { callbackCount += 1 }

        terminal.keyboardDidShow(keyboardNotification(height: 498))
        XCTAssertTrue(terminal.ownsFullSoftwareKeyboardPresentation)
        terminal.keyboardDidShow(keyboardNotification(height: 68.5))
        XCTAssertEqual(callbackCount, 1)
        XCTAssertFalse(terminal.ownsFullSoftwareKeyboardPresentation)
        terminal.keyboardDidHide(keyboardNotification(
            name: UIResponder.keyboardDidHideNotification,
            height: 0
        ))
        XCTAssertEqual(callbackCount, 1)
    }

    /// Regression: on a 13-inch iPad the unsafe-paste confirmation collapsed the
    /// full keyboard to the minimized assistant. That was classified as a native
    /// user dismissal, leaving the terminal suppressed behind a Show Keyboard
    /// control that the iPadOS keyboard pill overlapped.
    func testOwnedAlertKeyboardTransitionsDoNotEnterSuppression() async throws {
        let mounted = try mountTerminal()
        defer { unmountTerminal(mounted) }
        let terminal = mounted.terminal
        disableAutomaticKeyboardNotifications(for: terminal)
        XCTAssertTrue(terminal.becomeFirstResponder())
        var callbackCount = 0
        terminal.onSystemSoftwareKeyboardDismiss = { callbackCount += 1 }
        terminal.keyboardDidShow(keyboardNotification(height: 498))
        XCTAssertTrue(terminal.ownsFullSoftwareKeyboardPresentation)

        let alert = UIAlertController(title: "Paste potentially unsafe text?", message: nil, preferredStyle: .alert)
        let presenter = try XCTUnwrap(mounted.window.rootViewController)
        terminal.presentOwnedAlert(alert, from: presenter)
        XCTAssertTrue(terminal.isPresentingOwnedAlert)
        XCTAssertFalse(terminal.ownsFullSoftwareKeyboardPresentation)

        // iPadOS collapses the keyboard to the minimized assistant, may briefly
        // re-show it, and may resign the terminal while the alert is up.
        terminal.keyboardDidShow(keyboardNotification(height: 68.5))
        terminal.keyboardDidShow(keyboardNotification(height: 498))
        XCTAssertFalse(terminal.ownsFullSoftwareKeyboardPresentation)
        terminal.keyboardDidShow(keyboardNotification(height: 68.5))
        XCTAssertTrue(terminal.resignFirstResponder())
        terminal.keyboardDidHide(keyboardNotification(
            name: UIResponder.keyboardDidHideNotification,
            height: 0
        ))
        await drainMainQueue()
        XCTAssertEqual(callbackCount, 0, "an app-owned alert is not a user keyboard dismissal")
        XCTAssertFalse(terminal.suppressesSoftwareKeyboard)

        try await dismissPresentedAlert(alert, from: presenter)
        terminal.ownedAlertDidDismiss()
        XCTAssertFalse(terminal.isPresentingOwnedAlert)
        XCTAssertTrue(terminal.isFirstResponder, "focus held before the alert is reclaimed")

        // Native dismissal tracking resumes once the full keyboard returns.
        terminal.keyboardDidShow(keyboardNotification(height: 498))
        XCTAssertTrue(terminal.ownsFullSoftwareKeyboardPresentation)
        terminal.keyboardDidShow(keyboardNotification(height: 68.5))
        XCTAssertEqual(callbackCount, 1)
    }

    func testOwnedAlertOverVisibleKeyboardRearmsDismissTrackingOnDismiss() throws {
        let mounted = try mountTerminal()
        defer { unmountTerminal(mounted) }
        let terminal = mounted.terminal
        disableAutomaticKeyboardNotifications(for: terminal)
        XCTAssertTrue(terminal.becomeFirstResponder())
        terminal.keyboardDidShow(keyboardNotification(height: 300))

        // Model a presentation that leaves the terminal focused with the
        // keyboard up under the alert: no keyboard notification follows.
        let alert = UIAlertController(title: "Unable to Paste", message: nil, preferredStyle: .alert)
        terminal.presentOwnedAlert(alert, from: RecordingPresenter())
        XCTAssertFalse(terminal.ownsFullSoftwareKeyboardPresentation)
        XCTAssertTrue(terminal.isFirstResponder)

        terminal.ownedAlertDidDismiss()
        XCTAssertTrue(terminal.ownsFullSoftwareKeyboardPresentation)
    }

    /// Regression: the credential-save sheet resigned the terminal after
    /// login, which entered persistent suppression like a native dismissal.
    func testAppSheetPresentationKeyboardTransitionsDoNotEnterSuppression() async throws {
        let mounted = try mountTerminal()
        defer { unmountTerminal(mounted) }
        let terminal = mounted.terminal
        disableAutomaticKeyboardNotifications(for: terminal)
        XCTAssertTrue(terminal.becomeFirstResponder())
        var callbackCount = 0
        terminal.onSystemSoftwareKeyboardDismiss = { callbackCount += 1 }
        terminal.keyboardDidShow(keyboardNotification(height: 498))
        XCTAssertTrue(terminal.ownsFullSoftwareKeyboardPresentation)

        let presenter = try XCTUnwrap(mounted.window.rootViewController)
        let sheet = UIViewController()
        let presented = expectation(description: "sheet presented")
        presenter.present(sheet, animated: false) { presented.fulfill() }
        await fulfillment(of: [presented], timeout: 3)
        XCTAssertTrue(terminal.isKeyboardTransitionOwnedByPresentation)

        terminal.keyboardDidShow(keyboardNotification(height: 68.5))
        _ = terminal.resignFirstResponder()
        terminal.keyboardDidHide(keyboardNotification(
            name: UIResponder.keyboardDidHideNotification,
            height: 0
        ))
        await drainMainQueue()
        XCTAssertEqual(callbackCount, 0, "an app sheet is not a user keyboard dismissal")

        let dismissed = expectation(description: "sheet dismissed")
        presenter.dismiss(animated: false) { dismissed.fulfill() }
        await fulfillment(of: [dismissed], timeout: 3)
        XCTAssertFalse(terminal.isKeyboardTransitionOwnedByPresentation)

        XCTAssertTrue(terminal.becomeFirstResponder())
        terminal.keyboardDidShow(keyboardNotification(height: 498))
        terminal.keyboardDidShow(keyboardNotification(height: 68.5))
        XCTAssertEqual(callbackCount, 1, "native dismissal tracking resumes after the sheet")
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

    private func dismissPresentedAlert(
        _ alert: UIAlertController,
        from presenter: UIViewController
    ) async throws {
        let deadline = Date().addingTimeInterval(3)
        while alert.isBeingPresented, Date() < deadline { await drainMainQueue() }
        let dismissed = expectation(description: "alert dismissed")
        presenter.dismiss(animated: false) { dismissed.fulfill() }
        await fulfillment(of: [dismissed], timeout: 3)
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
private final class RecordingPresenter: UIViewController {
    private(set) var presentedControllers: [UIViewController] = []

    override func present(
        _ viewControllerToPresent: UIViewController,
        animated flag: Bool,
        completion: (() -> Void)? = nil
    ) {
        presentedControllers.append(viewControllerToPresent)
        completion?()
    }
}

@MainActor
private final class InputViewReloadTrackingTerminalView: UITerminalView {
    private(set) var reloadInputViewsCallCount = 0
    var onReloadInputViews: ((UITerminalView) -> Void)?

    override func reloadInputViews() {
        reloadInputViewsCallCount += 1
        onReloadInputViews?(self)
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
