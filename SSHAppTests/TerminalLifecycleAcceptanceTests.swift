#if DEBUG && !targetEnvironment(macCatalyst)
import XCTest
import UIKit
@testable import GhosttyVT
@testable import GhosttyTerminal
@testable import SSHApp

@MainActor
final class TerminalLifecycleAcceptanceTests: XCTestCase {
    private let base = ["--sshapp-ui-test-terminal-selection", "--sshapp-ui-test-terminal-selection-scenario=standard"]
    private let option = "--sshapp-ui-test-terminal-lifecycle="

    func testStrictOptInAcceptsOnlyOneKnownNonconflictingMode() throws {
        XCTAssertNil(try UITestAppState.parseTerminalLifecycleArguments(base).get())
        for mode in [TerminalLifecycleScenario.graphicsBackground, .graphicsSystem, .scrollMomentum] {
            XCTAssertEqual(try UITestAppState.parseTerminalLifecycleArguments(base + [option + mode.rawValue]).get(), mode)
        }
        for suffix in ["", "unknown", "graphics-background=extra"] {
            XCTAssertThrowsError(try UITestAppState.parseTerminalLifecycleArguments(base + [option + suffix]).get())
        }
        let valid = option + "graphics-background"
        for arguments in [base + [valid, valid], base + [valid, option + "scroll-momentum"],
                          base + [valid, "--sshapp-ui-test-terminal-ime"],
                          base + [valid, "--sshapp-ui-test-terminal-loupe"],
                          base + ["--sshapp-ui-test-terminal-lifecycle"],
                          [valid], base + [valid, "--sshapp-ui-test-terminal-selection-scenario=mouse-captured"]] {
            XCTAssertThrowsError(try UITestAppState.parseTerminalLifecycleArguments(arguments).get())
        }
    }

    func testSystemModeNeverResetsPersistentStateEvenWithLegacyManualResetArgument() {
        XCTAssertTrue(UITestAppState.shouldResetState(arguments: ["--sshapp-reset-state"]))
        XCTAssertFalse(UITestAppState.shouldResetState(arguments: base + [option + "graphics-system"]))
        XCTAssertFalse(UITestAppState.shouldResetState(arguments: base + [option + "graphics-system", "--sshapp-reset-state"]))
        XCTAssertTrue(UITestAppState.shouldResetState(arguments: base + [option + "graphics-background", "--sshapp-reset-state"]))
    }

    func testSystemMarkerAvoidsAmbiguousHexDigitsButStillChangesEachSequence() {
        let id = UUID(uuidString: "0FCC1045-710E-4874-A171-EA9353F838EE")!
        let markers = (1...12).map { TerminalSystemMarker.make(runID: id, sequence: $0) }
        XCTAssertEqual(Set(markers).count, 12)
        XCTAssertTrue(markers.allSatisfy { $0.hasPrefix("LIFE SYS ") && !$0.contains(where: \.isNumber) })
    }

    func testSystemGeometryKeepsFullDisplayAndOffsetWindowDistinct() {
        let display = CGRect(x: 0, y: 0, width: 1366, height: 1024)
        let window = CGRect(x: 210, y: 100, width: 900, height: 700)
        let terminal = CGRect(x: 210, y: 220, width: 900, height: 580)
        XCTAssertTrue(TerminalSystemGeometry.valid(display: display, window: window, terminal: terminal))
        XCTAssertNotEqual(display, window, "Never use a floating window as the full screenshot extent")
        XCTAssertEqual(TerminalSystemGeometry.displayRect(display: display, containing: window), display)
        let portrait = CGRect(x: 0, y: 0, width: 1024, height: 1366)
        XCTAssertEqual(TerminalSystemGeometry.displayRect(display: portrait,
            containing: CGRect(x: 100, y: 200, width: 700, height: 800)), portrait)
        XCTAssertNil(TerminalSystemGeometry.displayRect(display: window, containing: display))
        let resized = CGRect(x: 210, y: 100, width: 700, height: 600)
        XCTAssertFalse(TerminalSystemGeometry.valid(display: display, window: resized, terminal: terminal),
                       "Old terminal bounds are not current resize evidence")
        XCTAssertFalse(TerminalSystemGeometry.valid(display: window, window: display, terminal: terminal))
        XCTAssertFalse(TerminalSystemGeometry.valid(display: display, window: window, terminal: .zero))
        XCTAssertFalse(TerminalSystemGeometry.valid(display: display, window: window,
            terminal: CGRect(x: CGFloat.nan, y: 0, width: 50, height: 50)))
    }

