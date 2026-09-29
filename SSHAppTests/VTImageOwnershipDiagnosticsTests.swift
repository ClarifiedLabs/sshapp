import XCTest
import UIKit
@testable import GhosttyVT

@MainActor
final class VTImageOwnershipDiagnosticsTests: XCTestCase {
    func testCacheCountsWeakLiveReplacementsWithoutRetainingDiagnosticImages() throws {
        let cache = VTImageSnapshotCache(limitBytes: 64)
        let owner = cache.makeOwner()
        var old: VTImageValue? = image(generation: 1)
        weak let oldProbe = old
        owner.retainViewport([1: try XCTUnwrap(old)])
        assertCache(cache, retained: 16, live: 16, external: 0, externalCount: 0)

        owner.releaseRetained()
        let released = cache.metrics
        assertCache(cache, retained: 0, live: 16, external: 16, externalCount: 1)
        XCTAssertEqual(cache.metrics, released, "Reading diagnostics does not change cache state")

        var replacement: VTImageValue? = image(generation: 2)
        weak let replacementProbe = replacement
        owner.retainViewport([2: try XCTUnwrap(replacement)])
        assertCache(cache, retained: 16, live: 32, external: 16, externalCount: 1)
        XCTAssertEqual(cache.metrics.trackedImages, 2)
        old = nil
        XCTAssertNil(oldProbe, "Stored scalar diagnostics must not keep old pixels alive")
        assertCache(cache, retained: 16, live: 16, external: 0, externalCount: 0)
        XCTAssertEqual(cache.metrics.trackedImages, 1)
        XCTAssertEqual(released.liveTrackedImageBytes, 16, "The scalar snapshot is immutable")

        replacement = nil
        XCTAssertNotNil(replacementProbe, "The cache alone still owns the replacement")
        owner.releaseRetained()
        XCTAssertNil(replacementProbe)
        assertCache(cache, retained: 0, live: 0, external: 0, externalCount: 0)
        XCTAssertEqual(cache.metrics.trackedImages, 0)
        XCTAssertEqual(cache.metrics.registeredOwners, 1)
    }

    func testRemovingOwnerRemovesEvidenceNotExternallyHeldPixels() {
        let cache = VTImageSnapshotCache(limitBytes: 64)
        let owner = cache.makeOwner()
        let held = image(generation: 1)
        owner.retainViewport([1: held])
        owner.releaseRetained()
        assertCache(cache, retained: 0, live: 16, external: 16, externalCount: 1)
        owner.remove()
        assertCache(cache, retained: 0, live: 0, external: 0, externalCount: 0)
        XCTAssertEqual(cache.metrics.registeredOwners, 0)
        XCTAssertEqual(cache.metrics.trackedImages, 0)
        XCTAssertEqual(held.rgba.count, 16, "Metrics are registrations, not a global census")
    }

    func testSchedulerDeduplicatesWithinFramesButNotAcrossTwoFlightsAndPending() async throws {
        var frame: VTFrameValue? = try await makeFrame()
        var shared: VTImageValue? = image(generation: 7)
        // Equal generations are intentionally insufficient for identity deduplication.
        var distinct: VTImageValue? = image(generation: 7)
        weak let sharedProbe = shared
        weak let distinctProbe = distinct
        frame?.graphics.placements = [placement(try XCTUnwrap(shared), id: 1),
                                      placement(try XCTUnwrap(shared), id: 2),
                                      placement(try XCTUnwrap(distinct), id: 3)]
        let scheduler = VTFrameScheduler()
        var alternate = VTPresentationState()
        alternate.blinkVisible = false
        var saved: VTFrameScheduler.OwnedImageDiagnostics?
        do {
            var first = try XCTUnwrap(scheduler.submit(try XCTUnwrap(frame)))
            let second = try XCTUnwrap(scheduler.submit(try XCTUnwrap(frame), presentation: alternate))
            XCTAssertNil(scheduler.submit(try XCTUnwrap(frame)))
            let held = scheduler.ownedImageDiagnostics
            saved = held
            XCTAssertEqual(held.slots.map(\.slot), [0, 1])
            XCTAssertEqual(held.slots.map(\.workID), [first.id, second.id])
            XCTAssertEqual(held.slots.map(\.revision), [frame?.revision, frame?.revision])
            XCTAssertEqual(held.slots.map(\.layoutGeneration), [frame?.layout.generation, frame?.layout.generation])
            XCTAssertEqual(held.slots.map(\.imageCount), [2, 2])
            XCTAssertEqual(held.slots.map(\.imageBytes), [32, 32])
            XCTAssertEqual(held.pending?.imageCount, 2)
            XCTAssertEqual(held.pending?.imageBytes, 32)
            XCTAssertNil(held.pending?.workID)
            XCTAssertNil(held.pending?.slot)
            XCTAssertEqual(scheduler.ownedImageDiagnostics, held)
            XCTAssertEqual(try JSONDecoder().decode(VTFrameScheduler.OwnedImageDiagnostics.self,
                                                   from: JSONEncoder().encode(held)), held)

            // Replace only the newest pending snapshot, preserving both flight records.
            frame?.graphics.placements = [placement(try XCTUnwrap(shared), id: 4)]
            XCTAssertNil(scheduler.submit(try XCTUnwrap(frame), presentation: alternate))
            XCTAssertEqual(scheduler.ownedImageDiagnostics.pending?.imageBytes, 16)
            XCTAssertEqual(scheduler.ownedImageDiagnostics.slots, held.slots)
            first = try XCTUnwrap(scheduler.complete(first))
            XCTAssertEqual(first.slot, 0)
            XCTAssertEqual(scheduler.ownedImageDiagnostics.slots[0].imageBytes, 16)
            XCTAssertNil(scheduler.ownedImageDiagnostics.pending)
            scheduler.retire()
            XCTAssertNil(scheduler.complete(first))
            XCTAssertNil(scheduler.complete(second))
            XCTAssertEqual(scheduler.ownedImageDiagnostics.slots.map(\.imageBytes), [0, 0])
            XCTAssertTrue(scheduler.ownedImageDiagnostics.slots.allSatisfy { $0.revision == nil && $0.workID == nil })
        } // Drop local Work values, which legitimately own the images.
        frame = nil
        shared = nil
        distinct = nil
        XCTAssertNil(sharedProbe, "Saved scalar diagnostics are not frame/image leases")
        XCTAssertNil(distinctProbe)
        XCTAssertEqual(saved?.slots[0].imageBytes, 32)
    }

