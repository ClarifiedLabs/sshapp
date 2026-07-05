//
//  TmuxObservableModels.swift
//  SSHApp
//
//  Observable model types for tmux windows and panes — the UI-bound state.
//  Pure value/event types are in TmuxModels.swift.
//

import Foundation

struct TmuxPaneFeedResult: Equatable {
    let deliveredDisplayBytes: Bool
    let didStartNestedControlMode: Bool
}

/// One tmux window (a "tab" in tmux's terminology). Holds its panes and layout.
@MainActor
@Observable
final class TmuxWindow: Identifiable {
    let id: TmuxWindowID
    var name: String
    var paneIDs: [TmuxPaneID]
    var activePaneID: TmuxPaneID?
    var layoutString: String?
    var visibleLayoutString: String?
    private(set) var layoutNode: TmuxLayoutNode?
    private(set) var visibleLayoutNode: TmuxLayoutNode?
    var cols: Int
    var rows: Int

    init(
        id: TmuxWindowID,
        name: String = "",
        paneIDs: [TmuxPaneID] = [],
        activePaneID: TmuxPaneID? = nil,
        layoutString: String? = nil,
        visibleLayoutString: String? = nil,
        cols: Int = 80,
        rows: Int = 24
    ) {
        let parsedLayoutNode = layoutString.flatMap(TmuxLayoutParser.parse)?.coalesced()
        let parsedVisibleLayoutNode = visibleLayoutString.flatMap(TmuxLayoutParser.parse)?.coalesced()

        self.id = id
        self.name = name
        self.paneIDs = paneIDs
        self.activePaneID = activePaneID
        self.layoutString = layoutString
        self.visibleLayoutString = visibleLayoutString
        self.layoutNode = parsedLayoutNode
        self.visibleLayoutNode = parsedVisibleLayoutNode
        if paneIDs.isEmpty, let ids = parsedLayoutNode?.paneIDs {
            self.paneIDs = ids
        }
        self.cols = cols
        self.rows = rows
    }

    /// Apply a fresh layout string. Updates `layoutNode` and synchronises
    /// `paneIDs` with the panes the layout declares.
    func updateLayout(_ layoutString: String, visibleLayoutString: String? = nil) {
        self.layoutString = layoutString
        self.visibleLayoutString = visibleLayoutString
        self.layoutNode = TmuxLayoutParser.parse(layoutString)?.coalesced()
        self.visibleLayoutNode = visibleLayoutString.flatMap(TmuxLayoutParser.parse)?.coalesced()

        if let ids = layoutNode?.paneIDs ?? visibleLayoutNode?.paneIDs {
            self.paneIDs = ids
        }
        if let frame = displayLayoutNode?.frame {
            self.cols = frame.cols
            self.rows = frame.rows
        }
    }

    var displayLayoutNode: TmuxLayoutNode? {
        visibleLayoutNode ?? layoutNode
    }
}

/// One tmux pane within a window. Carries its byte stream sink + UI state.
@MainActor
@Observable
final class TmuxPane: Identifiable {
    let id: TmuxPaneID
    var windowID: TmuxWindowID
    var title: String
    var cols: Int
    var rows: Int
    var isActive: Bool
    var isPaused: Bool

    /// Set by the per-pane terminal view's coordinator when alive.
    /// Keep `@ObservationIgnored` so view updates don't churn just because
    /// the sink got rebound.
    @ObservationIgnored
    var feedSink: (@MainActor (Data) -> Void)?

    @ObservationIgnored
    private var feedSinkToken: UUID?

    /// Bytes received before `feedSink` was wired. Replayed once the sink lands.
    @ObservationIgnored
    private var pendingBytes: Data = Data()

    @ObservationIgnored
    private var controlModeOutputSuppressor = TmuxControlModeOutputSuppressor()

    init(
        id: TmuxPaneID,
        windowID: TmuxWindowID,
        title: String = "",
        cols: Int = 80,
        rows: Int = 24,
        isActive: Bool = false
    ) {
        self.id = id
        self.windowID = windowID
        self.title = title
        self.cols = cols
        self.rows = rows
        self.isActive = isActive
        self.isPaused = false
    }

    /// Feed data to the pane. If no sink is wired, buffer for later replay.
    /// Returns true when any display bytes survived filtering.
    @discardableResult
    func feed(_ data: Data) -> Bool {
        feedResult(data).deliveredDisplayBytes
    }

    @discardableResult
    func feedResult(_ data: Data) -> TmuxPaneFeedResult {
        let result = controlModeOutputSuppressor.filterWithResult(data)
        return TmuxPaneFeedResult(
            deliveredDisplayBytes: deliver(result.data),
            didStartNestedControlMode: result.didStartControlMode
        )
    }

    /// Replay a controller-generated snapshot without mutating the live output
    /// suppressor. A fresh suppressor still removes nested DCS bytes embedded
    /// in pending output captured with the snapshot.
    @discardableResult
    func feedSnapshot(_ data: Data) -> Bool {
        var snapshotSuppressor = TmuxControlModeOutputSuppressor()
        return deliver(snapshotSuppressor.filter(data))
    }

    private func deliver(_ filteredData: Data) -> Bool {
        guard !filteredData.isEmpty else { return false }
        if let sink = feedSink {
            sink(filteredData)
        } else {
            pendingBytes.append(filteredData)
        }
        return true
    }

    /// Wire a sink. Replays any pending bytes once, then keeps the sink for
    /// future feeds.
    @discardableResult
    func setSink(_ sink: @escaping @MainActor (Data) -> Void) -> UUID {
        let token = UUID()
        feedSinkToken = token
        feedSink = sink
        if !pendingBytes.isEmpty {
            sink(pendingBytes)
            pendingBytes.removeAll()
        }
        return token
    }

    /// Detach the sink if it still belongs to the caller. Subsequent feeds
    /// buffer until a new sink lands.
    func clearSink(_ token: UUID?) {
        guard let token, feedSinkToken == token else { return }
        feedSinkToken = nil
        feedSink = nil
    }
}

/// Resolved settings the controller uses (computed from global + per-host
/// overrides at attach time).
struct TmuxSettings: Sendable, Equatable {
    var backfillEnabled: Bool = true
    var pauseModeEnabled: Bool = true
    var scrollbackLines: Int = 5000
    var pauseAfterSeconds: Int = 30

    static let `default` = TmuxSettings()
}
