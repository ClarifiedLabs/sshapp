import XCTest

@MainActor
final class LiveSSHSmokeUITests: XCTestCase {
    func testAuthenticationReadinessRequiresConnectedState() {
        XCTAssertFalse(
            LiveSSHUITestHarness.authenticationIsComplete(
                connectionPillValue: "Awaiting input"
            )
        )
        XCTAssertFalse(
            LiveSSHUITestHarness.authenticationIsComplete(
                connectionPillValue: nil
            )
        )
        XCTAssertTrue(
            LiveSSHUITestHarness.authenticationIsComplete(
                connectionPillValue: "Connected"
            )
        )
    }

    func testPasswordPromptRequiresPromptShapedLine() {
        XCTAssertTrue(
            LiveSSHUITestHarness.isPasswordPrompt(
                screenText: "demo@host:~$ ssh demo@example.test\n"
                    + "demo@example.test's password: "
            )
        )
        XCTAssertTrue(
            LiveSSHUITestHarness.isPasswordPrompt(screenText: "password:")
        )
        XCTAssertFalse(
            LiveSSHUITestHarness.isPasswordPrompt(
                screenText: """
                    The authenticity of host 'example.test' can't be established.
                    Are you sure you want to continue connecting (yes/no/[fingerprint])?
                    """
            )
        )
        XCTAssertFalse(
            LiveSSHUITestHarness.isPasswordPrompt(
                screenText: "Permission denied (publickey,password)."
            )
        )
        XCTAssertFalse(
            LiveSSHUITestHarness.isPasswordPrompt(
                screenText: "Last password change: Tue Jul 28"
            )
        )
        XCTAssertFalse(
            LiveSSHUITestHarness.isPasswordPrompt(
                screenText: "PASSWORD MANAGER v2.0"
            )
        )
        XCTAssertFalse(LiveSSHUITestHarness.isPasswordPrompt(screenText: ""))
    }

    func testLiveSSHLoginAndCommandRoundTrip() throws {
        continueAfterFailure = false

        let configuration = try LiveSSHTestConfiguration.fromEnvironment()
        let harness = LiveSSHUITestHarness(testCase: self)
        harness.launch()
        defer { harness.terminate() }

        try harness.createConnectionAndAuthenticate(using: configuration)

        let token = UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .prefix(8)
        let markerWords = ["SSHAPP", "LIVE", "SSH", "SMOKE", String(token)]
        let marker = markerWords.joined(separator: " ")
        try harness.sendCommand("printf '\\n\(marker)\\n'")
        try harness.assertScreen(
            containsExactPhrase: markerWords,
            timeout: configuration.connectionTimeout,
            attachmentName: "live-ssh-command-round-trip"
        )
    }
}
