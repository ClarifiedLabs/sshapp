import CoreText
import UIKit

/// Bounded reuse of CoreText shaping. This caches neither VT cells nor mutable
/// native terminal storage. Geometry/font changes invalidate all cached lines.
/// Confine each instance to one serial owner (CoreText UI or a raster worker).
/// A raster worker may transfer the cache only in its private drained glyph
/// bundle after rendering returns; no two workers access it concurrently and the
/// main actor only stores/releases that bundle. This type is not Sendable.
public final class VTGlyphCache {
    private struct Key: Hashable {
        let text: String
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        let traits: UInt32
        let faint: Bool
    }
    /// CLOCK (second-chance) replacement: a hit sets `referenced`; eviction
    /// sweeps the ring clearing bits until an unreferenced slot. Amortized O(1)
    /// per miss, unlike scanning every entry for the least recently used.
    private struct Slot { let key: Key; let line: CTLine; var referenced: Bool }
    private var entries: [Key: Int] = [:]
    private var slots: [Slot] = []
    private var hand = 0
    private var fonts: [UInt32: UIFont] = [:]
    private var baseFont: UIFont?
    private var scale: Double = 0
    let capacity: Int
    var count: Int { entries.count }
    private(set) var misses = 0

    public init(capacity: Int = 512) { self.capacity = max(1, capacity) }

    func removeAll() {
        entries.removeAll()
        slots.removeAll()
        hand = 0
        fonts.removeAll()
        baseFont = nil
        scale = 0
    }

    func prepare(font: UIFont, scale: Double) {
        guard baseFont != font || self.scale != scale else { return }
        baseFont = font
        self.scale = scale
        entries.removeAll(keepingCapacity: true)
        slots.removeAll(keepingCapacity: true)
        hand = 0
        fonts.removeAll(keepingCapacity: true)
    }

    func line(for cell: VTCellValue, font: UIFont) -> (CTLine, UIFont, UIColor) {
        var traits: UIFontDescriptor.SymbolicTraits = []
        if cell.bold { traits.insert(.traitBold) }
        if cell.italic { traits.insert(.traitItalic) }
        let drawFont: UIFont
        if let cached = fonts[traits.rawValue] { drawFont = cached }
        else {
            drawFont = UIFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits) ?? font.fontDescriptor, size: font.pointSize)
            fonts[traits.rawValue] = drawFont
        }
        let color = UIColor(red: CGFloat(cell.foreground.red) / 255,
                            green: CGFloat(cell.foreground.green) / 255,
                            blue: CGFloat(cell.foreground.blue) / 255,
                            alpha: cell.faint ? 0.5 : 1)
        let key = Key(text: cell.text, red: cell.foreground.red, green: cell.foreground.green,
                      blue: cell.foreground.blue, traits: traits.rawValue, faint: cell.faint)
        if let index = entries[key] {
            slots[index].referenced = true
            return (slots[index].line, drawFont, color)
        }
        misses += 1
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: cell.text, attributes: [.font: drawFont, .foregroundColor: color]))
        // Count and key length are bounded; pathological graphemes are drawn
        // correctly without retaining their shaped data in the cache.
        if cell.text.utf8.count <= 256 {
            if slots.count < capacity {
                entries[key] = slots.count
                slots.append(Slot(key: key, line: line, referenced: false))
            } else {
                while slots[hand].referenced {
                    slots[hand].referenced = false
                    hand = (hand + 1) % slots.count
                }
                entries.removeValue(forKey: slots[hand].key)
                entries[key] = hand
                slots[hand] = Slot(key: key, line: line, referenced: false)
                hand = (hand + 1) % slots.count
            }
        }
        return (line, drawFont, color)
    }
}
