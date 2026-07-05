import XCTest
@testable import SSHApp

final class CredentialSavePolicyTests: XCTestCase {

    // MARK: - Combined save dialog rows

    func testUsernameOnlyOfferShowsUsernameRow() {
        let rows = CredentialSavePolicy.rowsToOffer(
            offer: CredentialSaveOffer(username: "alice", password: nil),
            hasSavedUsername: false,
            neverAskUsername: false,
            neverAskPassword: false
        )
        XCTAssertEqual(
            rows,
            CredentialSaveRows(
                showUsernameRow: true,
                showPasswordRow: false,
                passwordDependsOnUsername: false
            )
        )
    }

    func testPasswordOnlyOfferWithSavedUsernameShowsUngatedPasswordRow() {
        let rows = CredentialSavePolicy.rowsToOffer(
            offer: CredentialSaveOffer(username: nil, password: "hunter2"),
            hasSavedUsername: true,
            neverAskUsername: false,
            neverAskPassword: false
        )
        XCTAssertEqual(
            rows,
            CredentialSaveRows(
                showUsernameRow: false,
                showPasswordRow: true,
                passwordDependsOnUsername: false
            )
        )
    }

    func testBothOfferedWithoutSavedUsernameGatesPasswordOnUsername() {
        let rows = CredentialSavePolicy.rowsToOffer(
            offer: CredentialSaveOffer(username: "alice", password: "hunter2"),
            hasSavedUsername: false,
            neverAskUsername: false,
            neverAskPassword: false
        )
        XCTAssertEqual(
            rows,
            CredentialSaveRows(
                showUsernameRow: true,
                showPasswordRow: true,
                passwordDependsOnUsername: true
            )
        )
    }

    func testNeverAskUsernameSuppressesUsernameRow() {
        let rows = CredentialSavePolicy.rowsToOffer(
            offer: CredentialSaveOffer(username: "alice", password: nil),
            hasSavedUsername: false,
            neverAskUsername: true,
            neverAskPassword: false
        )
        XCTAssertTrue(rows.isEmpty)
    }

    func testNeverAskUsernameWithoutSavedUsernameAlsoDropsPasswordRow() {
        let rows = CredentialSavePolicy.rowsToOffer(
            offer: CredentialSaveOffer(username: "alice", password: "hunter2"),
            hasSavedUsername: false,
            neverAskUsername: true,
            neverAskPassword: false
        )
        XCTAssertTrue(rows.isEmpty, "A password without any username to associate it with must not be offered")
    }

    func testNeverAskPasswordSuppressesPasswordRowOnly() {
        let rows = CredentialSavePolicy.rowsToOffer(
            offer: CredentialSaveOffer(username: "alice", password: "hunter2"),
            hasSavedUsername: false,
            neverAskUsername: false,
            neverAskPassword: true
        )
        XCTAssertEqual(
            rows,
            CredentialSaveRows(
                showUsernameRow: true,
                showPasswordRow: false,
                passwordDependsOnUsername: false
            )
        )
    }

    func testPasswordWithoutAnyUsernameIsNotOffered() {
        let rows = CredentialSavePolicy.rowsToOffer(
            offer: CredentialSaveOffer(username: nil, password: "hunter2"),
            hasSavedUsername: false,
            neverAskUsername: false,
            neverAskPassword: false
        )
        XCTAssertTrue(rows.isEmpty)
    }

    func testEmptyOfferShowsNothing() {
        let rows = CredentialSavePolicy.rowsToOffer(
            offer: CredentialSaveOffer(username: nil, password: nil),
            hasSavedUsername: true,
            neverAskUsername: false,
            neverAskPassword: false
        )
        XCTAssertTrue(rows.isEmpty)
    }

    // MARK: - Declining an offered password suppresses future prompts