    func testSystemSceneEventFilterRejectsProcessAndUnrelatedNotifications() {
        for name in [UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification,
                     UIScene.willEnterForegroundNotification, UIScene.didActivateNotification,
                     UIScene.didDisconnectNotification] {
            XCTAssertTrue(TerminalSystemEventFilter.accepts(expectedID: "original", observedID: "original", name: name))
            XCTAssertFalse(TerminalSystemEventFilter.accepts(expectedID: "original", observedID: "other", name: name))
            XCTAssertFalse(TerminalSystemEventFilter.accepts(expectedID: "original", observedID: nil, name: name))
        }
        XCTAssertFalse(TerminalSystemEventFilter.accepts(expectedID: nil, observedID: nil,
            name: UIScene.didDisconnectNotification))
        XCTAssertFalse(TerminalSystemEventFilter.accepts(expectedID: "original", observedID: "original",
            name: UIApplication.didEnterBackgroundNotification))
        // Filter tests call the pure predicate; no fabricated lifecycle notification is posted.
    }

    func testSceneProvenanceRejectsDisconnectedExistingSessionEvenIfItAttachesFirst() {
        let token = UUID()
        let gate = TerminalSystemSceneProvenance(originalID: "original",
            preexistingIDs: ["original", "disconnected-existing"], requestToken: token)
        XCTAssertFalse(gate.accepts(sceneID: "disconnected-existing", deliveredToken: token))
        XCTAssertFalse(gate.accepts(sceneID: "disconnected-existing", deliveredToken: nil))
        XCTAssertFalse(gate.accepts(sceneID: "original", deliveredToken: token))
        XCTAssertFalse(gate.accepts(sceneID: "unrelated-new", deliveredToken: nil))
        XCTAssertFalse(gate.accepts(sceneID: "unrelated-new", deliveredToken: UUID()))
        XCTAssertFalse(gate.accepts(sceneID: "", deliveredToken: token))
        XCTAssertTrue(gate.accepts(sceneID: "requested-new", deliveredToken: token))
    }

    func testProcessRecorderOwnerBoxDoesNotExtendOwnerLifetime() {
        var object: NSObject? = NSObject()
        let box = TerminalSystemAcceptanceRecorder.WeakOwner(object!)
        XCTAssertNotNil(box.value)
        object = nil
        XCTAssertNil(box.value)
    }

    func testTerminalOwnerWitnessIsWeakAndMissingRendererIsNotDrainEvidence() {
        var terminal: UITerminalView? = UITerminalView(frame: .zero)
        let witness = terminal!.systemAcceptanceOwners()
        XCTAssertFalse(witness.sample().hostReleased)
        XCTAssertFalse(witness.sample().observedInactiveDrain)
        terminal = nil
        let released = witness.sample()
        XCTAssertTrue(released.hostReleased)
        XCTAssertTrue(released.contentReleased)
        XCTAssertTrue(released.sessionReleased)
        XCTAssertTrue(released.rendererReleased)
        XCTAssertFalse(released.observedInactiveDrain, "Nil owners must never manufacture a successful drain sample")
        XCTAssertNil(released.pending)
        XCTAssertNil(released.inFlight)
    }

