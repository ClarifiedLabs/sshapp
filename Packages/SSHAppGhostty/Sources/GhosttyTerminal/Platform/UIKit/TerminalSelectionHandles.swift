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
        }

        func setDimmed(_ dimmed: Bool) {
            alpha = dimmed ? 0.45 : 1
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
            addSubview(start)
            addSubview(end)
            selectionStartHandle = start
            selectionEndHandle = end
        }

        /// Captures the gesture endpoints after Ghostty finalizes a non-empty
        /// selection, then exposes persistent handles. For the common
        /// stationary single-word gesture, use Ghostty's quicklook cell
        /// coordinates to snap to the selected word's real leading/trailing
        /// edges. Swift string offsets never participate in geometry.
        func installSelectionHandlesAfterTouchSelection() {
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
            snapSingleWordSelectionEndpointsIfPossible()
            normalizeTouchSelectionEndpoints()
            selectionHandlesVisible = true
            selectionStartHandle?.setVisible(true)
            selectionEndHandle?.setVisible(true)
            layoutSelectionHandles()
        }

        func dismissSelectionHandles() {
            UIMenuController.shared.hideMenu()
            let wasAdjustingSelection = syntheticLeftButtonDown
                || selectionHandleMode != .none
            releaseSyntheticSelectionButton()
            if wasAdjustingSelection {
                activePointerButton = nil
            }
            selectionHandlesVisible = false
            selectionHandleMode = .none
            selectionHandleDragOriginalPoints = nil
            selectionHandleDragOriginalMousePoints = nil
            selectionStartHandle?.setVisible(false)
            selectionEndHandle?.setVisible(false)
            touchSelectionAnchorPoint = nil
            touchSelectionActiveEndPoint = nil
            touchSelectionAnchorMousePoint = nil
            touchSelectionActiveEndMousePoint = nil
        }

        /// Keeps both 48-point hit targets reachable. Stored points remain raw
        /// terminal coordinates so an endpoint beyond the top/bottom during
        /// Ghostty autoscroll is not corrupted by display clamping.
        func layoutSelectionHandles() {
            guard selectionHandlesVisible,
                  let startPoint = touchSelectionAnchorPoint,
                  let endPoint = touchSelectionActiveEndPoint
            else { return }

            positionSelectionHandle(selectionStartHandle, at: startPoint)
            positionSelectionHandle(selectionEndHandle, at: endPoint)
            bringSelectionHandlesToFront()
        }

        private func positionSelectionHandle(
            _ handle: TerminalSelectionHandleView?,
            at point: CGPoint
        ) {
            guard let handle else { return }
            let half = TerminalSelectionHandleView.hitSize / 2
            let minimumX = min(bounds.midX, bounds.minX + half)
            let maximumX = max(bounds.midX, bounds.maxX - half)
            let minimumY = min(bounds.midY, bounds.minY + half)
            let maximumY = max(bounds.midY, bounds.maxY - half)
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
            handle.setDimmed(!bounds.contains(point))
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

            // Ghostty reports quicklook top-left in host view points, while
            // grid cell dimensions are surface pixels.
            let cellWidth = CGFloat(metrics.cellWidthPixels) / contentScaleFactor
            let cellHeight = CGFloat(metrics.cellHeightPixels) / contentScaleFactor
            guard cellWidth > 0, cellHeight > 0 else { return }

            let columns = Int(metrics.columns)
            let firstCell = Int(word.offsetStart)
            // offsetLength is the inclusive distance from first to last cell.
            let lastCell = firstCell + Int(word.offsetLength)
            let firstColumn = firstCell % columns
            let firstRow = firstCell / columns
            let lastColumn = lastCell % columns
            let lastRow = lastCell / columns
            let gridOriginX = CGFloat(word.pointX) - CGFloat(firstColumn) * cellWidth

            touchSelectionAnchorPoint = CGPoint(
                x: CGFloat(word.pointX),
                y: CGFloat(word.pointY) + cellHeight
            )
            touchSelectionActiveEndPoint = CGPoint(
                x: gridOriginX + CGFloat(lastColumn + 1) * cellWidth,
                y: CGFloat(word.pointY) + CGFloat(lastRow - firstRow + 1) * cellHeight
            )
            // Display markers belong on cell edges, but Ghostty hit testing
            // must use interior points or an exact trailing/bottom edge would
            // resolve to the adjacent cell.
            touchSelectionAnchorMousePoint = CGPoint(
                x: CGFloat(word.pointX) + cellWidth / 2,
                y: CGFloat(word.pointY) + cellHeight / 2
            )
            touchSelectionActiveEndMousePoint = CGPoint(
                x: gridOriginX + (CGFloat(lastColumn) + 0.5) * cellWidth,
                y: CGFloat(word.pointY) + (CGFloat(lastRow - firstRow) + 0.5) * cellHeight
            )
        }

        @objc func handleSelectionHandlePan(_ gesture: UIPanGestureRecognizer) {
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
                UIMenuController.shared.hideMenu()
                selectionHandleDragOriginalPoints = (
                    start: startPoint,
                    end: endPoint
                )
                selectionHandleDragOriginalMousePoints = (
                    start: startMousePoint,
                    end: endMousePoint
                )
                selectionHandleMode = handle.endpoint == .start
                    ? .adjustingStart
                    : .adjustingEnd
                let fixedPoint = handle.endpoint == .start
                    ? endMousePoint
                    : startMousePoint

                // A reset guarantees this press is character-granularity,
                // independent of Ghostty's recent double-click count.
                resetSyntheticClickCount()
                surface?.sendMousePos(
                    x: min(max(fixedPoint.x, 0), bounds.width),
                    y: fixedPoint.y,
                    mods: mods
                )
                surface?.sendMouseButton(
                    state: GHOSTTY_MOUSE_PRESS,
                    button: GHOSTTY_MOUSE_LEFT,
                    mods: mods
                )
                syntheticLeftButtonDown = true
                activePointerButton = GHOSTTY_MOUSE_LEFT

            case .changed:
                guard syntheticLeftButtonDown else { return }
                updateDraggedSelectionEndpoint(handle.endpoint, to: location)
                surface?.sendMousePos(
                    x: min(max(location.x, 0), bounds.width),
                    y: location.y,
                    mods: mods
                )
                layoutSelectionHandles()

            case .ended:
                guard syntheticLeftButtonDown else { return }
                updateDraggedSelectionEndpoint(handle.endpoint, to: location)
                surface?.sendMousePos(
                    x: min(max(location.x, 0), bounds.width),
                    y: location.y,
                    mods: mods
                )
                releaseSyntheticSelectionButton()
                activePointerButton = nil
                selectionHandleMode = .none
                selectionHandleDragOriginalPoints = nil
                selectionHandleDragOriginalMousePoints = nil
                normalizeTouchSelectionEndpoints()
                layoutSelectionHandles()
                if surface?.readSelection()?.isEmpty == false {
                    showSelectionCopyMenu(at: selectionHandlesMenuPoint())
                } else {
                    dismissSelectionHandles()
                }

            case .cancelled, .failed:
                releaseSyntheticSelectionButton()
                activePointerButton = nil
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
                normalizeTouchSelectionEndpoints()
                layoutSelectionHandles()
                if surface?.readSelection()?.isEmpty == false {
                    showSelectionCopyMenu(at: selectionHandlesMenuPoint())
                }

            default:
                break
            }
        }

        private func updateDraggedSelectionEndpoint(
            _ endpoint: TerminalSelectionEndpoint,
            to point: CGPoint
        ) {
            switch endpoint {
            case .start:
                touchSelectionAnchorPoint = point
                touchSelectionAnchorMousePoint = point
            case .end:
                touchSelectionActiveEndPoint = point
                touchSelectionActiveEndMousePoint = point
            }
        }

        private func rebuildTouchSelection(from start: CGPoint, to end: CGPoint) {
            guard let surface else { return }
            let mods = ghostty_input_mods_e(rawValue: 0)
            resetSyntheticClickCount()
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
                  let second = touchSelectionActiveEndPoint,
                  !touchSelectionPointPrecedes(first, second)
            else { return }
            touchSelectionAnchorPoint = second
            touchSelectionActiveEndPoint = first
            let firstMouse = touchSelectionAnchorMousePoint
            touchSelectionAnchorMousePoint = touchSelectionActiveEndMousePoint
            touchSelectionActiveEndMousePoint = firstMouse
        }

        private func touchSelectionPointPrecedes(_ first: CGPoint, _ second: CGPoint) -> Bool {
            if let metrics = surface?.size(), contentScaleFactor > 0 {
                let cellWidth = max(
                    CGFloat(metrics.cellWidthPixels) / contentScaleFactor,
                    1
                )
                let cellHeight = max(
                    CGFloat(metrics.cellHeightPixels) / contentScaleFactor,
                    1
                )
                let firstRow = floor(first.y / cellHeight)
                let secondRow = floor(second.y / cellHeight)
                if firstRow != secondRow { return firstRow < secondRow }
                let firstColumn = floor(first.x / cellWidth)
                let secondColumn = floor(second.x / cellWidth)
                if firstColumn != secondColumn { return firstColumn < secondColumn }
            }
            if first.y != second.y { return first.y < second.y }
            return first.x <= second.x
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
