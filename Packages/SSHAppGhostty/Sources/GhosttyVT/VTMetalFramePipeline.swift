import Metal
import QuartzCore
import UIKit

/// Production-facing ownership boundary for the bounded Metal renderer. The
/// underlying atlas, workers and budget types remain private to GhosttyVT.
@MainActor
public final class VTMetalRenderer {
    /// Hosts the published IOSurface frames.
    public var presentationLayer: CALayer { pipeline.presentationLayer! }
    private let pipeline: VTMetalFramePipeline
    #if VT_TEST_HOOKS
    /// Internal access to hold real presentation leases across facade teardown.
    var pipelineForTesting: VTMetalFramePipeline { pipeline }
    #endif

    public init(font: UIFont) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw NSError(domain: "GhosttyVT.Metal", code: 1)
        }
        pipeline = try VTMetalFramePipeline(font: font,
            ioSurfacePresenter: VTIOSurfacePresenter(device: device))
        pipeline.setActive(false)
    }

    /// Warms the Metal device, a command queue and both render pipelines so
    /// the first terminal frame avoids one-time driver setup. Call from a
    /// background thread at app startup.
    public nonisolated static func warmup() { VTMetalFramePipeline.warmup() }

    deinit {
        let pipeline = pipeline
        cleanupOnMainActor { pipeline.retire() }
    }

    public var onNeedsFrame: (() -> Void)? {
        get { pipeline.onNeedsFrame }
        set { pipeline.onNeedsFrame = newValue }
    }
    public var onFailure: ((any Error) -> Void)? {
        get { pipeline.onFailure }
        set { pipeline.onFailure = newValue }
    }
    /// Successful current GPU render, before waiting for presentation. This is
    /// not evidence of display/scanout or UIKit snapshot freshness.
    public var onRendered: ((VTFrameValue) -> Void)? {
        didSet {
            pipeline.onRendered = { [weak self] frame in
                self?.onRendered?(frame)
            }
        }
    }
    /// Successful, current GPU/presentation completion only; never observations
    /// from obsolete epochs or failed commands. Renderer resources stay private.
    public var onComplete: ((VTFrameValue) -> Void)? {
        didSet {
            pipeline.onComplete = { [weak self] completion in
                self?.onComplete?(completion.frame)
            }
        }
    }
    public var isActive: Bool { pipeline.isActive }
    public var inFlightCount: Int { pipeline.inFlightCount }
    public var pendingCount: Int { pipeline.pendingCount }

    #if DEBUG
    /// Scalar-only history of actual inactive resource drains. Keeping this box
    /// alive cannot keep the facade, pipeline, frames or GPU resources alive.
    @MainActor
    package final class InactiveDrainDiagnostics {
        package struct Sample: Sendable {
            package let sequence: UInt64
            package let pending: Int
            package let inFlight: Int
        }
        package private(set) var latest: Sample?

        fileprivate func record(pending: Int, inFlight: Int) {
            latest = Sample(sequence: (latest?.sequence ?? 0) + 1,
                            pending: pending, inFlight: inFlight)
        }
    }
    /// Package-only, read-only diagnostics; no renderer implementation escapes.
    package var inactiveDrainDiagnostics: InactiveDrainDiagnostics { pipeline.inactiveDrainDiagnostics }
    #endif

    /// Cumulative scalar evidence for acquisition and completion stalls. No frames,
    /// textures, timers or callbacks are retained by an observation.
    public struct Diagnostics: Codable, Sendable {
        public let presentationTargetCount: Int
        public let presentationAvailableTargets: Int
        public let presentationLeasedTargets: Int
        public let presentationTargetBytes: Int
        public let presentationTargetCreations: Int
        public let presentationPublications: Int
        public let presentationDiscardedPublications: Int
        /// Cumulative IOSurface target acquisition outcomes.
        public let presentationTargetAcquisitionAttempts: Int
        public let presentationTargetAcquisitionSuccesses: Int
        /// Counts once per acquire that enters the existing 1ms pool-wait sleep.
        public let presentationTargetAcquisitionStalls: Int
        public let presentationTargetAcquisitionTimeouts: Int
        public let presentationTargetAcquisitionCancellations: Int
        /// Excludes cancellation and the bounded pool-wait timeout.
        public let presentationTargetAcquisitionFailures: Int
        /// Sum / lifetime maximum per completed acquire of pool sleep/resumption
        /// seconds, including cancelled/failed attempts. Excludes target allocation
        /// and CPU scans; neither metric measures compositor scanout or energy.
        public let presentationTargetPoolWaitTotalSeconds: Double
        public let presentationTargetPoolWaitMaxSeconds: Double
        public let submissions: Int
        public let startedFrames: Int
        public let presentationRequests: Int
        public let gpuCompletedFrames: Int
        public let observedCompletions: Int
        public let currentCompletions: Int
        public let retryRequests: Int
        public let retryExhausted: Bool
        public let needsFrameRequests: Int
        public let requestFrameWhenReady: Bool
        public let suppressedFrames: Int
        public let staleFrames: Int
        public let obsoleteCompletions: Int
        public let failedFrames: Int
        public let externalEpochChanges: Int
        public let lastSubmittedRevision: UInt64?
        public let lastObservedRevision: UInt64?
        public let lastCompletedRevision: UInt64?
        public let lastFailure: String?
    }
    public var diagnostics: Diagnostics { pipeline.diagnostics }
    public func submit(_ frame: VTFrameValue, presentation: VTPresentationState) {
        pipeline.submit(frame, presentation: presentation)
    }
    package func submit(_ frame: VTFrameValue, presentation: VTPresentationState,
                        acceptedFrameReadyTime: Double?) {
        pipeline.submit(frame, presentation: presentation, acceptedFrameReadyTime: acceptedFrameReadyTime)
    }
    public func beginEpoch(font: UIFont) { pipeline.beginEpoch(font: font) }
    public func setActive(_ active: Bool) { pipeline.setActive(active) }
    public func trimResources() { pipeline.trimResources() }
    public func retire() { pipeline.retire() }
}

