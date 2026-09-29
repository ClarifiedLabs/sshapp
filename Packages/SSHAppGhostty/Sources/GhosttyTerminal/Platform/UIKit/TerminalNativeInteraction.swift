#if canImport(UIKit) && !targetEnvironment(macCatalyst)
import UIKit
import GhosttyVT

@MainActor
final class TerminalNativeInteraction: NSObject {
    private unowned let view: UITerminalView
    private let start = TerminalSelectionHandleView(endpoint: .start)
    private let end = TerminalSelectionHandleView(endpoint: .end)
    private let menuHost = UIView()
    private var menu: UIEditMenuInteraction { view.selectionEditMenuInteraction }
    private var wantsMenu = false
    private var selectionClearToken: UUID?
    private var selectionClearBoundary: VTSelectionClearBoundary?
    var isSelectionClearPending: Bool { selectionClearToken != nil }
    #if VT_TEST_HOOKS
    /// Test observation of native completions, including ones whose host is
    /// gone. Lets tests await the stale path instead of sleeping.
    enum DebugCompletion: Equatable {
        case copy(applied: Bool)
        case selectionClear(applied: Bool)
        case pointer(applied: Bool)
    }
    static var debugCompletionObserver: ((DebugCompletion) -> Void)?
    #endif
    private var pointerMenuPoint: CGPoint?
    private struct SelectionDrag {
        let id: UInt64
        let terminalID: UUID
        let generation: UInt64
        let start: Bool
        let offset: CGPoint
        var location: CGPoint
        var hasMoved = false
        var needsUpdate = false
        var ending = false
        var point: CGPoint { CGPoint(x: location.x + offset.x, y: location.y + offset.y) }
    }
    private var drag: SelectionDrag?
    private var nextDragID: UInt64 = 0
    private var magnifierRefresh: (terminalID: UUID, generation: UInt64, revision: UInt64, gestureID: UInt64)?
    private var magnifierRefreshScheduled = false
    private(set) var renderedMagnifierRefreshes = 0
    /// Opt-in diagnostic: inclusive synchronous main-thread wall time,
    /// not exclusive CPU time, queued refresh wait or presentation latency.
    struct MagnifierRefreshSample: Codable {
        let afterScreenUpdates: Bool
        let mainThreadWallMilliseconds: Double
    }
    var onMagnifierRefresh: ((MagnifierRefreshSample) -> Void)?
    private var autoscrollTask: Task<Void, Never>?
    private var dragLease = TerminalInteractionLease<VTSelectionDragRequest>()
    var pendingDragRequest: VTSelectionDragRequest? { dragLease.current }
    private var inFlightDragRequest: VTSelectionDragRequest? { dragLease.inFlight }
    var isDraggingSelection: Bool { drag != nil }
    var isAutoscrollScheduled: Bool { autoscrollTask != nil }
    deinit { autoscrollTask?.cancel() }
    private let feedback = UISelectionFeedbackGenerator()
    private var lastFeedbackCell: VTCellPosition?
    private var lastHoverPoint: CGPoint?
    private var pointerModifiers: UIKeyModifierFlags = []
    private let magnifier = TerminalSelectionMagnifierView()
    var visibleHandles: [Any] { [start, end].filter { !$0.isHidden } }

    init(view: UITerminalView) { self.view = view }

