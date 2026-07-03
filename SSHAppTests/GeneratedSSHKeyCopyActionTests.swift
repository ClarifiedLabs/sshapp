import XCTest
@testable import SSHApp

final class GeneratedSSHKeyCopyActionTests: XCTestCase {
    @MainActor
    func testCopyPublicKeyWritesPasteboardBeforeDismissingSheet() {
        let publicKey = "ssh-ed25519 AAAATEST generated-key"
        var pastedValue: String?
        var didDismiss = false

        GeneratedSSHKeyCopyAction.copyPublicKey(
            publicKey,
            writeToPasteboard: { pastedValue = $0 }
        ) {
            XCTAssertEqual(
                pastedValue,
                publicKey,
                "The generated public key must be copied before the sheet closes."
            )
            didDismiss = true
        }

        XCTAssertTrue(didDismiss)
    }

    func testGeneratedKeySheetCopyButtonUsesCopyAndDismissAction() throws {
        let source = try readSourceFile("SSHApp/Views/CredentialsView.swift")

        let generatedState = try XCTUnwrap(source.range(of: "if let generatedKey {"))
        let copyButton = try XCTUnwrap(source.range(of: #"Button("Copy Public Key")"#, range: generatedState.lowerBound..<source.endIndex))
        let copyAction = try XCTUnwrap(
            source.range(
                of: "GeneratedSSHKeyCopyAction.copyPublicKey(generatedKey.publicKey)",
                range: copyButton.lowerBound..<source.endIndex
            )
        )
        let dismissCall = try XCTUnwrap(source.range(of: "dismiss()", range: copyAction.lowerBound..<source.endIndex))
        let doneButton = try XCTUnwrap(source.range(of: #"Button("Done")"#, range: copyAction.lowerBound..<source.endIndex))

        XCTAssertLessThan(copyAction.lowerBound, dismissCall.lowerBound)
        XCTAssertLessThan(dismissCall.lowerBound, doneButton.lowerBound)
    }
}
