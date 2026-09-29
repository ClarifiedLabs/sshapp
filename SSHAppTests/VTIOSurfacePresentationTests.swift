import IOSurface
import Metal
import UIKit
import XCTest
@testable import GhosttyVT

@MainActor
final class VTIOSurfacePresentationTests: XCTestCase {
    private let font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)

    @MainActor
    private final class LeaseResult {
        var lease: VTIOSurfacePresenter.Lease?
    }

    func testOrdinaryRendererUsesIOSurfaceWithoutLaunchConfiguration() throws {
        let renderer = try VTMetalRenderer(font: font)
        defer { renderer.retire() }
        XCTAssertFalse(renderer.presentationLayer is CAMetalLayer)
    }

    func testTargetCreatesBGRAIOSurfaceTextureWithExactPixelSize() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let target = try VTMetalOutputTarget.ioSurface(device: device, width: 321, height: 123)
        XCTAssertTrue(target.isIOSurfaceBacked)
        XCTAssertEqual(target.width, 321)
        XCTAssertEqual(target.height, 123)
        XCTAssertEqual(target.texture.width, 321)
        XCTAssertEqual(target.texture.height, 123)
        XCTAssertEqual(target.texture.pixelFormat, .bgra8Unorm)
        XCTAssertEqual(target.texture.storageMode, .shared)
        XCTAssertTrue(target.texture.usage.contains(.renderTarget))
        let surface = try XCTUnwrap(target.surface)
        XCTAssertEqual(target.retainedBytes,
                       max(target.texture.allocatedSize, surface.allocationSize, 321 * 123 * 4))
        XCTAssertEqual(surface.width, 321)
        XCTAssertEqual(surface.height, 123)
        XCTAssertEqual(surface.pixelFormat, UInt32(0x4247_5241))
    }

    func testDirectIOSurfaceOutputMatchesRGBAReferencePixels() async throws {
        let frame = try await makeFrame(text: "\u{1B}[?25l\u{1B}[48;2;12;40;90m\u{1B}[38;2;255;120;20mDirect 🙂")
        let reference = try VTMetalRasterizer()
        defer { reference.releaseResources() }
        _ = try await reference.render(frame, font: font)
        let rgba = try read(reference.output)

        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let direct = try VTMetalRasterizer(queue: queue, usesExternalOutput: true)
        defer { direct.releaseResources() }
        let width = Int((frame.layout.viewportWidth * frame.layout.scale).rounded())
        let height = Int((frame.layout.viewportHeight * frame.layout.scale).rounded())
        let target = try VTMetalOutputTarget.ioSurface(device: device, width: width, height: height)
        _ = try await direct.render(frame, font: font, outputTarget: target)
        var bgra = try read(target.texture)
        for pixel in 0..<(bgra.count / 4) { bgra.swapAt(pixel * 4, pixel * 4 + 2) }
        XCTAssertEqual(bgra, rgba)

        // Exercise the rare CoreText whole-frame fallback on BGRA output too.
        direct.forceCPUFallbackForTesting = true
        let fallback = try VTMetalOutputTarget.ioSurface(device: device, width: width, height: height)
        _ = try await direct.render(frame, font: font, outputTarget: fallback)
        var fallbackBytes = try read(fallback.texture)
        for pixel in 0..<(fallbackBytes.count / 4) {
            fallbackBytes.swapAt(pixel * 4, pixel * 4 + 2)
        }
        XCTAssertEqual(fallbackBytes, try cpuPixels(frame))
        XCTAssertNil(direct.output, "Presentation owns direct targets; raster caches must not retain or charge them")
        XCTAssertEqual(direct.outputTextureBytes, 0)
    }

    func testCurrentGPUCompletionPublishesAfterRenderedCallbackWithoutFakeTimestamp() async throws {
        let frame = try await makeFrame(text: "published")
        let renderer = try VTMetalRenderer(font: font)
        let pipeline = renderer.pipelineForTesting
        defer { renderer.retire() }
        var rendered = 0
        var completed = 0
        renderer.onRendered = { _ in
            rendered += 1
            XCTAssertNil(renderer.presentationLayer.contents, "GPU callback must precede IOSurface publication")
        }
        renderer.onComplete = { _ in
            completed += 1
            XCTAssertTrue(renderer.presentationLayer.contents is IOSurface)
        }
        renderer.setActive(true)
        renderer.submit(frame, presentation: .init())
        await pipeline.waitForIdle()

        XCTAssertEqual(rendered, 1)
        XCTAssertEqual(completed, 1)
        XCTAssertEqual(renderer.diagnostics.presentationRequests, 1)
        XCTAssertEqual(renderer.diagnostics.presentationPublications, 1)
        XCTAssertEqual(renderer.diagnostics.presentationTargetCount, 1)
        XCTAssertEqual(renderer.diagnostics.presentationLeasedTargets, 0)
        XCTAssertGreaterThan(renderer.diagnostics.presentationTargetBytes, 0)
        XCTAssertEqual(renderer.diagnostics.presentationTargetAcquisitionAttempts, 1)
        XCTAssertEqual(renderer.diagnostics.presentationTargetAcquisitionSuccesses, 1)
        XCTAssertEqual(renderer.diagnostics.presentationTargetAcquisitionStalls, 0)
        XCTAssertEqual(renderer.diagnostics.presentationTargetAcquisitionTimeouts, 0)
        XCTAssertEqual(renderer.diagnostics.presentationTargetAcquisitionCancellations, 0)
        XCTAssertEqual(renderer.diagnostics.presentationTargetAcquisitionFailures, 0)
        XCTAssertEqual(renderer.diagnostics.presentationTargetPoolWaitTotalSeconds, 0)
        XCTAssertEqual(renderer.diagnostics.presentationTargetPoolWaitMaxSeconds, 0)
    }

    func testReentrantEpochChangeAfterRenderedDoesNotPublishSurface() async throws {
        let frame = try await makeFrame(text: "obsolete publication")
        let renderer = try VTMetalRenderer(font: font)
        let pipeline = renderer.pipelineForTesting
        defer { renderer.retire() }
        var completed = 0
        renderer.onRendered = { _ in pipeline.beginEpoch() }
        renderer.onComplete = { _ in completed += 1 }
        renderer.setActive(true)
        renderer.submit(frame, presentation: .init())
        await pipeline.waitForIdle()

        XCTAssertNil(renderer.presentationLayer.contents)
        XCTAssertEqual(completed, 0)
        XCTAssertEqual(renderer.diagnostics.presentationPublications, 0)
        XCTAssertEqual(renderer.diagnostics.presentationDiscardedPublications, 1)
        XCTAssertEqual(renderer.diagnostics.obsoleteCompletions, 1)
        XCTAssertEqual(renderer.diagnostics.failedFrames, 0)
    }

    func testTargetPoolWarmsToThreeThenReusesWithoutGrowth() async throws {
        let frame = try await makeFrame(text: "bounded pool")
        let renderer = try VTMetalRenderer(font: font)
        let pipeline = renderer.pipelineForTesting
        defer { renderer.retire() }
        renderer.setActive(true)
        for index in 0..<12 {
            var presentation = VTPresentationState()
            presentation.blinkVisible = index.isMultiple(of: 2)
            renderer.submit(frame, presentation: presentation)
            await pipeline.waitForIdle()
        }
        let diagnostics = renderer.diagnostics
        XCTAssertEqual(diagnostics.presentationPublications, 12)
        XCTAssertEqual(diagnostics.presentationTargetCreations, 3)
        XCTAssertEqual(diagnostics.presentationTargetCount, 3)
        XCTAssertEqual(diagnostics.presentationAvailableTargets, 2)
        XCTAssertEqual(diagnostics.presentationLeasedTargets, 0)
        XCTAssertTrue(renderer.presentationLayer.contents is IOSurface)
    }

    func testPoolDoesNotLeaseAnIOSurfaceStillInUse() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let presenter = VTIOSurfacePresenter(device: device)
        let layout = try VTLayout(generation: 1, width: 200, height: 100,
                                  cellWidth: 10, cellHeight: 20, scale: 2, padding: 0)
        let first = try await presenter.acquire(layout: layout)
        try presenter.publish(first, layout: layout)
        let second = try await presenter.acquire(layout: layout)
        try presenter.publish(second, layout: layout)
        let third = try await presenter.acquire(layout: layout)
        try presenter.publish(third, layout: layout)
        // first and second are available; mark first compositor-owned and verify
        // acquisition skips it rather than rendering into an in-use surface.
        let firstSurface = try XCTUnwrap(first.target.surface)
        firstSurface.incrementUseCount()
        defer { firstSurface.decrementUseCount() }
        let next = try await presenter.acquire(layout: layout)
        defer { presenter.discard(next) }
        XCTAssertFalse(next.target === first.target)
        XCTAssertTrue(next.target === second.target)
    }

    func testImmediateAcquisitionsDoNotCountAllocationAsWaitAndSurviveTrimAndClear() async throws {
        let presenter = VTIOSurfacePresenter(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let layout = try poolLayout()
        for _ in 0..<4 {
            let lease = try await presenter.acquire(layout: layout)
            presenter.discard(lease)
        }
        let before = presenter.metrics
        XCTAssertEqual(before.targetCreations, 3)
        XCTAssertEqual(before.acquisitionAttempts, 4)
        XCTAssertEqual(before.acquisitionSuccesses, 4)
        XCTAssertEqual(before.acquisitionStalls, 0)
        XCTAssertEqual(before.poolWaitTotalSeconds, 0)
        XCTAssertEqual(before.poolWaitMaxSeconds, 0)
        presenter.trimAvailableTargets()
        presenter.clear()
        XCTAssertEqual(presenter.metrics.targetCount, 0)
        XCTAssertEqual(presenter.metrics.acquisitionAttempts, before.acquisitionAttempts)
        XCTAssertEqual(presenter.metrics.acquisitionSuccesses, before.acquisitionSuccesses)
    }

    func testFullLeasedPoolAccumulatesWaitAcrossReleaseAndCancellation() async throws {
        let presenter = VTIOSurfacePresenter(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let layout = try poolLayout()
        let leases = try await fillPool(presenter, layout: layout)
        defer { leases.forEach { presenter.discard($0) } }
        let result = LeaseResult()
        let waiter = Task<Void, Error> { @MainActor in
            result.lease = try await presenter.acquire(layout: layout)
        }
        defer { waiter.cancel() }
        try await waitForStall(presenter)
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(presenter.metrics.acquisitionAttempts, 4)
        XCTAssertEqual(presenter.metrics.acquisitionSuccesses, 3)
        XCTAssertEqual(presenter.metrics.acquisitionStalls, 1, "Not one stall per polling sleep")
        XCTAssertEqual(presenter.metrics.poolWaitTotalSeconds, 0, "Durations publish on acquire exit")
        presenter.discard(leases[0])
        try await waiter.value
        let acquired = try XCTUnwrap(result.lease)
        defer { presenter.discard(acquired) }
        XCTAssertTrue(acquired.target === leases[0].target)
        let metrics = presenter.metrics
        XCTAssertEqual(metrics.acquisitionSuccesses, 4)
        XCTAssertEqual(metrics.acquisitionStalls, 1)
        XCTAssertEqual(metrics.acquisitionTimeouts, 0)
        XCTAssertEqual(metrics.acquisitionCancellations, 0)
        XCTAssertEqual(metrics.acquisitionFailures, 0)
        XCTAssertGreaterThan(metrics.poolWaitTotalSeconds, 0)
        XCTAssertEqual(metrics.poolWaitMaxSeconds, metrics.poolWaitTotalSeconds)

        // The returned lease fills the pool again. A second wait must accumulate,
        // including cancellation, while max remains the longest single acquire.
        let cancelled = Task<Void, Error> { @MainActor in
            let lease = try await presenter.acquire(layout: layout)
            presenter.discard(lease)
        }
        defer { cancelled.cancel() }
        try await waitForStall(presenter, expected: 2)
        try await Task.sleep(for: .milliseconds(10))
        cancelled.cancel()
        do {
            try await cancelled.value
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
        let cumulative = presenter.metrics
        XCTAssertEqual(cumulative.acquisitionAttempts, 5)
        XCTAssertEqual(cumulative.acquisitionSuccesses, 4)
        XCTAssertEqual(cumulative.acquisitionStalls, 2)
        XCTAssertEqual(cumulative.acquisitionCancellations, 1)
        XCTAssertEqual(cumulative.acquisitionTimeouts, 0)
        XCTAssertEqual(cumulative.acquisitionFailures, 0)
        XCTAssertGreaterThan(cumulative.poolWaitTotalSeconds, metrics.poolWaitTotalSeconds)
        let secondWait = cumulative.poolWaitTotalSeconds - metrics.poolWaitTotalSeconds
        XCTAssertEqual(cumulative.poolWaitMaxSeconds, max(metrics.poolWaitMaxSeconds, secondWait), accuracy: 0.000001)
    }

    func testFullCompositorInUsePoolRecordsReleaseAndCancellationWaits() async throws {
        // Explicit use counts exercise the real isInUse check without relying on
        // compositor timing or holding a continuation that can hang on assertion.
        for cancel in [false, true] {
            let presenter = VTIOSurfacePresenter(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
            let layout = try poolLayout()
            let leases = try await fillPool(presenter, layout: layout)
            let surfaces = try leases.map { try XCTUnwrap($0.target.surface) }
            surfaces.forEach { $0.incrementUseCount() }
            var firstReleased = false
            defer {
                for (index, surface) in surfaces.enumerated() where index != 0 || !firstReleased {
                    surface.decrementUseCount()
                }
                leases.forEach { presenter.discard($0) }
            }
            leases.forEach { presenter.discard($0) }
            XCTAssertTrue(surfaces.allSatisfy(\.isInUse))
            let waiter = Task<Void, Error> { @MainActor in
                let acquired = try await presenter.acquire(layout: layout)
                XCTAssertTrue(acquired.target === leases[0].target)
                presenter.discard(acquired)
            }
            defer { waiter.cancel() }
            try await waitForStall(presenter)
            try await Task.sleep(for: .milliseconds(10))
            if cancel {
                waiter.cancel()
                do {
                    try await waiter.value
                    XCTFail("A cancelled full-pool acquire must throw")
                } catch is CancellationError { }
            } else {
                surfaces[0].decrementUseCount()
                firstReleased = true
                try await waiter.value
            }
            let metrics = presenter.metrics
            XCTAssertEqual(metrics.acquisitionAttempts, 4)
            XCTAssertEqual(metrics.acquisitionSuccesses, cancel ? 3 : 4)
            XCTAssertEqual(metrics.acquisitionStalls, 1)
            XCTAssertEqual(metrics.acquisitionCancellations, cancel ? 1 : 0)
            XCTAssertEqual(metrics.acquisitionTimeouts, 0)
            XCTAssertEqual(metrics.acquisitionFailures, 0)
            XCTAssertGreaterThan(metrics.poolWaitTotalSeconds, 0)
            XCTAssertEqual(metrics.poolWaitMaxSeconds, metrics.poolWaitTotalSeconds)
            presenter.trimAvailableTargets()
            presenter.clear()
            XCTAssertEqual(presenter.metrics.acquisitionStalls, metrics.acquisitionStalls)
            XCTAssertEqual(presenter.metrics.acquisitionCancellations, metrics.acquisitionCancellations)
            XCTAssertEqual(presenter.metrics.poolWaitTotalSeconds, metrics.poolWaitTotalSeconds)
            XCTAssertEqual(presenter.metrics.poolWaitMaxSeconds, metrics.poolWaitMaxSeconds)
        }
    }

    func testCancellationBeforeAcquireDoesNotCountPoolWait() async throws {
        let presenter = VTIOSurfacePresenter(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let layout = try poolLayout()
        let waiter = Task<Void, Error> { @MainActor in
            let lease = try await presenter.acquire(layout: layout)
            presenter.discard(lease)
        }
        waiter.cancel() // Same main-actor turn, before the task can enter acquire.
        do {
            try await waiter.value
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
        XCTAssertEqual(presenter.metrics.acquisitionAttempts, 1)
        XCTAssertEqual(presenter.metrics.acquisitionSuccesses, 0)
        XCTAssertEqual(presenter.metrics.acquisitionCancellations, 1)
        XCTAssertEqual(presenter.metrics.acquisitionStalls, 0)
        XCTAssertEqual(presenter.metrics.acquisitionFailures, 0)
        XCTAssertEqual(presenter.metrics.poolWaitTotalSeconds, 0)
        XCTAssertEqual(presenter.metrics.poolWaitMaxSeconds, 0)
    }

    func testFullPoolUsesExistingTwoSecondTimeoutAndRecordsWait() async throws {
        let presenter = VTIOSurfacePresenter(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let layout = try poolLayout()
        let leases = try await fillPool(presenter, layout: layout)
        defer { leases.forEach { presenter.discard($0) } }
        let started = ProcessInfo.processInfo.systemUptime
        do {
            let unexpected = try await presenter.acquire(layout: layout)
            presenter.discard(unexpected)
            XCTFail("A permanently full pool must time out")
        } catch VTIOSurfacePresenter.Failure.unavailable { }
        XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - started, 2)
        let metrics = presenter.metrics
        XCTAssertEqual(metrics.acquisitionAttempts, 4)
        XCTAssertEqual(metrics.acquisitionSuccesses, 3)
        XCTAssertEqual(metrics.acquisitionStalls, 1)
        XCTAssertEqual(metrics.acquisitionTimeouts, 1)
        XCTAssertEqual(metrics.acquisitionCancellations, 0)
        XCTAssertEqual(metrics.acquisitionFailures, 0)
        XCTAssertGreaterThan(metrics.poolWaitTotalSeconds, 0)
        XCTAssertLessThanOrEqual(metrics.poolWaitTotalSeconds, ProcessInfo.processInfo.systemUptime - started)
        XCTAssertEqual(metrics.poolWaitMaxSeconds, metrics.poolWaitTotalSeconds)
    }

    func testInvalidTargetSizeCountsOtherFailureNotTimeoutOrWait() async throws {
        let presenter = VTIOSurfacePresenter(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(poolLayout())) as? [String: Any])
        object["viewportWidth"] = 0
        let invalid = try JSONDecoder().decode(VTLayout.self, from: JSONSerialization.data(withJSONObject: object))
        do {
            let unexpected = try await presenter.acquire(layout: invalid)
            presenter.discard(unexpected)
            XCTFail("Expected invalid target size")
        } catch VTIOSurfacePresenter.Failure.unavailable { }
        XCTAssertEqual(presenter.metrics.acquisitionAttempts, 1)
        XCTAssertEqual(presenter.metrics.acquisitionSuccesses, 0)
        XCTAssertEqual(presenter.metrics.acquisitionFailures, 1)
        XCTAssertEqual(presenter.metrics.acquisitionTimeouts, 0)
        XCTAssertEqual(presenter.metrics.acquisitionCancellations, 0)
        XCTAssertEqual(presenter.metrics.acquisitionStalls, 0)
        XCTAssertEqual(presenter.metrics.poolWaitTotalSeconds, 0)
        XCTAssertEqual(presenter.metrics.poolWaitMaxSeconds, 0)
    }

    private func poolLayout() throws -> VTLayout {
        try VTLayout(generation: 1, width: 200, height: 100,
                     cellWidth: 10, cellHeight: 20, scale: 2, padding: 0)
    }

    private func fillPool(_ presenter: VTIOSurfacePresenter, layout: VTLayout) async throws -> [VTIOSurfacePresenter.Lease] {
        var leases: [VTIOSurfacePresenter.Lease] = []
        for _ in 0..<3 { leases.append(try await presenter.acquire(layout: layout)) }
        return leases
    }

    private func waitForStall(_ presenter: VTIOSurfacePresenter, expected: Int = 1) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while presenter.metrics.acquisitionStalls < expected, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(presenter.metrics.acquisitionStalls, expected)
    }

    func testResizeReplacesSurfaceAndKeepsExactLayerGeometry() async throws {
        let first = try await makeFrame(text: "first", width: 240, height: 120, generation: 1)
        let second = try await makeFrame(text: "second", width: 360, height: 180, generation: 2)
        let renderer = try VTMetalRenderer(font: font)
        let pipeline = renderer.pipelineForTesting
        defer { renderer.retire() }
        renderer.setActive(true)
        renderer.submit(first, presentation: .init())
        await pipeline.waitForIdle()
        let old = try XCTUnwrap(renderer.presentationLayer.contents as? IOSurface)

        renderer.beginEpoch(font: font)
        renderer.submit(second, presentation: .init())
        await pipeline.waitForIdle()
        let fresh = try XCTUnwrap(renderer.presentationLayer.contents as? IOSurface)
        XCTAssertFalse(old === fresh)
        XCTAssertEqual(fresh.width, Int(second.layout.viewportWidth * second.layout.scale))
        XCTAssertEqual(fresh.height, Int(second.layout.viewportHeight * second.layout.scale))
        XCTAssertEqual(renderer.presentationLayer.frame.size,
                       CGSize(width: second.layout.viewportWidth, height: second.layout.viewportHeight))
        XCTAssertEqual(renderer.presentationLayer.contentsScale, second.layout.scale)
        XCTAssertEqual(renderer.diagnostics.presentationPublications, 2)
    }

    func testRetireWhilePublicationHeldNeverPublishesAndClearsTargets() async throws {
        let frame = try await makeFrame(text: "retire publication")
        let renderer = try VTMetalRenderer(font: font)
        let pipeline = renderer.pipelineForTesting
        let entered = expectation(description: "GPU complete, publication held")
        var continuation: CheckedContinuation<Void, Never>?
        var completed = 0
        renderer.onComplete = { _ in completed += 1 }
        pipeline.publicationHoldForTesting = {
            await withCheckedContinuation {
                continuation = $0
                entered.fulfill()
            }
        }
        renderer.setActive(true)
        renderer.submit(frame, presentation: .init())
        await fulfillment(of: [entered], timeout: 5)
        XCTAssertEqual(pipeline.inFlightCount, 1)
        XCTAssertNil(renderer.presentationLayer.contents)

        renderer.retire()
        try XCTUnwrap(continuation).resume()
        continuation = nil
        await pipeline.waitForIdle()
        XCTAssertEqual(completed, 0)
        XCTAssertNil(renderer.presentationLayer.contents)
        XCTAssertEqual(renderer.diagnostics.presentationTargetCount, 0)
        XCTAssertEqual(renderer.diagnostics.presentationLeasedTargets, 0)
        XCTAssertEqual(renderer.diagnostics.presentationPublications, 0)
        XCTAssertEqual(renderer.diagnostics.presentationTargetAcquisitionAttempts, 1)
        XCTAssertEqual(renderer.diagnostics.presentationTargetAcquisitionSuccesses, 1)
        XCTAssertEqual(renderer.diagnostics.presentationTargetAcquisitionStalls, 0)
    }

    func testPressureTrimWhileTwoTargetsAreLeasedDoesNotRegrowPoolOnDrain() async throws {
        let frame = try await makeFrame(text: "trim in flight")
        let renderer = try VTMetalRenderer(font: font)
        let pipeline = renderer.pipelineForTesting
        defer { renderer.retire() }
        let firstEntered = expectation(description: "first publication held")
        let secondEntered = expectation(description: "second publication held")
        var continuations: [CheckedContinuation<Void, Never>] = []
        pipeline.publicationHoldForTesting = {
            await withCheckedContinuation {
                continuations.append($0)
                if continuations.count == 1 { firstEntered.fulfill() }
                else { secondEntered.fulfill() }
            }
        }
        renderer.setActive(true)
        var firstPresentation = VTPresentationState()
        firstPresentation.blinkVisible = false
        renderer.submit(frame, presentation: firstPresentation)
        await fulfillment(of: [firstEntered], timeout: 5)
        renderer.submit(frame, presentation: .init())
        await fulfillment(of: [secondEntered], timeout: 5)
        XCTAssertEqual(renderer.diagnostics.presentationLeasedTargets, 2)
        renderer.trimResources()
        XCTAssertEqual(renderer.diagnostics.presentationAvailableTargets, 0)
        let held = continuations
        continuations.removeAll()
        held.forEach { $0.resume() }
        await pipeline.waitForIdle()
        XCTAssertEqual(renderer.diagnostics.presentationTargetCount, 1)
        XCTAssertEqual(renderer.diagnostics.presentationAvailableTargets, 0)
        XCTAssertEqual(renderer.diagnostics.presentationLeasedTargets, 0)
        XCTAssertTrue(renderer.presentationLayer.contents is IOSurface)
    }

    func testTrimDropsOnlyAvailableTargetsAndKeepsDisplayedSurface() async throws {
        let frame = try await makeFrame(text: "trim")
        let renderer = try VTMetalRenderer(font: font)
        let pipeline = renderer.pipelineForTesting
        defer { renderer.retire() }
        renderer.setActive(true)
        for index in 0..<3 {
            var presentation = VTPresentationState()
            presentation.blinkVisible = index.isMultiple(of: 2)
            renderer.submit(frame, presentation: presentation)
            await pipeline.waitForIdle()
        }
        let displayed = try XCTUnwrap(renderer.presentationLayer.contents as? IOSurface)
        XCTAssertEqual(renderer.diagnostics.presentationTargetCount, 3)
        renderer.trimResources()
        XCTAssertTrue(renderer.presentationLayer.contents as? IOSurface === displayed)
        XCTAssertEqual(renderer.diagnostics.presentationTargetCount, 1)
        XCTAssertEqual(renderer.diagnostics.presentationAvailableTargets, 0)
        XCTAssertTrue(renderer.diagnostics.presentationTargetBytes > 0)
    }

    private func makeFrame(text: String, width: Double = 300, height: Double = 120,
                           generation: UInt64 = 1) async throws -> VTFrameValue {
        let layout = try VTLayout(generation: generation, width: width, height: height,
                                  cellWidth: 10, cellHeight: 20, scale: 2, padding: 0)
        let terminal = try VTTerminal(layout: layout)
        _ = try await terminal.ingest(Data(text.utf8))
        let frame = try await terminal.snapshot()
        _ = try await terminal.retire()
        return frame
    }

    private func cpuPixels(_ frame: VTFrameValue) throws -> [UInt8] {
        let width = Int(frame.layout.viewportWidth * frame.layout.scale)
        let height = Int(frame.layout.viewportHeight * frame.layout.scale)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: frame.layout.scale, y: -frame.layout.scale)
            VTCoreTextRenderer.draw(frame, font: font, context: context,
                bounds: CGRect(x: 0, y: 0, width: frame.layout.viewportWidth,
                               height: frame.layout.viewportHeight), cache: VTGlyphCache())
        }
        return bytes
    }

    private func read(_ texture: (any MTLTexture)?) throws -> [UInt8] {
        let texture = try XCTUnwrap(texture)
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        bytes.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * 4,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return bytes
    }
}
