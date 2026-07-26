//
//  TmuxController.swift
//  SSHApp
//
//  High-level coordinator for a tmux -CC session. Owns windows/panes state,
//  drives the attach sequence, routes events from the gateway, and exposes
//  UI-friendly mutation commands.
//

import Foundation
import os

private let logger = Logger(subsystem: "dev.sshapp.sshapp.tmux", category: "controller")

/// Refresh-client debounce window. Latest-wins.
private let refreshDebounceNanos: UInt64 = 50_000_000  // 50ms
private let newPaneBackfillDelayNanos: UInt64 = 150_000_000  // 150ms
private let newPaneBackfillRetryDelayNanos: UInt64 = 250_000_000  // 250ms
private let newPaneBackfillAttempts = 2
private let nestedTmuxClientMatchWindow: TimeInterval = 2.0

/// Auto-resume budget for a pane tmux keeps pausing. A pane whose output
/// genuinely outruns the link will re-pause immediately after every continue, and
/// each resume costs a full scrollback re-capture — so cap the retries and leave
/// the pane paused (and say so) rather than looping on a metered connection.
private let paneResumeAttemptLimit = 3
private let paneResumeAttemptWindow: TimeInterval = 60.0

@MainActor
@Observable
final class TmuxController {
    // MARK: - Observable state

    private(set) var state: TmuxState = .bootstrapping
    private(set) var serverVersion: TmuxVersion?
    private(set) var sessionID: TmuxSessionID?
    private(set) var sessionName: String?

    /// Windows keyed by ID for direct lookup. Display order via `windowOrder`.
    /// Internal-writable so tests can seed state directly.
    var windows: [TmuxWindowID: TmuxWindow] = [:]
    var windowOrder: [TmuxWindowID] = []

    /// All panes across all windows. Internal-writable for tests.
    var panes: [TmuxPaneID: TmuxPane] = [:]

    var activeWindowID: TmuxWindowID?
    var activePaneID: TmuxPaneID?

    /// Last user-facing message (e.g. "Detached", "Pane paused").
    private(set) var statusMessage: String?

    // MARK: - Settings

    let settings: TmuxSettings

    // MARK: - Dependencies

    let gateway: TmuxGateway

    // MARK: - Internal

    @ObservationIgnored
    private var lastSentSize: (cols: Int, rows: Int)?

    @ObservationIgnored
    private var lastSentWindowSizes: [TmuxWindowID: (cols: Int, rows: Int)] = [:]

    @ObservationIgnored
    private var refreshTask: Task<Void, Never>?

    @ObservationIgnored
    private var windowRefreshTasks: [TmuxWindowID: Task<Void, Never>] = [:]

    @ObservationIgnored
    private var newPaneBackfillTasks: [TmuxPaneID: Task<Void, Never>] = [:]

    @ObservationIgnored
    private var panesWithReceivedOutput: Set<TmuxPaneID> = []

    @ObservationIgnored
    private var deferredBackfillTask: Task<Void, Never>?

    @ObservationIgnored
    private var paneResumeTasks: [TmuxPaneID: Task<Void, Never>] = [:]

    @ObservationIgnored
    private var paneResumeAttempts: [TmuxPaneID: [Date]] = [:]

    @ObservationIgnored
    private var pauseStartedAt: [TmuxPaneID: Date] = [:]

    @ObservationIgnored
    private var pendingOutputForUnmappedPanes: [TmuxPaneID: Data] = [:]

    @ObservationIgnored
    private var panesRestoringSnapshot: Set<TmuxPaneID> = []

    @ObservationIgnored
    private var pendingOutputDuringSnapshot: [TmuxPaneID: Data] = [:]

    @ObservationIgnored
    private var pendingNestedControlStartTimes: [Date] = []

    @ObservationIgnored
    private var recentClientSessionChanges: [TmuxClientSessionChange] = []

    @ObservationIgnored
    private var handledNestedClientNames: Set<String> = []

    /// This client's own tmux client name, probed at attach. The nested-tmux
    /// cleanup must never act on it.
    @ObservationIgnored
    private var ownClientName: String?

    /// The server's `history-limit`, probed at attach. Used to avoid asking for
    /// more scrollback than tmux actually keeps.
    @ObservationIgnored
    private var serverHistoryLimit: Int?

    /// The version every feature gate is decided against.
    ///
    /// Routed through one accessor because the gates used to disagree about what
    /// an unknown version meant: the `-H` gate assumed tmux 2.0 (silently
    /// corrupting every control byte on a modern server) while the window-size
    /// gate assumed modern. See `TmuxVersion.assumedWhenUnknown`.
    var effectiveVersion: TmuxVersion {
        serverVersion ?? .assumedWhenUnknown
    }

    private struct TmuxClientSessionChange: Equatable {
        let clientName: String
        let sessionID: TmuxSessionID
        let sessionName: String
        let observedAt: Date
    }

    // MARK: - Init

    init(gateway: TmuxGateway, settings: TmuxSettings = .default) {
        self.gateway = gateway
        self.settings = settings
    }

    // MARK: - Attach sequence

    /// Run the post-DCS bootstrap: probe version, list windows + panes,
    /// set client size, optionally enable pause-mode, optionally backfill.
    func attach(initialCols: Int, initialRows: Int) async {
        state = .bootstrapping
        statusMessage = "Attaching..."
        pendingNestedControlStartTimes.removeAll()
        recentClientSessionChanges.removeAll()
        handledNestedClientNames.removeAll()

        await probeVersionAndSessionName()
        await listWindows()
        for windowID in windowOrder {
            await listPanes(in: windowID)
        }
        await discoverActivePane()

        do {
            _ = try await gateway.sendCommand("refresh-client -C \(initialCols),\(initialRows)")
            lastSentSize = (initialCols, initialRows)
        } catch {
            logger.warning("refresh-client at attach failed: \(error.localizedDescription)")
        }

        if settings.pauseModeEnabled, effectiveVersion.supportsPauseMode {
            do {
                _ = try await gateway.sendCommand("refresh-client -fpause-after=\(settings.pauseAfterSeconds)")
                logger.info("pause-after enabled: \(self.settings.pauseAfterSeconds)s")
            } catch {
                logger.warning("pause-mode setup failed: \(error.localizedDescription)")
            }
        }

        // Restore the pane the user is actually looking at before declaring the
        // session attached, then finish the rest in the background. The bootstrap
        // costs 5 + W + 4P round trips, so waiting for every pane in every window
        // left the UI on "Attaching…" for tens of seconds on a high-latency link.
        let backfillPanes = settings.backfillEnabled ? backfillOrder() : []
        if let visiblePane = backfillPanes.first {
            await backfillScrollback(for: visiblePane)
        }

        // Only promote to `.attached` if the bootstrap is still the current
        // story. `listWindows` sets `.failed` on error and a mid-attach `%exit`
        // sets `.exited`; overwriting either strands the UI in a state that
        // claims success while carrying no windows and no error message.
        guard case .bootstrapping = state else {
            logger.warning(
                "attach finished but state moved on: \(String(describing: self.state), privacy: .public)"
            )
            return
        }

        state = .attached
        statusMessage = nil
        cleanupNestedTmuxClientIfReady()
        logger.info("attached: \(self.windows.count) windows, \(self.panes.count) panes")

        if backfillPanes.count > 1 {
            scheduleDeferredBackfill(Array(backfillPanes.dropFirst()))
        }
    }

