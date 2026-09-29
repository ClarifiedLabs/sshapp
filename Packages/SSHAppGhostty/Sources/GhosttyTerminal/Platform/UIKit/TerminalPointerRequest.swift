import Foundation
import GhosttyVT

extension VTPointerRequest {
    /// Continue the same physical stream. In particular, word selection must
    /// keep its native anchor through motion, reversal, autoscroll and release.
    /// Reconstruct through the public initializer: phase is engine-owned state.
    func continuing(
        phase: Phase,
        point: CGPoint? = nil,
        modifiers: VTModifiers? = nil,
        time: UInt64? = nil
    ) -> VTPointerRequest {
        VTPointerRequest(
            id: id,
            terminalID: terminalID,
            generation: generation,
            revision: revision,
            phase: phase,
            source: source,
            button: button,
            point: point ?? self.point,
            modifiers: modifiers ?? self.modifiers,
            time: time ?? self.time,
            selectionBehavior: selectionBehavior
        )
    }
}
