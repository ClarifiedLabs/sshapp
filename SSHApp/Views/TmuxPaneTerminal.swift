import Foundation
import SwiftUI
import UIKit
import GhosttyTerminal
import os

private let logger = Logger(subsystem: "dev.sshapp.sshapp", category: "TmuxPaneTerminal")

protocol TerminalOutputReceiver: AnyObject, Sendable {
    func receive(_ data: Data)
}

extension InMemoryTerminalSession: TerminalOutputReceiver {}

/// Delivers tmux pane bytes without synchronously entering Ghostty from the
/// SwiftUI view update path. `ghostty_surface_write_buffer` can block on an
/// internal futex during scene transitions, so the main actor only enqueues.
final class TmuxPaneTerminalOutputDeliveryQueue: @unchecked Sendable {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private weak var receiver: (any TerminalOutputReceiver)?
    private var isSurfaceAttached = false
    private var pendingOutput = Data()
    private var scheduledGeneration: Int?
    private var generation = 0

    init(label: String = "dev.sshapp.sshapp.tmux-pane-terminal-output") {
        queue = DispatchQueue(label: label)
    }

    func setReceiver(_ receiver: (any TerminalOutputReceiver)?) {
        lock.lock()
        let receiverChanged: Bool
        switch (self.receiver, receiver) {
        case (nil, nil):
            receiverChanged = false
        case let (current?, replacement?):
            receiverChanged = current !== replacement
        default:
            receiverChanged = true
        }

        guard receiverChanged else {
            scheduleDrainIfReadyLocked()
            lock.unlock()
            return
        }

        self.receiver = receiver
        generation += 1
        pendingOutput.removeAll(keepingCapacity: true)
        scheduledGeneration = nil
        scheduleDrainIfReadyLocked()
        lock.unlock()
    }

    func setSurfaceAttached(_ attached: Bool) {
        lock.lock()
        guard isSurfaceAttached != attached else {
            scheduleDrainIfReadyLocked()
            lock.unlock()
            return
        }

        isSurfaceAttached = attached
        generation += 1
        scheduledGeneration = nil
        scheduleDrainIfReadyLocked()
        lock.unlock()
    }

    func resetPendingOutput() {
        lock.lock()
        generation += 1
        pendingOutput.removeAll(keepingCapacity: true)
        scheduledGeneration = nil
        lock.unlock()
    }

    func enqueue(_ data: Data) {
        guard !data.isEmpty else { return }

        lock.lock()
        pendingOutput.append(data)
        scheduleDrainIfReadyLocked()
        lock.unlock()
    }

    private func scheduleDrainIfReadyLocked() {
        guard scheduledGeneration == nil,
              isSurfaceAttached,
              receiver != nil,
              !pendingOutput.isEmpty else {
            return
        }

        let scheduledGeneration = generation
        self.scheduledGeneration = scheduledGeneration
        queue.async { [weak self] in
            self?.drain(generation: scheduledGeneration)
        }
    }

    private func drain(generation scheduledGeneration: Int) {
        while true {
            let receiver: (any TerminalOutputReceiver)
            let output: Data

            lock.lock()
            guard self.scheduledGeneration == scheduledGeneration else {
                lock.unlock()
                return
            }
            guard scheduledGeneration == generation,
                  isSurfaceAttached,
                  let currentReceiver = self.receiver,
                  !pendingOutput.isEmpty else {
                self.scheduledGeneration = nil
                scheduleDrainIfReadyLocked()
                lock.unlock()
                return
            }
            receiver = currentReceiver
            output = pendingOutput
            pendingOutput.removeAll(keepingCapacity: true)
            lock.unlock()

            receiver.receive(output)
        }
    }
}

