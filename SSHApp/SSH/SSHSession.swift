import Foundation
import os

private let logger = Logger(subsystem: "dev.sshapp.sshapp", category: "SSHSession")

/// Errors that can occur during SSH operations
enum SSHError: LocalizedError, Sendable, Equatable {
    case connectionFailed(String)
    case authenticationFailed(String)
    case timeout
    case notConnected
    case alreadyConnected
    case shellNotOpen
    case tooManyAttempts
    case hostKeyRejected
    case hostKeyMismatch(oldFingerprint: String, newFingerprint: String)
    case hostKeyNotTrusted(fingerprint: String, keyType: String)

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let reason): return "Connection failed: \(reason)"
        case .authenticationFailed(let reason): return "Authentication failed: \(reason)"
        case .timeout: return "Connection timed out"
        case .notConnected: return "Not connected to server"
        case .alreadyConnected: return "Already connected"
        case .shellNotOpen: return "Shell is not open"
        case .tooManyAttempts: return "Too many authentication failures"
        case .hostKeyRejected: return "Host key rejected by user"
        case .hostKeyMismatch(let oldFingerprint, let newFingerprint):
            return "Host key mismatch. Expected \(oldFingerprint), received \(newFingerprint)."
        case .hostKeyNotTrusted(let fingerprint, let keyType):
            return "Host key is not trusted. \(keyType) key fingerprint is \(fingerprint)."
        }
    }
}

enum HostKeyVerificationPolicy: Equatable {
    case interactive
    case requireKnownMatch

    func nonInteractiveFailure(for status: HostKeyStatus) -> SSHError? {
        switch (self, status) {
        case (.interactive, _), (.requireKnownMatch, .match):
            return nil
        case (.requireKnownMatch, .mismatch(let oldFingerprint, let newFingerprint)):
            return .hostKeyMismatch(oldFingerprint: oldFingerprint, newFingerprint: newFingerprint)
        case (.requireKnownMatch, .notFound(let fingerprint, let keyType)):
            return .hostKeyNotTrusted(fingerprint: fingerprint, keyType: keyType)
        }
    }
}

enum SSHAuthenticationMode: Equatable {
    case interactive
    case storedCredentialsOnly

    var usesStoredCredentialsOnly: Bool {
        self == .storedCredentialsOnly
    }
}

/// Whether terminal input should be sent to the SSH server or captured locally for auth
enum InputMode: Equatable {
    /// Normal mode: input is sent to the SSH server
    case normal
    /// Auth capture mode: input is buffered locally, no echo (passwords)
    case capturePassword
    /// Auth capture mode: input is buffered locally, with echo (verification codes, etc.)
    case captureInteractive
    /// tmux -CC control mode: input is routed to the active tmux pane via TmuxController.
    case tmuxControlMode
}

/// Manages an SSH connection using libssh2 via SSH2Transport
@MainActor
@Observable
final class SSHSession {
    private var transport: SSH2Transport?
    private let knownHostsManager = KnownHostsManager()
    private var host: String = ""
    private var port: Int = 22

    // Terminal dimensions
    private(set) var isConnected: Bool = false
    private(set) var isAuthenticated: Bool = false

    /// Current input routing mode
    private(set) var inputMode: InputMode = .normal

    /// Settings the controller will use when DCS is detected. Phase 5 wires
    /// this from `AppSettings` + per-host overrides on `SavedConnection`.
    var tmuxSettings: TmuxSettings = .default
    private var channels: [UUID: SSHChannel] = [:]

    /// Continuation for async input collection from terminal
    private var authInputContinuation: CheckedContinuation<String, Never>?

    /// Continuation for waiting until the terminal view is ready
    private var terminalReadyContinuation: CheckedContinuation<Void, Never>?
    private var isTerminalReady: Bool = false

    // Data received callback
    var onDataReceived: (@MainActor (Data) -> Void)?

