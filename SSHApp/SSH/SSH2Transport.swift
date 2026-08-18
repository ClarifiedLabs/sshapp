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
enum SSH2Error: LocalizedError {
    case socketFailed(String)
    case handshakeFailed(Int32)
    case authFailed(String)
    case channelFailed(String)
    case disconnected

    var errorDescription: String? {
        switch self {
        case .socketFailed(let msg): return "Socket error: \(msg)"
        case .handshakeFailed(let rc): return "SSH handshake failed (rc=\(rc))"
        case .authFailed(let msg): return "Authentication failed: \(msg)"
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
    private var isRunning = false
    private var isPumpScheduled = false

    /// Cancellation epoch for in-flight shell channel setup. `closeChannel`
    /// cannot reach a channel that has not been registered yet, so closing an
    /// opening shell must abort the native open/PTY/startup retry loops
    /// directly. The epoch is read at setup start; `cancelOpeningShellChannel`
    /// increments it, so setups that begin afterwards are unaffected.
    private let cancellationLock = NSLock()
    private var channelSetupCancellationEpoch: UInt64 = 0

    init() {
        self.queue = DispatchQueue(label: "dev.sshapp.sshapp.ssh2transport", qos: .userInitiated)
    }

    deinit {
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
                let stream = SSHNetworkStream()
                networkStream.withLock { $0 = stream }

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
                    logger.error("Network.framework connection failed: \(error.localizedDescription)")
                    if error is CancellationError { throw error }
                    throw SSH2Error.socketFailed(error.localizedDescription)
                }

                onPhaseChanged(.startingSSH)
                logger.info("Initializing SSH session")
                guard let sess = libssh2_session_init_ex(nil, nil, nil, nil) else {
                    stream.cancel()
                    networkStream.withLock { $0 = nil }
                    throw SSH2Error.socketFailed("Failed to create SSH session")
                }

                guard let context = sshapp_session_context_create(
                    Unmanaged.passUnretained(stream).toOpaque(),
                    networkSendCallback,
                    networkReceiveCallback
                ) else {
                    libssh2_session_free(sess)
                    stream.cancel()
                    networkStream.withLock { $0 = nil }
                    throw SSH2Error.socketFailed("Failed to create SSH I/O context")
                }

                var sockets = [Int32](repeating: -1, count: 2)
                guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else {
                    sshapp_session_context_destroy(context)
                    libssh2_session_free(sess)
                    stream.cancel()
                    networkStream.withLock { $0 = nil }
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

    func discoverAuthentication(username: String) async throws -> SSHAuthenticationDiscovery {
        try await perform { [self] in
            guard let session else { throw SSH2Error.disconnected }
            logger.info("Querying auth methods for \(username)")

            guard let listPtr = libssh2_userauth_list(session, username, UInt32(username.utf8.count)) else {
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
        throw SSH2Error.authFailed("Could not discover authentication methods (rc=\(lastError))")
    }

    func authPassword(username: String, password: String) async throws {
        try await performVoid { [self] in
            guard let session else { throw SSH2Error.disconnected }
            logger.info("Attempting password auth for \(username)")

            let rc = libssh2_userauth_password_ex(
                session,
                username, UInt32(username.utf8.count),
                password, UInt32(password.utf8.count),
                nil
            )
            guard rc == 0 else {
                logger.warning("Password auth failed (rc=\(rc))")
                throw SSH2Error.authFailed("Password authentication failed")
            }
            logger.info("Password auth succeeded")
        }
    }

    /// Authenticate with keyboard-interactive (for 2FA, TOTP, etc.)
    /// Supports multi-round challenges (e.g., password then TOTP).
    func authKeyboardInteractive(
        username: String,
        promptHandler: @escaping @Sendable @MainActor ([(text: String, echo: Bool)]) async -> [String]
    ) async throws {
        logger.info("Starting keyboard-interactive auth for \(username)")
        // Create semaphores and retain them for the C side (void* fields)
        let promptsSema = DispatchSemaphore(value: 0)
        let responsesSema = DispatchSemaphore(value: 0)

        nonisolated(unsafe) let ctx = UnsafeMutablePointer<KbdInteractiveContext>.allocate(capacity: 1)
        ctx.initialize(to: KbdInteractiveContext())
        ctx.pointee.prompts_ready = Unmanaged.passRetained(promptsSema).toOpaque()
        ctx.pointee.responses_ready = Unmanaged.passRetained(responsesSema).toOpaque()

        // Atomic flag: set to true when the libssh2 auth call returns
        let authDone = OSAllocatedUnfairLock(initialState: false)
        let transport = self

        defer {
            // Balance the passRetained calls
            Unmanaged<DispatchSemaphore>.fromOpaque(ctx.pointee.prompts_ready!).release()
            Unmanaged<DispatchSemaphore>.fromOpaque(ctx.pointee.responses_ready!).release()
            ctx.deinitialize(count: 1)
            ctx.deallocate()
        }

        // Local copies for Sendable capture
        let usernameCopy = username

        // Task 1: Run libssh2 auth on the serial queue.
        // The C callback fires once per prompt round (may be multiple).
        let authTask: Task<Void, Error> = Task { @Sendable in
            defer { authDone.withLock { $0 = true } }

            try await transport.performVoid {
                guard let session = transport.session else { throw SSH2Error.disconnected }

                guard let sessionContext = transport.sessionContext else {
                    throw SSH2Error.disconnected
                }
                sshapp_session_context_set_keyboard_context(sessionContext, ctx)
                defer { sshapp_session_context_set_keyboard_context(sessionContext, nil) }

                let rc = libssh2_userauth_keyboard_interactive_ex(
                    session,
                    usernameCopy,
                    UInt32(usernameCopy.utf8.count),
                    kbd_interactive_trampoline
                )

                // Mark auth finished BEFORE the final wake. Otherwise the prompt
                // loop can consume this signal while `authDone` is still false
                // (it is otherwise only set in the Task's defer, after this
                // closure returns), process a spurious zero-prompt round, and
                // park on another wait() that never comes — hanging the auth
                // call and leaking ctx + semaphores.
                authDone.withLock { $0 = true }

                // Signal prompts_ready one last time to unblock the prompt loop
                promptsSema.signal()

                guard rc == 0 else {
                    throw SSH2Error.authFailed("Keyboard-interactive authentication failed")
                }
            }
        }

        // Task 2: Handle prompt rounds from the C callback.
        let promptTask = Task { @Sendable in
            while true {
                // Wait for the C callback to signal prompts are ready
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    DispatchQueue.global().async {
                        promptsSema.wait()
                        cont.resume()
                    }
                }

                if authDone.withLock({ $0 }) { break }

                let numPrompts = Int(ctx.pointee.num_prompts)
                var prompts: [(text: String, echo: Bool)] = []
                for i in 0..<numPrompts {
                    let text = ctx.pointee.prompt_texts[i].map { String(cString: $0) } ?? ""
                    let echo = ctx.pointee.prompt_echos[i] != 0
                    prompts.append((text, echo))
                }

                let responses = await promptHandler(prompts)

                for i in 0..<min(numPrompts, responses.count) {
                    ctx.pointee.responses[i] = strdup(responses[i])
                }

                responsesSema.signal()
            }
        }

        // Wait for auth to complete, then guarantee the prompt loop is released
        // and joined — even if auth threw before it could signal a final round
        // (e.g. the session went away), which would otherwise orphan promptTask
        // parked on wait().
        let authResult = await authTask.result
        authDone.withLock { $0 = true }
        promptsSema.signal()
        _ = await promptTask.result
        try authResult.get()
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

            let rc = username.withCString { usernamePtr in
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

            guard rc == 0 else {
                if let signingError = context.signingError {
                    logger.warning("Callback public key signing failed: \(signingError.localizedDescription)")
                    throw SSH2Error.authFailed("Public key signing failed: \(signingError.localizedDescription)")
                }

                logger.warning("Callback public key auth failed (rc=\(rc))")
                throw SSH2Error.authFailed("Public key authentication failed")
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

                logger.info("SSH transport disconnected")
                cont.resume()
            }
        }
    }

    /// Synchronously wake Network.framework and every libssh2 callback that may
    /// be waiting on it. This intentionally does not enqueue work behind the
    /// blocked connection attempt.
    func cancelPendingIO() {
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
