#if canImport(UIKit)
    import GhosttyVT
    import UIKit

    /// Only existing host bindings belong here. Everything else stays eligible
    /// for mode-aware remote encoding, including Command combined with Ctrl/Alt.
    enum TerminalLocalKeyAction: Equatable {
        case selectAll, copy, paste, increaseFontSize, decreaseFontSize, resetFontSize

        static func resolve(
            characters: String,
            ignoringModifiers: String,
            modifiers: TerminalInputModifiers
        ) -> Self? {
            let modifiers = modifiers.subtracting([.caps, .num])
            guard modifiers.subtracting(.shift) == .super_ else { return nil }
            let candidates = [characters, ignoringModifiers]
            if candidates.contains(where: { $0 == "+" || $0 == "=" }) { return .increaseFontSize }
            if candidates.contains(where: { $0 == "-" || $0 == "_" }) { return .decreaseFontSize }
            guard !modifiers.contains(.shift) else { return nil }
            switch ignoringModifiers.lowercased() {
            case "a": return .selectAll
            case "c": return .copy
            case "v": return .paste
            case "0": return .resetFontSize
            // Command-K is mode-dependent: the VT actor atomically chooses
            // native clear or remote encoding, not the displayed UIKit frame.
            default: return nil
            }
        }

        var usesNativeClipboardShortcut: Bool { self == .copy || self == .paste }
        var repeats: Bool { self == .increaseFontSize || self == .decreaseFontSize }
    }

    struct TerminalLocalKeyLifecycle {
        let action: TerminalLocalKeyAction
        let usesUIKit: Bool
    }

    extension UITerminalView {
        /// The HID identity, not the current modifier flags, owns repeats and
        /// releases. A released Command modifier must never leak a Kitty key-up.
        /// False means UIKit owns this physical clipboard shortcut; nil means
        /// this is not a local binding and the remote route should decide.
        func handleLocalHardwareKey(
            _ key: TerminalUIKitKeyPress,
            action: VTKey.Action,
            modifiers: TerminalInputModifiers
        ) -> Bool? {
            let code = key.keyCodeRawValue
            if let held = localKeyActionsByKeyCode[code] {
                if action == .release {
                    localKeyActionsByKeyCode.removeValue(forKey: code)
                    hardwareTextInputSuppressedKeyCodes.remove(code)
                } else if held.action.repeats, !held.usesUIKit, !inputHandler.hasMarkedText {
                    performLocalKeyAction(held.action)
                }
                return !held.usesUIKit
            }
            guard action == .press, !inputHandler.hasMarkedText,
                  let local = TerminalLocalKeyAction.resolve(
                    characters: key.characters,
                    ignoringModifiers: key.charactersIgnoringModifiers,
                    modifiers: modifiers
                  ) else { return nil }
            // Physical Cmd-C/V must reach UIKit's standard edit actions. Calling
            // paste here as well would duplicate a system-dispatched paste and
            // bypass the platform's explicit clipboard-access attribution.
            let usesUIKit = key.modifierFlags.contains(.command) && local.usesNativeClipboardShortcut
            localKeyActionsByKeyCode[code] = .init(action: local, usesUIKit: usesUIKit)
            if !usesUIKit {
                hardwareKeyHandled = true
                hardwareTextInputSuppressedKeyCodes.insert(code)
                performLocalKeyAction(local)
            }
            return !usesUIKit
        }

        func cancelLocalKeyActions() {
            if !localKeyActionsByKeyCode.isEmpty { hardwareKeyHandled = false }
            for code in localKeyActionsByKeyCode.keys {
                cancelledLocalKeyCodes.insert(code)
                hardwareTextInputSuppressedKeyCodes.remove(code)
                hardwareStickyModifiersByKeyCode.removeValue(forKey: code)
            }
            localKeyActionsByKeyCode.removeAll()
        }

        func performLocalKeyAction(_ action: TerminalLocalKeyAction) {
            guard surface != nil else { return }
            switch action {
            case .selectAll:
                #if !targetEnvironment(macCatalyst)
                    nativeInteraction.selectAll()
                #else
                    surface?.session.enqueueSelectAll()
                #endif
            case .copy: copy(nil)
            case .paste: paste(nil)
            case .increaseFontSize: scheduleViewportRefreshAfterKeyboardZoom(.increase)
            case .decreaseFontSize: scheduleViewportRefreshAfterKeyboardZoom(.decrease)
            case .resetFontSize: _ = resetFontSize()
            }
        }
    }
#endif
