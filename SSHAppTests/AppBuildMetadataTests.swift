import XCTest
@testable import SSHApp

final class AppBuildMetadataTests: XCTestCase {
    func testUsesBuildInfoDictionaryValues() {
        let metadata = AppBuildMetadata(infoDictionary: [
            AppBuildMetadata.sourceRepositoryURLKey: "https://github.com/ClarifiedLabs/sshapp",
            AppBuildMetadata.sourceCommitKey: "1234567890abcdef",
            AppBuildMetadata.sourceVersionKey: "v1.2.3",
        ])

        XCTAssertEqual(metadata.repositoryURL.absoluteString, "https://github.com/ClarifiedLabs/sshapp")
        XCTAssertEqual(metadata.repositoryDisplayName, "github.com/ClarifiedLabs/sshapp")
        XCTAssertEqual(metadata.sourceCommit, "1234567890abcdef")
        XCTAssertEqual(metadata.shortSourceCommit, "1234567890ab")
        XCTAssertEqual(metadata.sourceVersion, "v1.2.3")
        XCTAssertEqual(
            metadata.sourceCommitURL?.absoluteString,
            "https://github.com/ClarifiedLabs/sshapp/commit/1234567890abcdef"
        )
    }

    func testFallsBackWhenBuildInfoIsMissing() {
        let metadata = AppBuildMetadata(infoDictionary: [:])

        XCTAssertEqual(metadata.repositoryURL, AppBuildMetadata.defaultRepositoryURL)
        XCTAssertEqual(metadata.repositoryDisplayName, "github.com/ClarifiedLabs/sshapp")
        XCTAssertEqual(metadata.sourceCommit, "unknown")
        XCTAssertEqual(metadata.shortSourceCommit, "unknown")
        XCTAssertEqual(metadata.sourceVersion, "dev")
        XCTAssertNil(metadata.sourceCommitURL)
    }

    func testDeclaresAppLicenseMetadata() {
        XCTAssertEqual(AppBuildMetadata.licenseName, "MIT License")
        XCTAssertEqual(AppBuildMetadata.licenseFileName, "sshapp-mit.txt")
    }
}
