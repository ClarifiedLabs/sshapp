import XCTest
@testable import SSHApp

@MainActor
final class TerminalLinkOpenerTests: XCTestCase {
    func testOpensHTTPAndHTTPSLinksExactlyOnce() {
        var openedURLs: [URL] = []

        XCTAssertTrue(TerminalLinkOpener.open(
            "http://example.com/path?value=1",
            using: { openedURLs.append($0) }
        ))
        XCTAssertTrue(TerminalLinkOpener.open(
            "HTTPS://example.com/secure",
            using: { openedURLs.append($0) }
        ))

        XCTAssertEqual(openedURLs.map(\.absoluteString), [
            "http://example.com/path?value=1",
            "HTTPS://example.com/secure",
        ])
    }

    func testRejectsNonWebAndMalformedLinkTargets() {
        var openedURLs: [URL] = []
        let candidates = [
            "ssh://example.com",
            "file:///etc/passwd",
            "javascript://example.com/alert(1)",
            "/tmp/no-scheme",
            "https:///missing-host",
        ]

        for candidate in candidates {
            XCTAssertFalse(
                TerminalLinkOpener.open(candidate, using: { openedURLs.append($0) }),
                "Unexpectedly accepted \(candidate)"
            )
        }

        XCTAssertTrue(openedURLs.isEmpty)
    }
}
