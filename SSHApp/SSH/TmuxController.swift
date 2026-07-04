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

@MainActor
@Observable
final class TmuxController {
    // MARK: - Observable state

    private(set) var state: TmuxState = .bootstrapping
    private(set) var serverVersion: TmuxVersion?
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
    private var pendingOutputForUnmappedPanes: [TmuxPaneID: Data] = [:]

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

        if settings.pauseModeEnabled, serverVersion?.supportsPauseMode == true {
            do {
                _ = try await gateway.sendCommand("refresh-client -fpause-after=\(settings.pauseAfterSeconds)")
                logger.info("pause-after enabled: \(self.settings.pauseAfterSeconds)s")
            } catch {
                logger.warning("pause-mode setup failed: \(error.localizedDescription)")
            }
        }

        if settings.backfillEnabled {
            for paneID in panes.keys {
                await backfillScrollback(for: paneID)
            }
        }

        state = .attached
        statusMessage = nil
        logger.info("attached: \(self.windows.count) windows, \(self.panes.count) panes")
    }

    // MARK: - User actions

    func detach() async {
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
        let version = serverVersion ?? TmuxVersion(major: 2, minor: 0)
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
        if serverVersion?.supportsVariableWindowSize == false {
            target = "\(cols),\(rows)"
        } else {
            target = "\(windowID.wire):\(cols)x\(rows)"
        }

        do {
            _ = try await gateway.sendCommand("refresh-client -C \(target)")
            lastSentWindowSizes[windowID] = (cols, rows)
            if serverVersion?.supportsVariableWindowSize == false {
                lastSentSize = (cols, rows)
            }
        } catch {
            logger.warning("refresh-client for \(windowID.wire) failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Active state helpers

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
            logger.warning("split-pane response did not identify new pane: \(line, privacy: .public)")
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
        panesWithReceivedOutput.insert(paneID)
        if let pane = paneForOutput(paneID) {
            pane.feed(data)
            return
        }

        var pending = pendingOutputForUnmappedPanes[paneID] ?? Data()
        pending.append(data)
        pendingOutputForUnmappedPanes[paneID] = pending
        logger.info("buffering output for unknown pane \(paneID.wire, privacy: .public) until attach metadata arrives")
    }

    private func replayPendingOutputIfNeeded(for paneID: TmuxPaneID) {
        guard let pending = pendingOutputForUnmappedPanes.removeValue(forKey: paneID),
              !pending.isEmpty
        else {
            return
        }
        panes[paneID]?.feed(pending)
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
            let response = try await gateway.sendCommand(
                "display-message -p \"#{version}\\t#{session_name}\""
            )
            let line = response.bodyString.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            if let versionPart = parts.first {
                serverVersion = TmuxVersion(parsing: String(versionPart))
            }
            if parts.count >= 2 {
                sessionName = String(parts[1])
            }
            logger.info("probed: version=\(self.serverVersion?.description ?? "?") session=\(self.sessionName ?? "?")")
        } catch {
            logger.warning("version probe failed: \(error.localizedDescription)")
        }
    }

    private func listWindows() async {
        do {
            let response = try await gateway.sendCommand(
                "list-windows -F \"#{window_id}\\t#{window_name}\\t#{window_active}\\t#{window_layout}\""
            )
            for line in response.bodyLines where !line.isEmpty {
                let parts = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
                guard parts.count == 4,
                      let windowID = TmuxWindowID(wire: String(parts[0]))
                else { continue }
                let name = String(parts[1])
                let isActive = parts[2] == "1"
                let layout = String(parts[3])

                let window = TmuxWindow(id: windowID, name: name, layoutString: layout)
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
        await capturePane(for: paneID, lines: settings.scrollbackLines, skipIfOutputArrived: true)
    }

    @discardableResult
    private func backfillVisiblePane(for paneID: TmuxPaneID) async -> Bool {
        let lines = max(panes[paneID]?.rows ?? 24, 24)
        return await capturePane(for: paneID, lines: lines, skipIfOutputArrived: true)
    }

    @discardableResult
    private func capturePane(
        for paneID: TmuxPaneID,
        lines: Int,
        skipIfOutputArrived: Bool = false
    ) async -> Bool {
        guard panes[paneID] != nil else { return false }
        let nFlag = serverVersion?.supportsCapturePaneN == true ? "N" : ""
        do {
            let primary = try await gateway.sendCommand(
                "capture-pane -peqJ\(nFlag) -t \(paneID.wire) -S -\(lines)"
            )
            guard !skipIfOutputArrived || !panesWithReceivedOutput.contains(paneID) else {
                return true
            }
            guard !primary.bodyString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return false
            }
            panes[paneID]?.feed(primary.body)
            panesWithReceivedOutput.insert(paneID)
            return true
        } catch {
            logger.warning("backfill failed for \(paneID.wire): \(error.localizedDescription)")
            return false
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
                panesWithReceivedOutput.remove(paneID)
                pendingOutputForUnmappedPanes.removeValue(forKey: paneID)
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

        case .layoutChange(let windowID, let layout, let visibleLayout, _):
            if let window = windows[windowID] {
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

        case .sessionChanged(_, let name):
            sessionName = name

        case .sessionWindowChanged(_, let windowID):
            applyActiveWindow(windowID)

        case .sessionRenamed(let name):
            sessionName = name

        case .pause(let paneID):
            if let id = paneID, let pane = panes[id] {
                pane.isPaused = true
                statusMessage = "Pane \(id.wire) paused"
            } else {
                statusMessage = "Session paused"
            }

        case .continueProcessing(let paneID):
            if let id = paneID {
                panes[id]?.isPaused = false
            }
            statusMessage = nil

        case .clientDetached:
            state = .exited(reason: "detached")
            statusMessage = "Detached"

        case .exit(let reason):
            state = .exited(reason: reason)
            statusMessage = reason ?? "tmux exited"

        case .commandResponse,
             .sessionsChanged,
             .unlinkedWindowAdd,
             .paneModeChanged,
             .subscriptionChanged,
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
