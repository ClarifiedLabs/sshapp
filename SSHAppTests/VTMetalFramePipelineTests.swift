import Metal
import QuartzCore
import Synchronization
import UIKit
import XCTest
@testable import GhosttyVT

/// Frame pipeline, scheduler and renderer facade lifetimes: bounded leases,
/// epoch invalidation, retry, publication ordering and off-main teardown.
@MainActor
final class VTMetalFramePipelineTests: XCTestCase {
    /// Own the only strong reference across queues without unchecked Sendable.
    private final class LastReleaseHolder<Value: AnyObject & Sendable>: Sendable {
        private let storage: Mutex<Value?>

        init(_ value: Value) { storage = Mutex(value) }
        var value: Value? { storage.withLock { $0 } }
        func release() { storage.withLock { $0 = nil } }
    }

    func testMainActorCleanupRunsSynchronouslyOnMainThread() {
        var cleaned = false
        cleanupOnMainActor {
            XCTAssertTrue(Thread.isMainThread)
            cleaned = true
        }
        XCTAssertTrue(cleaned, "Main-thread teardown must not wait for another task")
    }

    func testMainActorCleanupHopsFromBackgroundQueue() async {
        let cleaned = expectation(description: "Cleanup runs on the main actor")
        DispatchQueue.global().async {
            XCTAssertFalse(Thread.isMainThread)
            cleanupOnMainActor {
                XCTAssertTrue(Thread.isMainThread)
                cleaned.fulfill()
            }
        }
        await fulfillment(of: [cleaned], timeout: 5)
    }

    func testRendererFacadeCanReleaseItsLastReferenceOffMainThread() async throws {
        let frame = try await frame(text: "facade teardown with held leases")
        let holder = LastReleaseHolder(try VTMetalRenderer(font: .monospacedSystemFont(ofSize: 12, weight: .regular)))
        weak let renderer = holder.value
        weak let pipeline = holder.value?.pipelineForTesting
        weak let layer = holder.value?.presentationLayer
        let first = expectation(description: "First GPU completion holds its IOSurface publication lease")
        let second = expectation(description: "Second GPU completion holds its IOSurface publication lease")
        var leases: [CheckedContinuation<Void, Never>] = []
        defer {
            holder.value?.retire()
            for lease in leases { lease.resume() }
        }
        pipeline?.publicationHoldForTesting = {
            await withCheckedContinuation { continuation in
                leases.append(continuation)
                (leases.count == 1 ? first : second).fulfill()
            }
        }
        // Observe the pipeline directly: the facade's weak callback forwarding
        // would suppress publication after deinit even if retirement were broken.
        var completions = 0
        pipeline?.onComplete = { _ in completions += 1 }
        holder.value?.setActive(true)
        holder.value?.submit(frame, presentation: .init())
        await fulfillment(of: [first], timeout: 5)
        guard leases.count == 1 else { throw CancellationError() }
        var presentation = VTPresentationState()
        presentation.blinkVisible = false
        holder.value?.submit(frame, presentation: presentation)
        await fulfillment(of: [second], timeout: 5)
        guard leases.count == 2 else { throw CancellationError() }
        holder.value?.submit(frame, presentation: .init())
        XCTAssertEqual(pipeline?.inFlightCount, 2)
        XCTAssertEqual(pipeline?.pendingCount, 1)
        XCTAssertEqual(pipeline?.diagnostics.gpuCompletedFrames, 2)
        XCTAssertEqual(pipeline?.diagnostics.presentationLeasedTargets, 2)
        let retainedBytes = try XCTUnwrap(pipeline?.cacheMetrics.retainedTextureBytes)
        XCTAssertGreaterThan(retainedBytes, 0, "The held leases must own real GPU resources")
        let previousReleases = try XCTUnwrap(pipeline?.resourceReleases)
        let drained = expectation(description: "Retirement releases resources after both leases drain")
        pipeline?.onResourcesReleased = { [weak pipeline] in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(pipeline?.inFlightCount, 0)
            XCTAssertEqual(pipeline?.pendingCount, 0)
            XCTAssertEqual(pipeline?.resourceReleases, previousReleases + 1)
            XCTAssertEqual(pipeline?.cacheMetrics.retainedTextureBytes, 0)
            XCTAssertEqual(pipeline?.cacheMetrics.atlasTextures, 0)
            XCTAssertEqual(pipeline?.cacheMetrics.outputTextures, 0)
            XCTAssertEqual(pipeline?.diagnostics.startedFrames, 2, "Pending work must never start")
            XCTAssertEqual(pipeline?.diagnostics.currentCompletions, 0)
            XCTAssertEqual(pipeline?.diagnostics.obsoleteCompletions, 2)
            XCTAssertEqual(pipeline?.diagnostics.presentationLeasedTargets, 0)
            drained.fulfill()
        }
        let released = expectation(description: "Renderer's last reference released off main")
        DispatchQueue.global().async {
            XCTAssertFalse(Thread.isMainThread)
            holder.release()
            released.fulfill()
        }
        await fulfillment(of: [released], timeout: 5)
        XCTAssertNil(renderer)
        let retirementDeadline = Date().addingTimeInterval(5)
        while pipeline?.isActive == true && Date() < retirementDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(pipeline, "Held leases, not the test, must retain the pipeline")
        XCTAssertNotNil(layer)
        XCTAssertEqual(pipeline?.isActive, false)
        XCTAssertEqual(pipeline?.pendingCount, 0, "Facade deinit must retire and cancel pending work")
        XCTAssertEqual(pipeline?.inFlightCount, 2)
        XCTAssertEqual(pipeline?.resourceReleases, previousReleases)
        XCTAssertEqual(pipeline?.cacheMetrics.retainedTextureBytes, retainedBytes)

        leases.removeFirst().resume()
        let firstDrainDeadline = Date().addingTimeInterval(5)
        while pipeline?.inFlightCount == 2 && Date() < firstDrainDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(pipeline?.inFlightCount, 1)
        XCTAssertEqual(pipeline?.resourceReleases, previousReleases, "Global drain notification waits for the remaining lease")
        let remainingBytes = try XCTUnwrap(pipeline?.cacheMetrics.retainedTextureBytes)
        XCTAssertGreaterThan(remainingBytes, 0, "The remaining presentation still owns its resources")
        XCTAssertLessThan(remainingBytes, retainedBytes, "The completed slot must release before its preparation permit")
        XCTAssertEqual(pipeline?.cacheMetrics.atlasTextures, 1)
        XCTAssertEqual(pipeline?.cacheMetrics.outputTextures, 0, "IOSurface targets are presenter-owned")
        XCTAssertEqual(pipeline?.diagnostics.presentationLeasedTargets, 1)
        leases.removeFirst().resume()
        await fulfillment(of: [drained], timeout: 5)
        XCTAssertEqual(completions, 0)
        let deadline = Date().addingTimeInterval(5)
        while (pipeline != nil || layer != nil) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(pipeline, "Drained work must release the pipeline without a surviving facade")
        XCTAssertNil(layer)
    }