/// Existing policy-link clocks, not rendered frames or display/scanout proof.
/// Generation changes on link restart; intervals must not cross generations.
public struct VTScrollRefreshSample: Sendable {
    public let timestamp: Double
    public let targetTimestamp: Double
    public let callbackTime: Double
    public let generation: Int
}

/// Narrow host bridge to the scene-shared, input-driven refresh policy. A pulse
/// expires after the coordinator's bounded idle tail; no held gesture or terminal
/// output can keep a display link alive without new local scroll input.
@MainActor
public final class VTScrollRefreshDriver {
    private static let coordinators = NSMapTable<UIWindowScene, VTScrollRefreshCoordinator>.weakToWeakObjects()
    private weak var scene: UIWindowScene?
    private weak var host: UIView?
    private var coordinator: VTScrollRefreshCoordinator?
    private var participant: VTScrollRefreshCoordinator.Participant?

    /// Installing/removing an observer cannot create or prolong refresh demand.
    public var onRefreshForDiagnostics: ((VTScrollRefreshSample) -> Void)? {
        didSet { participant?.onRefreshForDiagnostics = onRefreshForDiagnostics }
    }

    public init() {}

    deinit {
        let participant = participant
        let coordinator = coordinator
        cleanupOnMainActor {
            // Participant holds its owner weakly; keep it alive through cancel.
            withExtendedLifetime(coordinator) { participant?.cancel() }
        }
    }

    public func pulse(host: UIView) {
        guard let scene = host.window?.windowScene else { cancel(); return }
        if self.scene !== scene || self.host !== host {
            cancel()
            self.scene = scene
            self.host = host
            let coordinator = Self.coordinators.object(forKey: scene) ?? VTScrollRefreshCoordinator(scene: scene)
            Self.coordinators.setObject(coordinator, forKey: scene)
            self.coordinator = coordinator
            participant = coordinator.makeParticipant(host: host)
            participant?.onRefreshForDiagnostics = onRefreshForDiagnostics
        }
        participant?.pulse()
    }

    public func cancel() { participant?.cancel() }
    public func visibilityChanged() { participant?.visibilityChanged() }
    public var isRunning: Bool { coordinator?.isRunning == true }
}

