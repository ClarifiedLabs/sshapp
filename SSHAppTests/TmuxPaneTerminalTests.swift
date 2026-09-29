import XCTest
import UIKit
@testable import GhosttyTerminal
@testable import GhosttyVT
@testable import SSHApp

/// Regression tests for tmux terminal view behavior: pane mounting, focus, output
/// delivery, window shortcuts, and split-divider hit testing.
final class TmuxPaneTerminalTests: XCTestCase {
    /// tmux windows must remain mounted when switching window tabs so hidden
    /// panes keep their terminal surface buffers (each ghostty surface holds its
    /// own scrollback).
    func testTmuxWindowsStayMountedAcrossWindowSwitches() throws {
        let source = try readSourceFile("SSHApp/Views/TerminalTab.swift")

        XCTAssertTrue(
            source.contains("ForEach(controller.windowOrder, id: \\.self)"),
            "TerminalTab must render every tmux window so hidden panes keep their terminal buffers"
        )
        XCTAssertTrue(
            source.contains(".opacity(isActiveWindow ? 1 : 0)"),
            "Inactive tmux windows should be hidden, not removed"
        )
        XCTAssertTrue(
            source.contains(".allowsHitTesting(isActiveWindow)"),
            "Only the active tmux window should receive gestures"
        )
        XCTAssertFalse(
            source.contains(".id(activeWindow.id)"),
            "Changing the active tmux window must not force terminal view remounts"
        )
    }

    /// tmux pane focus must be touch-driven via the terminal view's own focus
    /// reporting, not forced from SwiftUI update passes.
    func testTmuxPaneFocusIsTouchDriven() throws {
        let source = try readSourceFile("SSHApp/Views/TmuxPaneTerminal.swift")
        let makeBody = try extractMethodBody(from: source, methodName: "func makeUIView")
        let updateBody = try extractMethodBody(from: source, methodName: "func updateUIView")
        let forwardBody = try extractMethodBody(from: source, methodName: "func forwardFromTerminal")

        XCTAssertTrue(
            source.contains("TerminalSurfaceFocusDelegate"),
            "TmuxPaneTerminal should track focus via the TerminalSurfaceFocusDelegate (touch-driven)"
        )
        XCTAssertTrue(
            source.contains("terminalDidChangeFocus"),
            "TmuxPaneTerminal must forward focus changes to update the active pane"
        )
        XCTAssertFalse(
            makeBody.contains("becomeFirstResponder()"),
            "TmuxPaneTerminal must not claim first responder while being mounted"
        )
        XCTAssertFalse(
            updateBody.contains("becomeFirstResponder()"),
            "TmuxPaneTerminal must not claim first responder from SwiftUI update passes"
        )
        XCTAssertFalse(
            forwardBody.contains("controller.focusPane"),
            "Terminal-generated replies from hidden tmux panes must not reactivate their old windows"
        )
    }

    /// Regression: a tmux window's active pane must also accept keyboard input
    /// immediately when its ghostty surface attaches. Inactive panes and hidden
    /// windows stay mounted, so the first-responder request must be gated by
    /// the SwiftUI-focused pane state.
    func testTmuxActivePaneClaimsInitialFirstResponderOnSurfaceAttach() throws {
        let source = try readSourceFile("SSHApp/Views/TmuxPaneTerminal.swift")
        let makeBody = try extractMethodBody(from: source, methodName: "func makeUIView")
        let updateBody = try extractMethodBody(from: source, methodName: "func updateUIView")
        let attachBody = try extractMethodBody(from: source, methodName: "func terminalDidAttachSurface")
        let updateFocusBody = try extractMethodBody(from: source, methodName: "func updateFocusedState")
        let requestBody = try extractMethodBody(from: source, methodName: "func requestFirstResponderIfReady")
        let scheduleBody = try extractMethodBody(from: source, methodName: "private func scheduleFirstResponderRequest")
        let attemptBody = try extractMethodBody(from: source, methodName: "private func attemptFirstResponderIfReady")

        XCTAssertTrue(
            source.contains("TerminalSurfaceLifecycleDelegate"),
            "TmuxPaneTerminal must observe surface attach before requesting initial input focus"
        )
        XCTAssertTrue(
            makeBody.contains("coordinator.updateFocusedState(isFocused)"),
            "makeUIView must seed the coordinator with the pane's active focus state"
        )
        XCTAssertTrue(
            updateBody.contains("coordinator.updateFocusedState(isFocused)"),
            "updateUIView must keep the coordinator's active focus state current"
        )
        XCTAssertTrue(
            source.contains("hasRequestedFirstResponderForCurrentFocus"),
            "tmux first-responder claiming must be gated within each active-focus period"
        )
        XCTAssertTrue(
            source.contains("firstResponderRequestScheduled")
                && source.contains("firstResponderRequestGeneration"),
            "tmux first-responder retries must be coalesced while a request is already scheduled"
        )
        XCTAssertTrue(
            attachBody.contains("markSurfaceAttached()"),
            "terminalDidAttachSurface must mark the pane surface attached"
        )
        XCTAssertTrue(
            updateFocusBody.contains("hasRequestedFirstResponderForCurrentFocus = false")
                && updateFocusBody.contains("cancelFirstResponderRetry()"),
            "tmux panes must allow first-responder claiming again after losing active focus and cancel stale retries"
        )
        XCTAssertTrue(
            requestBody.contains("surfaceAttached, isFocused, !hasRequestedFirstResponderForCurrentFocus"),
            "tmux first-responder claiming must be gated to the active pane after surface attach"
        )
        XCTAssertTrue(
            requestBody.contains("scheduleFirstResponderRequest(after: .nanoseconds(0))"),
            "the tmux first-responder request should be deferred until UIKit finishes the attach/update cycle"
        )
        XCTAssertTrue(
            scheduleBody.contains("DispatchQueue.main.asyncAfter")
                && scheduleBody.contains("self.firstResponderRequestGeneration == generation"),
            "tmux first-responder attempts must run asynchronously on the next main-queue turn and ignore stale retries"
        )
        XCTAssertTrue(
            attemptBody.contains("terminalView.isFirstResponder || terminalView.becomeFirstResponder()")
                && attemptBody.contains("hasRequestedFirstResponderForCurrentFocus = true"),
            "the active tmux pane must mark first-responder claiming complete only after UIKit grants focus"
        )
        XCTAssertTrue(
            attemptBody.contains("scheduleFirstResponderRequest(after: .milliseconds(50))"),
            "failed tmux first-responder attempts must retry while the pane remains focused"
        )
    }

    /// Regression: every Ghostty surface starts focused unless the wrapper
    /// explicitly pushes a focus state into it. tmux split panes mount multiple
    /// terminal surfaces at once, so inactive panes must receive the logical
    /// active-pane state before any user touch/blur callback happens.
    func testTmuxPaneFocusSynchronizesGhosttySurfaceFocusBeforeUIKitFocusEvents() throws {
        let paneSource = try readSourceFile("SSHApp/Views/TmuxPaneTerminal.swift")
        let terminalViewSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView.swift"
        )
        let coordinatorSource = try readSourceFile(
            "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Surface/TerminalSurfaceCoordinator.swift"
        )