    func testScrollRefreshDriverCanReleaseItsLastReferenceOffMainThread() async throws {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw XCTSkip("Requires an attached UIWindowScene")
        }
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let controller = UIViewController()
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true }
        let holder = LastReleaseHolder(VTScrollRefreshDriver())
        // Allocate a participant and its weakly referenced coordinator even on
        // 60 Hz simulators where the display-link policy does not start a link.
        holder.value?.pulse(host: controller.view)
        weak let driver = holder.value
        let released = expectation(description: "Driver's last reference released off main")
        DispatchQueue.global().async {
            XCTAssertFalse(Thread.isMainThread)
            holder.release()
            released.fulfill()
        }
        await fulfillment(of: [released], timeout: 5)
        XCTAssertNil(driver)
    }

    func testRunningScrollRefreshCoordinatorCanReleaseOffMainThread() async throws {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw XCTSkip("Requires an attached UIWindowScene")
        }
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let controller = UIViewController()
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true }
        let center = NotificationCenter()
        let invalidated = expectation(description: "Owned display-link resource invalidated on main actor")
        var invalidations = 0
        let holder = LastReleaseHolder(VTScrollRefreshCoordinator(scene: scene, notifications: center,
            conditions: { .init(maximumFramesPerSecond: 120, lowPower: false, thermalState: .nominal) },
            now: { 10 }, onDisplayLinkInvalidatedForTesting: {
                XCTAssertTrue(Thread.isMainThread)
                invalidations += 1
                invalidated.fulfill()
            }))
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        center.post(name: UIScene.didActivateNotification, object: scene)
        let participant = try XCTUnwrap(holder.value?.makeParticipant(host: controller.view))
        participant.pulse()
        XCTAssertTrue(holder.value?.isRunning == true, "Exercise an owned, scheduled display link")
        let link = try XCTUnwrap(holder.value?.displayLinkForTesting)
        link.isPaused = true // An orphan LinkTarget.tick must not rescue missing resource cleanup.
        XCTAssertEqual(invalidations, 0)
        XCTAssertEqual(holder.value?.callbacks, 0)
        weak let coordinator = holder.value
        let released = expectation(description: "Running coordinator's last reference released off main")
        DispatchQueue.global().async {
            XCTAssertFalse(Thread.isMainThread)
            holder.release()
            released.fulfill()
        }
        await fulfillment(of: [released, invalidated], timeout: 5)
        XCTAssertNil(coordinator)
        XCTAssertEqual(invalidations, 1, "Resource teardown must invalidate without a display-link tick")
        participant.cancel() // A surviving participant must not keep its owner alive.
        withExtendedLifetime(link) {} // The test does not depend on CADisplayLink deallocation.
    }

    private func frame(text: String) async throws -> VTFrameValue {
        let layout = try VTLayout(
            generation: 1,
            width: 390,
            height: 480,
            cellWidth: 10,
            cellHeight: 20,
            scale: 2
        )
        let terminal = try VTTerminal(layout: layout)
        if !text.isEmpty {
            _ = try await terminal.ingest(Data(text.utf8))
        }
        let frame = try await terminal.snapshot()
        _ = try await terminal.retire()
        return frame
    }

    private func coreTextBytes(for frame: VTFrameValue, font: UIFont) -> [UInt8] {
        let width = Int(frame.layout.viewportWidth)
        let height = Int(frame.layout.viewportHeight)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                XCTFail("CoreText bitmap context unavailable")
                return
            }
            VTCoreTextRenderer.draw(
                frame,
                font: font,
                context: context,
                bounds: CGRect(x: 0, y: 0, width: width, height: height),
                cache: VTGlyphCache()
            )
        }
        return bytes
    }

    func testCoreTextDrawsHelloDifferentlyThanBlank() async throws {
        let font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let hello = coreTextBytes(for: try await frame(text: "hello"), font: font)
        let blank = coreTextBytes(for: try await frame(text: ""), font: font)
        XCTAssertEqual(hello.count, blank.count)
        XCTAssertGreaterThan(hello.count, 0)
        XCTAssertNotEqual(hello, blank)
    }

    private func offscreenPipeline() throws -> VTMetalFramePipeline {
        try VTMetalFramePipeline(font: .monospacedSystemFont(ofSize: 12, weight: .regular))
    }

    func testHistoricalPresentationLifetimeSurvivesNewerCommitButNotLeaseRelease() async throws {
        let frame = try await frame(text: "historical presentation")
        let scheduler = VTFrameScheduler()
        let older = try XCTUnwrap(scheduler.submit(frame))
        XCTAssertTrue(scheduler.commitPresentation(older))
        var blink = VTPresentationState()
        blink.blinkVisible = false
        let newer = try XCTUnwrap(scheduler.submit(frame, presentation: blink))
        XCTAssertTrue(scheduler.commitPresentation(newer))
        for _ in 0..<3 {
            XCTAssertTrue(scheduler.isSamePresentationLifetime(older))
            XCTAssertTrue(scheduler.isSamePresentationLifetime(newer))
            XCTAssertFalse(scheduler.isCurrent(older))
            XCTAssertFalse(scheduler.commitPresentation(older), "Diagnostics cannot authorize an older commit")
            XCTAssertEqual(scheduler.inFlightCount, 2)
            XCTAssertEqual(scheduler.pendingCount, 0)
            XCTAssertEqual(scheduler.coalescedFrames, 0)
        }
        XCTAssertNil(scheduler.complete(older))
        XCTAssertFalse(scheduler.isSamePresentationLifetime(older))
        let replacement = try XCTUnwrap(scheduler.submit(frame))
        XCTAssertEqual(replacement.slot, older.slot)
        XCTAssertFalse(scheduler.isSamePresentationLifetime(older), "Slot reuse cannot resurrect released work")
        XCTAssertNil(scheduler.complete(older), "Duplicate completion cannot release the replacement")
        XCTAssertTrue(scheduler.isSamePresentationLifetime(replacement))
        XCTAssertNil(scheduler.complete(newer))
        XCTAssertNil(scheduler.complete(replacement))
    }

    func testHistoricalPresentationLifetimeRejectsForgedLeaseFields() async throws {
        let frame = try await frame(text: "lease identity")
        let otherTerminal = try await self.frame(text: "lease identity")
        XCTAssertNotEqual(frame.terminalID, otherTerminal.terminalID)
        XCTAssertEqual(frame.revision, otherTerminal.revision)
        let scheduler = VTFrameScheduler()
        let work = try XCTUnwrap(scheduler.submit(frame))
        var otherPresentation = work.presentation
        otherPresentation.focused = false
        let forgeries: [VTFrameScheduler.Work] = [
            .init(id: work.id + 1, slot: work.slot, epoch: work.epoch, frame: frame, presentation: work.presentation),
            .init(id: work.id, slot: work.slot + 1, epoch: work.epoch, frame: frame, presentation: work.presentation),
            .init(id: work.id, slot: work.slot, epoch: work.epoch + 1, frame: frame, presentation: work.presentation),
            .init(id: work.id, slot: work.slot, epoch: work.epoch, frame: otherTerminal, presentation: work.presentation),
            .init(id: work.id, slot: work.slot, epoch: work.epoch, frame: frame, presentation: otherPresentation)
        ]
        for forged in forgeries { XCTAssertFalse(scheduler.isSamePresentationLifetime(forged)) }
        XCTAssertTrue(scheduler.isSamePresentationLifetime(work))
        XCTAssertEqual(scheduler.inFlightCount, 1)
        XCTAssertTrue(scheduler.commitPresentation(work))
        XCTAssertNil(scheduler.complete(work))
    }

    func testHistoricalPresentationLifetimeRejectsGeometryEpochAndRetirementChanges() async throws {
        let layout = try VTLayout(generation: 1, width: 390, height: 480,
                                  cellWidth: 10, cellHeight: 20, scale: 2)
        let terminal = try VTTerminal(layout: layout)
        let frame = try await terminal.snapshot()
        let scheduler = VTFrameScheduler()
        let old = try XCTUnwrap(scheduler.submit(frame))
        let nextLayout = try VTLayout(generation: 2, width: 400, height: 480,
                                      cellWidth: 10, cellHeight: 20, scale: 2)
        _ = try await terminal.resize(to: nextLayout)
        let resized = try await terminal.snapshot()
        _ = try await terminal.retire()
        let forged = VTFrameScheduler.Work(id: old.id, slot: old.slot, epoch: old.epoch,
                                           frame: resized, presentation: old.presentation)
        XCTAssertFalse(scheduler.isSamePresentationLifetime(forged))
        XCTAssertTrue(scheduler.isSamePresentationLifetime(old))
        XCTAssertNil(scheduler.submit(resized))
        XCTAssertFalse(scheduler.isSamePresentationLifetime(old), "Pending geometry invalidates the old layout")
        let current = try XCTUnwrap(scheduler.complete(old))
        XCTAssertTrue(scheduler.isSamePresentationLifetime(current))
        scheduler.beginEpoch()
        XCTAssertFalse(scheduler.isSamePresentationLifetime(current))
        XCTAssertNil(scheduler.submit(resized))
        let fresh = try XCTUnwrap(scheduler.complete(current))
        XCTAssertTrue(scheduler.isSamePresentationLifetime(fresh))
        XCTAssertFalse(scheduler.isSamePresentationLifetime(current))
        scheduler.retire()
        XCTAssertFalse(scheduler.isSamePresentationLifetime(fresh))
        XCTAssertNil(scheduler.complete(fresh))
    }

    func testPipelineHistoricalPresentationLifetimeDoesNotChangeSupersededCompletionPolicy() async throws {
        let frame = try await frame(text: "late positive presentation")
        let pipeline = try offscreenPipeline()
        let first = expectation(description: "Older presentation held")
        let second = expectation(description: "Newer presentation held")
        var leases: [CheckedContinuation<Void, Never>] = []
        var works: [VTFrameScheduler.Work] = []
        var observations: [VTMetalFramePipeline.Completion] = []
        var completions = 0
        defer {
            pipeline.retire()
            for lease in leases { lease.resume() }
        }
        pipeline.onRendered = { [weak pipeline] _ in
            if let work = pipeline?.renderedWorkForDiagnostics { works.append(work) }
        }
        pipeline.publicationHoldForTesting = {
            await withCheckedContinuation { continuation in
                leases.append(continuation)
                (leases.count == 1 ? first : second).fulfill()
            }
        }
        pipeline.onObservation = { [weak pipeline] completion in
            observations.append(completion)
            XCTAssertTrue(pipeline?.isSamePresentationLifetime(completion) == true)
            XCTAssertEqual(pipeline?.isCurrent(completion), completion.work.id == works.last?.id)
        }
        pipeline.onComplete = { _ in completions += 1 }
        pipeline.submit(frame)
        await fulfillment(of: [first], timeout: 5)
        guard leases.count == 1 else { throw CancellationError() }
        var blink = VTPresentationState()
        blink.blinkVisible = false
        pipeline.submit(frame, presentation: blink)
        await fulfillment(of: [second], timeout: 5)
        guard leases.count == 2, works.count == 2 else { throw CancellationError() }
        XCTAssertFalse(pipeline.isCurrent(works[0]))
        XCTAssertTrue(pipeline.isSamePresentationLifetime(works[0]))
        XCTAssertTrue(pipeline.isSamePresentationLifetime(works[1]))
        leases.removeFirst().resume()
        leases.removeFirst().resume()
        await pipeline.waitForIdle()
        XCTAssertEqual(observations.count, 2)
        for work in works { XCTAssertFalse(pipeline.isSamePresentationLifetime(work)) }
        XCTAssertEqual(completions, 1, "Historical evidence must not publish obsolete production completions")
        XCTAssertEqual(pipeline.diagnostics.currentCompletions, 1)
        XCTAssertEqual(pipeline.diagnostics.obsoleteCompletions, 1)
        XCTAssertEqual(pipeline.diagnostics.retryRequests, 0)
        XCTAssertEqual(pipeline.diagnostics.startedFrames, 2)
    }

    func testPipelineHistoricalPresentationLifetimeRejectsInvalidatedHeldLeases() async throws {
        enum Invalidation: CaseIterable { case suspend, hideResume, epoch, font, retire }
        let frame = try await frame(text: "invalidated historical presentation")
        for invalidation in Invalidation.allCases {
            let pipeline = try offscreenPipeline()
            let held = expectation(description: "Presentation held for \(invalidation)")
            var lease: CheckedContinuation<Void, Never>?
            var work: VTFrameScheduler.Work?
            defer { pipeline.retire(); lease?.resume() }
            pipeline.onRendered = { [weak pipeline] _ in work = pipeline?.renderedWorkForDiagnostics }
            pipeline.publicationHoldForTesting = {
                await withCheckedContinuation { lease = $0; held.fulfill() }
            }
            pipeline.onObservation = { [weak pipeline] completion in
                XCTAssertFalse(pipeline?.isSamePresentationLifetime(completion) ?? true)
            }
            pipeline.submit(frame)
            await fulfillment(of: [held], timeout: 5)
            let original = try XCTUnwrap(work)
            XCTAssertTrue(pipeline.isSamePresentationLifetime(original))
            switch invalidation {
            case .suspend: pipeline.setActive(false)
            case .hideResume:
                pipeline.setActive(false)
                pipeline.setActive(true)
            case .epoch: pipeline.beginEpoch()
            case .font: pipeline.beginEpoch(font: .monospacedSystemFont(ofSize: 14, weight: .regular))
            case .retire:
                pipeline.retire()
                pipeline.setActive(true)
            }
            XCTAssertFalse(pipeline.isSamePresentationLifetime(original))
            XCTAssertEqual(pipeline.inFlightCount, 1, "A read-only rejection cannot release the lease")
            try XCTUnwrap(lease).resume()
            lease = nil
            await pipeline.waitForIdle()
            XCTAssertFalse(pipeline.isSamePresentationLifetime(original))
            XCTAssertEqual(pipeline.diagnostics.currentCompletions, 0)
            XCTAssertEqual(pipeline.diagnostics.obsoleteCompletions, 1)
            XCTAssertEqual(pipeline.diagnostics.retryRequests, 0)
        }
    }

    func testSchedulerReadyTimeDefaultsToNilAndDoesNotChangeDuplicateSuppression() async throws {
        let frame = try await frame(text: "same revision")
        let scheduler = VTFrameScheduler(capacity: 1)
        let first = try XCTUnwrap(scheduler.submit(frame))
        XCTAssertNil(first.acceptedFrameReadyTime)
        XCTAssertNil(scheduler.submit(frame, acceptedFrameReadyTime: 10))
        XCTAssertEqual(scheduler.pendingCount, 0)
        XCTAssertEqual(scheduler.coalescedFrames, 0)
        XCTAssertTrue(scheduler.isCurrent(first))
        XCTAssertTrue(scheduler.commitPresentation(first))
        XCTAssertNil(scheduler.complete(first))
        XCTAssertNil(scheduler.submit(frame, acceptedFrameReadyTime: 20),
                     "Changing metadata cannot revive an already presented revision")
        XCTAssertTrue(scheduler.isIdle)
    }

    func testSchedulerCoalescesReadyTimeWithItsFrameWithoutRestampingDuplicates() async throws {
        let frame = try await frame(text: "pending metadata")
        let scheduler = VTFrameScheduler(capacity: 1)
        let first = try XCTUnwrap(scheduler.submit(frame, acceptedFrameReadyTime: 10))
        var blink = VTPresentationState()
        blink.blinkVisible = false
        XCTAssertNil(scheduler.submit(frame, presentation: blink, acceptedFrameReadyTime: 20))
        XCTAssertEqual(scheduler.pendingCount, 1)
        XCTAssertNil(scheduler.submit(frame, acceptedFrameReadyTime: 30))
        XCTAssertEqual(scheduler.coalescedFrames, 1)
        XCTAssertNil(scheduler.submit(frame, acceptedFrameReadyTime: 40))
        XCTAssertEqual(scheduler.coalescedFrames, 1, "Timestamp-only changes are still duplicates")
        XCTAssertEqual(first.acceptedFrameReadyTime, 10)
        XCTAssertTrue(scheduler.isCurrent(first))
        XCTAssertTrue(scheduler.commitPresentation(first))
        let newest = try XCTUnwrap(scheduler.complete(first))
        XCTAssertEqual(newest.acceptedFrameReadyTime, 30, "Keep the stamp of the accepted pending work")
        XCTAssertEqual(newest.frame, frame)
        XCTAssertEqual(newest.presentation, VTPresentationState())
        XCTAssertTrue(scheduler.commitPresentation(newest))
        XCTAssertFalse(scheduler.isCurrent(first))
        XCTAssertNil(scheduler.complete(newest))
        XCTAssertTrue(scheduler.isIdle)
    }

    func testSchedulerEpochInvalidatesPendingReadyTimeButRetainsOldLeaseMetadata() async throws {
        let frame = try await frame(text: "epoch metadata")
        let scheduler = VTFrameScheduler(capacity: 1)
        let old = try XCTUnwrap(scheduler.submit(frame, acceptedFrameReadyTime: 10))
        var blink = VTPresentationState()
        blink.blinkVisible = false
        XCTAssertNil(scheduler.submit(frame, presentation: blink, acceptedFrameReadyTime: 20))
        scheduler.beginEpoch()
        XCTAssertEqual(scheduler.pendingCount, 0)
        XCTAssertFalse(scheduler.isCurrent(old))
        XCTAssertFalse(scheduler.commitPresentation(old))
        XCTAssertEqual(old.acceptedFrameReadyTime, 10)
        XCTAssertNil(scheduler.submit(frame, acceptedFrameReadyTime: 30), "Old epoch still owns its slot")
        let fresh = try XCTUnwrap(scheduler.complete(old))
        XCTAssertEqual(fresh.acceptedFrameReadyTime, 30)
        XCTAssertNotEqual(fresh.epoch, old.epoch)
        XCTAssertEqual(fresh.frame, old.frame, "Equal revisions in a fresh epoch remain distinct work")
        XCTAssertTrue(scheduler.isCurrent(fresh))
        XCTAssertNil(scheduler.complete(old), "Stale completion cannot release the fresh lease")
        XCTAssertTrue(scheduler.commitPresentation(fresh))
        XCTAssertNil(scheduler.complete(fresh))
    }

    func testPipelineCarriesReadyTimeThroughRenderedAndCompletionWorkIndependentlyOfTimelines() async throws {
        let frame = try await frame(text: "scalar diagnostic")
        let pipeline = try VTMetalFramePipeline(font: .monospacedSystemFont(ofSize: 12, weight: .regular))
        defer { pipeline.retire() }
        XCTAssertFalse(pipeline.recordsTimelines)
        var expectedTime: Double?
        var renders = 0
        var observations = 0
        pipeline.onRendered = { [weak pipeline] _ in
            renders += 1
            XCTAssertEqual(pipeline?.renderedWorkForDiagnostics?.acceptedFrameReadyTime, expectedTime)
        }
        pipeline.onObservation = { completion in
            observations += 1
            XCTAssertEqual(completion.work.acceptedFrameReadyTime, expectedTime)
            XCTAssertNil(completion.timeline)
        }
        pipeline.submit(frame)
        await pipeline.waitForIdle()
        XCTAssertEqual(renders, 1)
        XCTAssertEqual(observations, 1)
        expectedTime = 123
        pipeline.beginEpoch()
        pipeline.submit(frame, acceptedFrameReadyTime: expectedTime)
        await pipeline.waitForIdle()
        XCTAssertEqual(renders, 2)
        XCTAssertEqual(observations, 2)
        XCTAssertNil(pipeline.renderedWorkForDiagnostics)
        pipeline.submit(frame, acceptedFrameReadyTime: 456)
        XCTAssertTrue(pipeline.isIdle)
        XCTAssertEqual(pipeline.diagnostics.startedFrames, 2)
    }

    func testMetalPipelineBoundsBurstAndDrainsBeforeResourceRelease() async throws {
        let frame = try await frame(text: "hello")
        let pipeline = try VTMetalFramePipeline(font: .monospacedSystemFont(ofSize: 12, weight: .regular))
        for index in 0..<100 {
            var presentation = VTPresentationState()
            presentation.blinkVisible = index.isMultiple(of: 2)
            pipeline.submit(frame, presentation: presentation)
            XCTAssertLessThanOrEqual(pipeline.inFlightCount, 2)
            XCTAssertLessThanOrEqual(pipeline.pendingCount, 1)
        }
        XCTAssertGreaterThan(pipeline.coalescedFrames, 0)
        pipeline.setActive(false)
        await pipeline.waitForIdle()
        XCTAssertEqual(pipeline.inFlightCount, 0)
        XCTAssertEqual(pipeline.pendingCount, 0)
        XCTAssertEqual(pipeline.cacheMetrics.retainedTextureBytes, 0)
        pipeline.retire()
    }

    func testMetalPipelineResumesWithFreshSnapshotRequest() async throws {
        let frame = try await frame(text: "hello")
        let pipeline = try VTMetalFramePipeline(font: .monospacedSystemFont(ofSize: 12, weight: .regular))
        pipeline.submit(frame)
        pipeline.setActive(false)
        var requests = 0
        pipeline.onNeedsFrame = { requests += 1 }
        pipeline.setActive(true)
        await pipeline.waitForIdle()
        XCTAssertEqual(requests, 1)
        var completed = false
        pipeline.onComplete = { _ in completed = true }
        pipeline.submit(frame)
        await pipeline.waitForIdle()
        XCTAssertTrue(completed)
        XCTAssertEqual(pipeline.failedFrames, 0)
        pipeline.retire()
    }

    func testObsoleteGPUCompletionCannotPublishCurrentFrame() async throws {
        let frame = try await frame(text: "epoch")
        let pipeline = try VTMetalFramePipeline(font: .monospacedSystemFont(ofSize: 12, weight: .regular))
        var observations = 0
        var completions = 0
        pipeline.onObservation = { [weak pipeline] _ in
            observations += 1
            pipeline?.beginEpoch()
        }
        pipeline.onComplete = { _ in completions += 1 }
        pipeline.submit(frame)
        await pipeline.waitForIdle()
        XCTAssertEqual(observations, 1)
        XCTAssertEqual(completions, 0)
        XCTAssertEqual(pipeline.obsoleteCompletions, 1)
        pipeline.retire()
    }

    func testRenderedCallbackPrecedesHeldIOSurfacePublicationAndKeepsLease() async throws {
        let frame = try await frame(text: "GPU before publication")
        let renderer = try VTMetalRenderer(font: .monospacedSystemFont(ofSize: 12, weight: .regular))
        let pipeline = renderer.pipelineForTesting
        let held = expectation(description: "IOSurface publication held")
        var lease: CheckedContinuation<Void, Never>?
        defer { renderer.retire(); lease?.resume() }
        var rendered = 0
        var completed = 0
        renderer.onRendered = { [weak pipeline] value in
            XCTAssertEqual(value, frame)
            XCTAssertEqual(pipeline?.diagnostics.gpuCompletedFrames, 1)
            XCTAssertEqual(pipeline?.inFlightCount, 1)
            XCTAssertEqual(completed, 0)
            rendered += 1
        }
        renderer.onComplete = { _ in completed += 1 }
        pipeline.publicationHoldForTesting = {
            XCTAssertEqual(rendered, 1, "GPU callback must precede IOSurface publication")
            await withCheckedContinuation { lease = $0; held.fulfill() }
        }
        renderer.setActive(true)
        renderer.submit(frame, presentation: .init())
        await fulfillment(of: [held], timeout: 5)
        XCTAssertEqual(rendered, 1)
        XCTAssertEqual(completed, 0)
        XCTAssertEqual(pipeline.inFlightCount, 1)
        XCTAssertEqual(pipeline.diagnostics.observedCompletions, 0)
        XCTAssertEqual(pipeline.diagnostics.presentationPublications, 0)
        XCTAssertNil(renderer.presentationLayer.contents)
        XCTAssertGreaterThan(pipeline.cacheMetrics.retainedTextureBytes, 0)
        try XCTUnwrap(lease).resume()
        lease = nil
        await pipeline.waitForIdle()
        XCTAssertEqual(rendered, 1)
        XCTAssertEqual(completed, 1)
        XCTAssertEqual(pipeline.diagnostics.presentationPublications, 1)
        XCTAssertNotNil(renderer.presentationLayer.contents)
        XCTAssertEqual(pipeline.inFlightCount, 0)
    }

    func testRenderedCallbackReentrantInvalidationDrainsPresentationBeforeRelease() async throws {
        let frame = try await frame(text: "reentrant render")
        for retire in [false, true] {
            let pipeline = try offscreenPipeline()
            let held = expectation(description: "Invalidated presentation still drains, retire=\(retire)")
            var lease: CheckedContinuation<Void, Never>?
            defer { pipeline.retire(); lease?.resume() }
            let releases = pipeline.resourceReleases
            var rendered = 0
            var completed = 0
            pipeline.onRendered = { [weak pipeline] _ in
                rendered += 1
                if retire { pipeline?.retire() }
                else { pipeline?.beginEpoch() }
            }
            pipeline.onComplete = { _ in completed += 1 }
            pipeline.publicationHoldForTesting = {
                await withCheckedContinuation { lease = $0; held.fulfill() }
            }
            pipeline.submit(frame)
            await fulfillment(of: [held], timeout: 5)
            XCTAssertEqual(rendered, 1)
            XCTAssertEqual(completed, 0)
            XCTAssertEqual(pipeline.inFlightCount, 1)
            XCTAssertEqual(pipeline.resourceReleases, releases)
            XCTAssertGreaterThan(pipeline.cacheMetrics.retainedTextureBytes, 0)
            try XCTUnwrap(lease).resume()
            lease = nil
            await pipeline.waitForIdle()
            XCTAssertEqual(completed, 0, "Reentrant invalidation suppresses late presentation success")
            XCTAssertEqual(pipeline.diagnostics.observedCompletions, 1)
            XCTAssertEqual(pipeline.diagnostics.obsoleteCompletions, 1)
            XCTAssertEqual(pipeline.inFlightCount, 0)
            if retire {
                XCTAssertEqual(pipeline.resourceReleases, releases + 1)
                XCTAssertEqual(pipeline.cacheMetrics.retainedTextureBytes, 0)
            }
        }
    }

    func testPostGPUInvalidationSuppressesPublicationAndDrainsHeldPresentation() async throws {
        enum Invalidation: CaseIterable { case epoch, suspend, retire }
        let frame = try await frame(text: "invalidated after GPU completion")
        for invalidation in Invalidation.allCases {
            let pipeline = try offscreenPipeline()
            let held = expectation(description: "Post-GPU invalidation holds presentation: \(invalidation)")
            var lease: CheckedContinuation<Void, Never>?
            defer { pipeline.retire(); lease?.resume() }
            let releases = pipeline.resourceReleases
            var boundaries = 0
            var rendered = 0
            var completed = 0
            pipeline.beforeRenderedPublicationForTesting = { [weak pipeline] in
                guard let pipeline else { XCTFail("GPU work must retain its pipeline"); return }
                boundaries += 1
                XCTAssertEqual(pipeline.diagnostics.gpuCompletedFrames, 1)
                XCTAssertEqual(pipeline.inFlightCount, 1)
                XCTAssertEqual(rendered, 0, "Invalidation must precede rendered publication")
                XCTAssertEqual(completed, 0)
                switch invalidation {
                case .epoch: pipeline.beginEpoch()
                case .suspend: pipeline.setActive(false)
                case .retire: pipeline.retire()
                }
            }
            pipeline.onRendered = { _ in rendered += 1 }
            pipeline.onComplete = { _ in completed += 1 }
            pipeline.publicationHoldForTesting = {
                await withCheckedContinuation { lease = $0; held.fulfill() }
            }
            pipeline.submit(frame)
            await fulfillment(of: [held], timeout: 5)
            XCTAssertEqual(boundaries, 1)
            XCTAssertEqual(pipeline.diagnostics.gpuCompletedFrames, 1, "Exercise actual GPU work, not task-entry rejection")
            XCTAssertEqual(rendered, 0, "Post-GPU currency guard must suppress \(invalidation) publication")
            XCTAssertEqual(completed, 0)
            XCTAssertEqual(pipeline.inFlightCount, 1, "Invalidation must not release a held presentation lease")
            XCTAssertFalse(pipeline.isIdle)
            XCTAssertEqual(pipeline.diagnostics.observedCompletions, 0)
            XCTAssertEqual(pipeline.resourceReleases, releases)
            XCTAssertGreaterThan(pipeline.cacheMetrics.retainedTextureBytes, 0)

            try XCTUnwrap(lease).resume()
            lease = nil
            await pipeline.waitForIdle()
            XCTAssertEqual(rendered, 0)
            XCTAssertEqual(completed, 0, "Invalidated presentation must not publish success")
            XCTAssertEqual(pipeline.diagnostics.observedCompletions, 1)
            XCTAssertEqual(pipeline.diagnostics.obsoleteCompletions, 1)
            XCTAssertEqual(pipeline.diagnostics.currentCompletions, 0)
            XCTAssertEqual(pipeline.diagnostics.failedFrames, 0)
            XCTAssertEqual(pipeline.diagnostics.staleFrames, 0, "Committed work must drain, not exit on cancellation")
            XCTAssertTrue(pipeline.isIdle)
            XCTAssertEqual(pipeline.inFlightCount, 0)
            XCTAssertEqual(pipeline.pendingCount, 0)
            if invalidation != .epoch {
                XCTAssertEqual(pipeline.resourceReleases, releases + 1)
                XCTAssertEqual(pipeline.cacheMetrics.retainedTextureBytes, 0)
            }
        }
    }

    func testInvalidatedWorkNeverPublishesRenderedCallback() async throws {
        let frame = try await frame(text: "invalidated before task entry")
        for retire in [false, true] {
            let pipeline = try offscreenPipeline()
            defer { pipeline.retire() }
            var rendered = 0
            pipeline.onRendered = { _ in rendered += 1 }
            pipeline.publicationHoldForTesting = {
                XCTFail("Invalidated work must not reach presentation")
            }
            pipeline.submit(frame)
            // No yield: invalidate before preparation/GPU submission can start.
            if retire { pipeline.retire() }
            else { pipeline.beginEpoch() }
            await pipeline.waitForIdle()
            XCTAssertEqual(rendered, 0)
            XCTAssertEqual(pipeline.diagnostics.gpuCompletedFrames, 0)
            XCTAssertEqual(pipeline.diagnostics.currentCompletions, 0)
        }
    }

    /// Regression: a failed current frame left an idle screen stale because
    /// the scheduler rejects resubmitting the same revision and presentation.
    func testFailedCurrentFrameRetriesOnceThenStops() async throws {
        let frame = try await frame(text: "retry")
        let pipeline = try VTMetalFramePipeline(font: .monospacedSystemFont(ofSize: 12, weight: .regular))
        defer { pipeline.retire() }
        var completions = 0
        var requests = 0
        pipeline.onComplete = { _ in completions += 1 }
        pipeline.onNeedsFrame = { [weak pipeline] in
            requests += 1
            pipeline?.submit(frame)
        }

        // Transient: the first attempt fails, the single retry succeeds.
        pipeline.retainedTextureBytesOverrideForTesting = Int.max
        pipeline.onFailure = { [weak pipeline] _ in pipeline?.retainedTextureBytesOverrideForTesting = nil }
        pipeline.submit(frame)
        await pipeline.waitForIdle()
        XCTAssertEqual(pipeline.failedFrames, 1)
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(completions, 1, "The retry must repaint the idle screen")

        // Persistent: one retry, then no idle render loop.
        pipeline.onFailure = nil
        pipeline.retainedTextureBytesOverrideForTesting = Int.max
        pipeline.beginEpoch()
        pipeline.submit(frame)
        await pipeline.waitForIdle()
        XCTAssertEqual(pipeline.failedFrames, 3)
        XCTAssertEqual(requests, 2, "Repeated failures cannot create an idle render loop")
        XCTAssertEqual(completions, 1)
    }

    func testRendererFacadePreservesLayerAcrossNormalSuspension() async throws {
        let frame = try await frame(text: "facade")
        let renderer = try VTMetalRenderer(font: .monospacedSystemFont(ofSize: 12, weight: .regular))
        defer { renderer.retire() }
        renderer.setActive(true)
        let old = renderer.presentationLayer
        let resumed = expectation(description: "Idle activation requests a frame on the existing layer")
        renderer.onNeedsFrame = { [weak renderer] in
            XCTAssertTrue(renderer?.presentationLayer === old)
            XCTAssertEqual(renderer?.inFlightCount, 0)
            XCTAssertEqual(renderer?.pendingCount, 0)
            resumed.fulfill()
        }
        renderer.submit(frame, presentation: .init())
        renderer.setActive(false)
        renderer.setActive(true)
        XCTAssertTrue(renderer.presentationLayer === old)
        await fulfillment(of: [resumed], timeout: 5)
        XCTAssertTrue(renderer.presentationLayer === old)
    }

    func testRetiredRendererFacadeNeverPublishesCompletion() async throws {
        let frame = try await frame(text: "retired")
        let renderer = try VTMetalRenderer(font: .monospacedSystemFont(ofSize: 12, weight: .regular))
        let pipeline = renderer.pipelineForTesting
        let held = expectation(description: "IOSurface publication held")
        var lease: CheckedContinuation<Void, Never>?
        defer { renderer.retire(); lease?.resume() }
        var rendered = 0
        var completions = 0
        renderer.onRendered = { _ in rendered += 1 }
        renderer.onComplete = { _ in completions += 1 }
        // Hold the frame after GPU completion, just before it would publish,
        // so only retire() (not an epoch change) can suppress the completion.
        pipeline.publicationHoldForTesting = {
            await withCheckedContinuation { lease = $0; held.fulfill() }
        }
        renderer.setActive(true)
        let layer = renderer.presentationLayer
        renderer.submit(frame, presentation: .init())
        await fulfillment(of: [held], timeout: 5)
        XCTAssertEqual(rendered, 1, "The frame reached GPU completion and would otherwise publish")
        XCTAssertEqual(pipeline.inFlightCount, 1)
        XCTAssertEqual(pipeline.diagnostics.presentationPublications, 0)
        renderer.retire()
        try XCTUnwrap(lease).resume()
        lease = nil
        await pipeline.waitForIdle()
        XCTAssertEqual(renderer.inFlightCount, 0)
        XCTAssertTrue(renderer.presentationLayer === layer, "Retirement must not allocate a replacement")
        XCTAssertNil(layer.contents)
        XCTAssertEqual(completions, 0)
        XCTAssertEqual(pipeline.diagnostics.presentationPublications, 0)
    }

    func testScrollRefreshDemandExpiresWithoutNewLocalInput() throws {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw XCTSkip("Requires an attached UIWindowScene")
        }
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let controller = UIViewController()
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true }
        let center = NotificationCenter()
        let time = Mutex(10.0)
        let coordinator = VTScrollRefreshCoordinator(scene: scene, notifications: center,
            conditions: { .init(maximumFramesPerSecond: 120, lowPower: false, thermalState: .nominal) },
            now: { time.withLock { $0 } })
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        center.post(name: UIScene.didActivateNotification, object: scene)
        let participant = coordinator.makeParticipant(host: controller.view)
        XCTAssertFalse(coordinator.isRunning)
        participant.pulse()
        XCTAssertTrue(coordinator.isRunning)
        time.withLock { $0 += VTScrollRefreshCoordinator.idleTail + 0.01 }
        coordinator.reconcile()
        XCTAssertFalse(coordinator.isRunning, "A held interaction cannot create an always-on display link")
        XCTAssertEqual(coordinator.starts, 1)
        participant.pulse()
        XCTAssertEqual(coordinator.starts, 2)
        participant.cancel()
        XCTAssertFalse(coordinator.isRunning)
    }

    func testScrollRefreshDriverDoesNotStartWithoutPresentedLocalInput() {
        let driver = VTScrollRefreshDriver()
        XCTAssertFalse(driver.isRunning)
        driver.visibilityChanged()
        XCTAssertFalse(driver.isRunning)
        driver.pulse(host: UIView())
        XCTAssertFalse(driver.isRunning)
        driver.cancel()
        XCTAssertFalse(driver.isRunning)
    }

    func testMetalOffscreenRendersHelloFrame() async throws {
        let frame = try await frame(text: "hello")
        let font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let renderer = try VTMetalRasterizer()
        let timing = try await renderer.render(frame, font: font)
        XCTAssertGreaterThanOrEqual(timing.renderPasses, 1)
        let texture = try XCTUnwrap(renderer.output)
        XCTAssertGreaterThan(texture.width, 0)
        XCTAssertGreaterThan(texture.height, 0)
    }
}