    func testSavingUsernameButDecliningPasswordSuppressesFuturePasswordPrompts() {
        let rows = CredentialSaveRows(
            showUsernameRow: true,
            showPasswordRow: true,
            passwordDependsOnUsername: true
        )
        let decision = CredentialSaveDecision.saving(username: true, password: false)
        XCTAssertTrue(CredentialSavePolicy.shouldSuppressFuturePassword(rows: rows, decision: decision))
    }

    func testSavingBothDoesNotSuppressFuturePasswordPrompts() {
        let rows = CredentialSaveRows(
            showUsernameRow: true,
            showPasswordRow: true,
            passwordDependsOnUsername: true
        )
        let decision = CredentialSaveDecision.saving(username: true, password: true)
        XCTAssertFalse(CredentialSavePolicy.shouldSuppressFuturePassword(rows: rows, decision: decision))
    }

    func testSavingUsernameWithoutPasswordRowDoesNotSuppress() {
        let rows = CredentialSaveRows(
            showUsernameRow: true,
            showPasswordRow: false,
            passwordDependsOnUsername: false
        )
        let decision = CredentialSaveDecision.saving(username: true, password: false)
        XCTAssertFalse(
            CredentialSavePolicy.shouldSuppressFuturePassword(rows: rows, decision: decision),
            "No password was offered, so nothing was declined"
        )
    }

    func testDecliningEverythingDoesNotSuppress() {
        let rows = CredentialSaveRows(
            showUsernameRow: true,
            showPasswordRow: true,
            passwordDependsOnUsername: true
        )
        XCTAssertFalse(CredentialSavePolicy.shouldSuppressFuturePassword(rows: rows, decision: .declined))
    }

    // MARK: - Dialog button decision mapping

    func testSaveButtonMapsToggleState() {
        XCTAssertEqual(
            CredentialSaveDecision.saving(username: true, password: false),
            CredentialSaveDecision(
                saveUsername: true,
                savePassword: false,
                neverAskUsername: false,
                neverAskPassword: false
            )
        )
    }

    func testDontAskAgainSuppressesOnlyOfferedRows() {
        let usernameOnly = CredentialSaveRows(
            showUsernameRow: true,
            showPasswordRow: false,
            passwordDependsOnUsername: false
        )
        XCTAssertEqual(
            CredentialSaveDecision.neverAsking(rows: usernameOnly),
            CredentialSaveDecision(
                saveUsername: false,
                savePassword: false,
                neverAskUsername: true,
                neverAskPassword: false
            )
        )

        let bothRows = CredentialSaveRows(
            showUsernameRow: true,
            showPasswordRow: true,
            passwordDependsOnUsername: true
        )
        XCTAssertEqual(
            CredentialSaveDecision.neverAsking(rows: bothRows),
            CredentialSaveDecision(
                saveUsername: false,
                savePassword: false,
                neverAskUsername: true,
                neverAskPassword: true
            )
        )
    }

    // MARK: - Keyboard-interactive password heuristic

    func testLoneEchoOffPromptIsPasswordPrompt() {
        XCTAssertTrue(CredentialSavePolicy.isLonePasswordPrompt([(text: "Password: ", echo: false)]))
    }

    func testLoneEchoedPromptIsNotPasswordPrompt() {
        XCTAssertFalse(CredentialSavePolicy.isLonePasswordPrompt([(text: "Username: ", echo: true)]))
    }

    func testMultiPromptRoundIsNotPasswordPrompt() {
        XCTAssertFalse(
            CredentialSavePolicy.isLonePasswordPrompt([
                (text: "Password: ", echo: false),
                (text: "Verification code: ", echo: false)
            ])
        )
    }

    func testEmptyPromptRoundIsNotPasswordPrompt() {
        XCTAssertFalse(CredentialSavePolicy.isLonePasswordPrompt([]))
    }

    // MARK: - Fingerprint-change credential confirmation

