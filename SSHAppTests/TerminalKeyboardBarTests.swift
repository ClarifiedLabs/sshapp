import XCTest

/// Regression tests for the SwiftUI host keyboard bar and its settings-menu toggle.
final class TerminalKeyboardBarTests: XCTestCase {
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
                && tabSource.contains("TerminalKeyboardBar(")
                && tabSource.contains("target: keyboardBarTarget"),
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

    /// The keyboard bar should reclaim the home-indicator dead space by lowering
    /// the actual `safeAreaInset` content into the bottom container inset. A child
    /// `.ignoresSafeArea` alone does not move content that `safeAreaInset` already
    /// anchored above the safe area.
    func testKeyboardBarReclaimsBottomSafeAreaDeadSpace() throws {
        let tabSource = try readSourceFile("SSHApp/Views/TerminalTab.swift")
        let barSource = try readSourceFile("SSHApp/Views/TerminalKeyboardBar.swift")

        XCTAssertTrue(
            tabSource.contains("ContainerSafeAreaInsetReader")
                && tabSource.contains("bottomContainerSafeAreaInset = insets.bottom"),
            "TerminalTab must read the bottom container safe-area inset"
        )
        XCTAssertTrue(
            tabSource.contains("keyboardBarBottomClearance - bottomContainerSafeAreaInset"),
            "The safeAreaInset content must be lowered by the bottom container safe area"
        )
        XCTAssertFalse(
            tabSource.contains(".ignoresSafeArea(.container, edges: .bottom)"),
            "A child ignoresSafeArea does not move safeAreaInset content lower"
        )
        XCTAssertFalse(
            barSource.contains(".padding(.bottom, 8)"),
            "The keyboard bar must not hard-code bottom padding that recreates the home-indicator dead space"
        )
    }

    /// Regression: the dead-space reclamation lowers the bar by the container
    /// inset, but `window.safeAreaInsets.bottom` never includes the software
    /// keyboard. Applying that negative padding while the keyboard is on screen
    /// would push the bar down into the top row of keys. The negative padding
    /// must therefore be gated on software-keyboard visibility so the bar rides
    /// on top of the keyboard while typing.
    func testKeyboardBarDoesNotOverlapSoftwareKeyboard() throws {
        let tabSource = try readSourceFile("SSHApp/Views/TerminalTab.swift")
        let paddingBody = try extractMethodBody(
            from: tabSource,
            methodName: "private var keyboardBarBottomPadding"
        )

        XCTAssertTrue(
            paddingBody.contains("guard !isSoftwareKeyboardVisible else { return 0 }"),
            "Negative padding must not apply while the software keyboard is visible"
        )
        XCTAssertTrue(
            tabSource.contains("keyboardWillShowNotification")
                && tabSource.contains("keyboardWillHideNotification")
                && tabSource.contains("keyboardWillChangeFrameNotification"),
            "TerminalTab must observe software-keyboard visibility to gate the bar padding"
        )
        XCTAssertTrue(
            tabSource.contains("isSoftwareKeyboardVisible = visible"),
            "Keyboard visibility must drive the padding gate state"
        )
    }

    /// The `showsKeyboardBar` toggle must gate the host SwiftUI bar, not
    /// libghostty's UIKit inputAccessoryView.
    func testKeyboardBarToggleGatesHostBar() throws {
        let source = try readSourceFile("SSHApp/Views/TerminalTab.swift")
        let predicate = try extractMethodBody(
            from: source,
            methodName: "private var shouldShowKeyboardBar"
        )
        XCTAssertTrue(
            predicate.contains("canAcceptTerminalInput")
                && predicate.contains("showsKeyboardBar")
                && predicate.contains("!isSoftwareKeyboardSuppressed"),
            "TerminalTab must gate the full host bar on input availability, the preference, and suppression"
        )
    }