/// Two independent atlas/raster leases and one newest pending owned snapshot.
/// Bytes and replies never enter this pipeline. Each lease owns a serial raster
/// worker; the main actor admits frames and submits their completed commands.
@MainActor
final class VTMetalFramePipeline {
    /// Owned scalar diagnostics; no renderer, texture or frame escapes here.
    struct CacheMetrics: Codable {
        let glyphsBySlot: [Int]
        let shapedGlyphsBySlot: [Int]
        let glyphCacheIdentitiesBySlot: [UUID?]
        let shapingMissesBySlot: [Int]
        let imagesBySlot: [Int]
        // Metal Simulator can report allocatedSize == 0 for live textures.
        // Counts distinguish a released cache from an unavailable byte gauge.
        let atlasTextures: Int
        let outputTextures: Int
        let imageTileTextures: Int
        let atlasTextureBytes: Int
        let outputTextureBytes: Int
        let imageTextureBytes: Int
        let imagePixelBytes: Int
        // Includes an RGBA pixel-storage floor when Metal has no byte gauge.
        let retainedTextureBytes: Int
    }
    /// Scalar diagnostics only. Permit observation includes executor resumption
    /// when queued; immediate permits can precede task entry. No lease changes.
    struct Timeline: Codable, Sendable {
        let start: Double
        let taskEntry: Double
        let permitObserved: Double
        let targetAcquisitionStart: Double?
        let targetAcquisitionEnd: Double?
        let renderReturned: Double
        let presentationObserved: Double
    }
    struct Completion {
        /// Immutable identity of the actual lease, including visibility epochs.
        /// Diagnostics must query currency after any chained/reentrant observer.
        let work: VTFrameScheduler.Work
        let frame: VTFrameValue
        let presentation: VTPresentationState
        let timing: VTMetalRasterizer.Timing
        var timeline: Timeline? = nil
    }
    /// Available only during the existing GPU publication callback. The owned
    /// work value lets diagnostic adapters join the same lease, not equal frames
    /// from different epochs. This does not replace or delay publication.
    private(set) var renderedWorkForDiagnostics: VTFrameScheduler.Work?

    func isCurrent(_ work: VTFrameScheduler.Work) -> Bool {
        isActive && !needsResourceRelease && scheduler.isCurrent(work)
    }

    func isCurrent(_ completion: Completion) -> Bool { isCurrent(completion.work) }

    /// Actual scheduler lifetime, including idle suspension/resumption. Unlike
    /// externalEpochChanges, this includes internal invalidation without callbacks.
    /// Diagnostic-only; reading it never changes admission or resource ownership.
    var presentationLifetimeGeneration: UInt64 { scheduler.presentationLifetimeGeneration }

    /// Read-only diagnostic evidence for a still-held lease, even when a newer
    /// commit has superseded it. This does not authorize production publication.
    /// Suspension/font/attachment changes invalidate the scheduler epoch.
    func isSamePresentationLifetime(_ work: VTFrameScheduler.Work) -> Bool {
        isActive && !needsResourceRelease && scheduler.isSamePresentationLifetime(work)
    }

    func isSamePresentationLifetime(_ completion: Completion) -> Bool {
        isSamePresentationLifetime(completion.work)
    }

    var recordsTimelines = false
    #if VT_TEST_HOOKS
    /// Holds publication after GPU completion while retaining the real GPU and
    /// scheduler leases, without exposing a surface or texture. Nil leaves
    /// production publication synchronous.
    var publicationHoldForTesting: (@MainActor () async -> Void)? = nil
    /// Synchronous post-GPU test seam immediately before the publication currency
    /// check. Nil leaves production execution and presentation leases unchanged.
    var beforeRenderedPublicationForTesting: (@MainActor () -> Void)? = nil
    /// Scalar-only accounting fault injection; can only raise the measured cost.
    /// Nil preserves production measurement and never exposes renderer resources.
    var retainedTextureBytesOverrideForTesting: Int? = nil
    #endif
    // Production builds compile these seams out; the accessors are constant nil.
    private var beforeRenderedPublication: (@MainActor () -> Void)? {
        #if VT_TEST_HOOKS
        beforeRenderedPublicationForTesting
        #else
        nil
        #endif
    }
    private var retainedTextureBytesOverride: Int? {
        #if VT_TEST_HOOKS
        retainedTextureBytesOverrideForTesting
        #else
        nil
        #endif
    }
    private var publicationHold: (@MainActor () async -> Void)? {
        #if VT_TEST_HOOKS
        publicationHoldForTesting
        #else
        nil
        #endif
    }
    private var retriedFailure = false
    private enum Failure: Error {
        case stale, unavailable
        case retainedTexturesExceedReservation(retainedBytes: Int, reservedBytes: Int)
    }
    private let scheduler = VTFrameScheduler()
    private let renderers: [VTMetalRasterizer]
    private let idleCacheBudget: VTMetalIdleCacheBudget
    private let preparationBudget: VTMetalPreparationBudget
    /// Nil only for offscreen test pipelines.
    private let ioSurfacePresenter: VTIOSurfacePresenter?
    var presentationLayer: CALayer? { ioSurfacePresenter?.layer }
    private var font: UIFont
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var needsResourceRelease = false
    private var requestFrameWhenReady = false
    private var trimAfterCompletion: Set<Int> = []
    // Scheduler occupancy includes admission waiters. Resource admission, unlike
    // renderer.busy, lasts until both GPU and presentation have drained.
    private enum SlotResourcePhase { case drained, waiting, admitted }
    private var resourcePhases: [SlotResourcePhase] = [.drained, .drained]
    // Diagnostic only: resource admission itself lasts through presentation.
    private var gpuCompletedBySlot = [false, false]

