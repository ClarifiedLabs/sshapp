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

        @objc func applicationDidEnterBackground(_: Notification) {
            TerminalDebugLog.log(.lifecycle, "application did enter background")
            stopMomentumScrolling(sendTerminalEndEvent: false)
            core.setApplicationActive(false)
        }

        @objc func applicationDidBecomeActive(_: Notification) {
            TerminalDebugLog.log(.lifecycle, "application did become active")
            updateDisplayScale()
            updateColorScheme()
            core.setApplicationActive(true)
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
                }
            } else {
                core.stopDisplayLink()
                core.freeSurface()
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

        func updateSublayerFrames() {
            let scale = resolvedDisplayScale()
            let frame = terminalViewportBounds
            contentScaleFactor = scale
            layer.contentsScale = scale
            guard let sublayers = layer.sublayers else { return }
            for sublayer in sublayers {
                sublayer.frame = frame
                sublayer.contentsScale = scale
            }
        }

        func enforceSublayerScale() {
            let scale = resolvedDisplayScale()
            let frame = terminalViewportBounds
            guard let sublayers = layer.sublayers else { return }
            for sublayer in sublayers {
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
            core.setFocus(true)
            onFocusChange?(true)
            #if !targetEnvironment(macCatalyst)
                if result {
                    refreshInputAccessoryViewport()
                }
            #endif
            return result
        }

        @discardableResult
        override open func resignFirstResponder() -> Bool {
            let result = super.resignFirstResponder()
            core.setFocus(false)
            onFocusChange?(false)
            #if !targetEnvironment(macCatalyst)
                keyboardFrameEndScreenRect = nil
                refitViewportForKeyboardChange(reason: "resign-first-responder")
            #endif
            return result
        }
    }
#endif