    func testSuppressionControlsHaveStablePresentationAndActions() throws {
        let tabSource = try readSourceFile("SSHApp/Views/TerminalTab.swift")
        let barSource = try readSourceFile("SSHApp/Views/TerminalKeyboardBar.swift")

        XCTAssertTrue(
            barSource.contains("HStack(spacing: 0)")
                && barSource.contains("ScrollView(.horizontal")
                && barSource.contains("Button(action: onHideKeyboard)"),
            "Hide Keyboard must be a fixed sibling outside the scrolling shortcut content"
        )
        XCTAssertTrue(
            barSource.contains(".accessibilityLabel(\"Hide Keyboard\")")
                && barSource.contains(".accessibilityIdentifier(\"terminal.keyboard.hide\")")
                && barSource.contains(".accessibilityLabel(\"Show Keyboard\")")
                && barSource.contains(".accessibilityIdentifier(\"terminal.keyboard.show\")"),
            "Suppression controls must keep stable accessible labels and identifiers"
        )
        XCTAssertTrue(
            barSource.contains("static let size: CGFloat = 44")
                && barSource.contains(".regularMaterial"),
            "Show Keyboard must provide a 44-point material hit target"
        )
        XCTAssertTrue(
            tabSource.contains(".overlay(alignment: .bottomTrailing)")
                && tabSource.contains("TerminalKeyboardRestoreButton(action: showSoftwareKeyboard)")
                && tabSource.contains(".zIndex(40_000)"),
            "Show Keyboard must be a non-reserving overlay above tmux overlays"
        )
        XCTAssertTrue(
            tabSource.contains("trailingContainerSafeAreaInset")
                && tabSource.contains(".padding(.trailing, keyboardRestoreTrailingPadding)"),
            "Show Keyboard must remain clear of the trailing safe area in landscape"
        )

        let restorePredicate = try extractMethodBody(
            from: tabSource,
            methodName: "private var shouldShowKeyboardRestoreControl"
        )
        XCTAssertTrue(restorePredicate.contains("canAcceptTerminalInput"))
        XCTAssertTrue(restorePredicate.contains("isSoftwareKeyboardSuppressed"))
        XCTAssertFalse(
            restorePredicate.contains("showsKeyboardBar"),
            "Show Keyboard must remain available when the Keyboard Bar preference is disabled"
        )

        let hideAction = try extractMethodBody(
            from: tabSource,
            methodName: "private func hideSoftwareKeyboard"
        )
        assertOccurrence(
            "keyboardBarTarget.suppressSoftwareKeyboard()",
            precedes: "onSoftwareKeyboardSuppressionChange(true)",
            in: hideAction
        )
        let showAction = try extractMethodBody(
            from: tabSource,
            methodName: "private func showSoftwareKeyboard"
        )
        assertOccurrence(
            "keyboardBarTarget.restoreSoftwareKeyboard()",
            precedes: "onSoftwareKeyboardSuppressionChange(false)",
            in: showAction
        )
    }

    func testSuppressionStateIsSceneLocalAndPropagatesToAllTerminalBranches() throws {
        let mainSource = try readSourceFile("SSHApp/Views/MainView.swift")
        let tabSource = try readSourceFile("SSHApp/Views/TerminalTab.swift")

        XCTAssertTrue(
            mainSource.contains("@State private var isSoftwareKeyboardSuppressed = false"),
            "MainView must own one scene-lifetime suppression mode"
        )
        XCTAssertFalse(
            mainSource.contains("@AppStorage(AppSettingsKey.isSoftwareKeyboardSuppressed)"),
            "Suppression is runtime state, not a persisted preference"
        )
        XCTAssertTrue(
            mainSource.contains("isSoftwareKeyboardSuppressed: isSoftwareKeyboardSuppressed")
                && mainSource.contains("onSoftwareKeyboardSuppressionChange:"),
            "MainView must pass the shared value and writer to every retained TerminalTab"
        )
        XCTAssertGreaterThanOrEqual(
            tabSource.components(separatedBy: "suppressesSoftwareKeyboard: isSoftwareKeyboardSuppressed").count - 1,
            2,
            "TerminalTab must propagate suppression to direct and tmux rendering branches"
        )
        XCTAssertTrue(
            tabSource.contains("let suppressesSoftwareKeyboard: Bool")
                && tabSource.contains("suppressesSoftwareKeyboard: suppressesSoftwareKeyboard"),
            "Every tmux window must forward suppression to every pane"
        )
    }