    // MARK: - User actions

    func detach() async {
        pendingNestedControlStartTimes.removeAll()
        recentClientSessionChanges.removeAll()
        handledNestedClientNames.removeAll()
        do {
            try await gateway.detach()
        } catch {
            logger.warning("detach failed: \(error.localizedDescription)")
        }
        state = .exited(reason: "user detached")
        statusMessage = "Detached"
    }

    func selectWindow(_ id: TmuxWindowID) async {
        do {
            _ = try await gateway.sendCommand("select-window -t \(id.wire)")
            applyActiveWindow(id)
        } catch {
            logger.warning("select-window failed: \(error.localizedDescription)")
        }
    }

    func selectPreviousWindow() async {
        guard let windowID = IndexedTabNavigation.previous(
            in: windowOrder,
            selected: activeWindowID
        ) else {
            return
        }
        await selectWindow(windowID)
    }

    func selectNextWindow() async {
        guard let windowID = IndexedTabNavigation.next(
            in: windowOrder,
            selected: activeWindowID
        ) else {
            return
        }
        await selectWindow(windowID)
    }

    func selectWindow(shortcutDigit digit: Int) async {
        guard let windowID = IndexedTabNavigation.item(
            forShortcutDigit: digit,
            in: windowOrder
        ) else {
            return
        }
        await selectWindow(windowID)
    }

    func focusPane(_ id: TmuxPaneID) {
        if let pane = panes[id] {
            applyWindowActivePane(windowID: pane.windowID, paneID: id, makeWindowActive: true)
        }
    }

    func selectPane(_ id: TmuxPaneID) async {
        focusPane(id)

        do {
            _ = try await gateway.sendCommand("select-pane -t \(id.wire)")
        } catch {
            logger.warning("select-pane failed: \(error.localizedDescription)")
        }
    }

    func resizePane(_ id: TmuxPaneID, cols: Int? = nil, rows: Int? = nil) async {
        var components = ["resize-pane", "-t", id.wire]
        if let cols {
            components.append(contentsOf: ["-x", "\(cols)"])
        }
        if let rows {
            components.append(contentsOf: ["-y", "\(rows)"])
        }
        let command = components.joined(separator: " ")

        do {
            logger.info("resize-pane sending command=\(command, privacy: .public)")
            _ = try await gateway.sendCommand(command)
            logger.info("resize-pane succeeded command=\(command, privacy: .public)")
        } catch {
            logger.warning("resize-pane failed command=\(command, privacy: .public) error=\(error.localizedDescription)")
        }
    }

    func splitPane(_ direction: TmuxSplitDirection, target: TmuxPaneID? = nil) async {
        let requestedTarget = target ?? activePaneID
        logger.info(
            "split-pane requested direction=\(direction.description, privacy: .public) target=\(requestedTarget?.wire ?? "nil", privacy: .public)"
        )

        guard let paneID = requestedTarget else {
            logger.warning("split-pane failed: no active or target pane")
            return
        }

        let command = "split-window -P -F \"#{pane_id}\\t#{window_id}\\t#{pane_width}\\t#{pane_height}\\t#{window_layout}\" \(direction.commandFlag) -t \(paneID.wire)"
        do {
            let response = try await gateway.sendCommand(command)
            logger.info("split-pane command sent: \(command, privacy: .public)")
            handleSplitPaneResponse(response)
        } catch {
            logger.warning("split-pane failed: \(error.localizedDescription)")
        }
    }

    /// Toggle zoom for the window containing `paneID`.
    ///
    /// The rendering half already worked: tmux reports the zoomed single-pane
    /// layout in `window_visible_layout`, and `displayLayout` prefers it. All
    /// that was missing was the control and the state — the `Z` window flag now
    /// lands in `TmuxWindow.isZoomed` via `%layout-change`.
    ///
    /// This is the highest-value pane primitive on a phone: four panes on an
    /// iPhone are unusable, and without zoom there is no way out of that.
    func toggleZoom(_ paneID: TmuxPaneID) async {
        do {
            _ = try await gateway.sendCommand("resize-pane -Z -t \(paneID.wire)")
        } catch {
            logger.warning("resize-pane -Z failed: \(error.localizedDescription)")
        }
    }

    /// Kill a single pane. Without this a mis-tapped split could only be undone
    /// by destroying the whole window.
    func killPane(_ paneID: TmuxPaneID) async {
        do {
            _ = try await gateway.sendCommand("kill-pane -t \(paneID.wire)")
        } catch {
            logger.warning("kill-pane failed: \(error.localizedDescription)")
        }
    }

    /// Apply a built-in tmux layout to a window.
    func selectLayout(_ preset: TmuxLayoutPreset, in windowID: TmuxWindowID) async {
        do {
            _ = try await gateway.sendCommand(
                "select-layout -t \(windowID.wire) \(preset.commandArgument)"
            )
        } catch {
            logger.warning("select-layout failed: \(error.localizedDescription)")
        }
    }

    /// Move focus to the neighbouring pane. tmux answers with
    /// `%window-pane-changed`, which updates `activePaneID` through the normal
    /// event path — no local guessing about which pane is adjacent.
    func selectPane(_ direction: TmuxPaneDirection, from paneID: TmuxPaneID) async {
        do {
            _ = try await gateway.sendCommand(
                "select-pane -t \(paneID.wire) \(direction.commandFlag)"
            )
        } catch {
            logger.warning("directional select-pane failed: \(error.localizedDescription)")
        }
    }

    /// Rename a window. Names are user text, so they go through the same
    /// escaping as keystrokes — a window called `$HOME` must stay `$HOME`.
    func renameWindow(_ windowID: TmuxWindowID, to name: String) async {
        do {
            _ = try await gateway.sendCommand(
                "rename-window -t \(windowID.wire) \(Self.tmuxDoubleQuoted(name))"
            )
            windows[windowID]?.name = name
        } catch {
            logger.warning("rename-window failed: \(error.localizedDescription)")
        }
    }

    /// Set a pane's title (`#{pane_title}`), which the pane strip renders.
    func setPaneTitle(_ paneID: TmuxPaneID, to title: String) async {
        do {
            _ = try await gateway.sendCommand(
                "select-pane -t \(paneID.wire) -T \(Self.tmuxDoubleQuoted(title))"
            )
            panes[paneID]?.title = title
        } catch {
            logger.warning("select-pane -T failed: \(error.localizedDescription)")
        }
    }

