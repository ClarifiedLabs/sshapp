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

    func testDisplayNameFallsBackToDisplayDestinationWhenNameIsNil() {
        let connection = SavedConnection(host: "example.com", port: 22, username: "test")
        XCTAssertNil(connection.name)
        XCTAssertEqual(connection.displayName, "test@example.com")
    }

    func testDisplayNameFallsBackToDisplayDestinationWhenNameIsBlank() {
        let connection = SavedConnection(host: "example.com", port: 2222, username: nil, name: "   ")
        XCTAssertEqual(connection.displayName, "example.com:2222")
        connection.name = "\n\t "
        XCTAssertEqual(connection.displayName, "example.com:2222")
        connection.name = ""
        XCTAssertEqual(connection.displayName, "example.com:2222")
    }

    func testDisplayNameReturnsTrimmedCustomNameWhenSet() {
        let connection = SavedConnection(host: "example.com", username: "test", name: "  My Server  ")
        XCTAssertEqual(connection.displayName, "My Server")
        connection.name = "prod"
        XCTAssertEqual(connection.displayName, "prod")
    }

    func testUsesCustomNameTracksNonBlankName() {
        let connection = SavedConnection(host: "example.com", username: "test")
        XCTAssertFalse(connection.usesCustomName)
        XCTAssertNil(connection.customName)

        connection.name = "   "
        XCTAssertFalse(connection.usesCustomName, "Blank names must not count as custom labels")
        XCTAssertNil(connection.customName)

        connection.name = "Prod"
        XCTAssertTrue(connection.usesCustomName)
        XCTAssertEqual(connection.customName, "Prod")
        XCTAssertEqual(connection.displayName, "Prod")
    }
}