    func testTerminalOwnerWitnessRequiresNewDrainAfterCloseObservation() throws {
        let renderer = try VTMetalRenderer(font: .monospacedSystemFont(ofSize: 12, weight: .regular))
        let witness = TerminalSystemAcceptanceOwners(host: nil, content: nil, session: nil, renderer: renderer)
        XCTAssertFalse(witness.sample().observedInactiveDrain, "Initial renderer suspension predates observation")
        renderer.setActive(true)
        renderer.setActive(false)
        XCTAssertTrue(witness.sample().observedInactiveDrain)

        witness.beginCloseObservation()
        XCTAssertFalse(witness.sample().observedInactiveDrain, "A prior switcher drain is not close evidence")
        renderer.setActive(true)
        renderer.setActive(false)
        XCTAssertTrue(witness.sample().observedInactiveDrain, "A new real suspension drain is evidence")
    }

    func testTerminalOwnerWitnessPreservesRealDrainAfterRendererFacadeRelease() async throws {
        let layout = try VTLayout(generation: 1, width: 300, height: 120,
                                  cellWidth: 10, cellHeight: 20, scale: 2, padding: 0)
        let native = try VTTerminal(layout: layout)
        _ = try await native.ingest(Data("close drain witness".utf8))
        let frame = try await native.snapshot()
        _ = try await native.retire()

        do {
            var renderer: VTMetalRenderer? = try VTMetalRenderer(
                font: .monospacedSystemFont(ofSize: 12, weight: .regular))
            weak let releasedRenderer = renderer
            weak let pipeline = renderer?.pipelineForTesting
            weak let layer = renderer?.presentationLayer
            // Isolate the renderer owner without inventing scene notifications or
            // retaining a host. The ordinary facade deinit must perform retirement.
            let witness = TerminalSystemAcceptanceOwners(host: nil, content: nil, session: nil, renderer: renderer)
            witness.beginCloseObservation()
            let held = expectation(description: "GPU complete with presentation still held")
            var lease: CheckedContinuation<Void, Never>?
            defer {
                renderer = nil
                lease?.resume()
            }
            pipeline?.publicationHoldForTesting = {
                await withCheckedContinuation {
                    lease = $0
                    held.fulfill()
                }
            }
            renderer?.setActive(true)
            renderer?.submit(frame, presentation: .init())
            await fulfillment(of: [held], timeout: 5)
            _ = try XCTUnwrap(lease)
            XCTAssertEqual(pipeline?.inFlightCount, 1)
            XCTAssertEqual(pipeline?.diagnostics.gpuCompletedFrames, 1)
            XCTAssertFalse(witness.sample().observedInactiveDrain)

            renderer = nil
            XCTAssertNil(releasedRenderer)
            XCTAssertNotNil(pipeline, "Only the held work should keep the pipeline alive")
            XCTAssertEqual(pipeline?.isActive, false)
            XCTAssertEqual(pipeline?.pendingCount, 0)
            XCTAssertEqual(pipeline?.inFlightCount, 1)
            XCTAssertTrue(witness.sample().rendererReleased)
            XCTAssertFalse(witness.sample().observedInactiveDrain, "Facade release is not drain evidence")

            lease?.resume()
            lease = nil
            // Deliberately do not sample until both the facade and its real work
            // have released: this reproduces the interval missed by close polling.
            let deadline = Date().addingTimeInterval(5)
            while (pipeline != nil || layer != nil) && Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertNil(pipeline, "Scalar diagnostics must not retain the pipeline")
            XCTAssertNil(layer, "Scalar diagnostics must not retain presentation resources")
            let drained = witness.sample()
            XCTAssertTrue(drained.rendererReleased)
            XCTAssertTrue(drained.observedInactiveDrain)
            XCTAssertEqual(drained.pending, 0)
            XCTAssertEqual(drained.inFlight, 0)

            witness.beginCloseObservation()
            let reset = witness.sample()
            XCTAssertFalse(reset.observedInactiveDrain, "Released owners cannot reuse a prior close drain")
            XCTAssertNil(reset.pending)
            XCTAssertNil(reset.inFlight)
        }
    }

