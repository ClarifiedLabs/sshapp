import Foundation
import GhosttyTerminal
import XCTest
@testable import SSHApp

@MainActor
final class TerminalSemanticLifetimeTests: XCTestCase {
    func testStalePreChannelAuthHostCannotPauseReplacementDelivery() async throws {
        let transport = SSHSession()
        let tab = Tab(session: transport)
        let old = GhosttyTerminalView.Coordinator()
        old.updateTab(tab)
        old.updateSession(transport)
        old.bindTerminalSession()
        let replacement = GhosttyTerminalView.Coordinator()
        replacement.updateTab(tab)
        replacement.updateSession(transport)
        replacement.bindTerminalSession()
        let lifetime = try XCTUnwrap(tab.terminalLifetime)
        lifetime.session.updateViewport(.init(width: 390, height: 480, cellWidth: 10, cellHeight: 20, scale: 2))
        _ = try await lifetime.session.snapshot()
        let drained = expectation(description: "replacement auth output commits")
        lifetime.setOutputReady(true, owner: replacement, onFirstDrain: { drained.fulfill() })
        old.prepareForDismantle()
        old.terminalDidDetachSurface() // Native callback can arrive after dismantle.
        transport.onDataReceived?(Data("auth".utf8))
        await fulfillment(of: [drained], timeout: 2)
        let frame = try await lifetime.session.snapshot()
        XCTAssertTrue(frame.line(0).hasPrefix("auth"))
        replacement.prepareForDismantle()
        tab.finishTerminalSession()
    }

    /// Regression: the engine's resize hop read `router.resize` when it ran.
    /// A grid change landing between host A's unbind and host B's bind was
    /// dropped, and the engine dedupes identical metrics, so B never sent it.
    func testEngineResizeWhileUnboundIsReplayedToNextHost() async throws {
        let lifetime = TerminalSemanticLifetime()
        let hostA = NSObject()
        let hostB = NSObject()
        lifetime.bind(owner: hostA, write: { _ in },
                      resize: { _ in XCTFail("An unbound host must not receive resizes") },
                      detachedWrite: { _ in })
        lifetime.unbind(owner: hostA)

        lifetime.session.updateViewport(.init(width: 390, height: 480, cellWidth: 10, cellHeight: 20, scale: 2))
        _ = try await lifetime.session.snapshot()
        let hopped = expectation(description: "engine resize hop ran while unbound")
        DispatchQueue.main.async { hopped.fulfill() }
        await fulfillment(of: [hopped], timeout: 2)

        var sizes: [InMemoryTerminalViewport] = []
        let replayed = expectation(description: "next host receives the engine size")
        lifetime.bind(owner: hostB, write: { _ in },
                      resize: { sizes.append($0); replayed.fulfill() },
                      detachedWrite: { _ in })
        await fulfillment(of: [replayed], timeout: 2)
        XCTAssertEqual(sizes.count, 1)
        XCTAssertGreaterThan(sizes.first?.columns ?? 0, 0)
        XCTAssertGreaterThan(sizes.first?.rows ?? 0, 0)
        lifetime.finish()
    }

