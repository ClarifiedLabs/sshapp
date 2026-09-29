#if canImport(UIKit) && !targetEnvironment(macCatalyst)
import UIKit
import GhosttyVT

extension UITerminalView {
    func setupSelectionHandles() {
        nativeInteraction.install()
        #if DEBUG
        applySelectionDebugHandleIdentifiers()
        #endif
    }

    func showSelectionMagnifier(at point: CGPoint) { nativeInteraction.showMagnifier(at: point) }
    func hideSelectionMagnifier() {
        selectionMagnifier?.isHidden = true
        #if DEBUG
        refreshSelectionDebugSnapshot()
        #endif
    }
    func clearTouchSelectionAfterCopy() { dismissSelectionHandles() }
    func clearTouchSelection() { nativeInteraction.clearSelection(); dismissSelectionHandles() }

    func synchronizeTouchSelectionOverlayAfterRender() {
        guard let frame = surface?.frameValue else { return }
        nativeInteraction.update(frame)
        nativePointer.framePublished(frame)
        #if DEBUG
        refreshSelectionDebugSnapshot()
        #endif
    }

    func installSelectionHandlesAfterTouchSelection() { synchronizeTouchSelectionOverlayAfterRender() }
    func layoutSelectionHandles() { synchronizeTouchSelectionOverlayAfterRender() }

    func dismissSelectionHandles() {
        nativeInteraction.cancelSelectionDrag()
        dismissTerminalEditMenus()
        hideSelectionMagnifier()
        selectionHandlesVisible = false
        selectionHandlesViewportBounds = nil
        selectionHandleMode = .none
        selectionStartHandle?.setVisible(false)
        selectionEndHandle?.setVisible(false)
        touchSelectionAnchorPoint = nil
        touchSelectionActiveEndPoint = nil
        touchSelectionAnchorMousePoint = nil
        touchSelectionActiveEndMousePoint = nil
        selectionHandleLastFeedbackCell = nil
    }

    func normalizeTouchSelectionEndpoints() { synchronizeTouchSelectionOverlayAfterRender() }
    func nudgeSelectionEndpoint(_ endpoint: TerminalSelectionEndpoint, byCells delta: Int) {
        nativeInteraction.nudge(start: endpoint == .start, delta: delta)
    }
    func selectionHandlesMenuPoint() -> CGPoint {
        let start = selectionStartHandle?.center ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let end = selectionEndHandle?.center ?? start
        return CGPoint(x: (start.x + end.x) / 2, y: min(start.y, end.y))
    }

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

}
#endif