    func testNoConfirmationWhenHostKeyUnchanged() {
        XCTAssertFalse(
            CredentialSavePolicy.shouldConfirmSavedCredentials(
                hostKeyChanged: false,
                hasSavedUsername: true,
                hasKey: true,
                hasStoredPassword: true
            )
        )
    }

    func testNoConfirmationWhenNothingSaved() {
        XCTAssertFalse(
            CredentialSavePolicy.shouldConfirmSavedCredentials(
                hostKeyChanged: true,
                hasSavedUsername: false,
                hasKey: false,
                hasStoredPassword: false
            )
        )
    }

    func testConfirmationRequiredForSavedUsername() {
        XCTAssertTrue(
            CredentialSavePolicy.shouldConfirmSavedCredentials(
                hostKeyChanged: true,
                hasSavedUsername: true,
                hasKey: false,
                hasStoredPassword: false
            )
        )
    }

    func testConfirmationRequiredForKeyOnlyConnection() {
        XCTAssertTrue(
            CredentialSavePolicy.shouldConfirmSavedCredentials(
                hostKeyChanged: true,
                hasSavedUsername: false,
                hasKey: true,
                hasStoredPassword: false
            )
        )
    }

    func testConfirmationRequiredForStoredPasswordOnly() {
        XCTAssertTrue(
            CredentialSavePolicy.shouldConfirmSavedCredentials(
                hostKeyChanged: true,
                hasSavedUsername: false,
                hasKey: false,
                hasStoredPassword: true
            )
        )
    }

    // MARK: - SavedConnection defaults

    func testSavedConnectionDefaultsToAskingBeforeSaving() {
        let connection = SavedConnection(host: "example.com")
        XCTAssertFalse(connection.neverAskSaveUsername)
        XCTAssertFalse(connection.neverAskSavePassword)
        XCTAssertFalse(connection.autoReconnectOnBackgroundDisconnect)
        XCTAssertFalse(connection.autoRunCommandEnabled)
        XCTAssertEqual(connection.autoRunCommand, SavedConnection.defaultAutoRunCommand)
        XCTAssertTrue(connection.autoRunCommand.contains("tmux -CC new -s ssh-app-session"))
        XCTAssertNil(connection.pendingAutoRunCommand)

        connection.autoRunCommandEnabled = true
        XCTAssertEqual(connection.pendingAutoRunCommand, SavedConnection.defaultAutoRunCommand)

        connection.autoRunCommand = "   \n  "
        XCTAssertNil(connection.pendingAutoRunCommand)
    }
}

@MainActor
final class KeyboardInteractiveCaptureTests: XCTestCase {

    func testSingleRoundLonePasswordPromptIsCaptured() {
        let capture = KeyboardInteractiveCapture()
        capture.recordRound(prompts: [(text: "Password: ", echo: false)], responses: ["hunter2"])
        XCTAssertEqual(capture.candidatePassword, "hunter2")
    }

    func testEmptyResponseIsNotCaptured() {
        let capture = KeyboardInteractiveCapture()
        capture.recordRound(prompts: [(text: "Password: ", echo: false)], responses: [""])
        XCTAssertNil(capture.candidatePassword)
    }

    func testMultiPromptRoundIsNotCaptured() {
        let capture = KeyboardInteractiveCapture()
        capture.recordRound(
            prompts: [(text: "Password: ", echo: false), (text: "Verification code: ", echo: false)],
            responses: ["hunter2", "123456"]
        )
        XCTAssertNil(capture.candidatePassword)
    }

    func testSecondRoundClearsCapturedPassword() {
        let capture = KeyboardInteractiveCapture()
        capture.recordRound(prompts: [(text: "Password: ", echo: false)], responses: ["hunter2"])
        capture.recordRound(prompts: [(text: "Verification code: ", echo: false)], responses: ["123456"])
        XCTAssertNil(
            capture.candidatePassword,
            "Multi-round exchanges (e.g. password + OTP) must never offer a response as the password"
        )
    }
}
