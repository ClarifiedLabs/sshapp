import XCTest
import SwiftUI
import UIKit
@testable import SSHApp

/// Regression tests for the libghostty terminal integration and SSH data-flow
/// invariants.
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
    /// `receive` is thread-safe).
    func testOnDataReceivedFeedsSessionReceive() throws {
        let source = try readSourceFile("SSHApp/Views/GhosttyTerminalView.swift")

        guard let range = source.range(of: "session.onDataReceived") else {
            XCTFail("Could not find session.onDataReceived in GhosttyTerminalView.swift")
            return
        }
        let afterAssignment = String(source[range.lowerBound...])
        let snippet = afterAssignment.components(separatedBy: "\n").prefix(12).joined(separator: "\n")

        XCTAssertTrue(
            snippet.contains("receive("),
            "onDataReceived must feed the in-memory session via receive(_:)"
        )
        XCTAssertFalse(
            snippet.contains("DispatchQueue.main.async"),
            "onDataReceived must NOT re-dispatch to main — SSH2Transport already does, and receive(_:) is thread-safe"
        )
    }

    /// The write/resize callbacks may fire off-main and must hop to the main
    /// queue (FIFO-ordered, never synchronously re-entering `receive`).
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
        let tab = Tab(title: "mini-m4.awb", connectionState: .awaitingInput)
        let coordinator = GhosttyTerminalView.Coordinator()
        coordinator.tab = tab

        coordinator.terminalDidChangeTitle(HostManagedTerminal.inertCommandName)

        XCTAssertEqual(tab.title, "mini-m4.awb")

        coordinator.terminalDidChangeTitle("mini-m4.awb:~")

        XCTAssertEqual(tab.title, "mini-m4.awb:~")
    }

    // MARK: - Surface lifecycle / attach-race

    /// The ghostty surface is created asynchronously; terminal-ready must be
    /// signaled when the surface attaches, NOT synchronously in makeUIView, so
    /// the gated auth flow's status text lands on a live surface.
    func testTerminalReadySignaledOnSurfaceAttach() throws {
        let source = try readSourceFile("SSHApp/Views/GhosttyTerminalView.swift")

        let makeBody = try extractMethodBody(from: source, methodName: "func makeUIView")
        XCTAssertFalse(
            makeBody.contains("signalTerminalReady"),
            "makeUIView must NOT signal terminal ready — the surface is not attached yet"
        )

        let attachBody = try extractMethodBody(from: source, methodName: "func terminalDidAttachSurface")
        XCTAssertTrue(
            attachBody.contains("signalTerminalReady"),
            "terminalDidAttachSurface must signal terminal ready once the surface exists"
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
            longPressBody.contains("showSelectionCopyMenu"),
            "Direct terminal selection should surface the Copy menu on release"
        )
        XCTAssertFalse(
            interactionSource.contains("TerminalSurfaceTextSelectionRequestDelegate")
                || interactionSource.contains("readViewportText()")
                || interactionSource.contains("terminalDidRequestTextSelection"),
            "The local terminal package must not use the snapshot selection-sheet API"
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
            ghosttySource.contains("terminalView?.resignFirstResponder()"),
            "inactive host tabs must resign first responder to avoid hidden terminal input"
        )
        XCTAssertTrue(
            ghosttySource.contains("guard surfaceAttached, isHostTabActive, !hasRequestedInitialFirstResponder"),
            "non-tmux first-responder claiming must be gated by active host-tab state"
        )
    }

    /// Regression: the terminal must open a shell channel after authentication
    /// once the ghostty surface is attached. Shell state now lives on
    /// `SSHChannel`, not on the authenticated `SSHSession`.
    func testTerminalOpensShellChannelAfterAuthentication() throws {
        let viewSource = try readSourceFile("SSHApp/Views/GhosttyTerminalView.swift")
        let openBody = try extractMethodBody(from: viewSource, methodName: "func openChannelIfReady")

        XCTAssertTrue(
            openBody.contains("session.isAuthenticated"),
            "GhosttyTerminalView must wait for authentication before opening a shell channel"
        )
        XCTAssertTrue(
            openBody.contains("tab.channel == nil"),
            "GhosttyTerminalView must create only one SSHChannel per terminal tab"
        )
        XCTAssertTrue(
            openBody.contains("session.openShellChannel"),
            "GhosttyTerminalView must open a shell through SSHSession.openShellChannel"
        )
        XCTAssertTrue(
            openBody.contains("tab.channel = openedChannel"),
            "the opened SSHChannel must be attached to the tab"
        )

        let sessionSource = try readSourceFile("SSHApp/SSH/SSHSession.swift")
        XCTAssertFalse(
            sessionSource.contains("var onAuthenticated:"),
            "SSHSession must not use a global authentication callback to open one shell"
        )
    }

    @MainActor
    func testPreOpenResizeSeedsUnmeasuredTabGridSize() {
        let tab = Tab(title: "shell", connectionState: .connected)
        let coordinator = GhosttyTerminalView.Coordinator()
        coordinator.tab = tab

        coordinator.handleResize(cols: 118, rows: 30)

        XCTAssertEqual(tab.terminalGridSize, TerminalGridSize(cols: 118, rows: 30))
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
        coordinator.tab = tab

        coordinator.handleResize(cols: 41, rows: 14)

        XCTAssertEqual(tab.terminalGridSize, inheritedGridSize)
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

    func testAutoRunCommandDispatchesOnlyForInitialShellChannel() throws {
        let mainSource = try readSourceFile("SSHApp/Views/MainView.swift")
        let connectBody = try extractMethodBody(from: mainSource, methodName: "func connectSession")
        let sharedBody = try extractMethodBody(from: mainSource, methodName: "private func openSharedChannelInNewTab")
        let ghosttySource = try readSourceFile("SSHApp/Views/GhosttyTerminalView.swift")
        let openBody = try extractMethodBody(from: ghosttySource, methodName: "func openChannelIfReady")

        guard let pendingRange = connectBody.range(of: "tab.pendingAutoRunCommand = connection.pendingAutoRunCommand"),
              let authenticateRange = connectBody.range(of: "session.connectAndAuthenticate") else {
            XCTFail("connectSession must snapshot the pending startup command before authentication begins")
            return
        }
        XCTAssertLessThan(
            pendingRange.lowerBound,
            authenticateRange.lowerBound,
            "The pending auto-run command must be attached to the initial tab before connectAndAuthenticate can report .connected"
        )
        XCTAssertFalse(
            sharedBody.contains("pendingAutoRunCommand"),
            "Shared terminals opened on an existing SSHSession must not receive a startup command"
        )

        guard let attachRange = openBody.range(of: "attachChannel(openedChannel)"),
              let consumeRange = openBody.range(of: "tab.consumePendingAutoRunCommand()"),
              let writeRange = openBody.range(of: "openedChannel.writeTerminalCommand(command)") else {
            XCTFail("openChannelIfReady must consume and send the pending startup command")
            return
        }
        XCTAssertLessThan(
            attachRange.lowerBound,
            consumeRange.lowerBound,
            "The command should be sent only after the channel is attached to the terminal sink"
        )
        XCTAssertLessThan(
            consumeRange.lowerBound,
            writeRange.lowerBound,
            "The consumed command must be sent through SSHChannel.writeTerminalCommand"
        )
    }

    func testSSHChannelWriteTerminalCommandNormalizesSubmittedCommand() throws {
        let source = try readSourceFile("SSHApp/SSH/SSHChannel.swift")
        let body = try extractMethodBody(from: source, methodName: "func writeTerminalCommand")

        XCTAssertTrue(
            source.contains("func writeTerminalCommand(_ command: String) async throws"),
            "SSHChannel must expose a helper for terminal-style command submission"
        )
        XCTAssertTrue(
            body.contains("command.trimmingCharacters(in: .whitespacesAndNewlines)")
                && body.contains("guard !trimmed.isEmpty else { return }"),
            "Blank startup commands must not send an empty line"
        )
        XCTAssertTrue(
            body.contains(#".replacingOccurrences(of: "\r\n", with: "\r")"#)
                && body.contains(#".replacingOccurrences(of: "\n", with: "\r")"#),
            "Multiline commands must normalize terminal input line endings to carriage returns"
        )
        XCTAssertTrue(
            body.contains(#"if !normalized.hasSuffix("\r")"#)
                && body.contains(#"normalized.append("\r")"#),
            "The helper must append a final carriage return to submit the command"
        )
        XCTAssertTrue(
            body.contains("try await write(data)"),
            "The helper must write through SSHChannel.write so it targets this channel"
        )
    }

    func testSSHChannelConsumesOrderedTmuxDecoderLifecycleEvents() throws {
        let source = try readSourceFile("SSHApp/SSH/SSHChannel.swift")
        let processBody = try extractMethodBody(from: source, methodName: "private func processIncomingBytes")
        let enqueueBody = try extractMethodBody(from: source, methodName: "private func enqueueTmuxLine")
        let startBody = try extractMethodBody(from: source, methodName: "private func startTmuxControlMode")
        let readyBody = try extractMethodBody(
            from: source,
            methodName: "private func startTmuxAttachBootstrapIfReady"
        )
        let bootstrapBody = try extractMethodBody(from: source, methodName: "private func startTmuxAttachBootstrap()")
        let finishBody = try extractMethodBody(from: source, methodName: "private func finishDecodedTmuxControlMode")
        let clearBody = try extractMethodBody(from: source, methodName: "private func clearTmuxControlModeReferences")

        XCTAssertTrue(
            processBody.contains("tmuxLineDecoder.feedEvents(data)"),
            "SSHChannel must consume ordered decoder events so DCS end/start pairs in one SSH read are not collapsed"
        )
        XCTAssertFalse(
            processBody.contains("wasHooked") || processBody.contains("nowHooked"),
            "SSHChannel must not infer tmux lifecycle from only the final decoder hook state"
        )
        XCTAssertTrue(
            processBody.contains("case .controlModeStarted:")
                && processBody.contains("startTmuxControlMode()"),
            "DCS start events must create a tmux controller at the decoded boundary"
        )
        XCTAssertTrue(
            processBody.contains("case .controlModeEnded:")
                && processBody.contains("finishDecodedTmuxControlMode()"),
            "DCS end events must clear the failed controller before a later DCS start in the same read"
        )
        XCTAssertTrue(
            processBody.contains("startTmuxAttachBootstrapIfReady(for: lineBytes)"),
            "tmux bootstrap should inspect decoded lines before starting metadata probes"
        )
        XCTAssertTrue(
            finishBody.contains("let deliveryTask = tmuxLineDeliveryTask")
                && finishBody.contains("_ = clearTmuxControlModeReferences()")
                && finishBody.contains("releaseRetainedTmuxController(after: deliveryTask)"),
            "Decoded tmux exits should clear current controller references while retaining the controller until queued lines drain"
        )
        XCTAssertFalse(
            finishBody.contains("shutdown"),
            "Decoded tmux exits already include a %exit line; clearing references must not race queued line delivery"
        )
        XCTAssertTrue(
            source.contains("private var tmuxAttachTask: Task<Void, Never>?")
                && source.contains("private var tmuxAttachFallbackTask: Task<Void, Never>?"),
            "SSHChannel must own the tmux bootstrap tasks so a failed first DCS can cancel them before fallback attach"
        )
        XCTAssertTrue(
            source.contains("private var tmuxGatewaySetupTask: Task<Void, Never>?"),
            "SSHChannel must track delegate setup before feeding tmux lines"
        )
        XCTAssertTrue(
            startBody.contains("tmuxGatewaySetupTask?.cancel()")
                && startBody.contains("tmuxGatewaySetupTask = Task")
                && startBody.contains("await gateway.setDelegate(controller)"),
            "DCS start should create the gateway and install its delegate without starting metadata probes yet"
        )
        XCTAssertTrue(
            source.contains("setupTask: Task<Void, Never>?")
                && enqueueBody.contains("await setupTask?.value"),
            "tmux protocol lines should wait for gateway delegate setup before delivery"
        )
        XCTAssertTrue(
            readyBody.contains("guard tmuxAttachTask == nil else { return }")
                && readyBody.contains("TmuxLineParser.parseLine(lineBytes)")
                && readyBody.contains("case .sessionChanged")
                && readyBody.contains("scheduleTmuxAttachBootstrapFallbackIfNeeded()"),
            "tmux metadata probes should prefer session-changed but fall back if tmux never emits one"
        )
        XCTAssertTrue(
            bootstrapBody.contains("tmuxAttachTask == nil")
                && bootstrapBody.contains("await setupTask?.value")
                && bootstrapBody.contains("guard !Task.isCancelled else { return }")
                && bootstrapBody.contains("await controller.attach"),
            "tmux attach bootstrap must be single-shot, delegate-ordered, and cancellation-aware"
        )
        XCTAssertTrue(
            clearBody.contains("tmuxAttachTask?.cancel()")
                && clearBody.contains("tmuxAttachTask = nil")
                && clearBody.contains("tmuxAttachFallbackTask?.cancel()")
                && clearBody.contains("tmuxAttachFallbackTask = nil")
                && clearBody.contains("tmuxGatewaySetupTask?.cancel()")
                && clearBody.contains("tmuxGatewaySetupTask = nil"),
            "Clearing a failed tmux controller must cancel its pending bootstrap probes"
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

    // MARK: - Keyboard bar

    /// iOS 26's UIKit `inputAccessoryView` host can spam unsatisfiable remote
    /// keyboard placeholder constraints. SSHApp must render its keyboard bar in
    /// SwiftUI while suppressing libghostty's UIKit input accessory.
    func testUsesHostKeyboardBarInsteadOfUIKitInputAccessory() throws {
        let tabSource = try readSourceFile("SSHApp/Views/TerminalTab.swift")
        let barSource = try readSourceFile("SSHApp/Views/TerminalKeyboardBar.swift")
        let publicStickySource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+PublicSticky.swift"
        )

        XCTAssertTrue(
            tabSource.contains(".safeAreaInset(edge: .bottom")
                && tabSource.contains("TerminalKeyboardBar(target: keyboardBarTarget)"),
            "TerminalTab must reserve bottom space with the SwiftUI keyboard bar"
        )
        XCTAssertTrue(
            barSource.contains("TerminalInputAccessoryItem.defaultItems")
                && barSource.contains("target.perform(item)"),
            "TerminalKeyboardBar must render the standard accessory items and dispatch through the active target"
        )
        XCTAssertTrue(
            publicStickySource.contains("public func performInputAccessoryItem")
                && publicStickySource.contains("handleInputBarKey")
                && publicStickySource.contains("toggleStickyModifier"),
            "GhosttyTerminal must expose a public host-bar dispatch API that reuses the bundled accessory key path"
        )

        for path in [
            "SSHApp/Views/GhosttyTerminalView.swift",
            "SSHApp/Views/TmuxPaneTerminal.swift",
        ] {
            let source = try readSourceFile(path)
            let applyBody = try extractMethodBody(from: source, methodName: "func applyAccessory")
            XCTAssertTrue(
                applyBody.contains("tv.usesSystemInputAccessory = false"),
                "\(path) must suppress UIKit inputAccessoryView hosting"
            )
            XCTAssertFalse(
                applyBody.contains("TerminalInputAccessoryItem.defaultItems"),
                "\(path) must not enable libghostty's built-in UIKit input accessory"
            )
        }
    }

    /// The `showsKeyboardBar` toggle must gate the host SwiftUI bar, not
    /// libghostty's UIKit inputAccessoryView.
    func testKeyboardBarToggleGatesHostBar() throws {
        let source = try readSourceFile("SSHApp/Views/TerminalTab.swift")
        XCTAssertTrue(
            source.contains("private var shouldShowKeyboardBar")
                && source.contains("guard showsKeyboardBar, isHostTabActive else { return false }"),
            "TerminalTab must use showsKeyboardBar to show/hide the host keyboard bar"
        )
    }

    /// Regression: on first load the terminal viewport did not account for the
    /// keyboard bar until the user manually toggled it. The first time a surface
    /// becomes first responder it must refresh Ghostty's visible viewport.
    /// The refresh must hang off the focus delegate, be deferred a runloop, and
    /// fire only once per view instance (no flicker on later focus/blur).
    func testInitialFocusRefreshesInputAccessoryViewportForKeyboardAvoidance() throws {
        for path in [
            "SSHApp/Views/GhosttyTerminalView.swift",
            "SSHApp/Views/TmuxPaneTerminal.swift",
        ] {
            let source = try readSourceFile(path)

            XCTAssertTrue(
                source.contains("TerminalSurfaceFocusDelegate"),
                "\(path) must observe focus via TerminalSurfaceFocusDelegate to fix first-load keyboard avoidance"
            )
            XCTAssertTrue(
                source.contains("hasPerformedInitialFocusReload"),
                "\(path): the once-only focus reload needs a per-coordinator latch"
            )

            let focusBody = try extractMethodBody(
                from: source,
                methodName: "func terminalDidChangeFocus"
            )
            XCTAssertTrue(
                focusBody.contains("hasPerformedInitialFocusReload"),
                "\(path): terminalDidChangeFocus must gate the reload so it fires only once per view instance"
            )
            XCTAssertTrue(
                focusBody.contains("DispatchQueue.main.async"),
                "\(path): the refresh must be deferred a runloop so layout has settled before Ghostty refits"
            )
            XCTAssertTrue(
                focusBody.contains("refreshInputAccessoryViewport()"),
                "\(path): terminalDidChangeFocus must refresh the accessory viewport on first focus"
            )
        }
    }

    // MARK: - Theme picker

    /// Terminal theme selections persist to UserDefaults under the dedicated keys.
    func testThemeSelectionPersists() throws {
        let source = try readSourceFile("SSHApp/Theme/TerminalRuntime.swift")
        let selectBody = try extractMethodBody(from: source, methodName: "func selectTheme")
        XCTAssertTrue(
            selectBody.contains("UserDefaults.standard.set"),
            "selectTheme must persist the chosen theme"
        )
        XCTAssertTrue(
            selectBody.contains("controller.setTheme"),
            "selectTheme must re-apply the theme to the shared controller (live update)"
        )
        XCTAssertEqual(AppSettingsKey.terminalLightTheme, "terminal.lightTheme")
        XCTAssertEqual(AppSettingsKey.terminalDarkTheme, "terminal.darkTheme")
    }

    /// Settings exposes separate font and theme destinations.
    func testSettingsExposesFontAndThemePickers() throws {
        let source = try readSourceFile("SSHApp/Views/MainView.swift")
        XCTAssertTrue(
            source.contains("ThemeSettingsView()"),
            "Settings must offer the theme picker"
        )
        XCTAssertTrue(
            source.contains("FontSettingsView()"),
            "Settings must offer the font settings"
        )
    }

    func testTerminalViewsApplyHardwareKeyRepeatConfiguration() throws {
        let tabSource = try readSourceFile("SSHApp/Views/TerminalTab.swift")
        XCTAssertTrue(tabSource.contains("AppSettingsKey.terminalKeyRepeatEnabled"))
        XCTAssertTrue(tabSource.contains("AppSettingsKey.terminalKeyRepeatDelayMilliseconds"))
        XCTAssertTrue(tabSource.contains("AppSettingsKey.terminalKeyRepeatIntervalMilliseconds"))
        XCTAssertTrue(tabSource.contains("TerminalHardwareKeyRepeatConfiguration("))
        XCTAssertTrue(tabSource.contains("hardwareKeyRepeatConfiguration: hardwareKeyRepeatConfiguration"))

        for path in [
            "SSHApp/Views/GhosttyTerminalView.swift",
            "SSHApp/Views/TmuxPaneTerminal.swift",
        ] {
            let source = try readSourceFile(path)
            let makeBody = try extractMethodBody(from: source, methodName: "func makeUIView")
            let updateBody = try extractMethodBody(from: source, methodName: "func updateUIView")
            XCTAssertTrue(
                source.contains("var hardwareKeyRepeatConfiguration: TerminalHardwareKeyRepeatConfiguration"),
                "\(path) must accept the app's hardware key repeat configuration"
            )
            XCTAssertTrue(
                makeBody.contains("tv.hardwareKeyRepeatConfiguration = hardwareKeyRepeatConfiguration"),
                "\(path) must apply repeat config during view creation"
            )
            XCTAssertTrue(
                updateBody.contains("hardwareKeyRepeatConfiguration = hardwareKeyRepeatConfiguration"),
                "\(path) must apply repeat config during live SwiftUI updates"
            )
        }
    }

    func testSettingsSheetsUsePagePresentationSizing() throws {
        let source = try readSourceFile("SSHApp/Views/MainView.swift")
        let settingsSheetStart = try XCTUnwrap(source.range(of: "struct SettingsSheet"))
        let previewStart = try XCTUnwrap(
            source.range(of: "#Preview", range: settingsSheetStart.lowerBound..<source.endIndex)
        )
        let settingsSheet = String(source[settingsSheetStart.lowerBound..<previewStart.lowerBound])

        XCTAssertTrue(
            settingsSheet.contains(".presentationSizing(.page)"),
            "Settings destinations should use the larger page presentation when the device has room."
        )
    }

    /// The theme screen hosts a Light/Dark/System selector that persists an
    /// app-wide appearance override, applied at the window root.
    func testThemeScreenExposesAppearanceModeSelector() throws {
        let themeSource = try readSourceFile("SSHApp/Views/ThemeSettingsView.swift")
        XCTAssertTrue(
            themeSource.contains("AppSettingsKey.appearanceMode"),
            "Appearance mode selection must persist through AppStorage"
        )
        XCTAssertTrue(
            themeSource.contains("ForEach(AppearanceMode.allCases)"),
            "Theme screen must offer every appearance mode (system/light/dark)"
        )
        XCTAssertEqual(AppSettingsKey.appearanceMode, "appearance.mode")

        let settingsSource = try readSourceFile("SSHApp/Models/AppSettings.swift")
        XCTAssertTrue(
            settingsSource.contains("overrideUserInterfaceStyle"),
            "The appearance override must set the window-level UIKit style so sheets and hosted UIKit views follow"
        )
        let contentViewSource = try readSourceFile("SSHApp/Views/ContentView.swift")
        XCTAssertTrue(
            contentViewSource.contains("applyToWindows()"),
            "ContentView must apply the appearance override at launch and on change"
        )
    }

    /// `.system` must not force a scheme, so the OS keeps driving live
    /// light/dark switches; light/dark must map to their schemes.
    func testAppearanceModeMapsToColorScheme() {
        XCTAssertNil(AppearanceMode.system.colorScheme)
        XCTAssertEqual(AppearanceMode.light.colorScheme, .light)
        XCTAssertEqual(AppearanceMode.dark.colorScheme, .dark)
        XCTAssertEqual(AppearanceMode.resolve(nil), .system)
        XCTAssertEqual(AppearanceMode.resolve("garbage"), .system)
        XCTAssertEqual(AppearanceMode.resolve("dark"), .dark)
    }

    /// TerminalRuntime seeds the terminal color scheme from the persisted
    /// appearance override, since it initializes before any window exists.
    func testTerminalRuntimeSeedsFromPersistedAppearanceMode() throws {
        let source = try readSourceFile("SSHApp/Theme/TerminalRuntime.swift")
        XCTAssertTrue(
            source.contains("AppSettingsKey.appearanceMode"),
            "TerminalRuntime must honor the persisted appearance override when seeding"
        )
    }

    /// The theme screen shows the theme list directly (no nested navigation)
    /// and dropped the old header/footer copy.
    func testThemeScreenIsFlattened() throws {
        let source = try readSourceFile("SSHApp/Views/ThemeSettingsView.swift")
        XCTAssertFalse(
            source.contains("NavigationLink"),
            "Theme list must be inline, not behind a navigation hop"
        )
        XCTAssertFalse(
            source.contains("Terminal Theme"),
            "The 'Terminal Theme' header copy must be gone"
        )
        XCTAssertFalse(
            source.contains("Sets the terminal foreground"),
            "The explanatory footer copy must be gone"
        )
    }

    /// Theme picker lists can be filtered by typing part of a theme name.
    func testThemePickerSupportsTypeaheadSearch() throws {
        let source = try readSourceFile("SSHApp/Views/ThemeSettingsView.swift")
        XCTAssertTrue(
            source.contains("@State private var searchText"),
            "ThemeSettingsView must own local typeahead search text"
        )
        XCTAssertTrue(
            source.contains("filteredThemes"),
            "ThemeSettingsView must render a filtered theme collection"
        )
        XCTAssertTrue(
            source.contains("theme.name.range("),
            "Theme search must match visible theme names by substring"
        )
        XCTAssertTrue(
            source.contains(".caseInsensitive"),
            "Theme search must ignore case"
        )
        XCTAssertTrue(
            source.contains(".diacriticInsensitive"),
            "Theme search must ignore diacritics"
        )
        XCTAssertTrue(
            source.contains(".searchable("),
            "ThemeSettingsView must expose native SwiftUI search"
        )
        XCTAssertTrue(
            source.contains("ContentUnavailableView"),
            "ThemeSettingsView must show an empty state when search has no matches"
        )
    }

    /// The selected theme stays visible above the long catalog so users do not
    /// have to hunt for it after scrolling or filtering.
    func testThemePickerPinsCurrentThemeAboveLongCatalog() throws {
        let source = try readSourceFile("SSHApp/Views/ThemeSettingsView.swift")
        XCTAssertTrue(
            source.contains("private var selectedTheme"),
            "ThemeSettingsView must derive the active selected theme for the pinned current row"
        )
        XCTAssertTrue(
            source.contains("topControls(proxy: proxy)"),
            "ThemeSettingsView must pin the current theme alongside the appearance selector"
        )
        XCTAssertTrue(
            source.contains("currentThemeButton(proxy:"),
            "ThemeSettingsView must render a tappable current-theme row"
        )
        XCTAssertTrue(
            source.contains("\"Current\""),
            "The pinned row must label the selected theme as current"
        )
        XCTAssertTrue(
            source.contains("theme.currentTheme"),
            "The pinned current-theme row must have a stable accessibility identifier"
        )
        XCTAssertTrue(
            source.contains("checkmark.circle.fill"),
            "The pinned current-theme row must visually mark the selected theme"
        )
    }

    /// Tapping the pinned current theme clears any active search and locates the
    /// selected row in the full list.
    func testCurrentThemeButtonLocatesSelectedTheme() throws {
        let source = try readSourceFile("SSHApp/Views/ThemeSettingsView.swift")
        let locateBody = try extractMethodBody(from: source, methodName: "private func locateSelectedTheme")

        XCTAssertTrue(
            locateBody.contains("searchText = \"\""),
            "Locating the current theme must clear search so the selected row exists in the list"
        )
        XCTAssertTrue(
            locateBody.contains("proxy.scrollTo(selectedName, anchor: .center)"),
            "Locating the current theme must scroll the list back to the selected row"
        )
        XCTAssertTrue(
            source.contains(".onChange(of: searchText)"),
            "Clearing search must also trigger selected-row scrolling after the full list returns"
        )
    }

    /// Font settings expose mono font family and size controls.
    func testTerminalAppearanceExposesFontControls() throws {
        let source = try readSourceFile("SSHApp/Views/FontSettingsView.swift")
        XCTAssertTrue(
            source.contains("Picker(\"Font\""),
            "Font settings must expose a terminal font picker"
        )
        XCTAssertTrue(
            source.contains("Stepper("),
            "Font settings must expose a terminal font size stepper"
        )
        XCTAssertTrue(
            source.contains("AppSettingsKey.terminalFontFamily"),
            "Font family selection must persist through AppStorage"
        )
        XCTAssertTrue(
            source.contains("AppSettingsKey.terminalFontSize"),
            "Font size selection must persist through AppStorage"
        )
        XCTAssertTrue(
            source.contains("TerminalRuntime.shared.selectFontFamily"),
            "Font family changes must apply live through TerminalRuntime"
        )
        XCTAssertTrue(
            source.contains("TerminalRuntime.shared.selectFontSize"),
            "Font size changes must apply live through TerminalRuntime"
        )
        XCTAssertTrue(
            source.contains("terminalAppearance.fontPreview"),
            "Appearance must show a live preview of the selected font and size"
        )
    }

    /// tmux pane separators should follow the selected terminal theme instead
    /// of fixed SwiftUI/system colors, without drawing outer pane borders.
    func testTmuxPaneChromeUsesTerminalThemeColors() throws {
        let runtimeSource = try readSourceFile("SSHApp/Theme/TerminalRuntime.swift")
        let tabSource = try readSourceFile("SSHApp/Views/TerminalTab.swift")

        XCTAssertTrue(
            runtimeSource.contains("@Observable"),
            "TerminalRuntime must be observable so theme changes repaint SwiftUI tmux chrome"
        )
        XCTAssertTrue(
            runtimeSource.contains("cursorColor ??"),
            "Active tmux split dividers should use the theme cursor color with a foreground fallback"
        )
        XCTAssertTrue(
            runtimeSource.contains("tmuxInactivePaneBorderColor"),
            "TerminalRuntime must expose a themed inactive tmux separator color"
        )
        XCTAssertTrue(
            runtimeSource.contains("tmuxSplitDividerColor"),
            "TerminalRuntime must expose a tmux split divider color"
        )
        XCTAssertTrue(
            tabSource.contains("@Environment(TerminalRuntime.self)"),
            "Tmux SwiftUI chrome should observe TerminalRuntime through the environment"
        )

        guard let start = tabSource.range(of: "private struct TmuxWindowTerminalView"),
              let end = tabSource.range(of: "/// View shown when not connected")
        else {
            XCTFail("Could not find tmux chrome source in TerminalTab.swift")
            return
        }

        let tmuxChromeSource = String(tabSource[start.lowerBound..<end.lowerBound])
        let paneTerminalBody = try extractMethodBody(from: tabSource, methodName: "private func paneTerminal")
        XCTAssertTrue(
            tmuxChromeSource.contains("bordersActivePane"),
            "Shared tmux split borders should know whether they border the active pane"
        )
        XCTAssertFalse(
            tmuxChromeSource.contains("TmuxActivePaneOuterBorderView"),
            "Tmux pane chrome must not draw active outer-edge borders around panes"
        )
        XCTAssertTrue(
            tmuxChromeSource.contains("terminalRuntime.tmuxInactivePaneBorderColor"),
            "Inactive tmux split dividers must use the selected terminal theme"
        )
        XCTAssertTrue(
            tmuxChromeSource.contains("terminalRuntime.tmuxSplitDividerColor"),
            "Tmux split dividers must use the selected terminal theme"
        )
        XCTAssertFalse(
            paneTerminalBody.contains("strokeBorder"),
            "Individual tmux panes must not draw their own borders; adjacent panes should share split borders"
        )
        XCTAssertFalse(
            tmuxChromeSource.contains("strokeBorder"),
            "Tmux pane chrome must not draw borders around the tmux window or pane outer edges"
        )
        XCTAssertFalse(
            tmuxChromeSource.contains("Color.accentColor"),
            "Tmux pane chrome must not use the app accent color"
        )
        XCTAssertFalse(
            tmuxChromeSource.contains("UIColor.separator"),
            "Tmux pane chrome must not use fixed system separator colors"
        )
    }

    // MARK: - Connection progress / theme contrast (unchanged invariants)

    /// Connection progress messages shown inside the terminal must not hard-code
    /// ANSI foregrounds.
    func testConnectionProgressMessagesUseTerminalDefaultForeground() throws {
        let source = try readSourceFile("SSHApp/SSH/SSHSession.swift")
        let body = try extractMethodBody(from: source, methodName: "func connectAndAuthenticate")
        let statusWriterBody = try extractMethodBody(
            from: source,
            methodName: "private func writeStatusToTerminal"
        )

        XCTAssertTrue(body.contains("writeStatusToTerminal(\"Connecting to"))
        XCTAssertTrue(body.contains("writeStatusToTerminal(\"Connected. Verifying host key...\""))
        XCTAssertTrue(body.contains("writeStatusToTerminal(\"Authenticating as"))

        for token in ["[97m", "[37m", "[90m", "\\u{1b}[", "\\u{1B}["] {
            XCTAssertFalse(
                body.contains(token),
                "Connection progress output must not hard-code ANSI foreground token \(token)"
            )
            XCTAssertFalse(
                statusWriterBody.contains(token),
                "writeStatusToTerminal must leave foreground selection to the terminal theme"
            )
        }
    }

    /// Muted SwiftUI text should use semantic system colors, not fixed gray.
    func testViewTextForegroundsAvoidFixedGray() throws {
        let sourceDir = projectRoot().appendingPathComponent("SSHApp/Views")
        let swiftFiles = try findSwiftFiles(in: sourceDir)

        for file in swiftFiles {
            let source = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(
                source.contains(".foregroundColor(.gray)"),
                "\(file.lastPathComponent) must use semantic colors like .secondary for text instead of fixed .gray"
            )
            XCTAssertFalse(
                source.contains(".foregroundStyle(.gray)"),
                "\(file.lastPathComponent) must use semantic colors like .secondary for text instead of fixed .gray"
            )
            XCTAssertFalse(
                source.contains(".foregroundColor(.secondary.opacity"),
                "\(file.lastPathComponent) must not fade secondary text with opacity"
            )
            XCTAssertFalse(
                source.contains(".foregroundStyle(.secondary.opacity"),
                "\(file.lastPathComponent) must not fade secondary text with opacity"
            )
        }
    }

    /// SSH write() targets a specific channel buffer and schedules the shared
    /// pump, rather than relying on a single global write queue.
    func testSSHWriteUsesPerChannelThreadSafeBuffer() throws {
        let source = try readSourceFile("SSHApp/SSH/SSH2Transport.swift")
        let body = try extractMethodBody(from: source, methodName: "func write")

        XCTAssertTrue(
            body.contains("guard let managed = channels[id]"),
            "write() must look up the target managed channel"
        )
        XCTAssertTrue(
            body.contains("managed.pendingWrites.withLock"),
            "write() must buffer data on the selected channel"
        )
        XCTAssertTrue(
            body.contains("ensurePumpScheduledLocked()"),
            "write() must schedule the session-wide channel pump"
        )
        XCTAssertTrue(
            source.contains("queue.asyncAfter"),
            "the channel pump must be scheduled so channel-open operations can interleave with I/O"
        )
    }

    /// Routine SSH byte-count write logs are useful during transport debugging,
    /// but too noisy for normal tmux debugging.
    func testSSHWriteTrafficLogsAreGated() throws {
        let source = try readSourceFile("SSHApp/SSH/SSH2Transport.swift")

        XCTAssertTrue(
            source.contains("private let logsSSHWriteTraffic = false"),
            "Routine SSH write byte-count logs should be disabled by default"
        )
        XCTAssertTrue(
            source.contains("logger.debug(\"SSH write: queued"),
            "SSH write queued logs should stay behind the explicit transport debug flag"
        )
        XCTAssertTrue(
            source.contains("logger.debug(\"SSH write: sent"),
            "SSH write sent logs should stay behind the explicit transport debug flag"
        )
    }

    // MARK: - tmux (kept invariants)

    /// tmux windows must remain mounted when switching window tabs so hidden
    /// panes keep their terminal surface buffers (each ghostty surface holds its
    /// own scrollback).
    func testTmuxWindowsStayMountedAcrossWindowSwitches() throws {
        let source = try readSourceFile("SSHApp/Views/TerminalTab.swift")

        XCTAssertTrue(
            source.contains("ForEach(controller.windowOrder, id: \\.self)"),
            "TerminalTab must render every tmux window so hidden panes keep their terminal buffers"
        )
        XCTAssertTrue(
            source.contains(".opacity(isActiveWindow ? 1 : 0)"),
            "Inactive tmux windows should be hidden, not removed"
        )
        XCTAssertTrue(
            source.contains(".allowsHitTesting(isActiveWindow)"),
            "Only the active tmux window should receive gestures"
        )
        XCTAssertFalse(
            source.contains(".id(activeWindow.id)"),
            "Changing the active tmux window must not force terminal view remounts"
        )
    }

    /// tmux pane focus must be touch-driven via the terminal view's own focus
    /// reporting, not forced from SwiftUI update passes.
    func testTmuxPaneFocusIsTouchDriven() throws {
        let source = try readSourceFile("SSHApp/Views/TmuxPaneTerminal.swift")
        let makeBody = try extractMethodBody(from: source, methodName: "func makeUIView")
        let updateBody = try extractMethodBody(from: source, methodName: "func updateUIView")
        let forwardBody = try extractMethodBody(from: source, methodName: "func forwardFromTerminal")

        XCTAssertTrue(
            source.contains("TerminalSurfaceFocusDelegate"),
            "TmuxPaneTerminal should track focus via the TerminalSurfaceFocusDelegate (touch-driven)"
        )
        XCTAssertTrue(
            source.contains("terminalDidChangeFocus"),
            "TmuxPaneTerminal must forward focus changes to update the active pane"
        )
        XCTAssertFalse(
            makeBody.contains("becomeFirstResponder()"),
            "TmuxPaneTerminal must not claim first responder while being mounted"
        )
        XCTAssertFalse(
            updateBody.contains("becomeFirstResponder()"),
            "TmuxPaneTerminal must not claim first responder from SwiftUI update passes"
        )
        XCTAssertFalse(
            forwardBody.contains("controller.focusPane"),
            "Terminal-generated replies from hidden tmux panes must not reactivate their old windows"
        )
    }

    /// Regression: a tmux window's active pane must also accept keyboard input
    /// immediately when its ghostty surface attaches. Inactive panes and hidden
    /// windows stay mounted, so the first-responder request must be gated by
    /// the SwiftUI-focused pane state.
    func testTmuxActivePaneClaimsInitialFirstResponderOnSurfaceAttach() throws {
        let source = try readSourceFile("SSHApp/Views/TmuxPaneTerminal.swift")
        let makeBody = try extractMethodBody(from: source, methodName: "func makeUIView")
        let updateBody = try extractMethodBody(from: source, methodName: "func updateUIView")
        let attachBody = try extractMethodBody(from: source, methodName: "func terminalDidAttachSurface")
        let updateFocusBody = try extractMethodBody(from: source, methodName: "func updateFocusedState")
        let requestBody = try extractMethodBody(from: source, methodName: "func requestFirstResponderIfReady")
        let scheduleBody = try extractMethodBody(from: source, methodName: "private func scheduleFirstResponderRequest")
        let attemptBody = try extractMethodBody(from: source, methodName: "private func attemptFirstResponderIfReady")

        XCTAssertTrue(
            source.contains("TerminalSurfaceLifecycleDelegate"),
            "TmuxPaneTerminal must observe surface attach before requesting initial input focus"
        )
        XCTAssertTrue(
            makeBody.contains("coordinator.updateFocusedState(isFocused)"),
            "makeUIView must seed the coordinator with the pane's active focus state"
        )
        XCTAssertTrue(
            updateBody.contains("coordinator.updateFocusedState(isFocused)"),
            "updateUIView must keep the coordinator's active focus state current"
        )
        XCTAssertTrue(
            source.contains("hasRequestedFirstResponderForCurrentFocus"),
            "tmux first-responder claiming must be gated within each active-focus period"
        )
        XCTAssertTrue(
            source.contains("firstResponderRequestScheduled")
                && source.contains("firstResponderRequestGeneration"),
            "tmux first-responder retries must be coalesced while a request is already scheduled"
        )
        XCTAssertTrue(
            attachBody.contains("markSurfaceAttached()"),
            "terminalDidAttachSurface must mark the pane surface attached"
        )
        XCTAssertTrue(
            updateFocusBody.contains("hasRequestedFirstResponderForCurrentFocus = false")
                && updateFocusBody.contains("cancelFirstResponderRetry()"),
            "tmux panes must allow first-responder claiming again after losing active focus and cancel stale retries"
        )
        XCTAssertTrue(
            requestBody.contains("surfaceAttached, isFocused, !hasRequestedFirstResponderForCurrentFocus"),
            "tmux first-responder claiming must be gated to the active pane after surface attach"
        )
        XCTAssertTrue(
            requestBody.contains("scheduleFirstResponderRequest(after: .nanoseconds(0))"),
            "the tmux first-responder request should be deferred until UIKit finishes the attach/update cycle"
        )
        XCTAssertTrue(
            scheduleBody.contains("DispatchQueue.main.asyncAfter")
                && scheduleBody.contains("self.firstResponderRequestGeneration == generation"),
            "tmux first-responder attempts must run asynchronously on the next main-queue turn and ignore stale retries"
        )
        XCTAssertTrue(
            attemptBody.contains("terminalView.isFirstResponder || terminalView.becomeFirstResponder()")
                && attemptBody.contains("hasRequestedFirstResponderForCurrentFocus = true"),
            "the active tmux pane must mark first-responder claiming complete only after UIKit grants focus"
        )
        XCTAssertTrue(
            attemptBody.contains("scheduleFirstResponderRequest(after: .milliseconds(50))"),
            "failed tmux first-responder attempts must retry while the pane remains focused"
        )
    }

    /// Regression: every Ghostty surface starts focused unless the wrapper
    /// explicitly pushes a focus state into it. tmux split panes mount multiple
    /// terminal surfaces at once, so inactive panes must receive the logical
    /// active-pane state before any user touch/blur callback happens.
    func testTmuxPaneFocusSynchronizesGhosttySurfaceFocusBeforeUIKitFocusEvents() throws {
        let paneSource = try readSourceFile("SSHApp/Views/TmuxPaneTerminal.swift")
        let terminalViewSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView.swift"
        )
        let coordinatorSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Surface/TerminalSurfaceCoordinator.swift"
        )

        let applyBody = try extractMethodBody(from: paneSource, methodName: "func applyAccessory")
        let markAttachedBody = try extractMethodBody(from: paneSource, methodName: "func markSurfaceAttached")
        let updateFocusBody = try extractMethodBody(from: paneSource, methodName: "func updateFocusedState")
        let syncFocusBody = try extractMethodBody(from: paneSource, methodName: "private func syncTerminalSurfaceFocus")
        let publicFocusBody = try extractMethodBody(from: terminalViewSource, methodName: "open func setTerminalSurfaceFocused")
        let rebuildBody = try extractMethodBody(from: coordinatorSource, methodName: "func rebuildIfReady")
        let coordinatorFocusBody = try extractMethodBody(from: coordinatorSource, methodName: "func setFocus(_ focused: Bool")

        XCTAssertTrue(
            applyBody.contains("syncTerminalSurfaceFocus()"),
            "tmux panes must seed Ghostty surface focus as soon as the terminal view is available"
        )
        XCTAssertTrue(
            markAttachedBody.contains("syncTerminalSurfaceFocus()"),
            "tmux panes must re-apply focus when Ghostty creates a new surface"
        )
        XCTAssertTrue(
            updateFocusBody.contains("syncTerminalSurfaceFocus()"),
            "tmux panes must update Ghostty surface focus when the active pane changes"
        )
        XCTAssertTrue(
            syncFocusBody.contains("terminalView?.setTerminalSurfaceFocused(isFocused)"),
            "tmux pane focus sync must drive Ghostty's surface focus from the logical active-pane state"
        )
        XCTAssertTrue(
            publicFocusBody.contains("core.setFocus(focused, notifyDelegate: false)"),
            "programmatic surface-focus sync must not synthesize a TerminalSurfaceFocusDelegate event"
        )
        XCTAssertTrue(
            rebuildBody.contains("newSurface.setFocus(isSurfaceFocused)"),
            "new Ghostty surfaces must inherit the wrapper's stored focus state instead of Ghostty's focused default"
        )
        XCTAssertTrue(
            coordinatorFocusBody.contains("notifyDelegate")
                && coordinatorFocusBody.contains("if notifyDelegate"),
            "TerminalSurfaceCoordinator must allow visual focus sync without delegate callbacks"
        )
    }

    /// Regression: tmux can deliver the initial prompt before the pane's
    /// ghostty surface exists. `InMemoryTerminalSession.receive(_:)` drops
    /// bytes without a surface, so the pane sink must queue through the
    /// coordinator and flush from `terminalDidAttachSurface`.
    func testTmuxPaneOutputWaitsForSurfaceAttach() throws {
        let source = try readSourceFile("SSHApp/Views/TmuxPaneTerminal.swift")
        let makeBody = try extractMethodBody(from: source, methodName: "func makeUIView")
        let updateBody = try extractMethodBody(from: source, methodName: "func updateUIView")
        let attachBody = try extractMethodBody(from: source, methodName: "func terminalDidAttachSurface")
        let markAttachedBody = try extractMethodBody(from: source, methodName: "func markSurfaceAttached")
        let receiveBody = try extractMethodBody(from: source, methodName: "func receiveFromPane")

        XCTAssertTrue(
            makeBody.contains("coordinator?.receiveFromPane(data)"),
            "makeUIView must route tmux pane replay through the coordinator, not directly into an unattached surface"
        )
        XCTAssertTrue(
            updateBody.contains("coordinator?.receiveFromPane(data)"),
            "pane reuse must route tmux pane replay through the same surface-readiness gate"
        )
        XCTAssertTrue(
            updateBody.contains("resetPendingOutputBeforeSurfaceAttach()"),
            "pane reuse must not flush stale pre-attach output into a different pane"
        )
        XCTAssertTrue(
            source.contains("pendingOutputBeforeSurfaceAttach"),
            "TmuxPaneTerminal must retain pane output until ghostty has a surface"
        )
        XCTAssertTrue(
            receiveBody.contains("guard surfaceAttached, let terminalSession else")
                && receiveBody.contains("pendingOutputBeforeSurfaceAttach.append(data)"),
            "receiveFromPane must buffer output before the surface attaches"
        )
        XCTAssertTrue(
            attachBody.contains("markSurfaceAttached()")
                && markAttachedBody.contains("flushPendingOutputIfReady()"),
            "terminalDidAttachSurface must flush tmux output that arrived during mount"
        )
        XCTAssertFalse(
            makeBody.contains("imSession?.receive(data)"),
            "makeUIView must not feed initial tmux output directly into an unattached InMemoryTerminalSession"
        )
    }

    func testTmuxWindowShortcutsAreScopedToActivePane() throws {
        let tabSource = try readSourceFile("SSHApp/Views/TerminalTab.swift")
        let paneSource = try readSourceFile("SSHApp/Views/TmuxPaneTerminal.swift")

        XCTAssertTrue(
            tabSource.contains("isHostTabActive && isActiveWindow"),
            "tmux panes should only be focused when both host tab and tmux window are active"
        )
        XCTAssertTrue(
            tabSource.contains("Task { await controller.selectPreviousWindow() }"),
            "TerminalTab must route previous tmux-window shortcuts to the controller"
        )
        XCTAssertTrue(
            tabSource.contains("Task { await controller.selectNextWindow() }"),
            "TerminalTab must route next tmux-window shortcuts to the controller"
        )
        XCTAssertTrue(
            tabSource.contains("Task { await controller.selectWindow(shortcutDigit: digit) }"),
            "TerminalTab must route numeric tmux-window shortcuts to the controller"
        )
        XCTAssertTrue(
            paneSource.contains("isFocused ? [.hostTabs, .tmuxWindows] : []"),
            "tmux window shortcuts must only be enabled on the focused tmux pane"
        )
        XCTAssertTrue(
            tabSource.contains("controller.activeWindowID == window.id")
                && tabSource.contains("pane.windowID == window.id"),
            "stale focus callbacks from hidden tmux windows must not reactivate their old panes"
        )
        XCTAssertTrue(
            paneSource.contains("terminalView.prefersTmuxWindowNumberShortcuts = isFocused"),
            "focused tmux panes must route command-number shortcuts to tmux windows"
        )
        XCTAssertTrue(
            paneSource.contains("terminalView?.resignFirstResponder()"),
            "tmux panes must resign first responder when losing active focus"
        )
    }

    /// The tmux mode indicator doubles as the split-pane Menu; the standalone
    /// split button is gone and the new-window affordance stays a button.
    func testUnifiedBarExposesSplitPaneMenu() throws {
        let barSource = try readSourceFile("SSHApp/Views/UnifiedTopBar.swift")

        XCTAssertFalse(
            barSource.contains(".confirmationDialog("),
            "Split direction actions should be normal in-app SwiftUI menu buttons, not a system confirmation dialog"
        )
        XCTAssertTrue(
            barSource.contains("Label(\"Split Right\""),
            "Tmux split menu must include Split Right"
        )
        XCTAssertTrue(
            barSource.contains("Label(\"Split Down\""),
            "Tmux split menu must include Split Down"
        )
        XCTAssertTrue(
            barSource.contains("private func tmuxModeIndicator(controller: TmuxController)"),
            "The tmux indicator must host the split menu instead of a separate split button"
        )
        XCTAssertFalse(
            barSource.contains(".accessibilityIdentifier(\"tmux.pane.split\")"),
            "The standalone split button is gone; the indicator presents the split menu"
        )
        XCTAssertTrue(
            barSource.contains(".accessibilityIdentifier(\"tmux.pane.split.right\")"),
            "Split Right must have a stable accessibility identifier"
        )
        XCTAssertTrue(
            barSource.contains(".accessibilityIdentifier(\"tmux.pane.split.down\")"),
            "Split Down must have a stable accessibility identifier"
        )
        XCTAssertTrue(
            barSource.contains("\"tmux.window.new\""),
            "The new-window control must remain available"
        )
        XCTAssertFalse(
            barSource.contains(".disabled(controller.activePaneID == nil)"),
            "Split actions should reach the controller so missing active-pane state is logged instead of silently disabling the button"
        )
        XCTAssertTrue(
            barSource.contains("controller.splitPane(direction)"),
            "The unified bar must route split menu actions through TmuxController"
        )
    }

    /// The + button appears only while tabs are open: it creates a tmux
    /// window while attached in control mode and a new shared terminal tab on
    /// the current connection otherwise. On the no-tabs home screen the
    /// + New Connection list row is the only entry point, so the bar hides it.
    func testUnifiedBarNewTabButtonWorksInBothModes() throws {
        let barSource = try readSourceFile("SSHApp/Views/UnifiedTopBar.swift")
        let topBarBody = try extractMethodBody(
            from: barSource,
            methodName: "var body"
        )
        let hostSessionPillsBody = try extractMethodBody(
            from: barSource,
            methodName: "private var hostSessionPills"
        )
        let tmuxWindowPillsBody = try extractMethodBody(
            from: barSource,
            methodName: "private func tmuxWindowPills"
        )
        let newTabButtonBody = try extractMethodBody(
            from: barSource,
            methodName: "private var newTabButton"
        )

        XCTAssertFalse(
            topBarBody.contains("newTabButton"),
            "The + button must not be a standalone trailing top-bar item"
        )
        XCTAssertTrue(
            hostSessionPillsBody.contains("if !tabs.isEmpty")
                && hostSessionPillsBody.contains("newTabButton"),
            "The host-tab + button must be hidden on the no-tabs home screen and appear immediately after the host tabs"
        )
        XCTAssertTrue(
            tmuxWindowPillsBody.contains("if !tabs.isEmpty")
                && tmuxWindowPillsBody.contains("newTabButton"),
            "The tmux-window + button must be hidden on the no-tabs home screen and appear immediately after the tmux windows"
        )
        XCTAssertTrue(
            hostSessionPillsBody.contains("ForEach(Array(tabs.enumerated()), id: \\.element.id)")
                && hostSessionPillsBody.contains("shortcutHint: hostShortcutHint(forTabAt: index)"),
            "Host tabs must render their command-number shortcut hint from tab order"
        )
        XCTAssertTrue(
            tmuxWindowPillsBody.contains("ForEach(Array(controller.windowOrder.enumerated()), id: \\.element)")
                && tmuxWindowPillsBody.contains("shortcutHint: tmuxShortcutHint("),
            "tmux windows must render their command-number shortcut hint from visible window order"
        )

        XCTAssertTrue(
            newTabButtonBody.contains("Task { await controller.newWindow() }"),
            "The + button must create a tmux window while a tmux -CC session is attached"
        )
        XCTAssertTrue(
            newTabButtonBody.contains("onNewTerminalForTab(selectedTab)"),
            "The + button must open a new shared terminal tab on the current connection outside tmux mode"
        )
        XCTAssertTrue(
            newTabButtonBody.contains("onAddTab()"),
            "The + button must fall back to the new-connection sheet when the selected tab can't host a shared terminal"
        )
        XCTAssertTrue(
            barSource.contains(".accessibilityIdentifier(attachedController != nil ? \"tmux.window.new\" : \"host.session.new\")"),
            "The + button must expose mode-specific accessibility identifiers"
        )
    }

    /// Regression: connections and tmux windows share a single top bar. The
    /// tmux controls must only render for an attached tmux controller, and
    /// TerminalTab must no longer stack its own toolbar above the panes.
    func testUnifiedBarMergesConnectionAndTmuxRows() throws {
        let barSource = try readSourceFile("SSHApp/Views/UnifiedTopBar.swift")
        let mainSource = try readSourceFile("SSHApp/Views/MainView.swift")
        let tabSource = try readSourceFile("SSHApp/Views/TerminalTab.swift")

        XCTAssertTrue(
            barSource.contains("controller.state.isAttached"),
            "Tmux controls must be gated on an attached tmux controller"
        )
        XCTAssertTrue(
            barSource.contains("TmuxWindowTabPill"),
            "Tmux windows must own the shared tab area as pills while attached"
        )
        XCTAssertTrue(
            barSource.contains("private func tmuxShortcutHint(forWindowAt index: Int, windowCount: Int) -> String?"),
            "tmux window pills must derive shortcut hints from the same indexed-tab mapping as host tabs"
        )
        XCTAssertTrue(
            barSource.contains("private func connectionSection(_ group: TerminalTabGroup)")
                && barSource.contains("ConnectionMenuModel.groupMenu("),
            "Each connection must render as a flat menu section composed from ConnectionMenuModel"
        )
        XCTAssertFalse(
            barSource.contains("tmuxSessionMenu"),
            "tmux windows must be direct section rows, not a nested per-session submenu"
        )
        XCTAssertTrue(
            barSource.contains("Task { await controller.selectWindow(window.id) }"),
            "Selecting a window row must route through TmuxController"
        )
        XCTAssertTrue(
            barSource.contains(".accessibilityIdentifier(\"tmux.windows.menu.select.\\(window.id.rawValue)\")"),
            "tmux window menu entries must have stable accessibility identifiers"
        )
        XCTAssertFalse(
            barSource.contains("tmux.window.picker"),
            "The window picker sheet is gone; windows are reachable as pills and via the connection menu"
        )
        let entryRowsForDetach = try extractMethodBody(
            from: barSource,
            methodName: "private func entryRows"
        )
        XCTAssertTrue(
            entryRowsForDetach.contains("Task { await controller.detach() }")
                && entryRowsForDetach.contains(".accessibilityIdentifier(\"tmux.detach.\\(tabID.uuidString)\")")
                && entryRowsForDetach.contains("primaryAction:"),
            "Detach tmux lives in the tmux tab row's expansion menu (tap expands; nested menus ignore primaryAction)"
        )
        XCTAssertFalse(
            try extractMethodBody(from: barSource, methodName: "private func connectionActionsMenu")
                .contains("controller.detach"),
            "The Connection… actions submenu must not host tmux detach anymore"
        )
        XCTAssertFalse(
            barSource.contains("onDetachTmux"),
            "Detach tmux must not remain a root-level connection menu action"
        )
        XCTAssertTrue(
            barSource.contains("tmuxModeIndicator"),
            "The unified bar must show a tmux indicator when tmux windows own the tab area"
        )
        XCTAssertTrue(
            barSource.contains(".accessibilityIdentifier(\"tmux.mode.indicator\")"),
            "The tmux indicator must have a stable accessibility identifier"
        )
        XCTAssertTrue(
            barSource.contains("hostSessionPills"),
            "Normal SSH sessions must render as top-bar host-session tabs"
        )
        XCTAssertTrue(
            barSource.contains(".accessibilityIdentifier(\"host.session.tabs\")"),
            "The normal host-session tab area must have a stable accessibility identifier"
        )
        XCTAssertTrue(
            mainSource.contains("UnifiedTopBar("),
            "MainView must render the unified top bar"
        )
        XCTAssertFalse(
            tabSource.contains("TmuxWindowTabBar"),
            "TerminalTab must not stack a second toolbar above the tmux panes"
        )
        XCTAssertFalse(
            mainSource.contains("TmuxWindowPicker"),
            "The tmux window picker sheet is gone; windows are reachable as pills and via the connection menu"
        )
    }

    /// Regression: the connection pill is a menu exposing switch, close, and
    /// new-connection actions instead of a row of per-connection pills.
    func testUnifiedBarConnectionMenuActions() throws {
        let barSource = try readSourceFile("SSHApp/Views/UnifiedTopBar.swift")
        let mainSource = try readSourceFile("SSHApp/Views/MainView.swift")
        let installSheetSource = try readSourceFile("SSHApp/Views/InstallSSHKeySheet.swift")
        let sectionBody = try extractMethodBody(
            from: barSource,
            methodName: "private func connectionSection"
        )
        let entryRowsBody = try extractMethodBody(
            from: barSource,
            methodName: "private func entryRows"
        )
        let actionsMenuBody = try extractMethodBody(
            from: barSource,
            methodName: "private func connectionActionsMenu"
        )
        let newTabRowBody = try extractMethodBody(
            from: barSource,
            methodName: "private func newTabRow(for"
        )
        let newTabRowTitleBody = try extractMethodBody(
            from: barSource,
            methodName: "private func newTabRowTitle"
        )
        let newTmuxWindowRowBody = try extractMethodBody(
            from: barSource,
            methodName: "private func newTmuxWindowRow"
        )

        XCTAssertTrue(
            barSource.contains("private struct ConnectionMenuPill: View"),
            "The connection pill must stay a compact SwiftUI view"
        )
        // Regression: the UIKit UIMenu presenter is gone. iPadOS (verified on
        // 26.5 with a hardware keyboard attached) renders no key-equivalent
        // column in any in-app menu, and UIKit `UIAction.subtitle` does not
        // render from these menus either, so the UIKit detour bought nothing
        // a plain SwiftUI Menu can't do.
        XCTAssertFalse(
            barSource.contains("UIViewRepresentable")
                || barSource.contains("showsMenuAsPrimaryAction")
                || barSource.contains("UIKeyCommand("),
            "The connection menu must be a plain SwiftUI Menu; the UIKit presenter existed only for a shortcut column iPadOS never draws"
        )
        XCTAssertTrue(
            barSource.contains("connectionPillLabel"),
            "The SwiftUI Menu must present from the compact pill label without changing the pill layout"
        )
        XCTAssertTrue(
            barSource.contains("Text(selectedTab.connectionDisplayTitle)")
                && barSource.contains(".accessibilityLabel(\"Connection \\(selectedTab.connectionDisplayTitle)\")"),
            "The connection menu pill must show the stable connection name, not the terminal's mutable title"
        )
        XCTAssertFalse(
            barSource.contains("Text(selectedTab.title)")
                || barSource.contains(".accessibilityLabel(\"Connection \\(selectedTab.title)\")"),
            "OSC title changes must not rename the connection menu pill"
        )
        XCTAssertTrue(
            barSource.contains("titleWithShortcutHint(\"New Connection\", \"⌘N\", alignedAfter: rootMenuActionTitles)")
                && barSource.contains("onAddTab()")
                && barSource.contains(".accessibilityIdentifier(\"tab.add\")"),
            "New Connection must remain reachable from the unified bar with its shortcut-aware title"
        )
        XCTAssertTrue(
            actionsMenuBody.contains("Button(role: .destructive)")
                && actionsMenuBody.contains("Label(\"Disconnect\", systemImage: \"xmark\")"),
            "Each connection's actions submenu must expose its own Disconnect action"
        )
        XCTAssertTrue(
            entryRowsBody.contains("onSelectTab(tab)"),
            "The connection menu must switch between open connections"
        )
        XCTAssertTrue(
            barSource.contains("TerminalTabGrouping.groups(for: tabs)"),
            "The connection menu must group open sessions by their live SSH connection"
        )
        XCTAssertTrue(
            sectionBody.contains("Section(group.title)"),
            "Connection groups must render as flat labeled sections, not nested submenus"
        )
        XCTAssertTrue(
            barSource.contains(".accessibilityIdentifier(\"connection.group.newTerminal.\\(group.primaryTab.id.uuidString)\")"),
            "Reusable connection groups must expose their own New Tab action"
        )
        XCTAssertTrue(
            newTabRowBody.contains("onNewTerminalForTab(sourceTab)")
                && newTabRowBody.contains("group.canOpenNewTerminal"),
            "The section's New Tab row must open a plain shared channel even when a tmux session is attached"
        )
        XCTAssertTrue(
            newTabRowTitleBody.contains("guard showsShortcutHint")
                && newTabRowTitleBody.contains("titleWithShortcutHint(title, \"⌘T\", alignedAfter: groupMenuActionTitles(newTabTitle: title))"),
            "The Cmd-T hint is contextual: only the row Cmd-T would trigger for the selected tab carries it"
        )
        XCTAssertTrue(
            barSource.contains("newTabShowsShortcutHint")
                && barSource.contains("showsShortcutHint: isSelected"),
            "The New Tab hint follows the selected tab: plain tab selected hints New Tab, tmux tab selected hints its New tmux Tab"
        )
        // Regression: iPadOS (verified through 26.5) renders no key-equivalent
        // column in ANY in-app menu — not for UIKeyCommand menu elements — and
        // UIKit `UIAction.subtitle` does not render from these menus either.
        // Custom trailing views, badges, and LabeledContent values are all
        // stripped from menu rows, and so are color, font, and weight styling
        // on the title text (no dimming is possible). The only way to place
        // the hint on the same line, to the right of the label, is inside the
        // title text itself. It is padded with nonbreaking spaces when it
        // fits so multiple hints align in a column, and omitted on compact
        // menus when the hinted title would wrap. The actual Cmd-T shortcut
        // is owned by the menu-bar commands (SSHAppCommands) and the
        // terminal's own key handling.
        XCTAssertTrue(
            barSource.contains("private func titleWithShortcutHint")
                && barSource.contains("MenuShortcutHintTitle.text(")
                && barSource.contains("horizontalSizeClass: horizontalSizeClass")
                && barSource.contains("static let noBreakSpace")
                && barSource.contains("static let wordJoiner")
                && barSource.contains("maximumWidth:"),
            "Shortcut hints must ride the title line with nonbreaking padding, or be omitted when they cannot fit without wrapping"
        )
        XCTAssertFalse(
            barSource.contains("private struct ShortcutMenuLabel: View")
                || barSource.contains("shortcutMenuLabel(title:")
                || barSource.contains(".frame(minWidth: 32, alignment: .trailing)"),
            "The menu must not rebuild a fake trailing shortcut column; the hint is an inline title string"
        )
        XCTAssertTrue(
            newTmuxWindowRowBody.contains("Task { await controller.newWindow() }")
                && newTmuxWindowRowBody.contains("onSelectTab(tab)")
                && newTmuxWindowRowBody.contains("tmuxWindowIndent + \"New tmux Tab\""),
            "Each tmux session block must end with its own indented New tmux Tab row targeting that session"
        )
        XCTAssertFalse(
            barSource.contains("New Terminal on This Server"),
            "New Terminal on This Server must not remain as a top-level selector action"
        )
        XCTAssertFalse(
            barSource.contains("Label(\"Close \\(selectedTab.title)\", systemImage: \"xmark\")"),
            "Connection groups must use a contextual Disconnect label instead of the selected tab title"
        )
        XCTAssertTrue(
            barSource.contains("let savedConnections: [SavedConnection]"),
            "The connection menu must receive saved connections from the app's query"
        )
        XCTAssertTrue(
            mainSource.contains("savedConnections: savedConnections"),
            "MainView must pass saved connections into the unified bar menu"
        )
        XCTAssertTrue(
            barSource.contains("Label(\"Saved Connections…\", systemImage: \"bookmark\")")
                && barSource.contains(".accessibilityIdentifier(\"savedConnections.open\")"),
            "The menu's root must open the Saved Connections manager instead of nesting a submenu"
        )
        XCTAssertTrue(
            barSource.contains("ForEach(favoriteConnections)")
                && barSource.contains("ConnectionMenuModel.favorites(savedConnections)")
                && barSource.contains("onConnectSavedConnection(connection)"),
            "Favorite saved connections must be one-tap connect rows at the menu's root"
        )
        XCTAssertFalse(
            barSource.contains("onEditSavedConnection")
                || barSource.contains("savedConnectionsMenu"),
            "Editing moved to the Saved Connections manager; the nested Connect/Edit submenu is gone"
        )
        XCTAssertTrue(
            actionsMenuBody.contains("Label(\"Install SSH Key\", systemImage: \"key\")"),
            "Connected sessions must expose ssh-copy-id-style key installation"
        )
        XCTAssertTrue(
            actionsMenuBody.contains(".accessibilityIdentifier(\"connection.installSSHKey."),
            "The Install SSH Key action must have a stable accessibility identifier"
        )
        XCTAssertTrue(
            barSource.contains("tab.connectionState == .connected && tab.session?.canOpenChannel == true"),
            "Install SSH Key must only be offered for live authenticated SSH sessions"
        )
        XCTAssertTrue(
            actionsMenuBody.contains("onInstallSSHKey(installSourceTab)"),
            "Install SSH Key must target the tab belonging to that connection group"
        )
        XCTAssertTrue(
            actionsMenuBody.contains("group.tabs.forEach"),
            "Disconnect must operate on the selected connection group without switching tabs first"
        )
        XCTAssertTrue(
            actionsMenuBody.contains("onCloseTab(tab)"),
            "Disconnect must dispatch closure for tabs in the chosen connection group"
        )
        XCTAssertTrue(
            mainSource.contains("InstallSSHKeySheet(tab: request.tab, keyStore: keyStore, connectionStore: connectionStore)"),
            "MainView must present the key installation sheet with the shared KeyStore and ConnectionStore"
        )
        XCTAssertTrue(
            installSheetSource.contains("GenerateKeySheet(keyStore: keyStore) { generatedKey in"),
            "The install sheet must allow generating a key and selecting it for installation"
        )
        let installSSHKeysSection = try XCTUnwrap(
            installSheetSource.range(of: #"Section("SSH Keys")"#),
            "The install sheet must present keys in the same named section as Credentials."
        )
        let installKeyRows = try XCTUnwrap(
            installSheetSource.range(of: "ForEach(keyStore.keys)", range: installSSHKeysSection.lowerBound..<installSheetSource.endIndex),
            "The install sheet SSH Keys section must list available keys as rows."
        )
        let installGenerateKeyAction = try XCTUnwrap(
            installSheetSource.range(of: #"Label("Generate New Key", systemImage: "plus.circle")"#),
            "The install sheet generate action must match the Credentials SSH Keys row style."
        )
        XCTAssertLessThan(
            installKeyRows.lowerBound,
            installGenerateKeyAction.lowerBound,
            "Generate New Key must stay as the last row in the install sheet SSH Keys section."
        )
        XCTAssertFalse(
            installSheetSource.contains("ContentUnavailableView")
                || installSheetSource.contains(#""No SSH Keys""#)
                || installSheetSource.contains("Generate a key to install on this host."),
            "The install sheet must not show an oversized empty-state card when there are no keys."
        )
        XCTAssertTrue(
            installSheetSource.contains("AuthorizedKeysInstaller.install(keys: [key], using: session)"),
            "The install sheet must install the selected public key through the connected session"
        )
        XCTAssertTrue(
            installSheetSource.contains("@State private var selectedKeyId: UUID?"),
            "The install sheet must allow selecting only a single SSH key"
        )
        XCTAssertFalse(
            installSheetSource.contains("Set<UUID>"),
            "The install sheet must not support multi-key selection"
        )

        let installBody = try extractMethodBody(
            from: installSheetSource,
            methodName: "private func installSelectedKey"
        )
        let authorizationIndex = try XCTUnwrap(
            installBody.range(of: "BiometricCredentialAuthorizer.authorizeStoredCredentialUse")?.lowerBound,
            "Key installation must honor credential protection with a biometric check"
        )
        let installIndex = try XCTUnwrap(
            installBody.range(of: "AuthorizedKeysInstaller.install")?.lowerBound,
            "installSelectedKey must run the remote installer"
        )
        XCTAssertTrue(
            installBody.contains("CredentialProtectionSettings.isEnabled()"),
            "The biometric check must be gated on the credential protection setting"
        )
        XCTAssertLessThan(
            authorizationIndex,
            installIndex,
            "The biometric check must run before the key is installed"
        )

        let associateBody = try extractMethodBody(
            from: installSheetSource,
            methodName: "private func associateInstalledKeyWithConnection"
        )
        XCTAssertTrue(
            installBody.contains("associateInstalledKeyWithConnection(key)"),
            "A successful install must associate the key with the saved connection"
        )
        XCTAssertTrue(
            associateBody.contains("connection.sshKeyId = key.id"),
            "The installed key must become the connection's SSH key"
        )
        XCTAssertTrue(
            associateBody.contains("connectionStore.saveChanges(touching: connection)"),
            "The key association must be persisted and marked for connection sync"
        )
        XCTAssertTrue(
            associateBody.contains("KeychainService.hasPassword(forConnectionId: connection.id)"),
            "The password-delete prompt must only appear when a password is saved"
        )
        XCTAssertTrue(
            installSheetSource.contains("\"Delete Saved Password?\""),
            "The install sheet must offer to delete a saved password after key installation"
        )
        XCTAssertTrue(
            installSheetSource.contains("KeychainService.deletePassword(forConnectionId: connection.id)"),
            "Confirming the prompt must delete the connection's saved password"
        )
    }

    func testCommandTRoutesContextually() throws {
        let shortcutSource = try readSourceFile("SSHApp/Views/TerminalTabShortcut.swift")
        let mainSource = try readSourceFile("SSHApp/Views/MainView.swift")
        let body = try extractMethodBody(from: mainSource, methodName: "private func openTerminalOnSelectedServer")

        XCTAssertTrue(
            shortcutSource.contains("case newTerminal"),
            "TerminalTabShortcut must expose a host-level new-terminal action"
        )
        XCTAssertTrue(
            shortcutSource.contains(".init(input: \"t\", modifierFlags: [.command], shortcut: .newTerminal)"),
            "Cmd-T must map to the new-terminal action"
        )
        XCTAssertTrue(
            body.contains("controller.state.isAttached"),
            "Cmd-T must prefer tmux window creation while attached to tmux control mode"
        )
        XCTAssertTrue(
            body.contains("await controller.newWindow()"),
            "Cmd-T in tmux mode must create a tmux window"
        )
        XCTAssertTrue(
            body.contains("session.canOpenChannel"),
            "Cmd-T outside tmux must require a reusable authenticated SSH session"
        )
        XCTAssertTrue(
            body.contains("openSharedChannelInNewTab"),
            "Cmd-T outside tmux must open another top-level tab on the same SSH session"
        )
    }

    func testNativeCommandMenuExposesTabShortcuts() throws {
        let appSource = try readSourceFile("SSHApp/App/SSHApp.swift")
        let commandSource = try readSourceFile("SSHApp/App/SSHAppCommands.swift")
        let mainSource = try readSourceFile("SSHApp/Views/MainView.swift")

        XCTAssertTrue(
            appSource.contains(".commands {"),
            "The app scene must install native SwiftUI commands for menu bar and shortcut HUD integration"
        )
        XCTAssertTrue(
            appSource.contains("SSHAppCommands()"),
            "The app scene must include the SSHApp command menu"
        )
        XCTAssertTrue(
            commandSource.contains("CommandMenu(\"Connection\")"),
            "Connection commands must be grouped in a native command menu"
        )
        XCTAssertTrue(
            commandSource.contains("@FocusedValue(\\.sshAppCommandActions)"),
            "Native commands must route through the focused MainView action bridge"
        )
        XCTAssertTrue(
            commandSource.contains("var selectIndexedTab: (Int) -> Void")
                && commandSource.contains("var canSelectIndexedTab: (Int) -> Bool"),
            "Native command-number shortcuts must route through MainView instead of depending on terminal first responder"
        )
        XCTAssertTrue(
            mainSource.contains(".focusedSceneValue(\\.sshAppCommandActions, appCommandActions)"),
            "MainView must publish command actions to the focused scene"
        )
        XCTAssertTrue(
            commandSource.contains("Button(actions?.isTmuxAttached == true ? \"New tmux Tab\" : \"New Tab\")"),
            "The native New Tab command must reflect tmux mode"
        )
        XCTAssertTrue(
            commandSource.contains(".keyboardShortcut(\"t\", modifiers: .command)"),
            "The native New Tab command must expose Cmd-T"
        )
        XCTAssertTrue(
            commandSource.contains("Button(\"Close Tab\")"),
            "The native command menu must expose Close Tab"
        )
        XCTAssertTrue(
            commandSource.contains(".keyboardShortcut(\"w\", modifiers: .command)"),
            "Close Tab must use Cmd-W"
        )
        XCTAssertTrue(
            commandSource.contains("ForEach(IndexedTabNavigation.shortcutDigits")
                && commandSource.contains(".keyboardShortcut(KeyEquivalent(Character(String(digit))), modifiers: .command)"),
            "Command-number shortcuts must be installed as native scene commands"
        )
        XCTAssertTrue(
            commandSource.contains("actions?.isTmuxAttached == true ? \"tmux Tab\" : \"Tab\"")
                || commandSource.contains("let label = isTmuxAttached ? \"tmux Tab\" : \"Tab\""),
            "Native command-number labels must reflect whether tmux controls own the tab strip"
        )
        XCTAssertTrue(
            mainSource.contains("private func selectIndexedTabShortcut")
                && mainSource.contains("controller.selectWindow(shortcutDigit: digit)")
                && mainSource.contains("IndexedTabNavigation.item(forShortcutDigit: digit, in: tabIDs)"),
            "Cmd-number must select tmux windows in tmux mode and host tabs outside tmux mode"
        )
        XCTAssertTrue(
            mainSource.contains("private func closeSelectedTab()"),
            "Cmd-W must close the selected tab through MainView"
        )
        XCTAssertTrue(
            commandSource.contains(".keyboardShortcut(\"[\", modifiers: [.command, .shift])"),
            "Previous host tab must use the existing Cmd-Shift-[ shortcut"
        )
        XCTAssertTrue(
            commandSource.contains(".keyboardShortcut(\"]\", modifiers: [.command, .shift])"),
            "Next host tab must use the existing Cmd-Shift-] shortcut"
        )
        XCTAssertTrue(
            commandSource.contains(".keyboardShortcut(\"[\", modifiers: [.command, .option])"),
            "Previous tmux tab must use the existing Cmd-Option-[ shortcut"
        )
        XCTAssertTrue(
            commandSource.contains(".keyboardShortcut(\"]\", modifiers: [.command, .option])"),
            "Next tmux tab must use the existing Cmd-Option-] shortcut"
        )
    }

    /// Regression: the keyboard-bar toggle lives in the settings gear menu, not
    /// as a standalone top-bar button (it used to show even with no connection).
    func testKeyboardBarToggleLivesInSettingsMenu() throws {
        let barSource = try readSourceFile("SSHApp/Views/UnifiedTopBar.swift")
        let mainSource = try readSourceFile("SSHApp/Views/MainView.swift")

        XCTAssertTrue(
            barSource.contains(".accessibilityIdentifier(\"keyboard.toggle\")"),
            "The keyboard-bar toggle must remain available in the unified bar's settings menu"
        )
        XCTAssertTrue(
            barSource.contains("Toggle(isOn: $showKeyboardBar)"),
            "The settings menu item must be a checkmark toggle bound to the keyboard-bar preference"
        )
        XCTAssertFalse(
            mainSource.contains("keyboard.toggle"),
            "MainView must not render its own keyboard toggle button"
        )
    }

    /// Split divider hit strips must stay in a top-level active-window overlay.
    /// The interaction layer is a full-window UIKit view, but its hit testing
    /// only returns true inside resize strips so normal terminal input passes
    /// through everywhere else.
    func testTmuxSplitDividerHitTestingUsesTopLevelResizeOverlay() throws {
        let source = try readSourceFile("SSHApp/Views/TerminalTab.swift")
        guard let visualStart = source.range(of: "private struct TmuxSplitDividerView"),
              let visualEnd = source[visualStart.lowerBound...].range(of: "/// View shown when not connected")
        else {
            XCTFail("Could not find TmuxSplitDividerView")
            return
        }

        let dividerSource = String(source[visualStart.lowerBound..<visualEnd.lowerBound])
        XCTAssertTrue(
            source.contains("private let tmuxSplitDividerHitThickness: CGFloat = 64"),
            "Divider hit strip should be large enough for direct touch resizing"
        )
        XCTAssertTrue(
            source.contains("TmuxSplitDividerOverlay("),
            "Divider hit strips should be mounted from TerminalTab's top-level active-window overlay"
        )
        XCTAssertTrue(
            source.contains(".zIndex(10_000)"),
            "The active-window divider overlay must render above terminal UIViews"
        )
        XCTAssertTrue(
            dividerSource.contains(".allowsHitTesting(false)"),
            "Visible divider lines should not compete with the UIKit interaction overlay"
        )
        XCTAssertTrue(
            source.contains("TmuxSplitDividerInteractionOverlay("),
            "A single top-level UIKit interaction overlay should own divider drags"
        )
        XCTAssertTrue(
            source.contains("UIPanGestureRecognizer("),
            "The top-level interaction overlay should use UIKit pan recognition"
        )
        XCTAssertTrue(
            source.contains("override func point(inside point: CGPoint, with event: UIEvent?) -> Bool"),
            "The full-window UIKit overlay must only hit-test divider strips"
        )
        XCTAssertTrue(
            source.contains("dividerHit(at: point) != nil"),
            "The full-window UIKit overlay must pass through touches outside divider hit rects"
        )
        XCTAssertTrue(
            source.contains("func gestureRecognizerShouldBegin"),
            "The pan recognizer should only begin for touches inside a divider hit rect"
        )
        XCTAssertTrue(
            source.contains("dispatchResizeIfNeeded(divider: divider, targetSize: targetSize, reason: \"changed\")"),
            "Resize must dispatch during movement so a cancelled end event cannot lose the resize"
        )
        XCTAssertTrue(
            source.contains("resize drag cancelled"),
            "Cancelled UIKit pans should be logged and reset explicitly"
        )
        XCTAssertTrue(
            dividerSource.contains(".frame(width: max(size.width, 1), height: max(size.height, 1), alignment: .topLeading)"),
            "Each divider should keep the older full-window wrapper shape that worked before shared pane borders"
        )
        XCTAssertTrue(
            dividerSource.contains("tmuxAdjustedHitRect("),
            "Divider hit testing should use adjusted non-overlapping hit rectangles"
        )
        XCTAssertTrue(
            source.contains("neighboringMids"),
            "Adjacent divider lines should constrain each other's hit strips"
        )
        XCTAssertTrue(
            source.contains("(previousMid + currentMid) / 2"),
            "A divider hit strip should stop at the midpoint to the previous neighboring divider"
        )
        XCTAssertTrue(
            source.contains("(currentMid + nextMid) / 2"),
            "A divider hit strip should stop at the midpoint to the next neighboring divider"
        )
        XCTAssertFalse(
            source.contains("TmuxSplitDividerHitOverlay"),
            "The dead full-window UIKit hit router should not be mounted"
        )
        XCTAssertFalse(
            source.contains("TmuxSplitDividerPanStrip"),
            "The dead per-strip UIKit pan recognizer should not be mounted"
        )
    }

    // MARK: - Connection flow (unchanged invariants)

    func testConnectSessionCatchCallsDisconnect() throws {
        let source = try readSourceFile("SSHApp/Views/MainView.swift")
        let body = try extractMethodBody(from: source, methodName: "func connectSession")

        guard let catchRange = body.range(of: "} catch {") ?? body.range(of: "} catch ") else {
            XCTFail("connectSession must have a catch block")
            return
        }
        let afterCatch = String(body[catchRange.lowerBound...])

        XCTAssertTrue(
            afterCatch.contains("session.disconnect()"),
            "connectSession catch block must call session.disconnect()"
        )
    }

    func testSSH2TransportUsesChannelRegistry() throws {
        let source = try readSourceFile("SSHApp/SSH/SSH2Transport.swift")
        let openBody = try extractMethodBody(from: source, methodName: "func openShellChannel")
        let closeBody = try extractMethodBody(from: source, methodName: "private func closeChannelLocked")

        XCTAssertTrue(
            source.contains("struct SSHTransportChannelID"),
            "SSH2Transport must expose an internal channel id for multiplexed channels"
        )
        XCTAssertTrue(
            source.contains("private var channels: [SSHTransportChannelID: ManagedSSHTransportChannel]"),
            "SSH2Transport must keep a channel registry rather than one shell pointer"
        )
        XCTAssertFalse(
            source.contains("private var channel: OpaquePointer?"),
            "SSH2Transport must not regress to a single stored channel"
        )
        XCTAssertTrue(
            openBody.contains("channels[id] = ManagedSSHTransportChannel"),
            "opening a shell must register a managed channel"
        )
        XCTAssertTrue(
            source.contains("func write(_ data: Data, to id: SSHTransportChannelID)"),
            "writes must target a specific transport channel"
        )
        XCTAssertTrue(
            source.contains("func resizePTY(channel id: SSHTransportChannelID"),
            "resizes must target a specific transport channel"
        )
        XCTAssertTrue(
            closeBody.contains("channels.removeValue(forKey: id)"),
            "closing must remove only the selected transport channel"
        )
    }

    func testConnectAndAuthenticateTriesPasswordBeforeKeyboardInteractive() throws {
        let source = try readSourceFile("SSHApp/SSH/SSHSession.swift")
        let body = try extractMethodBody(from: source, methodName: "func connectAndAuthenticate")

        guard let passwordRange = body.range(of: "if authMethods.contains(\"password\")") else {
            XCTFail("connectAndAuthenticate must handle password auth")
            return
        }
        guard let keyboardInteractiveRange = body.range(of: "if authMethods.contains(\"keyboard-interactive\")") else {
            XCTFail("connectAndAuthenticate must keep keyboard-interactive fallback")
            return
        }

        XCTAssertLessThan(
            passwordRange.lowerBound,
            keyboardInteractiveRange.lowerBound,
            "Password auth must be attempted before keyboard-interactive when both are advertised"
        )
    }

    func testPasswordKeychainFlowLoadsByConnectionIdAndPromptsToSave() throws {
        let sessionSource = try readSourceFile("SSHApp/SSH/SSHSession.swift")
        let mainSource = try readSourceFile("SSHApp/Views/MainView.swift")
        let sessionBody = try extractMethodBody(from: sessionSource, methodName: "func connectAndAuthenticate")

        XCTAssertTrue(
            sessionBody.contains("Self.loadPasswordOffMainActor(forConnectionId: connectionId)"),
            "SSHSession must try an existing keychain password by connection id without a saved preference flag"
        )
        XCTAssertTrue(
            mainSource.contains("promptToSaveCredentials:"),
            "MainView must provide a UI confirmation callback for saving typed credentials"
        )
    }

    func testStoredCredentialUseRequiresBiometricAuthorizationBeforeKeychainReads() throws {
        let source = try readSourceFile("SSHApp/SSH/SSHSession.swift")
        let body = try extractMethodBody(from: source, methodName: "func connectAndAuthenticate")

        guard let keyAuthorizationRange = body.range(
            of: "authorizeStoredCredentialUse(\n                reason: \"Authenticate to \\(host) using your saved SSH key.\""
        ),
              let keyLoadRange = body.range(of: "keyStore.getPrivateKey(for: key)") else {
            XCTFail("Could not find key biometric authorization/load flow")
            return
        }

        XCTAssertLessThan(
            keyAuthorizationRange.lowerBound,
            keyLoadRange.lowerBound,
            "SSH private-key data must not load before biometric authorization"
        )

        guard let passwordExistenceRange = body.range(
            of: "Self.hasPasswordOffMainActor(forConnectionId: connectionId)"
        ),
              let passwordAuthorizationRange = body.range(
                of: "reason: \"Authenticate to \\(host) using your saved SSH password.\""
              ),
              let passwordLoadRange = body.range(
                of: "Self.loadPasswordOffMainActor(forConnectionId: connectionId)"
              ) else {
            XCTFail("Could not find stored password existence/authorization/load flow")
            return
        }

        XCTAssertLessThan(
            passwordExistenceRange.lowerBound,
            passwordAuthorizationRange.lowerBound,
            "Stored password existence may be checked before authorization"
        )
        XCTAssertLessThan(
            passwordAuthorizationRange.lowerBound,
            passwordLoadRange.lowerBound,
            "Stored password data must not load before biometric authorization"
        )
    }

    func testCredentialSavePromptHappensAfterSuccessfulTypedPasswordAuth() throws {
        let source = try readSourceFile("SSHApp/SSH/SSHSession.swift")
        let body = try extractMethodBody(from: source, methodName: "func connectAndAuthenticate")

        guard let passwordPromptRange = body.range(of: "let password = await promptForPassword()"),
              let authRange = body.range(of: "try await transport.authPassword(username: resolvedUsername, password: password)"),
              let savePromptRange = body.range(of: "typedPassword: password.isEmpty ? nil : password") else {
            XCTFail("Could not find typed password auth/save flow in connectAndAuthenticate")
            return
        }

        XCTAssertLessThan(passwordPromptRange.lowerBound, authRange.lowerBound)
        XCTAssertLessThan(
            authRange.lowerBound,
            savePromptRange.lowerBound,
            "The combined save prompt must only fire after the typed password authenticates"
        )

        // The keychain write happens inside the shared helper, only after the
        // user's decision comes back from the combined dialog.
        let helperBody = try extractMethodBody(from: source, methodName: "private func offerCredentialSave")
        guard let decisionRange = helperBody.range(of: "let decision = await prompt(offer)"),
              let saveRange = helperBody.range(of: "Self.savePasswordOffMainActor(") else {
            XCTFail("Could not find decision/save flow in offerCredentialSave")
            return
        }
        XCTAssertLessThan(decisionRange.lowerBound, saveRange.lowerBound)
    }

    func testMissingUsernameIsPromptedBeforeAuthenticationAndCanBeSaved() throws {
        let sessionSource = try readSourceFile("SSHApp/SSH/SSHSession.swift")
        let mainSource = try readSourceFile("SSHApp/Views/MainView.swift")
        let body = try extractMethodBody(from: sessionSource, methodName: "func connectAndAuthenticate")

        XCTAssertTrue(
            sessionSource.contains("username: String?"),
            "SSHSession must accept missing usernames"
        )
        XCTAssertTrue(
            sessionSource.contains("private func promptForUsername()"),
            "SSHSession must prompt for a username in the terminal when one is not saved"
        )
        XCTAssertTrue(
            mainSource.contains("connection.username = username"),
            "Saving a prompted username must update the current connection"
        )
        XCTAssertTrue(
            mainSource.contains("connectionStore.saveChanges(touching: connection)"),
            "Saving a prompted username must persist and mark the current connection for sync"
        )

        guard let promptRange = body.range(of: "let input = await promptForUsername()"),
              let authListRange = body.range(of: "transport.userAuthList(username: resolvedUsername)") else {
            XCTFail("Could not find prompted username auth flow in connectAndAuthenticate")
            return
        }
        XCTAssertLessThan(
            promptRange.lowerBound,
            authListRange.lowerBound,
            "Username entry must happen before auth method discovery"
        )
        XCTAssertNil(
            body.range(of: "shouldSaveUsername"),
            "Prompted usernames must not be offered for saving before authentication succeeds"
        )
    }

    func testCredentialSaveUsesSingleCombinedDialog() throws {
        let mainSource = try readSourceFile("SSHApp/Views/MainView.swift")
        let sheetSource = try readSourceFile("SSHApp/Views/CredentialSaveSheet.swift")

        // Regression: the two separate alerts must not come back.
        XCTAssertNil(mainSource.range(of: "\"Save Username?\""), "The separate save-username alert was replaced by CredentialSaveSheet")
        XCTAssertNil(mainSource.range(of: "\"Save Password?\""), "The separate save-password alert was replaced by CredentialSaveSheet")
        XCTAssertTrue(
            mainSource.contains("CredentialSaveSheet("),
            "MainView must present the combined credential-save sheet"
        )

        XCTAssertTrue(sheetSource.contains("Toggle(isOn: $saveUsername)"))
        XCTAssertTrue(sheetSource.contains("Toggle(isOn: $savePassword)"))
        XCTAssertTrue(
            sheetSource.contains(".disabled(!passwordEnabled)"),
            "The password toggle must be gated on the username toggle when no username is saved"
        )
        XCTAssertTrue(
            sheetSource.contains(".disabled(!canSave)"),
            "The Save button must be disabled until at least one credential is selected"
        )
    }

    func testAuthPromptsDoNotAppendSecondBlankLineAfterReturn() throws {
        let source = try readSourceFile("SSHApp/SSH/SSHSession.swift")

        XCTAssertTrue(
            source.contains("The terminal bridge locally handles the user's Return key"),
            "SSHSession must document that auth prompt line breaks are emitted by the terminal input bridge"
        )

        for forbiddenSnippet in [
            "let response = await promptForInput(\"\", echo: true)\n            writeToTerminal(\"\\r\\n\")",
            "let input = await promptForUsername()\n            writeToTerminal(\"\\r\\n\")",
            "let password = await promptForPassword()\n                writeToTerminal(\"\\r\\n\")",
            "let response = await self.promptForInput(prompt.text, echo: prompt.echo)\n                        self.writeToTerminal(\"\\r\\n\")",
        ] {
            XCTAssertFalse(
                source.contains(forbiddenSnippet),
                "Auth prompt callers must not append a second CRLF after the terminal bridge already echoed Return"
            )
        }
    }

    func testSuccessfulPasswordSaveDoesNotPrintTerminalStatus() throws {
        let source = try readSourceFile("SSHApp/SSH/SSHSession.swift")

        XCTAssertFalse(
            source.contains("Password saved to iCloud Keychain."),
            "Successful password saves must stay silent to avoid cluttering the terminal"
        )
        XCTAssertTrue(
            source.contains("Could not save password to iCloud Keychain."),
            "Failed password saves should still explain the failure in the terminal"
        )
    }

    func testShellLifecycleLivesOnSSHChannel() throws {
        let sessionSource = try readSourceFile("SSHApp/SSH/SSHSession.swift")
        let channelSource = try readSourceFile("SSHApp/SSH/SSHChannel.swift")
        let writeBody = try extractMethodBody(from: channelSource, methodName: "func write(_ data")
        let openShellBody = try extractMethodBody(from: channelSource, methodName: "func openShell")
        let disconnectBody = try extractMethodBody(from: sessionSource, methodName: "func disconnect")

        XCTAssertTrue(
            channelSource.contains("private(set) var isOpen"),
            "SSHChannel must track whether its shell channel is open"
        )
        XCTAssertTrue(
            writeBody.contains("guard let transportChannelID, isOpen"),
            "SSHChannel.write must reject input before its shell channel opens"
        )
        XCTAssertTrue(
            openShellBody.contains("isOpen = true"),
            "SSHChannel.openShell must mark the shell as open only after transport setup succeeds"
        )
        XCTAssertTrue(
            disconnectBody.contains("channel.markClosedBySessionDisconnect()"),
            "SSHSession.disconnect must clear all channel-owned shell state"
        )
        XCTAssertFalse(
            sessionSource.contains("private(set) var isShellOpen"),
            "SSHSession must not keep single-shell state after channelization"
        )
    }

    func testSSHChannelReportsRemoteChannelClosure() throws {
        let channelSource = try readSourceFile("SSHApp/SSH/SSHChannel.swift")
        let body = try extractMethodBody(from: channelSource, methodName: "private func handleTransportClosed")

        XCTAssertTrue(
            channelSource.contains("enum SSHChannelRemoteCloseReason")
                && channelSource.contains("var onRemoteDisconnected: (@MainActor (SSHChannelRemoteCloseReason) -> Void)?"),
            "SSHChannel must expose a typed callback for remote channel closure"
        )
        XCTAssertTrue(
            body.contains("owner?.channelDidClose(self)"),
            "remote channel closure must update the shared session's channel registry"
        )
        XCTAssertTrue(
            body.contains("onRemoteDisconnected?(.orderlyExit)")
                && body.contains("onRemoteDisconnected?(.transportFailure)"),
            "remote channel closure must distinguish orderly exits from transport failures"
        )
    }

    func testRemoteChannelCloseRemovesOwningTabWithoutSecondDisconnect() throws {
        let source = try readSourceFile("SSHApp/Views/MainView.swift")
        let closeBody = try extractMethodBody(from: source, methodName: "private func closeTab")

        XCTAssertTrue(
            source.contains("private func closeTab(_ tab: Tab, disconnectSession: Bool = true)"),
            "closeTab must allow callers to remove an already-disconnected tab without calling disconnect again"
        )
        XCTAssertTrue(
            closeBody.contains("channel.close()"),
            "manual tab close should close only the tab's SSHChannel when one exists"
        )
        XCTAssertTrue(
            source.contains("onRemoteChannelClosed: { closedTab, reason in"),
            "MainView must wire remote channel closure to app-tab removal"
        )
        XCTAssertTrue(
            source.contains("handleRemoteChannelClosed(closedTab, reason: reason)"),
            "remote channel closure must route through the background-reconnect-aware handler"
        )

        let handlerBody = try extractMethodBody(from: source, methodName: "private func handleRemoteChannelClosed")
        XCTAssertTrue(
            handlerBody.contains("closeTab(tab, disconnectSession: false)"),
            "non-auto-reconnect remote channel closure must still remove the tab without recursively closing the channel"
        )
    }

    func testForegroundHostInteractionClearsPendingBackgroundReconnectCandidate() throws {
        let mainSource = try readSourceFile("SSHApp/Views/MainView.swift")
        let tabSource = try readSourceFile("SSHApp/Views/TerminalTab.swift")
        let ghosttySource = try readSourceFile("SSHApp/Views/GhosttyTerminalView.swift")
        let tmuxPaneSource = try readSourceFile("SSHApp/Views/TmuxPaneTerminal.swift")
        let ghosttyForwardBody = try extractMethodBody(from: ghosttySource, methodName: "func forwardFromTerminal")
        let tmuxForwardBody = try extractMethodBody(from: tmuxPaneSource, methodName: "func forwardFromTerminal")

        XCTAssertTrue(
            mainSource.contains("onHostSessionInteraction: { interactingTab in")
                && mainSource.contains("handleHostSessionInteraction(interactingTab)"),
            "MainView must clear reconnect tracking when the foregrounded session is actively used"
        )
        XCTAssertTrue(
            tabSource.contains("onHostSessionInteraction: { onHostSessionInteraction(tab) }"),
            "TerminalTab must pass host-session interaction callbacks down to its terminal surfaces"
        )
        XCTAssertTrue(
            ghosttyForwardBody.contains("onHostSessionInteraction?()"),
            "Host-shell input must clear pending background reconnect tracking before sending bytes"
        )
        XCTAssertTrue(
            tmuxForwardBody.contains("onHostSessionInteraction?()"),
            "tmux pane input must clear pending background reconnect tracking before sending bytes"
        )
    }

    func testBackgroundDisconnectQueuesFreshAutomaticReconnectInsteadOfPreservingTabs() throws {
        let source = try readSourceFile("SSHApp/Views/MainView.swift")
        let handlerBody = try extractMethodBody(from: source, methodName: "private func handleRemoteChannelClosed")
        let removeBody = try extractMethodBody(from: source, methodName: "private func removeTabs")
        let openBody = try extractMethodBody(from: source, methodName: "private func openAutomaticReconnectInNewTab")

        XCTAssertTrue(
            source.contains("@Environment(\\.scenePhase) private var scenePhase")
                && source.contains(".onChange(of: scenePhase)"),
            "MainView must observe scenePhase to detect background reconnect candidates"
        )
        XCTAssertTrue(
            source.contains("backgroundReconnectCandidates")
                && source.contains("queuedBackgroundReconnects")
                && source.contains("attemptedBackgroundReconnectKeys"),
            "MainView must track candidates, queued requests, and one-shot attempts"
        )
        XCTAssertTrue(
            source.contains("private func recordBackgroundReconnectCandidates()")
                && source.contains("private func automaticReconnectIsEligible(for connection: SavedConnection)")
                && source.contains("AutomaticReconnectPolicy.isEligible(for: connection, keyStore: keyStore)"),
            "MainView must record only eligible saved connections while entering the background"
        )
        XCTAssertTrue(
            source.contains(
                "private struct BackgroundReconnectCandidate {\n    let sessionID: ObjectIdentifier\n    let connectionID: UUID\n}"
            ),
            "Background reconnect tracking should keep only connection IDs so deleted SwiftData models are not retained"
        )
        XCTAssertTrue(
            source.contains(".onChange(of: savedConnectionIDs)")
                && source.contains("pruneBackgroundReconnectsForMissingConnections()"),
            "MainView must prune queued reconnect work when saved connections are deleted"
        )
        XCTAssertTrue(
            source.contains("private func handleHostSessionInteraction")
                && source.contains("clearBackgroundReconnectTracking(forSessionID:"),
            "Foreground user interaction must clear pending background reconnect candidates"
        )
        XCTAssertFalse(
            source.contains("foregroundReconnectGraceDeadline") || source.contains("backgroundDisconnectWindowIsOpen"),
            "Background reconnect should not rely on a fixed wall-clock grace window"
        )
        XCTAssertTrue(
            handlerBody.contains("reason == .transportFailure")
                && handlerBody.contains("savedConnection(withID: candidate.connectionID)")
                && handlerBody.contains("session.canOpenChannel != true"),
            "Remote channel closure should reconnect only transport-failure candidates that still resolve to a saved connection"
        )
        XCTAssertTrue(
            handlerBody.contains("queueBackgroundReconnect(for: candidate)")
                && handlerBody.contains("removeTabs(forSessionID: sessionID, disconnectSession: false)"),
            "Background disconnects must queue one fresh reconnect and remove stale local tabs"
        )
        XCTAssertTrue(
            removeBody.contains("closeTab(tab, disconnectSession: disconnectSession)"),
            "Stale tabs should be removed through closeTab without preserving old terminal contents"
        )
        XCTAssertTrue(
            openBody.contains("Tab(")
                && openBody.contains("selectTab(newTab)")
                && openBody.contains("attemptMode: .automaticReconnect"),
            "Automatic reconnect must open and select a fresh tab rather than reusing the stale one"
        )
    }

    func testAutomaticReconnectUsesStrictStoredCredentialConnectionAttempt() throws {
        let source = try readSourceFile("SSHApp/Views/MainView.swift")
        let body = try extractMethodBody(from: source, methodName: "func connectSession")

        XCTAssertTrue(
            source.contains("private enum ConnectionAttemptMode")
                && source.contains("case automaticReconnect"),
            "MainView must distinguish automatic reconnect attempts from user-initiated connections"
        )
        XCTAssertTrue(
            source.contains("AutomaticReconnectPolicy.normalizedEnabled(")
                && source.contains("for: connection,")
                && source.contains("keyStore: keyStore"),
            "Automatic reconnect call sites should use the shared normalization helper"
        )
        XCTAssertTrue(
            body.contains("tab.pendingAutoRunCommand = connection.pendingAutoRunCommand"),
            "Automatic reconnect must keep startup commands so tmux -CC attach can restore remote tmux state"
        )
        XCTAssertTrue(
            body.contains("let credentialSaveHandler")
                && body.contains("if isAutomaticReconnect")
                && body.contains("credentialSaveHandler = nil"),
            "Automatic reconnect must not show credential-save prompts"
        )
        XCTAssertTrue(
            body.contains("hostKeyPolicy: isAutomaticReconnect ? .requireKnownMatch : .interactive")
                && body.contains("authenticationMode: isAutomaticReconnect ? .storedCredentialsOnly : .interactive"),
            "Automatic reconnect must require a known host-key match and use stored credentials only"
        )
        XCTAssertTrue(
            body.contains("normalizeAutoReconnectAfterAutomaticFailure(for: connection)"),
            "Automatic reconnect failures must re-check eligibility after stale saved credentials are cleared"
        )
    }

    func testLastChannelCloseDisconnectsSharedSession() throws {
        let source = try readSourceFile("SSHApp/SSH/SSHSession.swift")
        let body = try extractMethodBody(from: source, methodName: "func channelDidClose")

        XCTAssertTrue(
            source.contains("private var channels: [UUID: SSHChannel]"),
            "SSHSession must track opened shell channels"
        )
        XCTAssertTrue(
            body.contains("channels.removeValue(forKey: channel.id)"),
            "SSHSession must remove each closed channel from its registry"
        )
        XCTAssertTrue(
            body.contains("if channels.isEmpty"),
            "SSHSession must detect when the last channel has closed"
        )
        XCTAssertTrue(
            body.contains("disconnect()"),
            "closing the last SSHChannel must disconnect the shared SSH session"
        )
    }

    func testConnectionSheetUsesToolbarSaveAndConnectActions() throws {
        let source = try readSourceFile("SSHApp/Views/ConnectionSheet.swift")
        let connectBody = try extractMethodBody(from: source, methodName: "private func connect")
        let applyBody = try extractMethodBody(from: source, methodName: "private func applyForm")

        XCTAssertTrue(
            source.contains("ToolbarItemGroup(placement: .topBarTrailing)"),
            "ConnectionSheet must place primary actions in the toolbar so they remain visible above the form"
        )
        XCTAssertTrue(
            source.contains("Button(\"Save\", action: save)"),
            "ConnectionSheet must expose a Save action for persisting a new connection without connecting"
        )
        XCTAssertTrue(
            source.contains("Button(\"Connect\", action: connect)"),
            "ConnectionSheet must expose a Connect action for starting a session from the entered details"
        )
        XCTAssertFalse(
            source.contains("Save & Connect"),
            "ConnectionSheet must not rely on the old bottom-of-list Save & Connect action"
        )
        XCTAssertTrue(
            connectBody.contains("persistForm(saveNewConnection: true)"),
            "Connect must persist a new connection before opening the session"
        )
        XCTAssertTrue(
            source.contains("TextField(\"Destination\", text: $destination, prompt: Text(\"[user@]hostname\"))"),
            "ConnectionSheet must expose a single Destination field with a [user@]hostname prompt"
        )
        XCTAssertTrue(
            source.contains("@FocusState private var isDestinationFocused")
                && source.contains(".focused($isDestinationFocused)")
                && source.contains("isDestinationFocused = editingConnection == nil"),
            "The new-connection sheet should focus the Destination field automatically"
        )
        XCTAssertTrue(
            source.contains(".accessibilityIdentifier(\"connection.destination\")"),
            "The Destination field must have a stable UI automation identifier"
        )
        XCTAssertFalse(
            source.contains("TextField(\"Name\""),
            "ConnectionSheet must not expose the removed Name field"
        )
        XCTAssertFalse(
            source.contains("TextField(\"Host\""),
            "ConnectionSheet must not expose the removed Host field"
        )
        XCTAssertFalse(
            source.contains("TextField(\"Username\""),
            "ConnectionSheet must not expose the removed Username field"
        )
        XCTAssertTrue(
            source.contains("ConnectionDestination.parse(destination)"),
            "ConnectionSheet must parse Destination as [user@]hostname"
        )
        XCTAssertTrue(
            applyBody.contains("connectionIdentityChanged"),
            "Editing a connection's host, port, or username must invalidate any saved password for the old connection identity"
        )
        XCTAssertTrue(
            applyBody.contains("KeychainService.deletePassword(forConnectionId: connection.id)"),
            "ConnectionSheet must clear a stored password when the connection identity changes"
        )
    }

    func testConnectionSheetExposesStartupCommandControlsAndPersistsValues() throws {
        let source = try readSourceFile("SSHApp/Views/ConnectionSheet.swift")
        let makeBody = try extractMethodBody(from: source, methodName: "private func makeConnection")
        let applyBody = try extractMethodBody(from: source, methodName: "private func applyForm")

        XCTAssertTrue(
            source.contains("@State private var autoRunCommandEnabled = false")
                && source.contains("@State private var autoRunCommand = SavedConnection.defaultAutoRunCommand"),
            "ConnectionSheet must own startup command form state with safe defaults"
        )
        XCTAssertTrue(
            source.contains("Toggle(\"Automatically run command after connecting?\", isOn: $autoRunCommandEnabled)"),
            "ConnectionSheet must expose an enable toggle for the startup command"
        )
        XCTAssertTrue(
            source.contains("TextEditor(text: $autoRunCommand)"),
            "ConnectionSheet must expose a multiline editor for the startup command"
        )
        XCTAssertTrue(
            source.contains(".accessibilityIdentifier(\"connection.autoRunCommand.enabled\")")
                && source.contains(".accessibilityIdentifier(\"connection.autoRunCommand.text\")"),
            "Startup command controls must have stable UI automation identifiers"
        )

        guard let startupRange = source.range(of: "TextEditor(text: $autoRunCommand)"),
              let tmuxRange = source.range(of: "Section(\"Tmux (per-host)\")") else {
            XCTFail("ConnectionSheet must place the startup command section before tmux settings")
            return
        }
        let startupSection = String(source[startupRange.lowerBound..<tmuxRange.lowerBound])
        XCTAssertFalse(
            startupSection.contains(".disabled"),
            "The command text editor must remain editable even while automatic sending is disabled"
        )
        XCTAssertTrue(
            makeBody.contains("autoRunCommandEnabled: autoRunCommandEnabled")
                && makeBody.contains("autoRunCommand: autoRunCommand"),
            "New saved connections must persist both startup command fields"
        )
        XCTAssertTrue(
            applyBody.contains("connection.autoRunCommandEnabled = autoRunCommandEnabled")
                && applyBody.contains("connection.autoRunCommand = autoRunCommand"),
            "Edited saved connections must persist both startup command fields"
        )
        XCTAssertTrue(
            applyBody.contains("connectionIdentityChanged"),
            "Startup command edits must not broaden the password-clearing identity-change logic"
        )
    }

    func testConnectionSheetExposesAutomaticReconnectToggleAndPersistsNormalizedValue() throws {
        let source = try readSourceFile("SSHApp/Views/ConnectionSheet.swift")
        let makeBody = try extractMethodBody(from: source, methodName: "private func makeConnection")
        let applyBody = try extractMethodBody(from: source, methodName: "private func applyForm")

        XCTAssertTrue(
            source.contains("@State private var autoReconnectOnBackgroundDisconnect = false")
                && source.contains("@State private var hasStoredPassword = false"),
            "ConnectionSheet must track reconnect toggle and saved-password state"
        )
        XCTAssertTrue(
            source.contains("Toggle(\"Automatically reconnect after background disconnect\", isOn: autoReconnectToggleBinding)")
                && source.contains(".accessibilityIdentifier(\"connection.autoReconnectAfterBackgroundDisconnect\")"),
            "ConnectionSheet must expose the automatic reconnect toggle with a stable UI identifier"
        )
        XCTAssertTrue(
            source.contains("private var autoReconnectToggleBinding: Binding<Bool>")
                && source.contains("autoReconnectIsEligible ? autoReconnectOnBackgroundDisconnect : false")
                && source.contains(".disabled(!autoReconnectIsEligible)"),
            "ConnectionSheet must preserve the user's reconnect choice across transient ineligible edits"
        )
        XCTAssertFalse(
            source.contains(".onChange(of: autoReconnectIsEligible)"),
            "ConnectionSheet must not one-way clear reconnect state while the user is still editing"
        )
        XCTAssertTrue(
            source.contains("AutomaticReconnectPolicy.isEligible")
                && source.contains("AutomaticReconnectPolicy.unavailableReason"),
            "ConnectionSheet must use the shared pure policy for UI gating and footer copy"
        )
        XCTAssertTrue(
            makeBody.contains("autoReconnectOnBackgroundDisconnect: AutomaticReconnectPolicy.normalizedEnabled(")
                && makeBody.contains("hasStoredPassword: false")
                && makeBody.contains("hasUsableKey: hasUsableSelectedKey"),
            "New connections must persist only an eligible normalized reconnect setting"
        )
        XCTAssertTrue(
            applyBody.contains("connection.autoReconnectOnBackgroundDisconnect = AutomaticReconnectPolicy.normalizedEnabled(")
                && applyBody.contains("effectiveHasStoredPassword")
                && applyBody.contains("hasUsableKey: hasUsableSelectedKey"),
            "Edited connections must normalize reconnect after identity/password/key changes"
        )
    }

    func testNewConnectionSheetDoesNotListSavedConnections() throws {
        let source = try readSourceFile("SSHApp/Views/ConnectionSheet.swift")

        XCTAssertTrue(
            source.contains(".navigationTitle(editingConnection == nil ? \"New Connection\" : \"Edit Connection\")"),
            "Creating a connection must present a dedicated New Connection sheet"
        )
        XCTAssertFalse(
            source.contains("Section(\"Saved Connections\")"),
            "The New Connection sheet must not list saved connections"
        )
        XCTAssertFalse(
            source.contains("SavedConnectionRow"),
            "Saved connection selection must live outside the New Connection sheet"
        )
        XCTAssertFalse(
            source.contains("loadSavedConnections"),
            "The New Connection sheet must not fetch saved connections for selection"
        )
    }

    func testEditingConnectionSheetExposesBottomDeleteAction() throws {
        let source = try readSourceFile("SSHApp/Views/ConnectionSheet.swift")
        let deleteBody = try extractMethodBody(from: source, methodName: "private func deleteEditingConnection")

        guard let tmuxSectionRange = source.range(of: "Section(\"Tmux (per-host)\")") else {
            XCTFail("ConnectionSheet must keep the tmux section before the bottom delete action")
            return
        }
        guard let deleteButtonRange = source.range(of: "Button(role: .destructive, action: confirmDeleteConnection)") else {
            XCTFail("Editing a connection must expose a destructive delete action")
            return
        }

        XCTAssertLessThan(
            tmuxSectionRange.lowerBound,
            deleteButtonRange.lowerBound,
            "Connection deletion must remain at the bottom of the edit form"
        )
        XCTAssertTrue(
            source.contains("if editingConnection != nil"),
            "Connection deletion must only be shown while editing an existing connection"
        )
        XCTAssertTrue(
            source.contains(".accessibilityIdentifier(\"connection.delete\")"),
            "The delete action must have a stable UI automation identifier"
        )
        XCTAssertTrue(
            source.contains(".alert(\"Delete Connection?\""),
            "Deleting a connection must require confirmation"
        )
        XCTAssertTrue(
            deleteBody.contains("connectionStore.delete(connection)"),
            "Confirmed deletion must use ConnectionStore so saved passwords are cleaned up"
        )
        XCTAssertTrue(
            deleteBody.contains("dismiss()"),
            "The edit sheet must close after deleting the connection"
        )
    }

    func testAddTabDoesNotCreatePlaceholderTabBeforeConnectionSelection() throws {
        let source = try readSourceFile("SSHApp/Views/MainView.swift")
        let body = try extractMethodBody(from: source, methodName: "private func addNewTab")

        XCTAssertTrue(
            body.contains("connectionSheet = .new"),
            "addNewTab must present the connection sheet"
        )
        XCTAssertFalse(
            body.contains("Tab("),
            "addNewTab must not create a placeholder terminal tab before a connection is selected"
        )
    }

    func testNoTabsHomeExposesSavedConnectionActionsAndNewConnectionRow() throws {
        let source = try readSourceFile("SSHApp/Views/MainView.swift")
        let tabSource = try readSourceFile("SSHApp/Views/TerminalTab.swift")

        XCTAssertTrue(
            source.contains("NoTabsConnectionHomeView"),
            "MainView must render a dedicated no-tabs home screen"
        )
        XCTAssertTrue(
            source.contains("SavedConnectionHomeRow"),
            "The no-tabs home screen must render saved connection rows"
        )
        XCTAssertTrue(
            source.contains("Image(systemName: \"pencil\")"),
            "Saved connection rows must expose an icon-only edit button"
        )
        XCTAssertTrue(
            source.contains("Button(\"Connect\", action: onConnect)"),
            "Saved connection rows must expose a Connect action"
        )
        XCTAssertTrue(
            source.contains("onNewConnection: {"),
            "The no-tabs home screen must receive an action for creating a connection"
        )
        XCTAssertTrue(
            source.contains("Label(\"New Connection\", systemImage: \"plus\")"),
            "The no-tabs home screen must expose a + New Connection row"
        )
        XCTAssertTrue(
            source.contains(".accessibilityIdentifier(\"connection.new\")"),
            "The new-connection row must have a stable UI automation identifier"
        )
        if let listRange = source.range(of: "Section(\"Saved Connections\")") {
            let sectionSource = source[listRange.lowerBound...]
            let rowsIndex = sectionSource.range(of: "ForEach(savedConnections)")?.lowerBound
            let newConnectionIndex = sectionSource.range(of: "Label(\"New Connection\"")?.lowerBound
            XCTAssertNotNil(rowsIndex)
            XCTAssertNotNil(newConnectionIndex)
            if let rowsIndex, let newConnectionIndex {
                XCTAssertLessThan(
                    rowsIndex,
                    newConnectionIndex,
                    "The + New Connection row must come after the saved connection rows"
                )
            }
        } else {
            XCTFail("The no-tabs home screen must keep the Saved Connections section")
        }
        XCTAssertFalse(
            source.contains("\"Tap + to add a new connection\""),
            "The no-tabs home screen must not show the legacy blank empty prompt"
        )
        XCTAssertFalse(
            tabSource.contains("\"Tap + to add a new connection\""),
            "Disconnected terminal placeholders must not reference the removed menu-bar + button"
        )
        XCTAssertFalse(
            source.contains("ContentUnavailableView"),
            "The no-tabs home screen must stay on the saved-connections list even when it is empty"
        )
    }

    func testNoTabsNewConnectionOnlyLivesInSavedConnectionsScreen() throws {
        let barSource = try readSourceFile("SSHApp/Views/UnifiedTopBar.swift")

        XCTAssertFalse(
            barSource.contains("if tabs.isEmpty"),
            "The no-tabs top bar must not show a standalone + button"
        )
        XCTAssertTrue(
            barSource.contains("titleWithShortcutHint(\"New Connection\", \"⌘N\", alignedAfter: rootMenuActionTitles)"),
            "New Connection must remain reachable from the connection menu when a terminal is active"
        )
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
