import CoreGraphics
@preconcurrency import IOSurface
import Metal
import QuartzCore

/// A directly renderable CoreAnimation surface. The Metal texture and IOSurface
/// are one allocation; keeping this object alive keeps both views valid.
final class VTMetalOutputTarget: @unchecked Sendable {
    enum Failure: Error { case unavailable }

    let texture: any MTLTexture
    let surface: IOSurface?
    let width: Int
    let height: Int
    let retainedBytes: Int

    var isIOSurfaceBacked: Bool { surface != nil }

    private init(texture: any MTLTexture, surface: IOSurface?, width: Int, height: Int) {
        self.texture = texture
        self.surface = surface
        self.width = width
        self.height = height
        retainedBytes = max(texture.allocatedSize, surface?.allocationSize ?? 0,
                            width * height * 4)
    }

    static func texture(device: any MTLDevice, pixelFormat: MTLPixelFormat,
                        width: Int, height: Int) throws -> VTMetalOutputTarget {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw Failure.unavailable }
        return VTMetalOutputTarget(texture: texture, surface: nil, width: width, height: height)
    }

    static func ioSurface(device: any MTLDevice, width: Int, height: Int) throws -> VTMetalOutputTarget {
        // 'BGRA' / kCVPixelFormatType_32BGRA without adding a CoreVideo dependency.
        let bgra = UInt32(0x4247_5241)
        let properties = [
            kIOSurfaceWidth: width,
            kIOSurfaceHeight: height,
            kIOSurfaceBytesPerElement: 4,
            kIOSurfacePixelFormat: bgra,
        ] as CFDictionary
        guard let surface = IOSurfaceCreate(properties) else { throw Failure.unavailable }
        if let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
           let propertyList = colorSpace.copyPropertyList() {
            IOSurfaceSetValue(surface, kIOSurfaceColorSpace, propertyList)
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0)
        else { throw Failure.unavailable }
        return VTMetalOutputTarget(texture: texture, surface: surface, width: width, height: height)
    }
}

/// Plain CALayer used for IOSurface publication. Returning NSNull disables all
/// implicit actions, including contents and geometry changes during resize.
final class VTIOSurfaceLayer: CALayer {
    override init() {
        super.init()
        contentsGravity = .topLeft
        isOpaque = true
        needsDisplayOnBoundsChange = false
    }

    override init(layer: Any) {
        super.init(layer: layer)
        contentsGravity = .topLeft
        isOpaque = true
        needsDisplayOnBoundsChange = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func action(forKey event: String) -> (any CAAction)? { NSNull() }
}

/// Main-actor ownership of a bounded IOSurface swap chain. At most one target is
/// displayed and at most two are leased by the existing raster scheduler, so a
/// three-target pool cannot grow without bound. Replacing layer.contents is the
/// publication boundary; it is not proof of scanout.
@MainActor
final class VTIOSurfacePresenter {
    enum Failure: Error { case unavailable, stale, sizeMismatch }

    final class Lease {
        fileprivate let id = UUID()
        fileprivate let generation: UInt64
        let target: VTMetalOutputTarget
        fileprivate var consumed = false

        fileprivate init(generation: UInt64, target: VTMetalOutputTarget) {
            self.generation = generation
            self.target = target
        }
    }

    struct Metrics: Codable, Equatable, Sendable {
        let targetCount: Int
        let availableTargets: Int
        let leasedTargets: Int
        let hasDisplayedTarget: Bool
        let retainedBytes: Int
        let peakRetainedBytes: Int
        let targetCreations: Int
        let publications: Int
        let discardedPublications: Int
        let acquisitionAttempts: Int
        let acquisitionSuccesses: Int
        let acquisitionStalls: Int
        let acquisitionTimeouts: Int
        let acquisitionCancellations: Int
        let acquisitionFailures: Int
        let poolWaitTotalSeconds: Double
        let poolWaitMaxSeconds: Double
    }

    let layer = VTIOSurfaceLayer()
    let device: any MTLDevice
    private let maximumTargets = 3
    private var generation: UInt64 = 0
    private var available: [VTMetalOutputTarget] = []
    private var leased: [UUID: VTMetalOutputTarget] = [:]
    private var displayed: VTMetalOutputTarget?
    private var targetCreations = 0
    /// Memory pressure discards targets returned by already in-flight work until
    /// those leases drain, preventing the pool from immediately regrowing to 3.
    private var trimToDisplayed = false
    private var publications = 0
    private var discardedPublications = 0
    private var peakRetainedBytes = 0
    // Cumulative for this presenter, including across trim/clear/retirement.
    private var acquisitionAttempts = 0
    private var acquisitionSuccesses = 0
    private var acquisitionStalls = 0
    private var acquisitionTimeouts = 0
    private var acquisitionCancellations = 0
    private var acquisitionFailures = 0
    private var poolWaitTotalSeconds = 0.0
    private var poolWaitMaxSeconds = 0.0

    init(device: any MTLDevice) { self.device = device }

    var metrics: Metrics {
        let targets = allTargets
        return .init(targetCount: targets.count, availableTargets: available.count,
                     leasedTargets: leased.count, hasDisplayedTarget: displayed != nil,
                     retainedBytes: targets.reduce(0) { $0 + $1.retainedBytes },
                     peakRetainedBytes: peakRetainedBytes,
                     targetCreations: targetCreations, publications: publications,
                     discardedPublications: discardedPublications,
                     acquisitionAttempts: acquisitionAttempts, acquisitionSuccesses: acquisitionSuccesses,
                     acquisitionStalls: acquisitionStalls, acquisitionTimeouts: acquisitionTimeouts,
                     acquisitionCancellations: acquisitionCancellations, acquisitionFailures: acquisitionFailures,
                     poolWaitTotalSeconds: poolWaitTotalSeconds, poolWaitMaxSeconds: poolWaitMaxSeconds)
    }

