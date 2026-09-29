#if DEBUG
import Foundation
import GhosttyTerminal
import SwiftUI
import UIKit

enum TerminalSelectionHarnessPhase: String, Codable {
    case awaitingStart
    case mounting
    case waitingForMetrics
    case opening
    case feeding
    case ready
    case failed
}

/// Loupe-only launch gate. No terminal, setup timeout, channel open, or fixture
/// delivery is allowed until the UI driver explicitly starts a settled scene.
struct TerminalLoupeStartupGeometry: Codable, Equatable {
    let sceneID: String
    let attachmentID: String
    let interfaceOrientation: Int
    let foregroundActive: Bool
    let keyWindow: Bool
    let sceneBounds: CGRect
    let windowBounds: CGRect
    let viewportBounds: CGRect
    let safeAreaFrame: CGRect
}

struct TerminalLoupeStartupGate: Codable, Equatable {
    let requestedInterfaceOrientation: Int
    private(set) var geometry: TerminalLoupeStartupGeometry?
    private(set) var stableSince: TimeInterval?
    private(set) var canStart = false
    private(set) var startRequested = false
    private(set) var mountedGeometry: TerminalLoupeStartupGeometry?

    init(orientation: UIInterfaceOrientation) {
        requestedInterfaceOrientation = orientation.rawValue
    }

    static func requestedOrientation(arguments: [String]) -> UIInterfaceOrientation? {
        guard arguments.contains("--sshapp-ui-test-terminal-loupe") else { return nil }
        let prefix = "--sshapp-ui-test-terminal-loupe-orientation="
        return arguments.first { $0.hasPrefix(prefix) }
            .flatMap { Int($0.dropFirst(prefix.count)) }
            .flatMap(UIInterfaceOrientation.init(rawValue:)) ?? .portrait
    }

    mutating func observe(_ sample: TerminalLoupeStartupGeometry?, now: TimeInterval) {
        guard !startRequested else { return }
        if sample != geometry {
            stableSince = nil
        }
        geometry = sample
        guard let sample, accepts(sample) else {
            stableSince = nil
            canStart = false
            return
        }
        if stableSince == nil { stableSince = now }
        canStart = now - (stableSince ?? now) >= 0.5
    }

    mutating func requestStart(_ sample: TerminalLoupeStartupGeometry?, now: TimeInterval) -> Bool {
        guard !startRequested else { return false }
        // Re-sample at the button action; a previously enabled button is not proof.
        observe(sample, now: now)
        guard canStart else { return false }
        startRequested = true
        return true
    }

    mutating func confirmMount(_ sample: TerminalLoupeStartupGeometry?) -> Bool {
        guard startRequested, let sample, accepts(sample), sample == geometry else { return false }
        mountedGeometry = sample
        return true
    }

    private func accepts(_ sample: TerminalLoupeStartupGeometry) -> Bool {
        sample.interfaceOrientation == requestedInterfaceOrientation
            && sample.interfaceOrientation != UIInterfaceOrientation.unknown.rawValue
            && sample.foregroundActive && sample.keyWindow
            && [sample.sceneBounds, sample.windowBounds].allSatisfy {
                ($0.width > $0.height)
                    == (UIInterfaceOrientation(rawValue: requestedInterfaceOrientation)?.isLandscape == true)
            }
            && [sample.sceneBounds, sample.windowBounds, sample.viewportBounds].allSatisfy {
                $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0
            }
    }
}

struct TerminalSelectionGridAnchor: Codable, Equatable {
    let column: Int
    let row: Int
}

struct TerminalSelectionFixture: Codable, Equatable {
    static let line = "ALPHA BRAVO CHARLIE DELTA ECHO"

    let rows: Int
    let columns: Int
    let fixtureRow: Int
    let anchors: [String: TerminalSelectionGridAnchor]
    let expectedStrings: [String: String]

    var bytes: Data {
        let fixtureLineRow = fixtureRow + 1
        let cursor = anchors["cursor"] ?? TerminalSelectionGridAnchor(column: 1, row: 1)
        let cursorRow = cursor.row + 1
        let cursorColumn = cursor.column + 1
        return Data(
            ("\u{1B}[2J\u{1B}[H\u{1B}[\(fixtureLineRow);1H\(Self.line)"
                + "\u{1B}[\(cursorRow);\(cursorColumn)H").utf8
        )
    }

    static func make(rows: Int, columns: Int) throws -> Self {
        guard rows >= 5 else {
            throw TerminalSelectionHarnessError(
                "Measured grid has \(rows) rows; terminal selection fixture requires at least 5"
            )
        }
        guard columns >= line.utf8.count + 2 else {
            throw TerminalSelectionHarnessError(
                "Measured grid has \(columns) columns; terminal selection fixture requires at least "
                    + "\(line.utf8.count + 2)"
            )
        }

        let row = min(max(rows / 2, 2), rows - 3)
        let cursorColumn = min(max(columns / 2, 2), columns - 3)
        let anchors = [
            "alphaCenter": TerminalSelectionGridAnchor(column: 2, row: row),
            "bravoLeading": TerminalSelectionGridAnchor(column: 6, row: row),
            "bravoCenter": TerminalSelectionGridAnchor(column: 8, row: row),
            "bravoTrailing": TerminalSelectionGridAnchor(column: 10, row: row),
            "charlieLeading": TerminalSelectionGridAnchor(column: 12, row: row),
            "charlieCenter": TerminalSelectionGridAnchor(column: 15, row: row),
            "charlieTrailing": TerminalSelectionGridAnchor(column: 18, row: row),
            "deltaLeading": TerminalSelectionGridAnchor(column: 20, row: row),
            "deltaCenter": TerminalSelectionGridAnchor(column: 22, row: row),
            "deltaTrailing": TerminalSelectionGridAnchor(column: 24, row: row),
            "echoCenter": TerminalSelectionGridAnchor(column: 27, row: row),
            "bravoRangeStart": TerminalSelectionGridAnchor(column: 6, row: row),
            "bravoRangeEnd": TerminalSelectionGridAnchor(column: 10, row: row),
            "bravoThroughCharlieEnd": TerminalSelectionGridAnchor(column: 18, row: row),
            "bravoThroughDeltaEnd": TerminalSelectionGridAnchor(column: 24, row: row),
            "safeOutsideSelection": TerminalSelectionGridAnchor(column: 1, row: row - 2),
            "cursor": TerminalSelectionGridAnchor(column: cursorColumn, row: row - 2),
        ]
        let expectedStrings = [
            "bravo": "BRAVO",
            "bravoThroughCharlie": "BRAVO CHARLIE",
            "bravoThroughDelta": "BRAVO CHARLIE DELTA",
            // Native tracked endpoints are inclusive. Crossing the logical
            // start past CHARLIE's final cell preserves that fixed end cell.
            "charlieLastCellThroughDelta": "E DELTA",
            "fullLine": line,
        ]
        return Self(
            rows: rows,
            columns: columns,
            fixtureRow: row,
            anchors: anchors,
            expectedStrings: expectedStrings
        )
    }
}