    func testPipelineWaitingAndPreGPUCancellationDrainScalarOwnership() async throws {
        let frame = try await makeFrameWithImages()
        let budget = VTMetalPreparationBudget(limitBytes: 1)
        let blocker = try XCTUnwrap(budget.tryAcquire(bytes: 1))
        let pipeline = try VTMetalFramePipeline(font: font, preparationBudget: budget)
        defer { pipeline.retire(); budget.release(blocker) }
        var alternate = VTPresentationState()
        alternate.blinkVisible = false
        pipeline.submit(frame)
        pipeline.submit(frame, presentation: alternate)
        pipeline.submit(frame)
        let waiting = pipeline.ownedImageDiagnostics
        XCTAssertEqual(waiting.slots.map(\.phase), [.waiting, .waiting])
        XCTAssertEqual(waiting.slots.map(\.images.imageBytes), [16, 16])
        XCTAssertEqual(waiting.pending?.imageBytes, 16)
        pipeline.beginEpoch()
        XCTAssertNil(pipeline.ownedImageDiagnostics.pending)
        XCTAssertEqual(pipeline.ownedImageDiagnostics.slots.map(\.phase), [.waiting, .waiting],
                       "Cancellation must not pretend the outstanding tasks have drained")
        await pipeline.waitForIdle()
        assertDrained(pipeline)
        budget.release(blocker)

        // An immediate permit reports preGPU synchronously, before task entry.
        pipeline.submit(frame)
        XCTAssertEqual(pipeline.ownedImageDiagnostics.slots.map(\.phase), [.preGPU, .drained])
        XCTAssertEqual(pipeline.ownedImageDiagnostics.slots[0].images.imageBytes, 16)
        pipeline.retire()
        XCTAssertEqual(pipeline.ownedImageDiagnostics.slots[0].phase, .preGPU)
        await pipeline.waitForIdle()
        assertDrained(pipeline)
        XCTAssertEqual(pipeline.diagnostics.gpuCompletedFrames, 0)
    }

    func testPipelineHeldPresentationRemainsPostGPUAcrossCancellationAndSlotReuse() async throws {
        let frame = try await makeFrameWithImages()
        let pipeline = try VTMetalFramePipeline(font: font)
        var lease: CheckedContinuation<Void, Never>?
        let held = expectation(description: "presentation held after GPU completion")
        defer { pipeline.retire(); lease?.resume() }
        pipeline.publicationHoldForTesting = {
            await withCheckedContinuation { lease = $0; held.fulfill() }
        }
        pipeline.onRendered = { [weak pipeline] _ in
            XCTAssertEqual(pipeline?.ownedImageDiagnostics.slots[0].phase, .postGPUAwaitingPresentation)
        }
        pipeline.submit(frame)
        XCTAssertEqual(pipeline.ownedImageDiagnostics.slots[0].phase, .preGPU)
        await fulfillment(of: [held], timeout: 5)
        let continuation = try XCTUnwrap(lease)
        let diagnostics = pipeline.ownedImageDiagnostics
        XCTAssertEqual(diagnostics.slots.map(\.phase), [.postGPUAwaitingPresentation, .drained])
        XCTAssertEqual(diagnostics.slots[0].images.imageCount, 1)
        XCTAssertEqual(diagnostics.slots[0].images.imageBytes, 16)
        XCTAssertEqual(try JSONDecoder().decode(VTMetalFramePipeline.OwnedImageDiagnostics.self,
                                               from: JSONEncoder().encode(diagnostics)), diagnostics)
        pipeline.beginEpoch()
        XCTAssertEqual(pipeline.ownedImageDiagnostics, diagnostics,
                       "Invalidation does not end a held presentation/image lease")
        lease = nil
        continuation.resume()
        await pipeline.waitForIdle()
        assertDrained(pipeline)
        pipeline.publicationHoldForTesting = nil
        pipeline.submit(frame)
        XCTAssertEqual(pipeline.ownedImageDiagnostics.slots[0].phase, .preGPU,
                       "Slot reuse must reset the successful GPU flag")
        pipeline.retire()
        await pipeline.waitForIdle()
        assertDrained(pipeline)
    }

