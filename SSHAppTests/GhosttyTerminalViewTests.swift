import XCTest
import SwiftUI
import UIKit
@testable import SSHApp

/// Regression tests for the libghostty terminal integration.
final class GhosttyTerminalViewTests: XCTestCase {

    // MARK: - Dependencies

    /// The terminal bridge must use the GhosttyTerminal module.
    func testTerminalViewImportsGhosttyTerminal() throws {
        for path in [
            "SSHApp/Views/GhosttyTerminalView.swift",
            "SSHApp/Views/TmuxPaneTerminal.swift",
        ] {
            let source = try readSourceFile(path)
            XCTAssertTrue(
                source.contains("import GhosttyTerminal"),
                "\(path) must import GhosttyTerminal"
            )
        }
    }

    func testDismantleStartsSurfaceRetirementWhilePlatformViewIsAlive() throws {
        let source = try readSourceFile("SSHApp/Views/GhosttyTerminalView.swift")
        let dismantleBody = try extractMethodBody(
            from: source,
            methodName: "static func dismantleUIView"
        )

        guard let retirement = dismantleBody.range(of: "uiView.controller = nil"),
              let callbackRelease = dismantleBody.range(
                  of: "uiView.selectionDebugConfiguration = nil"
              )
        else {
            return XCTFail("Dismantle must retire the surface and release its DEBUG callback")
        }
        XCTAssertLessThan(
            retirement.lowerBound,
            callbackRelease.lowerBound,
            "The old-generation callback must observe synchronous surface cleanup"
        )
    }

