#if DEBUG && canImport(UIKit)
import UIKit
import XCTest
@testable import SSHApp
import GhosttyTerminal

@MainActor
final class TerminalSelectionHarnessStartupTests: XCTestCase {
    func testOnlyLoupeOptInDefersTheTerminalMount() {
        let option = "--sshapp-ui-test-terminal-loupe-orientation=\(UIInterfaceOrientation.landscapeRight.rawValue)"
        XCTAssertNil(TerminalLoupeStartupGate.requestedOrientation(arguments: [option]))
        XCTAssertEqual(TerminalLoupeStartupGate.requestedOrientation(arguments: [
            "--sshapp-ui-test-terminal-loupe", option,
        ]), .landscapeRight)

        let model = TerminalSelectionUITestHarnessModel(scenarioArgument: .success(.standard))
        XCTAssertTrue(model.shouldMountTerminal)
        XCTAssertEqual(model.phase, .mounting)
        model.surfaceDidAppear(generation: model.generation)
        XCTAssertEqual(model.phase, .waitingForMetrics)
        XCTAssertNotNil(model.setupTimeoutTask, "Non-loupe clients retain their original startup")
    }

    func testLoupeShellCannotStartTimeoutOpenOrFeedBeforeExplicitStart() {
        let model = TerminalSelectionUITestHarnessModel(
            scenarioArgument: .success(.standard), loupeStartupOrientation: .landscapeRight
        )
        model.sampleLoupeStartupGeometry = { self.geometry(orientation: .portrait) }
        model.startLoupeFixture()
        model.surfaceDidAppear(generation: model.generation)
        model.resetSurface()
        model.postFlushDraw(generation: model.generation)
        let landscape = geometry()
        model.sampleLoupeStartupGeometry = { landscape }
        // Even arbitrarily long, valid settlement cannot start work by itself.
        model.observeLoupeStartupGeometry(landscape, now: 0)
        model.observeLoupeStartupGeometry(landscape, now: 100)
        XCTAssertEqual(model.phase, .awaitingStart)
        XCTAssertFalse(model.shouldMountTerminal)
        XCTAssertEqual(model.generation, 1)
        XCTAssertNil(model.setupTimeoutTask)
        XCTAssertNil(model.actualRows)
        XCTAssertNil(model.actualColumns)
        XCTAssertNil(model.fixture)
        XCTAssertFalse(model.channel.isOpen)
        XCTAssertTrue(model.transport.snapshot().activeChannelIDs.isEmpty)
        XCTAssertTrue(model.transport.snapshot().pendingRequests.isEmpty)
        XCTAssertFalse(model.generationLatches[1]?.sawPostFlushDraw ?? true)
    }

    func testLandscapeBoundsDoNotSubstituteForActualInterfaceOrientation() {
        var gate = TerminalLoupeStartupGate(orientation: .landscapeRight)
        // All samples have identical landscape bounds. Portrait and the opposite
        // landscape orientation must not pass the actual UIWindowScene gate.
        for orientation in [UIInterfaceOrientation.portrait, .landscapeLeft, .unknown] {
            let sample = geometry(orientation: orientation)
            gate.observe(sample, now: 0)
            XCTAssertFalse(gate.requestStart(sample, now: 100))
        }
        let sample = geometry()
        gate.observe(sample, now: 101)
        XCTAssertFalse(gate.requestStart(sample, now: 101.49))
        XCTAssertTrue(gate.requestStart(sample, now: 101.5))
        XCTAssertFalse(gate.requestStart(sample, now: 102), "Explicit start is one-shot")
        XCTAssertTrue(gate.confirmMount(sample))
        XCTAssertEqual(gate.mountedGeometry, sample)
    }

    func testInterfaceOrientationCannotStartWhileSceneBoundsAreStillPortrait() {
        var gate = TerminalLoupeStartupGate(orientation: .landscapeRight)
        let staleBounds = geometry(landscapeBounds: false)
        gate.observe(staleBounds, now: 0)
        XCTAssertFalse(gate.requestStart(staleBounds, now: 100))
        let settled = geometry()
        gate.observe(settled, now: 101)
        XCTAssertTrue(gate.requestStart(settled, now: 101.5))
    }

    func testForegroundAndGeometryChangesRestartSettlement() {
        var gate = TerminalLoupeStartupGate(orientation: .landscapeRight)
        let sample = geometry()
        gate.observe(sample, now: 0)
        gate.observe(sample, now: 1)
        XCTAssertTrue(gate.canStart)
        XCTAssertFalse(gate.requestStart(geometry(foreground: false), now: 2))
        gate.observe(sample, now: 3)
        XCTAssertFalse(gate.canStart)
        XCTAssertFalse(gate.requestStart(geometry(viewportHeight: 600), now: 3.6))
        XCTAssertFalse(gate.requestStart(geometry(keyWindow: false), now: 5))
        XCTAssertFalse(gate.requestStart(nil, now: 6))
        gate.observe(sample, now: 7)
        XCTAssertTrue(gate.requestStart(sample, now: 7.5))
    }

