#if DEBUG && canImport(UIKit) && !targetEnvironment(macCatalyst)
import GhosttyVT
import UIKit

/// Read-only access for the opt-in physical compositor fixture. This does not
/// install observers, request frames, mutate selection, or refresh the loupe.
extension UITerminalView {
    public var debugLoupeAcceptanceFrame: VTFrameValue? { surface?.frameValue }
    public var debugLoupeAcceptanceEndPan: UIPanGestureRecognizer? {
        guard selectionEndHandle?.isHidden == false else { return nil }
        return selectionEndHandle?.panGesture
    }
    public var debugLoupeAcceptanceLoupe: UIView? { selectionMagnifier }
    public var debugLoupeAcceptanceHandleExclusionRects: [CGRect] {
        [selectionStartHandle, selectionEndHandle].compactMap { handle in
            guard let handle, !handle.isHidden else { return nil }
            return handle.acceptanceInkExclusionRect(in: self)
        }
    }
    public var debugLoupeAcceptanceRenderer: String {
        surface?.contentView.metalRenderer == nil ? "CoreText" : "Metal"
    }
    public var debugLoupeAcceptanceDragging: Bool { nativeInteraction.isDraggingSelection }
    public var debugLoupeAcceptanceAutoscroll: Bool { nativeInteraction.isAutoscrollScheduled }
}
#endif
