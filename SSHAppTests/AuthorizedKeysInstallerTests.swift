import XCTest
@testable import SSHApp

final class AuthorizedKeysInstallerTests: XCTestCase {
    func testInstallCommandCreatesSSHDirectoryAndAuthorizedKeysFile() throws {
        let key = try makeKey(name: "work")

        let command = try AuthorizedKeysInstaller.makeInstallCommand(keys: [key])

        XCTAssertTrue(command.hasPrefix("exec sh -c '"))
        XCTAssertTrue(command.contains("cd || exit 1"))
        XCTAssertTrue(command.contains("umask 077"))
        XCTAssertTrue(command.contains("AUTH_KEY_FILE=\".ssh/authorized_keys\""))
        XCTAssertTrue(command.contains("AUTH_KEY_DIR=$(dirname \"$AUTH_KEY_FILE\")"))
        XCTAssertTrue(command.contains("mkdir -p \"$AUTH_KEY_DIR\" || exit 1"))
        XCTAssertTrue(command.contains(": >> \"$AUTH_KEY_FILE\" || exit 1"))
        XCTAssertTrue(command.contains("chmod 700 \"$AUTH_KEY_DIR\""))
        XCTAssertTrue(command.contains("chmod 600 \"$AUTH_KEY_FILE\""))
        XCTAssertTrue(command.contains(key.publicKey))
    }

    func testInstallCommandHandlesSshCopyIdRemoteFileEdgeCases() throws {
        let key = try makeKey(name: "work")

        let command = try AuthorizedKeysInstaller.makeInstallCommand(keys: [key])

        XCTAssertTrue(command.contains("[ -f /etc/openwrt_release ]"))
        XCTAssertTrue(command.contains("AUTH_KEY_FILE=/etc/dropbear/authorized_keys"))
        XCTAssertTrue(command.contains("[ \"$(uname -s)\" = \"Haiku\" ]"))
        XCTAssertTrue(command.contains("AUTH_KEY_FILE=config/settings/ssh/authorized_keys"))
        XCTAssertTrue(command.contains("tail -1c \"$AUTH_KEY_FILE\""))
        XCTAssertTrue(command.contains("echo >> \"$AUTH_KEY_FILE\" || exit 1"))
        XCTAssertTrue(command.contains("restorecon -F \"$AUTH_KEY_DIR\" \"$AUTH_KEY_FILE\""))
    }

    func testInstallCommandSkipsKeysAlreadyPresentByKeyTypeAndBlob() throws {
        let key = try makeKey(name: "deploy")

        let command = try AuthorizedKeysInstaller.makeInstallCommand(keys: [key])

        XCTAssertTrue(command.contains("key_id=$(printf"))
        XCTAssertTrue(command.contains("{print $1 \" \" $2}"))
        XCTAssertTrue(command.contains("awk -v key_id=\"$key_id\""))
        XCTAssertTrue(command.contains("$i \" \" $(i + 1) == key_id"))
        XCTAssertTrue(command.contains("\"$key\" >> \"$AUTH_KEY_FILE\" || exit 1"))
    }

    func testInstallCommandChoosesDelimiterThatDoesNotAppearInPayload() throws {
        let key = try makeKey(name: "work", publicKeySuffix: "__SSHAPP_AUTHORIZED_KEYS_0__")

        let command = try AuthorizedKeysInstaller.makeInstallCommand(keys: [key])

        XCTAssertFalse(command.contains("done <<'\\''__SSHAPP_AUTHORIZED_KEYS_0__'\\''"))
        XCTAssertTrue(command.contains("done <<'\\''__SSHAPP_AUTHORIZED_KEYS_1__'\\''"))
    }

    func testInstallCommandRejectsEmptySelection() {
        XCTAssertThrowsError(try AuthorizedKeysInstaller.makeInstallCommand(keys: [])) { error in
            XCTAssertEqual(error as? AuthorizedKeysInstaller.InstallError, .noKeysSelected)
        }
    }

    func testInstallCommandRejectsMultilinePublicKey() throws {
        let validKey = try makeKey(name: "bad")
        let invalidKey = SSHKey(
            id: validKey.id,
            name: validKey.name,
            publicKey: "\(validKey.publicKey)\nmalformed",
            fingerprint: validKey.fingerprint,
            createdAt: validKey.createdAt,
            keyType: validKey.keyType
        )

        XCTAssertThrowsError(try AuthorizedKeysInstaller.makeInstallCommand(keys: [invalidKey])) { error in
            XCTAssertEqual(error as? AuthorizedKeysInstaller.InstallError, .invalidPublicKey("bad"))
        }
    }

    func testParseInstallSummary() throws {
        let result = try AuthorizedKeysInstaller.parseInstallSummary(
            from: "noise\nsshapp-installed=2 existing=1 invalid=0\n",
            selectedCount: 3
        )

        XCTAssertEqual(
            result,
            AuthorizedKeysInstallResult(selectedCount: 3, installedCount: 2, existingCount: 1)
        )
        XCTAssertEqual(result.summary, "2 keys installed; 1 already present.")
    }

    func testParseInstallSummaryRejectsMissingSummary() {
        XCTAssertThrowsError(
            try AuthorizedKeysInstaller.parseInstallSummary(from: "done", selectedCount: 1)
        ) { error in
            guard case .missingSummary = error as? AuthorizedKeysInstaller.InstallError else {
                return XCTFail("Expected missingSummary, got \(error)")
            }
        }
    }

    private func makeKey(name: String, publicKeySuffix: String = "") throws -> SSHKey {
        let generated = try SSHKeyGenerator.generateEd25519Key(name: name).sshKey
        return SSHKey(
            id: generated.id,
            name: generated.name,
            publicKey: [generated.publicKey, publicKeySuffix]
                .filter { !$0.isEmpty }
                .joined(separator: " "),
            fingerprint: generated.fingerprint,
            createdAt: Date(timeIntervalSince1970: 0),
            keyType: generated.keyType
        )
    }
}