    // Connection state callback
    var onStateChanged: (@MainActor (ConnectionState) -> Void)?

    init() {}

    var canOpenChannel: Bool {
        transport != nil && isConnected && isAuthenticated
    }

    // MARK: - Terminal Ready Signaling

    func signalTerminalReady() {
        logger.info("Terminal view signaled ready")
        isTerminalReady = true
        terminalReadyContinuation?.resume()
        terminalReadyContinuation = nil
    }

    private func waitForTerminalReady() async {
        if isTerminalReady {
            logger.info("Terminal already ready, proceeding immediately")
            return
        }
        logger.info("Waiting for terminal view to become ready...")
        await withCheckedContinuation { continuation in
            terminalReadyContinuation = continuation
        }
        logger.info("Terminal view is now ready")
    }

    // MARK: - Auth Input

    func submitAuthInput(_ input: String) {
        authInputContinuation?.resume(returning: input)
        authInputContinuation = nil
    }

    /// Prompt for input in the terminal with the given mode.
    ///
    /// The terminal bridge locally handles the user's Return key while in auth
    /// capture mode by echoing one CRLF before calling `submitAuthInput(_:)`.
    /// Callers must not append another CRLF after this returns, otherwise the
    /// terminal shows a blank line after prompts such as host-key acceptance,
    /// username, and password.
    private func promptForInput(_ prompt: String, echo: Bool) async -> String {
        inputMode = echo ? .captureInteractive : .capturePassword
        writeToTerminal(prompt)
        let response = await withCheckedContinuation { continuation in
            authInputContinuation = continuation
        }
        inputMode = .normal
        return response
    }

    private func promptForPassword() async -> String {
        await promptForInput("Password: ", echo: false)
    }

    private func promptForUsername() async -> String {
        await promptForInput("Username: ", echo: true)
    }

    /// Write text directly to the terminal display (not to SSH)
    private func writeToTerminal(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        onDataReceived?(data)
    }

    private func writeStatusToTerminal(_ message: String) {
        writeToTerminal("\(message)\r\n")
    }

    private func authorizeStoredCredentialUse(reason: String, deniedMessage: String) async -> Bool {
        guard CredentialProtectionSettings.isEnabled() else {
            return true
        }

        let result = await BiometricCredentialAuthorizer.authorizeStoredCredentialUse(
            reason: reason,
            allowsPasscodeFallback: CredentialProtectionSettings.isPasscodeFallbackEnabled()
        )
        guard result.isAuthorized else {
            logger.warning("Stored credential authorization failed: \(result.message ?? "unknown")")
            writeToTerminal("\(deniedMessage)\r\n")
            if let message = result.message {
                writeToTerminal("\(message)\r\n")
            }
            return false
        }

        return true
    }

    // MARK: - Unified Auth Flow

