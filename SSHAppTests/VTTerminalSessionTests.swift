import XCTest
@testable import GhosttyVT
@testable import GhosttyTerminal

/// Production VT session seam: ordered receive, viewport-driven resize,
/// reply forwarding and VT event fan-out without a `ghostty_surface_t`.
@MainActor
final class VTTerminalSessionTests: XCTestCase {
    private final class BellProbe: TerminalSurfaceBellDelegate {
        var rings = 0

        func terminalDidRingBell() {
            rings += 1
        }
    }

    private var defaultMetrics: VTTerminalSessionMetrics {
        VTTerminalSessionMetrics(
            width: 390,
            height: 480,
            cellWidth: 10,
            cellHeight: 20,
            scale: 2
        )
    }

    private func makeSession(
        writes: LockBox<[Data]> = LockBox([]),
        resizes: LockBox<[InMemoryTerminalViewport]> = LockBox([]),
        eventDelegate: (any TerminalSurfaceViewDelegate)? = nil
    ) -> VTTerminalSession {
        let session = VTTerminalSession(
            write: { value in writes.mutate { $0.append(value) } },
            resize: { value in resizes.mutate { $0.append(value) } }
        )
        session.eventDelegate = eventDelegate
        return session
    }

    func testReceiveBeforeViewportIsRejected() {
        let session = makeSession()
        XCTAssertFalse(session.receiveIfSurfaceAttached(Data("hello".utf8)))
    }

    func testNilViewportIsIgnored() {
        let session = makeSession()
        session.updateViewport(nil)
        XCTAssertFalse(session.receiveIfSurfaceAttached(Data("hello".utf8)))
    }

    func testReceiveSnapshotsTextAfterViewport() async throws {
        let session = makeSession()
        session.updateViewport(defaultMetrics)
        try await waitUntil("viewport ready") {
            (try? await session.snapshot()) != nil
        }
        XCTAssertTrue(session.receiveIfSurfaceAttached(Data("hello".utf8)))
        let line = LockBox("")
        try await waitUntil("hello snapshot") {
            guard let frame = try? await session.snapshot() else { return false }
            line.set(frame.line(0))
            return frame.line(0).hasPrefix("hello")
        }
        XCTAssertTrue(line.get().hasPrefix("hello"))
        session.finish()
    }

    func testResizeChangesReportedGrid() async throws {
        let resizes = LockBox<[InMemoryTerminalViewport]>([])
        let session = makeSession(resizes: resizes)
        session.updateViewport(defaultMetrics)
        try await waitUntil("initial grid") { resizes.get().count >= 1 }
        XCTAssertEqual(resizes.get().last?.columns, 37)
        XCTAssertEqual(resizes.get().last?.rows, 23)
    }

    func testBellEventReachesDelegate() async throws {
        let probe = BellProbe()
        let session = makeSession(eventDelegate: probe)
        session.updateViewport(defaultMetrics)
        try await waitUntil("viewport ready") {
            (try? await session.snapshot()) != nil
        }
        session.receive(Data([0x07]))
        try await waitUntil("bell rings") { probe.rings == 1 }
        XCTAssertEqual(probe.rings, 1)
        session.finish()
    }

    func testDeviceAttributesReplyIsForwarded() async throws {
        let writes = LockBox<[Data]>([])
        let session = makeSession(writes: writes)
        session.updateViewport(defaultMetrics)
        try await waitUntil("viewport ready") {
            (try? await session.snapshot()) != nil
        }
        session.receive(Data("\u{1B}[c".utf8))
        try await waitUntil("DA reply") { !writes.get().isEmpty }
        let reply = writes.get().joined()
        XCTAssertTrue(reply.contains(0x1B), "DA reply must be a terminal reply sequence")
        session.finish()
    }

    func testFinishInvalidatesQueuedWork() {
        let session = makeSession()
        session.updateViewport(defaultMetrics)
        session.finish()
        XCTAssertFalse(session.receiveIfSurfaceAttached(Data("late".utf8)))
    }

