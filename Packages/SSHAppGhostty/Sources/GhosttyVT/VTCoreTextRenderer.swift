import CoreText
import UIKit

/// Reference renderer and CPU fallback. Draws are pure functions of the
/// frame, context and caller-owned cache, so any serial owner may call them.
public enum VTCoreTextRenderer {
    public static func draw(_ frame: VTFrameValue, font: UIFont, context: CGContext, bounds: CGRect,
                            cache: VTGlyphCache, presentation: VTPresentationState = .init()) {
        context.saveGState()
        defer { context.restoreGState() }
        frame.paint.apply(to: context)
        context.setFillColor(frame.background.uiColor.cgColor)
        context.fill(bounds)
        let layout = frame.layout
        let decorations = VTDecorationGeometry(font: font, layout: layout)
        cache.prepare(font: font, scale: layout.scale)
        frame.graphics.draw(layer: .belowBackground, layout: layout, context: context)
        for (index, cell) in frame.cells.enumerated() {
            guard cell.selected || cell.background != frame.background else { continue }
            context.setFillColor(frame.paintedBackground(cell).uiColor.cgColor)
            context.fill(layout.rect(column: index % layout.columns, row: index / layout.columns))
        }
        frame.graphics.draw(layer: .belowText, layout: layout, context: context)
        func drawCell(_ cell: VTCellValue, at index: Int) {
            let cell = presentation.decorate(cell, at: index, in: frame)
            guard presentation.draws(cell) else { return }
            let rect = layout.rect(column: index % layout.columns, row: index / layout.columns, width: cell.width)
            if !cell.text.isEmpty {
                let (line, drawFont, _) = cache.line(for: cell, font: font)
                context.saveGState()
                context.clip(to: rect)
                context.translateBy(x: rect.minX, y: rect.minY + drawFont.ascender)
                context.scaleBy(x: 1, y: -1)
                context.textMatrix = .identity
                context.textPosition = .zero
                CTLineDraw(line, context)
                context.restoreGState()
            }
            for quad in decorations.quads(for: cell, in: rect) {
                context.setFillColor(quad.color.uiColor.withAlphaComponent(cell.faint ? 0.5 : 1).cgColor)
                context.fill(quad.rect)
            }
        }
        for (index, cell) in frame.cells.enumerated() { drawCell(frame.paintedCell(cell), at: index) }
        let cursor = VTCursorGeometry(frame: frame, presentation: presentation)
        context.setFillColor(frame.cursorColor.uiColor.withAlphaComponent(cursor.opacity).cgColor)
        cursor.rects.forEach { context.fill($0) }
        if let index = cursor.textIndex { drawCell(frame.cursorCell(at: index), at: index) }
        frame.graphics.draw(layer: .aboveText, layout: layout, context: context)
    }
}

extension VTColor {
    var uiColor: UIColor {
        UIColor(red: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }
}