    func connectAndAuthenticate(
        host: String,
        port: UInt16 = 22,
        username: String?,
        keyId: UUID?,
        keyStore: KeyStore,
        connectionId: UUID? = nil,
        hostKeyPolicy: HostKeyVerificationPolicy = .interactive,
        authenticationMode: SSHAuthenticationMode = .interactive,
        promptToSaveCredentials: (@MainActor (CredentialSaveOffer) async -> CredentialSaveDecision)? = nil,
        onSavedCredentialsDeclined: (@MainActor () async -> Void)? = nil
    ) async throws {
        self.host = host
        self.port = Int(port)

        logger.info("connectAndAuthenticate: starting for \(host):\(port)")

        // Wait for the terminal view to render before proceeding.
        // The tab must already be in .awaitingInput so the terminal view is shown.
        await waitForTerminalReady()

        writeStatusToTerminal("Connecting to \(host):\(port)...")

        // Step 1: Create transport and connect (single TCP connection)
        let transport = SSH2Transport()
        self.transport = transport

        do {
            try await transport.connect(host: host, port: port)
        } catch {
            logger.error("TCP connection failed: \(error.localizedDescription)")
            throw SSHError.connectionFailed(error.localizedDescription)
        }

        isConnected = true
        writeStatusToTerminal("Connected. Verifying host key...")

        // Step 2: Host key verification
        let hostKeyChanged: Bool
        do {
            hostKeyChanged = try await verifyHostKey(transport: transport, policy: hostKeyPolicy)
        } catch {
            logger.error("Host key verification failed: \(error.localizedDescription)")
            await transport.disconnect()
            isConnected = false
            throw error
        }

        // If the host key changed, saved credentials (username, key, stored
        // password) must not be sent without explicit consent. Declining
        // removes them and falls through to a fully interactive login.
        var effectiveUsername = username
        var effectiveKeyId = keyId
        var hasStoredPassword = false
        if let connectionId {
            hasStoredPassword = await Self.hasPasswordOffMainActor(forConnectionId: connectionId)
        }

        if authenticationMode == .interactive,
           CredentialSavePolicy.shouldConfirmSavedCredentials(
            hostKeyChanged: hostKeyChanged,
            hasSavedUsername: effectiveUsername?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            hasKey: effectiveKeyId.flatMap { keyStore.key(withId: $0) } != nil,
            hasStoredPassword: hasStoredPassword
        ) {
            writeToTerminal("This host's identity has changed. Send your saved credentials (username/password/key) to it anyway? (y/N): ")
            let response = await promptForInput("", echo: true)

            if response.lowercased() != "y" && response.lowercased() != "yes" {
                logger.info("User declined sending saved credentials after host key change; removing them")
                writeStatusToTerminal("Saved credentials removed. Continuing with interactive login.")
                if let connectionId {
                    await Self.deletePasswordOffMainActor(forConnectionId: connectionId)
                }
                await onSavedCredentialsDeclined?()
                effectiveUsername = nil
                effectiveKeyId = nil
                hasStoredPassword = false
            }
        }

        let suppliedUsername = effectiveUsername?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedUsername: String
        let promptedUsername: String?
        if let suppliedUsername, !suppliedUsername.isEmpty {
            resolvedUsername = suppliedUsername
            promptedUsername = nil
        } else if authenticationMode.usesStoredCredentialsOnly {
            throw SSHError.authenticationFailed("Automatic reconnect requires a saved username")
        } else {
            let input = await promptForUsername()
            let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedInput.isEmpty else {
                throw SSHError.authenticationFailed("No username provided")
            }
            resolvedUsername = trimmedInput
            promptedUsername = trimmedInput
        }

        // Step 3: Discover supported auth methods
        writeStatusToTerminal("Authenticating as \(resolvedUsername)...")
        logger.info("Discovering auth methods for \(resolvedUsername)")

        let authMethods: [String]
        do {
            authMethods = try await transport.userAuthList(username: resolvedUsername)
            logger.info("Server auth methods: \(authMethods.joined(separator: ", "))")
        } catch {
            logger.warning("Failed to query auth methods, assuming password: \(error.localizedDescription)")
            authMethods = ["password"]  // fallback assumption
        }

        // Step 4: Try key auth if configured
        if let keyId = effectiveKeyId, let key = keyStore.key(withId: keyId) {
            logger.info("Attempting public key authentication")
            let credentialAuthorized = await authorizeStoredCredentialUse(
                reason: "Authenticate to \(host) using your saved SSH key.",
                deniedMessage: "Biometric authentication is required to use the selected SSH key."
            )
            if credentialAuthorized {
                do {
                    let privateKeyData = try keyStore.getPrivateKey(for: key)
                    let keyType = key.keyType
                    let publicKeyBlob = try SSHKeyGenerator.publicKeyBlob(fromOpenSSHPublicKey: key.publicKey)
                    // Both key types authenticate through libssh2's callback
                    // signer — no private-key PEM is ever materialised. Secure
                    // Enclave signs in-enclave; Ed25519 signs with CryptoKit.
                    try await transport.authPublicKey(username: resolvedUsername, publicKeyBlob: publicKeyBlob) { payload in
                        try SSHKeyGenerator.signSSHPayload(
                            keyType: keyType,
                            privateKeyData: privateKeyData,
                            payload: payload
                        )
                    }
                    isAuthenticated = true
                    logger.info("Public key authentication succeeded")
                    await offerCredentialSave(
                        connectionId: connectionId,
                        promptedUsername: promptedUsername,
                        typedPassword: nil,
                        prompt: promptToSaveCredentials
                    )
                    onStateChanged?(.connected)
                    return
                } catch {
                    logger.warning("Public key authentication failed: \(error.localizedDescription)")
                    writeToTerminal("Key authentication failed: \(error.localizedDescription)\r\n")
                }
            } else if authenticationMode.usesStoredCredentialsOnly {
                throw SSHError.authenticationFailed("Automatic reconnect could not use the saved SSH key")
            }
        }

        // Step 5: Try password auth with up to 3 attempts.
        //
        // If a credential exists for this connection, try it silently first.
        // On success we proceed; on failure the stale credential is cleared and
        // we fall through to interactive prompting.
        var exhaustedPasswordAttempts = false
        if authMethods.contains("password") {
            if let connectionId, hasStoredPassword {
                let credentialAuthorized = await authorizeStoredCredentialUse(
                    reason: "Authenticate to \(host) using your saved SSH password.",
                    deniedMessage: "Biometric authentication is required to use the saved password."
                )
                if credentialAuthorized {
                    if let stored = await Self.loadPasswordOffMainActor(forConnectionId: connectionId) {
                        logger.info("Attempting stored password authentication")
                        do {
                            try await transport.authPassword(username: resolvedUsername, password: stored)
                            isAuthenticated = true
                            logger.info("Stored password authentication succeeded")
                            await offerCredentialSave(
                                connectionId: connectionId,
                                promptedUsername: promptedUsername,
                                typedPassword: nil,
                                prompt: promptToSaveCredentials
                            )
                            onStateChanged?(.connected)
                            return
                        } catch {
                            logger.warning("Stored password authentication failed; clearing stale credential")
                            writeToTerminal("Saved password was rejected.\r\n")
                            await Self.deletePasswordOffMainActor(forConnectionId: connectionId)
                            hasStoredPassword = false
                            if authenticationMode.usesStoredCredentialsOnly {
                                throw SSHError.authenticationFailed("Saved password was rejected")
                            }
                        }
                    } else if authenticationMode.usesStoredCredentialsOnly {
                        throw SSHError.authenticationFailed("Saved password is unavailable")
                    }
                } else if authenticationMode.usesStoredCredentialsOnly {
                    throw SSHError.authenticationFailed("Automatic reconnect could not use the saved password")
                }
            }

            if authenticationMode.usesStoredCredentialsOnly {
                logger.info("Stored-credentials-only password auth did not succeed; skipping password prompt")
            } else {
                logger.info("Attempting password authentication")
                let maxAttempts = 3

                for attempt in 1...maxAttempts {
                    let password = await promptForPassword()

                    if password.isEmpty && attempt == 1 {
                        throw SSHError.authenticationFailed("No password provided")
                    }

                    do {
                        try await transport.authPassword(username: resolvedUsername, password: password)
                        isAuthenticated = true
                        logger.info("Password authentication succeeded")

                        await offerCredentialSave(
                            connectionId: connectionId,
                            promptedUsername: promptedUsername,
                            typedPassword: password.isEmpty ? nil : password,
                            prompt: promptToSaveCredentials
                        )
                        onStateChanged?(.connected)
                        return
                    } catch {
                        logger.warning("Password attempt \(attempt)/\(maxAttempts) failed")
                        if attempt < maxAttempts {
                            writeToTerminal("Permission denied, please try again.\r\n")
                        } else {
                            writeToTerminal("Too many authentication failures.\r\n")
                            exhaustedPasswordAttempts = true
                            break
                        }
                    }
                }
            }
        }

        // Step 6: Fall back to keyboard-interactive if supported.
        if authMethods.contains("keyboard-interactive") {
            // PAM-only servers expose password auth solely via
            // keyboard-interactive. If a password is stored and the password
            // method wasn't available (it would already have tried and
            // cleared a stale credential), try it silently against a lone
            // echo-off prompt before prompting the user.
            if let connectionId,
               hasStoredPassword,
               !authMethods.contains("password") {
                let credentialAuthorized = await authorizeStoredCredentialUse(
                    reason: "Authenticate to \(host) using your saved SSH password.",
                    deniedMessage: "Biometric authentication is required to use the saved password."
                )
                if credentialAuthorized {
                    if let stored = await Self.loadPasswordOffMainActor(forConnectionId: connectionId) {
                        logger.info("Attempting stored password via keyboard-interactive")
                        do {
                            try await transport.authKeyboardInteractive(username: resolvedUsername) { prompts in
                                if CredentialSavePolicy.isLonePasswordPrompt(prompts) {
                                    return [stored]
                                }
                                return prompts.map { _ in "" }
                            }
                            isAuthenticated = true
                            logger.info("Stored password keyboard-interactive authentication succeeded")
                            await offerCredentialSave(
                                connectionId: connectionId,
                                promptedUsername: promptedUsername,
                                typedPassword: nil,
                                prompt: promptToSaveCredentials
                            )
                            onStateChanged?(.connected)
                            return
                        } catch {
                            logger.warning("Stored password keyboard-interactive auth failed; clearing stale credential")
                            writeToTerminal("Saved password was rejected.\r\n")
                            await Self.deletePasswordOffMainActor(forConnectionId: connectionId)
                            hasStoredPassword = false
                            if authenticationMode.usesStoredCredentialsOnly {
                                throw SSHError.authenticationFailed("Saved password was rejected")
                            }
                        }
                    } else if authenticationMode.usesStoredCredentialsOnly {
                        throw SSHError.authenticationFailed("Saved password is unavailable")
                    }
                } else if authenticationMode.usesStoredCredentialsOnly {
                    throw SSHError.authenticationFailed("Automatic reconnect could not use the saved password")
                }
            }

            if authenticationMode.usesStoredCredentialsOnly {
                logger.info("Stored-credentials-only keyboard-interactive auth did not succeed; skipping prompts")
                throw SSHError.authenticationFailed("Stored credentials were not accepted")
            }

            logger.info("Attempting keyboard-interactive authentication")
            // When the whole exchange is a single round with a lone echo-off
            // prompt, the typed response is treated as the account password
            // and offered for saving. Multi-prompt or multi-round exchanges
            // (OTP/2FA) are never captured.
            let capture = KeyboardInteractiveCapture()
            do {
                try await transport.authKeyboardInteractive(username: resolvedUsername) { [weak self] prompts in
                    guard let self else { return prompts.map { _ in "" } }
                    var responses: [String] = []
                    for prompt in prompts {
                        let response = await self.promptForInput(prompt.text, echo: prompt.echo)
                        responses.append(response)
                    }
                    capture.recordRound(prompts: prompts, responses: responses)
                    return responses
                }
                isAuthenticated = true
                logger.info("Keyboard-interactive authentication succeeded")
                await offerCredentialSave(
                    connectionId: connectionId,
                    promptedUsername: promptedUsername,
                    typedPassword: capture.candidatePassword,
                    prompt: promptToSaveCredentials
                )
                onStateChanged?(.connected)
                return
            } catch {
                logger.warning("Keyboard-interactive auth failed: \(error.localizedDescription)")
                if authMethods.contains("password") {
                    throw SSHError.tooManyAttempts
                }
                throw error
            }
        }

        if exhaustedPasswordAttempts {
            throw SSHError.tooManyAttempts
        }

        if authenticationMode.usesStoredCredentialsOnly {
            throw SSHError.authenticationFailed("Stored credentials were not accepted")
        }

        throw SSHError.authenticationFailed("No supported authentication method")
    }

