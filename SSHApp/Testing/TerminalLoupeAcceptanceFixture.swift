#if DEBUG && !targetEnvironment(macCatalyst)
import GhosttyTerminal
import GhosttyVT
import SwiftUI
import UIKit

/// Finite opt-in fixture around the production terminal. The seed selection is
/// made by XCUITest long press; only the real end-handle pan starts output.
struct TerminalLoupeAcceptanceFixture: UIViewRepresentable {
    let model: TerminalSelectionUITestHarnessModel

    func makeUIView(context: Context) -> Probe { Probe(model: model) }
    func updateUIView(_ uiView: Probe, context: Context) {}
    static func dismantleUIView(_ uiView: Probe, coordinator: ()) { uiView.stop() }

    @MainActor
    final class Probe: UIStackView {
        private let model: TerminalSelectionUITestHarnessModel
        private let status = UILabel()
        private let witness = UIView()
        private weak var terminal: UITerminalView?
        private weak var pan: UIPanGestureRecognizer?
        private var task: Task<Void, Never>?
        private var layout: VTLayout?
        private var terminalID: UUID?
        private var destination: CGPoint?
        private var seed: CGPoint?
        private var point: CGPoint?
        private var stationaryPoint: CGPoint?
        private var stationaryMoves: Int?
        private var begins = 0, moves = 0, ends = 0, writes = 0, witnessTicks = 0
        private var panActive = false, outputStarted = false, outputFinished = false
        private var failure: String?
        private var checkpoints: [[String: Any]] = []
        private struct Geometry: Equatable {
            let source: CGRect
            let loupe: CGRect
            let full: CGRect
            let handles: [CGRect]
        }
        private var stationaryGeometry: Geometry?
        private var outputRows: ClosedRange<Int>?

        init(model: TerminalSelectionUITestHarnessModel) {
            self.model = model
            super.init(frame: .zero)
            // Fixture-only colors through the normal configuration API. Both
            // appearances must supply the analyzer's white selected-background
            // witness; a user's theme must not turn hidden-loupe pixels into a pass.
            let colors = TerminalConfiguration().foreground("#ffffff").background("#000000")
                .selectionBackground("#ffffff").selectionForeground("#000000")
            TerminalRuntime.shared.controller.setTheme(TerminalTheme(light: colors, dark: colors))
            axis = .vertical
            status.text = "Production continuous handle drag compositor fixture"
            status.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            status.accessibilityIdentifier = "terminal.loupe.status"
            witness.isUserInteractionEnabled = false
            witness.isAccessibilityElement = false
            status.addSubview(witness)
            addArrangedSubview(status)
            let prepare = UIButton(type: .system)
            prepare.setTitle("Prepare loupe fixture", for: .normal)
            prepare.accessibilityIdentifier = "terminal.loupe.prepare"
            prepare.addAction(UIAction { [weak self, weak prepare] _ in
                prepare?.isEnabled = false
                self?.prepare()
            }, for: .touchUpInside)
            addArrangedSubview(prepare)
            report("idle")
        }

        required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        deinit { task?.cancel() }

