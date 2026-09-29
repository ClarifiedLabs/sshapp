import UIKit
import XCTest
@testable import GhosttyVT

/// Exercise packaged admission/ownership with isolated quotas, not the shared
/// policy allowance or process-memory measurements.
@MainActor
final class VTMetalPreparationBudgetTests: XCTestCase {
    private let font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    func testPipelinesReserveBeforePreparationAndHoldThroughGPUAndPresentationObservation() async throws {
        let frame = try await makeFrame()
        let cost = try VTMetalRasterizer().preparationBytes(for: frame)
        let budget = VTMetalPreparationBudget(limitBytes: cost)
        let idle = VTMetalIdleCacheBudget(limitBytes: 0)
        let panes = try (0..<3).map { _ in
            try VTMetalFramePipeline(font: font, idleCacheBudget: idle, preparationBudget: budget)
        }
        let gate = PresentationGate()
        defer {
            panes.forEach { $0.retire() }
            gate.open()
        }
        var rendered = 0
        var observed = 0
        for pane in panes {
            pane.publicationHoldForTesting = { await gate.wait() }
            pane.beforeRenderedPublicationForTesting = { [weak pane] in
                XCTAssertEqual(budget.metrics.reservedBytes, pane?.cacheMetrics.retainedTextureBytes,
                               "Reduction must precede even the pre-publication test callback")
                XCTAssertEqual(budget.metrics.activeLeases, 1)
            }
            pane.onRendered = { [weak pane] actual in
                guard let pane else { return XCTFail("Pane released during its lease") }
                rendered += 1
                XCTAssertEqual(actual, frame)
                XCTAssertEqual(budget.metrics.activeLeases, 1)
                XCTAssertEqual(budget.metrics.reservedBytes, pane.cacheMetrics.retainedTextureBytes)
                XCTAssertLessThan(budget.metrics.reservedBytes, cost)
            }
            pane.onObservation = { [weak pane] completion in
                guard let pane else { return XCTFail("Pane released during its lease") }
                observed += 1
                XCTAssertEqual(completion.frame, frame)
                XCTAssertEqual(budget.metrics.activeLeases, 1)
                XCTAssertEqual(budget.metrics.reservedBytes, pane.cacheMetrics.retainedTextureBytes,
                               "Observation still owns the texture reservation and permit")
            }
            pane.submit(frame)
        }
        // No main-actor task can have prepared resources before this assertion.
        XCTAssertEqual(budget.metrics.activeLeases, 1)
        XCTAssertEqual(budget.metrics.reservedBytes, cost)
        XCTAssertTrue(panes.allSatisfy { $0.cacheMetrics.retainedTextureBytes == 0 })

        for index in panes.indices {
            try await waitUntil { gate.entries == index + 1 && gate.waiting == 1
                && budget.metrics.waitingLeases == panes.count - index - 1 }
            XCTAssertEqual(rendered, index + 1, "Only the admitted pane may reach GPU completion")
            XCTAssertEqual(observed, index, "Presentation must remain gated after GPU completion")
            XCTAssertEqual(budget.metrics.activeLeases, 1)
            XCTAssertEqual(budget.metrics.reservedBytes, panes.reduce(0) { $0 + $1.cacheMetrics.retainedTextureBytes })
            XCTAssertGreaterThan(budget.metrics.reservedBytes, 0)
            XCTAssertLessThan(budget.metrics.reservedBytes, cost)
            XCTAssertEqual(panes.filter { $0.cacheMetrics.retainedTextureBytes > 0 }.count, 1,
                           "Queued panes must not allocate uncharged raster storage")
            gate.releaseNext()
        }
        try await waitUntil { panes.allSatisfy(\.isIdle) }
        XCTAssertEqual(observed, panes.count)
        XCTAssertTrue(panes.allSatisfy { $0.completedFrames == 1 && $0.failedFrames == 0 })
        XCTAssertEqual(budget.metrics.peakReservedBytes, cost)
        XCTAssertEqual(budget.metrics.peakActiveLeases, 1)
        assertDrained(budget)
    }

