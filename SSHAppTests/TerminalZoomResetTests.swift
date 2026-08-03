@testable import GhosttyTerminal
import UIKit
import XCTest
@testable import SSHApp

private final class FontSizeResetResizeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCount = 0

    var count: Int {
        lock.withLock { storedCount }
    }

    func record() {
        lock.withLock { storedCount += 1 }
    }
}

private struct MountedFontSizeResetTerminal {
    let terminal: UITerminalView
    let window: UIWindow
    let previousKeyWindow: UIWindow?
}

@MainActor
private final class FontSizeResetSpyTerminalView: UITerminalView {
    var resetResult = true
    private(set) var resetCallCount = 0

    override func resetFontSize() -> Bool {
        resetCallCount += 1
        return resetResult
    }
}

final class TerminalZoomResetTests: XCTestCase {
    @MainActor
    func testResetWithoutLiveSurfaceFailsWithoutChangingConfiguredBaseline() {
        let view = UITerminalView(frame: .zero)
        view.configuredFontSize = 3

        XCTAssertFalse(view.resetFontSize())
        XCTAssertEqual(view.configuredFontSize, 3)

        view.configuredFontSize = 2
        XCTAssertEqual(view.configuredFontSize, 2)
    }

    @MainActor
    func testLiveSurfaceResetUsesLatestLowConfiguredBaselineAndRefreshesResize() throws {
        let mounted = try mountTerminal()
        defer { unmountTerminal(mounted) }

        let resizeRecorder = FontSizeResetResizeRecorder()
        let session = InMemoryTerminalSession(
            write: { _ in },
            resize: { _ in resizeRecorder.record() }
        )
        let initialConfiguration = TerminalConfiguration { builder in
            builder.withFontSize(3)
        }
        let controller = TerminalController(
            terminalConfiguration: initialConfiguration
        )
        let terminal = mounted.terminal
        terminal.configuredFontSize = 3
        terminal.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        terminal.controller = controller

        let surface = try XCTUnwrap(terminal.surface)
        XCTAssertTrue(surface.performBindingAction("increase_font_size:1"))
        terminal.currentFontSize = 4
        terminal.isFontSizeTransientlyAdjusted = true

        let updatedConfiguration = TerminalConfiguration { builder in
            builder.withFontSize(2)
        }
        XCTAssertTrue(controller.setTerminalConfiguration(updatedConfiguration))
        terminal.configuredFontSize = 2
        XCTAssertEqual(terminal.currentFontSize, 4)

        let resizeCountBeforeReset = resizeRecorder.count
        XCTAssertTrue(terminal.resetFontSize())
        XCTAssertFalse(terminal.isFontSizeTransientlyAdjusted)
        XCTAssertEqual(terminal.currentFontSize, 2)
        XCTAssertGreaterThan(resizeRecorder.count, resizeCountBeforeReset)
    }

    @MainActor
    func testTwoFingerResetGestureAndAccessibilityActionAreInstalled() {
        let view = UITerminalView(frame: .zero)
        let resetTaps = (view.gestureRecognizers ?? [])
            .compactMap { $0 as? UITapGestureRecognizer }
            .filter { $0.numberOfTapsRequired == 1 && $0.numberOfTouchesRequired == 2 }

        XCTAssertEqual(resetTaps.count, 1)
        XCTAssertEqual(
            view.accessibilityCustomActions?.map(\.name),
            ["Reset Font Size"]
        )
        XCTAssertFalse(
            view.isAccessibilityElement,
            "The custom action must not make the terminal a leaf that hides selection handles"
        )
    }

    @MainActor
    func testRegistryKeepsHostTabTargetsIsolated() {
        let registry = TerminalFontSizeTargetRegistry()
        let firstID = UUID()
        let secondID = UUID()
        let first = FontSizeResetSpyTerminalView(frame: .zero)
        let second = FontSizeResetSpyTerminalView(frame: .zero)

        registry.register(first, for: .hostTab(firstID))
        registry.register(second, for: .hostTab(secondID))

        XCTAssertTrue(registry.resetFontSize(for: .hostTab(firstID)))
        XCTAssertEqual(first.resetCallCount, 1)
        XCTAssertEqual(second.resetCallCount, 0)
    }

    @MainActor
    func testRegistryScopesReusedTmuxPaneIDsByHostTab() {
        let registry = TerminalFontSizeTargetRegistry()
        let firstTabID = UUID()
        let secondTabID = UUID()
        let reusedPaneID = TmuxPaneID(rawValue: 7)
        let first = FontSizeResetSpyTerminalView(frame: .zero)
        let second = FontSizeResetSpyTerminalView(frame: .zero)

        registry.register(first, for: .tmuxPane(tabID: firstTabID, paneID: reusedPaneID))
        registry.register(second, for: .tmuxPane(tabID: secondTabID, paneID: reusedPaneID))

        XCTAssertTrue(
            registry.resetFontSize(
                for: .tmuxPane(tabID: secondTabID, paneID: reusedPaneID)
            )
        )
        XCTAssertEqual(first.resetCallCount, 0)
        XCTAssertEqual(second.resetCallCount, 1)
    }

