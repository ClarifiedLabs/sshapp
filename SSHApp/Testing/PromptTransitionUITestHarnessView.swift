#if DEBUG
import GhosttyTerminal
import SwiftUI

private enum PromptTransitionSurface: String {
    case normal
    case tmux

    var replacement: PromptTransitionSurface {
        self == .normal ? .tmux : .normal
    }
}

/// Network-free UI harness that mounts the production normal and tmux terminal
/// representables around an in-memory existing channel and one-shot pane snapshot.
struct PromptTransitionUITestHarnessView: View {
    @State private var model: PromptTransitionUITestHarnessModel
    @State private var settledSurface: PromptTransitionSurface?

    init() {
        let initialSurface: PromptTransitionSurface = UITestAppState.promptTransitionStartsInTmux
            ? .tmux
            : .normal
        _model = State(initialValue: PromptTransitionUITestHarnessModel(surface: initialSurface))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Switch surface") {
                    settledSurface = nil
                    model.switchSurface()
                }
                .accessibilityIdentifier("prompt.transition.switch")

                Spacer()

                Text(settledSurface?.rawValue ?? "waiting")
                    .accessibilityIdentifier("prompt.transition.settledSurface")
            }
            .padding()

            terminal
                .id(model.presentationGeneration)
                .accessibilityIdentifier("prompt.transition.terminal")
        }
        .background(Color(uiColor: .systemBackground))
    }

    @ViewBuilder
    private var terminal: some View {
        switch model.surface {
        case .normal:
            GhosttyTerminalView(
                session: model.session,
                tab: model.tab,
                isHostTabActive: false,
                onShortcut: { _ in },
                onRemoteChannelClosed: { _, _ in },
                onHostSessionInteraction: {},
                showsKeyboardBar: false,
                keyboardBarTarget: nil,
                hardwareKeyRepeatConfiguration: .default,
                onPostFlushDraw: {
                    settledSurface = .normal
                }
            )
            .onAppear {
                model.normalSurfaceDidAppear()
            }

        case .tmux:
            TmuxPaneTerminal(
                controller: model.tmuxController,
                pane: model.tmuxPane,
                isFocused: false,
                onFocus: {},
                showsKeyboardBar: false,
                keyboardBarTarget: nil,
                hardwareKeyRepeatConfiguration: .default,
                onShortcut: { _ in },
                onHostSessionInteraction: {},
                onPostFlushDraw: {
                    settledSurface = .tmux
                }
            )
        }
    }
}

@MainActor
@Observable
private final class PromptTransitionUITestHarnessModel {
    static let normalPrompt = Data("NORMALPROMPTALPHA $ ".utf8)
    static let tmuxPrompt = Data("TMUXPROMPTBRAVO $ ".utf8)

    let session: SSHSession
    let tab: Tab
    let tmuxController: TmuxController
    let tmuxPane: TmuxPane

    var surface: PromptTransitionSurface
    private(set) var presentationGeneration = 0
    private var normalPromptGeneration: Int?

    init(surface: PromptTransitionSurface) {
        let session = SSHSession()
        let channel = SSHChannel(
            transport: SSH2Transport(),
            owner: session,
            tmuxSettings: .default
        )
        self.session = session
        tab = Tab(
            title: "Prompt Transition Harness",
            connectionState: .connected,
            session: session,
            channel: channel,
            terminalGridSize: .fallback
        )

        let gateway = TmuxGateway(writer: { _ in })
        tmuxController = TmuxController(gateway: gateway)
        tmuxPane = TmuxPane(
            id: TmuxPaneID(rawValue: 1),
            windowID: TmuxWindowID(rawValue: 1),
            isActive: true
        )
        tmuxPane.feedSnapshot(Self.tmuxPrompt, mode: .freshAttach)
        self.surface = surface
    }

    func switchSurface() {
        let replacement = surface.replacement
        presentationGeneration += 1
        if replacement == .normal, let channel = tab.channel {
            // Exercise the real no-representable handoff window: normal output
            // arrives before SwiftUI installs the replacement surface receiver.
            normalPromptGeneration = presentationGeneration
            channel.deliverTerminalOutput(Self.normalPrompt)
        }
        surface = replacement
        if replacement == .tmux {
            tmuxPane.feedSnapshot(Self.tmuxPrompt, mode: .freshAttach)
        }
    }

    /// `onAppear` runs after the production representable has installed the
    /// existing channel callback, while its Ghostty viewport is still settling.
    func normalSurfaceDidAppear() {
        guard normalPromptGeneration != presentationGeneration,
              let channel = tab.channel else {
            return
        }
        normalPromptGeneration = presentationGeneration
        channel.deliverTerminalOutput(Self.normalPrompt)
    }
}
#endif
