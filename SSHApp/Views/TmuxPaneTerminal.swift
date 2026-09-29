import Foundation
import SwiftUI
import UIKit
import GhosttyTerminal
import os

private let logger = Logger(subsystem: "dev.sshapp.sshapp", category: "TmuxPaneTerminal")

/// Per-pane libghostty terminal for tmux -CC mode.
///
/// Mirrors `GhosttyTerminalView` but binds a single `TmuxPane` to a
/// `UITerminalView`. The pane sink is installed only after Ghostty reports a
/// live surface, so snapshots remain pane-owned across initial construction.
/// Thereafter the model keeps ingesting while UIKit hosts detach or change.
/// User input is routed through
/// `controller.sendKeys(to:data:)` to THIS pane (not necessarily the
/// globally-active one). Initial input focus is claimed by the active pane after
/// its surface attaches; later touch focus is reported via `onFocusChange`.
/// Resize is inferred against the owning window layout and sent through
/// `controller.refreshWindow`. Title updates set `pane.title`.
struct TmuxPaneTerminal: UIViewRepresentable {
    let controller: TmuxController
    let pane: TmuxPane
    let hostTabID: UUID
    var isFocused: Bool
    var isHostVisible = true
    var onFocus: () -> Void
    var showsKeyboardBar: Bool
    var suppressesSoftwareKeyboard: Bool
    var keyboardBarTarget: TerminalKeyboardBarTarget?
    var hardwareKeyRepeatConfiguration: TerminalHardwareKeyRepeatConfiguration
    var configuredFontSize: Float
    let fontSizeTargetRegistry: TerminalFontSizeTargetRegistry
    var onShortcut: (TerminalTabShortcut) -> Void
    var onHostSessionInteraction: () -> Void
    var onSystemSoftwareKeyboardDismiss: () -> Void = {}
    var onPostFlushDraw: (@MainActor () -> Void)? = nil

    func makeUIView(context: Context) -> ShortcutAwareTerminalView {
        let coordinator = context.coordinator
        let tv = ShortcutAwareTerminalView(frame: .zero)
        coordinator.onSystemSoftwareKeyboardDismiss = onSystemSoftwareKeyboardDismiss
        tv.onSystemSoftwareKeyboardDismiss = { [weak coordinator, weak tv] in
            guard let tv else { return }
            coordinator?.handleSystemSoftwareKeyboardDismiss(from: tv)
        }
        coordinator.updateHostVisibility(isHostVisible, view: tv)
        tv.configuredFontSize = configuredFontSize
        tv.suppressesSoftwareKeyboard = suppressesSoftwareKeyboard

        coordinator.controller = controller
        coordinator.pane = pane
        coordinator.updateKeyboardBarTarget(keyboardBarTarget)
        coordinator.updateFocusedState(isFocused)
        coordinator.onFocus = onFocus
        coordinator.onHostSessionInteraction = onHostSessionInteraction
        coordinator.onPostFlushDraw = onPostFlushDraw
        coordinator.bindTerminalSession()
        coordinator.updateFontSizeTarget(
            registry: fontSizeTargetRegistry,
            key: .tmuxPane(tabID: hostTabID, paneID: pane.id),
            view: tv
        )

        tv.delegate = coordinator
        tv.controller = TerminalRuntime.shared.controller
        tv.configuration = TerminalSurfaceOptions(backend: .vt(coordinator.terminalSession!))
        tv.hardwareKeyRepeatConfiguration = hardwareKeyRepeatConfiguration
        configureShortcuts(on: tv)
        tv.onSoftwareKeyboardReturn = { [weak coordinator] in
            coordinator?.forwardSoftwareKeyboardReturn()
        }
        coordinator.applyAccessory(to: tv, showsBar: showsKeyboardBar)

        return tv
    }

