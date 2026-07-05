import Foundation
import SwiftUI
import UIKit
import GhosttyTerminal
import os

private let logger = Logger(subsystem: "dev.sshapp.sshapp", category: "TmuxPaneTerminal")

/// Per-pane libghostty terminal for tmux -CC mode.
///
/// Mirrors `GhosttyTerminalView` but binds a single `TmuxPane` to a
/// `UITerminalView`. Bytes flow via `pane.setSink` (which replays bytes buffered
/// before the sink landed, avoiding the attach-race) into the pane's own
/// `InMemoryTerminalSession`. User input is routed through
/// `controller.sendKeys(to:data:)` to THIS pane (not necessarily the
/// globally-active one). Initial input focus is claimed by the active pane after
/// its surface attaches; later touch focus is reported via `onFocusChange`.
/// Resize is inferred against the owning window layout and sent through
/// `controller.refreshWindow`. Title updates set `pane.title`.
struct TmuxPaneTerminal: UIViewRepresentable {
    let controller: TmuxController
    let pane: TmuxPane
    var isFocused: Bool
    var onFocus: () -> Void
    var showsKeyboardBar: Bool
    var keyboardBarTarget: TerminalKeyboardBarTarget?
    var onShortcut: (TerminalTabShortcut) -> Void
    var onHostSessionInteraction: () -> Void

    func makeUIView(context: Context) -> ShortcutAwareTerminalView {
        let coordinator = context.coordinator
        let tv = ShortcutAwareTerminalView(frame: .zero)

        let imSession = InMemoryTerminalSession(
            write: { [weak coordinator] data in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { coordinator?.forwardFromTerminal(data) }
                }
            },
            resize: { [weak coordinator] viewport in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        coordinator?.handleResize(
                            cols: Int(viewport.columns),
                            rows: Int(viewport.rows)
                        )
                    }
                }
            }
        )

        coordinator.controller = controller
        coordinator.pane = pane
        coordinator.updateKeyboardBarTarget(keyboardBarTarget)
        coordinator.updateFocusedState(isFocused)
        coordinator.onFocus = onFocus
        coordinator.onHostSessionInteraction = onHostSessionInteraction
        coordinator.terminalSession = imSession

        tv.delegate = coordinator
        tv.controller = TerminalRuntime.shared.controller
        tv.configuration = TerminalSurfaceOptions(backend: .inMemory(imSession))
        configureShortcuts(on: tv)
        tv.onSoftwareKeyboardReturn = { [weak coordinator] in
            coordinator?.forwardSoftwareKeyboardReturn()
        }
        coordinator.applyAccessory(to: tv, showsBar: showsKeyboardBar)

        // Wire pane output → terminal. setSink also replays any bytes the pane
        // buffered before this view existed (attach-race avoidance).
        coordinator.sinkToken = pane.setSink { [weak coordinator] data in
            coordinator?.receiveFromPane(data)
        }

        return tv
    }

    func updateUIView(_ uiView: ShortcutAwareTerminalView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onFocus = onFocus
        coordinator.onHostSessionInteraction = onHostSessionInteraction
        coordinator.controller = controller
        coordinator.updateKeyboardBarTarget(keyboardBarTarget)
        coordinator.updateFocusedState(isFocused)
        configureShortcuts(on: uiView)
        coordinator.applyAccessory(to: uiView, showsBar: showsKeyboardBar)

        // Re-wire if the bound pane changed (e.g. SwiftUI reused this view for a
        // different pane). Clear the old sink so its buffer doesn't leak into the
        // new view's stream, then point at the new pane.
        if coordinator.pane?.id != pane.id {
            coordinator.pane?.clearSink(coordinator.sinkToken)
            coordinator.pane = pane
            coordinator.resetFirstResponderRequest()
            coordinator.resetPendingOutputBeforeSurfaceAttach()
            coordinator.sinkToken = pane.setSink { [weak coordinator] data in
                coordinator?.receiveFromPane(data)
            }
        }
        coordinator.requestFirstResponderIfReady()
    }

    static func dismantleUIView(_ uiView: ShortcutAwareTerminalView, coordinator: Coordinator) {
        coordinator.detachKeyboardBarTarget(from: uiView)
        uiView.onShortcut = nil
        uiView.onSoftwareKeyboardReturn = nil
        uiView.enabledShortcutScopes = []
        uiView.prefersTmuxWindowNumberShortcuts = false
        coordinator.pane?.clearSink(coordinator.sinkToken)
        coordinator.sinkToken = nil
        coordinator.terminalSession = nil
        coordinator.controller = nil
        coordinator.pane = nil
        coordinator.onFocus = nil
        coordinator.onHostSessionInteraction = nil
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
        var onFocus: (() -> Void)?
        var onHostSessionInteraction: (() -> Void)?
        var terminalSession: InMemoryTerminalSession?
        var sinkToken: UUID?
        weak var terminalView: UITerminalView?
        private var keyboardBarTarget: TerminalKeyboardBarTarget?
        private var surfaceAttached = false
        private var hasRequestedFirstResponderForCurrentFocus = false
        private var hasPerformedInitialFocusReload = false
        private var pendingOutputBeforeSurfaceAttach = Data()

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
            surfaceAttached = true
            syncTerminalSurfaceFocus()
            flushPendingOutputIfReady()
            requestFirstResponderIfReady()
        }

        func markSurfaceDetached() {
            surfaceAttached = false
        }

        func updateFocusedState(_ focused: Bool) {
            if isFocused && !focused {
                hasRequestedFirstResponderForCurrentFocus = false
                keyboardBarTarget?.detach(terminalView)
                terminalView?.resignFirstResponder()
            }
            isFocused = focused
            syncTerminalSurfaceFocus()
            syncKeyboardBarTarget()
            requestFirstResponderIfReady()
        }

        private func syncKeyboardBarTarget() {
            guard isFocused else {
                keyboardBarTarget?.detach(terminalView)
                return
            }
            keyboardBarTarget?.attach(terminalView)
        }

        private func syncTerminalSurfaceFocus() {
            terminalView?.setTerminalSurfaceFocused(isFocused)
        }

        func resetFirstResponderRequest() {
            hasRequestedFirstResponderForCurrentFocus = false
        }

        func resetPendingOutputBeforeSurfaceAttach() {
            pendingOutputBeforeSurfaceAttach.removeAll()
        }

        func requestFirstResponderIfReady() {
            guard surfaceAttached, isFocused, !hasRequestedFirstResponderForCurrentFocus else { return }
            hasRequestedFirstResponderForCurrentFocus = true
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isFocused else { return }
                _ = self.terminalView?.becomeFirstResponder()
            }
        }

        func receiveFromPane(_ data: Data) {
            guard surfaceAttached, let terminalSession else {
                pendingOutputBeforeSurfaceAttach.append(data)
                return
            }
            terminalSession.receive(data)
        }

        private func flushPendingOutputIfReady() {
            guard surfaceAttached,
                  let terminalSession,
                  !pendingOutputBeforeSurfaceAttach.isEmpty
            else {
                return
            }
            terminalSession.receive(pendingOutputBeforeSurfaceAttach)
            pendingOutputBeforeSurfaceAttach.removeAll()
        }

        // MARK: - Resize

        func handleResize(cols: Int, rows: Int) {
            guard cols > 0, rows > 0 else { return }
            pane?.cols = cols
            pane?.rows = rows
            refreshWindowSizeFromPane(cols: cols, rows: rows)
        }

        private func refreshWindowSizeFromPane(cols: Int, rows: Int) {
            guard let controller,
                  let pane,
                  let window = controller.windows[pane.windowID],
                  let layout = window.displayLayoutNode,
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

        /// Route raw input bytes to THIS pane via the gateway. Unlike
        /// `controller.sendKeysToActivePane`, this targets the pane this view
        /// represents — important because the active pane may be a different one
        /// when the user types into a non-focused split.
        func forwardFromTerminal(_ data: Data) {
            guard let controller, let pane else {
                logger.warning("forwardFromTerminal: controller or pane is nil, dropping \(data.count)B")
                return
            }
            let paneID = pane.id
            let normalizedData = TerminalInputNormalizer.normalize(data)
            onHostSessionInteraction?()
            controller.focusPane(paneID)
            Task {
                await controller.sendKeys(to: paneID, data: normalizedData)
            }
        }

        func forwardSoftwareKeyboardReturn() {
            terminalSession?.sendInput(Data([0x0D]))
        }
    }
}

