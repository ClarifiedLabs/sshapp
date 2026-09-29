import Metal
import UIKit
import XCTest
@testable import GhosttyVT

/// Real native snapshots and isolated policy budgets: no RSS or timing assertions.
@MainActor
final class VTMetalGlyphRetentionTests: XCTestCase {
    private let font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    private struct WarmPane {
        let frame: VTFrameValue
        let pane: VTMetalFramePipeline
        let preparation: VTMetalPreparationBudget
        let idle: VTMetalIdleCacheBudget
        let coldBytes: Int
    }

    func testDeniedWarmSlotKeepsGlyphsButSynchronouslyDropsImagesOutputAndTile() async throws {
        // 65 tiny native images exceed the texture-count cap, not a memory quota.
        let warm = try await makeWarmPane(imageCount: VTMetalImagePlan.cacheCountLimit + 1)
        let before = warm.pane.cacheMetrics
        XCTAssertEqual(before.imagesBySlot.reduce(0, +), VTMetalImagePlan.cacheCountLimit)
        XCTAssertEqual(before.imageTileTextures, 1)
        XCTAssertEqual(before.outputTextures, 1)
        let blocker = try XCTUnwrap(warm.preparation.tryAcquire(bytes: warm.coldBytes))
        defer { warm.pane.retire(); warm.preparation.release(blocker) }

        warm.pane.beginEpoch()
        warm.pane.submit(warm.frame)
        // No task suspension: denial must replace ownership synchronously.
        let waiting = warm.pane.cacheMetrics
        XCTAssertEqual(waiting.glyphsBySlot, before.glyphsBySlot)
        XCTAssertEqual(waiting.shapedGlyphsBySlot, before.shapedGlyphsBySlot)
        XCTAssertEqual(waiting.glyphCacheIdentitiesBySlot, before.glyphCacheIdentitiesBySlot)
        XCTAssertEqual(waiting.shapingMissesBySlot, before.shapingMissesBySlot)
        XCTAssertEqual(waiting.atlasTextures, 1)
        assertNoTransients(waiting)
        XCTAssertGreaterThan(waiting.retainedTextureBytes, 0)
        XCTAssertLessThan(waiting.retainedTextureBytes, before.retainedTextureBytes)
        XCTAssertEqual(warm.idle.metrics.retainedBytes, waiting.retainedTextureBytes)
        XCTAssertEqual(warm.idle.metrics.slots, 1)
        XCTAssertEqual(warm.preparation.metrics.reservedBytes, blocker.bytes)
        try await waitUntil(timeout: 10) { warm.preparation.metrics.waitingLeases == 1 }
        XCTAssertEqual(warm.pane.completedFrames, 1, "Waiting must not render or shape a new frame")

        warm.preparation.release(blocker)
        try await waitUntil(timeout: 10) { warm.pane.isIdle }
        XCTAssertEqual(warm.pane.completedFrames, 2)
        XCTAssertEqual(warm.pane.failedFrames, 0)
        XCTAssertEqual(warm.pane.cacheMetrics.glyphsBySlot, before.glyphsBySlot)
        XCTAssertEqual(warm.pane.cacheMetrics.shapedGlyphsBySlot, before.shapedGlyphsBySlot)
        XCTAssertEqual(warm.pane.cacheMetrics.glyphCacheIdentitiesBySlot, before.glyphCacheIdentitiesBySlot)
        XCTAssertEqual(warm.pane.cacheMetrics.shapingMissesBySlot, before.shapingMissesBySlot,
                       "Warm handoff must reuse shaped lines, not rebuild equal cache counts")
        XCTAssertEqual(warm.pane.cacheMetrics.imageTileTextures, 1)
        assertDrained(warm.preparation)
    }

    func testLoweringIdleLimitEvictsWaitingGlyphsAndAdmissionReconstructsCold() async throws {
        let warm = try await makeWarmPane()
        let before = warm.pane.cacheMetrics
        let blocker = try XCTUnwrap(warm.preparation.tryAcquire(bytes: warm.coldBytes))
        let gate = PresentationGate()
        defer { warm.pane.retire(); gate.open(); warm.preparation.release(blocker) }
        warm.pane.publicationHoldForTesting = { await gate.wait() }
        warm.pane.beginEpoch()
        warm.pane.submit(warm.frame)
        try await waitUntil(timeout: 10) { warm.preparation.metrics.waitingLeases == 1 }
        XCTAssertGreaterThan(warm.idle.metrics.retainedBytes, 0)

        warm.idle.limitBytes = 0
        assertEmpty(warm.pane.cacheMetrics)
        XCTAssertEqual(warm.idle.metrics.retainedBytes, 0)
        XCTAssertEqual(warm.idle.metrics.slots, 0)
        XCTAssertEqual(warm.idle.metrics.evictions, 1)
        XCTAssertEqual(warm.preparation.metrics.waitingLeases, 1)
        warm.preparation.release(blocker)
        XCTAssertEqual(warm.preparation.metrics.reservedBytes, warm.coldBytes,
                       "The grant covers cold reconstruction before the waiter resumes")
        try await waitUntil(timeout: 10) { gate.waiting == 1 }
        XCTAssertEqual(warm.preparation.metrics.activeLeases, 1)
        XCTAssertEqual(warm.preparation.metrics.reservedBytes, warm.pane.cacheMetrics.retainedTextureBytes,
                       "After GPU drain, all reconstructed textures remain charged")
        XCTAssertLessThan(warm.preparation.metrics.reservedBytes, warm.coldBytes)
        XCTAssertEqual(warm.pane.cacheMetrics.glyphsBySlot, before.glyphsBySlot)
        XCTAssertEqual(warm.pane.cacheMetrics.shapedGlyphsBySlot, before.shapedGlyphsBySlot)
        XCTAssertEqual(warm.pane.cacheMetrics.outputTextures, 1)
        XCTAssertNotNil(warm.pane.cacheMetrics.glyphCacheIdentitiesBySlot[0])
        XCTAssertNotEqual(warm.pane.cacheMetrics.glyphCacheIdentitiesBySlot[0], before.glyphCacheIdentitiesBySlot[0])
        XCTAssertGreaterThan(warm.pane.cacheMetrics.shapingMissesBySlot[0], 0)
        XCTAssertEqual(warm.pane.cacheMetrics.imagesBySlot, before.imagesBySlot)
        XCTAssertEqual(warm.idle.metrics.retainedBytes, 0, "Admitted storage belongs to preparation")
        gate.open()
        try await waitUntil(timeout: 10) { warm.pane.isIdle }
        XCTAssertEqual(warm.pane.completedFrames, 2)
        XCTAssertEqual(warm.pane.failedFrames, 0)
        assertEmpty(warm.pane.cacheMetrics)
        assertDrained(warm.preparation)
    }