    func updateUIView(_ uiView: ShortcutAwareTerminalView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSystemSoftwareKeyboardDismiss = onSystemSoftwareKeyboardDismiss
        coordinator.updateHostVisibility(isHostVisible, view: uiView)
        uiView.configuredFontSize = configuredFontSize
        uiView.suppressesSoftwareKeyboard = suppressesSoftwareKeyboard
        coordinator.onFocus = onFocus
        coordinator.onHostSessionInteraction = onHostSessionInteraction
        coordinator.onPostFlushDraw = onPostFlushDraw
        coordinator.controller = controller
        coordinator.updateFontSizeTarget(
            registry: fontSizeTargetRegistry,
            key: .tmuxPane(tabID: hostTabID, paneID: pane.id),
            view: uiView
        )
        coordinator.updateKeyboardBarTarget(keyboardBarTarget)
        coordinator.updateFocusedState(isFocused)
        configureShortcuts(on: uiView)
        uiView.hardwareKeyRepeatConfiguration = hardwareKeyRepeatConfiguration
        coordinator.applyAccessory(to: uiView, showsBar: showsKeyboardBar)

        // Re-wire if the bound pane changed (e.g. SwiftUI reused this view for a
        // different pane). Clear the old sink so its buffer doesn't leak into the
        // new view's stream, then point at the new pane.
        if coordinator.pane !== pane {
            coordinator.replacePane(pane)
        }
        coordinator.requestFirstResponderIfReady()
    }