    enum OwnedImagePhase: String, Codable, Sendable {
        case waiting, preGPU, postGPUAwaitingPresentation, drained
    }
    struct OwnedImageSlot: Codable, Equatable, Sendable {
        let images: VTFrameScheduler.OwnedImageRecord
        let phase: OwnedImagePhase
    }
    struct OwnedImageDiagnostics: Codable, Equatable, Sendable {
        let pending: VTFrameScheduler.OwnedImageRecord?
        let slots: [OwnedImageSlot]
    }
    /// Overlapping per-frame ownership, not an additive allocation census. No
    /// frames, images, resources, callbacks or extra executor hops escape here.
    var ownedImageDiagnostics: OwnedImageDiagnostics {
        let ownership = scheduler.ownedImageDiagnostics
        return .init(pending: ownership.pending, slots: ownership.slots.enumerated().map { slot, images in
            let phase: OwnedImagePhase
            switch resourcePhases[slot] {
            case .drained: phase = .drained
            case .waiting: phase = .waiting
            case .admitted: phase = gpuCompletedBySlot[slot] ? .postGPUAwaitingPresentation : .preGPU
            }
            return .init(images: images, phase: phase)
        })
    }
    private var tasks: [Int: Task<Void, Never>] = [:]
    private(set) var isActive = true
    private(set) var resourceReleases = 0
    #if DEBUG
    let inactiveDrainDiagnostics = VTMetalRenderer.InactiveDrainDiagnostics()
    #endif
    private(set) var suppressedFrames = 0
    private(set) var trimmedSlots = 0
    /// Resubmit current owned state after suspension drains, without retaining
    /// a stale snapshot here while inactive. Never replay terminal bytes.
    var onNeedsFrame: (() -> Void)?
    var onResourcesReleased: (() -> Void)?
    /// Current successful GPU work only; the presentation lease remains held.
    var onRendered: ((VTFrameValue) -> Void)?
    var onComplete: ((Completion) -> Void)?
    // Diagnostic observations include obsolete geometry;
    // UI render barriers use onRendered, presentation success uses onComplete.
    var onObservation: ((Completion) -> Void)?
    var onFailure: ((any Error) -> Void)?
    // Diagnostic counterpart to onObservation: obsolete work can fail after a
    // newer presentation, while UI-facing onFailure remains suppressed.
    var onFailureObservation: ((UInt64, any Error) -> Void)?
    private(set) var completedFrames = 0
    private(set) var staleFrames = 0
    private(set) var failedFrames = 0
    private(set) var obsoleteCompletions = 0
    private var submissions = 0
    private var startedFrames = 0
    private var presentationRequests = 0
    private var gpuCompletedFrames = 0
    private var currentCompletions = 0
    private var retryRequests = 0
    private var needsFrameRequests = 0
    private var externalEpochChanges = 0
    private var lastSubmittedRevision: UInt64?
    private var lastObservedRevision: UInt64?
    private var lastCompletedRevision: UInt64?
    private var lastFailure: String?
    var diagnostics: VTMetalRenderer.Diagnostics {
        let surface = ioSurfacePresenter?.metrics
        return .init(presentationTargetCount: surface?.targetCount ?? 0,
              presentationAvailableTargets: surface?.availableTargets ?? 0,
              presentationLeasedTargets: surface?.leasedTargets ?? 0,
              presentationTargetBytes: surface?.retainedBytes ?? 0,
              presentationTargetCreations: surface?.targetCreations ?? 0,
              presentationPublications: surface?.publications ?? 0,
              presentationDiscardedPublications: surface?.discardedPublications ?? 0,
              presentationTargetAcquisitionAttempts: surface?.acquisitionAttempts ?? 0,
              presentationTargetAcquisitionSuccesses: surface?.acquisitionSuccesses ?? 0,
              presentationTargetAcquisitionStalls: surface?.acquisitionStalls ?? 0,
              presentationTargetAcquisitionTimeouts: surface?.acquisitionTimeouts ?? 0,
              presentationTargetAcquisitionCancellations: surface?.acquisitionCancellations ?? 0,
              presentationTargetAcquisitionFailures: surface?.acquisitionFailures ?? 0,
              presentationTargetPoolWaitTotalSeconds: surface?.poolWaitTotalSeconds ?? 0,
              presentationTargetPoolWaitMaxSeconds: surface?.poolWaitMaxSeconds ?? 0,
              submissions: submissions, startedFrames: startedFrames,
              presentationRequests: presentationRequests, gpuCompletedFrames: gpuCompletedFrames,
              observedCompletions: completedFrames, currentCompletions: currentCompletions,
              retryRequests: retryRequests,
              retryExhausted: retriedFailure, needsFrameRequests: needsFrameRequests,
              requestFrameWhenReady: requestFrameWhenReady, suppressedFrames: suppressedFrames,
              staleFrames: staleFrames, obsoleteCompletions: obsoleteCompletions,
              failedFrames: failedFrames, externalEpochChanges: externalEpochChanges,
              lastSubmittedRevision: lastSubmittedRevision, lastObservedRevision: lastObservedRevision,
              lastCompletedRevision: lastCompletedRevision,
              lastFailure: lastFailure)
    }
    var inFlightCount: Int { scheduler.inFlightCount }
    var pendingCount: Int { scheduler.pendingCount }
    var coalescedFrames: Int { scheduler.coalescedFrames }
    var isIdle: Bool { scheduler.isIdle }
    var imageTextureBytes: Int { renderers.reduce(0) { $0 + $1.imageTextureBytes } }
    var cachedImages: Int { renderers.reduce(0) { $0 + $1.cachedImages } }
    var cacheMetrics: CacheMetrics {
        CacheMetrics(glyphsBySlot: renderers.map(\.cachedGlyphs),
                     shapedGlyphsBySlot: renderers.map(\.shapedGlyphs),
                     glyphCacheIdentitiesBySlot: renderers.map(\.glyphCacheIdentity),
                     shapingMissesBySlot: renderers.map(\.shapingMisses),
                     imagesBySlot: renderers.map(\.cachedImages),
                     atlasTextures: renderers.filter(\.hasAtlas).count,
                     outputTextures: renderers.filter { $0.output != nil }.count,
                     imageTileTextures: renderers.filter(\.hasImageTile).count,
                     atlasTextureBytes: renderers.reduce(0) { $0 + $1.allocatedAtlasBytes },
                     outputTextureBytes: renderers.reduce(0) { $0 + $1.outputTextureBytes },
                     imageTextureBytes: imageTextureBytes,
                     imagePixelBytes: renderers.reduce(0) { $0 + $1.imagePixelBytes },
                     retainedTextureBytes: renderers.reduce(0) { $0 + $1.retainedTextureBytes })
    }

