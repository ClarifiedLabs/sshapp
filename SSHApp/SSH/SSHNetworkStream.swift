import Darwin
import Foundation
import Network
import os

private let networkLogger = Logger(subsystem: "dev.sshapp.sshapp", category: "SSHNetworkStream")

enum SSHConnectionPhase: Equatable, Sendable {
    case connecting
    case waitingForNetwork
    case startingSSH

    var label: String {
        switch self {
        case .connecting: "Connecting"
        case .waitingForNetwork: "Waiting for network"
        case .startingSSH: "Starting SSH"
        }
    }
}

struct SSHConnectionProgress: Equatable, Sendable {
    let phase: SSHConnectionPhase
    let startedAt: Date
}

enum SSHNetworkStreamError: LocalizedError, Equatable, Sendable {
    case timedOut(host: String, port: UInt16)
    case failed(String)
    case cancelled
    case invalidPort(UInt16)

    var errorDescription: String? {
        switch self {
        case .timedOut(let host, let port):
            "Connection timed out (\(host):\(port))"
        case .failed(let reason):
            "Connection failed: \(reason)"
        case .cancelled:
            "Connection cancelled"
        case .invalidPort(let port):
            "Invalid network port: \(port)"
        }
    }
}

enum SSHAuthenticationOperationOutcome: Equatable, Sendable {
    case completed
    case timedOut(waitingForInteraction: Bool)
    case failed(String)
    case cancelled
}

/// A synchronous byte-stream facade over NWConnection. libssh2 invokes its I/O
/// callbacks from SSH2Transport's serial queue, while Network.framework
/// delivers state, receive, and send-completion events on `networkQueue`.
final class SSHNetworkStream: @unchecked Sendable {
    private enum State {
        case idle
        case connecting
        case waiting
        case ready
        case failed(String)
        case cancelled
        case ended
    }

    private let condition = NSCondition()
    private let networkQueue = DispatchQueue(label: "dev.sshapp.sshapp.sshnetwork", qos: .userInitiated)
    private let ioTimeout: TimeInterval

    private var connection: NWConnection?
    private var state: State = .idle
    private var bufferedInput = Data()
    private var inputOffset = 0
    private var usesBlockingIO = true
    private var receiveStarted = false
    private var nextSendID: UInt64 = 1
    private var completedSends: Set<UInt64> = []
    private var sendErrors: [UInt64: String] = [:]
    private var authenticationOperationActive = false
    private var authenticationOperationDeadlineUptimeNanoseconds: UInt64?
    private var authenticationWaitDeadlineUptimeNanoseconds: UInt64?
    private var operationTimedOut = false
    private var authenticationWaitTimedOut = false

    init(ioTimeout: TimeInterval = 15) {
        self.ioTimeout = ioTimeout
    }

