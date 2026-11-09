import UIKit
import XCTest
@testable import SSHApp

@MainActor
final class TerminalTabMenuTests: XCTestCase {
    func testHostWithoutLiveTerminalOnlyOffersCloseAndInvokesItsCallback() throws {
        let tab = Tab()
        var closes = 0
        let items = TerminalTabMenu.host(
            tab: tab,
            onClose: { closes += 1 },
            onNewTerminal: { XCTFail("Cannot open another terminal without a reusable session") },
            onFind: { XCTFail("Cannot find without a live terminal") },
            onResetFontSize: { XCTFail("Cannot reset without a live terminal") }
        )
        XCTAssertEqual(items.count, 1, "No leading separator when only Close is available")
        let close = try XCTUnwrap(actions(items).first)
        XCTAssertEqual(close.title, "Close Tab")
        XCTAssertEqual(close.systemImage, "xmark")
        XCTAssertTrue(close.isDestructive)
        XCTAssertEqual(close.id, "host.session.tab.close.\(tab.id.uuidString)")
        close.action()
        XCTAssertEqual(closes, 1)
    }

    func testHostFindAndResetAvailabilityAndCallbacks() throws {
        let tab = Tab(connectionState: .connected, session: SSHSession())
        var calls: [String] = []
        let items = TerminalTabMenu.host(
            tab: tab, onClose: { calls.append("close") }, onNewTerminal: nil,
            onFind: { calls.append("find") }, onResetFontSize: { calls.append("reset") }
        )
        let menuActions = actions(items)
        XCTAssertEqual(menuActions.map(\.title), ["Find in Terminal…", "Reset Font Size", "Close Tab"])
        XCTAssertEqual(menuActions.map(\.systemImage), ["magnifyingglass", "textformat.size", "xmark"])
        XCTAssertEqual(menuActions.map(\.accessibilityIdentifier), [
            "terminal.hostTab.context.find.\(tab.id.uuidString)",
            "terminal.hostTab.context.resetFontSize.\(tab.id.uuidString)",
            "host.session.tab.close.\(tab.id.uuidString)",
        ])
        XCTAssertEqual(menuActions.map(\.isDestructive), [false, false, true])
        XCTAssertEqual(items.count, 4)
        guard case .separator = items[2] else { return XCTFail("Close must be in its own group") }
        menuActions.forEach { $0.action() }
        XCTAssertEqual(calls, ["find", "reset", "close"])

        for state: ConnectionState in [.disconnected, .connecting, .failed("offline"), .awaitingInput, .connected] {
            tab.connectionState = state
            let available = actions(TerminalTabMenu.host(
                tab: tab, onClose: {}, onNewTerminal: nil, onFind: {}, onResetFontSize: {}
            )).map(\.title)
            if state == .connected || state == .awaitingInput {
                XCTAssertEqual(available, ["Find in Terminal…", "Reset Font Size", "Close Tab"])
            } else {
                XCTAssertEqual(available, ["Close Tab"])
            }
        }
        XCTAssertEqual(actions(TerminalTabMenu.host(
            tab: tab, onClose: {}, onNewTerminal: nil, onFind: nil, onResetFontSize: nil
        )).map(\.title), ["Close Tab"])
    }

