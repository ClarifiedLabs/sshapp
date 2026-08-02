//
//  TerminalSelectionHandles.swift
//  libghostty-spm
//

#if canImport(UIKit) && !targetEnvironment(macCatalyst)
    import GhosttyKit
    import UIKit

    enum TerminalSelectionEndpoint {
        case start
        case end
    }

    /// A 22-point selection marker inside a HIG-sized 48-point hit target.
    /// The terminal owns the pan handling so both endpoint views share one
    /// Ghostty selection-rebuild path.
    @MainActor
    final class TerminalSelectionHandleView: UIView {
        static let hitSize: CGFloat = 48
        private static let markerSize: CGFloat = 22
        private static let coreSize: CGFloat = 8

        let endpoint: TerminalSelectionEndpoint
        let panGesture = UIPanGestureRecognizer()
        var onAccessibilityNudge: ((Int) -> Void)?

        private let markerView = UIView()
        private let coreView = UIView()

        init(endpoint: TerminalSelectionEndpoint) {
            self.endpoint = endpoint
            super.init(
                frame: CGRect(
                    origin: .zero,
                    size: CGSize(width: Self.hitSize, height: Self.hitSize)
                )
            )

            backgroundColor = .clear
            clipsToBounds = false
            isHidden = true
            isUserInteractionEnabled = false

            markerView.backgroundColor = tintColor
            markerView.layer.cornerRadius = Self.markerSize / 2
            markerView.layer.shadowColor = UIColor.black.cgColor
            markerView.layer.shadowOpacity = 0.24
            markerView.layer.shadowRadius = 3
            markerView.layer.shadowOffset = CGSize(width: 0, height: 1)
            markerView.isUserInteractionEnabled = false
            addSubview(markerView)

            coreView.backgroundColor = .white
            coreView.layer.cornerRadius = Self.coreSize / 2
            coreView.isUserInteractionEnabled = false
            markerView.addSubview(coreView)

            panGesture.maximumNumberOfTouches = 1
            panGesture.allowedTouchTypes = [
                NSNumber(value: UITouch.TouchType.direct.rawValue),
                NSNumber(value: UITouch.TouchType.pencil.rawValue),
            ]
            addGestureRecognizer(panGesture)

            isAccessibilityElement = true
            accessibilityLabel = endpoint == .start ? "Selection start" : "Selection end"
            accessibilityHint = "Drag to adjust"
            accessibilityTraits = [.adjustable]
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            markerView.bounds = CGRect(
                origin: .zero,
                size: CGSize(width: Self.markerSize, height: Self.markerSize)
            )
            markerView.center = CGPoint(x: bounds.midX, y: bounds.midY)
            coreView.bounds = CGRect(
                origin: .zero,
                size: CGSize(width: Self.coreSize, height: Self.coreSize)
            )
            coreView.center = CGPoint(
                x: markerView.bounds.midX,
                y: markerView.bounds.midY
            )
        }

        override func tintColorDidChange() {
            super.tintColorDidChange()
            markerView.backgroundColor = tintColor
        }

        func setVisible(_ visible: Bool) {
            isHidden = !visible
            isUserInteractionEnabled = visible
            isAccessibilityElement = visible
            accessibilityElementsHidden = !visible
            if !visible {
                removeFromSuperview()
            }
        }

        func setDimmed(_ dimmed: Bool) {
            alpha = dimmed ? 0.45 : 1
        }

        override func accessibilityActivate() -> Bool {
            // Activation expands outward by one cell; adjustable increment and
            // decrement remain available for bidirectional VoiceOver control.
            onAccessibilityNudge?(endpoint == .start ? -1 : 1)
            return onAccessibilityNudge != nil
        }

        override func accessibilityIncrement() {
            onAccessibilityNudge?(1)
        }

        override func accessibilityDecrement() {
            onAccessibilityNudge?(-1)
        }
    }

    /// A lightweight 2× terminal snapshot around the active drag point.
    /// It is intentionally a sibling overlay (not a window) so every terminal
    /// and tmux pane owns an independent loupe.
    @MainActor
    final class TerminalSelectionMagnifierView: UIView {
        static let diameter: CGFloat = 96
        private static let sourceDiameter: CGFloat = 48
        private let imageView = UIImageView()
        private var snapshotView: UIView?

        init() {
            super.init(
                frame: CGRect(
                    origin: .zero,
                    size: CGSize(width: Self.diameter, height: Self.diameter)
                )
            )
            isHidden = true
            isUserInteractionEnabled = false
            isAccessibilityElement = false
            accessibilityElementsHidden = true
            backgroundColor = .secondarySystemBackground
            clipsToBounds = true
            layer.cornerRadius = Self.diameter / 2
            layer.borderWidth = 2
            layer.borderColor = UIColor.separator.cgColor
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOpacity = 0.28
            layer.shadowRadius = 7
            layer.shadowOffset = CGSize(width: 0, height: 3)

            imageView.contentMode = .scaleAspectFill
            imageView.frame = bounds
            imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(imageView)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func restorePreferredBounds() {
            bounds = CGRect(
                origin: .zero,
                size: CGSize(width: Self.diameter, height: Self.diameter)
            )
        }

        func updateSnapshot(
            of terminalView: UIView,
            around point: CGPoint,
            clippedTo clippingBounds: CGRect
        ) {
            // Hide the previous loupe while capturing so repeated drag updates
            // never recursively snapshot the loupe itself.
            let wasHidden = isHidden
            let handles = terminalView.subviews.compactMap {
                $0 as? TerminalSelectionHandleView
            }
            let handleHiddenStates = handles.map(\.isHidden)
            isHidden = true
            handles.forEach { $0.isHidden = true }
            defer {
                isHidden = wasHidden
                for (handle, wasHandleHidden) in zip(handles, handleHiddenStates) {
                    handle.isHidden = wasHandleHidden
                }
            }

            snapshotView?.removeFromSuperview()
            snapshotView = nil
            imageView.image = nil

            let desiredSourceRect = CGRect(
                x: point.x - Self.sourceDiameter / 2,
                y: point.y - Self.sourceDiameter / 2,
                width: Self.sourceDiameter,
                height: Self.sourceDiameter
            )
            let sourceRect = desiredSourceRect.intersection(clippingBounds)
            if !sourceRect.isNull,
               !sourceRect.isEmpty,
               let snapshot = terminalView.resizableSnapshotView(
                   from: sourceRect,
                   afterScreenUpdates: false,
                   withCapInsets: .zero
               ) {
                let zoom = Self.diameter / Self.sourceDiameter
                snapshot.frame = CGRect(
                    x: (sourceRect.minX - desiredSourceRect.minX) * zoom,
                    y: (sourceRect.minY - desiredSourceRect.minY) * zoom,
                    width: sourceRect.width * zoom,
                    height: sourceRect.height * zoom
                )
                snapshot.isUserInteractionEnabled = false
                addSubview(snapshot)
                snapshotView = snapshot
                return
            }

            // Keep an image-render fallback for views/platform versions that
            // cannot vend a live snapshot view.
            let format = UIGraphicsImageRendererFormat()
            format.scale = terminalView.window?.screen.scale
                ?? terminalView.traitCollection.displayScale
            format.opaque = true
            let renderer = UIGraphicsImageRenderer(
                size: CGSize(width: Self.diameter, height: Self.diameter),
                format: format
            )
            imageView.image = renderer.image { context in
                let zoom = Self.diameter / Self.sourceDiameter
                context.cgContext.translateBy(
                    x: Self.diameter / 2 - point.x * zoom,
                    y: Self.diameter / 2 - point.y * zoom
                )
                context.cgContext.scaleBy(x: zoom, y: zoom)
                terminalView.layer.render(in: context.cgContext)
            }
        }
    }

    extension UITerminalView {
        func setupSelectionHandles() {
            guard selectionStartHandle == nil, selectionEndHandle == nil else { return }

            let start = TerminalSelectionHandleView(endpoint: .start)
            let end = TerminalSelectionHandleView(endpoint: .end)
            start.panGesture.addTarget(
                self,
                action: #selector(handleSelectionHandlePan(_:))
            )
            end.panGesture.addTarget(
                self,
                action: #selector(handleSelectionHandlePan(_:))
            )
            start.onAccessibilityNudge = { [weak self] delta in
                self?.nudgeSelectionEndpoint(.start, byCells: delta)
            }
            end.onAccessibilityNudge = { [weak self] delta in
                self?.nudgeSelectionEndpoint(.end, byCells: delta)
            }
            let magnifier = TerminalSelectionMagnifierView()
            addSubview(start)
            addSubview(end)
            addSubview(magnifier)
            selectionStartHandle = start
            selectionEndHandle = end
            selectionMagnifier = magnifier
            start.setVisible(false)
            end.setVisible(false)
            #if DEBUG
                applySelectionDebugHandleIdentifiers()
                refreshSelectionDebugSnapshot()
            #endif
        }

        func showSelectionMagnifier(at point: CGPoint) {
            #if DEBUG
                defer { refreshSelectionDebugSnapshot() }
            #endif
            guard !UIAccessibility.isVoiceOverRunning,
                  let magnifier = selectionMagnifier
            else {
                hideSelectionMagnifier()
                return
            }

            let viewport = terminalViewportBounds.intersection(bounds)
            guard !viewport.isNull, !viewport.isEmpty else {
                hideSelectionMagnifier()
                return
            }
            let samplingPoint = CGPoint(
                x: min(max(point.x, viewport.minX), viewport.maxX),
                y: min(max(point.y, viewport.minY), viewport.maxY)
            )
            // Defend against any external layer-layout pass changing the
            // UIView-backed overlay before capture or presentation.
            magnifier.restorePreferredBounds()
            magnifier.updateSnapshot(of: self, around: samplingPoint, clippedTo: viewport)
            let radius = TerminalSelectionMagnifierView.diameter / 2
            let minCenterX = viewport.minX + radius
            let maxCenterX = max(minCenterX, viewport.maxX - radius)
            let x = min(max(point.x, minCenterX), maxCenterX)
            let preferredAbove = point.y - 64
            let y = preferredAbove - radius >= viewport.minY
                ? preferredAbove
                : point.y + 64
            let minCenterY = viewport.minY + radius
            let maxCenterY = max(minCenterY, viewport.maxY - radius)
            magnifier.center = CGPoint(
                x: x,
                y: min(max(y, minCenterY), maxCenterY)
            )
            magnifier.isHidden = false
            bringSubviewToFront(magnifier)
        }

        func hideSelectionMagnifier() {
            selectionMagnifier?.isHidden = true
            #if DEBUG
                refreshSelectionDebugSnapshot()
            #endif
        }

        /// Clears a touch selection after a successful Copy action. Pointer
        /// selections retain their existing behavior because they do not own
        /// the direct-touch handle overlay.
        func clearTouchSelectionAfterCopy() {
            guard selectionHandlesVisible else { return }
            clearTouchSelection()
        }

        /// Removes both the UIKit overlay and Ghostty's native selection.
        func clearTouchSelection() {
            guard let surface, !surface.isMouseCaptured else {
                dismissSelectionHandles()
                return
            }

            let viewport = terminalViewportBounds
            let reference = touchSelectionActiveEndMousePoint
                ?? touchSelectionAnchorMousePoint
                ?? CGPoint(x: viewport.midX, y: viewport.midY)

            // The final valid primer click is guaranteed to be Ghostty click
            // number one, which clears the native selection on its press.
            resetSyntheticClickCount(relativeTo: reference)
            dismissSelectionHandles()
        }

        /// Ghostty can clear its selection in response to terminal input or
        /// output without a UIKit gesture. Remove overlays once the corresponding
        /// render confirms there is no native selection left.
        func synchronizeTouchSelectionOverlayAfterRender() {
            guard selectionHandlesVisible,
                  selectionHandleMode == .none,
                  !syntheticLeftButtonDown,
                  surface?.hasSelection() != true
            else { return }
            dismissSelectionHandles()
        }

        /// Captures the gesture endpoints after Ghostty finalizes a non-empty
        /// selection, then exposes persistent handles. For the common
        /// stationary single-word gesture, use Ghostty's quicklook cell
        /// coordinates to snap to the selected word's real leading/trailing
        /// edges. Swift string offsets never participate in geometry.
        func installSelectionHandlesAfterTouchSelection() {
            #if DEBUG
                defer { refreshSelectionDebugSnapshot() }
            #endif
            guard surface?.isMouseCaptured != true else {
                dismissSelectionHandles()
                return
            }
            guard surface?.readSelection()?.isEmpty == false,
                  touchSelectionAnchorPoint != nil,
                  touchSelectionActiveEndPoint != nil
            else {
                dismissSelectionHandles()
                return
            }

            if touchSelectionAnchorMousePoint == nil {
                touchSelectionAnchorMousePoint = touchSelectionAnchorPoint
            }
            if touchSelectionActiveEndMousePoint == nil {
                touchSelectionActiveEndMousePoint = touchSelectionActiveEndPoint
            }
            refreshTouchSelectionGridOrigin()
            snapSingleWordSelectionEndpointsIfPossible()
            normalizeTouchSelectionEndpoints()
            selectionHandlesViewportBounds = terminalViewportBounds
            selectionHandlesVisible = true
            if let startHandle = selectionStartHandle {
                if startHandle.superview == nil { addSubview(startHandle) }
                startHandle.setVisible(true)
            }
            if let endHandle = selectionEndHandle {
                if endHandle.superview == nil { addSubview(endHandle) }
                endHandle.setVisible(true)
            }
            layoutSelectionHandles()
        }

        func dismissSelectionHandles() {
            #if DEBUG
                defer { refreshSelectionDebugSnapshot() }
            #endif
            selectionEditMenuInteraction.dismissMenu()
            hideSelectionMagnifier()
            selectionHandleLastFeedbackCell = nil
            let wasAdjustingSelection = syntheticLeftButtonDown
                || selectionHandleMode != .none
            releaseSyntheticSelectionButton()
            if wasAdjustingSelection {
                activePointerButton = nil
            }
            selectionHandlesVisible = false
            selectionHandlesViewportBounds = nil
            selectionHandleMode = .none
            selectionHandleDragOriginalPoints = nil
            selectionHandleDragOriginalMousePoints = nil
            selectionHandleDragTouchOffset = .zero
            selectionHandleDragMouseOffset = .zero
            selectionStartHandle?.setVisible(false)
            selectionEndHandle?.setVisible(false)
            touchSelectionAnchorPoint = nil
            touchSelectionActiveEndPoint = nil
            touchSelectionAnchorMousePoint = nil
            touchSelectionActiveEndMousePoint = nil
            touchSelectionGridOrigin = nil
            touchSelectionGridMetrics = nil
            touchSelectionGridScale = nil
        }

        /// Keeps both 48-point hit targets reachable. Stored points remain raw
        /// terminal coordinates so an endpoint beyond the top/bottom during
        /// Ghostty autoscroll is not corrupted by display clamping.
        func layoutSelectionHandles() {
            #if DEBUG
                defer { refreshSelectionDebugSnapshot() }
            #endif
            guard selectionHandlesVisible,
                  let startPoint = touchSelectionAnchorPoint,
                  let endPoint = touchSelectionActiveEndPoint
            else { return }
            guard selectionHandlesViewportBounds == terminalViewportBounds,
                  touchSelectionGridMetrics == surface?.size(),
                  touchSelectionGridScale == contentScaleFactor
            else {
                dismissSelectionHandles()
                return
            }

            positionSelectionHandle(selectionStartHandle, at: startPoint)
            positionSelectionHandle(selectionEndHandle, at: endPoint)
            bringSelectionHandlesToFront()
        }

        private func positionSelectionHandle(
            _ handle: TerminalSelectionHandleView?,
            at point: CGPoint
        ) {
            guard let handle else { return }
            let viewport = terminalViewportBounds
            let half = TerminalSelectionHandleView.hitSize / 2
            let minimumX = min(viewport.midX, viewport.minX + half)
            let maximumX = max(viewport.midX, viewport.maxX - half)
            let minimumY = min(viewport.midY, viewport.minY + half)
            let maximumY = max(viewport.midY, viewport.maxY - half)
            let center = CGPoint(
                x: min(max(point.x, minimumX), maximumX),
                y: min(max(point.y, minimumY), maximumY)
            )
            handle.bounds = CGRect(
                origin: .zero,
                size: CGSize(
                    width: TerminalSelectionHandleView.hitSize,
                    height: TerminalSelectionHandleView.hitSize
                )
            )
            handle.center = center
            handle.setDimmed(!viewport.contains(point))
        }

        private func bringSelectionHandlesToFront() {
            if let start = selectionStartHandle { bringSubviewToFront(start) }
            if let end = selectionEndHandle { bringSubviewToFront(end) }
        }

        private func snapSingleWordSelectionEndpointsIfPossible() {
            guard let surface,
                  let selection = surface.readSelectionResult(),
                  let word = surface.quicklookWord(),
                  selection.offsetStart == word.offsetStart,
                  selection.offsetLength == word.offsetLength,
                  let metrics = surface.size(),
                  metrics.columns > 0,
                  contentScaleFactor > 0
            else { return }

            let cellWidth = CGFloat(metrics.cellWidthPixels) / contentScaleFactor
            let cellHeight = CGFloat(metrics.cellHeightPixels) / contentScaleFactor
            guard cellWidth > 0, cellHeight > 0,
                  let gridOrigin = touchSelectionGridOrigin
            else { return }

            let columns = Int(metrics.columns)
            let firstCell = Int(word.offsetStart)
            // offsetLength is the inclusive distance from first to last cell.
            let lastCell = firstCell + Int(word.offsetLength)
            let firstColumn = firstCell % columns
            let firstRow = firstCell / columns
            let lastColumn = lastCell % columns
            let lastRow = lastCell / columns

            touchSelectionAnchorPoint = CGPoint(
                x: gridOrigin.x + CGFloat(firstColumn) * cellWidth,
                y: gridOrigin.y + CGFloat(firstRow + 1) * cellHeight
            )
            touchSelectionActiveEndPoint = CGPoint(
                x: gridOrigin.x + CGFloat(lastColumn + 1) * cellWidth,
                y: gridOrigin.y + CGFloat(lastRow + 1) * cellHeight
            )
            // Display markers belong on cell edges, but Ghostty hit testing
            // must use interior points or an exact trailing/bottom edge would
            // resolve to the adjacent cell. Keep the mouse points on the outer
            // quarters so a later character-granularity handle drag crosses
            // Ghostty's in-cell selection threshold on the inclusive side.
            touchSelectionAnchorMousePoint = CGPoint(
                x: gridOrigin.x + (CGFloat(firstColumn) + 0.25) * cellWidth,
                y: gridOrigin.y + (CGFloat(firstRow) + 0.5) * cellHeight
            )
            touchSelectionActiveEndMousePoint = CGPoint(
                x: gridOrigin.x + (CGFloat(lastColumn) + 0.75) * cellWidth,
                y: gridOrigin.y + (CGFloat(lastRow) + 0.5) * cellHeight
            )
        }

        @objc func handleSelectionHandlePan(_ gesture: UIPanGestureRecognizer) {
            #if DEBUG
                defer { refreshSelectionDebugSnapshot() }
            #endif
            guard let handle = gesture.view as? TerminalSelectionHandleView,
                  let startPoint = touchSelectionAnchorPoint,
                  let endPoint = touchSelectionActiveEndPoint,
                  let startMousePoint = touchSelectionAnchorMousePoint,
                  let endMousePoint = touchSelectionActiveEndMousePoint
            else { return }

            let location = gesture.location(in: self)
            let mods = ghostty_input_mods_e(rawValue: 0)

            switch gesture.state {
            case .began:
                guard let surface, !surface.isMouseCaptured else {
                    dismissSelectionHandles()
                    return
                }
                selectionEditMenuInteraction.dismissMenu()
                selectionHandleDragOriginalPoints = (
                    start: startPoint,
                    end: endPoint
                )
                selectionHandleDragOriginalMousePoints = (
                    start: startMousePoint,
                    end: endMousePoint
                )
                let draggedDisplayPoint = handle.endpoint == .start
                    ? startPoint
                    : endPoint
                // Follow the gesture location directly once the pan begins.
                // Capturing an offset from the threshold-crossing location makes
                // the endpoint lag the finger by UIKit's pan hysteresis distance.
                selectionHandleDragTouchOffset = .zero
                let draggedMousePoint = handle.endpoint == .start
                    ? startMousePoint
                    : endMousePoint
                selectionHandleDragMouseOffset = CGPoint(
                    x: draggedMousePoint.x - draggedDisplayPoint.x,
                    y: draggedMousePoint.y - draggedDisplayPoint.y
                )
                selectionHandleMode = handle.endpoint == .start
                    ? .adjustingStart
                    : .adjustingEnd
                let fixedPoint = handle.endpoint == .start
                    ? endMousePoint
                    : startMousePoint

                // A reset guarantees this press is character-granularity,
                // independent of Ghostty's recent double-click count.
                resetSyntheticClickCount(relativeTo: fixedPoint)
                surface.sendMousePos(
                    x: min(max(fixedPoint.x, 0), bounds.width),
                    y: fixedPoint.y,
                    mods: mods
                )
                surface.sendMouseButton(
                    state: GHOSTTY_MOUSE_PRESS,
                    button: GHOSTTY_MOUSE_LEFT,
                    mods: mods
                )
                syntheticLeftButtonDown = true
                activePointerButton = GHOSTTY_MOUSE_LEFT
                let draggedPoint = handle.endpoint == .start
                    ? startMousePoint
                    : endMousePoint
                selectionHandleLastFeedbackCell = selectionCell(at: draggedPoint)
                selectionHandleFeedbackGenerator.prepare()
                showSelectionMagnifier(at: draggedDisplayPoint)

            case .changed:
                guard syntheticLeftButtonDown else { return }
                guard let surface, !surface.isMouseCaptured else {
                    dismissSelectionHandles()
                    return
                }
                let endpointLocation = selectionHandleLocation(for: location)
                let mouseLocation = selectionHandleMouseLocation(
                    for: endpointLocation
                )
                updateDraggedSelectionEndpoint(
                    handle.endpoint,
                    displayPoint: endpointLocation,
                    mousePoint: mouseLocation
                )
                surface.sendMousePos(
                    x: min(max(mouseLocation.x, 0), bounds.width),
                    y: mouseLocation.y,
                    mods: mods
                )
                emitSelectionFeedbackIfCellChanged(at: mouseLocation)
                layoutSelectionHandles()
                showSelectionMagnifier(at: endpointLocation)

            case .ended:
                guard syntheticLeftButtonDown else { return }
                guard let surface, !surface.isMouseCaptured else {
                    dismissSelectionHandles()
                    return
                }
                let endpointLocation = selectionHandleLocation(for: location)
                let mouseLocation = selectionHandleMouseLocation(
                    for: endpointLocation
                )
                updateDraggedSelectionEndpoint(
                    handle.endpoint,
                    displayPoint: endpointLocation,
                    mousePoint: mouseLocation
                )
                surface.sendMousePos(
                    x: min(max(mouseLocation.x, 0), bounds.width),
                    y: mouseLocation.y,
                    mods: mods
                )
                emitSelectionFeedbackIfCellChanged(at: mouseLocation)
                hideSelectionMagnifier()
                selectionHandleLastFeedbackCell = nil
                releaseSyntheticSelectionButton()
                activePointerButton = nil
                selectionHandleMode = .none
                selectionHandleDragOriginalPoints = nil
                selectionHandleDragOriginalMousePoints = nil
                selectionHandleDragTouchOffset = .zero
                selectionHandleDragMouseOffset = .zero
                normalizeTouchSelectionEndpoints()
                layoutSelectionHandles()
                if selectionHandlesVisible,
                   surface.readSelection()?.isEmpty == false {
                    presentTouchSelectionEditMenu(at: selectionHandlesMenuPoint())
                } else {
                    dismissSelectionHandles()
                }

            case .cancelled, .failed:
                hideSelectionMagnifier()
                selectionHandleLastFeedbackCell = nil
                releaseSyntheticSelectionButton()
                activePointerButton = nil
                guard surface?.isMouseCaptured != true else {
                    dismissSelectionHandles()
                    return
                }
                if let original = selectionHandleDragOriginalPoints,
                   let originalMouse = selectionHandleDragOriginalMousePoints
                {
                    touchSelectionAnchorPoint = original.start
                    touchSelectionActiveEndPoint = original.end
                    touchSelectionAnchorMousePoint = originalMouse.start
                    touchSelectionActiveEndMousePoint = originalMouse.end
                    rebuildTouchSelection(
                        from: originalMouse.start,
                        to: originalMouse.end
                    )
                }
                selectionHandleMode = .none
                selectionHandleDragOriginalPoints = nil
                selectionHandleDragOriginalMousePoints = nil
                selectionHandleDragTouchOffset = .zero
                selectionHandleDragMouseOffset = .zero
                normalizeTouchSelectionEndpoints()
                layoutSelectionHandles()
                if selectionHandlesVisible,
                   surface?.readSelection()?.isEmpty == false {
                    presentTouchSelectionEditMenu(at: selectionHandlesMenuPoint())
                }

            default:
                break
            }
        }

        private func selectionHandleLocation(for touchLocation: CGPoint) -> CGPoint {
            CGPoint(
                x: touchLocation.x + selectionHandleDragTouchOffset.x,
                y: touchLocation.y + selectionHandleDragTouchOffset.y
            )
        }

        private func selectionHandleMouseLocation(
            for displayLocation: CGPoint
        ) -> CGPoint {
            CGPoint(
                x: displayLocation.x + selectionHandleDragMouseOffset.x,
                y: displayLocation.y + selectionHandleDragMouseOffset.y
            )
        }

        private func updateDraggedSelectionEndpoint(
            _ endpoint: TerminalSelectionEndpoint,
            displayPoint: CGPoint,
            mousePoint: CGPoint
        ) {
            switch endpoint {
            case .start:
                touchSelectionAnchorPoint = displayPoint
                touchSelectionAnchorMousePoint = mousePoint
            case .end:
                touchSelectionActiveEndPoint = displayPoint
                touchSelectionActiveEndMousePoint = mousePoint
            }
        }

        private func rebuildTouchSelection(from start: CGPoint, to end: CGPoint) {
            guard let surface else { return }
            let mods = ghostty_input_mods_e(rawValue: 0)
            resetSyntheticClickCount(relativeTo: start)
            surface.sendMousePos(
                x: min(max(start.x, 0), bounds.width),
                y: start.y,
                mods: mods
            )
            surface.sendMouseButton(
                state: GHOSTTY_MOUSE_PRESS,
                button: GHOSTTY_MOUSE_LEFT,
                mods: mods
            )
            syntheticLeftButtonDown = true
            surface.sendMousePos(
                x: min(max(end.x, 0), bounds.width),
                y: end.y,
                mods: mods
            )
            releaseSyntheticSelectionButton()
        }

        func normalizeTouchSelectionEndpoints() {
            guard let first = touchSelectionAnchorPoint,
                  let second = touchSelectionActiveEndPoint
            else { return }
            let firstOrderingPoint = touchSelectionAnchorMousePoint ?? first
            let secondOrderingPoint = touchSelectionActiveEndMousePoint ?? second
            guard !touchSelectionPointPrecedes(firstOrderingPoint, secondOrderingPoint) else {
                return
            }
            touchSelectionAnchorPoint = second
            touchSelectionActiveEndPoint = first
            let firstMouse = touchSelectionAnchorMousePoint
            touchSelectionAnchorMousePoint = touchSelectionActiveEndMousePoint
            touchSelectionActiveEndMousePoint = firstMouse
        }

        /// Resolves Ghostty's actual grid origin from its effective padding
        /// configuration and pixel metrics. Quicklook's Y coordinate is a text
        /// baseline, not a cell-top coordinate, so it cannot be used here.
        func refreshTouchSelectionGridOrigin() {
            guard let surface,
                  let metrics = surface.size(),
                  metrics.columns > 0,
                  metrics.rows > 0,
                  contentScaleFactor > 0
            else { return }

            guard let padding = surface.gridPadding() else { return }
            let scale = contentScaleFactor
            touchSelectionGridOrigin = CGPoint(
                x: CGFloat(padding.leftPixels) / scale,
                y: CGFloat(padding.topPixels) / scale
            )
            touchSelectionGridMetrics = metrics
            touchSelectionGridScale = scale
        }

        func touchSelectionGridGeometry(
            for metrics: TerminalGridMetrics
        ) -> (origin: CGPoint, cellWidth: CGFloat, cellHeight: CGFloat)? {
            guard metrics.columns > 0,
                  metrics.rows > 0,
                  contentScaleFactor > 0
            else { return nil }

            let cellWidth = CGFloat(metrics.cellWidthPixels) / contentScaleFactor
            let cellHeight = CGFloat(metrics.cellHeightPixels) / contentScaleFactor
            guard cellWidth > 0, cellHeight > 0 else { return nil }

            // Balanced residual padding changes with every resize. Reuse the
            // origin only while Ghostty's complete pixel metrics and scale match.
            if let origin = touchSelectionGridOrigin,
               touchSelectionGridMetrics == metrics,
               touchSelectionGridScale == contentScaleFactor {
                return (origin, cellWidth, cellHeight)
            }
            refreshTouchSelectionGridOrigin()
            guard let origin = touchSelectionGridOrigin else { return nil }
            return (origin, cellWidth, cellHeight)
        }

        private func touchSelectionCellCoordinates(
            at point: CGPoint,
            metrics: TerminalGridMetrics
        ) -> (column: Int, row: Int)? {
            guard let geometry = touchSelectionGridGeometry(for: metrics) else {
                return nil
            }
            return (
                Int(floor((point.x - geometry.origin.x) / geometry.cellWidth)),
                Int(floor((point.y - geometry.origin.y) / geometry.cellHeight))
            )
        }

        private func touchSelectionCellIndex(
            at point: CGPoint,
            metrics: TerminalGridMetrics
        ) -> Int? {
            guard let cell = touchSelectionCellCoordinates(at: point, metrics: metrics),
                  cell.column >= 0,
                  cell.column < Int(metrics.columns),
                  cell.row >= 0,
                  cell.row < Int(metrics.rows)
            else { return nil }
            return cell.row * Int(metrics.columns) + cell.column
        }

        private func touchSelectionPointPrecedes(_ first: CGPoint, _ second: CGPoint) -> Bool {
            if let metrics = surface?.size(),
               let firstCell = touchSelectionCellCoordinates(at: first, metrics: metrics),
               let secondCell = touchSelectionCellCoordinates(at: second, metrics: metrics) {
                if firstCell.row != secondCell.row {
                    return firstCell.row < secondCell.row
                }
                if firstCell.column != secondCell.column {
                    return firstCell.column < secondCell.column
                }
            }
            if first.y != second.y { return first.y < second.y }
            return first.x <= second.x
        }

        private func selectionCell(at point: CGPoint) -> CGPoint? {
            guard let metrics = surface?.size(),
                  let cell = touchSelectionCellCoordinates(at: point, metrics: metrics)
            else { return nil }
            let column = min(max(cell.column, 0), Int(metrics.columns) - 1)
            return CGPoint(x: column, y: cell.row)
        }

        private func emitSelectionFeedbackIfCellChanged(at point: CGPoint) {
            guard let cell = selectionCell(at: point),
                  cell != selectionHandleLastFeedbackCell
            else { return }
            selectionHandleLastFeedbackCell = cell
            selectionHandleFeedbackGenerator.selectionChanged()
            selectionHandleFeedbackGenerator.prepare()
        }

        func nudgeSelectionEndpoint(
            _ endpoint: TerminalSelectionEndpoint,
            byCells delta: Int
        ) {
            #if DEBUG
                defer { refreshSelectionDebugSnapshot() }
            #endif
            guard surface?.isMouseCaptured != true else {
                dismissSelectionHandles()
                return
            }
            guard delta != 0,
                  let surface,
                  let metrics = surface.size(),
                  metrics.columns > 0,
                  let geometry = touchSelectionGridGeometry(for: metrics),
                  let startPoint = touchSelectionAnchorPoint,
                  let endPoint = touchSelectionActiveEndPoint,
                  let startMouse = touchSelectionAnchorMousePoint,
                  let endMouse = touchSelectionActiveEndMousePoint
            else { return }

            let cellWidth = geometry.cellWidth
            let cellHeight = geometry.cellHeight
            let currentDisplay = endpoint == .start ? startPoint : endPoint
            let currentMouse = endpoint == .start ? startMouse : endMouse
            let fixedMouse = endpoint == .start ? endMouse : startMouse
            let columns = Int(metrics.columns)
            let currentColumn = min(
                max(
                    Int(floor((currentMouse.x - geometry.origin.x) / cellWidth)),
                    0
                ),
                columns - 1
            )
            var newColumn = currentColumn + delta
            var rowDelta = 0
            while newColumn < 0 {
                newColumn += columns
                rowDelta -= 1
            }
            while newColumn >= columns {
                newColumn -= columns
                rowDelta += 1
            }
            let newMouse = CGPoint(
                x: geometry.origin.x + (CGFloat(newColumn) + 0.5) * cellWidth,
                y: currentMouse.y + CGFloat(rowDelta) * cellHeight
            )
            let newDisplay = CGPoint(
                x: currentDisplay.x + newMouse.x - currentMouse.x,
                y: currentDisplay.y + newMouse.y - currentMouse.y
            )

            selectionEditMenuInteraction.dismissMenu()
            guard let candidateIndex = touchSelectionCellIndex(
                at: newMouse,
                metrics: metrics
            ),
                let fixedIndex = touchSelectionCellIndex(
                    at: fixedMouse,
                    metrics: metrics
                ),
                endpoint == .start
                    ? candidateIndex <= fixedIndex
                    : candidateIndex >= fixedIndex
            else {
                UIAccessibility.post(
                    notification: .announcement,
                    argument: "Selection endpoint cannot move farther"
                )
                return
            }

            let originalPoints = (start: startPoint, end: endPoint)
            let originalMousePoints = (start: startMouse, end: endMouse)
            switch endpoint {
            case .start:
                touchSelectionAnchorPoint = newDisplay
                touchSelectionAnchorMousePoint = newMouse
            case .end:
                touchSelectionActiveEndPoint = newDisplay
                touchSelectionActiveEndMousePoint = newMouse
            }
            rebuildTouchSelection(from: fixedMouse, to: newMouse)
            guard surface.readSelection()?.isEmpty == false else {
                touchSelectionAnchorPoint = originalPoints.start
                touchSelectionActiveEndPoint = originalPoints.end
                touchSelectionAnchorMousePoint = originalMousePoints.start
                touchSelectionActiveEndMousePoint = originalMousePoints.end
                rebuildTouchSelection(
                    from: originalMousePoints.start,
                    to: originalMousePoints.end
                )
                layoutSelectionHandles()
                UIAccessibility.post(
                    notification: .announcement,
                    argument: "Selection endpoint cannot move farther"
                )
                return
            }

            normalizeTouchSelectionEndpoints()
            layoutSelectionHandles()
            selectionHandleFeedbackGenerator.selectionChanged()
            UIAccessibility.post(
                notification: .announcement,
                argument: endpoint == .start
                    ? "Selection start adjusted"
                    : "Selection end adjusted"
            )
            if selectionHandlesVisible,
               surface.readSelection()?.isEmpty == false {
                presentTouchSelectionEditMenu(at: selectionHandlesMenuPoint())
            }
        }

        func selectionHandlesMenuPoint() -> CGPoint {
            guard let start = touchSelectionAnchorPoint,
                  let end = touchSelectionActiveEndPoint
            else { return CGPoint(x: bounds.midX, y: bounds.midY) }
            return CGPoint(
                x: (start.x + end.x) / 2,
                y: min(start.y, end.y)
            )
        }
    }
#endif