    func testSameGridScaleAndCellMetricsInvalidateLayout() async throws {
        let session = makeSession()
        session.updateViewport(defaultMetrics)
        let first = try await session.snapshot()
        var metrics = defaultMetrics
        metrics.scale = 3
        session.updateViewport(metrics)
        let scaled = try await session.snapshot()
        XCTAssertEqual(scaled.layout.columns, first.layout.columns)
        XCTAssertEqual(scaled.layout.scale, 3)
        XCTAssertGreaterThan(scaled.layout.generation, first.layout.generation)
        metrics.width += 1
        session.updateViewport(metrics)
        let resized = try await session.snapshot()
        XCTAssertEqual(resized.layout.viewportWidth, metrics.width)
        XCTAssertGreaterThan(resized.layout.generation, scaled.layout.generation)
        session.finish()
    }

    /// Regression: admission recorded metrics before the FIFO applied them, so
    /// a failed create/resize deduped every identical retry and VTContentView
    /// rejected all snapshots against the never-applied layout.
    func testFailedLayoutApplyAdmitsIdenticalRetry() async throws {
        let resizes = LockBox<[InMemoryTerminalViewport]>([])
        let session = makeSession(resizes: resizes)
        defer { session.finish() }
        let failing: @Sendable () throws -> Void = { throw VTError.invalidLayout }

        session.beforeLayoutApply = failing
        session.updateViewport(defaultMetrics)
        do {
            _ = try await session.snapshot()
            XCTFail("A failed first layout must not create a terminal")
        } catch {}
        session.beforeLayoutApply = nil
        session.updateViewport(defaultMetrics)
        let created = try await session.snapshot()
        XCTAssertEqual(created.layout.viewportWidth, defaultMetrics.width)
        XCTAssertEqual(resizes.get().count, 1)

        var scaled = defaultMetrics
        scaled.scale = 3
        session.beforeLayoutApply = failing
        session.updateViewport(scaled)
        let unchanged = try await session.snapshot()
        XCTAssertEqual(unchanged.layout.scale, defaultMetrics.scale)
        session.beforeLayoutApply = nil
        session.updateViewport(scaled)
        let resized = try await session.snapshot()
        XCTAssertEqual(resized.layout.scale, 3, "An identical retry after a failed resize must be admitted")
        XCTAssertGreaterThan(resized.layout.generation, created.layout.generation)
        XCTAssertEqual(resizes.get().count, 2)
    }

    func testConfigurationBeforeFirstViewportIsRetained() async throws {
        let session = makeSession()
        var configuration = VTTerminalConfiguration()
        configuration.background = VTColor(red: 19, green: 23, blue: 31)
        await session.configure(configuration)
        session.updateViewport(defaultMetrics)
        let frame = try await session.snapshot()
        XCTAssertEqual(frame.background, configuration.background)
        session.finish()
    }

    func testFinishCannotBeUndoneByPendingLayoutOrLaterUpdates() async throws {
        let session = makeSession()
        session.updateViewport(defaultMetrics)
        session.finish()
        session.updateViewport(defaultMetrics)
        do {
            _ = try await session.snapshot()
            XCTFail("Finished session must not recreate its terminal")
        } catch {
            XCTAssertEqual(error as? VTError, .retired)
        }
        let rejected = expectation(description: "late delivery rejected")
        session.deliver(Data("late".utf8), ifCurrent: { true }) { accepted in
            XCTAssertFalse(accepted)
            rejected.fulfill()
        }
        await fulfillment(of: [rejected], timeout: 5)
    }

    func testDeliveryCompletionMeansBytesAndRepliesAreCommitted() async throws {
        let writes = LockBox<[Data]>([])
        let session = makeSession(writes: writes)
        session.updateViewport(defaultMetrics)
        let committed = expectation(description: "committed")
        session.deliver(Data("hello\u{1B}[c".utf8), ifCurrent: { true }) { accepted in
            XCTAssertTrue(accepted)
            XCTAssertFalse(writes.get().isEmpty)
            committed.fulfill()
        }
        await fulfillment(of: [committed], timeout: 5)
        let frame = try await session.snapshot()
        XCTAssertTrue(frame.line(0).hasPrefix("hello"))
        session.finish()
    }

    func testSynchronousFeedCannotCreateUnboundedSecondaryOutputQueue() async throws {
        let session = makeSession()
        session.updateViewport(defaultMetrics)
        XCTAssertFalse(session.receiveIfSurfaceAttached(Data(repeating: 65, count: 512 * 1024 + 1)))
        let frame = try await session.snapshot()
        XCTAssertTrue(frame.line(0).trimmingCharacters(in: .whitespaces).isEmpty)
        session.finish()
    }

