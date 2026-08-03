import Foundation
import GhosttyTerminal

/// Identifies one mounted terminal surface without relying on current focus.
enum TerminalFontSizeTargetKey: Hashable {
    case hostTab(UUID)
    case tmuxPane(tabID: UUID, paneID: TmuxPaneID)
}

/// Routes a font-size reset to exactly one mounted terminal view.
@MainActor
final class TerminalFontSizeTargetRegistry {
    private final class WeakTarget {
        weak var view: UITerminalView?

        init(_ view: UITerminalView) {
            self.view = view
        }
    }

    private var targets: [TerminalFontSizeTargetKey: WeakTarget] = [:]

    func register(_ view: UITerminalView, for key: TerminalFontSizeTargetKey) {
        removeDeadTargets()
        targets[key] = WeakTarget(view)
    }

    func unregister(_ view: UITerminalView, for key: TerminalFontSizeTargetKey) {
        guard let target = targets[key] else { return }
        guard let registeredView = target.view else {
            targets.removeValue(forKey: key)
            return
        }
        guard registeredView === view else { return }
        targets.removeValue(forKey: key)
    }

    func target(for key: TerminalFontSizeTargetKey) -> UITerminalView? {
        guard let target = targets[key] else { return nil }
        guard let view = target.view else {
            targets.removeValue(forKey: key)
            return nil
        }
        return view
    }

    @discardableResult
    func resetFontSize(for key: TerminalFontSizeTargetKey) -> Bool {
        target(for: key)?.resetFontSize() ?? false
    }

    private func removeDeadTargets() {
        targets = targets.filter { $0.value.view != nil }
    }
}
