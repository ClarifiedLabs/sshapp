import XCTest

final class ModalToolbarTests: XCTestCase {
    func testConnectionAndSettingsActionsHaveTitlesSymbolsAndSemanticPlacements() throws {
        let connection = try readSourceFile("SSHApp/Views/ConnectionSheet.swift")
        let main = try readSourceFile("SSHApp/Views/MainView.swift")
        let settings = try extractMethodBody(from: main, methodName: "struct SettingsSheet")

        for label in [
            "Label(\"Cancel\", systemImage: \"xmark\")",
            "Label(\"Save\", systemImage: \"square.and.arrow.down\")",
            "Label(\"Connect\", systemImage: \"arrow.right.circle\")"
        ] {
            XCTAssertTrue(connection.contains(label), "Missing \(label)")
        }
        XCTAssertTrue(connection.contains("ToolbarItem(placement: .cancellationAction)"))
        XCTAssertTrue(connection.contains("ToolbarItemGroup(placement: .confirmationAction)"))
        XCTAssertTrue(settings.contains("Label(\"Done\", systemImage: \"checkmark\")"))
        XCTAssertTrue(settings.contains("ToolbarItem(placement: .confirmationAction)"))
        XCTAssertTrue(settings.contains("settings.done"))
    }

    func testCredentialAndInstallSheetsKeepAccessiblePrimaryAndCancellationActions() throws {
        let install = try readSourceFile("SSHApp/Views/InstallSSHKeySheet.swift")
        let save = try readSourceFile("SSHApp/Views/CredentialSaveSheet.swift")

        XCTAssertTrue(install.contains("installResult == nil ? \"Cancel\" : \"Done\""))
        XCTAssertTrue(install.contains("systemImage: installResult == nil ? \"xmark\" : \"checkmark\""))
        XCTAssertTrue(install.contains("Label(\"Install\", systemImage: \"key\")"))
        XCTAssertTrue(install.contains("installSSHKey.dismiss"))
        XCTAssertTrue(install.contains("installSSHKey.install"))
        XCTAssertTrue(save.contains("Label(\"Not Now\", systemImage: \"xmark\")"))
        XCTAssertTrue(save.contains("Label(\"Save\", systemImage: \"square.and.arrow.down\")"))
        XCTAssertTrue(save.contains("credentialSave.notNow"))
        XCTAssertTrue(save.contains("credentialSave.save"))
        for source in [install, save] {
            XCTAssertTrue(source.contains(".cancellationAction"))
            XCTAssertTrue(source.contains(".confirmationAction"))
        }
    }

    func testCredentialEditingAndGenerationToolbarsAreAdaptive() throws {
        let source = try readSourceFile("SSHApp/Views/CredentialsView.swift")

        XCTAssertTrue(source.contains("Label(\"Cancel\", systemImage: \"xmark\")"))
        XCTAssertTrue(source.contains("Label(\"Save\", systemImage: \"checkmark\")"))
        XCTAssertTrue(source.contains("Label(actionTitle, systemImage: \"checkmark\")"))
        XCTAssertTrue(source.contains("ToolbarItem(placement: .cancellationAction)"))
        XCTAssertTrue(source.contains("ToolbarItem(placement: .confirmationAction)"))
        XCTAssertFalse(source.contains("ToolbarItem(placement: .topBarLeading)"))
        XCTAssertFalse(source.contains("ToolbarItem(placement: .topBarTrailing)"))
    }
}
