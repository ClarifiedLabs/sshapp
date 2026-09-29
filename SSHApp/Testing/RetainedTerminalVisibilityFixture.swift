#if DEBUG
import GhosttyTerminal
import SwiftUI
import UIKit

/// Reproducer policy: use production representables and real VT output. Never
/// repair visibility, replace accessibility elements, force drawing/focus, or
/// infer visible pixels from terminal text/state. The probe only assigns native
/// identifiers and observes window descendants; XCUITest owns pixel/AX evidence.
struct RetainedTerminalVisibilityFixture: View {
    @State private var model = RetainedTerminalVisibilityModel()

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button("Alpha") { model.activeGroup = "Alpha" }
                    .accessibilityIdentifier("retained.switch.Alpha")
                Button("Bravo") { model.activeGroup = "Bravo" }
                    .accessibilityIdentifier("retained.switch.Bravo")
            }
            // Keep test controls below iPad's system multitasking hit region.
            .padding(.top, 32)
            RetainedTerminalVisibilityProbe(model: model)
                .frame(height: 20)
            ZStack {
                VStack(spacing: 2) {
                    terminal(0)
                    terminal(1)
                }
                .opacity(model.activeGroup == "Alpha" ? 1 : 0)
                .allowsHitTesting(model.activeGroup == "Alpha")
                .accessibilityHidden(model.activeGroup != "Alpha")

                terminal(2)
                    .opacity(model.activeGroup == "Bravo" ? 1 : 0)
                    .allowsHitTesting(model.activeGroup == "Bravo")
                    .accessibilityHidden(model.activeGroup != "Bravo")
            }
        }
    }

    private func terminal(_ index: Int) -> some View {
        let visible = model.activeGroup == (index < 2 ? "Alpha" : "Bravo")
        return TmuxPaneTerminal(
            controller: model.controller,
            pane: model.panes[index],
            hostTabID: model.hostTabIDs[index],
            isFocused: visible && (index == 2 || model.alphaFocus == index),
            isHostVisible: visible,
            onFocus: { model.didFocus(index) },
            showsKeyboardBar: false,
            suppressesSoftwareKeyboard: !ProcessInfo.processInfo.arguments.contains(
                "--sshapp-ui-test-retained-terminal-keyboard"
            ),
            keyboardBarTarget: nil,
            hardwareKeyRepeatConfiguration: .default,
            configuredFontSize: 20,
            fontSizeTargetRegistry: model.registry,
            onShortcut: { _ in },
            onHostSessionInteraction: {}
        )
    }
}

@MainActor
@Observable
private final class RetainedTerminalVisibilityModel {
    let controller = TmuxController(gateway: TmuxGateway(writer: { _ in }))
    let registry = TerminalFontSizeTargetRegistry()
    let hostTabIDs: [UUID]
    let panes: [TmuxPane]
    let identifiers = ["retained.terminal.alpha.top", "retained.terminal.alpha.bottom", "retained.terminal.bravo"]
    var activeGroup = "Alpha"
    var alphaFocus = 0
    // Observation-only callback evidence, not another driver of terminal state.
    @ObservationIgnored var focusCount = 0
    @ObservationIgnored var focusSourceHostID = "none"

    init() {
        let alphaID = UUID(), bravoID = UUID()
        hostTabIDs = [alphaID, alphaID, bravoID]
        panes = (0..<3).map {
            TmuxPane(id: TmuxPaneID(rawValue: $0 + 1),
                     windowID: TmuxWindowID(rawValue: $0 < 2 ? 1 : 2))
        }
        // No attach(), server, credentials, shell, or remote resize loop. Stable
        // model references own the semantic sessions across every group switch.
        for (pane, marker) in zip(panes, ["AMBER ORCHARD", "COPPER MEADOW", "VIOLET HARBOR"]) {
            controller.panes[pane.id] = pane
            pane.feedSnapshot(Data(("\u{1B}[0m\u{1B}[2J\u{1B}[H\u{1B}[?25l"
                + "\u{1B}[37;40m\r\n  \(marker)  \r\n").utf8), mode: .freshAttach)
        }
    }

    func host(_ index: Int) -> UITerminalView? {
        registry.target(for: .tmuxPane(tabID: hostTabIDs[index], paneID: panes[index].id))
    }

    func didFocus(_ index: Int) {
        focusCount += 1
        focusSourceHostID = host(index).map { String(describing: ObjectIdentifier($0)) } ?? "none"
        if index < 2 { alphaFocus = index }
    }
}

private struct RetainedTerminalVisibilityProbe: UIViewRepresentable {
    let model: RetainedTerminalVisibilityModel

    func makeUIView(context: Context) -> Probe { Probe(model: model) }
    func updateUIView(_ uiView: Probe, context: Context) { uiView.sample() }
    static func dismantleUIView(_ uiView: Probe, coordinator: ()) { uiView.stop() }

    @MainActor
    final class Probe: UILabel {
        private let model: RetainedTerminalVisibilityModel
        private var task: Task<Void, Never>?

        init(model: RetainedTerminalVisibilityModel) {
            self.model = model
            super.init(frame: .zero)
            text = "Native host flags"
            font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            accessibilityIdentifier = "retained.native.status"
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        deinit { task?.cancel() }
        func stop() { task?.cancel(); task = nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            stop()
            guard window != nil else { return }
            task = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    self?.sample()
                    do { try await Task.sleep(for: .milliseconds(100)) }
                    catch { return }
                }
            }
        }

        func sample() {
            guard let window else { return }
            func descendants(_ view: UIView) -> [UITerminalView] {
                (view as? UITerminalView).map { [$0] } ?? view.subviews.flatMap { descendants($0) }
            }
            let hosts = descendants(window)
            // Assign on the actual UIKit host, NEVER the SwiftUI container (that
            // would change the representable's accessibility proxy under test).
            for index in model.panes.indices {
                if let host = model.host(index), host.accessibilityIdentifier != model.identifiers[index] {
                    host.accessibilityIdentifier = model.identifiers[index]
                }
            }
            let rows: [[String: Any]] = hosts.map { host in
                let frame = window.convert(host.convert(host.bounds, to: window),
                                           to: window.screen.coordinateSpace)
                return ["id": host.accessibilityIdentifier ?? "unidentified",
                        "hostID": String(describing: ObjectIdentifier(host)),
                        "isHostVisible": host.isHostVisible, "isHidden": host.isHidden,
                        "isFirstResponder": host.isFirstResponder,
                        "canBecomeFirstResponder": host.canBecomeFirstResponder,
                        "accessibilityElementsHidden": host.accessibilityElementsHidden,
                        "x": frame.minX, "y": frame.minY,
                        "width": frame.width, "height": frame.height]
            }
            let value: [String: Any] = [
                "activeGroup": model.activeGroup,
                "interfaceOrientation": window.windowScene?.interfaceOrientation.rawValue ?? 0,
                "logicalFocusedID": model.identifiers[model.activeGroup == "Alpha" ? model.alphaFocus : 2],
                "hostCount": hosts.count,
                "visibleHostCount": hosts.filter(\.isHostVisible).count,
                "firstResponderCount": hosts.filter(\.isFirstResponder).count,
                "focusCount": model.focusCount, "focusSourceHostID": model.focusSourceHostID,
                "hosts": rows
            ]
            if let data = try? JSONSerialization.data(withJSONObject: value, options: .sortedKeys) {
                let value = String(decoding: data, as: UTF8.self)
                if accessibilityValue != value { accessibilityValue = value }
            }
        }
    }
}
#endif