    func testRepresentablesApplySuppressionBeforeAnyFocusUpdate() throws {
        let expectations = [
            (
                "SSHApp/Views/GhosttyTerminalView.swift",
                "coordinator.updateHostTabActiveState"
            ),
            (
                "SSHApp/Views/TmuxPaneTerminal.swift",
                "coordinator.updateFocusedState"
            ),
        ]

        for (path, activeUpdate) in expectations {
            let source = try readSourceFile(path)
            let makeBody = try extractMethodBody(from: source, methodName: "func makeUIView")
            let updateBody = try extractMethodBody(from: source, methodName: "func updateUIView")

            assertOccurrence(
                "tv.suppressesSoftwareKeyboard = suppressesSoftwareKeyboard",
                precedes: activeUpdate,
                in: makeBody,
                message: "\(path) must suppress newly-created terminals before focus"
            )
            assertOccurrence(
                "uiView.suppressesSoftwareKeyboard = suppressesSoftwareKeyboard",
                precedes: activeUpdate,
                in: updateBody,
                message: "\(path) must update suppression before active/focused state"
            )
        }
    }

    func testSystemKeyboardDismissCallbacksAreScopedAndForwarded() throws {
        let representables = [
            (
                path: "SSHApp/Views/GhosttyTerminalView.swift",
                activeGuard: "isHostTabActive",
                focusUpdate: "coordinator.updateHostTabActiveState"
            ),
            (
                path: "SSHApp/Views/TmuxPaneTerminal.swift",
                activeGuard: "isFocused",
                focusUpdate: "coordinator.updateFocusedState"
            ),
        ]

        for representable in representables {
            let source = try readSourceFile(representable.path)
            let makeBody = try extractMethodBody(from: source, methodName: "func makeUIView")
            let updateBody = try extractMethodBody(from: source, methodName: "func updateUIView")
            let dismantleBody = try extractMethodBody(
                from: source,
                methodName: "static func dismantleUIView"
            )
            let handlerBody = try extractMethodBody(
                from: source,
                methodName: "func handleSystemSoftwareKeyboardDismiss"
            )

            XCTAssertTrue(
                makeBody.contains("tv.onSystemSoftwareKeyboardDismiss =")
                    && makeBody.contains("[weak coordinator, weak tv]"),
                "\(representable.path) must weakly forward the source terminal callback"
            )
            assertOccurrence(
                "coordinator.onSystemSoftwareKeyboardDismiss = onSystemSoftwareKeyboardDismiss",
                precedes: "tv.suppressesSoftwareKeyboard = suppressesSoftwareKeyboard",
                in: makeBody,
                message: "\(representable.path) must store the callback before initial suppression/focus"
            )
            assertOccurrence(
                "coordinator.onSystemSoftwareKeyboardDismiss = onSystemSoftwareKeyboardDismiss",
                precedes: "uiView.suppressesSoftwareKeyboard = suppressesSoftwareKeyboard",
                in: updateBody,
                message: "\(representable.path) must refresh the callback before suppression/focus updates"
            )
            assertOccurrence(
                "uiView.suppressesSoftwareKeyboard = suppressesSoftwareKeyboard",
                precedes: representable.focusUpdate,
                in: updateBody
            )
            XCTAssertTrue(
                dismantleBody.contains("uiView.onSystemSoftwareKeyboardDismiss = nil")
                    && dismantleBody.contains("coordinator.onSystemSoftwareKeyboardDismiss = nil"),
                "\(representable.path) must clear both callback references during dismantle"
            )
            XCTAssertTrue(
                handlerBody.contains("surfaceAttached")
                    && handlerBody.contains(representable.activeGuard)
                    && handlerBody.contains("terminalView === source"),
                "\(representable.path) must reject inactive, detached, or stale terminal callbacks"
            )
        }

        let tabSource = try readSourceFile("SSHApp/Views/TerminalTab.swift")
        XCTAssertEqual(
            tabSource.components(
                separatedBy: "onSystemSoftwareKeyboardDismiss: hideSoftwareKeyboard"
            ).count - 1,
            2,
            "TerminalTab must route direct and tmux system dismissals through its existing hide action"
        )
        XCTAssertTrue(
            tabSource.contains("onSystemSoftwareKeyboardDismiss: onSystemSoftwareKeyboardDismiss"),
            "TmuxWindowTerminalView must forward the callback to each pane"
        )

        let harnessSource = try readSourceFile(
            "SSHApp/Testing/KeyboardSuppressionUITestHarnessView.swift"
        )
        XCTAssertTrue(
            harnessSource.contains("TerminalTab(")
                && harnessSource.contains("onSoftwareKeyboardSuppressionChange:"),
            "The UI harness direct surface must exercise TerminalTab's production callback path"
        )
        XCTAssertEqual(
            harnessSource.components(
                separatedBy: "onSystemSoftwareKeyboardDismiss: hideSoftwareKeyboard"
            ).count - 1,
            1,
            "The UI harness must wire its raw tmux surfaces to the shared suppression state"
        )
        XCTAssertTrue(
            harnessSource.contains("activeSurface != .direct && showsKeyboardBar")
                && harnessSource.contains("activeSurface != .direct && suppressesSoftwareKeyboard"),
            "Harness-level controls must not duplicate TerminalTab's direct-surface controls"
        )
    }