    func testFIFOHeadCancellationAdmitsFittingTailWithoutReleasingOtherPermit() async throws {
        let budget = VTMetalPreparationBudget(limitBytes: 10)
        let first = try XCTUnwrap(budget.tryAcquire(bytes: 6))
        defer { budget.release(first) }
        var headResult: Result<VTMetalPreparationBudget.Permit, any Error>?
        var tailResult: Result<VTMetalPreparationBudget.Permit, any Error>?
        let head = Task { @MainActor in
            do { headResult = .success(try await budget.acquire(bytes: 8)) }
            catch { headResult = .failure(error) }
        }
        defer {
            head.cancel()
            if case .success(let permit)? = headResult { budget.release(permit) }
        }
        try await waitUntil { budget.metrics.waitingLeases == 1 }
        let tail = Task { @MainActor in
            do { tailResult = .success(try await budget.acquire(bytes: 4)) }
            catch { tailResult = .failure(error) }
        }
        defer {
            tail.cancel()
            if case .success(let permit)? = tailResult { budget.release(permit) }
        }
        try await waitUntil { budget.metrics.waitingLeases == 2 }
        XCTAssertEqual(budget.metrics.reservedBytes, 6)
        XCTAssertNil(budget.tryAcquire(bytes: 1), "New small requests cannot bypass the head")
        head.cancel()
        try await waitUntil { headResult != nil && tailResult != nil }
        switch try XCTUnwrap(headResult) {
        case .success: XCTFail("Cancelled head was admitted")
        case .failure(let error): XCTAssertTrue(error is CancellationError)
        }
        let second = try XCTUnwrap(tailResult).get()
        XCTAssertEqual(budget.metrics.reservedBytes, 10)
        XCTAssertEqual(budget.metrics.activeLeases, 2)
        XCTAssertEqual(budget.metrics.waitingLeases, 0)
        budget.release(first)
        budget.release(first)
        XCTAssertEqual(budget.metrics.reservedBytes, 4, "Duplicate release must not free another permit")
        budget.release(second)
        assertDrained(budget)
    }

    func testReductionIsInPlaceAndRejectsDuplicateIncreasingReleasedAndForeignTokens() throws {
        let budget = VTMetalPreparationBudget(limitBytes: 10)
        let first = try XCTUnwrap(budget.tryAcquire(bytes: 8))
        let other = try XCTUnwrap(budget.tryAcquire(bytes: 2))
        defer { budget.release(first); budget.release(other) }
        let originalToken = first
        budget.reduce(first, to: 4)
        XCTAssertEqual(first.bytes, 8, "Permit bytes remain original admission metadata")
        XCTAssertEqual(budget.metrics.reservedBytes, 6)
        XCTAssertEqual(budget.metrics.activeLeases, 2)
        budget.reduce(first, to: 4)
        budget.reduce(originalToken, to: 7)
        budget.reduce(first, to: 9)
        budget.reduce(first, to: -1)
        XCTAssertEqual(budget.metrics.reservedBytes, 6, "Old metadata cannot restore or increase the live balance")
        let foreign = VTMetalPreparationBudget(limitBytes: 10)
        foreign.reduce(first, to: 0)
        assertDrained(foreign)
        XCTAssertEqual(budget.metrics.reservedBytes, 6)
        budget.reduce(first, to: 0)
        XCTAssertEqual(budget.metrics.activeLeases, 2, "Even zero bytes retain the resource lease")
        XCTAssertEqual(budget.metrics.reservedBytes, other.bytes)
        budget.release(first)
        let successor = try XCTUnwrap(budget.tryAcquire(bytes: 3))
        defer { budget.release(successor) }
        budget.reduce(originalToken, to: 0)
        budget.reduce(originalToken, to: 8)
        budget.release(originalToken)
        XCTAssertEqual(budget.metrics.reservedBytes, other.bytes + successor.bytes)
        XCTAssertEqual(budget.metrics.activeLeases, 2, "Released tokens cannot affect another owner")
        XCTAssertEqual(budget.metrics.peakReservedBytes, 10)
        budget.release(other)
        budget.release(successor)
        assertDrained(budget)
    }

    func testReductionPreservesFIFOHeadUntilCancellationAdmitsFittingTail() async throws {
        let budget = VTMetalPreparationBudget(limitBytes: 10)
        let first = try XCTUnwrap(budget.tryAcquire(bytes: 8))
        defer { budget.release(first) }
        var headResult: Result<VTMetalPreparationBudget.Permit, any Error>?
        var tailResult: Result<VTMetalPreparationBudget.Permit, any Error>?
        let head = Task { @MainActor in
            do { headResult = .success(try await budget.acquire(bytes: 7)) }
            catch { headResult = .failure(error) }
        }
        defer {
            head.cancel()
            if case .success(let permit)? = headResult { budget.release(permit) }
        }
        try await waitUntil { budget.metrics.waitingLeases == 1 }
        let tail = Task { @MainActor in
            do { tailResult = .success(try await budget.acquire(bytes: 4)) }
            catch { tailResult = .failure(error) }
        }
        defer {
            tail.cancel()
            if case .success(let permit)? = tailResult { budget.release(permit) }
        }
        try await waitUntil { budget.metrics.waitingLeases == 2 }
        budget.reduce(first, to: 5)
        XCTAssertEqual(budget.metrics.reservedBytes, 5)
        XCTAssertEqual(budget.metrics.activeLeases, 1)
        XCTAssertEqual(budget.metrics.waitingLeases, 2, "A fitting tail still cannot bypass its head")
        XCTAssertNil(budget.tryAcquire(bytes: 1))
        head.cancel()
        try await waitUntil { headResult != nil && tailResult != nil }
        switch try XCTUnwrap(headResult) {
        case .success: XCTFail("Cancelled head was admitted")
        case .failure(let error): XCTAssertTrue(error is CancellationError)
        }
        let admitted = try XCTUnwrap(tailResult).get()
        XCTAssertEqual(budget.metrics.reservedBytes, 9)
        XCTAssertEqual(budget.metrics.activeLeases, 2)
        XCTAssertEqual(budget.metrics.waitingLeases, 0)
        budget.release(admitted)
        XCTAssertEqual(budget.metrics.reservedBytes, 5, "Tail cleanup cannot release the reduced owner")
        budget.release(first)
        assertDrained(budget)
    }