        func stop() {
            task?.cancel()
            pan?.removeTarget(self, action: #selector(observePan(_:)))
        }

        private func findTerminal(in root: UIView) -> UITerminalView? {
            if let terminal = root as? UITerminalView { return terminal }
            for child in root.subviews {
                if let terminal = findTerminal(in: child) { return terminal }
            }
            return nil
        }

        private func prepare() {
            guard model.phase == .ready, let window, let terminal = findTerminal(in: window),
                  let frame = terminal.debugLoupeAcceptanceFrame,
                  frame.layout.rows >= 11, frame.layout.columns >= 24 else {
                fail("missingReadyViewport"); return
            }
            self.terminal = terminal
            layout = frame.layout
            terminalID = frame.terminalID
            let layout = frame.layout
            // Row numbers alone are not geometry: at the default 8pt font,
            // row 6 is ~72pt down and its source band lies INSIDE the loupe.
            // Leave room for the full 96pt loupe plus its 24pt lift, even with
            // the allowed 6pt drag tolerance. Keep the seed below the loupe's
            // on-screen white-witness position but above its sampled selection.
            let targetRow = Int(ceil((160 - layout.padding) / layout.cellHeight))
            let seedRow = targetRow - Int(ceil(24 / layout.cellHeight))
            let lastOutputRow = targetRow + Int(ceil(32 / layout.cellHeight)) - 1
            guard seedRow >= 0, lastOutputRow < layout.rows,
                  layout.cellHeight <= 32 else {
                fail("insufficientPointGeometry"); return
            }
            let target = layout.rect(column: layout.columns * 3 / 4, row: targetRow)
            // A few points below the row boundary leaves the snapped trailing
            // handle above the finger, giving the lower witness shadow clearance.
            destination = CGPoint(x: target.midX, y: target.minY + 4)
            // ANSI rows are one-based. Cover the lower source band (+18...21pt)
            // and drag tolerance without writing over the selected rows above.
            outputRows = (targetRow + 1)...(lastOutputRow + 1)
            let initial = layout.rect(column: (layout.columns / 4) / 2 * 2, row: seedRow)
            seed = CGPoint(x: initial.midX, y: initial.midY)
            witness.frame = CGRect(x: status.bounds.maxX - 8, y: 2, width: 6, height: 6)
            task = Task { [weak self] in
                guard let self else { return }
                do {
                    let split = (layout.columns / 4) * 2
                    var output = "\u{1B}[0m\u{1B}[2J\u{1B}[?25l\u{1B}[38;2;255;255;255m"
                    for row in 1...layout.rows {
                        output += "\u{1B}[\(row);1H\u{1B}[48;2;220;20;30m"
                            + String(repeating: "H ", count: split / 2)
                            + "\u{1B}[48;2;20;220;30m"
                            + String(repeating: "H ", count: (layout.columns - split - 1) / 2)
                    }
                    try await write(output)
                    report("seeded")
                    // Bounded observation only. XCUITest makes a real long press
                    // at seed; no direct selection/drag/refresh APIs are called.
                    try await waitUntil {
                        terminal.selectionDebugProbe?.snapshot?.touchHandlesVisible == true
                            && terminal.debugLoupeAcceptanceEndPan != nil
                            && terminal.selectionDebugProbe?.snapshot?.selectionGestureActive == false
                    }
                    guard let pan = terminal.debugLoupeAcceptanceEndPan else {
                        fail("missingEndHandle"); return
                    }
                    self.pan = pan
                    pan.addTarget(self, action: #selector(observePan(_:)))
                    task = nil
                    report("prepared")
                } catch { fail("prepare: \(error)") }
            }
        }

        @objc private func observePan(_ recognizer: UIPanGestureRecognizer) {
            guard recognizer === pan, let terminal else { return }
            point = recognizer.location(in: terminal)
            switch recognizer.state {
            case .began:
                begins += 1
                panActive = true
                status.backgroundColor = .yellow
                if begins != 1 { fail("multipleBegins") }
            case .changed:
                moves += 1
                // Reject EVERY changed callback after settle, even at the same
                // coordinate: it could refresh a stale loupe and mask a defect.
                if stationaryMoves != nil { fail("movementDuringOutput"); return }
                if !outputStarted, let point, let destination,
                   hypot(point.x - destination.x, point.y - destination.y) <= 6 {
                    outputStarted = true
                    task = Task { [weak self] in await self?.writeDuringHold() }
                }
            case .ended:
                ends += 1
                panActive = false
                status.backgroundColor = .clear
                guard outputFinished else { fail("releasedBeforeOutputFinished"); return }
                guard moves == stationaryMoves, point == stationaryPoint else {
                    fail("holdChangedAtRelease"); return
                }
                task = Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await waitUntil {
                            terminal.debugLoupeAcceptanceLoupe?.isHidden == true
                                && !terminal.debugLoupeAcceptanceDragging
                        }
                        task = nil
                        report("ended")
                    } catch { fail("end: \(error)") }
                }
            case .cancelled, .failed:
                panActive = false
                status.backgroundColor = .clear
                task?.cancel()
                fail("panCancelled")
            default: break
            }
        }