    func testSynchronousInputAdmissionPreservesOrderThroughImmediateFinish() async throws {
        let writes = LockBox<[Data]>([])
        let session = makeSession(writes: writes)
        session.updateViewport(defaultMetrics)
        let first = try XCTUnwrap(session.enqueueInput(.text("first")))
        let second = try XCTUnwrap(session.enqueueInput(.text("second")))
        session.finish()
        XCTAssertNil(session.enqueueInput(.text("late")))
        _ = try await first.value
        _ = try await second.value
        XCTAssertEqual(Data(writes.get().joined()), Data("firstsecond".utf8))
    }

    func testSemanticAdmissionCopiesWrappedTextBeforeImmediateFinish() async throws {
        let session = makeSession()
        session.updateViewport(.init(width: 50, height: 60, cellWidth: 10,
                                     cellHeight: 20, scale: 1, padding: 0))
        XCTAssertTrue(session.receiveIfSurfaceAttached(Data("hello world".utf8)))
        let select = try XCTUnwrap(session.enqueueSelectAll())
        let copy = try XCTUnwrap(session.enqueueSelectedText())
        let take = try XCTUnwrap(session.enqueueTakeSelectedText())
        let empty = try XCTUnwrap(session.enqueueSelectedText())
        session.finish()
        XCTAssertNil(session.enqueueSelectAll())
        XCTAssertNil(session.enqueueSelectedText())
        try await select.value
        let copied = try await copy.value
        let taken = try await take.value
        let cleared = try await empty.value
        XCTAssertEqual(copied, "hello world")
        XCTAssertEqual(taken, copied)
        XCTAssertEqual(cleared, "")
    }

    func testFinishForwardsRemotePointerReleaseAfterAcceptedInput() async throws {
        let writes = LockBox<[Data]>([])
        let released = expectation(description: "retirement release forwarded")
        let session = VTTerminalSession(write: { bytes in
            writes.mutate { $0.append(bytes) }
            if bytes == Data("\u{1B}[<0;1;1m".utf8) { released.fulfill() }
        }, resize: { _ in })
        session.updateViewport(defaultMetrics)
        session.receive(Data("\u{1B}[?1000h\u{1B}[?1006h".utf8))
        let frame = try await session.snapshot()
        let pointer = try XCTUnwrap(session.enqueuePointer(.init(id: 1,
            terminalID: frame.terminalID, generation: frame.layout.generation,
            revision: frame.revision, phase: .press, source: .touch,
            point: CGPoint(x: 9, y: 9), time: 1)))
        let input = try XCTUnwrap(session.enqueueInput(.text("middle")))
        session.finish()
        _ = try await pointer.value
        _ = try await input.value
        await fulfillment(of: [released], timeout: 5)
        XCTAssertEqual(writes.get(), [Data("\u{1B}[<0;1;1M".utf8), Data("middle".utf8),
                                      Data("\u{1B}[<0;1;1m".utf8)])
    }

    func testSelectionMutationsNotifyBeforeCompletionAndQueriesPreserveSelection() async throws {
        let session = makeSession()
        session.updateViewport(defaultMetrics)
        session.receive(Data("alpha beta".utf8))
        let frame = try await session.snapshot()
        let notifications = LockBox(0)
        session.onFramesAvailable = { notifications.mutate { $0 += 1 } }
        let select = try XCTUnwrap(session.enqueueSelect(.word, at: .init(column: 1, row: 0),
                                                        generation: frame.layout.generation))
        try await select.value
        XCTAssertEqual(notifications.get(), 1)
        let move = try XCTUnwrap(session.enqueueMoveSelection(start: false,
            to: .init(column: 6, row: 0), generation: frame.layout.generation))
        let drag = try XCTUnwrap(session.enqueueDragSelection(.init(gestureID: 1,
            terminalID: frame.terminalID, generation: frame.layout.generation, start: false,
            position: .init(column: 7, row: 0))))
        let adjust = try XCTUnwrap(session.enqueueAdjustSelection(start: false, forward: true,
            terminalID: frame.terminalID, generation: frame.layout.generation))
        try await move.value
        try await drag.value
        let changed = try await adjust.value
        XCTAssertTrue(changed)
        XCTAssertEqual(notifications.get(), 4)
        let selected = try await session.snapshot()
        let link = try XCTUnwrap(session.enqueueLinkHit(at: .init(column: 1, row: 0),
                                                       in: selected, geometry: true))
        let hit = try await link.value
        XCTAssertNil(hit)
        XCTAssertEqual(notifications.get(), 4)
        let scroll = try XCTUnwrap(session.enqueueScrollPointer(.init(terminalID: frame.terminalID,
            generation: frame.layout.generation, point: CGPoint(x: 9, y: 9),
            delta: .zero, modifiers: [])))
        _ = try await scroll.value
        let final = try await session.snapshot()
        XCTAssertEqual(final.selection, selected.selection)
        session.finish()
    }