private struct TerminalSelectionHarnessError: Error, LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

private struct TerminalSelectionOpenArguments: Codable {
    let terminalType: String
    let columns: Int
    let rows: Int
}

private struct TerminalSelectionResizeArguments: Codable {
    let columns: Int
    let rows: Int
}

struct TerminalSelectionGenerationLatches: Codable {
    let generation: Int
    var latestSnapshotRevision: UInt64 = 0
    var sawGridReady = false
    var sawPostFlushDraw = false
    var sawSelectionGestureActive = false
    var sawLoupeVisible = false
    var sawAdjustingStart = false
    var sawAdjustingEnd = false
    var sawMouseCaptured = false
    var sawSurfaceRetirementCleanup = false
    var interruptionTriggerSnapshotRevision: UInt64?
}

private struct TerminalSelectionTransportStatus: Codable {
    let schemaVersion: Int
    let eventRevision: UInt64
    let openArguments: TerminalSelectionOpenArguments?
    let latestResize: TerminalSelectionResizeArguments?
    let activeChannelCount: Int
    let pendingCallbackCount: Int
    let pendingRequestCount: Int
    let clientWriteHex: String
    let ledger: [String]
}

private struct TerminalSelectionFixtureStatus: Codable {
    let schemaVersion: Int
    let generation: Int
    let phase: TerminalSelectionHarnessPhase
    let scenario: String
    let error: String?
    let actualRows: Int?
    let actualColumns: Int?
    let fixture: TerminalSelectionFixture?
    let transportEventRevision: UInt64
    let openArguments: TerminalSelectionOpenArguments?
    let latestResize: TerminalSelectionResizeArguments?
    let clientWriteHex: String
    let interruptionArmed: Bool
    let interruptionFired: Bool
    let interruptionComplete: Bool
    let interruptionOutcome: String?
    let triggeringSnapshot: TerminalSelectionDebugSnapshot?
    let latestPackageSnapshot: TerminalSelectionDebugSnapshot?
    let generationLatches: [TerminalSelectionGenerationLatches]
    let imeEnabled: Bool
    let imeOutputDelivered: Bool
    let imeOutputTitle: String
    let imeOutputComplete: Bool
    let layoutFlushRevision: Int
    let flushedTerminalWidth: Double?
    let flushedTerminalHeight: Double?
    let loupeStartup: TerminalLoupeStartupGate?
    let setupRestartCount: Int
    /// Timestamped setup timeline (ms since model init): mount, grid changes,
    /// open/resize/feed, post-flush draw chain, restarts, ready/fail.
    let setupEvents: [String]
}

/// Network-free app-side fixture for XCUITest terminal touch-selection gestures.
/// The terminal itself is the production `GhosttyTerminalView`; all output enters
/// through `ScriptedSSHChannelTransport -> SSHChannel`.
struct TerminalSelectionUITestHarnessView: View {
    @State private var model = TerminalSelectionUITestHarnessModel(
        scenarioArgument: UITestAppState.terminalSelectionScenarioArgument,
        loupeStartupOrientation: TerminalLoupeStartupGate.requestedOrientation(
            arguments: ProcessInfo.processInfo.arguments
        )
    )
    @State private var fontSizeTargetRegistry = TerminalFontSizeTargetRegistry()
    @State private var keyboardBarTarget = TerminalKeyboardBarTarget()
    @State private var imeKeyboardSuppressed = true

