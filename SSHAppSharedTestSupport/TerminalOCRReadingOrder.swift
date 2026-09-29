import Foundation

/// Reorders OCR fragments without correcting, normalizing, or inferring their text.
/// Coordinates must be normalized Vision rectangles (origin at the bottom left).
enum TerminalOCRReadingOrder {
    struct Observation {
        let text: String
        let boundingBox: CGRect
    }

    /// Joins fragments with spaces and visual rows with newlines, top to bottom.
    static func text(from observations: [Observation]) -> String {
        let fragments = observations.enumerated().sorted { lhs, rhs in
            if lhs.element.boundingBox.midY != rhs.element.boundingBox.midY {
                return lhs.element.boundingBox.midY > rhs.element.boundingBox.midY
            }
            if lhs.element.boundingBox.minX != rhs.element.boundingBox.minX {
                return lhs.element.boundingBox.minX < rhs.element.boundingBox.minX
            }
            return lhs.offset < rhs.offset
        }
        var rows: [[Observation]] = []
        for fragment in fragments.map(\.element) {
            // Require agreement with every fragment, not just the last one: small
            // OCR offsets must not chain together and collapse neighboring rows.
            let candidates = rows.indices.filter { index in
                rows[index].allSatisfy { sharesRow($0.boundingBox, fragment.boundingBox) }
            }
            if let index = candidates.min(by: {
                abs(baseline(of: rows[$0]) - fragment.boundingBox.minY)
                    < abs(baseline(of: rows[$1]) - fragment.boundingBox.minY)
            }) {
                rows[index].append(fragment)
            } else {
                rows.append([fragment])
            }
        }

        // Lower box edges approximate a shared baseline even when glyph heights
        // differ. A median prevents one unusually tall/low box from moving a row.
        return rows.enumerated().sorted { lhs, rhs in
            let leftBaseline = baseline(of: lhs.element)
            let rightBaseline = baseline(of: rhs.element)
            if leftBaseline != rightBaseline {
                return leftBaseline > rightBaseline
            }
            return lhs.offset < rhs.offset
        }.map { row in
            row.element.enumerated().sorted { lhs, rhs in
                if lhs.element.boundingBox.minX != rhs.element.boundingBox.minX {
                    return lhs.element.boundingBox.minX < rhs.element.boundingBox.minX
                }
                return lhs.offset < rhs.offset
            }.map(\.element.text).joined(separator: " ")
        }.joined(separator: "\n")
    }

    private static func sharesRow(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let height = min(lhs.height, rhs.height)
        guard height > 0 else { return false }
        let overlap = max(0, min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY))
        let centersAlign = abs(lhs.midY - rhs.midY) <= height * 0.4
        let baselinesAlign = abs(lhs.minY - rhs.minY) <= height * 0.2
        // Scale tolerance by the smaller glyph box, not screenshot size or the
        // taller box; otherwise a tall box can swallow an adjacent terminal row.
        return (centersAlign && overlap >= height * 0.5)
            || (baselinesAlign && overlap >= height * 0.7)
    }

    private static func baseline(of row: [Observation]) -> CGFloat {
        let edges = row.map(\.boundingBox.minY).sorted()
        let middle = edges.count / 2
        if edges.count.isMultiple(of: 2) {
            return (edges[middle - 1] + edges[middle]) / 2
        }
        return edges[middle]
    }
}
