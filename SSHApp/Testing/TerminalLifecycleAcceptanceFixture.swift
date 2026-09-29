#if DEBUG && !targetEnvironment(macCatalyst)
import GhosttyTerminal
import GhosttyVT
import OSLog
import SwiftUI
import UIKit

/// Pure checkpoint gate shared with deterministic regressions. A late foreground
/// query is never relabeled as background evidence.
enum TerminalLifecycleCheckpointGate {
    static func accepts(cycle: Int, expectedCycle: Int, epoch: UInt64, expectedEpoch: UInt64,
                        background: Bool, expired: Bool, samplePresent: Bool) -> Bool {
        cycle == expectedCycle && cycle > 0 && epoch == expectedEpoch
            && background && !expired && samplePresent
    }
}

/// Presentation after UIKit .ended can still be the final pan frame. Only a
/// newer revision beyond the native final-release viewport proves momentum.
enum TerminalLifecycleMomentumGate {
    static func acceptsMovement(release: VTPointerReleaseBoundary, terminalID: UUID,
                                generation: UInt64, revision: UInt64, offset: UInt64,
                                awayFromBottom: Bool) -> Bool {
        terminalID == release.terminalID && generation == release.generation
            && revision > release.revision && offset < release.offset && awayFromBottom
    }

    static func acceptsStop(interrupted: Bool, cause: TerminalLifecycleMomentumSample.StopCause?,
                            velocityX: Double, velocityY: Double) -> Bool {
        guard velocityX.isFinite, velocityY.isFinite else { return false }
        let belowThreshold = abs(velocityX) < 50 && abs(velocityY) < 50
        return interrupted ? cause == .visibility && !belowThreshold
            : cause == .deceleration && belowThreshold
    }
}

/// Manual controls and capture policy only; production and automated deadlines
/// are unchanged. The launch opt-in has no effect outside graphics-system.
enum TerminalLifecycleManualPolicy {
    static let launchArgument = "--sshapp-ui-test-system-capture"

    static func captureEnabled(scenario: TerminalLifecycleScenario, arguments: [String]) -> Bool {
        scenario == .graphicsSystem && arguments.contains(launchArgument)
    }

    static func observationSeconds(manualCapture: Bool) -> Int { manualCapture ? 1800 : 300 }

    static func seedEnabled(modelReady: Bool, phase: String, busy: Bool, failure: String?) -> Bool {
        modelReady && phase == "idle" && !busy && failure == nil
    }

    static func advanceEnabled(phase: String, busy: Bool, failure: String?) -> Bool {
        phase == "systemReady" && !busy && failure == nil
    }

    static func label(phase: String, sequence: Int, modelReady: Bool, busy: Bool,
                      failure: String?, captureError: String?) -> String {
        var text = "\(phase) · seq \(sequence)"
        if let failure { text += "\nFAIL: \(failure)" }
        else if busy { text += " · busy" }
        else if !modelReady { text += " · waiting for terminal" }
        if let captureError { text += "\nCAPTURE: \(captureError)" }
        return text
    }

    static func captureDelay(now: TimeInterval, lastWrite: TimeInterval?) -> TimeInterval {
        guard let lastWrite else { return 0 }
        return max(0, 1 - (now - lastWrite))
    }

    static func captureFilename(runID: UUID) -> String { "TerminalCapture-\(runID.uuidString).json" }
}

struct TerminalLifecycleAcceptanceFixture: UIViewRepresentable {
    let model: TerminalSelectionUITestHarnessModel
    let scenario: TerminalLifecycleScenario
    func makeUIView(context: Context) -> Probe { Probe(model: model, scenario: scenario) }
    func updateUIView(_ view: Probe, context: Context) {}
    static func dismantleUIView(_ view: Probe, coordinator: ()) { view.stop() }

    struct BackgroundCheckpoint: Codable {
        let cycle: Int
        let notificationTime: Double
        let checkpointTime: Double
        let sample: TerminalLifecyclePresentationSample
        let engine: VTLifecycleEngineScalars
    }
    /// One bounded scalar observation, replaced each cycle. Unlike `engine`,
    /// this records the actual background query even when the boundary rejects it.
    struct BackgroundAttempt: Codable {
        let cycle: Int
        let expectedCycle: Int
        let expectedEpoch: UInt64
        let applicationState: Int
        let expired: Bool
        let priorFailure: Bool
        let identityMatches: Bool
        let notificationTime: Double
        let checkpointTime: Double
        let sample: TerminalLifecyclePresentationSample?
        let engine: VTLifecycleEngineScalars
        let expectedEngine: VTLifecycleEngineScalars?
        let failedReasons: [String]