    var body: some View {
        let _ = UITestStartupTrace.record("harness.body", once: true)
        VStack(spacing: 0) {
            controls
            #if !targetEnvironment(macCatalyst)
            switch UITestAppState.terminalLifecycleArgument {
            case .success(let scenario):
                if let scenario {
                    TerminalLifecycleAcceptanceFixture(model: model, scenario: scenario)
                        .frame(height: 64)
                }
            case .failure(let error):
                Text(error.description).accessibilityIdentifier("terminal.lifecycle.error")
            }
            if ProcessInfo.processInfo.arguments.contains("--sshapp-ui-test-terminal-loupe") {
                TerminalLoupeAcceptanceFixture(model: model)
                    .frame(height: 64)
            }
            #endif
            if model.loupeStartup != nil {
                ZStack {
                    Color.clear
                    if model.shouldMountTerminal {
                        terminal
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { TerminalLoupeStartupProbe(model: model) }
            } else {
                terminal
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        #if !targetEnvironment(macCatalyst)
        .onContinueUserActivity(TerminalSystemAcceptanceRecorder.activityType) { activity in
            guard case .success(.graphicsSystem) = UITestAppState.terminalLifecycleArgument else { return }
            TerminalSystemAcceptanceRecorder.shared.receive(activity: activity, for: model)
        }
        #endif
        .onAppear { UITestStartupTrace.record("harness.appear", once: true) }
        .background(Color(uiColor: TerminalRuntime.shared.terminalBackgroundColor))
        // Selection keeps its fixed grid; the opt-in IME scenario uses real
        // keyboard safe-area resizing and the production host keyboard bar.
        .ignoresSafeArea(.keyboard, edges: model.imeEnabled ? [] : .bottom)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.imeEnabled && !imeKeyboardSuppressed {
                TerminalKeyboardBar(target: keyboardBarTarget) {
                    keyboardBarTarget.suppressSoftwareKeyboard()
                    imeKeyboardSuppressed = true
                }
            }
        }
        .background {
            if case .success(.graphicsSystem) = UITestAppState.terminalLifecycleArgument {
                // Exactly the production policy; legacy acceptance modes remain unchanged.
                PrivacyScreenObserver().frame(width: 1, height: 1)
            }
            if model.imeEnabled {
                TerminalIMEInputDocumentProbe().frame(width: 1, height: 1)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            if model.imeEnabled {
                Button("Keyboard") {
                    model.requestIMEKeyboard()
                    keyboardBarTarget.restoreSoftwareKeyboard()
                    imeKeyboardSuppressed = false
                }
                .accessibilityIdentifier("terminal.ime.showKeyboard")
                Button("Output") {
                    model.injectIMEOutput()
                }
                .accessibilityIdentifier("terminal.ime.output")
            }

            if model.phase == .awaitingStart {
                Button("Start loupe") {
                    model.startLoupeFixture()
                }
                .accessibilityIdentifier("terminal.loupe.start")
                .disabled(model.loupeStartup?.canStart != true)
            } else if !model.imeEnabled {
                Button("Arm") {
                    model.armInterruption()
                }
                .accessibilityIdentifier("terminal.selection.armInterruption")

                Button("Reset") {
                    model.resetObservations()
                }
                .accessibilityLabel("Reset observations")
                .accessibilityIdentifier("terminal.selection.resetObservations")

                Button("Flush") {
                    model.flushLayout()
                }
                .accessibilityLabel("Flush layout")
                .accessibilityIdentifier("terminal.selection.flushLayout")

                Button("Remount") {
                    model.resetSurface()
                }
                .accessibilityLabel("Reset surface")
                .accessibilityIdentifier("terminal.selection.resetSurface")
            }

            Spacer(minLength: 4)

            Text(model.phase.rawValue)
                .font(.caption2.monospaced())
                .lineLimit(1)
                .accessibilityLabel("Terminal selection fixture")
                .accessibilityIdentifier("terminal.selection.fixture")
                .accessibilityValue(model.fixtureStatusJSON)

            Text("T")
                .font(.caption2.monospaced())
                .accessibilityLabel("Terminal selection transport")
                .accessibilityIdentifier("terminal.selection.transport")
                .accessibilityValue(model.transportStatusJSON)

            Text(model.interruptionComplete ? "C" : "P")
                .font(.caption2.monospaced())
                .accessibilityLabel("Terminal selection interruption completion")
                .accessibilityIdentifier("terminal.selection.interruptionComplete")
                .accessibilityValue(model.interruptionComplete ? "true" : "false")
        }
        .padding(.horizontal, 8)
        .frame(height: 52)
        .background(.bar)
    }

    private var terminal: some View {
        let generation = model.generation
        return GhosttyTerminalView(
            session: model.session,
            tab: model.tab,
            isHostTabActive: true,
            onShortcut: { _ in },
            onRemoteChannelClosed: { _, reason in
                model.remoteChannelClosed(reason)
            },
            onHostSessionInteraction: {},
            showsKeyboardBar: model.imeEnabled && !imeKeyboardSuppressed,
            suppressesSoftwareKeyboard: !model.imeEnabled || imeKeyboardSuppressed,
            keyboardBarTarget: model.imeEnabled ? keyboardBarTarget : nil,
            hardwareKeyRepeatConfiguration: .default,
            configuredFontSize: Float(TerminalRuntime.shared.fontSize),
            fontSizeTargetRegistry: fontSizeTargetRegistry,
            onPostFlushDraw: {
                model.postFlushDraw(generation: generation)
            },
            terminalSelectionDebugConfiguration: TerminalSelectionDebugConfiguration(
                accessibilityIdentifierPrefix: "terminal.selection",
                // CI automation can take slightly over 0.5 seconds to deliver a
                // nominal tap. Keep it distinct from an intentional long press
                // without changing production gesture timing.
                touchSelectionLongPressMinimumDuration: 1.0,
                snapshotCallback: { snapshot in
                    model.receive(snapshot: snapshot, generation: generation)
                }
            ),
            onPostFlushDrawEvent: { event in
                model.recordSetupEvent("draw.\(event) gen=\(generation)")
            }
        )
        .id(generation)
        .onAppear {
            model.surfaceDidAppear(generation: generation)
        }
    }
}

@MainActor
@Observable
final class TerminalSelectionUITestHarnessModel {
    private static let schemaVersion = 2
    private static let setupTimeout: Duration = .seconds(8)
    /// Bound on grid changes absorbed during setup (e.g. the IME fixture's
    /// software keyboard resizing 79 -> 75 -> 79 -> 76 rows while presenting).
    static let maximumSetupRestarts = 8
    private static let interruptionTimeout: Duration = .seconds(6)
    private static let mouseCaptureBytes = Data("\u{1B}[?1000h\u{1B}[?1006h".utf8)

    let session: SSHSession
    let transport: ScriptedSSHChannelTransport
    let channel: SSHChannel
    let tab: Tab
    let scenario: TerminalSelectionUITestScenario?
    // Delivered to this scene's SwiftUI root, never inferred from connection order.
    @ObservationIgnored var systemSceneRequestToken: UUID?
    let imeEnabled: Bool
    /// Set by the fixture's Keyboard control. Until then the IME fixture's grid
    /// still follows system keyboard chrome the test did not ask for.
    private(set) var imeKeyboardRequested = false
    private(set) var imeOutputRequested = false
    private(set) var imeOutputDelivered = false

    private(set) var generation = 1
    private(set) var phase: TerminalSelectionHarnessPhase = .mounting {
        didSet {
            UITestStartupTrace.record("harness.phase", details: "\(phase.rawValue) generation=\(generation)")
        }
    }
    private(set) var loupeStartup: TerminalLoupeStartupGate?
    @ObservationIgnored var sampleLoupeStartupGeometry: (() -> TerminalLoupeStartupGeometry?)?

    var shouldMountTerminal: Bool {
        loupeStartup == nil || loupeStartup?.startRequested == true
    }
    private(set) var errorText: String?
    private(set) var fixture: TerminalSelectionFixture?
    private(set) var actualRows: Int?
    private(set) var actualColumns: Int?
    private(set) var latestSelectionSnapshot: TerminalSelectionDebugSnapshot?
    private(set) var transportRevision: UInt64 = 0
    private(set) var interruptionArmed = false
    private(set) var interruptionFired = false
    private(set) var interruptionComplete = false
    private(set) var layoutFlushRevision = 0
    private(set) var flushedTerminalSize: CGSize?
    private(set) var interruptionOutcome: String?
    private(set) var triggeringSnapshot: TerminalSelectionDebugSnapshot?
    private(set) var generationLatches: [Int: TerminalSelectionGenerationLatches] = [:]
    /// Setups restarted because the measured grid changed before readiness.
    private(set) var setupRestartCount = 0
    /// Bounded diagnostic timeline published in the fixture status.
    @ObservationIgnored private(set) var setupEvents: [String] = []
    @ObservationIgnored private let setupEventOrigin = ProcessInfo.processInfo.systemUptime
    @ObservationIgnored private var lastRecordedGrid: (columns: Int, rows: Int)?
    static let maximumSetupEvents = 120

    @ObservationIgnored private var setupStartedGeneration: Int?
    /// Identifies the in-flight setup; a restart supersedes older attempts.
    @ObservationIgnored private var setupAttempt = 0
    /// The single shell open, shared by every setup attempt of the model.
    @ObservationIgnored private var channelOpenTask: Task<Void, Error>?
    @ObservationIgnored private(set) var setupTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var interruptionTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var interruptionTriggerGeneration: Int?

    init(
        scenarioArgument:
            Result<TerminalSelectionUITestScenario, TerminalSelectionUITestScenarioArgumentError>,
        loupeStartupOrientation: UIInterfaceOrientation? = nil,
        imeEnabled: Bool = ProcessInfo.processInfo.arguments.contains("--sshapp-ui-test-terminal-ime")
    ) {
        UITestStartupTrace.record("harness.model.init.begin")
        self.imeEnabled = imeEnabled
        let session = SSHSession()
        let transport = ScriptedSSHChannelTransport()
        transport.queueOpenPlan(.succeed)
        let channel = SSHChannel(
            transport: transport,
            owner: session,
            tmuxSettings: .default
        )
        self.session = session
        self.transport = transport
        self.channel = channel
        self.tab = Tab(
            title: "Terminal Selection Harness",
            connectionState: .connected,
            session: session,
            channel: channel,
            terminalGridSize: nil
        )

        switch scenarioArgument {
        case .success(let scenario):
            self.scenario = scenario
        case .failure(let error):
            self.scenario = nil
            phase = .failed
            errorText = error.description
        }
        if let loupeStartupOrientation {
            loupeStartup = TerminalLoupeStartupGate(orientation: loupeStartupOrientation)
            if phase != .failed { phase = .awaitingStart }
        }
        generationLatches[generation] = TerminalSelectionGenerationLatches(
            generation: generation
        )

        transport.setEventObserver { [weak self] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    self?.refreshTransportStatus()
                }
            } else {
                Task { @MainActor [weak self] in
                    self?.refreshTransportStatus()
                }
            }
        }
        refreshTransportStatus()
        UITestStartupTrace.record("harness.model.init.end", details: phase.rawValue)
    }

    deinit {
        setupTimeoutTask?.cancel()
        interruptionTimeoutTask?.cancel()
        transport.setEventObserver(nil)
    }

    var fixtureStatusJSON: String {
        _ = transportRevision
        let transportStatus = makeTransportStatus()
        return encodeJSON(TerminalSelectionFixtureStatus(
            schemaVersion: Self.schemaVersion,
            generation: generation,
            phase: phase,
            scenario: scenario?.rawValue ?? "invalid",
            error: errorText,
            actualRows: actualRows,
            actualColumns: actualColumns,
            fixture: fixture,
            transportEventRevision: transportStatus.eventRevision,
            openArguments: transportStatus.openArguments,
            latestResize: transportStatus.latestResize,
            clientWriteHex: transportStatus.clientWriteHex,
            interruptionArmed: interruptionArmed,
            interruptionFired: interruptionFired,
            interruptionComplete: interruptionComplete,
            interruptionOutcome: interruptionOutcome,
            triggeringSnapshot: triggeringSnapshot,
            latestPackageSnapshot: latestSelectionSnapshot,
            generationLatches: generationLatches.values.sorted {
                $0.generation < $1.generation
            },
            imeEnabled: imeEnabled,
            imeOutputDelivered: imeOutputDelivered,
            imeOutputTitle: tab.title,
            // The trailing OSC title proves native parser acceptance, not pixels.
            // onPostFlushDraw is a readiness/first-drain callback, not per output.
            // The physical IME UI test separately requires visible-marker OCR.
            imeOutputComplete: imeOutputDelivered && tab.title == "IME-OUTPUT-011",
            layoutFlushRevision: layoutFlushRevision,
            flushedTerminalWidth: flushedTerminalSize.map { Double($0.width) },
            flushedTerminalHeight: flushedTerminalSize.map { Double($0.height) },
            loupeStartup: loupeStartup,
            setupRestartCount: setupRestartCount,
            setupEvents: setupEvents
        ))
    }

    var transportStatusJSON: String {
        _ = transportRevision
        return encodeJSON(makeTransportStatus())
    }

    func observeLoupeStartupGeometry(_ geometry: TerminalLoupeStartupGeometry?, now: TimeInterval) {
        guard phase == .awaitingStart else { return }
        loupeStartup?.observe(geometry, now: now)
    }

    func startLoupeFixture() {
        guard phase == .awaitingStart else { return }
        let sample = sampleLoupeStartupGeometry?()
        guard loupeStartup?.requestStart(sample, now: ProcessInfo.processInfo.systemUptime) == true else { return }
        phase = .mounting
    }

    func recordSetupEvent(_ event: String) {
        let milliseconds = Int(((ProcessInfo.processInfo.systemUptime - setupEventOrigin) * 1000).rounded())
        let entry = "+\(milliseconds)ms [\(phase.rawValue)] \(event)"
        if setupEvents.count >= Self.maximumSetupEvents {
            // Keep the start of setup and the latest events around a failure.
            setupEvents.remove(at: Self.maximumSetupEvents / 2)
        }
        setupEvents.append(entry)
    }

    func surfaceDidAppear(generation appearedGeneration: Int) {
        UITestStartupTrace.record("harness.surface.appear", details: "generation=\(appearedGeneration)")
        recordSetupEvent("surface.appear gen=\(appearedGeneration)")
        guard appearedGeneration == generation, phase == .mounting else { return }
        if loupeStartup != nil, loupeStartup?.mountedGeometry == nil {
            // Validate actual UIWindowScene orientation again at mount, before
            // metrics can freeze the grid or start the bounded setup timeout.
            let sample = sampleLoupeStartupGeometry?()
            guard loupeStartup?.confirmMount(sample) == true else {
                fail("Loupe scene geometry/orientation changed before terminal mount")
                return
            }
        }
        beginWaitingForMetrics(generation: appearedGeneration)
    }

    func receive(
        snapshot: TerminalSelectionDebugSnapshot,
        generation snapshotGeneration: Int
    ) {
        guard shouldMountTerminal, phase != .failed,
              generationLatches[snapshotGeneration] != nil
        else { return }
        updateLatches(with: snapshot, generation: snapshotGeneration)
        guard snapshotGeneration == generation else { return }
        latestSelectionSnapshot = snapshot
        recordGridChangeIfNeeded(snapshot)
        triggerInterruptionIfNeeded(from: snapshot, generation: snapshotGeneration)
        restartSetupIfMetricsChanged(generation: snapshotGeneration)
        startSetupIfMetricsAreReady(generation: snapshotGeneration)
        evaluateReadiness(generation: snapshotGeneration)
        evaluateInterruptionCompletion(snapshot: snapshot)
    }

    func postFlushDraw(generation flushGeneration: Int) {
        recordSetupEvent("postFlushDraw gen=\(flushGeneration) current=\(generation)")
        guard shouldMountTerminal, flushGeneration == generation, phase != .failed else { return }
        updateLatch(generation: flushGeneration) { latch in
            latch.sawPostFlushDraw = true
        }
        evaluateReadiness(generation: flushGeneration)
    }

    /// Ends the post-ready resize window: from here on grid changes come from
    /// the keyboard the test requested and must not reset the fixture.
    func requestIMEKeyboard() {
        recordSetupEvent("ime.keyboardRequested")
        imeKeyboardRequested = true
    }

    /// One bounded incoming burst, never a client write or synthetic input.
    func injectIMEOutput() {
        guard imeEnabled, phase == .ready, !imeOutputRequested,
              let channelID = transport.snapshot().activeChannelIDs.first else { return }
        guard let snapshot = latestSelectionSnapshot,
              (snapshot.gridRows ?? 0) >= 2,
              Int(snapshot.gridColumns ?? 0) > "IME-OUTPUT-011".utf8.count else {
            fail("IME output requires a visible marker row and sufficient columns")
            return
        }
        imeOutputRequested = true
        // Update one visible row without scrolling the keyboard-reduced viewport
        // or relocating the saved preedit cursor. Only the final marker survives.
        let bytes = Data(("\u{1B}7" + (0..<12).map {
            String(format: "\u{1B}[2;1H\u{1B}[2KIME-OUTPUT-%03d", $0)
        }.joined() + "\u{1B}8\u{1B}]2;IME-OUTPUT-011\u{7}").utf8)
        Task { @MainActor in
            guard await transport.deliverServerData(bytes, to: channelID) else {
                fail("Scripted transport rejected IME output")
                return
            }
            imeOutputDelivered = true
            refreshTransportStatus()
        }
    }

    func armInterruption() {
        guard phase == .ready else {
            fail("Cannot arm interruption while harness phase is \(phase.rawValue)")
            return
        }
        guard scenario == .captureDuringLongPress || scenario == .remountDuringHandleDrag else {
            fail("Scenario \(scenario?.rawValue ?? "invalid") does not support interruption arming")
            return
        }
        guard !interruptionFired else {
            fail("The one-shot interruption has already fired")
            return
        }
        interruptionArmed = true
        interruptionComplete = false
        interruptionOutcome = nil
    }

    func resetObservations() {
        updateLatch(generation: generation) { latch in
            let postFlush = latch.sawPostFlushDraw
            let gridReady = latch.sawGridReady
            let mouseCaptured = latch.sawMouseCaptured
            latch = TerminalSelectionGenerationLatches(generation: generation)
            latch.sawPostFlushDraw = postFlush
            latch.sawGridReady = gridReady
            latch.sawMouseCaptured = mouseCaptured
        }
    }

    /// Applies every pending layout invalidation synchronously, then records the
    /// terminal's bounds. The grid is a pure function of these bounds and the
    /// font, so equal flushed bounds prove no relayout changed the grid.
    func flushLayout() {
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }
        window?.layoutIfNeeded()
        func terminal(in view: UIView) -> UITerminalView? {
            if let terminal = view as? UITerminalView { return terminal }
            return view.subviews.lazy.compactMap(terminal(in:)).first
        }
        flushedTerminalSize = window.flatMap(terminal(in:))?.bounds.size
        layoutFlushRevision += 1
    }

    func resetSurface() {
        guard shouldMountTerminal, phase != .failed else { return }
        beginReplacementGeneration(isInterruption: false)
    }

    func remoteChannelClosed(_ reason: SSHChannelRemoteCloseReason) {
        fail("Scripted terminal channel unexpectedly closed: \(String(reflecting: reason))")
    }

    private func startSetupIfMetricsAreReady(generation setupGeneration: Int) {
        guard setupGeneration == generation,
              phase == .waitingForMetrics,
              setupStartedGeneration != setupGeneration,
              let snapshot = latestSelectionSnapshot,
              snapshot.surfaceReady,
              snapshot.gridReady,
              let columnsValue = snapshot.gridColumns,
              let rowsValue = snapshot.gridRows,
              snapshot.resolvedGridOrigin != nil,
              let cellWidth = snapshot.cellWidthPoints,
              cellWidth > 0,
              let cellHeight = snapshot.cellHeightPoints,
              cellHeight > 0
        else { return }

        let columns = Int(columnsValue)
        let rows = Int(rowsValue)
        setupStartedGeneration = setupGeneration
        setupAttempt += 1
        let attempt = setupAttempt
        actualColumns = columns
        actualRows = rows
        phase = .opening
        recordSetupEvent("setup.start attempt=\(attempt) grid=\(columns)x\(rows)")
        Task { @MainActor [weak self] in
            await self?.performSetup(
                generation: setupGeneration,
                attempt: attempt,
                rows: rows,
                columns: columns
            )
        }
    }

    /// The grid can still change after setup locked its metrics: the IME
    /// fixture's software keyboard shrinks the viewport while it presents.
    /// Readiness requires the live grid to equal the fixture grid, so restart
    /// setup with the new metrics instead of timing out on the stale ones.
    /// On iPad the IME fixture's grid can shrink once more just after ready
    /// (the minimized keyboard's dictation accessory claims the keyboard safe
    /// area: 64 -> 60 -> 59 rows), so it also restarts from ready until the
    /// test requests the software keyboard.
    private func restartSetupIfMetricsChanged(generation candidateGeneration: Int) {
        let acceptsPostReadyResize = imeEnabled && !imeKeyboardRequested
        guard candidateGeneration == generation,
              phase == .opening || phase == .feeding
                || (phase == .ready && acceptsPostReadyResize),
              let snapshot = latestSelectionSnapshot,
              snapshot.surfaceReady,
              snapshot.gridReady,
              let columns = snapshot.gridColumns,
              let rows = snapshot.gridRows,
              Int(columns) != actualColumns || Int(rows) != actualRows
        else { return }
        guard setupRestartCount < Self.maximumSetupRestarts else {
            fail("Terminal grid kept changing during setup; last "
                 + "\(actualColumns ?? 0)x\(actualRows ?? 0) -> \(columns)x\(rows)")
            return
        }
        setupRestartCount += 1
        recordSetupEvent(
            "setup.restart #\(setupRestartCount) from=\(phase.rawValue) "
                + "\(actualColumns ?? 0)x\(actualRows ?? 0) -> \(columns)x\(rows)"
        )
        setupStartedGeneration = nil
        fixture = nil
        actualColumns = nil
        actualRows = nil
        phase = .waitingForMetrics
        scheduleSetupTimeout(for: candidateGeneration)
    }

    private func isCurrentSetup(generation setupGeneration: Int, attempt: Int) -> Bool {
        setupGeneration == generation && attempt == setupAttempt && phase != .failed
    }

    private func performSetup(generation setupGeneration: Int, attempt: Int, rows: Int, columns: Int) async {
        do {
            let fixture = try TerminalSelectionFixture.make(rows: rows, columns: columns)
            guard isCurrentSetup(generation: setupGeneration, attempt: attempt) else { return }
            self.fixture = fixture

            // Only the first attempt opens the shell; a restarted attempt joins
            // that open (never a second channel) and then resizes it below.
            let opensChannel = channelOpenTask == nil && !channel.isOpen
            if !channel.isOpen {
                let open = channelOpenTask ?? Task { @MainActor [channel] in
                    try await channel.openShell(
                        termType: "xterm-256color",
                        cols: columns,
                        rows: rows
                    )
                }
                channelOpenTask = open
                recordSetupEvent("open.await attempt=\(attempt) opens=\(opensChannel)")
                try await open.value
                recordSetupEvent("open.done attempt=\(attempt)")
            }
            guard isCurrentSetup(generation: setupGeneration, attempt: attempt) else { return }

            refreshTransportStatus()
            let snapshotAfterOpen = transport.snapshot()
            guard snapshotAfterOpen.activeChannelIDs.count == 1,
                  let channelID = snapshotAfterOpen.activeChannelIDs.first
            else {
                throw TerminalSelectionHarnessError(
                    "Expected exactly one active scripted channel after open; snapshot: "
                        + "\(String(reflecting: snapshotAfterOpen))"
                )
            }
            guard let openArguments = openArguments(in: snapshotAfterOpen),
                  openArguments.terminalType == "xterm-256color",
                  // A restarted setup reuses the shell opened with the earlier
                  // grid; the resize below must then match the current grid.
                  (setupRestartCount > 0 && !opensChannel)
                    || (openArguments.columns == columns && openArguments.rows == rows)
            else {
                throw TerminalSelectionHarnessError(
                    "Scripted transport open arguments did not match measured \(columns)x\(rows) grid"
                )
            }

            channel.resizeTerminal(cols: columns, rows: rows)
            recordSetupEvent("resize attempt=\(attempt) grid=\(columns)x\(rows)")
            refreshTransportStatus()
            guard transport.snapshot().latestDimensions[channelID]
                == ScriptedSSHChannelTransport.TerminalDimensions(cols: columns, rows: rows)
            else {
                throw TerminalSelectionHarnessError(
                    "Scripted transport did not record matching \(columns)x\(rows) resize"
                )
            }

            phase = .feeding
            recordSetupEvent("feed.start attempt=\(attempt) bytes=\(fixture.bytes.count)")
            guard await transport.deliverServerData(fixture.bytes, to: channelID) else {
                throw TerminalSelectionHarnessError("Scripted transport rejected base fixture delivery")
            }
            recordSetupEvent("feed.delivered attempt=\(attempt)")
            guard isCurrentSetup(generation: setupGeneration, attempt: attempt) else { return }

            if scenario == .mouseCaptured {
                guard await transport.deliverServerData(Self.mouseCaptureBytes, to: channelID) else {
                    throw TerminalSelectionHarnessError(
                        "Scripted transport rejected startup mouse-capture delivery"
                    )
                }
            }
            guard isCurrentSetup(generation: setupGeneration, attempt: attempt) else { return }
            refreshTransportStatus()
            evaluateReadiness(generation: setupGeneration)
            if phase != .ready {
                recordSetupEvent("readiness.pending attempt=\(attempt) \(readinessBlockers(generation: setupGeneration))")
            }
        } catch {
            guard setupGeneration == generation, attempt == setupAttempt else { return }
            fail("Terminal selection setup failed: \(error.localizedDescription)")
        }
    }

    private func evaluateReadiness(generation candidateGeneration: Int) {
        guard candidateGeneration == generation,
              phase == .feeding || phase == .opening,
              let snapshot = latestSelectionSnapshot,
              snapshot.surfaceReady,
              snapshot.gridReady,
              Int(snapshot.gridColumns ?? 0) == actualColumns,
              Int(snapshot.gridRows ?? 0) == actualRows,
              generationLatches[candidateGeneration]?.sawPostFlushDraw == true
        else { return }

        let expectsCapture = scenario == .mouseCaptured
        guard snapshot.isMouseCaptured == expectsCapture else { return }
        phase = .ready
        recordSetupEvent("ready grid=\(actualColumns ?? 0)x\(actualRows ?? 0)")
        setupTimeoutTask?.cancel()
        setupTimeoutTask = nil
        evaluateInterruptionCompletion(snapshot: snapshot)
    }

    private func recordGridChangeIfNeeded(_ snapshot: TerminalSelectionDebugSnapshot) {
        guard snapshot.gridReady,
              let columns = snapshot.gridColumns.map({ Int($0) }),
              let rows = snapshot.gridRows.map({ Int($0) }),
              lastRecordedGrid?.columns != columns || lastRecordedGrid?.rows != rows
        else { return }
        lastRecordedGrid = (columns, rows)
        let viewport = snapshot.terminalViewportBounds
        let bounds = "\(viewport.width)x\(viewport.height)"
        recordSetupEvent("grid \(columns)x\(rows) viewport=\(bounds) surfaceReady=\(snapshot.surfaceReady)")
    }

    /// Which readiness predicate is still false, for timeout diagnostics.
    func readinessBlockers(generation candidateGeneration: Int) -> String {
        var blockers: [String] = []
        if candidateGeneration != generation { blockers.append("staleGeneration") }
        if phase != .feeding && phase != .opening { blockers.append("phase=\(phase.rawValue)") }
        if let snapshot = latestSelectionSnapshot {
            if !snapshot.surfaceReady { blockers.append("surfaceNotReady") }
            if !snapshot.gridReady { blockers.append("gridNotReady") }
            if Int(snapshot.gridColumns ?? 0) != actualColumns || Int(snapshot.gridRows ?? 0) != actualRows {
                blockers.append(
                    "grid=\(Int(snapshot.gridColumns ?? 0))x\(Int(snapshot.gridRows ?? 0))"
                        + "!=\(actualColumns ?? 0)x\(actualRows ?? 0)"
                )
            }
            if snapshot.isMouseCaptured != (scenario == .mouseCaptured) { blockers.append("mouseCapture") }
        } else {
            blockers.append("noSnapshot")
        }
        if generationLatches[candidateGeneration]?.sawPostFlushDraw != true {
            blockers.append("noPostFlushDraw")
        }
        return blockers.isEmpty ? "none" : blockers.joined(separator: ",")
    }

    private func triggerInterruptionIfNeeded(
        from snapshot: TerminalSelectionDebugSnapshot,
        generation triggerGeneration: Int
    ) {
        guard interruptionArmed, !interruptionFired else { return }

        let shouldFire: Bool
        switch scenario {
        case .captureDuringLongPress:
            shouldFire = snapshot.selectionGestureActive
        case .remountDuringHandleDrag:
            shouldFire = snapshot.selectionGestureActive
                && (snapshot.handleMode == .adjustingStart || snapshot.handleMode == .adjustingEnd)
        case .standard, .mouseCaptured, nil:
            shouldFire = false
        }
        guard shouldFire else { return }

        // This callback is emitted only for a semantic package snapshot. Mark the
        // one-shot fired synchronously before scheduling any app-side action.
        interruptionArmed = false
        interruptionFired = true
        interruptionTriggerGeneration = triggerGeneration
        triggeringSnapshot = snapshot
        updateLatch(generation: triggerGeneration) { latch in
            latch.interruptionTriggerSnapshotRevision = snapshot.revision
        }
        scheduleInterruptionTimeout()

        switch scenario {
        case .captureDuringLongPress:
            Task { @MainActor [weak self] in
                await self?.injectCaptureDuringHeldGesture(generation: triggerGeneration)
            }
        case .remountDuringHandleDrag:
            beginReplacementGeneration(isInterruption: true)
        case .standard, .mouseCaptured, nil:
            break
        }
    }

    private func injectCaptureDuringHeldGesture(generation triggerGeneration: Int) async {
        guard triggerGeneration == generation,
              let channelID = transport.snapshot().activeChannelIDs.first
        else {
            fail("Capture interruption could not find the active scripted channel")
            return
        }
        guard await transport.deliverServerData(Self.mouseCaptureBytes, to: channelID) else {
            fail("Capture interruption delivery was rejected by scripted transport")
            return
        }
        guard triggerGeneration == generation, phase != .failed else { return }
        refreshTransportStatus()
        if let snapshot = latestSelectionSnapshot {
            evaluateInterruptionCompletion(snapshot: snapshot)
        }
    }

    private func beginReplacementGeneration(isInterruption: Bool) {
        let oldGeneration = generation
        generation += 1
        phase = .mounting
        errorText = nil
        fixture = nil
        actualRows = nil
        actualColumns = nil
        latestSelectionSnapshot = nil
        setupStartedGeneration = nil
        generationLatches[generation] = TerminalSelectionGenerationLatches(
            generation: generation
        )
        setupTimeoutTask?.cancel()
        beginWaitingForMetrics(generation: generation)
        if !isInterruption {
            interruptionArmed = false
            interruptionComplete = false
            interruptionOutcome = "Explicit surface reset from generation \(oldGeneration)"
        }
    }

    private func beginWaitingForMetrics(generation targetGeneration: Int) {
        guard targetGeneration == generation, phase == .mounting else { return }
        phase = .waitingForMetrics
        scheduleSetupTimeout(for: targetGeneration)
        startSetupIfMetricsAreReady(generation: targetGeneration)
    }

    private func evaluateInterruptionCompletion(snapshot: TerminalSelectionDebugSnapshot) {
        guard interruptionFired,
              !interruptionComplete,
              transport.snapshot().pendingCallbackWork.isEmpty,
              isIdle(snapshot)
        else { return }

        switch scenario {
        case .captureDuringLongPress:
            guard generation == interruptionTriggerGeneration,
                  snapshot.isMouseCaptured == true
            else { return }
            interruptionOutcome = "Mouse capture activated and held host gesture cleaned up"
        case .remountDuringHandleDrag:
            guard let triggerGeneration = interruptionTriggerGeneration,
                  generation > triggerGeneration,
                  phase == .ready,
                  generationLatches[triggerGeneration]?.sawSurfaceRetirementCleanup == true,
                  snapshot.selectionOwnership != .touch
            else { return }
            interruptionOutcome = "Retired generation cleaned up; replacement generation \(generation) is ready and idle"
        case .standard, .mouseCaptured, nil:
            return
        }

        interruptionComplete = true
        interruptionTimeoutTask?.cancel()
        interruptionTimeoutTask = nil
    }

    private func isIdle(_ snapshot: TerminalSelectionDebugSnapshot) -> Bool {
        !snapshot.selectionGestureActive
            && !snapshot.loupeVisible
            && snapshot.handleMode == .none
            && !snapshot.touchHandlesVisible
    }

    private func updateLatches(
        with snapshot: TerminalSelectionDebugSnapshot,
        generation snapshotGeneration: Int
    ) {
        updateLatch(generation: snapshotGeneration) { latch in
            latch.latestSnapshotRevision = snapshot.revision
            latch.sawGridReady = latch.sawGridReady || snapshot.gridReady
            latch.sawSelectionGestureActive = latch.sawSelectionGestureActive
                || snapshot.selectionGestureActive
            latch.sawLoupeVisible = latch.sawLoupeVisible || snapshot.loupeVisible
            latch.sawAdjustingStart = latch.sawAdjustingStart
                || snapshot.handleMode == .adjustingStart
            latch.sawAdjustingEnd = latch.sawAdjustingEnd
                || snapshot.handleMode == .adjustingEnd
            latch.sawMouseCaptured = latch.sawMouseCaptured || snapshot.isMouseCaptured == true
            latch.sawSurfaceRetirementCleanup = latch.sawSurfaceRetirementCleanup
                || (!snapshot.surfaceReady && isIdle(snapshot))
        }
    }

    private func updateLatch(
        generation latchGeneration: Int,
        mutation: (inout TerminalSelectionGenerationLatches) -> Void
    ) {
        var latch = generationLatches[latchGeneration]
            ?? TerminalSelectionGenerationLatches(generation: latchGeneration)
        mutation(&latch)
        generationLatches[latchGeneration] = latch
    }

    private func scheduleSetupTimeout(for timeoutGeneration: Int) {
        setupTimeoutTask?.cancel()
        setupTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.setupTimeout)
            guard !Task.isCancelled,
                  let self,
                  self.generation == timeoutGeneration,
                  self.phase != .ready,
                  self.phase != .failed
            else { return }
            self.recordSetupEvent(
                "timeout blockers=\(self.readinessBlockers(generation: timeoutGeneration))"
            )
            self.fail(
                "Timed out preparing terminal selection generation \(timeoutGeneration) "
                    + "during phase \(self.phase.rawValue)"
            )
        }
    }

    private func scheduleInterruptionTimeout() {
        interruptionTimeoutTask?.cancel()
        interruptionTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.interruptionTimeout)
            guard !Task.isCancelled,
                  let self,
                  self.interruptionFired,
                  !self.interruptionComplete,
                  self.phase != .failed
            else { return }
            self.fail(
                "Timed out waiting for idle cleanup after \(self.scenario?.rawValue ?? "invalid") "
                    + "interruption"
            )
        }
    }

    private func refreshTransportStatus() {
        transportRevision = transport.snapshot().lastEventSequence
        if let snapshot = latestSelectionSnapshot {
            evaluateInterruptionCompletion(snapshot: snapshot)
        }
    }

    private func fail(_ message: String) {
        guard phase != .failed else { return }
        recordSetupEvent("fail \(message)")
        phase = .failed
        errorText = message
        setupTimeoutTask?.cancel()
        setupTimeoutTask = nil
        interruptionTimeoutTask?.cancel()
        interruptionTimeoutTask = nil
    }

    private func makeTransportStatus() -> TerminalSelectionTransportStatus {
        let snapshot = transport.snapshot()
        let resize = snapshot.ledger.reversed().compactMap { recorded -> TerminalSelectionResizeArguments? in
            guard case .resize(_, let columns, let rows) = recorded.event else { return nil }
            return TerminalSelectionResizeArguments(columns: columns, rows: rows)
        }.first
        let writes = snapshot.capturedClientWrites.reduce(into: Data()) { result, write in
            result.append(write.data)
        }
        return TerminalSelectionTransportStatus(
            schemaVersion: Self.schemaVersion,
            eventRevision: snapshot.lastEventSequence,
            openArguments: openArguments(in: snapshot),
            latestResize: resize,
            activeChannelCount: snapshot.activeChannelIDs.count,
            pendingCallbackCount: snapshot.pendingCallbackWork.count,
            pendingRequestCount: snapshot.pendingRequests.count,
            clientWriteHex: writes.map { String(format: "%02x", $0) }.joined(),
            ledger: snapshot.ledger.map {
                "#\($0.sequence) \(String(reflecting: $0.event))"
            }
        )
    }

    private func openArguments(
        in snapshot: ScriptedSSHChannelTransport.Snapshot
    ) -> TerminalSelectionOpenArguments? {
        for recorded in snapshot.ledger {
            guard case .openRequested(_, let terminalType, let columns, let rows, _, _)
                = recorded.event
            else { continue }
            return TerminalSelectionOpenArguments(
                terminalType: terminalType,
                columns: columns,
                rows: rows
            )
        }
        return nil
    }

    private func encodeJSON<Value: Encodable>(_ value: Value) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8)
        else {
            return "{\"schemaVersion\":2,\"error\":\"JSON encoding failed\"}"
        }
        return string
    }
}