    /// Without a presenter, runs the identical GPU lease path offscreen into the
    /// rasterizers' private output textures; used by regressions.
    init(font: UIFont, ioSurfacePresenter: VTIOSurfacePresenter? = nil,
         idleCacheBudget: VTMetalIdleCacheBudget = .shared,
         preparationBudget: VTMetalPreparationBudget = .shared) throws {
        self.font = font
        self.ioSurfacePresenter = ioSurfacePresenter
        self.idleCacheBudget = idleCacheBudget
        self.preparationBudget = preparationBudget
        guard let device = ioSurfacePresenter?.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { throw Failure.unavailable }
        // Independent resource slots share submission order. Separate queues
        // could let an older, slower GPU frame overwrite a newer presentation.
        renderers = try (0..<2).map { _ in
            try VTMetalRasterizer(queue: queue, usesExternalOutput: ioSurfacePresenter != nil)
        }
    }

    func submit(_ frame: VTFrameValue, presentation: VTPresentationState = .init(),
                acceptedFrameReadyTime: Double? = nil) {
        submissions += 1
        lastSubmittedRevision = frame.revision
        guard isActive, !needsResourceRelease, !scheduler.isRetired else {
            suppressedFrames += 1
            return
        }
        guard let work = scheduler.submit(frame, presentation: presentation,
                                          acceptedFrameReadyTime: acceptedFrameReadyTime) else { return }
        start(work)
    }

    /// Font changes and terminal reattachment invalidate queued presentation,
    /// but never release resources that the GPU still uses.
    func beginEpoch(font: UIFont? = nil) {
        externalEpochChanges += 1
        if let font { self.font = font }
        scheduler.beginEpoch()
        tasks.values.forEach { $0.cancel() }
        wakeIfIdle()
    }

