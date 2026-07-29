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

/// What tmux is currently doing with a pane's output.
///
/// This exists instead of a bare `isPaused` flag because the two paused states
/// want opposite treatment in the UI. With auto-resume a pause normally lasts
/// about one round trip, so binding a warning to "paused" would flash it on
/// every slow moment.
enum TmuxPaneActivity: Equatable, Sendable {
    /// Output is flowing.
    case running
    /// tmux paused the pane and an automatic resume is in flight. Deliberately
    /// invisible to the UI — it resolves on its own.
    case recovering
    /// Paused and not coming back on its own: either the pane burned its
    /// auto-resume budget, or it is off screen so the resume is deferred until
    /// someone looks at it. This is the state worth surfacing, because the pane
    /// still accepts keystrokes while showing a stale screen.
    case stalled
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
    private(set) var parsedLayout: TmuxLayout?
    private(set) var parsedVisibleLayout: TmuxLayout?
    var cols: Int
    var rows: Int

    /// Latest flags tmux reported for this window (`%layout-change`'s fourth
    /// field). Carries zoom plus the activity/bell/silence alerts.
    var flags: TmuxWindowFlags = []

    /// True when the window's active pane is zoomed. tmux reports the zoomed
    /// single-pane layout in `window_visible_layout`, so `displayLayout`
    /// already renders it correctly — this is what lets the UI say so and offer
    /// an unzoom.
    var isZoomed: Bool { flags.contains(.zoomed) }

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
        let parsedLayout = layoutString.flatMap(TmuxLayoutParser.parse)
        let parsedVisibleLayout = visibleLayoutString.flatMap(TmuxLayoutParser.parse)