    func testStaleSemanticRequestFailsWithoutBlockingFollowingCopy() async throws {
        let session = makeSession()
        session.updateViewport(defaultMetrics)
        session.receive(Data("one two".utf8))
        let frame = try await session.snapshot()
        let stale = try XCTUnwrap(session.enqueueSelect(.word, at: .init(column: 0, row: 0),
                                                        generation: frame.layout.generation + 1))
        let select = try XCTUnwrap(session.enqueueSelectAll())
        let copy = try XCTUnwrap(session.enqueueSelectedText())
        do { try await stale.value; XCTFail("Expected stale layout") }
        catch { XCTAssertEqual(error as? VTError, .staleLayout) }
        try await select.value
        let text = try await copy.value
        XCTAssertEqual(text, "one two")
        session.finish()
    }

    func testCanceledWrappersStillDrainAcceptedOperationsBeforeRetirement() async throws {
        let writes = LockBox<[Data]>([])
        let session = makeSession(writes: writes)
        session.updateViewport(defaultMetrics)
        _ = try await session.snapshot()
        let gate = DeliveryGate()
        let entered = expectation(description: "delivery holds the lane")
        let delivered = expectation(description: "accepted delivery survives finish")
        session.beforeDelivery = {
            entered.fulfill()
            await gate.wait()
        }
        session.deliver(Data("kept".utf8), ifCurrent: { true }) { accepted in
            XCTAssertTrue(accepted)
            delivered.fulfill()
        }
        await fulfillment(of: [entered], timeout: 5)
        session.beforeDelivery = nil

        let input = try XCTUnwrap(session.enqueueInput(.text("sent")))
        let select = try XCTUnwrap(session.enqueueSelectAll())
        let copy = try XCTUnwrap(session.enqueueSelectedText())
        input.cancel()
        select.cancel()
        copy.cancel()
        session.finish()
        XCTAssertNil(session.enqueueInput(.text("late")))
        XCTAssertFalse(session.receiveIfSurfaceAttached(Data("late".utf8)))

        await gate.open()
        await fulfillment(of: [delivered], timeout: 5)
        let sent = try await input.value
        try await select.value
        let copied = try await copy.value
        XCTAssertEqual(sent, Data("sent".utf8))
        XCTAssertEqual(writes.get(), [Data("sent".utf8)])
        XCTAssertEqual(copied, "kept")
    }