    /// Visual suspension does not affect VT ingestion, accepted writes or replies.
    /// Invalidate queued frames immediately; purge only after all leases drain.
    func setActive(_ active: Bool) {
        guard !scheduler.isRetired, isActive != active else { return }
        isActive = active
        if active { retriedFailure = false }
        requestFrameWhenReady = active
        if !active {
            needsResourceRelease = true
            scheduler.beginEpoch()
            tasks.values.forEach { $0.cancel() }
        }
        wakeIfIdle()
    }

    func retire() {
        guard !scheduler.isRetired else { return }
        isActive = false
        requestFrameWhenReady = false
        needsResourceRelease = true
        scheduler.retire()
        tasks.values.forEach { $0.cancel() }
        wakeIfIdle()
    }

    /// A pressure warning does not invalidate useful frames or force a redraw.
    /// Drained/admission-waiting slots release now; admitted slots release after
    /// GPU/presentation and before the next task. Native frame data is separate.
    func trimResources() {
        guard !scheduler.isRetired, !needsResourceRelease else { return }
        ioSurfacePresenter?.trimAvailableTargets()
        for slot in renderers.indices {
            if resourcePhases[slot] == .admitted { trimAfterCompletion.insert(slot) }
            else {
                idleCacheBudget.remove(renderers[slot])
                renderers[slot].releaseResources()
                trimmedSlots += 1
            }
        }
    }

