//
//  TmuxControllerTests.swift
//  SSHAppTests
//
//  Tests TmuxController against a real gateway with a recording writer,
//  feeding scripted protocol lines to drive scenarios.
//

import XCTest
@testable import SSHApp

@MainActor
final class TmuxControllerTests: XCTestCase {

    private final class RecordingWriter: @unchecked Sendable {
        let lock = NSLock()
        private var bytes: Data = Data()

        var captured: Data {
            lock.withLock { bytes }
        }

        var capturedString: String {
            String(data: captured, encoding: .utf8) ?? ""
        }

        func write(_ data: Data) async throws {
            lock.withLock { bytes.append(data) }
        }

        func reset() {
            lock.withLock { bytes.removeAll() }
        }
    }

    private func makeStack(
        settings: TmuxSettings = .default
    ) async -> (TmuxGateway, TmuxController, RecordingWriter) {
        let writer = RecordingWriter()
        let gateway = TmuxGateway(writer: { data in try await writer.write(data) })
        let controller = TmuxController(gateway: gateway, settings: settings)
        // Await the delegate hookup so the gateway routes events to the controller
        // before the test starts feeding lines. Fire-and-forget Task races feedLine.
        await gateway.setDelegate(controller)
        return (gateway, controller, writer)
    }

    // Schedule a fake response for the Nth command we've sent (commandNumber starts at 1).
    // The response body is `body`; isError indicates %end vs %error.
    private func feedResponse(
        to gateway: TmuxGateway,
        commandNumber: Int,
        body: String,
        isError: Bool = false
    ) async {
        await gateway.feedLine(Data("%begin 0 \(commandNumber) 1".utf8))
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            await gateway.feedLine(Data(line.utf8))
        }
        let endVerb = isError ? "%error" : "%end"
        await gateway.feedLine(Data("\(endVerb) 0 \(commandNumber) 1".utf8))
    }

    // MARK: - Attach

    func testAttachProbesVersionListsWindowsAndDiscoversActivePane() async throws {
        // Disable optional features so the attach sequence is exactly 5 commands
        // (probe + list-windows + list-panes + active-pane + refresh-client).
        // Backfill and pause-mode would each add commands the test doesn't feed,
        // making the attach hang waiting for responses.
        let settings = TmuxSettings(
            backfillEnabled: false,
            pauseModeEnabled: false
        )
        let (gateway, controller, writer) = await makeStack(settings: settings)

        let attachTask = Task { await controller.attach(initialCols: 80, initialRows: 24) }

        // 1: display-message version+session
        try await Task.sleep(nanoseconds: 50_000_000)
        await feedResponse(to: gateway, commandNumber: 1, body: "3.4\tios-test")

        // 2: list-windows
        try await Task.sleep(nanoseconds: 50_000_000)
        await feedResponse(
            to: gateway,
            commandNumber: 2,
            body: "@1\tshell\t1\tabcd,80x24,0,0,3"
        )

        // 3: list-panes for @1
        try await Task.sleep(nanoseconds: 50_000_000)
        await feedResponse(
            to: gateway,
            commandNumber: 3,
            body: "%3\t1\trobotic\t80\t24"
        )

        // 4: display-message active pane
        try await Task.sleep(nanoseconds: 50_000_000)
        await feedResponse(to: gateway, commandNumber: 4, body: "%3")

        // 5: refresh-client
        try await Task.sleep(nanoseconds: 50_000_000)
        await feedResponse(to: gateway, commandNumber: 5, body: "")

        await attachTask.value

        XCTAssertEqual(controller.serverVersion?.description, "3.4")
        XCTAssertEqual(controller.sessionName, "ios-test")
        XCTAssertEqual(controller.windows.count, 1)
        XCTAssertEqual(controller.windowOrder, [TmuxWindowID(rawValue: 1)])
        XCTAssertEqual(controller.activeWindowID, TmuxWindowID(rawValue: 1))
        XCTAssertEqual(controller.activePaneID, TmuxPaneID(rawValue: 3))
        XCTAssertEqual(controller.panes[TmuxPaneID(rawValue: 3)]?.title, "robotic")
        XCTAssertEqual(controller.state, .attached)

        let written = writer.capturedString
        XCTAssertTrue(written.contains("display-message -p \"#{version}\\t#{session_name}\""))
        XCTAssertTrue(written.contains("list-windows -F"))
        XCTAssertTrue(written.contains("list-panes -t @1"))
        XCTAssertTrue(written.contains("refresh-client -C 80,24"))
    }

    // MARK: - Output routing

    func testOutputEventFeedsBytesIntoPane() async throws {
        let (gateway, controller, _) = await makeStack()
        let pane = TmuxPane(id: TmuxPaneID(rawValue: 3), windowID: TmuxWindowID(rawValue: 1))
        controller.panes[TmuxPaneID(rawValue: 3)] = pane

        var receivedSink = Data()
        pane.setSink { receivedSink.append($0) }

        await gateway.feedLine(Data("%output %3 hello".utf8))

        // event delivery is async — give it a moment
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(receivedSink, Data("hello".utf8))
    }

    func testOutputBeforeSinkBuffersUntilSinkLands() async throws {
        let (gateway, controller, _) = await makeStack()
        let pane = TmuxPane(id: TmuxPaneID(rawValue: 3), windowID: TmuxWindowID(rawValue: 1))
        controller.panes[TmuxPaneID(rawValue: 3)] = pane

        await gateway.feedLine(Data("%output %3 buffered".utf8))
        try await Task.sleep(nanoseconds: 50_000_000)

        // No sink yet — should be buffered
        var received = Data()
        pane.setSink { received.append($0) }

        XCTAssertEqual(received, Data("buffered".utf8))
    }

    func testStaleSinkTokenCannotClearNewerSink() async throws {
        let pane = TmuxPane(id: TmuxPaneID(rawValue: 3), windowID: TmuxWindowID(rawValue: 1))
        var staleSink = Data()
        var currentSink = Data()

        let staleToken = pane.setSink { staleSink.append($0) }
        let currentToken = pane.setSink { currentSink.append($0) }

        pane.clearSink(staleToken)
        pane.feed(Data("live".utf8))

        XCTAssertEqual(staleSink, Data())
        XCTAssertEqual(currentSink, Data("live".utf8))

        pane.clearSink(currentToken)
        pane.feed(Data("buffered".utf8))

        var replayed = Data()
        pane.setSink { replayed.append($0) }

        XCTAssertEqual(replayed, Data("buffered".utf8))
    }

    // MARK: - Window lifecycle

    func testWindowCloseRemovesWindowAndPanes() async throws {
        let (gateway, controller, _) = await makeStack()
        let windowID = TmuxWindowID(rawValue: 5)
        let paneID = TmuxPaneID(rawValue: 7)
        let window = TmuxWindow(id: windowID, name: "test", paneIDs: [paneID])
        controller.windows[windowID] = window
        controller.windowOrder.append(windowID)
        controller.panes[paneID] = TmuxPane(id: paneID, windowID: windowID)
        controller.activeWindowID = windowID

        await gateway.feedLine(Data("%window-close @5".utf8))
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertNil(controller.windows[windowID])
        XCTAssertNil(controller.panes[paneID])
        XCTAssertFalse(controller.windowOrder.contains(windowID))
        XCTAssertNil(controller.activeWindowID)
    }

    func testUnlinkedWindowCloseRemovesWindowAndPanes() async throws {
        let (gateway, controller, _) = await makeStack()
        let windowID = TmuxWindowID(rawValue: 6)
        let paneID = TmuxPaneID(rawValue: 8)
        let window = TmuxWindow(id: windowID, name: "exited", paneIDs: [paneID])
        controller.windows[windowID] = window
        controller.windowOrder.append(windowID)
        controller.panes[paneID] = TmuxPane(id: paneID, windowID: windowID)
        controller.activeWindowID = windowID

        await gateway.feedLine(Data("%unlinked-window-close @6".utf8))
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertNil(controller.windows[windowID])
        XCTAssertNil(controller.panes[paneID])
        XCTAssertFalse(controller.windowOrder.contains(windowID))
        XCTAssertNil(controller.activeWindowID)
    }

    func testWindowRenamedUpdatesName() async throws {
        let (gateway, controller, _) = await makeStack()
        let windowID = TmuxWindowID(rawValue: 5)
        controller.windows[windowID] = TmuxWindow(id: windowID, name: "old")
        controller.windowOrder.append(windowID)

        await gateway.feedLine(Data("%window-renamed @5 newname".utf8))
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(controller.windows[windowID]?.name, "newname")
    }

    // MARK: - Layout change

    func testLayoutChangeMaterializesPanes() async throws {
        let (gateway, controller, _) = await makeStack()
        let windowID = TmuxWindowID(rawValue: 5)
        controller.windows[windowID] = TmuxWindow(id: windowID, name: "test")
        controller.windowOrder.append(windowID)

        await gateway.feedLine(Data("%layout-change @5 abcd,80x24,0,0{40x24,0,0,3,40x24,40,0,4}".utf8))
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertNotNil(controller.panes[TmuxPaneID(rawValue: 3)])
        XCTAssertNotNil(controller.panes[TmuxPaneID(rawValue: 4)])
        XCTAssertEqual(controller.windows[windowID]?.paneIDs, [TmuxPaneID(rawValue: 3), TmuxPaneID(rawValue: 4)])
    }

    func testLayoutChangeStoresVisibleLayoutWhenPresent() async throws {
        let (gateway, controller, _) = await makeStack()
        let windowID = TmuxWindowID(rawValue: 5)
        controller.windows[windowID] = TmuxWindow(id: windowID, name: "test")
        controller.windowOrder.append(windowID)

        await gateway.feedLine(
            Data("%layout-change @5 abcd,80x24,0,0{40x24,0,0,3,40x24,40,0,4} efgh,40x24,0,0,3 0".utf8)
        )
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(controller.windows[windowID]?.layoutString, "abcd,80x24,0,0{40x24,0,0,3,40x24,40,0,4}")
        XCTAssertEqual(controller.windows[windowID]?.visibleLayoutString, "efgh,40x24,0,0,3")
        XCTAssertEqual(controller.windows[windowID]?.paneIDs, [TmuxPaneID(rawValue: 3), TmuxPaneID(rawValue: 4)])
        XCTAssertEqual(controller.windows[windowID]?.displayLayoutNode?.frame, TmuxFrame(cols: 40, rows: 24))
    }

    func testWindowPaneChangedUpdatesActivePaneForActiveWindow() async throws {
        let (gateway, controller, _) = await makeStack()
        let windowID = TmuxWindowID(rawValue: 1)
        let pane3 = TmuxPaneID(rawValue: 3)
        let pane4 = TmuxPaneID(rawValue: 4)
        controller.windows[windowID] = TmuxWindow(
            id: windowID,
            name: "split",
            paneIDs: [pane3, pane4],
            activePaneID: pane3
        )
        controller.windowOrder.append(windowID)
        controller.panes[pane3] = TmuxPane(id: pane3, windowID: windowID, isActive: true)
        controller.panes[pane4] = TmuxPane(id: pane4, windowID: windowID)
        controller.activeWindowID = windowID
        controller.activePaneID = pane3

        await gateway.feedLine(Data("%window-pane-changed @1 %4".utf8))
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(controller.activeWindowID, windowID)
        XCTAssertEqual(controller.activePaneID, pane4)
        XCTAssertEqual(controller.windows[windowID]?.activePaneID, pane4)
        XCTAssertEqual(controller.panes[pane3]?.isActive, false)
        XCTAssertEqual(controller.panes[pane4]?.isActive, true)
    }

    func testWindowPaneChangedForInactiveWindowDoesNotStealActiveWindow() async throws {
        let (gateway, controller, _) = await makeStack()
        let activeWindow = TmuxWindowID(rawValue: 1)
        let inactiveWindow = TmuxWindowID(rawValue: 2)
        let activePane = TmuxPaneID(rawValue: 3)
        let inactivePane = TmuxPaneID(rawValue: 4)

        controller.windows[activeWindow] = TmuxWindow(
            id: activeWindow,
            paneIDs: [activePane],
            activePaneID: activePane
        )
        controller.windows[inactiveWindow] = TmuxWindow(
            id: inactiveWindow,
            paneIDs: [inactivePane],
            activePaneID: nil
        )
        controller.windowOrder.append(contentsOf: [activeWindow, inactiveWindow])
        controller.panes[activePane] = TmuxPane(id: activePane, windowID: activeWindow, isActive: true)
        controller.panes[inactivePane] = TmuxPane(id: inactivePane, windowID: inactiveWindow)
        controller.activeWindowID = activeWindow
        controller.activePaneID = activePane

        await gateway.feedLine(Data("%window-pane-changed @2 %4".utf8))
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(controller.activeWindowID, activeWindow)
        XCTAssertEqual(controller.activePaneID, activePane)
        XCTAssertEqual(controller.windows[inactiveWindow]?.activePaneID, inactivePane)
    }

    func testSessionWindowChangedSelectsWindowAndItsActivePane() async throws {
        let (gateway, controller, _) = await makeStack()
        let window1 = TmuxWindowID(rawValue: 1)
        let window2 = TmuxWindowID(rawValue: 2)
        let pane3 = TmuxPaneID(rawValue: 3)
        let pane4 = TmuxPaneID(rawValue: 4)

        controller.windows[window1] = TmuxWindow(id: window1, paneIDs: [pane3], activePaneID: pane3)
        controller.windows[window2] = TmuxWindow(id: window2, paneIDs: [pane4], activePaneID: pane4)
        controller.windowOrder.append(contentsOf: [window1, window2])
        controller.panes[pane3] = TmuxPane(id: pane3, windowID: window1, isActive: true)
        controller.panes[pane4] = TmuxPane(id: pane4, windowID: window2, isActive: true)
        controller.activeWindowID = window1
        controller.activePaneID = pane3

        await gateway.feedLine(Data("%session-window-changed $1 @2".utf8))
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(controller.activeWindowID, window2)
        XCTAssertEqual(controller.activePaneID, pane4)
    }

    func testSelectNextWindowShortcutWrapsAndSendsSelectWindow() async throws {
        let (gateway, controller, writer) = await makeStack()
        let window1 = TmuxWindowID(rawValue: 1)
        let window2 = TmuxWindowID(rawValue: 2)
        controller.windows[window1] = TmuxWindow(id: window1)
        controller.windows[window2] = TmuxWindow(id: window2)
        controller.windowOrder.append(contentsOf: [window1, window2])
        controller.activeWindowID = window2

        let selectTask = Task { await controller.selectNextWindow() }
        try await Task.sleep(nanoseconds: 25_000_000)

        XCTAssertTrue(writer.capturedString.contains("select-window -t @1"))

        await feedResponse(to: gateway, commandNumber: 1, body: "")
        await selectTask.value

        XCTAssertEqual(controller.activeWindowID, window1)
    }

    func testSelectPreviousWindowShortcutWrapsAndSendsSelectWindow() async throws {
        let (gateway, controller, writer) = await makeStack()
        let window1 = TmuxWindowID(rawValue: 1)
        let window2 = TmuxWindowID(rawValue: 2)
        let window3 = TmuxWindowID(rawValue: 3)
        controller.windows[window1] = TmuxWindow(id: window1)
        controller.windows[window2] = TmuxWindow(id: window2)
        controller.windows[window3] = TmuxWindow(id: window3)
        controller.windowOrder.append(contentsOf: [window1, window2, window3])
        controller.activeWindowID = window1

        let selectTask = Task { await controller.selectPreviousWindow() }
        try await Task.sleep(nanoseconds: 25_000_000)

        XCTAssertTrue(writer.capturedString.contains("select-window -t @3"))

        await feedResponse(to: gateway, commandNumber: 1, body: "")
        await selectTask.value

        XCTAssertEqual(controller.activeWindowID, window3)
    }

    func testSelectWindowShortcutSlotNineSelectsLastWindow() async throws {
        let (gateway, controller, writer) = await makeStack()
        let window1 = TmuxWindowID(rawValue: 1)
        let window2 = TmuxWindowID(rawValue: 2)
        let window3 = TmuxWindowID(rawValue: 3)
        controller.windows[window1] = TmuxWindow(id: window1)
        controller.windows[window2] = TmuxWindow(id: window2)
        controller.windows[window3] = TmuxWindow(id: window3)
        controller.windowOrder.append(contentsOf: [window1, window2, window3])
        controller.activeWindowID = window1

        let selectTask = Task { await controller.selectWindow(shortcutSlot: 9) }
        try await Task.sleep(nanoseconds: 25_000_000)

        XCTAssertTrue(writer.capturedString.contains("select-window -t @3"))

        await feedResponse(to: gateway, commandNumber: 1, body: "")
        await selectTask.value

        XCTAssertEqual(controller.activeWindowID, window3)
    }

    func testSelectPaneUpdatesActivePaneBeforeCommandResponse() async throws {
        let (gateway, controller, writer) = await makeStack()
        let windowID = TmuxWindowID(rawValue: 1)
        let pane3 = TmuxPaneID(rawValue: 3)
        let pane4 = TmuxPaneID(rawValue: 4)
        controller.windows[windowID] = TmuxWindow(
            id: windowID,
            paneIDs: [pane3, pane4],
            activePaneID: pane3
        )
        controller.windowOrder.append(windowID)
        controller.panes[pane3] = TmuxPane(id: pane3, windowID: windowID, isActive: true)
        controller.panes[pane4] = TmuxPane(id: pane4, windowID: windowID)
        controller.activeWindowID = windowID
        controller.activePaneID = pane3

        let selectTask = Task { await controller.selectPane(pane4) }
        try await Task.sleep(nanoseconds: 25_000_000)

        XCTAssertEqual(controller.activePaneID, pane4)
        XCTAssertEqual(controller.panes[pane3]?.isActive, false)
        XCTAssertEqual(controller.panes[pane4]?.isActive, true)
        XCTAssertTrue(writer.capturedString.contains("select-pane -t %4"))

        await feedResponse(to: gateway, commandNumber: 1, body: "")
        await selectTask.value
    }

    func testRefreshWindowUsesPerWindowSizeTarget() async throws {
        let (gateway, controller, writer) = await makeStack()

        controller.refreshWindow(TmuxWindowID(rawValue: 7), cols: 120, rows: 40)
        try await Task.sleep(nanoseconds: 75_000_000)
        await feedResponse(to: gateway, commandNumber: 1, body: "")
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(writer.capturedString.contains("refresh-client -C @7:120x40"))
    }

    func testResizePaneUsesAbsoluteWidthAndHeight() async throws {
        let (gateway, controller, writer) = await makeStack()
        let paneID = TmuxPaneID(rawValue: 3)

        let widthTask = Task { await controller.resizePane(paneID, cols: 50) }
        try await Task.sleep(nanoseconds: 25_000_000)
        XCTAssertTrue(writer.capturedString.contains("resize-pane -t %3 -x 50"))
        await feedResponse(to: gateway, commandNumber: 1, body: "")
        await widthTask.value

        writer.reset()
        let heightTask = Task { await controller.resizePane(paneID, rows: 12) }
        try await Task.sleep(nanoseconds: 25_000_000)
        XCTAssertTrue(writer.capturedString.contains("resize-pane -t %3 -y 12"))
        await feedResponse(to: gateway, commandNumber: 2, body: "")
        await heightTask.value
    }

    func testSplitPaneRightTargetsActivePane() async throws {
        let (gateway, controller, writer) = await makeStack()
        controller.activePaneID = TmuxPaneID(rawValue: 3)

        let splitTask = Task { await controller.splitPane(.right) }
        try await Task.sleep(nanoseconds: 25_000_000)

        XCTAssertTrue(writer.capturedString.contains("split-window -h -t %3"))

        await feedResponse(to: gateway, commandNumber: 1, body: "")
        await splitTask.value
    }

    func testSplitPaneDownTargetsActivePane() async throws {
        let (gateway, controller, writer) = await makeStack()
        controller.activePaneID = TmuxPaneID(rawValue: 4)

        let splitTask = Task { await controller.splitPane(.down) }
        try await Task.sleep(nanoseconds: 25_000_000)

        XCTAssertTrue(writer.capturedString.contains("split-window -v -t %4"))

        await feedResponse(to: gateway, commandNumber: 1, body: "")
        await splitTask.value
    }

    func testSplitPaneExplicitTargetOverridesActivePane() async throws {
        let (gateway, controller, writer) = await makeStack()
        controller.activePaneID = TmuxPaneID(rawValue: 3)

        let splitTask = Task {
            await controller.splitPane(.right, target: TmuxPaneID(rawValue: 7))
        }
        try await Task.sleep(nanoseconds: 25_000_000)

        XCTAssertTrue(writer.capturedString.contains("split-window -h -t %7"))
        XCTAssertFalse(writer.capturedString.contains("split-window -h -t %3"))

        await feedResponse(to: gateway, commandNumber: 1, body: "")
        await splitTask.value
    }

    func testSplitPaneWithoutTargetDoesNotWriteCommand() async throws {
        let (_, controller, writer) = await makeStack()

        await controller.splitPane(.right)
        try await Task.sleep(nanoseconds: 25_000_000)

        XCTAssertEqual(writer.capturedString, "")
    }

    // MARK: - Pause / continue

    func testPauseEventMarksPanePaused() async throws {
        let (gateway, controller, _) = await makeStack()
        let paneID = TmuxPaneID(rawValue: 3)
        controller.panes[paneID] = TmuxPane(id: paneID, windowID: TmuxWindowID(rawValue: 1))

        await gateway.feedLine(Data("%pause %3".utf8))
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(controller.panes[paneID]?.isPaused, true)
        XCTAssertNotNil(controller.statusMessage)
    }

    func testContinueEventClearsPaused() async throws {
        let (gateway, controller, _) = await makeStack()
        let paneID = TmuxPaneID(rawValue: 3)
        let pane = TmuxPane(id: paneID, windowID: TmuxWindowID(rawValue: 1))
        pane.isPaused = true
        controller.panes[paneID] = pane

        await gateway.feedLine(Data("%continue %3".utf8))
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(controller.panes[paneID]?.isPaused, false)
        XCTAssertNil(controller.statusMessage)
    }

    // MARK: - Exit

    func testExitTransitionsToExitedState() async throws {
        let (gateway, controller, _) = await makeStack()
        await gateway.feedLine(Data("%exit detached".utf8))
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(controller.state, .exited(reason: "detached"))
    }

    func testUserDetachSendsDetachAndExits() async throws {
        let (_, controller, writer) = await makeStack()

        await controller.detach()

        XCTAssertEqual(writer.capturedString, "detach\n")
        XCTAssertEqual(controller.state, .exited(reason: "user detached"))
        XCTAssertFalse(controller.state.isAttached)
        XCTAssertEqual(controller.statusMessage, "Detached")
    }

    // MARK: - sendKeysToActivePane

    func testSendKeysWritesToActivePane() async throws {
        let (_, controller, writer) = await makeStack()
        let paneID = TmuxPaneID(rawValue: 3)
        controller.panes[paneID] = TmuxPane(id: paneID, windowID: TmuxWindowID(rawValue: 1))
        controller.activePaneID = paneID

        await controller.sendKeysToActivePane(Data("hi".utf8))
        try await Task.sleep(nanoseconds: 50_000_000)

        let written = writer.capturedString
        XCTAssertTrue(written.contains("send"))
        XCTAssertTrue(written.contains("%3"))
    }
}
