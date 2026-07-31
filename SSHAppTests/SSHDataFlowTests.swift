import XCTest
@testable import SSHApp

/// Regression tests for SSH connection, authentication, credential, and reconnect
/// data-flow invariants across SSHSession, SSHChannel, SSH2Transport, and their
/// MainView/GhosttyTerminalView wiring.
final class SSHDataFlowTests: XCTestCase {
    private final class SuspendedShellTransport: SSHChannelTransport, @unchecked Sendable {
        private let lock = NSLock()
        private let onOpenStarted: @Sendable () -> Void
        private let onCloseReceived: @Sendable () -> Void
        private let cancelsOpen: Bool
        private let onCancelReceived: (@Sendable () -> Void)?
        private var openContinuation: CheckedContinuation<SSHTransportChannelID, Error>?
        private var closedChannelIDs: [SSHTransportChannelID] = []
        private var cancelCount = 0

        init(
            onOpenStarted: @escaping @Sendable () -> Void,
            onCloseReceived: @escaping @Sendable () -> Void,
            cancelsOpen: Bool = false,
            onCancelReceived: (@Sendable () -> Void)? = nil
        ) {
            self.onOpenStarted = onOpenStarted
            self.onCloseReceived = onCloseReceived
            self.cancelsOpen = cancelsOpen
            self.onCancelReceived = onCancelReceived
        }

