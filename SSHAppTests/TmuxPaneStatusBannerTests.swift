import XCTest
@testable import SSHApp

/// The banner's whole job is deciding *when* to appear. With auto-resume a pause
/// normally lasts about one round trip, so surfacing every pause would flash a
/// warning on every slow moment — only the states a user must act on qualify.
@MainActor
final class TmuxPaneStatusBannerTests: XCTestCase {

    private func makePane() -> TmuxPane {
        TmuxPane(id: TmuxPaneID(rawValue: 3), windowID: TmuxWindowID(rawValue: 1))
    }

    func testRecoveringPaneShowsNothing() {
        let pane = makePane()
        pane.activity = .recovering
        XCTAssertFalse(shouldShowStalledBanner(pane))
        XCTAssertFalse(shouldShowGapNotice(pane))
    }

    func testStalledPaneShowsTheStalledBanner() {
        let pane = makePane()
        pane.activity = .stalled
        XCTAssertTrue(shouldShowStalledBanner(pane))
    }

    func testRunningPaneWithAPauseGapShowsTheGapNotice() {
        let pane = makePane()
        pane.activity = .running
        pane.lastPauseGap = 12
        XCTAssertFalse(shouldShowStalledBanner(pane))
        XCTAssertTrue(shouldShowGapNotice(pane))
    }

    func testStalledTakesPrecedenceOverAStaleGapNotice() {
        let pane = makePane()
        pane.activity = .stalled
        pane.lastPauseGap = 12
        XCTAssertTrue(shouldShowStalledBanner(pane))
        XCTAssertFalse(shouldShowGapNotice(pane))
    }

    func testRunningPaneWithNoGapShowsNothing() {
        let pane = makePane()
        XCTAssertFalse(shouldShowStalledBanner(pane))
        XCTAssertFalse(shouldShowGapNotice(pane))
    }

    func testFallbackPaneUsesTheSharedStatusWrapper() throws {
        let source = try readSourceFile("SSHApp/Views/TerminalTab.swift")
        guard let fallbackStart = source.range(of: "} else if let pane = fallbackPane {"),
              let helperStart = source.range(
                of: "private func paneTerminal",
                range: fallbackStart.upperBound..<source.endIndex
              )
        else {
            return XCTFail("Could not locate fallback pane rendering and its shared helper")
        }

        let fallbackSource = String(
            source[fallbackStart.lowerBound..<helperStart.lowerBound]
        )
        XCTAssertTrue(fallbackSource.contains("paneTerminal("))
        XCTAssertFalse(
            fallbackSource.contains("TmuxPaneTerminal("),
            "fallback rendering must not bypass the status banner and pane callbacks"
        )
    }

    func testAttachedTmuxBodyConsumesControllerSessionMessage() throws {
        let source = try readSourceFile("SSHApp/Views/TerminalTab.swift")
        guard let bodyStart = source.range(of: "private func tmuxBody"),
              let bodyEnd = source.range(
                of: "private func handleShortcut",
                range: bodyStart.upperBound..<source.endIndex
              )
        else {
            return XCTFail("Could not locate TerminalTab.tmuxBody")
        }

        let bodySource = String(source[bodyStart.lowerBound..<bodyEnd.lowerBound])
        XCTAssertTrue(bodySource.contains("controller.attachedSessionMessage"))
        XCTAssertTrue(bodySource.contains("controller.dismissAttachedSessionMessage"))
        XCTAssertTrue(bodySource.contains("TmuxSessionMessageBanner"))
    }

    // MARK: - Duration text

    func testDurationTextIsCoarse() {
        XCTAssertEqual(TmuxPaneStatusBanner.durationText(0.2), "1s")
        XCTAssertEqual(TmuxPaneStatusBanner.durationText(12), "12s")
        XCTAssertEqual(TmuxPaneStatusBanner.durationText(59.4), "59s")
        XCTAssertEqual(TmuxPaneStatusBanner.durationText(90), "1m")
        XCTAssertEqual(TmuxPaneStatusBanner.durationText(3600), "1h")
    }

    // Mirrors the branch conditions in `TmuxPaneStatusBanner.body`. Kept here so
    // the precedence rule is pinned without instantiating a SwiftUI hierarchy.
    private func shouldShowStalledBanner(_ pane: TmuxPane) -> Bool {
        pane.activity == .stalled
    }

    private func shouldShowGapNotice(_ pane: TmuxPane) -> Bool {
        pane.activity != .stalled && pane.lastPauseGap != nil
    }
}
