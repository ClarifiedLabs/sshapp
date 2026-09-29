import CoreText
import Metal
import UIKit

/// Loads the build-time-compiled metallib (VTShaders.metal). Runtime MSL
/// compilation would otherwise run on the first renderer use.
enum VTShaderLibrary {
    enum Failure: Error { case unavailable }

    static func load(_ device: any MTLDevice) throws -> any MTLLibrary {
        guard let library = try? device.makeDefaultLibrary(bundle: .module) else { throw Failure.unavailable }
        return library
    }
}

/// Main-actor admission and presentation boundary. Each call leases one private
/// raster worker through GPU completion; only owned values cross that boundary.
@MainActor
final class VTMetalRasterizer {
    enum Failure: Error { case unavailable, busy, rendering }
    /// Opt-in host clocks, not CPU durations. One command encodes the frame.
    struct CommandTimeline: Codable, Sendable {
        let mainEntry: Double
        let commit: Double
        let gpuStart: Double
        let gpuEnd: Double
        let completedHandler: Double
    }
    struct Timeline: Codable, Sendable {
        let workerEntry: Double
        let preparationStart: Double
        let finalPrepared: Double
        let command: CommandTimeline
    }
    struct Timing: Sendable {
        // CPU interval sum excludes executor hops and GPU waits.
        let submitMilliseconds: Double
        let gpuMilliseconds: Double
        let renderPasses: Int
        let preparationSegments: Int
        let mainThreadPreparationSegments: Int
        let workerCPUMilliseconds: Double
        let mainSubmissionCPUMilliseconds: Double
        var timeline: Timeline? = nil
    }
    /// Monochrome glyphs are stored as 1-byte coverage and tinted per cell.
    /// 4096 x 4096 coverage exceeds the pixel area of any iPhone/iPad screen,
    /// so once grown, a frame's visible glyphs always fit and cannot thrash.
    nonisolated static let initialAtlasSide = 1024
    nonisolated static let maximumAtlasSide = 4096
    /// Color glyphs (emoji) keep RGBA pixels in a separate, lazily created page.
    nonisolated static let initialColorAtlasSide = 512
    nonisolated static let maximumColorAtlasSide = 2048
    /// Initial coverage page plus the initial color page.
    nonisolated static let freshGlyphTextureBytes = initialAtlasSide * initialAtlasSide
        + initialColorAtlasSide * initialColorAtlasSide * 4
    /// Bounds key storage; atlas space is the usual limit.
    nonisolated static let maximumAtlasEntries = 8192
    /// Worker scratch charged on every preparation, beyond retained textures.
    nonisolated static var plannedScratchBytes: Int { VTMetalRasterWorker.plannedScratchBytes }
    private let queue: any MTLCommandQueue
    /// IOSurface presentation supplies a target owned by its bounded swap chain;
    /// offscreen rendering keeps a private RGBA output texture.
    private let usesExternalOutput: Bool
    private var worker: VTMetalRasterWorker?
    private var state = VTMetalRasterSnapshot()
    private var busy = false
    var submittedPasses: Int { state.submittedPasses }
    var peakVertexBytes: Int { state.peakVertexBytes }
    var imageUploadCount: Int { state.imageUploadCount }
    var output: (any MTLTexture)? { state.output }
    var cachedGlyphs: Int { state.glyphs }
    var shapedGlyphs: Int { state.shapes }
    var glyphCacheIdentity: UUID? { state.glyphCacheIdentity }
    var shapingMisses: Int { state.shapingMisses }
    #if VT_TEST_HOOKS
    /// Forces the rare whole-frame CoreText fallback without manufacturing an
    /// enormous terminal grid. Production builds compile this seam out.
    var forceCPUFallbackForTesting = false
    /// Weak lifetime observation only; never exposes or retains mutable cache state.
    func glyphCacheLifetimeProbeForTesting() -> @MainActor () -> Bool {
        precondition(!busy)
        return { [weak glyphs = state.drainedGlyphState] in glyphs != nil }
    }
    #endif
    var retainedGlyphTextureBytes: Int { state.retainedGlyphTextureBytes }
    var atlasBytes: Int { state.atlasBytes }
    var allocatedAtlasBytes: Int { state.allocatedAtlasBytes }
    var hasAtlas: Bool { state.atlasBytes > 0 }
    var outputTextureBytes: Int { state.outputTextureBytes }
    var imageTextureBytes: Int { state.imageTextureBytes }
    var cachedImages: Int { state.images }
    var imagePixelBytes: Int { state.imagePixelBytes }
    var imageTileUploads: Int { state.imageTileUploads }
    var hasImageTile: Bool { state.hasImageTile }
    var retainedTextureBytes: Int { state.retainedTextureBytes }

    /// Plan from the drained slot before allocation. Existing atlas/output
    /// storage is reused when possible; a resize still charges both old and new
    /// output textures through replacement. A waiting slot keeps only evictable
    /// glyph state, so its reservation must also cover cold reconstruction.
    /// Charges remain textures plus planned scratch, not opaque CoreText overhead.
    func preparationBytes(for frame: VTFrameValue, retainingCache: Bool = true, font: UIFont? = nil) -> Int {
        let width = Int((frame.layout.viewportWidth * frame.layout.scale).rounded())
        let height = Int((frame.layout.viewportHeight * frame.layout.scale).rounded())
        let retained = retainingCache ? retainedTextureBytes : 0
        // Retained image textures and the tile page are inside `retained`.
        let imagePlan = VTMetalImagePlan(frame)
        let images = imagePlan.newPixelBytes(retaining: retainingCache ? state.cachedImageGenerations : [])
        // Tile page growth is reserved in full, like the glyph pages; the old
        // page stays charged in `retained` until the replacement exists.
        let currentTileSide = retainingCache ? state.tileTextureSide : 0
        let requiredTileSide = VTMetalImagePlan.tilePageSide(for: imagePlan.tileCount) ?? currentTileSide
        let tileReserve = requiredTileSide > currentTileSide ? requiredTileSide * requiredTileSide * 4 : 0
        // Each page's frame-start side (pending growth included) is reserved
        // in full: the frame encodes in a single pass, so the atlas must hold
        // the frame's whole working set before rasterization starts, and the
        // old page stays charged in `retained` until its replacement exists.
        // The color page is created lazily mid-frame, so its first allocation
        // is always reserved while absent.
        let glyphs = state.drainedGlyphState
        let newAtlas: Int
        if retainingCache {
            let sides = Self.plannedAtlasSides(for: frame, font: font, glyphs: glyphs)
            let coverageReserve = glyphs?.coverage.texture != nil && sides.coverage == glyphs?.coverage.side
                ? 0 : sides.coverage * sides.coverage
            let colorReserve = glyphs?.color.texture != nil && sides.color == glyphs?.color.side
                ? 0 : sides.color * sides.color * 4
            newAtlas = coverageReserve + colorReserve
        } else {
            // Nothing is charged in `retained`, yet the evictable glyph state
            // either survives admission (and grows at frame start) or is lost
            // and rebuilt cold: reserve whichever ends up larger.
            let warm = Self.plannedAtlasSides(for: frame, font: font, glyphs: glyphs)
            let cold = Self.plannedAtlasSides(for: frame, font: font, glyphs: nil)
            newAtlas = max(retainedGlyphTextureBytes,
                           warm.coverage * warm.coverage + warm.color * warm.color * 4,
                           cold.coverage * cold.coverage + cold.color * cold.color * 4)
        }
        let reuseOutput = retainingCache && output?.width == width && output?.height == height
        let newOutput = usesExternalOutput || reuseOutput ? 0 : width * height * 4
        // Geometry beyond the fixed scratch: the instance array and a buffer
        // that grows up to the frame's instance bound, plus the grid-sized
        // background array and buffer. A waiting slot drops both buffers.
        let instanceBytes = max(VTMetalRasterWorker.instanceBound(for: frame) * VTMetalRasterWorker.instanceStride,
                                4096)
        let backgroundBytes = max(frame.layout.columns * frame.layout.rows * 4, 4096)
        let instanceBuffer = retainingCache && state.instanceBufferBytes >= instanceBytes ? 0 : instanceBytes
        let backgroundBuffer = retainingCache && state.bgBufferBytes >= backgroundBytes ? 0 : backgroundBytes
        let geometry = max(0, instanceBytes + instanceBuffer - VTMetalRasterWorker.plannedInstanceBytes)
            + max(0, backgroundBytes + backgroundBuffer - VTMetalRasterWorker.plannedBackgroundBytes)
        return retained + newAtlas + newOutput + images + tileReserve + geometry
            + VTMetalRasterWorker.plannedScratchBytes
    }

