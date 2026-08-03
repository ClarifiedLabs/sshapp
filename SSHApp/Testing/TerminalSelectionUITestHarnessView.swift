#if DEBUG
import Foundation
import GhosttyTerminal
import SwiftUI

enum TerminalSelectionHarnessPhase: String, Codable {
    case mounting
    case waitingForMetrics
    case opening
    case feeding
    case ready
    case failed
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
            "afterCharlieThroughDelta": " DELTA",
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
    var sawSyntheticButtonDown = false
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
}

/// Network-free app-side fixture for XCUITest terminal touch-selection gestures.
/// The terminal itself is the production `GhosttyTerminalView`; all output enters
/// through `ScriptedSSHChannelTransport -> SSHChannel`.
struct TerminalSelectionUITestHarnessView: View {
    @State private var model = TerminalSelectionUITestHarnessModel(
        scenarioArgument: UITestAppState.terminalSelectionScenarioArgument
    )
    @State private var fontSizeTargetRegistry = TerminalFontSizeTargetRegistry()

    var body: some View {
        VStack(spacing: 0) {
            controls
            terminal
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(uiColor: TerminalRuntime.shared.terminalBackgroundColor))
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button("Arm") {
                model.armInterruption()
            }
            .accessibilityIdentifier("terminal.selection.armInterruption")

            Button("Reset") {
                model.resetObservations()
            }
            .accessibilityLabel("Reset observations")
            .accessibilityIdentifier("terminal.selection.resetObservations")

            Button("Remount") {
                model.resetSurface()
            }
            .accessibilityLabel("Reset surface")
            .accessibilityIdentifier("terminal.selection.resetSurface")

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
            isHostTabActive: false,
            onShortcut: { _ in },
            onRemoteChannelClosed: { _, reason in
                model.remoteChannelClosed(reason)
            },
            onHostSessionInteraction: {},
            showsKeyboardBar: false,
            suppressesSoftwareKeyboard: true,
            keyboardBarTarget: nil,
            hardwareKeyRepeatConfiguration: .default,
            configuredFontSize: Float(TerminalRuntime.shared.fontSize),
            fontSizeTargetRegistry: fontSizeTargetRegistry,
            onPostFlushDraw: {
                model.postFlushDraw(generation: generation)
            },
            terminalSelectionDebugConfiguration: TerminalSelectionDebugConfiguration(
                accessibilityIdentifierPrefix: "terminal.selection",
                snapshotCallback: { snapshot in
                    model.receive(snapshot: snapshot, generation: generation)
                }
            )
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
    private static let schemaVersion = 1
    private static let setupTimeout: Duration = .seconds(8)
    private static let interruptionTimeout: Duration = .seconds(6)
    private static let mouseCaptureBytes = Data("\u{1B}[?1000h\u{1B}[?1006h".utf8)

    let session: SSHSession
    let transport: ScriptedSSHChannelTransport
    let channel: SSHChannel
    let tab: Tab
    let scenario: TerminalSelectionUITestScenario?

    private(set) var generation = 1
    private(set) var phase: TerminalSelectionHarnessPhase = .mounting
    private(set) var errorText: String?
    private(set) var fixture: TerminalSelectionFixture?
    private(set) var actualRows: Int?
    private(set) var actualColumns: Int?
    private(set) var latestSelectionSnapshot: TerminalSelectionDebugSnapshot?
    private(set) var transportRevision: UInt64 = 0
    private(set) var interruptionArmed = false
    private(set) var interruptionFired = false
    private(set) var interruptionComplete = false
    private(set) var interruptionOutcome: String?
    private(set) var triggeringSnapshot: TerminalSelectionDebugSnapshot?
    private(set) var generationLatches: [Int: TerminalSelectionGenerationLatches] = [:]

    @ObservationIgnored private var setupStartedGeneration: Int?
    @ObservationIgnored private var setupTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var interruptionTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var interruptionTriggerGeneration: Int?

    init(
        scenarioArgument:
            Result<TerminalSelectionUITestScenario, TerminalSelectionUITestScenarioArgumentError>
    ) {
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
            }
        ))
    }

    var transportStatusJSON: String {
        _ = transportRevision
        return encodeJSON(makeTransportStatus())
    }

    func surfaceDidAppear(generation appearedGeneration: Int) {
        guard appearedGeneration == generation, phase == .mounting else { return }
        beginWaitingForMetrics(generation: appearedGeneration)
    }

    func receive(
        snapshot: TerminalSelectionDebugSnapshot,
        generation snapshotGeneration: Int
    ) {
        guard phase != .failed,
              generationLatches[snapshotGeneration] != nil
        else { return }
        updateLatches(with: snapshot, generation: snapshotGeneration)
        guard snapshotGeneration == generation else { return }
        latestSelectionSnapshot = snapshot
        triggerInterruptionIfNeeded(from: snapshot, generation: snapshotGeneration)
        startSetupIfMetricsAreReady(generation: snapshotGeneration)
        evaluateReadiness(generation: snapshotGeneration)
        evaluateInterruptionCompletion(snapshot: snapshot)
    }

    func postFlushDraw(generation flushGeneration: Int) {
        guard flushGeneration == generation, phase != .failed else { return }
        updateLatch(generation: flushGeneration) { latch in
            latch.sawPostFlushDraw = true
        }
        evaluateReadiness(generation: flushGeneration)
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

    func resetSurface() {
        guard phase != .failed else { return }
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
        actualColumns = columns
        actualRows = rows
        phase = .opening
        Task { @MainActor [weak self] in
            await self?.performSetup(
                generation: setupGeneration,
                rows: rows,
                columns: columns
            )
        }
    }

    private func performSetup(generation setupGeneration: Int, rows: Int, columns: Int) async {
        do {
            let fixture = try TerminalSelectionFixture.make(rows: rows, columns: columns)
            guard setupGeneration == generation, phase != .failed else { return }
            self.fixture = fixture

            if !channel.isOpen {
                try await channel.openShell(
                    termType: "xterm-256color",
                    cols: columns,
                    rows: rows
                )
            }
            guard setupGeneration == generation, phase != .failed else { return }

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
                  openArguments.columns == columns,
                  openArguments.rows == rows
            else {
                throw TerminalSelectionHarnessError(
                    "Scripted transport open arguments did not match measured \(columns)x\(rows) grid"
                )
            }

            channel.resizeTerminal(cols: columns, rows: rows)
            refreshTransportStatus()
            guard transport.snapshot().latestDimensions[channelID]
                == ScriptedSSHChannelTransport.TerminalDimensions(cols: columns, rows: rows)
            else {
                throw TerminalSelectionHarnessError(
                    "Scripted transport did not record matching \(columns)x\(rows) resize"
                )
            }

            phase = .feeding
            guard await transport.deliverServerData(fixture.bytes, to: channelID) else {
                throw TerminalSelectionHarnessError("Scripted transport rejected base fixture delivery")
            }
            guard setupGeneration == generation, phase != .failed else { return }

            if scenario == .mouseCaptured {
                guard await transport.deliverServerData(Self.mouseCaptureBytes, to: channelID) else {
                    throw TerminalSelectionHarnessError(
                        "Scripted transport rejected startup mouse-capture delivery"
                    )
                }
            }
            guard setupGeneration == generation, phase != .failed else { return }
            refreshTransportStatus()
            evaluateReadiness(generation: setupGeneration)
        } catch {
            guard setupGeneration == generation else { return }
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
        setupTimeoutTask?.cancel()
        setupTimeoutTask = nil
        evaluateInterruptionCompletion(snapshot: snapshot)
    }

    private func triggerInterruptionIfNeeded(
        from snapshot: TerminalSelectionDebugSnapshot,
        generation triggerGeneration: Int
    ) {
        guard interruptionArmed, !interruptionFired else { return }

        let shouldFire: Bool
        switch scenario {
        case .captureDuringLongPress:
            shouldFire = snapshot.syntheticLeftButtonDown
        case .remountDuringHandleDrag:
            shouldFire = snapshot.syntheticLeftButtonDown
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
        !snapshot.syntheticLeftButtonDown
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
            latch.sawSyntheticButtonDown = latch.sawSyntheticButtonDown
                || snapshot.syntheticLeftButtonDown
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
            return "{\"schemaVersion\":1,\"error\":\"JSON encoding failed\"}"
        }
        return string
    }
}
#endif