        self.id = id
        self.name = name
        self.paneIDs = paneIDs
        self.activePaneID = activePaneID
        self.layoutString = layoutString
        self.visibleLayoutString = visibleLayoutString
        self.parsedLayout = parsedLayout
        self.parsedVisibleLayout = parsedVisibleLayout
        if paneIDs.isEmpty, let ids = parsedLayout?.paneIDs {
            self.paneIDs = ids
        }
        self.cols = cols
        self.rows = rows
    }

    /// Apply a fresh layout string. Updates parsed layouts and synchronises
    /// `paneIDs` with the panes the layout declares.
    func updateLayout(_ layoutString: String, visibleLayoutString: String? = nil) {
        self.layoutString = layoutString
        self.visibleLayoutString = visibleLayoutString
        self.parsedLayout = TmuxLayoutParser.parse(layoutString)
        self.parsedVisibleLayout = visibleLayoutString.flatMap(TmuxLayoutParser.parse)

        // The non-visible layout is authoritative for pane membership. During
        // zoom tmux's visible layout contains only one pane and must never
        // delete the other known panes.
        if let ids = parsedLayout?.paneIDs {
            self.paneIDs = ids
        }
        if let frame = displayLayout?.frame {
            self.cols = frame.cols
            self.rows = frame.rows
        }
    }

    var displayLayout: TmuxLayout? {
        parsedVisibleLayout ?? parsedLayout
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

    /// Fine-grained pause state. Bind UI to this, not to `isPaused`.
    var activity: TmuxPaneActivity

    /// True whenever tmux is not delivering this pane's output, for whatever
    /// reason. Convenience only — `.recovering` resolves itself, so anything
    /// user-facing should test `activity == .stalled`.
    var isPaused: Bool { activity != .running }

    /// Duration of the most recent pause, set when the pane resumes. The screen
    /// is repainted on resume but the scrollback keeps a hole, so the UI uses
    /// this to offer a full history reload. Cleared once acted on.
    var lastPauseGap: TimeInterval?

    /// True while a user-requested full history rebuild is queued or running.
    /// The gap banner uses this to prevent duplicate Load actions.
    var isReloadingHistory = false

    /// Set by the per-pane terminal view's coordinator when alive.
    /// Keep `@ObservationIgnored` so view updates don't churn just because
    /// the sink got rebound.
    @ObservationIgnored
    var feedSink: (@MainActor (Data) -> Void)?

    @ObservationIgnored
    private var feedSinkToken: UUID?

    /// Whether this pane has ever been presented by a live Ghostty surface.
    ///
    /// A Ghostty surface is destructive on detach: a later attach creates an
    /// empty terminal core. Keep this on the pane rather than the SwiftUI
    /// coordinator so a replacement coordinator can still recognize that it
    /// must ask tmux for a fresh authoritative snapshot.
    @ObservationIgnored
    private var hasAttachedTerminalSurface = false

    private enum PendingSegmentKind {
        case snapshot(TmuxPaneRenderMode)
        case live
    }

    private struct PendingSegment {
        let kind: PendingSegmentKind
        var data: Data
    }

    /// Ordered snapshots and live bytes received before `feedSink` was wired.
    /// Snapshots are authoritative and uncapped; only live bytes are bounded.
    @ObservationIgnored
    private var pendingSegments: [PendingSegment] = []

    @ObservationIgnored
    private var pendingLiveByteCount = 0

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
        self.activity = .running
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
            deliveredDisplayBytes: deliverLive(result.data),
            didStartNestedControlMode: result.didStartControlMode
        )
    }

    /// Replay a controller-generated snapshot without mutating the live output
    /// suppressor. A fresh suppressor still removes nested DCS bytes embedded
    /// in pending output captured with the snapshot.
    @discardableResult
    func feedSnapshot(_ data: Data, mode: TmuxPaneRenderMode) -> Bool {
        var snapshotSuppressor = TmuxControlModeOutputSuppressor()
        return deliverSnapshot(snapshotSuppressor.filter(data), mode: mode)
    }

    private func deliverLive(_ filteredData: Data) -> Bool {
        guard !filteredData.isEmpty else { return false }
        if let sink = feedSink {
            sink(filteredData)
        } else {
            appendPendingLive(filteredData)
            trimPendingLiveBytesIfNeeded()
        }
        return true
    }

    private func deliverSnapshot(_ filteredData: Data, mode: TmuxPaneRenderMode) -> Bool {
        if let sink = feedSink {
            guard !filteredData.isEmpty else { return false }
            sink(filteredData)
            return true
        }

        if mode == .freshAttach {
            // A full render is authoritative: anything queued before it is
            // stale and must not be replayed onto the fresh terminal surface.
            pendingSegments.removeAll(keepingCapacity: true)
            pendingLiveByteCount = 0
        }

        guard !filteredData.isEmpty else { return false }
        pendingSegments.append(
            PendingSegment(kind: .snapshot(mode), data: filteredData)
        )
        return true
    }

    private func appendPendingLive(_ data: Data) {
        if case .live = pendingSegments.last?.kind {
            pendingSegments[pendingSegments.count - 1].data.append(data)
        } else {
            pendingSegments.append(PendingSegment(kind: .live, data: data))
        }
        pendingLiveByteCount += data.count
    }

    /// Bound only the live-output portion of the pre-sink buffer.
    ///
    /// A pane with no live view still receives every byte tmux sends it, and on
    /// iOS an unbounded buffer is an OOM: a window whose layout fails to parse,
    /// or a pane in a window the user never opens, can accumulate live output
    /// for the life of the connection. Snapshot segments remain complete because
    /// they are the authoritative terminal base.
    private func trimPendingLiveBytesIfNeeded() {
        while pendingLiveByteCount > Self.maxPendingBytes,
              let segmentIndex = pendingSegments.firstIndex(where: {
                  if case .live = $0.kind { return true }
                  return false
              }) {
            let overflow = pendingLiveByteCount - Self.maxPendingBytes
            let segmentCount = pendingSegments[segmentIndex].data.count

            if segmentCount <= overflow {
                pendingLiveByteCount -= segmentCount
                pendingSegments.remove(at: segmentIndex)
                continue
            }

            let segment = pendingSegments[segmentIndex].data
            var cutIndex = segment.startIndex + overflow
            // Prefer cutting just after a newline so we drop whole lines rather
            // than slicing an escape sequence in half. Only scan a bounded
            // window and never cross into a snapshot segment.
            let scanLimit = min(cutIndex + Self.trimNewlineScanWindow, segment.endIndex)
            if let newline = segment[cutIndex..<scanLimit].firstIndex(of: 0x0A) {
                cutIndex = newline + 1
            }
            pendingLiveByteCount -= cutIndex - segment.startIndex
            pendingSegments[segmentIndex].data = Data(segment[cutIndex...])
        }
    }

    /// Tail of pre-sink output retained per pane (a screenful is a few KB).
    private static let maxPendingBytes = 512 * 1024
    private static let trimNewlineScanWindow = 8 * 1024

    /// Wire a sink. Replays any pending bytes once, then keeps the sink for
    /// future feeds.
    @discardableResult
    func setSink(_ sink: @escaping @MainActor (Data) -> Void) -> UUID {
        let token = UUID()
        feedSinkToken = token
        feedSink = sink
        for segment in pendingSegments where !segment.data.isEmpty {
            sink(segment.data)
        }
        pendingSegments.removeAll()
        pendingLiveByteCount = 0
        return token
    }

    /// Detach the sink if it still belongs to the caller. Subsequent feeds
    /// buffer until a new sink lands.
    func clearSink(_ token: UUID?) {
        guard let token, feedSinkToken == token else { return }
        feedSinkToken = nil
        feedSink = nil
    }

    /// Record a terminal-surface attachment and return whether it replaces an
    /// earlier surface whose local terminal buffer no longer exists.
    func registerTerminalSurfaceAttachment() -> Bool {
        let isReplacement = hasAttachedTerminalSurface
        hasAttachedTerminalSurface = true
        return isReplacement
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
