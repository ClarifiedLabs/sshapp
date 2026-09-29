import XCTest

final class LiveSSHInputAcknowledgmentTests: XCTestCase {
    private func status(
        prompt: String = "password", promptRevision: Int = 2,
        submissionRevision: Int = 1, pasteRevision: Int = 1,
        pasteHadTarget: Bool = true, inputRevision: Int = 1
    ) -> LiveSSHUIStatus {
        LiveSSHUIStatus(
            prompt: prompt, promptRevision: promptRevision,
            submissionRevision: submissionRevision, pasteRevision: pasteRevision,
            pasteHadTarget: pasteHadTarget, pasteboardHadText: true,
            inputRevision: inputRevision
        )
    }

    func testUntouchedStateAllowsSubmissionButIsNotAcknowledged() {
        let before = status()
        let acknowledgment = LiveSSHInputAcknowledgment(before: before, authenticating: true)
        XCTAssertTrue(acknowledgment.canStartSubmission(before))
        XCTAssertFalse(acknowledgment.isComplete(before))
    }

    func testDeliveredPasteCannotResubmitWhileInputIsDelayed() {
        let acknowledgment = LiveSSHInputAcknowledgment(before: status(), authenticating: true)
        let delayed = status(pasteRevision: 2)
        XCTAssertFalse(acknowledgment.canStartSubmission(delayed))
        XCTAssertFalse(acknowledgment.isComplete(delayed))
    }

    func testPartialInputCannotResubmitOrCompleteAuthentication() {
        let acknowledgment = LiveSSHInputAcknowledgment(before: status(), authenticating: true)
        let partial = status(pasteRevision: 2, inputRevision: 2)
        XCTAssertFalse(acknowledgment.canStartSubmission(partial))
        XCTAssertFalse(acknowledgment.isComplete(partial))
        XCTAssertTrue(acknowledgment.isComplete(
            status(prompt: "none", submissionRevision: 2, pasteRevision: 2, inputRevision: 2)
        ))
    }

    func testChangedPromptAndDetachedTargetCannotAuthorizeAnotherPaste() {
        let acknowledgment = LiveSSHInputAcknowledgment(before: status(), authenticating: true)
        XCTAssertFalse(acknowledgment.canStartSubmission(status(promptRevision: 3)))
        XCTAssertFalse(acknowledgment.canStartSubmission(status(prompt: "none")))
        XCTAssertFalse(acknowledgment.isComplete(status(
            submissionRevision: 2, pasteRevision: 2, pasteHadTarget: false, inputRevision: 2
        )))
    }

    func testSafetyConfirmationRequiresOnePendingPasteAndUnchangedPrompt() {
        let acknowledgment = LiveSSHInputAcknowledgment(before: status(), authenticating: true)
        XCTAssertTrue(acknowledgment.canConfirmPendingPaste(status(pasteRevision: 2)))
        XCTAssertFalse(acknowledgment.canConfirmPendingPaste(status()))
        XCTAssertFalse(acknowledgment.canConfirmPendingPaste(status(pasteRevision: 3)))
        XCTAssertFalse(acknowledgment.canConfirmPendingPaste(status(pasteRevision: 2, inputRevision: 2)))
        XCTAssertFalse(acknowledgment.canConfirmPendingPaste(status(submissionRevision: 2, pasteRevision: 2)))
        XCTAssertFalse(acknowledgment.canConfirmPendingPaste(status(promptRevision: 3, pasteRevision: 2)))
        XCTAssertFalse(acknowledgment.canConfirmPendingPaste(status(prompt: "none", pasteRevision: 2)))
        XCTAssertFalse(acknowledgment.canConfirmPendingPaste(status(pasteRevision: 2, pasteHadTarget: false)))
    }

    func testSafetyConfirmationWaitsForStableButtonGeometry() {
        var stability = LiveSSHPasteConfirmationStability()
        let frame = CGRect(x: 40, y: 400, width: 100, height: 44)
        XCTAssertFalse(stability.isReady(frame: frame, at: 0))
        XCTAssertFalse(stability.isReady(frame: frame, at: 0.49))
        XCTAssertTrue(stability.isReady(frame: frame, at: 0.5))
    }

    func testSafetyConfirmationMovementRestartsSettling() {
        var stability = LiveSSHPasteConfirmationStability()
        let frame = CGRect(x: 40, y: 400, width: 100, height: 44)
        let moved = frame.offsetBy(dx: 0, dy: -20)
        XCTAssertFalse(stability.isReady(frame: frame, at: 0))
        XCTAssertFalse(stability.isReady(frame: moved, at: 0.4))
        XCTAssertFalse(stability.isReady(frame: moved, at: 0.6))
        XCTAssertTrue(stability.isReady(frame: moved, at: 1))
    }

    func testSafetyConfirmationIneligibleInputDiscardsSettledState() {
        var stability = LiveSSHPasteConfirmationStability()
        let frame = CGRect(x: 40, y: 400, width: 100, height: 44)
        XCTAssertFalse(stability.isReady(frame: frame, at: 0))
        XCTAssertTrue(stability.isReady(frame: frame, at: 1))
        XCTAssertFalse(stability.isReady(frame: nil, at: 2))
        XCTAssertFalse(stability.isReady(frame: frame, at: 3))
        XCTAssertTrue(stability.isReady(frame: frame, at: 4))
        XCTAssertFalse(stability.isReady(frame: .zero, at: 5))
        XCTAssertFalse(stability.isReady(frame: frame, at: 6))
    }

    func testUnrelatedTerminalReplyCannotAcknowledgeAMissedPaste() {
        let acknowledgment = LiveSSHInputAcknowledgment(before: status(), authenticating: false)
        XCTAssertFalse(acknowledgment.isComplete(status(inputRevision: 2)))
        XCTAssertTrue(acknowledgment.isComplete(status(pasteRevision: 2, inputRevision: 2)))
    }
}
