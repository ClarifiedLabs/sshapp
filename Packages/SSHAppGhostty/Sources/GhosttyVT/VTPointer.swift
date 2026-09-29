import Foundation

public struct VTPointerRequest: Equatable, Sendable {
    public enum Phase: Sendable { case press, move, release, cancel, autoscroll, tap }
    public enum Source: Sendable { case pointer, touch }
    public let id: UInt64
    public let terminalID: UUID
    public let generation: UInt64
    public let revision: UInt64
    public internal(set) var phase: Phase
    public let source: Source
    public let button: Int32
    public let point: CGPoint
    public let modifiers: VTModifiers
    public let time: UInt64
    #if DEBUG
    package var recordsLifecycleReleaseBoundary = false
    #endif
    /// Explicit long-press selection; nil preserves normal pointer/touch routing.
    public enum SelectionBehavior: Sendable { case word }
    public let selectionBehavior: SelectionBehavior?

    public init(id: UInt64, terminalID: UUID, generation: UInt64, revision: UInt64,
                phase: Phase, source: Source, button: Int32 = 1, point: CGPoint,
                modifiers: VTModifiers = [], time: UInt64, selectionBehavior: SelectionBehavior? = nil) {
        self.id = id
        self.terminalID = terminalID
        self.generation = generation
        self.revision = revision
        self.phase = phase
        self.source = source
        self.button = button
        self.point = point
        self.modifiers = modifiers
        self.time = time
        self.selectionBehavior = selectionBehavior
    }

}

public struct VTPointerResponse: Sendable {
    public internal(set) var bytes = Data()
    public internal(set) var active = false
    public internal(set) var localSelection = false
    public internal(set) var autoscroll = 0
    public internal(set) var menu = false
    public internal(set) var showKeyboard = false
    /// The press was routed to the remote application's mouse tracking.
    public internal(set) var remote = false
    public internal(set) var link: VTLink?
    // Diagnostic command classification only; nonzero rows can still clamp at
    // a history boundary. Never infer a viewport change from a displayed mode.
    public internal(set) var localScrollRows: Int?
    public internal(set) var localScrollRevision: UInt64?
    #if DEBUG
    public internal(set) var lifecycleReleaseBoundary: VTPointerReleaseBoundary?
    #endif
}

struct VTPointerState {
    enum Route { case remote, selection, context, viewport, link }
    let press: VTPointerRequest
    let route: Route
    var point: CGPoint
    var modifiers: VTModifiers
    var moved = false
    var remainder: CGFloat = 0
    var link: VTLink?
}

public struct VTPointerScrollRequest: Sendable {
    public let terminalID: UUID
    public let generation: UInt64
    public let point: CGPoint
    public let delta: CGPoint
    public let modifiers: VTModifiers

    public init(terminalID: UUID, generation: UInt64, point: CGPoint, delta: CGPoint, modifiers: VTModifiers) {
        self.terminalID = terminalID
        self.generation = generation
        self.point = point
        self.delta = delta
        self.modifiers = modifiers
    }
}

#if DEBUG
/// Captured after final release effects in the same uninterrupted engine actor
/// operation. This owns no frame and cannot lag behind final pan/release work.
public struct VTPointerReleaseBoundary: Codable, Equatable, Sendable {
    public let pointerID: UInt64
    public let terminalID: UUID
    public let generation: UInt64
    public let revision: UInt64
    public let offset: UInt64
    public let totalRows: UInt64
    public let rows: UInt64
}
#endif