    func newWindow() async {
        do {
            _ = try await gateway.sendCommand("new-window")
        } catch {
            logger.warning("new-window failed: \(error.localizedDescription)")
        }
    }

    func killWindow(_ id: TmuxWindowID) async {
        do {
            _ = try await gateway.sendCommand("kill-window -t \(id.wire)")
        } catch {
            logger.warning("kill-window failed: \(error.localizedDescription)")
        }
    }

    func sendKeysToActivePane(_ data: Data) async {
        guard let paneID = activePaneID else {
            logger.warning("no active pane; dropping \(data.count)B of input")
            return
        }
        await sendKeys(to: paneID, data: data)
    }

    func sendKeys(to paneID: TmuxPaneID, data: Data) async {
        let version = effectiveVersion
        do {
            try await gateway.sendKeysToPane(paneID, data: data, version: version)
        } catch {
            logger.warning("send-keys failed: \(error.localizedDescription)")
        }
    }

    /// Update the tmux client size. Debounced 50ms latest-wins.
    func refreshClient(cols: Int, rows: Int) {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: refreshDebounceNanos)
            guard !Task.isCancelled, let self else { return }
            await self.sendRefreshClient(cols: cols, rows: rows)
        }
    }

    private func sendRefreshClient(cols: Int, rows: Int) async {
        if let last = lastSentSize, last.cols == cols, last.rows == rows {
            return
        }
        do {
            _ = try await gateway.sendCommand("refresh-client -C \(cols),\(rows)")
            lastSentSize = (cols, rows)
        } catch {
            logger.warning("refresh-client failed: \(error.localizedDescription)")
        }
    }

    /// Update a single tmux window size for control-mode split rendering.
    /// Debounced per window, latest-wins.
    func refreshWindow(_ windowID: TmuxWindowID, cols: Int, rows: Int) {
        windowRefreshTasks[windowID]?.cancel()
        windowRefreshTasks[windowID] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: refreshDebounceNanos)
            guard !Task.isCancelled, let self else { return }
            await self.sendRefreshWindow(windowID, cols: cols, rows: rows)
        }
    }

    private func sendRefreshWindow(_ windowID: TmuxWindowID, cols: Int, rows: Int) async {
        if let last = lastSentWindowSizes[windowID], last.cols == cols, last.rows == rows {
            return
        }

        let target: String
        if !effectiveVersion.supportsVariableWindowSize {
            target = "\(cols),\(rows)"
        } else {
            target = "\(windowID.wire):\(cols)x\(rows)"
        }

        do {
            _ = try await gateway.sendCommand("refresh-client -C \(target)")
            lastSentWindowSizes[windowID] = (cols, rows)
            if !effectiveVersion.supportsVariableWindowSize {
                lastSentSize = (cols, rows)
            }
        } catch {
            logger.warning("refresh-client for \(windowID.wire) failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Active state helpers

    /// Whether a session-scoped notification refers to the session this client is
    /// actually attached to.
    ///
    /// `sessionID` is only known once `%session-changed` has been processed, and
    /// `attach()` can run before that (the bootstrap task awaits gateway setup,
    /// not the line-delivery chain), so an unknown session is treated as ours
    /// rather than dropping the notifications that set up the initial view.
    private func isOwnSession(_ candidate: TmuxSessionID) -> Bool {
        guard let sessionID else { return true }
        return candidate == sessionID
    }

    private func applyActiveWindow(_ windowID: TmuxWindowID) {
        activeWindowID = windowID
        guard let window = windows[windowID] else {
            activePaneID = nil
            return
        }
        if let paneID = window.activePaneID ?? window.paneIDs.first {
            applyWindowActivePane(windowID: windowID, paneID: paneID, makeWindowActive: true)
        } else {
            activePaneID = nil
        }
    }

    private func applyWindowActivePane(
        windowID: TmuxWindowID,
        paneID: TmuxPaneID,
        makeWindowActive: Bool
    ) {
        if panes[paneID] == nil {
            panes[paneID] = TmuxPane(id: paneID, windowID: windowID)
        }
        panes[paneID]?.windowID = windowID
        replayPendingOutputIfNeeded(for: paneID)

        if let window = windows[windowID] {
            if !window.paneIDs.contains(paneID) {
                window.paneIDs.append(paneID)
            }
            window.activePaneID = paneID
            for id in window.paneIDs {
                panes[id]?.isActive = id == paneID
            }
        } else {
            windows[windowID] = TmuxWindow(
                id: windowID,
                paneIDs: [paneID],
                activePaneID: paneID
            )
            windowOrder.append(windowID)
            panes[paneID]?.isActive = true
        }

        if makeWindowActive {
            activeWindowID = windowID
            activePaneID = paneID
            // Panes paused while off screen are resumed lazily, so this is where
            // that cost is finally paid — when the user looks at them. Called
            // unconditionally rather than only on a window change: `applyActiveWindow`
            // assigns `activeWindowID` before routing here, so a "did it change"
            // test at this point would never fire. It is a no-op unless something
            // is actually stalled.
            resumeStalledVisiblePanes()
        }
    }

    private func handleSplitPaneResponse(_ response: TmuxCommandResponse) {
        let line = response.bodyLines.first(where: { !$0.isEmpty }) ?? ""
        guard !line.isEmpty else { return }

        let parts = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false)
        guard parts.count >= 2,
              let paneID = TmuxPaneID(wire: String(parts[0])),
              let windowID = TmuxWindowID(wire: String(parts[1]))
        else {
            logger.warning("split-pane response did not identify new pane: \(line, privacy: .private)")
            return
        }

        let pane = panes[paneID] ?? TmuxPane(id: paneID, windowID: windowID)
        pane.windowID = windowID
        if parts.count >= 3, let cols = Int(parts[2]) {
            pane.cols = cols
        }
        if parts.count >= 4, let rows = Int(parts[3]) {
            pane.rows = rows
        }
        panes[paneID] = pane
        replayPendingOutputIfNeeded(for: paneID)

        if let window = windows[windowID] {
            if parts.count >= 5, !parts[4].isEmpty {
                window.updateLayout(String(parts[4]))
            } else if !window.paneIDs.contains(paneID) {
                window.paneIDs.append(paneID)
            }
        } else {
            windows[windowID] = TmuxWindow(
                id: windowID,
                paneIDs: [paneID],
                activePaneID: paneID
            )
            windowOrder.append(windowID)
        }

        applyWindowActivePane(
            windowID: windowID,
            paneID: paneID,
            makeWindowActive: activeWindowID == nil || activeWindowID == windowID
        )
        scheduleNewPaneBackfillIfNeeded(paneID)
    }

    private func paneForOutput(_ paneID: TmuxPaneID) -> TmuxPane? {
        if let pane = panes[paneID] {
            return pane
        }

        // New split panes can emit their prompt before tmux sends the layout
        // change that materializes them in the UI.
        guard let windowID = activeWindowID ?? windowOrder.first else {
            return nil
        }

        let pane = TmuxPane(id: paneID, windowID: windowID)
        panes[paneID] = pane
        logger.info("buffering output for newly observed pane \(paneID.wire, privacy: .public) before layout metadata")
        replayPendingOutputIfNeeded(for: paneID)
        return pane
    }

    private func feedOutput(_ data: Data, to paneID: TmuxPaneID) {
        if panesRestoringSnapshot.contains(paneID) {
            var pending = pendingOutputDuringSnapshot[paneID] ?? Data()
            pending.append(data)
            pendingOutputDuringSnapshot[paneID] = pending
            return
        }

        if let pane = paneForOutput(paneID) {
            let result = pane.feedResult(data)
            if result.deliveredDisplayBytes {
                panesWithReceivedOutput.insert(paneID)
            }
            if result.didStartNestedControlMode {
                recordNestedControlModeStart(in: paneID)
            }
            return
        }

        var pending = pendingOutputForUnmappedPanes[paneID] ?? Data()
        pending.append(data)
        pendingOutputForUnmappedPanes[paneID] = pending
        logger.info("buffering output for unknown pane \(paneID.wire, privacy: .public) until attach metadata arrives")
    }

    @discardableResult
    private func replayPendingOutputIfNeeded(for paneID: TmuxPaneID) -> Bool {
        guard let pending = pendingOutputForUnmappedPanes.removeValue(forKey: paneID),
              !pending.isEmpty
        else {
            return false
        }
        guard let pane = panes[paneID] else { return false }
        let result = pane.feedResult(pending)
        if result.deliveredDisplayBytes {
            panesWithReceivedOutput.insert(paneID)
        }
        if result.didStartNestedControlMode {
            recordNestedControlModeStart(in: paneID)
        }
        return result.deliveredDisplayBytes
    }

    private func recordNestedControlModeStart(in paneID: TmuxPaneID) {
        guard panes[paneID] != nil else { return }
        pendingNestedControlStartTimes.append(Date())
        logger.info("nested tmux control mode detected in pane \(paneID.wire, privacy: .public)")
        cleanupNestedTmuxClientIfReady()
    }

    private func recordClientSessionChanged(
        clientName: String,
        sessionID: TmuxSessionID,
        sessionName: String
    ) {
        recentClientSessionChanges.append(TmuxClientSessionChange(
            clientName: clientName,
            sessionID: sessionID,
            sessionName: sessionName,
            observedAt: Date()
        ))
        pruneRecentClientSessionChanges()
        cleanupNestedTmuxClientIfReady()
    }

    private func cleanupNestedTmuxClientIfReady() {
        pruneRecentClientSessionChanges()
        guard !pendingNestedControlStartTimes.isEmpty, state.isAttached else { return }
        // Never act on our own client. This correlation is a 2s time window, not
        // an identity check, so a `%client-session-changed` for *this* client
        // arriving while a nested detection is pending would otherwise make us
        // detach ourselves and tear down the user's whole tmux view.
        guard let candidate = recentClientSessionChanges.last(where: {
            !handledNestedClientNames.contains($0.clientName) && $0.clientName != ownClientName
        }) else {
            return
        }

        pendingNestedControlStartTimes.removeLast()
        handledNestedClientNames.insert(candidate.clientName)

        logger.info(
            "detaching nested tmux client=\(candidate.clientName, privacy: .public) session=\(candidate.sessionID.wire, privacy: .public) name=\(candidate.sessionName, privacy: .public)"
        )

        Task { @MainActor [weak self] in
            await self?.detachNestedTmuxClient(candidate)
        }
    }

    private func pruneRecentClientSessionChanges() {
        let cutoff = Date().addingTimeInterval(-nestedTmuxClientMatchWindow)
        recentClientSessionChanges.removeAll { $0.observedAt < cutoff }
        pendingNestedControlStartTimes.removeAll { $0 < cutoff }
    }

    private func detachNestedTmuxClient(_ candidate: TmuxClientSessionChange) async {
        guard candidate.clientName != ownClientName else {
            logger.warning("refusing to detach our own tmux client")
            return
        }

        let clientName = Self.tmuxDoubleQuoted(candidate.clientName)
        do {
            _ = try await gateway.sendCommand("detach-client -t \(clientName)")
        } catch {
            logger.debug("nested tmux client detach failed: \(error.localizedDescription)")
        }

        guard await shouldKillNestedSession(candidate) else { return }
        do {
            _ = try await gateway.sendCommand("kill-session -t \"\(candidate.sessionID.wire)\"")
        } catch {
            logger.debug("nested tmux session cleanup failed: \(error.localizedDescription)")
        }
    }

    /// Whether the candidate session is safe to destroy.
    ///
    /// `kill-session` is irreversible, and the only thing linking this session to
    /// our nested-tmux detection is a 2-second time window. The previous test —
    /// "session name equals its numeric id" — matched any session a user happened
    /// to name `3`, so a stray `%client-session-changed` could destroy real work.
    ///
    /// Require positive evidence instead: the session must have been created
    /// inside the correlation window (so it really is the one our nested attach
    /// just spawned) and must have no clients attached after the detach above.
    /// Anything unproven leaves the session alone — an orphaned empty session is
    /// harmless clutter; killing the wrong one is data loss.
    private func shouldKillNestedSession(_ candidate: TmuxClientSessionChange) async -> Bool {
        guard candidate.sessionID != sessionID else { return false }
        guard candidate.sessionName == String(candidate.sessionID.rawValue) else { return false }

        let response: TmuxCommandResponse
        do {
            response = try await gateway.sendCommand(
                "display-message -p -t \"\(candidate.sessionID.wire)\" \"#{session_attached}\\t#{session_created}\""
            )
        } catch {
            logger.debug("nested session safety probe failed; leaving it alone")
            return false
        }

        let fields = response.bodyString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        guard fields.count == 2,
              let attached = Int(fields[0]),
              let created = Double(fields[1])
        else {
            logger.debug("nested session safety probe unparseable; leaving it alone")
            return false
        }

        guard attached == 0 else {
            logger.info("nested session \(candidate.sessionID.wire, privacy: .public) still has clients; leaving it")
            return false
        }

        let age = Date().timeIntervalSince1970 - created
        guard age >= 0, age <= nestedTmuxClientMatchWindow else {
            logger.info("nested session \(candidate.sessionID.wire, privacy: .public) predates our detection; leaving it")
            return false
        }
        return true
    }

    /// Wrap a value as a tmux double-quoted command argument.
    ///
    /// tmux's command lexer expands `\`, `$` and `~` inside double quotes, so all
    /// three must be escaped — the same defect fixed in `TmuxKeyEncoder`, and it
    /// matters more here because these arguments carry user-chosen window and
    /// session names. Verified against tmux 3.7b: `"$PATH"` interpolates the
    /// server's environment and a leading `~` becomes the server's home
    /// directory.
    static func tmuxDoubleQuoted(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count + 2)
        for character in value {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "$": escaped += "\\$"
            case "~": escaped += "\\~"
            default: escaped.append(character)
            }
        }
        return "\"\(escaped)\""
    }

    // MARK: - Pause recovery

    /// tmux never resumes a paused pane on its own. Once `pause-after` fires,
    /// `CONTROL_PANE_PAUSED` is cleared in exactly one place — `control_continue_pane()`,
    /// reachable only from `refresh-client -A '<pane>:continue'` (tmux 3.2+, man
    /// tmux "refresh-client"). We opt into `pause-after` at attach, so without
    /// this the pane stops delivering output for the life of the connection while
    /// keystrokes still land: the user types into a screen that never updates.
    private func handlePanePaused(_ paneID: TmuxPaneID) {
        guard let pane = panes[paneID] else { return }
        if pauseStartedAt[paneID] == nil {
            pauseStartedAt[paneID] = Date()
        }

        // Only spend a resume — and the capture that follows it — on a pane
        // somebody can actually see. A paused pane in a window the user never
        // opens costs nothing until they look at it.
        guard isPaneVisible(paneID) else {
            pane.activity = .stalled
            logger.info("pane \(paneID.wire, privacy: .public) paused off screen; deferring resume")
            return
        }

        guard recordResumeAttempt(for: paneID) else {
            pane.activity = .stalled
            logger.warning(
                "pane \(paneID.wire, privacy: .public) re-paused past its resume budget; awaiting the user"
            )
            return
        }

        pane.activity = .recovering
        startResumeTask(for: paneID)
    }

    /// A pane is on screen when its window is the active one: all panes of the
    /// active window render simultaneously as splits.
    private func isPaneVisible(_ paneID: TmuxPaneID) -> Bool {
        guard let windowID = panes[paneID]?.windowID else { return false }
        return windowID == activeWindowID
    }

    /// Resume panes left stalled because nobody was looking at them. Called when
    /// the active window changes, so the cost lands exactly when it buys the user
    /// something.
    private func resumeStalledVisiblePanes() {
        for (paneID, pane) in panes where pane.activity == .stalled {
            guard isPaneVisible(paneID), recordResumeAttempt(for: paneID) else { continue }
            pane.activity = .recovering
            startResumeTask(for: paneID)
        }
    }

    /// User-initiated resume, from the stalled banner. Clears the budget: a
    /// deliberate tap should not be rate-limited by a counter that exists to stop
    /// runaway background loops.
    func resumePaneManually(_ paneID: TmuxPaneID) {
        guard let pane = panes[paneID], pane.activity == .stalled else { return }
        paneResumeAttempts.removeValue(forKey: paneID)
        pane.activity = .recovering
        startResumeTask(for: paneID)
    }

    /// Full history rebuild, on demand. Expensive on a metered link — which is
    /// exactly why it is a tap rather than something the resume path does for
    /// you. Best effort: tmux's own `history-limit` may already have discarded
    /// what was missed.
    func reloadMissedOutput(for paneID: TmuxPaneID) async {
        guard panes[paneID] != nil else { return }
        panesWithReceivedOutput.remove(paneID)
        await restorePaneSnapshot(
            for: paneID,
            lines: settings.scrollbackLines,
            skipIfOutputArrived: false
        )
        panes[paneID]?.lastPauseGap = nil
    }

    private func startResumeTask(for paneID: TmuxPaneID) {
        paneResumeTasks[paneID]?.cancel()
        paneResumeTasks[paneID] = Task { @MainActor [weak self] in
            await self?.resumePane(paneID)
        }
    }

    private func resumePane(_ paneID: TmuxPaneID) async {
        guard panes[paneID] != nil else { return }

        // The pane argument MUST be quoted. tmux's lexer reads a bare
        // `%0:continue` as a format conditional and rejects the command outright
        // (verified against 3.7b: `refresh-client -A %0:continue` → parse error).
        do {
            _ = try await gateway.sendCommand("refresh-client -A \"\(paneID.wire):continue\"")
        } catch {
            logger.warning(
                "resume failed for \(paneID.wire, privacy: .public): \(error.localizedDescription)"
            )
            panes[paneID]?.activity = .stalled
            return
        }

        guard !Task.isCancelled, panes[paneID] != nil else { return }

        // tmux also sends `%continue`, which clears this via the normal event
        // path; do it here too so a missing notification can't leave the pane
        // marked paused forever.
        panes[paneID]?.activity = .running
        if let startedAt = pauseStartedAt.removeValue(forKey: paneID) {
            panes[paneID]?.lastPauseGap = Date().timeIntervalSince(startedAt)
        }

        await repaintVisiblePane(paneID)
    }

    /// Correct the pane's visible grid after a resume.
    ///
    /// A continue restarts the stream from *now*, so the screen is stale — but
    /// everything the pane rendered before the pause is still correct locally.
    /// Repainting just the visible rows costs one small capture instead of the
    /// user's entire scrollback, leaves Ghostty's scrollback and the user's
    /// scroll position untouched, and does not re-send content the device
    /// already has. The scrollback keeps a hole; `reloadMissedOutput` fills it
    /// on request.
    private func repaintVisiblePane(_ paneID: TmuxPaneID) async {
        guard panes[paneID] != nil else { return }

        let nFlag = effectiveVersion.supportsCapturePaneN ? "N" : ""
        // Reuse the snapshot buffering so output arriving mid-repaint is replayed
        // after it, rather than being overwritten by the repaint.
        panesRestoringSnapshot.insert(paneID)

        do {
            let stateResponse = try await gateway.sendCommand(
                "list-panes -t \(paneID.wire) -F \"\(TmuxPaneState.format)\""
            )
            guard let state = TmuxPaneState.parse(from: stateResponse.body, paneID: paneID) else {
                finishSnapshotRestore(for: paneID)
                return
            }

            let visible = try await gateway.sendCommand(
                "capture-pane -peq\(nFlag) -t \(paneID.wire) -S 0 -E -"
            )
            guard panes[paneID] != nil else {
                finishSnapshotRestore(for: paneID, replayBufferedOutput: false)
                return
            }

            let snapshot = TmuxPaneSnapshot(
                primaryHistory: Data(),
                visibleScreen: visible.body,
                state: state,
                pendingOutput: Data()
            )
            let rendered = TmuxPaneSnapshotRenderer.render(
                snapshot,
                cols: state.cols > 0 ? state.cols : (panes[paneID]?.cols ?? 80),
                rows: state.rows > 0 ? state.rows : (panes[paneID]?.rows ?? 24),
                mode: .repaintVisible
            )
            panes[paneID]?.feedSnapshot(rendered)
            finishSnapshotRestore(for: paneID)
        } catch {
            finishSnapshotRestore(for: paneID)
            logger.warning(
                "visible repaint failed for \(paneID.wire, privacy: .public): \(error.localizedDescription)"
            )
        }
    }

    /// Consume one resume from the pane's budget, returning false when the pane
    /// has already burned `paneResumeAttemptLimit` resumes inside the trailing
    /// `paneResumeAttemptWindow`.
    private func recordResumeAttempt(for paneID: TmuxPaneID) -> Bool {
        let now = Date()
        let cutoff = now.addingTimeInterval(-paneResumeAttemptWindow)
        var attempts = (paneResumeAttempts[paneID] ?? []).filter { $0 >= cutoff }
        defer { paneResumeAttempts[paneID] = attempts }

        guard attempts.count < paneResumeAttemptLimit else { return false }
        attempts.append(now)
        return true
    }

    private func scheduleNewPaneBackfillIfNeeded(_ paneID: TmuxPaneID) {
        newPaneBackfillTasks[paneID]?.cancel()
        newPaneBackfillTasks[paneID] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: newPaneBackfillDelayNanos)
            for attempt in 1...newPaneBackfillAttempts {
                guard let self, !Task.isCancelled else { return }
                guard self.panes[paneID] != nil else { return }
                guard !self.panesWithReceivedOutput.contains(paneID) else { return }

                let captured = await self.backfillVisiblePane(for: paneID)
                if captured {
                    return
                }
                guard attempt < newPaneBackfillAttempts else { return }
                try? await Task.sleep(nanoseconds: newPaneBackfillRetryDelayNanos)
            }
        }
    }

    // MARK: - Attach helpers

    private func probeVersionAndSessionName() async {
        do {
            // `#{client_name}` rides along for free on a probe we already make.
            // Knowing our own client name is what keeps the nested-tmux cleanup
            // from ever detaching this client — see cleanupNestedTmuxClientIfReady.
            let response = try await gateway.sendCommand(
                "display-message -p \"#{version}\\t#{session_name}\\t#{client_name}\\t#{history_limit}\""
            )
            let line = response.bodyString.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
            if let versionPart = parts.first {
                serverVersion = TmuxVersion(parsing: String(versionPart))
            }
            if parts.count >= 2 {
                sessionName = String(parts[1])
            }
            if parts.count >= 3 {
                let name = String(parts[2]).trimmingCharacters(in: .whitespaces)
                ownClientName = name.isEmpty ? nil : name
            }
            if parts.count >= 4, let limit = Int(String(parts[3]).trimmingCharacters(in: .whitespaces)) {
                serverHistoryLimit = max(limit, 0)
            }
            logger.info("probed: version=\(self.serverVersion?.description ?? "?") session=\(self.sessionName ?? "?")")
        } catch {
            logger.warning("version probe failed: \(error.localizedDescription)")
        }
    }

    private func listWindows() async {
        do {
            // `window_layout` deliberately ignores zoom, so a window that is
            // zoomed when we attach would render unzoomed until the next
            // %layout-change. `window_visible_layout` is the zoom-aware form and
            // `window_flags` tells us it *is* zoomed (see TmuxWindowFlags).
            let response = try await gateway.sendCommand(
                "list-windows -F \"#{window_id}\\t#{window_name}\\t#{window_active}\\t#{window_layout}\\t#{window_visible_layout}\\t#{window_flags}\""
            )
            for line in response.bodyLines where !line.isEmpty {
                let parts = line.split(separator: "\t", maxSplits: 5, omittingEmptySubsequences: false)
                guard parts.count >= 4,
                      let windowID = TmuxWindowID(wire: String(parts[0]))
                else { continue }
                let name = String(parts[1])
                let isActive = parts[2] == "1"
                let layout = String(parts[3])
                let visibleLayout = parts.count >= 5 && !parts[4].isEmpty ? String(parts[4]) : nil
                // Format expansion escapes `#` as `##`; TmuxWindowFlags(wire:)
                // treats repeated symbols idempotently, so both forms parse.
                let flags = parts.count >= 6 ? TmuxWindowFlags(wire: String(parts[5])) : []

                let window = TmuxWindow(
                    id: windowID,
                    name: name,
                    layoutString: layout,
                    visibleLayoutString: visibleLayout
                )
                window.flags = flags
                if windows[windowID] == nil {
                    windowOrder.append(windowID)
                }
                windows[windowID] = window
                if isActive {
                    applyActiveWindow(windowID)
                }
            }
        } catch {
            logger.error("list-windows failed: \(error.localizedDescription)")
            state = .failed(message: "list-windows: \(error.localizedDescription)")
        }
    }

    private func listPanes(in windowID: TmuxWindowID) async {
        guard let window = windows[windowID] else { return }
        do {
            let response = try await gateway.sendCommand(
                "list-panes -t \(windowID.wire) -F \"#{pane_id}\\t#{pane_active}\\t#{pane_title}\\t#{pane_width}\\t#{pane_height}\""
            )
            window.paneIDs.removeAll()
            for line in response.bodyLines where !line.isEmpty {
                let parts = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false)
                guard let firstPart = parts.first,
                      let paneID = TmuxPaneID(wire: String(firstPart))
                else { continue }

                let pane = panes[paneID] ?? TmuxPane(id: paneID, windowID: windowID)
                pane.windowID = windowID
                if parts.count >= 2 { pane.isActive = parts[1] == "1" }
                if parts.count >= 3 { pane.title = String(parts[2]) }
                if parts.count >= 4, let cols = Int(parts[3]) { pane.cols = cols }
                if parts.count >= 5, let rows = Int(parts[4]) { pane.rows = rows }

                panes[paneID] = pane
                replayPendingOutputIfNeeded(for: paneID)
                window.paneIDs.append(paneID)
                if pane.isActive {
                    applyWindowActivePane(
                        windowID: windowID,
                        paneID: paneID,
                        makeWindowActive: activeWindowID == windowID
                    )
                }
            }
        } catch {
            logger.warning("list-panes for \(windowID.wire) failed: \(error.localizedDescription)")
        }
    }

    private func discoverActivePane() async {
        do {
            let response = try await gateway.sendCommand(
                "display-message -p \"#{pane_id}\""
            )
            let trimmed = response.bodyString.trimmingCharacters(in: .whitespacesAndNewlines)
            if let paneID = TmuxPaneID(wire: trimmed) {
                if let pane = panes[paneID] {
                    applyWindowActivePane(
                        windowID: pane.windowID,
                        paneID: paneID,
                        makeWindowActive: true
                    )
                } else {
                    activePaneID = paneID
                }
            }
        } catch {
            logger.warning("active-pane probe failed: \(error.localizedDescription)")
        }
    }

    private func backfillScrollback(for paneID: TmuxPaneID) async {
        guard panes[paneID] != nil else { return }
        // Deliberately NOT `skipIfOutputArrived`. At attach the pane's Ghostty
        // surface is brand new, so the snapshot is the authoritative content and
        // the renderer's leading ESC[3J/ESC[2J supersedes anything already fed.
        //
        // The skip was actively harmful here: `attach()` sends `refresh-client -C`
        // two steps earlier, which resizes the tmux window and makes every shell
        // pane redraw its prompt. Those bytes marked the pane as having produced
        // output, so the guard suppressed the restore for exactly the panes that
        // needed it — a one-line prompt is not a substitute for the scrollback.
        await restorePaneSnapshot(
            for: paneID,
            lines: settings.scrollbackLines,
            skipIfOutputArrived: false
        )
    }

    /// Backfill order: the pane the user is looking at first.
    ///
    /// `panes.keys` is unordered, so the visible pane was previously as likely as
    /// not to be restored last — behind every pane in every other window.
    private func backfillOrder() -> [TmuxPaneID] {
        var ordered: [TmuxPaneID] = []
        var seen: Set<TmuxPaneID> = []

        func append(_ paneID: TmuxPaneID) {
            guard panes[paneID] != nil, seen.insert(paneID).inserted else { return }
            ordered.append(paneID)
        }

        if let activePaneID { append(activePaneID) }
        if let activeWindowID, let window = windows[activeWindowID] {
            for paneID in window.paneIDs { append(paneID) }
        }
        for paneID in panes.keys { append(paneID) }
        return ordered
    }

    /// Restore the remaining panes after the session is already usable.
    private func scheduleDeferredBackfill(_ paneIDs: [TmuxPaneID]) {
        deferredBackfillTask?.cancel()
        deferredBackfillTask = Task { @MainActor [weak self] in
            for paneID in paneIDs {
                guard let self, !Task.isCancelled, self.state.isAttached else { return }
                await self.backfillScrollback(for: paneID)
            }
        }
    }

    @discardableResult
    private func backfillVisiblePane(for paneID: TmuxPaneID) async -> Bool {
        let lines = max(panes[paneID]?.rows ?? 24, 24)
        return await restorePaneSnapshot(
            for: paneID,
            lines: lines,
            skipIfOutputArrived: true
        )
    }

    @discardableResult
    private func restorePaneSnapshot(
        for paneID: TmuxPaneID,
        lines: Int,
        skipIfOutputArrived: Bool = false
    ) async -> Bool {
        guard panes[paneID] != nil else { return false }

        let nFlag = effectiveVersion.supportsCapturePaneN ? "N" : ""
        panesRestoringSnapshot.insert(paneID)

        do {
            let stateResponse = try await gateway.sendCommand(
                "list-panes -t \(paneID.wire) -F \"\(TmuxPaneState.format)\""
            )
            guard let state = TmuxPaneState.parse(from: stateResponse.body, paneID: paneID) else {
                finishSnapshotRestore(for: paneID)
                logger.warning("pane snapshot state parse failed for \(paneID.wire)")
                return false
            }

            guard !skipIfOutputArrived || !panesWithReceivedOutput.contains(paneID) || state.alternateOn else {
                finishSnapshotRestore(for: paneID)
                return true
            }

            // `-E -1` ends the capture at the last history row, so this is pure
            // scrollback with no overlap with the visible screen. Two bugs fixed
            // at once, both verified against tmux 3.7b:
            //  * without `-E -1` the response also contained the visible screen,
            //    and the renderer split the two by comparing a `-J`-joined line
            //    count against a grid-row count — different units, so it deleted
            //    one scrollback line per wrapped row on screen;
            //  * this runs for alternate-screen panes too. The old code skipped
            //    it believing a plain capture returns only the alt grid; it does
            //    not — `-S -N` returns primary history *followed by* the alt
            //    grid, so skipping threw away real scrollback. `-E -1` gives the
            //    primary history alone even while the alt screen is active.
            // Never ask for more history than the server keeps. With the
            // scrollback setting at its 50000 maximum against a default
            // `history-limit` of 2000, the extra 48000 lines are pure round-trip
            // cost on a link that may be metered.
            let requestedLines = min(lines, serverHistoryLimit ?? lines)
            let primary = try await gateway.sendCommand(
                "capture-pane -peqJ\(nFlag) -t \(paneID.wire) -S -\(requestedLines) -E -1"
            )
            let primaryHistory = primary.body

            // Capture the exact visible rows without -J so full-screen TUIs can
            // be repainted row-for-row after control-mode attach.
            let visible = try await gateway.sendCommand(
                "capture-pane -peq\(nFlag) -t \(paneID.wire) -S 0 -E -"
            )

            let pending: Data
            do {
                let pendingResponse = try await gateway.sendCommand(
                    "capture-pane -p -P -C -t \(paneID.wire)"
                )
                pending = TmuxLineParser.unescapeOutputPayload(pendingResponse.body)
            } catch {
                pending = Data()
                logger.debug("pending pane output snapshot failed for \(paneID.wire): \(error.localizedDescription)")
            }

            guard panes[paneID] != nil else {
                finishSnapshotRestore(for: paneID, replayBufferedOutput: false)
                return false
            }

            let snapshot = TmuxPaneSnapshot(
                primaryHistory: primaryHistory,
                visibleScreen: visible.body,
                state: state,
                pendingOutput: pending
            )
            // Render at the geometry the state probe reported, not the pane's
            // cached size: the cache is only refreshed by `list-panes` at attach
            // and by view resizes, so a resize between them skewed every row.
            let rendered = TmuxPaneSnapshotRenderer.render(
                snapshot,
                cols: state.cols > 0 ? state.cols : (panes[paneID]?.cols ?? 80),
                rows: state.rows > 0 ? state.rows : (panes[paneID]?.rows ?? 24)
            )
            panes[paneID]?.feedSnapshot(rendered)
            finishSnapshotRestore(for: paneID)

            return !primaryHistory.isEmpty || !visible.body.isEmpty || !pending.isEmpty
        } catch {
            finishSnapshotRestore(for: paneID)
            logger.warning("backfill failed for \(paneID.wire): \(error.localizedDescription)")
            return false
        }
    }

    private func finishSnapshotRestore(
        for paneID: TmuxPaneID,
        replayBufferedOutput: Bool = true
    ) {
        panesRestoringSnapshot.remove(paneID)
        guard replayBufferedOutput,
              let pending = pendingOutputDuringSnapshot.removeValue(forKey: paneID),
              !pending.isEmpty
        else {
            pendingOutputDuringSnapshot.removeValue(forKey: paneID)
            return
        }

        if let pane = panes[paneID] {
            let result = pane.feedResult(pending)
            if result.deliveredDisplayBytes {
                panesWithReceivedOutput.insert(paneID)
            }
            if result.didStartNestedControlMode {
                recordNestedControlModeStart(in: paneID)
            }
        } else {
            var existing = pendingOutputForUnmappedPanes[paneID] ?? Data()
            existing.append(pending)
            pendingOutputForUnmappedPanes[paneID] = existing
        }
    }

    /// Materialize a freshly-added window post-attach. Issues a metadata query,
    /// then list-panes for the window.
    private func handleWindowAdd(_ windowID: TmuxWindowID) async {
        guard windows[windowID] == nil else { return }
        do {
            let response = try await gateway.sendCommand(
                "display-message -p -t \(windowID.wire) \"#{window_name}\\t#{window_layout}\""
            )
            let line = response.bodyString.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            let name = parts.first.map(String.init) ?? ""
            let layout = parts.count >= 2 ? String(parts[1]) : ""

            let window = TmuxWindow(id: windowID, name: name, layoutString: layout)
            windows[windowID] = window
            windowOrder.append(windowID)

            await listPanes(in: windowID)
        } catch {
            logger.warning("window-add details for \(windowID.wire) failed: \(error.localizedDescription)")
        }
    }

    private func scheduleWindowMaterialization(_ windowID: TmuxWindowID) {
        Task { @MainActor [weak self] in
            await self?.handleWindowAdd(windowID)
        }
    }

    // MARK: - Event processing

    fileprivate func processEvent(_ event: TmuxControllerEvent) async {
        switch event {
        case .output(let paneID, let data),
             .extendedOutput(let paneID, let data):
            feedOutput(data, to: paneID)

        case .windowAdd(let windowID):
            scheduleWindowMaterialization(windowID)

        case .windowClose(let windowID),
             .unlinkedWindowClose(let windowID):
            for paneID in windows[windowID]?.paneIDs ?? [] {
                newPaneBackfillTasks[paneID]?.cancel()
                newPaneBackfillTasks.removeValue(forKey: paneID)
                paneResumeTasks[paneID]?.cancel()
                paneResumeTasks.removeValue(forKey: paneID)
                paneResumeAttempts.removeValue(forKey: paneID)
                pauseStartedAt.removeValue(forKey: paneID)
                panesWithReceivedOutput.remove(paneID)
                pendingOutputForUnmappedPanes.removeValue(forKey: paneID)
                panesRestoringSnapshot.remove(paneID)
                pendingOutputDuringSnapshot.removeValue(forKey: paneID)
                panes.removeValue(forKey: paneID)
            }
            windows.removeValue(forKey: windowID)
            windowOrder.removeAll { $0 == windowID }
            if activeWindowID == windowID {
                if let nextWindowID = windowOrder.first {
                    applyActiveWindow(nextWindowID)
                } else {
                    activeWindowID = nil
                    activePaneID = nil
                }
            }

        case .windowRenamed(let windowID, let name):
            windows[windowID]?.name = name

        case .layoutChange(let windowID, let layout, let visibleLayout, let flags):
            if let window = windows[windowID] {
                window.flags = flags
                window.updateLayout(layout, visibleLayoutString: visibleLayout)
                for paneID in window.paneIDs {
                    let pane = panes[paneID] ?? TmuxPane(id: paneID, windowID: windowID)
                    pane.windowID = windowID
                    panes[paneID] = pane
                    replayPendingOutputIfNeeded(for: paneID)
                }
                if let activePaneID = window.activePaneID, window.paneIDs.contains(activePaneID) {
                    applyWindowActivePane(
                        windowID: windowID,
                        paneID: activePaneID,
                        makeWindowActive: self.activeWindowID == windowID
                    )
                } else if let firstPaneID = window.paneIDs.first {
                    applyWindowActivePane(
                        windowID: windowID,
                        paneID: firstPaneID,
                        makeWindowActive: self.activeWindowID == windowID
                    )
                }
            } else {
                scheduleWindowMaterialization(windowID)
            }

        case .windowPaneChanged(let windowID, let paneID):
            applyWindowActivePane(
                windowID: windowID,
                paneID: paneID,
                makeWindowActive: activeWindowID == windowID
            )

        case .sessionChanged(let id, let name):
            sessionID = id
            sessionName = name

        case .sessionWindowChanged(let eventSessionID, let windowID):
            // tmux does NOT scope this notification to the client's own session:
            // a client attached to $0 is told about every session on the server.
            // Verified against tmux 3.7b — switching another session's window
            // emits `%session-window-changed $1 @1` to us. Acting on it made the
            // UI jump to a window we have no state for, which blanked the view
            // and left `activePaneID` nil.
            guard isOwnSession(eventSessionID) else {
                logger.debug(
                    "ignoring %session-window-changed for foreign session \(eventSessionID.wire, privacy: .public)"
                )
                break
            }
            applyActiveWindow(windowID)

        case .sessionRenamed(let eventSessionID, let name):
            // Like %session-window-changed, this is not scoped to our session:
            // verified against tmux 3.7b, the id is present (`%session-renamed
            // $0 renamed`) precisely so clients can tell whose rename it is.
            guard eventSessionID.map(isOwnSession) ?? true else { break }
            sessionName = name

        case .clientSessionChanged(let clientName, let sessionID, let sessionName):
            recordClientSessionChanged(
                clientName: clientName,
                sessionID: sessionID,
                sessionName: sessionName
            )

        case .pause(let paneID):
            if let id = paneID, panes[id] != nil {
                handlePanePaused(id)
            } else {
                statusMessage = "Session paused"
            }

        case .continueProcessing(let paneID):
            if let id = paneID {
                panes[id]?.activity = .running
            }
            statusMessage = nil

        case .clientDetached(let name):
            if let name {
                handledNestedClientNames.remove(name)
                recentClientSessionChanges.removeAll { $0.clientName == name }
            }

        case .exit(let reason):
            state = .exited(reason: reason)
            statusMessage = reason ?? "tmux exited"

        case .message(let text):
            // `display-message` from any client on this server, including our own
            // non-`-p` invocations. Surface it rather than dropping it.
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                statusMessage = trimmed
            }
            logger.info("tmux message: \(trimmed, privacy: .public)")

        case .commandResponse,
             .sessionsChanged,
             .unlinkedWindowAdd,
             .paneModeChanged,
             .subscriptionChanged,
             .pasteBufferChanged,
             .pasteBufferDeleted,
             .configError:
            break
        }
    }
}

// MARK: - TmuxGatewayDelegate

extension TmuxController: TmuxGatewayDelegate {
    nonisolated func gateway(_ gateway: TmuxGateway, didReceive event: TmuxControllerEvent) async {
        await self.processEvent(event)
    }

    nonisolated func gatewayDidShutDown(_ gateway: TmuxGateway, reason: String?) async {
        await MainActor.run {
            self.state = .exited(reason: reason)
            self.statusMessage = reason ?? "Gateway shut down"
        }
    }
}