    func testSuspendingWaitingWarmSlotDestroysCacheWithoutReleasingUnrelatedPermit() async throws {
        let warm = try await makeWarmPane()
        let blocker = try XCTUnwrap(warm.preparation.tryAcquire(bytes: warm.coldBytes))
        defer { warm.pane.retire(); warm.preparation.release(blocker) }
        warm.pane.beginEpoch()
        warm.pane.submit(warm.frame)
        try await waitUntil(timeout: 10) { warm.preparation.metrics.waitingLeases == 1 }
        XCTAssertGreaterThan(warm.idle.metrics.retainedBytes, 0)

        warm.pane.setActive(false)
        try await waitUntil(timeout: 10) { warm.pane.isIdle }
        assertEmpty(warm.pane.cacheMetrics)
        XCTAssertEqual(warm.idle.metrics.retainedBytes, 0)
        XCTAssertEqual(warm.idle.metrics.slots, 0)
        XCTAssertEqual(warm.preparation.metrics.waitingLeases, 0)
        XCTAssertEqual(warm.preparation.metrics.activeLeases, 1)
        XCTAssertEqual(warm.preparation.metrics.reservedBytes, blocker.bytes)
        XCTAssertEqual(warm.pane.completedFrames, 1)
        XCTAssertEqual(warm.pane.failedFrames, 0)
        warm.preparation.release(blocker)
        assertDrained(warm.preparation)
    }

    func testRetirementAfterWaitingWarmSlotIsGrantedBeforeResumptionDestroysHandoff() async throws {
        let warm = try await makeWarmPane()
        let blocker = try XCTUnwrap(warm.preparation.tryAcquire(bytes: warm.coldBytes))
        defer { warm.pane.retire(); warm.preparation.release(blocker) }
        warm.pane.beginEpoch()
        warm.pane.submit(warm.frame)
        try await waitUntil(timeout: 10) { warm.preparation.metrics.waitingLeases == 1 }
        XCTAssertGreaterThan(warm.idle.metrics.retainedBytes, 0)

        // Grant and cancellation share one main-actor turn; rendering cannot resume.
        warm.preparation.release(blocker)
        XCTAssertEqual(warm.preparation.metrics.activeLeases, 1)
        XCTAssertEqual(warm.preparation.metrics.waitingLeases, 0)
        warm.pane.retire()
        try await waitUntil(timeout: 10) { warm.pane.isIdle }
        assertEmpty(warm.pane.cacheMetrics)
        XCTAssertEqual(warm.idle.metrics.retainedBytes, 0)
        XCTAssertEqual(warm.idle.metrics.slots, 0)
        XCTAssertEqual(warm.pane.completedFrames, 1)
        XCTAssertEqual(warm.pane.failedFrames, 0)
        assertDrained(warm.preparation)
    }

    func testTrimWaitingWarmSlotPurgesImmediatelyWithoutCancelingItsColdReservation() async throws {
        let warm = try await makeWarmPane()
        let blocker = try XCTUnwrap(warm.preparation.tryAcquire(bytes: warm.coldBytes))
        defer { warm.pane.retire(); warm.preparation.release(blocker) }
        warm.pane.beginEpoch()
        warm.pane.submit(warm.frame)
        try await waitUntil(timeout: 10) { warm.preparation.metrics.waitingLeases == 1 }
        XCTAssertGreaterThan(warm.idle.metrics.retainedBytes, 0)

        warm.pane.trimResources()
        assertEmpty(warm.pane.cacheMetrics)
        XCTAssertEqual(warm.idle.metrics.retainedBytes, 0)
        XCTAssertEqual(warm.idle.metrics.slots, 0)
        XCTAssertEqual(warm.preparation.metrics.waitingLeases, 1)
        XCTAssertEqual(warm.preparation.metrics.reservedBytes, blocker.bytes)
        warm.preparation.release(blocker)
        try await waitUntil(timeout: 10) { warm.pane.isIdle }
        XCTAssertEqual(warm.pane.completedFrames, 2)
        XCTAssertEqual(warm.pane.failedFrames, 0)
        assertDrained(warm.preparation)
    }

    func testTrimAndIdlePressureCannotReleasePresentationHeldResources() async throws {
        // Warm image refresh planning can exceed the cold estimate slightly;
        // use a non-oversized isolated admission to exercise actual reduction.
        let warm = try await makeWarmPane(preparationLimitMultiplier: 2)
        let gate = PresentationGate()
        defer { warm.pane.retire(); gate.open() }
        warm.pane.publicationHoldForTesting = { await gate.wait() }
        warm.pane.beginEpoch()
        warm.pane.submit(warm.frame)
        try await waitUntil(timeout: 10) { gate.waiting == 1 }
        let held = warm.pane.cacheMetrics
        let reserved = warm.preparation.metrics.reservedBytes
        XCTAssertEqual(reserved, held.retainedTextureBytes)
        XCTAssertLessThan(reserved, warm.coldBytes)
        XCTAssertEqual(held.outputTextures, 1)
        XCTAssertGreaterThan(held.retainedTextureBytes, 0)
        XCTAssertEqual(warm.idle.metrics.retainedBytes, 0)

        warm.pane.trimResources()
        warm.idle.limitBytes = 0
        XCTAssertEqual(warm.pane.cacheMetrics.retainedTextureBytes, held.retainedTextureBytes)
        XCTAssertEqual(warm.pane.cacheMetrics.glyphsBySlot, held.glyphsBySlot)
        XCTAssertEqual(warm.pane.cacheMetrics.glyphCacheIdentitiesBySlot, held.glyphCacheIdentitiesBySlot)
        XCTAssertEqual(warm.pane.cacheMetrics.imagesBySlot, held.imagesBySlot)
        XCTAssertEqual(warm.pane.cacheMetrics.outputTextures, held.outputTextures)
        XCTAssertEqual(warm.preparation.metrics.activeLeases, 1)
        XCTAssertEqual(warm.preparation.metrics.reservedBytes, reserved)
        XCTAssertEqual(warm.pane.inFlightCount, 1)
        gate.open()
        try await waitUntil(timeout: 10) { warm.pane.isIdle }
        assertEmpty(warm.pane.cacheMetrics)
        assertDrained(warm.preparation)
    }

