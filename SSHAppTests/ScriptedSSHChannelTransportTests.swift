import Foundation
import XCTest
@testable import SSHApp

@MainActor
final class ScriptedSSHChannelTransportTests: XCTestCase {
    func testImmediateOpenCapturesRequestedTerminalAndDimensions() async throws {
        let transport = ScriptedSSHChannelTransport()
        transport.queueOpenPlan(.succeed)

        let channelID = try await transport.openShellChannel(
            term: "screen-256color",
            cols: 132,
            rows: 43,
            onDataReceived: { _ in },
            onClosed: { _ in }
        )

        let snapshot = transport.snapshot()
        XCTAssertEqual(snapshot.activeChannelIDs, [channelID])
        XCTAssertEqual(
            snapshot.latestDimensions[channelID],
            .init(cols: 132, rows: 43)
        )
        XCTAssertTrue(snapshot.pendingRequests.isEmpty)
        XCTAssertTrue(snapshot.queuedOpenPlans.isEmpty)
        XCTAssertEqual(snapshot.ledger.map(\.sequence), [1, 2])
        guard case let .openRequested(_, term, cols, rows, epoch, plan) =
            snapshot.ledger[0].event
        else {
            return XCTFail("expected openRequested as the first event")
        }
        XCTAssertEqual(term, "screen-256color")
        XCTAssertEqual(cols, 132)
        XCTAssertEqual(rows, 43)
        XCTAssertEqual(epoch, 0)
        XCTAssertEqual(plan, .succeed)

        try await close(channelID, on: transport)
    }

    func testMultiplePendingOpensHaveUniqueOrderedRequestAndChannelIDs() async throws {
        let transport = ScriptedSSHChannelTransport()

        let firstOpen = openTask(on: transport, term: "first", cols: 80, rows: 24)
        let firstEvent = try await transport.nextEvent(matching: Self.isOpenRequested)
        let firstRequestID = try requestID(from: firstEvent)

        let secondOpen = openTask(on: transport, term: "second", cols: 100, rows: 30)
        let secondEvent = try await transport.nextEvent(
            after: firstEvent.sequence,
            matching: Self.isOpenRequested
        )
        let secondRequestID = try requestID(from: secondEvent)

        XCTAssertNotEqual(firstRequestID, secondRequestID)
        XCTAssertEqual(
            transport.snapshot().pendingRequests.map(\.id),
            [firstRequestID, secondRequestID]
        )

        let completedFirstChannelID = await transport.completeOpen(firstRequestID)
        let completedSecondChannelID = await transport.completeOpen(secondRequestID)
        let firstChannelID = try XCTUnwrap(completedFirstChannelID)
        let secondChannelID = try XCTUnwrap(completedSecondChannelID)
        let openedFirstChannelID = try await firstOpen.value
        let openedSecondChannelID = try await secondOpen.value
        XCTAssertEqual(openedFirstChannelID, firstChannelID)
        XCTAssertEqual(openedSecondChannelID, secondChannelID)
        XCTAssertNotEqual(firstChannelID, secondChannelID)

        let snapshot = transport.snapshot()
        XCTAssertEqual(snapshot.activeChannelIDs, [firstChannelID, secondChannelID])
        XCTAssertEqual(
            snapshot.ledger.map(\.sequence),
            Array(1 ... UInt64(snapshot.ledger.count))
        )

        try await close(firstChannelID, on: transport)
        try await close(secondChannelID, on: transport)
    }