    private final class RecordingOutputReceiver: TerminalOutputReceiver, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Data] = []
        var received: [Data] { lock.withLock { values } }

        func receiveIfCurrent(_ data: Data, ifCurrent: @Sendable () -> Bool) -> Bool {
            guard ifCurrent() else { return false }
            lock.withLock { values.append(data) }
            return true
        }
    }

    /// Regression: session status bytes arriving after the lifetime finished
    /// were enqueued into its (reset) delivery queue.
    func testSessionOutputAfterLifetimeFinishIsNotEnqueued() async throws {
        let transport = SSHSession()
        let tab = Tab(session: transport)
        let host = GhosttyTerminalView.Coordinator()
        host.updateTab(tab)
        host.updateSession(transport)
        host.bindTerminalSession()
        let lifetime = try XCTUnwrap(tab.terminalLifetime)
        let deliverSessionOutput = try XCTUnwrap(transport.onDataReceived)
        lifetime.finish()

        // Swap in a live probe queue so an unguarded enqueue is observable.
        let probe = TerminalOutputDeliveryQueue(label: "dev.sshapp.tests.finished-lifetime-probe")
        let receiver = RecordingOutputReceiver()
        probe.setReceiver(receiver)
        probe.setReady(true)
        lifetime.outputDelivery = probe
        deliverSessionOutput(Data("late status".utf8))

        let drained = expectation(description: "probe drained")
        probe.notifyWhenDrained { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
        XCTAssertTrue(receiver.received.isEmpty)
        host.prepareForDismantle()
        tab.finishTerminalSession()
    }

    func testStaleTmuxHostCannotPauseReplacementDelivery() async throws {
        let pane = TmuxPane(id: .init(rawValue: 1), windowID: .init(rawValue: 1))
        let old = TmuxPaneTerminal.Coordinator()
        old.pane = pane
        old.bindTerminalSession()
        let replacement = TmuxPaneTerminal.Coordinator()
        replacement.pane = pane
        replacement.bindTerminalSession()
        let lifetime = try XCTUnwrap(pane.terminalLifetime)
        lifetime.session.updateViewport(.init(width: 390, height: 480, cellWidth: 10, cellHeight: 20, scale: 2))
        _ = try await lifetime.session.snapshot()
        pane.installSemanticSink(restore: { false })
        let drained = expectation(description: "replacement pane output commits")
        lifetime.setOutputReady(true, owner: replacement, onFirstDrain: { drained.fulfill() })
        old.prepareForDismantle()
        pane.feed(Data("replacement".utf8))
        await fulfillment(of: [drained], timeout: 2)
        let frame = try await lifetime.session.snapshot()
        XCTAssertTrue(frame.line(0).hasPrefix("replacement"))
        replacement.prepareForDismantle()
        pane.finishTerminalSession()
    }

    func testDetachedTmuxOverflowRestoresBeforeResumingRetainedEngine() async throws {
        let pane = TmuxPane(id: .init(rawValue: 1), windowID: .init(rawValue: 1))
        let host = TmuxPaneTerminal.Coordinator()
        host.pane = pane
        host.bindTerminalSession()
        let lifetime = try XCTUnwrap(pane.terminalLifetime)
        let session = lifetime.session
        session.updateViewport(.init(width: 390, height: 480, cellWidth: 10, cellHeight: 20, scale: 2))
        _ = try await session.snapshot()
        let restored = expectation(description: "model requests snapshot without host")
        pane.installSemanticSink { [weak pane] in
            // Deterministic authoritative fixture, equivalent to tmux freshAttach.
            pane?.feedSnapshot(Data("\u{1b}[?1049l\u{1b}crecovered".utf8), mode: .freshAttach)
            restored.fulfill()
            return true
        }
        let initial = expectation(description: "alternate screen entered")
        lifetime.setOutputReady(true, owner: host, onFirstDrain: { initial.fulfill() })
        pane.feed(Data("\u{1b}[?1049halt".utf8))
        await fulfillment(of: [initial], timeout: 2)
        host.prepareForDismantle()
        XCTAssertNotNil(pane.feedSink, "Host detach must not remove semantic ingestion")
        // One enqueue deterministically overflows before a drain can claim it.
        // The dropped prefix contains the alternate-screen exit.
        pane.feed(Data("\u{1b}[?1049l".utf8) + Data(repeating: 120, count: 600_000))
        await fulfillment(of: [restored], timeout: 2)
        let drained = expectation(description: "recovered snapshot commits")
        lifetime.outputDelivery.setReady(true, onFirstDrain: { drained.fulfill() })
        lifetime.outputDelivery.enqueue(Data("!".utf8))
        await fulfillment(of: [drained], timeout: 2)
        let frame = try await session.snapshot()
        XCTAssertTrue(frame.line(0).hasPrefix("recovered"))
        XCTAssertFalse(pane.needsOutputRecovery)
        XCTAssertFalse(lifetime.outputDelivery.requiresSnapshotRecovery)
        // Switching away and back proves the restored text is in primary,
        // not an alternate screen accidentally kept alive across the gap.
        session.receive(Data("\u{1b}[?1049h\u{1b}[?1049l".utf8))
        let primary = try await session.snapshot()
        XCTAssertTrue(primary.line(0).hasPrefix("recovered"))
        pane.finishTerminalSession()
    }

    func testTmuxGapRecoveryFailureStaysClosedUntilAuthoritativeSnapshot() async throws {
        let pane = TmuxPane(id: .init(rawValue: 2), windowID: .init(rawValue: 1))
        let lifetime = TerminalSemanticLifetime()
        pane.terminalLifetime = lifetime
        let attempted = expectation(description: "recovery attempted")
        pane.installSemanticSink {
            attempted.fulfill()
            return false
        }
        pane.feed(Data(repeating: 120, count: 600_000))
        await fulfillment(of: [attempted], timeout: 2)
        XCTAssertTrue(pane.needsOutputRecovery)
        XCTAssertEqual(pane.activity, .stalled)
        lifetime.outputDelivery.setReady(true)
        XCTAssertTrue(lifetime.outputDelivery.requiresSnapshotRecovery,
                      "Failed restore must not fail open onto a corrupt retained parser")
        pane.feedSnapshot(Data("\u{1b}[?1049l\u{1b}[H\u{1b}[2Jauthoritative".utf8), mode: .freshAttach)
        XCTAssertFalse(pane.needsOutputRecovery)
        XCTAssertFalse(lifetime.outputDelivery.requiresSnapshotRecovery)
        pane.finishTerminalSession()
    }

    func testManualResumeRecoversFailedOutputGapThroughController() async throws {
        try await exerciseOutputGapResume(automatic: false, failFirstSnapshot: false)
    }

    func testAutomaticResumeRecoversFailedOutputGapThroughController() async throws {
        try await exerciseOutputGapResume(automatic: true, failFirstSnapshot: false)
    }

    func testFailedManualGapResumeRemainsStalledAndCanRetry() async throws {
        try await exerciseOutputGapResume(automatic: false, failFirstSnapshot: true)
    }

    func testManualResumeRecoversGapFromBeforeFirstSinkInstallation() async throws {
        try await exerciseOutputGapResume(automatic: false, failFirstSnapshot: false,
                                         overflowBeforeSink: true)
    }

    @MainActor
    private final class RecoveryCommands {
        var values: [String] = []
        func append(_ data: Data) { values.append(String(decoding: data, as: UTF8.self)) }
    }

    private func exerciseOutputGapResume(automatic: Bool, failFirstSnapshot: Bool,
                                         overflowBeforeSink: Bool = false) async throws {
        let commands = RecoveryCommands()
        let gateway = TmuxGateway(writer: { data in await commands.append(data) })
        let controller = TmuxController(gateway: gateway)
        await gateway.setDelegate(controller)
        let pane = TmuxPane(id: .init(rawValue: 3), windowID: .init(rawValue: 1))
        controller.panes[pane.id] = pane
        controller.activeWindowID = pane.windowID
        let lifetime = TerminalSemanticLifetime()
        pane.terminalLifetime = lifetime
        lifetime.session.updateViewport(.init(width: 390, height: 480, cellWidth: 10, cellHeight: 20, scale: 2))
        _ = try await lifetime.session.snapshot()
        defer { pane.finishTerminalSession() }
        if overflowBeforeSink { pane.feed(Data(repeating: 120, count: 600_000)) }
        pane.installSemanticSink { false }
        if !overflowBeforeSink { pane.feed(Data(repeating: 120, count: 600_000)) }
        try await waitUntil("output recovery", timeout: 2) { pane.activity == .stalled }
        XCTAssertTrue(pane.requiresOutputRecovery)

        let attempts = failFirstSnapshot ? 2 : 1
        for attempt in 0..<attempts {
            let offset = commands.values.count
            if automatic {
                await gateway.feedLine(Data("%pause %3".utf8))
            } else {
                controller.resumePaneManually(pane.id)
            }
            try await waitUntil("output recovery", timeout: 2) { commands.values.count == offset + 1 }
            XCTAssertTrue(commands.values.last?.contains("refresh-client -A \"%3:continue\"") == true)
            await recoveryResponse(gateway, number: offset + 1, body: "")
            await gateway.feedLine(Data("%continue %3".utf8))
            try await waitUntil("output recovery", timeout: 2) { commands.values.count == offset + 2 }
            XCTAssertEqual(pane.activity, .recovering,
                           "%continue must not hide a still-gated pane")
            XCTAssertTrue(pane.requiresOutputRecovery)
            XCTAssertTrue(commands.values.last?.contains("list-panes -t %3") == true)

            if failFirstSnapshot && attempt == 0 {
                await recoveryResponse(gateway, number: offset + 2, body: "unavailable", failed: true)
                try await waitUntil("output recovery", timeout: 2) { pane.activity == .stalled }
                XCTAssertTrue(pane.requiresOutputRecovery)
                await gateway.feedLine(Data("%continue %3".utf8))
                XCTAssertEqual(pane.activity, .stalled)
                continue
            }

            let state = [
                "pane_id=%3", "pane_width=39", "pane_height=24", "alternate_on=0",
                "alternate_saved_x=0", "alternate_saved_y=0", "cursor_x=9", "cursor_y=0",
                "scroll_region_upper=0", "scroll_region_lower=23", "pane_tabs=",
                "cursor_flag=1", "insert_flag=0", "keypad_cursor_flag=0", "keypad_flag=0",
                "wrap_flag=1", "mouse_standard_flag=0", "mouse_button_flag=0",
                "mouse_any_flag=0", "mouse_utf8_flag=0", "mouse_sgr_flag=0",
                "bracket_paste_flag=0", "pane_key_mode=emacs",
            ].joined(separator: "\t")
            await recoveryResponse(gateway, number: offset + 2, body: state)
            try await waitUntil("output recovery", timeout: 2) { commands.values.count == offset + 3 }
            XCTAssertTrue(commands.values.last?.contains("-S 0 -E -") == true)
            await recoveryResponse(gateway, number: offset + 3, body: "recovered")
            try await waitUntil("output recovery", timeout: 2) { pane.activity == .running }
        }

        XCTAssertFalse(pane.needsOutputRecovery)
        XCTAssertFalse(lifetime.outputDelivery.requiresSnapshotRecovery)
        let drained = expectation(description: "manual/automatic recovery releases live output")
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
    }

    private func recoveryResponse(_ gateway: TmuxGateway, number: Int, body: String,
                                  failed: Bool = false) async {
        await gateway.feedLine(Data("%begin 0 \(number) 1".utf8))
        await gateway.feedLine(Data(body.utf8))
        await gateway.feedLine(Data("\(failed ? "%error" : "%end") 0 \(number) 1".utf8))
    }

    func testTabSessionReplacementRetiresEngineButSameSessionDoesNot() {
        let transport = SSHSession()
        let tab = Tab(session: transport)
        let lifetime = TerminalSemanticLifetime()
        tab.terminalLifetime = lifetime

        tab.session = transport
        XCTAssertTrue(tab.terminalLifetime === lifetime)
        XCTAssertFalse(lifetime.isFinished)

        tab.session = SSHSession()
        XCTAssertNil(tab.terminalLifetime)
        XCTAssertTrue(lifetime.isFinished)
        XCTAssertNil(lifetime.session.enqueueSelectAll(), "Retirement must close VT admission")
    }

    func testDisconnectedStateRetiresEngineIdempotently() {
        let tab = Tab(connectionState: .connected)
        let lifetime = TerminalSemanticLifetime()
        tab.terminalLifetime = lifetime

        tab.connectionState = .disconnected
        tab.finishTerminalSession()

        XCTAssertNil(tab.terminalLifetime)
        XCTAssertTrue(lifetime.isFinished)
        XCTAssertNil(lifetime.session.enqueueSelectAll())
    }

    func testDetachedHostKeepsEngineAndRoutesRepliesWithoutRetainingOwner() async {
        let tab = Tab()
        let lifetime = TerminalSemanticLifetime()
        tab.terminalLifetime = lifetime
        var owner: NSObject? = NSObject()
        let weakOwner = WeakReference(owner)
        let reply = expectation(description: "Detached reply routed")
        lifetime.bind(owner: owner!, write: { _ in
            XCTFail("Detached replies must not use the old host")
        }, resize: { _ in }, detachedWrite: { data in
            XCTAssertEqual(data, Data("reply".utf8))
            reply.fulfill()
        })

        lifetime.unbind(owner: owner!)
        owner = nil
        lifetime.session.sendInput(Data("reply".utf8))
        await fulfillment(of: [reply], timeout: 1)

        XCTAssertNil(weakOwner.value)
        XCTAssertTrue(tab.terminalLifetime === lifetime)
        XCTAssertFalse(lifetime.isFinished)
        tab.finishTerminalSession()
    }

    func testStaleHostUnbindCannotDetachReplacementHost() async {
        let lifetime = TerminalSemanticLifetime()
        let oldHost = NSObject()
        let newHost = NSObject()
        let write = expectation(description: "Replacement host receives input")
        lifetime.bind(owner: oldHost, write: { _ in XCTFail("Stale host") },
                      resize: { _ in }, detachedWrite: { _ in XCTFail("Stale route") })
        lifetime.bind(owner: newHost, write: { _ in write.fulfill() },
                      resize: { _ in }, detachedWrite: { _ in XCTFail("Detached replacement") })

        lifetime.unbind(owner: oldHost)
        lifetime.session.sendInput(Data("input".utf8))
        await fulfillment(of: [write], timeout: 1)
        lifetime.finish()
    }

    func testRetirementRevokesAlreadyQueuedRepliesAndCannotRebind() async {
        let lifetime = TerminalSemanticLifetime()
        let owner = NSObject()
        let noWrite = expectation(description: "Retired engine cannot write")
        noWrite.isInverted = true
        lifetime.bind(owner: owner, write: { _ in noWrite.fulfill() },
                      resize: { _ in }, detachedWrite: { _ in noWrite.fulfill() })
        lifetime.session.sendInput(Data("queued".utf8))
        // No actor suspension between admission and retirement: any main-queue
        // reply callback is still pending when its route is revoked.
        lifetime.finish()
        lifetime.bind(owner: owner, write: { _ in noWrite.fulfill() },
                      resize: { _ in }, detachedWrite: { _ in noWrite.fulfill() })
        lifetime.session.sendInput(Data("late".utf8))
        await fulfillment(of: [noWrite], timeout: 0.1)
    }

    func testPaneFocusAndWindowChangesPreserveLifetime() {
        let pane = TmuxPane(id: .init(rawValue: 1), windowID: .init(rawValue: 1))
        let lifetime = TerminalSemanticLifetime()
        pane.terminalLifetime = lifetime
        pane.isActive = true
        pane.isActive = false
        pane.windowID = .init(rawValue: 2)
        XCTAssertTrue(pane.terminalLifetime === lifetime)
        XCTAssertFalse(lifetime.isFinished)
        pane.finishTerminalSession()
        XCTAssertNil(pane.terminalLifetime)
        XCTAssertTrue(lifetime.isFinished)
    }

    func testWindowRemovalRetiresPaneEvenWhenModelIsStillRetained() async {
        let gateway = TmuxGateway(writer: { _ in })
        let controller = TmuxController(gateway: gateway)
        let windowID = TmuxWindowID(rawValue: 1)
        let pane = TmuxPane(id: .init(rawValue: 2), windowID: windowID)
        let lifetime = TerminalSemanticLifetime()
        pane.terminalLifetime = lifetime
        controller.windows[windowID] = TmuxWindow(id: windowID, paneIDs: [pane.id])
        controller.panes[pane.id] = pane

        await controller.gateway(gateway, didReceive: .windowClose(windowID))

        XCTAssertNil(controller.panes[pane.id])
        XCTAssertNil(pane.terminalLifetime)
        XCTAssertTrue(lifetime.isFinished)
    }

    func testGatewayShutdownRetiresAllRetainedPaneEngines() async {
        let gateway = TmuxGateway(writer: { _ in })
        let controller = TmuxController(gateway: gateway)
        let panes = (1...2).map {
            TmuxPane(id: .init(rawValue: $0), windowID: .init(rawValue: 1))
        }
        let lifetimes = panes.map { pane in
            let lifetime = TerminalSemanticLifetime()
            pane.terminalLifetime = lifetime
            controller.panes[pane.id] = pane
            return lifetime
        }

        await controller.gatewayDidShutDown(gateway, reason: "test")

        XCTAssertTrue(panes.allSatisfy { $0.terminalLifetime == nil })
        XCTAssertTrue(lifetimes.allSatisfy(\.isFinished))
    }

    #if DEBUG
    func testInitialChannelPreservesAuthEngineAndReplacementRetiresIt() {
        let transport = ScriptedSSHChannelTransport()
        let session = SSHSession()
        let tab = Tab(session: session)
        let lifetime = TerminalSemanticLifetime()
        tab.terminalLifetime = lifetime
        let first = SSHChannel(transport: transport, owner: session, tmuxSettings: .default)
        tab.channel = first
        tab.channel = first
        XCTAssertTrue(tab.terminalLifetime === lifetime)
        XCTAssertFalse(lifetime.isFinished)

        tab.channel = SSHChannel(transport: transport, owner: session, tmuxSettings: .default)
        XCTAssertTrue(lifetime.isFinished)
        XCTAssertNil(tab.terminalLifetime)
        XCTAssertNil(first.onTerminalClosed)

        let replacement = TerminalSemanticLifetime()
        tab.terminalLifetime = replacement
        first.close()
        XCTAssertFalse(replacement.isFinished, "A replaced channel cannot retire its successor")
        tab.finishTerminalSession()
    }

    func testChannelCloseAndSessionDisconnectRetireWithoutHost() {
        for closeBySession in [false, true] {
            let session = SSHSession()
            let channel = SSHChannel(transport: ScriptedSSHChannelTransport(),
                                     owner: session, tmuxSettings: .default)
            let tab = Tab(session: session, channel: channel)
            let lifetime = TerminalSemanticLifetime()
            tab.terminalLifetime = lifetime

            if closeBySession {
                channel.markClosedBySessionDisconnect()
            } else {
                channel.close()
            }
            XCTAssertNil(tab.terminalLifetime)
            XCTAssertTrue(lifetime.isFinished)
        }
    }

    func testChannelRetirementCallbackDoesNotRetainTabOrLifetime() {
        let session = SSHSession()
        let channel = SSHChannel(transport: ScriptedSSHChannelTransport(),
                                 owner: session, tmuxSettings: .default)
        var tab: Tab? = Tab(session: session, channel: channel)
        tab?.terminalLifetime = TerminalSemanticLifetime()
        let weakTab = WeakReference(tab)
        let weakLifetime = WeakReference(tab?.terminalLifetime)

        tab = nil

        XCTAssertNil(weakTab.value)
        XCTAssertNil(weakLifetime.value)
    }
    #endif
}