    /// Page sides after the worker's frame-start growth for `glyphs`, or for
    /// a cold cache when nil. Mirrors applyPendingGrowth.
    fileprivate nonisolated static func plannedAtlasSides(for frame: VTFrameValue, font: UIFont?,
                                                          glyphs: VTMetalGlyphState?) -> (coverage: Int, color: Int) {
        let estimate = atlasEstimate(for: frame, font: font, glyphs: glyphs)
        return (plannedSide(currentSide: glyphs?.coverage.side ?? initialAtlasSide,
                            growing: glyphs?.coverage.growNextFrame == true, usedPixels: estimate.usedCoverage,
                            neededPixels: estimate.coverage, maximumSide: maximumAtlasSide),
                plannedSide(currentSide: glyphs?.color.side ?? initialColorAtlasSide,
                            growing: glyphs?.color.growNextFrame == true, usedPixels: estimate.usedColor,
                            neededPixels: estimate.color, maximumSide: maximumColorAtlasSide))
    }

    /// The estimate's required side, or the pending 2x growth if larger.
    nonisolated static func plannedSide(currentSide: Int, growing: Bool, usedPixels: Int, neededPixels: Int,
                                        maximumSide: Int) -> Int {
        let required = requiredAtlasSide(currentSide: currentSide, usedPixels: usedPixels,
                                         neededPixels: neededPixels, maximumSide: maximumSide)
        return max(required, growing ? min(currentSide * 2, maximumSide) : currentSide)
    }

    /// Pixel-area estimate of the glyphs a frame will rasterize into each atlas
    /// page (used plus missing), so the reservation and the worker's frame-start
    /// growth agree on a side that fits the whole frame in one pass. Runs
    /// against the drained glyph handoff on the main actor or the live state on
    /// the worker. Shaping-independent color detection may over-reserve the
    /// color page, which is safe; geometry/font invalidation empties the cache.
    struct AtlasEstimate: Equatable {
        var coverage = 0, color = 0, usedCoverage = 0, usedColor = 0
    }
    fileprivate nonisolated static func atlasEstimate(for frame: VTFrameValue, font: UIFont?,
                                                      glyphs: VTMetalGlyphState?) -> AtlasEstimate {
        let layout = frame.layout
        // Mirror the worker's invalidation: a cleared cache makes every glyph
        // missing and its used area zero.
        let valid = glyphs != nil
            && (font == nil || glyphs?.font == font)
            && glyphs?.layout?.cellWidth == layout.cellWidth
            && glyphs?.layout?.cellHeight == layout.cellHeight
            && glyphs?.layout?.scale == layout.scale
            && glyphs?.fontSmoothing == frame.paint.fontSmoothing
        var estimate = AtlasEstimate()
        if let glyphs, valid {
            estimate.usedCoverage = glyphs.coverage.usedArea
            estimate.usedColor = glyphs.color.usedArea
        }
        var seen = Set<VTMetalGlyphState.Key>()
        for (index, cell) in frame.cells.enumerated() {
            guard cell.width > 0, !cell.imagePlaceholder, !cell.invisible, !cell.text.isEmpty else { continue }
            let key = VTMetalGlyphState.Key(text: cell.text,
                style: (cell.bold ? 1 : 0) | (cell.italic ? 2 : 0), width: cell.width)
            if valid, let glyphs, glyphs.coverage.entries[key] != nil || glyphs.color.entries[key] != nil { continue }
            guard seen.insert(key).inserted else { continue }
            let rect = layout.rect(column: index % layout.columns, row: index / layout.columns, width: cell.width)
            let width = Int((rect.width * layout.scale).rounded())
            let height = Int((rect.height * layout.scale).rounded())
            // Transient oversized tiles are not reserved: they are rewound after
            // each frame, and a frame they overflow falls back to the CPU while
            // the page grows (or clears) for the next.
            let tileSide = VTMetalRasterWorker.rasterTileSide - 4
            guard cell.text.utf8.count <= 256, width <= tileSide, height <= tileSide else { continue }
            let pixels = (width + 2) * (height + 2)
            if isEmojiish(cell.text) { estimate.color += pixels } else { estimate.coverage += pixels }
        }
        return estimate
    }

    /// The side whose shelf area holds the used plus estimated pixels, doubling
    /// from the current side with 25% packing headroom.
    nonisolated static func requiredAtlasSide(currentSide: Int, usedPixels: Int, neededPixels: Int,
                                              maximumSide: Int) -> Int {
        let total = usedPixels + neededPixels
        var side = currentSide
        while side < maximumSide, side * side * 4 < total * 5 { side *= 2 }
        return side
    }

