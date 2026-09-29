import GhosttyVT
import UIKit

/// Coordinates disposable native hosts, not terminal engine lifetime. Metal and
/// VTContentView own bounded frame scheduling.
@MainActor
final class TerminalSurfaceCoordinator {
    weak var delegate: (any TerminalSurfaceViewDelegate)? {
        didSet { surface?.session.setEventDelegate(delegate, owner: eventDelegateOwner) }
    }
    var controller: TerminalController? {
        didSet {
            guard controller !== oldValue else { return }
            // A controller reassignment changes configuration ownership; removing
            // a disposable host does not. Remove this host before checking for
            // other hosts that still share the old controller/session.
            oldValue?.unregisterVTHost(self)
            if case let .vt(session) = configuration.backend {
                oldValue?.unregisterVTSession(session)
                controller?.registerVTSession(session)
            }
            rebuildIfReady()
        }
    }
    var configuration: TerminalSurfaceOptions = .init() {
        didSet {
            guard !configuration.isEquivalent(to: oldValue) else { return }
            if case let .vt(session) = configuration.backend {
                controller?.registerVTSession(session)
            }
            rebuildIfReady()
        }
    }
    private let eventDelegateOwner = UUID()
    private(set) var surface: TerminalSurface?
    private var surfaceController: TerminalController?
    private var lastMetrics: TerminalViewportMetrics?
    private var announcedSurface = false
    private var lifecycleEpoch: UInt64 = 0
    private var isDetaching = false
    private var rebuildAfterDetach = false
    private var isDisplayVisible = true
    private var isApplicationActive = true
    private var isSurfaceFocused = false
    /// Whether the delegate has observed the current `isSurfaceFocused` value.
    /// Programmatic sync changes focus silently; the next notifying call for
    /// that same value must still report it once.
    private var hasNotifiedSurfaceFocus = true

    // MARK: - Host hooks

    var isAttached: () -> Bool = { false }
    var scaleFactor: () -> Double = { 2 }
    var viewSize: () -> (width: Double, height: Double) = { (0, 0) }
    weak var platformOwner: AnyObject?
    var fontSize: (() -> CGFloat)?
    var onSurfaceCreated: ((TerminalSurface) -> Void)?
    /// Runs while the retiring host is still current, so native interactions
    /// can admit their cancel into the surviving session before detach.
    var onSurfaceWillDetach: ((TerminalSurface) -> Void)?
    var onSurfaceFreed: ((TerminalSurface) -> Void)?
    var onFrame: ((VTFrameValue) -> Void)?
    var onPostRender: (() -> Void)?
    var onMetricsUpdate: (() -> Void)?
    var onCellSizeDidChange: (() -> Void)?

    func rebuildIfReady() {
        lifecycleEpoch &+= 1
        let epoch = lifecycleEpoch
        if isDetaching {
            rebuildAfterDetach = true
            return
        }
        detachSurface()
        // External teardown hooks may synchronously build a replacement.
        guard lifecycleEpoch == epoch else { return }
        buildSurfaceIfReady()
    }

    private func buildSurfaceIfReady() {
        guard surface == nil, let controller, isAttached(), validGeometry,
              case let .vt(session) = configuration.backend else { return }
        let newSurface = TerminalSurface(session: session)
        surface = newSurface
        surfaceController = controller
        controller.registerVTHost(self)
        session.setEventDelegate(delegate, owner: eventDelegateOwner)
        // Retained metadata replay is a callout and may replace this host.
        guard surface === newSurface else { return }
        newSurface.setOcclusion(effectiveSurfaceVisible)
        newSurface.contentView.onFrame = { [weak self, weak newSurface] frame in
            guard let self, let newSurface, self.surface === newSurface else { return }
            self.accept(frame, from: newSurface)
        }
        newSurface.contentView.onRendered = { [weak self, weak newSurface] frame in
            guard let self, let newSurface, self.isCurrent(frame, surface: newSurface) else { return }
            self.onPostRender?()
        }
        // Installation precedes layout. The first lifecycle attach follows an
        // accepted native snapshot, never the provisional host measurement.
        onSurfaceCreated?(newSurface)
        guard surface === newSurface else { return }
        synchronizeMetrics()
        guard surface === newSurface else { return }
        // Admit focus after layout creation in the same session FIFO.
        newSurface.setFocus(isSurfaceFocused)
        requestImmediateTick()
    }

