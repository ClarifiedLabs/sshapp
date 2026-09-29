#if DEBUG && canImport(UIKit)
import GhosttyVT
import QuartzCore
import UIKit

/// Observations contain scalars only; none owns a terminal frame, image or view.
public struct TerminalLifecyclePresentationSample: Codable, Sendable {
    public let hostID: String
    public let contentID: String
    public let sessionID: String?
    public let active: Bool
    public let epoch: UInt64
    public let hasFrame: Bool
    public let extractions: Int
    public let renderCompletions: Int
    /// Current content's accepted GPU-render revision, not scanout evidence.
    public let renderedRevision: UInt64?
    /// Independent presentation diagnostics; never substituted for GPU readiness.
    public let rendererDiagnostics: VTMetalRenderer.Diagnostics?
    public let metal: Bool
    public let rendererActive: Bool
    public let pending: Int
    public let inFlight: Int
    public let frame: TerminalLifecycleFrameSample?
}

public struct TerminalLifecycleFrameSample: Codable, Sendable {
    public let terminalID: UUID
    public let revision: UInt64
    public let layout: VTLayout
    public let offset: UInt64
    public let totalRows: UInt64
    public let awayFromBottom: Bool
    public let topMarker: String
    public let bottomMarker: String
    public let markers: [String]
}

public struct TerminalLifecycleMomentumSample: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case started, tick, stopped }
    public enum StopCause: String, Codable, Sendable { case deceleration, visibility, cancelled }
    public let kind: Kind
    public let generation: UInt64
    public let ticks: Int
    public let time: Double
    public let velocityX: Double
    public let velocityY: Double
    public let deltaX: Double
    public let deltaY: Double
    public let stopCause: StopCause?
    public let releaseBoundary: VTPointerReleaseBoundary?
}

extension UITerminalView {
    #if !targetEnvironment(macCatalyst)
    public var lifecycleAcceptancePan: UIPanGestureRecognizer? { touchScrollPanGesture }
    #endif

    /// Recording stores only scalar identity/revision after an accepted render;
    /// enabling it does not request extraction, rendering or presentation.
    public var recordsLifecycleAcceptanceRenders: Bool {
        get { surface?.contentView.recordsLifecycleRenderCompletions == true }
        set { surface?.contentView.recordsLifecycleRenderCompletions = newValue }
    }

    /// FIFO admission is synchronous. Await only the returned scalar task.
    public func enqueueLifecycleAcceptanceQuery() -> Task<VTLifecycleEngineScalars, Error>? {
        surface?.contentView.enqueueLifecycleAcceptanceQuery()
    }

    public var lifecycleAcceptanceSample: TerminalLifecyclePresentationSample? {
        guard let content = surface?.contentView else { return nil }
        let frame = content.frameValue.map { frame in
            TerminalLifecycleFrameSample(terminalID: frame.terminalID, revision: frame.revision,
                layout: frame.layout, offset: frame.viewport.offset, totalRows: frame.viewport.totalRows,
                awayFromBottom: frame.viewport.canScrollDown,
                topMarker: String(frame.line(0).trimmingCharacters(in: .whitespaces).prefix(64)),
                bottomMarker: String(frame.line(frame.layout.rows - 1).trimmingCharacters(in: .whitespaces).prefix(64)),
                markers: (0..<frame.layout.rows).compactMap { row in
                    let line = frame.line(row).trimmingCharacters(in: .whitespaces)
                    return line.hasPrefix("LIFE") ? String(line.prefix(64)) : nil
                }.prefix(8).map { $0 })
        }
        return .init(hostID: String(describing: ObjectIdentifier(self)),
            contentID: String(describing: ObjectIdentifier(content)), sessionID: content.lifecycleSessionIdentity,
            active: content.isPresentationActive, epoch: content.presentationEpochForDiagnostics,
            hasFrame: content.frameValue != nil, extractions: content.snapshotExtractions,
            renderCompletions: content.lifecycleRenderCompletions,
            renderedRevision: content.lifecycleRenderedRevision,
            rendererDiagnostics: content.metalRenderer?.diagnostics, metal: content.metalRenderer != nil,
            rendererActive: content.metalRenderer?.isActive == true,
            pending: content.metalRenderer?.pendingCount ?? -1,
            inFlight: content.metalRenderer?.inFlightCount ?? -1, frame: frame)
    }

    func emitLifecycleMomentum(_ kind: TerminalLifecycleMomentumSample.Kind, delta: CGPoint,
                               velocity: CGPoint? = nil,
                               stopCause: TerminalLifecycleMomentumSample.StopCause? = nil) {
        guard let observer = lifecycleMomentumObserver else { return }
        let velocity = velocity ?? momentumVelocity
        observer(.init(kind: kind, generation: lifecycleMomentumGeneration,
            ticks: lifecycleMomentumTicks, time: CACurrentMediaTime(),
            velocityX: velocity.x, velocityY: velocity.y,
            deltaX: delta.x, deltaY: delta.y, stopCause: stopCause,
            releaseBoundary: lifecycleMomentumReleaseBoundary))
    }
}
#endif
