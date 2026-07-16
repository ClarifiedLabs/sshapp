import XCTest
@testable import SSHApp

final class UnifiedTopBarLayoutTests: XCTestCase {
    func testTabPillsKeepShortcutHintsTightToTitles() throws {
        let source = try readSourceFile("SSHApp/Views/UnifiedTopBar.swift")

        for structName in ["HostSessionTabPill", "TmuxWindowTabPill"] {
            let pillSource = try extractStructSource(named: structName, from: source)

            XCTAssertFalse(
                pillSource.contains("Spacer("),
                "\(structName) must not use a flexible spacer between its title and shortcut hint"
            )
            XCTAssertFalse(
                pillSource.contains("minWidth:"),
                "\(structName) must size short titles intrinsically instead of enforcing a wide minimum width"
            )
            XCTAssertFalse(
                pillSource.contains("idealWidth:"),
                "\(structName) must not force short titles into a wide ideal tab width"
            )
            XCTAssertTrue(
                pillSource.contains("HStack(spacing: TabPillLayout.shortcutSpacing)"),
                "\(structName) should use the compact shared shortcut spacing"
            )
        }
    }

    func testUnifiedTopBarUsesCompactIPhoneFirstMetrics() throws {
        let source = try readSourceFile("SSHApp/Views/UnifiedTopBar.swift")
        let hostBody = try extractMethodBody(from: source, methodName: "private var hostSessionPills")
        let tmuxBody = try extractMethodBody(from: source, methodName: "private func tmuxWindowPills")
        let plusBody = try extractMethodBody(from: source, methodName: "private var newTabButton")

        XCTAssertTrue(source.contains("static let maximumWidth: CGFloat = 110"))
        XCTAssertTrue(hostBody.contains("HStack(spacing: 6)"))
        XCTAssertTrue(tmuxBody.contains("HStack(spacing: 6)"))
        XCTAssertTrue(plusBody.contains("frameSize: 28"))
        XCTAssertTrue(source.contains("CircleIcon(systemImage: \"gearshape\", size: 16, filled: false)"))
    }

    func testConnectionPillIsButtonAndPresentsSwitcherAdaptively() throws {
        let source = try readSourceFile("SSHApp/Views/UnifiedTopBar.swift")
        let switcherSource = try readSourceFile("SSHApp/Views/ConnectionSwitcherView.swift")
        let pillBody = try extractMethodBody(from: source, methodName: "private func connectionPillButton")

        XCTAssertTrue(source.contains("@State private var isSwitcherPresented = false"))
        XCTAssertTrue(source.contains("@Environment(\\.horizontalSizeClass)"))
        XCTAssertTrue(source.contains("ConnectionSwitcherView("))
        XCTAssertTrue(source.contains(".presentationDetents([.medium, .large])"))
        XCTAssertTrue(source.contains(".popover("))
        XCTAssertTrue(switcherSource.contains("accessibilityIdentifier(\"connection.switcher\")"))
        XCTAssertTrue(pillBody.contains("Button {"))
        XCTAssertFalse(source.contains("private struct ConnectionMenuPill: View"))
        XCTAssertFalse(source.contains(".accessibilityIdentifier(\"connection.menu\")"))
    }

    func testHardwareKeyboardMonitorGatesVisualShortcutHints() throws {
        let source = try readSourceFile("SSHApp/Views/UnifiedTopBar.swift")
        let switcherSource = try readSourceFile("SSHApp/Views/ConnectionSwitcherView.swift")
        let monitorSource = try readSourceFile("SSHApp/Views/HardwareKeyboardMonitor.swift")
        let hostHintBody = try extractMethodBody(from: source, methodName: "private func hostShortcutHint")
        let tmuxHintBody = try extractMethodBody(from: source, methodName: "private func tmuxShortcutHint")

        XCTAssertTrue(monitorSource.contains("import GameController"))
        XCTAssertTrue(monitorSource.contains("GCKeyboard.coalesced != nil"))
        XCTAssertTrue(monitorSource.contains(".GCKeyboardDidConnect"))
        XCTAssertTrue(monitorSource.contains(".GCKeyboardDidDisconnect"))
        // A hardware keyboard reported by GameController is not enough: the
        // Simulator (and Stage Manager setups) can report the host keyboard as
        // attached while the on-screen software keyboard is in use. Hints must
        // additionally require the software keyboard to be hidden.
        XCTAssertTrue(
            monitorSource.contains("keyboardWillShowNotification")
                && monitorSource.contains("keyboardWillHideNotification"),
            "HardwareKeyboardMonitor must observe software-keyboard visibility"
        )
        XCTAssertTrue(
            monitorSource.contains("gameControllerKeyboardAttached && !softwareKeyboardVisible"),
            "isAttached must require a hardware keyboard AND a hidden software keyboard"
        )
        // Regression: a hard simulator override forced the keyboard-attached
        // signal to false, so shortcut hints never appeared even when a hardware
        // keyboard was genuinely connected (on device, or via the Simulator's
        // "Connect Hardware Keyboard"). Detection must rely on GameController in
        // all environments rather than disabling itself in the Simulator.
        XCTAssertFalse(
            monitorSource.contains("#if targetEnvironment(simulator)"),
            "HardwareKeyboardMonitor must not disable hardware-keyboard detection in the Simulator"
        )
        XCTAssertTrue(source.contains("@State private var hardwareKeyboardMonitor = HardwareKeyboardMonitor()"))
        XCTAssertTrue(hostHintBody.contains("guard hardwareKeyboardMonitor.isAttached else { return nil }"))
        XCTAssertTrue(tmuxHintBody.contains("guard hardwareKeyboardMonitor.isAttached else { return nil }"))
        XCTAssertTrue(source.contains("showsShortcutHints: showsShortcutHints"))
        XCTAssertTrue(switcherSource.contains("let showsShortcutHints: Bool"))
        XCTAssertTrue(switcherSource.contains("if showsShortcutHints"))
    }