    func synchronizeMetrics() {
        guard let surface, let controller = surfaceController, validGeometry else { return }
        let fontSize = fontSize?() ?? CGFloat(configuration.fontSize ?? controller.vtFontSize)
        surface.setContentFont(Self.resolveFont(family: controller.vtFontFamily, size: fontSize))
        surface.setContentPadding(controller.vtPadding)
        let size = viewSize()
        surface.updateViewport(size: CGSize(width: size.width, height: size.height), scale: scaleFactor())
        // Delegates are notified by accept(), after the session FIFO has applied
        // this layout and VTContentView has checked its current geometry epoch.
    }

    private func accept(_ frame: VTFrameValue, from currentSurface: TerminalSurface) {
        guard isCurrent(frame, surface: currentSurface), let grid = currentSurface.size() else { return }
        rearmInvalidatedDraws(on: currentSurface)
        let metrics = TerminalViewportMetrics(surfaceSize: grid, scale: frame.layout.scale)
        let previous = lastMetrics
        if metrics != previous {
            lastMetrics = metrics
            if let delegate = delegate as? any TerminalSurfaceGridResizeDelegate {
                delegate.terminalDidResize(grid)
            } else if let delegate = delegate as? any TerminalSurfaceResizeDelegate {
                delegate.terminalDidResize(columns: Int(grid.columns), rows: Int(grid.rows))
            }
            guard isCurrent(frame, surface: currentSurface) else { return }
            if previous?.surfaceSize.cellWidthPixels != grid.cellWidthPixels
                || previous?.surfaceSize.cellHeightPixels != grid.cellHeightPixels {
                onCellSizeDidChange?()
                guard isCurrent(frame, surface: currentSurface) else { return }
            }
        }
        onMetricsUpdate?()
        guard isCurrent(frame, surface: currentSurface) else { return }
        if !announcedSurface {
            announcedSurface = true
            (delegate as? any TerminalSurfaceLifecycleDelegate)?.terminalDidAttachSurface(currentSurface)
            guard isCurrent(frame, surface: currentSurface) else { return }
        }
        onFrame?(frame)
    }

    private func isCurrent(_ frame: VTFrameValue, surface candidate: TerminalSurface) -> Bool {
        surface === candidate && candidate.frameValue == frame
    }

    func fitToSize() {
        if surface == nil { rebuildIfReady() }
        else { synchronizeMetrics() }
        requestImmediateTick()
    }

    func setDisplayVisible(_ visible: Bool) {
        isDisplayVisible = visible
        if !visible { dropPendingDraws() }
        surface?.setOcclusion(effectiveSurfaceVisible)
        if visible { requestImmediateTick() }
    }

    func setApplicationActive(_ active: Bool) {
        isApplicationActive = active
        if !active { dropPendingDraws() }
        surface?.setOcclusion(effectiveSurfaceVisible)
        if active {
            synchronizeMetrics()
            requestImmediateTick()
        }
    }

    func requestImmediateTick() {
        guard effectiveSurfaceVisible, isAttached() else { return }
        surface?.refresh()
    }

    /// Completion is tied to a newly requested, successfully rendered snapshot.
    /// The content view fences geometry/visibility epochs; identity fences a
    /// replaced host, including replacements triggered from onPostRender.
    ///
    /// A geometry change on the same visible host (keyboard/accessory insets,
    /// rotation) discards the content view's pending callback but not this
    /// request: the next accepted frame of the new geometry re-arms it, so the
    /// completion still follows a render of the current geometry. Completion is
    /// dropped, never invoked, when the host is hidden, detached, inactive, or
    /// replaced before render; callers must not use it as a release barrier.
    func requestImmediateDraw(completion: @escaping @MainActor () -> Void) {
        guard effectiveSurfaceVisible, isAttached(), let surface else { return }
        nextPendingDrawID &+= 1
        let draw = PendingDraw(
            id: nextPendingDrawID,
            surface: ObjectIdentifier(surface),
            epoch: surface.contentView.presentationEpochForDiagnostics,
            completion: completion
        )
        pendingDraws.append(draw)
        armPendingDraw(id: draw.id, on: surface)
    }

    private struct PendingDraw {
        let id: UInt64
        let surface: ObjectIdentifier
        var epoch: UInt64
        let completion: @MainActor () -> Void
    }

    private var pendingDraws: [PendingDraw] = []
    private var nextPendingDrawID: UInt64 = 0

    private func armPendingDraw(id: UInt64, on surface: TerminalSurface) {
        surface.contentView.requestFrame { [weak self, weak surface] frame in
            guard let self, let surface, self.surface === surface,
                  let index = self.pendingDraws.firstIndex(where: { $0.id == id })
            else { return }
            guard self.isCurrent(frame, surface: surface) else {
                // A post-render callout changed the accepted frame on this
                // same host; wait for a render of the newer frame instead.
                self.pendingDraws[index].epoch = surface.contentView.presentationEpochForDiagnostics
                self.armPendingDraw(id: id, on: surface)
                return
            }
            let draw = self.pendingDraws.remove(at: index)
            draw.completion()
        }
    }

