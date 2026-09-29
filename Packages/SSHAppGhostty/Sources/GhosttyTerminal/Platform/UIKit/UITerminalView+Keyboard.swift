//
//  UITerminalView+Keyboard.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/17.
//

#if canImport(UIKit)
    import GhosttyVT
    import UIKit

    struct TerminalUIKitKeyPress: Equatable, Sendable {
        let keyCodeRawValue: UIKeyboardHIDUsage.RawValue
        let characters: String
        let charactersIgnoringModifiers: String
        let modifierFlagsRawValue: UIKeyModifierFlags.RawValue

        @MainActor
        init(_ key: UIKey) {
            keyCodeRawValue = key.keyCode.rawValue
            characters = key.characters
            charactersIgnoringModifiers = key.charactersIgnoringModifiers
            modifierFlagsRawValue = key.modifierFlags.rawValue
        }

        init(
            keyCode: UIKeyboardHIDUsage,
            characters: String,
            charactersIgnoringModifiers: String? = nil,
            modifierFlags: UIKeyModifierFlags = []
        ) {
            keyCodeRawValue = keyCode.rawValue
            self.characters = characters
            self.charactersIgnoringModifiers = charactersIgnoringModifiers ?? characters
            modifierFlagsRawValue = modifierFlags.rawValue
        }

        var keyCode: UIKeyboardHIDUsage {
            UIKeyboardHIDUsage(rawValue: keyCodeRawValue)!
        }

        var modifierFlags: UIKeyModifierFlags {
            UIKeyModifierFlags(rawValue: modifierFlagsRawValue)
        }
    }

    extension UITerminalView {
        #if !targetEnvironment(macCatalyst)
            func softwareKeyboardSuppressionDidChange() {
                invalidateSoftwareKeyboardDismissTracking()
                cancelDeferredSuppressedInputViewReload()
                if inputHandler.hasMarkedText {
                    if suppressesSoftwareKeyboard {
                        // Explicit Hide cancels preedit. Clear it before reloading
                        // input views, which can synchronously ask UIKit to unmark.
                        inputHandler.setMarkedText(nil, selectedRange: NSRange(location: 0, length: 0))
                    } else {
                        inputHandler.unmarkText(applyingStickyModifiers: false)
                    }
                }
                pendingKeyboardDismissOnTouchEnd = false
                touchDidScrollDuringCurrentTouch = false
                stickyModifiers.reset()
                hardwareStickyModifiersByKeyCode.removeAll()
                updateInputAssistantShortcutsForSuppression()

                if isFirstResponder {
                    reloadInputViews()
                }

                softwareKeyboardVisible = false
                keyboardFrameEndScreenRect = nil
                refitViewportForKeyboardChange(reason: "software-keyboard-suppression")

                if suppressesSoftwareKeyboard {
                    scheduleDeferredSuppressedInputViewReload()
                }
            }

            /// iPadOS keeps hosting the input assistant (on iPadOS 26+, a
            /// minimized shortcut pill at the bottom trailing corner) above the
            /// zero-height suppression input view. With no shortcut groups there
            /// is nothing for it to show. The original groups are restored on
            /// unsuppress so the normal keyboard shortcut bar is unchanged.
            func updateInputAssistantShortcutsForSuppression() {
                let item = inputAssistantItem
                if suppressesSoftwareKeyboard {
                    guard suppressedInputAssistantBarButtonGroups == nil else { return }
                    suppressedInputAssistantBarButtonGroups = (
                        item.leadingBarButtonGroups,
                        item.trailingBarButtonGroups
                    )
                    item.leadingBarButtonGroups = []
                    item.trailingBarButtonGroups = []
                } else if let saved = suppressedInputAssistantBarButtonGroups {
                    suppressedInputAssistantBarButtonGroups = nil
                    item.leadingBarButtonGroups = saved.leading
                    item.trailingBarButtonGroups = saved.trailing
                }
            }

            func cancelDeferredSuppressedInputViewReload() {
                deferredSuppressedInputViewReloadID = nil
            }

            private func scheduleDeferredSuppressedInputViewReload() {
                nextSuppressedInputViewReloadID &+= 1
                let reloadID = nextSuppressedInputViewReloadID
                deferredSuppressedInputViewReloadID = reloadID

                // UIKit can ignore the synchronous reload while processing its
                // native keyboard-hide transaction. Refresh once more after that
                // callback so the iPad input-assistant host is also dismantled.
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          deferredSuppressedInputViewReloadID == reloadID else {
                        return
                    }
                    deferredSuppressedInputViewReloadID = nil
                    guard isFirstResponder,
                          suppressesSoftwareKeyboard,
                          window != nil else {
                        return
                    }
                    reloadInputViews()
                }
            }
        #endif

        override open func pressesBegan(
            _ presses: Set<UIPress>,
            with event: UIPressesEvent?
        ) {
            var unhandled = presses
            for press in presses {
                guard let key = press.key else { continue }
                let keyPress = TerminalUIKitKeyPress(key)
                if handleKeyPress(keyPress, action: .press) {
                    unhandled.remove(press)
                    startHardwareKeyRepeatIfNeeded(for: keyPress)
                }
            }
            if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
        }

        override open func pressesChanged(
            _ presses: Set<UIPress>,
            with event: UIPressesEvent?
        ) {
            var unhandled = presses
            for press in presses {
                guard let key = press.key else { continue }
                let keyPress = TerminalUIKitKeyPress(key)
                if handleHardwareKeyRepeatChange(keyPress) { unhandled.remove(press) }
            }
            if !unhandled.isEmpty { super.pressesChanged(unhandled, with: event) }
        }

        override open func pressesEnded(
            _ presses: Set<UIPress>,
            with event: UIPressesEvent?
        ) {
            var unhandled = presses
            for press in presses {
                guard let key = press.key else { continue }
                let keyPress = TerminalUIKitKeyPress(key)
                cancelHardwareKeyRepeat(for: keyPress)
                if handleKeyPress(keyPress, action: .release) { unhandled.remove(press) }
                releaseHardwareTextInputSuppression(for: keyPress)
            }
            hardwareKeyHandled = false
            if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
        }

        override open func pressesCancelled(
            _ presses: Set<UIPress>,
            with event: UIPressesEvent?
        ) {
            var unhandled = presses
            for press in presses {
                guard let key = press.key else { continue }
                let keyPress = TerminalUIKitKeyPress(key)
                cancelHardwareKeyRepeat(for: keyPress)
                if handleKeyPress(keyPress, action: .release) { unhandled.remove(press) }
                releaseHardwareTextInputSuppression(for: keyPress)
            }
            hardwareKeyHandled = false
            if !unhandled.isEmpty { super.pressesCancelled(unhandled, with: event) }
        }

        func handleKeyPress(
            _ key: UIKey,
            action: VTKey.Action
        ) {
            handleKeyPress(TerminalUIKitKeyPress(key), action: action)
        }

        @discardableResult
        func handleKeyPress(
            _ key: TerminalUIKitKeyPress,
            action: VTKey.Action
        ) -> Bool {
            // Deactivation may lose the key-up. Keep a bounded HID tombstone so
            // a late repeat/release cannot escape remotely; a fresh press starts
            // a new lifecycle with current modifiers instead of stale sticky state.
            if cancelledLocalKeyCodes.contains(key.keyCodeRawValue) {
                if action != .press {
                    if action == .release { cancelledLocalKeyCodes.remove(key.keyCodeRawValue) }
                    return true
                }
                cancelledLocalKeyCodes.remove(key.keyCodeRawValue)
            }
            // Finish a previously claimed lifecycle even during IME ownership or
            // after detachment. Modifier changes cannot turn a local release remote.
            if localKeyActionsByKeyCode[key.keyCodeRawValue] != nil {
                let handled = handleLocalHardwareKey(key, action: action, modifiers: []) ?? true
                if action == .release { clearHardwareStickyModifiers(for: key) }
                return handled
            }
            guard let surface else {
                if action == .release {
                    clearHardwareStickyModifiers(for: key)
                }
                TerminalDebugLog.log(.input, "uikit key ignored: missing surface")
                return false
            }
            // UIKit owns composition and sticky state until committed text.
            guard !inputHandler.hasMarkedText else { return false }

            let filteredModifierFlags = filteredModifierFlags(for: key)
            #if !targetEnvironment(macCatalyst)
                nativeInteraction.hardwareModifiersChanged(to: filteredModifierFlags)
            #endif
            let stickyMods = stickyModifiersForHardwareKey(key, action: action)
            defer {
                if action == .release {
                    clearHardwareStickyModifiers(for: key)
                }
            }
            let mods = TerminalInputModifiers(from: filteredModifierFlags).union(stickyMods)
            let isCommandModified = mods.contains(.super_)

            if let handled = handleLocalHardwareKey(key, action: action, modifiers: mods) {
                return handled
            }
            if (action == .press || action == .repeatPress),
               (!stickyMods.isEmpty
                   || shouldSuppressUIKeyInput(for: key, isCommandModified: isCommandModified))
            {
                hardwareKeyHandled = true
                markHardwareTextInputSuppressionIfNeeded(for: key)
            }

            let unshifted = TerminalInputText.filteredFunctionKeyText(
                key.charactersIgnoringModifiers
            )?.unicodeScalars.first?.value ?? 0
            let text = !isCommandModified && shouldSendHardwareText(for: key)
                ? TerminalInputText.filteredFunctionKeyText(key.characters) ?? ""
                : ""
            // HID is already the native VT key identity. The encoder owns
            // DECCKM, modifyOtherKeys, and Kitty press/repeat/release handling.
            _ = surface.sendKey(
                hid: UInt16(key.keyCode.rawValue),
                action: action,
                text: text,
                unshifted: unshifted,
                modifiers: mods,
                consumedModifiers: TerminalInputModifiers(from: consumedModifierFlags(
                    for: key,
                    filteredModifierFlags: filteredModifierFlags
                ))
            )
            return true
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

        /// Shared by pressesChanged and its regression seam. The active task
        /// owns this HID, with the initial stroke's modifiers, until release.
        /// Current modifier eligibility cannot start a second repeat producer.
        func handleHardwareKeyRepeatChange(_ key: TerminalUIKitKeyPress) -> Bool {
            if hardwareKeyRepeatConfiguration.enabled,
               hardwareKeyRepeatTask != nil,
               hardwareKeyRepeatKey?.keyCodeRawValue == key.keyCodeRawValue,
               !inputHandler.hasMarkedText {
                markHardwareTextInputSuppressionIfNeeded(for: key)
                return true
            }
            return handleKeyPress(key, action: .repeatPress)
        }

        func cancelHardwareKeyRepeat(for key: TerminalUIKitKeyPress? = nil) {
            guard key == nil || hardwareKeyRepeatKey?.keyCodeRawValue == key?.keyCodeRawValue else { return }
            hardwareKeyRepeatTask?.cancel()
            hardwareKeyRepeatTask = nil
            hardwareKeyRepeatKey = nil
        }

        func startHardwareKeyRepeatIfNeeded(for key: TerminalUIKitKeyPress) {
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
                    self.handleKeyPress(key, action: .repeatPress)
                    try? await Task.sleep(nanoseconds: self.hardwareKeyRepeatConfiguration.intervalNanoseconds)
                }
            }
        }

        private func shouldSynthesizeHardwareRepeat(for key: TerminalUIKitKeyPress) -> Bool {
            let filteredModifierFlags = filteredModifierFlags(for: key)
            let stickyMods = hardwareStickyModifiersByKeyCode[key.keyCode.rawValue] ?? []
            let modifiers = TerminalInputModifiers(from: filteredModifierFlags).union(stickyMods)
            guard !modifiers.contains(.super_) else { return false }
            guard !Self.isModifierOnlyKey(key) else { return false }

            return !inputHandler.hasMarkedText && key.keyCode.rawValue != 0
        }

        private func markHardwareTextInputSuppressionIfNeeded(for key: TerminalUIKitKeyPress) {
            guard hardwareKeyRepeatConfiguration.enabled, !inputHandler.hasMarkedText else { return }
            let stickyMods = hardwareStickyModifiersByKeyCode[key.keyCode.rawValue] ?? []
            let modifiers = TerminalInputModifiers(
                from: filteredModifierFlags(for: key)
            ).union(stickyMods)
            guard !stickyMods.isEmpty
                    || shouldSuppressUIKeyInput(
                        for: key,
                        isCommandModified: modifiers.contains(.super_)
                    ) else {
                return
            }
            hardwareTextInputSuppressedKeyCodes.insert(key.keyCode.rawValue)
        }

        private func releaseHardwareTextInputSuppression(for key: TerminalUIKitKeyPress) {
            hardwareTextInputSuppressedKeyCodes.remove(key.keyCode.rawValue)
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

        func scheduleViewportRefreshAfterKeyboardZoom(
            _ direction: KeyboardZoomDirection
        ) {
            TerminalDebugLog.log(
                .actions,
                "keyboard zoom shortcut direction=\(direction.rawValue)"
            )
            switch direction {
            case .increase:
                currentFontSize = min(currentFontSize + 1, Self.maxFontSize)
            case .decrease:
                currentFontSize = max(currentFontSize - 1, Self.minFontSize)
            }
            isFontSizeTransientlyAdjusted = true
            pushVTFont()

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                core.synchronizeMetrics()
                refreshTextInputGeometry(
                    reason: "keyboard-zoom-\(direction.rawValue)"
                )
            }
        }

        enum KeyboardZoomDirection: String {
            case increase
            case decrease
        }

        private static func isModifierOnlyKey(_ key: TerminalUIKitKeyPress) -> Bool {
            (0xE0...0xE7).contains(Int(key.keyCode.rawValue))
        }

        private func stickyModifiersForHardwareKey(
            _ key: TerminalUIKitKeyPress,
            action: VTKey.Action
        ) -> TerminalInputModifiers {
            guard !Self.isModifierOnlyKey(key) else { return [] }

            let keyCode = key.keyCode.rawValue
            switch action {
            case .press:
                if let activeModifiers = hardwareStickyModifiersByKeyCode[keyCode] {
                    return activeModifiers
                }
                guard stickyModifiers.hasActiveModifiers else { return [] }
                let activeModifiers = stickyModifiers.consumeForNextKey()
                if !activeModifiers.isEmpty {
                    hardwareStickyModifiersByKeyCode[keyCode] = activeModifiers
                }
                return activeModifiers

            case .repeatPress, .release:
                return hardwareStickyModifiersByKeyCode[keyCode] ?? []

            }
        }

        private func clearHardwareStickyModifiers(for key: TerminalUIKitKeyPress) {
            hardwareStickyModifiersByKeyCode.removeValue(forKey: key.keyCode.rawValue)
        }
    }
#endif