    func testReductionAdmitsFittingWaiterWhilePresentationHoldsEveryTextureKindProtected() async throws {
        let frame = try await makeFrame(imageCount: VTMetalImagePlan.cacheCountLimit + 1)
        let coldBytes = try VTMetalRasterizer().preparationBytes(for: frame)
        let preparation = VTMetalPreparationBudget(limitBytes: coldBytes * 2 - 1)
        let idle = VTMetalIdleCacheBudget(limitBytes: coldBytes * 2)
        let panes = try (0..<2).map { _ in
            try VTMetalFramePipeline(font: font, idleCacheBudget: idle, preparationBudget: preparation)
        }
        let gate = PresentationGate()
        let blocker = try XCTUnwrap(preparation.tryAcquire(bytes: preparation.limitBytes))
        defer {
            panes.forEach { $0.retire() }
            gate.open()
            preparation.release(blocker)
        }
        for pane in panes {
            pane.publicationHoldForTesting = { await gate.wait() }
            pane.submit(frame)
        }
        try await waitUntil(timeout: 10) { preparation.metrics.waitingLeases == 2 }
        preparation.release(blocker)
        XCTAssertEqual(preparation.metrics.activeLeases, 1)
        XCTAssertEqual(preparation.metrics.waitingLeases, 1)
        XCTAssertEqual(preparation.metrics.reservedBytes, coldBytes)
        // No presentation is released: only the post-GPU reduction can grant the tail.
        try await waitUntil(timeout: 10) { gate.waiting == 2 }
        let held = panes.map(\.cacheMetrics)
        let heldBytes = held.reduce(0) { $0 + $1.retainedTextureBytes }
        XCTAssertEqual(preparation.metrics.activeLeases, 2)
        XCTAssertEqual(preparation.metrics.waitingLeases, 0)
        XCTAssertEqual(preparation.metrics.reservedBytes, heldBytes)
        XCTAssertLessThan(heldBytes, coldBytes * 2)
        XCTAssertEqual(idle.metrics.retainedBytes, 0)
        for metrics in held {
            XCTAssertEqual(metrics.atlasTextures, 1)
            XCTAssertEqual(metrics.outputTextures, 1)
            XCTAssertEqual(metrics.imageTileTextures, 1)
            XCTAssertEqual(metrics.imagesBySlot.reduce(0, +), VTMetalImagePlan.cacheCountLimit)
            XCTAssertGreaterThan(metrics.imagePixelBytes, 0)
            XCTAssertGreaterThanOrEqual(metrics.retainedTextureBytes,
                                        metrics.atlasTextureBytes + metrics.outputTextureBytes + metrics.imageTextureBytes)
        }
        panes.forEach { $0.trimResources() }
        idle.limitBytes = 0
        panes.forEach { $0.retire() }
        for (pane, metrics) in zip(panes, held) {
            XCTAssertEqual(pane.inFlightCount, 1)
            XCTAssertEqual(pane.completedFrames, 0)
            XCTAssertEqual(pane.cacheMetrics.retainedTextureBytes, metrics.retainedTextureBytes)
            XCTAssertEqual(pane.cacheMetrics.glyphCacheIdentitiesBySlot, metrics.glyphCacheIdentitiesBySlot)
            XCTAssertEqual(pane.cacheMetrics.imagesBySlot, metrics.imagesBySlot)
            XCTAssertEqual(pane.cacheMetrics.imageTileTextures, metrics.imageTileTextures)
            XCTAssertEqual(pane.cacheMetrics.outputTextures, metrics.outputTextures)
        }
        XCTAssertEqual(preparation.metrics.reservedBytes, heldBytes)
        XCTAssertEqual(preparation.metrics.activeLeases, 2)
        gate.open()
        try await waitUntil(timeout: 10) { panes.allSatisfy(\.isIdle) }
        panes.forEach { assertEmpty($0.cacheMetrics); XCTAssertEqual($0.failedFrames, 0) }
        assertDrained(preparation)
    }

    func testReducedReservationPrecedesReentrantInvalidationWithoutReleasingHeldTextures() async throws {
        for invalidation in ["epoch", "suspend", "retire"] {
            let warm = try await makeWarmPane(preparationLimitMultiplier: 2)
            let gate = PresentationGate()
            defer {
                warm.pane.beforeRenderedPublicationForTesting = nil
                warm.pane.retire()
                gate.open()
            }
            var heldBytes = 0
            var rendered = 0
            var completed = 0
            warm.pane.publicationHoldForTesting = { await gate.wait() }
            warm.pane.onRendered = { _ in rendered += 1 }
            warm.pane.onComplete = { _ in completed += 1 }
            warm.pane.beforeRenderedPublicationForTesting = {
                heldBytes = warm.pane.cacheMetrics.retainedTextureBytes
                XCTAssertEqual(warm.preparation.metrics.reservedBytes, heldBytes, invalidation)
                XCTAssertLessThan(heldBytes, warm.coldBytes)
                XCTAssertEqual(warm.preparation.metrics.activeLeases, 1)
                switch invalidation {
                case "epoch": warm.pane.beginEpoch()
                case "suspend": warm.pane.setActive(false)
                default: warm.pane.retire()
                }
                warm.pane.trimResources()
                warm.idle.limitBytes = 0
                XCTAssertEqual(warm.pane.cacheMetrics.retainedTextureBytes, heldBytes)
                XCTAssertEqual(warm.preparation.metrics.reservedBytes, heldBytes)
            }
            warm.pane.beginEpoch()
            warm.pane.submit(warm.frame)
            try await waitUntil(timeout: 10) { gate.waiting == 1 }
            XCTAssertGreaterThan(heldBytes, 0)
            XCTAssertEqual(rendered, 0, "Reentrant invalidation must still suppress GPU publication")
            XCTAssertEqual(completed, 0)
            XCTAssertEqual(warm.pane.inFlightCount, 1)
            XCTAssertEqual(warm.preparation.metrics.activeLeases, 1)
            XCTAssertEqual(warm.preparation.metrics.reservedBytes, heldBytes)
            gate.open()
            try await waitUntil(timeout: 10) { warm.pane.isIdle }
            XCTAssertEqual(rendered, 0)
            XCTAssertEqual(completed, 0, "Obsolete presentation must remain unpublished")
            XCTAssertEqual(warm.pane.failedFrames, 0)
            assertEmpty(warm.pane.cacheMetrics)
            assertDrained(warm.preparation)
        }
    }