    func testLargeMixedPriorityBacklogDrainsWithoutPredecessorTaskChain() async throws {
        let timing = BacklogTimingDiagnostics()
        defer {
            timing.record("test.end")
            timing.emit(to: self)
        }
        timing.record("test.start")
        let writes = LockBox<[Data]>([])
        let probe = BellProbe()
        let session = makeSession(writes: writes, eventDelegate: probe)
        defer { session.finish() }
        session.updateViewport(defaultMetrics)
        _ = try await session.snapshot()

        let gate = DeliveryGate()
        let entered = DeliveryGate()
        let delivered = expectation(description: "gated delivery committed exactly once")
        delivered.assertForOverFulfill = true
        session.beforeDelivery = {
            timing.record("beforeDelivery.entry")
            await entered.open()
            await gate.wait()
            timing.record("beforeDelivery.afterGateWait")
        }
        let delivery = Task.detached(priority: .background) {
            await withCheckedContinuation { continuation in
                session.deliver(Data(), ifCurrent: { true }) { accepted in
                    timing.record("delivered.callbackEntry")
                    delivered.fulfill()
                    timing.record("delivered.afterFulfill")
                    continuation.resume(returning: accepted)
                }
            }
        }
        // Establish the blocked lane before clearing the hook or admitting work.
        // A wall-clock expectation can expire before a background task starts
        // under full-suite load, silently removing the barrier under test.
        timing.record("entered.beforeGateWait")
        await entered.wait()
        timing.record("entered.afterGateWait")
        session.beforeDelivery = nil

        // Keep thousands of one-byte admissions pending simultaneously. A high
        // priority task waiting on the old predecessor chain recursively
        // escalated every earlier task and exhausted the runtime's stack.
        let priorities: [TaskPriority] = [.background, .utility, .high]
        let cyclesPerBatch = 256
        var configuration = VTTerminalConfiguration()
        configuration.background = VTColor(red: 19, green: 23, blue: 31)
        let expectedConfiguration = configuration
        for (batch, priority) in priorities.enumerated() {
            let admitted = DeliveryGate()
            let producer = Task.detached(priority: priority) {
                var rejectedFeeds = 0
                var rejectedInputs = 0
                let configuration = session.enqueueConfiguration(expectedConfiguration)
                configuration?.cancel()
                for index in (batch * cyclesPerBatch)..<((batch + 1) * cyclesPerBatch) {
                    // CR + digit + bell + cursor query: seven separate feeds.
                    // Repeated queries must each observe precisely column two.
                    for byte in Data("\r\(index % 10)\u{7}\u{1B}[6n".utf8) {
                        if !session.receiveIfSurfaceAttached(Data([byte])) {
                            rejectedFeeds += 1
                        }
                    }
                    let marker = "input-\(index);"
                    if index.isMultiple(of: 2) {
                        // Canceling the API wrapper must not cancel accepted work.
                        let input = session.enqueueInput(.text(marker))
                        if input == nil { rejectedInputs += 1 }
                        input?.cancel()
                    } else {
                        session.sendInput(Data(marker.utf8))
                    }
                }
                timing.record("batch.\(batch).admitted")
                await admitted.open()
                return (configuration != nil, rejectedFeeds, rejectedInputs)
            }
            // Admission is finite synchronous work, independent of the blocked
            // drainer. Signal before joining so the test does not escalate the
            // producer while it creates the mixed-priority backlog. Unlike an
            // expectation timeout, this cannot start the next batch too early.
            await admitted.wait()
            let (configured, rejectedFeeds, rejectedInputs) = await producer.value
            XCTAssertTrue(configured, "Configuration rejected in batch \(batch)")
            XCTAssertEqual(rejectedFeeds, 0, "Feeds rejected in batch \(batch)")
            XCTAssertEqual(rejectedInputs, 0, "Inputs rejected in batch \(batch)")
        }
        XCTAssertEqual(probe.rings, 0)
        XCTAssertTrue(writes.get().isEmpty)

        let queried = expectation(description: "high-priority later query completes")
        let queryAdmitted = DeliveryGate()
        let query = Task.detached(priority: .high) {
            defer {
                timing.record("query.completion")
                queried.fulfill()
                timing.record("query.afterFulfill")
            }
            session.enqueueSelectAll()?.cancel()
            let copy = session.enqueueSelectedText()
            timing.record("query.admitted")
            await queryAdmitted.open()
            guard let copy else { throw VTError.retired }
            let copiedText = try await copy.value
            return (try await session.snapshot(), copiedText)
        }
        // The later high-priority query must be queued behind the entire
        // backlog before releasing it, regardless of executor scheduling.
        await queryAdmitted.wait()
        timing.record("gate.beforeOpen")
        await gate.open()
        timing.record("gate.afterOpen")
        // Join only after every mixed-priority admission and gate release. This
        // permits priority donation during completion without changing the
        // backlog's creation priorities or imposing a scheduler-speed limit.
        // Both tasks were already joined unconditionally after the old timeout;
        // keep that cleanup guarantee and check callback counts after joining.
        timing.record("delivery.beforeJoin")
        let accepted = await delivery.value
        timing.record("delivery.afterJoin")
        timing.record("query.beforeJoin")
        let (frame, copiedText) = try await query.value
        timing.record("query.afterJoin")
        timing.record("completion.beforeFulfillmentWait")
        await fulfillment(of: [delivered, queried], timeout: 5)
        timing.record("completion.afterFulfillmentWait")
        XCTAssertTrue(accepted)
        let cycles = priorities.count * cyclesPerBatch
        XCTAssertEqual(frame.background, expectedConfiguration.background)
        XCTAssertEqual(frame.line(0).trimmingCharacters(in: .whitespaces), "\((cycles - 1) % 10)")
        XCTAssertEqual(copiedText, "\((cycles - 1) % 10)")
        XCTAssertEqual(probe.rings, cycles, "No dropped or duplicated one-byte effects")
        let expectedWrites = (0..<cycles).flatMap { index in
            [Data("\u{1B}[1;2R".utf8), Data("input-\(index);".utf8)]
        }
        XCTAssertEqual(writes.get(), expectedWrites, "Replies and input must retain exact FIFO order")
    }