    func waitForIdle() async {
        guard !isIdle else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private func start(_ work: VTFrameScheduler.Work) {
        startedFrames += 1
        let recordTimeline = recordsTimelines
        let started = recordTimeline ? CACurrentMediaTime() : nil
        let renderer = renderers[work.slot]
        precondition(resourcePhases[work.slot] == .drained)
        gpuCompletedBySlot[work.slot] = false
        // Keep idle charging until a permit owns the resources: no accounting gap.
        let requestedBytes = renderer.preparationBytes(for: work.frame, font: font)
        let waitingBytes = renderer.preparationBytes(for: work.frame, retainingCache: false, font: font)
        let immediatePermit = preparationBudget.tryAcquire(bytes: requestedBytes)
        let immediatePermitTime = recordTimeline && immediatePermit != nil ? CACurrentMediaTime() : nil
        if immediatePermit != nil {
            idleCacheBudget.remove(renderer)
            resourcePhases[work.slot] = .admitted
        } else {
            // Synchronous ownership replacement, not an asynchronous worker trim.
            // Waiting glyphs remain evictable; waitingBytes also covers their loss.
            renderer.discardTransientResources()
            idleCacheBudget.retainDrained(renderer)
            resourcePhases[work.slot] = .waiting
        }
        let font = font
        // Retain self until GPU completion even if its view is detached. There
        // are at most two such tasks; the pending snapshot has no task/resources.
        tasks[work.slot] = Task { @MainActor in
            let taskEntry = recordTimeline ? CACurrentMediaTime() : nil
            var permit = immediatePermit
            var surfaceLease: VTIOSurfacePresenter.Lease?
            defer {
                if let surfaceLease { self.ioSurfacePresenter?.discard(surfaceLease) }
            }
            do {
                // Work invalidated before this task runs must not shape glyphs,
                // allocate textures, acquire targets or submit another command.
                guard isActive, !needsResourceRelease, scheduler.isCurrent(work) else { throw Failure.stale }
                if permit == nil {
                    permit = try await preparationBudget.acquire(bytes: waitingBytes)
                    // A grant may precede task resumption: conservative double
                    // charging is safe. Transfer without an intervening await.
                    idleCacheBudget.remove(renderer)
                    resourcePhases[work.slot] = .admitted
                }
                let permitObserved = immediatePermitTime ?? (recordTimeline ? CACurrentMediaTime() : nil)
                try Task.checkCancellation()
                guard isActive, !needsResourceRelease, scheduler.isCurrent(work) else { throw Failure.stale }
                var targetAcquisitionStart: Double?, targetAcquisitionEnd: Double?
                if let presenter = self.ioSurfacePresenter {
                    if recordTimeline { targetAcquisitionStart = CACurrentMediaTime() }
                    surfaceLease = try await presenter.acquire(layout: work.frame.layout)
                    if recordTimeline { targetAcquisitionEnd = CACurrentMediaTime() }
                }
                let timing = try await renderers[work.slot].render(work.frame, font: font,
                    presentation: work.presentation, recordTimeline: recordTimeline,
                    outputTarget: surfaceLease?.target, validate: {
                    // An overflowing frame may need several commands. Check
                    // again after every GPU await before preparing another one.
                    guard self.isActive, !self.needsResourceRelease, self.scheduler.isCurrent(work) else { throw Failure.stale }
                }) { _, _ in
                    // The IOSurface is already the render target: publication
                    // happens only after GPU completion and a fresh currency check.
                    guard self.scheduler.commitPresentation(work) else { throw Failure.stale }
                }
                gpuCompletedBySlot[work.slot] = true
                // Successful facade return includes the drained worker snapshot:
                // CPU/GPU scratch is finished, but every retained texture stays
                // charged and the slot remains admitted through presentation.
                guard let activePermit = permit else { throw Failure.unavailable }
                let measuredBytes = renderer.retainedTextureBytes
                let retainedBytes = max(measuredBytes, retainedTextureBytesOverride ?? measuredBytes)
                let accountingFailure: Failure?
                if retainedBytes > activePermit.bytes {
                    // Preserve the original permit and admitted slot until the
                    // presentation drains; never clamp or publish invalid accounting.
                    accountingFailure = .retainedTexturesExceedReservation(
                        retainedBytes: retainedBytes, reservedBytes: activePermit.bytes)
                } else {
                    accountingFailure = nil
                    preparationBudget.reduce(activePermit, to: retainedBytes)
                }
                // Keep the slot through presentation too: fast GPU completion
                // must not cause unbounded target acquisition ahead of display.
                gpuCompletedFrames += 1
                if accountingFailure == nil {
                    beforeRenderedPublication?()
                    if isActive, !needsResourceRelease, scheduler.isCurrent(work) {
                        renderedWorkForDiagnostics = work
                        onRendered?(work.frame)
                        renderedWorkForDiagnostics = nil
                    }
                }
                // Reentrant callbacks may retire or change epochs. Still drain
                // presentation and recheck currency below before publishing it.
                let renderReturned = recordTimeline ? CACurrentMediaTime() : nil
                if let hold = publicationHold { await hold() }
                // Accounting failures never publish an unaccounted target; the
                // saved error is reported only after its lease drains.
                if let accountingFailure { throw accountingFailure }
                // CALayer.contents assignment has no scanout timestamp.
                if let presenter = ioSurfacePresenter,
                   isActive, !needsResourceRelease, scheduler.isCurrent(work),
                   let lease = surfaceLease {
                    try presenter.publish(lease, layout: work.frame.layout)
                    surfaceLease = nil
                    presentationRequests += 1
                }
                var timeline: Timeline?
                if let started, let taskEntry, let permitObserved, let renderReturned {
                    timeline = .init(start: started, taskEntry: taskEntry, permitObserved: permitObserved,
                        targetAcquisitionStart: targetAcquisitionStart, targetAcquisitionEnd: targetAcquisitionEnd,
                        renderReturned: renderReturned, presentationObserved: CACurrentMediaTime())
                }
                completedFrames += 1
                lastObservedRevision = work.frame.revision
                let completion = Completion(work: work, frame: work.frame, presentation: work.presentation,
                                            timing: timing, timeline: timeline)
                onObservation?(completion)
                if scheduler.isCurrent(work) {
                    retriedFailure = false
                    currentCompletions += 1
                    lastCompletedRevision = work.frame.revision
                    onComplete?(completion)
                } else { obsoleteCompletions += 1 }
            } catch Failure.stale {
                staleFrames += 1
            } catch is CancellationError {
                // Epoch/suspension cancellation stops CPU preparation. Already
                // committed GPU/presentation work still drains its lease.
                staleFrames += 1
            } catch {
                failedFrames += 1
                lastFailure = String(describing: error)
                onFailureObservation?(work.frame.revision, error)
                if scheduler.isCurrent(work) {
                    onFailure?(error)
                    // A transient failure (no target, GPU error) leaves an
                    // idle screen stale: the scheduler would reject resubmitting
                    // the same frame. Retry once with duplicate suppression reset,
                    // bounded so a persistent failure cannot spin.
                    if !retriedFailure {
                        retriedFailure = true
                        retryRequests += 1
                        scheduler.beginEpoch()
                        requestFrameWhenReady = true
                    }
                }
            }
            // Return an unpublished IOSurface before idle/resource callbacks can
            // observe the presenter as drained.
            if let lease = surfaceLease {
                ioSurfacePresenter?.discard(lease)
                surfaceLease = nil
            }
            tasks.removeValue(forKey: work.slot)
            let next = scheduler.complete(work)
            resourcePhases[work.slot] = .drained
            gpuCompletedBySlot[work.slot] = false
            let trimPending = trimAfterCompletion.remove(work.slot) != nil
            if trimPending || needsResourceRelease || scheduler.isRetired {
                // Purge this completed slot before returning its permit, even
                // when another lease still delays global release notification.
                idleCacheBudget.remove(renderer)
                renderer.releaseResources()
                if trimPending { trimmedSlots += 1 }
            } else {
                // scheduler.complete may already have assigned next work here;
                // its resources are nevertheless drained until start(next).
                idleCacheBudget.retainDrained(renderer)
            }
            if let permit { preparationBudget.release(permit) }
            if let next { start(next) }
            wakeIfIdle()
        }
    }

    private func wakeIfIdle() {
        guard isIdle else { return }
        if needsResourceRelease {
            needsResourceRelease = false
            trimAfterCompletion.removeAll()
            ioSurfacePresenter?.clear()
            renderers.forEach {
                idleCacheBudget.remove($0)
                $0.releaseResources()
            }
            resourceReleases += 1
            #if DEBUG
            // Capture the real drained scheduler before reentrant callbacks or
            // facade/pipeline release can erase the observation interval.
            if !isActive {
                inactiveDrainDiagnostics.record(pending: pendingCount, inFlight: inFlightCount)
            }
            #endif
            onResourcesReleased?()
        }
        // Callbacks may change activity or submit the fresh frame synchronously.
        guard isIdle else { return }
        if isActive, requestFrameWhenReady, !scheduler.isRetired {
            requestFrameWhenReady = false
            needsFrameRequests += 1
            onNeedsFrame?()
        }
        guard isIdle else { return }
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// Pre-creates the device, a command queue and both BGRA pipelines so the first
    /// rendered frame does not pay one-time driver setup costs (mirrors
    /// ghostty's Metal.warmup). Safe off the main thread; call at app startup.
    nonisolated static func warmup() {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        _ = device.makeCommandQueue()
        _ = try? VTMetalRasterizer.makePipeline(device: device, pixelFormat: .bgra8Unorm)
        _ = try? VTMetalRasterizer.makeBgPipeline(device: device, pixelFormat: .bgra8Unorm)
    }
}

/// A scene can be inactive while another scene keeps the application active.
/// Observe both gates, and ignore activity from unrelated scenes. The view
/// owner retains this binding; it does not extend the pipeline/scene lifetime.
@MainActor
final class VTMetalSceneActivity: NSObject {
    private weak var pipeline: VTMetalFramePipeline?
    private weak var scene: UIScene?
    private let notifications: NotificationCenter
    private var applicationActive: Bool
    private var sceneActive: Bool
    private let presentationAllowed: () -> Bool

    init(pipeline: VTMetalFramePipeline, scene: UIScene, notifications: NotificationCenter = VTLifecycleNotifications.center,
         presentationAllowed: @escaping () -> Bool = { true }) {
        self.pipeline = pipeline
        self.scene = scene
        self.notifications = notifications
        self.presentationAllowed = presentationAllowed
        applicationActive = UIApplication.shared.applicationState == .active
        sceneActive = scene.activationState == .foregroundActive
        super.init()
        for name in [UIApplication.willResignActiveNotification, UIApplication.didBecomeActiveNotification] {
            notifications.addObserver(self, selector: #selector(applicationChanged(_:)), name: name, object: nil)
        }
        for name in [UIScene.willDeactivateNotification, UIScene.didActivateNotification, UIScene.didDisconnectNotification] {
            notifications.addObserver(self, selector: #selector(sceneChanged(_:)), name: name, object: nil)
        }
        notifications.addObserver(self, selector: #selector(memoryWarning),
                                  name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        update()
    }

    deinit { notifications.removeObserver(self) }

    @objc private func applicationChanged(_ notification: Notification) {
        applicationActive = notification.name == UIApplication.didBecomeActiveNotification
        update()
    }

    @objc private func sceneChanged(_ notification: Notification) {
        guard let changed = notification.object as? UIScene, changed === scene else { return }
        sceneActive = notification.name == UIScene.didActivateNotification
        update()
    }

    func update() { pipeline?.setActive(applicationActive && sceneActive && scene != nil && presentationAllowed()) }

    @objc private func memoryWarning() { pipeline?.trimResources() }
}