    func testAccountingFailureKeepsOriginalReservationUntilPresentationDrains() async throws {
        for reentrantRetirement in [false, true] {
            let frame = try await makeFrame(imageCount: VTMetalImagePlan.cacheCountLimit + 1)
            let coldBytes = try VTMetalRasterizer().preparationBytes(for: frame)
            let preparation = VTMetalPreparationBudget(limitBytes: coldBytes * 2 - 1)
            let idle = VTMetalIdleCacheBudget(limitBytes: 0)
            let pane = try VTMetalFramePipeline(font: font, idleCacheBudget: idle, preparationBudget: preparation)
            let gate = PresentationGate()
            let forcedRetainedBytes = coldBytes + 1
            var nextPermit: VTMetalPreparationBudget.Permit?
            var rendered = 0
            var completed = 0
            var observed = 0
            var publicationSeamCalls = 0
            var failures: [String] = []
            var failureObservations: [String] = []
            defer {
                pane.retire()
                gate.open()
                if let nextPermit { preparation.release(nextPermit) }
                pane.publicationHoldForTesting = nil
            }
            XCTAssertNil(pane.retainedTextureBytesOverrideForTesting)
            pane.retainedTextureBytesOverrideForTesting = forcedRetainedBytes
            pane.beforeRenderedPublicationForTesting = { publicationSeamCalls += 1 }
            pane.onRendered = { _ in rendered += 1 }
            pane.onComplete = { _ in completed += 1 }
            pane.onObservation = { _ in observed += 1 }
            pane.onFailure = { failures.append(String(describing: $0)) }
            pane.onFailureObservation = { revision, error in
                XCTAssertEqual(revision, frame.revision)
                failureObservations.append(String(describing: error))
            }
            pane.publicationHoldForTesting = {
                // This runs only after the real GPU render has returned. Trim and
                // retirement reenter the pipeline while its presentation is owned.
                XCTAssertEqual(pane.diagnostics.gpuCompletedFrames, 1)
                XCTAssertEqual(preparation.metrics.reservedBytes, coldBytes)
                let before = pane.cacheMetrics
                if reentrantRetirement {
                    pane.trimResources()
                    pane.retire()
                }
                XCTAssertEqual(pane.cacheMetrics.retainedTextureBytes, before.retainedTextureBytes)
                XCTAssertEqual(pane.cacheMetrics.glyphCacheIdentitiesBySlot, before.glyphCacheIdentitiesBySlot)
                XCTAssertEqual(pane.inFlightCount, 1)
                XCTAssertEqual(preparation.metrics.activeLeases, 1)
                XCTAssertEqual(preparation.metrics.reservedBytes, coldBytes)
                return await gate.wait()
            }
            pane.submit(frame)
            XCTAssertEqual(preparation.metrics.reservedBytes, coldBytes)
            try await waitUntil(timeout: 10) { gate.waiting == 1 }
            let held = pane.cacheMetrics
            XCTAssertEqual(held.atlasTextures, 1)
            XCTAssertEqual(held.outputTextures, 1)
            XCTAssertEqual(held.imageTileTextures, 1)
            XCTAssertEqual(held.imagesBySlot.reduce(0, +), VTMetalImagePlan.cacheCountLimit)
            XCTAssertGreaterThan(held.imagePixelBytes, 0)
            XCTAssertGreaterThan(held.retainedTextureBytes, 0)
            XCTAssertLessThan(held.retainedTextureBytes, coldBytes)
            // This waiter would fit after any reduction of the original permit,
            // but must remain blocked even though the GPU has actually finished.
            let next = Task { @MainActor in
                do {
                    nextPermit = try await preparation.acquire(bytes: coldBytes)
                    XCTAssertEqual(pane.failedFrames, 1)
                    XCTAssertTrue(pane.isIdle)
                    assertEmpty(pane.cacheMetrics)
                } catch is CancellationError {
                } catch { XCTFail("Unexpected admission failure: \(error)") }
            }
            defer { next.cancel() }
            try await waitUntil(timeout: 10) { preparation.metrics.waitingLeases == 1 }
            XCTAssertNil(nextPermit)
            XCTAssertEqual(preparation.metrics.activeLeases, 1)
            XCTAssertEqual(preparation.metrics.reservedBytes, coldBytes)
            XCTAssertEqual(pane.inFlightCount, 1)
            XCTAssertEqual(pane.cacheMetrics.retainedTextureBytes, held.retainedTextureBytes)
            XCTAssertEqual(pane.cacheMetrics.glyphCacheIdentitiesBySlot, held.glyphCacheIdentitiesBySlot)
            XCTAssertEqual(pane.cacheMetrics.imagesBySlot, held.imagesBySlot)
            XCTAssertEqual(pane.cacheMetrics.imageTileTextures, held.imageTileTextures)
            XCTAssertEqual(pane.cacheMetrics.outputTextures, held.outputTextures)
            XCTAssertEqual(idle.metrics.retainedBytes, 0)
            XCTAssertEqual(pane.resourceReleases, 0)
            XCTAssertEqual(rendered, 0)
            XCTAssertEqual(completed, 0)
            XCTAssertEqual(observed, 0)
            XCTAssertEqual(publicationSeamCalls, 0)
            XCTAssertEqual(pane.failedFrames, 0)
            XCTAssertNil(pane.diagnostics.lastFailure)
            XCTAssertTrue(failures.isEmpty)
            XCTAssertTrue(failureObservations.isEmpty)

            // The eventual error must preserve the original measured/reserved
            // values, not recompute or clamp them after presentation resumes.
            pane.retainedTextureBytesOverrideForTesting = nil
            gate.open()
            try await waitUntil(timeout: 10) { pane.isIdle && nextPermit != nil }
            XCTAssertEqual(pane.failedFrames, 1)
            XCTAssertEqual(pane.staleFrames, 0)
            XCTAssertEqual(pane.completedFrames, 0)
            XCTAssertEqual(rendered, 0)
            XCTAssertEqual(completed, 0)
            XCTAssertEqual(observed, 0)
            XCTAssertEqual(publicationSeamCalls, 0)
            XCTAssertEqual(failureObservations.count, 1)
            XCTAssertEqual(failures.count, reentrantRetirement ? 0 : 1)
            let failure = try XCTUnwrap(failureObservations.first)
            XCTAssertTrue(failure.contains("retainedTexturesExceedReservation"))
            XCTAssertTrue(failure.contains("retainedBytes: \(forcedRetainedBytes)"))
            XCTAssertTrue(failure.contains("reservedBytes: \(coldBytes)"))
            XCTAssertEqual(pane.diagnostics.lastFailure, failure)
            if !reentrantRetirement { XCTAssertEqual(failures, failureObservations) }
            assertEmpty(pane.cacheMetrics)
            XCTAssertEqual(idle.metrics.retainedBytes, 0)
            XCTAssertEqual(idle.metrics.slots, 0)
            preparation.release(try XCTUnwrap(nextPermit))
            nextPermit = nil
            assertDrained(preparation)
        }
    }