    func testApplicationFocusResignationsUseMarkedTerminalAPI() throws {
        let lifecycleSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+Lifecycle.swift"
        )
        let markedResignBody = try extractMethodBody(
            from: lifecycleSource,
            methodName: "public func resignFirstResponderForApplicationAction"
        )
        XCTAssertTrue(
            markedResignBody.contains("markApplicationResponderResignIntent()")
                && markedResignBody.contains("applicationResponderResignDepth += 1")
                && markedResignBody.contains("return resignFirstResponder()"),
            "The public app-resign API must mark intent around the ordinary UIKit responder call"
        )

        let callSites = [
            (
                path: "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+Interaction.swift",
                method: "override open func touchesEnded"
            ),
            (
                path: "Packages/SSHAppGhostty/Sources/GhosttyTerminal/View/TerminalViewRepresentable.swift",
                method: "static func synchronizeFocus"
            ),
            (
                path: "SSHApp/Views/GhosttyTerminalView.swift",
                method: "func updateHostTabActiveState"
            ),
            (
                path: "SSHApp/Views/TmuxPaneTerminal.swift",
                method: "func updateFocusedState"
            ),
        ]

        for callSite in callSites {
            let source = try readSourceFile(callSite.path)
            let body = try extractMethodBody(from: source, methodName: callSite.method)
            XCTAssertTrue(
                body.contains("resignFirstResponderForApplicationAction()"),
                "\(callSite.path) must mark its app-driven focus resignation"
            )
            XCTAssertFalse(
                body.contains(".resignFirstResponder()"),
                "\(callSite.path) must not leave an unmarked product resignation"
            )
        }
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

    // MARK: - Helpers

    private func assertOccurrence(
        _ first: String,
        precedes second: String,
        in source: String,
        message: String = "Expected operations to remain in order",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let firstRange = source.range(of: first),
              let secondRange = source.range(of: second) else {
            XCTFail("\(message): missing operation", file: file, line: line)
            return
        }
        XCTAssertLessThan(
            firstRange.lowerBound,
            secondRange.lowerBound,
            message,
            file: file,
            line: line
        )
    }

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
