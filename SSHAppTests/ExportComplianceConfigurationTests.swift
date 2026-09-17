import XCTest

final class ExportComplianceConfigurationTests: XCTestCase {
    private let exportComplianceKey = "ITSAppUsesNonExemptEncryption"

    func testBuiltInfoPlistDeclaresExemptEncryptionUsage() throws {
        let plist = try XCTUnwrap(Bundle.main.infoDictionary)
        let value = try XCTUnwrap(plist[exportComplianceKey] as? Bool)

        XCTAssertFalse(value)
    }

    func testTargetBuildSettingsDoNotOverrideExportComplianceToNonExempt() throws {
        let project = try readSourceFile("SSHApp.xcodeproj/project.pbxproj")
        let overrideLines = project
            .components(separatedBy: .newlines)
            .filter { $0.contains("INFOPLIST_KEY_\(exportComplianceKey)") }

        for line in overrideLines {
            XCTAssertTrue(
                line.contains(" = NO;"),
                "Target build setting must not override \(exportComplianceKey) to non-exempt: \(line)"
            )
        }
    }

    func testBuiltAppInfoPlistDeclaresExemptEncryptionUsage() throws {
        let value = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: exportComplianceKey) as? Bool
        )

        XCTAssertFalse(value)
    }

}