    func testRetiringTwoHeldSlotsReleasesOnlyFirstBeforeNextPermitOwnerResumes() async throws {
        let frame = try await makeFrame()
        let coldBytes = try VTMetalRasterizer().preparationBytes(for: frame)
        let preparation = VTMetalPreparationBudget(limitBytes: coldBytes * 2)
        let idle = VTMetalIdleCacheBudget(limitBytes: coldBytes * 2)
        let pane = try VTMetalFramePipeline(font: font, idleCacheBudget: idle, preparationBudget: preparation)
        let gate = PresentationGate()
        var nextPermit: VTMetalPreparationBudget.Permit?
        var blocker: VTMetalPreparationBudget.Permit?
        defer {
            pane.retire()
            gate.open()
            if let nextPermit { preparation.release(nextPermit) }
            if let blocker { preparation.release(blocker) }
        }
        pane.publicationHoldForTesting = { await gate.wait() }
        pane.submit(frame)
        try await waitUntil(timeout: 10) { gate.waiting == 1 }
        let firstHeldBytes = pane.cacheMetrics.retainedTextureBytes
        guard firstHeldBytes > 0 else { return XCTFail("First held slot must own charged textures") }
        var alternate = VTPresentationState()
        alternate.blinkVisible = false
        pane.submit(frame, presentation: alternate)
        try await waitUntil(timeout: 10) { gate.waiting == 2 }
        let held = pane.cacheMetrics
        XCTAssertTrue(held.glyphsBySlot.allSatisfy { $0 > 0 })
        XCTAssertEqual(held.outputTextures, 2)
        XCTAssertEqual(preparation.metrics.activeLeases, 2)
        XCTAssertEqual(preparation.metrics.reservedBytes, held.retainedTextureBytes)
        // Scratch is no longer held. Fill that free capacity with an unrelated
        // owner so only releasing the first slot can admit its fitting successor.
        let remainingBytes = preparation.limitBytes - held.retainedTextureBytes
        guard remainingBytes > 0 else { return XCTFail("GPU drain must have returned scratch capacity") }
        blocker = try XCTUnwrap(preparation.tryAcquire(bytes: remainingBytes))
        XCTAssertEqual(preparation.metrics.reservedBytes, preparation.limitBytes)
        let next = Task { @MainActor in
            do {
                nextPermit = try await preparation.acquire(bytes: firstHeldBytes)
                XCTAssertEqual(pane.cacheMetrics.glyphsBySlot[0], 0,
                               "Completed retired slot must be purged before its permit is reused")
                XCTAssertEqual(pane.cacheMetrics.glyphsBySlot[1], held.glyphsBySlot[1])
                XCTAssertEqual(pane.cacheMetrics.outputTextures, 1)
            } catch { XCTFail("Unexpected admission failure: \(error)") }
        }
        defer { next.cancel() }
        try await waitUntil(timeout: 10) { preparation.metrics.waitingLeases == 1 }
        pane.retire()
        XCTAssertEqual(pane.cacheMetrics.retainedTextureBytes, held.retainedTextureBytes)
        gate.releaseNext()
        try await waitUntil(timeout: 10) { pane.inFlightCount == 1 && nextPermit != nil }
        XCTAssertEqual(gate.waiting, 1)
        XCTAssertEqual(pane.cacheMetrics.glyphsBySlot[0], 0)
        XCTAssertEqual(pane.cacheMetrics.shapedGlyphsBySlot[0], 0)
        XCTAssertNil(pane.cacheMetrics.glyphCacheIdentitiesBySlot[0])
        XCTAssertEqual(pane.cacheMetrics.glyphCacheIdentitiesBySlot[1], held.glyphCacheIdentitiesBySlot[1])
        XCTAssertEqual(pane.cacheMetrics.glyphsBySlot[1], held.glyphsBySlot[1])
        XCTAssertEqual(pane.cacheMetrics.atlasTextures, 1)
        XCTAssertEqual(pane.cacheMetrics.outputTextures, 1)
        XCTAssertEqual(idle.metrics.retainedBytes, 0)
        XCTAssertEqual(preparation.metrics.activeLeases, 3,
                       "Other presentation, successor and unrelated blocker still own permits")
        XCTAssertEqual(preparation.metrics.reservedBytes, preparation.limitBytes)
        preparation.release(try XCTUnwrap(nextPermit))
        nextPermit = nil
        preparation.release(try XCTUnwrap(blocker))
        blocker = nil
        XCTAssertEqual(preparation.metrics.reservedBytes, pane.cacheMetrics.retainedTextureBytes)
        gate.open()
        try await waitUntil(timeout: 10) { pane.isIdle }
        assertEmpty(pane.cacheMetrics)
        assertDrained(preparation)
    }

    func testSelectiveDiscardRetainsGlyphsAndRebuildsIdenticalOutputPixels() async throws {
        let frame = try await makeFrame(imageCount: 1)
        let renderer = try VTMetalRasterizer()
        let idle = VTMetalIdleCacheBudget(limitBytes: 32 * 1024 * 1024)
        defer { idle.remove(renderer); renderer.releaseResources() }
        _ = try await renderer.render(frame, font: font)
        let pixels = try readPixels(renderer)
        let glyphs = renderer.cachedGlyphs
        let shapes = renderer.shapedGlyphs
        let uploads = renderer.imageUploadCount
        let identity = try XCTUnwrap(renderer.glyphCacheIdentity)
        let misses = renderer.shapingMisses
        XCTAssertGreaterThan(glyphs, 0)
        XCTAssertGreaterThan(shapes, 0)
        XCTAssertEqual(renderer.cachedImages, 1)

        renderer.discardTransientResources()
        idle.retainDrained(renderer)
        XCTAssertEqual(renderer.cachedGlyphs, glyphs)
        XCTAssertEqual(renderer.shapedGlyphs, shapes)
        XCTAssertEqual(renderer.glyphCacheIdentity, identity)
        XCTAssertEqual(renderer.shapingMisses, misses)
        XCTAssertTrue(renderer.hasAtlas)
        XCTAssertNil(renderer.output)
        XCTAssertEqual(renderer.outputTextureBytes, 0)
        XCTAssertEqual(renderer.cachedImages, 0)
        XCTAssertEqual(renderer.imageTextureBytes, 0)
        XCTAssertEqual(renderer.imagePixelBytes, 0)
        XCTAssertFalse(renderer.hasImageTile)
        XCTAssertEqual(idle.metrics.retainedBytes, renderer.retainedTextureBytes)
        XCTAssertGreaterThan(idle.metrics.retainedBytes, 0)
        idle.remove(renderer)
        _ = try await renderer.render(frame, font: font)
        XCTAssertEqual(try readPixels(renderer), pixels)
        XCTAssertEqual(renderer.cachedGlyphs, glyphs)
        XCTAssertEqual(renderer.shapedGlyphs, shapes)
        XCTAssertEqual(renderer.glyphCacheIdentity, identity)
        XCTAssertEqual(renderer.shapingMisses, misses, "Handoff must not recreate CoreText lines")
        XCTAssertEqual(renderer.imageUploadCount, uploads + 1, "Dropped image texture must be uploaded again")
    }

