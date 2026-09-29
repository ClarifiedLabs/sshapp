import CoreGraphics
import Foundation

/// Test-only provenance, independent of the privacy-cover/lock verdict. Works on
/// the full screenshot: terminal glyphs inside a card cannot supply the required
/// external artwork and bottom boundary. Unsupported OS icon styles fail closed.
enum SystemPrivacyIconMatcher {
    struct Evidence {
        let matches: [CGRect] // full-screenshot pixels, before any sampling fringe
        let scores: [String]
        // Independently measured opaque silhouette, BEFORE the existing 1px
        // sampling fringe. A bounding square is not an opacity witness.
        var opaqueRows: [CGRect] = []
        var bounds: CGRect? { matches.count == 1 ? matches[0] : nil }
        var description: String {
            "full-icon candidates=\(matches); \(scores.joined(separator: "; ")); unique=\(bounds != nil); external-contour-runs=\(opaqueRows.count)"
        }
    }

    private struct Raster {
        let width: Int
        let height: Int
        let gray: [UInt8]
        init?(_ image: CGImage, size: Int? = nil) {
            let width = size ?? image.width, height = size ?? image.height
            self.width = width; self.height = height
            var bytes = [UInt8](repeating: 0, count: width * height)
            let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: 0) else { return false }
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { return nil }
            gray = bytes
        }
        subscript(_ x: Int, _ y: Int) -> Int { Int(gray[y * width + x]) }
    }

    /// Bounds are measured, not a fixed OS icon size. The search ceiling is the
    /// existing iconPixelBounds 20% geometry limit; 12px is the minimum resolvable
    /// artwork, not a fallback size. Every accepted box needs measured top/bottom
    /// highlight ridges AND both side transitions, plus the complete asset mask.
    static func measure(in image: CGImage, snapshot: CGRect, display: CGRect,
                        artwork: CGImage) -> Evidence {
        let empty = Evidence(matches: [], scores: ["missing full artwork/boundary witness"])
        guard display.width > 0, display.height > 0, display.contains(snapshot),
              [display.minX, display.minY, display.width, display.height,
               snapshot.minX, snapshot.minY, snapshot.width, snapshot.height].allSatisfy(\.isFinite),
              let raster = Raster(image), artwork.width == artwork.height else { return empty }
        let sx = CGFloat(image.width) / display.width, sy = CGFloat(image.height) / display.height
        guard abs(sx - sy) < 0.01 else { return empty }
        let card = CGRect(x: (snapshot.minX - display.minX) * sx,
                          y: (snapshot.minY - display.minY) * sy,
                          width: snapshot.width * sx, height: snapshot.height * sy)
        let maximum = Int(floor(min(card.width, card.height) * 0.20))
        guard maximum >= 12 else { return empty }
        var matches: [CGRect] = [], scores: [String] = []
        for size in 12...maximum {
            guard let reference = Raster(artwork, size: size) else { return empty }
            let startX = Int(ceil(card.midX - CGFloat(size) / 2 - sx))
            let endX = Int(floor(card.midX - CGFloat(size) / 2 + sx))
            // At least 20% of the full icon on EACH side of the snapshot edge.
            let startY = Int(ceil(card.maxY - CGFloat(size) * 0.8))
            let endY = Int(floor(card.maxY - CGFloat(size) * 0.2))
            guard startX <= endX, startY <= endY else { continue }
            for y in startY...endY {
                for x in startX...endX {
                    // Need the entire icon and independent boundary samples.
                    guard x >= 2, y >= 2, x + size + 2 <= raster.width,
                          y + size + 2 <= raster.height else { continue }
                    let samples = (0..<5).map { size * (30 + $0 * 10) / 100 }
                    let ridges = samples.allSatisfy { offset in
                        let edge = raster[x + offset, y]
                        let ridge = edge - max(raster[x + offset, y - 2], raster[x + offset, y + 2]) > 6
                        let lightBackgroundStep = raster[x + offset, y - 1] - edge > 6
                            && edge <= raster[x + offset, y + 2] + 6
                        return (ridge || lightBackgroundStep) && raster[x + offset, y + size - 1]
                            - max(raster[x + offset, y + size - 3], raster[x + offset, y + size + 1]) > 6
                    }
                    guard ridges else { continue }
                    // The lower sides can be black-on-black wallpaper. Measure
                    // both sides in the portion still over the neutral snapshot.
                    let sideEnd = min(size * 45 / 100, Int(floor(card.maxY)) - y - 2)
                    let sideStart = size / 4
                    guard sideEnd > sideStart else { continue }
                    let sides = (0..<5).allSatisfy { index in
                        let offset = sideStart + (sideEnd - sideStart) * index / 4
                        return raster[x - 1, y + offset] - raster[x + 1, y + offset] > 6
                            && raster[x + size, y + offset] - raster[x + size - 2, y + offset] > 6
                    }
                    guard sides else { continue }
                    var intersection = 0, union = 0, externalIntersection = 0, externalUnion = 0
                    var foreground = 0, externalForeground = 0
                    for row in 0..<size {
                        for column in 0..<size {
                            let actual = raster[x + column, y + row] > 110
                            let expected = reference[column, row] > 110
                            let external = CGFloat(y + row) + 0.5 >= card.maxY
                            if actual && expected { intersection += 1; if external { externalIntersection += 1 } }
                            if actual || expected { union += 1; if external { externalUnion += 1 } }
                            if expected { foreground += 1; if external { externalForeground += 1 } }
                        }
                    }
                    guard union > 0, externalUnion > 0, foreground >= 12,
                          externalForeground >= 6, externalForeground * 5 >= foreground else { continue }
                    let score = Double(intersection) / Double(union)
                    let externalScore = Double(externalIntersection) / Double(externalUnion)
                    guard score >= 0.82, externalScore >= 0.80 else { continue }
                    matches.append(CGRect(x: x, y: y, width: size, height: size))
                    scores.append("IoU=\(score), outside-IoU=\(externalScore), outside-reference-pixels=\(externalForeground)/\(foreground), four-boundaries=true")
                }
            }
        }
        var evidence = Evidence(matches: matches, scores: scores)
        if let bounds = evidence.bounds, let reference = Raster(artwork, size: Int(bounds.width)) {
            evidence.opaqueRows = opaqueSilhouette(in: raster, bounds: bounds, cardBottom: card.maxY,
                                                   reference: reference) ?? []
        }
        return evidence
    }

    /// The lower rounded rim lies OUTSIDE the selected snapshot. Trace that
    /// independent contour, then reflect the OS icon's symmetric silhouette;
    /// never infer excluded corner pixels from what fails the privacy gate.
    /// The faint side rim need only reach the existing one-pixel fringe. Missing,
    /// non-monotone, artwork-contaminated, or in-card contour evidence fails closed.
    private static func opaqueSilhouette(in image: Raster, bounds: CGRect, cardBottom: CGFloat,
                                         reference: Raster) -> [CGRect]? {
        let x = Int(bounds.minX), y = Int(bounds.minY), size = Int(bounds.width)
        var left: [Int] = [], right: [Int] = []
        for depth in 0..<(size / 2) {
            let row = y + size - 1 - depth
            guard CGFloat(row) >= cardBottom else { return nil }
            // This part of the shipped icon must be empty black artwork: the
            // witness is the OS rim, not the dollar/underscore foreground.
            guard (0..<size).allSatisfy({ reference[$0, size - 1 - depth] < 110 }) else { return nil }
            func edge(fromRight: Bool) -> Int? {
                let outsideX = fromRight ? x + size + 1 : x - 2
                // A single 0/1 background fluctuation hid the mini's 4-level
                // rim. Measure its flat exterior field, without lowering the
                // rim requirement or borrowing any in-snapshot pixels.
                let samples = (-2...2).map { image[outsideX, row + $0] }
                guard let baseline = exteriorBaseline(samples, firstRow: row - 2,
                    cardBottom: cardBottom, imageHeight: image.height) else { return nil }
                let values = (0..<(size / 2)).map {
                    image[fromRight ? x + size - 1 - $0 : x + $0, row] - baseline
                }
                guard let peak = values.max(), peak >= 4, peak < 110,
                      let first = values.firstIndex(where: { $0 * 2 >= peak }) else { return nil }
                return first
            }
            guard let l = edge(fromRight: false), let r = edge(fromRight: true),
                  l <= (left.last ?? size), r <= (right.last ?? size) else { return nil }
            left.append(l); right.append(r)
            if l <= 1 && r <= 1 {
                // The rest is the opaque core between the independently matched
                // straight sides. The measured corner cutouts remain unexcluded.
                var runs: [CGRect] = []
                for row in 0..<size {
                    let distance = min(row, size - 1 - row)
                    let l = distance < left.count ? left[distance] : 0
                    let r = distance < right.count ? right[distance] : 0
                    let rect = CGRect(x: x + l, y: y + row, width: size - l - r, height: 1)
                    if let last = runs.last, last.minX == rect.minX, last.width == rect.width {
                        runs[runs.count - 1].size.height += 1
                    } else { runs.append(rect) }
                }
                return runs
            }
        }
        return nil
    }

    /// Exactly five consecutive exterior pixels, never a permissive fallback
    /// for a nonuniform field. The caller's column lies outside the matched icon.
    static func exteriorBaseline(_ samples: [Int], firstRow: Int, cardBottom: CGFloat,
                                 imageHeight: Int) -> Int? {
        guard samples.count == 5, firstRow >= 0, firstRow < imageHeight,
              samples.count <= imageHeight - firstRow, cardBottom.isFinite,
              CGFloat(firstRow) >= cardBottom,
              samples.allSatisfy({ (0...255).contains($0) }) else { return nil }
        let sorted = samples.sorted()
        guard sorted[4] - sorted[0] <= 1 else { return nil }
        return sorted[2]
    }

    static func matchesSceneIdentifier(_ identifier: String, sceneID: String) -> Bool {
        let fields = identifier.components(separatedBy: ":")
        return !sceneID.isEmpty && fields.count == 4 && fields[0] == "card" && !fields[1].isEmpty
            && fields[2] == "sceneID" && fields[3] == fields[1] + "-" + sceneID
    }

    static func displayBounds(_ pixels: CGRect, imageSize: CGSize, display: CGRect) -> CGRect {
        CGRect(x: display.minX + pixels.minX * display.width / imageSize.width,
               y: display.minY + pixels.minY * display.height / imageSize.height,
               width: pixels.width * display.width / imageSize.width,
               height: pixels.height * display.height / imageSize.height)
    }
}