    static func dismantleUIView(_ uiView: ShortcutAwareTerminalView, coordinator: Coordinator) {
        coordinator.unregisterFontSizeTarget(view: uiView)
        coordinator.detachKeyboardBarTarget(from: uiView)
        uiView.onShortcut = nil
        uiView.onSoftwareKeyboardReturn = nil
        uiView.onSystemSoftwareKeyboardDismiss = nil
        coordinator.onSystemSoftwareKeyboardDismiss = nil
        uiView.enabledShortcutScopes = []
        uiView.prefersTmuxWindowNumberShortcuts = false
        coordinator.prepareForDismantle()
        // Start native retirement while UIKit still strongly owns the platform
        // pointer passed unretained to Ghostty.
        uiView.controller = nil
        coordinator.terminalSession = nil
        coordinator.controller = nil
        coordinator.pane = nil
        coordinator.onFocus = nil
        coordinator.onHostSessionInteraction = nil
        coordinator.onPostFlushDraw = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func configureShortcuts(on terminalView: ShortcutAwareTerminalView) {
        terminalView.enabledShortcutScopes = isFocused ? [.hostTabs, .tmuxWindows] : []
        terminalView.prefersTmuxWindowNumberShortcuts = isFocused
        terminalView.onShortcut = onShortcut
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject {
        var controller: TmuxController?
        var pane: TmuxPane?
        var isFocused = false
        private(set) var isHostVisible = true
        private var hostVisibilityGeneration = 0
        var onFocus: (() -> Void)?
        var onHostSessionInteraction: (() -> Void)?
        var onSystemSoftwareKeyboardDismiss: (() -> Void)?
        var onPostFlushDraw: (@MainActor () -> Void)?
        var terminalSession: VTTerminalSession? {
            didSet {
                if let terminalSession { outputDelivery.setReceiver(terminalSession) }
            }
        }
        var sinkToken: UUID?
        weak var terminalView: UITerminalView?
        private weak var fontSizeTargetView: UITerminalView?
        private weak var fontSizeTargetRegistry: TerminalFontSizeTargetRegistry?
        private var fontSizeTargetKey: TerminalFontSizeTargetKey?
        private var keyboardBarTarget: TerminalKeyboardBarTarget?
        private var surfaceAttached = false
        private var viewportReady = false
        private var surfaceRequiresRestore = false
        private var surfaceBindingGeneration = 0
        private var surfaceRestoreTask: Task<Void, Never>?

        /// Package-internal injection seam for the recreated-surface restore
        /// pipeline. When set, it replaces the controller snapshot pipeline so
        /// tests can deterministically fail or defer a restoration.
        var restorePaneForRecreatedSurfaceOverride: ((TmuxPaneID) async -> Bool)?
        /// Allows readiness tests to complete the native render fence explicitly.
        var requestImmediateDrawOverride: ((@escaping @MainActor () -> Void) -> Void)?
        private var outputReadinessGeneration = 0
        private let viewportReadiness = TerminalViewportReadinessGate()
        private var hasRequestedFirstResponderForCurrentFocus = false
        private var firstResponderRequestScheduled = false
        private var firstResponderRequestGeneration = 0
        private var hasPerformedInitialFocusReload = false
        private var outputDelivery = TerminalOutputDeliveryQueue()
        private var terminalLifetime: TerminalSemanticLifetime?

        func bindTerminalSession() {
            guard let pane else { return }
            let lifetime = pane.terminalLifetime ?? TerminalSemanticLifetime()
            pane.terminalLifetime = lifetime
            terminalLifetime = lifetime
            outputDelivery = lifetime.outputDelivery
            lifetime.bind(owner: self, write: { [weak self] in self?.forwardFromTerminal($0) },
                          resize: { [weak self] in self?.handleResize(cols: Int($0.columns), rows: Int($0.rows)) },
                          detachedWrite: { [weak controller, weak pane] data in
                              guard let controller, let pane else { return }
                              let paneID = pane.id
                              let bytes = TerminalInputNormalizer.normalize(data)
                              Task { await controller.sendKeys(to: paneID, data: bytes) }
                          })
            terminalSession = lifetime.session
            terminalView?.configuration = TerminalSurfaceOptions(backend: .vt(lifetime.session))
        }

        func updateFontSizeTarget(
            registry: TerminalFontSizeTargetRegistry,
            key: TerminalFontSizeTargetKey,
            view: UITerminalView
        ) {
            if fontSizeTargetRegistry === registry,
               fontSizeTargetKey == key,
               fontSizeTargetView === view {
                return
            }

            if let oldRegistry = fontSizeTargetRegistry,
               let oldKey = fontSizeTargetKey,
               let oldView = fontSizeTargetView {
                oldRegistry.unregister(oldView, for: oldKey)
            }

            fontSizeTargetRegistry = registry
            fontSizeTargetKey = key
            fontSizeTargetView = view
            registry.register(view, for: key)
        }

        func unregisterFontSizeTarget(view: UITerminalView) {
            guard fontSizeTargetView === view else { return }
            if let registry = fontSizeTargetRegistry, let key = fontSizeTargetKey {
                registry.unregister(view, for: key)
            }
            fontSizeTargetView = nil
            fontSizeTargetRegistry = nil
            fontSizeTargetKey = nil
        }

        func applyAccessory(to tv: UITerminalView, showsBar _: Bool) {
            terminalView = tv
            #if !targetEnvironment(macCatalyst)
            if tv.usesSystemInputAccessory {
                tv.usesSystemInputAccessory = false
            }
            #endif
            syncTerminalSurfaceFocus()
            syncKeyboardBarTarget()
        }

        func updateKeyboardBarTarget(_ target: TerminalKeyboardBarTarget?) {
            guard keyboardBarTarget !== target else {
                syncKeyboardBarTarget()
                return
            }
            keyboardBarTarget?.detach(terminalView)
            keyboardBarTarget = target
            syncKeyboardBarTarget()
        }

        func detachKeyboardBarTarget(from tv: UITerminalView) {
            keyboardBarTarget?.detach(tv)
        }

        func markSurfaceAttached() {
            guard !surfaceAttached else { return }
            surfaceAttached = true
            viewportReady = false
            terminalLifetime?.setOutputReady(false, owner: self)
            surfaceBindingGeneration += 1
            let generation = surfaceBindingGeneration
            if terminalLifetime == nil { bindTerminalSession() }
            if terminalLifetime?.requiresPaneRestore == nil {
                terminalLifetime?.requiresPaneRestore = pane?.registerTerminalSurfaceAttachment() == true || pane?.needsOutputRecovery == true
            }
            surfaceRequiresRestore = terminalLifetime?.requiresPaneRestore == true
            beginViewportSettle(for: generation)
            syncTerminalSurfaceFocus()
            requestFirstResponderIfReady()
        }

        func markSurfaceDetached() {
            guard surfaceAttached else { return }
            surfaceAttached = false
            viewportReady = false
            surfaceRequiresRestore = false
            surfaceBindingGeneration += 1
            viewportReadiness.invalidate()
            surfaceRestoreTask?.cancel()
            surfaceRestoreTask = nil
            clearPaneSink()
            terminalLifetime?.setOutputReady(false, owner: self)
            cancelFirstResponderRetry()
        }

        func replacePane(_ replacement: TmuxPane) {
            guard pane !== replacement else { return }

            surfaceBindingGeneration += 1
            viewportReady = false
            surfaceRequiresRestore = true
            surfaceRestoreTask?.cancel()
            surfaceRestoreTask = nil
            clearPaneSink()
            terminalLifetime?.setOutputReady(false, owner: self)
            terminalLifetime?.unbind(owner: self)
            pane = replacement
            bindTerminalSession()
            if terminalLifetime?.requiresPaneRestore == nil {
                terminalLifetime?.requiresPaneRestore = replacement.registerTerminalSurfaceAttachment()
            }
            surfaceRequiresRestore = terminalLifetime?.requiresPaneRestore == true
            resetFirstResponderRequest()

            guard surfaceAttached else {
                viewportReadiness.invalidate()
                return
            }
            beginViewportSettle(for: surfaceBindingGeneration)
        }

        func prepareForDismantle() {
            surfaceAttached = false
            viewportReady = false
            surfaceRequiresRestore = false
            surfaceBindingGeneration += 1
            viewportReadiness.invalidate()
            surfaceRestoreTask?.cancel()
            surfaceRestoreTask = nil
            clearPaneSink()
            terminalLifetime?.setOutputReady(false, owner: self)
            cancelFirstResponderRetry()
            terminalLifetime?.unbind(owner: self)
            terminalLifetime = nil
        }

        private func beginViewportSettle(for bindingGeneration: Int) {
            if let pane, pane.cols > 0, pane.rows > 0 {
                viewportReadiness.measurementDidChange()
            }
            viewportReadiness.begin(
                fitViewport: { [weak self] in
                    self?.terminalView?.fitToSize()
                },
                onReady: { [weak self] readinessGeneration in
                    self?.viewportDidSettle(
                        bindingGeneration: bindingGeneration,
                        readinessGeneration: readinessGeneration
                    )
                }
            )
        }

        private func viewportDidSettle(
            bindingGeneration: Int,
            readinessGeneration: Int
        ) {
            guard surfaceAttached,
                  surfaceBindingGeneration == bindingGeneration,
                  viewportReadiness.generation == readinessGeneration else {
                return
            }

            viewportReady = true
            // Gap recovery belongs to the semantic sink, including overflow
            // during layout after markSurfaceAttached cached its restore flag.
            if surfaceRequiresRestore && pane?.requiresOutputRecovery != true {
                restoreAndBindPane(for: bindingGeneration)
            } else {
                bindPaneSinkAndOpenOutputIfCurrent(generation: bindingGeneration)
            }
        }

        private func bindPaneSinkIfCurrent(generation: Int) {
            guard surfaceAttached,
                  viewportReady,
                  surfaceBindingGeneration == generation,
                  sinkToken == nil,
                  terminalLifetime?.ownsHost(self) == true,
                  let pane else {
                return
            }

            let restoreOverride = restorePaneForRecreatedSurfaceOverride
            sinkToken = pane.installSemanticSink(onOutputRecovered: { [weak self] in
                self?.bindPaneSinkAndOpenOutputIfCurrent(generation: generation)
            }) { [weak controller, weak pane] in
                guard let pane else { return false }
                if let restoreOverride { return await restoreOverride(pane.id) }
                guard let controller else { return false }
                return await controller.restorePaneForRecreatedSurface(pane.id)
            }
        }

        private func bindPaneSinkAndOpenOutputIfCurrent(generation: Int) {
            bindPaneSinkIfCurrent(generation: generation)
            guard surfaceAttached,
                  viewportReady,
                  surfaceBindingGeneration == generation,
                  terminalLifetime?.ownsHost(self) == true,
                  sinkToken != nil else {
                return
            }

            outputReadinessGeneration += 1
            let outputGeneration = outputReadinessGeneration
            // A pre-sink gap can have an empty delivery queue. Its drain barrier
            // must not fire before recovery, nor be discarded by snapshot reset.
            guard pane?.requiresOutputRecovery == false else { return }
            let readinessGeneration = viewportReadiness.generation
            terminalLifetime?.setOutputReady(true, owner: self, onDrain: { [weak self] in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.requestPostFlushDraw(
                            bindingGeneration: generation,
                            readinessGeneration: readinessGeneration,
                            outputGeneration: outputGeneration
                        )
                    }
                }
            })
        }

        private func requestPostFlushDraw(
            bindingGeneration: Int,
            readinessGeneration: Int,
            outputGeneration: Int
        ) {
            guard surfaceAttached,
                  viewportReady,
                  pane?.requiresOutputRecovery == false,
                  outputReadinessGeneration == outputGeneration,
                  terminalLifetime?.ownsHost(self) == true,
                  surfaceBindingGeneration == bindingGeneration,
                  viewportReadiness.generation == readinessGeneration else {
                return
            }
            let completion: @MainActor () -> Void = { [weak self] in
                guard let self,
                      self.surfaceAttached,
                      self.viewportReady,
                      self.pane?.requiresOutputRecovery == false,
                      self.outputReadinessGeneration == outputGeneration,
                      self.terminalLifetime?.ownsHost(self) == true,
                      self.surfaceBindingGeneration == bindingGeneration,
                      self.viewportReadiness.generation == readinessGeneration else {
                    return
                }
                self.onPostFlushDraw?()
            }
            if let requestImmediateDrawOverride {
                requestImmediateDrawOverride(completion)
            } else {
                terminalView?.requestImmediateDraw(onPostRender: completion)
            }
        }

        private func clearPaneSink() {
            // Only drop this host's handle; model ingestion survives detach.
            sinkToken = nil
        }

        private func restoreAndBindPane(for generation: Int) {
            guard let pane else {
                bindPaneSinkIfCurrent(generation: generation)
                return
            }

            let restorePaneID = pane.id
            surfaceRestoreTask?.cancel()
            surfaceRestoreTask = Task { @MainActor [weak self, weak controller, weak pane] in
                let restored: Bool
                if let injectedRestore = self?.restorePaneForRecreatedSurfaceOverride {
                    restored = await injectedRestore(restorePaneID)
                } else if let controller {
                    restored = await controller.restorePaneForRecreatedSurface(restorePaneID)
                } else {
                    restored = false
                }
                self?.finishPaneRestore(
                    bindingGeneration: generation,
                    pane: pane,
                    restored: restored
                )
            }
        }

        /// Completes a recreated-surface restoration for a binding generation.
        ///
        /// Restoration succeeds when an authoritative snapshot was rendered.
        /// It deliberately fails open: when the surface and pane are still
        /// current but no authoritative snapshot could be captured, live
        /// output is bound and opened anyway so the pane cannot stay gated
        /// forever on a degraded tmux link. A known output gap is different:
        /// the semantic sink stays closed until an authoritative recovery.
        func finishPaneRestore(bindingGeneration: Int, pane: TmuxPane?, restored: Bool) {
            guard !Task.isCancelled,
                  surfaceAttached,
                  surfaceBindingGeneration == bindingGeneration,
                  self.pane === pane else {
                return
            }

            surfaceRestoreTask = nil
            guard pane?.requiresOutputRecovery != true else {
                // A gap arising during restoration must still install the
                // model-owned sink so recovery (and a later Resume) can finish.
                bindPaneSinkAndOpenOutputIfCurrent(generation: bindingGeneration)
                return
            }
            surfaceRequiresRestore = false
            terminalLifetime?.requiresPaneRestore = false
            if !restored {
                logger.warning(
                    "tmux recreated-surface restore failed; opening live output without an authoritative snapshot"
                )
            }
            bindPaneSinkAndOpenOutputIfCurrent(generation: bindingGeneration)
        }

        func handleSystemSoftwareKeyboardDismiss(from source: UITerminalView) {
            guard isHostVisible,
                  surfaceAttached,
                  isFocused,
                  terminalView === source else {
                return
            }
            onSystemSoftwareKeyboardDismiss?()
        }

        /// Visibility owns UIKit admission, not the pane's semantic lifetime.
        /// A visible but nonfocused split must remain available for touch focus.
        func updateHostVisibility(_ visible: Bool, view: UITerminalView) {
            terminalView = view
            if isHostVisible != visible {
                hostVisibilityGeneration += 1
                resetFirstResponderRequest()
            }
            isHostVisible = visible
            view.isHostVisible = visible
            if !visible {
                keyboardBarTarget?.detach(view)
                syncTerminalSurfaceFocus()
            }
        }

        func updateFocusedState(_ focused: Bool) {
            if isFocused && !focused {
                hasRequestedFirstResponderForCurrentFocus = false
                cancelFirstResponderRetry()
                keyboardBarTarget?.detach(terminalView)
                terminalView?.resignFirstResponderForApplicationAction()
            }
            isFocused = focused
            syncTerminalSurfaceFocus()
            syncKeyboardBarTarget()
            requestFirstResponderIfReady()
        }

        private func syncKeyboardBarTarget() {
            guard isHostVisible, isFocused else {
                keyboardBarTarget?.detach(terminalView)
                return
            }
            keyboardBarTarget?.attach(terminalView)
        }

        private func syncTerminalSurfaceFocus() {
            terminalView?.setTerminalSurfaceFocused(isHostVisible && isFocused)
        }

        func resetFirstResponderRequest() {
            hasRequestedFirstResponderForCurrentFocus = false
            cancelFirstResponderRetry()
        }

        func cancelFirstResponderRetry() {
            firstResponderRequestScheduled = false
            firstResponderRequestGeneration += 1
        }

        func requestFirstResponderIfReady() {
            guard isHostVisible, surfaceAttached, isFocused, !hasRequestedFirstResponderForCurrentFocus else { return }
            scheduleFirstResponderRequest(after: .nanoseconds(0))
        }

        private func scheduleFirstResponderRequest(after delay: DispatchTimeInterval) {
            guard !firstResponderRequestScheduled else { return }
            firstResponderRequestScheduled = true
            let generation = firstResponderRequestGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.firstResponderRequestGeneration == generation else { return }
                self.firstResponderRequestScheduled = false
                self.attemptFirstResponderIfReady()
            }
        }