    func testHandoffStillInvalidatesFontScaleCellGeometryAndSmoothingAgainstColdRender() async throws {
        let original = try await makeFrame()
        let scaled = try await makeFrame(scale: 3)
        let geometry = try await makeFrame(cellWidth: 11, cellHeight: 22)
        let unsmoothed = try await makeFrame(fontSmoothing: false)
        let changedFont = UIFont.monospacedSystemFont(ofSize: 16, weight: .bold)
        let variants: [(String, VTFrameValue, UIFont)] = [
            ("font", original, changedFont), ("scale", scaled, font),
            ("cell geometry", geometry, font), ("smoothing", unsmoothed, font)
        ]
        for (name, frame, targetFont) in variants {
            let reused = try VTMetalRasterizer()
            let cold = try VTMetalRasterizer()
            defer { reused.releaseResources(); cold.releaseResources() }
            _ = try await reused.render(original, font: font)
            reused.discardTransientResources()
            XCTAssertGreaterThan(reused.cachedGlyphs, 0)
            _ = try await reused.render(frame, font: targetFont)
            _ = try await cold.render(frame, font: targetFont)
            XCTAssertEqual(try readPixels(reused), try readPixels(cold), "Invalidation mismatch: \(name)")
            XCTAssertEqual(reused.cachedGlyphs, cold.cachedGlyphs, name)
            XCTAssertEqual(reused.shapedGlyphs, cold.shapedGlyphs, name)
        }
    }

    /// Regression: a frame whose unique glyphs exceed the atlas cleared and
    /// re-rasterized its whole working set on every frame. The atlas now grows
    /// for the next frame, which is charged for it before allocation.
    func testAtlasGrowsWhenOneFrameOverflowsAClearedAtlas() async throws {
        // 120x240-pixel cells: about 32 glyphs fit a 1024 page, 128 fit 2048.
        let layout = try VTLayout(generation: 1, width: 800, height: 800,
                                  cellWidth: 40, cellHeight: 80, scale: 3, padding: 0)
        let terminal = try VTTerminal(layout: layout)
        let glyphs = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$%&*+?@"
        _ = try await terminal.ingest(Data(glyphs.utf8))
        let frame = try await terminal.snapshot()
        _ = try await terminal.retire()
        let renderer = try VTMetalRasterizer()
        defer { renderer.releaseResources() }
        let side = VTMetalRasterizer.initialAtlasSide
        let colorReserve = VTMetalRasterizer.initialColorAtlasSide * VTMetalRasterizer.initialColorAtlasSide * 4

        // The single-pass frame reserves the side its working set needs before
        // any allocation: one command buffer cannot stream a mid-frame clear.
        let reservation = renderer.preparationBytes(for: frame)
        XCTAssertGreaterThanOrEqual(reservation, (2 * side) * (2 * side) + colorReserve
            + VTMetalRasterizer.plannedScratchBytes,
            "The larger page is reserved before it is allocated")

        let first = try await renderer.render(frame, font: font)
        XCTAssertEqual(first.renderPasses, 1, "Growth precedes rasterization; no overflow submits")
        XCTAssertEqual(renderer.atlasBytes, (2 * side) * (2 * side), "1-byte coverage page; no color page without emoji")
        XCTAssertEqual(renderer.cachedGlyphs, glyphs.count)
        XCTAssertEqual(renderer.preparationBytes(for: frame),
                       renderer.retainedTextureBytes + colorReserve
                           + VTMetalRasterizer.plannedScratchBytes,
                       "Warm frames reserve only the absent color page's first allocation")

        _ = try await renderer.render(frame, font: font)
        XCTAssertEqual(renderer.cachedGlyphs, glyphs.count, "The whole working set stays cached")
        let warm = try await renderer.render(frame, font: font)
        XCTAssertEqual(warm.renderPasses, 1, "No overflow submits once the working set fits")
    }

    /// Regression: an overflow at the maximum page side never cleared the
    /// page, so every later frame with an uncached glyph fell back to CoreText.
    func testMaximumSizeAtlasClearsAfterOverflowAndRepopulates() async throws {
        // 450x900-pixel glyphs: 36 fit a 4096 page, and 20 already need it.
        let layout = try VTLayout(generation: 1, width: 1500, height: 600,
                                  cellWidth: 150, cellHeight: 300, scale: 3, padding: 0)
        let upper = try await makeFrame(layout: layout, text: "ABCDEFGHIJKLMNOPQRST")
        let lower = try await makeFrame(layout: layout, text: "abcdefghijklmnopqrst")
        let renderer = try VTMetalRasterizer()
        defer { renderer.releaseResources() }
        let side = VTMetalRasterizer.maximumAtlasSide

        _ = try await renderer.render(upper, font: font)
        XCTAssertEqual(renderer.atlasBytes, side * side)
        XCTAssertEqual(renderer.cachedGlyphs, 20)
        _ = try await renderer.render(lower, font: font)
        XCTAssertEqual(renderer.cachedGlyphs, 0, "A page that cannot grow clears after its overflow")
        XCTAssertEqual(renderer.atlasBytes, side * side)
        for _ in 0..<2 {
            _ = try await renderer.render(lower, font: font)
            XCTAssertEqual(renderer.cachedGlyphs, 20, "The next frame repopulates only its own working set")
        }
    }

    /// Regression: uncacheable oversized tiles took fresh page space every
    /// frame and their overflow never grew the page, so the pane fell back
    /// to CoreText for good.
    func testTransientTilesDoNotAccumulateAcrossFrames() async throws {
        // 1200x900-pixel cells exceed the 1020-pixel cacheable raster tile.
        let layout = try VTLayout(generation: 1, width: 800, height: 300,
                                  cellWidth: 400, cellHeight: 300, scale: 3, padding: 0)
        let frame = try await makeFrame(layout: layout, text: "WM")
        let renderer = try VTMetalRasterizer()
        defer { renderer.releaseResources() }
        let side = VTMetalRasterizer.initialAtlasSide

        _ = try await renderer.render(frame, font: font)
        XCTAssertEqual(renderer.atlasBytes, side * side, "The overflowing frame falls back before growth")
        for _ in 0..<5 {
            _ = try await renderer.render(frame, font: font)
            XCTAssertEqual(renderer.atlasBytes, (2 * side) * (2 * side),
                           "One frame's transient tiles fit; rewinding keeps later frames from growing")
            XCTAssertEqual(renderer.cachedGlyphs, 0)
        }
    }

