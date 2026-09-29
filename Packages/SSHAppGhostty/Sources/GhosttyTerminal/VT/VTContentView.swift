import GhosttyVT
import QuartzCore
import UIKit

/// VT-backed terminal content: presents owned engine frames with bounded Metal
/// work. CoreText is only a recovery path when Metal is unavailable.
///
/// The coordinator owns the `VTTerminalSession` (SSH wiring, viewport
/// readiness) and attaches it here; this view only measures its font,
/// publishes layout metrics, feeds bytes, and paints snapshots. Frame
/// requests coalesce newest-wins; terminal bytes, replies, and events are
/// never coalesced. Native chrome (handles, menus, keyboard, IME) stays in
/// the hosting `UITerminalView`. Created and owned by `TerminalSurface`.
@MainActor
public final class VTContentView: UIView {
    var font: UIFont = .monospacedSystemFont(ofSize: 12, weight: .regular) {
        didSet {
            guard font != oldValue else { return }
            invalidateGeometry()
            updateViewport()
        }
    }

    var padding: Double = 8 {
        didSet { if padding != oldValue { updateViewport() } }
    }

    var hoveredLink: VTLinkHighlight? {
        didSet {
            presentation.hoveredLink = hoveredLink
            presentFrame()
        }
    }

    /// Test and preview override; production uses the attached window scale.
    var forcedScale: CGFloat? {
        didSet {
            guard forcedScale != oldValue, !isApplyingHostViewport else { return }
            updateViewport()
        }
    }
    private var isApplyingHostViewport = false

    /// Applies host size and scale as one viewport admission. Setting
    /// forcedScale before the frame would publish old size + new scale first,
    /// and the remote would see two SIGWINCHs for one host change.
    func updateViewport(size: CGSize, scale: CGFloat) {
        let frame = CGRect(origin: .zero, size: size)
        let scaleChanged = forcedScale != scale
        isApplyingHostViewport = true
        forcedScale = scale
        isApplyingHostViewport = false
        if scaleChanged || self.frame != frame {
            self.frame = frame
            setNeedsLayout()
        }
        layoutIfNeeded()
    }

    var terminalFocused = true {
        didSet {
            guard terminalFocused != oldValue else { return }
            configureBlink()
            presentFrame()
        }
    }

    /// Semantic updates are published only after geometry/attachment acceptance.
    var onFrame: ((VTFrameValue) -> Void)?
    /// Successful GPU render of the current Metal frame or CoreText draw.
    /// Not display/scanout or snapshot freshness; snapshot callers must still
    /// request afterScreenUpdates (including the selection magnifier).
    var onRendered: ((VTFrameValue) -> Void)?