    func testPipelineAccountingErrorStaysPostGPUUntilPresentationCleanup() async throws {
        let frame = try await makeFrameWithImages()
        let pipeline = try VTMetalFramePipeline(font: font)
        var lease: CheckedContinuation<Void, Never>?
        let held = expectation(description: "failed accounting still holds presentation")
        var failures = 0
        defer { pipeline.retire(); lease?.resume() }
        pipeline.retainedTextureBytesOverrideForTesting = Int.max
        pipeline.publicationHoldForTesting = {
            await withCheckedContinuation { lease = $0; held.fulfill() }
        }
        pipeline.onRendered = { _ in XCTFail("Invalid accounting cannot publish") }
        pipeline.onFailureObservation = { [weak pipeline] _, _ in
            failures += 1
            XCTAssertEqual(pipeline?.ownedImageDiagnostics.slots[0].phase, .postGPUAwaitingPresentation)
            XCTAssertEqual(pipeline?.ownedImageDiagnostics.slots[0].images.imageBytes, 16)
        }
        pipeline.submit(frame)
        await fulfillment(of: [held], timeout: 5)
        let continuation = try XCTUnwrap(lease)
        XCTAssertEqual(pipeline.ownedImageDiagnostics.slots[0].phase, .postGPUAwaitingPresentation)
        XCTAssertEqual(failures, 0)
        lease = nil
        continuation.resume()
        await pipeline.waitForIdle()
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(pipeline.failedFrames, 1)
        assertDrained(pipeline)
    }

    private var font: UIFont { .monospacedSystemFont(ofSize: 12, weight: .regular) }

    private func image(generation: UInt64) -> VTImageValue {
        VTImageValue(generation: generation, width: 2, height: 2, rgba: Data(repeating: 255, count: 16))
    }

    private func placement(_ image: VTImageValue, id: UInt32) -> VTImagePlacementValue {
        .init(image: image, imageID: 1, placementID: id, z: 0, column: 0, row: 0,
              offset: .zero, pixelSize: CGSize(width: 2, height: 2),
              source: CGRect(x: 0, y: 0, width: 2, height: 2))
    }

    private func makeFrame() async throws -> VTFrameValue {
        let layout = try VTLayout(generation: 1, width: 80, height: 40,
                                  cellWidth: 10, cellHeight: 20, scale: 1, padding: 0)
        let terminal = try VTTerminal(layout: layout)
        do {
            let frame = try await terminal.snapshot()
            _ = try await terminal.retire()
            return frame
        } catch {
            _ = try? await terminal.retire()
            throw error
        }
    }

    private func makeFrameWithImages() async throws -> VTFrameValue {
        var frame = try await makeFrame()
        let shared = image(generation: 1)
        frame.graphics.placements = [placement(shared, id: 1), placement(shared, id: 2)]
        return frame
    }

    private func assertCache(_ cache: VTImageSnapshotCache, retained: Int, live: Int,
                             external: Int, externalCount: Int,
                             file: StaticString = #filePath, line: UInt = #line) {
        let metrics = cache.metrics
        XCTAssertEqual(metrics.retainedBytes, retained, file: file, line: line)
        XCTAssertEqual(metrics.liveTrackedImageBytes, live, file: file, line: line)
        XCTAssertEqual(metrics.externalOnlyImageBytes, external, file: file, line: line)
        XCTAssertEqual(metrics.externalOnlyImages, externalCount, file: file, line: line)
    }

    private func assertDrained(_ pipeline: VTMetalFramePipeline,
                               file: StaticString = #filePath, line: UInt = #line) {
        let diagnostics = pipeline.ownedImageDiagnostics
        XCTAssertNil(diagnostics.pending, file: file, line: line)
        XCTAssertEqual(diagnostics.slots.map(\.phase), [.drained, .drained], file: file, line: line)
        XCTAssertEqual(diagnostics.slots.map(\.images.imageBytes), [0, 0], file: file, line: line)
        XCTAssertTrue(diagnostics.slots.allSatisfy { $0.images.workID == nil }, file: file, line: line)
    }
}