    /// Regression: a region wider than the page wrapped to a fresh shelf and
    /// was written outside the texture instead of growing the page.
    func testGlyphWiderThanThePageGrowsItInsteadOfWrappingOutOfBounds() async throws {
        // A wide emoji rasterizes 600 pixels wide into the 512 color page.
        let layout = try VTLayout(generation: 1, width: 400, height: 100,
                                  cellWidth: 100, cellHeight: 100, scale: 3, padding: 0)
        let frame = try await makeFrame(layout: layout, text: "\u{1F600}")
        let renderer = try VTMetalRasterizer()
        defer { renderer.releaseResources() }
        _ = try await renderer.render(frame, font: font)
        _ = try await renderer.render(frame, font: font)
        XCTAssertEqual(renderer.cachedGlyphs, 1)
        let side = VTMetalRasterizer.initialAtlasSide
        let colorSide = 2 * VTMetalRasterizer.initialColorAtlasSide
        XCTAssertEqual(renderer.atlasBytes, side * side + colorSide * colorSide * 4)
    }

    /// Regression: a waiting slot reserved only its current glyph textures,
    /// but its surviving cache still grew at frame start, so the drained
    /// textures exceeded the permit and the pane fell back permanently.
    func testWaitingReservationCoversFrameStartAtlasGrowth() async throws {
        let layout = try VTLayout(generation: 1, width: 1500, height: 600,
                                  cellWidth: 150, cellHeight: 300, scale: 3, padding: 0)
        let small = try await makeFrame(layout: layout, text: "A")
        let large = try await makeFrame(layout: layout, text: "ABCDEFGHIJKLMNOPQRST")
        let renderer = try VTMetalRasterizer()
        defer { renderer.releaseResources() }
        _ = try await renderer.render(small, font: font)
        let side = VTMetalRasterizer.initialAtlasSide
        XCTAssertEqual(renderer.atlasBytes, side * side)

        // Pipeline order: reserve, then drop transients for the waiting slot.
        let waiting = renderer.preparationBytes(for: large, retainingCache: false, font: font)
        renderer.discardTransientResources()
        _ = try await renderer.render(large, font: font)
        let maximum = VTMetalRasterizer.maximumAtlasSide
        XCTAssertEqual(renderer.atlasBytes, maximum * maximum, "The surviving cache grew at frame start")
        XCTAssertLessThanOrEqual(renderer.retainedTextureBytes, waiting)
    }

    /// Regression: the instance buffer grew without bound while preparation
    /// covered only a fixed 65,536-instance scratch, so dense frames exceeded
    /// their permit and fell back permanently.
    func testDenseInstanceFrameStaysWithinItsReservation() async throws {
        // 12,000 curly-underlined 32-pixel cells: a quad per wave step.
        let layout = try VTLayout(generation: 1, width: 2560, height: 1800,
                                  cellWidth: 32, cellHeight: 12, scale: 1, padding: 0)
        let frame = try await makeFrame(layout: layout,
                                        text: "\u{1B}[4:3m" + String(repeating: "x", count: 80 * 150))
        let renderer = try VTMetalRasterizer()
        defer { renderer.releaseResources() }
        let cold = renderer.preparationBytes(for: frame, font: font)
        let waiting = renderer.preparationBytes(for: frame, retainingCache: false, font: font)
        _ = try await renderer.render(frame, font: font)
        XCTAssertGreaterThan(renderer.peakVertexBytes, 65_536 * 48 * 2,
                             "The frame exceeds the fixed instance scratch")
        XCTAssertLessThanOrEqual(renderer.retainedTextureBytes, cold)
        XCTAssertLessThanOrEqual(renderer.retainedTextureBytes, waiting)
        let warm = renderer.preparationBytes(for: frame, font: font)
        _ = try await renderer.render(frame, font: font)
        XCTAssertLessThanOrEqual(renderer.retainedTextureBytes, warm)
    }

    /// Regression: the atlas keyed glyphs by color, so the same glyph in many
    /// colors was rasterized and stored once per color.
    func testOneCoverageEntryServesEveryForegroundColor() async throws {
        let layout = try VTLayout(generation: 1, width: 400, height: 40, cellWidth: 10, cellHeight: 20,
                                  scale: 2, padding: 0)
        let terminal = try VTTerminal(layout: layout)
        let text = (0..<30).map { "\u{1B}[38;2;\($0 * 8);\(255 - $0 * 8);128mM" }.joined()
        _ = try await terminal.ingest(Data(("\u{1B}[?25l" + text).utf8))
        let frame = try await terminal.snapshot()
        _ = try await terminal.retire()
        let renderer = try VTMetalRasterizer()
        defer { renderer.releaseResources() }
        _ = try await renderer.render(frame, font: font)
        XCTAssertEqual(renderer.cachedGlyphs, 1, "30 colors of M share one coverage entry")
        XCTAssertEqual(renderer.shapedGlyphs, 1, "Shaping is color-free too")
    }

    /// Regression: retained image textures were charged again through the
    /// frame's image plan, so warm image panes reserved twice their pixels.
    func testWarmPreparationChargesRetainedImagesOnce() async throws {
        let frame = try await makeFrame(imageCount: 2)
        let renderer = try VTMetalRasterizer()
        defer { renderer.releaseResources() }
        let cold = renderer.preparationBytes(for: frame)
        _ = try await renderer.render(frame, font: font)
        XCTAssertEqual(renderer.cachedImages, 2)
        // Same frame and size: atlas, output and both images are all reused.
        // Atlas, output and both images are reused; only the absent color
        // page's first allocation stays reserved.
        XCTAssertEqual(renderer.preparationBytes(for: frame),
                       renderer.retainedTextureBytes + VTMetalRasterizer.plannedScratchBytes
                           + VTMetalRasterizer.initialColorAtlasSide * VTMetalRasterizer.initialColorAtlasSide * 4)
        XCTAssertEqual(renderer.preparationBytes(for: frame, retainingCache: false), cold)
    }