        init(cycle: Int, expectedCycle: Int, expectedEpoch: UInt64,
             applicationState: UIApplication.State, expired: Bool, priorFailure: Bool,
             identityMatches: Bool, notificationTime: Double, checkpointTime: Double,
             sample: TerminalLifecyclePresentationSample?, engine: VTLifecycleEngineScalars,
             expectedEngine: VTLifecycleEngineScalars?) {
            self.cycle = cycle
            self.expectedCycle = expectedCycle
            self.expectedEpoch = expectedEpoch
            self.applicationState = applicationState.rawValue
            self.expired = expired
            self.priorFailure = priorFailure
            self.identityMatches = identityMatches
            self.notificationTime = notificationTime
            self.checkpointTime = checkpointTime
            self.sample = sample
            self.engine = engine
            self.expectedEngine = expectedEngine
            // Diagnostic only: the acceptance guard below remains authoritative.
            failedReasons = [
                (cycle == expectedCycle, "cycle"), (cycle > 0, "positiveCycle"),
                (sample != nil, "missingSample"), (sample?.epoch == expectedEpoch, "epoch"),
                (applicationState == .background, "applicationState"),
                (!expired, "expired"), (!priorFailure, "priorFailure"),
                (sample?.active == false, "active"), (sample?.hasFrame == false, "hasFrame"),
                (sample?.rendererActive == false, "rendererActive"),
                (sample?.inFlight == 0, "inFlight"), (sample?.pending == 0, "pending"),
                (engine.cachedImageBytes == 0, "cachedImageBytes"),
                (engine.terminalID == expectedEngine?.terminalID, "terminalID"),
                (engine.processNativeImageBytes == expectedEngine?.processNativeImageBytes, "nativeImageBytes"),
                (identityMatches, "identity")
            ].compactMap { accepted, reason in accepted ? nil : reason }
        }
    }
    struct MomentumEvidence: Codable {
        var begins = 0, changes = 0, ends = 0, panWrites = 0, momentumWrites = 0
        var start: TerminalLifecycleMomentumSample?
        var lastTick: TerminalLifecycleMomentumSample?
        var stop: TerminalLifecycleMomentumSample?
        var release: VTPointerReleaseBoundary?
        var panReleasePresentation: TerminalLifecycleFrameSample?
        var moved: TerminalLifecycleFrameSample?
        var anchored: TerminalLifecycleFrameSample?
        var final: TerminalLifecycleFrameSample?
        var interrupted = false
        var hidden: TerminalLifecyclePresentationSample?
        var revealed: TerminalLifecyclePresentationSample?
    }
    struct Status: Codable {
        let schema: Int
        let runID: UUID
        let scenario: TerminalLifecycleScenario
        var phase = "idle"
        var failure: String?
        var captureError: String?
        var cycle = 0
        var writes = 0
        var clientWriteHex = ""
        var initial: TerminalLifecyclePresentationSample?
        var current: TerminalLifecyclePresentationSample?
        var engine: VTLifecycleEngineScalars?
        var checkpoints: [BackgroundCheckpoint] = []
        var backgroundAttempt: BackgroundAttempt?
        var momentum: [MomentumEvidence] = []
        var screen: CGRect?
        var terminalRect: CGRect?
        var placements: [CGRect] = []
        // System mode uses the full display for screenshots and records window
        // geometry separately. Legacy modes keep their existing contract.
        var windowRect: CGRect?
        var sceneID: String?
        var supportsMultipleScenes: Bool?
        var systemSequence = 0
        var systemMarker: String?
        var systemMarkerRect: CGRect?
        var systemEvents: [TerminalSystemAcceptanceRecorder.Event] = []
        var sceneClose: TerminalSystemAcceptanceRecorder.CloseEvidence?

        init(scenario: TerminalLifecycleScenario) {
            schema = 1
            runID = UUID()
            self.scenario = scenario
        }

        mutating func recordFailure(_ reason: String) {
            failure = failure ?? String(reason.prefix(256))
            phase = "error"
        }
    }

    @MainActor
    final class Probe: UIStackView {
        private let model: TerminalSelectionUITestHarnessModel
        private let label = UILabel()
        private var actionButtons: [String: UIButton] = [:]
        private let manualCapture: Bool
        private var captureTask: Task<Void, Never>?
        private var pendingCapture: Data?
        private var lastCaptureWrite: TimeInterval?
        private let captureLogger = Logger(subsystem: "dev.sshapp.sshapp", category: "TerminalCapture")
        private var state: Status
        private weak var terminal: UITerminalView?
        private weak var pan: UIPanGestureRecognizer?
        private var task: Task<Void, Never>?
        private var watchdog: Task<Void, Never>?
        private var systemPoll: Task<Void, Never>?
        private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
        private var backgroundEpoch: UInt64?
        private var baseline: TerminalLifecyclePresentationSample?
        private var panActive = false, momentumActive = false, expired = false
        private var round = 0, outputLine = 1600