        private func attemptFirstResponderIfReady() {
            guard isHostVisible, surfaceAttached, isFocused, !hasRequestedFirstResponderForCurrentFocus else { return }
            guard let terminalView else { return }

            if terminalView.isFirstResponder || terminalView.becomeFirstResponder() {
                hasRequestedFirstResponderForCurrentFocus = true
                return
            }

            scheduleFirstResponderRequest(after: .milliseconds(50))
        }

        func receiveFromPane(_ data: Data) {
            outputDelivery.enqueue(data)
        }

        // MARK: - Resize

        func handleResize(cols: Int, rows: Int) {
            guard cols > 0, rows > 0 else { return }
            viewportReadiness.measurementDidChange()
            pane?.cols = cols
            pane?.rows = rows
            refreshWindowSizeFromPane(cols: cols, rows: rows)
        }

        private func refreshWindowSizeFromPane(cols: Int, rows: Int) {
            guard let controller,
                  let pane,
                  let window = controller.windows[pane.windowID],
                  let layout = window.displayLayout,
                  let placement = layout.panePlacements.first(where: { $0.id == pane.id }),
                  placement.frame.cols > 0,
                  placement.frame.rows > 0
            else { return }

            let windowCols = max(
                1,
                Int((Double(cols) * Double(layout.frame.cols) / Double(placement.frame.cols)).rounded())
            )
            let windowRows = max(
                1,
                Int((Double(rows) * Double(layout.frame.rows) / Double(placement.frame.rows)).rounded())
            )
            controller.refreshWindow(window.id, cols: windowCols, rows: windowRows)
        }

