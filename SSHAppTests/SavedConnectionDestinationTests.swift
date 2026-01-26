import XCTest
@testable import SSHApp

final class SavedConnectionDestinationTests: XCTestCase {
    func testDestinationParserAcceptsHostWithoutUsername() {
        XCTAssertEqual(
            ConnectionDestination.parse(" example.com "),
            ConnectionDestination(username: nil, host: "example.com")
        )
    }

    func testDestinationParserAcceptsUserAtHost() {
        XCTAssertEqual(
            ConnectionDestination.parse(" test@example.com "),
            ConnectionDestination(username: "test", host: "example.com")
        )
    }

    func testDestinationParserRejectsEmptyAndMalformedValues() {
        XCTAssertNil(ConnectionDestination.parse(""))
        XCTAssertNil(ConnectionDestination.parse("   "))
        XCTAssertNil(ConnectionDestination.parse("@example.com"))
        XCTAssertNil(ConnectionDestination.parse("test@"))
        XCTAssertNil(ConnectionDestination.parse("test@example.com@other"))
    }

    func testDisplayDestinationUsesUsernameOnlyWhenSaved() {
        XCTAssertEqual(
            ConnectionDestination.display(username: "test", host: "example.com", port: 22),
            "test@example.com"
        )
        XCTAssertEqual(
            ConnectionDestination.display(username: nil, host: "example.com", port: 22),
            "example.com"
        )
    }

    func testDisplayDestinationAddsNonDefaultPortSuffix() {
        XCTAssertEqual(
            ConnectionDestination.display(username: "test", host: "example.com", port: 2222),
            "test@example.com:2222"
        )
        XCTAssertEqual(
            ConnectionDestination.display(username: nil, host: "example.com", port: 2222),
            "example.com:2222"
        )
    }
}
