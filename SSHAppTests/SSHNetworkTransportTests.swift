import XCTest
import Network
@testable import SSHApp

final class SSHNetworkTransportTests: XCTestCase {
    #if VT_TEST_HOOKS
    func testReceiveBufferBackpressurePreservesBytesAndEOF() async throws {
        // Several buffer fills, with nonuniform bytes to detect loss/reordering.
        let payload = Data((0..<(SSHNetworkStream.receiveBufferLimit * 5 + 37)).map { UInt8($0 % 251) })
        let server = try ReceiveBufferTestServer(payload: payload)
        defer { server.stop() }
        try await waitUntil("loopback listener") { server.port != nil }
        let port = try XCTUnwrap(server.port)

        for blocking in [true, false] {
            let stream = SSHNetworkStream(ioTimeout: 5)
            defer { stream.cancel() }
            try stream.connect(host: "127.0.0.1", port: port, timeout: 5, onPhaseChanged: { _ in })
            stream.setBlocking(blocking)
            try await waitForReceivePause(stream)
            let paused = stream.receiveBufferSnapshot
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertEqual(stream.receiveBufferSnapshot.bytes, paused.bytes,
                           "A stalled consumer must not accumulate more network data")

            var received = Data()
            var scratch = [UInt8](repeating: 0, count: 7_919)
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                let count = scratch.withUnsafeMutableBytes {
                    stream.receive(into: $0.baseAddress!, count: $0.count)
                }
                let snapshot = stream.receiveBufferSnapshot
                XCTAssertLessThanOrEqual(snapshot.storedBytes, SSHNetworkStream.receiveBufferLimit)
                if count == -Int(EAGAIN) {
                    try await Task.sleep(for: .milliseconds(1))
                    continue
                }
                if count == 0 { break }
                guard count > 0 else { return XCTFail("Receive failed: \(count)") }
                received.append(contentsOf: scratch.prefix(count))
            }
            XCTAssertEqual(received, payload)
            XCTAssertEqual(stream.receiveBufferSnapshot.storedBytes, 0)
            let eof = scratch.withUnsafeMutableBytes { stream.receive(into: $0.baseAddress!, count: $0.count) }
            XCTAssertEqual(eof, 0, "EOF must arrive after all buffered bytes, including after a paused receive")
        }
    }

    func testCancellationWhileReceiveIsPausedDoesNotRestartNetworkReads() async throws {
        let server = try ReceiveBufferTestServer(payload: Data(repeating: 42, count: SSHNetworkStream.receiveBufferLimit * 5))
        defer { server.stop() }
        try await waitUntil("loopback listener") { server.port != nil }
        let stream = SSHNetworkStream(ioTimeout: 5)
        defer { stream.cancel() }
        try stream.connect(host: "127.0.0.1", port: try XCTUnwrap(server.port),
                           timeout: 5, onPhaseChanged: { _ in })
        try await waitForReceivePause(stream)
        stream.cancel()
        var scratch = [UInt8](repeating: 0, count: 8_192)
        var drained = 0
        let expected = stream.receiveBufferSnapshot.bytes
        while drained < expected {
            let count = scratch.withUnsafeMutableBytes { stream.receive(into: $0.baseAddress!, count: $0.count) }
            guard count > 0 else { return XCTFail("Buffered data was lost on cancellation") }
            drained += count
        }
        let cancelled = scratch.withUnsafeMutableBytes { stream.receive(into: $0.baseAddress!, count: $0.count) }
        XCTAssertEqual(cancelled, -Int(ECANCELED))
        XCTAssertEqual(drained, expected)
        XCTAssertEqual(stream.receiveBufferSnapshot.storedBytes, 0)
        XCTAssertFalse(stream.receiveBufferSnapshot.inFlight)
    }

    func testFailureBeforeReceiveCompletionPreservesFinalBytesAndError() {
        let stream = SSHNetworkStream()
        stream.setBlocking(false)
        stream.failForTesting("connection reset")
        let finalBytes = Data("final output".utf8)
        stream.completeReceiveForTesting(finalBytes, isComplete: true)
        var scratch = [UInt8](repeating: 0, count: 64)
        let count = scratch.withUnsafeMutableBytes { stream.receive(into: $0.baseAddress!, count: $0.count) }
        XCTAssertEqual(count, finalBytes.count)
        XCTAssertEqual(Data(scratch.prefix(max(0, count))), finalBytes)
        let error = scratch.withUnsafeMutableBytes { stream.receive(into: $0.baseAddress!, count: $0.count) }
        XCTAssertEqual(error, -Int(EIO), "A late EOF must not replace the recorded failure")
        XCTAssertFalse(stream.receiveBufferSnapshot.inFlight)
    }

    func testCancellationBeforeReceiveCompletionDiscardsLateBytes() {
        let stream = SSHNetworkStream()
        stream.cancel()
        stream.completeReceiveForTesting(Data("late output".utf8), isComplete: true)
        var byte: UInt8 = 0
        XCTAssertEqual(stream.receive(into: &byte, count: 1), -Int(ECANCELED))
        XCTAssertEqual(stream.receiveBufferSnapshot.storedBytes, 0)
        XCTAssertFalse(stream.receiveBufferSnapshot.inFlight)
    }

    private func waitForReceivePause(_ stream: SSHNetworkStream) async throws {
        try await waitUntil("receive buffer backpressure") {
            let snapshot = stream.receiveBufferSnapshot
            XCTAssertLessThanOrEqual(snapshot.storedBytes, SSHNetworkStream.receiveBufferLimit)
            return snapshot.bytes > SSHNetworkStream.receiveBufferLimit - SSHNetworkStream.receiveChunkBytes
                && !snapshot.inFlight
        }
    }
    #endif

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

}

#if VT_TEST_HOOKS
/// A real TCP peer exercises NWConnection's receive-size contract and resumption
/// races, rather than testing a second implementation of the admission policy.
private final class ReceiveBufferTestServer: @unchecked Sendable {
    let listener: NWListener
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var stopped = false
    private var readyPort: UInt16?
    var port: UInt16? { lock.withLock { readyPort } }
    private let queue = DispatchQueue(label: "SSHNetworkTransportTests.server")

    init(payload: Data) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, case .ready = state,
                  let port = listener.port?.rawValue, port != 0 else { return }
            lock.withLock { readyPort = port }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            lock.lock()
            guard !stopped else { lock.unlock(); connection.cancel(); return }
            connections.append(connection)
            lock.unlock()
            connection.start(queue: queue)
            connection.send(content: payload, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { _ in })
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
        lock.lock()
        stopped = true
        let accepted = connections
        connections.removeAll()
        lock.unlock()
        accepted.forEach { $0.cancel() }
    }
}
#endif