    func testFinalPanPresentedAfterReleaseCannotCountAsMomentumMovement() {
        let id = UUID()
        // UIKit .ended last presented offset 100/revision 10. The native final
        // release reaches offset 90/revision 11 before starting the display link.
        let release = VTPointerReleaseBoundary(pointerID: 1, terminalID: id,
            generation: 1, revision: 11, offset: 90, totalRows: 200, rows: 20)
        func accepted(revision: UInt64, offset: UInt64) -> Bool {
            TerminalLifecycleMomentumGate.acceptsMovement(release: release, terminalID: id,
                generation: 1, revision: revision, offset: offset, awayFromBottom: true)
        }
        XCTAssertFalse(accepted(revision: 10, offset: 100))
        XCTAssertFalse(accepted(revision: 11, offset: 90), "Late final-pan presentation is not momentum")
        XCTAssertFalse(accepted(revision: 12, offset: 90), "Output plus no-op momentum is not movement")
        XCTAssertFalse(accepted(revision: 11, offset: 89), "A newer native revision is mandatory")
        XCTAssertTrue(accepted(revision: 12, offset: 89))
        XCTAssertFalse(TerminalLifecycleMomentumGate.acceptsMovement(release: release,
            terminalID: UUID(), generation: 1, revision: 12, offset: 89, awayFromBottom: true))
        XCTAssertFalse(TerminalLifecycleMomentumGate.acceptsMovement(release: release,
            terminalID: id, generation: 2, revision: 12, offset: 89, awayFromBottom: true))
    }

    func testNaturalStopRejectsCancellationAndVisibilityRequiresPositiveVelocity() {
        func accepted(_ cause: TerminalLifecycleMomentumSample.StopCause?, _ velocity: Double,
                      interrupted: Bool = false) -> Bool {
            TerminalLifecycleMomentumGate.acceptsStop(interrupted: interrupted, cause: cause,
                velocityX: 0, velocityY: velocity)
        }
        XCTAssertTrue(accepted(.deceleration, 49))
        XCTAssertFalse(accepted(.deceleration, 50))
        XCTAssertFalse(accepted(.cancelled, 49))
        XCTAssertFalse(accepted(.visibility, 49))
        XCTAssertFalse(accepted(nil, 0))
        XCTAssertTrue(accepted(.visibility, 500, interrupted: true))
        XCTAssertFalse(accepted(.visibility, 49, interrupted: true))
        XCTAssertFalse(accepted(.deceleration, 49, interrupted: true))
        XCTAssertFalse(accepted(.cancelled, 500, interrupted: true))
        XCTAssertFalse(accepted(.deceleration, .nan))
    }

    func testFirstFailureIsStickyAndBounded() {
        var status = TerminalLifecycleAcceptanceFixture.Status(scenario: .graphicsBackground)
        status.recordFailure(String(repeating: "x", count: 300))
        status.recordFailure("late foreground completion")
        XCTAssertEqual(status.failure, String(repeating: "x", count: 256))
        XCTAssertEqual(status.phase, "error")
    }

    func testManualCaptureOptInIsExactAndOnlyAffectsGraphicsSystemObservation() {
        let flag = TerminalLifecycleManualPolicy.launchArgument
        for scenario in [TerminalLifecycleScenario.graphicsBackground, .graphicsSystem, .scrollMomentum] {
            XCTAssertEqual(TerminalLifecycleManualPolicy.captureEnabled(scenario: scenario,
                arguments: base + [option + scenario.rawValue, flag]), scenario == .graphicsSystem)
            XCTAssertFalse(TerminalLifecycleManualPolicy.captureEnabled(scenario: scenario, arguments: base))
            XCTAssertFalse(TerminalLifecycleManualPolicy.captureEnabled(scenario: scenario, arguments: [flag + "=true"]))
        }
        XCTAssertEqual(TerminalLifecycleManualPolicy.observationSeconds(manualCapture: false), 5 * 60)
        XCTAssertEqual(TerminalLifecycleManualPolicy.observationSeconds(manualCapture: true), 30 * 60)
    }