        // MARK: - Input router (per-pane)

        /// Route raw terminal-originated bytes to THIS pane via the gateway.
        /// Unlike `controller.sendKeysToActivePane`, this targets the pane this
        /// view represents. Do not mutate controller focus here: Ghostty can
        /// write automatic terminal replies while rendering remote output from
        /// a hidden pane, and those replies must not reactivate the hidden tmux
        /// window. Touch focus is handled by `terminalDidChangeFocus`.
        func forwardFromTerminal(_ data: Data) {
            guard let controller, let pane else {
                logger.warning("forwardFromTerminal: controller or pane is nil, dropping \(data.count)B")
                return
            }
            let paneID = pane.id
            let normalizedData = TerminalInputNormalizer.normalize(data)
            #if DEBUG
            LiveSSHUITestInputObservation.shared.receivedInput()
            #endif
            onHostSessionInteraction?()
            Task {
                await controller.sendKeys(to: paneID, data: normalizedData)
            }
        }

        func forwardSoftwareKeyboardReturn() {
            guard isHostVisible, isFocused else { return }
            terminalSession?.enqueueInput(.text("\r"))
        }
    }
}

// MARK: - libghostty surface delegate

extension TmuxPaneTerminal.Coordinator:
    TerminalSurfaceTitleDelegate,
    TerminalSurfaceBellDelegate,
    TerminalSurfaceFocusDelegate,
    TerminalSurfaceLifecycleDelegate,
    TerminalSurfaceOpenURLDelegate {

    func terminalDidChangeTitle(_ title: String) {
        pane?.title = title
    }

    /// libghostty's `UITerminalView` becomes first responder on touch and
    /// reports focus here; keep the controller's active pane in sync. The
    /// first time a pane is focused, also force a deferred viewport refresh so
    /// Ghostty refits after the host keyboard bar's bottom inset has settled
    /// (see `GhosttyTerminalView`'s matching fix for the non-tmux path).
    func terminalDidChangeFocus(_ focused: Bool) {
        guard focused, isHostVisible else { return }
        keyboardBarTarget?.attach(terminalView)
        onFocus?()
        guard !hasPerformedInitialFocusReload else { return }
        hasPerformedInitialFocusReload = true
        let generation = hostVisibilityGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isHostVisible,
                  self.hostVisibilityGeneration == generation else { return }
            self.terminalView?.refreshInputAccessoryViewport()
        }
    }

    func terminalDidRingBell() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    func terminalDidRequestOpenURL(_ url: String, kind _: TerminalOpenURLKind) {
        TerminalLinkOpener.open(url)
    }

    func terminalDidAttachSurface(_ surface: TerminalSurface) {
        markSurfaceAttached()
    }

    func terminalDidDetachSurface() {
        markSurfaceDetached()
    }
}