/// Attached to the terminal slot, not an arbitrary connected scene. Sampling
/// stops after start; the live reader remains for the mount-time revalidation.
private struct TerminalLoupeStartupProbe: UIViewRepresentable {
    let model: TerminalSelectionUITestHarnessModel

    func makeUIView(context: Context) -> Probe { Probe(model: model) }
    func updateUIView(_ uiView: Probe, context: Context) {}
    static func dismantleUIView(_ uiView: Probe, coordinator: ()) { uiView.stop() }

    final class Probe: UIView {
        private let model: TerminalSelectionUITestHarnessModel
        private var task: Task<Void, Never>?
        private var attachmentID = UUID()

        init(model: TerminalSelectionUITestHarnessModel) {
            self.model = model
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            model.sampleLoupeStartupGeometry = { [weak self] in self?.sample() }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        deinit { task?.cancel() }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            stop()
            // A reattachment cannot inherit a previously settled interval, even
            // when the same scene/window geometry returns between samples.
            attachmentID = UUID()
            guard window != nil else { return }
            task = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    // Do not publish observable state from a SwiftUI layout pass.
                    try? await Task.sleep(for: .milliseconds(50))
                    guard !Task.isCancelled, let self,
                          model.phase == .awaitingStart else { return }
                    model.observeLoupeStartupGeometry(sample(), now: ProcessInfo.processInfo.systemUptime)
                }
            }
        }

        func stop() {
            task?.cancel()
            task = nil
        }

        private func sample() -> TerminalLoupeStartupGeometry? {
            guard let window, let scene = window.windowScene else { return nil }
            window.layoutIfNeeded()
            return TerminalLoupeStartupGeometry(
                sceneID: scene.session.persistentIdentifier,
                attachmentID: attachmentID.uuidString,
                interfaceOrientation: scene.interfaceOrientation.rawValue,
                foregroundActive: scene.activationState == .foregroundActive,
                keyWindow: window.isKeyWindow,
                sceneBounds: scene.coordinateSpace.bounds,
                windowBounds: window.bounds,
                viewportBounds: bounds,
                safeAreaFrame: window.safeAreaLayoutGuide.layoutFrame
            )
        }
    }
}