    /// Offer newly-typed credentials for saving after a successful login.
    /// Keychain I/O is done off the main actor / libssh2 session thread to
    /// preserve concurrency invariants; SwiftData writes (username, never-ask
    /// flags) are the caller's responsibility inside `prompt`.
    private func offerCredentialSave(
        connectionId: UUID?,
        promptedUsername: String?,
        typedPassword: String?,
        prompt: (@MainActor (CredentialSaveOffer) async -> CredentialSaveDecision)?
    ) async {
        guard let connectionId, let prompt else { return }
        let offer = CredentialSaveOffer(username: promptedUsername, password: typedPassword)
        guard offer.username != nil || offer.password != nil else { return }

        let decision = await prompt(offer)

        if decision.savePassword, let typedPassword {
            do {
                try await Self.savePasswordOffMainActor(typedPassword, forConnectionId: connectionId)
            } catch {
                logger.warning("Failed to save password: \(error.localizedDescription)")
                writeToTerminal("Could not save password to iCloud Keychain.\r\n")
            }
        }
    }

    // MARK: - Host Key Verification

    /// Returns true when the host key changed (mismatch) and the user accepted the new key.
    private func verifyHostKey(
        transport: SSH2Transport,
        policy: HostKeyVerificationPolicy
    ) async throws -> Bool {
        logger.info("Verifying host key for \(self.host):\(self.port)")
        let (fingerprint, keyType, keyData) = try await transport.hostKeyInfo()

        let status = try await transport.withSession { [knownHostsManager, host, port] session in
            knownHostsManager.check(
                session: session,
                host: host,
                port: port,
                keyData: keyData,
                fingerprint: fingerprint,
                keyType: keyType
            )
        }

        if let failure = policy.nonInteractiveFailure(for: status) {
            switch status {
            case .match:
                break
            case .mismatch:
                writeStatusToTerminal("Host key mismatch. Automatic reconnect aborted.")
            case .notFound:
                writeStatusToTerminal("Host key is not trusted. Automatic reconnect aborted.")
            }
            throw failure
        }

        switch status {
        case .match:
            logger.info("Host key matched known hosts")
            return false

        case .mismatch(let oldFP, let newFP):
            logger.warning("Host key MISMATCH for \(self.host)")
            writeToTerminal("\r\n")
            writeToTerminal("@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\r\n")
            writeToTerminal("@    WARNING: HOST KEY HAS CHANGED!     @\r\n")
            writeToTerminal("@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\r\n")
            writeToTerminal("Host key for \(host) has changed!\r\n")
            writeToTerminal("Old fingerprint: \(oldFP)\r\n")
            writeToTerminal("New fingerprint: \(newFP)\r\n")
            writeToTerminal("Accept new key? (y/N): ")

            let response = await promptForInput("", echo: true)

            guard response.lowercased() == "y" || response.lowercased() == "yes" else {
                throw SSHError.hostKeyRejected
            }

            try await transport.withSession { [knownHostsManager, host, port] session in
                knownHostsManager.addHost(
                    session: session,
                    host: host, port: port,
                    keyData: keyData, keyType: keyType
                )
            }
            return true

        case .notFound(let fp, let kt):
            logger.info("Host key not found in known hosts (fingerprint: \(fp))")
            writeToTerminal("The authenticity of host '\(host)' can't be established.\r\n")
            writeToTerminal("\(kt) key fingerprint is \(fp).\r\n")
            writeToTerminal("Are you sure you want to continue? (yes/no): ")

            let response = await promptForInput("", echo: true)

            guard response.lowercased() == "y" || response.lowercased() == "yes" else {
                throw SSHError.hostKeyRejected
            }

            writeToTerminal("Warning: Permanently added '\(host)' (\(kt)) to the list of known hosts.\r\n")

            try await transport.withSession { [knownHostsManager, host, port] session in
                knownHostsManager.addHost(
                    session: session,
                    host: host, port: port,
                    keyData: keyData, keyType: keyType
                )
            }
            return false
        }
    }