    func testServerDataBeforeAndAfterOpenCompletionRunsOnMainActorInOrder() async throws {
        let transport = ScriptedSSHChannelTransport()
        let recorder = CallbackRecorder()
        let open = Task {
            try await transport.openShellChannel(
                term: "xterm-256color",
                cols: 80,
                rows: 24,
                onDataReceived: { data in
                    recorder.record(data: data, wasMainThread: Thread.isMainThread)
                },
                onClosed: { reason in
                    recorder.record(close: reason, wasMainThread: Thread.isMainThread)
                }
            )
        }
        let openEvent = try await transport.nextEvent(matching: Self.isOpenRequested)
        let requestID = try requestID(from: openEvent)
        let before = Data("before\n".utf8)
        let after = Data("after\n".utf8)

        let deliveredBeforeOpen = await transport.deliverServerData(before, to: requestID)
        XCTAssertTrue(deliveredBeforeOpen)
        let completedChannelID = await transport.completeOpen(requestID)
        let channelID = try XCTUnwrap(completedChannelID)
        let openedChannelID = try await open.value
        XCTAssertEqual(openedChannelID, channelID)
        let deliveredAfterOpen = await transport.deliverServerData(after, to: channelID)
        XCTAssertTrue(deliveredAfterOpen)

        XCTAssertEqual(recorder.data, [before, after])
        XCTAssertEqual(recorder.callbackMainThreadValues, [true, true])
        let deliveredData = transport.snapshot().ledger.compactMap { recorded -> Data? in
            guard case let .dataDelivered(_, data) = recorded.event else { return nil }
            return data
        }
        XCTAssertEqual(deliveredData, [before, after])

        try await close(channelID, on: transport)
        XCTAssertEqual(recorder.closes, [.local])
        XCTAssertEqual(recorder.callbackMainThreadValues, [true, true, true])
    }

    func testWritesAndResizesAreCapturedAgainstTheirChannelsInEventOrder() async throws {
        let transport = ScriptedSSHChannelTransport()
        transport.queueOpenPlans([.succeed, .succeed])
        let first = try await openImmediately(on: transport, term: "one")
        let second = try await openImmediately(on: transport, term: "two")
        let firstWrite = Data([0x01, 0x02])
        let secondWrite = Data("raw mouse bytes".utf8)

        transport.write(secondWrite, to: second)
        transport.resizePTY(channel: first, cols: 120, rows: 40)
        transport.write(firstWrite, to: first)
        transport.resizePTY(channel: second, cols: 90, rows: 28)

        let snapshot = transport.snapshot()
        XCTAssertEqual(
            snapshot.capturedClientWrites,
            [
                .init(channelID: second, data: secondWrite),
                .init(channelID: first, data: firstWrite),
            ]
        )
        XCTAssertEqual(snapshot.latestDimensions[first], .init(cols: 120, rows: 40))
        XCTAssertEqual(snapshot.latestDimensions[second], .init(cols: 90, rows: 28))

        let operationOrder = snapshot.ledger.compactMap { recorded -> String? in
            switch recorded.event {
            case .clientWrite(let channelID, _):
                return channelID == first ? "write-first" : "write-second"
            case .resize(let channelID, _, _):
                return channelID == first ? "resize-first" : "resize-second"
            default:
                return nil
            }
        }
        XCTAssertEqual(
            operationOrder,
            ["write-second", "resize-first", "write-first", "resize-second"]
        )

        try await close(first, on: transport)
        try await close(second, on: transport)
    }

    func testLocalRemoteAndTransportFailureCloseReasonsRemainDistinct() async throws {
        let transport = ScriptedSSHChannelTransport()
        let recorder = CallbackRecorder()
        transport.queueOpenPlans([.succeed, .succeed, .succeed])
        let local = try await openImmediately(on: transport, recorder: recorder)
        let orderly = try await openImmediately(on: transport, recorder: recorder)
        let failed = try await openImmediately(on: transport, recorder: recorder)

        try await close(local, on: transport)
        let deliveredOrderlyClose = await transport.deliverClose(
            .remoteProcessExited,
            to: orderly
        )
        let deliveredFailureClose = await transport.deliverClose(
            .transportFailure,
            to: failed
        )
        XCTAssertTrue(deliveredOrderlyClose)
        XCTAssertTrue(deliveredFailureClose)

        XCTAssertEqual(
            recorder.closes,
            [.local, .remoteProcessExited, .transportFailure]
        )
        let snapshot = transport.snapshot()
        XCTAssertTrue(snapshot.activeChannelIDs.isEmpty)
        XCTAssertTrue(snapshot.pendingCallbackWork.isEmpty)
        XCTAssertEqual(
            snapshot.ledger.filter {
                if case .localCloseRequested = $0.event { return true }
                return false
            }.count,
            1
        )
        XCTAssertEqual(
            snapshot.ledger.compactMap { recorded -> SSHTransportChannelCloseReason? in
                guard case let .remoteCloseDelivered(_, reason) = recorded.event else {
                    return nil
                }
                return reason
            },
            [.remoteProcessExited, .transportFailure]
        )
    }

