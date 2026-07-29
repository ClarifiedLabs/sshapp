import Foundation
import UIKit

@MainActor
final class IdleTimerCoordinator {
    static let shared = IdleTimerCoordinator()

    private let setIdleTimerDisabled: (Bool) -> Void
    private var requestingSceneIDs: Set<UUID> = []
    private var appliedValue = false

    init(
        setIdleTimerDisabled: @escaping (Bool) -> Void = {
            UIApplication.shared.isIdleTimerDisabled = $0
        }
    ) {
        self.setIdleTimerDisabled = setIdleTimerDisabled
    }

    func updateScene(_ sceneID: UUID, shouldDisableIdleTimer: Bool) {
        if shouldDisableIdleTimer {
            requestingSceneIDs.insert(sceneID)
        } else {
            requestingSceneIDs.remove(sceneID)
        }
        applyAggregateValue()
    }

    func removeScene(_ sceneID: UUID) {
        requestingSceneIDs.remove(sceneID)
        applyAggregateValue()
    }

    private func applyAggregateValue() {
        let newValue = !requestingSceneIDs.isEmpty
        guard newValue != appliedValue else { return }

        appliedValue = newValue
        setIdleTimerDisabled(newValue)
    }
}
