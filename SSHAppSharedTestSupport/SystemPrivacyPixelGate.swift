import CoreGraphics
import UIKit

// Shared by SSHAppUITests (physical switcher/window acceptance) and SSHAppTests
// (pure fixture replay). Keep this file free of XCUIApplication/device access.

/// Positive pixel witness for the *existing* PrivacyScreen symbol specification.
/// This draws only a reference mask in the test process; it never installs an app cover.
/// Pure raster code: nonisolated so unit tests can run it off the main thread.
enum SystemPrivacyPixelGate {
    static var productionSymbol: UIImage? {
        UIImage(systemName: "lock.fill")?.withConfiguration(UIImage.SymbolConfiguration(pointSize: 44, weight: .semibold))
    }
    private struct Raster {
        let width: Int
        let height: Int
        let gray: [UInt8]
        init?(_ image: CGImage) {
            width = image.width; height = image.height
            var pixels = [UInt8](repeating: 0, count: width * height)
            let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                return true
            }
            guard rendered else { return nil }; gray = pixels
        }
    }
    static func snapshotBounds(card: CGRect, window: CGRect) -> CGRect? {
        guard card.width > 0, window.width > 0, window.height > 0 else { return nil }
        let height = card.width * window.height / window.width
        guard height <= card.height + 1 else { return nil }
        return CGRect(x: card.minX, y: card.minY, width: card.width, height: min(height, card.height))
    }

    /// Map explicit OS icon AX bounds using the same integral screen crop as the
    /// screenshot. Scaling by the rounded crop width would shift fractional AX
    /// coordinates and could leave icon pixels behind or hide adjacent content.
    static func iconPixelBounds(_ frames: [CGRect], snapshot: CGRect, display: CGRect,
                                pixelSize: CGSize) -> [CGRect] {
        guard let crop = TerminalScreenshotCrop.pixelRect(region: snapshot, captureFrame: display,
            pixelSize: pixelSize) else { return [] }
        let scaleX = pixelSize.width / display.width, scaleY = pixelSize.height / display.height
        return frames.filter {
            $0.width > 0 && $0.height > 0
                && $0.width <= snapshot.width * 0.20 && $0.height <= snapshot.height * 0.20
                && abs($0.midX - snapshot.midX) <= 1
                && $0.minY < snapshot.maxY && $0.maxY > snapshot.maxY
        }.map {
            CGRect(x: ($0.minX - display.minX) * scaleX - crop.minX,
                   y: ($0.minY - display.minY) * scaleY - crop.minY,
                   width: $0.width * scaleX, height: $0.height * scaleY).insetBy(dx: -1, dy: -1)
        }
    }

    /// The geometry gate remains unchanged, but its bounding square is only an
    /// envelope. Exclude the independently measured opaque silhouette plus the
    /// same 1px fringe, not exposed snapshot pixels in its rounded corners.
    static func iconPixelExclusions(_ evidence: SystemPrivacyIconMatcher.Evidence, snapshot: CGRect,
                                    display: CGRect, pixelSize: CGSize) -> [CGRect] {
        guard let measured = evidence.bounds, !evidence.opaqueRows.isEmpty,
              let crop = TerminalScreenshotCrop.pixelRect(region: snapshot, captureFrame: display,
                  pixelSize: pixelSize) else { return [] }
        let frame = SystemPrivacyIconMatcher.displayBounds(measured, imageSize: pixelSize, display: display)
        let envelopes = iconPixelBounds([frame], snapshot: snapshot, display: display, pixelSize: pixelSize)
        guard envelopes.count == 1, let envelope = envelopes.first else { return [] }
        return evidence.opaqueRows.map {
            $0.offsetBy(dx: -crop.minX, dy: -crop.minY).insetBy(dx: -1, dy: -1).intersection(envelope)
        }.filter { !$0.isNull && !$0.isEmpty }
    }

    /// Phone icon/title live above the snapshot. No exclusion argument exists:
    /// this path cannot turn failed iPad artwork matching into permission to mask.
    static func isOpaquePhonePrivacyCover(in image: CGImage, expectedHeight: CGFloat) -> Bool {
        isOpaquePrivacyCover(in: image, expectedHeight: expectedHeight, excludedRects: [], phoneContour: true)
    }

    static func isOpaquePrivacyCover(in image: CGImage, expectedHeight: CGFloat,
                                     roundedCornerRadius: CGFloat = 0, excludedRects: [CGRect] = [],
                                     phoneContour: Bool = false) -> Bool {
        guard let raster = Raster(image),
              let lock = productionLockBounds(in: raster, expectedHeight: expectedHeight) else { return false }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let outline = UIBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerRadius: roundedCornerRadius)
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard pixels.withUnsafeMutableBytes({ buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: bounds); return true
        }) else { return false }
        let included = raster.gray.indices.filter {
            // Test pixel centers, not boundary vertices: the integral crop can
            // include a partial OS border pixel at a fractional snapshot edge.
            let point = CGPoint(x: CGFloat($0 % image.width) + 0.5, y: CGFloat($0 / image.width) + 0.5)
            let inside = phoneContour
                ? PhonePrivacySnapshotGeometry.includes(x: Int(point.x), y: Int(point.y),
                                                        width: image.width, height: image.height)
                : outline.contains(point)
            return inside && !excludedRects.contains(where: { $0.contains(point) })
        }
        let backgroundPixels = included.filter {
            !lock.insetBy(dx: -2, dy: -2).contains(CGPoint(x: CGFloat($0 % image.width) + 0.5,
                                                         y: CGFloat($0 / image.width) + 0.5))
        }
        guard !backgroundPixels.isEmpty else { return false }
        let sorted = backgroundPixels.map { raster.gray[$0] }.sorted()
        let background = Int(sorted[sorted.count / 2])
        // Per-pixel coverage, not a whole-card percentage: a small edge leak
        // must not disappear into the much larger neutral center.
        return included.allSatisfy {
            let r = Int(pixels[$0 * 4]), g = Int(pixels[$0 * 4 + 1]), b = Int(pixels[$0 * 4 + 2])
            return max(r, g, b) - min(r, g, b) < 20
        } && backgroundPixels.allSatisfy { abs(Int(raster.gray[$0]) - background) <= 18 }
    }

    static func containsProductionLock(in image: CGImage, expectedHeight: CGFloat) -> Bool {
        guard let raster = Raster(image) else { return false }
        return productionLockBounds(in: raster, expectedHeight: expectedHeight) != nil
    }
    static func lockEvidence(in image: CGImage, expectedHeight: CGFloat) -> String {
        guard let raster = Raster(image) else { return "lock raster unavailable" }
        var matches: [String] = []
        let bounds = productionLockBounds(in: raster, expectedHeight: expectedHeight) { matches.append($0) }
        return "expectedHeight=\(expectedHeight); acceptedBounds=\(String(describing: bounds)); \(matches.joined(separator: "; "))"
    }
    private static func productionLockBounds(in image: Raster, expectedHeight: CGFloat,
                                             record: (String) -> Void = { _ in }) -> CGRect? {
        guard expectedHeight >= 6, let symbol = productionSymbol else { return nil }
        let format = UIGraphicsImageRendererFormat(); format.scale = 2; format.opaque = true
        // SF Symbol sizes are fractional. An opaque renderer rounds its pixel
        // extent up; filling only symbol.size leaves a dark final row/column
        // which corrupts the reference silhouette bounds. Pad an integral canvas.
        let canvas = CGSize(width: ceil(symbol.size.width) + 4, height: ceil(symbol.size.height) + 4)
        let template = UIGraphicsImageRenderer(size: canvas, format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: canvas))
            symbol.withTintColor(.black, renderingMode: .alwaysOriginal).draw(in: CGRect(origin: CGPoint(x: 2, y: 2), size: symbol.size))
        }
        guard let cgTemplate = template.cgImage, let reference = Raster(cgTemplate) else { return nil }
        let referenceMask = reference.gray.map { $0 < 128 }
        let indices = referenceMask.indices.filter { referenceMask[$0] }
        guard let refMinX = indices.map({ $0 % reference.width }).min(),
              let refMaxX = indices.map({ $0 % reference.width }).max(),
              let refMinY = indices.map({ $0 / reference.width }).min(),
              let refMaxY = indices.map({ $0 / reference.width }).max() else { return nil }
        let refWidth = refMaxX - refMinX + 1, refHeight = refMaxY - refMinY + 1
        let sorted = image.gray.sorted(), background = Int(sorted[sorted.count / 2])
        let contrast = image.gray.map { abs(Int($0) - background) }.max() ?? 0
        guard contrast > 30 else { return nil }
        let mask = image.gray.map { abs(Int($0) - background) > max(18, contrast * 2 / 5) }
        var visited = [Bool](repeating: false, count: mask.count)
        for seed in mask.indices where mask[seed] && !visited[seed] {
            var queue = [seed], cursor = 0
            visited[seed] = true
            var minX = seed % image.width, maxX = minX, minY = seed / image.width, maxY = minY
            while cursor < queue.count {
                let point = queue[cursor]; cursor += 1
                let x = point % image.width, y = point / image.width
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
                    guard nx >= 0, nx < image.width, ny >= 0, ny < image.height else { continue }
                    let index = ny * image.width + nx
                    if mask[index] && !visited[index] { visited[index] = true; queue.append(index) }
                }
            }
            let width = maxX - minX + 1, height = maxY - minY + 1
            guard CGFloat(height) >= expectedHeight * 0.65, CGFloat(height) <= expectedHeight * 1.4,
                  abs(CGFloat(minX + maxX) / 2 - CGFloat(image.width) / 2) < CGFloat(image.width) * 0.20,
                  abs(CGFloat(minY + maxY) / 2 - CGFloat(image.height) / 2) < CGFloat(image.height) * 0.20,
                  abs(Double(width) / Double(height) - Double(refWidth) / Double(refHeight)) < 0.18 else { continue }
            var intersection = 0, union = 0
            for y in 0..<48 {
                for x in 0..<36 {
                    let candidate = mask[(minY + y * height / 48) * image.width + minX + x * width / 36]
                    let expected = referenceMask[(refMinY + y * refHeight / 48) * reference.width + refMinX + x * refWidth / 36]
                    if candidate && expected { intersection += 1 }
                    if candidate || expected { union += 1 }
                }
            }
            record("candidate=\(CGRect(x: minX, y: minY, width: width, height: height)); IoU=\(union > 0 ? Double(intersection) / Double(union) : 0); required=0.80")
            if union > 0 && Double(intersection) / Double(union) >= 0.80 {
                return CGRect(x: minX, y: minY, width: width, height: height)
            }
        }
        return nil
    }
}