    func testManualSeedAndAdvanceRequireTheirOwnPhaseAndRejectBusyOrFailedState() {
        for phase in ["idle", "systemUpdating", "systemReady", "error"] {
            for ready in [false, true] {
                for busy in [false, true] {
                    for failure: String? in [nil, "advanceContract"] {
                        XCTAssertEqual(TerminalLifecycleManualPolicy.seedEnabled(modelReady: ready,
                            phase: phase, busy: busy, failure: failure),
                            ready && phase == "idle" && !busy && failure == nil)
                        XCTAssertEqual(TerminalLifecycleManualPolicy.advanceEnabled(phase: phase,
                            busy: busy, failure: failure), phase == "systemReady" && !busy && failure == nil)
                    }
                }
            }
        }
    }

    func testManualLabelShowsPhaseSequenceReadinessAndStickyFailure() {
        XCTAssertEqual(TerminalLifecycleManualPolicy.label(phase: "idle", sequence: 0,
            modelReady: false, busy: false, failure: nil, captureError: nil),
            "idle · seq 0 · waiting for terminal")
        XCTAssertEqual(TerminalLifecycleManualPolicy.label(phase: "systemUpdating", sequence: 2,
            modelReady: true, busy: true, failure: nil, captureError: nil), "systemUpdating · seq 2 · busy")
        var status = TerminalLifecycleAcceptanceFixture.Status(scenario: .graphicsSystem)
        status.recordFailure("advanceContract")
        status.recordFailure("systemObservationExceededFiveMinutes")
        XCTAssertEqual(TerminalLifecycleManualPolicy.label(phase: status.phase, sequence: 0,
            modelReady: true, busy: true, failure: status.failure, captureError: "write failed"),
            "error · seq 0\nFAIL: advanceContract\nCAPTURE: write failed")
        XCTAssertEqual(status.failure, "advanceContract", "Manual capture must never clear the first contract failure")
    }

    func testManualCaptureUsesStableRunFilenameAndAtMostOneWritePerSecond() throws {
        let status = TerminalLifecycleAcceptanceFixture.Status(scenario: .graphicsSystem)
        let bytes = try JSONEncoder().encode(status)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(TerminalLifecycleManualPolicy.captureFilename(runID: status.runID),
            "TerminalCapture-\(try XCTUnwrap(json["runID"] as? String)).json")
        XCTAssertNil(json["captureError"], "Ordinary automation status has no new capture-error key")
        XCTAssertEqual(TerminalLifecycleManualPolicy.captureDelay(now: 100, lastWrite: nil), 0)
        XCTAssertEqual(TerminalLifecycleManualPolicy.captureDelay(now: 100, lastWrite: 100), 1)
        XCTAssertEqual(TerminalLifecycleManualPolicy.captureDelay(now: 100.25, lastWrite: 100), 0.75)
        XCTAssertEqual(TerminalLifecycleManualPolicy.captureDelay(now: 101, lastWrite: 100), 0)
        XCTAssertEqual(TerminalLifecycleManualPolicy.captureDelay(now: 200, lastWrite: 100), 0)
    }

    func testStatusDecodingPreservesRecordedSchemaAndRunIdentity() throws {
        let status = TerminalLifecycleAcceptanceFixture.Status(scenario: .graphicsSystem)
        let data = try JSONEncoder().encode(status)
        let decoded = try JSONDecoder().decode(TerminalLifecycleAcceptanceFixture.Status.self, from: data)
        XCTAssertEqual(decoded.schema, status.schema)
        XCTAssertEqual(decoded.runID, status.runID)
        XCTAssertEqual(decoded.scenario, status.scenario)

        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        record["schema"] = 2
        let changedData = try JSONSerialization.data(withJSONObject: record)
        let changed = try JSONDecoder().decode(TerminalLifecycleAcceptanceFixture.Status.self, from: changedData)
        XCTAssertEqual(changed.schema, 2, "Decoding must retain the recorded schema instead of substituting the current one")
        XCTAssertEqual(changed.runID, status.runID)
    }