    @MainActor
    func testStaleUnregisterCannotRemoveReplacementTarget() {
        let registry = TerminalFontSizeTargetRegistry()
        let key = TerminalFontSizeTargetKey.hostTab(UUID())
        let stale = FontSizeResetSpyTerminalView(frame: .zero)
        let replacement = FontSizeResetSpyTerminalView(frame: .zero)

        registry.register(stale, for: key)
        registry.register(replacement, for: key)
        registry.unregister(stale, for: key)

        XCTAssertTrue(registry.target(for: key) === replacement)
        XCTAssertTrue(registry.resetFontSize(for: key))
        XCTAssertEqual(stale.resetCallCount, 0)
        XCTAssertEqual(replacement.resetCallCount, 1)
    }

    @MainActor
    func testDeadWeakTargetFailsSafelyAndIsRemoved() {
        let registry = TerminalFontSizeTargetRegistry()
        let key = TerminalFontSizeTargetKey.hostTab(UUID())
        weak var releasedView: FontSizeResetSpyTerminalView?

        do {
            let view = FontSizeResetSpyTerminalView(frame: .zero)
            releasedView = view
            registry.register(view, for: key)
        }

        XCTAssertNil(releasedView)
        XCTAssertFalse(registry.resetFontSize(for: key))
        XCTAssertNil(registry.target(for: key))
    }

