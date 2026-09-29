@testable import GhosttyTerminal
@testable import GhosttyVT

/// Test-only choice: full snapshot extraction as an explicit control.
/// Scalar reads traverse the same session FIFO without creating frames, copying
/// pixels, formatting selection text, or notifying render observers.
enum TerminalMemoryObservation: String, Sendable {
    case snapshot
    case scalar

    func layout(in session: VTTerminalSession) async throws -> VTLayout {
        switch self {
        case .snapshot:
            return try await session.snapshot().layout
        case .scalar:
            guard let query = session.enqueueInputQuery({ await $0.currentLayout }) else {
                throw VTError.retired
            }
            return try await query.value
        }
    }

    func hasSelection(in session: VTTerminalSession) async throws -> Bool {
        switch self {
        case .snapshot:
            return try await session.snapshot().selection != nil
        case .scalar:
            guard let query = session.enqueueInputQuery({ try await $0.hasSelection() }) else {
                throw VTError.retired
            }
            return try await query.value
        }
    }
}