    func testDeliveryRevalidatesAfterEarlierWorkRatherThanAtScheduling() async throws {
        let session = makeSession()
        session.updateViewport(defaultMetrics)
        _ = try await session.snapshot()
        let current = LockBox(true)
        // A paused handoff holds the semantic lane without blocking MainActor.
        let gate = DeliveryGate()
        let entered = expectation(description: "earlier operation entered")
        session.beforeDelivery = {
            entered.fulfill()
            await gate.wait()
        }
        let first = expectation(description: "first committed")
        session.deliver(Data("first".utf8), ifCurrent: { true }) { accepted in
            XCTAssertTrue(accepted)
            first.fulfill()
        }
        await fulfillment(of: [entered], timeout: 5)
        session.beforeDelivery = nil
        let stale = expectation(description: "stale rejected")
        session.deliver(Data("stale".utf8), ifCurrent: { current.get() }) { accepted in
            XCTAssertFalse(accepted)
            stale.fulfill()
        }
        current.set(false)
        await gate.open()
        await fulfillment(of: [first, stale], timeout: 5)
        let frame = try await session.snapshot()
        XCTAssertTrue(frame.line(0).hasPrefix("first"))
        XCTAssertFalse(frame.line(0).contains("stale"))
        session.finish()
    }

}


/// Fixed-size, synchronous capture only; encoding and output happen after the test joins.
private final class BacklogTimingDiagnostics: @unchecked Sendable {
    private struct Event: Encodable {
        let phase: String
        let uptimeNanoseconds: UInt64
        let taskPriorityRawValue: UInt8
    }

    private struct Report: Encodable {
        let startedAtUptimeNanoseconds: UInt64
        let eventLimit: Int
        let droppedEvents: Int
        let events: [Event]
    }

    private let lock = NSLock()
    private let startedAtUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
    private let eventLimit = 32
    private var events: [Event] = []
    private var droppedEvents = 0

    init() {
        events.reserveCapacity(eventLimit)
    }

    func record(_ phase: String) {
        // Timestamp before locking so lock acquisition is not mistaken for callback entry.
        let event = Event(phase: phase, uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
                          taskPriorityRawValue: Task.currentPriority.rawValue)
        lock.lock()
        defer { lock.unlock() }
        guard events.count < eventLimit else {
            droppedEvents += 1
            return
        }
        events.append(event)
    }

    private func snapshot() -> Report {
        lock.lock()
        defer { lock.unlock() }
        return Report(startedAtUptimeNanoseconds: startedAtUptimeNanoseconds,
                      eventLimit: eventLimit, droppedEvents: droppedEvents, events: events)
    }

    @MainActor
    func emit(to test: XCTestCase) {
        let report = snapshot()
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let attachment = XCTAttachment(data: try encoder.encode(report),
                                           uniformTypeIdentifier: "public.json")
            attachment.name = "Mixed-priority backlog timing"
            attachment.lifetime = .keepAlways
            test.add(attachment)
        } catch {
            XCTFail("Could not encode backlog timing diagnostics: \(error)")
        }
        let summary = report.events.map { event in
            let milliseconds = Double(event.uptimeNanoseconds - report.startedAtUptimeNanoseconds) / 1_000_000
            return "\(event.phase)=\(String(format: "%.1f", milliseconds))ms/p\(event.taskPriorityRawValue)"
        }.joined(separator: " ")
        print("[MixedPriorityBacklogTiming] \(summary) dropped=\(report.droppedEvents)")
    }
}

private actor DeliveryGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
