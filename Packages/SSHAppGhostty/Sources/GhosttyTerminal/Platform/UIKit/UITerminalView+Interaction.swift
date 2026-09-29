//
//  UITerminalView+Interaction.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/17.
//

#if canImport(UIKit)
    import GhosttyVT
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
                // A direct touch catches a fling, as in UIScrollView.
                stopMomentumScrolling()
                // Keyboard/paste intent is committed only after the native
                // atomic tap response confirms local (not captured) routing.
                pendingKeyboardDismissOnTouchEnd = !suppressesSoftwareKeyboard && softwareKeyboardVisible
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
            #if targetEnvironment(macCatalyst)
            addInteraction(selectionContextMenuInteraction)
            addInteraction(selectionEditMenuInteraction)
            addInteraction(terminalInputEditMenuInteraction)
            #endif
            setupPointerHoverInput()
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

        func setupPointerHoverInput() {
            let gesture = UIHoverGestureRecognizer(
                target: self,
                action: #selector(handlePointerHoverGesture(_:))
            )
            gesture.cancelsTouchesInView = false
            gesture.delaysTouchesBegan = false
            gesture.delaysTouchesEnded = false
            addGestureRecognizer(gesture)
        }

        static func pointerHoverPosition(
            for state: UIGestureRecognizer.State,
            location: CGPoint
        ) -> CGPoint? {
            switch state {
            case .began, .changed:
                location
            case .ended:
                // A hover end is the genuine pointer-exit state.
                CGPoint(x: -1, y: -1)
            case .cancelled, .failed:
                // Arbitration does not imply that the pointer left the view.
                nil
            default:
                nil
            }
        }

        @objc func handlePointerHoverGesture(_ gesture: UIHoverGestureRecognizer) {
            #if !targetEnvironment(macCatalyst)
            let point = Self.pointerHoverPosition(for: gesture.state, location: gesture.location(in: self))
            if let point {
                nativeInteraction.hover(at: point.x < 0 ? nil : point, modifiers: gesture.modifierFlags)
            }
            #endif
        }

        func handleIndirectPointerTouches(_ touches: Set<UITouch>, phase: IndirectPointerPhase, event: UIEvent?) -> Bool {
            if touches.contains(where: { $0.type == .indirectPointer }) {
                stopMomentumScrolling()
                core.setFocus(true)
            }
            let nativePhase: VTPointerRequest.Phase = switch phase {
            case .began: .press
            case .moved: .move
            case .ended: .release
            case .cancelled: .cancel
            }
            return nativePointer.touches(touches, phase: nativePhase, event: event)
        }

        func logPointerSelectionDiagnostics(context: String, point: CGPoint) {
            TerminalDebugLog.log(.input, "native selection \(context) at \(point) exists=\(surface?.frameValue?.hasSelection == true)")
        }

        @IBAction override open func copy(_: Any?) {
            #if !targetEnvironment(macCatalyst)
            nativeInteraction.copySelection()
            #else
            let operation = surface?.session.enqueueTakeSelectedText()
            Task { @MainActor [weak self] in
                guard let text = try? await operation?.value, !text.isEmpty else { return }
                UIPasteboard.general.string = text
                self?.surface?.contentView.requestFrame()
            }
            #endif
        }

        @IBAction override open func paste(_: Any?) {
            pasteFromPasteboard()
        }

        @discardableResult
        func pasteFromPasteboard() -> Bool {
            guard let text = UIPasteboard.general.string, !text.isEmpty else {
                return false
            }
            insertPastedText(text)
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
            guard let frame = surface?.frameValue, let cell = frame.layout.cell(at: point) else { return false }
            return frame.contains(column: cell.column, row: cell.row)
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
                sendNativeScroll(delta: translation, at: gesture.location(in: self), modifiers: gesture.modifierFlags)
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

                nativePointer.install()

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

            @objc func handleIndirectPointerScrollGesture(_ gesture: UIPanGestureRecognizer) {
                guard gesture.numberOfTouches == 0, !nativePointer.isPressed else { return }
                sendIndirectPointerScrollDelta(from: gesture)
            }
            func sendIndirectPointerScrollDelta(from gesture: UIPanGestureRecognizer) {
                let delta = gesture.translation(in: self)
                gesture.setTranslation(.zero, in: self)
                nativePointer.scroll(at: gesture.location(in: self), delta: delta, modifiers: gesture.modifierFlags)
            }
            @objc func handleIndirectPointerSelectionGesture(_ gesture: UIPanGestureRecognizer) {
                // Physical pointer touches own the stream; never start a second
                // button lifecycle from UIKit's competing pan recognizer.
            }

            @objc func handleLongPressForSelection(_ gesture: UILongPressGestureRecognizer) {
                stopMomentumScrolling()
                nativeInteraction.longPress(gesture)
            }

            func cancelTouchSelectionInteraction() {
                nativeInteraction.cancelInteraction()
                activePointerButton = nil
                pointerSelectionStartPoint = nil
                touchSelectionIsMouseCaptured = false
                selectionGestureActive = false
                selectionHandleMode = .none
                hideSelectionMagnifier()
            }



            /// A terminal tap has exactly one intent, captured at touch-down.
            /// A selection-clearing tap must never continue into cursor Paste.
            @objc func handleTerminalTap(_ gesture: UITapGestureRecognizer) {
                guard gesture.state == .ended else { return }
                defer {
                    terminalTapBeganWithHostSelection = false
                    terminalTapInitiatingPoint = nil
                }
                let hadSelection = terminalTapBeganWithHostSelection
                let point = terminalTapInitiatingPoint ?? gesture.location(in: self)
                // Keyboard notifications are global: an unfocused split can see
                // another split's keyboard. Only its owner may dismiss it; other
                // panes must transfer focus on an ordinary local tap.
                let dismissKeyboard = isFirstResponder && !suppressesSoftwareKeyboard && softwareKeyboardVisible
                nativeInteraction.tap(at: gesture.location(in: self), modifiers: gesture.modifierFlags) { [weak self] in
                    guard let self else { return }
                    if hadSelection { dismissSelectionHandles(); return }
                    if dismissKeyboard { resignFirstResponderForApplicationAction(); return }
                    becomeFirstResponder()
                    if terminalCursorHitTarget()?.contains(point) == true {
                        presentTerminalInputEditMenu(at: point)
                    }
                }
            }
        #endif

        @objc func handleTouchScrollGesture(_ gesture: UIPanGestureRecognizer) {
            if gesture.state == .began {
                stopMomentumScrolling()
                dismissTerminalEditMenus()
            }
            #if !targetEnvironment(macCatalyst)
            touchDidScrollDuringCurrentTouch = true
            #endif
            // Always admit a native touch press. Its route stays fixed through
            // release even if output changes capture mode during the gesture.
            nativePointer.directPan(state: gesture.state, at: gesture.location(in: self),
                modifiers: gesture.modifierFlags, velocity: gesture.velocity(in: self))
            if gesture.state == .cancelled || gesture.state == .failed { stopMomentumScrolling() }
        }

        func sendNativeScroll(delta: CGPoint, at point: CGPoint, modifiers: UIKeyModifierFlags = []) {
            nativePointer.scroll(at: point, delta: delta, modifiers: modifiers)
        }

        func startMomentumScrolling(velocity: CGPoint) {
            guard abs(velocity.x) > 50 || abs(velocity.y) > 50 else { return }

            momentumVelocity = velocity
            TerminalDebugLog.log(
                .input,
                "momentum start velocity=\(String(format: "%.2f", velocity.x))x\(String(format: "%.2f", velocity.y))"
            )

            let link = CADisplayLink(
                target: self,
                selector: #selector(momentumScrollFrame(_:))
            )
            link.add(to: .main, forMode: .common)
            momentumDisplayLink = link
            #if DEBUG
                if lifecycleMomentumObserver != nil {
                    lifecycleMomentumGeneration &+= 1
                    lifecycleMomentumTicks = 0
                    emitLifecycleMomentum(.started, delta: .zero)
                }
            #endif
        }

        @objc func momentumScrollFrame(_ link: CADisplayLink) {
            // Invalidation does not retract a callback already delivered by
            // UIKit. An old link must never mutate a replacement generation.
            guard link === momentumDisplayLink else { return }
            let dt = link.targetTimestamp - link.timestamp
            let deceleration: CGFloat = 0.92

            momentumVelocity.x *= deceleration
            momentumVelocity.y *= deceleration

            let deltaX = momentumVelocity.x * dt * touchScrollMultiplier
            let deltaY = momentumVelocity.y * dt * touchScrollMultiplier

            if abs(momentumVelocity.x) < 50, abs(momentumVelocity.y) < 50 {
                stopMomentumScrolling(decelerationCompleted: true)
                return
            }

            TerminalDebugLog.log(
                .input,
                "momentum frame velocity=\(String(format: "%.2f", momentumVelocity.x))x\(String(format: "%.2f", momentumVelocity.y)) delta=\(String(format: "%.2f", deltaX))x\(String(format: "%.2f", deltaY))"
            )
            nativePointer.scroll(at: CGPoint(x: bounds.midX, y: bounds.midY),
                delta: CGPoint(x: deltaX, y: deltaY), modifiers: [], localOnly: true)
            #if DEBUG
                if lifecycleMomentumObserver != nil, deltaX != 0 || deltaY != 0 {
                    lifecycleMomentumTicks += 1
                    emitLifecycleMomentum(.tick, delta: CGPoint(x: deltaX, y: deltaY))
                }
            #endif
        }

        func stopMomentumScrolling(sendTerminalEndEvent: Bool = true, decelerationCompleted: Bool = false) {
            guard momentumDisplayLink != nil else { return }
            TerminalDebugLog.log(.input, "momentum stop")


            #if DEBUG
                let stopVelocity = momentumVelocity
                let cause: TerminalLifecycleMomentumSample.StopCause = decelerationCompleted
                    ? .deceleration : (isHostVisible ? .cancelled : .visibility)
            #endif
            momentumDisplayLink?.invalidate()
            momentumDisplayLink = nil
            momentumVelocity = .zero
            #if DEBUG
                emitLifecycleMomentum(.stopped, delta: .zero, velocity: stopVelocity, stopCause: cause)
            #endif
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
                    return !nativeInteraction.isSelecting
                }
                if gestureRecognizer === touchSelectionLongPressGesture {
                    if surface?.isMouseCaptured == true && !gestureRecognizer.modifierFlags.contains(.shift) {
                        // The long-press handler also owns the remote mouse
                        // lifecycle, but must not reuse stale host selection.
                        dismissSelectionHandles()
                        return true
                    }
                    if nativeInteraction.isSelecting || selectionHandleMode != .none {
                        return false
                    }
                    // Long-press on an existing selection belongs to the
                    // context menu (UIContextMenuInteraction); the selection
                    // long press yields there.
                    return true
                }
                if nativeInteraction.isSelecting || selectionHandleMode != .none {
                    // While a native selection gesture is active (long-press
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
                    guard touch.type == .direct || touch.type == .pencil else { return false }
                    terminalTapBeganWithHostSelection = hasHostSelection()
                    terminalTapInitiatingPoint = touch.location(in: self)
                    return true
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
                // A native local selection may intentionally coexist with
                // remote mouse capture when Shift overrides pointer routing.
                guard hasHostSelection(),
                      surface?.frameValue?.hasSelection == true
                else { return nil }
                #if !targetEnvironment(macCatalyst)
                return UIMenu(children: nativeInteraction.menuElements())
                #else
                return UIMenu(children: selectionMenuElements())
                #endif
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
            #if !targetEnvironment(macCatalyst)
            if interaction === selectionEditMenuInteraction,
               let menuView = interaction.view,
               let target = nativeInteraction.selectionMenuTargetRect(in: menuView)
            {
                return target
            }
            #endif
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