        init(model: TerminalSelectionUITestHarnessModel, scenario: TerminalLifecycleScenario) {
            self.model = model
            manualCapture = TerminalLifecycleManualPolicy.captureEnabled(
                scenario: scenario, arguments: ProcessInfo.processInfo.arguments)
            state = Status(scenario: scenario)
            super.init(frame: .zero)
            axis = .vertical
            let colors = TerminalConfiguration().foreground("#ffffff").background("#000000")
            TerminalRuntime.shared.controller.setTheme(TerminalTheme(light: colors, dark: colors))
            label.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            label.numberOfLines = 0
            label.accessibilityIdentifier = "terminal.lifecycle.status"
            addArrangedSubview(label)
            let buttons = UIStackView()
            buttons.distribution = .fillEqually
            let actions = scenario == .graphicsSystem
                ? [("Seed", "seed"), ("Advance", "advance"), ("New scene", "createScene"), ("Close created", "closeScene")]
                : [("Seed", "seed"), ("Replace", "replace"), ("Second fling", "second")]
            for (title, action) in actions {
                let button = UIButton(type: .system)
                button.setTitle(title, for: .normal)
                button.accessibilityIdentifier = "terminal.lifecycle." + action
                button.addAction(UIAction { [weak self] _ in self?.perform(action) }, for: .touchUpInside)
                actionButtons[action] = button
                buttons.addArrangedSubview(button)
            }
            addArrangedSubview(buttons)
            NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground),
                name: UIApplication.didEnterBackgroundNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(didBecomeActive),
                name: UIApplication.didBecomeActiveNotification, object: nil)
            report()
        }
        required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        deinit { task?.cancel(); watchdog?.cancel(); systemPoll?.cancel(); captureTask?.cancel() }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard state.scenario == .graphicsSystem, let window, let scene = window.windowScene else { return }
            state.sceneID = scene.session.persistentIdentifier
            state.supportsMultipleScenes = UIApplication.shared.supportsMultipleScenes
            TerminalSystemAcceptanceRecorder.shared.register(window: window, model: model)
            guard systemPoll == nil else { return }
            // Weak across every suspension; no diagnostic task can own a scene.
            let manual = manualCapture
            let seconds = TerminalLifecycleManualPolicy.observationSeconds(manualCapture: manual)
            let deadline = ProcessInfo.processInfo.systemUptime + Double(seconds)
            systemPoll = Task { [weak self] in
                for _ in 0..<(seconds * 10) {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    guard self != nil else { return }
                    // Manual capture also expires across time suspended in the background.
                    if manual && ProcessInfo.processInfo.systemUptime >= deadline { break }
                    self?.refreshSystem()
                }
                self?.fail(manual ? "systemCaptureExceededThirtyMinutes" : "systemObservationExceededFiveMinutes")
            }
        }

        private func refreshSystem() {
            let recorder = TerminalSystemAcceptanceRecorder.shared
            recorder.refresh()
            state.sceneClose = recorder.close
            if let id = state.sceneID { state.systemEvents = recorder.events(for: id) }
            // A requested new scene gets an independent production terminal and
            // native image before it is eligible for the close request.
            if state.phase == "idle", state.sceneID == recorder.close.createdID,
               model.phase == .ready, task == nil { perform("seed") }
            geometry()
            report()
        }

        func stop() {
            task?.cancel(); watchdog?.cancel(); systemPoll?.cancel(); systemPoll = nil
            captureTask?.cancel(); captureTask = nil; pendingCapture = nil
            pan?.removeTarget(self, action: #selector(observePan(_:)))
            terminal?.lifecycleMomentumObserver = nil
            terminal?.recordsLifecycleAcceptanceRenders = false
            NotificationCenter.default.removeObserver(self)
            endBackgroundTask()
        }
        private func endBackgroundTask() {
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
        }
        private func findTerminal(_ root: UIView) -> UITerminalView? {
            if let view = root as? UITerminalView { return view }
            for child in root.subviews { if let view = findTerminal(child) { return view } }
            return nil
        }
        private func perform(_ action: String) {
            // Keep rejected programmatic actions explicit; UI gating is not a
            // substitute for the contract checks below or a reason to clear failure.
            defer { report() }
            guard state.failure == nil else { return }
            if state.scenario == .graphicsSystem {
                if action == "createScene", state.phase == "systemReady", let scene = window?.windowScene {
                    TerminalSystemAcceptanceRecorder.shared.create(from: scene)
                    refreshSystem(); return
                }
                if action == "closeScene" {
                    TerminalSystemAcceptanceRecorder.shared.closeCreated()
                    refreshSystem(); return
                }
                if action == "advance" {
                    guard state.phase == "systemReady", task == nil else { fail("advanceContract"); return }
                    state.phase = "systemUpdating"
                    task = Task { [weak self] in await self?.advanceSystem() }
                    return
                }
            }
            if action == "second" {
                guard state.phase == "anchored", state.momentum.count == 1 else { fail("secondContract"); return }
                round = 1
                state.momentum.append(.init())
                state.phase = "secondReady"
                report()
                return
            }
            guard task == nil else { fail("actionWhileBusy"); return }
            if action == "replace" {
                guard state.scenario == .graphicsBackground, state.phase == "resumed" else { fail("replacementContract"); return }
                task = Task { [weak self] in await self?.replace() }
            } else {
                guard state.phase == "idle" || (state.phase == "replaced" && state.cycle < 3),
                      model.phase == .ready, let window, let view = findTerminal(window),
                      let sample = view.lifecycleAcceptanceSample, sample.metal,
                      let frame = sample.frame, frame.layout.rows >= 16, frame.layout.columns >= 32 else {
                    fail("seedContractOrMissingMetal"); return
                }
                terminal = view
                view.recordsLifecycleAcceptanceRenders = true
                if state.initial == nil { state.initial = sample }
                if state.scenario == .graphicsSystem {
                    if let id = state.sceneID {
                        TerminalSystemAcceptanceRecorder.shared.bind(terminal: view, sceneID: id)
                    }
                    state.phase = "systemUpdating"
                    task = Task { [weak self] in await self?.advanceSystem() }
                } else {
                    task = Task { [weak self] in await self?.seed() }
                }
            }
        }
        private func seed() async {
            do {
                if state.cycle == 0 {
                    let history = (0..<1600).map { String(format: "LIFE%05d", $0) }.joined(separator: "\r\n")
                    try await write("\u{1B}[?1000l\u{1B}[?1002l\u{1B}[?1003l\u{1B}[?1006l\u{1B}[?1004l\u{1B}[?25l\u{1B}[0m\u{1B}[2J\u{1B}[H" + history, expectedMarker: "LIFE01599")
                }
                if state.scenario == .graphicsBackground {
                    try await write("\u{1B}[2J" + graphics(red: true) + "\u{1B}[14;1HLIFE ORIGINAL", expectedMarker: "LIFE ORIGINAL")
                    guard let query = terminal?.enqueueLifecycleAcceptanceQuery() else { throw Failure.missingQuery }
                    let engine = try await query.value
                    guard engine.cachedImageBytes > 0, engine.processNativeImageBytes > 0 else { throw Failure.missingImage }
                    if let previous = state.engine, previous.terminalID != engine.terminalID { throw Failure.identity }
                    state.engine = engine
                    baseline = terminal?.lifecycleAcceptanceSample
                    geometry()
                    state.phase = "seeded"
                } else {
                    guard let terminal, let recognizer = terminal.lifecycleAcceptancePan else { throw Failure.missingPan }
                    pan = recognizer
                    recognizer.addTarget(self, action: #selector(observePan(_:)))
                    terminal.lifecycleMomentumObserver = { [weak self] sample in self?.observeMomentum(sample) }
                    state.momentum = [.init()]
                    geometry()
                    state.phase = "flingReady"
                }
                task = nil
                report()
            } catch { fail("seed: \(error)") }
        }
        private func advanceSystem() async {
            do {
                guard state.systemSequence < 12 else { throw Failure.priorFailure }
                state.systemSequence += 1
                let marker = TerminalSystemMarker.make(runID: state.runID, sequence: state.systemSequence)
                try await write("\u{1B}[?1000l\u{1B}[?1002l\u{1B}[?1003l\u{1B}[?1006l\u{1B}[?1004l\u{1B}[?25l\u{1B}[0m\u{1B}[2J"
                    + graphics(red: state.systemSequence % 2 == 1) + "\u{1B}[14;1H" + marker,
                    expectedMarker: marker)
                guard let query = terminal?.enqueueLifecycleAcceptanceQuery() else { throw Failure.missingQuery }
                let engine = try await query.value
                guard engine.cachedImageBytes > 0, engine.processNativeImageBytes > 0,
                      let sample = terminal?.lifecycleAcceptanceSample, sameIdentity(sample),
                      sample.frame?.terminalID == state.initial?.frame?.terminalID else { throw Failure.identity }
                state.engine = engine
                state.systemMarker = marker
                geometry()
                state.phase = "systemReady"; task = nil; report()
            } catch { fail("systemAdvance: \(error)") }
        }

        /// Two opaque, non-overlapping placements. Replacement uses the same
        /// native image ID; no query responses or client writes are permitted.
        private func graphics(red: Bool) -> String {
            let rgba: [UInt8] = red ? [220, 20, 30, 255] : [20, 30, 220, 255]
            let pixels = Data((0..<64).flatMap { _ in rgba }).base64EncodedString()
            return "\u{1B}[2;2H\u{1B}_Ga=T,f=32,s=8,v=8,i=71,p=1,c=8,r=4,C=1,q=2;\(pixels)\u{1B}\\"
                + "\u{1B}[8;14H\u{1B}_Ga=p,i=71,p=2,c=8,r=4,C=1,q=2\u{1B}\\"
        }
        private func replace() async {
            do {
                try await write(graphics(red: false) + "\u{1B}[14;1HLIFE REPLACED", expectedMarker: "LIFE REPLACED")
                state.phase = "replaced"; task = nil; report()
            } catch { fail("replacement: \(error)") }
        }
        @objc private func didEnterBackground() {
            guard state.scenario == .graphicsBackground, state.failure == nil else { return }
            guard state.phase == "seeded", state.cycle < 3, task == nil,
                  let sample = terminal?.lifecycleAcceptanceSample,
                  !sample.active, !sample.hasFrame, !sample.rendererActive else {
                fail("productionDidNotDeactivateBeforeBackground"); return
            }
            state.cycle += 1
            let cycle = state.cycle, epoch = sample.epoch, notificationTime = ProcessInfo.processInfo.systemUptime
            backgroundEpoch = epoch
            expired = false
            // Production already synchronously enqueued release on resign/deactivate.
            // Admit now, before yielding, behind any already-admitted extraction.
            guard let query = terminal?.enqueueLifecycleAcceptanceQuery() else { fail("missingBackgroundQuery"); return }
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "lifecycle-scalar-checkpoint") { [weak self] in
                MainActor.assumeIsolated {
                    self?.expired = true
                    self?.fail("backgroundTaskExpired")
                    self?.endBackgroundTask()
                }
            }
            watchdog = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self else { return }
                expired = true
                fail("backgroundCheckpointTimeout")
                endBackgroundTask()
            }
            task = Task { [weak self] in
                guard let self else { return }
                defer { watchdog?.cancel(); watchdog = nil; endBackgroundTask(); task = nil }
                do {
                    let engine = try await query.value
                    try await waitUntil {
                        guard let sample = self.terminal?.lifecycleAcceptanceSample else { return false }
                        return sample.inFlight == 0 && sample.pending == 0
                    }
                    let observedSample = terminal?.lifecycleAcceptanceSample
                    let applicationState = UIApplication.shared.applicationState
                    let attempt = BackgroundAttempt(cycle: cycle, expectedCycle: state.cycle,
                        expectedEpoch: epoch, applicationState: applicationState,
                        expired: expired, priorFailure: state.failure != nil,
                        identityMatches: observedSample.map { sameIdentity($0) } ?? false,
                        notificationTime: notificationTime, checkpointTime: ProcessInfo.processInfo.systemUptime,
                        sample: observedSample, engine: engine, expectedEngine: state.engine)
                    state.backgroundAttempt = attempt
                    guard let sample = observedSample,
                          TerminalLifecycleCheckpointGate.accepts(cycle: cycle, expectedCycle: state.cycle,
                            epoch: sample.epoch, expectedEpoch: epoch,
                            background: applicationState == .background,
                            expired: expired || state.failure != nil, samplePresent: true),
                          !sample.active, !sample.hasFrame, !sample.rendererActive,
                          sample.inFlight == 0, sample.pending == 0,
                          engine.cachedImageBytes == 0, engine.terminalID == state.engine?.terminalID,
                          engine.processNativeImageBytes == state.engine?.processNativeImageBytes,
                          sameIdentity(sample) else {
                        fail("background: backgroundBoundary[\(attempt.failedReasons.joined(separator: ","))]")
                        return
                    }
                    state.checkpoints.append(.init(cycle: cycle, notificationTime: notificationTime,
                        checkpointTime: ProcessInfo.processInfo.systemUptime, sample: sample, engine: engine))
                    state.phase = "backgroundLatched"
                    report()
                } catch { fail("background: \(error)") }
            }
        }
        @objc private func didBecomeActive() {
            guard state.scenario == .graphicsBackground, backgroundEpoch != nil, state.failure == nil else { return }
            guard state.phase == "backgroundLatched", state.checkpoints.last?.cycle == state.cycle,
                  task == nil, let baseline else { fail("foregroundBeforeCheckpoint"); return }
            backgroundEpoch = nil
            task = Task { [weak self] in
                guard let self else { return }
                do {
                    try await waitUntil {
                        guard let sample = self.terminal?.lifecycleAcceptanceSample else { return false }
                        return sample.active && sample.hasFrame && sample.renderedRevision == sample.frame?.revision
                            && sample.extractions > baseline.extractions
                            && sample.renderCompletions > baseline.renderCompletions
                    }
                    guard let sample = terminal?.lifecycleAcceptanceSample, sameIdentity(sample),
                          sample.frame?.terminalID == state.engine?.terminalID,
                          sample.frame?.totalRows == baseline.frame?.totalRows,
                          sample.frame?.markers == baseline.frame?.markers else { throw Failure.identity }
                    state.phase = "resumed"; task = nil; report()
                } catch { fail("resume: \(error)") }
            }
        }
        @objc private func observePan(_ recognizer: UIPanGestureRecognizer) {
            guard state.failure == nil, recognizer === pan, state.momentum.indices.contains(round) else { return }
            switch recognizer.state {
            case .began:
                guard state.phase == (round == 0 ? "flingReady" : "secondReady"), task == nil else { fail("unexpectedPan"); return }
                state.momentum[round].begins += 1
                panActive = true
                state.phase = "panning"
                task = Task { [weak self] in await self?.pacedOutput() }
            case .changed:
                guard panActive else { fail("changedAfterRelease"); return }
                state.momentum[round].changes += 1
            case .ended:
                panActive = false
                state.momentum[round].ends += 1
                state.momentum[round].panReleasePresentation = terminal?.lifecycleAcceptanceSample?.frame
            case .cancelled, .failed:
                if !state.momentum[round].interrupted { fail("panCancelled") }
            default: break
            }
            report()
        }
        private func observeMomentum(_ sample: TerminalLifecycleMomentumSample) {
            guard state.failure == nil, state.momentum.indices.contains(round) else { return }
            switch sample.kind {
            case .started:
                guard !panActive, state.momentum[round].ends == 1,
                      state.momentum[round].start == nil,
                      let release = sample.releaseBoundary,
                      release.terminalID == state.initial?.frame?.terminalID else {
                    fail("momentumBeforeReleaseOrMissingNativeBoundary"); return
                }
                state.momentum[round].release = release
                momentumActive = true
                state.momentum[round].start = sample
            case .tick:
                guard momentumActive, !panActive, state.momentum[round].stop == nil,
                      sample.generation == state.momentum[round].start?.generation else { fail("invalidMomentumTick"); return }
                state.momentum[round].lastTick = sample
                if let presentation = terminal?.lifecycleAcceptanceSample,
                   let frame = presentation.frame, presentation.renderedRevision == frame.revision,
                   let release = state.momentum[round].release,
                   TerminalLifecycleMomentumGate.acceptsMovement(release: release,
                       terminalID: frame.terminalID, generation: frame.layout.generation,
                       revision: frame.revision, offset: frame.offset, awayFromBottom: frame.awayFromBottom),
                   frame.topMarker != state.momentum[round].panReleasePresentation?.topMarker,
                   frame.topMarker.hasPrefix("LIFE") {
                    state.momentum[round].moved = frame
                }
                if round == 1, sample.ticks >= 3, state.momentum[round].moved != nil,
                   state.momentum[round].momentumWrites > 0, !state.momentum[round].interrupted {
                    state.momentum[round].interrupted = true
                    // The existing production host visibility path cancels the
                    // pointer lease and momentum. Never invoke stop/scroll here.
                    terminal?.isHostVisible = false
                    state.momentum[round].hidden = terminal?.lifecycleAcceptanceSample
                }
            case .stopped:
                guard momentumActive else { fail("stopWithoutStart"); return }
                guard TerminalLifecycleMomentumGate.acceptsStop(
                    interrupted: round == 1 && state.momentum[round].interrupted,
                    cause: sample.stopCause, velocityX: sample.velocityX, velocityY: sample.velocityY),
                    (round == 0 || state.momentum[round].interrupted) else {
                    fail("unexpectedMomentumStopCause"); return
                }
                momentumActive = false
                state.momentum[round].stop = sample
            }
            report()
        }
        private func pacedOutput() async {
            do {
                for _ in 0..<160 {
                    try await writeNextLine()
                    if panActive { state.momentum[round].panWrites += 1 }
                    if momentumActive { state.momentum[round].momentumWrites += 1 }
                    if state.momentum[round].stop != nil { break }
                    try await Task.sleep(for: .milliseconds(80))
                }
                let evidence = state.momentum[round]
                guard evidence.begins == 1, evidence.changes > 2, evidence.ends == 1,
                      evidence.panWrites > 0, evidence.momentumWrites > 0,
                      let tick = evidence.lastTick, tick.ticks > 1, evidence.stop != nil,
                      evidence.moved != nil else { throw Failure.missingMomentum }
                if round == 1 {
                    guard evidence.interrupted, evidence.hidden?.active == false,
                          evidence.hidden?.hasFrame == false else { throw Failure.interruption }
                    try await Task.sleep(for: .milliseconds(250))
                    guard state.momentum[round].lastTick?.ticks == tick.ticks else { throw Failure.interruption }
                    terminal?.isHostVisible = true
                    try await waitUntil { self.terminal?.lifecycleAcceptanceSample?.active == true && self.terminal?.lifecycleAcceptanceSample?.hasFrame == true }
                    guard let revealed = terminal?.lifecycleAcceptanceSample, sameIdentity(revealed),
                          revealed.frame?.terminalID == state.initial?.frame?.terminalID else { throw Failure.identity }
                    state.momentum[round].revealed = revealed
                    state.phase = "interrupted"
                } else {
                    // Let the last native scroll completion reach presentation.
                    try await Task.sleep(for: .milliseconds(250))
                    guard let anchor = terminal?.lifecycleAcceptanceSample?.frame,
                          anchor.awayFromBottom, anchor.topMarker.hasPrefix("LIFE") else { throw Failure.anchor }
                    state.momentum[round].anchored = anchor
                    for _ in 0..<5 {
                        try await writeNextLine()
                        try await Task.sleep(for: .milliseconds(80))
                        guard let current = terminal?.lifecycleAcceptanceSample?.frame,
                              current.offset == anchor.offset, current.topMarker == anchor.topMarker,
                              current.awayFromBottom, state.momentum[round].lastTick?.ticks == tick.ticks else { throw Failure.anchor }
                    }
                    guard let final = terminal?.lifecycleAcceptanceSample?.frame,
                          final.totalRows > anchor.totalRows else { throw Failure.anchor }
                    state.momentum[round].final = final
                    state.phase = "anchored"
                }
                task = nil; report()
            } catch { fail("momentum: \(error)") }
        }
        private func writeNextLine() async throws {
            outputLine += 1
            try await write(String(format: "\r\nLIFE%05d", outputLine), requirePresentation: terminal?.isHostVisible == true, requiresRowProgress: true)
        }
        private func write(_ output: String, requirePresentation: Bool = true,
                           expectedMarker: String? = nil, requiresRowProgress: Bool = false) async throws {
            let before = terminal?.lifecycleAcceptanceSample
            guard let channel = model.transport.snapshot().activeChannelIDs.first,
                  await model.transport.deliverServerData(Data(output.utf8), to: channel) else { throw Failure.delivery }
            state.writes += 1
            if requirePresentation {
                try await waitUntil {
                    guard let sample = self.terminal?.lifecycleAcceptanceSample else { return false }
                    // Hidden interruption may happen while a write is awaiting a
                    // frame. Its bytes still flow through production ingestion.
                    if self.round == 1 && self.state.momentum.last?.interrupted == true { return true }
                    let markerAccepted = expectedMarker.map { marker in
                        sample.frame?.bottomMarker == marker || sample.frame?.markers.contains(marker) == true
                    } ?? true
                    let progressed = !requiresRowProgress || (sample.frame?.totalRows ?? 0) > (before?.frame?.totalRows ?? 0)
                    return sample.frame?.revision != before?.frame?.revision
                        && sample.renderCompletions > (before?.renderCompletions ?? 0)
                        && sample.renderedRevision == sample.frame?.revision && markerAccepted && progressed
                }
            }
            guard model.transport.snapshot().capturedClientWrites.allSatisfy({ $0.data.isEmpty }) else { throw Failure.clientWrite }
        }
        private func waitUntil(_ condition: () -> Bool) async throws {
            for _ in 0..<160 {
                try Task.checkCancellation()
                if state.failure != nil { throw Failure.priorFailure }
                if condition() { return }
                try await Task.sleep(for: .milliseconds(25))
            }
            throw Failure.timeout
        }
        private func sameIdentity(_ sample: TerminalLifecyclePresentationSample) -> Bool {
            sample.hostID == state.initial?.hostID && sample.contentID == state.initial?.contentID
                && sample.sessionID != nil && sample.sessionID == state.initial?.sessionID
        }
        private func geometry() {
            guard let window, let terminal, let frame = terminal.lifecycleAcceptanceSample?.frame else { return }
            func screen(_ rect: CGRect) -> CGRect {
                window.convert(terminal.convert(rect, to: window), to: window.screen.coordinateSpace)
            }
            let windowRect = window.convert(window.bounds, to: window.screen.coordinateSpace)
            state.windowRect = windowRect
            state.screen = state.scenario == .graphicsSystem
                ? TerminalSystemGeometry.displayRect(display: window.screen.coordinateSpace.bounds, containing: windowRect)
                : windowRect
            state.terminalRect = screen(terminal.bounds)
            if state.scenario == .graphicsSystem,
               !TerminalSystemGeometry.valid(display: window.screen.coordinateSpace.bounds,
                   window: windowRect, terminal: screen(terminal.bounds)) {
                // During a real OS resize, layout may be between generations.
                // Do not publish stale pixel rectangles as usable evidence.
                state.placements = []
                return
            }
            if state.scenario == .graphicsSystem, let marker = state.systemMarker {
                let cell = frame.layout.rect(column: 0, row: 13, width: marker.count + 1)
                state.systemMarkerRect = screen(cell.insetBy(dx: 0, dy: -2).intersection(terminal.bounds))
            }
            state.placements = [(1, 1), (13, 7)].map { column, row in
                let cell = frame.layout.rect(column: column, row: row)
                return screen(CGRect(x: cell.minX, y: cell.minY,
                    width: frame.layout.cellWidth * 8, height: frame.layout.cellHeight * 4).insetBy(dx: 3, dy: 3))
            }
        }
        private enum Failure: Error {
            case delivery, timeout, identity, missingQuery, missingImage, missingPan,
                 missingMomentum, interruption, anchor, clientWrite, priorFailure
        }
        private func fail(_ reason: String) {
            state.recordFailure(reason)
            task?.cancel()
            report()
        }
        private func report() {
            state.current = terminal?.lifecycleAcceptanceSample
            let writes = model.transport.snapshot().capturedClientWrites.reduce(into: Data()) { $0.append($1.data) }
            state.clientWriteHex = writes.prefix(128).map { String(format: "%02x", $0) }.joined()
            if !writes.isEmpty { state.recordFailure("unexpectedClientWrite") }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if state.failure != nil { state.phase = "error" }
            if let bytes = try? encoder.encode(state), bytes.count < 65_536 {
                // Preserve the automation AX JSON; capture reuses the same bounded bytes.
                label.accessibilityValue = String(decoding: bytes, as: UTF8.self)
                scheduleCapture(bytes)
            } else {
                state.recordFailure("statusEncoding")
                label.accessibilityValue = "{\"schema\":1,\"phase\":\"error\",\"failure\":\"statusEncoding\"}"
            }
            label.text = TerminalLifecycleManualPolicy.label(phase: state.phase,
                sequence: state.systemSequence, modelReady: model.phase == .ready,
                busy: task != nil, failure: state.failure, captureError: state.captureError)
            if state.scenario == .graphicsSystem {
                actionButtons["seed"]?.isEnabled = TerminalLifecycleManualPolicy.seedEnabled(
                    modelReady: model.phase == .ready, phase: state.phase, busy: task != nil, failure: state.failure)
                actionButtons["advance"]?.isEnabled = TerminalLifecycleManualPolicy.advanceEnabled(
                    phase: state.phase, busy: task != nil, failure: state.failure)
            }
        }

        private func scheduleCapture(_ bytes: Data) {
            guard manualCapture, state.captureError == nil else { return }
            pendingCapture = bytes // At most one latest, already-bounded snapshot; never an event backlog.
            guard captureTask == nil else { return }
            let delay = TerminalLifecycleManualPolicy.captureDelay(
                now: ProcessInfo.processInfo.systemUptime, lastWrite: lastCaptureWrite)
            captureTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                self?.writeCapture()
            }
        }

        private func writeCapture() {
            captureTask = nil
            guard let bytes = pendingCapture else { return }
            pendingCapture = nil
            lastCaptureWrite = ProcessInfo.processInfo.systemUptime
            do {
                let documents = try FileManager.default.url(for: .documentDirectory,
                    in: .userDomainMask, appropriateFor: nil, create: true)
                let url = documents.appendingPathComponent(
                    TerminalLifecycleManualPolicy.captureFilename(runID: state.runID))
                try bytes.write(to: url, options: .atomic)
            } catch {
                // One visible diagnostic, no retry/report loop, no lifecycle failure
                // mutation, and no environment, credential, or arbitrary error payload.
                let error = error as NSError
                state.captureError = "write failed (\(error.domain):\(error.code))"
                captureLogger.error("Terminal capture write failed: \(error.domain, privacy: .public):\(error.code)")
                report()
            }
        }
    }
}
#endif
