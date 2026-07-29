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
