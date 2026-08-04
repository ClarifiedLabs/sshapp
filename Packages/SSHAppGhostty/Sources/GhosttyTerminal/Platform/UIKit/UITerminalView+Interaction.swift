//
//  UITerminalView+Interaction.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/17.
//

#if canImport(UIKit)
    import GhosttyKit
    import UIKit

    extension UITerminalView {
        override open func touchesBegan(
            _ touches: Set<UITouch>,
            with event: UIEvent?
        ) {
            if handleIndirectPointerTouches(touches, phase: .began, event: event) {
                return
            }
            super.touchesBegan(touches, with: event)
            #if targetEnvironment(macCatalyst)
                becomeFirstResponder()
            #else
                pendingKeyboardDismissOnTouchEnd = false
                touchDidScrollDuringCurrentTouch = false
                if suppressesSoftwareKeyboard {
                    becomeFirstResponder()
                } else if softwareKeyboardVisible {
                    pendingKeyboardDismissOnTouchEnd = true
                } else {
                    becomeFirstResponder()
                }
            #endif
        }

        override open func touchesMoved(
            _ touches: Set<UITouch>,
            with event: UIEvent?
        ) {
            if handleIndirectPointerTouches(touches, phase: .moved, event: event) {
                return
            }
            super.touchesMoved(touches, with: event)
        }

        override open func touchesEnded(
            _ touches: Set<UITouch>,
            with event: UIEvent?
        ) {
            if handleIndirectPointerTouches(touches, phase: .ended, event: event) {
                return
            }
            #if !targetEnvironment(macCatalyst)
                if touchSelectionIsMouseCaptured {
                    cancelTouchSelectionInteraction()
                }
                if !suppressesSoftwareKeyboard,
                   pendingKeyboardDismissOnTouchEnd,
                   !touchDidScrollDuringCurrentTouch
                {
                    resignFirstResponderForApplicationAction()
                }
                pendingKeyboardDismissOnTouchEnd = false
                touchDidScrollDuringCurrentTouch = false
            #endif
            super.touchesEnded(touches, with: event)
        }

        override open func touchesCancelled(
            _ touches: Set<UITouch>,
            with event: UIEvent?
        ) {
            if handleIndirectPointerTouches(touches, phase: .cancelled, event: event) {
                return
            }
            #if !targetEnvironment(macCatalyst)
                if touchSelectionIsMouseCaptured {
                    cancelTouchSelectionInteraction()
                }
                pendingKeyboardDismissOnTouchEnd = false
                touchDidScrollDuringCurrentTouch = false
            #endif
            super.touchesCancelled(touches, with: event)
        }

        func setupPlatformInput() {
            addInteraction(selectionContextMenuInteraction)
            addInteraction(selectionEditMenuInteraction)
            addInteraction(terminalInputEditMenuInteraction)
            #if targetEnvironment(macCatalyst)
                setupCatalystScrollWheelInput()
            #else
                setupTouchScrollInput()
            #endif
        }

        enum IndirectPointerPhase {
            case began
            case moved
            case ended
            case cancelled
        }

        func handleIndirectPointerTouches(
            _ touches: Set<UITouch>,
            phase: IndirectPointerPhase,
            event: UIEvent?
        ) -> Bool {
            let hasIndirectPointerTouch = touches.contains { $0.type == .indirectPointer }

            #if !targetEnvironment(macCatalyst)
                if suppressNextIndirectPointerTouchEnd, hasIndirectPointerTouch {
                    if phase == .ended || phase == .cancelled {
                        suppressNextIndirectPointerTouchEnd = false
                        return true
                    }
                    suppressNextIndirectPointerTouchEnd = false
                }

                if indirectPointerPanOwnsTouchSequence, hasIndirectPointerTouch {
                    if phase == .began {
                        indirectPointerPanOwnsTouchSequence = false
                    } else {
                        return true
                    }
                }
            #endif

            guard hasIndirectPointerTouch,
                  let touch = touches.first(where: { $0.type == .indirectPointer })
            else {
                return false
            }
            #if DEBUG
                defer { refreshSelectionDebugSnapshot() }
            #endif

            core.setFocus(true)
            #if targetEnvironment(macCatalyst)
                if phase == .began {
                    becomeFirstResponder()
                }
            #endif
            stopMomentumScrolling()

            let button = pointerButton(from: event)
            let mods = ghostty_input_mods_e(rawValue: 0)
            let location = touch.location(in: self)
            let suppressSurfacePositionForSelectionMenu =
                button == GHOSTTY_MOUSE_RIGHT &&
                (pendingSelectionMenuPoint != nil || pointIsInsidePointerSelection(location))
            TerminalDebugLog.log(
                .input,
                "pointer touch phase=\(phase) type=\(touch.type.rawValue) button=\(button.rawValue) location=\(NSCoder.string(for: location)) mask=\(event?.buttonMask.rawValue ?? 0)"
            )
            if !suppressSurfacePositionForSelectionMenu {
                surface?.sendMousePos(
                    x: location.x,
                    y: location.y,
                    mods: mods
                )
            }

            switch phase {
            case .began:
                activePointerButton = button
                switch button {
                case GHOSTTY_MOUSE_LEFT:
                    #if !targetEnvironment(macCatalyst)
                        dismissSelectionHandles()
                    #endif
                    pointerSelectionStartPoint = location
                    pendingSelectionMenuPoint = nil
                    surface?.sendMouseButton(
                        state: GHOSTTY_MOUSE_PRESS,
                        button: button,
                        mods: mods
                    )

                case GHOSTTY_MOUSE_RIGHT:
                    if pointIsInsidePointerSelection(location) {
                        pendingSelectionMenuPoint = location
                    } else {
                        pendingSelectionMenuPoint = selectionMenuPoint(at: location)
                    }

                default:
                    surface?.sendMouseButton(
                        state: GHOSTTY_MOUSE_PRESS,
                        button: button,
                        mods: mods
                    )
                }

            case .moved:
                updatePointerSelectionRect(to: location)

            case .ended:
                let releasedButton = activePointerButton ?? button
                activePointerButton = nil

                if releasedButton == GHOSTTY_MOUSE_RIGHT,
                   pendingSelectionMenuPoint != nil
                {
                    if selectionMenuPoint(at: location) != nil {
                        showSelectionCopyMenu(at: location)
                    }
                    pendingSelectionMenuPoint = nil
                    return true
                }

                if releasedButton == GHOSTTY_MOUSE_RIGHT {
                    surface?.sendMouseButton(
                        state: GHOSTTY_MOUSE_PRESS,
                        button: releasedButton,
                        mods: mods
                    )
                }

                surface?.sendMouseButton(
                    state: GHOSTTY_MOUSE_RELEASE,
                    button: releasedButton,
                    mods: mods
                )

                if releasedButton == GHOSTTY_MOUSE_LEFT {
                    finishPointerSelection(at: location)
                }
                pendingSelectionMenuPoint = nil

            case .cancelled:
                let releasedButton = activePointerButton ?? button
                activePointerButton = nil
                pendingSelectionMenuPoint = nil
                pointerSelectionStartPoint = nil
                surface?.sendMouseButton(
                    state: GHOSTTY_MOUSE_RELEASE,
                    button: releasedButton,
                    mods: mods
                )
            }

            return true
        }

        func pointerButton(from event: UIEvent?) -> ghostty_input_mouse_button_e {
            guard let event else { return GHOSTTY_MOUSE_LEFT }
            if event.buttonMask.contains(.secondary) {
                return GHOSTTY_MOUSE_RIGHT
            }
            if event.buttonMask.contains(.primary) {
                return GHOSTTY_MOUSE_LEFT
            }
            return GHOSTTY_MOUSE_LEFT
        }

        func updatePointerSelectionRect(to point: CGPoint) {
            guard activePointerButton == GHOSTTY_MOUSE_LEFT,
                  let start = pointerSelectionStartPoint
            else { return }

            lastPointerSelectionRect = CGRect(
                x: min(start.x, point.x),
                y: min(start.y, point.y),
                width: abs(start.x - point.x),
                height: abs(start.y - point.y)
            ).insetBy(dx: -2, dy: -2)
            logPointerSelectionDiagnostics(
                context: "updatePointerSelectionRect",
                point: point
            )
        }

        func finishPointerSelection(at point: CGPoint) {
            defer { pointerSelectionStartPoint = nil }
            guard let start = pointerSelectionStartPoint else { return }
            let dragDistance = hypot(point.x - start.x, point.y - start.y)
            if dragDistance < 2 {
                lastPointerSelectionRect = nil
            } else {
                updatePointerSelectionRect(to: point)
            }
            logPointerSelectionDiagnostics(
                context: "finishPointerSelection",
                point: point
            )
        }

        func logPointerSelectionDiagnostics(context: String, point: CGPoint) {
            guard TerminalDebugLog.isEnabled,
                  TerminalDebugLog.categories.contains(.input)
            else { return }

            let rectDescription = lastPointerSelectionRect.map {
                NSCoder.string(for: $0)
            } ?? "nil"
            let metricsDescription = surface?.size().map(\.debugSummary) ?? "nil"
            let selection = surface?.readSelectionResult()
            let selectionDescription = selection.map {
                "text=\(TerminalDebugLog.describe($0.text)) offset=\($0.offsetStart)+\($0.offsetLength)"
            } ?? "nil"
            let word = surface?.quicklookWord()
            let wordDescription = word.map {
                "word=\(TerminalDebugLog.describe($0.word)) offset=\($0.offsetStart)+\($0.offsetLength) point=\(String(format: "%.2f", $0.pointX))x\(String(format: "%.2f", $0.pointY))"
            } ?? "nil"
            TerminalDebugLog.log(
                .input,
                "pointer selection \(context) viewBounds=\(NSCoder.string(for: bounds)) point=\(NSCoder.string(for: point)) rect=\(rectDescription) metrics=\(metricsDescription) selection=\(selectionDescription) quicklook=\(wordDescription)"
            )
        }

        @IBAction override open func copy(_: Any?) {
            guard copySelectedTextToPasteboard() else { return }
        }

        @IBAction override open func paste(_: Any?) {
            pasteFromPasteboard()
        }

        @discardableResult
        func pasteFromPasteboard() -> Bool {
            guard let text = UIPasteboard.general.string, !text.isEmpty else {
                return false
            }
            insertText(text)
            return true
        }

        override open func canPerformAction(
            _ action: Selector,
            withSender sender: Any?
        ) -> Bool {
            if action == #selector(copy(_:)) {
                return surface?.hasSelection() == true
            }
            if action == #selector(paste(_:)) {
                return UIPasteboard.general.hasStrings
            }
            return super.canPerformAction(action, withSender: sender)
        }

        func pointIsInsidePointerSelection(_ point: CGPoint) -> Bool {
            lastPointerSelectionRect.map {
                $0.insetBy(dx: -4, dy: -4).contains(point)
            } ?? false
        }

        #if targetEnvironment(macCatalyst)
            func setupCatalystScrollWheelInput() {
                let gesture = UIPanGestureRecognizer(
                    target: self,
                    action: #selector(handleCatalystScrollWheelGesture(_:))
                )
                gesture.allowedScrollTypesMask = [.continuous, .discrete]
                gesture.cancelsTouchesInView = false
                gesture.delaysTouchesBegan = false
                gesture.delaysTouchesEnded = false
                addGestureRecognizer(gesture)
            }

            @objc func handleCatalystScrollWheelGesture(
                _ gesture: UIPanGestureRecognizer
            ) {
                guard activePointerButton == nil else { return }
                if gesture.state == .began {
                    dismissTerminalEditMenus()
                }

                let translation = gesture.translation(in: self)
                gesture.setTranslation(.zero, in: self)
                TerminalDebugLog.log(
                    .input,
                    "catalyst scroll translation=\(String(format: "%.2f", translation.x))x\(String(format: "%.2f", translation.y))"
                )

                let scrollMods = TerminalScrollModifiers(precision: true)
                surface?.sendMouseScroll(
                    x: Double(translation.x),
                    y: Double(translation.y),
                    mods: scrollMods.rawValue
                )
            }
        #else
            static let defaultTouchSelectionLongPressMinimumDuration: TimeInterval = 0.5

            func setupTouchScrollInput() {
                let gesture = UIPanGestureRecognizer(
                    target: self,
                    action: #selector(handleTouchScrollGesture(_:))
                )
                gesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
                gesture.maximumNumberOfTouches = 1
                gesture.delegate = self
                addGestureRecognizer(gesture)
                touchScrollPanGesture = gesture

                setupIndirectPointerScrollInput()

                let longPress = UILongPressGestureRecognizer(
                    target: self,
                    action: #selector(handleLongPressForSelection(_:))
                )
                longPress.minimumPressDuration = Self.defaultTouchSelectionLongPressMinimumDuration
                longPress.allowableMovement = 10
                longPress.numberOfTouchesRequired = 1
                longPress.numberOfTapsRequired = 0
                longPress.allowedTouchTypes = [
                    NSNumber(value: UITouch.TouchType.direct.rawValue),
                    NSNumber(value: UITouch.TouchType.pencil.rawValue),
                ]
                longPress.cancelsTouchesInView = false
                longPress.delegate = self
                addGestureRecognizer(longPress)
                touchSelectionLongPressGesture = longPress

                let terminalTap = UITapGestureRecognizer(
                    target: self,
                    action: #selector(handleTerminalTap(_:))
                )
                terminalTap.allowedTouchTypes = [
                    NSNumber(value: UITouch.TouchType.direct.rawValue),
                    NSNumber(value: UITouch.TouchType.pencil.rawValue),
                ]
                terminalTap.cancelsTouchesInView = true
                terminalTap.delegate = self
                terminalTap.require(toFail: gesture)
                terminalTap.require(toFail: longPress)
                addGestureRecognizer(terminalTap)
                terminalTapGesture = terminalTap
                setupSelectionHandles()

                setupIndirectPointerSelectionGesture()
                setupPinchZoomGesture()
            }

            func setupIndirectPointerScrollInput() {
                let gesture = UIPanGestureRecognizer(
                    target: self,
                    action: #selector(handleIndirectPointerScrollGesture(_:))
                )
                gesture.allowedScrollTypesMask = [.continuous, .discrete]
                gesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
                gesture.minimumNumberOfTouches = 0
                gesture.maximumNumberOfTouches = 0
                gesture.cancelsTouchesInView = false
                gesture.delaysTouchesBegan = false
                gesture.delaysTouchesEnded = false
                addGestureRecognizer(gesture)
            }

            func setupIndirectPointerSelectionGesture() {
                let gesture = UIPanGestureRecognizer(
                    target: self,
                    action: #selector(handleIndirectPointerSelectionGesture(_:))
                )
                gesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
                gesture.minimumNumberOfTouches = 1
                gesture.maximumNumberOfTouches = 1
                gesture.cancelsTouchesInView = false
                gesture.delaysTouchesBegan = false
                gesture.delaysTouchesEnded = false
                addGestureRecognizer(gesture)
            }

            @objc func handleIndirectPointerScrollGesture(
                _ gesture: UIPanGestureRecognizer
            ) {
                guard activePointerButton == nil else { return }
                guard gesture.numberOfTouches == 0 else { return }

                switch gesture.state {
                case .began:
                    dismissTerminalEditMenus()
                    dismissSelectionHandles()
                    core.setFocus(true)
                    stopMomentumScrolling()
                    sendIndirectPointerScrollDelta(from: gesture)

                case .changed:
                    sendIndirectPointerScrollDelta(from: gesture)

                case .ended, .cancelled, .failed:
                    TerminalDebugLog.log(
                        .input,
                        "indirect pointer scroll ended state=\(gesture.state.rawValue)"
                    )

                default:
                    break
                }
            }

            func sendIndirectPointerScrollDelta(from gesture: UIPanGestureRecognizer) {
                let translation = gesture.translation(in: self)
                gesture.setTranslation(.zero, in: self)

                guard translation != .zero else { return }

                TerminalDebugLog.log(
                    .input,
                    "indirect pointer scroll translation=\(String(format: "%.2f", translation.x))x\(String(format: "%.2f", translation.y))"
                )

                let scrollMods = TerminalScrollModifiers(precision: true)
                surface?.sendMouseScroll(
                    x: Double(translation.x),
                    y: Double(translation.y),
                    mods: scrollMods.rawValue
                )
            }

            @objc func handleIndirectPointerSelectionGesture(
                _ gesture: UIPanGestureRecognizer
            ) {
                #if DEBUG
                    defer { refreshSelectionDebugSnapshot() }
                #endif
                let location = gesture.location(in: self)
                let mods = ghostty_input_mods_e(rawValue: 0)
                TerminalDebugLog.log(
                    .input,
                    "indirect pointer gesture state=\(gesture.state.rawValue) location=\(NSCoder.string(for: location)) translation=\(NSCoder.string(for: gesture.translation(in: self)))"
                )

                switch gesture.state {
                case .began:
                    dismissSelectionHandles()
                    core.setFocus(true)
                    stopMomentumScrolling()
                    indirectPointerPanOwnsTouchSequence = true
                    if activePointerButton != GHOSTTY_MOUSE_LEFT {
                        activePointerButton = GHOSTTY_MOUSE_LEFT
                        surface?.sendMouseButton(
                            state: GHOSTTY_MOUSE_PRESS,
                            button: GHOSTTY_MOUSE_LEFT,
                            mods: mods
                        )
                    }
                    if pointerSelectionStartPoint == nil {
                        pointerSelectionStartPoint = location
                    }
                    pendingSelectionMenuPoint = nil
                    surface?.sendMousePos(x: location.x, y: location.y, mods: mods)

                case .changed:
                    updatePointerSelectionRect(to: location)
                    surface?.sendMousePos(x: location.x, y: location.y, mods: mods)

                case .ended:
                    activePointerButton = nil
                    updatePointerSelectionRect(to: location)
                    surface?.sendMousePos(x: location.x, y: location.y, mods: mods)
                    surface?.sendMouseButton(
                        state: GHOSTTY_MOUSE_RELEASE,
                        button: GHOSTTY_MOUSE_LEFT,
                        mods: mods
                    )
                    finishPointerSelection(at: location)
                    indirectPointerPanOwnsTouchSequence = false
                    suppressNextIndirectPointerTouchEnd = true

                case .cancelled, .failed:
                    activePointerButton = nil
                    indirectPointerPanOwnsTouchSequence = false
                    suppressNextIndirectPointerTouchEnd = true
                    pointerSelectionStartPoint = nil
                    pendingSelectionMenuPoint = nil
                    lastPointerSelectionRect = nil
                    surface?.sendMouseButton(
                        state: GHOSTTY_MOUSE_RELEASE,
                        button: GHOSTTY_MOUSE_LEFT,
                        mods: mods
                    )

                default:
                    break
                }
            }

            @objc func handleLongPressForSelection(
                _ gesture: UILongPressGestureRecognizer
            ) {
                #if DEBUG
                    defer { refreshSelectionDebugSnapshot() }
                #endif
                let location = gesture.location(in: self)
                let mods = ghostty_input_mods_e(rawValue: 0)

                switch gesture.state {
                case .began:
                    guard let surface else { return }
                    dismissSelectionHandles()
                    core.setFocus(true)
                    stopMomentumScrolling()
                    activePointerButton = GHOSTTY_MOUSE_LEFT
                    pointerSelectionStartPoint = location
                    pendingSelectionMenuPoint = nil
                    lastPointerSelectionRect = nil
                    touchSelectionIsMouseCaptured = surface.isMouseCaptured

                    if touchSelectionIsMouseCaptured {
                        // Mouse-reporting apps own the entire gesture. Never
                        // consult stale host-selection state or install host
                        // handles/menu when this sequence ends.
                        surface.sendMousePos(x: location.x, y: location.y, mods: mods)
                        surface.sendMouseButton(
                            state: GHOSTTY_MOUSE_PRESS,
                            button: GHOSTTY_MOUSE_LEFT,
                            mods: mods
                        )
                        syntheticLeftButtonDown = true
                        return
                    }

                    touchSelectionAnchorPoint = location
                    touchSelectionActiveEndPoint = location
                    touchSelectionAnchorMousePoint = location
                    touchSelectionActiveEndMousePoint = location
                    // Synthesize Ghostty's double-click at the touch point:
                    // the second press becomes a word-granularity selection,
                    // and keeping it held arms word-wise drag expansion
                    // (wrapped rows included). Primer clicks first reset the
                    // multi-click counter so the pair is always press 1 + 2.
                    resetSyntheticClickCount(relativeTo: location)
                    surface.sendMousePos(x: location.x, y: location.y, mods: mods)
                    surface.sendMouseButton(
                        state: GHOSTTY_MOUSE_PRESS,
                        button: GHOSTTY_MOUSE_LEFT,
                        mods: mods
                    )
                    surface.sendMouseButton(
                        state: GHOSTTY_MOUSE_RELEASE,
                        button: GHOSTTY_MOUSE_LEFT,
                        mods: mods
                    )
                    surface.sendMouseButton(
                        state: GHOSTTY_MOUSE_PRESS,
                        button: GHOSTTY_MOUSE_LEFT,
                        mods: mods
                    )
                    syntheticLeftButtonDown = true
                    refreshTouchSelectionGridOrigin()
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    showSelectionMagnifier(at: location)

                case .changed:
                    guard activePointerButton == GHOSTTY_MOUSE_LEFT,
                          syntheticLeftButtonDown
                    else { return }
                    guard let surface else {
                        cancelTouchSelectionInteraction()
                        return
                    }
                    if !touchSelectionIsMouseCaptured && surface.isMouseCaptured {
                        cancelTouchSelectionInteraction()
                        dismissSelectionHandles()
                        return
                    }
                    if touchSelectionIsMouseCaptured {
                        surface.sendMousePos(x: location.x, y: location.y, mods: mods)
                        return
                    }
                    touchSelectionActiveEndPoint = location
                    touchSelectionActiveEndMousePoint = location
                    updatePointerSelectionRect(to: location)
                    // Clamp X but deliberately let Y leave the viewport so
                    // Ghostty's held-button selection autoscroll can engage.
                    surface.sendMousePos(
                        x: min(max(location.x, 0), bounds.width),
                        y: location.y,
                        mods: mods
                    )
                    showSelectionMagnifier(at: location)

                case .ended:
                    guard activePointerButton == GHOSTTY_MOUSE_LEFT else { return }
                    guard let surface else {
                        cancelTouchSelectionInteraction()
                        return
                    }
                    if touchSelectionIsMouseCaptured {
                        // UIKit can deliver the recognizer's terminal state
                        // before the view's direct-touch callback. Preserve
                        // capture ownership and the held button so touchesEnded
                        // authoritatively emits exactly one remote release.
                        return
                    }
                    if surface.isMouseCaptured {
                        cancelTouchSelectionInteraction()
                        dismissSelectionHandles()
                        return
                    }

                    touchSelectionActiveEndPoint = location
                    touchSelectionActiveEndMousePoint = location
                    updatePointerSelectionRect(to: location)
                    surface.sendMousePos(
                        x: min(max(location.x, 0), bounds.width),
                        y: location.y,
                        mods: mods
                    )
                    hideSelectionMagnifier()
                    releaseSyntheticSelectionButton()
                    finishPointerSelection(at: location)
                    activePointerButton = nil
                    touchSelectionIsMouseCaptured = false

                    if surface.readSelection()?.isEmpty == false {
                        installSelectionHandlesAfterTouchSelection()
                        if selectionHandlesVisible {
                            presentTouchSelectionEditMenu(at: selectionHandlesMenuPoint())
                        }
                    } else {
                        dismissSelectionHandles()
                    }

                case .cancelled, .failed:
                    cancelTouchSelectionInteraction()

                default:
                    break
                }
            }

            /// Establishes deterministic single-click state before a synthetic
            /// selection press. Ghostty ignores off-grid presses before updating
            /// its click counter, so both primer clicks must target real cells.
            /// The second primer is far from both the first and the upcoming
            /// target, making it click number one and making the target the next
            /// click number one as well.
            func resetSyntheticClickCount(
                relativeTo target: CGPoint,
                mods: ghostty_input_mods_e = ghostty_input_mods_e(rawValue: 0)
            ) {
                guard let surface,
                      let metrics = touchSelectionGridMetrics ?? surface.size(),
                      let geometry = touchSelectionGridGeometry(for: metrics)
                else { return }

                let firstColumn = geometry.origin.x + geometry.cellWidth / 2
                let lastColumn = geometry.origin.x
                    + (CGFloat(metrics.columns) - 0.5) * geometry.cellWidth
                let firstRow = geometry.origin.y + geometry.cellHeight / 2
                let lastRow = geometry.origin.y
                    + (CGFloat(metrics.rows) - 0.5) * geometry.cellHeight
                let corners = [
                    CGPoint(x: firstColumn, y: firstRow),
                    CGPoint(x: lastColumn, y: firstRow),
                    CGPoint(x: firstColumn, y: lastRow),
                    CGPoint(x: lastColumn, y: lastRow),
                ]
                guard let finalPrimer = corners.max(by: {
                    hypot($0.x - target.x, $0.y - target.y)
                        < hypot($1.x - target.x, $1.y - target.y)
                }), let firstPrimer = corners.max(by: {
                    hypot($0.x - finalPrimer.x, $0.y - finalPrimer.y)
                        < hypot($1.x - finalPrimer.x, $1.y - finalPrimer.y)
                }) else { return }

                for point in [firstPrimer, finalPrimer] {
                    surface.sendMousePos(x: point.x, y: point.y, mods: mods)
                    surface.sendMouseButton(
                        state: GHOSTTY_MOUSE_PRESS,
                        button: GHOSTTY_MOUSE_LEFT,
                        mods: mods
                    )
                    surface.sendMouseButton(
                        state: GHOSTTY_MOUSE_RELEASE,
                        button: GHOSTTY_MOUSE_LEFT,
                        mods: mods
                    )
                }
            }

            /// Releases the synthetic left button if a touch-selection
            /// gesture is currently holding it.
            func releaseSyntheticSelectionButton() {
                guard syntheticLeftButtonDown else { return }
                // If capture activated after this host gesture began, Shift
                // bypasses terminal mouse reporting while still clearing
                // Ghostty's native held-button state. Gestures that began under
                // capture retain their ordinary remote release.
                let mods = !touchSelectionIsMouseCaptured && surface?.isMouseCaptured == true
                    ? TerminalInputModifiers.shift.ghosttyMods
                    : ghostty_input_mods_e(rawValue: 0)
                surface?.sendMouseButton(
                    state: GHOSTTY_MOUSE_RELEASE,
                    button: GHOSTTY_MOUSE_LEFT,
                    mods: mods
                )
                syntheticLeftButtonDown = false
            }

            /// Clears every transient touch-selection field even if the
            /// Ghostty surface disappeared mid-gesture. This prevents a stale
            /// synthetic-button flag from permanently blocking scroll/pinch.
            func cancelTouchSelectionInteraction() {
                #if DEBUG
                    defer { refreshSelectionDebugSnapshot() }
                #endif
                let captureInterruptedHostGesture = syntheticLeftButtonDown
                    && !touchSelectionIsMouseCaptured
                    && surface?.isMouseCaptured == true
                let cleanupReference = touchSelectionActiveEndMousePoint
                    ?? touchSelectionAnchorMousePoint
                    ?? pointerSelectionStartPoint
                    ?? CGPoint(x: bounds.midX, y: bounds.midY)

                hideSelectionMagnifier()
                releaseSyntheticSelectionButton()
                if captureInterruptedHostGesture {
                    // The Shift release preserves the old host selection. Follow
                    // it with valid-cell primer clicks under the same reporting
                    // override to clear that native range without remote output.
                    resetSyntheticClickCount(
                        relativeTo: cleanupReference,
                        mods: TerminalInputModifiers.shift.ghosttyMods
                    )
                }
                activePointerButton = nil
                pointerSelectionStartPoint = nil
                pendingSelectionMenuPoint = nil
                lastPointerSelectionRect = nil
                touchSelectionAnchorPoint = nil
                touchSelectionActiveEndPoint = nil
                touchSelectionAnchorMousePoint = nil
                touchSelectionActiveEndMousePoint = nil
                touchSelectionGridOrigin = nil
                touchSelectionGridMetrics = nil
                touchSelectionGridScale = nil
                touchSelectionIsMouseCaptured = false
                selectionHandleMode = .none
            }

            /// A terminal tap has exactly one intent, captured at touch-down.
            /// A selection-clearing tap must never continue into cursor Paste.
            @objc func handleTerminalTap(_ gesture: UITapGestureRecognizer) {
                guard gesture.state == .ended else { return }
                defer {
                    terminalTapBeganWithHostSelection = false
                    terminalTapInitiatingPoint = nil
                }
                guard surface?.isMouseCaptured != true else { return }

                if terminalTapBeganWithHostSelection {
                    clearTouchSelection()
                    pointerSelectionStartPoint = nil
                    pendingSelectionMenuPoint = nil
                    lastPointerSelectionRect = nil
                    return
                }

                guard let initiatingPoint = terminalTapInitiatingPoint else { return }
                presentTerminalInputEditMenu(at: initiatingPoint)
            }
        #endif

        @objc func handleTouchScrollGesture(
            _ gesture: UIPanGestureRecognizer
        ) {
            switch gesture.state {
            case .began:
                guard activePointerButton == nil else { return }
                dismissTerminalEditMenus()
                #if !targetEnvironment(macCatalyst)
                    dismissSelectionHandles()
                    touchDidScrollDuringCurrentTouch = true
                #endif
                TerminalDebugLog.log(.input, "touch scroll began")
                stopMomentumScrolling()

            case .changed:
                guard activePointerButton == nil else { return }
                let translation = gesture.translation(in: self)
                gesture.setTranslation(.zero, in: self)
                TerminalDebugLog.log(
                    .input,
                    "touch scroll changed translation=\(String(format: "%.2f", translation.x))x\(String(format: "%.2f", translation.y))"
                )

                let scrollMods = TerminalScrollModifiers(precision: true)
                surface?.sendMouseScroll(
                    x: Double(translation.x * touchScrollMultiplier),
                    y: Double(translation.y * touchScrollMultiplier),
                    mods: scrollMods.rawValue
                )

            case .ended:
                guard activePointerButton == nil else { return }
                let velocity = gesture.velocity(in: self)
                TerminalDebugLog.log(
                    .input,
                    "touch scroll ended velocity=\(String(format: "%.2f", velocity.x))x\(String(format: "%.2f", velocity.y))"
                )
                startMomentumScrolling(velocity: velocity)

            case .cancelled, .failed:
                TerminalDebugLog.log(.input, "touch scroll cancelled")
                stopMomentumScrolling()

            default:
                break
            }
        }

        func startMomentumScrolling(velocity: CGPoint) {
            guard abs(velocity.x) > 50 || abs(velocity.y) > 50 else { return }

            momentumVelocity = velocity
            TerminalDebugLog.log(
                .input,
                "momentum start velocity=\(String(format: "%.2f", velocity.x))x\(String(format: "%.2f", velocity.y))"
            )

            let mods = TerminalScrollModifiers(precision: true, momentum: .began)
            surface?.sendMouseScroll(x: 0, y: 0, mods: mods.rawValue)

            let link = CADisplayLink(
                target: self,
                selector: #selector(momentumScrollFrame(_:))
            )
            link.add(to: .main, forMode: .common)
            momentumDisplayLink = link
        }

        @objc func momentumScrollFrame(_ link: CADisplayLink) {
            let dt = link.targetTimestamp - link.timestamp
            let deceleration: CGFloat = 0.92

            momentumVelocity.x *= deceleration
            momentumVelocity.y *= deceleration

            let deltaX = momentumVelocity.x * dt * touchScrollMultiplier
            let deltaY = momentumVelocity.y * dt * touchScrollMultiplier

            if abs(momentumVelocity.x) < 50, abs(momentumVelocity.y) < 50 {
                stopMomentumScrolling()
                return
            }

            TerminalDebugLog.log(
                .input,
                "momentum frame velocity=\(String(format: "%.2f", momentumVelocity.x))x\(String(format: "%.2f", momentumVelocity.y)) delta=\(String(format: "%.2f", deltaX))x\(String(format: "%.2f", deltaY))"
            )

            let mods = TerminalScrollModifiers(precision: true, momentum: .changed)
            surface?.sendMouseScroll(
                x: Double(deltaX),
                y: Double(deltaY),
                mods: mods.rawValue
            )
        }

        func stopMomentumScrolling(sendTerminalEndEvent: Bool = true) {
            guard momentumDisplayLink != nil else { return }
            TerminalDebugLog.log(.input, "momentum stop")

            if sendTerminalEndEvent {
                let mods = TerminalScrollModifiers(precision: true, momentum: .none)
                surface?.sendMouseScroll(x: 0, y: 0, mods: mods.rawValue)
            }

            momentumDisplayLink?.invalidate()
            momentumDisplayLink = nil
            momentumVelocity = .zero
        }
    }

    extension UITerminalView: UIGestureRecognizerDelegate,
        UIContextMenuInteractionDelegate
    {
        override open func gestureRecognizerShouldBegin(
            _ gestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            #if !targetEnvironment(macCatalyst)
                if gestureRecognizer === terminalTapGesture {
                    guard surface?.isMouseCaptured != true else { return false }
                    if terminalTapBeganWithHostSelection {
                        return true
                    }
                    guard !hasHostSelection(),
                          UIPasteboard.general.hasStrings,
                          let initiatingPoint = terminalTapInitiatingPoint,
                          terminalCursorHitTarget()?.contains(initiatingPoint) == true
                    else { return false }
                    let releasePoint = gestureRecognizer.location(in: self)
                    return terminalCursorHitTarget()?.contains(releasePoint) == true
                }
                if gestureRecognizer === touchSelectionLongPressGesture {
                    if surface?.isMouseCaptured == true {
                        // The long-press handler also owns the remote mouse
                        // lifecycle, but must not reuse stale host selection.
                        dismissSelectionHandles()
                        return true
                    }
                    if syntheticLeftButtonDown || selectionHandleMode != .none {
                        return false
                    }
                    // Long-press on an existing selection belongs to the
                    // context menu (UIContextMenuInteraction); the selection
                    // long press yields there.
                    let location = gestureRecognizer.location(in: self)
                    surface?.sendMousePos(
                        x: location.x,
                        y: location.y,
                        mods: ghostty_input_mods_e(rawValue: 0)
                    )
                    return selectionMenuPoint(at: location) == nil
                }
                if syntheticLeftButtonDown || selectionHandleMode != .none {
                    // While a synthetic selection button is held (long-press
                    // word drag or handle drag), scroll and font gestures must
                    // not steal the touch sequence.
                    if gestureRecognizer is UIPinchGestureRecognizer
                        || gestureRecognizer === fontSizeResetTapGesture
                        || gestureRecognizer === touchScrollPanGesture
                    {
                        return false
                    }
                }
            #endif
            return true
        }

        open func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            #if !targetEnvironment(macCatalyst)
                // Ancestor recognizers normally observe touches in subviews.
                // Handle pans own their complete touch sequence: terminal
                // scroll/pinch/long-press/tap recognizers must ignore it.
                if gestureRecognizer.view === self {
                    let touchedView = touch.view
                    let touchesStartHandle = selectionStartHandle.map {
                        touchedView === $0 || touchedView?.isDescendant(of: $0) == true
                    } ?? false
                    let touchesEndHandle = selectionEndHandle.map {
                        touchedView === $0 || touchedView?.isDescendant(of: $0) == true
                    } ?? false
                    if touchesStartHandle || touchesEndHandle {
                        return false
                    }
                }

                if gestureRecognizer === terminalTapGesture {
                    terminalTapBeganWithHostSelection = false
                    terminalTapInitiatingPoint = nil
                    guard touch.type == .direct || touch.type == .pencil,
                          surface?.isMouseCaptured != true
                    else { return false }
                    if !suppressesSoftwareKeyboard, softwareKeyboardVisible {
                        return false
                    }

                    let point = touch.location(in: self)
                    terminalTapBeganWithHostSelection = hasHostSelection()
                    terminalTapInitiatingPoint = point
                    if terminalTapBeganWithHostSelection {
                        return true
                    }
                    return UIPasteboard.general.hasStrings
                        && terminalCursorHitTarget()?.contains(point) == true
                }
            #endif
            return true
        }

        open func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            #if !targetEnvironment(macCatalyst)
                let pair = [gestureRecognizer, otherGestureRecognizer]
                if pair.contains(where: { $0 === terminalTapGesture }),
                   pair.contains(where: {
                       $0 === touchScrollPanGesture
                           || $0 === touchSelectionLongPressGesture
                           || $0 is UIPinchGestureRecognizer
                           || $0 === fontSizeResetTapGesture
                   })
                {
                    return false
                }
                if pair.contains(where: { $0 === fontSizeResetTapGesture }),
                   pair.contains(where: {
                       $0 === touchScrollPanGesture
                           || $0 === touchSelectionLongPressGesture
                           || $0 is UIPinchGestureRecognizer
                   })
                {
                    return false
                }
            #endif
            return false
        }

        open func contextMenuInteraction(
            _: UIContextMenuInteraction,
            configurationForMenuAtLocation location: CGPoint
        ) -> UIContextMenuConfiguration? {
            dismissTerminalEditMenuInteractions()
            surface?.sendMousePos(
                x: location.x,
                y: location.y,
                mods: ghostty_input_mods_e(rawValue: 0)
            )
            guard selectionMenuPoint(at: location) != nil else { return nil }

            return selectionContextMenuConfiguration(at: location)
        }

    }

    extension UITerminalView: @MainActor UIEditMenuInteractionDelegate {
        open func editMenuInteraction(
            _ interaction: UIEditMenuInteraction,
            menuFor _: UIEditMenuConfiguration,
            suggestedActions _: [UIMenuElement]
        ) -> UIMenu? {
            if interaction === selectionEditMenuInteraction {
                guard surface?.isMouseCaptured != true,
                      hasHostSelection(),
                      surface?.readSelection()?.isEmpty == false
                else { return nil }
                return UIMenu(children: selectionMenuElements())
            }
            if interaction === terminalInputEditMenuInteraction {
                guard terminalInputMenuIsValid() else { return nil }
                return UIMenu(children: terminalInputMenuElements())
            }
            return nil
        }

        open func editMenuInteraction(
            _ interaction: UIEditMenuInteraction,
            targetRectFor configuration: UIEditMenuConfiguration
        ) -> CGRect {
            if interaction === terminalInputEditMenuInteraction,
               let anchor = terminalInputMenuAnchor
            {
                return anchor
            }
            return CGRect(
                x: configuration.sourcePoint.x,
                y: configuration.sourcePoint.y,
                width: 1,
                height: 1
            )
        }
    }
#endif
