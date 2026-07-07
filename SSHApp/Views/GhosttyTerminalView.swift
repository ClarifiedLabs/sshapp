import SwiftUI
import UIKit
import GhosttyTerminal
import os

private let logger = Logger(subsystem: "dev.sshapp.sshapp", category: "GhosttyTerminalView")

/// SwiftUI ↔ libghostty bridge for a single SSH shell terminal.
///
/// Wraps libghostty's `UITerminalView` with a per-surface, host-managed
/// `InMemoryTerminalSession`:
///   - SSH bytes → `session.receive(_:)` for display.
///   - User input → the session's `write` callback → routed to SSH (or to the
///     local auth-capture buffer during password prompts).
///   - Grid changes → the session's `resize` callback → SSH window-change.
/// The shared `TerminalController` owns font/cursor/theme.
struct GhosttyTerminalView: UIViewRepresentable {
    let session: SSHSession
    let tab: Tab
    var isHostTabActive: Bool
    var onShortcut: (TerminalTabShortcut) -> Void
    var onRemoteChannelClosed: (Tab, SSHChannelRemoteCloseReason) -> Void
    var onHostSessionInteraction: () -> Void
    /// Whether the host SwiftUI keyboard bar should be shown.
    var showsKeyboardBar: Bool
    var keyboardBarTarget: TerminalKeyboardBarTarget?
    var hardwareKeyRepeatConfiguration: TerminalHardwareKeyRepeatConfiguration