/// Read-only DEBUG fallback when the production UITextInput does not expose a
/// native text-view accessibility document. Never mutates composition or focus.
private struct TerminalIMEInputDocumentProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ uiView: Probe, context: Context) {}

    final class Probe: UIView {
        override init(frame: CGRect) {
            super.init(frame: frame)
            isAccessibilityElement = true
            accessibilityIdentifier = "terminal.ime.inputDocument"
            accessibilityLabel = "Terminal IME input document"
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override var accessibilityValue: String? {
            get {
                guard let window,
                      let terminal = firstView(of: UITerminalView.self, in: window) else {
                    return "{\"source\":\"unavailable\"}"
                }
                let native = firstView(of: UITextView.self, in: terminal)
                let input: any UITextInput = if let native { native } else { terminal }
                let range = input.textRange(from: input.beginningOfDocument, to: input.endOfDocument)
                let text = range.flatMap { input.text(in: $0) } ?? ""
                let responder: UIResponder = if let native { native } else { terminal }
                let value: [String: Any] = [
                    "source": native == nil ? "customUITextInput" : "nativeTextView",
                    "text": text,
                    "hasMarkedText": input.markedTextRange != nil,
                    "primaryLanguage": responder.textInputMode?.primaryLanguage ?? "",
                ]
                guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
                    return nil
                }
                return String(data: data, encoding: .utf8)
            }
            set {}
        }

        private func firstView<T: UIView>(of type: T.Type, in root: UIView) -> T? {
            if let match = root as? T { return match }
            for child in root.subviews {
                if let match = firstView(of: type, in: child) { return match }
            }
            return nil
        }
    }
}
#endif