    func testSurfaceReplacementAlwaysCancelsTouchSelectionState() throws {
        let source = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView.swift"
        )

        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy: "if replacesSurface {").count - 1,
            2,
            "Controller and configuration replacement must both clean up touch selection"
        )
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy: "cancelTouchSelectionInteraction()").count - 1,
            2,
            "Surface replacement must release transient touch-selection state"
        )
        XCTAssertFalse(
            source.contains("if replacesSurface, selectionDebugConfiguration != nil"),
            "Surface cleanup must not depend on a DEBUG accessibility probe"
        )
    }

    // MARK: - Data flow

    /// Terminal output (user input) must route through the shared input router
    /// so auth-mode capture keeps working. The `write` closure on the in-memory
    /// session is the SwiftTerm `send(source:)` replacement.
    func testWriteClosureRoutesThroughForward() throws {
        let source = try readSourceFile("SSHApp/Views/GhosttyTerminalView.swift")
        XCTAssertTrue(
            source.contains("forwardFromTerminal"),
            "GhosttyTerminalView must route terminal output through forwardFromTerminal for auth-mode capture"
        )
        XCTAssertTrue(
            source.contains("InMemoryTerminalSession("),
            "GhosttyTerminalView must create a per-surface InMemoryTerminalSession"
        )
        let forwardBody = try extractMethodBody(from: source, methodName: "func forwardFromTerminal")
        XCTAssertTrue(
            forwardBody.contains("session.inputMode"),
            "forwardFromTerminal must branch on the session input mode (normal / tmux / auth capture)"
        )
    }

    /// SSH bytes feed the terminal via `session.receive(_:)` and must not be
    /// double-dispatched to main (SSH2Transport already dispatches to main, and
    /// `receive` can block inside Ghostty during surface transitions).
    func testOnDataReceivedUsesEnqueueOnlyOutputDelivery() throws {
        let source = try readSourceFile("SSHApp/Views/GhosttyTerminalView.swift")
        let updateSessionBody = try extractMethodBody(from: source, methodName: "func updateSession")
        let enqueueSessionBody = try extractMethodBody(
            from: source,
            methodName: "private func enqueueSessionOutput"
        )
        let attachChannelBody = try extractMethodBody(from: source, methodName: "private func attachChannel")

        XCTAssertTrue(updateSessionBody.contains("enqueueSessionOutput(data)"))
        XCTAssertTrue(
            enqueueSessionBody.contains("sessionOutputDelivery.enqueue(data)")
                && enqueueSessionBody.contains("channel.deliverTerminalOutput(data)"),
            "session output must join the channel's ordered writer after shell attachment"
        )
        XCTAssertTrue(
            attachChannelBody.contains("registerTerminalOutputReceiver(terminalSession)"),
            "existing-channel output must bind the channel-owned ordered delivery queue"
        )
        XCTAssertFalse(
            updateSessionBody.contains("terminalSession?.receive")
                || attachChannelBody.contains("terminalSession?.receive"),
            "main-actor SSH callbacks must never enter Ghostty synchronously"
        )
    }

    /// Session and existing-channel delivery have independent lifetimes. A
    /// channel replacement must not silently invalidate the still-current
    /// session callback (or vice versa).
    func testSessionAndChannelOutputUseIndependentOwnership() throws {
        let source = try readSourceFile("SSHApp/Views/GhosttyTerminalView.swift")
        let updateSessionBody = try extractMethodBody(from: source, methodName: "func updateSession")
        let attachChannelBody = try extractMethodBody(from: source, methodName: "private func attachChannel")

        XCTAssertTrue(
            updateSessionBody.contains("sessionOutputGeneration == sessionGeneration"),
            "session output must be guarded only by the current session generation"
        )
        XCTAssertTrue(
            attachChannelBody.contains("registerTerminalOutputReceiver(terminalSession)"),
            "existing-channel output must use its channel-owned tokenized queue"
        )
        XCTAssertFalse(updateSessionBody.contains("outputBindingGeneration == bindingGeneration"))
        XCTAssertFalse(attachChannelBody.contains("outputBindingGeneration == bindingGeneration"))
    }

    /// The write callback may fire off-main and must hop to the main queue
    /// (FIFO-ordered, never synchronously re-entering `receive`). Resize must
    /// still hop when it arrives off-main.
    func testWriteResizeClosuresHopToMain() throws {
        for path in [
            "SSHApp/Views/GhosttyTerminalView.swift",
            "SSHApp/Views/TmuxPaneTerminal.swift",
        ] {
            let source = try readSourceFile(path)
            let makeBody = try extractMethodBody(from: source, methodName: "func makeUIView")
            XCTAssertTrue(
                makeBody.contains("DispatchQueue.main.async"),
                "\(path): the write/resize closures must hop to the main queue (ordered, deadlock-safe)"
            )
        }
    }

    // MARK: - Title handling

    /// Regression: libghostty can report the app's inert host-managed command
    /// as the surface title before a failed SSH connection finishes. That
    /// internal command name must not replace the connection label in the tab
    /// menu.
    @MainActor
    func testHostManagedTerminalTitleDoesNotReplaceConnectionTitle() {
        let tab = Tab(title: "server.example.com", connectionState: .awaitingInput)
        let coordinator = GhosttyTerminalView.Coordinator()
        coordinator.tab = tab

        coordinator.terminalDidChangeTitle(HostManagedTerminal.inertCommandName)

        XCTAssertEqual(tab.title, "server.example.com")

        coordinator.terminalDidChangeTitle("server.example.com:~")

        XCTAssertEqual(tab.title, "server.example.com:~")
    }

    // MARK: - Surface lifecycle / attach-race

    /// The ghostty surface is created asynchronously, and its first metrics can
    /// still be provisional. Terminal-ready must be scheduled from surface
    /// attach, not signaled synchronously from makeUIView or attach.
    func testTerminalReadyScheduledAfterSurfaceAttach() throws {
        let source = try readSourceFile("SSHApp/Views/GhosttyTerminalView.swift")

        let makeBody = try extractMethodBody(from: source, methodName: "func makeUIView")
        XCTAssertFalse(
            makeBody.contains("signalTerminalReady"),
            "makeUIView must NOT signal terminal ready — the surface is not attached yet"
        )

        let attachBody = try extractMethodBody(from: source, methodName: "func terminalDidAttachSurface")
        XCTAssertFalse(
            attachBody.contains("signalTerminalReady"),
            "terminalDidAttachSurface must not unblock SSH before the initial grid has settled"
        )
        XCTAssertTrue(
            attachBody.contains("beginViewportSettle()")
                && attachBody.contains("suspendOutputDeliveries()"),
            "terminalDidAttachSurface must keep output gated and begin viewport settling"
        )
    }

    /// The first valid queue drain must request a draw and expose completion
    /// only after Ghostty's corresponding render callback. Both production
    /// representables keep the completion generation-checked.
    func testFirstDrainCompletionFollowsGenerationCheckedGhosttyRender() throws {
        let terminalViewSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView.swift"
        )
        let immediateDrawBody = try extractMethodBody(
            from: terminalViewSource,
            methodName: "public func requestImmediateDraw"
        )
        XCTAssertTrue(
            immediateDrawBody.contains("immediateDrawCompletions.append(completion)")
                && immediateDrawBody.contains("core.requestImmediateTick()"),
            "an immediate-draw completion must be registered before requesting the tick"
        )
        XCTAssertTrue(
            terminalViewSource.contains("core.onPostRender")
                && terminalViewSource.contains("completions.forEach { $0() }"),
            "registered immediate-draw completions must run from Ghostty's post-render callback"
        )

        for path in [
            "SSHApp/Views/GhosttyTerminalView.swift",
            "SSHApp/Views/TmuxPaneTerminal.swift",
        ] {
            let source = try readSourceFile(path)
            let requestBody = try extractMethodBody(
                from: source,
                methodName: "private func requestPostFlushDraw"
            )
            XCTAssertTrue(
                requestBody.contains("requestImmediateDraw(onPostRender:")
                    && requestBody.contains("bindingGeneration")
                    && requestBody.contains("readinessGeneration")
                    && requestBody.contains("onPostFlushDraw?()"),
                "\(path) must report first-drain completion only after a generation-safe post-flush render"
            )
        }
    }

    func testPromptTransitionHarnessMountsProductionRepresentables() throws {
        let source = try readSourceFile("SSHApp/Testing/PromptTransitionUITestHarnessView.swift")
        XCTAssertTrue(source.contains("GhosttyTerminalView("))
        XCTAssertTrue(source.contains("TmuxPaneTerminal("))
        XCTAssertFalse(
            source.contains("TerminalOutputDeliveryQueue")
                || source.contains("TerminalViewportReadinessGate"),
            "the UI regression must exercise the production coordinators rather than a synthetic gate/queue replica"
        )
    }

    /// Regression: a newly opened SSH session must accept hardware/software
    /// keyboard input immediately. The first-responder request belongs after
    /// the ghostty surface attaches, not in SwiftUI's make/update passes where
    /// the UIKit view may not be window-backed yet.
    func testTerminalClaimsInitialFirstResponderOnSurfaceAttach() throws {
        let source = try readSourceFile("SSHApp/Views/GhosttyTerminalView.swift")
        let makeBody = try extractMethodBody(from: source, methodName: "func makeUIView")
        let updateBody = try extractMethodBody(from: source, methodName: "func updateUIView")
        let attachBody = try extractMethodBody(from: source, methodName: "func terminalDidAttachSurface")
        let requestBody = try extractMethodBody(from: source, methodName: "func requestInitialFirstResponder")

        XCTAssertFalse(
            makeBody.contains("becomeFirstResponder()"),
            "makeUIView must not request first responder before the terminal view is attached"
        )
        XCTAssertFalse(
            updateBody.contains("becomeFirstResponder()"),
            "updateUIView must not repeatedly steal first responder from SwiftUI updates"
        )
        XCTAssertTrue(
            source.contains("hasRequestedInitialFirstResponder"),
            "initial first-responder claiming must be one-shot per terminal view"
        )
        XCTAssertTrue(
            attachBody.contains("requestInitialFirstResponder()"),
            "terminalDidAttachSurface must request initial input focus once the surface exists"
        )
        XCTAssertTrue(
            requestBody.contains("DispatchQueue.main.async"),
            "the initial first-responder request should be deferred until UIKit finishes the attach cycle"
        )
        XCTAssertTrue(
            requestBody.contains("becomeFirstResponder()"),
            "the terminal view must become first responder so a newly opened session accepts input"
        )
    }

    func testTerminalViewsUseShortcutAwareTerminalView() throws {
        for path in [
            "SSHApp/Views/GhosttyTerminalView.swift",
            "SSHApp/Views/TmuxPaneTerminal.swift",
        ] {
            let source = try readSourceFile(path)
            XCTAssertTrue(
                source.contains("ShortcutAwareTerminalView(frame: .zero)"),
                "\(path) must instantiate the shortcut-aware terminal subclass"
            )
            XCTAssertTrue(
                source.contains("configureShortcuts(on:"),
                "\(path) must keep shortcut scopes current during make/update"
            )
            XCTAssertTrue(
                source.contains("enabledShortcutScopes"),
                "\(path) must explicitly scope keyboard shortcuts"
            )
            XCTAssertTrue(
                source.contains("prefersTmuxWindowNumberShortcuts"),
                "\(path) must explicitly choose whether command-number shortcuts prefer tmux windows"
            )
        }
    }

    func testTerminalViewsDirectRouteSoftwareKeyboardReturn() throws {
        let shortcutSource = try readSourceFile("SSHApp/Views/TerminalTabShortcut.swift")
        XCTAssertTrue(
            shortcutSource.contains("override func insertText(_ text: String)"),
            "ShortcutAwareTerminalView must intercept UIKit software-keyboard text insertion"
        )
        XCTAssertTrue(
            shortcutSource.contains("onSoftwareKeyboardReturn?()"),
            "software-keyboard Return must have an app-owned direct route before ghostty text insertion"
        )
        XCTAssertTrue(
            shortcutSource.contains("sendSoftwareKeyboardTextDirectly(text)"),
            "software-keyboard text must use the in-memory direct input route instead of Ghostty's surface text path"
        )
        XCTAssertTrue(
            shortcutSource.contains("!hardwareTextInputPending"),
            "hardware keyboard text must keep Ghostty's hardware-key suppression path to avoid duplicate input"
        )
        XCTAssertTrue(
            shortcutSource.contains("session.sendInput(data)"),
            "software-keyboard text must be injected through InMemoryTerminalSession.sendInput"
        )

        for path in [
            "SSHApp/Views/GhosttyTerminalView.swift",
            "SSHApp/Views/TmuxPaneTerminal.swift",
        ] {
            let source = try readSourceFile(path)
            let makeBody = try extractMethodBody(from: source, methodName: "func makeUIView")
            let returnBody = try extractMethodBody(from: source, methodName: "func forwardSoftwareKeyboardReturn")

            XCTAssertTrue(
                makeBody.contains("tv.onSoftwareKeyboardReturn"),
                "\(path) must wire software-keyboard Return into the SSH input path"
            )
            XCTAssertTrue(
                returnBody.contains("terminalSession?.sendInput(Data([0x0D]))"),
                "\(path) must send software-keyboard Return as CR through the in-memory write callback"
            )
        }
    }

    func testTerminalPasteUsesSoftwareKeyboardInputRoute() throws {
        let interactionSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+Interaction.swift"
        )
        let inputAccessorySource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+InputAccessory.swift"
        )

        let pasteBody = try extractMethodBody(
            from: interactionSource,
            methodName: "@IBAction override open func paste"
        )
        let pasteHelperBody = try extractMethodBody(
            from: interactionSource,
            methodName: "func pasteFromPasteboard"
        )
        let canPerformBody = try extractMethodBody(
            from: interactionSource,
            methodName: "override open func canPerformAction"
        )
        let accessoryBody = try extractMethodBody(
            from: inputAccessorySource,
            methodName: "func handleInputBarKey"
        )

        XCTAssertTrue(
            pasteBody.contains("pasteFromPasteboard()"),
            "Long-press Paste must dispatch through the shared terminal paste helper"
        )
        XCTAssertTrue(
            pasteHelperBody.contains("UIPasteboard.general.string")
                && pasteHelperBody.contains("insertText(text)"),
            "Terminal paste must read the user-initiated pasteboard value and re-enter dynamic text insertion"
        )
        XCTAssertFalse(
            pasteHelperBody.contains("inputHandler.insertText"),
            "Terminal paste must not bypass ShortcutAwareTerminalView's direct in-memory input route"
        )
        XCTAssertTrue(
            canPerformBody.contains("#selector(paste(_:))")
                && canPerformBody.contains("UIPasteboard.general.hasStrings"),
            "The UIKit edit menu must advertise Paste when the pasteboard contains text"
        )
        XCTAssertTrue(
            accessoryBody.contains("case .paste:")
                && accessoryBody.contains("pasteFromPasteboard()"),
            "The custom keyboard bar Paste item must use the same paste route as the edit menu"
        )
        XCTAssertFalse(
            accessoryBody.contains("inputHandler.insertText"),
            "The keyboard bar Paste item must not bypass ShortcutAwareTerminalView's direct input route"
        )
    }

    func testOpenURLCallbackRoutesLinksToIOS() throws {
        let callbackSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Controller/TerminalController+Callbacks.swift"
        )
        let actionBody = try extractMethodBody(
            from: callbackSource,
            methodName: "static func action"
        )

        XCTAssertTrue(
            actionBody.contains("action.tag == GHOSTTY_ACTION_OPEN_URL")
                && actionBody.contains("return handled"),
            "The embedded callback must prevent Ghostty from falling back to its unavailable iOS opener"
        )

        for path in [
            "SSHApp/Views/GhosttyTerminalView.swift",
            "SSHApp/Views/TmuxPaneTerminal.swift",
        ] {
            let source = try readSourceFile(path)
            XCTAssertTrue(
                source.contains("TerminalSurfaceOpenURLDelegate")
                    && source.contains("TerminalLinkOpener.open(url)"),
                "\(path) must route Ghostty link activation through the native iOS URL opener"
            )
        }
    }

    func testIpadTrackpadScrollInputIsRecognized() throws {
        let interactionSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+Interaction.swift"
        )

        let touchSetupBody = try extractMethodBody(
            from: interactionSource,
            methodName: "func setupTouchScrollInput"
        )
        let trackpadSetupBody = try extractMethodBody(
            from: interactionSource,
            methodName: "func setupIndirectPointerScrollInput"
        )
        let trackpadHandlerBody = try extractMethodBody(
            from: interactionSource,
            methodName: "func handleIndirectPointerScrollGesture"
        )
        let deltaSenderBody = try extractMethodBody(
            from: interactionSource,
            methodName: "func sendIndirectPointerScrollDelta"
        )
        let trackpadScrollPath = trackpadHandlerBody + "\n" + deltaSenderBody

        XCTAssertTrue(
            touchSetupBody.contains("setupIndirectPointerScrollInput()"),
            "Non-Catalyst touch setup must install the indirect-pointer scroll recognizer"
        )
        XCTAssertTrue(
            trackpadSetupBody.contains("UIPanGestureRecognizer("),
            "iPad trackpad scroll input must use a pan recognizer"
        )
        XCTAssertTrue(
            trackpadSetupBody.contains("allowedScrollTypesMask = [.continuous, .discrete]"),
            "Trackpad scrolling must opt into UIKit scroll-wheel/trackpad scroll events"
        )
        XCTAssertTrue(
            trackpadSetupBody.contains("UITouch.TouchType.indirectPointer"),
            "Trackpad scrolling must be scoped to indirect pointer input"
        )
        XCTAssertTrue(
            trackpadSetupBody.contains("minimumNumberOfTouches = 0"),
            "Trackpad scrolling must not steal one-finger pointer selection drags"
        )
        XCTAssertTrue(
            trackpadSetupBody.contains("maximumNumberOfTouches = 0"),
            "Trackpad scrolling must only handle scroll-type, zero-touch events"
        )
        XCTAssertTrue(
            trackpadSetupBody.contains("cancelsTouchesInView = false"),
            "Trackpad scrolling must not cancel terminal touches"
        )

        XCTAssertTrue(
            trackpadHandlerBody.contains("activePointerButton == nil"),
            "Trackpad scroll must ignore active pointer click/selection drags"
        )
        XCTAssertTrue(
            trackpadHandlerBody.contains("gesture.numberOfTouches == 0"),
            "Trackpad scroll handling must defensively require zero touches"
        )
        XCTAssertTrue(
            trackpadHandlerBody.contains("core.setFocus(true)"),
            "Trackpad scroll should focus the target terminal surface"
        )
        XCTAssertTrue(
            trackpadHandlerBody.contains("stopMomentumScrolling()"),
            "Trackpad scroll should stop any previous direct-touch momentum"
        )
        XCTAssertTrue(
            trackpadHandlerBody.contains("sendIndirectPointerScrollDelta(from: gesture)"),
            "Trackpad scroll deltas must be forwarded through the precision-scroll path"
        )

        XCTAssertTrue(
            deltaSenderBody.contains("gesture.translation(in: self)"),
            "Trackpad scroll must use UIKit's precision translation deltas"
        )
        XCTAssertTrue(
            deltaSenderBody.contains("gesture.setTranslation(.zero, in: self)"),
            "Trackpad scroll must reset translation after forwarding each delta"
        )
        XCTAssertTrue(
            deltaSenderBody.contains("TerminalScrollModifiers(precision: true)"),
            "Trackpad scroll events must be sent as precision scroll events"
        )
        XCTAssertTrue(
            deltaSenderBody.contains("surface?.sendMouseScroll("),
            "Trackpad scroll deltas must be forwarded to Ghostty"
        )
        XCTAssertFalse(
            trackpadScrollPath.contains("touchScrollMultiplier"),
            "Trackpad scroll deltas are already OS-scaled and must not use direct-touch scaling"
        )
        XCTAssertFalse(
            trackpadScrollPath.contains("startMomentumScrolling("),
            "Trackpad scrolling must not add synthetic direct-touch momentum"
        )
    }

    func testHardwareKeyboardRepeatIsForwardedToGhostty() throws {
        let terminalSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+Keyboard.swift"
        )
        let terminalRepeatBody = try extractMethodBody(
            from: terminalSource,
            methodName: "override open func pressesChanged"
        )
        XCTAssertTrue(
            terminalRepeatBody.contains("GHOSTTY_ACTION_REPEAT"),
            "UIKit key-repeat events must be forwarded to Ghostty as repeat actions"
        )

        let handleBody = try extractMethodBody(
            from: terminalSource,
            methodName: "func handleKeyPress(\n            _ key: TerminalUIKitKeyPress"
        )
        XCTAssertTrue(
            handleBody.contains("action == GHOSTTY_ACTION_PRESS || action == GHOSTTY_ACTION_REPEAT"),
            "repeat events must suppress UIKit text insertion just like initial hardware key presses"
        )

        let shortcutSource = try readSourceFile("SSHApp/Views/TerminalTabShortcut.swift")
        let shortcutRepeatBody = try extractMethodBody(
            from: shortcutSource,
            methodName: "override func pressesChanged"
        )
        XCTAssertTrue(
            shortcutRepeatBody.contains("invokeShortcut: false"),
            "app-level shortcuts must not fire repeatedly while a command key is held"
        )
        XCTAssertTrue(
            shortcutRepeatBody.contains("super.pressesChanged"),
            "ordinary terminal key-repeat events must continue through the terminal view"
        )
    }

    func testHardwareKeyboardRepeatFallbackUsesConfigAndCancelsOnRelease() throws {
        let terminalViewSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView.swift"
        )
        let keyboardSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+Keyboard.swift"
        )
        let textInputSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+UITextInput.swift"
        )

        XCTAssertTrue(
            terminalViewSource.contains("public var hardwareKeyRepeatConfiguration"),
            "UITerminalView must expose a live hardware key repeat configuration"
        )
        XCTAssertTrue(
            terminalViewSource.contains("cancelHardwareKeyRepeat()"),
            "Disabling configured repeat must cancel any active repeat task"
        )

        let beganBody = try extractMethodBody(from: keyboardSource, methodName: "override open func pressesBegan")
        XCTAssertTrue(
            beganBody.contains("startHardwareKeyRepeatIfNeeded"),
            "Hardware key press must start the app-managed repeat scheduler"
        )

        let changedBody = try extractMethodBody(from: keyboardSource, methodName: "override open func pressesChanged")
        XCTAssertTrue(
            changedBody.contains("hardwareKeyRepeatConfiguration.enabled")
                && changedBody.contains("return")
                && changedBody.contains("GHOSTTY_ACTION_REPEAT"),
            "UIKit repeat events must be ignored only while app-managed repeat is enabled"
        )

        let endedBody = try extractMethodBody(from: keyboardSource, methodName: "override open func pressesEnded")
        XCTAssertTrue(
            endedBody.contains("cancelHardwareKeyRepeat(for: keyPress)")
                && endedBody.contains("releaseHardwareTextInputSuppression(for: keyPress)"),
            "Releasing a hardware key must stop repeat and text suppression"
        )

        let startBody = try extractMethodBody(
            from: keyboardSource,
            methodName: "private func startHardwareKeyRepeatIfNeeded"
        )
        XCTAssertTrue(
            startBody.contains("delayNanoseconds")
                && startBody.contains("intervalNanoseconds")
                && startBody.contains("GHOSTTY_ACTION_REPEAT"),
            "The repeat scheduler must honor configured delay/interval and emit repeat actions"
        )

        let repeatableBody = try extractMethodBody(
            from: keyboardSource,
            methodName: "private func shouldSynthesizeHardwareRepeat"
        )
        XCTAssertTrue(
            repeatableBody.contains("!filteredModifierFlags.contains(.command)")
                && repeatableBody.contains("!Self.isModifierOnlyKey(key)"),
            "Synthetic repeat must exclude command-modified shortcuts and modifier-only keys"
        )

        XCTAssertTrue(
            textInputSource.contains("hardwareTextInputSuppressedKeyCodes.isEmpty"),
            "System text insertion must stay suppressed while app-managed hardware repeat owns a held key"
        )
    }

    func testModifiedHardwareKeysUseGhosttyStateAwareEncoding() throws {
        let routerSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/Shared/TerminalHardwareKeyRouter.swift"
        )
        XCTAssertFalse(
            routerSource.contains("modifiedControlInputForUIKit"),
            "modified hardware keys must not bypass Ghostty with fixed escape strings"
        )

        let modifiedRouteBody = try extractMethodBody(
            from: routerSource,
            methodName: """
            static func routeUIKit(
                    usage: UInt16,
                    backend: TerminalSessionBackend,
                    modifiers: TerminalInputModifiers
            """
        )
        XCTAssertTrue(
            modifiedRouteBody.contains("guard modifiers.isEmpty else")
                && modifiedRouteBody.contains("return .ghostty(ghosttyKeyForUIKit(usage: usage))"),
            "modified hardware keys must route through Ghostty so Kitty/modifyOtherKeys state is honored"
        )
        XCTAssertTrue(
            modifiedRouteBody.contains("return routeUIKit(usage: usage, backend: backend)"),
            "unmodified host-managed control keys may keep the direct byte path"
        )

        let keyboardSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+Keyboard.swift"
        )
        let handleKeyBody = try extractMethodBody(
            from: keyboardSource,
            methodName: """
            func handleKeyPress(
                        _ key: TerminalUIKitKeyPress,
            """
        )
        XCTAssertTrue(
            handleKeyBody.contains("consumedModifierFlags(")
                && handleKeyBody.contains("shouldSendHardwareText(for: key)"),
            "hardware key events must avoid treating functional keys as shifted text"
        )

        let suppressBody = try extractMethodBody(
            from: keyboardSource,
            methodName: "func shouldSuppressUIKeyInput"
        )
        XCTAssertTrue(
            suppressBody.contains("Self.isNonTextHardwareKey")
                && suppressBody.contains("return true"),
            "non-text hardware keys must suppress UIKit text insertion for all terminal modifiers"
        )

        let consumedBody = try extractMethodBody(
            from: keyboardSource,
            methodName: "private func consumedModifierFlags"
        )
        XCTAssertTrue(
            consumedBody.contains("guard shouldSendHardwareText(for: key) else { return [] }"),
            "Return/Tab/Backspace must not consume Shift before Ghostty encodes Kitty sequences"
        )

        let nonTextBody = try extractMethodBody(
            from: keyboardSource,
            methodName: "private static func isNonTextHardwareKey"
        )
        XCTAssertTrue(
            nonTextBody.contains("0x28")
                && nonTextBody.contains("0x2A")
                && nonTextBody.contains("0x2B")
                && nonTextBody.contains("0x3A ... 0x45")
                && nonTextBody.contains("0x46 ... 0x52"),
            "Return, Backspace, Tab, function keys, and navigation keys must be encoded as keys"
        )
    }

    /// Regression: touch text selection must happen directly in the terminal
    /// surface. The old path presented a separate UITextView sheet containing a
    /// viewport snapshot, which meant users copied from a modal instead of the
    /// terminal display.
    func testTerminalSelectionUsesDirectTerminalSurfacePath() throws {
        for path in [
            "SSHApp/Views/GhosttyTerminalView.swift",
            "SSHApp/Views/TmuxPaneTerminal.swift",
        ] {
            let source = try readSourceFile(path)
            XCTAssertFalse(
                source.contains("TerminalSurfaceTextSelectionRequestDelegate"),
                "\(path) must not opt into the old selection-sheet delegate"
            )
            XCTAssertFalse(
                source.contains("presentSelectionSheet"),
                "\(path) must not present a separate text-selection sheet"
            )
        }

        let interactionSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+Interaction.swift"
        )
        let longPressBody = try extractMethodBody(
            from: interactionSource,
            methodName: "func handleLongPressForSelection"
        )

        XCTAssertTrue(
            longPressBody.contains("GHOSTTY_MOUSE_PRESS")
                && longPressBody.contains("GHOSTTY_MOUSE_RELEASE"),
            "Long-press selection must drive Ghostty's native mouse selection"
        )
        XCTAssertTrue(
            longPressBody.contains("presentTouchSelectionEditMenu"),
            "Direct terminal selection should surface the edit menu on release"
        )
        XCTAssertFalse(
            interactionSource.contains("TerminalSurfaceTextSelectionRequestDelegate")
                || interactionSource.contains("readViewportText()")
                || interactionSource.contains("terminalDidRequestTextSelection"),
            "The local terminal package must not use the snapshot selection-sheet API"
        )
    }

    /// Direct-touch long press must drive Ghostty's word-granularity selection:
    /// the recognizer synthesizes a full double-click (press, release, press)
    /// at the touch point and holds the second press during the drag. A single
    /// press would give a character-level selection anchored exactly under the
    /// finger, which is nearly impossible to target with touch.
    func testDirectTouchLongPressUsesWordGranularityDoubleClick() throws {
        let interactionSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+Interaction.swift"
        )
        let setupBody = try extractMethodBody(
            from: interactionSource,
            methodName: "func setupTouchScrollInput"
        )
        XCTAssertTrue(
            setupBody.contains("allowedTouchTypes") && setupBody.contains("pencil"),
            "Long-press selection must accept Pencil touches, not just direct touches"
        )

        let longPressBody = try extractMethodBody(
            from: interactionSource,
            methodName: "func handleLongPressForSelection"
        )
        XCTAssertTrue(
            longPressBody.components(separatedBy: "GHOSTTY_MOUSE_PRESS").count - 1 >= 2,
            "Long-press began must synthesize Ghostty's double-click (press-release-press) so selection is word-granular"
        )
        XCTAssertTrue(
            longPressBody.components(separatedBy: "GHOSTTY_MOUSE_RELEASE").count - 1 >= 1,
            "Long-press began must release the first synthetic click before the held second press"
        )
        XCTAssertTrue(
            longPressBody.contains("syntheticLeftButtonDown"),
            "Long-press must track the held synthetic button so drags and arbitration can rely on it"
        )

        let releaseBody = try extractMethodBody(
            from: interactionSource,
            methodName: "func releaseSyntheticSelectionButton"
        )
        XCTAssertTrue(
            releaseBody.contains("!touchSelectionIsMouseCaptured")
                && releaseBody.contains("surface?.isMouseCaptured == true")
                && releaseBody.contains("TerminalInputModifiers.shift.ghosttyMods"),
            "A host gesture interrupted by capture must clear native button state without emitting an unmatched remote release"
        )
    }

    /// UIKit subview-backed layers must never be resized as if they were
    /// Ghostty renderer layers. Overlapping endpoint targets must route to the
    /// nearest handle rather than always choosing the later-added end handle.
    @MainActor
    func testDirectTouchSelectionOverlaysKeepTheirSizeAndBothHandlesRemainReachable() throws {
        let terminal = ShortcutAwareTerminalView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 640)
        )
        let rendererLayer = CALayer()
        terminal.layer.insertSublayer(rendererLayer, at: 0)
        terminal.setNeedsLayout()
        terminal.layoutIfNeeded()

        XCTAssertEqual(rendererLayer.frame, terminal.bounds)
        XCTAssertEqual(rendererLayer.contentsScale, terminal.contentScaleFactor)

        let handles = terminal.subviews.filter {
            $0.bounds.size == CGSize(width: 48, height: 48)
        }
        let magnifiers = terminal.subviews.filter {
            $0.bounds.size == CGSize(width: 96, height: 96)
        }
        XCTAssertEqual(
            handles.count,
            0,
            "Hidden endpoint handles must stay out of the view and accessibility hierarchies"
        )
        XCTAssertEqual(magnifiers.count, 1)

        let handlesSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/TerminalSelectionHandles.swift"
        )
        let viewSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView.swift"
        )
        XCTAssertTrue(
            handlesSource.contains("if startHandle.superview == nil { addSubview(startHandle) }")
                && handlesSource.contains("if endHandle.superview == nil { addSubview(endHandle) }"),
            "Showing a selection must reattach both endpoint handles"
        )
        XCTAssertTrue(
            viewSource.contains("let candidates = [selectionStartHandle, selectionEndHandle]")
                && viewSource.contains("if let nearest = candidates.min"),
            "Overlapping hit targets must route to the nearest visible endpoint"
        )
    }

    /// Persistent selection handles must use Ghostty's cell geometry, remain
    /// finger-sized, and rebuild the native selection from the opposite end.
    func testDirectTouchSelectionHandlesRebuildGhosttySelection() throws {
        let handlesSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/TerminalSelectionHandles.swift"
        )
        XCTAssertTrue(
            handlesSource.contains("static let hitSize: CGFloat = 48")
                && handlesSource.contains("private static let markerSize: CGFloat = 22"),
            "Selection markers must live inside at least 44-point finger hit targets"
        )

        let installBody = try extractMethodBody(
            from: handlesSource,
            methodName: "func installSelectionHandlesAfterTouchSelection"
        )
        let snapBody = try extractMethodBody(
            from: handlesSource,
            methodName: "private func snapTouchSelectionEndpointsToNativeSelection"
        )
        XCTAssertTrue(
            installBody.contains("snapTouchSelectionEndpointsToNativeSelection()")
                && snapBody.contains("surface.readSelectionResult()")
                && snapBody.contains("selection.offsetStart")
                && snapBody.contains("selection.offsetLength")
                && snapBody.contains("touchSelectionGridGeometry(for: metrics)"),
            "Initial handles must snap every in-viewport selection to Ghostty's finalized leading and trailing cell edges"
        )
        XCTAssertFalse(
            snapBody.contains("surface.quicklookWord()"),
            "Initial range geometry must not be limited to stationary single-word selections"
        )

        let panBody = try extractMethodBody(
            from: handlesSource,
            methodName: "func handleSelectionHandlePan"
        )
        XCTAssertTrue(
            panBody.contains("let fixedPoint")
                && panBody.contains("endMousePoint")
                && panBody.contains("startMousePoint")
                && panBody.contains("GHOSTTY_MOUSE_PRESS"),
            "A handle drag must start a Ghostty selection rebuild at the opposite endpoint using a cell-interior point"
        )
        XCTAssertTrue(
            panBody.contains("selectionHandleDragTouchOffset")
                && panBody.contains("selectionHandleLocation(for: location)")
                && panBody.contains("selectionHandleDragMouseOffset")
                && panBody.contains("selectionHandleMouseLocation(")
                && panBody.contains("displayPoint: endpointLocation")
                && panBody.contains("mousePoint: mouseLocation"),
            "A handle drag must preserve both finger-to-display and display-to-cell-interior offsets so grabbing or releasing the large hit target cannot jump the selection"
        )
        XCTAssertTrue(
            panBody.contains("min(max(mouseLocation.x, 0), bounds.width)")
                && panBody.contains("y: mouseLocation.y"),
            "Handle drags must clamp X but leave Y out of bounds for Ghostty autoscroll"
        )
        XCTAssertTrue(
            panBody.components(separatedBy: "releaseSyntheticSelectionButton()").count - 1 >= 2,
            "Ended and cancelled handle drags must both release the synthetic button"
        )
    }

    /// Output selection and terminal input are separate semantic menu paths:
    /// every selection presentation is Copy-only, while cursor input is Paste-only.
    func testTerminalSelectionAndInputMenusStaySemanticallySeparate() throws {
        let viewSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView.swift"
        )
        let interactionSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+Interaction.swift"
        )
        let handlesSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/TerminalSelectionHandles.swift"
        )

        let selectionElements = try extractMethodBody(
            from: viewSource,
            methodName: "func selectionMenuElements"
        )
        XCTAssertTrue(selectionElements.contains("title: \"Copy\""))
        XCTAssertFalse(
            selectionElements.contains("title: \"Paste\"")
                || selectionElements.contains("pasteFromPasteboard()"),
            "Host output selection must never construct Paste"
        )

        let inputElements = try extractMethodBody(
            from: viewSource,
            methodName: "func terminalInputMenuElements"
        )
        XCTAssertTrue(
            inputElements.contains("UIPasteboard.general.hasStrings")
                && inputElements.contains("title: \"Paste\"")
                && inputElements.contains("terminalInputMenuIsValid()")
                && inputElements.contains("pasteFromPasteboard()"),
            "Cursor input must expose a pasteboard-gated Paste action and revalidate ownership"
        )
        XCTAssertFalse(
            inputElements.contains("title: \"Copy\"")
                || inputElements.contains("inputHandler")
                || inputElements.contains("sendText")
                || inputElements.contains("SSHChannel"),
            "Cursor Paste must not construct Copy or bypass the shared paste route"
        )

        let setupBody = try extractMethodBody(
            from: interactionSource,
            methodName: "func setupPlatformInput"
        )
        XCTAssertTrue(
            setupBody.contains("addInteraction(selectionContextMenuInteraction)")
                && setupBody.contains("addInteraction(selectionEditMenuInteraction)")
                && setupBody.contains("addInteraction(terminalInputEditMenuInteraction)"),
            "Pointer selection, touch selection, and cursor input need distinct installed interactions"
        )

        let delegateBody = try extractMethodBody(
            from: interactionSource,
            methodName: "menuFor _: UIEditMenuConfiguration"
        )
        XCTAssertTrue(
            delegateBody.contains("interaction === selectionEditMenuInteraction")
                && delegateBody.contains("selectionMenuElements()")
                && delegateBody.contains("interaction === terminalInputEditMenuInteraction")
                && delegateBody.contains("terminalInputMenuElements()"),
            "The edit-menu delegate must choose elements by interaction identity"
        )
        let targetBody = try extractMethodBody(
            from: interactionSource,
            methodName: "targetRectFor configuration"
        )
        XCTAssertTrue(
            targetBody.contains("interaction === terminalInputEditMenuInteraction")
                && targetBody.contains("terminalInputMenuAnchor"),
            "Cursor input must target its stored unexpanded cursor cell"
        )

        let contextConfiguration = try extractMethodBody(
            from: viewSource,
            methodName: "func selectionContextMenuConfiguration"
        )
        XCTAssertTrue(contextConfiguration.contains("selectionMenuElements()"))
        let pointerFallback = try extractMethodBody(
            from: viewSource,
            methodName: "func showSelectionCopyMenu"
        )
        XCTAssertTrue(pointerFallback.contains("presentTouchSelectionEditMenu"))
        XCTAssertFalse(
            viewSource.contains("UIMenuController"),
            "Pointer fallback must not leak responder-chain Paste through UIMenuController"
        )

        let handlePanBody = try extractMethodBody(
            from: handlesSource,
            methodName: "func handleSelectionHandlePan"
        )
        XCTAssertTrue(
            handlePanBody.contains("dismissTerminalEditMenus()")
                && handlePanBody.contains("presentTouchSelectionEditMenu"),
            "Handle adjustment must dismiss transient menus and restore the Copy-only selection menu"
        )
    }

    /// Cursor geometry follows Ghostty's midpoint/bottom IME contract, while
    /// one generalized tap gives selection cleanup strict priority over Paste.
    func testCursorPasteUsesNormalizedGeometryAndExclusiveTapArbitration() throws {
        let viewSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView.swift"
        )
        let interactionSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+Interaction.swift"
        )
        let lifecycleSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+Lifecycle.swift"
        )
        let pinchSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+PinchZoom.swift"
        )

        let geometryBody = try extractMethodBody(
            from: viewSource,
            methodName: "func terminalCursorCellGeometry"
        )
        XCTAssertTrue(
            geometryBody.contains("surface.imePoint()")
                && geometryBody.contains("surface.size()")
                && geometryBody.contains("resolvedDisplayScale()")
                && geometryBody.contains("imeX - cellWidth / 2")
                && geometryBody.contains("imeY - cellHeight")
                && geometryBody.contains("cell.intersection(viewport)"),
            "Cursor cells must normalize Ghostty's midpoint/bottom point using scaled cell metrics"
        )
        XCTAssertFalse(
            geometryBody.contains("caretRect(for:"),
            "Cursor menu geometry must not depend on the overridable composition caret"
        )

        let hitTargetBody = try extractMethodBody(
            from: viewSource,
            methodName: "func terminalCursorHitTarget"
        )
        XCTAssertTrue(
            hitTargetBody.contains("max(44, geometry.cell.width)")
                && hitTargetBody.contains("max(44, geometry.cell.height)")
                && hitTargetBody.contains("intersection(terminalViewportBounds)"),
            "Cursor hit testing must be finger-sized and clipped to the visible viewport"
        )

        let presentationBody = try extractMethodBody(
            from: viewSource,
            methodName: "func presentTerminalInputEditMenu"
        )
        XCTAssertTrue(
            presentationBody.contains("!hasHostSelection()")
                && presentationBody.contains("surface?.isMouseCaptured != true")
                && presentationBody.contains("UIPasteboard.general.hasStrings")
                && presentationBody.contains("terminalCursorHitTarget()?.contains(initiatingPoint)")
                && presentationBody.contains("terminalInputMenuAnchor = cursorRect")
                && presentationBody.contains("sourcePoint: CGPoint(x: cursorRect.midX"),
            "Cursor menu presentation must revalidate state and point to the unexpanded cell"
        )

        let tapBody = try extractMethodBody(
            from: interactionSource,
            methodName: "func handleTerminalTap"
        )
        let selectionBranch = try XCTUnwrap(tapBody.range(of: "if terminalTapBeganWithHostSelection"))
        let clear = try XCTUnwrap(tapBody.range(of: "clearTouchSelection()"))
        let earlyReturn = try XCTUnwrap(tapBody.range(of: "return", range: clear.upperBound..<tapBody.endIndex))
        let present = try XCTUnwrap(tapBody.range(of: "presentTerminalInputEditMenu"))
        XCTAssertTrue(selectionBranch.lowerBound < clear.lowerBound)
        XCTAssertTrue(clear.lowerBound < earlyReturn.lowerBound && earlyReturn.lowerBound < present.lowerBound)
        XCTAssertFalse(
            tapBody.contains("pasteFromPasteboard()") || tapBody.contains("insertText("),
            "The initial cursor tap must never paste directly"
        )

        let setupBody = try extractMethodBody(
            from: interactionSource,
            methodName: "func setupTouchScrollInput"
        )
        XCTAssertTrue(
            setupBody.contains("terminalTap.cancelsTouchesInView = true")
                && setupBody.contains("terminalTap.require(toFail: gesture)")
                && setupBody.contains("terminalTap.require(toFail: longPress)"),
            "Cursor tapping must yield to direct scroll and long-press selection"
        )
        let touchAdmissionBody = try extractMethodBody(
            from: interactionSource,
            methodName: "shouldReceive touch: UITouch"
        )
        XCTAssertTrue(
            touchAdmissionBody.contains("!suppressesSoftwareKeyboard")
                && touchAdmissionBody.contains("softwareKeyboardVisible")
                && touchAdmissionBody.contains("return false"),
            "A keyboard-dismissal tap must not also become a cursor Paste tap"
        )

        let touchScrollBody = try extractMethodBody(
            from: interactionSource,
            methodName: "func handleTouchScrollGesture"
        )
        let pointerScrollBody = try extractMethodBody(
            from: interactionSource,
            methodName: "func handleIndirectPointerScrollGesture"
        )
        XCTAssertTrue(
            touchScrollBody.contains("dismissTerminalEditMenus()")
                && pointerScrollBody.contains("dismissTerminalEditMenus()"),
            "Direct and pointer scrolling must invalidate stale terminal menus"
        )

        let simultaneousBody = try extractMethodBody(
            from: interactionSource,
            methodName: "shouldRecognizeSimultaneouslyWith"
        )
        XCTAssertTrue(
            simultaneousBody.contains("terminalTapGesture")
                && simultaneousBody.contains("touchScrollPanGesture")
                && simultaneousBody.contains("touchSelectionLongPressGesture")
                && simultaneousBody.contains("UIPinchGestureRecognizer")
                && simultaneousBody.contains("return false"),
            "Cursor tap must not recognize simultaneously with scroll, selection, or pinch"
        )

        XCTAssertTrue(
            viewSource.contains("invalidateTerminalInputMenuAfterRender()")
                && viewSource.contains("selectionContextMenuInteraction.dismissMenu()")
                && lifecycleSource.contains("dismissTerminalEditMenus()")
                && lifecycleSource.contains("invalidateTerminalEditMenusForViewportChange()")
                && lifecycleSource.contains("override open func resignFirstResponder()")
                && pinchSource.contains("dismissTerminalEditMenus()"),
            "Render, focus, lifecycle, and pinch invalidation must dismiss stale cursor menus"
        )
    }

    /// Copy, outside taps, and native-selection invalidation must tear down the
    /// touch overlay so stale handles can never cover subsequent terminal use.
    func testDirectTouchSelectionClearsAfterCopyTapAndNativeSelectionLoss() throws {
        let viewSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView.swift"
        )
        let interactionSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+Interaction.swift"
        )
        let handlesSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/TerminalSelectionHandles.swift"
        )

        let copyBody = try extractMethodBody(
            from: viewSource,
            methodName: "func copySelectedTextToPasteboard"
        )
        XCTAssertTrue(
            copyBody.contains("clearTouchSelectionAfterCopy()"),
            "A successful touch-selection Copy must remove both highlight and handles"
        )

        let clearAfterCopyBody = try extractMethodBody(
            from: handlesSource,
            methodName: "func clearTouchSelectionAfterCopy"
        )
        XCTAssertTrue(
            clearAfterCopyBody.contains("guard selectionHandlesVisible")
                && clearAfterCopyBody.contains("clearTouchSelection()"),
            "Copy cleanup must be limited to direct-touch selections"
        )

        let clearBody = try extractMethodBody(
            from: handlesSource,
            methodName: "func clearTouchSelection()"
        )
        XCTAssertTrue(
            clearBody.contains("dismissSelectionHandles()")
                && clearBody.contains("resetSyntheticClickCount(relativeTo: reference)"),
            "Touch cleanup must remove overlays and clear Ghostty's native selection"
        )

        let tapBody = try extractMethodBody(
            from: interactionSource,
            methodName: "func handleTerminalTap"
        )
        XCTAssertTrue(
            tapBody.contains("clearTouchSelection()"),
            "A terminal tap must use the same complete touch-selection cleanup path"
        )

        let synchronizeBody = try extractMethodBody(
            from: handlesSource,
            methodName: "func synchronizeTouchSelectionOverlayAfterRender"
        )
        XCTAssertTrue(
            synchronizeBody.contains("surface?.hasSelection() == true")
                && synchronizeBody.contains("dismissSelectionHandles()")
                && synchronizeBody.contains("snapTouchSelectionEndpointsToNativeSelection()")
                && synchronizeBody.contains("layoutSelectionHandles()")
                && viewSource.contains("synchronizeTouchSelectionOverlayAfterRender()"),
            "A completed render must align handles to Ghostty's finalized range or remove them when the native selection is gone"
        )
    }

    /// Touch-selection polish stays local to the terminal overlay: a live
    /// snapshot loupe, cell-boundary haptics, and accessible endpoint nudges.
    func testDirectTouchSelectionPolishSupportsMagnifierHapticsAndVoiceOver() throws {
        let handlesSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/TerminalSelectionHandles.swift"
        )
        let interactionSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+Interaction.swift"
        )
        let surfaceSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Surface/TerminalSurface.swift"
        )

        XCTAssertTrue(
            handlesSource.contains("final class TerminalSelectionMagnifierView")
                && handlesSource.contains("static let diameter: CGFloat = 96")
                && handlesSource.contains("resizableSnapshotView(")
                && handlesSource.contains("terminalView.layer.render")
                && handlesSource.contains("terminalViewportBounds.intersection(bounds)")
                && handlesSource.contains("intersection(clippingBounds)")
                && handlesSource.contains("$0 as? TerminalSelectionHandleView")
                && handlesSource.contains("handles.forEach { $0.isHidden = true }")
                && handlesSource.contains("UIAccessibility.isVoiceOverRunning"),
            "Active selection drags need a 96-point GPU-capable live loupe with a render fallback that stays hidden under VoiceOver"
        )

        let handlePanBody = try extractMethodBody(
            from: handlesSource,
            methodName: "func handleSelectionHandlePan"
        )
        XCTAssertTrue(
            handlePanBody.contains("showSelectionMagnifier(at: draggedDisplayPoint)")
                && handlePanBody.contains("showSelectionMagnifier(at: endpointLocation)")
                && handlePanBody.contains("hideSelectionMagnifier()"),
            "The handle drag must show/update the loupe at the adjusted endpoint and hide it on every terminal state"
        )
        let longPressBody = try extractMethodBody(
            from: interactionSource,
            methodName: "func handleLongPressForSelection"
        )
        XCTAssertTrue(
            longPressBody.contains("showSelectionMagnifier(at: location)")
                && longPressBody.contains("hideSelectionMagnifier()"),
            "Initial long-press expansion must use the same active-drag loupe"
        )

        let feedbackBody = try extractMethodBody(
            from: handlesSource,
            methodName: "private func emitSelectionFeedbackIfCellChanged"
        )
        XCTAssertTrue(
            feedbackBody.contains("selectionHandleLastFeedbackCell")
                && feedbackBody.contains("selectionChanged()"),
            "Handle haptics must fire only when the drag crosses a terminal cell boundary"
        )
        let selectionCellBody = try extractMethodBody(
            from: handlesSource,
            methodName: "private func selectionCell"
        )
        XCTAssertTrue(
            selectionCellBody.contains("touchSelectionCellCoordinates")
                && handlesSource.contains("touchSelectionGridOrigin")
                && handlesSource.contains("refreshTouchSelectionGridOrigin")
                && handlesSource.contains("surface.gridPadding()")
                && surfaceSource.contains("ghostty_surface_grid_padding(")
                && handlesSource.contains("padding.leftPixels")
                && handlesSource.contains("padding.topPixels")
                && handlesSource.contains("touchSelectionGridMetrics == metrics")
                && handlesSource.contains("touchSelectionGridScale == contentScaleFactor")
                && handlesSource.contains("selectionHandlesViewportBounds == terminalViewportBounds")
                && handlesSource.contains("let viewport = terminalViewportBounds")
                && handlesSource.contains("Quicklook's Y coordinate is a text")
                && handlesSource.contains("cell.column < Int(metrics.columns)")
                && handlesSource.contains("cell.row < Int(metrics.rows)"),
            "Haptics and accessibility must use Ghostty's padded grid origin and bounded terminal cell geometry"
        )

        XCTAssertTrue(
            handlesSource.contains("accessibilityLabel = endpoint == .start ? \"Selection start\" : \"Selection end\"")
                && handlesSource.contains("accessibilityHint = \"Drag to adjust\"")
                && handlesSource.contains("override func accessibilityActivate()")
                && handlesSource.contains("func nudgeSelectionEndpoint")
                && handlesSource.contains("candidateIndex <= fixedIndex")
                && handlesSource.contains("candidateIndex >= fixedIndex")
                && handlesSource.contains("Selection endpoint cannot move farther"),
            "Both endpoint handles must be labeled, offer a one-cell VoiceOver adjustment, and preserve endpoint ordering at boundaries"
        )
    }

    /// Regression coverage for runtime edges where touch selection previously
    /// leaked into mouse-reporting apps or left a synthetic button held after
    /// its surface detached. Pointer input must also invalidate touch overlays.
    func testDirectTouchSelectionCleansUpAndIsolatesInputPaths() throws {
        let viewSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView.swift"
        )
        let interactionSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+Interaction.swift"
        )
        let lifecycleSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+Lifecycle.swift"
        )
        let handlesSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/TerminalSelectionHandles.swift"
        )
        let surfaceSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Surface/TerminalSurface.swift"
        )
        let selectionContainsPatch = try readSourceFile(
            "scripts/ghostty-patches/0010-selection-contains.patch"
        )

        let longPressBody = try extractMethodBody(
            from: interactionSource,
            methodName: "func handleLongPressForSelection"
        )
        XCTAssertTrue(
            longPressBody.contains("touchSelectionIsMouseCaptured = surface.isMouseCaptured")
                && longPressBody.contains("if touchSelectionIsMouseCaptured")
                && longPressBody.contains("cancelTouchSelectionInteraction()")
                && handlesSource.contains("!surface.isMouseCaptured")
                && handlesSource.contains("guard surface?.isMouseCaptured != true else")
                && viewSource.contains("if surface?.isMouseCaptured == true")
                && interactionSource.contains("The long-press handler also owns the remote mouse")
                && interactionSource.contains("!touchSelectionIsMouseCaptured && surface.isMouseCaptured"),
            "Mouse capture must isolate new long presses and invalidate every stale host-selection interaction"
        )

        let cancelBody = try extractMethodBody(
            from: interactionSource,
            methodName: "func cancelTouchSelectionInteraction"
        )
        XCTAssertTrue(
            cancelBody.contains("releaseSyntheticSelectionButton()")
                && !cancelBody.contains("syntheticLeftButtonDown = false")
                && cancelBody.contains("touchSelectionIsMouseCaptured = false")
                && cancelBody.contains("selectionHandleMode = .none"),
            "Touch cancellation must release through the idempotent helper and clear all gesture ownership state"
        )

        let detachBody = try extractMethodBody(
            from: lifecycleSource,
            methodName: "override open func didMoveToWindow"
        )
        guard let cancelRange = detachBody.range(of: "cancelTouchSelectionInteraction()"),
              let freeRange = detachBody.range(of: "core.freeSurface()")
        else {
            return XCTFail("Detaching must cancel touch selection before freeing Ghostty")
        }
        XCTAssertLessThan(cancelRange.lowerBound, freeRange.lowerBound)

        let menuHitBody = try extractMethodBody(
            from: viewSource,
            methodName: "open func selectionMenuPoint"
        )
        XCTAssertTrue(
            menuHitBody.contains("if selectionHandlesVisible")
                && menuHitBody.contains("touchSelectionContains(point)")
                && viewSource.contains("point.x - geometry.origin.x")
                && viewSource.contains("point.y - geometry.origin.y")
                && viewSource.contains("surface.selectionContains(")
                && surfaceSource.contains("ghostty_surface_selection_contains(")
                && selectionContainsPatch.contains("surface.cursorPosToPixels(")
                && selectionContainsPatch.contains("selection.contains(screen, pin)"),
            "Expanded direct-touch selections must use Ghostty's tracked selection pins so the full visible range remains hittable after autoscroll clipping"
        )
        XCTAssertGreaterThanOrEqual(
            interactionSource.components(separatedBy: "dismissSelectionHandles()").count - 1,
            3,
            "New pointer selection and pointer scrolling must dismiss stale touch handles and edit menus"
        )
    }

    /// Regression: the floating iPad keyboard accessory can initially overlay
    /// the terminal before SwiftUI re-runs keyboard avoidance. The Ghostty
    /// surface must fit to the visible viewport, not raw view bounds, whenever
    /// the accessory or keyboard frame changes.
    func testKeyboardAccessoryRefreshRefitsTerminalViewport() throws {
        let terminalSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView.swift"
        )
        let lifecycleSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+Lifecycle.swift"
        )
        let inputAccessorySource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+InputAccessory.swift"
        )
        let textInputHandlerSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/TerminalTextInputHandler@UIKit.swift"
        )

        XCTAssertTrue(
            terminalSource.contains("let viewport = terminalViewportBounds"),
            "Ghostty viewSize must use the visible terminal viewport"
        )
        XCTAssertFalse(
            terminalSource.contains("return (bounds.width, bounds.height)"),
            "Ghostty viewSize must not keep using raw bounds that can sit under the accessory bar"
        )
        XCTAssertTrue(
            terminalSource.contains("var keyboardFrameEndScreenRect: CGRect?"),
            "UITerminalView must track the keyboard screen rect for viewport fitting"
        )
        XCTAssertTrue(
            terminalSource.contains("open var usesSystemInputAccessory"),
            "UITerminalView must let hosts suppress UIKit inputAccessoryView hosting"
        )
        XCTAssertTrue(
            inputAccessorySource.contains("usesSystemInputAccessory && !inputAccessoryItems.isEmpty"),
            "inputAccessoryView must honor usesSystemInputAccessory"
        )

        let refreshBody = try extractMethodBody(
            from: terminalSource,
            methodName: "open func refreshInputAccessoryViewport"
        )
        XCTAssertTrue(
            refreshBody.contains("refitViewportForKeyboardChange"),
            "refreshInputAccessoryViewport must refit Ghostty"
        )
        XCTAssertFalse(
            refreshBody.contains("reloadInputViews()"),
            "refreshInputAccessoryViewport must not reload UIKit input views during focus/typing"
        )

        let keyboardShowBody = try extractMethodBody(from: terminalSource, methodName: "func keyboardDidShow")
        XCTAssertTrue(
            keyboardShowBody.contains("keyboardScreenFrame(from: notification)")
                && keyboardShowBody.contains("refitViewportForKeyboardChange(reason: \"keyboard-show\")"),
            "keyboardDidShow must capture the keyboard frame and refit the viewport"
        )
        let keyboardHideBody = try extractMethodBody(from: terminalSource, methodName: "func keyboardDidHide")
        XCTAssertTrue(
            keyboardHideBody.contains("keyboardFrameEndScreenRect = nil")
                && keyboardHideBody.contains("refitViewportForKeyboardChange(reason: \"keyboard-hide\")"),
            "keyboardDidHide must restore the full viewport"
        )

        XCTAssertTrue(
            lifecycleSource.contains("var terminalViewportBounds"),
            "UITerminalView must expose a viewport rect for size and layer fitting"
        )
        XCTAssertTrue(
            lifecycleSource.contains("max(currentKeyboardOverlapHeight(), currentInputAccessoryOverlapHeight())"),
            "viewport fitting must include both keyboard notifications and the accessory's actual overlap"
        )
        XCTAssertTrue(
            lifecycleSource.contains("usesSystemInputAccessory"),
            "viewport fitting must ignore built-in accessory overlap when that accessory is suppressed"
        )
        XCTAssertTrue(
            lifecycleSource.contains("viewportOverlapHeight(withScreenRect"),
            "keyboard/accessory overlap should be computed from screen-coordinate intersections"
        )

        let updateFramesBody = try extractMethodBody(from: lifecycleSource, methodName: "func updateSublayerFrames")
        XCTAssertTrue(
            updateFramesBody.contains("let frame = terminalViewportBounds")
                && updateFramesBody.contains("sublayer.frame = frame"),
            "Ghostty layers must be framed to the visible viewport"
        )
        let enforceBody = try extractMethodBody(from: lifecycleSource, methodName: "func enforceSublayerScale")
        XCTAssertTrue(
            enforceBody.contains("let frame = terminalViewportBounds")
                && enforceBody.contains("sublayer.frame = frame"),
            "post-render layer enforcement must preserve the visible viewport frame"
        )
        let refitBody = try extractMethodBody(
            from: lifecycleSource,
            methodName: "func refitViewportForKeyboardChange"
        )
        XCTAssertTrue(
            refitBody.contains("core.fitToSize()")
                && refitBody.contains("DispatchQueue.main.async"),
            "keyboard/accessory changes must fit immediately and after UIKit lays out the accessory"
        )
        let becomeBody = try extractMethodBody(
            from: lifecycleSource,
            methodName: "override open func becomeFirstResponder"
        )
        XCTAssertTrue(
            becomeBody.contains("refreshInputAccessoryViewport()"),
            "initial focus must refresh the accessory viewport without waiting for a manual toggle"
        )
        XCTAssertTrue(
            becomeBody.contains("guard result else { return false }"),
            "failed UIKit first-responder requests must not synthesize terminal focus callbacks"
        )
        let geometryBody = try extractMethodBody(
            from: textInputHandlerSource,
            methodName: "func notifyGeometryDidChange"
        )
        XCTAssertFalse(
            geometryBody.contains("reloadInputViews()"),
            "text geometry updates must not reload UIKit input views while typing"
        )

        for path in [
            "SSHApp/Views/GhosttyTerminalView.swift",
            "SSHApp/Views/TmuxPaneTerminal.swift",
        ] {
            let source = try readSourceFile(path)
            let focusBody = try extractMethodBody(from: source, methodName: "func terminalDidChangeFocus")
            XCTAssertTrue(
                focusBody.contains("refreshInputAccessoryViewport()"),
                "\(path) must use the Ghostty viewport refresh on first focus"
            )
            XCTAssertFalse(
                focusBody.contains("reloadInputViews()"),
                "\(path) must not return to a raw input-view reload that leaves Ghostty under the bar"
            )
        }
    }

    /// The app owns the iOS-only Ghostty wrapper and native binary build now;
    /// it must not resolve the previous remote binary package.
    func testGhosttyDependencyIsLocalPackage() throws {
        let project = try readSourceFile("SSHApp.xcodeproj/project.pbxproj")
        let package = try readSourceFile("Packages/SSHAppGhostty/Package.swift")

        XCTAssertTrue(project.contains("XCLocalSwiftPackageReference \"Packages/SSHAppGhostty\""))
        XCTAssertTrue(project.contains("relativePath = Packages/SSHAppGhostty"))
        XCTAssertTrue(project.contains("Build Ghostty"))
        XCTAssertFalse(project.contains("https://github.com/Lakr233/libghostty-spm"))

        XCTAssertTrue(package.contains("name: \"SSHAppGhostty\""))
        XCTAssertTrue(package.contains(".iOS(.v18)"))
        XCTAssertTrue(package.contains("path: \"../../Frameworks/GhosttyKit.xcframework\""))
        XCTAssertFalse(package.contains(".macOS") || package.contains(".macCatalyst"))
    }

    /// Regression: the software keyboard asks the terminal view for UIKit caret
    /// geometry. Ghostty already renders the terminal cursor, so UIKit's caret
    /// must stay hidden during normal input to avoid a second block cursor over
    /// the final glyph. Preserve the upstream caret geometry for IME marked text.
    func testSoftwareKeyboardHidesUIKitCaretOutsideMarkedText() throws {
        let source = try readSourceFile("SSHApp/Views/TerminalTabShortcut.swift")
        let caretBody = try extractMethodBody(from: source, methodName: "override func caretRect")

        XCTAssertTrue(
            caretBody.contains("markedTextRange == nil"),
            "ShortcutAwareTerminalView must only suppress UIKit's caret when no marked text is active"
        )
        XCTAssertTrue(
            caretBody.contains("super.caretRect(for: position)"),
            "IME marked text must keep GhosttyTerminal's caret geometry"
        )
        XCTAssertTrue(
            caretBody.contains("return .zero"),
            "Normal software-keyboard input must hide UIKit's duplicate caret"
        )
    }

    func testHostTabFocusGatesTerminalShortcutsAndFirstResponder() throws {
        let mainSource = try readSourceFile("SSHApp/Views/MainView.swift")
        let ghosttySource = try readSourceFile("SSHApp/Views/GhosttyTerminalView.swift")

        XCTAssertTrue(
            mainSource.contains("isHostTabActive: isSelected"),
            "MainView must pass selected host-tab state into each TerminalTab"
        )
        XCTAssertTrue(
            mainSource.contains(".allowsHitTesting(isSelected)"),
            "inactive host tabs must not receive gestures"
        )
        XCTAssertTrue(
            mainSource.contains(".accessibilityHidden(!isSelected)"),
            "inactive host tabs must be hidden from accessibility"
        )
        XCTAssertTrue(
            ghosttySource.contains("isHostTabActive ? [.hostTabs] : []"),
            "non-tmux terminal shortcuts must be enabled only for the active host tab"
        )
        XCTAssertTrue(
            ghosttySource.contains("terminalView?.resignFirstResponderForApplicationAction()"),
            "inactive host tabs must mark app-driven resignation to avoid hidden terminal input"
        )
        XCTAssertTrue(
            ghosttySource.contains("guard surfaceAttached, isHostTabActive, !hasRequestedInitialFirstResponder"),
            "non-tmux first-responder claiming must be gated by active host-tab state"
        )
    }

    @MainActor
    func testPreOpenResizeSeedsUnmeasuredTabGridSize() {
        let tab = Tab(title: "shell", connectionState: .connected)
        let coordinator = GhosttyTerminalView.Coordinator()
        coordinator.updateTab(tab)

        coordinator.handleResize(cols: 118, rows: 30)

        XCTAssertEqual(tab.terminalGridSize, TerminalGridSize(cols: 118, rows: 30))
    }

    @MainActor
    func testPreOpenResizeCanCorrectInitiallyMeasuredTabGridSize() {
        let tab = Tab(title: "shell", connectionState: .connected)
        let coordinator = GhosttyTerminalView.Coordinator()
        coordinator.updateTab(tab)

        coordinator.handleResize(cols: 41, rows: 14)
        coordinator.handleResize(cols: 108, rows: 60)

        XCTAssertEqual(tab.terminalGridSize, TerminalGridSize(cols: 108, rows: 60))
    }

    @MainActor
    func testPreOpenResizeDoesNotOverwriteInheritedTabGridSize() {
        let inheritedGridSize = TerminalGridSize(cols: 144, rows: 44)
        let tab = Tab(
            title: "shell",
            connectionState: .connected,
            terminalGridSize: inheritedGridSize
        )
        let coordinator = GhosttyTerminalView.Coordinator()
        coordinator.updateTab(tab)

        coordinator.handleResize(cols: 41, rows: 14)

        XCTAssertEqual(tab.terminalGridSize, inheritedGridSize)
    }

    func testInitialShellOpenWaitsForSettledTerminalGrid() throws {
        let source = try readSourceFile("SSHApp/Views/GhosttyTerminalView.swift")
        let gateSource = try readSourceFile("SSHApp/Views/TerminalViewportReadinessGate.swift")
        let handleResizeBody = try extractMethodBody(from: source, methodName: "func handleResize")
        let beginBody = try extractMethodBody(from: source, methodName: "private func beginViewportSettle")
        let signalBody = try extractMethodBody(
            from: source,
            methodName: "private func signalTerminalReadyAndOpenChannelIfNeeded"
        )
        let openBody = try extractMethodBody(from: source, methodName: "func openChannelIfReady")

        XCTAssertTrue(
            source.contains("if Thread.isMainThread")
                && source.contains("coordinator?.handleResize"),
            "main-thread Ghostty resize callbacks must update the coordinator synchronously so fitToSize has current grid data"
        )
        XCTAssertTrue(
            handleResizeBody.contains("viewportReadiness.measurementDidChange()"),
            "each measured grid must advance shared viewport readiness"
        )
        XCTAssertTrue(
            beginBody.contains("viewportReadiness.begin")
                && beginBody.contains("terminalView?.fitToSize()")
                && gateSource.contains("generationAfterFirstFit")
                && gateSource.contains("measurementGeneration == generationAfterFirstFit"),
            "readiness must wait for a measured grid to survive two deferred viewport fits"
        )
        XCTAssertTrue(
            signalBody.contains("resumeOutputDeliveries")
                && signalBody.contains("session?.signalTerminalReady()")
                && signalBody.contains("openChannelIfReady()"),
            "the settled-grid path must release buffered output, unblock auth, and open a shell if needed"
        )
        XCTAssertTrue(
            openBody.contains("terminalReadySignaled"),
            "openChannelIfReady must not send the initial PTY request before terminal readiness has settled"
        )
        XCTAssertTrue(
            openBody.contains("let openingOutputDelivery = sessionOutputDelivery")
                && openBody.contains("terminalOutputDelivery: openingOutputDelivery"),
            "the initial shell must inherit the session queue so status text cannot be overtaken by its prompt"
        )
        XCTAssertTrue(
            openBody.contains("sessionOutputDelivery === openingOutputDelivery")
                && openBody.contains("sessionOutputDelivery = replacementDelivery"),
            "after adoption, the coordinator must relinquish direct access to the channel-owned queue"
        )
        let publishRange = try XCTUnwrap(openBody.range(of: "tab.channel = openedChannel"))
        let relinquishRange = try XCTUnwrap(
            openBody.range(of: "sessionOutputDelivery = replacementDelivery")
        )
        let transportTaskRange = try XCTUnwrap(openBody.range(of: "Task { @MainActor in"))
        XCTAssertLessThan(
            openBody.distance(from: openBody.startIndex, to: publishRange.lowerBound),
            openBody.distance(from: openBody.startIndex, to: transportTaskRange.lowerBound)
        )
        XCTAssertLessThan(
            openBody.distance(from: openBody.startIndex, to: relinquishRange.lowerBound),
            openBody.distance(from: openBody.startIndex, to: transportTaskRange.lowerBound),
            "queue transfer must finish before the transport open can suspend"
        )
    }

    func testSharedTerminalInheritsSourceTabGridSize() throws {
        let mainSource = try readSourceFile("SSHApp/Views/MainView.swift")
        let tabSource = try readSourceFile("SSHApp/Models/Tab.swift")
        let ghosttySource = try readSourceFile("SSHApp/Views/GhosttyTerminalView.swift")
        let sharedBody = try extractMethodBody(from: mainSource, methodName: "private func openSharedChannelInNewTab")
        let openBody = try extractMethodBody(from: ghosttySource, methodName: "func openChannelIfReady")

        XCTAssertTrue(
            tabSource.contains("var currentTerminalGridSize: TerminalGridSize?"),
            "Tab must expose the latest measured terminal grid for sibling tabs"
        )
        XCTAssertTrue(
            mainSource.contains("openSharedChannelInNewTab(from: selectedTab")
                && mainSource.contains("openSharedChannelInNewTab(from: tab"),
            "Shared terminals must pass the source tab that owns the current viewport"
        )
        XCTAssertTrue(
            sharedBody.contains("terminalGridSize: sourceTab.currentTerminalGridSize"),
            "New shared tabs must inherit the source tab's terminal grid before their shell channel opens"
        )
        XCTAssertTrue(
            openBody.contains("let openingGridSize = tab.terminalGridSize ?? lastGridSize")
                && openBody.contains("cols: openingGridSize.cols")
                && openBody.contains("rows: openingGridSize.rows"),
            "GhosttyTerminalView must use the inherited grid for the initial PTY request"
        )
    }

    // MARK: - Configuration

    /// The shared terminal config keeps a non-blinking block cursor (parity with
    /// the SwiftTerm-era steady block).
    func testTerminalConfigUsesSteadyBlockCursor() throws {
        let source = try readSourceFile("SSHApp/Theme/TerminalRuntime.swift")
        XCTAssertTrue(
            source.contains("withCursorStyle(.block)"),
            "TerminalRuntime must configure a block cursor"
        )
        XCTAssertTrue(
            source.contains("withCursorStyleBlink(false)"),
            "TerminalRuntime must make the cursor steady (non-blinking)"
        )
    }

    /// Regression: physical-device software-keyboard text must not go through
    /// Ghostty's surface text path. If UIKit reports a simple Latin key tap as
    /// marked text, commit it through the same direct in-memory input route
    /// while preserving upstream marked-text handling for real IME composition.
    func testSoftwareKeyboardCommitsPlainMarkedTextWithoutPreedit() throws {
        let source = try readSourceFile("SSHApp/Views/TerminalTabShortcut.swift")
        let setMarkedBody = try extractMethodBody(from: source, methodName: "override func setMarkedText")
        let helperBody = try extractMethodBody(
            from: source,
            methodName: "private static func shouldCommitMarkedTextDirectly"
        )

        XCTAssertTrue(
            setMarkedBody.contains("Self.shouldCommitMarkedTextDirectly"),
            "ShortcutAwareTerminalView must identify plain software-keyboard marked text"
        )
        XCTAssertTrue(
            setMarkedBody.contains("sendSoftwareKeyboardTextDirectly(markedText)"),
            "Plain marked text must use the direct in-memory route instead of becoming Ghostty preedit"
        )
        XCTAssertTrue(
            setMarkedBody.contains("super.setMarkedText(markedText, selectedRange: selectedRange)"),
            "Non-plain marked text must preserve GhosttyTerminal's IME path"
        )
        XCTAssertTrue(
            setMarkedBody.contains("super.insertText(markedText)"),
            "Non-in-memory fallback must still commit plain marked text through GhosttyTerminal"
        )
        XCTAssertTrue(
            helperBody.contains("text.count == 1"),
            "Only single-character key taps should bypass marked-text handling"
        )
        XCTAssertTrue(
            helperBody.contains("selectedRange.location == text.count"),
            "The bypass must only apply to collapsed selections at the end of the marked text"
        )
        XCTAssertTrue(
            helperBody.contains("(0x20 ... 0x7E).contains(scalar.value)"),
            "Only printable ASCII should bypass marked-text handling"
        )
    }

    /// libghostty validates the base config before any host-managed surface is
    /// attached. Explicit inert command/working-directory values avoid simulator
    /// passwd/default-shell lookup warnings without launching a local shell for
    /// in-memory surfaces.
    func testTerminalConfigAvoidsPasswdDefaultLookups() throws {
        let source = try readSourceFile("SSHApp/Theme/TerminalRuntime.swift")

        XCTAssertTrue(
            source.contains("TerminalConfiguration(startingFrom: .default)"),
            "TerminalRuntime must preserve libghostty's default base config"
        )
        XCTAssertEqual(
            HostManagedTerminal.inertCommandName,
            "sshapp-host-managed-terminal",
            "TerminalRuntime must keep the inert command name stable for title filtering"
        )
        XCTAssertEqual(
            HostManagedTerminal.directCommand,
            "direct:sshapp-host-managed-terminal",
            "TerminalRuntime must keep Ghostty's direct command value stable"
        )
        XCTAssertTrue(
            source.contains("builder.withCustom(\"command\", HostManagedTerminal.directCommand)"),
            "TerminalRuntime must set an explicit inert command for host-managed surfaces"
        )
        XCTAssertTrue(
            source.contains("builder.withCustom(\"working-directory\", \"inherit\")"),
            "TerminalRuntime must not let Ghostty resolve a default home directory from passwd"
        )
        XCTAssertTrue(
            source.contains("configSource: .generated(Self.baseTerminalConfiguration.rendered)"),
            "TerminalRuntime must seed Ghostty with the explicit base config before per-session overrides"
        )
    }

    /// Terminal font defaults to the bundled JetBrains Mono files and remains
    /// user-selectable through persisted app settings.
    @MainActor
    func testTerminalConfigUsesPersistedJetBrainsMonoFontSettings() throws {
        let runtimeSource = try readSourceFile("SSHApp/Theme/TerminalRuntime.swift")
        let fontSource = try readSourceFile("SSHApp/Theme/TerminalFontSettings.swift")
        let infoPlist = try readSourceFile("SSHApp/Info.plist")

        XCTAssertEqual(TerminalFontFamily.defaultChoice, .jetBrainsMono)
        let expectedDefault: Double =
            UIDevice.current.userInterfaceIdiom == .pad ? 12 : 8
        XCTAssertEqual(TerminalFontSize.defaultValue, expectedDefault)
        XCTAssertEqual(TerminalFontSize.range.lowerBound, 2)
        XCTAssertEqual(TerminalFontSize.range.upperBound, 48)
        XCTAssertEqual(AppSettingsKey.terminalFontFamily, "terminal.fontFamily")
        XCTAssertEqual(AppSettingsKey.terminalFontSize, "terminal.fontSize")

        XCTAssertTrue(
            fontSource.contains("case jetBrainsMono = \"JetBrains Mono\""),
            "JetBrains Mono must be a selectable terminal font family"
        )
        XCTAssertTrue(
            runtimeSource.contains("TerminalFontRegistrar.registerBundledFonts()"),
            "TerminalRuntime must register bundled font files before Ghostty config loads"
        )
        XCTAssertTrue(
            runtimeSource.contains("builder.withFontFamily(fontFamily.ghosttyFontFamily)"),
            "TerminalRuntime must apply the selected font family to Ghostty"
        )
        XCTAssertTrue(
            runtimeSource.contains("builder.withFontSize(Float(TerminalFontSize.clamped(fontSize)))"),
            "TerminalRuntime must apply the selected font size to Ghostty"
        )
        XCTAssertTrue(
            runtimeSource.contains("controller.setTerminalConfiguration"),
            "Font changes must re-apply terminal configuration live"
        )

        for fontFile in [
            "JetBrainsMono-Regular.ttf",
            "JetBrainsMono-Bold.ttf",
            "JetBrainsMono-Italic.ttf",
            "JetBrainsMono-BoldItalic.ttf",
        ] {
            let url = projectRoot()
                .appendingPathComponent("SSHApp/Fonts")
                .appendingPathComponent(fontFile)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: url.path),
                "\(fontFile) must be bundled with the app"
            )
            XCTAssertTrue(
                infoPlist.contains(fontFile),
                "\(fontFile) must be declared in UIAppFonts"
            )
        }
    }

    func testInfoPlistDeclaresFaceIDUsageDescription() throws {
        let infoPlist = try readSourceFile("SSHApp/Info.plist")

        XCTAssertTrue(
            infoPlist.contains("NSFaceIDUsageDescription"),
            "Face ID use must have an Info.plist usage description"
        )
        XCTAssertTrue(
            infoPlist.contains("protect saved SSH passwords and keys"),
            "The Face ID usage string must explain stored credential protection"
        )
    }

    /// One shared TerminalController backs every surface so theme/appearance
    /// changes apply everywhere at once.
    func testTerminalViewsUseSharedController() throws {
        for path in [
            "SSHApp/Views/GhosttyTerminalView.swift",
            "SSHApp/Views/TmuxPaneTerminal.swift",
        ] {
            let source = try readSourceFile(path)
            XCTAssertTrue(
                source.contains("TerminalRuntime.shared.controller"),
                "\(path) must attach the shared TerminalController"
            )
        }
    }

    // MARK: - Helpers

    private func extractMethodBody(from source: String, methodName: String) throws -> String {
        guard let methodRange = source.range(of: methodName) else {
            throw NSError(domain: "Test", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Method '\(methodName)' not found"])
        }

        let afterMethod = source[methodRange.upperBound...]
        guard let braceStart = afterMethod.firstIndex(of: "{") else {
            throw NSError(domain: "Test", code: 2,
                         userInfo: [NSLocalizedDescriptionKey: "No opening brace for '\(methodName)'"])
        }

        var depth = 0
        var braceEnd: String.Index?
        var index = braceStart

        while index < afterMethod.endIndex {
            let char = afterMethod[index]
            if char == "{" { depth += 1 }
            if char == "}" {
                depth -= 1
                if depth == 0 {
                    braceEnd = index
                    break
                }
            }
            index = afterMethod.index(after: index)
        }

        guard let end = braceEnd else {
            throw NSError(domain: "Test", code: 3,
                         userInfo: [NSLocalizedDescriptionKey: "No matching brace for '\(methodName)'"])
        }

        return String(afterMethod[braceStart...end])
    }
}