        private func stationary() -> Bool {
            failure == nil && panActive && begins == 1 && ends == 0
                && point == stationaryPoint && moves == stationaryMoves
                && terminal?.debugLoupeAcceptanceDragging == true
                && terminal?.debugLoupeAcceptanceAutoscroll == false
                && terminal?.debugLoupeAcceptanceLoupe?.isHidden == false
                && terminal?.debugLoupeAcceptanceRenderer == "Metal"
                && terminal?.debugLoupeAcceptanceFrame?.layout == layout
                && terminal?.debugLoupeAcceptanceFrame?.terminalID == terminalID
                && terminal?.debugLoupeAcceptanceFrame?.selection != nil
                && stationaryGeometry != nil && geometry() == stationaryGeometry
        }

        private func writeDuringHold() async {
            guard let layout, let outputRows else { fail("missingLayout"); return }
            do {
                try await Task.sleep(for: .milliseconds(300))
                stationaryPoint = point
                stationaryMoves = moves
                guard let geometry = geometry() else { fail("invalidLoupeGeometry"); return }
                stationaryGeometry = geometry
                for (marker, color) in [("red", "220;20;30"), ("green", "20;220;30")] {
                    for index in 0..<5 {
                        guard stationary() else { fail("notStationary"); return }
                        var output = "\u{1B}7\u{1B}[48;2;\(index < 4 ? "20;30;220" : color)m\u{1B}[38;2;255;255;255m"
                        for row in outputRows {
                            // Real terminal text, not a painted marker, with broad vertical
                            // edges. Recorded glyph evidence is still required; 2x video
                            // antialiasing can be inconclusive. Selected H rows stay intact.
                            output += "\u{1B}[\(row);1H" + String(repeating: "\u{258C} ", count: (layout.columns - 1) / 2)
                        }
                        try await write(output + "\u{1B}8")
                        if index < 4 { try await Task.sleep(for: .milliseconds(50)) }
                    }
                    guard stationary(), let terminal,
                          let frame = terminal.debugLoupeAcceptanceFrame,
                          let checkpointGeometry = self.geometry(),
                          checkpointGeometry == stationaryGeometry else {
                        fail("outputIdentityOrGeometry"); return
                    }
                    checkpoints.append(["marker": marker, "writes": writes,
                                        "revision": frame.revision, "panActive": panActive,
                                        "sourceRect": rectValue(checkpointGeometry.source),
                                        "loupeRect": rectValue(checkpointGeometry.loupe),
                                        "loupeFullRect": rectValue(checkpointGeometry.full),
                                        "handleExclusionRects": checkpointGeometry.handles.map(rectValue)])
                    for _ in 0..<8 {
                        guard stationary() else { fail("movementDuringWitness"); return }
                        witnessTicks += 1
                        witness.backgroundColor = witnessTicks.isMultiple(of: 2) ? .black : .white
                        try await Task.sleep(for: .milliseconds(100))
                    }
                }
                outputFinished = true
                task = nil
            } catch { fail("output: \(error)") }
        }

        private func write(_ output: String) async throws {
            let revision = terminal?.debugLoupeAcceptanceFrame?.revision
            guard let channelID = model.transport.snapshot().activeChannelIDs.first,
                  await model.transport.deliverServerData(Data(output.utf8), to: channelID) else {
                throw FixtureError.delivery
            }
            writes += 1
            // Read-only frame observation, not a renderer barrier that could
            // itself request presentation or refresh the magnifier.
            try await waitUntil {
                guard let frame = self.terminal?.debugLoupeAcceptanceFrame else { return false }
                return frame.revision != revision && frame.layout == self.layout && frame.terminalID == self.terminalID
            }
        }

