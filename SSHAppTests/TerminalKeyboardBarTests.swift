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