    // MARK: - Shell Channels

    func openShellChannel(termType: String = "xterm-256color", cols: Int = 80, rows: Int = 24) async throws -> SSHChannel {
        guard let transport, canOpenChannel else {
            throw SSHError.notConnected
        }

        let channel = SSHChannel(transport: transport, owner: self, tmuxSettings: tmuxSettings)
        channels[channel.id] = channel

        do {
            try await channel.openShell(termType: termType, cols: cols, rows: rows)
            return channel
        } catch {
            channels.removeValue(forKey: channel.id)
            throw error
        }
    }

    func executeCommand(_ command: String, timeout: TimeInterval = 30) async throws -> SSHExecResult {
        guard let transport, canOpenChannel else {
            throw SSHError.notConnected
        }

        return try await transport.executeCommand(command, timeout: timeout)
    }

    func channelDidClose(_ channel: SSHChannel) {
        guard channels.removeValue(forKey: channel.id) != nil else { return }
        if channels.isEmpty {
            disconnect()
        }
    }

    // MARK: - Disconnection

    func disconnect() {
        logger.info("disconnect() called")

        let openChannels = Array(channels.values)
        channels.removeAll()
        for channel in openChannels {
            channel.markClosedBySessionDisconnect()
        }

        authInputContinuation?.resume(returning: "")
        authInputContinuation = nil

        terminalReadyContinuation?.resume()
        terminalReadyContinuation = nil

        if let transport {
            Task {
                await transport.disconnect()
            }
        }
        transport = nil

        isConnected = false
        isAuthenticated = false
        inputMode = .normal
        onStateChanged?(.disconnected)
    }

