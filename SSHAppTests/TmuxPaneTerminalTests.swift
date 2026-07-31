import XCTest
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
            syncFocusBody.contains("terminalView?.setTerminalSurfaceFocused(isFocused)"),
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
            source.contains("private let outputDelivery = TerminalOutputDeliveryQueue()"),
            "TmuxPaneTerminal must own the shared queue for ordered non-blocking pane output delivery"
        )
        XCTAssertTrue(
            receiveBody.contains("outputDelivery.enqueue(data)")
                && !receiveBody.contains("terminalSession.receive(data)"),
            "receiveFromPane must not synchronously enter InMemoryTerminalSession.receive(_:)"
        )
        XCTAssertTrue(
            attachBody.contains("markSurfaceAttached()")
                && markAttachedBody.contains("outputDelivery.setReady(false)")
                && markAttachedBody.contains("registerTerminalSurfaceAttachment()")
                && markAttachedBody.contains("beginViewportSettle"),
            "raw attachment must record the pane but keep output gated until viewport readiness"
        )
        XCTAssertTrue(
            viewportReadyBody.contains("restoreAndBindPane")
                && viewportReadyBody.contains("bindPaneSinkAndOpenOutputIfCurrent")
                && bindAndOpenBody.contains("outputDelivery.setReady(true"),
            "only settled viewport generations may restore/bind a pane and release snapshot/live output"
        )
        XCTAssertTrue(
            bindBody.contains("isReplayingPaneBacklog = true")
                && bindBody.contains("isReplayingPaneBacklog = false")
                && receiveBody.contains("enqueuePreservingPaneReplay"),
            "authoritative pane replay must bypass only the live-output byte cap"
        )
        XCTAssertTrue(
            markDetachedBody.contains("viewportReadiness.invalidate()")
                && markDetachedBody.contains("clearPaneSink()")
                && markDetachedBody.contains("outputDelivery.setReady(false)")
                && markDetachedBody.contains("outputDelivery.resetPendingOutput()"),
            "terminalDidDetachSurface must return output ownership to the pane and invalidate stale queued bytes"
        )
        XCTAssertTrue(
            replaceBody.contains("surfaceBindingGeneration += 1")
                && replaceBody.contains("clearPaneSink()")
                && replaceBody.contains("beginViewportSettle"),
            "pane reuse must invalidate stale settle work before requesting an authoritative replacement snapshot"
        )
        XCTAssertTrue(
            dismantleBody.contains("coordinator.prepareForDismantle()"),
            "view dismantling must synchronously clear the pane sink even if Ghostty's detach callback arrives later"
        )
        XCTAssertTrue(
            dismantleBody.contains("uiView.controller = nil"),
            "view dismantling must begin native retirement while the platform view is still alive"
        )
        XCTAssertFalse(
            makeBody.contains("imSession?.receive(data)"),
            "makeUIView must not feed initial tmux output directly into an unattached InMemoryTerminalSession"
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
            paneSource.contains("terminalView?.resignFirstResponder()"),
            "tmux panes must resign first responder when losing active focus"
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

        // First attachment is not a recreated surface; the second one is.
        coordinator.markSurfaceAttached()
        coordinator.markSurfaceDetached()
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
        coordinator.markSurfaceDetached()
        coordinator.markSurfaceAttached()

        try await waitUntil("successful restore binds the pane sink") {
            coordinator.sinkToken != nil
        }
        XCTAssertEqual(restoreCalls, 1)
        XCTAssertNotNil(coordinator.sinkToken)
    }

    // MARK: - Helpers

    @MainActor
    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("Timed out waiting for \(description)", file: file, line: line)
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func extractMethodBody(from source: String, methodName: String) throws -> String {
        guard let methodRange = source.range(of: methodName) else {
            throw NSError(domain: "Test", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Method '\(methodName)' not found"])
        }

        let afterMethod = source[methodRange.upperBound...]
        guard let braceStart = afterMethod.firstIndex(of: "{") else {
            throw NSError(domain: "Test", code: 2,
                         userInfo: [NSLocalizedDescriptionKey: "No opening brace for '\(methodName)'"])
        }

        var depth = 0
        var braceEnd: String.Index?
        var index = braceStart

        while index < afterMethod.endIndex {
            let char = afterMethod[index]
            if char == "{" { depth += 1 }
            if char == "}" {
                depth -= 1
                if depth == 0 {
                    braceEnd = index
                    break
                }
            }
            index = afterMethod.index(after: index)
        }

        guard let end = braceEnd else {
            throw NSError(domain: "Test", code: 3,
                         userInfo: [NSLocalizedDescriptionKey: "No matching brace for '\(methodName)'"])
        }

        return String(afterMethod[braceStart...end])
    }
}