// MARK: - libghostty surface delegate

extension TmuxPaneTerminal.Coordinator:
    TerminalSurfaceTitleDelegate,
    TerminalSurfaceBellDelegate,
    TerminalSurfaceFocusDelegate,
    TerminalSurfaceLifecycleDelegate {

    func terminalDidChangeTitle(_ title: String) {
        pane?.title = title
    }

    /// libghostty's `UITerminalView` becomes first responder on touch and
    /// reports focus here; keep the controller's active pane in sync. The
    /// first time a pane is focused, also force a deferred viewport refresh so
    /// Ghostty refits after the host keyboard bar's bottom inset has settled
    /// (see `GhosttyTerminalView`'s matching fix for the non-tmux path).
    func terminalDidChangeFocus(_ focused: Bool) {
        guard focused else { return }
        keyboardBarTarget?.attach(terminalView)
        onFocus?()
        guard !hasPerformedInitialFocusReload else { return }
        hasPerformedInitialFocusReload = true
        DispatchQueue.main.async { [weak self] in
            self?.terminalView?.refreshInputAccessoryViewport()
        }
    }

    func terminalDidRingBell() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    func terminalDidAttachSurface(_ surface: TerminalSurface) {
        markSurfaceAttached()
    }

    func terminalDidDetachSurface() {
        markSurfaceDetached()
    }
}
