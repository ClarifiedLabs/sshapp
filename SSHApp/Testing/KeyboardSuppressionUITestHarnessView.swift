#if DEBUG
import GhosttyTerminal
import SwiftUI
import UIKit

private enum KeyboardSuppressionHarnessSurface: String, CaseIterable {
    case direct
    case tmuxWindowOne = "tmux-window-1"
    case tmuxWindowTwo = "tmux-window-2"

    var next: KeyboardSuppressionHarnessSurface {
        let surfaces = Self.allCases
        let index = surfaces.firstIndex(of: self) ?? 0
        return surfaces[(index + 1) % surfaces.count]
    }
}

/// Network-free UI harness for the persistent software-keyboard suppression mode.
/// It retains one production direct terminal and two production tmux pane terminals
/// from distinct logical windows so UI automation can switch focus while suppressed.
struct KeyboardSuppressionUITestHarnessView: View {
    @State private var model = KeyboardSuppressionUITestHarnessModel()
    @State private var keyboardBarTarget = TerminalKeyboardBarTarget()
    @State private var fontSizeTargetRegistry = TerminalFontSizeTargetRegistry()
    @State private var activeSurface: KeyboardSuppressionHarnessSurface = .direct
    @State private var suppressesSoftwareKeyboard = false
    @State private var showsKeyboardBar = true

    var body: some View {
        VStack(spacing: 0) {
            harnessControls
            terminalSurfaces
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("keyboard.suppression.terminalArea")
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if activeSurface != .direct && showsKeyboardBar && !suppressesSoftwareKeyboard {
                TerminalKeyboardBar(
                    target: keyboardBarTarget,
                    onHideKeyboard: hideSoftwareKeyboard
                )
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if activeSurface != .direct && suppressesSoftwareKeyboard {
                TerminalKeyboardRestoreButton(action: showSoftwareKeyboard)
                    .padding(.trailing, 8)
                    .padding(.bottom, 8)
                    .zIndex(40_000)
            }
        }
        .background(Color(uiColor: TerminalRuntime.shared.terminalBackgroundColor))
    }

    private var harnessControls: some View {
        HStack(spacing: 12) {
            Button("Switch Surface") {
                activeSurface = activeSurface.next
            }
            .accessibilityIdentifier("keyboard.suppression.switchSurface")

            Button(showsKeyboardBar ? "Disable Bar" : "Enable Bar") {
                showsKeyboardBar.toggle()
            }
            .accessibilityIdentifier("keyboard.suppression.toggleBarPreference")

            if UITestAppState.simulatesKeyboardSuppressionSystemResign {
                Button("Simulate Native Dismiss") {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil,
                        from: nil,
                        for: nil
                    )
                }
                .accessibilityIdentifier("keyboard.suppression.simulateSystemResign")
            }

            Spacer(minLength: 0)

            Text(activeSurface.rawValue)
                .font(.caption.monospaced())
                .accessibilityIdentifier("keyboard.suppression.activeSurface")
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
        .background(.bar)
    }

    private var terminalSurfaces: some View {
        ZStack {
            directTerminal
                .opacity(activeSurface == .direct ? 1 : 0)
                .allowsHitTesting(activeSurface == .direct)
                .accessibilityHidden(activeSurface != .direct)

            tmuxTerminal(
                pane: model.tmuxPaneOne,
                surface: .tmuxWindowOne
            )
            .opacity(activeSurface == .tmuxWindowOne ? 1 : 0)
            .allowsHitTesting(activeSurface == .tmuxWindowOne)
            .accessibilityHidden(activeSurface != .tmuxWindowOne)

            tmuxTerminal(
                pane: model.tmuxPaneTwo,
                surface: .tmuxWindowTwo
            )
            .opacity(activeSurface == .tmuxWindowTwo ? 1 : 0)
            .allowsHitTesting(activeSurface == .tmuxWindowTwo)
            .accessibilityHidden(activeSurface != .tmuxWindowTwo)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var directTerminal: some View {
        TerminalTab(
            tab: model.tab,
            fontSizeTargetRegistry: fontSizeTargetRegistry,
            isHostTabActive: activeSurface == .direct,
            showsKeyboardBar: showsKeyboardBar,
            isSoftwareKeyboardSuppressed: suppressesSoftwareKeyboard,
            onSoftwareKeyboardSuppressionChange: {
                suppressesSoftwareKeyboard = $0
            }
        )
        .onAppear {
            model.feedDirectPrompt()
        }
    }

    private func tmuxTerminal(
        pane: TmuxPane,
        surface: KeyboardSuppressionHarnessSurface
    ) -> some View {
        let isFocused = activeSurface == surface
        return TmuxPaneTerminal(
            controller: model.tmuxController,
            pane: pane,
            hostTabID: model.tab.id,
            isFocused: isFocused,
            onFocus: {
                activeSurface = surface
            },
            showsKeyboardBar: showsKeyboardBar,
            suppressesSoftwareKeyboard: suppressesSoftwareKeyboard,
            keyboardBarTarget: keyboardBarTarget,
            hardwareKeyRepeatConfiguration: .default,
            configuredFontSize: Float(TerminalRuntime.shared.fontSize),
            fontSizeTargetRegistry: fontSizeTargetRegistry,
            onShortcut: { _ in },
            onHostSessionInteraction: {},
            onSystemSoftwareKeyboardDismiss: hideSoftwareKeyboard
        )
    }

    private func hideSoftwareKeyboard() {
        keyboardBarTarget.suppressSoftwareKeyboard()
        suppressesSoftwareKeyboard = true
    }

    private func showSoftwareKeyboard() {
        keyboardBarTarget.restoreSoftwareKeyboard()
        suppressesSoftwareKeyboard = false
    }
}

@MainActor
@Observable
private final class KeyboardSuppressionUITestHarnessModel {
    private static let directPrompt = Data(
        Array(repeating: "DIRECT KEYBOARD SUPPRESSION $ \r\n", count: 8).joined().utf8
    )
    private static let tmuxPromptOne = Data(
        Array(repeating: "TMUX WINDOW ONE $ \r\n", count: 8).joined().utf8
    )
    private static let tmuxPromptTwo = Data(
        Array(repeating: "TMUX WINDOW TWO $ \r\n", count: 8).joined().utf8
    )

    let session: SSHSession
    let tab: Tab
    let tmuxController: TmuxController
    let tmuxPaneOne: TmuxPane
    let tmuxPaneTwo: TmuxPane

    init() {
        let session = SSHSession()
        let channel = SSHChannel(
            transport: SSH2Transport(),
            owner: session,
            tmuxSettings: .default
        )
        self.session = session
        tab = Tab(
            title: "Keyboard Suppression Harness",
            connectionState: .connected,
            session: session,
            channel: channel,
            terminalGridSize: .fallback
        )

        let gateway = TmuxGateway(writer: { _ in })
        tmuxController = TmuxController(gateway: gateway)
        tmuxPaneOne = TmuxPane(
            id: TmuxPaneID(rawValue: 1),
            windowID: TmuxWindowID(rawValue: 1),
            isActive: true
        )
        tmuxPaneTwo = TmuxPane(
            id: TmuxPaneID(rawValue: 2),
            windowID: TmuxWindowID(rawValue: 2),
            isActive: true
        )
        tmuxPaneOne.feedSnapshot(Self.tmuxPromptOne, mode: .freshAttach)
        tmuxPaneTwo.feedSnapshot(Self.tmuxPromptTwo, mode: .freshAttach)
    }

    func feedDirectPrompt() {
        tab.channel?.deliverTerminalOutput(Self.directPrompt)
    }
}
#endif