    // MARK: - Stored Password Helpers (off the main actor)

    /// Load a remembered password off the main actor so keychain I/O never
    /// blocks the UI or the libssh2 session thread.
    private static func hasPasswordOffMainActor(forConnectionId connectionId: UUID) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            KeychainService.hasPassword(forConnectionId: connectionId)
        }.value
    }

    private static func loadPasswordOffMainActor(forConnectionId connectionId: UUID) async -> String? {
        await Task.detached(priority: .userInitiated) {
            KeychainService.loadPassword(forConnectionId: connectionId)
        }.value
    }

    /// Save a remembered password off the main actor.
    private static func savePasswordOffMainActor(_ password: String, forConnectionId connectionId: UUID) async throws {
        try await Task.detached(priority: .userInitiated) {
            try KeychainService.savePassword(password, forConnectionId: connectionId)
        }.value
    }

    /// Clear a remembered password off the main actor.
    private static func deletePasswordOffMainActor(forConnectionId connectionId: UUID) async {
        await Task.detached(priority: .userInitiated) {
            KeychainService.deletePassword(forConnectionId: connectionId)
        }.value
    }
}

/// Records keyboard-interactive rounds to decide whether the typed response
/// can be offered for saving as the account password: only when the entire
/// exchange was a single round consisting of a lone echo-off prompt.
@MainActor
final class KeyboardInteractiveCapture {
    private var roundCount = 0
    private(set) var candidatePassword: String?

    func recordRound(prompts: [(text: String, echo: Bool)], responses: [String]) {
        roundCount += 1
        if roundCount == 1,
           CredentialSavePolicy.isLonePasswordPrompt(prompts),
           let response = responses.first,
           !response.isEmpty {
            candidatePassword = response
        } else {
            candidatePassword = nil
        }
    }
}
