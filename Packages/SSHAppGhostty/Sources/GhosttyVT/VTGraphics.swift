import CoreGraphics
import Foundation
import os

/// Immutable decoded pixels shared by frames. Generations are process-unique
/// in the pinned VT API, including replacements, screen changes and resets.
final class VTImageValue: Equatable, Sendable {
    let generation: UInt64
    let width: Int
    let height: Int
    let rgba: Data

    init(generation: UInt64, width: Int, height: Int, rgba: Data) {
        self.generation = generation
        self.width = width
        self.height = height
        self.rgba = rgba
    }

    static func == (lhs: VTImageValue, rhs: VTImageValue) -> Bool { lhs.generation == rhs.generation }

    /// Built on first CoreText draw and shared by every later draw of this
    /// immutable image (blink ticks, hover and scroll redraws). The Metal path
    /// never asks, so it pays nothing.
    private let cachedCGImage = OSAllocatedUnfairLock<CGImage??>(uncheckedState: nil)

    var cgImage: CGImage? {
        cachedCGImage.withLockUnchecked { cached in
            if let cached { return cached }
            let image = makeCGImage()
            cached = .some(image)
            return image
        }
    }

    private func makeCGImage() -> CGImage? {
        guard let provider = CGDataProvider(data: rgba as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                        .union(.byteOrder32Big), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

enum VTImageLayer { case belowBackground, belowText, aboveText }

struct VTImagePlacementValue: Equatable, Sendable {
    let image: VTImageValue
    let imageID: UInt32
    let placementID: UInt32
    let z: Int32
    let column: Int
    let row: Int
    let offset: CGPoint
    let pixelSize: CGSize
    let source: CGRect
    var isUnicode = false

    var layer: VTImageLayer {
        z < Int32.min / 2 ? .belowBackground : (z < 0 ? .belowText : .aboveText)
    }

    /// Native geometry uses physical pixels and may have negative cell origins
    /// after scrolling or a relative placement. Clip source and destination as
    /// one transform so neither renderer stretches a partially visible image.
    func geometry(in layout: VTLayout) -> (destination: CGRect, source: CGRect)? {
        // Remote-derived values: renderers convert these to integer texels.
        guard [offset.x, offset.y, pixelSize.width, pixelSize.height,
               source.minX, source.minY, source.width, source.height].allSatisfy(\.isFinite),
              pixelSize.width > 0, pixelSize.height > 0, source.width > 0, source.height > 0 else { return nil }
        let destination = CGRect(x: layout.padding + Double(column) * layout.cellWidth + offset.x / layout.scale,
                                 y: layout.padding + Double(row) * layout.cellHeight + offset.y / layout.scale,
                                 width: pixelSize.width / layout.scale, height: pixelSize.height / layout.scale)
        let grid = CGRect(x: layout.padding, y: layout.padding,
                          width: Double(layout.columns) * layout.cellWidth, height: Double(layout.rows) * layout.cellHeight)
        let clipped = destination.intersection(grid)
        guard !clipped.isEmpty, !source.isEmpty else { return nil }
        let sx = source.width / destination.width, sy = source.height / destination.height
        return (clipped, CGRect(x: source.minX + (clipped.minX - destination.minX) * sx,
                                y: source.minY + (clipped.minY - destination.minY) * sy,
                                width: clipped.width * sx, height: clipped.height * sy))
    }
}

struct VTGraphicsValue: Equatable, Sendable {
    var placements: [VTImagePlacementValue] = []
    // Stored virtual templates; visible fragments appear in placements and
    // are marked isUnicode. A template need not have any cells in the viewport.
    var virtualPlacementCount = 0
    var storageLimitBytes: UInt64 = 0

    func draw(layer: VTImageLayer, layout: VTLayout, context: CGContext) {
        for placement in placements where placement.layer == layer {
            guard let geometry = placement.geometry(in: layout), let image = placement.image.cgImage else { continue }
            let destination = geometry.destination, source = geometry.source
            let sx = destination.width / source.width, sy = destination.height / source.height
            context.saveGState()
            context.clip(to: destination)
            context.interpolationQuality = .none
            context.translateBy(x: destination.minX - source.minX * sx,
                                y: destination.minY - source.minY * sy + CGFloat(image.height) * sy)
            context.scaleBy(x: sx, y: -sy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            context.restoreGState()
        }
    }
}
