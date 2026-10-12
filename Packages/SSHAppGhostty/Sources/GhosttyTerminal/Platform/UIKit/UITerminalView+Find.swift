#if canImport(UIKit)
import GhosttyVT
import UIKit

extension UITerminalView {
    public var isFindPresented: Bool { findController != nil }

    var findHostIsVisible: Bool {
        guard findApplicationActive, window != nil, isHostVisible, isUserInteractionEnabled else { return false }
        if let scene = window?.windowScene, scene.activationState != .foregroundActive { return false }
        var ancestor: UIView? = self
        while let view = ancestor {
            if view.isHidden || view.alpha <= 0.01 { return false }
            ancestor = view.superview
        }
        return true
    }

    /// Presents transient, session-local search. Query text never enters the SSH input path.
    public func presentFind() {
        if let findController {
            findController.field.focusQuery()
            return
        }
        guard !inputHandler.hasMarkedText, findHostIsVisible,
              let session = surface?.session else { return }
        #if !targetEnvironment(macCatalyst)
            guard !isKeyboardTransitionOwnedByPresentation else { return }
        #endif
        findPresentationGeneration &+= 1
        let find = TerminalFindController(host: self, session: session)
        // Cancel before begin is admitted, so selection/mouse cleanup cannot
        // overwrite the search highlight after search ownership starts.
        cancelNativeInteractions()
        cancelHardwareKeyRepeat()
        cancelLocalKeyActions()
        dismissTerminalEditMenus()
        inputHandler.setMarkedText(nil, selectedRange: NSRange(location: 0, length: 0))
        #if !targetEnvironment(macCatalyst)
            dismissSelectionHandles()
            cancelDeferredSuppressedInputViewReload()
            invalidateSoftwareKeyboardDismissTracking()
        #endif
        findController = find
        resignFirstResponderForApplicationAction()
        find.start()
    }

    public func dismissFind(restoringFocus: Bool = true) {
        guard let find = findController else { return }
        // Keep Find ownership during resignation/keyboard notifications.
        find.close()
        findController = nil
        #if !targetEnvironment(macCatalyst)
            invalidateSoftwareKeyboardDismissTracking()
        #endif
        setNeedsLayout()
        refitViewportForKeyboardChange(reason: "find-dismiss")
        requestImmediateDraw()
        guard restoringFocus, find.restoresFocus, find.canRestoreFocus,
              surface?.session === find.session, findHostIsVisible else { return }
        becomeFirstResponder()
    }

    func layoutFindBar() {
        guard let findController else { return }
        let viewport = terminalViewportBounds
        findController.bar.frame = CGRect(x: bounds.minX, y: viewport.maxY,
            width: bounds.width, height: min(TerminalFindController.height, bounds.height))
        bringSubviewToFront(findController.bar)
    }

    /// Claims a complete physical shortcut lifecycle, including key-up after
    /// Find's field has relinquished focus. Modifier changes cannot leak it remotely.
    func handleFindKey(_ key: TerminalUIKitKeyPress, action: VTKey.Action) -> Bool {
        let code = key.keyCodeRawValue
        if findKeyCodes.contains(code) {
            if action != .press {
                if action == .release { findKeyCodes.remove(code) }
                return true
            }
            // UIKit may deliver key-up only to the field. A fresh press starts
            // a new lifecycle rather than leaving a stale HID tombstone.
            findKeyCodes.remove(code)
        }
        // Finish claimed key lifecycles above, but do not steal a fresh Find
        // shortcut from UIKit while terminal composition owns the keyboard.
        guard isFindPresented || !inputHandler.hasMarkedText else { return false }
        let modifiers = key.modifierFlags.intersection([.command, .shift, .alternate, .control])
        let character = key.charactersIgnoringModifiers.lowercased()
        if action == .press, modifiers.subtracting(.shift) == .command,
           character == "f" || character == "g" {
            findKeyCodes.insert(code)
            presentFind()
            if character == "g" { findController?.navigate(modifiers.contains(.shift) ? -1 : 1) }
            return true
        }
        if isFindPresented {
            if action == .press { findKeyCodes.insert(code) }
            return true
        }
        return false
    }
}
#endif