    func testBackgroundAttemptRecordsActualQueryAndEveryRejectedClauseWithoutAcceptingIt() throws {
        let id = UUID()
        let seeded = VTLifecycleEngineScalars(terminalID: id, cachedImageBytes: 256, processNativeImageBytes: 256)
        let queried = VTLifecycleEngineScalars(terminalID: id, cachedImageBytes: 0, processNativeImageBytes: 256)
        let sample = TerminalLifecyclePresentationSample(hostID: "host", contentID: "content", sessionID: "session",
            active: false, epoch: 8, hasFrame: false, extractions: 8, renderCompletions: 3,
            renderedRevision: nil, rendererDiagnostics: nil, metal: true, rendererActive: false,
            pending: 0, inFlight: 0, frame: nil)
        func attempt(epoch: UInt64 = 7, applicationState: UIApplication.State = .background,
                     expired: Bool = false, priorFailure: Bool = false) -> TerminalLifecycleAcceptanceFixture.BackgroundAttempt {
            .init(cycle: 1, expectedCycle: 1, expectedEpoch: epoch, applicationState: applicationState,
                expired: expired, priorFailure: priorFailure, identityMatches: true,
                notificationTime: 100, checkpointTime: 100.1, sample: sample, engine: queried, expectedEngine: seeded)
        }
        let mismatch = attempt()
        XCTAssertEqual(mismatch.failedReasons, ["epoch"])
        XCTAssertFalse(TerminalLifecycleCheckpointGate.accepts(cycle: mismatch.cycle,
            expectedCycle: mismatch.expectedCycle, epoch: sample.epoch, expectedEpoch: mismatch.expectedEpoch,
            background: true, expired: false, samplePresent: true), "Diagnostics must not relax the epoch gate")
        XCTAssertEqual(attempt(epoch: 8).failedReasons, [])
        XCTAssertEqual(attempt(applicationState: .active, expired: true, priorFailure: true).failedReasons,
            ["epoch", "applicationState", "expired", "priorFailure"])
        var status = TerminalLifecycleAcceptanceFixture.Status(scenario: .graphicsBackground)
        status.engine = seeded
        let before = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(status)) as? [String: Any])
        XCTAssertNil(before["backgroundAttempt"], "Other scenarios gain no placeholder diagnostic")
        status.backgroundAttempt = mismatch
        let data = try JSONEncoder().encode(status)
        XCTAssertLessThan(data.count, 8192)
        let decoded = try JSONDecoder().decode(TerminalLifecycleAcceptanceFixture.Status.self, from: data)
        XCTAssertEqual(decoded.engine?.cachedImageBytes, 256)
        XCTAssertEqual(decoded.backgroundAttempt?.engine.cachedImageBytes, 0)
        XCTAssertEqual(decoded.backgroundAttempt?.expectedEpoch, 7)
        XCTAssertEqual(decoded.backgroundAttempt?.sample?.epoch, 8)
        XCTAssertEqual(decoded.backgroundAttempt?.applicationState, UIApplication.State.background.rawValue)
        XCTAssertEqual(decoded.backgroundAttempt?.failedReasons, ["epoch"])
    }

    func testBackgroundCheckpointRejectsStaleLateExpiredAndMissingEvidence() {
        func accepts(cycle: Int = 2, epoch: UInt64 = 7, background: Bool = true,
                     expired: Bool = false, present: Bool = true) -> Bool {
            TerminalLifecycleCheckpointGate.accepts(cycle: cycle, expectedCycle: 2,
                epoch: epoch, expectedEpoch: 7, background: background, expired: expired, samplePresent: present)
        }
        XCTAssertTrue(accepts())
        XCTAssertFalse(accepts(cycle: 1))
        XCTAssertFalse(accepts(cycle: 3))
        XCTAssertFalse(accepts(epoch: 6))
        XCTAssertFalse(accepts(epoch: 8))
        XCTAssertFalse(accepts(background: false))
        XCTAssertFalse(accepts(expired: true))
        XCTAssertFalse(accepts(present: false))
    }
}
#endif