    func testReattachmentToSameSceneRequiresFreshSettlement() {
        var gate = TerminalLoupeStartupGate(orientation: .landscapeRight)
        let original = geometry()
        gate.observe(original, now: 0)
        gate.observe(original, now: 1)
        XCTAssertTrue(gate.canStart)
        let reattached = geometry(attachmentID: "attachment-2")
        XCTAssertFalse(gate.requestStart(reattached, now: 10))
        XCTAssertFalse(gate.requestStart(reattached, now: 10.49))
        XCTAssertTrue(gate.requestStart(reattached, now: 10.5))
    }

    func testMountRevalidatesActualOrientationForegroundAndGeometry() {
        for changed in [geometry(orientation: .landscapeLeft), geometry(foreground: false),
                        geometry(keyWindow: false), geometry(viewportHeight: 600)] {
            var gate = TerminalLoupeStartupGate(orientation: .landscapeRight)
            let sample = geometry()
            gate.observe(sample, now: 0)
            XCTAssertTrue(gate.requestStart(sample, now: 1))
            XCTAssertFalse(gate.confirmMount(changed))
            XCTAssertNil(gate.mountedGeometry)
        }
    }

    func testModelRejectsMountRaceBeforeStartingSetup() {
        let model = preparedModel()
        model.startLoupeFixture()
        XCTAssertTrue(model.shouldMountTerminal)
        XCTAssertNil(model.setupTimeoutTask)
        model.sampleLoupeStartupGeometry = { self.geometry(orientation: .portrait) }
        model.surfaceDidAppear(generation: model.generation)
        XCTAssertEqual(model.phase, .failed)
        XCTAssertNil(model.setupTimeoutTask)
        XCTAssertFalse(model.channel.isOpen)
        XCTAssertNil(model.actualRows)
        XCTAssertNil(model.loupeStartup?.mountedGeometry)
    }

    func testModelStartsMetricsTimeoutOnlyAfterValidatedMount() {
        let model = preparedModel()
        model.startLoupeFixture()
        XCTAssertEqual(model.phase, .mounting)
        XCTAssertNil(model.setupTimeoutTask)
        model.surfaceDidAppear(generation: model.generation)
        XCTAssertEqual(model.phase, .waitingForMetrics)
        XCTAssertNotNil(model.setupTimeoutTask)
        XCTAssertEqual(model.loupeStartup?.mountedGeometry, geometry())
        XCTAssertFalse(model.channel.isOpen, "The validated mount must still wait for real grid metrics")
    }

    /// Regression: the IME fixture's software keyboard resized the grid
    /// 79 -> 75 -> 79 -> 76 rows after setup had locked 79 rows, and readiness
    /// (live grid == locked grid) timed out "during phase feeding".
    func testGridResizeDuringOpeningAndFeedingRestartsSetupAndBecomesReady() async throws {
        let model = TerminalSelectionUITestHarnessModel(scenarioArgument: .success(.standard))
        model.surfaceDidAppear(generation: model.generation)
        XCTAssertEqual(model.phase, .waitingForMetrics)
        model.receive(snapshot: try gridSnapshot(rows: 79, revision: 1), generation: model.generation)
        XCTAssertEqual(model.phase, .opening)
        XCTAssertEqual(model.actualRows, 79)
        try await waitUntil("initial setup feeds") { model.phase == .feeding }

        var revision: UInt64 = 1
        for rows in [75, 79, 76] {
            revision += 1
            model.receive(snapshot: try gridSnapshot(rows: rows, revision: revision), generation: model.generation)
            XCTAssertEqual(model.actualRows, rows, "Setup restarts with the new grid immediately")
            try await waitUntil("setup for \(rows) rows feeds") {
                model.phase == .feeding && model.fixture?.rows == rows
            }
        }
        XCTAssertEqual(model.setupRestartCount, 3)

        model.postFlushDraw(generation: model.generation)
        revision += 1
        model.receive(snapshot: try gridSnapshot(rows: 76, revision: revision), generation: model.generation)
        XCTAssertEqual(model.phase, .ready, model.errorText ?? "")
        XCTAssertNil(model.errorText)
        XCTAssertEqual(model.actualRows, 76)
        XCTAssertEqual(model.fixture?.rows, 76)
        XCTAssertNil(model.setupTimeoutTask, "Readiness cancels the setup timeout")

        let transport = model.transport.snapshot()
        let opens = transport.ledger.filter {
            if case .openRequested = $0.event { return true } else { return false }
        }
        XCTAssertEqual(opens.count, 1, "A restart reuses the one shell, never opens another")
        let channelID = try XCTUnwrap(transport.activeChannelIDs.first)
        XCTAssertEqual(transport.latestDimensions[channelID],
                       ScriptedSSHChannelTransport.TerminalDimensions(cols: 100, rows: 76))
    }