    /// Fallback-font runs decide color glyphs; reservation only needs a cheap
    /// superset of emoji-capable text.
    private nonisolated static func isEmojiish(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            (0x1F000...0x1FAFF).contains($0.value) || (0x2600...0x27BF).contains($0.value)
                || (0x2B00...0x2BFF).contains($0.value) || $0.value == 0x20E3 || $0.value == 0xFE0F
        }
    }

    convenience init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw Failure.unavailable }
        try self.init(queue: queue)
    }

    init(queue: any MTLCommandQueue, usesExternalOutput: Bool = false) throws {
        self.queue = queue
        self.usesExternalOutput = usesExternalOutput
    }

    /// Pipeline creation is static and nonisolated so warmup can pay the
    /// one-time driver cost before any renderer exists.
    nonisolated static func makePipeline(device: any MTLDevice,
                                         pixelFormat: MTLPixelFormat = .rgba8Unorm) throws -> any MTLRenderPipelineState {
        let library = try VTShaderLibrary.load(device)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "vt_cell_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "vt_cell_fragment")
        let color = descriptor.colorAttachments[0]!
        color.pixelFormat = pixelFormat
        color.isBlendingEnabled = true
        color.sourceRGBBlendFactor = .one
        color.sourceAlphaBlendFactor = .one
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// The cell-background pass shares the cell pipeline's premultiplied
    /// blending: alpha-0 entries preserve what is underneath.
    nonisolated static func makeBgPipeline(device: any MTLDevice,
                                           pixelFormat: MTLPixelFormat = .rgba8Unorm) throws -> any MTLRenderPipelineState {
        let library = try VTShaderLibrary.load(device)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "vt_bg_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "vt_bg_fragment")
        let color = descriptor.colorAttachments[0]!
        color.pixelFormat = pixelFormat
        color.isBlendingEnabled = true
        color.sourceRGBBlendFactor = .one
        color.sourceAlphaBlendFactor = .one
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// Synchronous selective release, only after preparation/GPU/presentation
    /// drain. The facade stores the handoff but never accesses its mutable data.
    func discardTransientResources() {
        precondition(!busy, "Raster resources remain leased until GPU completion")
        precondition(worker == nil || state.drainedGlyphState != nil,
                     "Selective release requires a drained glyph handoff")
        worker = nil
        state = VTMetalRasterSnapshot(glyphs: state.glyphs, shapes: state.shapes,
            atlasBytes: state.atlasBytes, allocatedAtlasBytes: state.allocatedAtlasBytes,
            imageUploadCount: state.imageUploadCount, submittedPasses: state.submittedPasses,
            peakVertexBytes: state.peakVertexBytes, retainedTextureBytes: state.retainedGlyphTextureBytes,
            imageTileUploads: state.imageTileUploads, pipeline: state.pipeline, bgPipeline: state.bgPipeline,
            retainedGlyphTextureBytes: state.retainedGlyphTextureBytes,
            glyphCacheIdentity: state.glyphCacheIdentity, shapingMisses: state.shapingMisses,
            drainedGlyphState: state.drainedGlyphState)
    }

    /// No worker task or GPU lease may remain when the owner drops the worker.
    /// A fresh actor reconstructs raster resources lazily; immutable shader state
    /// and cumulative upload diagnostics survive. No synchronous worker wait.
    func releaseResources() {
        precondition(!busy, "Raster resources remain leased until GPU completion")
        worker = nil
        state = VTMetalRasterSnapshot(imageUploadCount: state.imageUploadCount,
                                      imageTileUploads: state.imageTileUploads,
                                      pipeline: state.pipeline, bgPipeline: state.bgPipeline)
    }

    func render(_ frame: VTFrameValue, font: UIFont, presentation: VTPresentationState = .init(),
                recordTimeline: Bool = false, outputTarget: VTMetalOutputTarget? = nil,
                validate: (@MainActor () throws -> Void)? = nil,
                finalPass: (@MainActor (any MTLCommandBuffer, any MTLTexture) throws -> Void)? = nil) async throws -> Timing {
        guard !busy else { throw Failure.busy }
        busy = true
        defer { busy = false }
        state.submittedPasses = 0
        state.peakVertexBytes = 0
        try Task.checkCancellation()
        try validate?()
        let worker = worker ?? VTMetalRasterWorker(queue: queue, previous: state,
                                                   usesExternalOutput: usesExternalOutput)
        self.worker = worker
        // Only the worker may access the bundle until render returns. Do not
        // keep a resource-bearing handoff in the facade across that await.
        state.drainedGlyphState = nil
        do {
            let forceFallback: Bool
            #if VT_TEST_HOOKS
            forceFallback = forceCPUFallbackForTesting
            #else
            forceFallback = false
            #endif
            let timing = try await worker.render(frame, font: font, presentation: presentation,
                recordTimeline: recordTimeline, outputTarget: outputTarget,
                forceFallback: forceFallback, validate: { snapshot in
                self.state = snapshot
                try Task.checkCancellation()
                try validate?()
            }, commit: { submission, snapshot, final in
                let mainEntry = recordTimeline && final ? CACurrentMediaTime() : nil
                self.state = snapshot
                let started = ProcessInfo.processInfo.systemUptime
                try Task.checkCancellation()
                try validate?()
                if final { try finalPass?(submission.command, submission.output) }
                self.state.submittedPasses += 1
                let cpuMilliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000
                // Generation check, presentation commit
                // and commit are one main-actor operation: no hop can reorder
                // an older command behind a newer presentation.
                let result: (Bool, Double, CommandTimeline?) = await withCheckedContinuation { continuation in
                    let commit = mainEntry.map { _ in CACurrentMediaTime() }
                    submission.command.addCompletedHandler { completed in
                        let timeline = mainEntry.map {
                            CommandTimeline(mainEntry: $0, commit: commit!,
                                gpuStart: completed.gpuStartTime, gpuEnd: completed.gpuEndTime,
                                completedHandler: CACurrentMediaTime())
                        }
                        continuation.resume(returning: (completed.status == .completed,
                            max(0, completed.gpuEndTime - completed.gpuStartTime) * 1000, timeline))
                    }
                    submission.command.commit()
                }
                guard result.0 else { throw Failure.rendering }
                return VTMetalRasterCompletion(cpuMilliseconds: cpuMilliseconds, gpuMilliseconds: result.1,
                                               timeline: result.2)
            })
            state = await worker.drainedSnapshot()
            return timing
        } catch {
            // Failed/stale work may have populated caches without presenting.
            // Publish their actual ownership before the pipeline trims the slot.
            let committedPasses = state.submittedPasses
            state = await worker.drainedSnapshot()
            state.submittedPasses = max(state.submittedPasses, committedPasses)
            throw error
        }
    }
}

/// The worker alone prepares the command, then suspends for this main-actor
/// handoff through GPU completion. The main actor only appends presentation and
/// commits; neither side concurrently encodes or modifies these Metal objects.
/// Metal's ObjC command/texture protocols lack Sendable annotations in the SDK.
private struct VTMetalRasterSubmission: @unchecked Sendable {
    let command: any MTLCommandBuffer
    let output: any MTLTexture
}

/// Live snapshots contain only gauges and shader/output handles. Only the final
/// drained snapshot owns a glyph handoff; validation/submission never carry it.
/// CPU output readback is valid after render and before the next lease.
private struct VTMetalRasterSnapshot: @unchecked Sendable {
    var glyphs = 0, shapes = 0, images = 0
    var atlasBytes = 0, allocatedAtlasBytes = 0, imageTextureBytes = 0, outputTextureBytes = 0
    var imageUploadCount = 0, submittedPasses = 0, peakVertexBytes = 0
    var retainedTextureBytes = 0
    var imagePixelBytes = 0
    var imageTileUploads = 0
    var hasImageTile = false
    /// Current tile page side (0 when absent); preparation reserves growth.
    var tileTextureSide = 0
    var outputTarget: VTMetalOutputTarget?
    var output: (any MTLTexture)? { outputTarget?.texture }
    var pipeline: (any MTLRenderPipelineState)?
    var bgPipeline: (any MTLRenderPipelineState)?
    var retainedGlyphTextureBytes = 0
    var glyphCacheIdentity: UUID?
    var shapingMisses = 0
    var drainedGlyphState: VTMetalGlyphState?
    var cachedImageGenerations: Set<UInt64> = []
    /// Geometry buffer capacities; preparation reserves their growth.
    var instanceBufferBytes = 0
    var bgBufferBytes = 0
}

/// Narrow drained ownership transfer, not generally concurrent mutable state.
/// Only the current raster worker touches these fields; the main actor merely
/// stores, transfers or releases the reference after the previous worker drains.
/// Texture charge excludes opaque CoreText overhead; shaping/key counts stay bounded.
private final class VTMetalGlyphState: @unchecked Sendable {
    /// Foreground color is not part of the key: coverage is tinted per cell,
    /// and color glyphs ignore the foreground.
    struct Key: Hashable {
        let text: String
        let style: UInt8
        let width: Int
    }
    /// One shelf-packed texture. A frame's working set must fit before
    /// encoding: preparation reserves (and the worker grows to) the side the
    /// estimate demands; residual overflow falls back to the CPU for that
    /// frame and flags growth for the next, or clears a page that cannot grow.
    final class Page: @unchecked Sendable {
        /// Shelf-packing position, saved and restored around transient tiles.
        struct Cursor { var x = 2, y = 2, shelfHeight = 0, usedArea = 0 }
        let pixelFormat: MTLPixelFormat
        let bytesPerPixel: Int
        let maximumSide: Int
        var texture: (any MTLTexture)?
        var entries: [Key: CGRect] = [:]
        var x = 2, y = 2, shelfHeight = 0
        /// Shelf-packed pixel area in use; feeds the growth reservation.
        var usedArea = 0
        var side: Int
        var growNextFrame = false
        var bytes: Int { texture == nil ? 0 : side * side * bytesPerPixel }
        var cursor: Cursor {
            get { Cursor(x: x, y: y, shelfHeight: shelfHeight, usedArea: usedArea) }
            set { (x, y, shelfHeight, usedArea) = (newValue.x, newValue.y, newValue.shelfHeight, newValue.usedArea) }
        }

        init(pixelFormat: MTLPixelFormat, bytesPerPixel: Int, side: Int, maximumSide: Int) {
            self.pixelFormat = pixelFormat
            self.bytesPerPixel = bytesPerPixel
            self.side = side
            self.maximumSide = maximumSide
        }

        func clear() {
            entries.removeAll(keepingCapacity: true)
            cursor = Cursor()
        }

        func allocate(width: Int, height: Int) -> CGRect? {
            // A region wider or taller than an empty page never fits, even on
            // a fresh shelf; wrapping would place it out of bounds.
            guard entries.count < VTMetalRasterizer.maximumAtlasEntries,
                  width + 4 <= side, height + 4 <= side else { return nil }
            if x + width + 2 > side {
                x = 2
                y += shelfHeight + 2
                shelfHeight = 0
            }
            guard y + height + 2 <= side else { return nil }
            let region = CGRect(x: x, y: y, width: width, height: height)
            x += width + 2
            shelfHeight = max(shelfHeight, height)
            usedArea += (width + 2) * (height + 2)
            return region
        }
    }
    let identity = UUID()
    let coverage = Page(pixelFormat: .r8Unorm, bytesPerPixel: 1,
                        side: VTMetalRasterizer.initialAtlasSide, maximumSide: VTMetalRasterizer.maximumAtlasSide)
    let color = Page(pixelFormat: .rgba8Unorm, bytesPerPixel: 4,
                     side: VTMetalRasterizer.initialColorAtlasSide, maximumSide: VTMetalRasterizer.maximumColorAtlasSide)
    var entryCount: Int { coverage.entries.count + color.entries.count }
    var layout: VTLayout?
    var font: UIFont?
    var fontSmoothing: Bool?
    let shapes = VTGlyphCache()
}

private struct VTMetalRasterCompletion: Sendable {
    let cpuMilliseconds: Double
    let gpuMilliseconds: Double
    let timeline: VTMetalRasterizer.CommandTimeline?
}

private actor VTMetalRasterWorker {
    typealias Failure = VTMetalRasterizer.Failure
    typealias Timing = VTMetalRasterizer.Timing
    /// One drawn quad: glyph, fill, decoration, cursor or image. Positions stay
    /// in points and UVs normalized; the vertex shader maps to NDC, replacing
    /// six expanded vertices per quad with one 48-byte instance.
    private struct Instance {
        var dst: SIMD4<Float>   // x, y, width, height in points
        var uv: SIMD4<Float>    // normalized origin + size in the bound texture
        var color: UInt32       // packed rgb: r | g << 8 | b << 16
        var flags: UInt32       // bit 0: faint (alpha 0.5); bit 1: color glyph pixels
    }
    private struct ImageSample: Equatable, Sendable {
        var imageSize = SIMD2<UInt32>(repeating: 0)
        var origin = SIMD2<UInt32>(repeating: 0)
        var size = SIMD2<UInt32>(repeating: 0)
        var pageOrigin = SIMD2<UInt32>(repeating: 0)
    }
    private struct Batch { let texture: any MTLTexture; let sample: ImageSample; let start: Int; var count: Int }
    private struct CellUniforms { var viewport: SIMD2<Float> }
    private struct BgUniforms { var padding: SIMD2<Float>; var cell: SIMD2<Float>; var grid: SIMD2<UInt32> }
    /// A glyph or transient tile region does not fit the page's free space.
    private struct PageOverflow: Error { let page: VTMetalGlyphState.Page }
    /// A frame's streamed image tiles exceed the tile page's slot count.
    private struct PlanOverflow: Error {}
    // Instance array/buffer storage, the cell-background array/buffer and one
    // maximum CoreText raster tile. Larger geometry is reserved per frame.
    // Driver, allocator and CoreText overhead are separate from this charge.
    static let instanceStride = MemoryLayout<Instance>.stride
    static let plannedInstanceBytes = 65_536 * instanceStride * 2
    static let plannedBackgroundBytes = 2 * 1024 * 1024
    static let plannedScratchBytes = plannedInstanceBytes + plannedBackgroundBytes + 1020 * 1020 * 4
    /// Raster tile bound (with the scratch budget); independent of atlas size.
    static let rasterTileSide = 1024
    private typealias Key = VTMetalGlyphState.Key
    private let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let usesExternalOutput: Bool
    private let outputPixelFormat: MTLPixelFormat
    private var pipeline: (any MTLRenderPipelineState)?
    private var bgPipeline: (any MTLRenderPipelineState)?
    private let glyphState: VTMetalGlyphState
    /// Largest texture side this device renders to (Metal feature sets).
    private let maximumTextureSide: Int
    private var busy = false
    // Diagnostic only: records where synchronous preparation runs.
    private nonisolated static var preparingOnMainThread: Bool { Thread.isMainThread }
    private(set) var submittedPasses = 0
    private(set) var peakVertexBytes = 0
    private var imageTextures: [UInt64: any MTLTexture] = [:]
    /// One page holds every streamed image tile of a frame in fixed 1024-pixel
    /// slots, so streaming needs no mid-frame GPU wait. Doubled on demand and
    /// reused only after the previous GPU lease drained (the slot lease orders
    /// reuse); a frame needing more slots renders on the CPU instead.
    /// (Buffer-backed textures would suit this but are macOS-only.)
    private var tileTexture: (any MTLTexture)?
    private var tilePageSide = 0
    private var stagedTiles = 0
    private(set) var imageUploadCount = 0
    private var imageTileUploads = 0
    private(set) var outputTarget: VTMetalOutputTarget?
    var output: (any MTLTexture)? { outputTarget?.texture }
    /// Persistent geometry storage, grown 2x and reused under the slot lease.
    private var instanceBuffer: (any MTLBuffer)?
    private var instanceBufferBytes = 0
    private var bgBuffer: (any MTLBuffer)?
    private var bgBufferBytes = 0
    var cachedGlyphs: Int { glyphState.entryCount }
    var shapedGlyphs: Int { glyphState.shapes.count }
    var atlasBytes: Int { glyphState.coverage.bytes + glyphState.color.bytes }
    var allocatedAtlasBytes: Int {
        (glyphState.coverage.texture?.allocatedSize ?? 0) + (glyphState.color.texture?.allocatedSize ?? 0)
    }
    var hasAtlas: Bool { glyphState.coverage.texture != nil }
    var outputTextureBytes: Int { output?.allocatedSize ?? 0 }
    var imageTextureBytes: Int {
        imageTextures.values.reduce(0) { $0 + $1.allocatedSize } + (tileTexture?.allocatedSize ?? 0)
    }
    var imagePixelBytes: Int {
        imageTextures.values.reduce(0) { $0 + $1.width * $1.height * 4 }
            + stagedTiles * VTMetalImagePlan.tilePixelBytes
    }
    var cachedImages: Int { imageTextures.count }
    var hasImageTile: Bool { tileTexture != nil }
    init(queue: any MTLCommandQueue, previous: VTMetalRasterSnapshot, usesExternalOutput: Bool) {
        let device = queue.device
        self.device = device
        self.queue = queue
        self.usesExternalOutput = usesExternalOutput
        outputPixelFormat = usesExternalOutput ? .bgra8Unorm : .rgba8Unorm
        // MSL and Swift agree on Instance layout only with float4 alignment.
        precondition(MemoryLayout<Instance>.stride == 48)
        // Mirrors ghostty's queryMaxTextureSize: apple10+ 32768, apple3+ 16384.
        maximumTextureSide = device.supportsFamily(.apple10) ? 32768
            : device.supportsFamily(.apple3) ? 16384 : 8192
        glyphState = previous.drainedGlyphState ?? VTMetalGlyphState()
        outputTarget = previous.outputTarget
        pipeline = previous.pipeline
        bgPipeline = previous.bgPipeline
        imageUploadCount = previous.imageUploadCount
        imageTileUploads = previous.imageTileUploads
    }

    func snapshot() -> VTMetalRasterSnapshot {
        VTMetalRasterSnapshot(glyphs: cachedGlyphs, shapes: shapedGlyphs,
            images: cachedImages, atlasBytes: atlasBytes, allocatedAtlasBytes: allocatedAtlasBytes,
            imageTextureBytes: imageTextureBytes, outputTextureBytes: outputTextureBytes,
            imageUploadCount: imageUploadCount, submittedPasses: submittedPasses,
            peakVertexBytes: peakVertexBytes,
            retainedTextureBytes: glyphTextureBytes + Self.textureCost(output)
                + imageTextures.values.reduce(0) { $0 + Self.textureCost($1) } + Self.textureCost(tileTexture)
                + instanceBufferBytes + bgBufferBytes,
            imagePixelBytes: imagePixelBytes, imageTileUploads: imageTileUploads,
            hasImageTile: tileTexture != nil, tileTextureSide: tileTexture == nil ? 0 : tilePageSide,
            outputTarget: outputTarget, pipeline: pipeline, bgPipeline: bgPipeline,
            retainedGlyphTextureBytes: glyphTextureBytes,
            glyphCacheIdentity: glyphState.identity, shapingMisses: glyphState.shapes.misses,
            cachedImageGenerations: Set(imageTextures.keys),
            instanceBufferBytes: instanceBufferBytes, bgBufferBytes: bgBufferBytes)
    }

    /// Upper bound on the quads a frame emits, so preparation can reserve the
    /// instance buffer the plan grows to. Blink only removes quads and link
    /// hover only swaps underline styles within the per-cell bound.
    static func instanceBound(for frame: VTFrameValue) -> Int {
        let layout = frame.layout
        let tileSide = rasterTileSide - 4
        let height = Int((layout.cellHeight * layout.scale).rounded())
        var total = 0, widest = 0
        for cell in frame.cells where cell.width > 0 && !cell.imagePlaceholder && !cell.invisible {
            let width = Int((Double(cell.width) * layout.cellWidth * layout.scale).rounded())
            // One glyph quad, or one per transient tile.
            var count = cell.text.isEmpty ? 0
                : max(1, (width + tileSide - 1) / tileSide) * max(1, (height + tileSide - 1) / tileSide)
            switch cell.underlineStyle {
            // Pattern runs change at most once per viewport pixel.
            case .curly, .dotted, .dashed: count += width + 2
            default: count += 2
            }
            count += 2 // strikethrough and overline
            total += count
            widest = max(widest, count)
        }
        // Cursor rects plus the re-emitted cursor cell.
        if frame.cursorVisible { total += 4 + widest }
        for placement in frame.graphics.placements {
            guard let geometry = placement.geometry(in: layout) else { continue }
            total += max(1, VTMetalImagePlan.tileRects(image: placement.image, source: geometry.source).count)
        }
        return total
    }

    func drainedSnapshot() -> VTMetalRasterSnapshot {
        precondition(!busy, "Glyph handoff requires render to have returned")
        var result = snapshot()
        result.drainedGlyphState = glyphState
        return result
    }

    private var glyphTextureBytes: Int {
        Self.textureCost(glyphState.coverage.texture) + Self.textureCost(glyphState.color.texture)
    }

    private static func textureCost(_ texture: (any MTLTexture)?) -> Int {
        guard let texture else { return 0 }
        // Raster textures are single-level RGBA8, except 1-byte glyph coverage.
        // Simulator allocatedSize may be zero; never make a live texture free
        // in the retention policy.
        let bytesPerPixel = texture.pixelFormat == .r8Unorm ? 1 : 4
        return max(texture.allocatedSize, texture.width * texture.height * bytesPerPixel)
    }

    private func ensurePipelines() throws -> (cell: any MTLRenderPipelineState, background: any MTLRenderPipelineState) {
        if pipeline == nil {
            pipeline = try VTMetalRasterizer.makePipeline(device: device, pixelFormat: outputPixelFormat)
        }
        if bgPipeline == nil {
            bgPipeline = try VTMetalRasterizer.makeBgPipeline(device: device, pixelFormat: outputPixelFormat)
        }
        guard let pipeline, let bgPipeline else { throw Failure.unavailable }
        return (pipeline, bgPipeline)
    }

    /// Creates (or regrows) a page's texture. Coverage is swizzled so its one
    /// channel reads as premultiplied white: the shader's `sample * color`
    /// then tints it, and texel (0, 0) is the opaque white used for fills.
    /// Growth applies only at frame start, where preparation reserved the side
    /// the frame's working set needs: the single command buffer cannot stream
    /// a mid-frame clear the way the old multipass path could.
    private func applyPendingGrowth(_ page: VTMetalGlyphState.Page, neededPixels: Int) {
        let side = VTMetalRasterizer.plannedSide(currentSide: page.side, growing: page.growNextFrame,
            usedPixels: page.usedArea, neededPixels: neededPixels, maximumSide: page.maximumSide)
        page.growNextFrame = false
        guard side != page.side else { return }
        page.side = side
        page.texture = nil
        page.clear()
    }

    private func ensurePage(_ page: VTMetalGlyphState.Page) throws -> any MTLTexture {
        if let texture = page.texture { return texture }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: page.pixelFormat,
            width: page.side, height: page.side, mipmapped: false)
        // CPU-written, never CPU-read: skip cache pollution (ghostty bufferOptions).
        descriptor.cpuCacheMode = .writeCombined
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        if page.pixelFormat == .r8Unorm {
            descriptor.swizzle = MTLTextureSwizzleChannels(red: .red, green: .red, blue: .red, alpha: .red)
        }
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw Failure.unavailable }
        page.texture = texture
        if page.pixelFormat == .r8Unorm {
            var white: UInt8 = 0xff
            texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &white, bytesPerRow: 1)
        }
        return texture
    }

    /// One command buffer per frame. Glyph rasterization and uploads finish
    /// before encoding, so no GPU await can split the frame and the atlas is
    /// never mutated while a command references it. A frame whose working set
    /// cannot fit the atlas renders on the CPU into the output texture instead
    /// (exact CoreText-reference pixels). validate runs before preparation and
    /// before submission; an obsolete frame drains without presenting.
    func render(_ frame: VTFrameValue, font: UIFont, presentation: VTPresentationState = .init(),
                recordTimeline: Bool, outputTarget externalOutput: VTMetalOutputTarget?,
                forceFallback: Bool,
                validate: @MainActor @Sendable (VTMetalRasterSnapshot) throws -> Void,
                commit: @MainActor @Sendable (VTMetalRasterSubmission, VTMetalRasterSnapshot, Bool) async throws -> VTMetalRasterCompletion) async throws -> Timing {
        guard !busy else { throw Failure.busy }
        busy = true
        defer { busy = false }
        let workerEntry = recordTimeline ? CACurrentMediaTime() : nil
        submittedPasses = 0
        peakVertexBytes = 0
        stagedTiles = 0
        try Task.checkCancellation()
        try await validate(snapshot())
        try Task.checkCancellation()
        let preparationStart = workerEntry.map { _ in CACurrentMediaTime() }
        let cpuStarted = ProcessInfo.processInfo.systemUptime
        let (pipeline, bgPipeline) = try ensurePipelines()
        let geometry = frame.layout
        if glyphState.font != font || glyphState.layout?.cellWidth != geometry.cellWidth || glyphState.layout?.cellHeight != geometry.cellHeight || glyphState.layout?.scale != geometry.scale || glyphState.fontSmoothing != frame.paint.fontSmoothing {
            clearAtlas()
            glyphState.font = font
            glyphState.fontSmoothing = frame.paint.fontSmoothing
        }
        glyphState.layout = geometry
        glyphState.shapes.prepare(font: font, scale: geometry.scale)
        // Growth precedes rasterization so the reservation estimate and the
        // frame agree on a page side that fits the whole working set.
        let missing = VTMetalRasterizer.atlasEstimate(for: frame, font: font, glyphs: glyphState)
        applyPendingGrowth(glyphState.coverage, neededPixels: missing.coverage)
        applyPendingGrowth(glyphState.color, neededPixels: missing.color)
        let atlas = try ensurePage(glyphState.coverage)
        // Keep a bounded subset of current visible images. Remaining generations
        // stream through staged tiles without dropping placements or changing order.
        let visibleImages = frame.graphics.placements.filter { $0.geometry(in: geometry) != nil }
        let imagePlan = VTMetalImagePlan(frame)
        imageTextures = imageTextures.filter { imagePlan.cachedGenerations.contains($0.key) }
        // Size the tile page before any staging; growth is reserved in full.
        if imagePlan.tileCount == 0 {
            tileTexture = nil
            tilePageSide = 0
        } else if let required = VTMetalImagePlan.tilePageSide(for: imagePlan.tileCount), tilePageSide != required {
            tileTexture = nil
            tilePageSide = required
        }
        for placement in visibleImages where imagePlan.cachedGenerations.contains(placement.image.generation)
            && imageTextures[placement.image.generation] == nil {
            try Task.checkCancellation()
            let image = placement.image
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                width: image.width, height: image.height, mipmapped: false)
            descriptor.cpuCacheMode = .writeCombined
            descriptor.storageMode = .shared
            descriptor.usage = .shaderRead
            guard let texture = device.makeTexture(descriptor: descriptor) else { throw Failure.unavailable }
            image.rgba.withUnsafeBytes {
                texture.replace(region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0,
                                withBytes: $0.baseAddress!, bytesPerRow: image.width * 4)
            }
            imageTextures[image.generation] = texture
            imageUploadCount += 1
        }
        let pointWidth = geometry.viewportWidth
        let pointHeight = geometry.viewportHeight
        let width = Int((pointWidth * geometry.scale).rounded())
        let height = Int((pointHeight * geometry.scale).rounded())
        // Fail cleanly (the host falls back to CoreText) instead of relying on
        // driver rejection of an over-limit texture.
        guard width <= maximumTextureSide, height <= maximumTextureSide else { throw Failure.unavailable }
        let frameOutput: VTMetalOutputTarget
        if usesExternalOutput {
            guard let externalOutput, externalOutput.width == width, externalOutput.height == height,
                  externalOutput.texture.pixelFormat == outputPixelFormat else { throw Failure.unavailable }
            frameOutput = externalOutput
            // The IOSurface presenter owns and budgets this target. Do not
            // retain or charge it in the raster slot after command completion.
            outputTarget = nil
        } else {
            if outputTarget?.width != width || outputTarget?.height != height {
                outputTarget = try .texture(device: device, pixelFormat: outputPixelFormat,
                                            width: width, height: height)
            }
            guard let outputTarget else { throw Failure.unavailable }
            frameOutput = outputTarget
        }
        let output = frameOutput.texture
        let plan = forceFallback ? nil : try buildPlan(
            frame: frame, font: font, presentation: presentation,
            atlas: atlas, visibleImages: visibleImages)
        guard let command = queue.makeCommandBuffer() else { throw Failure.unavailable }
        if let plan {
            peakVertexBytes = plan.instances.count * Self.instanceStride
            // A cold blank/cursor-hidden frame has no quads. Its background
            // pass must not require an instance buffer that has never existed.
            let instances: (any MTLBuffer)?
            if plan.instances.isEmpty {
                instances = nil
            } else {
                instances = try upload(&instanceBuffer, capacity: &instanceBufferBytes, of: plan.instances,
                                       limit: Self.instanceBound(for: frame) * Self.instanceStride)
            }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = output
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(frame.background.red) / 255,
                green: Double(frame.background.green) / 255, blue: Double(frame.background.blue) / 255, alpha: 1)
            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw Failure.unavailable }
            var cellUniforms = CellUniforms(viewport: SIMD2(Float(pointWidth), Float(pointHeight)))
            encoder.setRenderPipelineState(pipeline)
            if !plan.instances.isEmpty {
                encoder.setVertexBuffer(instances, offset: 0, index: 0)
                encoder.setVertexBytes(&cellUniforms, length: MemoryLayout<CellUniforms>.stride, index: 1)
            }
            func draw(_ batches: [Batch]) {
                for batch in batches {
                    encoder.setVertexBuffer(instances, offset: batch.start * Self.instanceStride, index: 0)
                    encoder.setFragmentTexture(batch.texture, index: 0)
                    var sample = batch.sample
                    encoder.setFragmentBytes(&sample, length: MemoryLayout<ImageSample>.stride, index: 0)
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: batch.count)
                }
            }
            draw(plan.pre)
            if let backgrounds = plan.backgrounds {
                let bgBuffer = try upload(&self.bgBuffer, capacity: &bgBufferBytes, of: backgrounds,
                                          limit: backgrounds.count)
                var bgUniforms = BgUniforms(
                    padding: SIMD2(Float(geometry.padding * geometry.scale),
                                   Float(geometry.padding * geometry.scale)),
                    cell: SIMD2(Float(geometry.cellWidth * geometry.scale),
                                Float(geometry.cellHeight * geometry.scale)),
                    grid: SIMD2(UInt32(geometry.columns), UInt32(geometry.rows)))
                encoder.setRenderPipelineState(bgPipeline)
                encoder.setFragmentBytes(&bgUniforms, length: MemoryLayout<BgUniforms>.stride, index: 0)
                encoder.setFragmentBuffer(bgBuffer, offset: 0, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                encoder.setRenderPipelineState(pipeline)
            }
            draw(plan.main)
            draw(plan.post)
            encoder.endEncoding()
        } else {
            // The atlas cannot hold this frame's working set (the reservation
            // estimate missed, or the set exceeds the maximum page). Render the
            // exact CoreText-reference pixels into the output texture instead.
            try renderFallback(frame, font: font, presentation: presentation, output: output)
        }
        let cpuMilliseconds = (ProcessInfo.processInfo.systemUptime - cpuStarted) * 1000
        // Only this worker encodes the command. It suspends while the main
        // actor validates, appends presentation and commits, then waits for
        // GPU completion. No command or atlas mutation overlaps that lease.
        let ownership = snapshot()
        let finalPrepared = recordTimeline ? CACurrentMediaTime() : nil
        let result = try await commit(VTMetalRasterSubmission(command: command, output: output), ownership, true)
        var timeline: VTMetalRasterizer.Timeline?
        if let finalPrepared, let commandTimeline = result.timeline, let workerEntry, let preparationStart {
            timeline = .init(workerEntry: workerEntry, preparationStart: preparationStart,
                             finalPrepared: finalPrepared, command: commandTimeline)
        }
        submittedPasses = 1
        return Timing(submitMilliseconds: cpuMilliseconds + result.cpuMilliseconds,
                      gpuMilliseconds: result.gpuMilliseconds, renderPasses: 1,
                      preparationSegments: 1,
                      mainThreadPreparationSegments: Self.preparingOnMainThread ? 1 : 0,
                      workerCPUMilliseconds: cpuMilliseconds,
                      mainSubmissionCPUMilliseconds: result.cpuMilliseconds, timeline: timeline)
    }

    /// Paint-order geometry for the whole frame. Atlas mutation happens only
    /// here, before encoding: an overflow cannot be streamed, so it flags
    /// growth for the next frame and returns nil for a CPU fallback.
    private struct Plan {
        var instances: [Instance] = []
        var pre: [Batch] = []    // belowBackground images
        var main: [Batch] = []   // belowText images, cells, decorations, cursor
        var post: [Batch] = []   // aboveText images
        var backgrounds: [UInt8]?
    }
    /// A transient oversized-cell raster in a page, drawn but never cached.
    private struct TransientTile {
        let page: VTMetalGlyphState.Page
        let region: CGRect
        let tileX: Int
        let tileY: Int
        let isColor: Bool
    }

    private func buildPlan(frame: VTFrameValue, font: UIFont, presentation: VTPresentationState,
                           atlas: any MTLTexture, visibleImages: [VTImagePlacementValue]) throws -> Plan? {
        do {
            return try planOnce(frame: frame, font: font, presentation: presentation,
                                atlas: atlas, visibleImages: visibleImages)
        } catch let overflow as PageOverflow {
            // The reservation estimate missed (shelf packing waste, an oversized
            // region or transient tiles); this frame falls back. A page below
            // its maximum side grows for the next frame, which clears it. At
            // the maximum side or the entry cap growth cannot help, so clear
            // now and let the next frame repopulate its own working set. This
            // is still a frame-start clear: the previous lease has drained and
            // the fallback command never samples the atlas.
            let page = overflow.page
            if page.side < page.maximumSide, page.entries.count < VTMetalRasterizer.maximumAtlasEntries {
                page.growNextFrame = true
            } else {
                page.clear()
            }
            return nil
        } catch is PlanOverflow {
            // More streamed tiles than the page holds: this frame falls back.
            return nil
        }
    }

    private func planOnce(frame: VTFrameValue, font: UIFont, presentation: VTPresentationState,
                          atlas: any MTLTexture, visibleImages: [VTImagePlacementValue]) throws -> Plan {
        let geometry = frame.layout
        var instances: [Instance] = []
        var pre: [Batch] = []
        var main: [Batch] = []
        var post: [Batch] = []
        var backgrounds: [UInt8]?
        instances.reserveCapacity(frame.cells.count * 2)

        // Phase 1: rasterize every missing visible glyph before any encoding.
        // paintedCell/decorate never change text, style or width, so the raw
        // cell already keys the region every later variant reuses.
        let tileSide = Self.rasterTileSide - 4
        var transient: [Int: [TransientTile]] = [:]
        var transientCells: [(index: Int, cell: VTCellValue, width: Int, height: Int)] = []
        func place(_ cell: VTCellValue, at index: Int, width: Int, height: Int, key glyphKey: Key?) throws {
            let isColor = drawsInColor(cell, font: font)
            let page = isColor ? glyphState.color : glyphState.coverage
            // Creates the color page on first use (reserved while absent);
            // growth applies only at frame start.
            _ = try ensurePage(page)
            for tileY in stride(from: 0, to: height, by: tileSide) {
                for tileX in stride(from: 0, to: width, by: tileSide) {
                    try Task.checkCancellation()
                    let tileWidth = min(tileSide, width - tileX)
                    let tileHeight = min(tileSide, height - tileY)
                    guard let region = page.allocate(width: tileWidth, height: tileHeight) else {
                        throw PageOverflow(page: page)
                    }
                    // Borrowed shaping state stays within this synchronous actor
                    // operation; nothing GPU-bound has been encoded yet.
                    try rasterize(cell, font: font, frame: frame, into: page, region: region,
                                  tileX: tileX, tileY: tileY)
                    if let glyphKey { page.entries[glyphKey] = region }
                    else { transient[index, default: []].append(TransientTile(page: page, region: region, tileX: tileX, tileY: tileY, isColor: isColor)) }
                }
            }
        }
        for (index, cell) in frame.cells.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            guard presentation.draws(cell), !cell.text.isEmpty else { continue }
            let rect = geometry.rect(column: index % geometry.columns, row: index / geometry.columns, width: cell.width)
            let width = Int((rect.width * geometry.scale).rounded())
            let height = Int((rect.height * geometry.scale).rounded())
            guard cell.text.utf8.count <= 256, width <= tileSide, height <= tileSide else {
                transientCells.append((index, cell, width, height))
                continue
            }
            let glyphKey = key(cell)
            if glyphState.coverage.entries[glyphKey] != nil || glyphState.color.entries[glyphKey] != nil { continue }
            try place(cell, at: index, width: width, height: height, key: glyphKey)
        }
        // Transient tiles pack after every cached glyph and are rewound once
        // planning ends, so they never consume the page across frames. Their
        // texels are only overwritten by a later frame's allocation, which
        // starts after this frame's GPU lease drains.
        let coverageMark = glyphState.coverage.cursor, colorMark = glyphState.color.cursor
        defer {
            glyphState.coverage.cursor = coverageMark
            glyphState.color.cursor = colorMark
        }
        for item in transientCells {
            try place(item.cell, at: item.index, width: item.width, height: item.height, key: nil)
        }

        // Phase 2: emit instances and batches in paint order.
        func uvRect(_ rect: CGRect, width denomWidth: Double, height denomHeight: Double) -> SIMD4<Float> {
            SIMD4(Float(rect.minX / denomWidth), Float(rect.minY / denomHeight),
                  Float(rect.width / denomWidth), Float(rect.height / denomHeight))
        }
        // instances and batches are disjoint struct properties, so passing both
        // as inout at once does not trip dynamic exclusivity.
        func append(_ rect: CGRect, uv: SIMD4<Float>, color: VTColor, faint: Bool,
                    colorGlyph: Bool, texture: any MTLTexture, sample: ImageSample,
                    instances: inout [Instance], into batches: inout [Batch]) {
            var flags: UInt32 = faint ? 1 : 0
            if colorGlyph { flags |= 2 }
            instances.append(Instance(
                dst: SIMD4(Float(rect.minX), Float(rect.minY), Float(rect.width), Float(rect.height)),
                uv: uv,
                color: UInt32(color.red) | (UInt32(color.green) << 8) | (UInt32(color.blue) << 16),
                flags: flags))
            let start = instances.count - 1
            if let last = batches.last, last.texture === texture, last.sample == sample {
                batches[batches.count - 1].count += 1
            } else { batches.append(Batch(texture: texture, sample: sample, start: start, count: 1)) }
        }
        // Fills sample the coverage page's opaque white texel at (0, 0).
        let whiteUV = SIMD4(Float(0.5 / Double(atlas.width)), Float(0.5 / Double(atlas.height)), 0, 0)
        let white = VTColor(red: 255, green: 255, blue: 255)

        func images(_ layer: VTImageLayer, into batches: inout [Batch]) throws {
            for placement in visibleImages where placement.layer == layer {
                guard let position = placement.geometry(in: geometry) else { continue }
                let image = placement.image
                if let texture = imageTextures[image.generation] {
                    append(position.destination,
                           uv: uvRect(position.source, width: Double(image.width), height: Double(image.height)),
                           color: white, faint: false, colorGlyph: false, texture: texture, sample: ImageSample(),
                           instances: &instances, into: &batches)
                    continue
                }
                for tile in VTMetalImagePlan.tileRects(image: image, source: position.source) {
                    try Task.checkCancellation()
                    let staged = try stageTile(image, x: tile.x, y: tile.y, width: tile.width, height: tile.height)
                    // Keep the original quad and UV interpolation for every
                    // tile. Cutting the quad itself introduces seam rounding.
                    let sample = ImageSample(imageSize: SIMD2(UInt32(image.width), UInt32(image.height)),
                        origin: SIMD2(UInt32(tile.x), UInt32(tile.y)),
                        size: SIMD2(UInt32(tile.width), UInt32(tile.height)), pageOrigin: staged.origin)
                    append(position.destination,
                           uv: uvRect(position.source, width: Double(image.width), height: Double(image.height)),
                           color: white, faint: false, colorGlyph: false, texture: staged.texture, sample: sample,
                           instances: &instances, into: &batches)
                }
            }
        }

        try images(.belowBackground, into: &pre)

        // Cell backgrounds: one packed RGBA byte per painted cell, drawn by the
        // fullscreen pass. Alpha 0 preserves the clear color and any
        // belowBackground image, matching the old skipped-quad behavior.
        for (index, cell) in frame.cells.enumerated() where cell.selected || cell.background != frame.background {
            if backgrounds == nil {
                backgrounds = [UInt8](repeating: 0, count: geometry.columns * geometry.rows * 4)
            }
            guard index < geometry.columns * geometry.rows else { continue }
            let painted = frame.paintedBackground(cell)
            let offset = index * 4
            backgrounds![offset] = painted.red
            backgrounds![offset + 1] = painted.green
            backgrounds![offset + 2] = painted.blue
            backgrounds![offset + 3] = 255
        }

        try images(.belowText, into: &main)

        let decorations = VTDecorationGeometry(font: font, layout: geometry)
        func emitCell(_ raw: VTCellValue, at index: Int) throws {
            let cell = presentation.decorate(raw, at: index, in: frame)
            guard presentation.draws(cell) else { return }
            let rect = geometry.rect(column: index % geometry.columns, row: index / geometry.columns, width: cell.width)
            if !cell.text.isEmpty {
                let width = Int((rect.width * geometry.scale).rounded())
                let height = Int((rect.height * geometry.scale).rounded())
                let cacheable = cell.text.utf8.count <= 256 && width <= tileSide && height <= tileSide
                let glyphKey = cacheable ? key(cell) : nil
                if let glyphKey, let region = glyphState.coverage.entries[glyphKey] {
                    append(rect, uv: uvRect(region, width: Double(atlas.width), height: Double(atlas.height)),
                           color: cell.foreground, faint: cell.faint, colorGlyph: false,
                           texture: atlas, sample: ImageSample(), instances: &instances, into: &main)
                } else if let glyphKey, let colorTexture = glyphState.color.texture,
                          let region = glyphState.color.entries[glyphKey] {
                    append(rect, uv: uvRect(region, width: Double(colorTexture.width), height: Double(colorTexture.height)),
                           color: cell.foreground, faint: cell.faint, colorGlyph: true,
                           texture: colorTexture, sample: ImageSample(), instances: &instances, into: &main)
                } else if let tiles = transient[index] {
                    for tile in tiles {
                        guard let texture = tile.page.texture else { throw Failure.unavailable }
                        let destination = CGRect(x: rect.minX + Double(tile.tileX) / geometry.scale,
                            y: rect.minY + Double(tile.tileY) / geometry.scale,
                            width: Double(tile.region.width) / geometry.scale,
                            height: Double(tile.region.height) / geometry.scale)
                        append(destination,
                               uv: uvRect(tile.region, width: Double(texture.width), height: Double(texture.height)),
                               color: cell.foreground, faint: cell.faint, colorGlyph: tile.isColor,
                               texture: texture, sample: ImageSample(), instances: &instances, into: &main)
                    }
                } else { throw Failure.rendering }
            }
            for decoration in decorations.quads(for: cell, in: rect) {
                append(decoration.rect, uv: whiteUV, color: decoration.color, faint: cell.faint,
                       colorGlyph: false, texture: atlas, sample: ImageSample(), instances: &instances, into: &main)
            }
        }
        for (index, cell) in frame.cells.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            try emitCell(frame.paintedCell(cell), at: index)
        }
        let cursor = VTCursorGeometry(frame: frame, presentation: presentation)
        for rect in cursor.rects {
            append(rect, uv: whiteUV, color: frame.cursorColor, faint: false,
                   colorGlyph: false, texture: atlas, sample: ImageSample(), instances: &instances, into: &main)
        }
        if let index = cursor.textIndex { try emitCell(frame.cursorCell(at: index), at: index) }
        try images(.aboveText, into: &post)
        return Plan(instances: instances, pre: pre, main: main, post: post, backgrounds: backgrounds)
    }

    /// Renders the frame on the CPU into the output texture: the exact
    /// CoreText-reference result, for frames whose working set cannot fit the
    /// atlas in a single pass.
    private func renderFallback(_ frame: VTFrameValue, font: UIFont,
                                presentation: VTPresentationState, output: any MTLTexture) throws {
        let width = output.width, height = output.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: frame.layout.scale, y: -frame.layout.scale)
            VTCoreTextRenderer.draw(frame, font: font, context: context,
                bounds: CGRect(x: 0, y: 0, width: frame.layout.viewportWidth, height: frame.layout.viewportHeight),
                cache: glyphState.shapes, presentation: presentation)
            return true
        }
        guard drawn else { throw Failure.rendering }
        if output.pixelFormat == .bgra8Unorm {
            // CGContext above produces RGBA bytes; the IOSurface view is BGRA.
            for index in 0..<(width * height) { bytes.swapAt(index * 4, index * 4 + 2) }
        }
        output.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                       withBytes: bytes, bytesPerRow: width * 4)
    }

    /// Grows 2x, but never past `limit` (the bytes preparation reserved), and
    /// overwrites one persistent buffer. Reuse is safe because a slot's next
    /// frame starts only after the previous GPU lease drained.
    private func upload<T>(_ buffer: inout (any MTLBuffer)?, capacity: inout Int, of array: [T],
                           limit: Int) throws -> any MTLBuffer {
        let bytes = array.count * MemoryLayout<T>.stride
        if capacity < bytes {
            buffer = nil
            capacity = max(bytes, min(max(capacity * 2, 4096), max(limit, 4096)))
            guard let created = device.makeBuffer(length: capacity,
                options: [.storageModeShared, .cpuCacheModeWriteCombined]) else {
                capacity = 0
                throw Failure.unavailable
            }
            buffer = created
        }
        guard let buffer else { throw Failure.unavailable }
        if bytes > 0 {
            array.withUnsafeBytes { bytes in
                _ = memcpy(buffer.contents(), bytes.baseAddress!, bytes.count)
            }
        }
        return buffer
    }

    private func clearAtlas() {
        glyphState.coverage.clear()
        glyphState.color.clear()
    }

    /// Uploads one image tile into the next fixed slot of the tile page. The
    /// single command buffer consumes all tiles after encoding, so one texture
    /// holds them all; slot exhaustion falls the frame back to the CPU.
    private func stageTile(_ image: VTImageValue, x: Int, y: Int, width: Int, height: Int) throws -> (texture: any MTLTexture, origin: SIMD2<UInt32>) {
        let slotSide = VTMetalImagePlan.tileSide
        let perRow = tilePageSide / slotSide
        guard tilePageSide > 0, stagedTiles < perRow * perRow else { throw PlanOverflow() }
        if tileTexture == nil {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                width: tilePageSide, height: tilePageSide, mipmapped: false)
            descriptor.cpuCacheMode = .writeCombined
            descriptor.storageMode = .shared
            descriptor.usage = .shaderRead
            guard let texture = device.makeTexture(descriptor: descriptor) else { throw Failure.unavailable }
            tileTexture = texture
        }
        guard let tileTexture else { throw Failure.unavailable }
        let origin = SIMD2(UInt32(stagedTiles % perRow * slotSide), UInt32(stagedTiles / perRow * slotSide))
        stagedTiles += 1
        image.rgba.withUnsafeBytes {
            tileTexture.replace(region: MTLRegionMake2D(Int(origin.x), Int(origin.y), width, height),
                mipmapLevel: 0, withBytes: $0.baseAddress!.advanced(by: (y * image.width + x) * 4),
                bytesPerRow: image.width * 4)
        }
        imageUploadCount += 1
        imageTileUploads += 1
        return (tileTexture, origin)
    }

    /// Color and faint are applied by the instance tint, not baked into pixels.
    private func key(_ cell: VTCellValue) -> Key {
        Key(text: cell.text, style: (cell.bold ? 1 : 0) | (cell.italic ? 2 : 0), width: cell.width)
    }

    /// The cell shaped in opaque white: its rasterized alpha is the coverage
    /// mask, and the shaping cache no longer keys on foreground color.
    private func maskCell(_ cell: VTCellValue) -> VTCellValue {
        var mask = cell
        mask.foreground = VTColor(red: 255, green: 255, blue: 255)
        mask.faint = false
        return mask
    }

    /// Whether any run falls back to a font with color glyphs (emoji).
    private func drawsInColor(_ cell: VTCellValue, font: UIFont) -> Bool {
        let (line, _, _) = glyphState.shapes.line(for: maskCell(cell), font: font)
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return false }
        return runs.contains { run in
            guard let attributes = CTRunGetAttributes(run) as? [NSAttributedString.Key: Any],
                  let value = attributes[.font] else { return false }
            return CTFontGetSymbolicTraits(value as! CTFont).contains(.traitColorGlyphs)
        }
    }

    private func rasterize(_ cell: VTCellValue, font: UIFont, frame: VTFrameValue, into page: VTMetalGlyphState.Page,
                           region: CGRect, tileX: Int, tileY: Int) throws {
        guard let texture = page.texture else { throw Failure.unavailable }
        let (line, drawFont, _) = glyphState.shapes.line(for: maskCell(cell), font: font)
        let width = Int(region.width), height = Int(region.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            // Keep the shared CoreText baseline while moving only the tile.
            context.translateBy(x: CGFloat(-tileX), y: CGFloat(tileY + height) - drawFont.ascender * frame.layout.scale)
            context.scaleBy(x: frame.layout.scale, y: frame.layout.scale)
            frame.paint.apply(to: context)
            context.textMatrix = .identity
            context.textPosition = .zero
            CTLineDraw(line, context)
            return true
        }
        guard drawn else { throw Failure.rendering }
        let origin = MTLRegionMake2D(Int(region.minX), Int(region.minY), width, height)
        if page.bytesPerPixel == 1 {
            // White premultiplied text: alpha is the antialiased coverage.
            var coverage = [UInt8](repeating: 0, count: width * height)
            for index in 0..<(width * height) { coverage[index] = bytes[index * 4 + 3] }
            texture.replace(region: origin, mipmapLevel: 0, withBytes: coverage, bytesPerRow: width)
        } else {
            texture.replace(region: origin, mipmapLevel: 0, withBytes: bytes, bytesPerRow: width * 4)
        }
    }

}
