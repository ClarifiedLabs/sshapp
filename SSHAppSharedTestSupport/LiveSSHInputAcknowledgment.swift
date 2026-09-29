import Foundation

// Shared by SSHAppUITests (live SSH harness) and SSHAppTests (pure regression
// coverage). Keep this file free of XCUIApplication/device access.

struct LiveSSHUIStatus: Decodable {
    let prompt: String
    let promptRevision: Int
    let submissionRevision: Int
    let pasteRevision: Int
    let pasteHadTarget: Bool
    let pasteboardHadText: Bool
    let inputRevision: Int
    /// Reported by the app (GameController). Nil only for older fixtures.
    var hardwareKeyboardConnected: Bool? = nil
    /// Host-level software-keyboard suppression (session state, not persisted).
    var softwareKeyboardSuppressed: Bool? = nil
    /// What last changed suppression: none, hideButton, systemDismiss, restoreButton.
    var suppressionSource: String? = nil
    var terminalFirstResponder: Bool? = nil
}

/// XCTest idleness is disabled for terminal interaction. A newly presented
/// alert can report hittable before its entrance animation accepts a tap.
/// Nil means the dialog/pending-input safety checks are no longer satisfied.
struct LiveSSHPasteConfirmationStability {
    private var previousFrame: CGRect?
    private var stableSince: TimeInterval?

    mutating func isReady(frame: CGRect?, at time: TimeInterval) -> Bool {
        guard let frame, frame.width > 0, frame.height > 0 else {
            previousFrame = nil
            stableSince = nil
            return false
        }
        if frame != previousFrame {
            previousFrame = frame
            stableSince = time
        }
        return stableSince.map { time - $0 >= 0.5 } ?? false
    }
}

/// A tap is only an attempt. Authentication additionally requires the session
/// to acknowledge a complete response, even if terminal input has arrived.
struct LiveSSHInputAcknowledgment {
    let before: LiveSSHUIStatus
    let authenticating: Bool

    func isComplete(_ current: LiveSSHUIStatus) -> Bool {
        guard current.pasteRevision > before.pasteRevision,
              current.pasteHadTarget,
              current.pasteboardHadText,
              current.inputRevision > before.inputRevision else { return false }
        return !authenticating || current.submissionRevision > before.submissionRevision
    }

    /// Confirm the single payload already delivered to the terminal's safety
    /// dialog, only while no input or authentication transition has intervened.
    func canConfirmPendingPaste(_ current: LiveSSHUIStatus) -> Bool {
        current.pasteRevision == before.pasteRevision + 1
            && current.pasteHadTarget && current.pasteboardHadText
            && current.inputRevision == before.inputRevision
            && current.submissionRevision == before.submissionRevision
            && current.promptRevision == before.promptRevision
            && current.prompt == before.prompt
    }

    func canStartSubmission(_ current: LiveSSHUIStatus) -> Bool {
        // Refuse stale prompt snapshots or intervening input before starting.
        // Once submitted, the caller must wait without repeating the paste.
        current.pasteRevision == before.pasteRevision
            && current.inputRevision == before.inputRevision
            && current.submissionRevision == before.submissionRevision
            && current.promptRevision == before.promptRevision
            && current.prompt == before.prompt
    }
}