        func openShellChannel(
            term: String,
            cols: Int,
            rows: Int,
            onDataReceived: @escaping @MainActor @Sendable (Data) -> Void,
            onClosed: @escaping @MainActor @Sendable (SSHTransportChannelCloseReason) -> Void
        ) async throws -> SSHTransportChannelID {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    openContinuation = continuation
                }
                onOpenStarted()
            }
        }

        func write(_ data: Data, to id: SSHTransportChannelID) {}

        func resizePTY(channel id: SSHTransportChannelID, cols: Int, rows: Int) {}

        func closeChannel(_ id: SSHTransportChannelID) {
            lock.withLock {
                closedChannelIDs.append(id)
            }
            onCloseReceived()
        }

        func cancelOpeningShellChannel() {
            let shouldCancel = lock.withLock { () -> Bool in
                cancelCount += 1
                return cancelsOpen
            }
            if shouldCancel {
                let continuation = lock.withLock {
                    defer { openContinuation = nil }
                    return openContinuation
                }
                continuation?.resume(throwing: CancellationError())
            }
            onCancelReceived?()
        }

        func completeOpen(with id: SSHTransportChannelID) {
            let continuation = lock.withLock {
                defer { openContinuation = nil }
                return openContinuation
            }
            continuation?.resume(returning: id)
        }

        var closedIDs: [SSHTransportChannelID] {
            lock.withLock { closedChannelIDs }
        }

        var cancelCallCount: Int {
            lock.withLock { cancelCount }
        }
    }

    // MARK: - Shell channel lifecycle

    @MainActor
    func testCloseWhileNativeShellOpenIsSuspendedClosesTheLateChannel() async throws {
        let openStarted = expectation(description: "native shell open suspended")
        let closeReceived = expectation(description: "late native channel closed")
        let transport = SuspendedShellTransport(
            onOpenStarted: { openStarted.fulfill() },
            onCloseReceived: { closeReceived.fulfill() }
        )
        let owner = SSHSession()
        let channel = SSHChannel(
            transport: transport,
            owner: owner,
            tmuxSettings: .default
        )
        let openTask = Task {
            try await channel.openShell()
        }

        await fulfillment(of: [openStarted], timeout: 2)
        channel.close()

        let lateID = SSHTransportChannelID(rawValue: 42)
        transport.completeOpen(with: lateID)

        do {
            try await openTask.value
            XCTFail("A locally closed in-flight shell must not reopen")
        } catch is CancellationError {
            // Expected: close invalidated the opening generation.
        }

        await fulfillment(of: [closeReceived], timeout: 2)
        XCTAssertEqual(transport.closedIDs, [lateID])
        XCTAssertFalse(channel.isOpen)
    }

    /// Regression: closing an opening shell must abort the native setup
    /// promptly instead of leaving libssh2 open/PTY/startup retries alive.
    @MainActor
    func testCloseCancelsSuspendedNativeShellOpenWithoutWaitingForSuccess() async throws {
        let openStarted = expectation(description: "native shell open suspended")
        let cancelReceived = expectation(description: "native setup cancellation received")
        let transport = SuspendedShellTransport(
            onOpenStarted: { openStarted.fulfill() },
            onCloseReceived: { XCTFail("no channel exists to close") },
            cancelsOpen: true,
            onCancelReceived: { cancelReceived.fulfill() }
        )
        let owner = SSHSession()
        let channel = SSHChannel(
            transport: transport,
            owner: owner,
            tmuxSettings: .default
        )
        let openTask = Task {
            try await channel.openShell()
        }

        await fulfillment(of: [openStarted], timeout: 2)
        channel.close()

        // The cancellation reaches the transport synchronously, so the open
        // fails without a late channel ID ever appearing.
        await fulfillment(of: [cancelReceived], timeout: 2)
        do {
            try await openTask.value
            XCTFail("A locally closed in-flight shell open must be cancelled")
        } catch is CancellationError {
            // Expected: close aborted the native setup.
        }

        XCTAssertEqual(transport.cancelCallCount, 1)
        XCTAssertTrue(transport.closedIDs.isEmpty)
        XCTAssertFalse(channel.isOpen)
    }

    func testChannelBuffersPassthroughAcrossTokenizedReceiverReplacement() throws {
        let channelSource = try readSourceFile("SSHApp/SSH/SSHChannel.swift")
        let viewSource = try readSourceFile("SSHApp/Views/GhosttyTerminalView.swift")
        let registerBody = try extractMethodBody(
            from: channelSource,
            methodName: "func registerTerminalOutputReceiver"
        )
        let unregisterBody = try extractMethodBody(
            from: channelSource,
            methodName: "func unregisterTerminalOutputReceiver"
        )
        let deliveryBody = try extractMethodBody(
            from: channelSource,
            methodName: "func deliverTerminalOutput"
        )
        let processBody = try extractMethodBody(
            from: channelSource,
            methodName: "private func processIncomingBytes"
        )
        let channelInitBody = try extractMethodBody(
            from: channelSource,
            methodName: "init("
        )
        let sessionSource = try readSourceFile("SSHApp/SSH/SSHSession.swift")
        let openShellBody = try extractMethodBody(
            from: sessionSource,
            methodName: "func openShellChannel"
        )
        let attachBody = try extractMethodBody(
            from: viewSource,
            methodName: "private func attachChannel"
        )
        let dismantleBody = try extractMethodBody(
            from: viewSource,
            methodName: "func prepareForDismantle"
        )

        XCTAssertTrue(registerBody.contains("terminalOutputReceiverToken = token"))
        XCTAssertTrue(registerBody.contains("setReceiverPreservingPendingOutput(receiver)"))
        XCTAssertTrue(
            unregisterBody.contains("terminalOutputReceiverToken == token"),
            "a stale representable must not unregister its replacement"
        )
        XCTAssertTrue(unregisterBody.contains("setReceiverPreservingPendingOutput(nil)"))
        XCTAssertTrue(deliveryBody.contains("terminalOutputDelivery.enqueue(data)"))
        XCTAssertTrue(processBody.contains("deliverTerminalOutput(bytes)"))
        XCTAssertTrue(channelInitBody.contains("self.terminalOutputDelivery = terminalOutputDelivery"))
        XCTAssertTrue(
            openShellBody.contains("terminalOutputDelivery: terminalOutputDelivery"),
            "SSHSession must pass the host's ordered writer into its initial shell channel"
        )
        XCTAssertTrue(
            attachBody.contains("registerTerminalOutputReceiver(terminalSession)")
        )
        XCTAssertTrue(dismantleBody.contains("unregisterTerminalOutputReceiver"))
    }

    func testClosingAnOpeningShellCannotResurrectItsNativeChannel() throws {
        let source = try readSourceFile("SSHApp/SSH/SSHChannel.swift")
        let openBody = try extractMethodBody(from: source, methodName: "func openShell")
        let closeBody = try extractMethodBody(from: source, methodName: "func close()")
        let disconnectBody = try extractMethodBody(
            from: source,
            methodName: "func markClosedBySessionDisconnect"
        )
        let dataBody = try extractMethodBody(
            from: source,
            methodName: "private func handleTransportData"
        )

        XCTAssertTrue(openBody.contains("guard openingGeneration == nil"))
        XCTAssertTrue(openBody.contains("openingGeneration = generation"))
        XCTAssertTrue(
            openBody.contains("guard openingGeneration == generation, !openWasCancelled")
        )
        XCTAssertTrue(openBody.contains("guard !openWasCancelled else { throw CancellationError() }"))
        XCTAssertTrue(openBody.contains("pendingOpeningClose.generation == generation"))
        XCTAssertTrue(openBody.contains("finishTransportClosed(reason: pendingOpeningClose.reason)"))
        XCTAssertTrue(openBody.contains("transport.closeChannel(id)"))
        XCTAssertTrue(openBody.contains("throw CancellationError()"))
        XCTAssertTrue(closeBody.contains("openingGeneration = nil"))
        XCTAssertTrue(closeBody.contains("activeGeneration = nil"))
        XCTAssertTrue(closeBody.contains("pendingOpeningClose = nil"))
        XCTAssertTrue(closeBody.contains("openWasCancelled = true"))
        XCTAssertTrue(disconnectBody.contains("openWasCancelled = true"))
        XCTAssertTrue(dataBody.contains("pendingOpeningClose?.generation != generation"))
        XCTAssertTrue(
            dataBody.contains("openingGeneration == generation || activeGeneration == generation")
        )
    }

    /// Regression: the terminal must open a shell channel after authentication
    /// once the ghostty surface is attached. Shell state now lives on
    /// `SSHChannel`, not on the authenticated `SSHSession`.
    func testTerminalOpensShellChannelAfterAuthentication() throws {
        let viewSource = try readSourceFile("SSHApp/Views/GhosttyTerminalView.swift")
        let openBody = try extractMethodBody(from: viewSource, methodName: "func openChannelIfReady")

        XCTAssertTrue(
            openBody.contains("session.isAuthenticated"),
            "GhosttyTerminalView must wait for authentication before opening a shell channel"
        )
        XCTAssertTrue(
            openBody.contains("tab.channel == nil"),
            "GhosttyTerminalView must create only one SSHChannel per terminal tab"
        )
        XCTAssertTrue(
            openBody.contains("session.createShellChannel")
                && openBody.contains("openedChannel.openShell"),
            "GhosttyTerminalView must publish the channel synchronously before its transport open suspends"
        )
        XCTAssertTrue(
            openBody.contains("tab.channel = openedChannel"),
            "the opened SSHChannel must be attached to the tab"
        )

        let sessionSource = try readSourceFile("SSHApp/SSH/SSHSession.swift")
        XCTAssertFalse(
            sessionSource.contains("var onAuthenticated:"),
            "SSHSession must not use a global authentication callback to open one shell"
        )
    }

    func testAutoRunCommandDispatchesOnlyForInitialShellChannel() throws {
        let mainSource = try readSourceFile("SSHApp/Views/MainView.swift")
        let connectBody = try extractMethodBody(from: mainSource, methodName: "func connectSession")
        let sharedBody = try extractMethodBody(from: mainSource, methodName: "private func openSharedChannelInNewTab")
        let ghosttySource = try readSourceFile("SSHApp/Views/GhosttyTerminalView.swift")
        let openBody = try extractMethodBody(from: ghosttySource, methodName: "func openChannelIfReady")

        guard let pendingRange = connectBody.range(of: "tab.pendingAutoRunCommand = connection.pendingAutoRunCommand"),
              let authenticateRange = connectBody.range(of: "session.connectAndAuthenticate") else {
            XCTFail("connectSession must snapshot the pending startup command before authentication begins")
            return
        }
        XCTAssertLessThan(
            pendingRange.lowerBound,
            authenticateRange.lowerBound,
            "The pending auto-run command must be attached to the initial tab before connectAndAuthenticate can report .connected"
        )
        XCTAssertFalse(
            sharedBody.contains("pendingAutoRunCommand"),
            "Shared terminals opened on an existing SSHSession must not receive a startup command"
        )

        guard let attachRange = openBody.range(of: "attachChannel(openedChannel)"),
              let consumeRange = openBody.range(of: "tab.consumePendingAutoRunCommand()"),
              let writeRange = openBody.range(of: "openedChannel.writeTerminalCommand(command)") else {
            XCTFail("openChannelIfReady must consume and send the pending startup command")
            return
        }
        XCTAssertLessThan(
            attachRange.lowerBound,
            consumeRange.lowerBound,
            "The command should be sent only after the channel is attached to the terminal sink"
        )
        XCTAssertLessThan(
            consumeRange.lowerBound,
            writeRange.lowerBound,
            "The consumed command must be sent through SSHChannel.writeTerminalCommand"
        )
    }

    // MARK: - Write path

    func testSSHChannelWriteTerminalCommandNormalizesSubmittedCommand() throws {
        let source = try readSourceFile("SSHApp/SSH/SSHChannel.swift")
        let body = try extractMethodBody(from: source, methodName: "func writeTerminalCommand")

        XCTAssertTrue(
            source.contains("func writeTerminalCommand(_ command: String) async throws"),
            "SSHChannel must expose a helper for terminal-style command submission"
        )
        XCTAssertTrue(
            body.contains("command.trimmingCharacters(in: .whitespacesAndNewlines)")
                && body.contains("guard !trimmed.isEmpty else { return }"),
            "Blank startup commands must not send an empty line"
        )
        XCTAssertTrue(
            body.contains(#".replacingOccurrences(of: "\r\n", with: "\r")"#)
                && body.contains(#".replacingOccurrences(of: "\n", with: "\r")"#),
            "Multiline commands must normalize terminal input line endings to carriage returns"
        )
        XCTAssertTrue(
            body.contains(#"if !normalized.hasSuffix("\r")"#)
                && body.contains(#"normalized.append("\r")"#),
            "The helper must append a final carriage return to submit the command"
        )
        XCTAssertTrue(
            body.contains("try await write(data)"),
            "The helper must write through SSHChannel.write so it targets this channel"
        )
    }

    func testSSHChannelConsumesOrderedTmuxDecoderLifecycleEvents() throws {
        let source = try readSourceFile("SSHApp/SSH/SSHChannel.swift")
        let processBody = try extractMethodBody(from: source, methodName: "private func processIncomingBytes")
        let enqueueBody = try extractMethodBody(from: source, methodName: "private func enqueueTmuxLine")
        let startBody = try extractMethodBody(from: source, methodName: "private func startTmuxControlMode")
        let readyBody = try extractMethodBody(
            from: source,
            methodName: "private func startTmuxAttachBootstrapIfReady"
        )
        let bootstrapBody = try extractMethodBody(from: source, methodName: "private func startTmuxAttachBootstrap()")
        let finishBody = try extractMethodBody(from: source, methodName: "private func finishDecodedTmuxControlMode")
        let clearBody = try extractMethodBody(from: source, methodName: "private func clearTmuxControlModeReferences")

        XCTAssertTrue(
            processBody.contains("tmuxLineDecoder.feedEvents(data)"),
            "SSHChannel must consume ordered decoder events so DCS end/start pairs in one SSH read are not collapsed"
        )
        XCTAssertFalse(
            processBody.contains("wasHooked") || processBody.contains("nowHooked"),
            "SSHChannel must not infer tmux lifecycle from only the final decoder hook state"
        )
        XCTAssertTrue(
            processBody.contains("case .controlModeStarted:")
                && processBody.contains("startTmuxControlMode()"),
            "DCS start events must create a tmux controller at the decoded boundary"
        )
        XCTAssertTrue(
            processBody.contains("case .controlModeEnded:")
                && processBody.contains("finishDecodedTmuxControlMode()"),
            "DCS end events must clear the failed controller before a later DCS start in the same read"
        )
        XCTAssertTrue(
            processBody.contains("startTmuxAttachBootstrapIfReady(for: lineBytes)"),
            "tmux bootstrap should inspect decoded lines before starting metadata probes"
        )
        XCTAssertTrue(
            finishBody.contains("let deliveryTask = tmuxLineDeliveryTask")
                && finishBody.contains("_ = clearTmuxControlModeReferences()")
                && finishBody.contains("releaseRetainedTmuxController(after: deliveryTask)"),
            "Decoded tmux exits should clear current controller references while retaining the controller until queued lines drain"
        )
        XCTAssertFalse(
            finishBody.contains("shutdown"),
            "Decoded tmux exits already include a %exit line; clearing references must not race queued line delivery"
        )
        XCTAssertTrue(
            source.contains("private var tmuxAttachTask: Task<Void, Never>?")
                && source.contains("private var tmuxAttachFallbackTask: Task<Void, Never>?"),
            "SSHChannel must own the tmux bootstrap tasks so a failed first DCS can cancel them before fallback attach"
        )
        XCTAssertTrue(
            source.contains("private var tmuxGatewaySetupTask: Task<Void, Never>?"),
            "SSHChannel must track delegate setup before feeding tmux lines"
        )
        XCTAssertTrue(
            startBody.contains("tmuxGatewaySetupTask?.cancel()")
                && startBody.contains("tmuxGatewaySetupTask = Task")
                && startBody.contains("await gateway.setDelegate(controller)"),
            "DCS start should create the gateway and install its delegate without starting metadata probes yet"
        )
        XCTAssertTrue(
            source.contains("setupTask: Task<Void, Never>?")
                && enqueueBody.contains("await setupTask?.value"),
            "tmux protocol lines should wait for gateway delegate setup before delivery"
        )
        XCTAssertTrue(
            readyBody.contains("guard tmuxAttachTask == nil else { return }")
                && readyBody.contains("TmuxLineParser.parseLine(lineBytes)")
                && readyBody.contains("case .sessionChanged")
                && readyBody.contains("scheduleTmuxAttachBootstrapFallbackIfNeeded()"),
            "tmux metadata probes should prefer session-changed but fall back if tmux never emits one"
        )
        XCTAssertTrue(
            bootstrapBody.contains("tmuxAttachTask == nil")
                && bootstrapBody.contains("await setupTask?.value")
                && bootstrapBody.contains("guard !Task.isCancelled else { return }")
                && bootstrapBody.contains("await controller.attach"),
            "tmux attach bootstrap must be single-shot, delegate-ordered, and cancellation-aware"
        )
        XCTAssertTrue(
            clearBody.contains("tmuxAttachTask?.cancel()")
                && clearBody.contains("tmuxAttachTask = nil")
                && clearBody.contains("tmuxAttachFallbackTask?.cancel()")
                && clearBody.contains("tmuxAttachFallbackTask = nil")
                && clearBody.contains("tmuxGatewaySetupTask?.cancel()")
                && clearBody.contains("tmuxGatewaySetupTask = nil"),
            "Clearing a failed tmux controller must cancel its pending bootstrap probes"
        )
    }

    /// SSH write() targets a specific channel buffer and schedules the shared
    /// pump, rather than relying on a single global write queue.
    func testSSHWriteUsesPerChannelThreadSafeBuffer() throws {
        let source = try readSourceFile("SSHApp/SSH/SSH2Transport.swift")
        let body = try extractMethodBody(from: source, methodName: "func write")

        XCTAssertTrue(
            body.contains("guard let managed = channels[id]"),
            "write() must look up the target managed channel"
        )
        XCTAssertTrue(
            body.contains("managed.pendingWrites.withLock"),
            "write() must buffer data on the selected channel"
        )
        XCTAssertTrue(
            body.contains("ensurePumpScheduledLocked()"),
            "write() must schedule the session-wide channel pump"
        )
        XCTAssertTrue(
            source.contains("queue.asyncAfter"),
            "the channel pump must be scheduled so channel-open operations can interleave with I/O"
        )
    }

    /// Routine SSH byte-count write logs are useful during transport debugging,
    /// but too noisy for normal tmux debugging.
    func testSSHWriteTrafficLogsAreGated() throws {
        let source = try readSourceFile("SSHApp/SSH/SSH2Transport.swift")

        XCTAssertTrue(
            source.contains("private let logsSSHWriteTraffic = false"),
            "Routine SSH write byte-count logs should be disabled by default"
        )
        XCTAssertTrue(
            source.contains("logger.debug(\"SSH write: queued"),
            "SSH write queued logs should stay behind the explicit transport debug flag"
        )
        XCTAssertTrue(
            source.contains("logger.debug(\"SSH write: sent"),
            "SSH write sent logs should stay behind the explicit transport debug flag"
        )
    }

    // MARK: - Connection flow

    func testConnectSessionCatchCallsDisconnect() throws {
        let source = try readSourceFile("SSHApp/Views/MainView.swift")
        let body = try extractMethodBody(from: source, methodName: "func connectSession")

        guard let catchRange = body.range(of: "} catch {") ?? body.range(of: "} catch ") else {
            XCTFail("connectSession must have a catch block")
            return
        }
        let afterCatch = String(body[catchRange.lowerBound...])

        XCTAssertTrue(
            afterCatch.contains("session.disconnect()"),
            "connectSession catch block must call session.disconnect()"
        )
    }

    func testSSH2TransportUsesChannelRegistry() throws {
        let source = try readSourceFile("SSHApp/SSH/SSH2Transport.swift")
        let openBody = try extractMethodBody(from: source, methodName: "func openShellChannel")
        let closeBody = try extractMethodBody(from: source, methodName: "private func closeChannelLocked")

        XCTAssertTrue(
            source.contains("struct SSHTransportChannelID"),
            "SSH2Transport must expose an internal channel id for multiplexed channels"
        )
        XCTAssertTrue(
            source.contains("private var channels: [SSHTransportChannelID: ManagedSSHTransportChannel]"),
            "SSH2Transport must keep a channel registry rather than one shell pointer"
        )
        XCTAssertFalse(
            source.contains("private var channel: OpaquePointer?"),
            "SSH2Transport must not regress to a single stored channel"
        )
        XCTAssertTrue(
            openBody.contains("channels[id] = ManagedSSHTransportChannel"),
            "opening a shell must register a managed channel"
        )
        XCTAssertTrue(
            source.contains("func write(_ data: Data, to id: SSHTransportChannelID)"),
            "writes must target a specific transport channel"
        )
        XCTAssertTrue(
            source.contains("func resizePTY(channel id: SSHTransportChannelID"),
            "resizes must target a specific transport channel"
        )
        XCTAssertTrue(
            closeBody.contains("channels.removeValue(forKey: id)"),
            "closing must remove only the selected transport channel"
        )
    }

    func testConnectAndAuthenticateTriesPasswordBeforeKeyboardInteractive() throws {
        let source = try readSourceFile("SSHApp/SSH/SSHSession.swift")
        let body = try extractMethodBody(from: source, methodName: "func connectAndAuthenticate")

        guard let passwordRange = body.range(of: "if authMethods.contains(\"password\")") else {
            XCTFail("connectAndAuthenticate must handle password auth")
            return
        }
        guard let keyboardInteractiveRange = body.range(of: "if authMethods.contains(\"keyboard-interactive\")") else {
            XCTFail("connectAndAuthenticate must keep keyboard-interactive fallback")
            return
        }

        XCTAssertLessThan(
            passwordRange.lowerBound,
            keyboardInteractiveRange.lowerBound,
            "Password auth must be attempted before keyboard-interactive when both are advertised"
        )
    }

    func testPasswordKeychainFlowLoadsByConnectionIdAndPromptsToSave() throws {
        let sessionSource = try readSourceFile("SSHApp/SSH/SSHSession.swift")
        let mainSource = try readSourceFile("SSHApp/Views/MainView.swift")
        let sessionBody = try extractMethodBody(from: sessionSource, methodName: "func connectAndAuthenticate")

        XCTAssertTrue(
            sessionBody.contains("Self.loadPasswordOffMainActor(forConnectionId: connectionId)"),
            "SSHSession must try an existing keychain password by connection id without a saved preference flag"
        )
        XCTAssertTrue(
            mainSource.contains("promptToSaveCredentials:"),
            "MainView must provide a UI confirmation callback for saving typed credentials"
        )
    }

    func testStoredCredentialUseRequiresBiometricAuthorizationBeforeKeychainReads() throws {
        let source = try readSourceFile("SSHApp/SSH/SSHSession.swift")
        let body = try extractMethodBody(from: source, methodName: "func connectAndAuthenticate")

        guard let keyAuthorizationRange = body.range(
            of: "authorizeStoredCredentialUse(\n                reason: \"Authenticate to \\(host) using your saved SSH key.\""
        ),
              let keyLoadRange = body.range(of: "keyStore.getPrivateKey(for: key)") else {
            XCTFail("Could not find key biometric authorization/load flow")
            return
        }

        XCTAssertLessThan(
            keyAuthorizationRange.lowerBound,
            keyLoadRange.lowerBound,
            "SSH private-key data must not load before biometric authorization"
        )

        guard let passwordExistenceRange = body.range(
            of: "Self.hasPasswordOffMainActor(forConnectionId: connectionId)"
        ),
              let passwordAuthorizationRange = body.range(
                of: "reason: \"Authenticate to \\(host) using your saved SSH password.\""
              ),
              let passwordLoadRange = body.range(
                of: "Self.loadPasswordOffMainActor(forConnectionId: connectionId)"
              ) else {
            XCTFail("Could not find stored password existence/authorization/load flow")
            return
        }

        XCTAssertLessThan(
            passwordExistenceRange.lowerBound,
            passwordAuthorizationRange.lowerBound,
            "Stored password existence may be checked before authorization"
        )
        XCTAssertLessThan(
            passwordAuthorizationRange.lowerBound,
            passwordLoadRange.lowerBound,
            "Stored password data must not load before biometric authorization"
        )
    }

    func testCredentialSavePromptHappensAfterSuccessfulTypedPasswordAuth() throws {
        let source = try readSourceFile("SSHApp/SSH/SSHSession.swift")
        let body = try extractMethodBody(from: source, methodName: "func connectAndAuthenticate")

        guard let passwordPromptRange = body.range(of: "let password = await promptForPassword()"),
              let authRange = body.range(of: "try await transport.authPassword(username: resolvedUsername, password: password)"),
              let savePromptRange = body.range(of: "typedPassword: password.isEmpty ? nil : password") else {
            XCTFail("Could not find typed password auth/save flow in connectAndAuthenticate")
            return
        }

        XCTAssertLessThan(passwordPromptRange.lowerBound, authRange.lowerBound)
        XCTAssertLessThan(
            authRange.lowerBound,
            savePromptRange.lowerBound,
            "The combined save prompt must only fire after the typed password authenticates"
        )

        // The keychain write happens inside the shared helper, only after the
        // user's decision comes back from the combined dialog.
        let helperBody = try extractMethodBody(from: source, methodName: "private func offerCredentialSave")
        guard let decisionRange = helperBody.range(of: "let decision = await prompt(offer)"),
              let saveRange = helperBody.range(of: "Self.savePasswordOffMainActor(") else {
            XCTFail("Could not find decision/save flow in offerCredentialSave")
            return
        }
        XCTAssertLessThan(decisionRange.lowerBound, saveRange.lowerBound)
    }

    func testMissingUsernameIsPromptedBeforeAuthenticationAndCanBeSaved() throws {
        let sessionSource = try readSourceFile("SSHApp/SSH/SSHSession.swift")
        let mainSource = try readSourceFile("SSHApp/Views/MainView.swift")
        let body = try extractMethodBody(from: sessionSource, methodName: "func connectAndAuthenticate")

        XCTAssertTrue(
            sessionSource.contains("username: String?"),
            "SSHSession must accept missing usernames"
        )
        XCTAssertTrue(
            sessionSource.contains("private func promptForUsername()"),
            "SSHSession must prompt for a username in the terminal when one is not saved"
        )
        XCTAssertTrue(
            mainSource.contains("connection.username = username"),
            "Saving a prompted username must update the current connection"
        )
        XCTAssertTrue(
            mainSource.contains("connectionStore.saveChanges(touching: connection)"),
            "Saving a prompted username must persist and mark the current connection for sync"
        )

        guard let promptRange = body.range(of: "let input = await promptForUsername()"),
              let authListRange = body.range(of: "transport.userAuthList(username: resolvedUsername)") else {
            XCTFail("Could not find prompted username auth flow in connectAndAuthenticate")
            return
        }
        XCTAssertLessThan(
            promptRange.lowerBound,
            authListRange.lowerBound,
            "Username entry must happen before auth method discovery"
        )
        XCTAssertNil(
            body.range(of: "shouldSaveUsername"),
            "Prompted usernames must not be offered for saving before authentication succeeds"
        )
    }

    func testCredentialSaveUsesSingleCombinedDialog() throws {
        let mainSource = try readSourceFile("SSHApp/Views/MainView.swift")
        let sheetSource = try readSourceFile("SSHApp/Views/CredentialSaveSheet.swift")

        // Regression: the two separate alerts must not come back.
        XCTAssertNil(mainSource.range(of: "\"Save Username?\""), "The separate save-username alert was replaced by CredentialSaveSheet")
        XCTAssertNil(mainSource.range(of: "\"Save Password?\""), "The separate save-password alert was replaced by CredentialSaveSheet")
        XCTAssertTrue(
            mainSource.contains("CredentialSaveSheet("),
            "MainView must present the combined credential-save sheet"
        )

        XCTAssertTrue(sheetSource.contains("Toggle(isOn: $saveUsername)"))
        XCTAssertTrue(sheetSource.contains("Toggle(isOn: $savePassword)"))
        XCTAssertTrue(
            sheetSource.contains(".disabled(!passwordEnabled)"),
            "The password toggle must be gated on the username toggle when no username is saved"
        )
        XCTAssertTrue(
            sheetSource.contains(".disabled(!canSave)"),
            "The Save button must be disabled until at least one credential is selected"
        )
    }

    func testAuthPromptsDoNotAppendSecondBlankLineAfterReturn() throws {
        let source = try readSourceFile("SSHApp/SSH/SSHSession.swift")

        XCTAssertTrue(
            source.contains("The terminal bridge locally handles the user's Return key"),
            "SSHSession must document that auth prompt line breaks are emitted by the terminal input bridge"
        )

        for forbiddenSnippet in [
            "let response = await promptForInput(\"\", echo: true)\n            writeToTerminal(\"\\r\\n\")",
            "let input = await promptForUsername()\n            writeToTerminal(\"\\r\\n\")",
            "let password = await promptForPassword()\n                writeToTerminal(\"\\r\\n\")",
            "let response = await self.promptForInput(prompt.text, echo: prompt.echo)\n                        self.writeToTerminal(\"\\r\\n\")",
        ] {
            XCTAssertFalse(
                source.contains(forbiddenSnippet),
                "Auth prompt callers must not append a second CRLF after the terminal bridge already echoed Return"
            )
        }
    }

    func testSuccessfulPasswordSaveDoesNotPrintTerminalStatus() throws {
        let source = try readSourceFile("SSHApp/SSH/SSHSession.swift")

        XCTAssertFalse(
            source.contains("Password saved to iCloud Keychain."),
            "Successful password saves must stay silent to avoid cluttering the terminal"
        )
        XCTAssertTrue(
            source.contains("Could not save password to iCloud Keychain."),
            "Failed password saves should still explain the failure in the terminal"
        )
    }

    func testShellLifecycleLivesOnSSHChannel() throws {
        let sessionSource = try readSourceFile("SSHApp/SSH/SSHSession.swift")
        let channelSource = try readSourceFile("SSHApp/SSH/SSHChannel.swift")
        let writeBody = try extractMethodBody(from: channelSource, methodName: "func write(_ data")
        let openShellBody = try extractMethodBody(from: channelSource, methodName: "func openShell")
        let disconnectBody = try extractMethodBody(from: sessionSource, methodName: "func disconnect")

        XCTAssertTrue(
            channelSource.contains("private(set) var isOpen"),
            "SSHChannel must track whether its shell channel is open"
        )
        XCTAssertTrue(
            writeBody.contains("guard let transportChannelID, isOpen"),
            "SSHChannel.write must reject input before its shell channel opens"
        )
        XCTAssertTrue(
            openShellBody.contains("isOpen = true"),
            "SSHChannel.openShell must mark the shell as open only after transport setup succeeds"
        )
        XCTAssertTrue(
            disconnectBody.contains("channel.markClosedBySessionDisconnect()"),
            "SSHSession.disconnect must clear all channel-owned shell state"
        )
        XCTAssertFalse(
            sessionSource.contains("private(set) var isShellOpen"),
            "SSHSession must not keep single-shell state after channelization"
        )
    }

    func testSSHChannelReportsRemoteChannelClosure() throws {
        let channelSource = try readSourceFile("SSHApp/SSH/SSHChannel.swift")
        let body = try extractMethodBody(from: channelSource, methodName: "private func finishTransportClosed")

        XCTAssertTrue(
            channelSource.contains("enum SSHChannelRemoteCloseReason")
                && channelSource.contains("var onRemoteDisconnected: (@MainActor (SSHChannelRemoteCloseReason) -> Void)?"),
            "SSHChannel must expose a typed callback for remote channel closure"
        )
        XCTAssertTrue(
            body.contains("owner?.channelDidClose(self)"),
            "remote channel closure must update the shared session's channel registry"
        )
        XCTAssertTrue(
            body.contains("onRemoteDisconnected?(.orderlyExit)")
                && body.contains("onRemoteDisconnected?(.transportFailure)"),
            "remote channel closure must distinguish orderly exits from transport failures"
        )
    }

    func testRemoteChannelCloseRemovesOwningTabWithoutSecondDisconnect() throws {
        let source = try readSourceFile("SSHApp/Views/MainView.swift")
        let closeBody = try extractMethodBody(from: source, methodName: "private func closeTab")

        XCTAssertTrue(
            source.contains("private func closeTab(_ tab: Tab, disconnectSession: Bool = true)"),
            "closeTab must allow callers to remove an already-disconnected tab without calling disconnect again"
        )
        XCTAssertTrue(
            closeBody.contains("channel.close()"),
            "manual tab close should close only the tab's SSHChannel when one exists"
        )
        XCTAssertTrue(
            source.contains("onRemoteChannelClosed: { closedTab, reason in"),
            "MainView must wire remote channel closure to app-tab removal"
        )
        XCTAssertTrue(
            source.contains("handleRemoteChannelClosed(closedTab, reason: reason)"),
            "remote channel closure must route through the background-reconnect-aware handler"
        )

        let handlerBody = try extractMethodBody(from: source, methodName: "private func handleRemoteChannelClosed")
        XCTAssertTrue(
            handlerBody.contains("closeTab(tab, disconnectSession: false)"),
            "non-auto-reconnect remote channel closure must still remove the tab without recursively closing the channel"
        )
    }

    func testForegroundHostInteractionClearsPendingBackgroundReconnectCandidate() throws {
        let mainSource = try readSourceFile("SSHApp/Views/MainView.swift")
        let tabSource = try readSourceFile("SSHApp/Views/TerminalTab.swift")
        let ghosttySource = try readSourceFile("SSHApp/Views/GhosttyTerminalView.swift")
        let tmuxPaneSource = try readSourceFile("SSHApp/Views/TmuxPaneTerminal.swift")
        let ghosttyForwardBody = try extractMethodBody(from: ghosttySource, methodName: "func forwardFromTerminal")
        let tmuxForwardBody = try extractMethodBody(from: tmuxPaneSource, methodName: "func forwardFromTerminal")

        XCTAssertTrue(
            mainSource.contains("onHostSessionInteraction: { interactingTab in")
                && mainSource.contains("handleHostSessionInteraction(interactingTab)"),
            "MainView must clear reconnect tracking when the foregrounded session is actively used"
        )
        XCTAssertTrue(
            tabSource.contains("onHostSessionInteraction: { onHostSessionInteraction(tab) }"),
            "TerminalTab must pass host-session interaction callbacks down to its terminal surfaces"
        )
        XCTAssertTrue(
            ghosttyForwardBody.contains("onHostSessionInteraction?()"),
            "Host-shell input must clear pending background reconnect tracking before sending bytes"
        )
        XCTAssertTrue(
            tmuxForwardBody.contains("onHostSessionInteraction?()"),
            "tmux pane input must clear pending background reconnect tracking before sending bytes"
        )
    }

    func testBackgroundDisconnectQueuesFreshAutomaticReconnectInsteadOfPreservingTabs() throws {
        let source = try readSourceFile("SSHApp/Views/MainView.swift")
        let handlerBody = try extractMethodBody(from: source, methodName: "private func handleRemoteChannelClosed")
        let removeBody = try extractMethodBody(from: source, methodName: "private func removeTabs")
        let openBody = try extractMethodBody(from: source, methodName: "private func openAutomaticReconnectInNewTab")

        XCTAssertTrue(
            source.contains("@Environment(\\.scenePhase) private var scenePhase")
                && source.contains(".onChange(of: scenePhase)"),
            "MainView must observe scenePhase to detect background reconnect candidates"
        )
        XCTAssertTrue(
            source.contains("backgroundReconnectCandidates")
                && source.contains("queuedBackgroundReconnects")
                && source.contains("attemptedBackgroundReconnectKeys"),
            "MainView must track candidates, queued requests, and one-shot attempts"
        )
        XCTAssertTrue(
            source.contains("private func recordBackgroundReconnectCandidates()")
                && source.contains("private func automaticReconnectIsEligible(for connection: SavedConnection)")
                && source.contains("AutomaticReconnectPolicy.isEligible(for: connection, keyStore: keyStore)"),
            "MainView must record only eligible saved connections while entering the background"
        )
        XCTAssertTrue(
            source.contains(
                "private struct BackgroundReconnectCandidate {\n    let sessionID: ObjectIdentifier\n    let connectionID: UUID\n}"
            ),
            "Background reconnect tracking should keep only connection IDs so deleted SwiftData models are not retained"
        )
        XCTAssertTrue(
            source.contains(".onChange(of: savedConnectionIDs)")
                && source.contains("pruneBackgroundReconnectsForMissingConnections()"),
            "MainView must prune queued reconnect work when saved connections are deleted"
        )
        XCTAssertTrue(
            source.contains("private func handleHostSessionInteraction")
                && source.contains("clearBackgroundReconnectTracking(forSessionID:"),
            "Foreground user interaction must clear pending background reconnect candidates"
        )
        XCTAssertFalse(
            source.contains("foregroundReconnectGraceDeadline") || source.contains("backgroundDisconnectWindowIsOpen"),
            "Background reconnect should not rely on a fixed wall-clock grace window"
        )
        XCTAssertTrue(
            handlerBody.contains("reason == .transportFailure")
                && handlerBody.contains("savedConnection(withID: candidate.connectionID)")
                && handlerBody.contains("session.canOpenChannel != true"),
            "Remote channel closure should reconnect only transport-failure candidates that still resolve to a saved connection"
        )
        XCTAssertTrue(
            handlerBody.contains("queueBackgroundReconnect(for: candidate)")
                && handlerBody.contains("removeTabs(forSessionID: sessionID, disconnectSession: false)"),
            "Background disconnects must queue one fresh reconnect and remove stale local tabs"
        )
        XCTAssertTrue(
            removeBody.contains("closeTab(tab, disconnectSession: disconnectSession)"),
            "Stale tabs should be removed through closeTab without preserving old terminal contents"
        )
        XCTAssertTrue(
            openBody.contains("Tab(")
                && openBody.contains("selectTab(newTab)")
                && openBody.contains("attemptMode: .automaticReconnect"),
            "Automatic reconnect must open and select a fresh tab rather than reusing the stale one"
        )
    }

    func testAutomaticReconnectUsesStrictStoredCredentialConnectionAttempt() throws {
        let source = try readSourceFile("SSHApp/Views/MainView.swift")
        let body = try extractMethodBody(from: source, methodName: "func connectSession")

        XCTAssertTrue(
            source.contains("private enum ConnectionAttemptMode")
                && source.contains("case automaticReconnect"),
            "MainView must distinguish automatic reconnect attempts from user-initiated connections"
        )
        XCTAssertTrue(
            source.contains("AutomaticReconnectPolicy.normalizedEnabled(")
                && source.contains("for: connection,")
                && source.contains("keyStore: keyStore"),
            "Automatic reconnect call sites should use the shared normalization helper"
        )
        XCTAssertTrue(
            body.contains("tab.pendingAutoRunCommand = connection.pendingAutoRunCommand"),
            "Automatic reconnect must keep startup commands so tmux -CC attach can restore remote tmux state"
        )
        XCTAssertTrue(
            body.contains("let credentialSaveHandler")
                && body.contains("if isAutomaticReconnect")
                && body.contains("credentialSaveHandler = nil"),
            "Automatic reconnect must not show credential-save prompts"
        )
        XCTAssertTrue(
            body.contains("hostKeyPolicy: isAutomaticReconnect ? .requireKnownMatch : .interactive")
                && body.contains("authenticationMode: isAutomaticReconnect ? .storedCredentialsOnly : .interactive"),
            "Automatic reconnect must require a known host-key match and use stored credentials only"
        )
        XCTAssertTrue(
            body.contains("normalizeAutoReconnectAfterAutomaticFailure(for: connection)"),
            "Automatic reconnect failures must re-check eligibility after stale saved credentials are cleared"
        )
    }

    func testLastChannelCloseDisconnectsSharedSession() throws {
        let source = try readSourceFile("SSHApp/SSH/SSHSession.swift")
        let body = try extractMethodBody(from: source, methodName: "func channelDidClose")

        XCTAssertTrue(
            source.contains("private var channels: [UUID: SSHChannel]"),
            "SSHSession must track opened shell channels"
        )
        XCTAssertTrue(
            body.contains("channels.removeValue(forKey: channel.id)"),
            "SSHSession must remove each closed channel from its registry"
        )
        XCTAssertTrue(
            body.contains("if channels.isEmpty"),
            "SSHSession must detect when the last channel has closed"
        )
        XCTAssertTrue(
            body.contains("disconnect()"),
            "closing the last SSHChannel must disconnect the shared SSH session"
        )
    }

    // MARK: - Helpers

    private func extractMethodBody(from source: String, methodName: String) throws -> String {
        guard let methodRange = source.range(of: methodName) else {
            throw NSError(domain: "Test", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Method '\(methodName)' not found"])
        }

        let afterMethod = source[methodRange.upperBound...]
        guard let braceStart = afterMethod.firstIndex(of: "{") else {
            throw NSError(domain: "Test", code: 2,
                         userInfo: [NSLocalizedDescriptionKey: "No opening brace for '\(methodName)'"])
        }

        var depth = 0
        var braceEnd: String.Index?
        var index = braceStart

        while index < afterMethod.endIndex {
            let char = afterMethod[index]
            if char == "{" { depth += 1 }
            if char == "}" {
                depth -= 1
                if depth == 0 {
                    braceEnd = index
                    break
                }
            }
            index = afterMethod.index(after: index)
        }

        guard let end = braceEnd else {
            throw NSError(domain: "Test", code: 3,
                         userInfo: [NSLocalizedDescriptionKey: "No matching brace for '\(methodName)'"])
        }

        return String(afterMethod[braceStart...end])
    }
}
