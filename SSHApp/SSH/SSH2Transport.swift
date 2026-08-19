import Foundation
import CryptoKit
import os
private import CSSH2

private let logger = Logger(subsystem: "dev.sshapp.sshapp", category: "SSH2Transport")
private let logsSSHWriteTraffic = false

private let networkSendCallback: SSHAppTransportSendCallback = { context, buffer, length in
    guard let context, let buffer else { return -Int(EINVAL) }
    let stream = Unmanaged<SSHNetworkStream>.fromOpaque(context).takeUnretainedValue()
    return stream.send(buffer, count: length)
}

private let networkReceiveCallback: SSHAppTransportReceiveCallback = { context, buffer, length in
    guard let context, let buffer else { return -Int(EINVAL) }
    let stream = Unmanaged<SSHNetworkStream>.fromOpaque(context).takeUnretainedValue()
    return stream.receive(into: buffer, count: length)
}

private let authenticationInteractionCallback: SSHAppAuthenticationInteractionCallback = {
    context, deadlineUptimeNanoseconds in
    guard let context else { return }
    let relay = Unmanaged<SSHAuthenticationNoticeRelay>
        .fromOpaque(context)
        .takeUnretainedValue()
    relay.beginAuthenticationInteraction(
        deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
    )
}

private let userauthBannerCallback: SSHAppUserauthBannerCallback = {
    context, message, messageLength, language, languageLength in
    guard let context else { return }
    let relay = Unmanaged<SSHAuthenticationNoticeRelay>
        .fromOpaque(context)
        .takeUnretainedValue()
    relay.receive(
        message: message,
        messageLength: messageLength,
        language: language,
        languageLength: languageLength
    )
}

private final class PublicKeyAuthContext: @unchecked Sendable {
    let signer: @Sendable (Data) throws -> Data
    var signingError: Error?

    init(signer: @escaping @Sendable (Data) throws -> Data) {
        self.signer = signer
    }
}

private let publicKeySignCallback: SSHAppPublicKeySignCallback = { _, sig, sigLen, data, dataLen, abstract in
    guard let sig,
          let sigLen,
          let data,
          let abstract,
          let rawContext = abstract.pointee else {
        return LIBSSH2_ERROR_PUBLICKEY_UNVERIFIED
    }

    let context = Unmanaged<PublicKeyAuthContext>.fromOpaque(rawContext).takeUnretainedValue()

    do {
        let payload = Data(bytes: data, count: dataLen)
        let signature = try context.signer(payload)
        guard let signatureBuffer = malloc(signature.count) else {
            return LIBSSH2_ERROR_ALLOC
        }

        signature.copyBytes(to: signatureBuffer.assumingMemoryBound(to: UInt8.self), count: signature.count)
        sig.pointee = signatureBuffer.assumingMemoryBound(to: UInt8.self)
        sigLen.pointee = signature.count
        return 0
    } catch {
        context.signingError = error
        return LIBSSH2_ERROR_PUBLICKEY_UNVERIFIED
    }
}

/// Errors from the libssh2 transport layer
enum SSH2Error: LocalizedError, Equatable, Sendable {
    case socketFailed(String)
    case handshakeFailed(Int32)
    case authFailed(String)
    case authenticationTimedOut(waitingForInteraction: Bool)
    case keyboardInteractiveBridgeFailed(String)
    case channelFailed(String)
    case disconnected

    var errorDescription: String? {
        switch self {
        case .socketFailed(let msg): return "Socket error: \(msg)"
        case .handshakeFailed(let rc): return "SSH handshake failed (rc=\(rc))"
        case .authFailed(let msg): return "Authentication failed: \(msg)"
        case .authenticationTimedOut(let waitingForInteraction):
            return waitingForInteraction
                ? "Timed out waiting for authentication interaction"
                : "Timed out while discovering or performing authentication"
        case .keyboardInteractiveBridgeFailed(let msg):
            return "Keyboard-interactive bridge failed: \(msg)"
        case .channelFailed(let msg): return "Channel error: \(msg)"
        case .disconnected: return "Disconnected"
        }
    }
}

struct SSHExecResult: Equatable, Sendable {
    let exitStatus: Int32
    let stdout: Data
    let stderr: Data

    var stdoutString: String {
        String(data: stdout, encoding: .utf8) ?? ""
    }

    var stderrString: String {
        String(data: stderr, encoding: .utf8) ?? ""
    }

