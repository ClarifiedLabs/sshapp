import XCTest
@testable import SSHApp

final class ThirdPartyNoticeTests: XCTestCase {
    func testNoticeManifestReferencesTrackedLicenseFiles() throws {
        let notices = try loadManifest()
        let expectedIDs: Set<String> = [
            "sshapp-ghostty-wrapper",
            "ghostty",
            "iterm2-color-schemes",
            "msdisplaylink",
            "libssh2",
            "openssl",
            "jetbrains-mono",
        ]

        XCTAssertEqual(Set(notices.map(\.id)), expectedIDs)

        for notice in notices {
            XCTAssertFalse(notice.name.isEmpty)
            XCTAssertFalse(notice.purpose.isEmpty)
            XCTAssertFalse(notice.source.isEmpty)
            XCTAssertFalse(notice.version.isEmpty)
            XCTAssertFalse(notice.licenseName.isEmpty)
            XCTAssertFalse(notice.copyright.isEmpty)
            XCTAssertTrue(notice.shippedInApp)

            let licenseURL = legalRoot().appendingPathComponent(notice.licenseFile)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: licenseURL.path),
                "\(notice.id) references missing license file \(notice.licenseFile)"
            )

            let licenseText = try String(contentsOf: licenseURL, encoding: .utf8)
            XCTAssertGreaterThan(licenseText.count, 100)
        }
    }

    func testRepoNoticeInventoryMentionsEveryManifestDependency() throws {
        let notices = try loadManifest()
        let repoNotice = try readSourceFile("THIRD_PARTY_NOTICES.md")

        for notice in notices {
            XCTAssertTrue(
                repoNotice.contains(notice.name),
                "THIRD_PARTY_NOTICES.md must mention \(notice.name)"
            )
            XCTAssertTrue(
                repoNotice.contains(notice.licenseFile),
                "THIRD_PARTY_NOTICES.md must point to \(notice.licenseFile)"
            )
        }
    }

    func testBuiltAppBundlesNoticeResources() throws {
        let notices = try loadManifest()

        XCTAssertNotNil(Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "json"))
        XCTAssertNotNil(Bundle.main.url(forResource: "sshapp-mit", withExtension: "txt"))

        for notice in notices {
            let file = notice.licenseFile as NSString
            XCTAssertNotNil(
                Bundle.main.url(
                    forResource: file.deletingPathExtension,
                    withExtension: file.pathExtension
                ),
                "App bundle must include \(notice.licenseFile)"
            )
        }
    }

    func testAppLicenseResourceMatchesRepoLicense() throws {
        let repoLicense = try readSourceFile("LICENSE")
        let bundledSourceLicense = try String(
            contentsOf: legalRoot().appendingPathComponent(AppBuildMetadata.licenseFileName),
            encoding: .utf8
        )

        XCTAssertEqual(bundledSourceLicense, repoLicense)
        XCTAssertEqual(AppBuildMetadata.licenseText(bundle: Bundle.main), repoLicense)
    }

    func testOpenSourceLicensesSettingsDestinationIsWired() throws {
        let mainSource = try readSourceFile("SSHApp/Views/MainView.swift")
        let topBarSource = try readSourceFile("SSHApp/Views/UnifiedTopBar.swift")

        XCTAssertTrue(mainSource.contains("case .licenses:"))
        XCTAssertTrue(mainSource.contains("OpenSourceLicensesView()"))
        XCTAssertTrue(mainSource.contains("case credentials, tmux, font, theme, licenses"))
        XCTAssertTrue(topBarSource.contains("onSettings(.licenses)"))
        XCTAssertTrue(topBarSource.contains("settings.licenses"))
    }

    func testSettingsMenuUsesShortLicenseAndTmuxLabelsInExpectedOrder() throws {
        let topBarSource = try readSourceFile("SSHApp/Views/UnifiedTopBar.swift")

        XCTAssertFalse(topBarSource.contains("Tmux Integration"))
        XCTAssertFalse(topBarSource.contains("Open Source Licenses"))
        XCTAssertTrue(topBarSource.contains("Label(\"tmux\""))
        XCTAssertTrue(topBarSource.contains("Label(\"Licenses\""))

        let themeRange = try XCTUnwrap(topBarSource.range(of: "settings.theme"))
        let tmuxRange = try XCTUnwrap(topBarSource.range(of: "settings.tmux"))
        let licensesRange = try XCTUnwrap(topBarSource.range(of: "settings.licenses"))

        XCTAssertLessThan(themeRange.lowerBound, tmuxRange.lowerBound)
        XCTAssertLessThan(tmuxRange.lowerBound, licensesRange.lowerBound)
    }

    func testLicensesScreenShowsAppMetadataBeforeThirdPartyNotices() throws {
        let licensesSource = try readSourceFile("SSHApp/Views/OpenSourceLicensesView.swift")
        let projectSource = try readSourceFile("SSHApp.xcodeproj/project.pbxproj")
        let buildMetadataScript = try readSourceFile("scripts/embed-build-metadata.sh")

        let metadataRange = try XCTUnwrap(licensesSource.range(of: "Section(\"SSH App\")"))
        let noticesRange = try XCTUnwrap(licensesSource.range(of: "ForEach(notices)"))

        XCTAssertLessThan(metadataRange.lowerBound, noticesRange.lowerBound)
        XCTAssertTrue(licensesSource.contains("AppBuildMetadata"))
        XCTAssertTrue(licensesSource.contains("licenses.app.version"))
        XCTAssertTrue(licensesSource.contains("AppLicenseDetailView"))
        XCTAssertTrue(licensesSource.contains("licenses.app.license"))
        XCTAssertTrue(licensesSource.contains(".navigationTitle(\"Licenses\")"))
        XCTAssertTrue(projectSource.contains("Embed build metadata"))
        XCTAssertTrue(buildMetadataScript.contains("SSHAppSourceVersion"))
        XCTAssertTrue(projectSource.contains("scripts/embed-build-metadata.sh"))
    }

    private func loadManifest() throws -> [ManifestNotice] {
        let data = try Data(contentsOf: legalRoot().appendingPathComponent("ThirdPartyNotices.json"))
        return try JSONDecoder().decode([ManifestNotice].self, from: data)
    }

    private func legalRoot() -> URL {
        projectRoot().appendingPathComponent("SSHApp/Resources/Legal")
    }

}

private struct ManifestNotice: Decodable {
    let id: String
    let name: String
    let purpose: String
    let source: String
    let version: String
    let licenseName: String
    let copyright: String
    let licenseFile: String
    let shippedInApp: Bool
}
