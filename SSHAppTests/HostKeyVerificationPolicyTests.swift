import XCTest
@testable import SSHApp

final class HostKeyVerificationPolicyTests: XCTestCase {
    func testRequireKnownMatchAllowsMatch() {
        XCTAssertNil(
            HostKeyVerificationPolicy.requireKnownMatch.nonInteractiveFailure(for: .match)
        )
    }

    func testRequireKnownMatchMapsMismatchToNonInteractiveFailure() {
        XCTAssertEqual(
            HostKeyVerificationPolicy.requireKnownMatch.nonInteractiveFailure(
                for: .mismatch(oldFingerprint: "SHA256:old", newFingerprint: "SHA256:new")
            ),
            .hostKeyMismatch(oldFingerprint: "SHA256:old", newFingerprint: "SHA256:new")
        )
    }

    func testRequireKnownMatchMapsUnknownHostToNonInteractiveFailure() {
        XCTAssertEqual(
            HostKeyVerificationPolicy.requireKnownMatch.nonInteractiveFailure(
                for: .notFound(fingerprint: "SHA256:new", keyType: "ssh-ed25519")
            ),
            .hostKeyNotTrusted(fingerprint: "SHA256:new", keyType: "ssh-ed25519")
        )
    }

    func testInteractivePolicyDoesNotPreemptMismatchOrUnknownHostPrompts() {
        XCTAssertNil(
            HostKeyVerificationPolicy.interactive.nonInteractiveFailure(
                for: .mismatch(oldFingerprint: "SHA256:old", newFingerprint: "SHA256:new")
            )
        )
        XCTAssertNil(
            HostKeyVerificationPolicy.interactive.nonInteractiveFailure(
                for: .notFound(fingerprint: "SHA256:new", keyType: "ssh-ed25519")
            )
        )
    }
}