    func install() {
        guard menuHost.superview == nil else { return }
        // Secondary clicks first reach the ordered native pointer router.
        // A passive sibling prevents UIKit edit-menu recognizers stealing them.
        menuHost.frame = view.bounds
        menuHost.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        menuHost.isUserInteractionEnabled = false
        view.addSubview(menuHost)
        menuHost.addInteraction(view.selectionEditMenuInteraction)
        menuHost.addInteraction(view.terminalInputEditMenuInteraction)
        view.addSubview(magnifier)
        view.selectionStartHandle = start
        view.selectionEndHandle = end
        view.selectionMagnifier = magnifier
        for handle in [start, end] {
            view.addSubview(handle)
            handle.panGesture.addTarget(self, action: #selector(handlePan(_:)))
            handle.onAccessibilityNudge = { [weak self, weak view, weak handle] delta in
                guard let self, let view, let handle else { return }
                withExtendedLifetime(view) { self.nudge(start: handle.start, delta: delta) }
            }
            handle.setVisible(false)
        }
    }

    func nudge(start: Bool, delta: Int) {
        guard delta != 0, let frame = view.surface?.frameValue else { return }
        cancelSelectionDrag()
        view.nativePointer.cancel()
        view.dismissTerminalEditMenus()
        let operation = view.surface?.session.enqueueAdjustSelection(start: start, forward: delta > 0,
            terminalID: frame.terminalID, generation: frame.layout.generation)
        Task { @MainActor [weak self, weak view] in
            // Await accepted native work without extending either UIKit lifetime.
            guard let changed = try? await operation?.value else { return }
            guard let self, let view else { return }
            defer { withExtendedLifetime(view) {} }
            selectionAdjusted(start: start, changed: changed)
            view.surface?.contentView.requestFrame()
        }
    }

    func update(_ frame: VTFrameValue) {
        #if DEBUG
        view.selectionDebugUpdateDepth += 1
        defer {
            view.selectionDebugUpdateDepth -= 1
            view.refreshSelectionDebugSnapshot()
        }
        #endif
        if let revoked = frame.revokedSelectionPointerID, revoked == wordPointerID {
            // The word gesture can outlive its pointer completion. Reset only
            // that gesture; a newer indirect Shift pointer may already be active.
            resetWordSelection()
            view.nativePointer.cancel(ifMatching: revoked)
        }
        if selectionClearToken != nil || (selectionClearBoundary.map {
            $0.terminalID == frame.terminalID && frame.revision < $0.revision
        } ?? false) {
            view.dismissSelectionHandles()
            return
        }
        if let drag, drag.terminalID != frame.terminalID || drag.generation != frame.layout.generation {
            cancelSelectionDrag()
        }
        if wordDragging, wordTerminalID != frame.terminalID || wordGeneration != frame.layout.generation {
            cancelInteraction()
        }
        if frame.selection == nil && !wordDragging { cancelSelectionDrag() }
        let previousMenuTarget = selectionMenuTargetRect(in: menuHost)
        for handle in [start, end] {
            guard let endpoint = frame.selection?.endpoint(start: handle.start) else { handle.setVisible(false); continue }
            let point = endpoint.position
            let rect = frame.layout.rect(column: point.column, row: point.row)
            let leading = handle.start != (frame.selection?.reversed ?? false)
            let rawCenter = CGPoint(x: leading ? rect.minX : rect.maxX,
                                    y: leading ? rect.minY : rect.maxY)
            let half = TerminalSelectionHandleView.hitSize / 2
            let bounds = view.terminalViewportBounds.intersection(view.bounds)
            let y = min(max(rawCenter.y, min(bounds.midY, bounds.minY + half)), max(bounds.midY, bounds.maxY - half))
            let horizontal = handleHorizontalRange(atY: y)
            handle.center = CGPoint(x: min(max(rawCenter.x, horizontal.lowerBound), horizontal.upperBound), y: y)
            handle.setDimmed(!endpoint.isVisible || !bounds.contains(rawCenter))
            handle.accessibilityValue = point.row < 0 ? "Above visible terminal"
                : point.row >= frame.layout.rows ? "Below visible terminal" : "Row \(point.row + 1), column \(point.column + 1)"
            if handle.superview == nil { view.addSubview(handle) }
            handle.setVisible(true)
            view.bringSubviewToFront(handle)
        }
        if !start.isHidden, !end.isHidden, start.center == end.center {
            // Clamping two different endpoints onto the same corner must not
            // make one impossible to pick up. Separate only display targets.
            let half = TerminalSelectionHandleView.hitSize / 2
            let horizontal = handleHorizontalRange(atY: start.center.y)
            let gap = min(half, horizontal.upperBound - horizontal.lowerBound)
            start.center.x = min(start.center.x, horizontal.upperBound - gap)
            end.center.x = start.center.x + gap
        }
        if frame.selection == nil { menu.dismissMenu() }
        else if wantsMenu && drag == nil && !wordDragging {
            wantsMenu = false
            let anchor = pointerMenuPoint ?? (!start.isHidden ? start.center : (!end.isHidden ? end.center : CGPoint(x: view.bounds.midX, y: view.bounds.midY)))
            pointerMenuPoint = nil
            menu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: anchor))
        } else if previousMenuTarget != selectionMenuTargetRect(in: menuHost) {
            // Output can move a selection even without a handle gesture. UIKit
            // re-queries the delegate; this is a no-op when no menu is visible.
            menu.updateVisibleMenuPosition(animated: false)
        }
        view.selectionHandlesVisible = frame.selection != nil
        if let selection = frame.selection {
            func point(_ endpoint: VTSelectionEndpoint, leading: Bool) -> CGPoint {
                let rect = frame.layout.rect(column: endpoint.position.column, row: endpoint.position.row)
                return CGPoint(x: leading ? rect.minX : rect.maxX, y: leading ? rect.minY : rect.maxY)
            }
            view.touchSelectionAnchorPoint = point(selection.startEndpoint, leading: !selection.reversed)
            view.touchSelectionActiveEndPoint = point(selection.endEndpoint, leading: selection.reversed)
        } else {
            view.touchSelectionAnchorPoint = nil
            view.touchSelectionActiveEndPoint = nil
        }
        view.selectionHandlesViewportBounds = view.terminalViewportBounds
        // This frame is semantic/owned state, not rendered pixels yet. The
        // renderer schedules a bounded loupe refresh after completing its work.
        scheduleAutoscroll()
    }

    /// UIKit places the edit menu around its target rectangle, space permitting.
    /// A point at either endpoint does not protect the other handle (or even the
    /// first handle's hit target). Use the displayed, possibly clamped targets,
    /// not native offscreen endpoints, and convert to the interaction's view.
    func selectionMenuTargetRect(in menuView: UIView) -> CGRect? {
        let rect = [start, end]
            .filter { !$0.isHidden && $0.superview === view }
            .reduce(CGRect.null) { $0.union($1.convert($1.bounds, to: menuView)) }
        return rect.isNull ? nil : rect
    }

    private func handleHorizontalRange(atY y: CGFloat) -> ClosedRange<CGFloat> {
        let bounds = view.terminalViewportBounds.intersection(view.bounds)
        let half = TerminalSelectionHandleView.hitSize / 2
        let minimum = min(bounds.midX, bounds.minX + half)
        let maximum = max(bounds.midX, bounds.maxX - half)
        if view.traitCollection.userInterfaceIdiom == .pad, let window = view.window {
            // iPad window resizing can claim drags inside our bottom-corner
            // targets. Keep markers clear, including when separating a pair.
            let cornerInset: CGFloat = 80
            let point = view.convert(CGPoint(x: 0, y: y), to: window)
            if point.y > window.bounds.maxY - cornerInset {
                let left = view.convert(CGPoint(x: window.bounds.minX + cornerInset, y: point.y), from: window).x
                let right = view.convert(CGPoint(x: window.bounds.maxX - cornerInset, y: point.y), from: window).x
                let lower = max(minimum, left), upper = min(maximum, right)
                if lower <= upper { return lower...upper }
            }
        }
        return minimum...maximum
    }

    func handle(at point: CGPoint) -> UIView? {
        [start, end].filter { !$0.isHidden && $0.frame.contains(point) }.min {
            hypot($0.center.x - point.x, $0.center.y - point.y) < hypot($1.center.x - point.x, $1.center.y - point.y)
        }
    }

    func selectAll() {
        view.nativePointer.cancel()
        cancelSelectionDrag()
        wantsMenu = true
        selectAllNative()
    }

    func mapped(_ point: CGPoint, clamp: Bool = false) -> (VTCellPosition, UInt64)? {
        guard point.x.isFinite, point.y.isFinite, let frame = view.surface?.frameValue else { return nil }
        let layout = frame.layout
        var point = point
        if clamp {
            point.x = min(max(point.x, layout.padding), layout.padding + Double(layout.columns) * layout.cellWidth - 0.1)
            point.y = min(max(point.y, layout.padding), layout.padding + Double(layout.rows) * layout.cellHeight - 0.1)
        }
        guard let cell = layout.cell(at: point) else { return nil }
        return (.init(column: cell.column, row: cell.row), layout.generation)
    }

    private(set) var wordDragging = false
    private var lastWordPoint: CGPoint?
    private var wordEnding = false
    private var wordIsLocal = false
    private var wordPointerID: UInt64?
    private var wordGeneration: UInt64?
    private var wordTerminalID: UUID?
    var hardwareModifiers: UIKeyModifierFlags = []
    var isSelecting: Bool { wordDragging || drag != nil }

    func longPress(_ gesture: UILongPressGestureRecognizer) {
        wordSelection(state: gesture.state, at: gesture.location(in: view), modifiers: gesture.modifierFlags)
    }

    /// UIKit owns gesture lifetime only. The ordered native press decides
    /// capture versus local word selection, including the Shift override.
    func wordSelection(state: UIGestureRecognizer.State, at location: CGPoint, modifiers: UIKeyModifierFlags) {
        #if DEBUG
        view.selectionDebugUpdateDepth += 1
        defer {
            view.selectionDebugUpdateDepth -= 1
            view.refreshSelectionDebugSnapshot()
        }
        #endif
        switch state {
        case .began:
            guard mapped(location) != nil, let frame = view.surface?.frameValue else { return }
            cancelInteraction()
            guard let id = view.nativePointer.begin(at: location, modifiers: modifiers,
                source: .touch, selectionBehavior: .word) else { return }
            wordPointerID = id
            wordDragging = true
            wordEnding = false
            wordIsLocal = false
            lastWordPoint = location
            wordGeneration = frame.layout.generation
            wordTerminalID = frame.terminalID
            view.selectionGestureActive = true
        case .changed:
            guard wordDragging, !wordEnding else { return }
            lastWordPoint = location
            view.nativePointer.move(to: location, modifiers: modifiers)
            if wordIsLocal { showMagnifier(at: location) }
        case .ended:
            guard wordDragging, !wordEnding else { return }
            lastWordPoint = location
            wordEnding = true
            view.selectionGestureActive = false
            // Release includes the final finger position even when a previous
            // move is awaiting completion. The controller drops deferred moves.
            view.nativePointer.end(at: location, modifiers: modifiers)
            view.touchSelectionIsMouseCaptured = false
            magnifier.isHidden = true
        case .cancelled, .failed:
            cancelInteraction()
        default: break
        }
    }

    func wordPointerCompleted(_ request: VTPointerRequest, response: VTPointerResponse) {
        #if DEBUG
        view.selectionDebugUpdateDepth += 1
        defer {
            view.selectionDebugUpdateDepth -= 1
            view.refreshSelectionDebugSnapshot()
        }
        #endif
        guard request.id == wordPointerID else { return }
        if request.phase == .press {
            // Never infer capture from a potentially stale presentation frame.
            wordIsLocal = response.localSelection
            view.touchSelectionIsMouseCaptured = response.active && !wordIsLocal && !wordEnding
            if wordIsLocal {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                if !wordEnding, let point = lastWordPoint { showMagnifier(at: point) }
            }
        }
        if request.phase == .release || !response.active {
            // Completion tasks may resume on MainActor in a different order;
            // the release response carries the native route's selection result.
            let showMenu = request.phase == .release && (wordIsLocal || response.localSelection)
            resetWordSelection()
            wantsMenu = showMenu
        }
    }

    func wordPointerFailed(_ request: VTPointerRequest) {
        #if DEBUG
        view.selectionDebugUpdateDepth += 1
        defer {
            view.selectionDebugUpdateDepth -= 1
            view.refreshSelectionDebugSnapshot()
        }
        #endif
        guard request.id == wordPointerID else { return }
        resetWordSelection()
        wantsMenu = false
    }

    private func resetWordSelection() {
        wordDragging = false
        view.selectionGestureActive = drag != nil && drag?.ending == false
        wordEnding = false
        wordIsLocal = false
        wordPointerID = nil
        wordGeneration = nil
        wordTerminalID = nil
        lastWordPoint = nil
        view.touchSelectionIsMouseCaptured = false
        magnifier.isHidden = true
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let handle = gesture.view as? TerminalSelectionHandleView else { return }
        let location = gesture.location(in: view)
        switch gesture.state {
        case .began:
            let initialTranslation: CGPoint
            if let pan = gesture as? TerminalSelectionPanGestureRecognizer, pan.hasReceivedTouches {
                // Real UIKit input must use the pre-recognition touch origin.
                // A lost/replaced window invalidates it; do not silently rebase.
                guard let touchDown = pan.touchDownLocation(in: view) else {
                    cancelInteraction()
                    return
                }
                initialTranslation = CGPoint(x: location.x - touchDown.x, y: location.y - touchDown.y)
            } else {
                // Synthetic recognizer seams have no touchesBegan delivery.
                initialTranslation = gesture.translation(in: view)
            }
            beginSelectionDrag(start: handle.start, at: location, initialTranslation: initialTranslation)
        case .changed: moveSelectionDrag(to: location)
        case .ended: endSelectionDrag(at: location)
        case .cancelled, .failed: cancelInteraction()
        default: break
        }
    }

    func beginSelectionDrag(start: Bool, at location: CGPoint, initialTranslation: CGPoint = .zero) {
        #if DEBUG
        view.selectionDebugUpdateDepth += 1
        defer {
            view.selectionDebugUpdateDepth -= 1
            view.refreshSelectionDebugSnapshot()
        }
        #endif
        view.nativePointer.cancel()
        cancelSelectionDrag()
        guard location.x.isFinite, location.y.isFinite,
              initialTranslation.x.isFinite, initialTranslation.y.isFinite,
              let frame = view.surface?.frameValue,
              let endpoint = frame.selection?.endpoint(start: start) else { return }
        // UIPan begins after recognition slop. Anchor at touch-down, not at
        // recognition, so those first points of movement are not discarded.
        let touchDown = CGPoint(x: location.x - initialTranslation.x, y: location.y - initialTranslation.y)
        guard touchDown.x.isFinite, touchDown.y.isFinite else { return }
        nextDragID &+= 1
        // Picking up an offscreen target leaves native selection untouched.
        // Deliberate movement brings that endpoint to the visible drag position.
        let point = VTCellPosition(column: min(max(endpoint.position.column, 0), frame.layout.columns - 1),
            row: min(max(endpoint.position.row, 0), frame.layout.rows - 1))
        let rect = frame.layout.rect(column: point.column, row: point.row)
        let offset = CGPoint(x: rect.midX - touchDown.x, y: rect.midY - touchDown.y)
        guard offset.x.isFinite, offset.y.isFinite else { return }
        view.selectionHandleMode = start ? .adjustingStart : .adjustingEnd
        drag = SelectionDrag(id: nextDragID, terminalID: frame.terminalID, generation: frame.layout.generation,
            start: start, offset: offset, location: location)
        view.selectionGestureActive = true
        lastFeedbackCell = point
        feedback.prepare()
        wantsMenu = false
        menu.dismissMenu()
        if initialTranslation != .zero {
            moveSelectionDrag(to: location)
        } else {
            showMagnifier(at: location)
        }
    }

    func moveSelectionDrag(to location: CGPoint) {
        guard drag != nil, location.x.isFinite, location.y.isFinite else { return }
        drag?.location = location
        drag?.hasMoved = true
        drag?.needsUpdate = true
        stopAutoscroll()
        submitDrag(scrollRows: 0)
        showMagnifier(at: location)
    }

    func endSelectionDrag(at location: CGPoint) {
        #if DEBUG
        view.selectionDebugUpdateDepth += 1
        defer {
            view.selectionDebugUpdateDepth -= 1
            view.refreshSelectionDebugSnapshot()
        }
        #endif
        guard let drag else { return }
        view.selectionGestureActive = false
        stopAutoscroll()
        if !drag.hasMoved, location == drag.location {
            self.drag = nil
            view.selectionHandleMode = .none
            magnifier.isHidden = true
            wantsMenu = true
            if let frame = view.surface?.frameValue { update(frame) }
            return
        }
        if location.x.isFinite, location.y.isFinite { self.drag?.location = location }
        self.drag?.ending = true
        self.drag?.needsUpdate = true
        magnifier.isHidden = true
        // Preserve the final finger position even if a previous tick is still
        // queued. It is the last non-scrolling update, then the menu can open.
        submitDrag(scrollRows: 0)
    }

    func accepts(_ request: VTSelectionDragRequest) -> Bool {
        drag?.id == request.gestureID && drag?.generation == request.generation
            && drag?.terminalID == request.terminalID
            && (request.scrollRows == 0 || drag?.ending == false)
    }

    func completed(_ request: VTSelectionDragRequest) {
        #if DEBUG
        view.selectionDebugUpdateDepth += 1
        defer {
            view.selectionDebugUpdateDepth -= 1
            view.refreshSelectionDebugSnapshot()
        }
        #endif
        guard dragLease.complete(request) else { return }
        if drag?.needsUpdate == true { submitDrag(scrollRows: 0) }
        else if drag?.ending == true {
            drag = nil
            view.selectionHandleMode = .none
            wantsMenu = true
        }
        // A scroll timer starts only after the resulting frame is published.
        // This bounds both queue growth and ticks while rendering falls behind.
    }

    private func submitDrag(scrollRows: Int) {
        guard inFlightDragRequest == nil, let drag,
              let (point, generation) = mapped(drag.point, clamp: true), generation == drag.generation,
              view.surface?.frameValue?.terminalID == drag.terminalID else { return }
        self.drag?.needsUpdate = false
        let request = VTSelectionDragRequest(gestureID: drag.id, terminalID: drag.terminalID,
            generation: generation,
            start: drag.start, position: point, scrollRows: scrollRows)
        guard dragLease.admit(request) else { return }
        submitNativeDrag(request)
        if lastFeedbackCell != point { feedback.selectionChanged(); lastFeedbackCell = point }
    }

    private func scheduleAutoscroll() {
        guard let drag, drag.hasMoved, !drag.ending,
              let frame = view.surface?.frameValue,
              frame.terminalID == drag.terminalID, frame.layout.generation == drag.generation,
              TerminalSelectionAutoscroll.rows(at: drag.point, layout: frame.layout, viewport: frame.viewport) != 0
        else { stopAutoscroll(); return }
        guard autoscrollTask == nil, inFlightDragRequest == nil else { return }
        autoscrollTask = Task { @MainActor [weak self, weak view] in
            do { try await Task.sleep(for: .milliseconds(60)) }
            catch { return }
            guard let self, let view, !Task.isCancelled, self.drag?.id == drag.id else { return }
            defer { withExtendedLifetime(view) {} }
            self.autoscrollTask = nil
            self.autoscrollTick()
        }
    }

    func autoscrollTick() {
        stopAutoscroll()
        guard let drag, drag.hasMoved, !drag.ending,
              let frame = view.surface?.frameValue,
              frame.terminalID == drag.terminalID, frame.layout.generation == drag.generation else { return }
        let rows = TerminalSelectionAutoscroll.rows(at: drag.point, layout: frame.layout, viewport: frame.viewport)
        if rows != 0 { submitDrag(scrollRows: rows) }
    }

    private func stopAutoscroll() { autoscrollTask?.cancel(); autoscrollTask = nil }

    func cancelSelectionDrag() {
        #if DEBUG
        view.selectionDebugUpdateDepth += 1
        defer {
            view.selectionDebugUpdateDepth -= 1
            view.refreshSelectionDebugSnapshot()
        }
        #endif
        magnifierRefresh = nil
        stopAutoscroll()
        drag = nil
        view.selectionGestureActive = wordDragging && !wordEnding
        dragLease.cancel()
        view.selectionHandleMode = .none
        lastFeedbackCell = nil
        magnifier.isHidden = true
        for handle in [start, end] {
            if view.surface?.frameValue?.selection == nil { handle.setVisible(false) }
        }
        // The pending request keeps its lease until the view acknowledges it.
        // A new drag cannot queue behind an unacknowledged old operation.
    }

    @objc private func tap(_ gesture: UITapGestureRecognizer) {
        tap(at: gesture.location(in: view), modifiers: gesture.modifierFlags)
    }

    func tap(at point: CGPoint, modifiers: UIKeyModifierFlags, onLocalTap: (@MainActor () -> Void)? = nil) {
        cancelSelectionDrag()
        view.nativePointer.tap(at: point, modifiers: modifiers, onLocalTap: onLocalTap)
    }

    @objc private func hover(_ gesture: UIHoverGestureRecognizer) {
        switch gesture.state {
        case .began, .changed:
            hover(at: gesture.location(in: view), modifiers: gesture.modifierFlags)
        case .ended, .cancelled, .failed: hover(at: nil, modifiers: [])
        default: break
        }
    }

    private var hoverRevision: UInt64 = 0
    var onLinkHighlight: ((VTLinkHighlight?) -> Void)?
    var onOpenLink: ((VTLink) -> Void)?

    func hover(at point: CGPoint?, modifiers: UIKeyModifierFlags) {
        lastHoverPoint = point
        pointerModifiers = modifiers
        hoverRevision &+= 1
        let revision = hoverRevision
        guard let point, !view.nativePointer.isPressed, !isSelecting,
              mapped(point) != nil, let surface = view.surface, let frame = surface.frameValue else {
            onLinkHighlight?(nil)
            return
        }
        let detectLink = modifiers.union(hardwareModifiers).contains(.command)
        if !detectLink { onLinkHighlight?(nil) }
        // Capture identities only. The session retains at most one latest link
        // frame per uninterrupted hover segment, not one frame/task per receipt.
        let terminalID = frame.terminalID, frameRevision = frame.revision
        surface.session.enqueueHover(at: point,
            modifiers: VTModifiers(TerminalInputModifiers(from: modifiers.union(hardwareModifiers))),
            frame: frame, detectLink: detectLink) { [weak self, weak view] hit in
                guard let self, let view, hoverRevision == revision,
                      view.surface?.frameValue?.terminalID == terminalID,
                      view.surface?.frameValue?.revision == frameRevision else { return }
                withExtendedLifetime(view) { onLinkHighlight?(hit?.highlight) }
            }
    }

    func hardwareModifiersChanged(to flags: UIKeyModifierFlags) {
        view.nativePointer.modifiersChanged(previous: hardwareModifiers, current: flags)
        pointerModifiers.subtract(hardwareModifiers.symmetricDifference(flags))
        hardwareModifiers = flags
        hover(at: lastHoverPoint, modifiers: pointerModifiers)
    }

    @objc private func pan(_ gesture: UIPanGestureRecognizer) {
        remotePan(state: gesture.state, at: gesture.location(in: view), modifiers: gesture.modifierFlags)
    }

    func remotePan(state: UIGestureRecognizer.State, at point: CGPoint, modifiers: UIKeyModifierFlags) {
        view.nativePointer.directPan(state: state, at: point, modifiers: modifiers)
    }

    func preparePointer() {
        cancelSelectionDrag()
        wantsMenu = false
        pointerMenuPoint = nil
        view.dismissTerminalEditMenus()
    }

    func showPointerMenu(at point: CGPoint) {
        pointerMenuPoint = point
        wantsMenu = true
    }

    func cancelInteraction() {
        #if DEBUG
        view.selectionDebugUpdateDepth += 1
        defer {
            view.selectionDebugUpdateDepth -= 1
            view.refreshSelectionDebugSnapshot()
        }
        #endif
        resetWordSelection()
        hover(at: nil, modifiers: [])
        cancelSelectionDrag()
        wantsMenu = false
        menu.dismissMenu()
        magnifier.isHidden = true
        pointerMenuPoint = nil
        view.nativePointer.cancel()
    }
    /// Rendering completion is not a display timestamp. Ask UIKit to include
    /// recent screen updates, outside draw(_:), only for the current moved drag.
    /// Coalesce to one queued refresh; retain no frame, texture or native handle.
    func rendered(_ frame: VTFrameValue) {
        if wordDragging, wordIsLocal, !wordEnding, let id = wordPointerID,
           frame.terminalID == wordTerminalID, frame.layout.generation == wordGeneration,
           canRefreshMagnifier, !magnifierRefreshScheduled {
            magnifierRefreshScheduled = true
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view else { return }
                defer { withExtendedLifetime(view) {} }
                magnifierRefreshScheduled = false
                guard wordPointerID == id, wordDragging, wordIsLocal, !wordEnding,
                      let point = lastWordPoint, canRefreshMagnifier else { return }
                showMagnifier(at: point, afterScreenUpdates: true)
            }
        }
        guard let drag, drag.hasMoved, !drag.ending else { return }
        magnifierRefresh = (frame.terminalID, frame.layout.generation, frame.revision, drag.id)
        guard !magnifierRefreshScheduled else { return }
        magnifierRefreshScheduled = true
        DispatchQueue.main.async { [weak self, weak view] in
            guard let self, let view else { return }
            defer { withExtendedLifetime(view) {} }
            magnifierRefreshScheduled = false
            let requested = magnifierRefresh
            magnifierRefresh = nil
            guard let requested, let drag = self.drag, drag.id == requested.gestureID, drag.hasMoved, !drag.ending,
                  canRefreshMagnifier,
                  let current = view.surface?.frameValue, current.terminalID == requested.terminalID,
                  current.layout.generation == requested.generation, current.revision == requested.revision else { return }
            showMagnifier(at: drag.location, afterScreenUpdates: true)
            renderedMagnifierRefreshes += 1
        }
    }

    private var canRefreshMagnifier: Bool {
        guard let content = view.surface?.contentView, content.isPresentationActive,
              let window = view.window, !window.isHidden,
              !UIAccessibility.isVoiceOverRunning else { return false }
        return !view.isHidden && view.alpha > 0.01
    }

    func showMagnifier(at point: CGPoint, afterScreenUpdates: Bool = false) {
        #if DEBUG
        defer { view.refreshSelectionDebugSnapshot() }
        #endif
        guard !UIAccessibility.isVoiceOverRunning, let content = view.surface?.contentView else { magnifier.isHidden = true; return }
        let observer = onMagnifierRefresh
        let started = observer == nil ? nil : CACurrentMediaTime()
        magnifier.updateSnapshot(of: content,
            around: content.convert(point, from: view),
            clippedTo: content.convert(view.terminalViewportBounds, from: view), afterScreenUpdates: afterScreenUpdates)
        let radius = TerminalSelectionMagnifierView.diameter / 2
        magnifier.center = CGPoint(x: min(max(point.x, radius), view.bounds.width - radius),
                                   y: max(radius, point.y - radius - 24))
        magnifier.isHidden = false
        view.bringSubviewToFront(magnifier)
        if let observer, let started {
            let elapsed = (CACurrentMediaTime() - started) * 1_000
            observer(.init(afterScreenUpdates: afterScreenUpdates, mainThreadWallMilliseconds: elapsed))
        }
    }
    @discardableResult
    func copySelection() -> Bool {
        guard view.surface?.frameValue?.hasSelection == true,
              let operation = view.surface?.session.enqueueTakeSelectedText() else { return false }
        view.nativePointer.cancel()
        cancelSelectionDrag()
        wantsMenu = false
        view.dismissTerminalEditMenus()
        Task { @MainActor [weak view] in
            let text = try? await operation.value
            guard let text, !text.isEmpty, let view else {
                #if VT_TEST_HOOKS
                Self.debugCompletionObserver?(.copy(applied: false))
                #endif
                return
            }
            #if VT_TEST_HOOKS
            defer { Self.debugCompletionObserver?(.copy(applied: true)) }
            #endif
            UIPasteboard.general.string = text
            #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                    view.accessibilityValue = text
                }
            #endif
            view.surface?.contentView.requestFrame()
        }
        return true
    }

    func clearSelection(surface: TerminalSurface? = nil) {
        cancelInteraction()
        let token = UUID()
        selectionClearToken = token
        // Suppress every pre-clear snapshot until FIFO execution supplies the
        // actual boundary, including snapshots newer than the displayed frame.
        let surface = surface ?? view.surface
        let operation = surface?.session.enqueueClearSelection(host: surface?.selectionHostID)
        view.dismissSelectionHandles()
        Task { @MainActor [weak self, weak view] in
            let boundary = try? await operation?.value
            guard let self, let view, selectionClearToken == token else {
                #if VT_TEST_HOOKS
                Self.debugCompletionObserver?(.selectionClear(applied: false))
                #endif
                return
            }
            defer { withExtendedLifetime(view) {} }
            #if VT_TEST_HOOKS
            defer { Self.debugCompletionObserver?(.selectionClear(applied: true)) }
            #endif
            selectionClearBoundary = boundary
            selectionClearToken = nil
            view.surface?.contentView.requestFrame()
        }
    }

    private func selectAllNative() {
        let operation = view.surface?.session.enqueueSelectAll()
        Task { @MainActor [weak view] in
            _ = try? await operation?.value
            view?.surface?.contentView.requestFrame()
        }
    }

    private func submitNativeDrag(_ request: VTSelectionDragRequest) {
        let operation = view.surface?.session.enqueueDragSelection(request)
        Task { @MainActor [weak self, weak view] in
            let succeeded: Bool
            do {
                guard let operation else { throw VTError.retired }
                try await operation.value
                succeeded = true
            } catch {
                succeeded = false
            }
            guard let self, let view else { return }
            defer { withExtendedLifetime(view) {} }
            if !succeeded, drag?.id == request.gestureID { cancelSelectionDrag() }
            // Native occupancy is independent of optional presentation. A
            // resize, background transition or detach can discard render callbacks.
            completed(request)
            view.surface?.contentView.requestFrame()
        }
    }

    func selectionAdjusted(start: Bool, changed: Bool) {
        if changed { feedback.selectionChanged(); wantsMenu = true }
        UIAccessibility.post(notification: .announcement, argument: changed
            ? (start ? "Selection start adjusted" : "Selection end adjusted")
            : "Selection endpoint cannot move farther")
    }

    private func adjustSelection() {
        cancelSelectionDrag()
        wantsMenu = false
        menu.dismissMenu()
    }

    func menuElements() -> [UIMenuElement] {
        var actions: [UIMenuElement] = [
            UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak self, weak view] _ in
                guard let self, let view else { return }
                withExtendedLifetime(view) { _ = self.copySelection() }
            },
            UIAction(title: "Select All") { [weak self, weak view] _ in
                guard let self, let view else { return }
                withExtendedLifetime(view) { self.selectAll() }
            },
        ]
        if UIAccessibility.isVoiceOverRunning {
            actions.append(UIAction(title: "Adjust Selection") { [weak self, weak view] _ in
                guard let self, let view else { return }
                withExtendedLifetime(view) { self.adjustSelection() }
            })
        }
        return actions
    }
}

private extension TerminalSelectionHandleView {
    var start: Bool { endpoint == .start }
}

#endif
