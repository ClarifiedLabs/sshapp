//
//  UITerminalView.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

#if canImport(UIKit)
    import GhosttyKit
    import UIKit

    #if !targetEnvironment(macCatalyst)
        /// Which endpoint of a touch selection a handle drag is adjusting.
        /// `.none` means no handle drag is in flight (handles may still be
        /// visible and stationary).
        enum TerminalSelectionHandleMode {
            case none
            case adjustingStart
            case adjustingEnd
        }
    #endif

    #if !targetEnvironment(macCatalyst)
        private final class TerminalSoftwareKeyboardSuppressionInputView: UIView {
            override var intrinsicContentSize: CGSize {
                CGSize(width: UIView.noIntrinsicMetric, height: 0)
            }

            override func sizeThatFits(_ size: CGSize) -> CGSize {
                CGSize(width: size.width, height: 0)
            }
        }

        enum TerminalSoftwareKeyboardDismissState: Equatable {
            case idle
            case fullPresentation
            case systemResignPending
            case applicationResignPending
        }
    #endif

    @MainActor
    open class UITerminalView: UIView {
        let core = TerminalSurfaceCoordinator()
        #if DEBUG
            public var selectionDebugConfiguration: TerminalSelectionDebugConfiguration? {
                didSet {
                    selectionDebugConfigurationDidChange(from: oldValue)
                }
            }
            public internal(set) var selectionDebugProbe: TerminalSelectionDebugProbe?
            var selectionDebugLastSemanticSnapshot: TerminalSelectionDebugSnapshot?
            var selectionDebugRevision: UInt64 = 0
        #endif
        var momentumDisplayLink: CADisplayLink?
        var momentumVelocity: CGPoint = .zero
        static let minFontSize: Float = 1
        static let maxFontSize: Float = 64
        var activePointerButton: ghostty_input_mouse_button_e? {
            didSet {
                #if DEBUG
                    guard oldValue != activePointerButton else { return }
                    refreshSelectionDebugSnapshot()
                #endif
            }
        }
        var pointerSelectionStartPoint: CGPoint?
        var lastPointerSelectionRect: CGRect?
        var pendingSelectionMenuPoint: CGPoint?
        #if !targetEnvironment(macCatalyst)
            var indirectPointerPanOwnsTouchSequence = false
            var suppressNextIndirectPointerTouchEnd = false
        #endif
        lazy var selectionContextMenuInteraction = UIContextMenuInteraction(delegate: self)
        lazy var selectionEditMenuInteraction = UIEditMenuInteraction(delegate: self)
        lazy var terminalInputEditMenuInteraction = UIEditMenuInteraction(delegate: self)
        var terminalInputMenuAnchor: CGRect?
        var terminalInputMenuInitiatingPoint: CGPoint?
        var lastKnownTerminalViewportBounds: CGRect?
        var lastKnownTerminalMetrics: TerminalViewportMetrics?
        var hardwareKeyHandled = false
        let touchScrollMultiplier: CGFloat = 3.0
        var currentFontSize: Float = 14
        var isFontSizeTransientlyAdjusted = false
        #if !targetEnvironment(macCatalyst)
            var lastPinchScale: CGFloat = 1.0
            var pinchZoomGesture: UIPinchGestureRecognizer?
            var fontSizeResetTapGesture: UITapGestureRecognizer?
        #endif

        /// The current app-configured font size that a surface-local reset restores.
        ///
        /// Updating the baseline preserves a user's transient zoom until they reset
        /// it, while unadjusted surfaces track settings changes immediately.
        open var configuredFontSize: Float = 14 {
            didSet {
                if !isFontSizeTransientlyAdjusted {
                    currentFontSize = configuredFontSize
                }
            }
        }

        public var hardwareKeyRepeatConfiguration: TerminalHardwareKeyRepeatConfiguration = .default {
            didSet {
                if !hardwareKeyRepeatConfiguration.enabled {
                    cancelHardwareKeyRepeat()
                    hardwareTextInputSuppressedKeyCodes.removeAll()
                }
            }
        }
        var hardwareKeyRepeatTask: Task<Void, Never>?
        var hardwareKeyRepeatKey: TerminalUIKitKeyPress?
        private var immediateDrawCompletions: [@MainActor () -> Void] = []
        var hardwareTextInputSuppressedKeyCodes: Set<UIKeyboardHIDUsage.RawValue> = []
        lazy var inputHandler = TerminalTextInputHandler(view: self)
        weak var _inputDelegate: (any UITextInputDelegate)?
        var onFocusChange: ((Bool) -> Void)?
        public var onSystemSoftwareKeyboardDismiss: (@MainActor () -> Void)?

        #if !targetEnvironment(macCatalyst)
            lazy var terminalInputAccessory = TerminalInputAccessoryView(terminalView: self)
            let stickyModifiers = TerminalStickyModifierState()
            var hardwareStickyModifiersByKeyCode: [
                UIKeyboardHIDUsage.RawValue: TerminalInputModifiers
            ] = [:]
            static let fullSoftwareKeyboardHeightThreshold: CGFloat = 120
            var softwareKeyboardVisible = false
            var keyboardFrameEndScreenRect: CGRect?
            var softwareKeyboardDismissState: TerminalSoftwareKeyboardDismissState = .idle
            var isResigningFirstResponder = false
            var applicationResponderResignDepth = 0
            var deferredSystemSoftwareKeyboardDismissID: UInt64?
            var nextSystemSoftwareKeyboardDismissID: UInt64 = 0
            var deferredSuppressedInputViewReloadID: UInt64?
            var nextSuppressedInputViewReloadID: UInt64 = 0
            var ownsFullSoftwareKeyboardPresentation: Bool {
                softwareKeyboardDismissState == .fullPresentation
            }
            var pendingKeyboardDismissOnTouchEnd = false
            var touchDidScrollDuringCurrentTouch = false

            // MARK: - Touch selection state

            /// Fixed end of the active touch-selection gesture, in view points.
            /// Ghostty owns the actual selected range; these points only
            /// position the adjustable handles and seed handle-drag rebuilds.
            var touchSelectionAnchorPoint: CGPoint?
            /// Moving end of the active touch-selection gesture, in view points.
            var touchSelectionActiveEndPoint: CGPoint?
            /// Cell-interior hit-test points corresponding to the visual
            /// endpoint points above. Snapped handles sit on cell edges, which
            /// must never be sent directly to Ghostty as mouse positions.
            var touchSelectionAnchorMousePoint: CGPoint?
            var touchSelectionActiveEndMousePoint: CGPoint?
            /// Grid origin in view points, resolved from Ghostty's effective
            /// padding configuration so padding never shifts terminal geometry.
            var touchSelectionGridOrigin: CGPoint?
            var touchSelectionGridMetrics: TerminalGridMetrics?
            var touchSelectionGridScale: CGFloat?
            /// Which endpoint a handle drag is currently adjusting.
            var selectionHandleMode: TerminalSelectionHandleMode = .none {
                didSet {
                    #if DEBUG
                        refreshSelectionDebugSnapshot()
                    #endif
                }
            }
            /// Whether the touch-selection handle overlay is currently shown.
            var selectionHandlesVisible = false
            var selectionHandlesViewportBounds: CGRect?
            /// True while a synthetic left-button press is held for touch
            /// selection (long-press word drag or a handle drag). Ghostty's
            /// word-expansion drag and selection autoscroll both key off the
            /// held button.
            var syntheticLeftButtonDown = false {
                didSet {
                    #if DEBUG
                        refreshSelectionDebugSnapshot()
                    #endif
                }
            }
            /// Captured at long-press begin so remote mouse-reporting apps
            /// never fall through into host-selection UI on gesture end.
            var touchSelectionIsMouseCaptured = false {
                didSet {
                    #if DEBUG
                        refreshSelectionDebugSnapshot()
                    #endif
                }
            }
            /// The touch-selection long press, stored so gesture arbitration
            /// can tell it apart from UIKit's context-menu long press.
            var touchSelectionLongPressGesture: UILongPressGestureRecognizer?
            /// One direct-touch tap recognizer that either dismisses the
            /// selection present at touch-down or offers cursor-anchored Paste.
            var terminalTapGesture: UITapGestureRecognizer?
            var terminalTapBeganWithHostSelection = false
            var terminalTapInitiatingPoint: CGPoint?
            /// The direct-touch scroll pan, stored so arbitration can block
            /// it during synthetic selection drags.
            var touchScrollPanGesture: UIPanGestureRecognizer?
            /// Finger-sized overlays for the ordered selection endpoints.
            var selectionStartHandle: TerminalSelectionHandleView?
            var selectionEndHandle: TerminalSelectionHandleView?
            var selectionMagnifier: TerminalSelectionMagnifierView?
            lazy var selectionHandleFeedbackGenerator = UISelectionFeedbackGenerator()
            var selectionHandleLastFeedbackCell: CGPoint?
            /// Snapshot restored if a handle drag is cancelled.
            var selectionHandleDragOriginalPoints: (start: CGPoint, end: CGPoint)?
            var selectionHandleDragOriginalMousePoints: (start: CGPoint, end: CGPoint)?
            /// Offset from the finger to the visual endpoint at handle grab.
            var selectionHandleDragTouchOffset: CGPoint = .zero
            /// Offset from the visual cell edge to Ghostty's cell-interior point.
            var selectionHandleDragMouseOffset: CGPoint = .zero
            private lazy var softwareKeyboardSuppressionInputView: UIView = {
                let view = TerminalSoftwareKeyboardSuppressionInputView(frame: .zero)
                view.isUserInteractionEnabled = false
                view.autoresizingMask = [.flexibleWidth]
                return view
            }()
        #endif

        open var suppressesSoftwareKeyboard = false {
            didSet {
                guard oldValue != suppressesSoftwareKeyboard else { return }
                #if !targetEnvironment(macCatalyst)
                    softwareKeyboardSuppressionDidChange()
                #endif
            }
        }

        override open var inputView: UIView? {
            #if targetEnvironment(macCatalyst)
                super.inputView
            #else
                suppressesSoftwareKeyboard ? softwareKeyboardSuppressionInputView : super.inputView
            #endif
        }

        #if !targetEnvironment(macCatalyst)
            open var inputAccessoryStyle: TerminalInputAccessoryStyle {
                get { terminalInputAccessory.style }
                set { terminalInputAccessory.style = newValue }
            }

            open var usesSystemInputAccessory = true {
                didSet {
                    guard oldValue != usesSystemInputAccessory else { return }
                    invalidateSoftwareKeyboardDismissTracking()
                    if isFirstResponder {
                        reloadInputViews()
                    }
                    refitViewportForKeyboardChange(reason: "system-input-accessory-toggle")
                }
            }

            open var inputAccessoryItems: [TerminalInputAccessoryItem] = TerminalInputAccessoryItem.defaultItems {
                didSet {
                    terminalInputAccessory.rebuildContent()
                    invalidateSoftwareKeyboardDismissTracking()
                    if isFirstResponder {
                        reloadInputViews()
                    }
                    refitViewportForKeyboardChange(reason: "input-accessory-items")
                }
            }
        #endif

        open weak var delegate: (any TerminalSurfaceViewDelegate)? {
            get { core.delegate }
            set { core.delegate = newValue }
        }

        open var controller: TerminalController? {
            get { core.controller }
            set {
                let replacesSurface = core.controller !== newValue
                if replacesSurface {
                    dismissTerminalEditMenus()
                    #if !targetEnvironment(macCatalyst)
                        cancelTouchSelectionInteraction()
                        dismissSelectionHandles()
                    #endif
                }
                core.controller = newValue
                if replacesSurface {
                    resetFontAdjustmentTrackingForSurfaceReplacement()
                }
                #if DEBUG
                    if replacesSurface {
                        refreshSelectionDebugSnapshot()
                    }
                #endif
            }
        }

        open var configuration: TerminalSurfaceOptions {
            get { core.configuration }
            set {
                let replacesSurface = !newValue.isEquivalent(to: core.configuration)
                if replacesSurface {
                    dismissTerminalEditMenus()
                    #if !targetEnvironment(macCatalyst)
                        cancelTouchSelectionInteraction()
                        dismissSelectionHandles()
                    #endif
                }
                core.configuration = newValue
                if replacesSurface {
                    resetFontAdjustmentTrackingForSurfaceReplacement()
                }
                #if DEBUG
                    if replacesSurface {
                        refreshSelectionDebugSnapshot()
                    }
                #endif
            }
        }

        var surface: TerminalSurface? {
            core.surface
        }

        /// Restores only this terminal surface to its current configured font size.
        ///
        /// The persisted setting and shared controller configuration are untouched.
        @discardableResult
        open func resetFontSize() -> Bool {
            resetFontSize(applying: { [weak self] in
                self?.surface?.performBindingAction("reset_font_size") == true
            })
        }

        @discardableResult
        func resetFontSize(applying action: () -> Bool) -> Bool {
            guard action() else { return false }

            dismissTerminalEditMenus()
            #if !targetEnvironment(macCatalyst)
                cancelTouchSelectionInteraction()
                dismissSelectionHandles()
            #endif

            isFontSizeTransientlyAdjusted = false
            currentFontSize = configuredFontSize
            core.synchronizeMetrics()
            refreshTextInputGeometry(reason: "font-size-reset")
            core.requestImmediateTick()
            UIAccessibility.post(notification: .announcement, argument: "Font size reset")
            return true
        }

        func resetFontAdjustmentTrackingForSurfaceReplacement() {
            isFontSizeTransientlyAdjusted = false
            currentFontSize = configuredFontSize
        }

        private func installFontSizeResetAccessibilityAction() {
            let action = UIAccessibilityCustomAction(
                name: "Reset Font Size",
                actionHandler: { [weak self] _ in
                    self?.resetFontSize() ?? false
                }
            )
            accessibilityCustomActions = [action]
        }

        open var hasText: Bool {
            true
        }

        override open var canBecomeFirstResponder: Bool {
            true
        }

        override open func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            #if !targetEnvironment(macCatalyst)
                // Selection hit targets commonly overlap for short words. UIKit
                // would otherwise always choose the later-added end handle.
                // Route the touch to whichever visible endpoint is closest.
                let candidates = [selectionStartHandle, selectionEndHandle]
                    .compactMap { $0 }
                    .filter {
                        !$0.isHidden
                            && $0.isUserInteractionEnabled
                            && $0.frame.contains(point)
                    }
                if let nearest = candidates.min(by: { lhs, rhs in
                    let lhsX = lhs.center.x - point.x
                    let lhsY = lhs.center.y - point.y
                    let rhsX = rhs.center.x - point.x
                    let rhsY = rhs.center.y - point.y
                    return lhsX * lhsX + lhsY * lhsY
                        < rhsX * rhsX + rhsY * rhsY
                }) {
                    return nearest
                }
            #endif
            return super.hitTest(point, with: event)
        }

        override public init(frame: CGRect) {
            super.init(frame: frame)
            commonInit()
        }

        @available(*, unavailable)
        public required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func commonInit() {
            backgroundColor = .clear
            isOpaque = false
            isUserInteractionEnabled = true
            updateDisplayScale()

            core.isAttached = { [weak self] in self?.window != nil }
            core.scaleFactor = { [weak self] in
                Double(self?.resolvedDisplayScale() ?? UIScreen.main.nativeScale)
            }
            core.viewSize = { [weak self] in
                guard let self else { return (0, 0) }
                let viewport = terminalViewportBounds
                return (viewport.width, viewport.height)
            }
            core.platformOwner = self
            core.platformSetup = { [weak self] config in
                guard let self else { return }
                config.platform_tag = GHOSTTY_PLATFORM_IOS
                config.platform = ghostty_platform_u(
                    ios: ghostty_platform_ios_s(
                        uiview: Unmanaged.passUnretained(self).toOpaque()
                    )
                )
            }
            core.onMetricsUpdate = { [weak self] in
                guard let self else { return }
                updateSublayerFrames()
                invalidateTerminalEditMenusForMetricsChange()
                #if !targetEnvironment(macCatalyst)
                    layoutSelectionHandles()
                #endif
                #if DEBUG
                    refreshSelectionDebugSnapshot()
                #endif
            }
            core.onCellSizeDidChange = { [weak self] in
                self?.refreshTextInputGeometry(reason: "cell-size-action")
            }
            core.onPostRender = { [weak self] in
                guard let self else { return }
                enforceSublayerScale()
                #if !targetEnvironment(macCatalyst)
                    synchronizeTouchSelectionOverlayAfterRender()
                #endif
                invalidateTerminalInputMenuAfterRender()
                #if DEBUG
                    refreshSelectionDebugSnapshot()
                #endif
                let completions = immediateDrawCompletions
                immediateDrawCompletions.removeAll(keepingCapacity: true)
                completions.forEach { $0() }
            }

            setupApplicationLifecycleObservers()
            syncApplicationActiveState()
            setupPlatformInput()
            installFontSizeResetAccessibilityAction()
            #if !targetEnvironment(macCatalyst)
                setupKeyboardObservers()
            #endif
        }

        open func selectionMenuPoint(at point: CGPoint) -> CGPoint? {
            logPointerSelectionDiagnostics(
                context: "selectionMenuPoint",
                point: point
            )
            #if !targetEnvironment(macCatalyst)
                if surface?.isMouseCaptured == true {
                    dismissSelectionHandles()
                    lastPointerSelectionRect = nil
                    return nil
                }
                if selectionHandlesVisible {
                    guard touchSelectionContains(point) else {
                        TerminalDebugLog.log(
                            .input,
                            "selection menu miss point=\(NSCoder.string(for: point)) outside touch selection"
                        )
                        return nil
                    }
                    TerminalDebugLog.log(
                        .input,
                        "selection menu hit point=\(NSCoder.string(for: point)) inside touch selection"
                    )
                    return point
                }
            #endif

            if let rect = lastPointerSelectionRect {
                let pointIsInsidePointerSelection = rect.insetBy(dx: -4, dy: -4).contains(point)
                guard pointIsInsidePointerSelection else {
                    TerminalDebugLog.log(
                        .input,
                        "selection menu miss point=\(NSCoder.string(for: point)) outside pointer selection"
                    )
                    return nil
                }
                guard surface?.hasSelection() == true else {
                    TerminalDebugLog.log(
                        .input,
                        "selection menu miss point=\(NSCoder.string(for: point)) inside pointer selection without active selection"
                    )
                    return nil
                }
                TerminalDebugLog.log(
                    .input,
                    "selection menu hit point=\(NSCoder.string(for: point)) inside pointer selection"
                )
                return point
            }

            guard surface?.hasSelection() == true else {
                TerminalDebugLog.log(
                    .input,
                    "selection menu miss point=\(NSCoder.string(for: point))"
                )
                return nil
            }

            guard surface?.selectionContainsQuicklookWord() == true else {
                TerminalDebugLog.log(
                    .input,
                    "selection menu miss point=\(NSCoder.string(for: point)) outside quicklook word"
                )
                return nil
            }

            TerminalDebugLog.log(
                .input,
                "selection menu hit point=\(NSCoder.string(for: point))"
            )
            return point
        }

        #if !targetEnvironment(macCatalyst)
            private func touchSelectionContains(_ point: CGPoint) -> Bool {
                guard selectionHandlesVisible,
                      let surface,
                      let metrics = surface.size(),
                      let geometry = touchSelectionGridGeometry(for: metrics)
                else { return false }

                let column = Int(floor(
                    (point.x - geometry.origin.x) / geometry.cellWidth
                ))
                let row = Int(floor(
                    (point.y - geometry.origin.y) / geometry.cellHeight
                ))
                let columns = Int(metrics.columns)
                guard column >= 0,
                      column < columns,
                      row >= 0,
                      row < Int(metrics.rows)
                else { return false }

                return surface.selectionContains(
                    x: Double(point.x),
                    y: Double(point.y)
                )
            }
        #endif

        open func showSelectionCopyMenu(at point: CGPoint) {
            presentTouchSelectionEditMenu(at: point)
        }

        /// Presents the modern edit menu for direct-touch selection. Pointer
        /// right-click and long-press-on-selection continue to use the existing
        /// context-menu path above.
        open func presentTouchSelectionEditMenu(at point: CGPoint) {
            becomeFirstResponder()
            guard surface?.isMouseCaptured != true,
                  hasHostSelection()
            else {
                dismissSelectionHandles()
                return
            }
            dismissTerminalEditMenus()
            selectionEditMenuInteraction.presentEditMenu(
                with: UIEditMenuConfiguration(
                    identifier: nil,
                    sourcePoint: point
                )
            )
        }

        @discardableResult
        open func copySelectedTextToPasteboard() -> Bool {
            #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                    accessibilityValue = nil
                }
            #endif
            guard let text = surface?.readSelection(), !text.isEmpty else {
                return false
            }
            UIPasteboard.general.string = text
            #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                    accessibilityValue = text
                }
            #endif
            TerminalDebugLog.log(
                .input,
                "selection copied bytes=\(text.utf8.count) lines=\(TerminalInputText.lineCount(in: text))"
            )
            #if !targetEnvironment(macCatalyst)
                clearTouchSelectionAfterCopy()
            #endif
            return true
        }

        open func selectionContextMenuConfiguration(
            at _: CGPoint
        ) -> UIContextMenuConfiguration {
            UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                UIMenu(children: self?.selectionMenuElements() ?? [])
            }
        }

        open func selectionMenuElements() -> [UIMenuElement] {
            let copy = UIAction(
                title: "Copy",
                image: UIImage(systemName: "doc.on.doc")
            ) { [weak self] _ in
                self?.copySelectedTextToPasteboard()
            }
            return [copy]
        }

        open func terminalInputMenuElements() -> [UIMenuElement] {
            guard UIPasteboard.general.hasStrings else { return [] }
            let paste = UIAction(
                title: "Paste",
                image: UIImage(systemName: "doc.on.clipboard")
            ) { [weak self] _ in
                guard let self else { return }
                guard terminalInputMenuIsValid() else {
                    dismissTerminalInputEditMenu()
                    return
                }
                pasteFromPasteboard()
            }
            return [paste]
        }

        func hasHostSelection() -> Bool {
            if surface?.hasSelection() == true { return true }
            if pointerSelectionStartPoint != nil || pendingSelectionMenuPoint != nil {
                return true
            }
            if lastPointerSelectionRect != nil,
               surface?.readSelection()?.isEmpty == false
            {
                return true
            }
            #if !targetEnvironment(macCatalyst)
                if selectionHandlesVisible
                    || touchSelectionAnchorPoint != nil
                    || touchSelectionActiveEndPoint != nil
                    || syntheticLeftButtonDown
                    || selectionHandleMode != .none
                {
                    return true
                }
            #endif
            return false
        }

        private func terminalCursorCellGeometry() -> (cell: CGRect, visibleCell: CGRect)? {
            guard let surface,
                  let metrics = surface.size(),
                  metrics.cellWidthPixels > 0,
                  metrics.cellHeightPixels > 0
            else { return nil }

            let scale = resolvedDisplayScale()
            let imePoint = surface.imePoint()
            let imeX = CGFloat(imePoint.x)
            let imeY = CGFloat(imePoint.y)
            let cellWidth = CGFloat(metrics.cellWidthPixels) / scale
            let cellHeight = CGFloat(metrics.cellHeightPixels) / scale
            guard scale.isFinite,
                  scale > 0,
                  imeX.isFinite,
                  imeY.isFinite,
                  cellWidth.isFinite,
                  cellHeight.isFinite,
                  cellWidth > 0,
                  cellHeight > 0
            else { return nil }

            let cell = CGRect(
                x: imeX - cellWidth / 2,
                y: imeY - cellHeight,
                width: cellWidth,
                height: cellHeight
            )
            let viewport = terminalViewportBounds
            guard cell.minX.isFinite,
                  cell.minY.isFinite,
                  cell.maxX.isFinite,
                  cell.maxY.isFinite,
                  viewport.width > 0,
                  viewport.height > 0
            else { return nil }

            let visibleCell = cell.intersection(viewport)
            guard !visibleCell.isNull, !visibleCell.isEmpty else { return nil }
            return (cell, visibleCell)
        }

        func terminalCursorCellRect() -> CGRect? {
            terminalCursorCellGeometry()?.visibleCell
        }

        func terminalCursorHitTarget() -> CGRect? {
            guard let geometry = terminalCursorCellGeometry() else { return nil }
            let hitWidth = max(44, geometry.cell.width)
            let hitHeight = max(44, geometry.cell.height)
            let expanded = CGRect(
                x: geometry.cell.midX - hitWidth / 2,
                y: geometry.cell.midY - hitHeight / 2,
                width: hitWidth,
                height: hitHeight
            )
            let visibleTarget = expanded.intersection(terminalViewportBounds)
            guard !visibleTarget.isNull, !visibleTarget.isEmpty else { return nil }
            return visibleTarget
        }

        func presentTerminalInputEditMenu(at initiatingPoint: CGPoint) {
            guard !hasHostSelection(),
                  surface?.isMouseCaptured != true,
                  UIPasteboard.general.hasStrings,
                  terminalCursorHitTarget()?.contains(initiatingPoint) == true
            else { return }

            becomeFirstResponder()
            guard !hasHostSelection(),
                  surface?.isMouseCaptured != true,
                  UIPasteboard.general.hasStrings,
                  let cursorRect = terminalCursorCellRect(),
                  terminalCursorHitTarget()?.contains(initiatingPoint) == true
            else { return }

            dismissTerminalEditMenus()
            terminalInputMenuAnchor = cursorRect
            terminalInputMenuInitiatingPoint = initiatingPoint
            terminalInputEditMenuInteraction.presentEditMenu(
                with: UIEditMenuConfiguration(
                    identifier: nil,
                    sourcePoint: CGPoint(x: cursorRect.midX, y: cursorRect.midY)
                )
            )
        }

        func terminalInputMenuIsValid() -> Bool {
            guard isFirstResponder,
                  !hasHostSelection(),
                  surface?.isMouseCaptured != true,
                  UIPasteboard.general.hasStrings,
                  let anchor = terminalInputMenuAnchor,
                  let initiatingPoint = terminalInputMenuInitiatingPoint,
                  let currentCell = terminalCursorCellRect(),
                  !terminalCursorCellMateriallyChanged(from: anchor, to: currentCell),
                  terminalCursorHitTarget()?.contains(initiatingPoint) == true
            else { return false }
            return true
        }

        private func terminalCursorCellMateriallyChanged(
            from oldRect: CGRect,
            to newRect: CGRect
        ) -> Bool {
            let tolerance: CGFloat = 0.5
            return abs(oldRect.minX - newRect.minX) > tolerance
                || abs(oldRect.minY - newRect.minY) > tolerance
                || abs(oldRect.width - newRect.width) > tolerance
                || abs(oldRect.height - newRect.height) > tolerance
        }

        func dismissTerminalInputEditMenu() {
            terminalInputEditMenuInteraction.dismissMenu()
            terminalInputMenuAnchor = nil
            terminalInputMenuInitiatingPoint = nil
        }

        func dismissTerminalEditMenuInteractions() {
            selectionEditMenuInteraction.dismissMenu()
            dismissTerminalInputEditMenu()
        }

        func dismissTerminalEditMenus() {
            selectionContextMenuInteraction.dismissMenu()
            dismissTerminalEditMenuInteractions()
        }

        func invalidateTerminalEditMenusForViewportChange() {
            let currentViewport = terminalViewportBounds
            defer { lastKnownTerminalViewportBounds = currentViewport }

            guard let previousViewport = lastKnownTerminalViewportBounds,
                  previousViewport != currentViewport
            else {
                invalidateTerminalInputMenuAfterRender()
                return
            }
            dismissTerminalEditMenus()
        }

        func invalidateTerminalEditMenusForMetricsChange() {
            let currentMetrics = surface?.size().map {
                TerminalViewportMetrics(
                    surfaceSize: $0,
                    scale: Double(resolvedDisplayScale())
                )
            }
            defer { lastKnownTerminalMetrics = currentMetrics }

            guard let previousMetrics = lastKnownTerminalMetrics,
                  previousMetrics != currentMetrics
            else {
                invalidateTerminalInputMenuAfterRender()
                return
            }
            dismissTerminalEditMenus()
        }

        func invalidateTerminalInputMenuAfterRender() {
            guard terminalInputMenuAnchor != nil else { return }
            guard terminalInputMenuIsValid() else {
                dismissTerminalInputEditMenu()
                return
            }
        }

        open func refreshInputAccessoryViewport() {
            refitViewportForKeyboardChange(reason: "input-accessory-refresh")
        }

        /// Coalesces a draw request onto the next main run-loop pass.
        ///
        /// Use this after synchronously delivering a buffered output batch. It
        /// does not resize the terminal and repeated requests before the pass
        /// are rendered by one tick.
        public func requestImmediateDraw(onPostRender completion: (@MainActor () -> Void)? = nil) {
            if let completion {
                immediateDrawCompletions.append(completion)
            }
            core.requestImmediateTick()
        }

        open func setTerminalSurfaceFocused(_ focused: Bool) {
            core.setFocus(focused, notifyDelegate: false)
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        #if !targetEnvironment(macCatalyst)
            func setupKeyboardObservers() {
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(keyboardDidShow),
                    name: UIResponder.keyboardDidShowNotification,
                    object: nil
                )
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(keyboardDidHide),
                    name: UIResponder.keyboardDidHideNotification,
                    object: nil
                )
            }

            var isActiveForSoftwareKeyboardDismissal: Bool {
                guard UIApplication.shared.applicationState == .active else { return false }
                guard let windowScene = window?.windowScene else { return true }
                return windowScene.activationState == .foregroundActive
            }

            @objc func keyboardDidShow(_ notification: Notification) {
                guard !suppressesSoftwareKeyboard else {
                    let hadStaleKeyboardState = softwareKeyboardVisible || keyboardFrameEndScreenRect != nil
                    invalidateSoftwareKeyboardDismissTracking()
                    softwareKeyboardVisible = false
                    keyboardFrameEndScreenRect = nil
                    if hadStaleKeyboardState {
                        refitViewportForKeyboardChange(reason: "suppressed-keyboard-show")
                    }
                    return
                }

                let keyboardFrame = keyboardScreenFrame(from: notification)
                softwareKeyboardVisible = true
                keyboardFrameEndScreenRect = keyboardFrame
                if !isResigningFirstResponder,
                   isFirstResponder,
                   window != nil,
                   isActiveForSoftwareKeyboardDismissal,
                   (keyboardFrame?.height ?? 0) > Self.fullSoftwareKeyboardHeightThreshold
                {
                    softwareKeyboardDismissState = .fullPresentation
                    deferredSystemSoftwareKeyboardDismissID = nil
                } else {
                    invalidateSoftwareKeyboardDismissTracking()
                }
                refitViewportForKeyboardChange(reason: "keyboard-show")
            }

            @objc func keyboardDidHide(_: Notification) {
                let tracksSystemDismiss = softwareKeyboardDismissState == .fullPresentation
                    || softwareKeyboardDismissState == .systemResignPending
                let shouldEmitSystemDismiss = tracksSystemDismiss
                    && window != nil
                    && isActiveForSoftwareKeyboardDismissal
                    && !suppressesSoftwareKeyboard

                softwareKeyboardDismissState = .idle
                softwareKeyboardVisible = false
                keyboardFrameEndScreenRect = nil
                refitViewportForKeyboardChange(reason: "keyboard-hide")

                guard shouldEmitSystemDismiss else { return }
                if isFirstResponder, !isResigningFirstResponder {
                    // Some native dismiss keys retain first responder. Suppress
                    // immediately so UIKit cannot reopen the full keyboard.
                    onSystemSoftwareKeyboardDismiss?()
                } else {
                    // If UIKit resigned the terminal, let it finish dismantling its
                    // keyboard host before suppression reclaims first responder.
                    // Re-entering from keyboardDidHide leaves stale bottom chrome.
                    deferSystemSoftwareKeyboardDismissCallback()
                }
            }
        #endif

        func refreshTextInputGeometry(reason: String) {
            guard isFirstResponder || inputHandler.hasMarkedText else { return }
            TerminalDebugLog.log(.ime, "refresh text geometry reason=\(reason)")
            inputHandler.notifyGeometryDidChange(reason: reason)
        }

        func refreshInputAccessoryContent() {
            #if !targetEnvironment(macCatalyst)
                terminalInputAccessory.refreshContent()
            #endif
        }
    }
#endif
