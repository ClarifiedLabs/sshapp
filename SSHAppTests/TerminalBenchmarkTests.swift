import UIKit
import XCTest
@testable import GhosttyTerminal
@testable import GhosttyVT

/// Terminal performance benchmarks. Each `testBenchmark…` test drives a fixed
/// synthetic workload through the production VT session, UIKit host and Metal
/// renderer, then attaches a JSON report (timings, process footprint, thermal
/// state). They assert only that the workload completed correctly; there are no
/// performance thresholds.
///
/// For meaningful numbers, run in Release on a physical device and compare
/// reports from the same device, build configuration and power state:
///
///     DEVICE_UDID=<udid> DEVICE_BUILD_CONFIGURATION=Release scripts/run-device-tests.py \
///       -only-testing:SSHAppTests/TerminalBenchmarkTests
///
/// Simulator runs are a smoke check only; the sustained workloads skip there.
@MainActor
final class TerminalBenchmarkTests: XCTestCase {
    func testSemanticFixturesSurviveArbitraryByteBoundaries() async throws {
        let mounted = try await mount(count: 1)
        defer { mounted.unmount() }
        let session = mounted.sessions[0]

        for fixture in TerminalReplayFixtures.semantic {
            var reference: String?
            // One-byte chunks split UTF-8 scalars, grapheme sequences and CSI.
            for chunkSize in [fixture.bytes.count, 1, 7] {
                let bytes = fixture.bytes
                let accepted = await Task.detached {
                    for offset in stride(from: 0, to: bytes.count, by: chunkSize) {
                        guard session.receiveIfSurfaceAttached(
                            bytes.subdata(in: offset..<min(offset + chunkSize, bytes.count))
                        ) else { return false }
                    }
                    return true
                }.value
                XCTAssertTrue(accepted, fixture.name)
                let text = try await selectedText(in: session)
                for expected in fixture.expectedText {
                    XCTAssertTrue(text.contains(expected), "\(fixture.name): missing \(expected)")
                }
                for absent in fixture.absentText {
                    XCTAssertFalse(text.contains(absent), "\(fixture.name): unexpected \(absent)")
                }
                if let reference {
                    XCTAssertEqual(text, reference, "\(fixture.name), chunk size \(chunkSize)")
                } else {
                    reference = text
                }
            }
        }
    }

    func testFixedBenchmarkCanvasFitsSafeAreaOrRefusesCompactWindow() throws {
        XCTAssertNil(TerminalBenchmarkWorkload.canvasOrigin(in: CGRect(x: 0, y: 59, width: 375, height: 700)))
        XCTAssertNil(TerminalBenchmarkWorkload.canvasOrigin(in: CGRect(x: 0, y: 0, width: 900, height: 500)))
        let area = CGRect(x: 0, y: 62, width: 440, height: 850)
        let origin = try XCTUnwrap(TerminalBenchmarkWorkload.canvasOrigin(in: area))
        let canvas = CGRect(origin: origin, size: CGSize(width: 390, height: 600))
        XCTAssertTrue(area.contains(canvas))
        XCTAssertEqual(canvas.midX, area.midX)
        XCTAssertEqual(canvas.midY, area.midY)
    }

    // MARK: - Benchmarks

    /// Short paced output with periodic resizes; also runs on simulators.
    func testBenchmarkReplayOnePane() async throws {
        try await recordOutput(paneCount: 1, samples: TerminalBenchmarkWorkload.shortSamples)
    }

    func testBenchmarkReplayFourPanes() async throws {
        try await recordOutput(paneCount: 4, samples: TerminalBenchmarkWorkload.shortSamples)
    }

    /// One minute of paced output.
    func testBenchmarkSustainedOutputOnePane() async throws {
        try skipOnSimulator()
        try await recordOutput(paneCount: 1, samples: TerminalBenchmarkWorkload.sustainedSamples)
    }

    func testBenchmarkSustainedOutputFourPanes() async throws {
        try skipOnSimulator()
        try await recordOutput(paneCount: 4, samples: TerminalBenchmarkWorkload.sustainedSamples)
    }