    func testResetImplementationUsesOneSurfaceLocalActionAndRefreshPath() throws {
        let source = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView.swift"
        )
        XCTAssertEqual(
            source.components(separatedBy: "performBindingAction(\"reset_font_size\")").count - 1,
            1
        )
        guard let actionGuard = source.range(of: "guard action() else { return false }") else {
            return XCTFail("Reset must reject a failed native action before mutating local UI state")
        }
        let dismissMenus = try XCTUnwrap(source.range(
            of: "dismissTerminalEditMenus()",
            range: actionGuard.upperBound..<source.endIndex
        ))
        XCTAssertLessThan(actionGuard.lowerBound, dismissMenus.lowerBound)
        XCTAssertTrue(source.contains("cancelTouchSelectionInteraction()"))
        XCTAssertTrue(source.contains("dismissSelectionHandles()"))
        XCTAssertTrue(source.contains("core.synchronizeMetrics()"))
        XCTAssertTrue(source.contains("refreshTextInputGeometry(reason: \"font-size-reset\")"))
        XCTAssertTrue(source.contains("currentFontSize = configuredFontSize"))
        XCTAssertTrue(source.contains("isFontSizeTransientlyAdjusted = false"))
        XCTAssertFalse(source.contains("UserDefaults"))
        XCTAssertFalse(source.contains("setTerminalConfiguration"))
    }

    func testConfiguredBaselinePreservesTransientAdjustmentUntilReset() throws {
        let source = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView.swift"
        )

        XCTAssertTrue(source.contains("static let minFontSize: Float = 1"))
        XCTAssertTrue(source.contains("if !isFontSizeTransientlyAdjusted"))
        XCTAssertTrue(source.contains("currentFontSize = configuredFontSize"))
        XCTAssertTrue(source.contains("resetFontAdjustmentTrackingForSurfaceReplacement()"))
    }

    func testZoomPathsMarkAdjustmentOnlyAfterSuccessfulAction() throws {
        let pinchSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+PinchZoom.swift"
        )
        let keyboardSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+Keyboard.swift"
        )

        guard let increaseAction = pinchSource.range(
            of: "performBindingAction(\"increase_font_size:1\") == true"
        ),
        let increaseAdjusted = pinchSource.range(
            of: "isFontSizeTransientlyAdjusted = true",
            range: increaseAction.upperBound..<pinchSource.endIndex
        ),
        let keyboardAction = keyboardSource.range(of: "let actionApplied = surface.sendKeyEvent"),
        let keyboardGuard = keyboardSource.range(of: "if actionApplied, let keyboardZoomDirection"),
        let keyboardAdjusted = keyboardSource.range(of: "isFontSizeTransientlyAdjusted = true")
        else {
            return XCTFail("Zoom actions must gate transient adjustment tracking on successful delivery")
        }

        XCTAssertLessThan(increaseAction.lowerBound, increaseAdjusted.lowerBound)
        XCTAssertLessThan(keyboardAction.lowerBound, keyboardGuard.lowerBound)
        XCTAssertLessThan(keyboardGuard.lowerBound, keyboardAdjusted.lowerBound)
    }

    func testCommandZeroUsesTheAuthoritativeResetOperation() throws {
        let source = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+Keyboard.swift"
        )
        let shortcutCheck = try XCTUnwrap(source.range(of: "if isCommandFontResetShortcut("))
        let sharedReset = try XCTUnwrap(source.range(
            of: "resetFontSize(applying:",
            range: shortcutCheck.upperBound..<source.endIndex
        ))
        let nativeKeyDelivery = try XCTUnwrap(source.range(
            of: "surface.sendKeyEvent(keyEvent)",
            range: sharedReset.upperBound..<source.endIndex
        ))

        XCTAssertLessThan(shortcutCheck.lowerBound, sharedReset.lowerBound)
        XCTAssertLessThan(sharedReset.lowerBound, nativeKeyDelivery.lowerBound)
        XCTAssertTrue(source.contains("key.charactersIgnoringModifiers].contains(\"0\")"))
    }

    func testResetTapWaitsForPinchAndUsesSelectionArbitration() throws {
        let pinchSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+PinchZoom.swift"
        )
        let interactionSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+Interaction.swift"
        )

        XCTAssertTrue(pinchSource.contains("resetTap.numberOfTapsRequired = 1"))
        XCTAssertTrue(pinchSource.contains("resetTap.numberOfTouchesRequired = 2"))
        XCTAssertTrue(pinchSource.contains("resetTap.require(toFail: pinch)"))
        XCTAssertTrue(pinchSource.contains("resetFontSize()"))
        XCTAssertTrue(interactionSource.contains("gestureRecognizer === fontSizeResetTapGesture"))
        XCTAssertTrue(interactionSource.contains("syntheticLeftButtonDown || selectionHandleMode != .none"))
        XCTAssertTrue(interactionSource.contains("touchesStartHandle || touchesEndHandle"))

        let terminalViewSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView.swift"
        )
        XCTAssertTrue(terminalViewSource.contains("self?.resetFontSize() ?? false"))
    }

    func testRepresentablesSynchronizeBaselineAndIdentitySafeRegistryLifecycle() throws {
        let cases = [
            (
                "SSHApp/Views/GhosttyTerminalView.swift",
                ".hostTab(tab.id)"
            ),
            (
                "SSHApp/Views/TmuxPaneTerminal.swift",
                ".tmuxPane(tabID: hostTabID, paneID: pane.id)"
            ),
        ]

        for (path, key) in cases {
            let source = try readSourceFile(path)
            XCTAssertGreaterThanOrEqual(
                source.components(separatedBy: "configuredFontSize = configuredFontSize").count - 1,
                2,
                path
            )
            XCTAssertGreaterThanOrEqual(
                source.components(separatedBy: key).count - 1,
                2,
                path
            )
            XCTAssertTrue(source.contains("static func dismantleUIView"), path)
            XCTAssertTrue(source.contains("unregisterFontSizeTarget"), path)
        }
    }

    func testPillMenusRouteExplicitIdentitiesAndLeaveSwitcherUntouched() throws {
        let topBarSource = try readSourceFile("SSHApp/Views/UnifiedTopBar.swift")
        let switcherSource = try readSourceFile("SSHApp/Views/ConnectionSwitcherView.swift")

        XCTAssertEqual(
            topBarSource.components(separatedBy: "Label(\"Reset Font Size\"").count - 1,
            2
        )
        XCTAssertTrue(topBarSource.contains("Button(action: onResetFontSize)"))
        XCTAssertTrue(
            topBarSource.contains("terminal.hostTab.context.resetFontSize.\\(tab.id.uuidString)")
        )
        XCTAssertTrue(topBarSource.contains("if let activePaneID = window.activePaneID"))
        XCTAssertTrue(topBarSource.contains("onResetFontSize(activePaneID)"))
        XCTAssertTrue(
            topBarSource.contains("terminal.tmuxWindow.context.resetFontSize.\\(window.id.rawValue)")
        )
        XCTAssertFalse(switcherSource.contains("Reset Font Size"))
    }

    func testMainViewOwnsRegistryAndRoutesExplicitKeys() throws {
        let source = try readSourceFile("SSHApp/Views/MainView.swift")

        XCTAssertTrue(
            source.contains("@State private var terminalFontSizeTargetRegistry = TerminalFontSizeTargetRegistry()")
        )
        XCTAssertTrue(source.contains("resetFontSize(for: .hostTab(tabID))"))
        XCTAssertTrue(source.contains(".tmuxPane(tabID: tabID, paneID: paneID)"))
        XCTAssertTrue(
            source.contains("fontSizeTargetRegistry: terminalFontSizeTargetRegistry")
        )
    }

    @MainActor
    private func mountTerminal() throws -> MountedFontSizeResetTerminal {
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

        return MountedFontSizeResetTerminal(
            terminal: terminal,
            window: window,
            previousKeyWindow: previousKeyWindow
        )
    }

    @MainActor
    private func unmountTerminal(_ mounted: MountedFontSizeResetTerminal) {
        mounted.terminal.removeFromSuperview()
        mounted.window.isHidden = true
        mounted.previousKeyWindow?.makeKey()
    }
}
