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

    private func enqueueSerialLine(
        _ string: String,
        to gateway: TmuxGateway,
        after previous: inout Task<Void, Never>?
    ) {
        let prior = previous
        previous = Task {
            await prior?.value
            guard !Task.isCancelled else { return }
            await gateway.feedLine(Data(string.utf8))
        }
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 1.0,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("Timed out waiting for \(description)", file: file, line: line)
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func paneSnapshotStateLine(
        paneID: TmuxPaneID,
        cursorX: Int = 0,
        cursorY: Int = 0,
        rows: Int = 24
    ) -> String {
        [
            "pane_id=\(paneID.wire)",
            "alternate_on=0",
            "alternate_saved_x=0",
            "alternate_saved_y=0",
            "cursor_x=\(cursorX)",
            "cursor_y=\(cursorY)",
            "scroll_region_upper=0",
            "scroll_region_lower=\(max(rows - 1, 0))",
            "pane_tabs=",
            "cursor_flag=1",
            "insert_flag=0",
            "keypad_cursor_flag=0",
            "keypad_flag=0",
            "wrap_flag=1",
            "mouse_standard_flag=0",
            "mouse_button_flag=0",
            "mouse_any_flag=0",
            "mouse_utf8_flag=0",
            "mouse_sgr_flag=0",
            "bracket_paste_flag=0",
            "pane_key_mode=emacs",
        ].joined(separator: "\t")
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

    func testNestedControlModeOutputDetachesNestedClientInSamePane() async throws {
        let settings = TmuxSettings(
            backfillEnabled: false,
            pauseModeEnabled: false
        )
        let (gateway, controller, writer) = await makeStack(settings: settings)
        let paneID = TmuxPaneID(rawValue: 61)

        let attachTask = Task {
            await controller.attach(initialCols: 62, initialRows: 49)
        }

        try await waitUntil("version probe command is written") {
            writer.capturedString.contains("display-message -p \"#{version}\\t#{session_name}\"")
        }
        await feedResponse(to: gateway, commandNumber: 1, body: "2.9\tssh-app-session")

        try await waitUntil("list-windows command is written") {
            writer.capturedString.contains("list-windows -F")
        }
        await feedResponse(
            to: gateway,
            commandNumber: 2,
            body: "@1\tbash\t1\tabcd,62x49,0,0,61"
        )

        try await waitUntil("list-panes command is written") {
            writer.capturedString.contains("list-panes -t @1")
        }
        await feedResponse(
            to: gateway,
            commandNumber: 3,
            body: "%61\t1\tfoo.example.local\t62\t49"
        )

        try await waitUntil("active pane probe command is written") {
            writer.capturedString.contains("display-message -p \"#{pane_id}\"")
        }
        await feedResponse(to: gateway, commandNumber: 4, body: "%61")

        try await waitUntil("refresh-client command is written") {
            writer.capturedString.contains("refresh-client -C 62,49")
        }
        await feedResponse(to: gateway, commandNumber: 5, body: "")

        await attachTask.value
        writer.reset()
        await gateway.feedLine(Data("%session-changed $21 ssh-app-session".utf8))
        await gateway.feedLine(Data("%client-session-changed /dev/pts/1 $21 ssh-app-session".utf8))

        let pane = try XCTUnwrap(controller.panes[paneID])

        var received = Data()
        pane.setSink { received.append($0) }

        await gateway.feedLine(Data(
            "%output %61 \\033P1000p%client-session-changed /dev/pts/1 $21 ssh-app-session\\012".utf8
        ))

        try await waitUntil("nested tmux detach command is written") {
            writer.capturedString.contains("detach-client -t \"/dev/pts/1\"")
        }
        await gateway.feedLine(Data("%client-detached /dev/pts/1".utf8))

        XCTAssertTrue(received.isEmpty)
        XCTAssertEqual(controller.state, .attached)
        XCTAssertFalse(writer.capturedString.contains("send -lt %61 \"detach-client\""))
    }

    func testNestedControlModeKillsAutoCreatedNumericChildSessionOnly() async throws {
        let settings = TmuxSettings(
            backfillEnabled: false,
            pauseModeEnabled: false
        )
        let (gateway, controller, writer) = await makeStack(settings: settings)
        let paneID = TmuxPaneID(rawValue: 61)

        let attachTask = Task {
            await controller.attach(initialCols: 62, initialRows: 49)
        }

        try await waitUntil("version probe command is written") {
            writer.capturedString.contains("display-message -p \"#{version}\\t#{session_name}\"")
        }
        await feedResponse(to: gateway, commandNumber: 1, body: "2.9\tssh-app-session")

        try await waitUntil("list-windows command is written") {
            writer.capturedString.contains("list-windows -F")
        }
        await feedResponse(
            to: gateway,
            commandNumber: 2,
            body: "@1\tbash\t1\tabcd,62x49,0,0,61"
        )

        try await waitUntil("list-panes command is written") {
            writer.capturedString.contains("list-panes -t @1")
        }
        await feedResponse(
            to: gateway,
            commandNumber: 3,
            body: "%61\t1\tfoo.example.local\t62\t49"
        )

        try await waitUntil("active pane probe command is written") {
            writer.capturedString.contains("display-message -p \"#{pane_id}\"")
        }
        await feedResponse(to: gateway, commandNumber: 4, body: "%61")

        try await waitUntil("refresh-client command is written") {
            writer.capturedString.contains("refresh-client -C 62,49")
        }
        await feedResponse(to: gateway, commandNumber: 5, body: "")

        await attachTask.value
        writer.reset()
        await gateway.feedLine(Data("%session-changed $21 ssh-app-session".utf8))
        await gateway.feedLine(Data("%client-session-changed /dev/pts/2 $22 22".utf8))

        await gateway.feedLine(Data("%output %61 \\033P1000p".utf8))

        try await waitUntil("nested tmux targeted detach command is written") {
            writer.capturedString.contains("detach-client -t \"/dev/pts/2\"")
        }
        await feedResponse(to: gateway, commandNumber: 6, body: "")

        try await waitUntil("auto-created nested session cleanup is written") {
            writer.capturedString.contains("kill-session -t \"$22\"")
        }
        XCTAssertEqual(controller.state, .attached)
    }

    func testOutputDuringBootstrapReplaysAfterAttachMapsPane() async throws {
        let settings = TmuxSettings(
            backfillEnabled: false,
            pauseModeEnabled: false
        )
        let (gateway, controller, writer) = await makeStack(settings: settings)
        let windowID = TmuxWindowID(rawValue: 1)
        let paneID = TmuxPaneID(rawValue: 37)
        let prompt = Data("demo@foo:~$ ".utf8)

        let attachTask = Task {
            await controller.attach(initialCols: 62, initialRows: 49)
        }

        try await waitUntil("version probe command is written") {
            writer.capturedString.contains("display-message -p \"#{version}\\t#{session_name}\"")
        }

        await gateway.feedLine(Data("%output %37 demo@foo:~$ ".utf8))

        await feedResponse(to: gateway, commandNumber: 1, body: "3.5a\t10")

        try await waitUntil("list-windows command is written") {
            writer.capturedString.contains("list-windows -F")
        }
        await feedResponse(
            to: gateway,
            commandNumber: 2,
            body: "@1\tzsh\t1\tabcd,62x49,0,0,37"
        )

        try await waitUntil("list-panes command is written") {
            writer.capturedString.contains("list-panes -t @1")
        }
        await feedResponse(
            to: gateway,
            commandNumber: 3,
            body: "%37\t1\tfoo.example.local\t62\t49"
        )

        try await waitUntil("active pane probe command is written") {
            writer.capturedString.contains("display-message -p \"#{pane_id}\"")
        }
        await feedResponse(to: gateway, commandNumber: 4, body: "%37")

        try await waitUntil("refresh-client command is written") {
            writer.capturedString.contains("refresh-client -C 62,49")
        }
        await feedResponse(to: gateway, commandNumber: 5, body: "")
        await attachTask.value

        let pane = try XCTUnwrap(controller.panes[paneID])
        XCTAssertEqual(pane.windowID, windowID)
        XCTAssertEqual(controller.activePaneID, paneID)

        var received = Data()
        pane.setSink { received.append($0) }

        XCTAssertEqual(received, prompt)
    }

    func testAttachBackfillDoesNotDuplicateEarlyPaneOutput() async throws {
        let settings = TmuxSettings(
            backfillEnabled: true,
            pauseModeEnabled: false
        )
        let (gateway, controller, writer) = await makeStack(settings: settings)
        let windowID = TmuxWindowID(rawValue: 1)
        let paneID = TmuxPaneID(rawValue: 41)
        let prompt = Data("demo@foo:~$ ".utf8)

        let attachTask = Task {
            await controller.attach(initialCols: 62, initialRows: 49)
        }

        try await waitUntil("version probe command is written") {
            writer.capturedString.contains("display-message -p \"#{version}\\t#{session_name}\"")
        }

        await gateway.feedLine(Data("%output %41 demo@foo:~$ ".utf8))
        await feedResponse(to: gateway, commandNumber: 1, body: "3.5a\t13")

        try await waitUntil("list-windows command is written") {
            writer.capturedString.contains("list-windows -F")
        }
        await feedResponse(
            to: gateway,
            commandNumber: 2,
            body: "@1\tbash\t1\tabcd,62x49,0,0,41"
        )

        try await waitUntil("list-panes command is written") {
            writer.capturedString.contains("list-panes -t @1")
        }
        await feedResponse(
            to: gateway,
            commandNumber: 3,
            body: "%41\t1\tfoo.example.local\t62\t49"
        )

        try await waitUntil("active pane probe command is written") {
            writer.capturedString.contains("display-message -p \"#{pane_id}\"")
        }
        await feedResponse(to: gateway, commandNumber: 4, body: "%41")

        try await waitUntil("refresh-client command is written") {
            writer.capturedString.contains("refresh-client -C 62,49")
        }
        await feedResponse(to: gateway, commandNumber: 5, body: "")

        await attachTask.value

        let pane = try XCTUnwrap(controller.panes[paneID])
        XCTAssertEqual(pane.windowID, windowID)

        var received = Data()
        pane.setSink { received.append($0) }

        XCTAssertEqual(received, prompt)
        XCTAssertFalse(writer.capturedString.contains("list-panes -t %41 -F"))
        XCTAssertFalse(writer.capturedString.contains("capture-pane -peqJN -t %41 -S -5000"))
    }

    func testAttachBackfillRunsWhenEarlyPaneOutputIsSuppressedNestedControlMode() async throws {
        let settings = TmuxSettings(
            backfillEnabled: true,
            pauseModeEnabled: false
        )
        let (gateway, controller, writer) = await makeStack(settings: settings)
        let windowID = TmuxWindowID(rawValue: 1)
        let paneID = TmuxPaneID(rawValue: 61)
        let prompt = Data("demo@foo:~$ ".utf8)

        let attachTask = Task {
            await controller.attach(initialCols: 62, initialRows: 49)
        }

        try await waitUntil("version probe command is written") {
            writer.capturedString.contains("display-message -p \"#{version}\\t#{session_name}\"")
        }

        await gateway.feedLine(Data(
            "%output %61 \\033P1000p%client-session-changed /dev/pts/1 $21 ssh-app-session\\012".utf8
        ))
        await gateway.feedLine(Data("%client-session-changed /dev/pts/1 $21 ssh-app-session".utf8))
        await feedResponse(to: gateway, commandNumber: 1, body: "3.5a\tssh-app-session")

        try await waitUntil("list-windows command is written") {
            writer.capturedString.contains("list-windows -F")
        }
        await feedResponse(
            to: gateway,
            commandNumber: 2,
            body: "@1\tbash\t1\tabcd,62x49,0,0,61"
        )

        try await waitUntil("list-panes command is written") {
            writer.capturedString.contains("list-panes -t @1")
        }
        await feedResponse(
            to: gateway,
            commandNumber: 3,
            body: "%61\t1\tfoo.example.local\t62\t49"
        )

        try await waitUntil("active pane probe command is written") {
            writer.capturedString.contains("display-message -p \"#{pane_id}\"")
        }
        await feedResponse(to: gateway, commandNumber: 4, body: "%61")

        try await waitUntil("refresh-client command is written") {
            writer.capturedString.contains("refresh-client -C 62,49")
        }
        await feedResponse(to: gateway, commandNumber: 5, body: "")

        try await waitUntil("attach snapshot state command is written") {
            writer.capturedString.contains("list-panes -t %61 -F \"pane_id=#{pane_id}")
        }
        await feedResponse(
            to: gateway,
            commandNumber: 6,
            body: paneSnapshotStateLine(paneID: paneID, cursorX: 12, cursorY: 1, rows: 49)
        )

        try await waitUntil("attach primary snapshot command is written") {
            writer.capturedString.contains("capture-pane -peqJN -t %61 -S -5000")
        }
        await feedResponse(
            to: gateway,
            commandNumber: 7,
            body: "%client-session-changed /dev/pts/1 $21 ssh-app-session\ndemo@foo:~$ "
        )

        try await waitUntil("attach alternate snapshot command is written") {
            writer.capturedString.contains("capture-pane -peqJN -a -t %61 -S -5000")
        }
        await feedResponse(to: gateway, commandNumber: 8, body: "")

        try await waitUntil("attach pending snapshot command is written") {
            writer.capturedString.contains("capture-pane -p -P -C -t %61")
        }
        await feedResponse(to: gateway, commandNumber: 9, body: "")

        await attachTask.value

        let pane = try XCTUnwrap(controller.panes[paneID])
        XCTAssertEqual(pane.windowID, windowID)

        var received = Data()
        pane.setSink { received.append($0) }
        let receivedString = try XCTUnwrap(String(data: received, encoding: .utf8))

        XCTAssertNotNil(received.range(of: prompt))
        XCTAssertFalse(receivedString.contains("%client-session-changed"))
        try await waitUntil("deferred nested tmux detach command is written") {
            writer.capturedString.contains("detach-client -t \"/dev/pts/1\"")
        }
    }

    func testAttachBackfillRestoresPaneSnapshotStateAndPendingOutput() async throws {
        let settings = TmuxSettings(
            backfillEnabled: true,
            pauseModeEnabled: false
        )
        let (gateway, controller, writer) = await makeStack(settings: settings)
        let windowID = TmuxWindowID(rawValue: 1)
        let paneID = TmuxPaneID(rawValue: 41)
        let prompt = Data("demo@foo:~$ ".utf8)
        var pendingTitle = Data([0x1B])
        pendingTitle.append(Data("]0;demo".utf8))
        pendingTitle.append(0x07)

        let attachTask = Task {
            await controller.attach(initialCols: 62, initialRows: 49)
        }

        try await waitUntil("version probe command is written") {
            writer.capturedString.contains("display-message -p \"#{version}\\t#{session_name}\"")
        }
        await feedResponse(to: gateway, commandNumber: 1, body: "3.5a\t13")

        try await waitUntil("list-windows command is written") {
            writer.capturedString.contains("list-windows -F")
        }
        await feedResponse(
            to: gateway,
            commandNumber: 2,
            body: "@1\tbash\t1\tabcd,62x49,0,0,41"
        )

        try await waitUntil("list-panes command is written") {
            writer.capturedString.contains("list-panes -t @1")
        }
        await feedResponse(
            to: gateway,
            commandNumber: 3,
            body: "%41\t1\tfoo.example.local\t62\t49"
        )

        try await waitUntil("active pane probe command is written") {
            writer.capturedString.contains("display-message -p \"#{pane_id}\"")
        }
        await feedResponse(to: gateway, commandNumber: 4, body: "%41")

        try await waitUntil("refresh-client command is written") {
            writer.capturedString.contains("refresh-client -C 62,49")
        }
        await feedResponse(to: gateway, commandNumber: 5, body: "")

        try await waitUntil("attach snapshot state command is written") {
            writer.capturedString.contains("list-panes -t %41 -F \"pane_id=#{pane_id}")
        }
        await feedResponse(
            to: gateway,
            commandNumber: 6,
            body: paneSnapshotStateLine(paneID: paneID, cursorX: 12, cursorY: 0, rows: 49)
        )

        try await waitUntil("attach primary snapshot command is written") {
            writer.capturedString.contains("capture-pane -peqJN -t %41 -S -5000")
        }
        await feedResponse(to: gateway, commandNumber: 7, body: "scrollback\ndemo@foo:~$ ")

        try await waitUntil("attach alternate snapshot command is written") {
            writer.capturedString.contains("capture-pane -peqJN -a -t %41 -S -5000")
        }
        await feedResponse(to: gateway, commandNumber: 8, body: "")

        try await waitUntil("attach pending snapshot command is written") {
            writer.capturedString.contains("capture-pane -p -P -C -t %41")
        }
        await feedResponse(to: gateway, commandNumber: 9, body: "\\033]0;demo\\007")

        await attachTask.value

        let pane = try XCTUnwrap(controller.panes[paneID])
        XCTAssertEqual(pane.windowID, windowID)

        var received = Data()
        pane.setSink { received.append($0) }

        XCTAssertNotEqual(received, prompt)
        XCTAssertNotNil(received.range(of: prompt))
        XCTAssertNotNil(received.range(of: Data("\u{1B}[1;13H".utf8)))
        XCTAssertTrue(received.suffix(pendingTitle.count).elementsEqual(pendingTitle))
    }

    func testOutputForSecondSplitPaneBuffersBeforeLayoutMaterializesPane() async throws {
        let (gateway, controller, _) = await makeStack()
        let windowID = TmuxWindowID(rawValue: 1)
        let firstPaneID = TmuxPaneID(rawValue: 12)
        let secondPaneID = TmuxPaneID(rawValue: 13)
        let thirdPaneID = TmuxPaneID(rawValue: 14)
        controller.windows[windowID] = TmuxWindow(
            id: windowID,
            name: "bash",
            paneIDs: [firstPaneID, secondPaneID],
            activePaneID: secondPaneID,
            layoutString: "abcd,144x42,0,0{72x42,0,0,12,71x42,73,0,13}"
        )
        controller.windowOrder.append(windowID)
        controller.panes[firstPaneID] = TmuxPane(id: firstPaneID, windowID: windowID)
        controller.panes[secondPaneID] = TmuxPane(
            id: secondPaneID,
            windowID: windowID,
            isActive: true
        )
        controller.activeWindowID = windowID
        controller.activePaneID = secondPaneID

        let prompt = Data("demo@foo:~$ ".utf8)
        await gateway.feedLine(Data("%output %14 demo@foo:~$ ".utf8))
        await gateway.feedLine(
            Data("%layout-change @1 abcd,144x42,0,0{72x42,0,0,12,71x42,73,0[71x21,73,0,13,71x20,73,22,14]}".utf8)
        )
        try await Task.sleep(nanoseconds: 50_000_000)

        let thirdPane = try XCTUnwrap(controller.panes[thirdPaneID])
        XCTAssertEqual(thirdPane.windowID, windowID)
        XCTAssertEqual(controller.windows[windowID]?.paneIDs, [firstPaneID, secondPaneID, thirdPaneID])

        var received = Data()
        thirdPane.setSink { received.append($0) }

        XCTAssertEqual(received, prompt)
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

    func testWindowAddMaterializationDoesNotBlockSerialLineDelivery() async throws {
        let (gateway, controller, writer) = await makeStack()
        let windowID = TmuxWindowID(rawValue: 9)
        let paneID = TmuxPaneID(rawValue: 12)
        var deliveryTask: Task<Void, Never>?

        enqueueSerialLine("%window-add @9", to: gateway, after: &deliveryTask)

        try await waitUntil("window-add metadata command is written") {
            writer.capturedString.contains("display-message -p -t @9")
        }

        enqueueSerialLine("%begin 0 1 1", to: gateway, after: &deliveryTask)
        enqueueSerialLine("fresh\tabcd,80x24,0,0,12", to: gateway, after: &deliveryTask)
        enqueueSerialLine("%end 0 1 1", to: gateway, after: &deliveryTask)

        try await waitUntil("window-add list-panes command is written") {
            writer.capturedString.contains("list-panes -t @9")
        }

        enqueueSerialLine("%begin 0 2 1", to: gateway, after: &deliveryTask)
        enqueueSerialLine("%12\t1\tfresh title\t80\t24", to: gateway, after: &deliveryTask)
        enqueueSerialLine("%end 0 2 1", to: gateway, after: &deliveryTask)

        try await waitUntil("fresh window and pane are materialized") {
            controller.windows[windowID]?.paneIDs == [paneID] &&
                controller.windows[windowID]?.activePaneID == paneID &&
                controller.panes[paneID]?.title == "fresh title"
        }

        deliveryTask?.cancel()
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

    func testSelectWindowShortcutDigitZeroSelectsTenthWindow() async throws {
        let (gateway, controller, writer) = await makeStack()
        let windowIDs = (1...10).map(TmuxWindowID.init(rawValue:))
        for windowID in windowIDs {
            controller.windows[windowID] = TmuxWindow(id: windowID)
        }
        controller.windowOrder.append(contentsOf: windowIDs)
        controller.activeWindowID = windowIDs[0]

        let selectTask = Task { await controller.selectWindow(shortcutDigit: 0) }
        try await Task.sleep(nanoseconds: 25_000_000)

        XCTAssertTrue(writer.capturedString.contains("select-window -t @10"))

        await feedResponse(to: gateway, commandNumber: 1, body: "")
        await selectTask.value

        XCTAssertEqual(controller.activeWindowID, windowIDs[9])
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
        try await waitUntil("split-window right command is written") {
            writer.capturedString.contains("split-window -P -F")
                && writer.capturedString.contains("-h -t %3")
        }

        await feedResponse(to: gateway, commandNumber: 1, body: "")
        await splitTask.value
    }

    func testSplitPaneDownTargetsActivePane() async throws {
        let (gateway, controller, writer) = await makeStack()
        controller.activePaneID = TmuxPaneID(rawValue: 4)

        let splitTask = Task { await controller.splitPane(.down) }
        try await waitUntil("split-window down command is written") {
            writer.capturedString.contains("split-window -P -F")
                && writer.capturedString.contains("-v -t %4")
        }

        await feedResponse(to: gateway, commandNumber: 1, body: "")
        await splitTask.value
    }

    func testSplitPaneExplicitTargetOverridesActivePane() async throws {
        let (gateway, controller, writer) = await makeStack()
        controller.activePaneID = TmuxPaneID(rawValue: 3)

        let splitTask = Task {
            await controller.splitPane(.right, target: TmuxPaneID(rawValue: 7))
        }
        try await waitUntil("split-window explicit target command is written") {
            writer.capturedString.contains("split-window -P -F")
                && writer.capturedString.contains("-h -t %7")
        }
        XCTAssertFalse(writer.capturedString.contains("-h -t %3"))

        await feedResponse(to: gateway, commandNumber: 1, body: "")
        await splitTask.value
    }

    func testSplitPaneBackfillsFourthPaneWhenNoOutputArrives() async throws {
        let (gateway, controller, writer) = await makeStack()
        let windowID = TmuxWindowID(rawValue: 1)
        let firstPaneID = TmuxPaneID(rawValue: 18)
        let secondPaneID = TmuxPaneID(rawValue: 19)
        let thirdPaneID = TmuxPaneID(rawValue: 20)
        let fourthPaneID = TmuxPaneID(rawValue: 21)
        controller.windows[windowID] = TmuxWindow(
            id: windowID,
            name: "bash",
            paneIDs: [firstPaneID, secondPaneID, thirdPaneID],
            activePaneID: firstPaneID,
            layoutString: "abcd,142x42,0,0{71x42,0,0[71x21,0,0,18,71x20,0,22,20],70x42,72,0,19}"
        )
        controller.windowOrder.append(windowID)
        controller.panes[firstPaneID] = TmuxPane(
            id: firstPaneID,
            windowID: windowID,
            isActive: true
        )
        controller.panes[secondPaneID] = TmuxPane(id: secondPaneID, windowID: windowID)
        controller.panes[thirdPaneID] = TmuxPane(id: thirdPaneID, windowID: windowID)
        controller.activeWindowID = windowID
        controller.activePaneID = firstPaneID

        let splitTask = Task { await controller.splitPane(.down) }
        try await waitUntil("split-window metadata command is written") {
            writer.capturedString.contains("split-window -P -F")
                && writer.capturedString.contains("-v -t %18")
        }

        await feedResponse(
            to: gateway,
            commandNumber: 1,
            body: "%21\t@1\t71\t10\tabcd,142x42,0,0{71x42,0,0[71x10,0,0,18,71x10,0,11,21,71x20,0,22,20],70x42,72,0,19}"
        )

        let prompt = "demo@foo:~$ "
        await splitTask.value

        let fourthPane = try XCTUnwrap(controller.panes[fourthPaneID])
        var received = Data()
        fourthPane.setSink { received.append($0) }

        try await waitUntil("new pane snapshot state command is written") {
            writer.capturedString.contains("list-panes -t %21 -F \"pane_id=#{pane_id}")
        }
        await feedResponse(
            to: gateway,
            commandNumber: 2,
            body: paneSnapshotStateLine(paneID: fourthPaneID, cursorX: 12, cursorY: 0, rows: 10)
        )

        try await waitUntil("new pane primary snapshot command is written") {
            writer.capturedString.contains("capture-pane -peqJ -t %21 -S -24")
        }
        await feedResponse(to: gateway, commandNumber: 3, body: prompt)

        try await waitUntil("new pane alternate snapshot command is written") {
            writer.capturedString.contains("capture-pane -peqJ -a -t %21 -S -24")
        }
        await feedResponse(to: gateway, commandNumber: 4, body: "")

        try await waitUntil("new pane pending snapshot command is written") {
            writer.capturedString.contains("capture-pane -p -P -C -t %21")
        }
        await feedResponse(to: gateway, commandNumber: 5, body: "")

        try await waitUntil("new pane snapshot is replayed") {
            !received.isEmpty
        }

        XCTAssertNotEqual(received, Data(prompt.utf8))
        XCTAssertNotNil(received.range(of: Data(prompt.utf8)))
        XCTAssertNotNil(received.range(of: Data("\u{1B}[1;13H".utf8)))
        XCTAssertEqual(controller.activePaneID, fourthPaneID)
        XCTAssertEqual(controller.windows[windowID]?.paneIDs, [firstPaneID, fourthPaneID, thirdPaneID, secondPaneID])
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

    func testPaneTerminalInputDoesNotReactivateInactiveTmuxWindow() async throws {
        let (_, controller, writer) = await makeStack()
        let oldWindowID = TmuxWindowID(rawValue: 1)
        let newWindowID = TmuxWindowID(rawValue: 2)
        let oldPaneID = TmuxPaneID(rawValue: 3)
        let newPaneID = TmuxPaneID(rawValue: 4)
        let oldPane = TmuxPane(id: oldPaneID, windowID: oldWindowID)
        let newPane = TmuxPane(id: newPaneID, windowID: newWindowID)

        controller.windows[oldWindowID] = TmuxWindow(
            id: oldWindowID,
            paneIDs: [oldPaneID],
            activePaneID: oldPaneID
        )
        controller.windows[newWindowID] = TmuxWindow(
            id: newWindowID,
            paneIDs: [newPaneID],
            activePaneID: newPaneID
        )
        controller.windowOrder = [oldWindowID, newWindowID]
        controller.panes[oldPaneID] = oldPane
        controller.panes[newPaneID] = newPane
        controller.activeWindowID = newWindowID
        controller.activePaneID = newPaneID

        let coordinator = TmuxPaneTerminal.Coordinator()
        coordinator.controller = controller
        coordinator.pane = oldPane

        coordinator.forwardFromTerminal(Data("x".utf8))

        try await waitUntil("inactive pane input is forwarded") {
            writer.capturedString.contains("%3")
        }
        XCTAssertEqual(controller.activeWindowID, newWindowID)
        XCTAssertEqual(controller.activePaneID, newPaneID)
    }

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
