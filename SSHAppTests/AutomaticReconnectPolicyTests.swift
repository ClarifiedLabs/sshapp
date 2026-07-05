import XCTest
@testable import SSHApp

final class AutomaticReconnectPolicyTests: XCTestCase {
    func testIsEligibleFalseWithoutUsernameEvenWhenPasswordExists() {
        XCTAssertFalse(
            AutomaticReconnectPolicy.isEligible(
                username: nil,
                hasStoredPassword: true,
                hasUsableKey: false
            )
        )
    }

    func testIsEligibleFalseWithoutUsernameEvenWhenKeyExists() {
        XCTAssertFalse(
            AutomaticReconnectPolicy.isEligible(
                username: nil,
                hasStoredPassword: false,
                hasUsableKey: true
            )
        )
    }

    func testIsEligibleFalseWithWhitespaceUsername() {
        XCTAssertFalse(
            AutomaticReconnectPolicy.isEligible(
                username: "  \n\t  ",
                hasStoredPassword: true,
                hasUsableKey: true
            )
        )
    }

    func testIsEligibleFalseWithUsernameButNoSavedCredential() {
        XCTAssertFalse(
            AutomaticReconnectPolicy.isEligible(
                username: "dev",
                hasStoredPassword: false,
                hasUsableKey: false
            )
        )
    }

    func testIsEligibleTrueWithUsernameAndStoredPassword() {
        XCTAssertTrue(
            AutomaticReconnectPolicy.isEligible(
                username: "dev",
                hasStoredPassword: true,
                hasUsableKey: false
            )
        )
    }

    func testIsEligibleTrueWithUsernameAndUsableKey() {
        XCTAssertTrue(
            AutomaticReconnectPolicy.isEligible(
                username: "dev",
                hasStoredPassword: false,
                hasUsableKey: true
            )
        )
    }

    func testNormalizedEnabledReturnsFalseWhenRequestedButIneligible() {
        XCTAssertFalse(
            AutomaticReconnectPolicy.normalizedEnabled(
                true,
                username: "dev",
                hasStoredPassword: false,
                hasUsableKey: false
            )
        )
    }
}
