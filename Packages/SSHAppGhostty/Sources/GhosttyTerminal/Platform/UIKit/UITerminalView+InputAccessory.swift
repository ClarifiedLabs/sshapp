//
//  UITerminalView+InputAccessory.swift
//  libghostty-spm
//

#if canImport(UIKit)
    import GhosttyVT
    import UIKit

    extension UITerminalView {
        /// Explicit user paste uses VT's paste encoder, not ordinary typing.
        /// Unsafe content is retried only after user confirmation.
        public func insertPastedText(_ text: String) {
            guard !text.isEmpty else { return }
            if inputHandler.hasMarkedText { inputHandler.unmarkText() }
            #if !targetEnvironment(macCatalyst)
                _ = stickyModifiers.consumeForNextKey()
            #endif
            enqueuePastedText(text, allowUnsafe: false)
        }

        private func enqueuePastedText(_ text: String, allowUnsafe: Bool) {
            guard let surface,
                  let operation = surface.session.enqueueInput(.paste(text, allowUnsafe: allowUnsafe)) else {
                reportPasteFailure("The terminal is no longer available.")
                return
            }
            // Admission is synchronous, before any actor hop, preserving input order.
            Task { @MainActor [weak self, weak surface] in
                do {
                    _ = try await operation.value
                } catch VTError.unsafePaste {
                    guard let self, let surface, self.surface === surface else { return }
                    self.confirmUnsafePaste(text)
                } catch {
                    self?.reportPasteFailure("Paste failed: \(error.localizedDescription)")
                }
            }
        }

        private func confirmUnsafePaste(_ text: String) {
            let alert = UIAlertController(
                title: "Paste potentially unsafe text?",
                message: "This text contains control characters or multiple lines that may execute commands.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
                self?.ownedAlertDidDismiss()
            })
            let originalSurface = surface
            alert.addAction(UIAlertAction(title: "Paste", style: .default) { [weak self, weak originalSurface] _ in
                guard let self else { return }
                self.ownedAlertDidDismiss()
                guard let originalSurface, self.surface === originalSurface else { return }
                self.enqueuePastedText(text, allowUnsafe: true)
            })
            guard let presenter = pasteAlertPresenter else {
                reportPasteFailure("Unsafe paste blocked. No confirmation presenter is available.")
                return
            }
            presentOwnedAlert(alert, from: presenter)
        }

        /// Presents a terminal-owned alert without treating the keyboard
        /// transition it causes as a user's native keyboard dismissal.
        ///
        /// iPadOS can resign the terminal or collapse the full keyboard to the
        /// minimized assistant while an alert is up. Classifying that as a
        /// system dismiss would enter persistent software-keyboard suppression
        /// after a paste confirmation. Pair with `ownedAlertDidDismiss()`.
        func presentOwnedAlert(_ alert: UIAlertController, from presenter: UIViewController) {
            #if !targetEnvironment(macCatalyst)
                ownedAlert = alert
                ownedAlertReclaimsFirstResponder = isFirstResponder
                invalidateSoftwareKeyboardDismissTracking()
            #endif
            presenter.present(alert, animated: true)
        }

        /// Restores keyboard ownership after a terminal-owned alert. Focus is
        /// reclaimed only if the terminal had it when the alert was presented.
        func ownedAlertDidDismiss() {
            #if !targetEnvironment(macCatalyst)
                ownedAlert = nil
                let reclaimsFirstResponder = ownedAlertReclaimsFirstResponder
                ownedAlertReclaimsFirstResponder = false
                guard window != nil, isHostVisible, !suppressesSoftwareKeyboard else { return }
                if !isFirstResponder {
                    // The next full keyboardDidShow re-arms dismissal tracking.
                    if reclaimsFirstResponder { _ = becomeFirstResponder() }
                    return
                }
                // The keyboard stayed up under the alert, so no keyboardDidShow
                // follows; re-arm tracking from the last observed frame.
                if softwareKeyboardVisible,
                   (keyboardFrameEndScreenRect?.height ?? 0) > Self.fullSoftwareKeyboardHeightThreshold,
                   !isResigningFirstResponder,
                   isActiveForSoftwareKeyboardDismissal {
                    softwareKeyboardDismissState = .fullPresentation
                }
            #endif
        }

        private func reportPasteFailure(_ message: String) {
            TerminalDebugLog.log(.input, message)
            UIAccessibility.post(notification: .announcement, argument: message)
            guard let presenter = pasteAlertPresenter else { return }
            let alert = UIAlertController(title: "Unable to Paste", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
                self?.ownedAlertDidDismiss()
            })
            presentOwnedAlert(alert, from: presenter)
        }

        private var pasteAlertPresenter: UIViewController? {
            guard window != nil else { return nil }
            var responder: UIResponder? = self
            while let current = responder {
                if var controller = current as? UIViewController {
                    while let presented = controller.presentedViewController { controller = presented }
                    return controller
                }
                responder = current.next
            }
            return nil
        }
    }
#endif

