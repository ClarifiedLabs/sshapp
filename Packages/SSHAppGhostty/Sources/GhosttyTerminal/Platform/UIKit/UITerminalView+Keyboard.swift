//
//  UITerminalView+Keyboard.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/17.
//

#if canImport(UIKit)
    import GhosttyKit
    import UIKit

    struct TerminalUIKitKeyPress: Equatable, Sendable {
        let keyCodeRawValue: UIKeyboardHIDUsage.RawValue
        let characters: String
        let charactersIgnoringModifiers: String
        let modifierFlagsRawValue: UIKeyModifierFlags.RawValue

        init(_ key: UIKey) {
            keyCodeRawValue = key.keyCode.rawValue
            characters = key.characters
            charactersIgnoringModifiers = key.charactersIgnoringModifiers
            modifierFlagsRawValue = key.modifierFlags.rawValue
        }

        var keyCode: UIKeyboardHIDUsage {
            UIKeyboardHIDUsage(rawValue: keyCodeRawValue)!
        }

        var modifierFlags: UIKeyModifierFlags {
            UIKeyModifierFlags(rawValue: modifierFlagsRawValue)
        }
    }

    extension UITerminalView {
        override open func pressesBegan(
            _ presses: Set<UIPress>,
            with _: UIPressesEvent?
        ) {
            for press in presses {
                guard let key = press.key else { continue }
                let keyPress = TerminalUIKitKeyPress(key)
                handleKeyPress(keyPress, action: GHOSTTY_ACTION_PRESS)
                startHardwareKeyRepeatIfNeeded(for: keyPress)
            }
        }

        override open func pressesChanged(
            _ presses: Set<UIPress>,
            with _: UIPressesEvent?
        ) {
            if hardwareKeyRepeatConfiguration.enabled {
                for press in presses {
                    guard let key = press.key else { continue }
                    markHardwareTextInputSuppressionIfNeeded(for: TerminalUIKitKeyPress(key))
                }
                return
            }

            for press in presses {
                guard let key = press.key else { continue }
                handleKeyPress(TerminalUIKitKeyPress(key), action: GHOSTTY_ACTION_REPEAT)
            }
        }

        override open func pressesEnded(
            _ presses: Set<UIPress>,
            with _: UIPressesEvent?
        ) {
            for press in presses {
                guard let key = press.key else { continue }
                let keyPress = TerminalUIKitKeyPress(key)
                cancelHardwareKeyRepeat(for: keyPress)
                handleKeyPress(keyPress, action: GHOSTTY_ACTION_RELEASE)
                releaseHardwareTextInputSuppression(for: keyPress)
            }
            hardwareKeyHandled = false
        }

        override open func pressesCancelled(
            _ presses: Set<UIPress>,
            with event: UIPressesEvent?
        ) {
            for press in presses {
                guard let key = press.key else { continue }
                let keyPress = TerminalUIKitKeyPress(key)
                cancelHardwareKeyRepeat(for: keyPress)
                releaseHardwareTextInputSuppression(for: keyPress)
            }
            hardwareKeyHandled = false
            super.pressesCancelled(presses, with: event)
        }

        func handleKeyPress(
            _ key: UIKey,
            action: ghostty_input_action_e
        ) {
            handleKeyPress(TerminalUIKitKeyPress(key), action: action)
        }

        func handleKeyPress(
            _ key: TerminalUIKitKeyPress,
            action: ghostty_input_action_e
        ) {
            guard let surface else {
                TerminalDebugLog.log(.input, "uikit key ignored: missing surface")
                return
            }

            let filteredModifierFlags = filteredModifierFlags(for: key)
            let isCommandModified = filteredModifierFlags.contains(.command)
            let mods = TerminalInputModifiers(from: filteredModifierFlags)
            let keyboardZoomDirection = commandZoomDirection(
                for: key,
                action: action,
                filteredModifierFlags: filteredModifierFlags
            )

            if (action == GHOSTTY_ACTION_PRESS || action == GHOSTTY_ACTION_REPEAT),
               shouldSuppressUIKeyInput(for: key, isCommandModified: isCommandModified)
            {
                hardwareKeyHandled = true
                markHardwareTextInputSuppressionIfNeeded(for: key)
            }

            let delivery = TerminalHardwareKeyRouter.routeUIKit(
                usage: UInt16(key.keyCode.rawValue),
                backend: configuration.backend,
                modifiers: mods
            )

            TerminalDebugLog.log(
                .input,
                "uikit key action=\(TerminalDebugLog.describe(action)) code=\(key.keyCode.rawValue) chars=\(TerminalDebugLog.describe(key.characters)) ignoring=\(TerminalDebugLog.describe(key.charactersIgnoringModifiers)) mods=0x\(String(filteredModifierFlags.rawValue, radix: 16)) delivery=\(delivery.debugSummary) marked=\(inputHandler.hasMarkedText)"
            )

            if action == GHOSTTY_ACTION_RELEASE, delivery.isDirectInput {
                return
            }

            if handleDirectInputIfNeeded(
                delivery,
                action: action,
                isCommandModified: isCommandModified
            ) {
                if let keyboardZoomDirection {
                    scheduleViewportRefreshAfterKeyboardZoom(keyboardZoomDirection)
                }
                return
            }

            var keyEvent = ghostty_input_key_s()
            keyEvent.action = action
            keyEvent.mods = mods.ghosttyMods
            // Ghostty expects a platform-native keycode, which it resolves
            // to its internal Key enum via src/input/keycodes.zig. On iOS
            // that table uses macOS virtual keycodes (native_idx = 4), so
            // translate the documented HID usage value from UIKey into the
            // corresponding AppKit keycode here.
            keyEvent.keycode = TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(
                usage: UInt16(key.keyCode.rawValue)
            )
            keyEvent.composing = inputHandler.hasMarkedText

            keyEvent.consumed_mods = TerminalInputModifiers(
                from: consumedModifierFlags(
                    for: key,
                    filteredModifierFlags: filteredModifierFlags
                )
            ).ghosttyMods

            guard action == GHOSTTY_ACTION_PRESS || action == GHOSTTY_ACTION_REPEAT else {
                _ = surface.sendKeyEvent(keyEvent)
                return
            }

            let filteredIgnoringModifiers = TerminalInputText.filteredFunctionKeyText(
                key.charactersIgnoringModifiers
            )

            if let codepoint = filteredIgnoringModifiers?.unicodeScalars.first {
                keyEvent.unshifted_codepoint = codepoint.value
            }

            guard !isCommandModified else {
                _ = surface.sendKeyEvent(keyEvent)
                if let keyboardZoomDirection {
                    scheduleViewportRefreshAfterKeyboardZoom(keyboardZoomDirection)
                }
                return
            }

            guard shouldSendHardwareText(for: key),
                  let text = TerminalInputText.filteredFunctionKeyText(key.characters),
                  !text.isEmpty
            else {
                _ = surface.sendKeyEvent(keyEvent)
                return
            }

            text.withCString { ptr in
                keyEvent.text = ptr
                _ = surface.sendKeyEvent(keyEvent)
            }
        }

        func shouldSuppressUIKeyInput(
            for key: TerminalUIKitKeyPress,
            isCommandModified: Bool
        ) -> Bool {
            guard !isCommandModified else { return false }
            if Self.isNonTextHardwareKey(usage: UInt16(key.keyCode.rawValue)) {
                return true
            }
            guard key.modifierFlags.intersection([.alternate, .control]).isEmpty else {
                return false
            }
            guard !key.characters.isEmpty else {
                return key.keyCode == .keyboardDeleteOrBackspace
            }
            return true
        }

        private func consumedModifierFlags(
            for key: TerminalUIKitKeyPress,
            filteredModifierFlags: UIKeyModifierFlags
        ) -> UIKeyModifierFlags {
            guard shouldSendHardwareText(for: key) else { return [] }

            var consumedFlags = filteredModifierFlags
            consumedFlags.remove(.control)
            consumedFlags.remove(.command)
            return consumedFlags
        }

        private func shouldSendHardwareText(for key: TerminalUIKitKeyPress) -> Bool {
            !Self.isNonTextHardwareKey(usage: UInt16(key.keyCode.rawValue))
        }

        func cancelHardwareKeyRepeat(for key: TerminalUIKitKeyPress? = nil) {
            guard key == nil || hardwareKeyRepeatKey == key else { return }
            hardwareKeyRepeatTask?.cancel()
            hardwareKeyRepeatTask = nil
            hardwareKeyRepeatKey = nil
        }

        private func startHardwareKeyRepeatIfNeeded(for key: TerminalUIKitKeyPress) {
            guard hardwareKeyRepeatConfiguration.enabled,
                  shouldSynthesizeHardwareRepeat(for: key) else {
                return
            }

            cancelHardwareKeyRepeat()
            hardwareKeyRepeatKey = key
            let initialDelayNanoseconds = hardwareKeyRepeatConfiguration.delayNanoseconds
            hardwareKeyRepeatTask = Task { @MainActor [weak self, key, initialDelayNanoseconds] in
                try? await Task.sleep(nanoseconds: initialDelayNanoseconds)
                while !Task.isCancelled {
                    guard let self,
                          self.hardwareKeyRepeatConfiguration.enabled,
                          self.hardwareKeyRepeatKey == key else {
                        return
                    }
                    self.handleKeyPress(key, action: GHOSTTY_ACTION_REPEAT)
                    try? await Task.sleep(nanoseconds: self.hardwareKeyRepeatConfiguration.intervalNanoseconds)
                }
            }
        }

        private func shouldSynthesizeHardwareRepeat(for key: TerminalUIKitKeyPress) -> Bool {
            let filteredModifierFlags = filteredModifierFlags(for: key)
            guard !filteredModifierFlags.contains(.command) else { return false }
            guard !Self.isModifierOnlyKey(key) else { return false }

            let delivery = TerminalHardwareKeyRouter.routeUIKit(
                usage: UInt16(key.keyCode.rawValue),
                backend: configuration.backend,
                modifiers: TerminalInputModifiers(from: filteredModifierFlags)
            )

            switch delivery {
            case .data:
                return true
            case let .ghostty(ghosttyKey):
                return ghosttyKey != GHOSTTY_KEY_UNIDENTIFIED
            }
        }

        private func markHardwareTextInputSuppressionIfNeeded(for key: TerminalUIKitKeyPress) {
            guard hardwareKeyRepeatConfiguration.enabled else { return }
            let isCommandModified = filteredModifierFlags(for: key).contains(.command)
            guard shouldSuppressUIKeyInput(for: key, isCommandModified: isCommandModified) else {
                return
            }
            hardwareTextInputSuppressedKeyCodes.insert(key.keyCode.rawValue)
        }

        private func releaseHardwareTextInputSuppression(for key: TerminalUIKitKeyPress) {
            hardwareTextInputSuppressedKeyCodes.remove(key.keyCode.rawValue)
        }

        private func handleDirectInputIfNeeded(
            _ delivery: TerminalHardwareKeyDelivery,
            action: ghostty_input_action_e,
            isCommandModified: Bool
        ) -> Bool {
            // When IME composition is active, UIKit must own editing keys such as
            // backspace and arrows so candidate text stays in sync.
            guard !inputHandler.hasMarkedText else { return false }
            guard !isCommandModified else { return false }
            guard action == GHOSTTY_ACTION_PRESS || action == GHOSTTY_ACTION_REPEAT else {
                return false
            }
            guard case let .data(sequence) = delivery else { return false }
            guard case let .inMemory(session) = configuration.backend else { return false }

            session.sendInput(sequence)
            return true
        }

        private func filteredModifierFlags(for key: TerminalUIKitKeyPress) -> UIKeyModifierFlags {
            var flags = key.modifierFlags
            let isFunctionKey =
                TerminalInputText.filteredFunctionKeyText(key.characters) == nil ||
                TerminalInputText.filteredFunctionKeyText(key.charactersIgnoringModifiers) == nil
            if isFunctionKey {
                flags.remove(.numericPad)
            }
            return flags
        }

        private static func isNonTextHardwareKey(usage: UInt16) -> Bool {
            switch usage {
            case 0x28, // Return
                 0x29, // Escape
                 0x2A, // Backspace
                 0x2B, // Tab
                 0x39, // Caps Lock
                 0x3A ... 0x45, // F1 through F12
                 0x46 ... 0x52, // Print Screen through Up Arrow
                 0x53, // Num Lock
                 0x58, // Keypad Enter
                 0x65, // Context Menu
                 0x68 ... 0x73, // F13 through F24
                 0x75, // Help
                 0x7B ... 0x81, // Cut/Copy/Paste and volume keys
                 0xE0 ... 0xE7: // Modifier keys
                return true
            default:
                return false
            }
        }

        private func commandZoomDirection(
            for key: TerminalUIKitKeyPress,
            action: ghostty_input_action_e,
            filteredModifierFlags: UIKeyModifierFlags
        ) -> KeyboardZoomDirection? {
            guard action == GHOSTTY_ACTION_PRESS || action == GHOSTTY_ACTION_REPEAT else {
                return nil
            }
            guard filteredModifierFlags.contains(.command) else { return nil }

            let candidates = [
                key.characters,
                key.charactersIgnoringModifiers,
            ]
            if candidates.contains(where: { $0 == "+" || $0 == "=" }) {
                return .increase
            }
            if candidates.contains(where: { $0 == "-" || $0 == "_" }) {
                return .decrease
            }
            return nil
        }

        private func scheduleViewportRefreshAfterKeyboardZoom(
            _ direction: KeyboardZoomDirection
        ) {
            TerminalDebugLog.log(
                .actions,
                "keyboard zoom shortcut direction=\(direction.rawValue)"
            )
            #if !targetEnvironment(macCatalyst)
                switch direction {
                case .increase:
                    currentFontSize = min(currentFontSize + 1, Self.maxFontSize)
                case .decrease:
                    currentFontSize = max(currentFontSize - 1, Self.minFontSize)
                }
            #endif

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                core.synchronizeMetrics()
                refreshTextInputGeometry(
                    reason: "keyboard-zoom-\(direction.rawValue)"
                )
            }
        }

        private enum KeyboardZoomDirection: String {
            case increase
            case decrease
        }

        private static func isModifierOnlyKey(_ key: TerminalUIKitKeyPress) -> Bool {
            (0xE0...0xE7).contains(Int(key.keyCode.rawValue))
        }
    }
#endif
