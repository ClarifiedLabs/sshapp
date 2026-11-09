@testable import GhosttyTerminal
import UIKit
import XCTest
@testable import SSHApp

@MainActor
final class TerminalFindPresentationTests: XCTestCase {
    func testWaitsForTargetVisibilityAndSearchesOnlyRequestedSurface() async {
        let first = mount()
        let second = mount()
        defer { unmount(first); unmount(second) }
        second.view.isHostVisible = false
        let registry = TerminalFontSizeTargetRegistry()
        let firstID = UUID()
        let secondID = UUID()
        registry.register(first.view, for: .hostTab(firstID))
        registry.register(second.view, for: .hostTab(secondID))
        var attempts = 0

        let presented = await TerminalFindPresentation.presentWhenReady(
            target: {
                attempts += 1
                if attempts == 2 { second.view.isHostVisible = true }
                return registry.target(for: .hostTab(secondID))
            },
            isCurrent: { true }
        )

        XCTAssertTrue(presented)
        XCTAssertEqual(attempts, 2)
        XCTAssertFalse(first.view.isFindPresented)
        XCTAssertTrue(second.view.isFindPresented)
    }

    func testInvalidatedRequestStopsResolvingTargets() async {
        var resolutions = 0
        var current = true
        let presented = await TerminalFindPresentation.presentWhenReady(
            target: {
                resolutions += 1
                current = false
                return nil
            },
            isCurrent: { current }
        )
        XCTAssertFalse(presented)
        XCTAssertEqual(resolutions, 1)
    }

    func testCancellationWhileWaitingStopsPresentation() async {
        var resolutions = 0
        let task = Task { @MainActor in
            await TerminalFindPresentation.presentWhenReady(
                target: {
                    resolutions += 1
                    // Cancel after one failed lookup, while waiting for the
                    // next visibility/menu-dismissal retry.
                    withUnsafeCurrentTask { $0?.cancel() }
                    return nil
                },
                isCurrent: { true }
            )
        }
        let presented = await task.value
        XCTAssertFalse(presented)
        XCTAssertEqual(resolutions, 1)
    }

    func testTmuxPaneLookupIsScopedToHostTab() async {
        let first = mount()
        let second = mount()
        defer { unmount(first); unmount(second) }
        let registry = TerminalFontSizeTargetRegistry()
        let paneID = TmuxPaneID(rawValue: 7)
        let firstTabID = UUID()
        let secondTabID = UUID()
        registry.register(first.view, for: .tmuxPane(tabID: firstTabID, paneID: paneID))
        registry.register(second.view, for: .tmuxPane(tabID: secondTabID, paneID: paneID))

        let presented = await TerminalFindPresentation.presentWhenReady(
            target: { registry.target(for: .tmuxPane(tabID: secondTabID, paneID: paneID)) },
            isCurrent: { true }
        )

        XCTAssertTrue(presented)
        XCTAssertFalse(first.view.isFindPresented)
        XCTAssertTrue(second.view.isFindPresented)
    }

    func testTabMenusUseExplicitTargetsAndKeepGlobalSettingsUnchanged() throws {
        let source = try readSourceFile("SSHApp/Views/UnifiedTopBar.swift")
        let hostPill = try extractMethodBody(from: source, methodName: "struct HostSessionTabPill")
        let tmuxPill = try extractMethodBody(from: source, methodName: "struct TmuxWindowTabPill")
        let settings = try extractMethodBody(from: source, methodName: "struct SessionSettingsMenu")
        XCTAssertTrue(hostPill.contains(".contextMenu"))
        XCTAssertTrue(hostPill.contains("Button(action: onFind)"))
        XCTAssertTrue(hostPill.contains("terminal.hostTab.context.find"))
        XCTAssertTrue(tmuxPill.contains("onFind(activePaneID)"))
        XCTAssertTrue(tmuxPill.contains("terminal.tmuxWindow.context.find"))
        XCTAssertFalse(settings.contains("Find in Terminal"))

        let main = try readSourceFile("SSHApp/Views/MainView.swift")
        let hostFind = try extractMethodBody(from: main, methodName: "private func findInHostTab")
        let tmuxFind = try extractMethodBody(from: main, methodName: "private func findInTmuxWindow")
        XCTAssertTrue(hostFind.contains("selectTab(tab)"))
        XCTAssertTrue(hostFind.contains(".hostTab(tab.id)"))
        XCTAssertTrue(tmuxFind.contains("Task { await controller.selectWindow(windowID) }"))
        XCTAssertTrue(tmuxFind.contains(".tmuxPane(tabID: tabID, paneID: paneID)"))
        XCTAssertTrue(tmuxFind.contains("controller.activeWindowID == windowID"))
        XCTAssertTrue(tmuxFind.contains("controller.activePaneID == paneID"))
        let sceneChange = try extractMethodBody(from: main, methodName: ".onChange(of: scenePhase)")
        let lockChange = try extractMethodBody(from: main, methodName: ".onChange(of: isAppUnlocked)")
        XCTAssertTrue(sceneChange.contains("terminalFindTask?.cancel()"))
        XCTAssertTrue(lockChange.contains("terminalFindTask?.cancel()"))
    }

    private struct Mounted {
        let view: UITerminalView
        let window: UIWindow
        let session: VTTerminalSession
    }

    private func mount() -> Mounted {
        let session = VTTerminalSession(write: { _ in }, resize: { _ in })
        let view = UITerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let window = UIWindow(frame: view.bounds)
        let root = UIViewController()
        window.rootViewController = root
        root.view.addSubview(view)
        window.isHidden = false
        view.configuration = .init(backend: .vt(session))
        view.controller = TerminalController()
        view.findApplicationActive = true
        view.layoutIfNeeded()
        return Mounted(view: view, window: window, session: session)
    }

    private func unmount(_ mounted: Mounted) {
        mounted.view.dismissFind(restoringFocus: false)
        mounted.view.controller = nil
        mounted.window.isHidden = true
        mounted.session.finish()
    }
}