#if canImport(UIKit) && !targetEnvironment(macCatalyst)
    import GhosttyVT
    import UIKit

    extension UITerminalView {
        override open var inputAccessoryView: UIView? {
            usesSystemInputAccessory && !inputAccessoryItems.isEmpty ? terminalInputAccessory : nil
        }

        func handleInputBarKey(_ key: TerminalInputBarKey) {
            commitMarkedTextIfStickyModifiersAreActive()

            switch key {
            case let .symbol(text):
                _ = handleStickyTextInput(text)

            case .paste:
                _ = stickyModifiers.consumeForNextKey()
                pasteFromPasteboard()

            case .esc:
                let mods = stickyModifiers.consumeForNextKey()
                sendSyntheticKey(usage: 0x29, additionalMods: mods)

            case .tab:
                let mods = stickyModifiers.consumeForNextKey()
                sendSyntheticKey(usage: 0x2B, additionalMods: mods)

            case .arrowLeft:
                let mods = stickyModifiers.consumeForNextKey()
                sendSyntheticKey(usage: 0x50, additionalMods: mods)

            case .arrowRight:
                let mods = stickyModifiers.consumeForNextKey()
                sendSyntheticKey(usage: 0x4F, additionalMods: mods)

            case .arrowUp:
                let mods = stickyModifiers.consumeForNextKey()
                sendSyntheticKey(usage: 0x52, additionalMods: mods)

            case .arrowDown:
                let mods = stickyModifiers.consumeForNextKey()
                sendSyntheticKey(usage: 0x51, additionalMods: mods)
            }
        }

        private func commitMarkedTextIfStickyModifiersAreActive() {
            guard stickyModifiers.hasActiveModifiers, inputHandler.hasMarkedText else { return }
            inputHandler.unmarkText(applyingStickyModifiers: false)
        }

        func sendSyntheticKey(
            usage: UInt16,
            additionalMods: TerminalInputModifiers = []
        ) {
            guard let surface else { return }

            if inputHandler.hasMarkedText {
                inputHandler.unmarkText()
            }

            _ = surface.sendKey(
                hid: usage, action: .press, text: "", unshifted: 0,
                modifiers: additionalMods, consumedModifiers: []
            )
            _ = surface.sendKey(
                hid: usage, action: .release, text: "", unshifted: 0,
                modifiers: additionalMods, consumedModifiers: []
            )
        }

        @discardableResult
        func handleStickyTextInput(_ text: String) -> Bool {
            handleStickyTextInput(text) { [weak self] text in
                self?.inputHandler.insertText(text)
            }
        }

        @discardableResult
        func handleStickyCommittedText(_ text: String) -> Bool {
            handleStickyTextInput(text) { [weak self] text in
                self?.surface?.sendText(text)
            }
        }

        @discardableResult
        func handleStickyMarkedText(_ text: String) -> Bool {
            guard stickyModifiers.hasActiveModifiers else { return false }

            let keyText = String(text.prefix(1))
            guard !keyText.isEmpty else {
                stickyModifiers.reset()
                return false
            }

            let mods = stickyModifiers.consumeForNextKey()
            let handled = sendModifiedTextKey(keyText, modifiers: mods)

            stickyModifiers.reset()
            return handled
        }

        @discardableResult
        private func handleStickyTextInput(
            _ text: String,
            fallback: (String) -> Void
        ) -> Bool {
            commitMarkedTextIfStickyModifiersAreActive()

            guard stickyModifiers.hasActiveModifiers else {
                fallback(text)
                return false
            }

            let mods = stickyModifiers.consumeForNextKey()
            if text == "\r" || text == "\n" {
                sendSyntheticKey(usage: 0x28, additionalMods: mods)
                return true
            }

            if sendModifiedTextKey(text, modifiers: mods) {
                return true
            }

            fallback(text)
            return false
        }

        private func sendModifiedTextKey(
            _ text: String,
            modifiers: TerminalInputModifiers
        ) -> Bool {
            guard let surface else { return false }

            if inputHandler.hasMarkedText {
                inputHandler.unmarkText()
            }

            guard let mapping = keyMapping(for: text) else { return false }

            let mods = modifiers.union(mapping.extraModifiers)
            if let action = TerminalLocalKeyAction.resolve(
                characters: text,
                ignoringModifiers: text,
                modifiers: mods
            ) {
                performLocalKeyAction(action)
                return true
            }
            let text = modifiers.contains(.super_) ? "" : text
            _ = surface.sendKey(
                hid: mapping.hid, action: .press, text: text,
                unshifted: mapping.unshifted, modifiers: mods,
                consumedModifiers: mapping.extraModifiers
            )
            _ = surface.sendKey(
                hid: mapping.hid, action: .release, text: text,
                unshifted: mapping.unshifted, modifiers: mods,
                consumedModifiers: mapping.extraModifiers
            )
            return true
        }

        private func keyMapping(
            for text: String
        ) -> (hid: UInt16, unshifted: UInt32, extraModifiers: TerminalInputModifiers)? {
            guard text.count == 1, let char = text.first else { return nil }
            let lower = char.lowercased()
            if let ascii = lower.utf8.first, lower.utf8.count == 1, (97...122).contains(ascii) {
                return (UInt16(ascii - 97 + 4), UInt32(ascii), text == lower ? [] : [.shift])
            }
            let unshifted = Array("1234567890-=[]\\;'`,./ ")
            let shifted = Array("!@#$%^&*()_+{}|:\"~<>? ")
            let usages: [UInt16] = [0x1E, 0x1F, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25,
                0x26, 0x27, 0x2D, 0x2E, 0x2F, 0x30, 0x31, 0x33, 0x34, 0x35,
                0x36, 0x37, 0x38, 0x2C]
            if let index = unshifted.firstIndex(of: char) {
                return (usages[index], unshifted[index].unicodeScalars.first!.value, [])
            }
            if let index = shifted.firstIndex(of: char) {
                return (usages[index], unshifted[index].unicodeScalars.first!.value, [.shift])
            }
            return nil
        }
    }
#endif
