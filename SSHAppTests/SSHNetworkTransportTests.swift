import XCTest
@testable import SSHApp

final class SSHNetworkTransportTests: XCTestCase {
    func testNilAuthListWithAuthenticatedSessionMeansNoneAuthSucceeded() throws {
        let result = try SSH2Transport.classifyAuthenticationDiscovery(
            methodList: nil,
            isAuthenticated: true,
            lastError: 0
        )

        XCTAssertEqual(result, .authenticated)
    }

    func testNilAuthListWithoutAuthenticatedSessionIsNotAcceptedAsNoneAuth() {
        XCTAssertThrowsError(
            try SSH2Transport.classifyAuthenticationDiscovery(
                methodList: nil,
                isAuthenticated: false,
                lastError: -18
            )
        ) { error in
            guard case SSH2Error.authFailed(let message) = error else {
                return XCTFail("Expected authFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("rc=-18"))
        }
    }

    func testAdvertisedAuthenticationMethodsArePreserved() throws {
        let result = try SSH2Transport.classifyAuthenticationDiscovery(
            methodList: "publickey,password,keyboard-interactive",
            isAuthenticated: false,
            lastError: 0
        )

        XCTAssertEqual(
            result,
            .methods(["publickey", "password", "keyboard-interactive"])
        )
    }

    func testAuthenticationRejectionAndInfrastructureFailuresAreDistinct() {
        XCTAssertEqual(
            SSH2Transport.classifyAuthenticationFailure(
                code: -18,
                operation: "Password",
                waitingForInteraction: false
            ),
            .authFailed("Password authentication failed")
        )
        XCTAssertEqual(
            SSH2Transport.classifyAuthenticationFailure(
                code: -43,
                operation: "Password",
                waitingForInteraction: false
            ),
            .socketFailed("Password transport failed (rc=-43)")
        )
        XCTAssertEqual(
            SSH2Transport.classifyAuthenticationFailure(
                code: -9,
                operation: "Keyboard-interactive",
                waitingForInteraction: true
            ),
            .authenticationTimedOut(waitingForInteraction: true)
        )
        XCTAssertEqual(
            SSH2Transport.classifyAuthenticationFailure(
                code: -5,
                operation: "Password",
                waitingForInteraction: false
            ),
            .socketFailed("Password failed unexpectedly (rc=-5)")
        )
    }

    func testDiscoverySocketFailureIsNotClassifiedAsCredentialRejection() {
        XCTAssertThrowsError(
            try SSH2Transport.classifyAuthenticationDiscovery(
                methodList: nil,
                isAuthenticated: false,
                lastError: -43
            )
        ) { error in
            XCTAssertEqual(
                error as? SSH2Error,
                .socketFailed("Authentication discovery transport failed (rc=-43)")
            )
        }
    }

    func testDiscoveryProtocolFailureIsNotClassifiedAsCredentialRejection() {
        XCTAssertThrowsError(
            try SSH2Transport.classifyAuthenticationDiscovery(
                methodList: nil,
                isAuthenticated: false,
                lastError: -14
            )
        ) { error in
            XCTAssertEqual(
                error as? SSH2Error,
                .socketFailed(
                    "Authentication discovery failed unexpectedly (rc=-14)"
                )
            )
        }
    }

    func testEmptyAdvertisedAuthenticationListIsPreserved() throws {
        XCTAssertEqual(
            try SSH2Transport.classifyAuthenticationDiscovery(
                methodList: "",
                isAuthenticated: false,
                lastError: 0
            ),
            .methods([])
        )
    }

    func testNilAuthListWithoutAuthenticationFailsEvenWhenLastErrorIsZero() {
        XCTAssertThrowsError(
            try SSH2Transport.classifyAuthenticationDiscovery(
                methodList: nil,
                isAuthenticated: false,
                lastError: 0
            )
        ) { error in
            XCTAssertEqual(
                error as? SSH2Error,
                .socketFailed("Authentication discovery failed unexpectedly (rc=0)")
            )
        }
    }

    func testOutboundTransportUsesNetworkFrameworkInsteadOfBSDConnect() throws {
        let streamSource = try readSourceFile("SSHApp/SSH/SSHNetworkStream.swift")
        let transportSource = try readSourceFile("SSHApp/SSH/SSH2Transport.swift")

        XCTAssertTrue(streamSource.contains("import Network"))
        XCTAssertTrue(streamSource.contains("let connection = NWConnection("))
        XCTAssertTrue(transportSource.contains("let stream = SSHNetworkStream("))
        XCTAssertTrue(transportSource.contains("sshapp_configure_session_io"))
        XCTAssertFalse(transportSource.contains("getaddrinfo"))
        XCTAssertFalse(streamSource.contains("Darwin.connect"))
        XCTAssertFalse(transportSource.contains("Darwin.connect"))
    }

    func testAuthenticationDeadlineCheckAndNetworkSendShareOneGate() throws {
        let source = try readSourceFile("SSHApp/SSH/SSHNetworkStream.swift")
        let body = try extractMethodBody(from: source, methodName: "func send")
        guard let deadlineCheck = body.range(of: "if authenticationWaitHasExpired()"),
              let send = body.range(of: "connection.send(content: data"),
              let unlock = body.range(
                of: "condition.unlock()",
                range: send.upperBound..<body.endIndex
              ) else {
            return XCTFail("Could not find authentication send gate")
        }

        XCTAssertLessThan(deadlineCheck.lowerBound, send.lowerBound)
        XCTAssertLessThan(send.lowerBound, unlock.lowerBound)
    }

    func testDNSFailureDoesNotWaitUntilConnectionTimeout() throws {
        XCTAssertTrue(SSHNetworkStream.isNameResolutionFailure(.dns(-65_554)))
        XCTAssertFalse(SSHNetworkStream.isNameResolutionFailure(.posix(.ETIMEDOUT)))

        let source = try readSourceFile("SSHApp/SSH/SSHNetworkStream.swift")
        XCTAssertTrue(source.contains(".failed(\"DNS lookup failed:"))
    }

    func testConnectionAttemptCanBeCancelledWithoutWaitingBehindTransportQueue() throws {
        let transportSource = try readSourceFile("SSHApp/SSH/SSH2Transport.swift")
        let sessionSource = try readSourceFile("SSHApp/SSH/SSHSession.swift")
        let tabSource = try readSourceFile("SSHApp/Models/Tab.swift")
        let mainSource = try readSourceFile("SSHApp/Views/MainView.swift")
        let closeBody = try extractMethodBody(from: mainSource, methodName: "private func closeTab")

        XCTAssertTrue(transportSource.contains("withTaskCancellationHandler"))
        XCTAssertTrue(sessionSource.contains("transport.cancelPendingIO()"))
        XCTAssertTrue(tabSource.contains("var connectionTask: Task<Void, Never>?"))
        XCTAssertTrue(closeBody.contains("tab.connectionTask?.cancel()"))
    }

    func testConnectionBannerShowsPhaseTickerAndCancelControl() throws {
        let source = try readSourceFile("SSHApp/Views/TerminalTab.swift")

        XCTAssertTrue(source.contains("TimelineView(.periodic(from: .now, by: 1))"))
        XCTAssertTrue(source.contains("progress.phase.label"))
        XCTAssertTrue(source.contains("terminal.connection.cancel"))
        XCTAssertTrue(source.contains("onDisconnect(tab)"))
        XCTAssertTrue(
            source.contains(".overlay(alignment: .center) {\n            if let progress = tab.session?.connectionProgress"),
            "Connection progress must float in the center instead of covering the first terminal row"
        )
    }

    func testConnectionBannerClearsBeforeHostVerificationPrompt() throws {
        let source = try readSourceFile("SSHApp/SSH/SSHSession.swift")
        let body = try extractMethodBody(
            from: source,
            methodName: "func connectAndAuthenticate"
        )

        guard let connected = body.range(of: "isConnected = true"),
              let cleared = body.range(
                of: "connectionProgress = nil",
                range: connected.upperBound..<body.endIndex
              ),
              let verification = body.range(
                of: "verifyHostKey(transport:",
                range: cleared.upperBound..<body.endIndex
              ) else {
            return XCTFail("Expected progress to clear before host verification")
        }

        XCTAssertLessThan(connected.lowerBound, cleared.lowerBound)
        XCTAssertLessThan(cleared.lowerBound, verification.lowerBound)
        XCTAssertFalse(body.contains("phase: .verifyingHost"))
        XCTAssertFalse(body.contains("phase: .authenticating"))
    }

    private func extractMethodBody(from source: String, methodName: String) throws -> String {
        guard let methodRange = source.range(of: methodName) else {
            throw ExtractionError.methodNotFound(methodName)
        }
        guard let openBrace = source[methodRange.upperBound...].firstIndex(of: "{") else {
            throw ExtractionError.openBraceNotFound(methodName)
        }

        var depth = 0
        var index = openBrace
        while index < source.endIndex {
            switch source[index] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(source[openBrace...index])
                }
            default:
                break
            }
            index = source.index(after: index)
        }
        throw ExtractionError.closeBraceNotFound(methodName)
    }

    private enum ExtractionError: Error {
        case methodNotFound(String)
        case openBraceNotFound(String)
        case closeBraceNotFound(String)
    }
}