    func testHonoredCancellationFailsPendingOpenPromptlyAndExactlyOnce() async throws {
        let transport = ScriptedSSHChannelTransport()
        transport.queueOpenPlan(.suspend(cancellation: .honorTransportCancellation))
        let open = openTask(on: transport)
        let openEvent = try await transport.nextEvent(matching: Self.isOpenRequested)
        let requestID = try requestID(from: openEvent)

        transport.cancelOpeningShellChannel()
        await assertCancellation(from: open)
        transport.cancelOpeningShellChannel()

        let snapshot = transport.snapshot()
        XCTAssertTrue(snapshot.pendingRequests.isEmpty)
        XCTAssertEqual(snapshot.cancellationEpoch, 2)
        let requestFailures = snapshot.ledger.filter { recorded in
            guard case let .openFailed(failedID, _) = recorded.event else { return false }
            return failedID == requestID
        }
        XCTAssertEqual(requestFailures.count, 1)
        guard case let .openFailed(_, .cancelled(cancellationEpoch)) = requestFailures.first?.event
        else {
            return XCTFail("expected one transport cancellation failure")
        }
        XCTAssertEqual(cancellationEpoch, 1)
    }

    func testIgnoredCancellationCanCompleteLateButSSHChannelClosesItAndStaysClosed() async throws {
        let transport = ScriptedSSHChannelTransport()
        transport.queueOpenPlan(.suspend(cancellation: .ignoreTransportCancellation))
        let channel = SSHChannel(
            transport: transport,
            owner: SSHSession(),
            tmuxSettings: .default
        )
        let open = Task { try await channel.openShell() }
        let openEvent = try await transport.nextEvent(matching: Self.isOpenRequested)
        let requestID = try requestID(from: openEvent)

        channel.close()
        let cancellation = try await transport.nextEvent(
            after: openEvent.sequence,
            matching: { event in
                guard case let .openingCancellation(_, _, _, ignored) = event else {
                    return false
                }
                return ignored == [requestID]
            }
        )
        let completedLateChannelID = await transport.completeOpen(requestID)
        let lateChannelID = try XCTUnwrap(completedLateChannelID)
        await assertCancellation(from: open)
        let localClose = try await transport.nextEvent(
            after: cancellation.sequence,
            matching: { event in
                guard case let .localCloseRequested(channelID) = event else { return false }
                return channelID == lateChannelID
            }
        )
        _ = try await transport.nextEvent(
            after: localClose.sequence,
            matching: Self.isCallbackCompleted
        )

        XCTAssertFalse(channel.isOpen)
        XCTAssertTrue(transport.snapshot().activeChannelIDs.isEmpty)
        XCTAssertTrue(transport.snapshot().pendingCallbackWork.isEmpty)
    }

    func testOpenStartedAfterEarlierCancellationUsesNewEpochAndCanSucceed() async throws {
        let transport = ScriptedSSHChannelTransport()
        transport.cancelOpeningShellChannel()
        transport.queueOpenPlan(.suspend(cancellation: .honorTransportCancellation))

        let open = openTask(on: transport)
        let event = try await transport.nextEvent(
            after: transport.snapshot().ledger.first?.sequence ?? 0,
            matching: Self.isOpenRequested
        )
        let requestID = try requestID(from: event)
        guard case let .openRequested(_, _, _, _, epoch, _) = event.event else {
            return XCTFail("expected open request")
        }
        XCTAssertEqual(epoch, 1)

        let completedChannelID = await transport.completeOpen(requestID)
        let channelID = try XCTUnwrap(completedChannelID)
        let openedChannelID = try await open.value
        XCTAssertEqual(openedChannelID, channelID)
        XCTAssertEqual(transport.snapshot().cancellationEpoch, 1)
        try await close(channelID, on: transport)
    }

