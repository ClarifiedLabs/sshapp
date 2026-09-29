#if DEBUG
import GhosttyTerminal
import SwiftUI
import UIKit

@MainActor
@Observable
final class LiveSSHUITestInputObservation {
    static let shared = LiveSSHUITestInputObservation()
    private(set) var revision = 0

    func receivedInput() {
        if UITestAppState.usesLiveSSHHarness { revision += 1 }
    }
}

/// Acknowledgments only: no credentials, clipboard contents, or terminal text.
struct LiveSSHUITestStatusView: View {
    let session: SSHSession?
    let keyboardTarget: TerminalKeyboardBarTarget
    /// Host-level suppression. It lives in `MainView` `@State`: session
    /// scoped, never persisted, so every launch starts unsuppressed.
    var softwareKeyboardSuppressed = false
    /// A connected hardware keyboard keeps iPadOS from presenting the software
    /// keyboard the live harness drives; report it so tests fail fast.
    @State private var hardwareKeyboardMonitor = HardwareKeyboardMonitor()
    @State private var lastKeyboardWillChangeFrame: CGRect?
    @State private var keyboardWillChangeFrameCount = 0

    private struct KeyboardFrame: Encodable {
        let x, y, width, height: Double

        init?(_ rect: CGRect?) {
            guard let rect else { return nil }
            x = rect.origin.x
            y = rect.origin.y
            width = rect.width
            height = rect.height
        }
    }

    private struct Status: Encodable {
        let prompt: String
        let promptRevision: Int
        let submissionRevision: Int
        let pasteRevision: Int
        let pasteHadTarget: Bool
        let pasteboardHadText: Bool
        let inputRevision: Int
        let hardwareKeyboardConnected: Bool
        // Keyboard diagnostics: scalar ownership state only.
        let hardwareKeyboardAttachedWithoutSoftwareKeyboard: Bool
        let softwareKeyboardSuppressed: Bool
        let suppressionSource: String
        let suppressionRevision: Int
        let suppressionPersisted: Bool
        let terminalAttached: Bool
        let terminalFirstResponder: Bool?
        let terminalSuppressesSoftwareKeyboard: Bool?
        let terminalInputViewKind: String?
        let terminalSoftwareKeyboardVisible: Bool?
        let terminalKeyboardFrame: KeyboardFrame?
        let terminalKeyboardDismissState: String?
        let terminalPresentingOwnedAlert: Bool?
        let terminalUnderPresentation: Bool?
        let lastKeyboardWillChangeFrame: KeyboardFrame?
        let keyboardWillChangeFrameCount: Int
    }

    private var status: String {
        let terminal = keyboardTarget.uiTestKeyboardDiagnostics
        let snapshot = Status(
            prompt: session?.uiTestAuthenticationPrompt?.rawValue ?? "none",
            promptRevision: session?.uiTestAuthenticationPromptRevision ?? 0,
            submissionRevision: session?.uiTestAuthenticationSubmissionRevision ?? 0,
            pasteRevision: keyboardTarget.uiTestPasteRevision,
            pasteHadTarget: keyboardTarget.uiTestPasteHadTarget,
            pasteboardHadText: keyboardTarget.uiTestPasteboardHadText,
            inputRevision: LiveSSHUITestInputObservation.shared.revision,
            hardwareKeyboardConnected: hardwareKeyboardMonitor.isHardwareKeyboardConnected,
            hardwareKeyboardAttachedWithoutSoftwareKeyboard: hardwareKeyboardMonitor.isAttached,
            softwareKeyboardSuppressed: softwareKeyboardSuppressed,
            suppressionSource: keyboardTarget.uiTestSuppressionSource.rawValue,
            suppressionRevision: keyboardTarget.uiTestSuppressionRevision,
            suppressionPersisted: false,
            terminalAttached: terminal != nil,
            terminalFirstResponder: terminal?.isFirstResponder,
            terminalSuppressesSoftwareKeyboard: terminal?.suppressesSoftwareKeyboard,
            terminalInputViewKind: terminal?.inputViewKind,
            terminalSoftwareKeyboardVisible: terminal?.softwareKeyboardVisible,
            terminalKeyboardFrame: KeyboardFrame(terminal?.keyboardFrame),
            terminalKeyboardDismissState: terminal?.dismissState,
            terminalPresentingOwnedAlert: terminal?.isPresentingOwnedAlert,
            terminalUnderPresentation: terminal?.isUnderPresentation,
            lastKeyboardWillChangeFrame: KeyboardFrame(lastKeyboardWillChangeFrame),
            keyboardWillChangeFrameCount: keyboardWillChangeFrameCount
        )
        return String(decoding: try! JSONEncoder().encode(snapshot), as: UTF8.self)
    }

    var body: some View {
        // Responder and keyboard state live in UIKit, outside observation.
        // Refresh periodically so a failing wait reads current values.
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            Text(status)
                .font(.system(size: 1))
                .frame(width: 1, height: 1)
                .clipped()
                .allowsHitTesting(false)
                .accessibilityIdentifier("liveSSH.status")
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)
        ) { notification in
            keyboardWillChangeFrameCount += 1
            lastKeyboardWillChangeFrame =
                (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        }
    }
}
#endif
