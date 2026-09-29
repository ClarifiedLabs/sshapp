import SwiftUI
import UIKit
import GhosttyTerminal
import os

private let logger = Logger(subsystem: "dev.sshapp.sshapp", category: "GhosttyTerminalView")

/// SwiftUI ↔ libghostty bridge for a single SSH shell terminal.
///
/// Wraps `UITerminalView` with a logical-terminal-owned
/// `VTTerminalSession`, retained across UIKit/Metal host recreation:
///   - SSH bytes → completion-bearing queued VT delivery for display.
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
    var onSystemSoftwareKeyboardDismiss: () -> Void = {}
    /// Whether the host SwiftUI keyboard bar should be shown.
    var showsKeyboardBar: Bool
    var suppressesSoftwareKeyboard: Bool
    var keyboardBarTarget: TerminalKeyboardBarTarget?
    var hardwareKeyRepeatConfiguration: TerminalHardwareKeyRepeatConfiguration
    var configuredFontSize: Float
    let fontSizeTargetRegistry: TerminalFontSizeTargetRegistry
    var onPostFlushDraw: (@MainActor () -> Void)? = nil
    #if DEBUG
    var terminalSelectionDebugConfiguration: TerminalSelectionDebugConfiguration? = nil
    /// Diagnostic trace of the post-flush draw chain (drain, request, render).
    var onPostFlushDrawEvent: (@MainActor (String) -> Void)? = nil
    #endif

    func makeUIView(context: Context) -> ShortcutAwareTerminalView {
        let coordinator = context.coordinator
        let tv = ShortcutAwareTerminalView(frame: .zero)
        tv.isHostVisible = isHostTabActive
        coordinator.onSystemSoftwareKeyboardDismiss = onSystemSoftwareKeyboardDismiss
        tv.onSystemSoftwareKeyboardDismiss = { [weak coordinator, weak tv] in
            guard let tv else { return }
            coordinator?.handleSystemSoftwareKeyboardDismiss(from: tv)
        }
        tv.configuredFontSize = configuredFontSize
        tv.suppressesSoftwareKeyboard = suppressesSoftwareKeyboard
        coordinator.updateHostTabActiveState(isHostTabActive, view: tv)

        coordinator.updateTab(tab)
        coordinator.updateSession(session)
        coordinator.bindTerminalSession()
        coordinator.onRemoteChannelClosed = onRemoteChannelClosed
        coordinator.onHostSessionInteraction = onHostSessionInteraction
        coordinator.onPostFlushDraw = onPostFlushDraw
        #if DEBUG
        coordinator.onPostFlushDrawEvent = onPostFlushDrawEvent
        #endif
        coordinator.updateKeyboardBarTarget(keyboardBarTarget)
        coordinator.updateChannel(tab.channel)
        coordinator.updateFontSizeTarget(
            registry: fontSizeTargetRegistry,
            key: .hostTab(tab.id),
            view: tv
        )

        tv.delegate = coordinator
        tv.controller = TerminalRuntime.shared.controller
        tv.configuration = TerminalSurfaceOptions(backend: .vt(coordinator.terminalSession!))
        #if DEBUG
        tv.selectionDebugConfiguration = terminalSelectionDebugConfiguration
        #endif
        tv.hardwareKeyRepeatConfiguration = hardwareKeyRepeatConfiguration
        configureShortcuts(on: tv)
        tv.onSoftwareKeyboardReturn = { [weak coordinator] in
            coordinator?.forwardSoftwareKeyboardReturn()
        }
        coordinator.applyAccessory(to: tv, showsBar: showsKeyboardBar)

        // SSH output is wired through the coordinator's bounded, enqueue-only
        // delivery queue. Raw attachment is not enough to drain it; the viewport
        // readiness gate opens delivery after deferred fits stabilize the grid.

        // NOTE: do NOT signal terminal ready here — the surface is created
        // asynchronously once the view is in a window. Readiness is scheduled
        // from `terminalDidAttachSurface` after the first grid settles.
        return tv
    }

    func updateUIView(_ uiView: ShortcutAwareTerminalView, context: Context) {
        let coordinator = context.coordinator
        uiView.isHostVisible = isHostTabActive
        coordinator.onSystemSoftwareKeyboardDismiss = onSystemSoftwareKeyboardDismiss
        uiView.configuredFontSize = configuredFontSize
        uiView.suppressesSoftwareKeyboard = suppressesSoftwareKeyboard
        coordinator.updateHostTabActiveState(isHostTabActive, view: uiView)
        #if DEBUG
        uiView.selectionDebugConfiguration = terminalSelectionDebugConfiguration
        #endif
        coordinator.updateTab(tab)
        coordinator.updateSession(session)
        coordinator.bindTerminalSession()
        coordinator.onRemoteChannelClosed = onRemoteChannelClosed
        coordinator.onHostSessionInteraction = onHostSessionInteraction
        coordinator.onPostFlushDraw = onPostFlushDraw
        #if DEBUG
        coordinator.onPostFlushDrawEvent = onPostFlushDrawEvent
        #endif
        coordinator.updateKeyboardBarTarget(keyboardBarTarget)
        coordinator.updateChannel(tab.channel)
        coordinator.updateFontSizeTarget(
            registry: fontSizeTargetRegistry,
            key: .hostTab(tab.id),
            view: uiView
        )
        uiView.hardwareKeyRepeatConfiguration = hardwareKeyRepeatConfiguration
        configureShortcuts(on: uiView)
        coordinator.applyAccessory(to: uiView, showsBar: showsKeyboardBar)
        coordinator.openChannelIfReady()
    }

    static func dismantleUIView(_ uiView: ShortcutAwareTerminalView, coordinator: Coordinator) {
        coordinator.unregisterFontSizeTarget(view: uiView)
        coordinator.detachKeyboardBarTarget(from: uiView)
        uiView.onSystemSoftwareKeyboardDismiss = nil
        coordinator.onSystemSoftwareKeyboardDismiss = nil
        coordinator.prepareForDismantle()
        // Start native retirement while UIKit still strongly owns the platform
        // pointer passed unretained to Ghostty. Keep the DEBUG callback attached
        // through this synchronous cleanup so the retired generation can
        // acknowledge that it released all transient selection state.
        uiView.controller = nil
        #if DEBUG
        uiView.selectionDebugConfiguration = nil
        #endif
        coordinator.onPostFlushDraw = nil
        #if DEBUG
        coordinator.onPostFlushDrawEvent = nil
        #endif
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
        var terminalSession: VTTerminalSession? {
            didSet {
                if let terminalSession { sessionOutputDelivery.setReceiver(terminalSession) }
            }
        }
        var onRemoteChannelClosed: ((Tab, SSHChannelRemoteCloseReason) -> Void)?
        var onHostSessionInteraction: (() -> Void)?
        var onSystemSoftwareKeyboardDismiss: (() -> Void)?
        var onPostFlushDraw: (@MainActor () -> Void)?
        #if DEBUG
        var onPostFlushDrawEvent: (@MainActor (String) -> Void)?
        #endif

        private func tracePostFlushDraw(_ event: @autoclosure () -> String) {
            #if DEBUG
            onPostFlushDrawEvent?(event())
            #endif
        }

        private var terminalLifetime: TerminalSemanticLifetime?

        func bindTerminalSession() {
            guard let tab, let session else { return }
            if let retained = tab.terminalLifetime, retained.transport !== session || (retained.channelID != nil && retained.channelID != tab.channel?.id) {
                tab.finishTerminalSession()
            }
            let lifetime = tab.terminalLifetime ?? TerminalSemanticLifetime()
            tab.terminalLifetime = lifetime
            lifetime.transport = session
            lifetime.channelID = tab.channel?.id
            lifetime.channel = tab.channel
            guard terminalLifetime !== lifetime else { return }
            terminalLifetime?.unbind(owner: self)
            terminalLifetime = lifetime
            sessionOutputDelivery = lifetime.outputDelivery
            lifetime.bind(owner: self, write: { [weak self] in self?.forwardFromTerminal($0) },
                          resize: { [weak self] in self?.handleResize(cols: Int($0.columns), rows: Int($0.rows)) },
                          detachedWrite: { [weak lifetime] data in
                              guard let channel = lifetime?.channel else { return }
                              let bytes = TerminalInputNormalizer.normalize(data)
                              Task { @MainActor in
                                  if channel.inputMode == .tmuxControlMode {
                                      await channel.tmuxController?.sendKeysToActivePane(bytes)
                                  } else {
                                      do {
                                          try await channel.write(bytes)
                                      } catch {
                                          logger.error("detached write to SSH channel failed: \(error)")
                                      }
                                  }
                              }
                          })
            terminalSession = lifetime.session
            // Transport output remains buffered even while no coordinator exists.
            session.onDataReceived = { [weak tab, weak lifetime] data in
                // A finished lifetime has reset its queue; never refill it.
                guard let lifetime, !lifetime.isFinished else { return }
                if let channel = tab?.channel {
                    channel.deliverTerminalOutput(data)
                } else {
                    lifetime.outputDelivery.enqueue(data)
                }
            }
            terminalView?.configuration = TerminalSurfaceOptions(backend: .vt(lifetime.session))
            if let channel, channel === tab.channel { attachChannel(channel) }
        }

        private var channelOpenRequested = false
        private var surfaceAttached = false
        private var authBuffer: String {
            get { terminalLifetime?.authBuffer ?? "" }
            set { terminalLifetime?.authBuffer = newValue }
        }
        private var lastGridSize = TerminalGridSize.fallback
        private var hasMeasuredGridSize = false
        private var preservesInheritedGridSizeForInitialOpen = false
        private var terminalReadySignaled = false
        private var outputBindingGeneration = 0
        private var sessionOutputGeneration = 0
        private var channelOutputReceiverToken: SSHChannel.TerminalOutputReceiverToken?
        private let viewportReadiness = TerminalViewportReadinessGate()
        private var sessionOutputDelivery = TerminalOutputDeliveryQueue(
            label: "dev.sshapp.sshapp.normal-terminal-output"
        )
        private weak var terminalView: UITerminalView?
        private weak var fontSizeTargetView: UITerminalView?
        private weak var fontSizeTargetRegistry: TerminalFontSizeTargetRegistry?
        private var fontSizeTargetKey: TerminalFontSizeTargetKey?
        private var keyboardBarTarget: TerminalKeyboardBarTarget?
        private var isHostTabActive = false
        private var hostVisibilityGeneration = 0
        private var hasRequestedInitialFirstResponder = false
        private var hasPerformedInitialFocusReload = false

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
            tv.isHostVisible = isHostTabActive
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
            let tabChanged = tab?.id != newTab.id
            if tabChanged {
                hasMeasuredGridSize = false
                preservesInheritedGridSizeForInitialOpen = newTab.terminalGridSize != nil
                terminalReadySignaled = false
                channelOpenRequested = false
                outputBindingGeneration += 1
                suspendOutputDeliveries()
                viewportReadiness.invalidate()
            } else if !hasMeasuredGridSize && !channelOpenRequested {
                preservesInheritedGridSizeForInitialOpen = newTab.terminalGridSize != nil
            }
            tab = newTab
            if let terminalGridSize = newTab.terminalGridSize {
                lastGridSize = terminalGridSize
            }
            if tabChanged, surfaceAttached {
                beginViewportSettle()
            }
        }

        func updateSession(_ newSession: SSHSession) {
            guard session !== newSession else { return }
            session = newSession
            outputBindingGeneration += 1
            sessionOutputGeneration += 1
            let sessionGeneration = sessionOutputGeneration
            newSession.onDataReceived = { [weak self, weak newSession] data in
                guard let self,
                      self.session === newSession,
                      self.sessionOutputGeneration == sessionGeneration else {
                    return
                }
                self.enqueueSessionOutput(data)
            }
        }

        private func enqueueSessionOutput(_ data: Data) {
            if let channel {
                channel.deliverTerminalOutput(data)
            } else {
                sessionOutputDelivery.enqueue(data)
            }
        }

        func handleSystemSoftwareKeyboardDismiss(from source: UITerminalView) {
            guard surfaceAttached,
                  isHostTabActive,
                  terminalView === source else {
                return
            }
            onSystemSoftwareKeyboardDismiss?()
        }

        func updateHostTabActiveState(_ active: Bool, view: UITerminalView? = nil) {
            if let view { terminalView = view }
            if isHostTabActive != active {
                hostVisibilityGeneration += 1
                hasRequestedInitialFirstResponder = false
            }
            isHostTabActive = active
            // Retained tabs keep ingesting SSH output; only UIKit admission and
            // presentation are suspended. Do not retire the semantic session.
            terminalView?.isHostVisible = active
            if !active {
                terminalView?.resignFirstResponderForApplicationAction()
            }
            syncKeyboardBarTarget()
            requestInitialFirstResponder()
        }

        private func syncKeyboardBarTarget() {
            guard isHostTabActive, terminalView?.isHostVisible == true else {
                keyboardBarTarget?.detach(terminalView)
                return
            }
            keyboardBarTarget?.attach(terminalView)
        }

        func updateChannel(_ newChannel: SSHChannel?) {
            guard channel?.id != newChannel?.id else { return }
            if let channel, let channelOutputReceiverToken {
                channel.unregisterTerminalOutputReceiver(channelOutputReceiverToken)
            }
            channelOutputReceiverToken = nil
            channel = newChannel
            outputBindingGeneration += 1
            suspendOutputDeliveries()
            terminalReadySignaled = false
            channelOpenRequested = newChannel != nil
            if let newChannel {
                attachChannel(newChannel)
            }
            if surfaceAttached {
                beginViewportSettle()
            }
        }

        private func attachChannel(_ channel: SSHChannel) {
            if let channelOutputReceiverToken {
                channel.unregisterTerminalOutputReceiver(channelOutputReceiverToken)
            }
            guard let terminalSession else { return }
            channelOutputReceiverToken = channel.registerTerminalOutputReceiver(terminalSession)
            if terminalReadySignaled {
                resumeOutputDeliveries(
                    readinessGeneration: viewportReadiness.generation
                )
            }
            channel.onRemoteDisconnected = { [weak self, weak channel, weak lifetime = terminalLifetime, weak tab] reason in
                // The SSH channel may close while its UIKit host is absent.
                lifetime?.finish()
                if let lifetime, tab?.terminalLifetime === lifetime {
                    tab?.finishTerminalSession()
                }
                guard let self,
                      self.channel === channel,
                      let tab = self.tab else {
                    return
                }
                self.onRemoteChannelClosed?(tab, reason)
            }
        }

        func prepareForDismantle() {
            updateHostTabActiveState(false)
            surfaceAttached = false
            terminalReadySignaled = false
            outputBindingGeneration += 1
            sessionOutputGeneration += 1
            viewportReadiness.invalidate()
            suspendOutputDeliveries()
            if let channel, let channelOutputReceiverToken {
                channel.unregisterTerminalOutputReceiver(channelOutputReceiverToken)
            }
            terminalLifetime?.unbind(owner: self)
            terminalLifetime = nil
            terminalSession = nil
            channelOutputReceiverToken = nil
            channel = nil
            session = nil
        }

        func requestInitialFirstResponder() {
            guard surfaceAttached, isHostTabActive, !hasRequestedInitialFirstResponder,
                  let terminalView, terminalView.isHostVisible else { return }
            hasRequestedInitialFirstResponder = true
            let generation = hostVisibilityGeneration
            DispatchQueue.main.async { [weak self, weak terminalView] in
                guard let self, let terminalView,
                      self.surfaceAttached, self.isHostTabActive,
                      self.hostVisibilityGeneration == generation,
                      self.terminalView === terminalView,
                      terminalView.isHostVisible else { return }
                _ = terminalView.becomeFirstResponder()
            }
        }

        // MARK: - Resize (terminal grid → SSH window-change)

        func handleResize(cols: Int, rows: Int) {
            guard let gridSize = TerminalGridSize(cols: cols, rows: rows) else { return }
            lastGridSize = gridSize
            hasMeasuredGridSize = true
            viewportReadiness.measurementDidChange()
            if channel?.isOpen == true || !preservesInheritedGridSizeForInitialOpen {
                tab?.terminalGridSize = gridSize
            }
            if channel?.isOpen == true {
                channel?.resizeTerminal(cols: cols, rows: rows)
            }
        }

        private func beginViewportSettle() {
            guard surfaceAttached, !terminalReadySignaled else { return }
            if hasMeasuredGridSize || tab?.terminalGridSize != nil {
                viewportReadiness.measurementDidChange()
            }
            suspendOutputDeliveries()
            viewportReadiness.begin(
                fitViewport: { [weak self] in
                    self?.terminalView?.fitToSize()
                },
                onReady: { [weak self] readinessGeneration in
                    self?.signalTerminalReadyAndOpenChannelIfNeeded(
                        readinessGeneration: readinessGeneration
                    )
                }
            )
        }

        private func signalTerminalReadyAndOpenChannelIfNeeded(
            readinessGeneration: Int
        ) {
            guard surfaceAttached,
                  !terminalReadySignaled,
                  viewportReadiness.generation == readinessGeneration,
                  hasMeasuredGridSize || tab?.terminalGridSize != nil
            else {
                return
            }

            terminalReadySignaled = true
            resumeOutputDeliveries(readinessGeneration: readinessGeneration)
            session?.signalTerminalReady()
            openChannelIfReady()
        }

        private func suspendOutputDeliveries() {
            terminalLifetime?.setOutputReady(false, owner: self)
            if let channel, let channelOutputReceiverToken {
                channel.setTerminalOutputReady(
                    false,
                    token: channelOutputReceiverToken
                )
            }
        }

        private func resumeOutputDeliveries(readinessGeneration: Int) {
            let bindingGeneration = outputBindingGeneration
            let completion: @Sendable () -> Void = { [weak self] in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.requestPostFlushDraw(
                            bindingGeneration: bindingGeneration,
                            readinessGeneration: readinessGeneration
                        )
                    }
                }
            }
            if let channel, let channelOutputReceiverToken {
                terminalLifetime?.setOutputReady(true, owner: self)
                channel.setTerminalOutputReady(
                    true,
                    token: channelOutputReceiverToken,
                    onDrain: completion
                )
            } else {
                terminalLifetime?.setOutputReady(true, owner: self, onDrain: completion)
            }
        }

        private func requestPostFlushDraw(
            bindingGeneration: Int,
            readinessGeneration: Int
        ) {
            guard surfaceAttached,
                  terminalReadySignaled,
                  terminalLifetime?.ownsHost(self) == true,
                  outputBindingGeneration == bindingGeneration,
                  viewportReadiness.generation == readinessGeneration else {
                tracePostFlushDraw(
                    "request-skipped attached=\(surfaceAttached) ready=\(terminalReadySignaled) "
                        + "binding=\(outputBindingGeneration)/\(bindingGeneration) "
                        + "readiness=\(viewportReadiness.generation)/\(readinessGeneration)"
                )
                return
            }
            tracePostFlushDraw(
                "request view=\(terminalView != nil) visible=\(terminalView?.isHostVisible ?? false) "
                    + "size=\(terminalView.map { "\($0.bounds.width)x\($0.bounds.height)" } ?? "nil")"
            )
            terminalView?.requestImmediateDraw(onPostRender: { [weak self] in
                guard let self,
                      self.surfaceAttached,
                      self.terminalReadySignaled,
                      self.terminalLifetime?.ownsHost(self) == true,
                      self.outputBindingGeneration == bindingGeneration,
                      self.viewportReadiness.generation == readinessGeneration else {
                    self?.tracePostFlushDraw("render-skipped")
                    return
                }
                self.tracePostFlushDraw("rendered")
                self.onPostFlushDraw?()
            })
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
            let openingOutputDelivery = sessionOutputDelivery
            let openingGridSize = tab.terminalGridSize ?? lastGridSize

            do {
                // Publish queue ownership and tokenized surface binding before
                // the transport open can suspend. A replacement representable
                // therefore observes this same channel instead of opening a
                // duplicate or mutating its adopted output queue directly.
                let openedChannel = try session.createShellChannel(
                    terminalOutputDelivery: openingOutputDelivery
                )
                tab.channel = openedChannel
                tab.terminalGridSize = openingGridSize
                preservesInheritedGridSizeForInitialOpen = false
                channel = openedChannel
                terminalLifetime?.channelID = openedChannel.id
                terminalLifetime?.channel = openedChannel

                if sessionOutputDelivery === openingOutputDelivery {
                    let replacementDelivery = TerminalOutputDeliveryQueue(
                        label: "dev.sshapp.sshapp.normal-terminal-output"
                    )
                    replacementDelivery.setReceiver(terminalSession)
                    sessionOutputDelivery = replacementDelivery
                    terminalLifetime?.outputDelivery = replacementDelivery
                }
                attachChannel(openedChannel)

                Task { @MainActor in
                    do {
                        try await openedChannel.openShell(
                            termType: "xterm-256color",
                            cols: openingGridSize.cols,
                            rows: openingGridSize.rows
                        )

                        if let command = tab.consumePendingAutoRunCommand() {
                            do {
                                try await openedChannel.writeTerminalCommand(command)
                            } catch {
                                logger.error("Failed to send auto-run command: \(error.localizedDescription)")
                            }
                        }
                    } catch {
                        let wasCurrentTabChannel = tab.channel === openedChannel
                        session.discardOpeningShellChannel(openedChannel)
                        if wasCurrentTabChannel {
                            tab.channel = nil
                        }
                        if channel === openedChannel {
                            updateChannel(nil)
                        }
                        if error is CancellationError {
                            logger.info("Shell channel opening was cancelled")
                        } else {
                            logger.error("Failed to open shell channel: \(error.localizedDescription)")
                            if wasCurrentTabChannel {
                                tab.connectionState = .failed(error.localizedDescription)
                            }
                        }
                    }
                }
            } catch {
                channelOpenRequested = false
                logger.error("Failed to create shell channel: \(error.localizedDescription)")
                tab.connectionState = .failed(error.localizedDescription)
            }
        }

        // MARK: - Input router (terminal output → SSH / auth capture)

        func forwardFromTerminal(_ data: Data) {
            guard let session else {
                logger.warning("forwardFromTerminal: session is nil, dropping \(data.count)B")
                return
            }

            let normalizedData = TerminalInputNormalizer.normalize(data)
            #if DEBUG
            LiveSSHUITestInputObservation.shared.receivedInput()
            #endif

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
            guard isHostTabActive, terminalView?.isHostVisible == true else { return }
            terminalSession?.enqueueInput(.text("\r"))
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
    TerminalSurfaceLifecycleDelegate,
    TerminalSurfaceOpenURLDelegate {

    func terminalDidChangeTitle(_ title: String) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }

        tab?.isTitleOwnedByTerminal = true
        tab?.title = title
    }

    /// The terminal becomes first responder on touch. The first focus pass
    /// defers a viewport refit so Ghostty sees the final SwiftUI layout after
    /// the host keyboard bar's bottom safe-area inset has settled. Gated to fire
    /// once per view instance to avoid refit churn on later focus/blur.
    func terminalDidChangeFocus(_ focused: Bool) {
        guard focused, isHostTabActive,
              let terminalView, terminalView.isHostVisible else { return }
        syncKeyboardBarTarget()
        guard !hasPerformedInitialFocusReload else { return }
        let generation = hostVisibilityGeneration
        DispatchQueue.main.async { [weak self, weak terminalView] in
            guard let self, let terminalView,
                  self.isHostTabActive,
                  self.hostVisibilityGeneration == generation,
                  self.terminalView === terminalView,
                  terminalView.isHostVisible,
                  !self.hasPerformedInitialFocusReload else { return }
            self.hasPerformedInitialFocusReload = true
            terminalView.refreshInputAccessoryViewport()
        }
    }

    func terminalDidRingBell() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    func terminalDidRequestOpenURL(_ url: String, kind _: TerminalOpenURLKind) {
        TerminalLinkOpener.open(url)
    }

    func terminalDidClose(processAlive: Bool) {
        // The SSH channel/process ended; connection teardown is handled by the
        // SSH layer / tab state.
    }

    func terminalDidAttachSurface(_ surface: TerminalSurface) {
        surfaceAttached = true
        terminalReadySignaled = false
        suspendOutputDeliveries()
        // The raw surface now has initial metrics, but UIKit still owes deferred
        // layout fits. Keep SSH output buffered until that viewport is stable.
        requestInitialFirstResponder()
        beginViewportSettle()
    }

    func terminalDidDetachSurface() {
        surfaceAttached = false
        terminalReadySignaled = false
        viewportReadiness.invalidate()
        // Retain same-channel bytes while a replacement surface is constructed.
        suspendOutputDeliveries()
    }
}