    func makeUIView(context: Context) -> ShortcutAwareTerminalView {
        let coordinator = context.coordinator
        let tv = ShortcutAwareTerminalView(frame: .zero)

        // Per-surface host-managed I/O. The write closure always hops to the
        // main queue and never synchronously re-enters `receive(_:)`, which
        // holds a non-recursive lock while calling into ghostty. Resize can be
        // delivered synchronously when ghostty is already on the main thread so
        // viewport fits and grid state stay in the same turn.
        let imSession = InMemoryTerminalSession(
            write: { [weak coordinator] data in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { coordinator?.forwardFromTerminal(data) }
                }
            },
            resize: { [weak coordinator] viewport in
                if Thread.isMainThread {
                    MainActor.assumeIsolated {
                        coordinator?.handleResize(
                            cols: Int(viewport.columns),
                            rows: Int(viewport.rows)
                        )
                    }
                } else {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            coordinator?.handleResize(
                                cols: Int(viewport.columns),
                                rows: Int(viewport.rows)
                            )
                        }
                    }
                }
            }
        )

        coordinator.session = session
        coordinator.updateTab(tab)
        coordinator.terminalSession = imSession
        coordinator.onRemoteChannelClosed = onRemoteChannelClosed
        coordinator.onHostSessionInteraction = onHostSessionInteraction
        coordinator.updateKeyboardBarTarget(keyboardBarTarget)
        coordinator.updateHostTabActiveState(isHostTabActive)
        coordinator.updateChannel(tab.channel)

        tv.delegate = coordinator
        tv.controller = TerminalRuntime.shared.controller
        tv.configuration = TerminalSurfaceOptions(backend: .inMemory(imSession))
        tv.hardwareKeyRepeatConfiguration = hardwareKeyRepeatConfiguration
        configureShortcuts(on: tv)
        tv.onSoftwareKeyboardReturn = { [weak coordinator] in
            coordinator?.forwardSoftwareKeyboardReturn()
        }
        coordinator.applyAccessory(to: tv, showsBar: showsKeyboardBar)

        // Wire SSH output → terminal display. `receive(_:)` is thread-safe and
        // drops bytes only until the ghostty surface attaches; the auth flow is
        // gated on `terminalDidAttachSurface` so status text lands on a ready
        // surface (see Coordinator).
        session.onDataReceived = { [weak imSession] data in
            imSession?.receive(data)
        }

        // NOTE: do NOT signal terminal ready here — the surface is created
        // asynchronously once the view is in a window. Readiness is scheduled
        // from `terminalDidAttachSurface` after the first grid settles.
        return tv
    }

    func updateUIView(_ uiView: ShortcutAwareTerminalView, context: Context) {
        let coordinator = context.coordinator
        coordinator.session = session
        coordinator.updateTab(tab)
        coordinator.onRemoteChannelClosed = onRemoteChannelClosed
        coordinator.onHostSessionInteraction = onHostSessionInteraction
        coordinator.updateKeyboardBarTarget(keyboardBarTarget)
        coordinator.updateChannel(tab.channel)
        coordinator.updateHostTabActiveState(isHostTabActive)
        uiView.hardwareKeyRepeatConfiguration = hardwareKeyRepeatConfiguration
        configureShortcuts(on: uiView)
        coordinator.applyAccessory(to: uiView, showsBar: showsKeyboardBar)
        coordinator.openChannelIfReady()
    }

    static func dismantleUIView(_ uiView: ShortcutAwareTerminalView, coordinator: Coordinator) {
        coordinator.detachKeyboardBarTarget(from: uiView)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func configureShortcuts(on terminalView: ShortcutAwareTerminalView) {
        terminalView.enabledShortcutScopes = isHostTabActive ? [.hostTabs] : []
        terminalView.prefersTmuxWindowNumberShortcuts = false
        terminalView.onShortcut = onShortcut
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject {
        var session: SSHSession?
        var channel: SSHChannel?
        var tab: Tab?
        var terminalSession: InMemoryTerminalSession?
        var onRemoteChannelClosed: ((Tab, SSHChannelRemoteCloseReason) -> Void)?
        var onHostSessionInteraction: (() -> Void)?

        private var channelOpenRequested = false
        private var surfaceAttached = false
        private var authBuffer = ""
        private var lastGridSize = TerminalGridSize.fallback
        private var hasMeasuredGridSize = false
        private var preservesInheritedGridSizeForInitialOpen = false
        private var gridMeasurementGeneration = 0
        private var terminalReadySettleRequestID = 0
        private var terminalReadySignaled = false
        private weak var terminalView: UITerminalView?
        private var keyboardBarTarget: TerminalKeyboardBarTarget?
        private var isHostTabActive = false
        private var hasRequestedInitialFirstResponder = false
        private var hasPerformedInitialFocusReload = false

        func applyAccessory(to tv: UITerminalView, showsBar _: Bool) {
            terminalView = tv
            #if !targetEnvironment(macCatalyst)
            if tv.usesSystemInputAccessory {
                tv.usesSystemInputAccessory = false
            }
            #endif
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

        func updateTab(_ newTab: Tab) {
            if tab?.id != newTab.id {
                hasMeasuredGridSize = false
                preservesInheritedGridSizeForInitialOpen = newTab.terminalGridSize != nil
                gridMeasurementGeneration = 0
                terminalReadySettleRequestID += 1
                terminalReadySignaled = false
            } else if !hasMeasuredGridSize && !channelOpenRequested {
                preservesInheritedGridSizeForInitialOpen = newTab.terminalGridSize != nil
            }
            tab = newTab
            if let terminalGridSize = newTab.terminalGridSize {
                lastGridSize = terminalGridSize
            }
        }

        func updateHostTabActiveState(_ active: Bool) {
            if isHostTabActive && !active {
                hasRequestedInitialFirstResponder = false
                keyboardBarTarget?.detach(terminalView)
                terminalView?.resignFirstResponder()
            }
            isHostTabActive = active
            syncKeyboardBarTarget()
            requestInitialFirstResponder()
        }

        private func syncKeyboardBarTarget() {
            guard isHostTabActive else {
                keyboardBarTarget?.detach(terminalView)
                return
            }
            keyboardBarTarget?.attach(terminalView)
        }

        func updateChannel(_ newChannel: SSHChannel?) {
            guard channel?.id != newChannel?.id else { return }
            channel = newChannel
            if let newChannel {
                channelOpenRequested = true
                attachChannel(newChannel)
            }
        }

        private func attachChannel(_ channel: SSHChannel) {
            channel.onDataReceived = { [weak self] data in
                self?.terminalSession?.receive(data)
            }
            channel.onRemoteDisconnected = { [weak self] reason in
                guard let self, let tab = self.tab else { return }
                self.onRemoteChannelClosed?(tab, reason)
            }
        }

        func requestInitialFirstResponder() {
            guard surfaceAttached, isHostTabActive, !hasRequestedInitialFirstResponder else { return }
            hasRequestedInitialFirstResponder = true
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isHostTabActive else { return }
                _ = self.terminalView?.becomeFirstResponder()
            }
        }

        // MARK: - Resize (terminal grid → SSH window-change)

        func handleResize(cols: Int, rows: Int) {
            guard let gridSize = TerminalGridSize(cols: cols, rows: rows) else { return }
            lastGridSize = gridSize
            gridMeasurementGeneration += 1
            hasMeasuredGridSize = true
            if channel?.isOpen == true || !preservesInheritedGridSizeForInitialOpen {
                tab?.terminalGridSize = gridSize
            }
            if channel?.isOpen == true {
                channel?.resizeTerminal(cols: cols, rows: rows)
            }
            scheduleTerminalReadyAfterViewportSettle()
        }

        private func scheduleTerminalReadyAfterViewportSettle() {
            guard surfaceAttached, !terminalReadySignaled else { return }
            terminalReadySettleRequestID += 1
            let requestID = terminalReadySettleRequestID

            DispatchQueue.main.async { [weak self] in
                guard let self,
                      surfaceAttached,
                      !terminalReadySignaled,
                      requestID == terminalReadySettleRequestID
                else {
                    return
                }

                terminalView?.fitToSize()
                guard requestID == terminalReadySettleRequestID else { return }

                let generationAfterFit = gridMeasurementGeneration
                guard hasMeasuredGridSize || tab?.terminalGridSize != nil else { return }

                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          surfaceAttached,
                          !terminalReadySignaled,
                          requestID == terminalReadySettleRequestID
                    else {
                        return
                    }

                    terminalView?.fitToSize()
                    guard requestID == terminalReadySettleRequestID else { return }

                    guard gridMeasurementGeneration == generationAfterFit else {
                        scheduleTerminalReadyAfterViewportSettle()
                        return
                    }

                    signalTerminalReadyAndOpenChannelIfNeeded()
                }
            }
        }

        private func signalTerminalReadyAndOpenChannelIfNeeded() {
            guard surfaceAttached,
                  !terminalReadySignaled,
                  hasMeasuredGridSize || tab?.terminalGridSize != nil
            else {
                return
            }

            terminalReadySignaled = true
            session?.signalTerminalReady()
            openChannelIfReady()
        }

        // MARK: - Shell lifecycle

        func openChannelIfReady() {
            guard let session,
                  let tab,
                  surfaceAttached,
                  terminalReadySignaled,
                  session.isAuthenticated,
                  tab.connectionState == .connected,
                  tab.channel == nil,
                  !channelOpenRequested
            else { return }
            channelOpenRequested = true
            Task { @MainActor in
                do {
                    let openingGridSize = tab.terminalGridSize ?? lastGridSize
                    let openedChannel = try await session.openShellChannel(
                        termType: "xterm-256color",
                        cols: openingGridSize.cols,
                        rows: openingGridSize.rows
                    )
                    tab.channel = openedChannel
                    tab.terminalGridSize = openingGridSize
                    preservesInheritedGridSizeForInitialOpen = false
                    channel = openedChannel
                    attachChannel(openedChannel)

                    if let command = tab.consumePendingAutoRunCommand() {
                        do {
                            try await openedChannel.writeTerminalCommand(command)
                        } catch {
                            logger.error("Failed to send auto-run command: \(error.localizedDescription)")
                        }
                    }
                } catch {
                    logger.error("Failed to open shell channel: \(error.localizedDescription)")
                    tab.connectionState = .failed(error.localizedDescription)
                }
            }
        }

        // MARK: - Input router (terminal output → SSH / auth capture)

        func forwardFromTerminal(_ data: Data) {
            guard let session else {
                logger.warning("forwardFromTerminal: session is nil, dropping \(data.count)B")
                return
            }

            let normalizedData = TerminalInputNormalizer.normalize(data)

            if let channel {
                switch channel.inputMode {
                case .normal:
                    onHostSessionInteraction?()
                    Task { @MainActor in
                        do {
                            try await channel.write(normalizedData)
                        } catch {
                            logger.error("write to SSH channel failed: \(error)")
                        }
                    }

                case .tmuxControlMode:
                    onHostSessionInteraction?()
                    if let controller = channel.tmuxController {
                        Task { await controller.sendKeysToActivePane(normalizedData) }
                    }

                case .capturePassword, .captureInteractive:
                    logger.warning("channel entered auth-capture input mode; dropping \(normalizedData.count)B")
                }
                return
            }

            switch session.inputMode {
            case .normal, .tmuxControlMode:
                logger.warning("forwardFromTerminal: no SSH channel is open, dropping \(normalizedData.count)B")

            case .capturePassword:
                Task { @MainActor in
                    handleCapturedInput(normalizedData, echo: false)
                }

            case .captureInteractive:
                Task { @MainActor in
                    handleCapturedInput(normalizedData, echo: true)
                }
            }
        }

        func forwardSoftwareKeyboardReturn() {
            terminalSession?.sendInput(Data([0x0D]))
        }

        private func handleCapturedInput(_ data: Data, echo: Bool) {
            guard let session,
                  let text = String(data: data, encoding: .utf8) else {
                return
            }

            for char in text {
                switch char {
                case "\r", "\n":
                    let response = authBuffer
                    authBuffer = ""
                    terminalSession?.receive(Data([0x0D, 0x0A]))
                    session.submitAuthInput(response)
                case "\u{7F}":
                    if !authBuffer.isEmpty {
                        authBuffer.removeLast()
                        if echo {
                            terminalSession?.receive(Data([0x08, 0x20, 0x08]))
                        }
                    }
                default:
                    authBuffer.append(char)
                    if echo, let bytes = String(char).data(using: .utf8) {
                        terminalSession?.receive(bytes)
                    }
                }
            }
        }
    }
}

