import XCTest

/// Pure regressions for the live SSH harness's text classification. They
/// launch nothing, so they run in the unit target instead of the UI runner.
final class LiveSSHAuthenticationTextTests: XCTestCase {
    func testAuthenticationReadinessRequiresConnectedState() {
        XCTAssertFalse(
            LiveSSHAuthenticationText.authenticationIsComplete(
                connectionPillValue: "Awaiting input"
            )
        )
        XCTAssertFalse(
            LiveSSHAuthenticationText.authenticationIsComplete(
                connectionPillValue: nil
            )
        )
        XCTAssertTrue(
            LiveSSHAuthenticationText.authenticationIsComplete(
                connectionPillValue: "Connected"
            )
        )
    }

    func testPasswordPromptRequiresPromptShapedLine() {
        XCTAssertTrue(
            LiveSSHAuthenticationText.isPasswordPrompt(
                screenText: "demo@host:~$ ssh demo@example.test\n"
                    + "demo@example.test's password: "
            )
        )
        XCTAssertTrue(
            LiveSSHAuthenticationText.isPasswordPrompt(screenText: "password:")
        )
        // OCR reads the terminal's block cursor after the prompt as a glyph.
        XCTAssertTrue(
            LiveSSHAuthenticationText.isPasswordPrompt(screenText: "Password: |")
        )
        XCTAssertFalse(
            LiveSSHAuthenticationText.isPasswordPrompt(
                screenText: """
                    The authenticity of host 'example.test' can't be established.
                    Are you sure you want to continue connecting (yes/no/[fingerprint])?
                    """
            )
        )
        XCTAssertFalse(
            LiveSSHAuthenticationText.isPasswordPrompt(
                screenText: "Permission denied (publickey,password)."
            )
        )
        XCTAssertFalse(
            LiveSSHAuthenticationText.isPasswordPrompt(
                screenText: "Last password change: Tue Jul 28"
            )
        )
        XCTAssertFalse(
            LiveSSHAuthenticationText.isPasswordPrompt(
                screenText: "PASSWORD MANAGER v2.0"
            )
        )
        XCTAssertFalse(LiveSSHAuthenticationText.isPasswordPrompt(screenText: ""))
    }
}