    func testStatusAndChipCompactnessRules() throws {
        let source = try readSourceFile("SSHApp/Views/UnifiedTopBar.swift")
        let pillTitleBody = try extractMethodBody(from: source, methodName: "private func connectionPillTitle")
        let statusBody = try extractMethodBody(from: source, methodName: "private func statusColor")
        let hostPill = try extractStructSource(named: "HostSessionTabPill", from: source)

        XCTAssertTrue(statusBody.contains("case .connected:") && statusBody.contains("palette.success"))
        XCTAssertTrue(pillTitleBody.contains("connection.host"))
        XCTAssertTrue(pillTitleBody.contains("connection.port == 22"))
        XCTAssertTrue(pillTitleBody.contains("\"\\(connection.host):\\(connection.port)\""))
        XCTAssertFalse(hostPill.contains("Circle()"), "Host-session chips must not render status dots")
        XCTAssertFalse(source.contains("tmuxModeIndicator"))
        XCTAssertFalse(source.contains("tmux.mode.indicator"))
    }

    func testTmuxCloseWindowHiddenForLastWindowAndSelectsPreviousBeforeKillingCurrent() throws {
        let source = try readSourceFile("SSHApp/Views/UnifiedTopBar.swift")
        let tmuxPill = try extractStructSource(named: "TmuxWindowTabPill", from: source)

        XCTAssertTrue(tmuxPill.contains("if controller.windowOrder.count > 1"))
        XCTAssertTrue(tmuxPill.contains("if window.id == controller.activeWindowID"))
        XCTAssertLessThan(
            tmuxPill.range(of: "await controller.selectPreviousWindow()")?.lowerBound ?? tmuxPill.endIndex,
            tmuxPill.range(of: "await controller.killWindow(window.id)")?.lowerBound ?? tmuxPill.startIndex
        )
    }

    func testSwitcherTmuxActionsOnlyExpandForCurrentWindow() throws {
        let switcherSource = try readSourceFile("SSHApp/Views/ConnectionSwitcherView.swift")
        let entryRowsBody = try extractMethodBody(from: switcherSource, methodName: "private func entryRows")

        XCTAssertTrue(
            entryRowsBody.contains("if window.isCurrent,")
                && entryRowsBody.contains("expandedActionsWindowID == window.id"),
            "The tmux actions row must only expand for the current window that owns the ellipsis"
        )
        XCTAssertTrue(
            entryRowsBody.contains("isCurrentWindow: true"),
            "Expanded switcher actions are current-window actions and must close by selecting previous before kill"
        )
    }

    func testSwitcherTmuxShortcutHintsOnlyAppearForSelectedSession() throws {
        let switcherSource = try readSourceFile("SSHApp/Views/ConnectionSwitcherView.swift")
        let entryRowsBody = try extractMethodBody(from: switcherSource, methodName: "private func entryRows")
        let shortcutBody = try extractMethodBody(
            from: switcherSource,
            methodName: "private func tmuxShortcutHint"
        )

        XCTAssertTrue(
            entryRowsBody.contains("isSelectedSession: isSelected"),
            "Each tmux window block must derive shortcut hints from its own tab selection state"
        )
        XCTAssertTrue(
            shortcutBody.contains("guard showsShortcutHints, isSelectedSession else { return nil }"),
            "Inactive tmux sessions sharing the selected SSH connection must not advertise active shortcuts"
        )
        XCTAssertFalse(
            switcherSource.contains("isCurrentConnection"),
            "Connection-level selection is too broad when one SSH session contains multiple terminal tabs"
        )
    }

    func testNoSplitPaneNativeCommandsWereAdded() throws {
        let commandSource = try readSourceFile("SSHApp/App/SSHAppCommands.swift")
        let mainSource = try readSourceFile("SSHApp/Views/MainView.swift")

        XCTAssertFalse(commandSource.contains("splitTmuxPaneRight"))
        XCTAssertFalse(commandSource.contains("splitTmuxPaneDown"))
        XCTAssertFalse(commandSource.contains("canSplitTmuxPane"))
        XCTAssertFalse(commandSource.contains(".keyboardShortcut(\"d\", modifiers: .command)"))
        XCTAssertFalse(mainSource.contains("splitTmuxPaneRight"))
        XCTAssertFalse(mainSource.contains("splitTmuxPaneDown"))
    }

    private func extractStructSource(named name: String, from source: String) throws -> String {
        let declaration = "struct \(name): View"
        let start = try XCTUnwrap(source.range(of: declaration)?.lowerBound)
        let openBrace = try XCTUnwrap(source[start...].firstIndex(of: "{"))

        var depth = 0
        var index = openBrace

        while index < source.endIndex {
            switch source[index] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(source[start...index])
                }
            default:
                break
            }

            index = source.index(after: index)
        }

        XCTFail("Could not find the end of \(declaration)")
        return ""
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
        var index = braceStart

        while index < source.endIndex {
            switch source[index] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(source[braceStart...index])
                }
            default:
                break
            }

            index = source.index(after: index)
        }

        throw NSError(domain: "Test", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "Could not find closing brace for '\(methodName)'"])
    }
}
