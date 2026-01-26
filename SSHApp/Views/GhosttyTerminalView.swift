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
    var onRemoteChannelClosed: (Tab) -> Void
    /// Whether the built-in keyboard accessory bar should be shown.
    var showsKeyboardBar: Bool

    func makeUIView(context: Context) -> ShortcutAwareTerminalView {
        let coordinator = context.coordinator
        let tv = ShortcutAwareTerminalView(frame: .zero)

        // Per-surface host-managed I/O. The write/resize closures are @Sendable
        // and may fire from a ghostty callback context; they hop to the main
        // queue (FIFO-ordered) and never synchronously re-enter `receive(_:)`,
        // which holds a non-recursive lock while calling into ghostty.
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

        coordinator.session = session
        coordinator.tab = tab
        coordinator.terminalSession = imSession
        coordinator.onRemoteChannelClosed = onRemoteChannelClosed
        coordinator.updateHostTabActiveState(isHostTabActive)
        coordinator.updateChannel(tab.channel)

        tv.delegate = coordinator
        tv.controller = TerminalRuntime.shared.controller
        tv.configuration = TerminalSurfaceOptions(backend: .inMemory(imSession))
        configureShortcuts(on: tv)
        coordinator.applyAccessory(to: tv, showsBar: showsKeyboardBar)

        // Wire SSH output → terminal display. `receive(_:)` is thread-safe and
        // drops bytes only until the ghostty surface attaches; the auth flow is
        // gated on `terminalDidAttachSurface` so status text lands on a ready
        // surface (see Coordinator).
        session.onDataReceived = { [weak imSession] data in
            imSession?.receive(data)
        }

        // NOTE: do NOT signal terminal ready here — the surface is created
        // asynchronously once the view is in a window. We signal ready in
        // `terminalDidAttachSurface`.
        return tv
    }

    func updateUIView(_ uiView: ShortcutAwareTerminalView, context: Context) {
        let coordinator = context.coordinator
        coordinator.session = session
        coordinator.tab = tab
        coordinator.onRemoteChannelClosed = onRemoteChannelClosed
        coordinator.updateChannel(tab.channel)
        coordinator.updateHostTabActiveState(isHostTabActive)
        configureShortcuts(on: uiView)
        coordinator.applyAccessory(to: uiView, showsBar: showsKeyboardBar)
        coordinator.openChannelIfReady()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func configureShortcuts(on terminalView: ShortcutAwareTerminalView) {
        terminalView.enabledShortcutScopes = isHostTabActive ? [.hostTabs] : []
        terminalView.onShortcut = onShortcut
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject {
        var session: SSHSession?
        var channel: SSHChannel?
        var tab: Tab?
        var terminalSession: InMemoryTerminalSession?
        var onRemoteChannelClosed: ((Tab) -> Void)?

        private var channelOpenRequested = false
        private var surfaceAttached = false
        private var authBuffer = ""
        private var lastCols = 80
        private var lastRows = 24
        private weak var terminalView: UITerminalView?
        private var isHostTabActive = false
        private var hasRequestedInitialFirstResponder = false
        private var hasPerformedInitialFocusReload = false

        func applyAccessory(to tv: UITerminalView, showsBar: Bool) {
            terminalView = tv
            #if !targetEnvironment(macCatalyst)
            let items: [TerminalInputAccessoryItem] = showsBar
                ? TerminalInputAccessoryItem.defaultItems
                : []
            if tv.inputAccessoryItems != items {
                tv.inputAccessoryItems = items
            }
            #endif
        }

        func updateHostTabActiveState(_ active: Bool) {
            if isHostTabActive && !active {
                hasRequestedInitialFirstResponder = false
                terminalView?.resignFirstResponder()
            }
            isHostTabActive = active
            requestInitialFirstResponder()
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
            channel.onRemoteDisconnected = { [weak self] in
                guard let self, let tab = self.tab else { return }
                self.onRemoteChannelClosed?(tab)
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
            guard cols > 0, rows > 0 else { return }
            lastCols = cols
            lastRows = rows
            if channel?.isOpen == true {
                channel?.resizeTerminal(cols: cols, rows: rows)
            }
        }

        // MARK: - Shell lifecycle

        func openChannelIfReady() {
            guard let session,
                  let tab,
                  surfaceAttached,
                  session.isAuthenticated,
                  tab.connectionState == .connected,
                  tab.channel == nil,
                  !channelOpenRequested
            else { return }
            channelOpenRequested = true
            Task { @MainActor in
                do {
                    let openedChannel = try await session.openShellChannel(
                        termType: "xterm-256color",
                        cols: lastCols,
                        rows: lastRows
                    )
                    tab.channel = openedChannel
                    channel = openedChannel
                    attachChannel(openedChannel)
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
                    Task { @MainActor in
                        do {
                            try await channel.write(normalizedData)
                        } catch {
                            logger.error("write to SSH channel failed: \(error)")
                        }
                    }

                case .tmuxControlMode:
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
    TerminalSurfaceTextSelectionRequestDelegate,
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

    /// The terminal becomes first responder on touch. The first time that
    /// happens, force UIKit to re-resolve the keyboard + input-accessory
    /// frame so SwiftUI's automatic keyboard avoidance accounts for the
    /// accessory bar height. The accessory's initial `reloadInputViews()`
    /// (triggered from `makeUIView` via `inputAccessoryItems`) was a no-op
    /// because the view had no window / was not first responder yet — which
    /// is why the bar overlaps the terminal until the user manually toggles
    /// it. Deferred a runloop so the accessory has laid out; gated to fire
    /// once per view instance to avoid reload flicker on later focus/blur.
    func terminalDidChangeFocus(_ focused: Bool) {
        guard focused, !hasPerformedInitialFocusReload else { return }
        hasPerformedInitialFocusReload = true
        DispatchQueue.main.async { [weak self] in
            self?.terminalView?.reloadInputViews()
        }
    }

    func terminalDidRingBell() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    func terminalDidClose(processAlive: Bool) {
        // The SSH channel/process ended; connection teardown is handled by the
        // SSH layer / tab state.
    }

    func terminalDidRequestTextSelection(_ request: TerminalTextSelectionRequest) {
        terminalView?.presentSelectionSheet(request)
    }

    func terminalDidAttachSurface(_ surface: TerminalSurface) {
        surfaceAttached = true
        // The surface (and its grid) now exists, so received bytes will display.
        // Kick the gated SSH/auth flow and open the shell if we're already
        // authenticated.
        session?.signalTerminalReady()
        openChannelIfReady()
        requestInitialFirstResponder()
    }

    func terminalDidDetachSurface() {
        surfaceAttached = false
    }
}