        private enum FixtureError: Error { case delivery, timeout }
        private func waitUntil(_ predicate: () -> Bool) async throws {
            for _ in 0..<160 {
                try Task.checkCancellation()
                if predicate() { return }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw FixtureError.timeout
        }

        private func fail(_ reason: String) {
            failure = failure ?? reason
            report("error")
        }

        private func geometry() -> Geometry? {
            guard let window, let terminal, let point,
                  let loupe = terminal.debugLoupeAcceptanceLoupe,
                  !loupe.isHidden, loupe.bounds.size == CGSize(width: 96, height: 96) else { return nil }
            // Map exactly the same pixels sampled by the production 48pt/2x
            // magnifier. (36,84,24,6) stays inside its 46pt inner radius:
            // farthest corner sqrt(12² + 42²) < 44pt, including rounding margin.
            let source = CGRect(x: point.x - 6, y: point.y + 18, width: 12, height: 3)
            let handles = terminal.debugLoupeAcceptanceHandleExclusionRects
            guard handles.count == 2, handles.allSatisfy({ !$0.intersects(source) }),
                  terminal.bounds.contains(source),
                  let sourceRect = screenRectangle(source, in: terminal),
                  let fullRect = screenRectangle(loupe.bounds, in: loupe),
                  let cropRect = screenRectangle(CGRect(x: 36, y: 84, width: 24, height: 6), in: loupe),
                  let screen = screenRectangle(window.bounds, in: window),
                  screen.contains(sourceRect), screen.contains(fullRect),
                  !sourceRect.intersects(fullRect) else { return nil }
            return Geometry(source: sourceRect, loupe: cropRect, full: fullRect,
                            handles: handles.compactMap { screenRectangle($0, in: terminal) })
        }

        private func screenRectangle(_ rect: CGRect, in source: UIView) -> CGRect? {
            guard let window else { return nil }
            return window.convert(source.convert(rect, to: window), to: window.screen.coordinateSpace)
        }

        private func rectValue(_ rect: CGRect) -> [String: Double] {
            ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]
        }

        private func screenRect(_ rect: CGRect, in source: UIView) -> [String: Double]? {
            screenRectangle(rect, in: source).map { rectValue($0) }
        }

        private func report(_ phase: String) {
            var value: [String: Any] = ["phase": failure == nil ? phase : "error",
                "renderer": terminal?.debugLoupeAcceptanceRenderer ?? "unavailable",
                "begins": begins, "moves": moves, "ends": ends, "writes": writes,
                "panActive": panActive, "outputFinished": outputFinished,
                "checkpoints": checkpoints, "witnessTicks": witnessTicks]
            value["interfaceOrientation"] = terminal?.window?.windowScene?.interfaceOrientation.rawValue
            value["stationaryMoves"] = stationaryMoves
            value["failure"] = failure
            if let geometry = stationaryGeometry {
                value["sourceRect"] = rectValue(geometry.source)
                value["loupeRect"] = rectValue(geometry.loupe)
                value["loupeFullRect"] = rectValue(geometry.full)
                value["handleExclusionRects"] = geometry.handles.map(rectValue)
            }
            if let frame = terminal?.debugLoupeAcceptanceFrame {
                value["terminalID"] = frame.terminalID.uuidString
                value["generation"] = frame.layout.generation
                value["selectionPresent"] = frame.selection != nil
            }
            value["loupeVisible"] = terminal?.debugLoupeAcceptanceLoupe?.isHidden == false
            if let window, let terminal {
                value["screenRect"] = screenRect(window.bounds, in: window)
                value["activeWitnessRect"] = screenRect(status.bounds.insetBy(dx: 2, dy: 2), in: status)
                if let destination { value["destination"] = screenRect(CGRect(origin: destination, size: .zero), in: terminal) }
                if let seed { value["seed"] = screenRect(CGRect(origin: seed, size: .zero), in: terminal) }
                if let point {
                    value["point"] = ["x": point.x, "y": point.y]
                }
            }
            if let data = try? JSONSerialization.data(withJSONObject: value, options: .sortedKeys) {
                status.accessibilityValue = String(decoding: data, as: UTF8.self)
            }
        }
    }
}
#endif