    /// One visible and two hidden (retained) panes receiving image replacements,
    /// then teardown. Reports footprint at each stage and requires every
    /// renderer to be released after unmount.
    func testBenchmarkRetainedPaneMemory() async throws {
        let graphics = TerminalGraphicsMemoryWorkload(side: 256)
        let baseline = processFootprint()
        var stages: [[String: Any]] = [["stage": "baseline", "processFootprintBytes": baseline]]
        weak var renderer: VTMetalRenderer?
        var hiddenContent: [WeakBox<VTContentView>] = []
        do {
            let mounted = try await mount(count: 3, visibleCount: 1)
            defer { mounted.unmount() }
            renderer = mounted.terminals[0].surface?.contentView.metalRenderer
            hiddenContent = mounted.terminals.dropFirst().compactMap {
                $0.surface.map { WeakBox($0.contentView) }
            }
            try mounted.requireMetal(context: "memory start")
            stages.append(["stage": "mounted", "processFootprintBytes": processFootprint()])
            for cycle in 0..<4 {
                for session in mounted.sessions { try await ingest(graphics.payload(cycle), into: session) }
                _ = try await renderedFrame(in: mounted.terminals[0]) { frame in
                    frame.line(0).hasPrefix("graphics-gray-\(graphics.level(cycle))")
                }
                stages.append(["stage": "cycle-\(cycle)", "processFootprintBytes": processFootprint()])
            }
            for session in mounted.sessions {
                let text = try await selectedText(in: session)
                XCTAssertTrue(text.contains("graphics-gray-\(graphics.level(3))"), "Hidden panes keep their state")
            }
            try mounted.requireMetal(context: "memory end")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while (renderer != nil || hiddenContent.contains { $0.value != nil })
                && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(renderer, "Unmount must release the Metal renderer")
        XCTAssertTrue(hiddenContent.allSatisfy { $0.value == nil }, "Unmount must release hidden panes")
        stages.append(["stage": "unmounted", "processFootprintBytes": processFootprint()])
        attachReport(name: "terminal-benchmark-retained-pane-memory", [
            "benchmark": "retained-pane-memory",
            "imageBytes": graphics.imageBytes, "visiblePanes": 1, "hiddenPanes": 2,
            "stages": stages,
        ])
    }

    // MARK: - Workloads

    private func recordOutput(paneCount: Int, samples: Int) async throws {
        let mounted = try await mount(count: paneCount)
        defer { mounted.unmount() }
        let batch = TerminalBenchmarkWorkload.batch
        let previousIdleTimer = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = previousIdleTimer }
        var lateness: [Double] = []
        var ingestMilliseconds: [Double] = []
        var frameRequestMilliseconds: [Double] = []
        var footprint: [UInt64] = []
        var thermalStates: [Int] = []
        try mounted.requireMetal(context: "output start")
        let started = ProcessInfo.processInfo.systemUptime
        let scheduleStart = ContinuousClock.now
        for sample in 0..<samples {
            lateness.append(try await TerminalBenchmarkWorkload.wait(for: sample, from: scheduleStart))
            let before = ProcessInfo.processInfo.systemUptime
            // Completion includes native ingest and reply/event fan-out.
            for session in mounted.sessions { try await ingest(batch, into: session) }
            ingestMilliseconds.append((ProcessInfo.processInfo.systemUptime - before) * 1_000)
            let drawStart = ProcessInfo.processInfo.systemUptime
            for terminal in mounted.terminals { terminal.surface?.refresh() }
            frameRequestMilliseconds.append((ProcessInfo.processInfo.systemUptime - drawStart) * 1_000)
            // Resize while scrollback grows; synthetic, not rotation or keyboard UI.
            if sample % 20 == 10 {
                for terminal in mounted.terminals {
                    terminal.frame.size.width = TerminalBenchmarkWorkload.width(after: sample)
                    terminal.setNeedsLayout()
                    terminal.layoutIfNeeded()
                }
            }
            footprint.append(processFootprint())
            thermalStates.append(ProcessInfo.processInfo.thermalState.rawValue)
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        try mounted.requireMetal(context: "output end")
        for terminal in mounted.terminals { _ = try await renderedFrame(in: terminal) }
        for session in mounted.sessions {
            let text = try await selectedText(in: session)
            XCTAssertTrue(text.contains("row-127"))
        }
        var workload = TerminalBenchmarkWorkload.metadata(scale: mounted.window.screen.scale, samples: samples)
        workload["paneCount"] = paneCount
        attachReport(name: "terminal-benchmark-output-\(paneCount)-panes-\(samples)-samples", [
            "benchmark": "paced-output",
            "workload": workload,
            "elapsedSeconds": elapsed,
            "deliveryLatenessMilliseconds": lateness,
            "completedIngestMilliseconds": ingestMilliseconds,
            "frameRequestMilliseconds": frameRequestMilliseconds,
            "processFootprintBytes": footprint,
            "thermalStates": thermalStates,
            "rendererDiagnostics": mounted.terminals.compactMap {
                ($0.surface?.contentView.metalRenderer?.diagnostics).flatMap { diagnostics in
                    (try? JSONEncoder().encode(diagnostics)).flatMap {
                        try? JSONSerialization.jsonObject(with: $0)
                    }
                }
            },
            "measurementLimit": "Ingest includes scheduling and native completion. Frame requests are admission only; excludes GPU completion, display, SSH and energy.",
        ])
    }

    // MARK: - Helpers

    private final class WeakBox<Value: AnyObject> {
        weak var value: Value?
        init(_ value: Value) { self.value = value }
    }

    @MainActor
    private final class MountedTerminals {
        let window: UIWindow
        let previousKeyWindow: UIWindow?
        let terminals: [UITerminalView]
        let sessions: [VTTerminalSession]
        // Keep the controller alive through asynchronous surface retirement.
        let controller: TerminalController

        init(window: UIWindow, previousKeyWindow: UIWindow?, terminals: [UITerminalView],
             sessions: [VTTerminalSession], controller: TerminalController) {
            self.window = window
            self.previousKeyWindow = previousKeyWindow
            self.terminals = terminals
            self.sessions = sessions
            self.controller = controller
        }

        /// CoreText recovery is valid in the app but invalidates a Metal benchmark.
        func requireMetal(context: String) throws {
            for (pane, terminal) in terminals.enumerated() where !terminal.isHidden {
                let content = terminal.surface?.contentView
                let renderer = content?.metalRenderer
                let active = renderer?.isActive == true && content?.isPresentationActive == true
                XCTAssertNotNil(renderer, "\(context) pane=\(pane): Metal renderer missing")
                XCTAssertTrue(active, "\(context) pane=\(pane): Metal presentation inactive")
                _ = try XCTUnwrap(renderer)
            }
        }

        func unmount() {
            sessions.forEach { $0.finish() }
            for terminal in terminals {
                terminal.controller = nil
                terminal.removeFromSuperview()
            }
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }
    }

    private enum BenchmarkError: Error { case mountTimeout, ingest }

    /// Mounts panes stacked in the fixed 390×600 canvas. Panes at or beyond
    /// `visibleCount` are hidden but keep their sessions (retained panes).
    private func mount(count: Int, visibleCount: Int? = nil) async throws -> MountedTerminals {
        let visibleCount = visibleCount ?? count
        let sceneDeadline = ProcessInfo.processInfo.systemUptime + 5
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }) {
            guard ProcessInfo.processInfo.systemUptime < sceneDeadline else { throw BenchmarkError.mountTimeout }
            try await Task.sleep(for: .milliseconds(10))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        root.view.backgroundColor = .systemGray6
        window.layoutIfNeeded()
        root.view.layoutIfNeeded()
        let safeArea = root.view.safeAreaLayoutGuide.layoutFrame
        guard let origin = TerminalBenchmarkWorkload.canvasOrigin(in: safeArea) else {
            window.isHidden = true
            previous?.makeKey()
            throw XCTSkip("Fixed 390×600 benchmark canvas does not fit this safe area: \(safeArea)")
        }
        let configuration = TerminalConfiguration.default.cursorStyleBlink(false)
            .fontFamily(TerminalBenchmarkWorkload.fontFamily)
            .fontSize(TerminalBenchmarkWorkload.ghosttyFontPoints).fontThicken(false)
            .windowPaddingX(0).windowPaddingY(0)
            .background("#000000").foreground("#ffffff")
        // An empty theme keeps the fixed colors instead of the light/dark default.
        let controller = TerminalController(configuration: configuration, theme: .init())
        XCTAssertNil(controller.lastConfigurationIssue, "Benchmark configuration must not fall back to defaults")
        let paneHeight: CGFloat = visibleCount == 1 ? 600 : 600 / CGFloat(visibleCount)
        var terminals: [UITerminalView] = []
        var sessions: [VTTerminalSession] = []
        for index in 0..<count {
            let frame = CGRect(x: origin.x, y: origin.y + CGFloat(index % visibleCount) * paneHeight,
                               width: 390, height: paneHeight)
            let terminal = UITerminalView(frame: frame)
            let session = VTTerminalSession(write: { _ in }, resize: { _ in })
            terminal.configuredFontSize = Float(TerminalBenchmarkWorkload.font.pointSize)
            terminal.configuration = TerminalSurfaceOptions(backend: .vt(session))
            terminal.controller = controller
            root.view.addSubview(terminal)
            terminals.append(terminal)
            sessions.append(session)
        }
        root.view.layoutIfNeeded()
        let mounted = MountedTerminals(window: window, previousKeyWindow: previous, terminals: terminals,
                                       sessions: sessions, controller: controller)
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while terminals.contains(where: { terminal in
            guard let metrics = terminal.surface?.size() else { return true }
            return metrics.columns == 0 || metrics.rows == 0
        }) {
            if ProcessInfo.processInfo.systemUptime > deadline {
                mounted.unmount()
                XCTFail("Timed out mounting terminal surfaces")
                throw BenchmarkError.mountTimeout
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        for (index, terminal) in terminals.enumerated() {
            terminal.isHidden = index >= visibleCount
        }
        return mounted
    }

    private func ingest(_ bytes: Data, into session: VTTerminalSession) async throws {
        let completed = await withCheckedContinuation { continuation in
            session.deliver(bytes, ifCurrent: { true }) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(completed, "Native ingestion must complete, not merely be admitted")
        guard completed else { throw BenchmarkError.ingest }
    }

    private func selectedText(in session: VTTerminalSession) async throws -> String {
        let select = try XCTUnwrap(session.enqueueSelectAll())
        let query = try XCTUnwrap(session.enqueueSelectedText())
        try await select.value
        return try await query.value
    }

    /// Waits for a fresh successful render (requested after this call) that
    /// satisfies `predicate`.
    private func renderedFrame(in terminal: UITerminalView, timeout: Double = 5,
                               matching predicate: @escaping (VTFrameValue) -> Bool = { _ in true }) async throws -> VTFrameValue {
        let content = try XCTUnwrap(terminal.surface?.contentView)
        var rendered: VTFrameValue?
        var freshRenderCompleted = false
        let previous = content.onRendered
        content.onRendered = { frame in
            previous?(frame)
            if freshRenderCompleted, predicate(frame) { rendered = frame }
        }
        defer { content.onRendered = previous }
        content.requestFrame { frame in
            freshRenderCompleted = true
            if predicate(frame) { rendered = frame }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while rendered == nil && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        return try XCTUnwrap(rendered, "Timed out waiting for a rendered frame: \(content.renderDiagnostics)")
    }

    private func attachReport(name: String, _ report: [String: Any]) {
        var report = report
        report["buildConfiguration"] = buildConfiguration
        report["os"] = ProcessInfo.processInfo.operatingSystemVersionString
        report["lowPowerMode"] = ProcessInfo.processInfo.isLowPowerModeEnabled
        report["thermalState"] = ProcessInfo.processInfo.thermalState.rawValue
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) else {
            return XCTFail("Benchmark report is not valid JSON")
        }
        print("TERMINAL_BENCHMARK \(name)")
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func skipOnSimulator() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Sustained benchmarks are only meaningful on a physical device")
        #endif
    }

    private var buildConfiguration: String {
        #if DEBUG
        "Debug"
        #else
        "Release"
        #endif
    }

    private func processFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let capacity = Int(count)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