    func acquire(layout: VTLayout) async throws -> Lease {
        acquisitionAttempts += 1
        var stalled = false
        var timedOut = false
        var waitSeconds = 0.0
        // Publish completed-attempt wait, even when sleep throws on cancellation.
        // Only existing sleep/resumption intervals count: allocation, scans and
        // ordinary successful acquisition are not compositor/pool wait time.
        defer {
            poolWaitTotalSeconds += waitSeconds
            poolWaitMaxSeconds = max(poolWaitMaxSeconds, waitSeconds)
        }
        do {
            let width = Int((layout.viewportWidth * layout.scale).rounded())
            let height = Int((layout.viewportHeight * layout.scale).rounded())
            guard width > 0, height > 0 else { throw Failure.unavailable }
            let started = ProcessInfo.processInfo.systemUptime
            while true {
                try Task.checkCancellation()
                // Old-size available targets can never serve this layout. The displayed
                // target stays alive until a correctly sized replacement publishes.
                available.removeAll { $0.width != width || $0.height != height }
                let target: VTMetalOutputTarget?
                // Fill the ring before reusing its oldest target, matching Ghostty's
                // triple-buffer rotation rather than immediately alternating two surfaces.
                if !trimToDisplayed, allTargets.count < maximumTargets {
                    let created = try VTMetalOutputTarget.ioSurface(
                        device: device, width: width, height: height)
                    targetCreations += 1
                    target = created
                } else if let index = available.firstIndex(where: {
                    $0 !== displayed && $0.surface?.isInUse != true
                }) {
                    target = available.remove(at: index)
                } else { target = nil }
                if let target {
                    let lease = Lease(generation: generation, target: target)
                    leased[lease.id] = target
                    updatePeak()
                    acquisitionSuccesses += 1
                    return lease
                }
                // CoreAnimation exposes no release callback for layer.contents.
                // Respect IOSurface's use count and apply bounded backpressure rather
                // than rendering into a surface the compositor may still sample.
                guard ProcessInfo.processInfo.systemUptime - started < 2 else {
                    timedOut = true
                    acquisitionTimeouts += 1
                    throw Failure.unavailable
                }
                if !stalled {
                    stalled = true
                    acquisitionStalls += 1
                }
                let waitStarted = ProcessInfo.processInfo.systemUptime
                defer { waitSeconds += ProcessInfo.processInfo.systemUptime - waitStarted }
                try await Task.sleep(for: .milliseconds(1))
            }
        } catch let error as CancellationError {
            acquisitionCancellations += 1
            throw error
        } catch {
            if !timedOut { acquisitionFailures += 1 }
            throw error
        }
    }

    /// Publish a completed target after the caller has rechecked frame currency.
    /// Returns false for a lease invalidated by suspension/retirement or resize.
    func publish(_ lease: Lease, layout: VTLayout) throws {
        guard !lease.consumed, leased.removeValue(forKey: lease.id) != nil else { throw Failure.stale }
        lease.consumed = true
        guard lease.generation == generation else {
            discardedPublications += 1
            throw Failure.stale
        }
        let width = Int((layout.viewportWidth * layout.scale).rounded())
        let height = Int((layout.viewportHeight * layout.scale).rounded())
        guard lease.target.width == width, lease.target.height == height else {
            discardedPublications += 1
            throw Failure.sizeMismatch
        }
        guard let surface = lease.target.surface else { throw Failure.unavailable }
        let previous = displayed
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame.size = CGSize(width: layout.viewportWidth, height: layout.viewportHeight)
        layer.contentsScale = layout.scale
        layer.contentsGravity = .topLeft
        layer.contents = surface
        layer.isHidden = false
        CATransaction.commit()
        // Push the contents change to CoreAnimation before allowing the previous
        // surface back into the producer pool. This is publication, not scanout.
        CATransaction.flush()
        displayed = lease.target
        if let previous, previous !== lease.target,
           previous.width == width, previous.height == height,
           !trimToDisplayed {
            available.append(previous)
        }
        publications += 1
        finishPressureTrimIfDrained()
        updatePeak()
    }

    func discard(_ lease: Lease) {
        guard !lease.consumed else { return }
        lease.consumed = true
        guard leased.removeValue(forKey: lease.id) != nil else { return }
        if lease.generation == generation, lease.target !== displayed, !trimToDisplayed {
            available.append(lease.target)
        }
        discardedPublications += 1
        finishPressureTrimIfDrained()
    }

    /// A pressure trim never drops the target CoreAnimation currently displays
    /// and never touches in-flight GPU targets.
    func trimAvailableTargets() {
        trimToDisplayed = !leased.isEmpty
        available.removeAll()
    }

    /// Invalidate publication immediately. Leased targets remain alive through
    /// their command completion and are discarded when their owners drain.
    func clear() {
        generation &+= 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = nil
        layer.isHidden = true
        CATransaction.commit()
        CATransaction.flush()
        displayed = nil
        available.removeAll()
        trimToDisplayed = !leased.isEmpty
    }

    private var allTargets: [VTMetalOutputTarget] {
        var identities = Set<ObjectIdentifier>()
        var result: [VTMetalOutputTarget] = []
        for target in available + Array(leased.values) + [displayed].compactMap({ $0 }) {
            if identities.insert(ObjectIdentifier(target)).inserted { result.append(target) }
        }
        return result
    }

    private func finishPressureTrimIfDrained() {
        if leased.isEmpty { trimToDisplayed = false }
    }

    private func updatePeak() {
        peakRetainedBytes = max(peakRetainedBytes, allTargets.reduce(0) { $0 + $1.retainedBytes })
    }
}