    /// Re-arms requests whose content-view callback a geometry epoch discarded.
    private func rearmInvalidatedDraws(on surface: TerminalSurface) {
        guard effectiveSurfaceVisible, !pendingDraws.isEmpty else { return }
        let identity = ObjectIdentifier(surface)
        let epoch = surface.contentView.presentationEpochForDiagnostics
        for index in pendingDraws.indices
        where pendingDraws[index].surface == identity && pendingDraws[index].epoch != epoch {
            pendingDraws[index].epoch = epoch
            armPendingDraw(id: pendingDraws[index].id, on: surface)
        }
    }

    private func dropPendingDraws() {
        pendingDraws.removeAll()
    }

    func startDisplayLink() { requestImmediateTick() }
    func stopDisplayLink() {
        // No persistent display link exists. Visibility changes suspend the
        // content renderer and invalidate pending completion barriers.
    }

    /// Pointer paths call this per event. Only transitions reach the session
    /// FIFO (mode 1004 reports ESC[I/ESC[O per admitted focus) and the delegate.
    /// New hosts receive the stored state from buildSurfaceIfReady().
    func setFocus(_ focused: Bool, notifyDelegate: Bool = true) {
        if focused != isSurfaceFocused {
            isSurfaceFocused = focused
            hasNotifiedSurfaceFocus = false
        }
        surface?.setFocus(focused)
        if notifyDelegate, !hasNotifiedSurfaceFocus {
            hasNotifiedSurfaceFocus = true
            (delegate as? any TerminalSurfaceFocusDelegate)?.terminalDidChangeFocus(focused)
        }
    }

    func freeSurface() {
        lifecycleEpoch &+= 1
        rebuildAfterDetach = false
        guard !isDetaching else { return }
        detachSurface()
    }

    private func detachSurface() {
        guard let retiring = surface else { return }
        isDetaching = true
        // The session outlives this host. Cancel pointer streams while their
        // route still resolves, or the remote keeps a press with no release.
        onSurfaceWillDetach?(retiring)
        let notifyDetach = announcedSurface
        let oldDelegate = delegate
        let oldController = surfaceController
        surface = nil
        surfaceController = nil
        lastMetrics = nil
        dropPendingDraws()
        announcedSurface = false
        oldController?.unregisterVTHost(self)
        retiring.session.clearEventDelegate(owner: eventDelegateOwner)
        retiring.free()
        // Finish all internal cleanup before calling out. A reentrant rebuild
        // must never have its callbacks or content cleared by this retirement.
        onSurfaceFreed?(retiring)
        if notifyDetach {
            (oldDelegate as? any TerminalSurfaceLifecycleDelegate)?.terminalDidDetachSurface()
        }
        isDetaching = false
        if rebuildAfterDetach {
            rebuildAfterDetach = false
            buildSurfaceIfReady()
        }
    }

    deinit {
        // Capture only Sendable resources, never the dying host or its weak,
        // non-Sendable delegate. Ownership tokens also fence replacement hosts.
        let controller = surfaceController
        let surface = surface
        let owner = eventDelegateOwner
        cleanupOnMainActor {
            controller?.pruneDeadVTHosts()
            surface?.session.clearEventDelegate(owner: owner)
            surface?.free()
        }
        // No external lifecycle callbacks during implicit teardown.
    }

    private var effectiveSurfaceVisible: Bool { isDisplayVisible && isApplicationActive }
    private var validGeometry: Bool {
        let size = viewSize()
        let scale = scaleFactor()
        return size.width.isFinite && size.height.isFinite && scale.isFinite
            && size.width > 0 && size.height > 0 && scale > 0
    }

    static func resolveFont(family: String?, size: CGFloat) -> UIFont {
        let size = size.isFinite && size > 0 ? size : 12
        if let family {
            let faces = UIFont.fontNames(forFamilyName: family).sorted { lhs, rhs in
                func rank(_ name: String) -> Int {
                    let lower = name.lowercased()
                    if lower.contains("regular") || lower == family.lowercased() { return 0 }
                    if lower.contains("bold") || lower.contains("italic") || lower.contains("oblique") { return 2 }
                    return 1
                }
                return rank(lhs) == rank(rhs) ? lhs < rhs : rank(lhs) < rank(rhs)
            }
            for face in faces {
                if let font = UIFont(name: face, size: size) { return font }
            }
            if let font = UIFont(name: family, size: size) { return font }
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }
}