    var combinedOutputString: String {
        [stdoutString, stderrString]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

enum SSHAuthenticationDiscovery: Equatable, Sendable {
    case authenticated
    case methods([String])
}

struct SSHTransportChannelID: Hashable, Sendable {
    fileprivate let rawValue: UInt64

    init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

enum SSHTransportChannelKind: Sendable {
    case shell
}

enum SSHTransportChannelCloseReason: Sendable, Equatable {
    case local
    case remoteProcessExited
    case transportFailure
}

private final class KeyboardInteractiveBridge: @unchecked Sendable {
    let promptsSemaphore = DispatchSemaphore(value: 0)
    let responsesSemaphore = DispatchSemaphore(value: 0)
    let context: UnsafeMutablePointer<KbdInteractiveContext>

    init(responseTimeout: TimeInterval) throws {
        context = .allocate(capacity: 1)
        context.initialize(to: KbdInteractiveContext())
        context.pointee.prompts_ready = Unmanaged.passRetained(promptsSemaphore).toOpaque()
        context.pointee.responses_ready = Unmanaged.passRetained(responsesSemaphore).toOpaque()
        context.pointee.response_timeout_milliseconds = UInt64(max(1, responseTimeout * 1_000))
        guard sshapp_keyboard_context_initialize(context) == 0 else {
            Unmanaged<DispatchSemaphore>.fromOpaque(context.pointee.prompts_ready!).release()
            Unmanaged<DispatchSemaphore>.fromOpaque(context.pointee.responses_ready!).release()
            context.deinitialize(count: 1)
            context.deallocate()
            throw SSH2Error.keyboardInteractiveBridgeFailed(
                "could not initialize bridge synchronization"
            )
        }
    }

    deinit {
        sshapp_keyboard_context_destroy(context)
        Unmanaged<DispatchSemaphore>.fromOpaque(context.pointee.prompts_ready!).release()
        Unmanaged<DispatchSemaphore>.fromOpaque(context.pointee.responses_ready!).release()
        context.deinitialize(count: 1)
        context.deallocate()
    }

    func cancel() {
        sshapp_keyboard_context_cancel(context)
    }

    func wakePromptLoop() {
        promptsSemaphore.signal()
    }

    var isCancelled: Bool {
        withContextLock { context.pointee.cancelled != 0 }
    }

    var bridgeError: Int32 {
        withContextLock { context.pointee.bridge_error }
    }

    func currentRound() throws -> SSHKeyboardInteractiveRound {
        sshapp_keyboard_context_lock(context)
        defer { sshapp_keyboard_context_unlock(context) }
        let bridgeError = context.pointee.bridge_error
        guard bridgeError == Int32(SSHAPP_KBD_BRIDGE_OK) else {
            throw Self.bridgeError(for: bridgeError)
        }
        guard context.pointee.round_active != 0 else {
            throw SSH2Error.keyboardInteractiveBridgeFailed("no active prompt round")
        }
        let count = Int(context.pointee.num_prompts)
        guard count >= 0,
              count == 0 || (
                context.pointee.prompt_texts != nil &&
                context.pointee.prompt_lengths != nil &&
                context.pointee.prompt_echos != nil
              ) else {
            throw SSH2Error.keyboardInteractiveBridgeFailed("invalid prompt storage")
        }

        let name = Self.copyData(
            context.pointee.name,
            length: context.pointee.name_length
        )
        let instruction = Self.copyData(
            context.pointee.instruction,
            length: context.pointee.instruction_length
        )
        var prompts: [(text: Data, echo: Bool)] = []
        prompts.reserveCapacity(count)
        for index in 0..<count {
            prompts.append(
                (
                    text: Self.copyData(
                        context.pointee.prompt_texts[index],
                        length: context.pointee.prompt_lengths[index]
                    ),
                    echo: context.pointee.prompt_echos[index] != 0
                )
            )
        }
        return SSHKeyboardInteractiveRound(
            nameBytes: name,
            instructionBytes: instruction,
            promptBytes: prompts
        )
    }

    func submit(_ result: SSHKeyboardInteractiveResult) throws {
        switch result {
        case .timedOut:
            throw SSH2Error.authenticationTimedOut(waitingForInteraction: true)
        case .cancelled:
            cancel()
        case .responses(let values):
            sshapp_keyboard_context_lock(context)
            defer { sshapp_keyboard_context_unlock(context) }
            guard context.pointee.round_active != 0 else {
                let error = context.pointee.bridge_error
                throw Self.bridgeError(
                    for: error == Int32(SSHAPP_KBD_BRIDGE_OK)
                        ? Int32(SSHAPP_KBD_BRIDGE_RESPONSE_TIMED_OUT)
                        : error
                )
            }
            let count = Int(context.pointee.num_prompts)
            guard values.count == count else {
                context.pointee.bridge_error = Int32(SSHAPP_KBD_BRIDGE_RESPONSE_COUNT_MISMATCH)
                responsesSemaphore.signal()
                throw Self.bridgeError(for: Int32(SSHAPP_KBD_BRIDGE_RESPONSE_COUNT_MISMATCH))
            }
            guard count == 0 || (
                context.pointee.responses != nil &&
                context.pointee.response_lengths != nil
            ) else {
                context.pointee.bridge_error = Int32(SSHAPP_KBD_BRIDGE_ALLOCATION_FAILED)
                responsesSemaphore.signal()
                throw Self.bridgeError(for: Int32(SSHAPP_KBD_BRIDGE_ALLOCATION_FAILED))
            }

            for (index, value) in values.enumerated() {
                let bytes = Array(value.utf8)
                let storage = malloc(max(1, bytes.count))
                guard let storage else {
                    context.pointee.bridge_error = Int32(SSHAPP_KBD_BRIDGE_ALLOCATION_FAILED)
                    responsesSemaphore.signal()
                    throw Self.bridgeError(for: Int32(SSHAPP_KBD_BRIDGE_ALLOCATION_FAILED))
                }
                if !bytes.isEmpty {
                    bytes.withUnsafeBytes {
                        storage.copyMemory(from: $0.baseAddress!, byteCount: bytes.count)
                    }
                }
                context.pointee.responses[index] = storage.assumingMemoryBound(to: UInt8.self)
                context.pointee.response_lengths[index] = bytes.count
            }
            context.pointee.response_count = Int32(values.count)
            responsesSemaphore.signal()
        }
    }

    private func withContextLock<T>(_ body: () -> T) -> T {
        sshapp_keyboard_context_lock(context)
        defer { sshapp_keyboard_context_unlock(context) }
        return body()
    }

    static func bridgeError(for code: Int32) -> SSH2Error {
        let message: String
        switch code {
        case Int32(SSHAPP_KBD_BRIDGE_ALLOCATION_FAILED):
            message = "allocation failed"
        case Int32(SSHAPP_KBD_BRIDGE_RESPONSE_COUNT_MISMATCH):
            message = "response count did not match prompt count"
        case Int32(SSHAPP_KBD_BRIDGE_RESPONSE_TIMED_OUT):
            return .authenticationTimedOut(waitingForInteraction: true)
        case Int32(SSHAPP_KBD_BRIDGE_INVALID_ROUND):
            message = "server supplied an invalid round"
        default:
            message = "unknown error \(code)"
        }
        return .keyboardInteractiveBridgeFailed(message)
    }

    private static func copyData(_ bytes: UnsafeMutablePointer<UInt8>?, length: Int) -> Data {
        guard length > 0, let bytes else { return Data() }
        return Data(bytes: bytes, count: length)
    }
}

private final class ManagedSSHTransportChannel: @unchecked Sendable {
    let id: SSHTransportChannelID
    let kind: SSHTransportChannelKind
    let channel: OpaquePointer
    let onDataReceived: @MainActor @Sendable (Data) -> Void
    let onClosed: @MainActor @Sendable (SSHTransportChannelCloseReason) -> Void
    var isClosing = false

    let pendingWrites = OSAllocatedUnfairLock(initialState: [Data]())
    let pendingResize = OSAllocatedUnfairLock<(cols: Int, rows: Int)?>(initialState: nil)

    init(
        id: SSHTransportChannelID,
        kind: SSHTransportChannelKind,
        channel: OpaquePointer,
        onDataReceived: @escaping @MainActor @Sendable (Data) -> Void,
        onClosed: @escaping @MainActor @Sendable (SSHTransportChannelCloseReason) -> Void
    ) {
        self.id = id
        self.kind = kind
        self.channel = channel
        self.onDataReceived = onDataReceived
        self.onClosed = onClosed
    }
}

/// Thread-safe wrapper around libssh2's C API.
/// All libssh2 calls are serialized on a dedicated DispatchQueue per session.
///
/// ## Channel Pump Architecture
/// The libssh2 session owns multiple independent channels. Each channel has
/// its own pending write/resize buffers; a scheduled pump drains those buffers
/// and reads all open channels without monopolizing the serial queue.
final class SSH2Transport: @unchecked Sendable {
    private let queue: DispatchQueue
    private var session: OpaquePointer?   // LIBSSH2_SESSION*
    private var sessionContext: OpaquePointer?
    private var channels: [SSHTransportChannelID: ManagedSSHTransportChannel] = [:]
    private var nextChannelRawValue: UInt64 = 1
    private var placeholderSockets: (session: Int32, peer: Int32) = (-1, -1)
    private let networkStream = OSAllocatedUnfairLock<SSHNetworkStream?>(initialState: nil)
    private let activeKeyboardBridge = OSAllocatedUnfairLock<KeyboardInteractiveBridge?>(initialState: nil)
    private let authenticationWaitPolicy: SSHAuthenticationWaitPolicy
    private let authenticationNoticeRelay: SSHAuthenticationNoticeRelay
    private let standardAuthenticationTimeout: TimeInterval
    private let interactiveAuthenticationTimeout: TimeInterval
    private var isRunning = false
    private var isPumpScheduled = false

    /// Cancellation epoch for in-flight shell channel setup. `closeChannel`
    /// cannot reach a channel that has not been registered yet, so closing an
    /// opening shell must abort the native open/PTY/startup retry loops
    /// directly. The epoch is read at setup start; `cancelOpeningShellChannel`
    /// increments it, so setups that begin afterwards are unaffected.
    private let cancellationLock = NSLock()
    private var channelSetupCancellationEpoch: UInt64 = 0

    init(
        authenticationWaitPolicy: SSHAuthenticationWaitPolicy = .interactive,
        standardAuthenticationTimeout: TimeInterval = 15,
        interactiveAuthenticationTimeout: TimeInterval = 30 * 60
    ) {
        self.authenticationWaitPolicy = authenticationWaitPolicy
        self.standardAuthenticationTimeout = standardAuthenticationTimeout
        self.interactiveAuthenticationTimeout = interactiveAuthenticationTimeout
        authenticationNoticeRelay = SSHAuthenticationNoticeRelay(
            waitPolicy: authenticationWaitPolicy,
            waitDuration: interactiveAuthenticationTimeout
        )
        self.queue = DispatchQueue(label: "dev.sshapp.sshapp.ssh2transport", qos: .userInitiated)
    }

    func setAuthenticationNoticeHandler(
        _ handler: @escaping @Sendable (SSHAuthenticationNotice) -> Void
    ) {
        authenticationNoticeRelay.setHandler(handler)
    }

    var authenticationInteractionDeadlineUptimeNanoseconds: UInt64? {
        authenticationNoticeRelay.interactionDeadlineUptimeNanoseconds
    }

    var authenticationInteractionHasExpired: Bool {
        authenticationNoticeRelay.authenticationInteractionHasExpired
    }

    deinit {
        activeKeyboardBridge.withLock { $0 }?.cancel()
        networkStream.withLock { $0?.cancel() }
        for managed in channels.values {
            libssh2_channel_free(managed.channel)
        }
        if session != nil {
            libssh2_session_disconnect_ex(session, 11 /* SSH_DISCONNECT_BY_APPLICATION */, "deinit", "")
            libssh2_session_free(session)
        }
        if let sessionContext {
            sshapp_session_context_destroy(sessionContext)
        }
        authenticationNoticeRelay.setStream(nil)
        closePlaceholderSockets()
    }

    // MARK: - Async bridge

    /// Execute work on the serial queue with access to the raw LIBSSH2_SESSION pointer.
    /// Used by KnownHostsManager which needs the session for knownhost_init().
    func withSession<T: Sendable>(_ work: @escaping @Sendable (OpaquePointer) throws -> T) async throws -> T {
        try await perform { [self] in
            guard let session else { throw SSH2Error.disconnected }
            return try work(session)
        }
    }

    private func perform<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let result = try work()
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func performVoid(_ work: @escaping @Sendable () throws -> Void) async throws {
        try await perform(work)
    }

    // MARK: - Connection

    func connect(
        host: String,
        port: UInt16,
        onPhaseChanged: @escaping @Sendable (SSHConnectionPhase) -> Void = { _ in }
    ) async throws {
        try await withTaskCancellationHandler {
            try await performVoid { [self] in
                let stream = SSHNetworkStream(ioTimeout: standardAuthenticationTimeout)
                networkStream.withLock { $0 = stream }
                authenticationNoticeRelay.setStream(stream)

                do {
                    logger.info("Connecting to \(host):\(port) with Network.framework")
                    try stream.connect(
                        host: host,
                        port: port,
                        timeout: 30,
                        onPhaseChanged: onPhaseChanged
                    )
                } catch {
                    stream.cancel()
                    networkStream.withLock { current in
                        if current === stream { current = nil }
                    }
                    authenticationNoticeRelay.setStream(nil)
                    logger.error("Network.framework connection failed: \(error.localizedDescription)")
                    if error is CancellationError { throw error }
                    throw SSH2Error.socketFailed(error.localizedDescription)
                }

                onPhaseChanged(.startingSSH)
                logger.info("Initializing SSH session")
                guard let sess = libssh2_session_init_ex(nil, nil, nil, nil) else {
                    stream.cancel()
                    networkStream.withLock { $0 = nil }
                    authenticationNoticeRelay.setStream(nil)
                    throw SSH2Error.socketFailed("Failed to create SSH session")
                }

                authenticationNoticeRelay.resetAuthenticationInteraction()
                let authenticationWaitMilliseconds = authenticationWaitPolicy == .interactive
                    ? UInt64(max(1, interactiveAuthenticationTimeout * 1_000))
                    : 0
                guard let context = sshapp_session_context_create(
                    Unmanaged.passUnretained(stream).toOpaque(),
                    networkSendCallback,
                    networkReceiveCallback,
                    Unmanaged.passUnretained(authenticationNoticeRelay).toOpaque(),
                    userauthBannerCallback,
                    authenticationWaitMilliseconds,
                    Unmanaged.passUnretained(authenticationNoticeRelay).toOpaque(),
                    authenticationInteractionCallback
                ) else {
                    libssh2_session_free(sess)
                    stream.cancel()
                    networkStream.withLock { $0 = nil }
                    authenticationNoticeRelay.setStream(nil)
                    throw SSH2Error.socketFailed("Failed to create SSH I/O context")
                }

                var sockets = [Int32](repeating: -1, count: 2)
                guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else {
                    sshapp_session_context_destroy(context)
                    libssh2_session_free(sess)
                    stream.cancel()
                    networkStream.withLock { $0 = nil }
                    authenticationNoticeRelay.setStream(nil)
                    throw SSH2Error.socketFailed("Failed to create libssh2 placeholder socket")
                }

                sshapp_configure_session_io(sess, context)
                libssh2_session_set_timeout(sess, 15_000)
                libssh2_session_set_blocking(sess, 1)
                stream.setBlocking(true)
                applyAlgorithmPreferences(session: sess)

                logger.info("Starting SSH handshake")
                let rc = libssh2_session_handshake(sess, sockets[0])
                guard rc == 0 else {
                    libssh2_session_free(sess)
                    sshapp_session_context_destroy(context)
                    Darwin.close(sockets[0])
                    Darwin.close(sockets[1])
                    stream.cancel()
                    networkStream.withLock { $0 = nil }
                    authenticationNoticeRelay.setStream(nil)
                    logger.error("SSH handshake failed with rc=\(rc)")
                    throw SSH2Error.handshakeFailed(rc)
                }

                session = sess
                sessionContext = context
                placeholderSockets = (sockets[0], sockets[1])
                logger.info("SSH handshake succeeded")
            }
        } onCancel: { [weak self] in
            self?.cancelPendingIO()
        }
    }

    /// Restrict the SSH transport to modern algorithms so a legacy or hostile
    /// server cannot negotiate weak crypto (ssh-dss, aes-cbc, 3des, hmac-sha1,
    /// hmac-md5, diffie-hellman-group1-sha1) and so the client stops offering
    /// unusable legacy primitives. Strong algorithms are listed first; libssh2
    /// intersects each preference with what it actually supports. Best-effort:
    /// if a preference can't be set libssh2 keeps its defaults, so this never
    /// blocks connecting.
    private func applyAlgorithmPreferences(session: OpaquePointer) {
        let kex = "curve25519-sha256,curve25519-sha256@libssh.org,"
            + "ecdh-sha2-nistp256,ecdh-sha2-nistp384,ecdh-sha2-nistp521,"
            + "diffie-hellman-group-exchange-sha256,diffie-hellman-group16-sha512,"
            + "diffie-hellman-group18-sha512,diffie-hellman-group14-sha256"
        let hostKey = "ssh-ed25519,ecdsa-sha2-nistp256,ecdsa-sha2-nistp384,"
            + "ecdsa-sha2-nistp521,rsa-sha2-512,rsa-sha2-256"
        let cipher = "chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,"
            + "aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr"
        let mac = "hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com,"
            + "hmac-sha2-256,hmac-sha2-512"

        let preferences: [(method: Int32, label: String, prefs: String)] = [
            (LIBSSH2_METHOD_KEX, "key exchange", kex),
            (LIBSSH2_METHOD_HOSTKEY, "host key", hostKey),
            (LIBSSH2_METHOD_CRYPT_CS, "client-to-server cipher", cipher),
            (LIBSSH2_METHOD_CRYPT_SC, "server-to-client cipher", cipher),
            (LIBSSH2_METHOD_MAC_CS, "client-to-server MAC", mac),
            (LIBSSH2_METHOD_MAC_SC, "server-to-client MAC", mac),
        ]

        for preference in preferences {
            let rc = libssh2_session_method_pref(session, preference.method, preference.prefs)
            if rc != 0 {
                logger.warning("Could not set \(preference.label) algorithm preference (rc=\(rc)); using libssh2 defaults")
            }
        }
    }

    // MARK: - Host Key

    /// Get the server's host key fingerprint and type
    func hostKeyInfo() async throws -> (fingerprint: String, keyType: String, keyData: Data) {
        try await perform { [self] in
            guard let session else { throw SSH2Error.disconnected }

            var keyLen: Int = 0
            var keyType: Int32 = 0
            guard let keyPtr = libssh2_session_hostkey(session, &keyLen, &keyType) else {
                throw SSH2Error.socketFailed("Cannot get host key")
            }

            let keyData = Data(bytes: keyPtr, count: keyLen)
            let hash = SHA256.hash(data: keyData)
            let fingerprint = "SHA256:" + Data(hash).base64EncodedString()

            let typeStr: String
            switch keyType {
            case LIBSSH2_HOSTKEY_TYPE_RSA: typeStr = "ssh-rsa"
            case LIBSSH2_HOSTKEY_TYPE_DSS: typeStr = "ssh-dss"
            case LIBSSH2_HOSTKEY_TYPE_ECDSA_256: typeStr = "ecdsa-sha2-nistp256"
            case LIBSSH2_HOSTKEY_TYPE_ECDSA_384: typeStr = "ecdsa-sha2-nistp384"
            case LIBSSH2_HOSTKEY_TYPE_ECDSA_521: typeStr = "ecdsa-sha2-nistp521"
            case LIBSSH2_HOSTKEY_TYPE_ED25519: typeStr = "ssh-ed25519"
            default: typeStr = "unknown"
            }

            return (fingerprint, typeStr, keyData)
        }
    }

    // MARK: - Authentication

    private func performAuthenticationOperation<T>(
        session: OpaquePointer,
        _ operation: () -> T
    ) throws -> T {
        guard let stream = networkStream.withLock({ $0 }) else {
            throw SSH2Error.disconnected
        }
        let previousTimeout = libssh2_session_get_timeout(session)
        let interactionDeadline = authenticationNoticeRelay
            .interactionDeadlineUptimeNanoseconds
        let now = DispatchTime.now().uptimeNanoseconds
        if let interactionDeadline, now >= interactionDeadline {
            throw SSH2Error.authenticationTimedOut(waitingForInteraction: true)
        }
        let standardDurationNanoseconds = UInt64(
            min(
                standardAuthenticationTimeout * 1_000_000_000,
                Double(UInt64.max)
            )
        )
        let standardDeadlineSum = now.addingReportingOverflow(
            standardDurationNanoseconds
        )
        let standardDeadline = standardDeadlineSum.overflow
            ? UInt64.max
            : standardDeadlineSum.partialValue
        let operationTimeout: TimeInterval
        if let interactionDeadline {
            let remaining = interactionDeadline > now
                ? interactionDeadline - now
                : 0
            operationTimeout = max(
                0.001,
                TimeInterval(remaining) / 1_000_000_000
            )
        } else {
            operationTimeout = standardAuthenticationTimeout
        }
        stream.beginAuthenticationOperation(
            standardDeadlineUptimeNanoseconds: standardDeadline,
            interactionDeadlineUptimeNanoseconds: interactionDeadline
        )
        if let sessionContext {
            sshapp_session_context_begin_authentication_operation(
                sessionContext,
                interactionDeadline == nil ? standardDeadline : 0
            )
        }
        libssh2_session_set_timeout(session, CLong(operationTimeout * 1_000))

        let result = operation()
        if let sessionContext {
            sshapp_session_context_end_authentication_operation(sessionContext)
        }
        let outcome = stream.finishAuthenticationOperation()
        libssh2_session_set_timeout(session, previousTimeout)

        switch outcome {
        case .completed:
            return result
        case .timedOut(let waitingForInteraction):
            throw SSH2Error.authenticationTimedOut(
                waitingForInteraction: waitingForInteraction
            )
        case .failed(let reason):
            throw SSH2Error.socketFailed(reason)
        case .cancelled:
            throw CancellationError()
        }
    }

    func discoverAuthentication(username: String) async throws -> SSHAuthenticationDiscovery {
        try await perform { [self] in
            guard let session else { throw SSH2Error.disconnected }
            logger.info("Querying auth methods for \(username)")

            let listPtr = try performAuthenticationOperation(session: session) {
                libssh2_userauth_list(session, username, UInt32(username.utf8.count))
            }
            guard let listPtr else {
                let authenticated = libssh2_userauth_authenticated(session) != 0
                return try Self.classifyAuthenticationDiscovery(
                    methodList: nil,
                    isAuthenticated: authenticated,
                    lastError: libssh2_session_last_errno(session)
                )
            }

            let methodList = String(cString: listPtr)
            let methods = methodList.split(separator: ",").map(String.init)
            logger.info("Auth methods: \(methods.joined(separator: ", "))")
            return .methods(methods)
        }
    }

    static func classifyAuthenticationDiscovery(
        methodList: String?,
        isAuthenticated: Bool,
        lastError: Int32
    ) throws -> SSHAuthenticationDiscovery {
        if let methodList {
            return .methods(methodList.split(separator: ",").map(String.init))
        }
        if isAuthenticated {
            return .authenticated
        }
        switch lastError {
        case Int32(LIBSSH2_ERROR_AUTHENTICATION_FAILED):
            throw SSH2Error.authFailed(
                "Could not discover authentication methods (rc=\(lastError))"
            )
        case Int32(LIBSSH2_ERROR_TIMEOUT):
            throw SSH2Error.authenticationTimedOut(waitingForInteraction: false)
        case Int32(LIBSSH2_ERROR_SOCKET_SEND), Int32(LIBSSH2_ERROR_SOCKET_RECV):
            throw SSH2Error.socketFailed(
                "Authentication discovery transport failed (rc=\(lastError))"
            )
        default:
            throw SSH2Error.socketFailed(
                "Authentication discovery failed unexpectedly (rc=\(lastError))"
            )
        }
    }

    static func classifyAuthenticationFailure(
        code: Int32,
        operation: String,
        waitingForInteraction: Bool
    ) -> SSH2Error {
        switch code {
        case Int32(LIBSSH2_ERROR_AUTHENTICATION_FAILED),
             Int32(LIBSSH2_ERROR_PUBLICKEY_UNVERIFIED),
             Int32(LIBSSH2_ERROR_PASSWORD_EXPIRED):
            return .authFailed("\(operation) authentication failed")
        case Int32(LIBSSH2_ERROR_TIMEOUT):
            return .authenticationTimedOut(
                waitingForInteraction: waitingForInteraction
            )
        case Int32(LIBSSH2_ERROR_SOCKET_SEND), Int32(LIBSSH2_ERROR_SOCKET_RECV):
            return .socketFailed("\(operation) transport failed (rc=\(code))")
        default:
            return .socketFailed("\(operation) failed unexpectedly (rc=\(code))")
        }
    }

    func authPassword(username: String, password: String) async throws {
        try await performVoid { [self] in
            guard let session else { throw SSH2Error.disconnected }
            logger.info("Attempting password auth for \(username)")

            let rc = try performAuthenticationOperation(session: session) {
                libssh2_userauth_password_ex(
                    session,
                    username, UInt32(username.utf8.count),
                    password, UInt32(password.utf8.count),
                    nil
                )
            }
            guard rc == 0 else {
                logger.warning("Password auth failed (rc=\(rc))")
                throw Self.classifyAuthenticationFailure(
                    code: rc,
                    operation: "Password",
                    waitingForInteraction: authenticationNoticeRelay
                        .interactionDeadlineUptimeNanoseconds != nil
                )
            }
            logger.info("Password auth succeeded")
        }
    }

    /// Authenticate with complete RFC 4256 rounds, including informational
    /// zero-prompt rounds and independent echo flags for every prompt.
    func authKeyboardInteractive(
        username: String,
        promptHandler: @escaping @Sendable @MainActor (SSHKeyboardInteractiveRound) async -> SSHKeyboardInteractiveResult
    ) async throws {
        logger.info("Starting keyboard-interactive auth for \(username)")
        let responseTimeout = authenticationWaitPolicy == .interactive
            ? interactiveAuthenticationTimeout
            : standardAuthenticationTimeout
        let bridge = try KeyboardInteractiveBridge(responseTimeout: responseTimeout)
        let authDone = OSAllocatedUnfairLock(initialState: false)
        let promptFailure = OSAllocatedUnfairLock<SSH2Error?>(initialState: nil)
        let promptCancelled = OSAllocatedUnfairLock(initialState: false)
        let transport = self
        let usernameCopy = username
        activeKeyboardBridge.withLock { $0 = bridge }
        defer {
            activeKeyboardBridge.withLock { current in
                if current === bridge { current = nil }
            }
        }

        try await withTaskCancellationHandler {
            let authTask: Task<Void, Error> = Task { @Sendable in
                defer {
                    authDone.withLock { $0 = true }
                    bridge.wakePromptLoop()
                }
                try await transport.performVoid {
                    guard let session = transport.session,
                          let sessionContext = transport.sessionContext else {
                        throw SSH2Error.disconnected
                    }
                    sshapp_session_context_set_keyboard_context(
                        sessionContext,
                        bridge.context
                    )
                    defer {
                        sshapp_session_context_set_keyboard_context(
                            sessionContext,
                            nil
                        )
                    }

                    let rc = try transport.performAuthenticationOperation(
                        session: session
                    ) {
                        libssh2_userauth_keyboard_interactive_ex(
                            session,
                            usernameCopy,
                            UInt32(usernameCopy.utf8.count),
                            kbd_interactive_trampoline
                        )
                    }
                    guard rc == 0 else {
                        throw Self.classifyAuthenticationFailure(
                            code: rc,
                            operation: "Keyboard-interactive",
                            waitingForInteraction: transport.authenticationNoticeRelay
                                .interactionDeadlineUptimeNanoseconds != nil
                        )
                    }
                }
            }

            let promptTask = Task { @Sendable in
                while true {
                    await withCheckedContinuation {
                        (continuation: CheckedContinuation<Void, Never>) in
                        DispatchQueue.global().async {
                            bridge.promptsSemaphore.wait()
                            continuation.resume()
                        }
                    }
                    if authDone.withLock({ $0 }) { break }
                    if bridge.isCancelled {
                        promptCancelled.withLock { $0 = true }
                        break
                    }

                    do {
                        let round = try bridge.currentRound()
                        let result = await promptHandler(round)
                        if Task.isCancelled {
                            throw CancellationError()
                        }
                        try bridge.submit(result)
                        if case .cancelled = result {
                            throw CancellationError()
                        }
                    } catch let error as SSH2Error {
                        promptFailure.withLock { $0 = error }
                        transport.networkStream.withLock { $0?.cancel() }
                        break
                    } catch {
                        promptCancelled.withLock { $0 = true }
                        bridge.cancel()
                        transport.networkStream.withLock { $0?.cancel() }
                        break
                    }
                }
            }

            let authResult = await authTask.result
            authDone.withLock { $0 = true }
            bridge.wakePromptLoop()
            promptTask.cancel()
            _ = await promptTask.result

            if let error = promptFailure.withLock({ $0 }) {
                throw error
            }
            if bridge.bridgeError != Int32(SSHAPP_KBD_BRIDGE_OK) {
                throw KeyboardInteractiveBridge.bridgeError(
                    for: bridge.bridgeError
                )
            }
            if promptCancelled.withLock({ $0 }) || bridge.isCancelled || Task.isCancelled {
                throw CancellationError()
            }
            try authResult.get()
        } onCancel: {
            bridge.cancel()
            transport.networkStream.withLock { $0?.cancel() }
        }
    }

    func authPublicKey(
        username: String,
        publicKeyBlob: Data,
        signer: @escaping @Sendable (Data) throws -> Data
    ) async throws {
        try await performVoid { [self] in
            guard let session else { throw SSH2Error.disconnected }
            guard !publicKeyBlob.isEmpty else {
                throw SSH2Error.authFailed("Public key data is empty")
            }
            logger.info("Attempting callback public key auth for \(username)")

            let context = PublicKeyAuthContext(signer: signer)
            let retainedContext = Unmanaged.passRetained(context)
            defer { retainedContext.release() }

            let rc = try performAuthenticationOperation(session: session) {
                username.withCString { usernamePtr in
                    publicKeyBlob.withUnsafeBytes { publicKeyBuffer in
                        guard let publicKeyPointer = publicKeyBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                            return LIBSSH2_ERROR_PUBLICKEY_UNVERIFIED
                        }

                        return sshapp_userauth_publickey(
                            session,
                            usernamePtr,
                            publicKeyPointer,
                            publicKeyBuffer.count,
                            publicKeySignCallback,
                            retainedContext.toOpaque()
                        )
                    }
                }
            }

            guard rc == 0 else {
                if let signingError = context.signingError {
                    logger.warning("Callback public key signing failed: \(signingError.localizedDescription)")
                    throw SSH2Error.authFailed("Public key signing failed: \(signingError.localizedDescription)")
                }

                logger.warning("Callback public key auth failed (rc=\(rc))")
                throw Self.classifyAuthenticationFailure(
                    code: rc,
                    operation: "Public key",
                    waitingForInteraction: authenticationNoticeRelay
                        .interactionDeadlineUptimeNanoseconds != nil
                )
            }
            logger.info("Callback public key auth succeeded")
        }
    }

    // MARK: - Shell channels

    func openShellChannel(
        term: String,
        cols: Int,
        rows: Int,
        onDataReceived: @escaping @MainActor @Sendable (Data) -> Void,
        onClosed: @escaping @MainActor @Sendable (SSHTransportChannelCloseReason) -> Void
    ) async throws -> SSHTransportChannelID {
        let setupEpoch = cancellationLock.withLock { channelSetupCancellationEpoch }
        return try await perform { [self] in
            guard let session else { throw SSH2Error.disconnected }
            logger.info("Opening SSH shell channel")

            let channel = try openSessionChannel(session: session, setupEpoch: setupEpoch)
            do {
                try requestPTY(channel: channel, session: session, term: term, cols: cols, rows: rows, setupEpoch: setupEpoch)
                try startShell(channel: channel, session: session, setupEpoch: setupEpoch)
            } catch {
                libssh2_channel_free(channel)
                throw error
            }

            let id = SSHTransportChannelID(rawValue: nextChannelRawValue)
            nextChannelRawValue += 1
            channels[id] = ManagedSSHTransportChannel(
                id: id,
                kind: .shell,
                channel: channel,
                onDataReceived: onDataReceived,
                onClosed: onClosed
            )

            libssh2_session_set_blocking(session, 0)
            networkStream.withLock { $0?.setBlocking(false) }
            ensurePumpScheduledLocked()
            logger.info("SSH shell channel opened id=\(id.rawValue)")
            return id
        }
    }

    func write(_ data: Data, to id: SSHTransportChannelID) {
        queue.async { [self] in
            guard let managed = channels[id] else { return }
            managed.pendingWrites.withLock { $0.append(data) }
            if logsSSHWriteTraffic {
                logger.debug("SSH write: queued \(data.count)B channel=\(id.rawValue)")
            }
            ensurePumpScheduledLocked()
        }
    }

    func resizePTY(channel id: SSHTransportChannelID, cols: Int, rows: Int) {
        queue.async { [self] in
            guard let managed = channels[id] else { return }
            managed.pendingResize.withLock { $0 = (cols, rows) }
            logger.debug("SSH resize: queued \(cols)x\(rows) channel=\(id.rawValue)")
            ensurePumpScheduledLocked()
        }
    }

    func closeChannel(_ id: SSHTransportChannelID) {
        queue.async { [self] in
            closeChannelLocked(id, reason: .local, notify: true)
        }
    }

    // MARK: - Exec channels

    func executeCommand(_ command: String, timeout: TimeInterval = 30) async throws -> SSHExecResult {
        try await perform { [self] in
            guard let session else { throw SSH2Error.disconnected }
            guard timeout > 0 else {
                throw SSH2Error.channelFailed("Command timeout must be greater than zero")
            }

            let setupEpoch = cancellationLock.withLock { channelSetupCancellationEpoch }
            libssh2_session_set_blocking(session, 0)
            networkStream.withLock { $0?.setBlocking(false) }
            let channel = try openSessionChannel(session: session, setupEpoch: setupEpoch)
            var didFreeChannel = false
            defer {
                if !didFreeChannel {
                    closeRawChannel(channel, session: session)
                }
                if !channels.isEmpty {
                    ensurePumpScheduledLocked()
                }
            }

            try startExec(channel: channel, session: session, command: command, setupEpoch: setupEpoch)

            var stdout = Data()
            var stderr = Data()
            var buffer = [UInt8](repeating: 0, count: 32768)
            let deadline = Date().addingTimeInterval(timeout)

            while true {
                var madeProgress = false
                pumpOpenChannelsOnceLocked()
                madeProgress = try readCommandStream(
                    channel: channel,
                    streamID: 0,
                    buffer: &buffer,
                    output: &stdout
                ) || madeProgress
                madeProgress = try readCommandStream(
                    channel: channel,
                    streamID: Int32(SSH_EXTENDED_DATA_STDERR),
                    buffer: &buffer,
                    output: &stderr
                ) || madeProgress

                if libssh2_channel_eof(channel) != 0 {
                    _ = retryBestEffortChannelOperation(session: session) {
                        libssh2_channel_close(channel)
                    }
                    let exitStatus = libssh2_channel_get_exit_status(channel)
                    libssh2_channel_free(channel)
                    didFreeChannel = true
                    return SSHExecResult(exitStatus: exitStatus, stdout: stdout, stderr: stderr)
                }

                guard Date() < deadline else {
                    throw SSH2Error.channelFailed("Command timed out")
                }

                if !madeProgress {
                    waitForSocketActivity(session: session)
                }
            }
        }
    }

    // MARK: - Channel setup

    private func openSessionChannel(session: OpaquePointer, setupEpoch: UInt64) throws -> OpaquePointer {
        var attempts = 0
        while attempts < 300 {
            try throwIfChannelSetupCancelled(setupEpoch: setupEpoch)
            if let channel = libssh2_channel_open_ex(
                session, "session", 7,
                UInt32(2 * 1024 * 1024),
                UInt32(32768),
                nil, 0
            ) {
                return channel
            }

            let rc = libssh2_session_last_errno(session)
            guard rc == Int32(LIBSSH2_ERROR_EAGAIN) else {
                throw SSH2Error.channelFailed("Failed to open channel (rc=\(rc))")
            }
            attempts += 1
            waitForSocketActivity(session: session)
        }
        throw SSH2Error.channelFailed("Timed out opening channel")
    }

    private func requestPTY(
        channel: OpaquePointer,
        session: OpaquePointer,
        term: String,
        cols: Int,
        rows: Int,
        setupEpoch: UInt64
    ) throws {
        logger.info("Requesting PTY (\(term), \(cols)x\(rows))")
        try retryChannelOperation(session: session, description: "PTY request", setupEpoch: setupEpoch) {
            libssh2_channel_request_pty_ex(
                channel,
                term, UInt32(term.utf8.count),
                nil, 0,
                Int32(cols), Int32(rows),
                0, 0
            )
        }
        logger.info("PTY allocated")
    }

    private func startShell(channel: OpaquePointer, session: OpaquePointer, setupEpoch: UInt64) throws {
        logger.info("Starting shell")
        try retryChannelOperation(session: session, description: "Shell request", setupEpoch: setupEpoch) {
            libssh2_channel_process_startup(
                channel,
                "shell", 5,
                nil, 0
            )
        }
        logger.info("Shell started")
    }

    private func startExec(channel: OpaquePointer, session: OpaquePointer, command: String, setupEpoch: UInt64) throws {
        logger.info("Starting exec channel")
        try retryChannelOperation(session: session, description: "Exec request", setupEpoch: setupEpoch) {
            command.withCString { commandPointer in
                libssh2_channel_process_startup(
                    channel,
                    "exec", 4,
                    commandPointer,
                    UInt32(command.utf8.count)
                )
            }
        }
        logger.info("Exec request started")
    }

    private func readCommandStream(
        channel: OpaquePointer,
        streamID: Int32,
        buffer: inout [UInt8],
        output: inout Data
    ) throws -> Bool {
        var madeProgress = false

        while true {
            let n = libssh2_channel_read_ex(channel, streamID, &buffer, buffer.count)
            if n > 0 {
                output.append(contentsOf: buffer.prefix(n))
                madeProgress = true
            } else if n == Int(LIBSSH2_ERROR_EAGAIN) || n == 0 {
                return madeProgress
            } else {
                throw SSH2Error.channelFailed("Command read failed (rc=\(n))")
            }
        }
    }

    private func retryChannelOperation(
        session: OpaquePointer,
        description: String,
        setupEpoch: UInt64,
        operation: () -> Int32
    ) throws {
        var attempts = 0
        while attempts < 300 {
            try throwIfChannelSetupCancelled(setupEpoch: setupEpoch)
            let rc = operation()
            if rc == 0 { return }
            guard rc == Int32(LIBSSH2_ERROR_EAGAIN) else {
                throw SSH2Error.channelFailed("\(description) failed (rc=\(rc))")
            }
            attempts += 1
            waitForSocketActivity(session: session)
        }
        throw SSH2Error.channelFailed("\(description) timed out")
    }

    /// Aborts an in-flight shell channel setup. Called synchronously from the
    /// channel owner so a closing tab interrupts the libssh2 open/PTY/startup
    /// retry loops without waiting for the serial queue.
    func cancelOpeningShellChannel() {
        cancellationLock.lock()
        channelSetupCancellationEpoch += 1
        cancellationLock.unlock()
    }

    private func throwIfChannelSetupCancelled(setupEpoch: UInt64) throws {
        let cancelled = cancellationLock.withLock {
            channelSetupCancellationEpoch != setupEpoch
        }
        if cancelled {
            throw CancellationError()
        }
    }

    // MARK: - Channel pump

    private func ensurePumpScheduledLocked() {
        guard !isPumpScheduled, !channels.isEmpty else { return }
        if !isRunning {
            logger.info("SSH channel pump starting")
            isRunning = true
        }
        isPumpScheduled = true
        queue.asyncAfter(deadline: .now() + .milliseconds(10)) { [self] in
            pumpChannelsLocked()
        }
    }

    private func pumpChannelsLocked() {
        isPumpScheduled = false

        guard isRunning, session != nil, !channels.isEmpty else {
            isRunning = false
            logger.info("SSH channel pump stopped")
            return
        }

        let snapshot = Array(channels.values)
        pumpOpenChannelsOnceLocked(snapshot: snapshot)

        ensurePumpScheduledLocked()
    }

    private func pumpOpenChannelsOnceLocked(snapshot: [ManagedSSHTransportChannel]? = nil) {
        let snapshot = snapshot ?? Array(channels.values)
        var buffer = [UInt8](repeating: 0, count: 32768)
        for managed in snapshot {
            guard channels[managed.id] != nil, !managed.isClosing else { continue }
            drainPendingWrites(for: managed)
            drainPendingResize(for: managed)
            readAvailableData(for: managed, buffer: &buffer)
        }
    }

    private func readAvailableData(for managed: ManagedSSHTransportChannel, buffer: inout [UInt8]) {
        while channels[managed.id] != nil {
            let n = libssh2_channel_read_ex(managed.channel, 0, &buffer, buffer.count)

            if n > 0 {
                let data = Data(bytes: buffer, count: n)
                let callback = managed.onDataReceived
                DispatchQueue.main.async {
                    callback(data)
                }
                continue
            } else if n == Int(LIBSSH2_ERROR_EAGAIN) {
                return
            }

            let didReceiveEOF = libssh2_channel_eof(managed.channel) != 0
            if didReceiveEOF {
                logger.info("Read pump: channel EOF id=\(managed.id.rawValue)")
                closeChannelLocked(managed.id, reason: .remoteProcessExited, notify: true)
                return
            }
            if n == 0 {
                logger.info("Read pump: channel closed without EOF id=\(managed.id.rawValue)")
                closeChannelLocked(managed.id, reason: .transportFailure, notify: true)
                return
            }

            logger.warning("Read pump: read error n=\(n) channel=\(managed.id.rawValue)")
            closeChannelLocked(managed.id, reason: .transportFailure, notify: true)
            return
        }
    }

    private func drainPendingWrites(for managed: ManagedSSHTransportChannel) {
        let writes = managed.pendingWrites.withLock { buf -> [Data] in
            let copy = buf
            buf.removeAll()
            return copy
        }
        guard !writes.isEmpty else { return }

        for data in writes {
            data.withUnsafeBytes { rawBuf in
                guard let ptr = rawBuf.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
                var offset = 0
                let total = data.count
                var attempts = 0

                while offset < total, channels[managed.id] != nil, attempts < 300 {
                    let n = libssh2_channel_write_ex(managed.channel, 0, ptr + offset, total - offset)
                    if n > 0 {
                        offset += n
                        attempts = 0
                    } else if n == Int(LIBSSH2_ERROR_EAGAIN) {
                        attempts += 1
                        if let session {
                            waitForSocketActivity(session: session)
                        }
                    } else {
                        logger.warning("SSH write: error n=\(n) channel=\(managed.id.rawValue)")
                        closeChannelLocked(managed.id, reason: .transportFailure, notify: true)
                        break
                    }
                }
            }
            if logsSSHWriteTraffic {
                logger.debug("SSH write: sent \(data.count)B channel=\(managed.id.rawValue)")
            }
        }
    }

    private func drainPendingResize(for managed: ManagedSSHTransportChannel) {
        guard let size = managed.pendingResize.withLock({ value -> (cols: Int, rows: Int)? in
            let copy = value
            value = nil
            return copy
        }) else {
            return
        }

        var attempts = 0
        while attempts < 20, channels[managed.id] != nil {
            let rc = libssh2_channel_request_pty_size_ex(
                managed.channel,
                Int32(size.cols),
                Int32(size.rows),
                0,
                0
            )
            if rc == 0 {
                logger.debug("SSH resize: sent \(size.cols)x\(size.rows) channel=\(managed.id.rawValue)")
                return
            }
            if rc == Int32(LIBSSH2_ERROR_EAGAIN), let session {
                attempts += 1
                waitForSocketActivity(session: session)
                continue
            }
            logger.warning("SSH resize: failed rc=\(rc) channel=\(managed.id.rawValue)")
            return
        }
        logger.warning("SSH resize: timed out channel=\(managed.id.rawValue)")
    }

    private func closeChannelLocked(
        _ id: SSHTransportChannelID,
        reason: SSHTransportChannelCloseReason,
        notify: Bool
    ) {
        guard let managed = channels.removeValue(forKey: id) else { return }
        managed.isClosing = true

        if let session {
            closeRawChannel(managed.channel, session: session)
        } else {
            libssh2_channel_free(managed.channel)
        }

        if notify {
            let callback = managed.onClosed
            DispatchQueue.main.async {
                callback(reason)
            }
        }

        if channels.isEmpty {
            isRunning = false
        }
    }

    private func closeRawChannel(_ channel: OpaquePointer, session: OpaquePointer) {
        _ = retryBestEffortChannelOperation(session: session) {
            libssh2_channel_send_eof(channel)
        }
        _ = retryBestEffortChannelOperation(session: session) {
            libssh2_channel_close(channel)
        }
        libssh2_channel_free(channel)
    }

    private func retryBestEffortChannelOperation(
        session: OpaquePointer,
        operation: () -> Int32
    ) -> Int32 {
        var attempts = 0
        while attempts < 20 {
            let rc = operation()
            if rc == 0 { return rc }
            guard rc == Int32(LIBSSH2_ERROR_EAGAIN) else { return rc }
            attempts += 1
            waitForSocketActivity(session: session)
        }
        return Int32(LIBSSH2_ERROR_EAGAIN)
    }

    private func waitForSocketActivity(session: OpaquePointer) {
        _ = session
        let stream = networkStream.withLock { $0 }
        stream?.waitForActivity()
    }

    // MARK: - Disconnect

    func disconnect() async {
        logger.info("Disconnecting SSH transport")
        isRunning = false
        cancelPendingIO()

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                let managedChannels = Array(channels.values)
                channels.removeAll()
                for managed in managedChannels {
                    managed.isClosing = true
                }

                if let session {
                    libssh2_session_set_blocking(session, 1)
                    networkStream.withLock { $0?.setBlocking(true) }
                    for managed in managedChannels {
                        libssh2_channel_send_eof(managed.channel)
                        libssh2_channel_wait_eof(managed.channel)
                        libssh2_channel_close(managed.channel)
                        libssh2_channel_wait_closed(managed.channel)
                        libssh2_channel_free(managed.channel)
                    }
                    libssh2_session_disconnect_ex(session, 11 /* SSH_DISCONNECT_BY_APPLICATION */, "bye", "")
                    libssh2_session_free(session)
                    self.session = nil
                } else {
                    for managed in managedChannels {
                        libssh2_channel_free(managed.channel)
                    }
                }

                if let sessionContext {
                    sshapp_session_context_destroy(sessionContext)
                    self.sessionContext = nil
                }
                closePlaceholderSockets()
                networkStream.withLock { $0 = nil }
                authenticationNoticeRelay.setStream(nil)

                logger.info("SSH transport disconnected")
                cont.resume()
            }
        }
    }

    /// Synchronously wake Network.framework and every libssh2 callback that may
    /// be waiting on it. This intentionally does not enqueue work behind the
    /// blocked connection attempt.
    func cancelPendingIO() {
        activeKeyboardBridge.withLock { $0 }?.cancel()
        networkStream.withLock { $0?.cancel() }
    }

    private func closePlaceholderSockets() {
        if placeholderSockets.session >= 0 {
            Darwin.close(placeholderSockets.session)
        }
        if placeholderSockets.peer >= 0 {
            Darwin.close(placeholderSockets.peer)
        }
        placeholderSockets = (-1, -1)
    }
}
