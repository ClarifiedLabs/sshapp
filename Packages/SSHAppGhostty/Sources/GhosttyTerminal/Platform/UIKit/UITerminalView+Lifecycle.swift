//
//  UITerminalView+Lifecycle.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/17.
//

#if canImport(UIKit)
    import UIKit

    extension UITerminalView {
        func setupApplicationLifecycleObservers() {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(sceneWillDeactivate),
                name: UIScene.willDeactivateNotification,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(sceneDidEnterBackground),
                name: UIScene.didEnterBackgroundNotification,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(applicationWillResignActive),
                name: UIApplication.willResignActiveNotification,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(applicationDidEnterBackground),
                name: UIApplication.didEnterBackgroundNotification,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(applicationDidBecomeActive),
                name: UIApplication.didBecomeActiveNotification,
                object: nil
            )
        }

        func syncApplicationActiveState() {
            core.setApplicationActive(
                UIApplication.shared.applicationState == .active
            )
        }

        #if !targetEnvironment(macCatalyst)
            func invalidateSoftwareKeyboardDismissTracking() {
                softwareKeyboardDismissState = .idle
                deferredSystemSoftwareKeyboardDismissID = nil
            }

            private func markApplicationResponderResignIntent() {
                if softwareKeyboardDismissState == .systemResignPending {
                    softwareKeyboardDismissState = .applicationResignPending
                }
                deferredSystemSoftwareKeyboardDismissID = nil
            }

            func deferSystemSoftwareKeyboardDismissCallback() {
                nextSystemSoftwareKeyboardDismissID &+= 1
                let dismissID = nextSystemSoftwareKeyboardDismissID
                deferredSystemSoftwareKeyboardDismissID = dismissID
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          deferredSystemSoftwareKeyboardDismissID == dismissID else {
                        return
                    }
                    deferredSystemSoftwareKeyboardDismissID = nil
                    guard softwareKeyboardDismissState == .idle,
                          window != nil,
                          isActiveForSoftwareKeyboardDismissal,
                          !suppressesSoftwareKeyboard else {
                        return
                    }
                    onSystemSoftwareKeyboardDismiss?()
                }
            }
        #endif

        /// Intentionally resigns the terminal for a product-driven focus action.
        ///
        /// App code must use this API for taps, focus changes, and tab or pane
        /// deactivation. Bare `resignFirstResponder()` is reserved for UIKit/system
        /// behavior and deterministic tests that model native keyboard dismissal.
        @discardableResult
        public func resignFirstResponderForApplicationAction() -> Bool {
            #if !targetEnvironment(macCatalyst)
                markApplicationResponderResignIntent()
            #endif
            guard isFirstResponder else { return false }
            #if !targetEnvironment(macCatalyst)
                applicationResponderResignDepth += 1
                defer { applicationResponderResignDepth -= 1 }
            #endif
            return resignFirstResponder()
        }

        @objc func sceneWillDeactivate(_ notification: Notification) {
            invalidateSoftwareKeyboardOwnership(for: notification)
        }

        @objc func sceneDidEnterBackground(_ notification: Notification) {
            invalidateSoftwareKeyboardOwnership(for: notification)
        }

        private func invalidateSoftwareKeyboardOwnership(for notification: Notification) {
            #if !targetEnvironment(macCatalyst)
                guard
                    let scene = notification.object as? UIScene,
                    scene === window?.windowScene
                else { return }
                invalidateSoftwareKeyboardDismissTracking()
            #endif
        }

        @objc func applicationWillResignActive(_: Notification) {
            #if !targetEnvironment(macCatalyst)
                invalidateSoftwareKeyboardDismissTracking()
            #endif
        }

        @objc func applicationDidEnterBackground(_: Notification) {
            TerminalDebugLog.log(.lifecycle, "application did enter background")
            #if !targetEnvironment(macCatalyst)
                invalidateSoftwareKeyboardDismissTracking()
            #endif
            dismissTerminalEditMenus()
            stopMomentumScrolling(sendTerminalEndEvent: false)
            #if !targetEnvironment(macCatalyst)
                cancelTouchSelectionInteraction()
                clearTouchSelection()
            #endif
            core.setApplicationActive(false)
            #if DEBUG
                refreshSelectionDebugSnapshot()
            #endif
        }

        @objc func applicationDidBecomeActive(_: Notification) {
            TerminalDebugLog.log(.lifecycle, "application did become active")
            updateDisplayScale()
            updateColorScheme()
            core.setApplicationActive(true)
            #if DEBUG
                refreshSelectionDebugSnapshot()
            #endif
        }

        override open func willMove(toWindow newWindow: UIWindow?) {
            #if !targetEnvironment(macCatalyst)
                if newWindow == nil {
                    invalidateSoftwareKeyboardDismissTracking()
                    cancelDeferredSuppressedInputViewReload()
                }
            #endif
            super.willMove(toWindow: newWindow)
        }

        override open func didMoveToWindow() {
            super.didMoveToWindow()
            TerminalDebugLog.log(
                .lifecycle,
                "didMoveToWindow attached=\(window != nil)"
            )
            updateDisplayScale()
            if window != nil {
                core.rebuildIfReady()
                updateColorScheme()
                core.startDisplayLink()
                // Defer sublayer frame and metrics sync to the next runloop
                // so that AutoLayout has resolved final bounds.
                DispatchQueue.main.async { [weak self] in
                    guard let self, window != nil else { return }
                    updateSublayerFrames()
                    core.fitToSize()
                    #if DEBUG
                        refreshSelectionDebugSnapshot()
                    #endif
                }
                #if DEBUG
                    refreshSelectionDebugSnapshot()
                #endif
            } else {
                core.stopDisplayLink()
                dismissTerminalEditMenus()
                #if !targetEnvironment(macCatalyst)
                    invalidateSoftwareKeyboardDismissTracking()
                    cancelTouchSelectionInteraction()
                    dismissSelectionHandles()
                #endif
                core.freeSurface()
                #if DEBUG
                    refreshSelectionDebugSnapshot()
                #endif
            }
        }

        override open func layoutSubviews() {
            super.layoutSubviews()
            TerminalDebugLog.log(
                .metrics,
                "layoutSubviews bounds=\(NSCoder.string(for: bounds)) viewport=\(NSCoder.string(for: terminalViewportBounds))"
            )
            updateSublayerFrames()
            core.fitToSize()
            invalidateTerminalEditMenusForViewportChange()
            #if !targetEnvironment(macCatalyst)
                layoutSelectionHandles()
            #endif
            #if DEBUG
                refreshSelectionDebugSnapshot()
            #endif
        }

        var terminalViewportBounds: CGRect {
            #if !targetEnvironment(macCatalyst)
                let overlap = min(
                    max(currentKeyboardOverlapHeight(), currentInputAccessoryOverlapHeight()),
                    bounds.height
                )
                guard overlap > 0 else { return bounds }
                return CGRect(
                    x: bounds.minX,
                    y: bounds.minY,
                    width: bounds.width,
                    height: max(0, bounds.height - overlap)
                )
            #else
                return bounds
            #endif
        }

        #if !targetEnvironment(macCatalyst)
            func keyboardScreenFrame(from notification: Notification) -> CGRect? {
                notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
            }

            func currentKeyboardOverlapHeight() -> CGFloat {
                guard isFirstResponder, let keyboardFrameEndScreenRect else { return 0 }
                return viewportOverlapHeight(withScreenRect: keyboardFrameEndScreenRect)
            }

            func currentInputAccessoryOverlapHeight() -> CGFloat {
                guard isFirstResponder,
                      usesSystemInputAccessory,
                      !inputAccessoryItems.isEmpty,
                      let accessoryWindow = terminalInputAccessory.window
                else {
                    return 0
                }
                let accessoryRectInWindow = terminalInputAccessory.convert(
                    terminalInputAccessory.bounds,
                    to: accessoryWindow
                )
                let accessoryRectInScreen = accessoryWindow.convert(
                    accessoryRectInWindow,
                    to: accessoryWindow.screen.coordinateSpace
                )
                return viewportOverlapHeight(withScreenRect: accessoryRectInScreen)
            }

            private func viewportOverlapHeight(withScreenRect screenRect: CGRect) -> CGFloat {
                guard let window else { return 0 }
                let boundsInWindow = convert(bounds, to: window)
                let boundsInScreen = window.convert(
                    boundsInWindow,
                    to: window.screen.coordinateSpace
                )
                let overlap = boundsInScreen.intersection(screenRect)
                guard !overlap.isNull, !overlap.isEmpty else { return 0 }
                return min(max(0, overlap.height), bounds.height)
            }
        #endif

        func refitViewportForKeyboardChange(reason: String) {
            invalidateTerminalEditMenusForViewportChange()
            TerminalDebugLog.log(
                .metrics,
                "viewport refit reason=\(reason) bounds=\(NSCoder.string(for: bounds)) viewport=\(NSCoder.string(for: terminalViewportBounds))"
            )
            updateSublayerFrames()
            core.fitToSize()
            refreshTextInputGeometry(reason: reason)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                updateSublayerFrames()
                core.fitToSize()
                refreshTextInputGeometry(reason: "\(reason)-deferred")
            }
        }

        func resolvedDisplayScale() -> CGFloat {
            if let screen = window?.screen {
                return screen.nativeScale
            }
            if traitCollection.displayScale > 0 {
                return traitCollection.displayScale
            }
            return UIScreen.main.nativeScale
        }

        func updateDisplayScale() {
            let scale = resolvedDisplayScale()
            TerminalDebugLog.log(
                .metrics,
                "updateDisplayScale scale=\(String(format: "%.2f", scale))"
            )
            contentScaleFactor = scale
            layer.contentsScale = scale
            updateSublayerFrames()
        }

        /// Ghostty installs its renderer layers directly under the terminal's
        /// root layer. UIKit also inserts every direct subview's backing layer
        /// there, so resizing all sublayers would stretch handles and the loupe
        /// to the full viewport.
        private var terminalRendererSublayers: [CALayer] {
            guard let sublayers = layer.sublayers else { return [] }
            return sublayers.filter { candidate in
                !subviews.contains { $0.layer === candidate }
            }
        }

        func updateSublayerFrames() {
            let scale = resolvedDisplayScale()
            let frame = terminalViewportBounds
            contentScaleFactor = scale
            layer.contentsScale = scale
            for sublayer in terminalRendererSublayers {
                sublayer.frame = frame
                sublayer.contentsScale = scale
            }
        }

        func enforceSublayerScale() {
            let scale = resolvedDisplayScale()
            let frame = terminalViewportBounds
            for sublayer in terminalRendererSublayers {
                if sublayer.contentsScale != scale {
                    sublayer.contentsScale = scale
                }
                if sublayer.frame != frame {
                    sublayer.frame = frame
                }
            }
        }

        public func fitToSize() {
            core.fitToSize()
        }

        override open func traitCollectionDidChange(
            _ previousTraitCollection: UITraitCollection?
        ) {
            super.traitCollectionDidChange(previousTraitCollection)
            updateDisplayScale()
            if traitCollection.hasDifferentColorAppearance(
                comparedTo: previousTraitCollection
            ) {
                updateColorScheme()
            }
        }

        func updateColorScheme() {
            let style = traitCollection.userInterfaceStyle
            let scheme: TerminalColorScheme = style == .dark ? .dark : .light
            TerminalDebugLog.log(.lifecycle, "updateColorScheme scheme=\(scheme)")
            surface?.setColorScheme(scheme.ghosttyValue)
            if let controller,
               let viewState = delegate as? TerminalViewState,
               viewState.controller === controller
            {
                viewState.adopt(terminalColorScheme: scheme)
            } else {
                controller?.setColorScheme(scheme)
            }
        }

        @discardableResult
        override open func becomeFirstResponder() -> Bool {
            let result = super.becomeFirstResponder()
            guard result else { return false }
            core.setFocus(true)
            onFocusChange?(true)
            #if !targetEnvironment(macCatalyst)
                refreshInputAccessoryViewport()
            #endif
            return result
        }

        @discardableResult
        override open func resignFirstResponder() -> Bool {
            dismissTerminalEditMenus()
            #if !targetEnvironment(macCatalyst)
                let dismissStateBeforeResign = softwareKeyboardDismissState
                if applicationResponderResignDepth > 0 {
                    switch softwareKeyboardDismissState {
                    case .fullPresentation, .systemResignPending:
                        softwareKeyboardDismissState = .applicationResignPending
                    case .idle, .applicationResignPending:
                        break
                    }
                } else if softwareKeyboardDismissState == .fullPresentation {
                    softwareKeyboardDismissState = .systemResignPending
                }
                let dismissStateAfterTransition = softwareKeyboardDismissState
                isResigningFirstResponder = true
            #endif
            let result = super.resignFirstResponder()
            #if !targetEnvironment(macCatalyst)
                isResigningFirstResponder = false
            #endif
            core.setFocus(false)
            onFocusChange?(false)
            #if !targetEnvironment(macCatalyst)
                if !result, softwareKeyboardDismissState == dismissStateAfterTransition {
                    softwareKeyboardDismissState = dismissStateBeforeResign
                } else if result {
                    cancelDeferredSuppressedInputViewReload()
                }
                keyboardFrameEndScreenRect = nil
                refitViewportForKeyboardChange(reason: "resign-first-responder")
            #endif
            return result
        }
    }
#endif