@MainActor
final class VTScrollRefreshDiagnosticsTests: XCTestCase {
    func testProductionRefreshObserverCannotCreateOrExtendDemandAndSeparatesRestarts() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = UIViewController()
        window.isHidden = false
        defer { window.isHidden = true }
        let center = NotificationCenter()
        var time = 10.0
        let coordinator = VTScrollRefreshCoordinator(scene: scene, notifications: center,
            conditions: { .init(maximumFramesPerSecond: 120, lowPower: false, thermalState: .nominal) },
            now: { time })
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        center.post(name: UIScene.didActivateNotification, object: scene)
        let participant = coordinator.makeParticipant(host: try XCTUnwrap(window.rootViewController?.view))
        var samples: [VTScrollRefreshSample] = []
        participant.onRefreshForDiagnostics = { samples.append($0) }
        coordinator.didRefresh(timestamp: 10, targetTimestamp: 10 + 1 / 120)
        XCTAssertFalse(coordinator.isRunning)
        XCTAssertTrue(samples.isEmpty)
        participant.pulse()
        coordinator.displayLinkForTesting?.isPaused = true
        XCTAssertEqual(coordinator.requestedRate, 120)
        time += 0.01
        coordinator.didRefresh(timestamp: time, targetTimestamp: time + 1 / 120)
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].timestamp, time)
        XCTAssertEqual(samples[0].callbackTime, time)
        XCTAssertEqual(samples[0].targetTimestamp, time + 1 / 120)
        time = 10 + VTScrollRefreshCoordinator.idleTail + 0.01
        coordinator.didRefresh(timestamp: time, targetTimestamp: time + 1 / 120)
        XCTAssertFalse(coordinator.isRunning, "Observation cannot extend the production idle tail")
        XCTAssertEqual(samples.count, 1)
        participant.pulse()
        coordinator.displayLinkForTesting?.isPaused = true
        coordinator.didRefresh(timestamp: time, targetTimestamp: time + 1 / 120)
        XCTAssertEqual(samples.count, 2)
        XCTAssertNotEqual(samples[0].generation, samples[1].generation)
        participant.cancel()
        coordinator.didRefresh(timestamp: time, targetTimestamp: time + 1 / 120)
        XCTAssertEqual(samples.count, 2)
        XCTAssertFalse(coordinator.isRunning)
    }

    func testDriverDiagnosticRegistrationDoesNotStartRefreshWithoutPresentedInput() {
        let driver = VTScrollRefreshDriver()
        driver.onRefreshForDiagnostics = { _ in XCTFail("No local presented input") }
        XCTAssertFalse(driver.isRunning)
        driver.pulse(host: UIView())
        driver.visibilityChanged()
        XCTAssertFalse(driver.isRunning)
        driver.onRefreshForDiagnostics = nil
    }
}