    /// The host owns IME state and UTF-16 selection. This is visual preedit only,
    /// not another input responder or terminal mutation.
    var markedText = "" {
        didSet { updateMarkedText() }
    }
    private let markedTextOverlay = VTMarkedTextOverlay()
    private let scrollRefresh = VTScrollRefreshDriver()
    private(set) var frameValue: VTFrameValue? {
        didSet { if frameValue == nil { acceptedFrameReadyTime = nil } }
    }
    /// Opt-in scalar diagnostics; timestamp the accepted snapshot, not redraws.
    var recordsFrameReadyTimes = false {
        didSet { if !recordsFrameReadyTimes { acceptedFrameReadyTime = nil } }
    }
    private var acceptedFrameReadyTime: Double?
    private var session: VTTerminalSession?
    #if DEBUG
    func enqueueLifecycleAcceptanceQuery() -> Task<VTLifecycleEngineScalars, Error>? {
        session?.enqueueLifecycleAcceptanceQuery()
    }
    var lifecycleSessionIdentity: String? { session.map { String(describing: ObjectIdentifier($0)) } }
    var lifecycleRenderCompletions: Int { acceptedRenderCallbacks }
    /// Opt-in, scalar-only accepted GPU evidence. Layer publication is a
    /// separate event and may be delayed or obsolete after render.
    var recordsLifecycleRenderCompletions = false {
        didSet { if !recordsLifecycleRenderCompletions { lifecycleRenderedFrame = nil } }
    }
    private struct LifecycleRenderedFrame {
        let epoch: UInt64
        let terminalID: UUID
        let generation: UInt64
        let revision: UInt64
    }
    private var lifecycleRenderedFrame: LifecycleRenderedFrame?
    var lifecycleRenderedRevision: UInt64? {
        guard recordsLifecycleRenderCompletions, isPresentationActive, metalRenderer != nil,
              let completed = lifecycleRenderedFrame, let frame = frameValue,
              completed.epoch == presentationEpoch, completed.terminalID == frame.terminalID,
              completed.generation == frame.layout.generation, completed.revision == frame.revision else { return nil }
        return completed.revision
    }
    #endif
    private var frameObserverToken: UUID?
    private var glyphCache = VTGlyphCache()
    private(set) var metalRenderer: VTMetalRenderer?
    /// Scalar failure evidence survives recovery without retaining GPU resources.
    private(set) var metalFailureDescription: String?
    private(set) var isPresentationActive = false
    private(set) var snapshotExtractions = 0
    private var needsFrame = false
    private var presentationEpoch: UInt64 = 0
    /// Read-only test diagnostics: hide/resume can invalidate content before the
    /// pipeline's asynchronous visibility epoch catches up.
    var presentationEpochForDiagnostics: UInt64 { presentationEpoch }
    private var requestedMetrics: VTTerminalSessionMetrics?
    private var applicationActive = UIApplication.shared.applicationState == .active
    private var sceneActiveOverride: Bool?
    private var visibilityObservations: [NSKeyValueObservation] = []
    private let blinkDriver = VTBlinkDriver()
    private var presentation = VTPresentationState()
    private var frameTask: Task<Void, Never>?
    /// Read-only test observation of admitted/coalesced snapshot work. Reading
    /// this must not extract a frame or change the presentation epoch.
    var hasPendingSnapshotWorkForDiagnostics: Bool {
        isPresentationActive && (needsFrame || frameTask != nil)
    }
    private var acceptedExtraction = 0
    private var renderBarrierExtraction = 0
    private struct FrameCompletion {
        let minimumExtraction: Int
        let action: (VTFrameValue) -> Void
    }
    private var frameCompletions: [FrameCompletion] = []
    private var rejectedSnapshots = 0
    private var receivedRenderCallbacks = 0
    private var acceptedRenderCallbacks = 0