// MARK: - libghostty surface delegate

extension GhosttyTerminalView.Coordinator:
    TerminalSurfaceTitleDelegate,
    TerminalSurfaceBellDelegate,
    TerminalSurfaceCloseDelegate,
    TerminalSurfaceFocusDelegate,
    TerminalSurfaceLifecycleDelegate {

    func terminalDidChangeTitle(_ title: String) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty,
              trimmedTitle != HostManagedTerminal.inertCommandName
        else {
            return
        }

        tab?.title = title
    }

    /// The terminal becomes first responder on touch. The first focus pass
    /// defers a viewport refit so Ghostty sees the final SwiftUI layout after
    /// the host keyboard bar's bottom safe-area inset has settled. Gated to fire
    /// once per view instance to avoid refit churn on later focus/blur.
    func terminalDidChangeFocus(_ focused: Bool) {
        if focused {
            keyboardBarTarget?.attach(terminalView)
        }
        guard focused, !hasPerformedInitialFocusReload else { return }
        hasPerformedInitialFocusReload = true
        DispatchQueue.main.async { [weak self] in
            self?.terminalView?.refreshInputAccessoryViewport()
        }
    }

    func terminalDidRingBell() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    func terminalDidClose(processAlive: Bool) {
        // The SSH channel/process ended; connection teardown is handled by the
        // SSH layer / tab state.
    }

    func terminalDidAttachSurface(_ surface: TerminalSurface) {
        surfaceAttached = true
        // The surface now exists, but its first metrics pass can still be a
        // provisional viewport. Wait for a measured grid to survive a final fit
        // before unblocking auth or the initial PTY request.
        requestInitialFirstResponder()
        scheduleTerminalReadyAfterViewportSettle()
    }

    func terminalDidDetachSurface() {
        surfaceAttached = false
        terminalReadySettleRequestID += 1
        terminalReadySignaled = false
    }
}
