import GhosttyTerminal
import Foundation

/// A context-menu action can run before its dismissal or SwiftUI's tab visibility
/// update finishes. Retry only this explicit target, briefly and cancellably.
@MainActor
enum TerminalFindPresentation {
    @discardableResult
    static func presentWhenReady(
        target: () -> UITerminalView?,
        isCurrent: () -> Bool
    ) async -> Bool {
        for _ in 0..<30 {
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return false
            }
            guard !Task.isCancelled, isCurrent() else { return false }
            guard let view = target() else { continue }
            view.presentFind()
            if view.isFindPresented { return true }
        }
        return false
    }
}
