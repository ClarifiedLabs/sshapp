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

            let licenseURL = try legalRoot().appendingPathComponent(notice.licenseFile)
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

    func testSSHNativeNoticesMatchBuildPins() throws {
        let notices = try loadManifest()
        let script = try readSourceFile("scripts/build-libssh2.sh")
        let pins = try readSourceFile("vendor/PINS.md")
        let dependencies = try readSourceFile("docs/DEPENDENCIES.md")
        let inventory = try readSourceFile("THIRD_PARTY_NOTICES.md")

        for (id, setting) in [
            ("libssh2", "EXPECTED_LIBSSH2_COMMIT"),
            ("openssl", "EXPECTED_OPENSSL_COMMIT"),
        ] {
            let assignment = try XCTUnwrap(
                script.components(separatedBy: .newlines).first { $0.hasPrefix("\(setting)=\"") }
            )
            let revision = try XCTUnwrap(assignment.split(separator: "\"").dropFirst().first)
            XCTAssertEqual(revision.count, 40)
            let notice = try XCTUnwrap(notices.first { $0.id == id })
            XCTAssertTrue(notice.version.contains(revision), "\(id) notice must match the compiled pin")
            for document in [pins, dependencies, inventory] {
                XCTAssertTrue(document.contains(revision), "\(id) documentation must match the compiled pin")
            }
        }
    }

    func testLibSSH2LicenseMatchesPinnedSource() throws {
        let upstream = try readSourceFile("vendor/libssh2/COPYING")
        let bundled = try readSourceFile("SSHApp/Resources/Legal/libssh2-bsd-3-clause.txt")
        XCTAssertEqual(bundled, upstream)
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
        XCTAssertTrue(mainSource.contains("case connections, credentials, appLock, iCloudSync, tmux, keyboard, font, theme, licenses"))
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
        XCTAssertTrue(licensesSource.contains("licenses.app.review"))
        XCTAssertTrue(licensesSource.contains("Rate/Review"))
        XCTAssertEqual(
            AppBuildMetadata.appStoreReviewURL.absoluteString,
            "https://apps.apple.com/app/id6785688380?action=write-review"
        )
        XCTAssertTrue(licensesSource.contains(".navigationTitle(\"Licenses\")"))
        XCTAssertTrue(projectSource.contains("Embed build metadata"))
        XCTAssertTrue(buildMetadataScript.contains("SSHAppSourceVersion"))
        XCTAssertTrue(projectSource.contains("scripts/embed-build-metadata.sh"))
    }

    private func loadManifest() throws -> [ManifestNotice] {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "json"))
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([ManifestNotice].self, from: data)
    }

    private func legalRoot() throws -> URL {
        try projectRoot().appendingPathComponent("SSHApp/Resources/Legal")
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