/// Per-pane libghostty terminal for tmux -CC mode.
///
/// Mirrors `GhosttyTerminalView` but binds a single `TmuxPane` to a
/// `UITerminalView`. The pane sink is installed only after Ghostty reports a
/// live surface, so snapshots remain pane-owned across view construction and
/// teardown races. User input is routed through
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
    var hardwareKeyRepeatConfiguration: TerminalHardwareKeyRepeatConfiguration
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
        coordinator.onFocus = onFocus
        coordinator.onHostSessionInteraction = onHostSessionInteraction
        coordinator.controller = controller
        coordinator.updateKeyboardBarTarget(keyboardBarTarget)
        coordinator.updateFocusedState(isFocused)
        configureShortcuts(on: uiView)
        uiView.hardwareKeyRepeatConfiguration = hardwareKeyRepeatConfiguration
        coordinator.applyAccessory(to: uiView, showsBar: showsKeyboardBar)

        // Re-wire if the bound pane changed (e.g. SwiftUI reused this view for a
        // different pane). Clear the old sink so its buffer doesn't leak into the
        // new view's stream, then point at the new pane.
        if coordinator.pane?.id != pane.id {
            coordinator.replacePane(pane)
        }
        coordinator.requestFirstResponderIfReady()
    }

    static func dismantleUIView(_ uiView: ShortcutAwareTerminalView, coordinator: Coordinator) {
        coordinator.detachKeyboardBarTarget(from: uiView)
        uiView.onShortcut = nil
        uiView.onSoftwareKeyboardReturn = nil
        uiView.enabledShortcutScopes = []
        uiView.prefersTmuxWindowNumberShortcuts = false
        coordinator.prepareForDismantle()
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
        var terminalSession: InMemoryTerminalSession? {
            didSet {
                outputDelivery.setReceiver(terminalSession)
            }
        }
        var sinkToken: UUID?
        weak var terminalView: UITerminalView?
        private var keyboardBarTarget: TerminalKeyboardBarTarget?
        private var surfaceAttached = false
        private var surfaceBindingGeneration = 0
        private var surfaceRestoreTask: Task<Void, Never>?
        private var hasRequestedFirstResponderForCurrentFocus = false
        private var firstResponderRequestScheduled = false
        private var firstResponderRequestGeneration = 0
        private var hasPerformedInitialFocusReload = false
        private let outputDelivery = TmuxPaneTerminalOutputDeliveryQueue()

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
            outputDelivery.setSurfaceAttached(true)
            surfaceBindingGeneration += 1
            let generation = surfaceBindingGeneration

            if pane?.registerTerminalSurfaceAttachment() == true {
                restoreAndBindPane(for: generation)
            } else {
                bindPaneSinkIfCurrent(generation: generation)
            }
            syncTerminalSurfaceFocus()
            requestFirstResponderIfReady()
        }

        func markSurfaceDetached() {
            guard surfaceAttached else { return }
            surfaceAttached = false
            surfaceBindingGeneration += 1
            surfaceRestoreTask?.cancel()
            surfaceRestoreTask = nil
            clearPaneSink()
            outputDelivery.setSurfaceAttached(false)
            outputDelivery.resetPendingOutput()
            cancelFirstResponderRetry()
        }

        func replacePane(_ replacement: TmuxPane) {
            guard pane?.id != replacement.id else { return }

            surfaceBindingGeneration += 1
            surfaceRestoreTask?.cancel()
            surfaceRestoreTask = nil
            clearPaneSink()
            outputDelivery.resetPendingOutput()
            pane = replacement
            resetFirstResponderRequest()

            guard surfaceAttached else { return }
            _ = replacement.registerTerminalSurfaceAttachment()
            restoreAndBindPane(for: surfaceBindingGeneration)
        }

        func prepareForDismantle() {
            surfaceAttached = false
            surfaceBindingGeneration += 1
            surfaceRestoreTask?.cancel()
            surfaceRestoreTask = nil
            clearPaneSink()
            outputDelivery.setSurfaceAttached(false)
            outputDelivery.resetPendingOutput()
            cancelFirstResponderRetry()
        }

        private func bindPaneSinkIfCurrent(generation: Int) {
            guard surfaceAttached,
                  surfaceBindingGeneration == generation,
                  sinkToken == nil,
                  let pane else {
                return
            }

            sinkToken = pane.setSink { [weak self] data in
                self?.receiveFromPane(data)
            }
        }

        private func clearPaneSink() {
            pane?.clearSink(sinkToken)
            sinkToken = nil
        }

        private func restoreAndBindPane(for generation: Int) {
            guard let controller, let pane else {
                bindPaneSinkIfCurrent(generation: generation)
                return
            }

            surfaceRestoreTask?.cancel()
            surfaceRestoreTask = Task { @MainActor [weak self, weak controller, weak pane] in
                if let controller, let pane {
                    _ = await controller.restorePaneForRecreatedSurface(pane.id)
                }

                guard let self,
                      !Task.isCancelled,
                      self.surfaceAttached,
                      self.surfaceBindingGeneration == generation,
                      self.pane === pane else {
                    return
                }
                self.surfaceRestoreTask = nil
                self.bindPaneSinkIfCurrent(generation: generation)
            }
        }

        func updateFocusedState(_ focused: Bool) {
            if isFocused && !focused {
                hasRequestedFirstResponderForCurrentFocus = false
                cancelFirstResponderRetry()
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
            cancelFirstResponderRetry()
        }

        func cancelFirstResponderRetry() {
            firstResponderRequestScheduled = false
            firstResponderRequestGeneration += 1
        }

        func requestFirstResponderIfReady() {
            guard surfaceAttached, isFocused, !hasRequestedFirstResponderForCurrentFocus else { return }
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
            guard surfaceAttached, isFocused, !hasRequestedFirstResponderForCurrentFocus else { return }
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
            onHostSessionInteraction?()
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
