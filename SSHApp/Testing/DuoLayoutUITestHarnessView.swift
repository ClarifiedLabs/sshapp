#if DEBUG
import SwiftUI

private enum DuoLayoutFixtureSurface: String {
    case direct
    case tmux
}

extension UITestAppState {
    static var usesDuoLayoutFixture: Bool {
        duoLayoutFixtureSurface != nil
    }

    fileprivate static var duoLayoutFixtureSurface: DuoLayoutFixtureSurface? {
        let prefix = "--sshapp-ui-test-duo-layout="
        return ProcessInfo.processInfo.arguments.compactMap { argument in
            guard argument.hasPrefix(prefix) else { return nil }
            return DuoLayoutFixtureSurface(rawValue: String(argument.dropFirst(prefix.count)))
        }.first
    }
}

/// Mounts the real MainView and retained TerminalTab hierarchy with one
/// network-free direct or tmux tab. Nothing in the fixture reconnects SSH or
/// changes selection when toolbar traits change.
struct DuoLayoutUITestHarnessView: View {
    @State private var model: DuoLayoutFixtureModel

    init() {
        let surface = UITestAppState.duoLayoutFixtureSurface ?? .direct
        _model = State(initialValue: DuoLayoutFixtureModel(surface: surface))
    }

    var body: some View {
        MainView(initialTabs: [model.tab])
            .task { await model.prepare() }
    }
}

@MainActor
@Observable
private final class DuoLayoutFixtureModel {
    let tab: Tab

    private let channel: SSHChannel
    private let tmuxController: TmuxController?
    private let tmuxPane: TmuxPane?
    private var hasPrepared = false

    init(surface: DuoLayoutFixtureSurface) {
        let session = SSHSession()
        let transport = ScriptedSSHChannelTransport()
        transport.queueOpenPlan(.succeed)
        let channel = SSHChannel(transport: transport, owner: session, tmuxSettings: .default)
        let connection = SavedConnection(
            host: "duo.fixture",
            username: "fixture",
            name: surface == .direct ? "Duo Direct" : "Duo tmux"
        )

        self.channel = channel
        self.tab = Tab(
            title: connection.displayName,
            connectionState: .connected,
            session: session,
            channel: channel,
            connection: connection,
            terminalGridSize: .fallback
        )

        switch surface {
        case .direct:
            tmuxController = nil
            tmuxPane = nil

        case .tmux:
            let controller = TmuxController(gateway: TmuxGateway(writer: { _ in }))
            let windowID = TmuxWindowID(rawValue: 1)
            let paneID = TmuxPaneID(rawValue: 1)
            let pane = TmuxPane(id: paneID, windowID: windowID, isActive: true)
            let window = TmuxWindow(
                id: windowID,
                name: "main",
                paneIDs: [paneID],
                activePaneID: paneID
            )
            controller.windows = [windowID: window]
            controller.windowOrder = [windowID]
            controller.panes = [paneID: pane]
            controller.activeWindowID = windowID
            controller.activePaneID = paneID
            controller.markAttachedForLayoutTesting()
            channel.installTmuxControllerForLayoutTesting(controller)
            tmuxController = controller
            tmuxPane = pane
        }
    }

    func prepare() async {
        guard !hasPrepared else { return }
        hasPrepared = true
        try? await channel.openShell()

        if let tmuxPane {
            tmuxPane.feedSnapshot(
                Data(Self.terminalOutput(marker: "DUO TMUX READY").utf8),
                mode: .freshAttach
            )
        } else {
            channel.deliverTerminalOutput(Data(Self.terminalOutput(marker: "DUO DIRECT READY").utf8))
        }
    }

    private static func terminalOutput(marker: String) -> String {
        let lines = (1...12).map { "  \(marker)  line \($0)\r\n" }.joined()
        return "\u{1B}[0m\u{1B}[2J\u{1B}[H\u{1B}[37;40m\r\n\(lines)"
    }
}
#endif