    func connect(
        host: String,
        port: UInt16,
        timeout: TimeInterval = 30,
        onPhaseChanged: @escaping @Sendable (SSHConnectionPhase) -> Void
    ) throws {
        guard let networkPort = NWEndpoint.Port(rawValue: port) else {
            throw SSHNetworkStreamError.invalidPort(port)
        }

        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: networkPort,
            using: .tcp
        )
        condition.withLock {
            self.connection = connection
            state = .connecting
        }
        connection.stateUpdateHandler = { [weak self] state in
            self?.handle(
                state: state,
                for: connection,
                onPhaseChanged: onPhaseChanged
            )
        }
        onPhaseChanged(.connecting)
        connection.start(queue: networkQueue)

        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while true {
            switch state {
            case .ready:
                return
            case .failed(let reason):
                throw SSHNetworkStreamError.failed(reason)
            case .cancelled:
                throw CancellationError()
            case .ended:
                throw SSHNetworkStreamError.failed("The connection closed before becoming ready")
            case .idle, .connecting, .waiting:
                guard condition.wait(until: deadline) else {
                    if self.connection === connection {
                        self.connection = nil
                        state = .idle
                        condition.broadcast()
                    }
                    condition.unlock()
                    connection.cancel()
                    condition.lock()
                    throw SSHNetworkStreamError.timedOut(host: host, port: port)
                }
            }
        }
    }

    func setBlocking(_ isBlocking: Bool) {
        condition.withLock {
            usesBlockingIO = isBlocking
            condition.broadcast()
        }
    }

    func beginAuthenticationOperation(
        standardDeadlineUptimeNanoseconds: UInt64? = nil,
        interactionDeadlineUptimeNanoseconds: UInt64? = nil
    ) {
        let operationDeadline = standardDeadlineUptimeNanoseconds
            ?? uptimeDeadline(after: ioTimeout)
        condition.withLock {
            authenticationOperationActive = true
            authenticationOperationDeadlineUptimeNanoseconds = operationDeadline
            authenticationWaitDeadlineUptimeNanoseconds =
                interactionDeadlineUptimeNanoseconds
            operationTimedOut = false
            authenticationWaitTimedOut = false
            condition.broadcast()
        }
        if let interactionDeadlineUptimeNanoseconds {
            scheduleAuthenticationWaitTimer(
                deadlineUptimeNanoseconds: interactionDeadlineUptimeNanoseconds
            )
        } else {
            scheduleStandardAuthenticationTimer(
                deadlineUptimeNanoseconds: operationDeadline
            )
        }
    }

    /// Starts one bounded interaction deadline. Repeated banners or challenge
    /// rounds do not extend it.
    func beginAuthenticationWait(maximumDuration: TimeInterval) {
        guard maximumDuration > 0 else { return }
        let durationNanoseconds = UInt64(maximumDuration * 1_000_000_000)
        let now = DispatchTime.now().uptimeNanoseconds
        let sum = now.addingReportingOverflow(durationNanoseconds)
        beginAuthenticationWait(
            deadlineUptimeNanoseconds: sum.overflow ? UInt64.max : sum.partialValue
        )
    }

    func beginAuthenticationWait(deadlineUptimeNanoseconds: UInt64) {
        let shouldScheduleTimer = condition.withLock {
            guard authenticationOperationActive,
                  authenticationWaitDeadlineUptimeNanoseconds == nil else {
                return false
            }
            // The native shim invokes the interaction callback only after it
            // has accepted the challenge before this operation's standard
            // deadline. That acceptance is authoritative at the boundary.
            operationTimedOut = false
            authenticationWaitTimedOut = false
            authenticationWaitDeadlineUptimeNanoseconds = deadlineUptimeNanoseconds
            condition.broadcast()
            return true
        }
        guard shouldScheduleTimer else { return }
        scheduleAuthenticationWaitTimer(
            deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
        )
    }

    private func scheduleStandardAuthenticationTimer(
        deadlineUptimeNanoseconds: UInt64
    ) {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: DispatchTime(uptimeNanoseconds: deadlineUptimeNanoseconds)
        ) { [weak self] in
            guard let self else { return }
            self.condition.withLock {
                guard self.authenticationOperationActive,
                      self.authenticationWaitDeadlineUptimeNanoseconds == nil,
                      self.authenticationOperationDeadlineUptimeNanoseconds
                        == deadlineUptimeNanoseconds,
                      DispatchTime.now().uptimeNanoseconds
                        >= deadlineUptimeNanoseconds else {
                    return
                }
                self.markOperationTimedOut(waitingForInteraction: false)
                self.condition.broadcast()
            }
        }
    }

    private func scheduleAuthenticationWaitTimer(
        deadlineUptimeNanoseconds: UInt64
    ) {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: DispatchTime(uptimeNanoseconds: deadlineUptimeNanoseconds)
        ) { [weak self] in
            guard let self else { return }
            self.condition.withLock {
                guard self.authenticationOperationActive,
                      self.authenticationWaitDeadlineUptimeNanoseconds == deadlineUptimeNanoseconds,
                      self.authenticationWaitHasExpired() else {
                    return
                }
                self.markOperationTimedOut(waitingForInteraction: true)
                self.condition.broadcast()
            }
        }
    }

    @discardableResult
    func finishAuthenticationOperation() -> SSHAuthenticationOperationOutcome {
        condition.withLock {
            let outcome: SSHAuthenticationOperationOutcome
            switch state {
            case .cancelled:
                outcome = .cancelled
            case .failed(let reason):
                outcome = .failed(reason)
            case .ended:
                outcome = .failed("The connection closed during authentication")
            case .idle, .connecting, .waiting, .ready:
                if operationTimedOut || authenticationWaitTimedOut {
                    outcome = .timedOut(waitingForInteraction: authenticationWaitTimedOut)
                } else {
                    outcome = .completed
                }
            }
            authenticationOperationActive = false
            authenticationOperationDeadlineUptimeNanoseconds = nil
            authenticationWaitDeadlineUptimeNanoseconds = nil
            operationTimedOut = false
            authenticationWaitTimedOut = false
            condition.broadcast()
            return outcome
        }
    }

    var isWaitingForAuthenticationInteraction: Bool {
        condition.withLock { authenticationWaitDeadlineUptimeNanoseconds != nil }
    }

    func send(_ bytes: UnsafeRawPointer, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let data = Data(bytes: bytes, count: count)

        condition.lock()
        let standardDeadline = uptimeDeadline(after: ioTimeout)
        while !isReadyState(state) {
            if operationTimedOut || standardAuthenticationOperationHasExpired() {
                markOperationTimedOut(waitingForInteraction: false)
                condition.unlock()
                return -Int(ETIMEDOUT)
            }
            if let error = ioError(for: state) {
                condition.unlock()
                return error
            }
            guard usesBlockingIO else {
                condition.unlock()
                return -Int(EAGAIN)
            }
            let wait = waitForIO(unlessEarlierThan: standardDeadline)
            guard wait.awakened else {
                markOperationTimedOut(waitingForInteraction: wait.isInteractionWait)
                condition.unlock()
                return -Int(ETIMEDOUT)
            }
        }

        if operationTimedOut || standardAuthenticationOperationHasExpired() {
            markOperationTimedOut(waitingForInteraction: false)
            condition.unlock()
            return -Int(ETIMEDOUT)
        }
        if authenticationWaitHasExpired() {
            markOperationTimedOut(waitingForInteraction: true)
            condition.unlock()
            return -Int(ETIMEDOUT)
        }
        guard let connection else {
            condition.unlock()
            return -Int(ENOTCONN)
        }
        let shouldWait = usesBlockingIO
        let sendID: UInt64?
        if shouldWait {
            sendID = nextSendID
            nextSendID &+= 1
        } else {
            sendID = nil
        }
        // Keep deadline validation and send submission in one critical section.
        // The deadline timer uses the same lock, so it cannot race a credential
        // packet through after the operation has been marked timed out.
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            self?.completeSend(id: sendID, error: error)
        })
        condition.unlock()

        guard shouldWait else { return count }
        guard let sendID else { return -Int(EIO) }

        condition.lock()
        defer { condition.unlock() }
        while !completedSends.contains(sendID) {
            if operationTimedOut || standardAuthenticationOperationHasExpired() {
                markOperationTimedOut(waitingForInteraction: false)
                return -Int(ETIMEDOUT)
            }
            if let error = ioError(for: state) {
                return error
            }
            let wait = waitForIO(unlessEarlierThan: standardDeadline)
            guard wait.awakened else {
                markOperationTimedOut(waitingForInteraction: wait.isInteractionWait)
                return -Int(ETIMEDOUT)
            }
        }
        completedSends.remove(sendID)
        if let error = sendErrors.removeValue(forKey: sendID) {
            networkLogger.error("NWConnection send failed: \(error)")
            return -Int(EIO)
        }
        return count
    }

    func receive(into buffer: UnsafeMutableRawPointer, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let standardDeadline = uptimeDeadline(after: ioTimeout)

        condition.lock()
        defer { condition.unlock() }
        if operationTimedOut || standardAuthenticationOperationHasExpired() {
            markOperationTimedOut(waitingForInteraction: false)
            return -Int(ETIMEDOUT)
        }
        if authenticationWaitHasExpired() {
            markOperationTimedOut(waitingForInteraction: true)
            return -Int(ETIMEDOUT)
        }
        while inputOffset >= bufferedInput.count {
            bufferedInput.removeAll(keepingCapacity: true)
            inputOffset = 0

            if case .ended = state { return 0 }
            if let error = ioError(for: state) { return error }
            guard usesBlockingIO else { return -Int(EAGAIN) }

            let wait = waitForIO(unlessEarlierThan: standardDeadline)
            guard wait.awakened else {
                markOperationTimedOut(waitingForInteraction: wait.isInteractionWait)
                return -Int(ETIMEDOUT)
            }
        }

        let available = bufferedInput.count - inputOffset
        let amount = min(count, available)
        bufferedInput.withUnsafeBytes { input in
            guard let baseAddress = input.baseAddress else { return }
            buffer.copyMemory(from: baseAddress.advanced(by: inputOffset), byteCount: amount)
        }
        inputOffset += amount
        if inputOffset == bufferedInput.count {
            bufferedInput.removeAll(keepingCapacity: true)
            inputOffset = 0
        } else if inputOffset > 64 * 1024 {
            bufferedInput.removeFirst(inputOffset)
            inputOffset = 0
        }
        return amount
    }

    func waitForActivity(timeout: TimeInterval = 0.05) {
        condition.lock()
        _ = condition.wait(until: Date().addingTimeInterval(timeout))
        condition.unlock()
    }

    func cancel() {
        condition.lock()
        if case .cancelled = state {
            condition.unlock()
            return
        }
        state = .cancelled
        let connection = connection
        condition.broadcast()
        condition.unlock()
        connection?.cancel()
    }

    private func handle(
        state networkState: NWConnection.State,
        for connection: NWConnection,
        onPhaseChanged: @escaping @Sendable (SSHConnectionPhase) -> Void
    ) {
        guard condition.withLock({ self.connection === connection }) else { return }

        switch networkState {
        case .setup:
            break
        case .preparing:
            condition.withLock {
                guard !isTerminalState(state) else { return }
                state = .connecting
                condition.broadcast()
            }
            onPhaseChanged(.connecting)
        case .waiting(let error):
            networkLogger.info("NWConnection waiting: \(error.localizedDescription)")
            condition.withLock {
                guard !isTerminalState(state) else { return }
                state = Self.isNameResolutionFailure(error)
                    ? .failed("DNS lookup failed: \(error.localizedDescription)")
                    : .waiting
                condition.broadcast()
            }
            if !Self.isNameResolutionFailure(error) {
                onPhaseChanged(.waitingForNetwork)
            }
        case .ready:
            var shouldReceive = false
            condition.withLock {
                guard !isTerminalState(state) else { return }
                state = .ready
                if !receiveStarted {
                    receiveStarted = true
                    shouldReceive = true
                }
                condition.broadcast()
            }
            if shouldReceive { receiveNext() }
        case .failed(let error):
            fail(error.localizedDescription)
        case .cancelled:
            condition.withLock {
                if !isTerminalState(state) { state = .cancelled }
                condition.broadcast()
            }
        @unknown default:
            fail("Unknown Network.framework connection state")
        }
    }

    static func isNameResolutionFailure(_ error: NWError) -> Bool {
        if case .dns = error { return true }
        return false
    }

    private func receiveNext() {
        guard let connection = condition.withLock({ self.connection }) else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var continueReceiving = false
            condition.withLock {
                if let data, !data.isEmpty {
                    bufferedInput.append(data)
                }
                if let error {
                    state = .failed(error.localizedDescription)
                } else if isComplete {
                    state = .ended
                } else if !isTerminalState(state) {
                    continueReceiving = true
                }
                condition.broadcast()
            }
            if continueReceiving { receiveNext() }
        }
    }

    private func completeSend(id: UInt64?, error: NWError?) {
        condition.withLock {
            if let id {
                completedSends.insert(id)
            }
            if let error {
                if let id {
                    sendErrors[id] = error.localizedDescription
                }
                if !isTerminalState(state) {
                    state = .failed(error.localizedDescription)
                }
            }
            condition.broadcast()
        }
    }

    private func fail(_ reason: String) {
        condition.withLock {
            guard !isTerminalState(state) else { return }
            state = .failed(reason)
            condition.broadcast()
        }
    }

    private func isReadyState(_ state: State) -> Bool {
        if case .ready = state { return true }
        return false
    }

    private func isTerminalState(_ state: State) -> Bool {
        switch state {
        case .failed, .cancelled, .ended: true
        case .idle, .connecting, .waiting, .ready: false
        }
    }

    private func markOperationTimedOut(waitingForInteraction: Bool) {
        guard authenticationOperationActive else { return }
        operationTimedOut = true
        authenticationWaitTimedOut =
            authenticationWaitTimedOut || waitingForInteraction
    }

    /// Must be called while `condition` is locked. Interactive waits are
    /// awakened by a DispatchTime timer so wall-clock changes cannot extend or
    /// shorten the absolute monotonic authentication deadline.
    private func waitForIO(
        unlessEarlierThan standardDeadlineUptimeNanoseconds: UInt64
    ) -> (awakened: Bool, isInteractionWait: Bool) {
        if authenticationOperationActive,
           authenticationWaitDeadlineUptimeNanoseconds != nil {
            guard !authenticationWaitHasExpired() else {
                return (false, true)
            }
            condition.wait()
            return (!authenticationWaitHasExpired(), true)
        }
        if authenticationOperationActive,
           let operationDeadline = authenticationOperationDeadlineUptimeNanoseconds {
            guard !operationTimedOut,
                  operationDeadline > DispatchTime.now().uptimeNanoseconds else {
                return (false, false)
            }
            condition.wait()
            return (
                !operationTimedOut &&
                    DispatchTime.now().uptimeNanoseconds < operationDeadline,
                false
            )
        }
        guard standardDeadlineUptimeNanoseconds
                > DispatchTime.now().uptimeNanoseconds else {
            return (false, false)
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: DispatchTime(
                uptimeNanoseconds: standardDeadlineUptimeNanoseconds
            )
        ) { [weak self] in
            guard let self else { return }
            self.condition.withLock { self.condition.broadcast() }
        }
        condition.wait()
        return (
            DispatchTime.now().uptimeNanoseconds
                < standardDeadlineUptimeNanoseconds,
            false
        )
    }

    private func uptimeDeadline(after duration: TimeInterval) -> UInt64 {
        let durationNanoseconds = UInt64(
            min(max(0, duration) * 1_000_000_000, Double(UInt64.max))
        )
        let now = DispatchTime.now().uptimeNanoseconds
        let deadline = now.addingReportingOverflow(durationNanoseconds)
        return deadline.overflow ? UInt64.max : deadline.partialValue
    }

    /// Must be called while `condition` is locked.
    private func standardAuthenticationOperationHasExpired() -> Bool {
        guard authenticationOperationActive,
              authenticationWaitDeadlineUptimeNanoseconds == nil,
              let deadline = authenticationOperationDeadlineUptimeNanoseconds else {
            return false
        }
        return DispatchTime.now().uptimeNanoseconds >= deadline
    }

    /// Must be called while `condition` is locked.
    private func authenticationWaitHasExpired() -> Bool {
        guard authenticationOperationActive,
              let deadline = authenticationWaitDeadlineUptimeNanoseconds else {
            return false
        }
        return DispatchTime.now().uptimeNanoseconds >= deadline
    }

    private func ioError(for state: State) -> Int? {
        switch state {
        case .failed: -Int(EIO)
        case .cancelled: -Int(ECANCELED)
        case .ended: -Int(ECONNRESET)
        case .idle, .connecting, .waiting, .ready: nil
        }
    }
}

private extension NSCondition {
    @discardableResult
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