    func testUnchangedGridDuringFeedingDoesNotRestartSetup() async throws {
        let model = TerminalSelectionUITestHarnessModel(scenarioArgument: .success(.standard))
        model.surfaceDidAppear(generation: model.generation)
        model.receive(snapshot: try gridSnapshot(rows: 40, revision: 1), generation: model.generation)
        try await waitUntil("setup feeds") { model.phase == .feeding }
        model.postFlushDraw(generation: model.generation)
        model.receive(snapshot: try gridSnapshot(rows: 40, revision: 2), generation: model.generation)
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.setupRestartCount, 0)
    }

    /// Regression: on iPad the IME fixture reached ready at 60 rows, then the
    /// minimized keyboard's dictation accessory shrank the grid to 59 rows. The
    /// fixture stayed "ready" for 60 rows and the UI test failed its
    /// geometry/open/resize contract. Setup now restarts until the test asks
    /// for the keyboard; afterwards keyboard resizes must keep the fixture.
    func testIMEGridResizeAfterReadyRestartsSetupUntilKeyboardRequested() async throws {
        let model = TerminalSelectionUITestHarnessModel(
            scenarioArgument: .success(.standard), imeEnabled: true
        )
        model.surfaceDidAppear(generation: model.generation)
        model.receive(snapshot: try gridSnapshot(rows: 60, revision: 1), generation: model.generation)
        try await waitUntil("initial setup feeds") { model.phase == .feeding }
        model.postFlushDraw(generation: model.generation)
        model.receive(snapshot: try gridSnapshot(rows: 60, revision: 2), generation: model.generation)
        XCTAssertEqual(model.phase, .ready, model.errorText ?? "")

        model.receive(snapshot: try gridSnapshot(rows: 59, revision: 3), generation: model.generation)
        XCTAssertEqual(model.setupRestartCount, 1)
        XCTAssertEqual(model.actualRows, 59)
        try await waitUntil("restarted setup is ready for 59 rows") {
            model.phase == .ready && model.fixture?.rows == 59
        }
        let transport = model.transport.snapshot()
        let channelID = try XCTUnwrap(transport.activeChannelIDs.first)
        XCTAssertEqual(transport.latestDimensions[channelID],
                       ScriptedSSHChannelTransport.TerminalDimensions(cols: 100, rows: 59))

        model.requestIMEKeyboard()
        model.receive(snapshot: try gridSnapshot(rows: 30, revision: 4), generation: model.generation)
        XCTAssertEqual(model.phase, .ready, "The requested keyboard's resize keeps the fixture")
        XCTAssertEqual(model.setupRestartCount, 1)
        XCTAssertEqual(model.fixture?.rows, 59)
    }

    /// r10 on both physical iPads: the IME fixture fed at the final 137x76
    /// grid but never saw the post-flush draw, and the status could not say
    /// why. The setup timeline must name each step and the missing signal.
    func testSetupTimelineExplainsMissingPostFlushDraw() async throws {
        let model = TerminalSelectionUITestHarnessModel(
            scenarioArgument: .success(.standard), imeEnabled: true
        )
        model.surfaceDidAppear(generation: model.generation)
        model.receive(snapshot: try gridSnapshot(rows: 79, columns: 137, revision: 1), generation: model.generation)
        try await waitUntil("initial setup feeds") { model.phase == .feeding }
        model.receive(snapshot: try gridSnapshot(rows: 76, columns: 137, revision: 2), generation: model.generation)
        try await waitUntil("restart feeds") { model.phase == .feeding && model.fixture?.rows == 76 }
        try await waitUntil("feed delivered") {
            model.setupEvents.contains { $0.contains("readiness.pending attempt=2") }
        }
        model.recordSetupEvent("draw.request view=true visible=true size=1032.0x1228.0 gen=1")

        XCTAssertEqual(model.readinessBlockers(generation: model.generation), "noPostFlushDraw")
        let timeline = model.setupEvents.joined(separator: "\n")
        for step in [
            "surface.appear gen=1", "grid 137x79", "setup.start attempt=1 grid=137x79",
            "open.await attempt=1 opens=true", "open.done attempt=1",
            "setup.restart #1", "137x79 -> 137x76", "setup.start attempt=2 grid=137x76",
            "resize attempt=2 grid=137x76", "feed.start attempt=2", "feed.delivered attempt=2",
            "readiness.pending attempt=2 noPostFlushDraw", "draw.request",
        ] {
            XCTAssertTrue(timeline.contains(step), "missing \(step) in\n\(timeline)")
        }
        XCTAssertTrue(model.fixtureStatusJSON.contains("\"setupEvents\""))

        model.postFlushDraw(generation: model.generation)
        model.receive(snapshot: try gridSnapshot(rows: 76, columns: 137, revision: 3), generation: model.generation)
        XCTAssertEqual(model.phase, .ready, model.errorText ?? "")
        XCTAssertTrue(model.setupEvents.last?.contains("ready grid=137x76") == true)
    }

    func testSetupTimelineIsBounded() {
        let model = TerminalSelectionUITestHarnessModel(scenarioArgument: .success(.standard))
        for index in 0..<(TerminalSelectionUITestHarnessModel.maximumSetupEvents * 2) {
            model.recordSetupEvent("event-\(index)")
        }
        XCTAssertEqual(model.setupEvents.count, TerminalSelectionUITestHarnessModel.maximumSetupEvents)
        XCTAssertTrue(model.setupEvents.first?.hasSuffix("event-0") == true, "Keeps the start of setup")
        XCTAssertTrue(model.setupEvents.last?.hasSuffix(
            "event-\(TerminalSelectionUITestHarnessModel.maximumSetupEvents * 2 - 1)"
        ) == true, "Keeps the latest events")
    }

    func testNonIMEGridResizeAfterReadyKeepsFixture() async throws {
        let model = TerminalSelectionUITestHarnessModel(
            scenarioArgument: .success(.standard), imeEnabled: false
        )
        model.surfaceDidAppear(generation: model.generation)
        model.receive(snapshot: try gridSnapshot(rows: 40, revision: 1), generation: model.generation)
        try await waitUntil("setup feeds") { model.phase == .feeding }
        model.postFlushDraw(generation: model.generation)
        model.receive(snapshot: try gridSnapshot(rows: 40, revision: 2), generation: model.generation)
        XCTAssertEqual(model.phase, .ready)
        model.receive(snapshot: try gridSnapshot(rows: 39, revision: 3), generation: model.generation)
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.setupRestartCount, 0)
        XCTAssertEqual(model.fixture?.rows, 40)
    }

    private func gridSnapshot(rows: Int, columns: Int = 100, revision: UInt64) throws -> TerminalSelectionDebugSnapshot {
        let bounds: [String: Double] = ["x": 0, "y": 0, "width": Double(columns) * 8, "height": Double(rows) * 16]
        let json: [String: Any] = [
            "schemaVersion": TerminalSelectionDebugSnapshot.currentSchemaVersion,
            "revision": revision,
            "surfaceReady": true,
            "gridReady": true,
            "selectionOwnership": "none",
            "touchHandlesVisible": false,
            "loupeVisible": false,
            "isMouseCaptured": false,
            "selectionGestureActive": false,
            "handleMode": "none",
            "terminalBounds": bounds,
            "terminalViewportBounds": bounds,
            "gridColumns": columns,
            "gridRows": rows,
            "resolvedGridOrigin": ["x": 0, "y": 0],
            "cellWidthPoints": 8,
            "cellHeightPoints": 16,
        ]
        return try JSONDecoder().decode(TerminalSelectionDebugSnapshot.self,
                                        from: JSONSerialization.data(withJSONObject: json))
    }

    private func waitUntil(_ description: String, timeout: Duration = .seconds(5),
                           _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out: \(description)")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func preparedModel() -> TerminalSelectionUITestHarnessModel {
        let model = TerminalSelectionUITestHarnessModel(
            scenarioArgument: .success(.standard), loupeStartupOrientation: .landscapeRight
        )
        let sample = geometry()
        model.sampleLoupeStartupGeometry = { sample }
        model.observeLoupeStartupGeometry(sample, now: ProcessInfo.processInfo.systemUptime - 1)
        return model
    }

    private func geometry(
        orientation: UIInterfaceOrientation = .landscapeRight,
        foreground: Bool = true,
        keyWindow: Bool = true,
        landscapeBounds: Bool = true,
        attachmentID: String = "attachment-1",
        viewportHeight: CGFloat = 650
    ) -> TerminalLoupeStartupGeometry {
        TerminalLoupeStartupGeometry(
            sceneID: "loupe-scene", attachmentID: attachmentID,
            interfaceOrientation: orientation.rawValue,
            foregroundActive: foreground, keyWindow: keyWindow,
            sceneBounds: CGRect(x: 0, y: 0, width: landscapeBounds ? 1024 : 768,
                                height: landscapeBounds ? 768 : 1024),
            windowBounds: CGRect(x: 0, y: 0, width: landscapeBounds ? 1024 : 768,
                                 height: landscapeBounds ? 768 : 1024),
            viewportBounds: CGRect(x: 0, y: 0, width: 1024, height: viewportHeight),
            safeAreaFrame: CGRect(x: 0, y: 24, width: 1024, height: 724)
        )
    }
}
#endif
