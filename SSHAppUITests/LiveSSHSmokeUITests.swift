import XCTest

@MainActor
final class LiveSSHSmokeUITests: XCTestCase {
    func testConnectionFormAndDelayedAuthenticationPromptsWithoutNetwork() throws {
        continueAfterFailure = false
        let harness = LiveSSHUITestHarness(testCase: self)
        harness.launch(simulatedAuthentication: true)
        defer { harness.terminate() }

        try harness.createConnectionAndAuthenticate(using: LiveSSHTestConfiguration(
            destination: "fixture@example.invalid", password: "synthetic-password",
            acceptUnknownHost: true, credentialPersistence: .decline,
            enableDefaultTmuxStartup: false, connectionTimeout: 45
        ))
        try harness.waitForLabel(harness.app.staticTexts["authentication.fixture.result"], equals: "complete")
        let status = try harness.waitForStatus("authentication input settled") {
            $0.pasteRevision == 2 && $0.submissionRevision == 2
        }
        XCTAssertEqual(status.pasteRevision, 2)
        XCTAssertEqual(status.submissionRevision, 2)
        XCTAssertEqual(status.promptRevision, 2)
        harness.recordScreen(name: "authentication-fixture-paste-complete")

        // A command must survive the real device's clipboard-cleanup app switch
        // before sending its single Return. No socket or remote echo is involved.
        try harness.sendCommand("LOCAL COMMAND PROBE")
        // One write for the pasted command and one for its Return.
        let afterCommand = try harness.waitForStatus("command paste and Return processed") {
            $0.pasteRevision == status.pasteRevision + 1 && $0.inputRevision >= status.inputRevision + 2
        }
        XCTAssertEqual(afterCommand.submissionRevision, status.submissionRevision)
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
        let marker = markerWords.joined(separator: "\\n")
        try harness.sendCommand("printf '\\n\(marker)\\n'")
        try harness.assertScreen(
            containsExactPhrase: markerWords,
            timeout: configuration.connectionTimeout,
            attachmentName: "live-ssh-command-round-trip"
        )
    }
}
