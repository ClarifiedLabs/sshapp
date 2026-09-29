import Foundation
import GhosttyVT

/// Edge speed is in terminal rows per tick, independent of screen scale. Small
/// viewports keep a middle dead zone; dragging farther beyond an edge caps at 4.
enum TerminalSelectionAutoscroll {
    static func rows(at point: CGPoint, layout: VTLayout, viewport: VTViewportValue) -> Int {
        rows(at: point, layout: layout, canScrollUp: viewport.canScrollUp, canScrollDown: viewport.canScrollDown)
    }

    static func rows(at point: CGPoint, layout: VTLayout, canScrollUp: Bool, canScrollDown: Bool) -> Int {
        guard point.x.isFinite, point.y.isFinite else { return 0 }
        let top = layout.padding
        let bottom = top + Double(layout.rows) * layout.cellHeight
        let band = min(24, (bottom - top) / 3)
        let step = max(12, layout.cellHeight)
        if point.y < top + band, canScrollUp {
            return -Int(min(4, max(1, ceil((top + band - point.y) / step))))
        }
        if point.y > bottom - band, canScrollDown {
            return Int(min(4, max(1, ceil((point.y - bottom + band) / step))))
        }
        return 0
    }
}
