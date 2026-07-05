import XCTest
@testable import SSHApp

/// Tests for `TmuxGateway`, the protocol-aware bridge between raw tmux
/// protocol lines and the controller. Validates command queue correlation,
/// edge cases (protocol-like response body lines, server-originated responses),
/// and shutdown semantics.
final class TmuxGatewayTests: XCTestCase {

    // MARK: - Test fixtures

    /// Records raw bytes written by the gateway.
    actor RecordingWriter {
        var written: [Data] = []
        func append(_ data: Data) { written.append(data) }
        func snapshot() -> [Data] { written }
        func snapshotJoinedString() -> String {
            var combined = Data()
            for d in written { combined.append(d) }
            return String(data: combined, encoding: .utf8) ?? ""
        }
    }

    /// Records all events delegated by the gateway.
    final class RecordingDelegate: TmuxGatewayDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [TmuxControllerEvent] = []
        private var _shutdownReasons: [String?] = []

        var events: [TmuxControllerEvent] {
            lock.withLock { _events }
        }

        var shutdownReasons: [String?] {
            lock.withLock { _shutdownReasons }
        }

        func gateway(_ gateway: TmuxGateway, didReceive event: TmuxControllerEvent) async {
            lock.withLock { _events.append(event) }
        }

        func gatewayDidShutDown(_ gateway: TmuxGateway, reason: String?) async {
            lock.withLock { _shutdownReasons.append(reason) }
        }
    }

    private func makeGateway() -> (TmuxGateway, RecordingWriter, RecordingDelegate) {
        let writer = RecordingWriter()
        let writerClosure: TmuxByteWriter = { data in
            await writer.append(data)
        }
        let gateway = TmuxGateway(writer: writerClosure)
        let delegate = RecordingDelegate()
        return (gateway, writer, delegate)
    }

    private func line(_ string: String) -> Data {
        Data(string.utf8)
    }

    // MARK: - 1. sendCommand happy path

    func testSendCommandResolvesWithBodyAndIsErrorFalse() async throws {
        let (gateway, writer, _) = makeGateway()

        let expectation = self.expectation(description: "sendCommand resolves")
        let task = Task<TmuxCommandResponse, Error> {
            let response = try await gateway.sendCommand("show-options")
            expectation.fulfill()
            return response
        }

        // Allow the gateway's internal write task to flush before feeding
        // the response.
        try await Task.sleep(nanoseconds: 50_000_000)

        await gateway.feedLine(line("%begin 1 1 1"))
        await gateway.feedLine(line("option1 value1"))
        await gateway.feedLine(line("%end 1 1 1"))

        await fulfillment(of: [expectation], timeout: 1.0)
        let response = try await task.value
        XCTAssertEqual(response.bodyString, "option1 value1")
        XCTAssertFalse(response.isError)
        XCTAssertEqual(response.commandNumber, 1)

        let writtenString = await writer.snapshotJoinedString()
        XCTAssertEqual(writtenString, "show-options\n")
    }

    // MARK: - 2. Two queued commands resolve in order

    func testTwoQueuedCommandsResolveInOrder() async throws {
        let (gateway, _, _) = makeGateway()

        let firstExpectation = expectation(description: "first")
        let secondExpectation = expectation(description: "second")

        let first = Task<TmuxCommandResponse, Error> {
            let r = try await gateway.sendCommand("first")
            firstExpectation.fulfill()
            return r
        }
        // Wait briefly so the first command is enqueued before the second.
        try await Task.sleep(nanoseconds: 20_000_000)
        let second = Task<TmuxCommandResponse, Error> {
            let r = try await gateway.sendCommand("second")
            secondExpectation.fulfill()
            return r
        }

        // Wait again so both pending commands are queued before responses begin.
        try await Task.sleep(nanoseconds: 50_000_000)

        await gateway.feedLine(line("%begin 1 1 1"))
        await gateway.feedLine(line("first response"))
        await gateway.feedLine(line("%end 1 1 1"))

        await gateway.feedLine(line("%begin 2 2 1"))
        await gateway.feedLine(line("second response"))
        await gateway.feedLine(line("%end 2 2 1"))

        await fulfillment(of: [firstExpectation, secondExpectation], timeout: 1.0)

        let firstResponse = try await first.value
        let secondResponse = try await second.value
        XCTAssertEqual(firstResponse.bodyString, "first response")
        XCTAssertEqual(secondResponse.bodyString, "second response")
    }

    // MARK: - 3. %error throws commandFailed

    func testErrorEndMakesContinuationThrowCommandFailed() async throws {
        let (gateway, _, _) = makeGateway()

        let expectation = self.expectation(description: "throws commandFailed")
        let task = Task<Result<TmuxCommandResponse, Error>, Never> {
            do {
                let response = try await gateway.sendCommand("bad-command")
                return .success(response)
            } catch {
                expectation.fulfill()
                return .failure(error)
            }
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        await gateway.feedLine(line("%begin 1 1 1"))
        await gateway.feedLine(line("error message"))
        await gateway.feedLine(line("%error 1 1 1"))

        await fulfillment(of: [expectation], timeout: 1.0)

        let result = await task.value
        switch result {
        case .success:
            XCTFail("expected commandFailed but got success")
        case .failure(let error):
            guard let tmuxError = error as? TmuxError, case .commandFailed(let message) = tmuxError else {
                XCTFail("expected TmuxError.commandFailed, got \(error)")
                return
            }
            XCTAssertEqual(message, "error message")
        }
    }

    // MARK: - 4. %exit outside a response block

    func testExitOutsideBlockDrainsQueuedCommandsAndShutsDown() async throws {
        let (gateway, _, delegate) = makeGateway()
        await gateway.setDelegate(delegate)

        let expectation = self.expectation(description: "queued throws disconnected")
        let task = Task<Result<TmuxCommandResponse, Error>, Never> {
            do {
                return .success(try await gateway.sendCommand("queued-command"))
            } catch {
                expectation.fulfill()
                return .failure(error)
            }
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        await gateway.feedLine(line("%exit server going away"))

        await fulfillment(of: [expectation], timeout: 1.0)

        switch await task.value {
        case .success:
            XCTFail("expected disconnected but command resolved")
        case .failure(let error):
            XCTAssertEqual(error as? TmuxError, TmuxError.disconnected)
        }

        // Subsequent sendCommand calls should also throw disconnected.
        do {
            _ = try await gateway.sendCommand("anything")
            XCTFail("expected disconnected on post-exit sendCommand")
        } catch {
            XCTAssertEqual(error as? TmuxError, TmuxError.disconnected)
        }

        // Delegate should have received .exit and gatewayDidShutDown.
        let events = delegate.events
        var foundExit = false
        for event in events {
            if case .exit(let reason) = event {
                XCTAssertEqual(reason, "server going away")
                foundExit = true
            }
        }
        XCTAssertTrue(foundExit, "expected .exit in delegate events")
        XCTAssertEqual(delegate.shutdownReasons, ["server going away"])
    }

    // MARK: - 5. shutdown(reason:) drains and notifies delegate

    func testShutdownResolvesAllPendingWithDisconnectedAndNotifiesDelegate() async throws {
        let (gateway, _, delegate) = makeGateway()
        await gateway.setDelegate(delegate)

        let expectation = self.expectation(description: "queued throws disconnected")
        expectation.expectedFulfillmentCount = 2

        let firstTask = Task<Result<TmuxCommandResponse, Error>, Never> {
            do { return .success(try await gateway.sendCommand("a")) }
            catch { expectation.fulfill(); return .failure(error) }
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        let secondTask = Task<Result<TmuxCommandResponse, Error>, Never> {
            do { return .success(try await gateway.sendCommand("b")) }
            catch { expectation.fulfill(); return .failure(error) }
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        await gateway.shutdown(reason: "test shutdown")

        await fulfillment(of: [expectation], timeout: 1.0)

        switch await firstTask.value {
        case .success: XCTFail("expected disconnected on first")
        case .failure(let error):
            XCTAssertEqual(error as? TmuxError, TmuxError.disconnected)
        }
        switch await secondTask.value {
        case .success: XCTFail("expected disconnected on second")
        case .failure(let error):
            XCTAssertEqual(error as? TmuxError, TmuxError.disconnected)
        }

        XCTAssertEqual(delegate.shutdownReasons, ["test shutdown"])
    }

    // MARK: - 6. Notification not in a block

    func testWindowAddNotificationOutsideBlockEmittedToDelegate() async throws {
        let (gateway, _, delegate) = makeGateway()
        await gateway.setDelegate(delegate)

        await gateway.feedLine(line("%window-add @5"))

        let events = delegate.events
        XCTAssertEqual(events.count, 1)
        guard case .windowAdd(let id) = events.first else {
            XCTFail("expected .windowAdd, got \(String(describing: events.first))")
            return
        }
        XCTAssertEqual(id, TmuxWindowID(rawValue: 5))
    }

    func testUnlinkedWindowCloseNotificationOutsideBlockEmittedToDelegate() async throws {
        let (gateway, _, delegate) = makeGateway()
        await gateway.setDelegate(delegate)

        await gateway.feedLine(line("%unlinked-window-close @6"))

        let events = delegate.events
        XCTAssertEqual(events.count, 1)
        guard case .unlinkedWindowClose(let id) = events.first else {
            XCTFail("expected .unlinkedWindowClose, got \(String(describing: events.first))")
            return
        }
        XCTAssertEqual(id, TmuxWindowID(rawValue: 6))
    }

    func testClientSessionChangedNotificationOutsideBlockEmittedToDelegate() async throws {
        let (gateway, _, delegate) = makeGateway()
        await gateway.setDelegate(delegate)

        await gateway.feedLine(line("%client-session-changed /dev/pts/22 $25 25"))

        let events = delegate.events
        XCTAssertEqual(events.count, 1)
        guard case let .clientSessionChanged(clientName, session, sessionName) = events.first else {
            XCTFail("expected .clientSessionChanged, got \(String(describing: events.first))")
            return
        }
        XCTAssertEqual(clientName, "/dev/pts/22")
        XCTAssertEqual(session, TmuxSessionID(rawValue: 25))
        XCTAssertEqual(sessionName, "25")
    }

    // MARK: - 7. Protocol-looking body inside a block

    func testNotificationLookingLineInsideBlockIsResponseBody() async throws {
        let (gateway, _, delegate) = makeGateway()
        await gateway.setDelegate(delegate)

        let expectation = self.expectation(description: "command resolves")
        let task = Task<TmuxCommandResponse, Error> {
            let r = try await gateway.sendCommand("capture-pane")
            expectation.fulfill()
            return r
        }

        try await Task.sleep(nanoseconds: 50_000_000)

        await gateway.feedLine(line("%begin 1 1 1"))
        await gateway.feedLine(line("%window-add @5"))
        await gateway.feedLine(line("body line"))
        await gateway.feedLine(line("%end 1 1 1"))

        await fulfillment(of: [expectation], timeout: 1.0)
        let response = try await task.value
        XCTAssertEqual(response.bodyString, "%window-add @5\nbody line")

        // tmux documents that notifications never occur inside an output block,
        // so a notification-looking line in a response is command output.
        let events = delegate.events
        var foundCommandResponse = false
        for event in events {
            if case .windowAdd = event { XCTFail("did not expect .windowAdd from response body") }
            if case .commandResponse(let response) = event,
               response.bodyString == "%window-add @5\nbody line" {
                foundCommandResponse = true
            }
        }
        XCTAssertTrue(foundCommandResponse, "expected .commandResponse among delegate events")
    }

    func testExitLineInsideCommandResponseIsBodyAndDoesNotShutdown() async throws {
        let (gateway, _, delegate) = makeGateway()
        await gateway.setDelegate(delegate)

        let expectation = self.expectation(description: "command resolves")
        let task = Task<TmuxCommandResponse, Error> {
            let r = try await gateway.sendCommand("capture-pane")
            expectation.fulfill()
            return r
        }

        try await Task.sleep(nanoseconds: 50_000_000)

        await gateway.feedLine(line("%begin 10 2 1"))
        await gateway.feedLine(line("before"))
        await gateway.feedLine(line("%exit"))
        await gateway.feedLine(line("after"))
        await gateway.feedLine(line("%end 10 2 1"))

        await fulfillment(of: [expectation], timeout: 1.0)
        let response = try await task.value
        XCTAssertEqual(response.bodyString, "before\n%exit\nafter")
        XCTAssertTrue(delegate.shutdownReasons.isEmpty)

        let followupExpectation = self.expectation(description: "followup resolves")
        let followup = Task<TmuxCommandResponse, Error> {
            let r = try await gateway.sendCommand("display-message")
            followupExpectation.fulfill()
            return r
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        await gateway.feedLine(line("%begin 11 3 1"))
        await gateway.feedLine(line("still attached"))
        await gateway.feedLine(line("%end 11 3 1"))

        await fulfillment(of: [followupExpectation], timeout: 1.0)
        let followupResponse = try await followup.value
        XCTAssertEqual(followupResponse.bodyString, "still attached")
    }

    func testMismatchedEndLineInsideCommandResponseIsBody() async throws {
        let (gateway, _, _) = makeGateway()

        let expectation = self.expectation(description: "command resolves")
        let task = Task<TmuxCommandResponse, Error> {
            let r = try await gateway.sendCommand("capture-pane")
            expectation.fulfill()
            return r
        }

        try await Task.sleep(nanoseconds: 50_000_000)

        await gateway.feedLine(line("%begin 20 4 1"))
        await gateway.feedLine(line("prompt output"))
        await gateway.feedLine(line("%end 1783098058 343877 1"))
        await gateway.feedLine(line("%error 1783098059 343878 1"))
        await gateway.feedLine(line("%end 20 4 1"))

        await fulfillment(of: [expectation], timeout: 1.0)
        let response = try await task.value
        XCTAssertEqual(
            response.bodyString,
            "prompt output\n%end 1783098058 343877 1\n%error 1783098059 343878 1"
        )
    }

    // MARK: - 8. sendKeysToPane fire-and-forget

    func testSendKeysToPaneWritesEncodedCommandsAndDoesNotReturnResponses() async throws {
        let (gateway, writer, _) = makeGateway()

        let pane = TmuxPaneID(rawValue: 3)
        let version = TmuxVersion(major: 3, minor: 0, letterOffset: 1)
        let payload = Data("x".utf8)

        // Fire-and-forget the call. We then feed the matching %begin/%end so
        // the queue stays consistent.
        let task = Task<Void, Error> {
            try await gateway.sendKeysToPane(pane, data: payload, version: version)
        }

        // Wait for the writer to receive the bytes.
        try await Task.sleep(nanoseconds: 80_000_000)

        // Feed matching response (one command from "x" → one %begin/%end).
        await gateway.feedLine(line("%begin 1 1 1"))
        await gateway.feedLine(line("%end 1 1 1"))

        // Should not throw — even if the response would be %error, sendKeys
        // discards individual responses and only surfaces writer errors.
        try await task.value

        let writtenString = await writer.snapshotJoinedString()
        XCTAssertEqual(writtenString, "send -lt %3 \"x\"\n")
    }

    func testSendKeysToPaneErrorResponseIsSwallowed() async throws {
        let (gateway, _, _) = makeGateway()

        let pane = TmuxPaneID(rawValue: 3)
        let version = TmuxVersion(major: 3, minor: 0, letterOffset: 1)
        let payload = Data("x".utf8)

        let task = Task<Void, Error> {
            try await gateway.sendKeysToPane(pane, data: payload, version: version)
        }
        try await Task.sleep(nanoseconds: 80_000_000)

        // Feed an %error response — the discarding handler should swallow it
        // without surfacing to the caller of sendKeysToPane.
        await gateway.feedLine(line("%begin 1 1 1"))
        await gateway.feedLine(line("oops"))
        await gateway.feedLine(line("%error 1 1 1"))

        // Must not throw.
        try await task.value
    }

    // MARK: - 9. detach

    func testDetachWritesDetachAndShutsDown() async throws {
        let (gateway, writer, _) = makeGateway()

        try await gateway.detach()

        let writtenString = await writer.snapshotJoinedString()
        XCTAssertEqual(writtenString, "detach\n")

        // Subsequent sendCommand throws disconnected.
        do {
            _ = try await gateway.sendCommand("anything")
            XCTFail("expected disconnected after detach")
        } catch {
            XCTAssertEqual(error as? TmuxError, TmuxError.disconnected)
        }
    }

    // MARK: - 10. Server-originated response

    func testServerOriginatedResponseEmittedToDelegateOnly() async throws {
        let (gateway, _, delegate) = makeGateway()
        await gateway.setDelegate(delegate)

        // No sendCommand has been issued — feed a %begin with bit-0 cleared.
        // Per spec: flag bit 0 == 0 means server-originated.
        await gateway.feedLine(line("%begin 1 99 0"))
        await gateway.feedLine(line("server body"))
        await gateway.feedLine(line("%end 1 99 0"))

        let events = delegate.events
        XCTAssertEqual(events.count, 1)
        guard case .commandResponse(let response) = events.first else {
            XCTFail("expected .commandResponse, got \(String(describing: events.first))")
            return
        }
        XCTAssertEqual(response.bodyString, "server body")
        XCTAssertEqual(response.commandNumber, 99)
    }

    // MARK: - 11. Body trimming

    func testSingleBodyLineDoesNotIncludeTrailingNewline() async throws {
        let (gateway, _, _) = makeGateway()

        let expectation = self.expectation(description: "resolves")
        let task = Task<TmuxCommandResponse, Error> {
            let r = try await gateway.sendCommand("show")
            expectation.fulfill()
            return r
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        await gateway.feedLine(line("%begin 1 1 1"))
        await gateway.feedLine(line("only line"))
        await gateway.feedLine(line("%end 1 1 1"))
        await fulfillment(of: [expectation], timeout: 1.0)

        let response = try await task.value
        XCTAssertEqual(response.body, Data("only line".utf8))
        XCTAssertEqual(response.bodyString, "only line")
    }

    func testMultiLineBodyJoinsWithNewlineAndTrimsTrailing() async throws {
        let (gateway, _, _) = makeGateway()

        let expectation = self.expectation(description: "resolves")
        let task = Task<TmuxCommandResponse, Error> {
            let r = try await gateway.sendCommand("show")
            expectation.fulfill()
            return r
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        await gateway.feedLine(line("%begin 1 1 1"))
        await gateway.feedLine(line("alpha"))
        await gateway.feedLine(line("beta"))
        await gateway.feedLine(line("gamma"))
        await gateway.feedLine(line("%end 1 1 1"))
        await fulfillment(of: [expectation], timeout: 1.0)

        let response = try await task.value
        XCTAssertEqual(response.bodyString, "alpha\nbeta\ngamma")
        XCTAssertFalse(response.bodyString.hasSuffix("\n"))
    }

    func testEmptyBodyResponse() async throws {
        let (gateway, _, _) = makeGateway()

        let expectation = self.expectation(description: "resolves")
        let task = Task<TmuxCommandResponse, Error> {
            let r = try await gateway.sendCommand("set-hook")
            expectation.fulfill()
            return r
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        await gateway.feedLine(line("%begin 1 1 1"))
        await gateway.feedLine(line("%end 1 1 1"))
        await fulfillment(of: [expectation], timeout: 1.0)

        let response = try await task.value
        XCTAssertEqual(response.body, Data())
        XCTAssertEqual(response.bodyString, "")
        XCTAssertFalse(response.isError)
    }

    // MARK: - %output passthrough

    func testOutputNotificationPassedToDelegateUnchanged() async throws {
        let (gateway, _, delegate) = makeGateway()
        await gateway.setDelegate(delegate)

        await gateway.feedLine(line("%output %3 hello"))

        let events = delegate.events
        XCTAssertEqual(events.count, 1)
        guard case .output(let pane, let data) = events.first else {
            XCTFail("expected .output event, got \(String(describing: events.first))")
            return
        }
        XCTAssertEqual(pane, TmuxPaneID(rawValue: 3))
        // The exact bytes depend on the parser's escape handling — the
        // gateway just forwards them.
        XCTAssertFalse(data.isEmpty)
    }

    // MARK: - Drop after shutdown

    func testFeedLineAfterShutdownIsIgnored() async throws {
        let (gateway, _, delegate) = makeGateway()
        await gateway.setDelegate(delegate)

        await gateway.shutdown(reason: nil)

        // Subsequent feeds must be ignored.
        await gateway.feedLine(line("%window-add @5"))

        // Only event should be the prior shutdown notification (delivered
        // via gatewayDidShutDown, not via .didReceive). So the events list
        // is empty.
        XCTAssertTrue(delegate.events.isEmpty)
    }
}