    func testCancellationAfterReductionGrantBeforeResumptionDoesNotLeak() async throws {
        let frame = try await makeFrame()
        let cost = try VTMetalRasterizer().preparationBytes(for: frame)
        let budget = VTMetalPreparationBudget(limitBytes: cost)
        let blocker = try XCTUnwrap(budget.tryAcquire(bytes: cost))
        defer { budget.release(blocker) }
        let pane = try VTMetalFramePipeline(font: font, preparationBudget: budget)
        defer { pane.retire() }
        pane.submit(frame)
        try await waitUntil { budget.metrics.waitingLeases == 1 }
        // Reduction grants the head synchronously, before its task can resume.
        budget.reduce(blocker, to: 0)
        XCTAssertEqual(budget.metrics.activeLeases, 2)
        XCTAssertEqual(budget.metrics.waitingLeases, 0)
        XCTAssertEqual(budget.metrics.reservedBytes, cost)
        pane.retire()
        try await waitUntil { pane.isIdle }
        XCTAssertEqual(budget.metrics.activeLeases, 1, "Cancellation preserves the reduced unrelated owner")
        XCTAssertEqual(budget.metrics.reservedBytes, 0)
        XCTAssertEqual(pane.cacheMetrics.retainedTextureBytes, 0)
        XCTAssertEqual(pane.completedFrames, 0)
        XCTAssertEqual(pane.staleFrames, 1)
        XCTAssertEqual(pane.failedFrames, 0)
        budget.release(blocker)
        assertDrained(budget)
    }

    func testCancellationAfterQueuedGrantBeforeResumptionDoesNotLeak() async throws {
        let frame = try await makeFrame()
        let cost = try VTMetalRasterizer().preparationBytes(for: frame)
        let budget = VTMetalPreparationBudget(limitBytes: cost)
        let blocker = try XCTUnwrap(budget.tryAcquire(bytes: cost))
        defer { budget.release(blocker) }
        let pane = try VTMetalFramePipeline(font: font, preparationBudget: budget)
        defer { pane.retire() }
        pane.submit(frame)
        try await waitUntil { budget.metrics.waitingLeases == 1 }
        // No await between granting the queued permit and cancellation: the
        // waiter cannot resume on the main actor until after retirement.
        budget.release(blocker)
        XCTAssertEqual(budget.metrics.activeLeases, 1)
        XCTAssertEqual(budget.metrics.waitingLeases, 0)
        pane.retire()
        try await waitUntil { pane.isIdle }
        assertDrained(budget)
        XCTAssertEqual(pane.cacheMetrics.retainedTextureBytes, 0)
        XCTAssertEqual(pane.completedFrames, 0)
        XCTAssertEqual(pane.staleFrames, 1)
        XCTAssertEqual(pane.failedFrames, 0)
    }

    func testEpochCancelsWaitingWorkWithoutReleasingOtherPermit() async throws {
        try await checkWaitingCancellation(suspend: false)
    }

    func testSuspensionCancelsWaitingWorkWithoutReleasingOtherPermit() async throws {
        try await checkWaitingCancellation(suspend: true)
    }