        let applyBody = try extractMethodBody(from: paneSource, methodName: "func applyAccessory")
        let markAttachedBody = try extractMethodBody(from: paneSource, methodName: "func markSurfaceAttached")
        let updateFocusBody = try extractMethodBody(from: paneSource, methodName: "func updateFocusedState")
        let syncFocusBody = try extractMethodBody(from: paneSource, methodName: "private func syncTerminalSurfaceFocus")
        let publicFocusBody = try extractMethodBody(from: terminalViewSource, methodName: "open func setTerminalSurfaceFocused")
        let buildSurfaceBody = try extractMethodBody(from: coordinatorSource, methodName: "private func buildSurfaceIfReady")
        let coordinatorFocusBody = try extractMethodBody(from: coordinatorSource, methodName: "func setFocus(_ focused: Bool")

        XCTAssertTrue(
            applyBody.contains("syncTerminalSurfaceFocus()"),
            "tmux panes must seed Ghostty surface focus as soon as the terminal view is available"
        )
        XCTAssertTrue(
            markAttachedBody.contains("syncTerminalSurfaceFocus()"),
            "tmux panes must re-apply focus when Ghostty creates a new surface"
        )
        XCTAssertTrue(
            updateFocusBody.contains("syncTerminalSurfaceFocus()"),
            "tmux panes must update Ghostty surface focus when the active pane changes"
        )
        XCTAssertTrue(
            syncFocusBody.contains("terminalView?.setTerminalSurfaceFocused(isHostVisible && isFocused)"),
            "tmux pane focus sync must drive Ghostty's surface focus from the logical active-pane state"
        )
        XCTAssertTrue(
            publicFocusBody.contains("core.setFocus(focused, notifyDelegate: false)"),
            "programmatic surface-focus sync must not synthesize a TerminalSurfaceFocusDelegate event"
        )
        XCTAssertTrue(
            buildSurfaceBody.contains("newSurface.setFocus(isSurfaceFocused)"),
            "new Ghostty surfaces must inherit the wrapper's stored focus state instead of Ghostty's focused default"
        )
        XCTAssertTrue(
            coordinatorFocusBody.contains("notifyDelegate")
                && coordinatorFocusBody.contains("if notifyDelegate"),
            "TerminalSurfaceCoordinator must allow visual focus sync without delegate callbacks"
        )
    }

    /// Regression: tmux can deliver output while SwiftUI is creating or
    /// reattaching the pane surface. The pane sink must queue through the
    /// coordinator instead of synchronously entering Ghostty's receive path,
    /// because Ghostty can block on an internal futex during scene updates.
    func testTmuxPaneOutputUsesNonBlockingSurfaceReadyDeliveryQueue() throws {
        let source = try readSourceFile("SSHApp/Views/TmuxPaneTerminal.swift")
        let makeBody = try extractMethodBody(from: source, methodName: "func makeUIView")
        let updateBody = try extractMethodBody(from: source, methodName: "func updateUIView")
        let attachBody = try extractMethodBody(from: source, methodName: "func terminalDidAttachSurface")
        let markAttachedBody = try extractMethodBody(from: source, methodName: "func markSurfaceAttached")
        let markDetachedBody = try extractMethodBody(from: source, methodName: "func markSurfaceDetached")
        let viewportReadyBody = try extractMethodBody(from: source, methodName: "private func viewportDidSettle")
        let bindBody = try extractMethodBody(
            from: source,
            methodName: "private func bindPaneSinkIfCurrent"
        )
        let bindAndOpenBody = try extractMethodBody(
            from: source,
            methodName: "private func bindPaneSinkAndOpenOutputIfCurrent"
        )
        let receiveBody = try extractMethodBody(from: source, methodName: "func receiveFromPane")
        let replaceBody = try extractMethodBody(from: source, methodName: "func replacePane")
        let dismantleBody = try extractMethodBody(from: source, methodName: "static func dismantleUIView")

        XCTAssertFalse(
            makeBody.contains("pane.setSink"),
            "makeUIView must leave the authoritative snapshot on TmuxPane until Ghostty attaches a real surface"
        )
        XCTAssertTrue(
            updateBody.contains("coordinator.replacePane(pane)"),
            "pane reuse must pass through the surface-aware replacement path"
        )
        XCTAssertTrue(
            source.contains("private var outputDelivery = TerminalOutputDeliveryQueue()"),
            "TmuxPaneTerminal must own the shared queue for ordered non-blocking pane output delivery"
        )
        XCTAssertTrue(
            receiveBody.contains("outputDelivery.enqueue(data)")
                && !receiveBody.contains("terminalSession.receive(data)"),
            "receiveFromPane must not synchronously enter VTTerminalSession.receive(_:)"
        )
        XCTAssertTrue(
            attachBody.contains("markSurfaceAttached()")
                && markAttachedBody.contains("setOutputReady(false, owner: self)")
                && markAttachedBody.contains("registerTerminalSurfaceAttachment()")
                && markAttachedBody.contains("beginViewportSettle"),
            "raw attachment must record the pane but keep output gated until viewport readiness"
        )
        XCTAssertTrue(
            viewportReadyBody.contains("restoreAndBindPane")
                && viewportReadyBody.contains("bindPaneSinkAndOpenOutputIfCurrent")
                && bindAndOpenBody.contains("setOutputReady(true, owner: self"),
            "only settled viewport generations may restore/bind a pane and release snapshot/live output"
        )
        XCTAssertTrue(
            bindBody.contains("pane.installSemanticSink")
                && bindBody.contains("terminalLifetime?.ownsHost(self)"),
            "only the current host may install the model-owned semantic sink"
        )
        XCTAssertTrue(
            markDetachedBody.contains("viewportReadiness.invalidate()")
                && markDetachedBody.contains("clearPaneSink()")
                && markDetachedBody.contains("setOutputReady(false, owner: self)")
                && !markDetachedBody.contains("outputDelivery.resetPendingOutput()"),
            "terminalDidDetachSurface drops host readiness without pausing model ingestion"
        )
        XCTAssertTrue(
            replaceBody.contains("surfaceBindingGeneration += 1")
                && replaceBody.contains("clearPaneSink()")
                && replaceBody.contains("beginViewportSettle"),
            "pane reuse must invalidate stale settle work before requesting an authoritative replacement snapshot"
        )
        XCTAssertTrue(
            dismantleBody.contains("coordinator.prepareForDismantle()"),
            "view dismantling must synchronously detach host callbacks even if the native detach callback arrives later"
        )
        XCTAssertTrue(
            dismantleBody.contains("uiView.controller = nil"),
            "view dismantling must begin native retirement while the platform view is still alive"
        )
        XCTAssertFalse(
            makeBody.contains("imSession?.receive(data)"),
            "makeUIView must not feed initial tmux output directly into an unattached VTTerminalSession"
        )
    }

    func testTmuxWindowShortcutsAreScopedToActivePane() throws {
        let tabSource = try readSourceFile("SSHApp/Views/TerminalTab.swift")
        let paneSource = try readSourceFile("SSHApp/Views/TmuxPaneTerminal.swift")

        XCTAssertTrue(
            tabSource.contains("isHostTabActive && isActiveWindow"),
            "tmux panes should only be focused when both host tab and tmux window are active"
        )
        XCTAssertTrue(
            tabSource.contains("Task { await controller.selectPreviousWindow() }"),
            "TerminalTab must route previous tmux-window shortcuts to the controller"
        )
        XCTAssertTrue(
            tabSource.contains("Task { await controller.selectNextWindow() }"),
            "TerminalTab must route next tmux-window shortcuts to the controller"
        )
        XCTAssertTrue(
            tabSource.contains("Task { await controller.selectWindow(shortcutDigit: digit) }"),
            "TerminalTab must route numeric tmux-window shortcuts to the controller"
        )
        XCTAssertTrue(
            paneSource.contains("isFocused ? [.hostTabs, .tmuxWindows] : []"),
            "tmux window shortcuts must only be enabled on the focused tmux pane"
        )
        XCTAssertTrue(
            tabSource.contains("controller.activeWindowID == window.id")
                && tabSource.contains("pane.windowID == window.id"),
            "stale focus callbacks from hidden tmux windows must not reactivate their old panes"
        )
        XCTAssertTrue(
            paneSource.contains("terminalView.prefersTmuxWindowNumberShortcuts = isFocused"),
            "focused tmux panes must route command-number shortcuts to tmux windows"
        )
        XCTAssertTrue(
            paneSource.contains("terminalView?.resignFirstResponderForApplicationAction()"),
            "tmux panes must mark app-driven resignation when losing active focus"
        )
    }

    /// Split divider hit strips use one active-window overlay. Floating panes
    /// must render above it so a real tiled divider cannot paint across or
    /// intercept touches inside an overlapping tmux 3.7 floating pane.
    func testTmuxSplitDividerHitTestingKeepsFloatingPanesAboveResizeOverlay() throws {
        let source = try readSourceFile("SSHApp/Views/TerminalTab.swift")
        guard let visualStart = source.range(of: "private struct TmuxSplitDividerView"),
              let visualEnd = source[visualStart.lowerBound...].range(of: "/// View shown when not connected")
        else {
            XCTFail("Could not find TmuxSplitDividerView")
            return
        }

        let dividerSource = String(source[visualStart.lowerBound..<visualEnd.lowerBound])
        XCTAssertTrue(
            source.contains("private let tmuxSplitDividerHitThickness: CGFloat = 64"),
            "Divider hit strip should be large enough for direct touch resizing"
        )
        XCTAssertTrue(
            source.contains("TmuxSplitDividerOverlay("),
            "Divider hit strips should be mounted from the active window"
        )
        XCTAssertTrue(
            source.contains(".zIndex(10_000)"),
            "The divider overlay must render above tiled terminal UIViews"
        )
        XCTAssertTrue(
            source.contains("let floatingPaneIDs = Set(layout.floatingPanePlacements.map(\\.id))")
                && source.contains("ForEach(Array(layout.panePlacements.enumerated())")
                && source.contains("? 20_000 + Double(indexedPlacement.offset)"),
            "Floating panes must have explicit render-rank z-indices above the tiled divider overlay"
        )
        XCTAssertTrue(
            dividerSource.contains(".allowsHitTesting(false)"),
            "Visible divider lines should not compete with the UIKit interaction overlay"
        )
        XCTAssertTrue(
            source.contains("TmuxSplitDividerInteractionOverlay("),
            "A single active-window UIKit interaction overlay should own divider drags"
        )
        XCTAssertTrue(
            source.contains("UIPanGestureRecognizer("),
            "The top-level interaction overlay should use UIKit pan recognition"
        )
        XCTAssertTrue(
            source.contains("override func point(inside point: CGPoint, with event: UIEvent?) -> Bool"),
            "The full-window UIKit overlay must only hit-test divider strips"
        )
        XCTAssertTrue(
            source.contains("dividerHit(at: point) != nil"),
            "The full-window UIKit overlay must pass through touches outside divider hit rects"
        )
        XCTAssertTrue(
            source.contains("func gestureRecognizerShouldBegin"),
            "The pan recognizer should only begin for touches inside a divider hit rect"
        )
        XCTAssertTrue(
            source.contains("dispatchResizeIfNeeded(divider: divider, targetSize: targetSize, reason: \"changed\")"),
            "Resize must dispatch during movement so a cancelled end event cannot lose the resize"
        )
        XCTAssertTrue(
            source.contains("resize drag cancelled"),
            "Cancelled UIKit pans should be logged and reset explicitly"
        )
        XCTAssertTrue(
            dividerSource.contains(".frame(width: max(size.width, 1), height: max(size.height, 1), alignment: .topLeading)"),
            "Each divider should keep the older full-window wrapper shape that worked before shared pane borders"
        )
        XCTAssertTrue(
            dividerSource.contains("tmuxAdjustedHitRect("),
            "Divider hit testing should use adjusted non-overlapping hit rectangles"
        )
        XCTAssertTrue(
            source.contains("neighboringMids"),
            "Adjacent divider lines should constrain each other's hit strips"
        )
        XCTAssertTrue(
            source.contains("(previousMid + currentMid) / 2"),
            "A divider hit strip should stop at the midpoint to the previous neighboring divider"
        )
        XCTAssertTrue(
            source.contains("(currentMid + nextMid) / 2"),
            "A divider hit strip should stop at the midpoint to the next neighboring divider"
        )
        XCTAssertFalse(
            source.contains("TmuxSplitDividerHitOverlay"),
            "The dead full-window UIKit hit router should not be mounted"
        )
        XCTAssertFalse(
            source.contains("TmuxSplitDividerPanStrip"),
            "The dead per-strip UIKit pan recognizer should not be mounted"
        )
    }

    // MARK: - Recreated-surface restore fail-open

    /// Regression: when no authoritative snapshot can be captured for a
    /// recreated surface, restoration fails open — live output is bound and
    /// opened instead of gating the pane behind a degraded tmux link.
    @MainActor
    func testRecreatedSurfaceRestoreFailsOpenWhenSnapshotUnavailable() async throws {
        let pane = TmuxPane(
            id: TmuxPaneID(rawValue: 7),
            windowID: TmuxWindowID(rawValue: 1),
            cols: 80,
            rows: 24
        )
        let coordinator = TmuxPaneTerminal.Coordinator()
        coordinator.pane = pane
        coordinator.restorePaneForRecreatedSurfaceOverride = { _ in false }

        // A stale completion from an older binding generation must not bind
        // the sink.
        coordinator.finishPaneRestore(bindingGeneration: 0, pane: pane, restored: true)
        XCTAssertNil(coordinator.sinkToken)

        // Only replacing the logical VT session requires a fresh snapshot.
        coordinator.markSurfaceAttached()
        coordinator.prepareForDismantle()
        pane.finishTerminalSession()
        coordinator.markSurfaceAttached()

        try await waitUntil("fail-open binds the pane sink") {
            coordinator.sinkToken != nil
        }
        XCTAssertNotNil(
            coordinator.sinkToken,
            "a failed authoritative restore must still bind live output (fail open)"
        )
    }

    /// The injected restore pipeline is consulted exactly once per recreated
    /// surface and its success result still binds the sink.
    @MainActor
    func testRecreatedSurfaceRestoreConsultsPipelineOnceBeforeBinding() async throws {
        let pane = TmuxPane(
            id: TmuxPaneID(rawValue: 8),
            windowID: TmuxWindowID(rawValue: 1),
            cols: 80,
            rows: 24
        )
        let coordinator = TmuxPaneTerminal.Coordinator()
        coordinator.pane = pane
        var restoreCalls = 0
        coordinator.restorePaneForRecreatedSurfaceOverride = { _ in
            restoreCalls += 1
            return true
        }

        coordinator.markSurfaceAttached()
        coordinator.prepareForDismantle()
        pane.finishTerminalSession()
        coordinator.markSurfaceAttached()

        try await waitUntil("successful restore binds the pane sink") {
            coordinator.sinkToken != nil
        }
        XCTAssertEqual(restoreCalls, 1)
        XCTAssertNotNil(coordinator.sinkToken)
    }

    @MainActor
    func testRetainedVTSessionSurvivesHostRecreationWithoutSnapshotReplay() async throws {
        let pane = TmuxPane(id: .init(rawValue: 9), windowID: .init(rawValue: 1))
        let first = TmuxPaneTerminal.Coordinator()
        first.pane = pane
        first.bindTerminalSession()
        let session = try XCTUnwrap(first.terminalSession)
        session.updateViewport(.init(width: 390, height: 480, cellWidth: 10, cellHeight: 20, scale: 2))
        session.receive(Data("retained".utf8))
        first.markSurfaceAttached()
        try await waitUntil("first sink") { first.sinkToken != nil }
        first.markSurfaceDetached()
        first.receiveFromPane(Data("-queued".utf8))
        first.prepareForDismantle()
        pane.feed(Data("-backlog".utf8))

        let replacement = TmuxPaneTerminal.Coordinator()
        replacement.pane = pane
        var restores = 0
        replacement.restorePaneForRecreatedSurfaceOverride = { _ in
            restores += 1
            return true
        }
        replacement.markSurfaceAttached()
        XCTAssertTrue(replacement.terminalSession === session)
        try await waitUntil("replacement sink") { replacement.sinkToken != nil }
        let deadline = Date().addingTimeInterval(2)
        var frame = try await session.snapshot()
        while !frame.line(0).hasPrefix("retained-queued-backlog"), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
            frame = try await session.snapshot()
        }
        XCTAssertTrue(frame.line(0).hasPrefix("retained-queued-backlog"))
        XCTAssertEqual(restores, 0, "A UIKit/Metal host is not a new logical terminal")
        replacement.prepareForDismantle()
        pane.finishTerminalSession()
        XCTAssertNil(session.enqueueSelectedText())
    }

    @MainActor
    func testEmptyRetainedPaneQueueSatisfiesRemountBarrierWithoutSnapshotReplay() async throws {
        let pane = TmuxPane(id: .init(rawValue: 11), windowID: .init(rawValue: 1), cols: 80, rows: 24)
        pane.feedSnapshot(Data("prompt".utf8), mode: .freshAttach)
        let first = TmuxPaneTerminal.Coordinator()
        first.pane = pane
        first.bindTerminalSession()
        let lifetime = try XCTUnwrap(pane.terminalLifetime)
        defer { pane.finishTerminalSession() }
        lifetime.session.updateViewport(.init(width: 390, height: 480, cellWidth: 10, cellHeight: 20, scale: 2))
        first.markSurfaceAttached()
        try await waitUntil("first sink") { first.sinkToken != nil }
        let firstCommit = expectation(description: "snapshot committed")
        lifetime.outputDelivery.notifyWhenDrained { firstCommit.fulfill() }
        await fulfillment(of: [firstCommit], timeout: 2)
        first.prepareForDismantle()

        pane.feed(Data("-detached".utf8))
        let detachedCommit = expectation(description: "detached pane output committed")
        lifetime.outputDelivery.notifyWhenDrained { detachedCommit.fulfill() }
        await fulfillment(of: [detachedCommit], timeout: 2)

        let replacement = TmuxPaneTerminal.Coordinator()
        replacement.pane = pane
        replacement.restorePaneForRecreatedSurfaceOverride = { _ in
            XCTFail("A host remount must not replay an authoritative snapshot")
            return false
        }
        defer { replacement.prepareForDismantle() }
        replacement.markSurfaceAttached()
        try await waitUntil("replacement sink") { replacement.sinkToken != nil }
        let remount = expectation(description: "empty remount barrier")
        lifetime.setOutputReady(true, owner: replacement, onDrain: { remount.fulfill() })
        await fulfillment(of: [remount], timeout: 2)
        let frame = try await lifetime.session.snapshot()
        XCTAssertEqual(frame.line(0).trimmingCharacters(in: .whitespaces), "prompt-detached")
    }

    func testPaneReadinessUsesDrainBarrierAndKeepsNativeRenderFence() throws {
        let source = try readSourceFile("SSHApp/Views/TmuxPaneTerminal.swift")
        let bind = try extractMethodBody(from: source, methodName: "private func bindPaneSinkAndOpenOutputIfCurrent")
        let draw = try extractMethodBody(from: source, methodName: "private func requestPostFlushDraw")
        XCTAssertTrue(bind.contains("setOutputReady(true, owner: self, onDrain:"))
        XCTAssertFalse(bind.contains("onFirstDrain:"), "An already committed prompt needs no new bytes")
        XCTAssertTrue(draw.contains("terminalLifetime?.ownsHost(self) == true"))
        XCTAssertTrue(draw.contains("requestImmediateDraw(onPostRender:"))
        XCTAssertTrue(draw.contains("viewportReadiness.generation == readinessGeneration"))
    }

    @MainActor
    func testPreSinkGapReadinessDrawsExactlyOnceAfterSnapshotRecovery() async throws {
        try await exercisePendingGapReadiness(overflowBeforeSink: true)
    }

    @MainActor
    func testDeliveryQueueGapReadinessDrawsExactlyOnceAfterSnapshotRecovery() async throws {
        try await exercisePendingGapReadiness(overflowBeforeSink: false)
    }

    @MainActor
    func testRecoveryNotifiesReplacementHostDespiteStaleDetach() async throws {
        try await exercisePendingGapReadiness(overflowBeforeSink: false, replaceHost: true)
    }

    @MainActor
    private func exercisePendingGapReadiness(overflowBeforeSink: Bool, replaceHost: Bool = false) async throws {
        let pane = TmuxPane(id: .init(rawValue: 12), windowID: .init(rawValue: 1))
        let coordinator = TmuxPaneTerminal.Coordinator()
        coordinator.pane = pane
        coordinator.bindTerminalSession()
        let lifetime = try XCTUnwrap(pane.terminalLifetime)
        lifetime.session.updateViewport(.init(width: 390, height: 480, cellWidth: 10, cellHeight: 20, scale: 2))
        _ = try await lifetime.session.snapshot()
        var finishRestore: CheckedContinuation<Bool, Never>?
        let restoreStarted = expectation(description: "authoritative restore requested")
        let restore: (TmuxPaneID) async -> Bool = { _ in
            await withCheckedContinuation {
                finishRestore = $0
                restoreStarted.fulfill()
            }
        }
        coordinator.restorePaneForRecreatedSurfaceOverride = restore
        var replacement: TmuxPaneTerminal.Coordinator?
        defer {
            finishRestore?.resume(returning: false)
            coordinator.prepareForDismantle()
            replacement?.prepareForDismantle()
            pane.finishTerminalSession()
        }
        if !overflowBeforeSink {
            // Install model ingestion while output is still gated. The actual
            // bridge readiness below must replace its current-host callback.
            pane.installSemanticSink { await restore(pane.id) }
        }
        coordinator.markSurfaceAttached()
        pane.feed(Data("\u{1b}[?1049h".utf8) + Data(repeating: 120, count: 600_000))
        XCTAssertTrue(pane.requiresOutputRecovery)
        XCTAssertEqual(lifetime.outputDelivery.requiresSnapshotRecovery, !overflowBeforeSink)

        let earlyDraw = expectation(description: "no draw before authoritative snapshot")
        earlyDraw.isInverted = true
        let recoveredDraw = expectation(description: "bridge post-flush after recovered snapshot")
        recoveredDraw.assertForOverFulfill = true
        var snapshotEnqueued = false
        var renderRequests = 0
        var postFlushCount = 0
        coordinator.requestImmediateDrawOverride = { completion in
            renderRequests += 1
            XCTAssertTrue(snapshotEnqueued, "An empty pre-sink queue is not recovered content")
            XCTAssertFalse(pane.requiresOutputRecovery)
            completion()
        }
        coordinator.onPostFlushDraw = {
            postFlushCount += 1
            if snapshotEnqueued { recoveredDraw.fulfill() }
            else { earlyDraw.fulfill() }
        }
        await fulfillment(of: [restoreStarted], timeout: 2)
        try await waitUntil("actual viewport readiness installs host sink") { coordinator.sinkToken != nil }
        if replaceHost {
            let next = TmuxPaneTerminal.Coordinator()
            next.pane = pane
            next.restorePaneForRecreatedSurfaceOverride = restore
            next.requestImmediateDrawOverride = coordinator.requestImmediateDrawOverride
            next.onPostFlushDraw = coordinator.onPostFlushDraw
            coordinator.onPostFlushDraw = { XCTFail("Retired host received recovery readiness") }
            coordinator.requestImmediateDrawOverride = { _ in XCTFail("Retired host requested a recovery draw") }
            replacement = next
            next.markSurfaceAttached()
            try await waitUntil("replacement installs its recovery callback") { next.sinkToken != nil }
            // Delayed teardown of the old host must not erase the new callback.
            coordinator.prepareForDismantle()
            XCTAssertTrue(lifetime.ownsHost(next))
        }
        // Observe the real bridge callback while restoration is suspended,
        // rather than manufacturing a second drain callback in the test.
        await fulfillment(of: [earlyDraw], timeout: 0.1)
        XCTAssertEqual(renderRequests, 0)
        XCTAssertEqual(postFlushCount, 0)
        pane.feed(Data("must-not-leak".utf8))
        let before = try await lifetime.session.snapshot()
        XCTAssertTrue(before.line(0).trimmingCharacters(in: .whitespaces).isEmpty)

        snapshotEnqueued = true
        XCTAssertTrue(pane.feedSnapshot(Data("\u{1b}[?1049l\u{1b}crecovered".utf8), mode: .freshAttach))
        let completion = try XCTUnwrap(finishRestore)
        finishRestore = nil
        completion.resume(returning: true)
        await fulfillment(of: [recoveredDraw], timeout: 2)
        let frame = try await lifetime.session.snapshot()
        XCTAssertTrue(frame.line(0).hasPrefix("recovered"))
        XCTAssertEqual(renderRequests, 1)
        XCTAssertEqual(postFlushCount, 1)
        XCTAssertFalse(pane.requiresOutputRecovery)

        // Normal snapshots and live output must not emit another recovery event.
        pane.feedSnapshot(Data("!".utf8), mode: .repaintVisible)
        let settled = expectation(description: "subsequent output committed")
        lifetime.outputDelivery.notifyWhenDrained { settled.fulfill() }
        await fulfillment(of: [settled], timeout: 2)
        XCTAssertEqual(renderRequests, 1)
        XCTAssertEqual(postFlushCount, 1)
    }

    @MainActor
    func testReusedPaneIDDoesNotReuseAnotherLogicalTerminal() throws {
        let originalPane = TmuxPane(id: .init(rawValue: 7), windowID: .init(rawValue: 1))
        let replacementPane = TmuxPane(id: .init(rawValue: 7), windowID: .init(rawValue: 1))
        let coordinator = TmuxPaneTerminal.Coordinator()
        coordinator.pane = originalPane
        coordinator.bindTerminalSession()
        let originalSession = try XCTUnwrap(coordinator.terminalSession)
        coordinator.replacePane(replacementPane)
        XCTAssertTrue(coordinator.pane === replacementPane)
        XCTAssertFalse(coordinator.terminalSession === originalSession)
        XCTAssertTrue(originalPane.terminalLifetime?.session === originalSession,
                      "Host reuse must not destroy a still-owned pane")
        coordinator.prepareForDismantle()
        originalPane.finishTerminalSession()
        replacementPane.finishTerminalSession()
    }

    @MainActor
    func testOverflowDuringInitialLayoutRestoresBeforeReleasingOutput() async throws {
        let pane = TmuxPane(id: .init(rawValue: 10), windowID: .init(rawValue: 1))
        let coordinator = TmuxPaneTerminal.Coordinator()
        coordinator.pane = pane
        coordinator.bindTerminalSession()
        let lifetime = try XCTUnwrap(pane.terminalLifetime)
        lifetime.session.updateViewport(.init(width: 390, height: 480, cellWidth: 10, cellHeight: 20, scale: 2))
        _ = try await lifetime.session.snapshot()
        defer {
            coordinator.prepareForDismantle()
            pane.finishTerminalSession()
        }
        var finishRestore: CheckedContinuation<Bool, Never>?
        defer { finishRestore?.resume(returning: false) }
        coordinator.restorePaneForRecreatedSurfaceOverride = { _ in
            await withCheckedContinuation { finishRestore = $0 }
        }

        coordinator.markSurfaceAttached()
        XCTAssertEqual(lifetime.requiresPaneRestore, false)
        // No actor suspension: overflow occurs after the cached attach decision
        // but before the real viewport readiness callback installs the sink.
        pane.feed(Data("\u{1b}[?1049h".utf8) + Data(repeating: 120, count: 600_000))
        XCTAssertTrue(pane.needsOutputRecovery)
        try await waitUntil("initial sink requests authoritative recovery") { finishRestore != nil }
        guard let completion = finishRestore else { return }
        pane.feed(Data("must-not-leak".utf8))
        let beforeRestore = try await lifetime.session.snapshot()
        XCTAssertTrue(beforeRestore.line(0).trimmingCharacters(in: .whitespaces).isEmpty,
                      "Neither truncated replay nor live output may enter the engine before recovery")

        pane.feedSnapshot(Data("\u{1b}[?1049l\u{1b}crecovered".utf8), mode: .freshAttach)
        finishRestore = nil
        completion.resume(returning: true)
        try await waitUntil("recovery completes") { pane.activity == .running }
        let drained = expectation(description: "snapshot and subsequent live output commit")
        lifetime.outputDelivery.setReady(true, onFirstDrain: { drained.fulfill() })
        pane.feed(Data("!".utf8))
        await fulfillment(of: [drained], timeout: 2)
        let deadline = Date().addingTimeInterval(2)
        var frame = try await lifetime.session.snapshot()
        while !frame.line(0).hasPrefix("recovered!"), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
            frame = try await lifetime.session.snapshot()
        }
        XCTAssertTrue(frame.line(0).hasPrefix("recovered!"))
        XCTAssertFalse(pane.requiresOutputRecovery)
        XCTAssertNotNil(coordinator.sinkToken)
    }

    func testTmuxHostVisibilityIsExplicitAndIndependentOfPaneFocus() throws {
        let tab = try readSourceFile("SSHApp/Views/TerminalTab.swift")
        let pane = try readSourceFile("SSHApp/Views/TmuxPaneTerminal.swift")
        XCTAssertTrue(tab.contains("isHostVisible: isHostTabActive && isActiveWindow"))
        for method in ["func makeUIView", "func updateUIView"] {
            let body = try extractMethodBody(from: pane, methodName: method)
            let visibility = try XCTUnwrap(body.range(of: "coordinator.updateHostVisibility"))
            let focus = try XCTUnwrap(body.range(of: "coordinator.updateFocusedState"))
            XCTAssertLessThan(visibility.lowerBound, focus.lowerBound)
        }
    }

    @MainActor
    func testRetainedTwoSplitWindowHidesNativeHostsWithoutStoppingSemanticOutput() async throws {
        var scene: UIWindowScene?
        try await waitUntil("active scene") {
            scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
            return scene != nil
        }
        let activeScene = try XCTUnwrap(scene)
        let previousKeyWindow = activeScene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: activeScene)
        let root = UIViewController()
        window.rootViewController = root
        window.frame = activeScene.coordinateSpace.bounds
        let target = TerminalKeyboardBarTarget()
        let panes = (0..<3).map {
            TmuxPane(id: .init(rawValue: $0 + 20), windowID: .init(rawValue: $0 == 2 ? 2 : 1), cols: 80, rows: 24)
        }
        let hosts = panes.map { _ in UITerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 200)) }
        let coordinators = panes.map { _ in TmuxPaneTerminal.Coordinator() }
        defer {
            for index in 0..<3 {
                coordinators[index].prepareForDismantle()
                hosts[index].controller = nil
                panes[index].finishTerminalSession()
            }
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }
        var focusCallbacks = 0
        for index in 0..<3 {
            let coordinator = coordinators[index]
            let host = hosts[index]
            host.frame.origin.y = index == 1 ? 200 : 0
            host.suppressesSoftwareKeyboard = true
            coordinator.pane = panes[index]
            coordinator.updateHostVisibility(index != 2, view: host)
            coordinator.updateKeyboardBarTarget(target)
            coordinator.updateFocusedState(index == 0)
            coordinator.onFocus = { focusCallbacks += 1 }
            coordinator.bindTerminalSession()
            host.delegate = coordinator
            host.controller = TerminalRuntime.shared.controller
            host.configuration = TerminalSurfaceOptions(backend: .vt(try XCTUnwrap(coordinator.terminalSession)))
            coordinator.applyAccessory(to: host, showsBar: false)
            root.view.addSubview(host)
        }
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        try await waitUntil("visible split sinks") { coordinators.prefix(2).allSatisfy { $0.sinkToken != nil } }
        try await waitUntil("initial responder") { hosts[0].isFirstResponder }
        let sessions = try coordinators.map { try XCTUnwrap($0.terminalSession) }
        let contents = try hosts.map { try XCTUnwrap($0.surface?.contentView) }
        try await waitUntil("both split frames") { contents[0].frameValue != nil && contents[1].frameValue != nil }
        XCTAssertTrue(hosts[1].canBecomeFirstResponder, "Visible nonfocused split remains tappable")
        XCTAssertNotNil(hosts[1].hitTest(CGPoint(x: 40, y: 40), with: nil))

        // Queue focus work before hiding; neither it nor a late focus callback
        // may reclaim the shared keyboard target after the switch.
        coordinators[1].updateFocusedState(true)
        #if !targetEnvironment(macCatalyst)
        hosts[0].pendingKeyboardDismissOnTouchEnd = true
        hosts[0].deferredSuppressedInputViewReloadID = 42
        hosts[0].onSystemSoftwareKeyboardDismiss = { XCTFail("Hidden host emitted keyboard dismissal") }
        hosts[0].deferSystemSoftwareKeyboardDismissCallback()
        #endif
        for index in 0..<2 {
            coordinators[index].updateHostVisibility(false, view: hosts[index])
            coordinators[index].updateFocusedState(false)
        }
        #if !targetEnvironment(macCatalyst)
        XCTAssertFalse(hosts[0].pendingKeyboardDismissOnTouchEnd)
        XCTAssertNil(hosts[0].deferredSuppressedInputViewReloadID)
        XCTAssertNil(hosts[0].deferredSystemSoftwareKeyboardDismissID)
        #endif
        coordinators[2].updateHostVisibility(true, view: hosts[2])
        coordinators[2].updateFocusedState(true)
        try await waitUntil("other window responder and sink") {
            hosts[2].isFirstResponder && coordinators[2].sinkToken != nil
        }
        let callbacksBeforeStaleFocus = focusCallbacks
        coordinators[1].terminalDidChangeFocus(true)
        coordinators[1].requestFirstResponderIfReady()
        XCTAssertEqual(focusCallbacks, callbacksBeforeStaleFocus)
        target.restoreSoftwareKeyboard()
        XCTAssertTrue(hosts[1].suppressesSoftwareKeyboard, "Late callback must not steal keyboard target")
        XCTAssertFalse(hosts[2].suppressesSoftwareKeyboard)
        let extractions = contents.prefix(2).map(\.snapshotExtractions)
        var hiddenPublications = 0
        for index in 0..<2 {
            let host = hosts[index]
            XCTAssertTrue(host.isHidden)
            // UIViewRepresentable can clear this root property after updateUIView.
            host.accessibilityElementsHidden = false
            XCTAssertTrue(host.accessibilityElementsHidden)
            host.isAccessibilityElement = true
            XCTAssertFalse(host.isAccessibilityElement, "Hide the UITextInput root, not just its descendants")
            XCTAssertFalse(host.isUserInteractionEnabled)
            XCTAssertFalse(host.canBecomeFirstResponder)
            XCTAssertFalse(host.becomeFirstResponder())
            XCTAssertNil(host.hitTest(CGPoint(x: 40, y: 40), with: nil))
            XCTAssertFalse(contents[index].isPresentationActive)
            XCTAssertNil(contents[index].frameValue)
            contents[index].onFrame = { _ in hiddenPublications += 1 }
            panes[index].feed(Data("hidden-\(index)".utf8))
        }
        for index in 0..<2 {
            let drained = expectation(description: "hidden pane output committed")
            panes[index].terminalLifetime?.outputDelivery.notifyWhenDrained { drained.fulfill() }
            await fulfillment(of: [drained], timeout: 2)
            let frame = try await sessions[index].snapshot()
            XCTAssertTrue(frame.line(0).hasPrefix("hidden-\(index)"))
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(contents.prefix(2).map(\.snapshotExtractions), extractions)
        XCTAssertEqual(hiddenPublications, 0)
        XCTAssertTrue(hosts[2].isFirstResponder)

        coordinators[2].updateHostVisibility(false, view: hosts[2])
        coordinators[2].updateFocusedState(false)
        for index in 0..<2 {
            contents[index].onFrame = nil
            coordinators[index].updateHostVisibility(true, view: hosts[index])
            coordinators[index].updateFocusedState(index == 0)
            XCTAssertTrue(coordinators[index].terminalSession === sessions[index])
            XCTAssertFalse(hosts[index].accessibilityElementsHidden)
            XCTAssertTrue(hosts[index].isAccessibilityElement, "Reveal restores the requested accessibility value")
            hosts[index].isAccessibilityElement = false
            XCTAssertFalse(hosts[index].isAccessibilityElement)
            XCTAssertNotNil(hosts[index].hitTest(CGPoint(x: 40, y: 40), with: nil))
        }
        try await waitUntil("resumed fresh split frames") {
            contents[0].frameValue?.line(0).hasPrefix("hidden-0") == true
                && contents[1].frameValue?.line(0).hasPrefix("hidden-1") == true
        }
        try await waitUntil("restored responder") { hosts[0].isFirstResponder }
    }

    @MainActor
    func testDeferredHostVisibilityRefreshTracksReparentedAncestorAndLatestVisibility() async throws {
        var scene: UIWindowScene?
        try await waitUntil("active scene") {
            scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
            return scene != nil
        }
        let activeScene = try XCTUnwrap(scene)
        let previousKeyWindow = activeScene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: activeScene)
        let root = UIViewController()
        window.rootViewController = root
        window.frame = activeScene.coordinateSpace.bounds
        let bounds = CGRect(x: 0, y: 0, width: 320, height: 200)
        let oldAncestor = UIView(frame: bounds)
        let newAncestor = UIView(frame: bounds)
        let container = UIView(frame: bounds)
        let host = UITerminalView(frame: bounds)
        let session = VTTerminalSession(write: { _ in }, resize: { _ in })
        defer {
            host.controller = nil
            session.finish()
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }
        host.suppressesSoftwareKeyboard = true
        host.controller = TerminalRuntime.shared.controller
        host.configuration = TerminalSurfaceOptions(backend: .vt(session))
        root.view.addSubview(oldAncestor)
        root.view.addSubview(newAncestor)
        oldAncestor.addSubview(container)
        container.addSubview(host)
        newAncestor.alpha = 0
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        let content = try XCTUnwrap(host.surface?.contentView)
        session.receive(Data("retained frame".utf8))
        try await waitUntil("initial host frame") {
            content.frameValue?.line(0).hasPrefix("retained frame") == true
        }

        host.isHostVisible = false
        oldAncestor.alpha = 0
        // Drain the hide refresh so only the reveal can repair the old chain.
        let hidden = expectation(description: "host hide refresh drained")
        DispatchQueue.main.async { hidden.fulfill() }
        await fulfillment(of: [hidden], timeout: 2)
        XCTAssertFalse(content.isPresentationActive)
        XCTAssertNil(content.frameValue)
        let extractions = content.snapshotExtractions

        // Model updateUIView followed synchronously by the ancestor transaction.
        // The host/content themselves never change superview or window.
        host.isHostVisible = true
        XCTAssertFalse(content.isPresentationActive, "The old ancestor is still transparent")
        newAncestor.addSubview(container)
        newAncestor.alpha = 1
        // No output, explicit refresh, draw, or layout may rescue this reveal.
        try await waitUntil("deferred reveal frame") {
            content.isPresentationActive
                && content.frameValue?.line(0).hasPrefix("retained frame") == true
        }
        XCTAssertTrue(host.surface?.contentView === content, "Reveal must retain the VT surface")
        XCTAssertGreaterThan(content.snapshotExtractions, extractions)

        newAncestor.alpha = 0
        XCTAssertFalse(content.isPresentationActive, "The refreshed chain must observe the new ancestor")
        XCTAssertNil(content.frameValue)
        newAncestor.alpha = 1
        try await waitUntil("new ancestor reveal") { content.frameValue != nil }

        var publications = 0
        content.onFrame = { _ in publications += 1 }
        defer { content.onFrame = nil }
        let beforeBurst = content.snapshotExtractions
        host.isHostVisible = false
        host.isHostVisible = true
        host.isHostVisible = false
        let settled = expectation(description: "visibility burst refreshes drained")
        DispatchQueue.main.async { settled.fulfill() }
        await fulfillment(of: [settled], timeout: 2)
        XCTAssertFalse(content.isPresentationActive, "Queued reveals must use the latest hidden state")
        XCTAssertNil(content.frameValue)
        XCTAssertEqual(content.snapshotExtractions, beforeBurst)
        XCTAssertEqual(publications, 0)
    }

    @MainActor
    func testQueuedHostVisibilityRefreshDoesNotRetainHost() {
        weak var released: UITerminalView?
        autoreleasepool {
            let host = UITerminalView(frame: .zero)
            released = host
            host.isHostVisible = false
            host.isHostVisible = true
        }
        XCTAssertNil(released, "The queued visibility refresh must not retain its host before it runs")
    }

    #if !targetEnvironment(macCatalyst)
    @MainActor
    func testTapOnUnfocusedSplitWithGloballyVisibleKeyboardTransfersFirstResponder() async throws {
        try await withMountedTapSplits { top, bottom in
            // Every unsuppressed host observes the global keyboard notification,
            // including the split that does not own the keyboard. Set the flags
            // directly so this does not depend on Simulator keyboard settings.
            top.softwareKeyboardVisible = true
            bottom.softwareKeyboardVisible = true
            XCTAssertTrue(top.isFirstResponder)
            XCTAssertFalse(bottom.isFirstResponder)
            XCTAssertFalse(bottom.suppressesSoftwareKeyboard)
            XCTAssertTrue(bottom.softwareKeyboardVisible)

            try await performEndedTerminalTap(on: bottom)

            XCTAssertTrue(bottom.isFirstResponder,
                "A nonfocused split must focus, not try to dismiss another split's keyboard")
            XCTAssertFalse(top.isFirstResponder, "The previous split must relinquish the responder")
        }
    }

    @MainActor
    func testTapOnFocusedSplitWithVisibleKeyboardStillDismissesFirstResponder() async throws {
        try await withMountedTapSplits { top, bottom in
            top.softwareKeyboardVisible = true
            bottom.softwareKeyboardVisible = true
            XCTAssertTrue(top.isFirstResponder)
            XCTAssertFalse(top.suppressesSoftwareKeyboard)

            try await performEndedTerminalTap(on: top)

            XCTAssertFalse(top.isFirstResponder, "Tapping the keyboard owner still dismisses its keyboard")
            XCTAssertFalse(bottom.isFirstResponder, "Dismissal must not transfer focus to another split")
        }
    }

    @MainActor
    func testSelectionClearingTapOnUnfocusedSplitDoesNotTransferFirstResponder() async throws {
        try await withMountedTapSplits { top, bottom in
            let surface = try XCTUnwrap(bottom.surface)
            surface.session.receive(Data("selected word".utf8))
            try await waitUntil("bottom split text") {
                surface.frameValue?.line(0).hasPrefix("selected word") == true
            }
            let selection = try XCTUnwrap(surface.session.enqueueSelectAll())
            try await selection.value
            try await waitUntil("bottom split native selection") {
                surface.frameValue?.hasSelection == true && bottom.selectionHandlesVisible
            }
            XCTAssertTrue(top.isFirstResponder)
            XCTAssertFalse(bottom.isFirstResponder)
            // Capture the same touch-down intent as the production recognizer.
            bottom.terminalTapBeganWithHostSelection = true
            // With no dismissal intent, an accidental fallthrough would focus
            // bottom even before the split-keyboard regression is fixed.
            top.softwareKeyboardVisible = false
            bottom.softwareKeyboardVisible = false

            try await performEndedTerminalTap(on: bottom)
            try await waitUntil("native selection cleared") { surface.frameValue?.hasSelection == false }

            XCTAssertFalse(bottom.selectionHandlesVisible)
            XCTAssertFalse(bottom.terminalTapBeganWithHostSelection)
            XCTAssertFalse(bottom.isFirstResponder, "A selection-clearing tap must not also take focus")
            XCTAssertTrue(top.isFirstResponder)
        }
    }

    @MainActor
    private func withMountedTapSplits(
        _ body: @MainActor (UITerminalView, UITerminalView) async throws -> Void
    ) async throws {
        var scene: UIWindowScene?
        try await waitUntil("active scene for split tap") {
            scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
            return scene != nil
        }
        let activeScene = try XCTUnwrap(scene)
        let previousKeyWindow = activeScene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: activeScene)
        let root = UIViewController()
        window.rootViewController = root
        window.frame = activeScene.coordinateSpace.bounds
        let panes = (0..<2).map {
            TmuxPane(id: .init(rawValue: $0 + 40), windowID: .init(rawValue: 1), cols: 80, rows: 24)
        }
        let hosts = (0..<2).map {
            UITerminalView(frame: CGRect(x: 0, y: CGFloat($0 * 200), width: 320, height: 200))
        }
        let coordinators = panes.map { _ in TmuxPaneTerminal.Coordinator() }
        defer {
            for index in 0..<2 {
                hosts[index].nativePointer.onDiagnostic = nil
                coordinators[index].prepareForDismantle()
                hosts[index].controller = nil
                panes[index].finishTerminalSession()
            }
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }
        for index in 0..<2 {
            let host = hosts[index]
            let coordinator = coordinators[index]
            host.suppressesSoftwareKeyboard = false
            coordinator.pane = panes[index]
            coordinator.updateHostVisibility(true, view: host)
            coordinator.updateFocusedState(index == 0)
            coordinator.bindTerminalSession()
            host.delegate = coordinator
            host.controller = TerminalRuntime.shared.controller
            host.configuration = TerminalSurfaceOptions(backend: .vt(try XCTUnwrap(coordinator.terminalSession)))
            coordinator.applyAccessory(to: host, showsBar: false)
            root.view.addSubview(host)
        }
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        try await waitUntil("two mounted VT splits and top responder") {
            hosts[0].isFirstResponder
                && coordinators.allSatisfy { $0.sinkToken != nil }
                && hosts.allSatisfy { $0.surface?.frameValue != nil }
        }
        XCTAssertFalse(hosts[1].isFirstResponder)
        XCTAssertTrue(hosts[1].canBecomeFirstResponder)
        try await body(hosts[0], hosts[1])
    }

    @MainActor
    private func performEndedTerminalTap(on host: UITerminalView) async throws {
        let frame = try XCTUnwrap(host.surface?.frameValue)
        let cell = frame.layout.rect(column: 2, row: 1)
        let point = CGPoint(x: cell.midX, y: cell.midY)
        XCTAssertTrue(host.bounds.contains(point))
        let routed = expectation(description: "native terminal tap response")
        var completed = false
        host.nativePointer.onDiagnostic = { diagnostic in
            guard !completed, diagnostic.contains(" tap:") else { return }
            completed = true
            routed.fulfill()
        }
        defer { host.nativePointer.onDiagnostic = nil }
        let gesture = EndedSplitTapGesture()
        gesture.point = point
        host.handleTerminalTap(gesture)
        // The diagnostic and the production local-tap action run synchronously
        // in the same MainActor callback. Resuming here observes both, without
        // relying on an arbitrary delay or manufacturing the native response.
        await fulfillment(of: [routed], timeout: 2)
    }

    @MainActor
    private final class EndedSplitTapGesture: UITapGestureRecognizer {
        var point: CGPoint = .zero

        override var state: UIGestureRecognizer.State {
            get { .ended }
            set {}
        }

        override func location(in view: UIView?) -> CGPoint { point }
    }
    #endif

    // MARK: - Helpers

}
