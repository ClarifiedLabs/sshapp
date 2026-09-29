//
//  UITerminalView.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

#if canImport(UIKit)
    import GhosttyVT
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

        public struct TerminalSoftwareKeyboardDiagnostics: Equatable, Sendable {
            public let isFirstResponder: Bool
            public let suppressesSoftwareKeyboard: Bool
            /// "system", "suppression", or "custom".
            public let inputViewKind: String
            public let softwareKeyboardVisible: Bool
            /// Last keyboardDidShow end frame, in screen coordinates.
            public let keyboardFrame: CGRect?
            public let dismissState: String
            public let isPresentingOwnedAlert: Bool
            /// Any view controller (alert or sheet) presented over the terminal.
            public let isUnderPresentation: Bool
            public let isHostVisible: Bool
            /// Native dismissals this terminal classified as the user's.
            public let systemDismissCount: Int
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
        /// Explicit retained-host visibility, independent of keyboard focus.
        /// Hiding suspends presentation and native interaction, never VT ingestion.
        public var isHostVisible = true {
            didSet {
                guard isHostVisible != oldValue else { return }
                hostVisibilityDidChange()
            }
        }

        // SwiftUI reapplies accessibility properties after updateUIView. A
        // retained hidden host must stay excluded even if that pass clears the
        // native property on the representable root.
        override open var accessibilityElementsHidden: Bool {
            get { !isHostVisible || super.accessibilityElementsHidden }
            set { super.accessibilityElementsHidden = !isHostVisible || newValue }
        }

        // accessibilityElementsHidden excludes descendants, not the UITextInput
        // root itself. Preserve UIKit/SwiftUI's requested value for the reveal.
        override open var isAccessibilityElement: Bool {
            get { isHostVisible && super.isAccessibilityElement }
            set { super.isAccessibilityElement = newValue }
        }

        let core = TerminalSurfaceCoordinator()
        lazy var nativePointer = TerminalNativePointerController(view: self)
        #if !targetEnvironment(macCatalyst)
            lazy var nativeInteraction = TerminalNativeInteraction(view: self)
        #endif
        #if DEBUG
            public var selectionDebugConfiguration: TerminalSelectionDebugConfiguration? {
                didSet {
                    selectionDebugConfigurationDidChange(from: oldValue)
                }
            }
            public internal(set) var selectionDebugProbe: TerminalSelectionDebugProbe?
            var selectionDebugLastSemanticSnapshot: TerminalSelectionDebugSnapshot?
            var selectionDebugRevision: UInt64 = 0
            // Nested native lifecycle transitions publish only once their
            // gesture, handle, pointer and loupe state is fully installed.
            var selectionDebugUpdateDepth = 0
        #endif
        #if DEBUG
            public var lifecycleMomentumObserver: ((TerminalLifecycleMomentumSample) -> Void)?
            var lifecycleMomentumGeneration: UInt64 = 0
            var lifecycleMomentumTicks = 0
            var lifecycleMomentumReleaseBoundary: VTPointerReleaseBoundary?
        #endif
        var momentumDisplayLink: CADisplayLink?
        var momentumVelocity: CGPoint = .zero
        static let minFontSize: Float = 1
        static let maxFontSize: Float = 64
        var activePointerButton: TerminalPointerButton? {
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
        var localKeyActionsByKeyCode: [UIKeyboardHIDUsage.RawValue: TerminalLocalKeyLifecycle] = [:]
        var cancelledLocalKeyCodes: Set<UIKeyboardHIDUsage.RawValue> = []
        let touchScrollMultiplier: CGFloat = 3.0
        private var adjustedFontSize: Float = 14
        private var hasExplicitConfiguredFontSize = false
        private var resolvedBaseFontSize: Float {
            hasExplicitConfiguredFontSize
                ? configuredFontSize
                : configuration.fontSize ?? controller?.vtFontSize ?? 14
        }
        // Resolve before each zoom read, including before a surface is mounted.
        // Zoom handlers store their new size before marking it transient.
        var currentFontSize: Float {
            get { isFontSizeTransientlyAdjusted ? adjustedFontSize : resolvedBaseFontSize }
            set { adjustedFontSize = newValue }
        }
        var isFontSizeTransientlyAdjusted = false {
            didSet { updateFontSizeOverride() }
        }
        #if !targetEnvironment(macCatalyst)
            var lastPinchScale: CGFloat = 1.0
            var pinchZoomGesture: UIPinchGestureRecognizer?
            var fontSizeResetTapGesture: UITapGestureRecognizer?
        #endif

        /// The current app-configured font size that a surface-local reset restores.
        ///
        /// Until explicitly assigned, the baseline comes from surface options,
        /// then the controller, then 14 points. Assigning even 14 is an override.
        /// Updating the baseline preserves a user's transient zoom until they reset
        /// it, while unadjusted surfaces track settings changes immediately.
        open var configuredFontSize: Float = 14 {
            didSet {
                let wasExplicit = hasExplicitConfiguredFontSize
                hasExplicitConfiguredFontSize = true
                updateFontSizeOverride()
                if !isFontSizeTransientlyAdjusted {
                    currentFontSize = configuredFontSize
                    if !wasExplicit || configuredFontSize != oldValue { pushVTFont() }
                }
            }
        }

        private func updateFontSizeOverride() {
            if hasExplicitConfiguredFontSize || isFontSizeTransientlyAdjusted {
                core.fontSize = { [weak self] in CGFloat(self?.currentFontSize ?? 14) }
            } else {
                core.fontSize = nil
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
            /// Shortcut-bar groups saved while software-keyboard suppression
            /// empties `inputAssistantItem`, restored verbatim on unsuppress.
            var suppressedInputAssistantBarButtonGroups: (
                leading: [UIBarButtonItemGroup],
                trailing: [UIBarButtonItemGroup]
            )?
            /// A terminal-owned alert (unsafe paste confirmation, paste failure).
            /// Presenting it can resign the terminal or, on large iPads, collapse
            /// the full keyboard to the minimized assistant. Neither is a user
            /// dismissal, so it must never enter persistent keyboard suppression.
            var systemSoftwareKeyboardDismissCount = 0
            weak var ownedAlert: UIAlertController?
            var ownedAlertReclaimsFirstResponder = false
            var isPresentingOwnedAlert: Bool {
                guard let ownedAlert else { return false }
                return ownedAlert.presentingViewController != nil || ownedAlert.isBeingPresented
            }

            /// True while any view controller is presented over the terminal's
            /// hierarchy: an owned alert, or an app sheet such as the
            /// credential-save prompt. Keyboard transitions then belong to the
            /// presentation (resigning the terminal, or collapsing the iPad
            /// keyboard to its minimized assistant), not to a user dismissal.
            var isKeyboardTransitionOwnedByPresentation: Bool {
                if isPresentingOwnedAlert { return true }
                if window?.rootViewController?.presentedViewController != nil { return true }
                var responder: UIResponder? = self
                while let current = responder {
                    if let controller = current as? UIViewController {
                        return controller.presentedViewController != nil
                    }
                    responder = current.next
                }
                return false
            }
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
            /// True only during an admitted UIKit word-selection or native
            /// handle gesture, including a word gesture routed to remote capture.
            /// Ends at UIKit release/cancellation, not at asynchronous completion.
            var selectionGestureActive = false {
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
            /// it during native selection gestures.
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

        #if !targetEnvironment(macCatalyst)
            /// Scalar keyboard ownership state for test diagnostics. Contains
            /// no terminal text or input.
            public var softwareKeyboardDiagnostics: TerminalSoftwareKeyboardDiagnostics {
                TerminalSoftwareKeyboardDiagnostics(
                    isFirstResponder: isFirstResponder,
                    suppressesSoftwareKeyboard: suppressesSoftwareKeyboard,
                    inputViewKind: inputView === softwareKeyboardSuppressionInputView
                        ? "suppression"
                        : (inputView == nil ? "system" : "custom"),
                    softwareKeyboardVisible: softwareKeyboardVisible,
                    keyboardFrame: keyboardFrameEndScreenRect,
                    dismissState: "\(softwareKeyboardDismissState)",
                    isPresentingOwnedAlert: isPresentingOwnedAlert,
                    isUnderPresentation: isKeyboardTransitionOwnedByPresentation,
                    isHostVisible: isHostVisible,
                    systemDismissCount: systemSoftwareKeyboardDismissCount
                )
            }
        #endif

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
                if replacesSurface {
                    resetFontAdjustmentTrackingForSurfaceReplacement()
                }
                core.controller = newValue
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
                // Options (including font size) may rebuild the disposable host
                // without replacing the session or discarding its transient zoom.
                if !newValue.backend.isEquivalent(to: core.configuration.backend) {
                    resetFontAdjustmentTrackingForSurfaceReplacement()
                }
                core.configuration = newValue
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
                self?.surface != nil
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
            currentFontSize = resolvedBaseFontSize
            pushVTFont()
            core.synchronizeMetrics()
            refreshTextInputGeometry(reason: "font-size-reset")
            core.requestImmediateTick()
            UIAccessibility.post(notification: .announcement, argument: "Font size reset")
            return true
        }

        func resetFontAdjustmentTrackingForSurfaceReplacement() {
            isFontSizeTransientlyAdjusted = false
            currentFontSize = resolvedBaseFontSize
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
            isHostVisible && !isHidden && alpha > 0.01 && isUserInteractionEnabled
        }

        override open func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            guard isHostVisible, !isHidden, alpha > 0.01, isUserInteractionEnabled else { return nil }
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
            setupTraitChangeObservers()
            updateDisplayScale()

            core.isAttached = { [weak self] in self?.window != nil }
            core.scaleFactor = { [weak self] in
                Double(self?.resolvedDisplayScale() ?? 1)
            }
            core.viewSize = { [weak self] in
                guard let self else { return (0, 0) }
                let viewport = terminalViewportBounds
                return (viewport.width, viewport.height)
            }
            core.platformOwner = self
            core.onSurfaceCreated = { [weak self] surface in
                self?.installVTContent(surface)
            }
            core.onSurfaceWillDetach = { [weak self] _ in
                // The retained session survives a host rebuild; its cancel must
                // be admitted while view.surface still routes to it.
                self?.cancelNativeInteractions()
            }
            core.onSurfaceFreed = { [weak self] surface in
                self?.cancelLocalKeyActions()
                #if !targetEnvironment(macCatalyst)
                    self?.nativeInteraction.clearSelection(surface: surface)
                #endif
            }
            core.onFrame = { [weak self] frame in
                guard let self else { return }
                #if !targetEnvironment(macCatalyst)
                    synchronizeTouchSelectionOverlayAfterRender()
                #else
                    nativePointer.framePublished(frame)
                #endif
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
                #if !targetEnvironment(macCatalyst)
                    if let frame = surface?.frameValue { nativeInteraction.rendered(frame) }
                #endif
                invalidateTerminalInputMenuAfterRender()
                #if DEBUG
                    refreshSelectionDebugSnapshot()
                #endif
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
            guard surface?.selectionContains(x: point.x, y: point.y) == true else { return nil }
            return point
        }

        open func showSelectionCopyMenu(at point: CGPoint) {
            presentTouchSelectionEditMenu(at: point)
        }

        /// Presents the modern edit menu for direct-touch selection. Pointer
        /// right-click and long-press-on-selection continue to use the existing
        /// context-menu path above.
        open func presentTouchSelectionEditMenu(at point: CGPoint) {
            becomeFirstResponder()
            guard hasHostSelection()
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
            #if !targetEnvironment(macCatalyst)
                return nativeInteraction.copySelection()
            #else
                guard surface?.hasSelection() == true,
                      let operation = surface?.session.enqueueTakeSelectedText() else { return false }
                Task { @MainActor in
                    guard let text = try? await operation.value, !text.isEmpty else { return }
                    UIPasteboard.general.string = text
                }
                return true
            #endif
        }

        open func selectionContextMenuConfiguration(
            at _: CGPoint
        ) -> UIContextMenuConfiguration {
            UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                UIMenu(children: self?.selectionMenuElements() ?? [])
            }
        }

        open func selectionMenuElements() -> [UIMenuElement] {
            #if !targetEnvironment(macCatalyst)
                return nativeInteraction.menuElements()
            #else
                return [UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                    self?.copySelectedTextToPasteboard()
                }]
            #endif
        }

        open func terminalInputMenuElements() -> [UIMenuElement] {
            guard UIPasteboard.general.hasStrings else { return [] }
            let paste = UIAction(
                title: "Paste",
                image: UIImage(systemName: "doc.on.clipboard"),
                // Tell UIKit this is an explicit user paste operation so it
                // can authorize the cross-app pasteboard read in the handler.
                identifier: .paste
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

        func hasHostSelection() -> Bool { surface?.hasSelection() == true }

        private func terminalCursorCellGeometry() -> (cell: CGRect, visibleCell: CGRect)? {
            guard let cell = surface?.frameValue?.cursorRect() else { return nil }
            let visibleCell = cell.intersection(terminalViewportBounds)
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
        /// are rendered by one tick. `completion` runs only if that draw
        /// renders on this host; hidden, detached, or replaced hosts drop it.
        public func requestImmediateDraw(onPostRender completion: (@MainActor () -> Void)? = nil) {
            if let completion { core.requestImmediateDraw(completion: completion) }
            else { core.requestImmediateTick() }
        }

        open func setTerminalSurfaceFocused(_ focused: Bool) {
            guard !focused || isHostVisible else { return }
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
                guard isHostVisible, UIApplication.shared.applicationState == .active else { return false }
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
                // iPad can dismiss the full keyboard by showing only its floating
                // assistant, without sending keyboardDidHide. Preserve the owned
                // presentation until this transition has emitted the dismiss event.
                if let keyboardFrame,
                   keyboardFrame.height <= Self.fullSoftwareKeyboardHeightThreshold,
                   softwareKeyboardDismissState == .fullPresentation,
                   !isKeyboardTransitionOwnedByPresentation,
                   isFirstResponder,
                   !isResigningFirstResponder,
                   window != nil,
                   isActiveForSoftwareKeyboardDismissal
                {
                    keyboardDidHide(notification)
                    return
                }
                softwareKeyboardVisible = true
                keyboardFrameEndScreenRect = keyboardFrame
                if !isResigningFirstResponder,
                   isFirstResponder,
                   window != nil,
                   !isKeyboardTransitionOwnedByPresentation,
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
                    && !isKeyboardTransitionOwnedByPresentation
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
                    systemSoftwareKeyboardDismissCount += 1
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