    func testOversizedRequestRunsAloneWithoutBeingBypassed() async throws {
        let budget = VTMetalPreparationBudget(limitBytes: 10)
        let first = try XCTUnwrap(budget.tryAcquire(bytes: 4))
        defer { budget.release(first) }
        var oversizedResult: Result<VTMetalPreparationBudget.Permit, any Error>?
        var tailResult: Result<VTMetalPreparationBudget.Permit, any Error>?
        let oversized = Task { @MainActor in
            do { oversizedResult = .success(try await budget.acquire(bytes: 20)) }
            catch { oversizedResult = .failure(error) }
        }
        defer {
            oversized.cancel()
            if case .success(let permit)? = oversizedResult { budget.release(permit) }
        }
        try await waitUntil { budget.metrics.waitingLeases == 1 }
        let tail = Task { @MainActor in
            do { tailResult = .success(try await budget.acquire(bytes: 1)) }
            catch { tailResult = .failure(error) }
        }
        defer {
            tail.cancel()
            if case .success(let permit)? = tailResult { budget.release(permit) }
        }
        try await waitUntil { budget.metrics.waitingLeases == 2 }
        XCTAssertNil(budget.tryAcquire(bytes: 1))
        budget.release(first)
        try await waitUntil { oversizedResult != nil }
        let exclusive = try XCTUnwrap(oversizedResult).get()
        XCTAssertEqual(budget.metrics.activeLeases, 1)
        XCTAssertEqual(budget.metrics.reservedBytes, 20)
        XCTAssertEqual(budget.metrics.waitingLeases, 1)
        XCTAssertEqual(budget.metrics.oversizedAdmissions, 1)
        XCTAssertNil(tailResult)
        XCTAssertNil(budget.tryAcquire(bytes: 1), "Oversized admission must remain exclusive")
        budget.reduce(exclusive, to: 1)
        budget.reduce(exclusive, to: 0)
        XCTAssertEqual(budget.metrics.reservedBytes, 20, "Originally oversized permits never shrink")
        XCTAssertEqual(budget.metrics.activeLeases, 1)
        XCTAssertEqual(budget.metrics.waitingLeases, 1)
        XCTAssertNil(tailResult)
        XCTAssertNil(budget.tryAcquire(bytes: 1), "Reduction cannot let a smaller request bypass exclusivity")
        budget.release(exclusive)
        try await waitUntil { tailResult != nil }
        let last = try XCTUnwrap(tailResult).get()
        XCTAssertEqual(budget.metrics.reservedBytes, 1)
        budget.release(last)
        XCTAssertEqual(budget.metrics.peakReservedBytes, 20)
        XCTAssertEqual(budget.metrics.peakActiveLeases, 1)
        assertDrained(budget)
    }

    private func checkWaitingCancellation(suspend: Bool) async throws {
        let frame = try await makeFrame()
        let cost = try VTMetalRasterizer().preparationBytes(for: frame)
        let budget = VTMetalPreparationBudget(limitBytes: cost)
        let blocker = try XCTUnwrap(budget.tryAcquire(bytes: cost))
        defer { budget.release(blocker) }
        let pane = try VTMetalFramePipeline(font: font, preparationBudget: budget)
        defer { pane.retire() }
        var observations = 0
        pane.onObservation = { _ in observations += 1 }
        pane.submit(frame)
        var alternatePresentation = VTPresentationState()
        alternatePresentation.blinkVisible = false
        pane.submit(frame, presentation: alternatePresentation)
        pane.submit(frame)
        try await waitUntil { budget.metrics.waitingLeases == 2 }
        XCTAssertEqual(pane.inFlightCount, 2)
        XCTAssertEqual(pane.pendingCount, 1)
        XCTAssertEqual(pane.cacheMetrics.retainedTextureBytes, 0)
        if suspend { pane.setActive(false) } else { pane.beginEpoch() }
        try await waitUntil { pane.isIdle }
        XCTAssertEqual(budget.metrics.waitingLeases, 0)
        XCTAssertEqual(budget.metrics.activeLeases, 1)
        XCTAssertEqual(budget.metrics.reservedBytes, cost, "Cancellation must preserve the unrelated permit")
        XCTAssertEqual(pane.pendingCount, 0)
        XCTAssertEqual(pane.staleFrames, 2)
        XCTAssertEqual(pane.failedFrames, 0)
        XCTAssertEqual(pane.completedFrames, 0)
        XCTAssertEqual(observations, 0)
        XCTAssertEqual(pane.cacheMetrics.retainedTextureBytes, 0)
        budget.release(blocker)
        assertDrained(budget)
        if suspend { pane.setActive(true) }
        pane.submit(frame)
        try await waitUntil { pane.isIdle }
        XCTAssertEqual(pane.completedFrames, 1, "Fresh work must remain usable after invalidation")
        XCTAssertEqual(pane.failedFrames, 0)
        XCTAssertEqual(observations, 1)
        assertDrained(budget)
    }

    private func makeFrame() async throws -> VTFrameValue {
        let layout = try VTLayout(generation: 1, width: 200, height: 120,
                                  cellWidth: 10, cellHeight: 20, scale: 2, padding: 0)
        let terminal = try VTTerminal(layout: layout)
        do {
            _ = try await terminal.ingest(Data("budget regression\r\nsmall native frame".utf8))
            let frame = try await terminal.snapshot()
            _ = try await terminal.retire()
            return frame
        } catch {
            _ = try? await terminal.retire()
            throw error
        }
    }
}