    func testCompetingCompletionFailureAndCancellationResumeOpenOnlyOnce() async throws {
        let transport = ScriptedSSHChannelTransport()
        transport.queueOpenPlan(.suspend(cancellation: .honorTransportCancellation))
        let open = openTask(on: transport)
        let openEvent = try await transport.nextEvent(matching: Self.isOpenRequested)
        let requestID = try requestID(from: openEvent)
        let scriptedError = ScriptedSSHChannelTransport.ScriptedError("racing failure")

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = await transport.completeOpen(requestID)
            }
            group.addTask {
                _ = await transport.failOpen(requestID, with: scriptedError)
            }
            group.addTask {
                transport.cancelOpeningShellChannel()
            }
            await group.waitForAll()
        }

        do {
            _ = try await open.value
        } catch is CancellationError {
            // Cancellation won the race.
        } catch let error as ScriptedSSHChannelTransport.ScriptedError {
            XCTAssertEqual(error, scriptedError)
        } catch {
            XCTFail("unexpected open result: \(error)")
        }

        let snapshot = transport.snapshot()
        let terminalEvents = snapshot.ledger.filter { recorded in
            switch recorded.event {
            case .openCompleted(let completedID, _):
                return completedID == requestID
            case .openFailed(let failedID, _):
                return failedID == requestID
            default:
                return false
            }
        }
        XCTAssertEqual(terminalEvents.count, 1)
        XCTAssertTrue(snapshot.pendingRequests.isEmpty)

        if case let .openCompleted(_, channelID) = terminalEvents[0].event {
            try await close(channelID, on: transport)
        }
    }

    func testTimedOutWaitIncludesLedgerDiagnosticsAndRemovesWaiter() async {
        let transport = ScriptedSSHChannelTransport()
        transport.cancelOpeningShellChannel()
        let sequence = transport.snapshot().lastEventSequence

        do {
            _ = try await transport.nextEvent(
                after: sequence,
                timeout: .zero,
                matching: { _ in false }
            )
            XCTFail("expected a bounded wait timeout")
        } catch let error as ScriptedSSHChannelTransport.EventWaitError {
            XCTAssertEqual(error.reason, .timedOut)
            XCTAssertEqual(error.afterSequence, sequence)
            XCTAssertEqual(error.ledger, transport.snapshot().ledger)
            XCTAssertTrue(error.description.contains("Event ledger:"))
            XCTAssertTrue(error.description.contains("openingCancellation"))
        } catch {
            XCTFail("unexpected wait error: \(error)")
        }

        XCTAssertEqual(transport.snapshot().eventWaiterCount, 0)
    }

    func testStaleResolvedOpenRequestOperationsCannotAffectRetriedCurrentGeneration() async throws {
        let transport = ScriptedSSHChannelTransport()
        let firstError = ScriptedSSHChannelTransport.ScriptedError("first open failed")
        transport.queueOpenPlans([.fail(firstError), .suspend()])
        let channel = SSHChannel(
            transport: transport,
            owner: SSHSession(),
            tmuxSettings: .default
        )

        do {
            try await channel.openShell()
            XCTFail("expected first open to fail")
        } catch let error as ScriptedSSHChannelTransport.ScriptedError {
            XCTAssertEqual(error, firstError)
        }
        let firstRequestID = try requestID(from: transport.snapshot().ledger[0])

        let retry = Task { try await channel.openShell() }
        let retryEvent = try await transport.nextEvent(
            after: transport.snapshot().ledger[1].sequence,
            matching: Self.isOpenRequested
        )
        let retryRequestID = try requestID(from: retryEvent)
        XCTAssertNotEqual(firstRequestID, retryRequestID)

        // Retained callbacks let regressions drive a resolved generation after a
        // retry has started. SSHChannel must ignore both stale callbacks.
        let deliveredStaleData = await transport.deliverServerData(
            Data("stale".utf8),
            to: firstRequestID
        )
        let deliveredStaleClose = await transport.deliverClose(
            .transportFailure,
            to: firstRequestID
        )
        XCTAssertTrue(deliveredStaleData)
        XCTAssertTrue(deliveredStaleClose)

        let completedCurrentChannelID = await transport.completeOpen(retryRequestID)
        let currentChannelID = try XCTUnwrap(completedCurrentChannelID)
        try await retry.value
        XCTAssertTrue(channel.isOpen)
        XCTAssertEqual(transport.snapshot().activeChannelIDs, [currentChannelID])
        XCTAssertEqual(
            transport.snapshot().ledger.filter { recorded in
                guard case .ignoredInvalidOperation = recorded.event else { return false }
                return true
            }.count,
            0
        )

        channel.close()
        let localClose = try await transport.nextEvent(matching: { event in
            guard case let .localCloseRequested(channelID) = event else { return false }
            return channelID == currentChannelID
        })
        _ = try await transport.nextEvent(
            after: localClose.sequence,
            matching: Self.isCallbackCompleted
        )
        XCTAssertFalse(channel.isOpen)
    }

    private func openTask(
        on transport: ScriptedSSHChannelTransport,
        term: String = "xterm-256color",
        cols: Int = 80,
        rows: Int = 24
    ) -> Task<SSHTransportChannelID, Error> {
        Task {
            try await transport.openShellChannel(
                term: term,
                cols: cols,
                rows: rows,
                onDataReceived: { _ in },
                onClosed: { _ in }
            )
        }
    }

    private func openImmediately(
        on transport: ScriptedSSHChannelTransport,
        term: String = "xterm-256color",
        recorder: CallbackRecorder? = nil
    ) async throws -> SSHTransportChannelID {
        try await transport.openShellChannel(
            term: term,
            cols: 80,
            rows: 24,
            onDataReceived: { data in
                recorder?.record(data: data, wasMainThread: Thread.isMainThread)
            },
            onClosed: { reason in
                recorder?.record(close: reason, wasMainThread: Thread.isMainThread)
            }
        )
    }

    private func close(
        _ channelID: SSHTransportChannelID,
        on transport: ScriptedSSHChannelTransport
    ) async throws {
        let sequence = transport.snapshot().lastEventSequence
        transport.closeChannel(channelID)
        _ = try await transport.nextEvent(
            after: sequence,
            matching: Self.isCallbackCompleted
        )
    }

    private func requestID(
        from event: ScriptedSSHChannelTransport.RecordedEvent
    ) throws -> ScriptedSSHChannelTransport.OpenRequestID {
        guard case let .openRequested(requestID, _, _, _, _, _) = event.event else {
            throw TestFailure.expectedOpenRequest
        }
        return requestID
    }

    private func assertCancellation(
        from task: Task<SSHTransportChannelID, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await task.value
            XCTFail("expected CancellationError", file: file, line: line)
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("unexpected error: \(error)", file: file, line: line)
        }
    }

    private func assertCancellation(
        from task: Task<Void, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await task.value
            XCTFail("expected CancellationError", file: file, line: line)
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("unexpected error: \(error)", file: file, line: line)
        }
    }

    nonisolated private static func isOpenRequested(
        _ event: ScriptedSSHChannelTransport.Event
    ) -> Bool {
        if case .openRequested = event { return true }
        return false
    }

    nonisolated private static func isCallbackCompleted(
        _ event: ScriptedSSHChannelTransport.Event
    ) -> Bool {
        if case .callbackCompleted = event { return true }
        return false
    }
}

@MainActor
private final class CallbackRecorder {
    private(set) var data: [Data] = []
    private(set) var closes: [SSHTransportChannelCloseReason] = []
    private(set) var callbackMainThreadValues: [Bool] = []

    func record(data value: Data, wasMainThread: Bool) {
        data.append(value)
        callbackMainThreadValues.append(wasMainThread)
    }

    func record(close reason: SSHTransportChannelCloseReason, wasMainThread: Bool) {
        closes.append(reason)
        callbackMainThreadValues.append(wasMainThread)
    }
}

private enum TestFailure: Error {
    case expectedOpenRequest
}