    /// Timeout-only observation: bounded scalar state, never terminal contents.
    /// The renderer counters distinguish skipped/retried presentations from
    /// obsolete GPU work and from callbacks rejected at this ownership boundary.
    var renderDiagnostics: String {
        let metal = metalRenderer.map { renderer in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return (try? encoder.encode(renderer.diagnostics)).flatMap {
                String(data: $0, encoding: .utf8)
            } ?? "unavailable"
        } ?? "none"
        return "epoch=\(presentationEpoch) extraction=\(snapshotExtractions) accepted=\(acceptedExtraction) "
            + "barrier=\(renderBarrierExtraction) rejectedSnapshots=\(rejectedSnapshots) "
            + "needsFrame=\(needsFrame) snapshotTask=\(frameTask != nil) "
            + "orderedCallbacks=\(frameCompletions.count) "
            + "minimumExtraction=\(String(describing: frameCompletions.map(\.minimumExtraction).min())) "
            + "renderCallbacks=\(receivedRenderCallbacks) acceptedRenderCallbacks=\(acceptedRenderCallbacks) "
            + "active=\(isPresentationActive) metalActive=\(metalRenderer?.isActive == true) "
            + "inFlight=\(metalRenderer?.inFlightCount ?? -1) pending=\(metalRenderer?.pendingCount ?? -1) "
            + "metal=\(metal) recovery=\(metalFailureDescription ?? "none")"
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isOpaque = true
        contentMode = .redraw
        registerForTraitChanges([UITraitDisplayScale.self]) { (view: VTContentView, _: UITraitCollection) in
            view.updateViewport()
        }
        do {
            metalRenderer = try VTMetalRenderer(font: font)
        } catch {
            metalFailureDescription = "initialization: \(error)"
        }
        if let metalRenderer {
            layer.insertSublayer(metalRenderer.presentationLayer, at: 0)
            metalRenderer.onNeedsFrame = { [weak self] in self?.requestFrame() }
            metalRenderer.onFailure = { [weak self] error in
                self?.metalFailureDescription = "render: \(error)"
                self?.recoverWithCoreText()
            }
            metalRenderer.onRendered = { [weak self] frame in self?.didRender(frame) }
        }
        markedTextOverlay.isUserInteractionEnabled = false
        addSubview(markedTextOverlay)
        blinkDriver.onChange = { [weak self] in
            guard let self else { return }
            presentation = blinkDriver.presentation
            presentation.hoveredLink = hoveredLink
            presentFrame()
        }
        // App/scene lifecycle and memory warnings are injectable for tests;
        // window visibility and Reduce Motion always come from UIKit.
        let lifecycle = VTLifecycleNotifications.center
        for name in [UIApplication.willResignActiveNotification, UIApplication.didBecomeActiveNotification,
                     UIScene.willDeactivateNotification, UIScene.didActivateNotification,
                     UIScene.didDisconnectNotification] {
            lifecycle.addObserver(self, selector: #selector(activityChanged(_:)), name: name, object: nil)
        }
        for name in [UIWindow.didBecomeVisibleNotification, UIWindow.didBecomeHiddenNotification,
                     UIAccessibility.reduceMotionStatusDidChangeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(activityChanged(_:)), name: name, object: nil)
        }
        lifecycle.addObserver(self, selector: #selector(trimResources),
                              name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        // Snapshot resources before passing the dying view to Foundation. Only
        // renderer retirement needs the main actor; observer removal is locked.
        let token = frameObserverToken
        let session = session
        let task = frameTask
        let renderer = metalRenderer
        NotificationCenter.default.removeObserver(self)
        if let token { session?.removeFrameObserver(token) }
        task?.cancel()
        // Admit immediately once deinit runs; UIKit can defer deinit itself.
        session?.enqueueReleaseSnapshotCache()
        cleanupOnMainActor { renderer?.retire() }
    }

    func attach(_ session: VTTerminalSession) {
        if self.session !== session { detach() }
        self.session = session
        if let frameObserverToken { session.removeFrameObserver(frameObserverToken) }
        frameObserverToken = session.observeFrames { [weak self] in
            self?.requestFrame()
        }
        updateViewport()
        reconcileActivity()
        requestFrame()
    }

    func detach() {
        // Keep the one outstanding snapshot slot until its actor hop returns.
        // Cancellation alone does not stop a native snapshot already admitted.
        presentationEpoch &+= 1
        frameCompletions.removeAll()
        scrollRefresh.cancel()
        markedText = ""
        needsFrame = false
        if let frameObserverToken { session?.removeFrameObserver(frameObserverToken) }
        frameObserverToken = nil
        session?.enqueueReleaseSnapshotCache()
        session = nil
        requestedMetrics = nil
        frameValue = nil
        metalRenderer?.beginEpoch(font: font)
        reconcileActivity()
        metalRenderer?.presentationLayer.isHidden = true
        configureBlink()
        setNeedsDisplay()
    }

    func feed(_ data: Data) {
        session?.receive(data)
        requestFrame()
    }

    func refresh() {
        requestFrame()
    }

    /// Call for each local scroll update (including deceleration), not terminal
    /// output. True pulses bounded demand; false ends the interaction immediately.
    func setScrollInteractionActive(_ active: Bool) {
        if active && isPresentationActive { scrollRefresh.pulse(host: self) }
        else { scrollRefresh.cancel() }
    }

    /// Read-only observation of the scene policy's existing input-driven link.
    /// No observer-created link, requested rate change, or extension of idle tail.
    var onScrollRefreshForDiagnostics: ((VTScrollRefreshSample) -> Void)? {
        get { scrollRefresh.onRefreshForDiagnostics }
        set { scrollRefresh.onRefreshForDiagnostics = newValue }
    }

    // MARK: - Synchronous frame queries for host UI

    func hasSelection() -> Bool {
        frameValue?.hasSelection == true
    }

    func selectedText() -> String {
        frameValue?.selectedText() ?? ""
    }

    func selectionContains(_ point: CGPoint) -> Bool {
        guard let frame = frameValue,
              let cell = frame.layout.cell(at: point)
        else { return false }
        return frame.contains(column: cell.column, row: cell.row)
    }

    func cursorRect() -> CGRect? {
        frameValue?.cursorRect()
    }

    func isMouseTracking() -> Bool {
        frameValue?.mouseTracking == true
    }

    func gridPaddingPixels() -> (left: UInt32, top: UInt32)? {
        guard let frame = frameValue else { return nil }
        let pixels = UInt32((frame.layout.padding * frame.layout.scale).rounded())
        return (pixels, pixels)
    }

    /// Host-measured layout metrics for an explicit size, using this view's font.
    func metrics(for size: CGSize, scale: CGFloat) -> VTTerminalSessionMetrics? {
        guard size.width.isFinite, size.height.isFinite, scale.isFinite,
              size.width > 0, size.height > 0, scale > 0 else { return nil }
        let cellWidth = ceil(("M" as NSString).size(withAttributes: [.font: font]).width * scale) / scale
        let cellHeight = ceil(font.lineHeight * scale) / scale
        guard cellWidth > 0, cellHeight > 0 else { return nil }
        return VTTerminalSessionMetrics(
            width: (size.width * scale).rounded() / scale,
            height: (size.height * scale).rounded() / scale,
            cellWidth: cellWidth,
            cellHeight: cellHeight,
            scale: scale,
            padding: (padding * scale).rounded() / scale
        )
    }

    override public func layoutSubviews() {
        super.layoutSubviews()
        updateViewport()
        reconcileActivity()
    }

    override public func draw(_ rect: CGRect) {
        // Never rasterize a second UIKit backing store alongside Metal.
        guard metalRenderer == nil, isPresentationActive, let frame = frameValue,
              let context = UIGraphicsGetCurrentContext()
        else { return }
        VTCoreTextRenderer.draw(
            frame,
            font: font,
            context: context,
            bounds: bounds,
            cache: glyphCache,
            presentation: presentation
        )
        didRender(frame)
    }

    private var resolvedScale: CGFloat {
        if let forcedScale, forcedScale > 0 { return forcedScale }
        if let scale = window?.windowScene?.screen.scale, scale > 0 { return scale }
        if traitCollection.displayScale > 0 { return traitCollection.displayScale }
        return UIScreen.main.scale
    }

    /// Completion requires a snapshot requested AFTER registration, then a
    /// successful render containing it (or a newer accepted snapshot). An old
    /// pending snapshot/render cannot satisfy it, even for unchanged VT state.
    /// GPU rendering does not establish display or UIKit snapshot freshness.
    /// Attachment, geometry, and visibility epoch changes discard callbacks.
    func requestFrame(completion: ((VTFrameValue) -> Void)? = nil) {
        if let completion {
            guard session != nil else { return }
            frameCompletions.append(.init(minimumExtraction: snapshotExtractions + 1, action: completion))
        }
        needsFrame = true
        guard isPresentationActive, frameTask == nil else { return }
        // One extraction plus one dirty bit, not a cancel/recreate task per byte
        // notification. The weak owner is not held over the session actor hop.
        frameTask = Task { [weak self] in
            while let request = self?.takeSnapshotRequest() {
                let frame = try? await request.snapshot.value
                self?.accept(frame, epoch: request.epoch, extraction: request.extraction)
            }
            self?.frameTask = nil
        }
    }

    private func takeSnapshotRequest() -> (snapshot: Task<VTFrameValue, Error>, epoch: UInt64, extraction: Int)? {
        guard isPresentationActive, needsFrame, let session else { return nil }
        needsFrame = false
        // Admit before yielding the main actor: hide/detach must enqueue cache
        // release AFTER this extraction, or an obsolete snapshot could refill it.
        guard let snapshot = session.enqueueSnapshot() else { return nil }
        snapshotExtractions += 1
        return (snapshot, presentationEpoch, snapshotExtractions)
    }

    private func accept(_ frame: VTFrameValue?, epoch: UInt64, extraction: Int) {
        guard isPresentationActive, epoch == presentationEpoch,
              let frame, let metrics = requestedMetrics,
              frame.layout.viewportWidth == metrics.width,
              frame.layout.viewportHeight == metrics.height,
              frame.layout.cellWidth == metrics.cellWidth,
              frame.layout.cellHeight == metrics.cellHeight,
              frame.layout.scale == metrics.scale,
              frame.layout.padding == metrics.padding else {
            rejectedSnapshots += 1
            return
        }
        acceptedFrameReadyTime = recordsFrameReadyTimes ? CACurrentMediaTime() : nil
        frameValue = frame
        acceptedExtraction = extraction
        if frameCompletions.contains(where: {
            $0.minimumExtraction > renderBarrierExtraction && $0.minimumExtraction <= extraction
        }) {
            // Also reset duplicate-revision suppression: a fresh extraction of
            // unchanged state must render after registration, not reuse old work.
            metalRenderer?.beginEpoch(font: font)
            renderBarrierExtraction = extraction
        }
        configureBlink()
        updateMarkedText()
        onFrame?(frame)
        // Host callbacks can synchronously detach, resize, or replace the session.
        guard epoch == presentationEpoch, acceptedExtraction == extraction else { return }
        presentFrame()
    }

    private func didRender(_ frame: VTFrameValue) {
        receivedRenderCallbacks += 1
        guard isPresentationActive, frameValue == frame else { return }
        acceptedRenderCallbacks += 1
        #if DEBUG
        if recordsLifecycleRenderCompletions, metalRenderer != nil {
            lifecycleRenderedFrame = .init(epoch: presentationEpoch, terminalID: frame.terminalID,
                generation: frame.layout.generation, revision: frame.revision)
        }
        #endif
        let epoch = presentationEpoch
        let ready = frameCompletions.filter { $0.minimumExtraction <= acceptedExtraction }
        frameCompletions.removeAll { $0.minimumExtraction <= acceptedExtraction }
        onRendered?(frame)
        for completion in ready {
            guard epoch == presentationEpoch else { return }
            completion.action(frame)
        }
    }

    private func updateMarkedText() {
        markedTextOverlay.frame = bounds
        markedTextOverlay.font = font
        markedTextOverlay.text = markedText
        markedTextOverlay.cursorRect = frameValue?.cursorRect() ?? .zero
        markedTextOverlay.isHidden = !isPresentationActive || frameValue == nil || markedText.isEmpty
        markedTextOverlay.setNeedsDisplay()
    }

    private func presentFrame() {
        guard isPresentationActive, let frame = frameValue else { return }
        if let metalRenderer {
            // The renderer reveals its current presentation layer together with
            // frame geometry on IOSurface publication.
            metalRenderer.submit(frame, presentation: presentation,
                                 acceptedFrameReadyTime: acceptedFrameReadyTime)
        } else { setNeedsDisplay() }
    }

    private func configureBlink() {
        blinkDriver.configure(frame: frameValue, active: isPresentationActive,
                              focused: terminalFocused, reduceMotion: UIAccessibility.isReduceMotionEnabled)
        presentation = blinkDriver.presentation
        presentation.hoveredLink = hoveredLink
    }

    private func invalidateGeometry() {
        presentationEpoch &+= 1
        frameCompletions.removeAll()
        frameValue = nil
        updateMarkedText()
        glyphCache = VTGlyphCache()
        metalRenderer?.beginEpoch(font: font)
        configureBlink()
    }

    private func updateViewport() {
        let metrics = metrics(for: bounds.size, scale: resolvedScale)
        if metrics != requestedMetrics {
            requestedMetrics = metrics
            invalidateGeometry()
        }
        session?.updateViewport(metrics)
        requestFrame()
    }

    override public func didMoveToWindow() {
        super.didMoveToWindow()
        sceneActiveOverride = nil
        observeVisibility()
        updateViewport()
        reconcileActivity()
    }

    override public func didMoveToSuperview() {
        super.didMoveToSuperview()
        observeVisibility()
        reconcileActivity()
    }

    /// SwiftUI can reparent an ancestor without moving this content view. Refresh
    /// the observed chain after the host's visibility transaction has settled.
    func hostVisibilityDidChange() {
        observeVisibility()
        reconcileActivity()
    }

    private func observeVisibility() {
        visibilityObservations.removeAll()
        var ancestor: UIView? = self
        while let view = ancestor {
            visibilityObservations.append(view.observe(\.isHidden) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.reconcileActivity() }
            })
            visibilityObservations.append(view.observe(\.alpha) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.reconcileActivity() }
            })
            ancestor = view.superview
        }
    }

    private var isVisible: Bool {
        guard window != nil, session != nil, requestedMetrics != nil else { return false }
        var ancestor: UIView? = self
        while let view = ancestor {
            guard !view.isHidden, view.alpha > 0.01 else { return false }
            ancestor = view.superview
        }
        return true
    }

    private func reconcileActivity() {
        let sceneActive = sceneActiveOverride ?? (window?.windowScene).map {
            $0.activationState == .foregroundActive
        } ?? true
        let active = applicationActive && sceneActive && isVisible
        guard active != isPresentationActive else { configureBlink(); return }
        isPresentationActive = active
        scrollRefresh.visibilityChanged()
        if !active {
            presentationEpoch &+= 1
            frameCompletions.removeAll()
            scrollRefresh.cancel()
            frameValue = nil
            glyphCache = VTGlyphCache()
            session?.enqueueReleaseSnapshotCache()
            metalRenderer?.presentationLayer.isHidden = true
        }
        metalRenderer?.setActive(active)
        updateMarkedText()
        configureBlink()
        if active { requestFrame() }
    }

    @objc private func activityChanged(_ notification: Notification) {
        switch notification.name {
        case UIApplication.willResignActiveNotification: applicationActive = false
        case UIApplication.didBecomeActiveNotification: applicationActive = true
        case UIScene.willDeactivateNotification, UIScene.didActivateNotification, UIScene.didDisconnectNotification:
            guard let scene = notification.object as? UIScene, scene === window?.windowScene else { return }
            sceneActiveOverride = notification.name == UIScene.didActivateNotification
        default: break
        }
        reconcileActivity()
    }

    @objc private func trimResources() {
        glyphCache = VTGlyphCache()
        session?.enqueueReleaseSnapshotCache()
        metalRenderer?.trimResources()
    }

    private func recoverWithCoreText() {
        // Retire, rather than reuse, any failed GPU leases. The owned frame is
        // still valid and CoreText can recover without touching terminal bytes.
        metalRenderer?.retire()
        metalRenderer?.presentationLayer.removeFromSuperlayer()
        metalRenderer = nil
        if isPresentationActive { setNeedsDisplay() }
    }
}

/// Transparent UIKit overlay sits above either renderer. UIFont/NSString use
/// the same shaping as the host's IME geometry, including non-ASCII preedit.
@MainActor
private final class VTMarkedTextOverlay: UIView {
    var text = ""
    var font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    var cursorRect = CGRect.zero

    init() {
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        clipsToBounds = true
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        guard !text.isEmpty, !cursorRect.isEmpty else { return }
        (text as NSString).draw(in: CGRect(x: cursorRect.minX, y: cursorRect.minY,
            width: max(0, bounds.maxX - cursorRect.minX), height: cursorRect.height * 2),
            withAttributes: [.font: font, .foregroundColor: UIColor.white,
                .backgroundColor: UIColor.darkGray, .underlineStyle: NSUnderlineStyle.single.rawValue])
    }
}