    func testTmuxMenuTargetsChosenWindowPaneAndPreservesActionMetadata() throws {
        let controller = makeController()
        let paneID = TmuxPaneID(rawValue: 17)
        let window = TmuxWindow(id: TmuxWindowID(rawValue: 3), activePaneID: paneID)
        controller.windowOrder = [window.id, TmuxWindowID(rawValue: 4)]
        controller.activePaneID = TmuxPaneID(rawValue: 99)
        var found: [TmuxPaneID] = []
        var reset: [TmuxPaneID] = []
        let menuActions = actions(TerminalTabMenu.tmux(
            window: window, controller: controller,
            onFind: { found.append($0) }, onResetFontSize: { reset.append($0) }
        ))
        XCTAssertEqual(menuActions.map(\.title), [
            "New Window", "Split Right", "Split Down", "Find in Terminal…",
            "Reset Font Size", "Detach tmux", "Close Window",
        ])
        XCTAssertEqual(menuActions.map(\.systemImage), [
            "plus", "rectangle.split.2x1", "rectangle.split.1x2", "magnifyingglass",
            "textformat.size", "rectangle.portrait.and.arrow.right", "xmark",
        ])
        XCTAssertEqual(menuActions.map(\.accessibilityIdentifier), [
            "tmux.window.tab.new.3", "tmux.window.tab.split.right.3", "tmux.window.tab.split.down.3",
            "terminal.tmuxWindow.context.find.3", "terminal.tmuxWindow.context.resetFontSize.3",
            "tmux.window.tab.detach.3", "tmux.window.tab.close.3",
        ])
        try XCTUnwrap(menuActions.first { $0.title == "Find in Terminal…" }).action()
        try XCTUnwrap(menuActions.first { $0.title == "Reset Font Size" }).action()
        XCTAssertEqual(found, [paneID])
        XCTAssertEqual(reset, [paneID])
        XCTAssertEqual(menuActions.filter(\.isDestructive).map(\.title), ["Close Window"])
    }

    func testTmuxWithoutActivePaneKeepsSplitsButHidesFindResetAndLastWindowClose() {
        let controller = makeController()
        let window = TmuxWindow(id: TmuxWindowID(rawValue: 3))
        controller.windowOrder = [window.id]
        let items = TerminalTabMenu.tmux(
            window: window, controller: controller,
            onFind: { _ in XCTFail("No active pane") },
            onResetFontSize: { _ in XCTFail("No active pane") }
        )
        XCTAssertEqual(actions(items).map(\.title), ["New Window", "Split Right", "Split Down", "Detach tmux"])
        guard case .separator = items[3] else { return XCTFail("Detach must stay in its own group") }
    }

    func testUIKitConversionPreservesGroupsMetadataAndActionCallbacks() throws {
        var calls = 0
        let first = TerminalTabMenuAction(
            title: "Find in Terminal…", systemImage: "magnifyingglass", isDestructive: false,
            accessibilityIdentifier: "find", action: { calls += 1 }
        )
        let close = TerminalTabMenuAction(
            title: "Close Tab", systemImage: "xmark", isDestructive: true,
            accessibilityIdentifier: "close", action: { calls += 10 }
        )
        let elements = TerminalTabMenu.uiMenuElements([.action(first), .separator, .action(close)])
        let groups = try elements.map { try XCTUnwrap($0 as? UIMenu) }
        XCTAssertEqual(groups.count, 2)
        XCTAssertTrue(groups.allSatisfy { $0.options.contains(.displayInline) })
        let nativeActions = try groups.flatMap(\.children).map { try XCTUnwrap($0 as? UIAction) }
        XCTAssertEqual(nativeActions.map(\.title), [first.title, close.title])
        XCTAssertEqual(nativeActions.map(\.identifier.rawValue), ["find", "close"])
        XCTAssertEqual(nativeActions.map(\.accessibilityIdentifier), ["find", "close"])
        XCTAssertTrue(nativeActions.allSatisfy { $0.image != nil })
        XCTAssertFalse(nativeActions[0].attributes.contains(.destructive))
        XCTAssertTrue(nativeActions[1].attributes.contains(.destructive))
        let button = UIButton()
        button.addAction(nativeActions[0], for: .touchUpInside)
        button.addAction(nativeActions[1], for: .touchUpInside)
        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(calls, 11)
        XCTAssertTrue(TerminalTabMenu.uiMenuElements([]).isEmpty)
        XCTAssertEqual(TerminalTabMenu.uiMenuElements([.action(close)]).count, 1)
        XCTAssertTrue(TerminalTabMenu.uiMenuElements([.action(close)])[0] is UIAction)
    }

    private func actions(_ items: [TerminalTabMenuItem]) -> [TerminalTabMenuAction] {
        items.compactMap {
            if case .action(let action) = $0 { return action }
            return nil
        }
    }

    private func makeController() -> TmuxController {
        TmuxController(gateway: TmuxGateway(writer: { _ in }))
    }
}
