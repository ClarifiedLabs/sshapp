#if DEBUG && canImport(UIKit)
import GhosttyVT
import UIKit

/// Does not keep any terminal owner, native frame, or GPU resource alive.
/// Session deallocation proves its FIFO drained (the drainer retains the session).
@MainActor
public final class TerminalSystemAcceptanceOwners {
    private weak var host: UITerminalView?
    private weak var content: VTContentView?
    private weak var session: VTTerminalSession?
    private weak var renderer: VTMetalRenderer?
    private let drainDiagnostics: VTMetalRenderer.InactiveDrainDiagnostics?
    private var drainBaseline: UInt64
    public private(set) var observedInactiveDrain = false

    init(host: UITerminalView?, content: VTContentView?, session: VTTerminalSession?, renderer: VTMetalRenderer?) {
        self.host = host
        self.content = content
        self.session = session
        self.renderer = renderer
        // This box contains only scalars, never an owner or a renderer resource.
        drainDiagnostics = renderer?.inactiveDrainDiagnostics
        drainBaseline = drainDiagnostics?.latest?.sequence ?? 0
    }

    public struct Scalars: Codable, Sendable {
        public let hostReleased: Bool
        public let contentReleased: Bool
        public let sessionReleased: Bool
        public let rendererReleased: Bool
        public let observedInactiveDrain: Bool
        public let pending: Int?
        public let inFlight: Int?
    }

    /// A prior switcher visit is not evidence for this destruction request.
    public func beginCloseObservation() {
        observedInactiveDrain = false
        drainBaseline = drainDiagnostics?.latest?.sequence ?? 0
    }

    public func sample() -> Scalars {
        // Polling the weak facade misses a drain followed by release between
        // polls. Only a new, real pipeline drain can survive that interval.
        let drain = drainDiagnostics?.latest.flatMap { $0.sequence > drainBaseline ? $0 : nil }
        if let drain, drain.pending == 0, drain.inFlight == 0 {
            observedInactiveDrain = true
        }
        return Scalars(hostReleased: host == nil, contentReleased: content == nil,
            sessionReleased: session == nil, rendererReleased: renderer == nil,
            observedInactiveDrain: observedInactiveDrain,
            pending: renderer?.pendingCount ?? drain?.pending,
            inFlight: renderer?.inFlightCount ?? drain?.inFlight)
    }
}

extension UITerminalView {
    public func systemAcceptanceOwners() -> TerminalSystemAcceptanceOwners {
        TerminalSystemAcceptanceOwners(host: self, content: surface?.contentView,
            session: surface?.session, renderer: surface?.contentView.metalRenderer)
    }
}
#endif