    func testFullReleasePurgesSelectiveHandoffAndAllowsColdPixelEquivalentRebuild() async throws {
        let frame = try await makeFrame()
        let renderer = try VTMetalRasterizer()
        defer { renderer.releaseResources() }
        _ = try await renderer.render(frame, font: font)
        let pixels = try readPixels(renderer)
        let oldIdentity = try XCTUnwrap(renderer.glyphCacheIdentity)
        let isOriginalCacheAlive = renderer.glyphCacheLifetimeProbeForTesting()
        XCTAssertTrue(isOriginalCacheAlive())
        renderer.discardTransientResources()
        XCTAssertTrue(isOriginalCacheAlive(), "Selective release must transfer the original bundle")
        XCTAssertEqual(renderer.glyphCacheIdentity, oldIdentity)
        XCTAssertGreaterThan(renderer.cachedGlyphs, 0)
        XCTAssertGreaterThan(renderer.shapedGlyphs, 0)
        XCTAssertTrue(renderer.hasAtlas)

        renderer.releaseResources()
        renderer.releaseResources()
        XCTAssertFalse(isOriginalCacheAlive(), "Full purge must drop both worker and snapshot ownership")
        XCTAssertEqual(renderer.cachedGlyphs, 0)
        XCTAssertEqual(renderer.shapedGlyphs, 0)
        XCTAssertFalse(renderer.hasAtlas)
        XCTAssertNil(renderer.output)
        XCTAssertEqual(renderer.retainedTextureBytes, 0)
        XCTAssertNil(renderer.glyphCacheIdentity)
        XCTAssertEqual(renderer.shapingMisses, 0)
        _ = try await renderer.render(frame, font: font)
        XCTAssertNotEqual(try XCTUnwrap(renderer.glyphCacheIdentity), oldIdentity)
        XCTAssertGreaterThan(renderer.shapingMisses, 0)
        XCTAssertGreaterThan(renderer.cachedGlyphs, 0)
        XCTAssertGreaterThan(renderer.shapedGlyphs, 0)
        XCTAssertEqual(try readPixels(renderer), pixels)
    }

    private func makeWarmPane(imageCount: Int = 1, preparationLimitMultiplier: Int = 1) async throws -> WarmPane {
        let frame = try await makeFrame(imageCount: imageCount)
        let coldBytes = try VTMetalRasterizer().preparationBytes(for: frame)
        let preparation = VTMetalPreparationBudget(limitBytes: coldBytes * preparationLimitMultiplier)
        let idle = VTMetalIdleCacheBudget(limitBytes: coldBytes * 2)
        let pane = try VTMetalFramePipeline(font: font, idleCacheBudget: idle, preparationBudget: preparation)
        pane.submit(frame)
        do { try await waitUntil(timeout: 10) { pane.isIdle } }
        catch { pane.retire(); throw error }
        XCTAssertEqual(pane.completedFrames, 1)
        XCTAssertEqual(pane.failedFrames, 0)
        XCTAssertGreaterThan(pane.cacheMetrics.glyphsBySlot[0], 0)
        XCTAssertGreaterThan(pane.cacheMetrics.shapedGlyphsBySlot[0], 0)
        XCTAssertEqual(idle.metrics.retainedBytes, pane.cacheMetrics.retainedTextureBytes)
        assertDrained(preparation)
        return WarmPane(frame: frame, pane: pane, preparation: preparation, idle: idle, coldBytes: coldBytes)
    }

    private func makeFrame(imageCount: Int = 0, scale: Double = 2,
                           cellWidth: Double = 10, cellHeight: Double = 20,
                           fontSmoothing: Bool = true) async throws -> VTFrameValue {
        let layout = try VTLayout(generation: 1, width: 200, height: 160,
                                  cellWidth: cellWidth, cellHeight: cellHeight, scale: scale, padding: 0)
        let imageBytes = max(16, imageCount * 16)
        let cache = VTImageSnapshotCache(limitBytes: imageBytes, limitImages: max(1, imageCount))
        let native = VTNativeImageBudget(limitBytes: imageBytes)
        let terminal = try VTTerminal(layout: layout, snapshotCache: cache, nativeImageBudget: native)
        do {
            var configuration = VTTerminalConfiguration()
            configuration.paint.fontSmoothing = fontSmoothing
            _ = try await terminal.configure(configuration)
            var input = Data()
            let pixels = Data((0..<4).flatMap { _ in [UInt8(64), 96, 128, 255] }).base64EncodedString()
            for image in 0..<imageCount {
                // Keep every distinct image visible at the same cell; C=1 does not advance the cursor.
                input.append(Data(("\u{1B}[1;1H\u{1B}_Ga=T,f=32,s=2,v=2,i=\(image + 1),p=1,c=2,r=2,C=1,q=2;"
                    + pixels + "\u{1B}\\").utf8))
            }
            input.append(Data("\u{1B}[4;1Hglyph retention\r\n\u{1B}[1;3mStyled ffi\u{1B}[0m\u{1B}[?25l".utf8))
            _ = try await terminal.ingest(input)
            let frame = try await terminal.snapshot()
            XCTAssertEqual(frame.graphics.placements.count, imageCount)
            _ = try await terminal.retire()
            XCTAssertEqual(native.metrics.reservedBytes, 0)
            return frame
        } catch {
            _ = try? await terminal.retire()
            throw error
        }
    }

    private func makeFrame(layout: VTLayout, text: String) async throws -> VTFrameValue {
        let terminal = try VTTerminal(layout: layout)
        do {
            _ = try await terminal.ingest(Data(("\u{1B}[?25l" + text).utf8))
            let frame = try await terminal.snapshot()
            _ = try await terminal.retire()
            return frame
        } catch {
            _ = try? await terminal.retire()
            throw error
        }
    }

    private func readPixels(_ renderer: VTMetalRasterizer) throws -> Data {
        let texture = try XCTUnwrap(renderer.output)
        var pixels = Data(count: texture.width * texture.height * 4)
        pixels.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * 4,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return pixels
    }

    private func assertNoTransients(_ metrics: VTMetalFramePipeline.CacheMetrics,
                                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(metrics.outputTextures, 0, file: file, line: line)
        XCTAssertEqual(metrics.outputTextureBytes, 0, file: file, line: line)
        XCTAssertEqual(metrics.imagesBySlot.reduce(0, +), 0, file: file, line: line)
        XCTAssertEqual(metrics.imageTileTextures, 0, file: file, line: line)
        XCTAssertEqual(metrics.imageTextureBytes, 0, file: file, line: line)
        XCTAssertEqual(metrics.imagePixelBytes, 0, file: file, line: line)
    }

    private func assertEmpty(_ metrics: VTMetalFramePipeline.CacheMetrics,
                             file: StaticString = #filePath, line: UInt = #line) {
        assertNoTransients(metrics, file: file, line: line)
        XCTAssertTrue(metrics.glyphsBySlot.allSatisfy { $0 == 0 }, file: file, line: line)
        XCTAssertTrue(metrics.shapedGlyphsBySlot.allSatisfy { $0 == 0 }, file: file, line: line)
        XCTAssertTrue(metrics.glyphCacheIdentitiesBySlot.allSatisfy { $0 == nil }, file: file, line: line)
        XCTAssertTrue(metrics.shapingMissesBySlot.allSatisfy { $0 == 0 }, file: file, line: line)
        XCTAssertEqual(metrics.atlasTextures, 0, file: file, line: line)
        XCTAssertEqual(metrics.retainedTextureBytes, 0, file: file, line: line)
    }
}
