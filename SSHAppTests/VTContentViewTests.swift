import QuartzCore
import UIKit
import XCTest
@testable import GhosttyTerminal
@testable import GhosttyVT

/// VT content view: measures its font, drives the session viewport, and
/// paints snapshots. Frame requests coalesce; bytes never do.
@MainActor
final class VTContentViewTests: XCTestCase {
    /// Synthetic app lifecycle events go to a private center, not the process.
    private var lifecycle: PrivateLifecycleNotifications!

    override func setUp() async throws {
        try await super.setUp()
        lifecycle = PrivateLifecycleNotifications()
    }

    private var windows: [(window: UIWindow, previousKeyWindow: UIWindow?)] = []

    override func tearDown() async throws {
        lifecycle.restore()
        for mounted in windows.reversed() {
            mounted.window.isHidden = true
            mounted.previousKeyWindow?.makeKey()
        }
        windows.removeAll()
        try await super.tearDown()
    }

    private func makeView(session suppliedSession: VTTerminalSession? = nil,
                          suppliedView: VTContentView? = nil,
                          configure: ((VTContentView) throws -> Void)? = nil) async throws -> VTContentView {
        var activeScene: UIWindowScene?
        try await waitUntil("active window scene") {
            activeScene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
            return activeScene != nil
        }
        let scene = try XCTUnwrap(activeScene)
        let view = suppliedView ?? VTContentView(frame: .zero)
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 480)
        view.forcedScale = 2
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        try configure?(view)
        let session = suppliedSession ?? VTTerminalSession(
            write: { _ in },
            resize: { _ in }
        )
        // A supplied view is already attached; preserve that observer across
        // delayed old-host deallocation rather than silently reinstalling it.
        if suppliedView == nil { view.attach(session) }
        // Device Metal completions require actual presentation in an active scene.
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.addSubview(view)
        windows.append((window, previousKeyWindow))
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        view.layoutIfNeeded()
        return view
    }

    func testMetalFailureEvidenceSurvivesRecoveryWithoutRetainingRenderer() throws {
        let view = VTContentView(frame: .zero)
        weak let renderer = try XCTUnwrap(view.metalRenderer)
        XCTAssertNil(view.metalFailureDescription)
        view.metalRenderer?.onFailure?(NSError(domain: "FailureEvidence", code: 42))
        XCTAssertNil(view.metalRenderer)
        XCTAssertNil(renderer)
        XCTAssertTrue(view.metalFailureDescription?.contains("FailureEvidence") == true)
        XCTAssertTrue(view.renderDiagnostics.contains("42"))
    }

    private func useCoreText(_ view: VTContentView) {
        view.metalRenderer?.onFailure?(NSError(domain: "VTContentViewTests", code: 1))
        XCTAssertNil(view.metalRenderer)
    }

    private func draw(_ view: UIView) -> UIImage {
        UIGraphicsImageRenderer(size: view.bounds.size).image { _ in view.draw(view.bounds) }
    }

    private actor DeliveryGate {
        var entered = false
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            entered = true
            await withCheckedContinuation { continuation = $0 }
        }
        func release() { continuation?.resume(); continuation = nil }
    }

    /// A FIFO barrier that observes this terminal only, without extracting a frame.
    private func cachedImageBytes(in session: VTTerminalSession) async throws -> Int {
        let query = try XCTUnwrap(session.enqueueInputQuery { terminal in
            await terminal.cachedSnapshotImageBytes
        })
        return try await query.value
    }

    private func snapshotRequestInFlight(in view: VTContentView) throws -> Bool {
        let storage = try XCTUnwrap(Mirror(reflecting: view).children.first {
            $0.label == "frameTask"
        })
        return storage.value as? Task<Void, Never> != nil
    }

    private func seedRetainedGraphics(in session: VTTerminalSession) async throws -> VTFrameValue {
        session.updateViewport(.init(width: 390, height: 480, cellWidth: 10, cellHeight: 20, scale: 2))
        session.receive(TerminalGraphicsMemoryWorkload(side: 2).payload(0))
        let snapshot = try XCTUnwrap(session.enqueueSnapshot())
        let frame = try await snapshot.value
        XCTAssertEqual(frame.graphics.placements.count, 2)
        let bytes = try await cachedImageBytes(in: session)
        XCTAssertEqual(bytes, 16)
        return frame
    }

    /// Inspect private scalar storage without adding a production diagnostic API.
    private func frameReadyTime(in view: VTContentView) throws -> Double? {
        let storage = try XCTUnwrap(Mirror(reflecting: view).children.first {
            $0.label == "acceptedFrameReadyTime"
        })
        return storage.value as? Double
    }

    func testFrameReadyTimeIsOptInPrecedesOnFrameAndSurvivesPresentationOnlyChanges() async throws {
        let view = try await makeView { view in
            view.terminalFocused = false
        }
        let pipeline = try XCTUnwrap(view.metalRenderer).pipelineForTesting
        defer { view.onFrame = nil; pipeline.onObservation = nil; view.detach() }
        try await waitUntil("initial render drained") {
            view.frameValue != nil && pipeline.isIdle && pipeline.diagnostics.currentCompletions > 0
        }
        XCTAssertFalse(view.recordsFrameReadyTimes)
        XCTAssertFalse(pipeline.recordsTimelines)
        XCTAssertNil(try frameReadyTime(in: view))
        var observedTimes: [Double?] = []
        pipeline.onObservation = { completion in
            observedTimes.append(completion.work.acceptedFrameReadyTime)
            XCTAssertNil(completion.timeline, "Ready-time recording does not enable pipeline timelines")
        }
        var completed = false
        view.requestFrame { _ in completed = true }
        try await waitUntil("default-off render") { completed && pipeline.isIdle }
        XCTAssertFalse(observedTimes.isEmpty)
        XCTAssertTrue(observedTimes.allSatisfy { $0 == nil })

        view.recordsFrameReadyTimes = true
        var callbackTime: Double?
        var callbackReadyTime: Double?
        view.onFrame = { [unowned self] _ in
            callbackTime = CACurrentMediaTime()
            callbackReadyTime = try? self.frameReadyTime(in: view)
            XCTAssertNotNil(callbackReadyTime, "Timestamp must already exist at semantic publication")
        }
        completed = false
        view.requestFrame { _ in completed = true }
        try await waitUntil("timestamped render") { completed && pipeline.isIdle }
        let ready = try XCTUnwrap(callbackReadyTime)
        XCTAssertLessThanOrEqual(ready, try XCTUnwrap(callbackTime))
        XCTAssertEqual(try XCTUnwrap(observedTimes.last), ready)
        XCTAssertEqual(try frameReadyTime(in: view), ready)
        view.onFrame = nil

        // Like blink, focus updates presentation without accepting another frame.
        let acceptedFrame = view.frameValue
        let observations = observedTimes.count
        view.terminalFocused = true
        await pipeline.waitForIdle()
        XCTAssertGreaterThan(observedTimes.count, observations)
        XCTAssertEqual(view.frameValue, acceptedFrame)
        XCTAssertEqual(try XCTUnwrap(observedTimes.last), ready, "Redraw must carry the original acceptance time")

        view.recordsFrameReadyTimes = false
        XCTAssertNil(try frameReadyTime(in: view))
        view.terminalFocused = false
        await pipeline.waitForIdle()
        XCTAssertNil(try XCTUnwrap(observedTimes.last))
        view.recordsFrameReadyTimes = true
        XCTAssertNil(try frameReadyTime(in: view), "Enabling must not retroactively stamp an old snapshot")
    }

    func testFrameReadyTimeClearsWithGeometryVisibilityAndAttachmentInvalidations() async throws {
        let view = try await makeView { view in
            self.useCoreText(view)
            view.recordsFrameReadyTimes = true
        }
        defer { view.detach() }
        try await waitUntil("initial accepted timestamp") { try self.frameReadyTime(in: view) != nil }
        view.font = view.font.withSize(20)
        XCTAssertNil(view.frameValue)
        XCTAssertNil(try frameReadyTime(in: view))
        try await waitUntil("new font timestamp") { try self.frameReadyTime(in: view) != nil }
        view.forcedScale = 3
        XCTAssertNil(view.frameValue)
        XCTAssertNil(try frameReadyTime(in: view))
        try await waitUntil("new scale timestamp") { try self.frameReadyTime(in: view) != nil }
        let ancestor = try XCTUnwrap(view.superview)
        ancestor.isHidden = true
        XCTAssertNil(view.frameValue)
        XCTAssertNil(try frameReadyTime(in: view))
        ancestor.isHidden = false
        try await waitUntil("resumed timestamp") { try self.frameReadyTime(in: view) != nil }
        view.detach()
        XCTAssertNil(view.frameValue)
        XCTAssertNil(try frameReadyTime(in: view))
    }

    func testOrderedCompletionRejectsSnapshotAlreadyInFlightAndWaitsForDraw() async throws {
        let session = VTTerminalSession(write: { _ in }, resize: { _ in })
        let view = try await makeView(session: session)
        useCoreText(view)
        // Accepting the first frame does not end the extraction loop. If it is
        // still running when delivery blocks, its next snapshot queues behind
        // the gate and the request below cannot start a new extraction.
        try await waitUntil("initial frame and idle extraction") {
            view.frameValue != nil && !view.hasPendingSnapshotWorkForDiagnostics
        }
        let gate = DeliveryGate()
        session.beforeDelivery = { await gate.wait() }
        session.deliver(Data("ordered".utf8), ifCurrent: { true }, completion: { _ in })
        try await waitUntil("blocked delivery") { await gate.entered }
        let before = view.snapshotExtractions
        view.requestFrame()
        try await waitUntil("old snapshot request") { view.snapshotExtractions > before }
        let oldExtraction = view.snapshotExtractions
        var completed = 0
        var accepted = 0
        var rendered = 0
        view.onRendered = { _ in rendered += 1 }
        view.requestFrame { frame in
            completed += 1
            XCTAssertGreaterThan(view.snapshotExtractions, oldExtraction)
            XCTAssertEqual(frame, view.frameValue)
            XCTAssertTrue(frame.line(0).hasPrefix("ordered"))
        }
        _ = draw(view)
        XCTAssertEqual(completed, 0, "An already accepted frame cannot satisfy registration")
        view.onFrame = { frame in
            accepted += 1
            XCTAssertEqual(frame, view.frameValue, "Semantic callback follows acceptance")
            if accepted == 1 {
                let beforeDraw = rendered
                _ = self.draw(view)
                XCTAssertEqual(rendered, beforeDraw + 1)
                XCTAssertEqual(completed, 0, "The snapshot requested before registration is insufficient")
            } else {
                _ = self.draw(view)
            }
        }
        await gate.release()
        try await waitUntil("ordered draw completion") { completed == 1 }
        _ = draw(view)
        XCTAssertEqual(completed, 1, "Completion is one-shot")
        view.onFrame = nil
        view.onRendered = nil
    }

    func testUnchangedMetalFrameCanSatisfyNewOrderedRequest() async throws {
        let view = try await makeView()
        try await waitUntil("initial frame") { view.frameValue != nil }
        _ = try XCTUnwrap(view.metalRenderer)
        var completions = 0
        let beforeFirst = view.renderDiagnostics
        view.requestFrame { _ in completions += 1 }
        try await waitUntil("first GPU completion", diagnostics: {
            "before: \(beforeFirst)\nafter: \(view.renderDiagnostics)"
        }) { completions == 1 }
        let first = view.frameValue
        let beforeSecond = view.renderDiagnostics
        view.requestFrame { frame in
            XCTAssertEqual(frame, first)
            completions += 1
        }
        try await waitUntil("unchanged frame GPU completion", diagnostics: {
            "before: \(beforeSecond)\nafter: \(view.renderDiagnostics)"
        }) { completions == 2 }
        XCTAssertNotNil(view.metalRenderer, "This regression must exercise Metal, not recovery")
    }

    func testFreshOrderedCompletionDoesNotWaitForIOSurfacePublication() async throws {
        let view = try await makeView { view in
            view.terminalFocused = false
        }
        let pipeline = try XCTUnwrap(view.metalRenderer).pipelineForTesting
        try await waitUntil("initial GPU render drained") {
            view.frameValue != nil && pipeline.isIdle && pipeline.diagnostics.currentCompletions > 0
        }
        let held = expectation(description: "Fresh frame IOSurface publication held")
        var leases: [CheckedContinuation<Void, Never>] = []
        defer {
            view.detach()
            pipeline.retire()
            leases.forEach { $0.resume() }
        }
        pipeline.publicationHoldForTesting = {
            await withCheckedContinuation {
                leases.append($0)
                if leases.count == 1 { held.fulfill() }
            }
        }
        let extraction = view.snapshotExtractions
        let completions = pipeline.diagnostics.currentCompletions
        let publications = pipeline.diagnostics.presentationPublications
        var completed = 0
        view.requestFrame { frame in
            XCTAssertGreaterThan(view.snapshotExtractions, extraction)
            XCTAssertEqual(frame, view.frameValue)
            completed += 1
        }
        await fulfillment(of: [held], timeout: 5)
        XCTAssertEqual(completed, 1, "Fresh GPU work satisfies readiness while IOSurface publication is held")
        XCTAssertGreaterThan(pipeline.inFlightCount, 0)
        XCTAssertEqual(pipeline.diagnostics.currentCompletions, completions)
        XCTAssertEqual(pipeline.diagnostics.presentationPublications, publications)
        pipeline.publicationHoldForTesting = nil
        leases.forEach { $0.resume() }
        leases.removeAll()
        await pipeline.waitForIdle()
        XCTAssertEqual(completed, 1, "Presentation must not publish the UI barrier twice")
        XCTAssertGreaterThan(pipeline.diagnostics.currentCompletions, completions)
        XCTAssertGreaterThan(pipeline.diagnostics.presentationPublications, publications)
    }

    #if DEBUG
    func testLifecycleRenderedRevisionTracksAcceptedGPUWithIOSurfacePublication() async throws {
        let view = try await makeView { view in
            view.terminalFocused = false
        }
        let pipeline = try XCTUnwrap(view.metalRenderer).pipelineForTesting
        defer { view.onFrame = nil; view.detach(); pipeline.retire() }
        try await waitUntil("initial IOSurface publication drained") {
            view.frameValue != nil && pipeline.isIdle && pipeline.diagnostics.presentationPublications > 0
                && !view.hasPendingSnapshotWorkForDiagnostics
        }
        XCTAssertFalse(view.recordsLifecycleRenderCompletions)
        XCTAssertNil(view.lifecycleRenderedRevision, "Unused observation remains inert")
        let extractions = view.snapshotExtractions
        view.recordsLifecycleRenderCompletions = true
        XCTAssertNil(view.lifecycleRenderedRevision, "Enabling cannot backfill an old GPU completion")
        XCTAssertEqual(view.snapshotExtractions, extractions)
        let previousRevision = try XCTUnwrap(view.frameValue?.revision)
        let previousCompletions = view.lifecycleRenderCompletions
        let previousPublications = pipeline.diagnostics.presentationPublications
        view.feed(Data("\u{1B}[?25lLIFE GPU COMPLETION".utf8))
        try await waitUntil("new accepted GPU completion and IOSurface publication", diagnostics: {
            view.renderDiagnostics
        }) {
            (view.frameValue?.revision ?? 0) > previousRevision && pipeline.isIdle
                && view.lifecycleRenderCompletions > previousCompletions
                && pipeline.diagnostics.presentationPublications > previousPublications
                && view.lifecycleRenderedRevision == view.frameValue?.revision
        }
        // IOSurface publication is current-frame evidence, not a scanout timestamp.
        XCTAssertEqual(view.lifecycleRenderedRevision, view.frameValue?.revision)
        XCTAssertEqual(pipeline.diagnostics.lastCompletedRevision, view.frameValue?.revision)
        XCTAssertEqual(pipeline.diagnostics.retryRequests, 0)
        XCTAssertEqual(pipeline.inFlightCount, 0)
        XCTAssertEqual(pipeline.pendingCount, 0)

        let renderedRevision = view.lifecycleRenderedRevision
        view.isHidden = true
        XCTAssertNil(view.lifecycleRenderedRevision, "Hidden content cannot reuse accepted GPU evidence")
        var observedFreshFrame = false
        view.onFrame = { _ in
            if !observedFreshFrame {
                observedFreshFrame = true
                XCTAssertNil(view.lifecycleRenderedRevision, "Same revision in a new epoch must render again")
            }
        }
        view.isHidden = false
        try await waitUntil("fresh render after reveal") {
            observedFreshFrame && view.lifecycleRenderedRevision == renderedRevision
        }
        let beforeDisable = view.snapshotExtractions
        view.recordsLifecycleRenderCompletions = false
        XCTAssertNil(view.lifecycleRenderedRevision)
        XCTAssertEqual(view.snapshotExtractions, beforeDisable)
        view.recordsLifecycleRenderCompletions = true
        XCTAssertNil(view.lifecycleRenderedRevision, "Re-enabling remains passive")
        useCoreText(view)
        _ = draw(view)
        XCTAssertNil(view.lifecycleRenderedRevision, "CoreText recovery cannot satisfy the Metal GPU gate")
    }
    #endif

    func testSuccessiveUnchangedFreshRequestsPublishIOSurfacesWithoutRetries() async throws {
        let view = try await makeView { view in
            view.terminalFocused = false
        }
        let pipeline = try XCTUnwrap(view.metalRenderer).pipelineForTesting
        defer { view.detach(); pipeline.retire() }
        try await waitUntil("initial IOSurface publication drained") {
            view.frameValue != nil && pipeline.isIdle && pipeline.diagnostics.presentationPublications > 0
                && !view.hasPendingSnapshotWorkForDiagnostics
        }
        let initial = try XCTUnwrap(view.frameValue)
        var completed = 0
        for request in 1...2 {
            let extraction = view.snapshotExtractions
            let renders = pipeline.diagnostics.gpuCompletedFrames
            let completions = pipeline.diagnostics.currentCompletions
            let publications = pipeline.diagnostics.presentationPublications
            view.requestFrame { frame in
                XCTAssertEqual(frame, initial, "Unchanged state still requires fresh extraction and rendering")
                XCTAssertGreaterThan(view.snapshotExtractions, extraction)
                XCTAssertGreaterThan(pipeline.diagnostics.gpuCompletedFrames, renders)
                completed += 1
            }
            try await waitUntil("fresh ordered request \(request)", diagnostics: { view.renderDiagnostics }) {
                completed == request && pipeline.isIdle
            }
            XCTAssertEqual(completed, request)
            XCTAssertEqual(pipeline.diagnostics.gpuCompletedFrames, renders + 1)
            XCTAssertEqual(pipeline.diagnostics.currentCompletions, completions + 1)
            XCTAssertEqual(pipeline.diagnostics.presentationPublications, publications + 1)
            XCTAssertEqual(pipeline.diagnostics.lastCompletedRevision, initial.revision)
            XCTAssertEqual(pipeline.diagnostics.retryRequests, 0)
            XCTAssertNotNil(view.metalRenderer, "No CoreText recovery")
        }
    }

    func testReplacementAndDetachDiscardOrderedCallbacks() async throws {
        let view = try await makeView()
        useCoreText(view)
        try await waitUntil("initial frame") { view.frameValue != nil }
        var callbacks = 0
        view.requestFrame { _ in callbacks += 1 }
        view.attach(VTTerminalSession(write: { _ in }, resize: { _ in }))
        try await waitUntil("replacement frame") { view.frameValue != nil }
        _ = draw(view)
        XCTAssertEqual(callbacks, 0)
        view.requestFrame { _ in callbacks += 1 }
        view.detach()
        _ = draw(view)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(callbacks, 0)
    }

    func testReentrantSemanticCallbackCannotPresentDetachedFrame() async throws {
        let view = try await makeView()
        useCoreText(view)
        try await waitUntil("initial frame") { view.frameValue != nil }
        var renders = 0
        view.onRendered = { _ in renders += 1 }
        view.onFrame = { _ in
            view.detach()
            renders = 0
        }
        view.refresh()
        try await waitUntil("semantic detach") { view.frameValue == nil }
        _ = draw(view)
        XCTAssertEqual(renders, 0)
        view.onFrame = nil
    }

    func testRenderedCallbackDetachDiscardsReadyOrderedCallbacks() async throws {
        let view = try await makeView()
        useCoreText(view)
        try await waitUntil("initial frame") { view.frameValue != nil }
        var completed = false
        view.onFrame = { _ in
            view.onRendered = { _ in view.detach() }
            _ = self.draw(view)
        }
        view.requestFrame { _ in completed = true }
        try await waitUntil("render callback detach") { view.frameValue == nil }
        XCTAssertFalse(completed)
        view.onFrame = nil
        view.onRendered = nil
    }

    func testMarkedTextUsesNonResponderOverlayAndClearsOnDetach() async throws {
        let view = try await makeView()
        try await waitUntil("cursor frame") { view.cursorRect() != nil }
        let overlay = try XCTUnwrap(view.subviews.first)
        let blank = draw(overlay).pngData()
        view.markedText = "にほん 👩🏽‍💻"
        XCTAssertFalse(overlay.isHidden)
        XCTAssertFalse(overlay.isUserInteractionEnabled)
        XCTAssertFalse(overlay.canBecomeFirstResponder)
        XCTAssertEqual(overlay.frame, view.bounds)
        XCTAssertNotEqual(draw(overlay).pngData(), blank)
        view.markedText = ""
        XCTAssertTrue(overlay.isHidden)
        view.markedText = "再"
        view.detach()
        XCTAssertEqual(view.markedText, "")
        XCTAssertTrue(overlay.isHidden)
    }

    func testFeedPublishesHelloThroughMetalContent() async throws {
        let view = try await makeView()
        view.refresh()
        try await waitUntil("blank frame") { view.frameValue != nil }
        view.feed(Data("hello".utf8))
        try await waitUntil("hello frame") {
            view.frameValue?.line(0).hasPrefix("hello") == true
        }
        let renderer = try XCTUnwrap(view.metalRenderer)
        XCTAssertTrue(renderer.isActive)
        XCTAssertTrue(renderer.presentationLayer.superlayer === view.layer)
        XCTAssertLessThanOrEqual(renderer.inFlightCount, 2)
        XCTAssertLessThanOrEqual(renderer.pendingCount, 1)
    }

    func testDefaultIOSurfaceBackendMountsPublishesAndFeedsThroughContentView() async throws {
        let view = try await makeView()
        let renderer = try XCTUnwrap(view.metalRenderer)
        XCTAssertTrue(renderer.presentationLayer.superlayer === view.layer)
        view.feed(Data("iosurface host".utf8))
        try await waitUntil("IOSurface host publication") {
            view.frameValue?.line(0).hasPrefix("iosurface host") == true
                && renderer.diagnostics.presentationPublications > 0
                && renderer.diagnostics.lastCompletedRevision == view.frameValue?.revision
                && renderer.presentationLayer.contents != nil
        }
        XCTAssertEqual(renderer.diagnostics.retryRequests, 0)
    }

    func testFractionalPointBoundsAcceptPixelAlignedEngineFrame() async throws {
        let view = try await makeView()
        view.frame.size = CGSize(width: 390.2, height: 480.1)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        try await waitUntil("pixel-aligned frame") { view.frameValue != nil }
        XCTAssertEqual(view.frameValue?.layout.viewportWidth, 390)
        XCTAssertEqual(view.frameValue?.layout.viewportHeight, 480)
    }

    func testImplicitMainActorReleaseRetiresRendererImmediately() async throws {
        let session = VTTerminalSession(write: { _ in }, resize: { _ in })
        defer { session.finish() }
        var view: VTContentView? = VTContentView(frame: .zero)
        view!.attach(session)
        let renderer = try XCTUnwrap(view!.metalRenderer)
        renderer.setActive(true)
        XCTAssertTrue(renderer.isActive, "Retirement must start from an active renderer")
        let held = try await seedRetainedGraphics(in: session)
        weak let released = view
        view = nil
        XCTAssertNil(released)
        XCTAssertFalse(renderer.isActive, "Main-thread retirement must be synchronous")
        let bytes = try await cachedImageBytes(in: session)
        XCTAssertEqual(bytes, 0, "Implicit release must trim the retained session's snapshot cache")
        XCTAssertEqual(held.graphics.placements.first?.image.rgba.prefix(4), Data([64, 64, 64, 255]))
        XCTAssertNotNil(session.enqueueInput(.text("session survives view")))
    }

    func testBackgroundLastViewReleaseRetiresRendererWithoutRemovingReplacementObserver() async throws {
        let session = VTTerminalSession(write: { _ in }, resize: { _ in })
        defer { session.finish() }
        var view: VTContentView? = VTContentView(frame: .zero)
        view!.attach(session)
        let renderer = try XCTUnwrap(view!.metalRenderer)
        renderer.setActive(true)
        XCTAssertTrue(renderer.isActive, "Retirement must start from an active renderer")
        let held = try await seedRetainedGraphics(in: session)
        // Transfer only a Sendable closure, not the UIKit view. The box never
        // invokes it: dropping its capture forces the last release off-main.
        let release = VTBackgroundReleaseBox({ @MainActor @Sendable [view = view!] in
            withExtendedLifetime(view) {}
        })
        weak let released = view
        view = nil
        release.releaseOnBackgroundSynchronously()
        XCTAssertNil(released)
        // UIKit may defer the entire UIView dealloc to main, after weak reads
        // already return nil. Attach a replacement before yielding, but leave it
        // unmounted so it cannot refill the cache while we observe old cleanup.
        let replacement = VTContentView(frame: .zero)
        replacement.attach(session)
        defer { replacement.detach() }
        try await waitUntil("old renderer retirement") { !renderer.isActive }
        // Retirement follows cache-release admission in the old deinit. This
        // FIFO query therefore observes completion, not merely weak zeroing.
        let cacheQuery = try XCTUnwrap(session.enqueueInputQuery { terminal in
            await terminal.cachedSnapshotImageBytes
        })
        _ = try await makeView(session: session, suppliedView: replacement)
        let bytes = try await cacheQuery.value
        XCTAssertEqual(bytes, 0)
        XCTAssertEqual(held.graphics.placements.first?.image.rgba.prefix(4), Data([64, 64, 64, 255]))
        try await waitUntil("replacement frame") { replacement.frameValue != nil }
        session.receive(Data("\u{1B}[Hreplacement survives\u{1B}[K".utf8))
        try await waitUntil("replacement observer receives output") {
            replacement.frameValue?.line(0).hasPrefix("replacement survives") == true
        }
    }

    func testDetachClearsFrame() async throws {
        let view = try await makeView()
        view.refresh()
        try await waitUntil("frame") { view.frameValue != nil }
        view.detach()
        XCTAssertNil(view.frameValue)
    }

    func testRefreshBurstCoalescesSnapshotExtraction() async throws {
        let view = try await makeView()
        try await waitUntil("initial frame") { view.frameValue != nil }
        let before = view.snapshotExtractions
        let beforeDiagnostics = view.renderDiagnostics
        for _ in 0..<1_000 { view.refresh() }
        try await waitUntil("coalesced snapshot") { view.snapshotExtractions > before }
        XCTAssertLessThanOrEqual(view.snapshotExtractions - before, 2,
            "before: \(beforeDiagnostics)\nafter: \(view.renderDiagnostics)")
    }

    func testHiddenAncestorSuspendsAndRestoresFreshFrame() async throws {
        let view = try await makeView()
        try await waitUntil("initial frame") { view.frameValue != nil }
        let ancestor = try XCTUnwrap(view.superview)
        ancestor.isHidden = true
        XCTAssertFalse(view.isPresentationActive)
        XCTAssertNil(view.frameValue)
        let before = view.snapshotExtractions
        view.feed(Data("hidden output".utf8))
        for _ in 0..<100 { view.refresh() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(view.snapshotExtractions, before)
        ancestor.isHidden = false
        try await waitUntil("fresh resumed frame") {
            view.frameValue?.line(0).hasPrefix("hidden output") == true
        }
    }

    func testHiddenGraphicsReleasePreservesOutputRepliesAndRevealsCurrentPixels() async throws {
        let reply = expectation(description: "Hidden terminal cursor report")
        let session = VTTerminalSession(write: { data in
            if data == Data("\u{1B}[7;14R".utf8) { reply.fulfill() }
        }, resize: { _ in })
        let view = try await makeView(session: session) { self.useCoreText($0) }
        defer { view.detach(); session.finish() }
        let graphics = TerminalGraphicsMemoryWorkload(side: 2)
        view.feed(graphics.payload(0))
        try await waitUntil("initial graphics drained") {
            try view.frameValue?.graphics.placements.count == 2 && !self.snapshotRequestInFlight(in: view)
        }
        let held = try XCTUnwrap(view.frameValue)
        let initialBytes = try await cachedImageBytes(in: session)
        XCTAssertEqual(initialBytes, graphics.imageBytes)
        let ancestor = try XCTUnwrap(view.superview)
        ancestor.isHidden = true
        XCTAssertNil(view.frameValue)
        let extractions = view.snapshotExtractions
        let hiddenBytes = try await cachedImageBytes(in: session)
        XCTAssertEqual(hiddenBytes, 0)

        view.feed(graphics.payload(1))
        view.feed(Data("\u{1B}[7;1Hhidden output\u{1B}[6n".utf8))
        for _ in 0..<100 { view.refresh() }
        let updatedBytes = try await cachedImageBytes(in: session)
        await fulfillment(of: [reply], timeout: 5)
        XCTAssertEqual(updatedBytes, 0, "Hidden output must not repopulate snapshot image retention")
        XCTAssertEqual(view.snapshotExtractions, extractions)
        XCTAssertNil(view.frameValue)
        XCTAssertEqual(held.graphics.placements.first?.image.rgba.prefix(4), Data([64, 64, 64, 255]))

        ancestor.isHidden = false
        try await waitUntil("current hidden graphics revealed") {
            view.frameValue?.line(6).hasPrefix("hidden output") == true
                && view.frameValue?.graphics.placements.first?.image.rgba.first == graphics.level(1)
        }
        let current = try XCTUnwrap(view.frameValue)
        XCTAssertEqual(current.graphics.placements.count, 2)
        XCTAssertEqual(current.graphics.placements.first?.image.rgba.prefix(4), Data([192, 192, 192, 255]))
        XCTAssertGreaterThan(view.snapshotExtractions, extractions)
    }

    func testScalarV3HiddenObservationPreservesCacheReleaseAndReadsCurrentLayoutAndSelection() async throws {
        let session = VTTerminalSession(write: { _ in }, resize: { _ in })
        let view = try await makeView(session: session) {
            self.useCoreText($0)
            $0.terminalFocused = false
        }
        defer { view.detach(); session.finish() }
        let observation = TerminalMemoryObservation.scalar
        let graphics = TerminalGraphicsMemoryWorkload(side: 2)
        let marker = "scalar-hidden-marker"
        view.feed(graphics.payload(0))
        view.feed(Data("\u{1B}[7;1H\(marker)\u{1B}[K".utf8))
        try await waitUntil("initial scalar probe graphics drained") {
            try view.frameValue?.graphics.placements.count == 2
                && view.frameValue?.line(6).hasPrefix(marker) == true
                && !self.snapshotRequestInFlight(in: view)
        }
        let held = try XCTUnwrap(view.frameValue)
        XCTAssertNotNil(draw(view).pngData())
        let initialBytes = try await cachedImageBytes(in: session)
        XCTAssertEqual(initialBytes, graphics.imageBytes)
        let ancestor = try XCTUnwrap(view.superview)
        ancestor.isHidden = true
        XCTAssertFalse(view.isPresentationActive)
        XCTAssertNil(view.frameValue)
        let extractions = view.snapshotExtractions
        // The non-extracting FIFO query completes after the hide's cache release.
        let hiddenBytes = try await cachedImageBytes(in: session)
        XCTAssertEqual(hiddenBytes, 0)

        for _ in 0..<4 {
            let layout = try await observation.layout(in: session)
            let selected = try await observation.hasSelection(in: session)
            XCTAssertEqual(layout, held.layout)
            XCTAssertFalse(selected)
        }
        let observedBytes = try await cachedImageBytes(in: session)
        XCTAssertEqual(observedBytes, 0)
        XCTAssertEqual(view.snapshotExtractions, extractions)

        let originalFont = view.font
        var previousLayout = held.layout
        for font in [originalFont.withSize(20), originalFont] {
            view.font = font
            let expected = try XCTUnwrap(view.metrics(for: view.bounds.size, scale: 2))
            // Font changes synchronously enqueue resize; scalar reads follow it.
            let layout = try await observation.layout(in: session)
            XCTAssertEqual(layout.cellWidth, expected.cellWidth)
            XCTAssertEqual(layout.cellHeight, expected.cellHeight)
            XCTAssertEqual(layout.generation, previousLayout.generation + 1)
            XCTAssertNotEqual(layout.cellWidth, previousLayout.cellWidth)
            XCTAssertNotEqual(layout.cellHeight, previousLayout.cellHeight)
            previousLayout = layout
            let bytes = try await cachedImageBytes(in: session)
            XCTAssertEqual(bytes, 0)
            XCTAssertEqual(view.snapshotExtractions, extractions)
        }

        let select = try XCTUnwrap(session.enqueueSelect(.all, at: .init(column: 0, row: 0),
                                                        generation: previousLayout.generation))
        try await select.value
        let selected = try await observation.hasSelection(in: session)
        XCTAssertTrue(selected)
        let copy = try XCTUnwrap(session.enqueueSelectedText())
        let copied = try await copy.value
        XCTAssertTrue(copied.contains(marker))
        let stillSelected = try await observation.hasSelection(in: session)
        XCTAssertTrue(stillSelected, "Scalar and text queries must preserve selection")
        let take = try XCTUnwrap(session.enqueueTakeSelectedText())
        let taken = try await take.value
        XCTAssertEqual(taken, copied)
        let cleared = try await observation.hasSelection(in: session)
        XCTAssertFalse(cleared)
        let selectionBytes = try await cachedImageBytes(in: session)
        XCTAssertEqual(selectionBytes, 0)
        XCTAssertEqual(view.snapshotExtractions, extractions)

        view.feed(graphics.payload(1))
        view.feed(Data("\u{1B}[7;1Hhidden replacement\u{1B}[K".utf8))
        let replacementBytes = try await cachedImageBytes(in: session)
        XCTAssertEqual(replacementBytes, 0)
        XCTAssertEqual(view.snapshotExtractions, extractions)
        XCTAssertNil(view.frameValue)
        XCTAssertEqual(held.graphics.placements.first?.image.rgba.prefix(4), Data([64, 64, 64, 255]))
        ancestor.isHidden = false
        try await waitUntil("scalar probe reveals current replacement") {
            view.frameValue?.line(6).hasPrefix("hidden replacement") == true
                && view.frameValue?.graphics.placements.first?.image.rgba.first == graphics.level(1)
        }
        let current = try XCTUnwrap(view.frameValue)
        XCTAssertEqual(current.layout, previousLayout)
        XCTAssertEqual(current.graphics.placements.count, 2)
        XCTAssertEqual(current.graphics.placements.first?.image.rgba.prefix(4), Data([192, 192, 192, 255]))
        XCTAssertGreaterThan(view.snapshotExtractions, extractions)
    }

    func testQueuedGraphicsSnapshotCannotRefillCacheOrPublishAfterHideOrDetach() async throws {
        for detach in [false, true] {
            let session = VTTerminalSession(write: { _ in }, resize: { _ in })
            let view = try await makeView(session: session) { self.useCoreText($0) }
            defer { view.onFrame = nil; view.detach(); session.finish() }
            view.feed(TerminalGraphicsMemoryWorkload(side: 2).payload(0))
            try await waitUntil("initial graphics drained") {
                try view.frameValue?.graphics.placements.count == 2 && !self.snapshotRequestInFlight(in: view)
            }
            let initialBytes = try await cachedImageBytes(in: session)
            XCTAssertEqual(initialBytes, 16)
            let gate = DeliveryGate()
            defer { Task { await gate.release() } }
            session.beforeDelivery = { await gate.wait() }
            session.deliver(Data("\u{1B}[7;1Hqueued".utf8), ifCurrent: { true }, completion: { _ in })
            try await waitUntil("blocked delivery") { await gate.entered }
            let before = view.snapshotExtractions
            var publications = 0
            var completions = 0
            view.onFrame = { _ in publications += 1 }
            view.requestFrame { _ in completions += 1 }
            try await waitUntil("snapshot admitted behind blocked delivery") { view.snapshotExtractions > before }
            if detach { view.detach() }
            else { try XCTUnwrap(view.superview).isHidden = true }
            XCTAssertNil(view.frameValue)
            // This query is admitted after lifecycle release, while both are
            // still blocked behind the old snapshot. Never snapshot to measure.
            let cacheQuery = try XCTUnwrap(session.enqueueInputQuery { terminal in
                await terminal.cachedSnapshotImageBytes
            })
            await gate.release()
            session.beforeDelivery = nil
            let bytes = try await cacheQuery.value
            XCTAssertEqual(bytes, 0, "Queued snapshot must precede release; detach=\(detach)")
            try await waitUntil("obsolete snapshot task drained") { try !self.snapshotRequestInFlight(in: view) }
            let settledBytes = try await cachedImageBytes(in: session)
            XCTAssertEqual(settledBytes, 0)
            XCTAssertNil(view.frameValue)
            XCTAssertEqual(publications, 0)
            XCTAssertEqual(completions, 0)
        }
    }

    func testMemoryWarningReleasesSnapshotCacheWithoutExtractingOrInvalidatingCurrentPixels() async throws {
        let session = VTTerminalSession(write: { _ in }, resize: { _ in })
        let view = try await makeView(session: session) {
            self.useCoreText($0)
            $0.terminalFocused = false
        }
        defer { view.detach(); session.finish() }
        view.feed(TerminalGraphicsMemoryWorkload(side: 2).payload(0))
        try await waitUntil("current graphics drained") {
            try view.frameValue?.graphics.placements.count == 2 && !self.snapshotRequestInFlight(in: view)
        }
        let held = try XCTUnwrap(view.frameValue)
        let rendered = draw(view).pngData()
        XCTAssertNotNil(rendered)
        let extractions = view.snapshotExtractions
        let initialBytes = try await cachedImageBytes(in: session)
        XCTAssertEqual(initialBytes, 16)
        var publications = 0
        view.onFrame = { _ in publications += 1 }
        defer { view.onFrame = nil }
        lifecycle.post(UIApplication.didReceiveMemoryWarningNotification, object: nil)
        let trimmedBytes = try await cachedImageBytes(in: session)
        XCTAssertEqual(trimmedBytes, 0)
        try await waitUntil("memory warning snapshot task drained") { try !self.snapshotRequestInFlight(in: view) }
        XCTAssertEqual(view.frameValue, held)
        XCTAssertEqual(draw(view).pngData(), rendered, "CoreText redraw retains the current immutable pixels")
        XCTAssertEqual(held.graphics.placements.first?.image.rgba.prefix(4), Data([64, 64, 64, 255]))
        XCTAssertEqual(view.snapshotExtractions, extractions)
        XCTAssertEqual(publications, 0)
        let redrawBytes = try await cachedImageBytes(in: session)
        XCTAssertEqual(redrawBytes, 0, "Drawing a held frame must not recreate snapshot retention")
        XCTAssertEqual(view.snapshotExtractions, extractions)
        XCTAssertEqual(publications, 0)
    }

    func testHeldGPUImageLeaseSurvivesHiddenSnapshotCacheReleaseAndDrains() async throws {
        let session = VTTerminalSession(write: { _ in }, resize: { _ in })
        let view = try await makeView(session: session) { view in
            view.terminalFocused = false
        }
        let pipeline = try XCTUnwrap(view.metalRenderer).pipelineForTesting
        try await waitUntil("initial GPU work drained") {
            try view.frameValue != nil && pipeline.isIdle && pipeline.diagnostics.currentCompletions > 0
                && !self.snapshotRequestInFlight(in: view)
        }
        let heldPresentation = expectation(description: "Graphics IOSurface publication held")
        var leases: [CheckedContinuation<Void, Never>] = []
        defer {
            view.detach()
            pipeline.retire()
            leases.forEach { $0.resume() }
            session.finish()
        }
        pipeline.publicationHoldForTesting = {
            await withCheckedContinuation {
                leases.append($0)
                if leases.count == 1 { heldPresentation.fulfill() }
            }
        }
        view.feed(TerminalGraphicsMemoryWorkload(side: 2).payload(0))
        await fulfillment(of: [heldPresentation], timeout: 5)
        let held = try XCTUnwrap(view.frameValue)
        XCTAssertEqual(held.graphics.placements.count, 2)
        XCTAssertGreaterThan(pipeline.inFlightCount, 0)
        let initialBytes = try await cachedImageBytes(in: session)
        XCTAssertEqual(initialBytes, 16)
        try XCTUnwrap(view.superview).isHidden = true
        let hiddenBytes = try await cachedImageBytes(in: session)
        XCTAssertEqual(hiddenBytes, 0)
        XCTAssertNil(view.frameValue)
        XCTAssertGreaterThan(pipeline.inFlightCount, 0, "Cache release must not release a GPU presentation lease")
        XCTAssertEqual(held.graphics.placements.first?.image.rgba.prefix(4), Data([64, 64, 64, 255]))
        let obsolete = pipeline.diagnostics.obsoleteCompletions
        pipeline.publicationHoldForTesting = nil
        leases.forEach { $0.resume() }
        leases.removeAll()
        await pipeline.waitForIdle()
        XCTAssertEqual(pipeline.inFlightCount, 0)
        XCTAssertGreaterThan(pipeline.diagnostics.obsoleteCompletions, obsolete)
        XCTAssertNil(view.frameValue)
        let drainedBytes = try await cachedImageBytes(in: session)
        XCTAssertEqual(drainedBytes, 0)
    }

    func testBackgroundAndDetachedFramesCannotReturn() async throws {
        let view = try await makeView()
        try await waitUntil("initial frame") { view.frameValue != nil }
        view.refresh()
        lifecycle.post(UIApplication.willResignActiveNotification, object: nil)
        XCTAssertFalse(view.isPresentationActive)
        XCTAssertNil(view.frameValue)
        view.detach()
        lifecycle.post(UIApplication.didBecomeActiveNotification, object: nil)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(view.isPresentationActive)
        XCTAssertNil(view.frameValue)
        XCTAssertFalse(view.metalRenderer?.isActive ?? true)
    }

    func testFontAndScaleInvalidateOldGeometry() async throws {
        let view = try await makeView()
        try await waitUntil("initial frame") { view.frameValue != nil }
        let oldWidth = try XCTUnwrap(view.frameValue).layout.cellWidth
        view.font = view.font.withSize(20)
        XCTAssertNil(view.frameValue)
        try await waitUntil("new font frame") { view.frameValue?.layout.cellWidth != nil }
        XCTAssertNotEqual(view.frameValue?.layout.cellWidth, oldWidth)
        view.forcedScale = 3
        XCTAssertNil(view.frameValue)
        try await waitUntil("new scale frame") { view.frameValue?.layout.scale == 3 }
    }

    func testSessionMetricsReflectFontAndBounds() async throws {
        let view = try await makeView()
        let metrics = view.metrics(for: view.bounds.size, scale: 2)
        XCTAssertEqual(metrics?.width, 390)
        XCTAssertEqual(metrics?.height, 480)
        XCTAssertEqual(metrics?.scale, 2)
        XCTAssertGreaterThan(metrics?.cellWidth ?? 0, 0)
        XCTAssertGreaterThan(metrics?.cellHeight ?? 0, 0)
    }
}
