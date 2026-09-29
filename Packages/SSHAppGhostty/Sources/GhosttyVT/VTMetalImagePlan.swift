import Foundation

/// Bound both pixel storage and texture-object count. Unselected generations
/// still draw, using the streaming tile page after each previous GPU lease drains.
struct VTMetalImagePlan: Sendable {
    static let cachePixelLimit = 4 * 1024 * 1024
    static let cacheCountLimit = 64
    static let tileSide = 1024
    static let tilePixelBytes = tileSide * tileSide * 4
    /// Conservative 2D texture side supported by every iOS 18 GPU family.
    /// Larger images (e.g. 20000x50, small in bytes) use the tile path.
    static let maximumTextureSide = 8192
    let cachedGenerations: Set<UInt64>
    let cachedPixelBytes: Int
    let tileCount: Int
    var needsTile: Bool { tileCount > 0 }
    var pixelBytes: Int { cachedPixelBytes + tileCount * Self.tilePixelBytes }
    private let cachedBytesByGeneration: [UInt64: Int]

    /// Tile rectangles covering a clipped source rect, with a one-texel margin
    /// around fractional clipping. The shader assigns every sample to exactly
    /// one tile, so extra edge tiles cannot double-blend or expose stale pixels.
    /// Shared by planning and rendering so both agree on the tile count.
    static func tileRects(image: VTImageValue, source: CGRect) -> [(x: Int, y: Int, width: Int, height: Int)] {
        // Clamp in floating point first: Int(_:) traps on non-finite or
        // out-of-range values.
        guard image.width > 0, image.height > 0,
              [source.minX, source.minY, source.maxX, source.maxY].allSatisfy(\.isFinite) else { return [] }
        func texel(_ value: CGFloat, _ limit: Int) -> Int { Int(max(0, min(CGFloat(limit - 1), value))) }
        let x0 = texel(floor(source.minX) - 1, image.width) / tileSide * tileSide
        let y0 = texel(floor(source.minY) - 1, image.height) / tileSide * tileSide
        let x1 = texel(ceil(source.maxX), image.width)
        let y1 = texel(ceil(source.maxY), image.height)
        var rects: [(x: Int, y: Int, width: Int, height: Int)] = []
        for y in stride(from: y0, through: y1, by: tileSide) {
            for x in stride(from: x0, through: x1, by: tileSide) {
                rects.append((x, y, min(tileSide, image.width - x), min(tileSide, image.height - y)))
            }
        }
        return rects
    }

    /// The tile page side for a frame's tile count: fixed 1024-pixel slots in
    /// a doubling page, like the glyph pages. 0 means no tiles; nil means the
    /// frame exceeds the page (16 tiles) and renders on the CPU instead.
    static func tilePageSide(for tileCount: Int) -> Int? {
        switch tileCount {
        case ...0: return 0
        case 1: return 1024
        case 2...4: return 2048
        case 5...16: return 4096
        default: return nil
        }
    }

    /// Bytes this plan still has to allocate for cached generations when
    /// `retained` generations already hold textures. Retained textures are
    /// charged separately, so charging them again would double-count. Tile
    /// page growth is reserved separately by the renderer's preparationBytes.
    func newPixelBytes(retaining retained: Set<UInt64>) -> Int {
        cachedBytesByGeneration.reduce(0) { $0 + (retained.contains($1.key) ? 0 : $1.value) }
    }

    init(_ frame: VTFrameValue) {
        var cached: Set<UInt64> = []
        var bytesByGeneration: [UInt64: Int] = [:]
        var bytes = 0
        var tiles = 0
        for placement in frame.graphics.placements {
            guard let geometry = placement.geometry(in: frame.layout) else { continue }
            let image = placement.image
            if cached.contains(image.generation) { continue }
            if cached.count < Self.cacheCountLimit, image.rgba.count <= Self.cachePixelLimit - bytes,
               image.width <= Self.maximumTextureSide, image.height <= Self.maximumTextureSide {
                cached.insert(image.generation)
                bytesByGeneration[image.generation] = image.rgba.count
                bytes += image.rgba.count
            } else {
                tiles += Self.tileRects(image: image, source: geometry.source).count
            }
        }
        self.cachedGenerations = cached
        self.cachedPixelBytes = bytes
        self.tileCount = tiles
        self.cachedBytesByGeneration = bytesByGeneration
    }
}
