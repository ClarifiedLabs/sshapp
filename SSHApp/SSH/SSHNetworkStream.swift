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

    func send(_ bytes: UnsafeRawPointer, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let data = Data(bytes: bytes, count: count)

        condition.lock()
        let deadline = Date().addingTimeInterval(ioTimeout)
        while !isReadyState(state) {
            if let error = ioError(for: state) {
                condition.unlock()
                return error
            }
            guard usesBlockingIO else {
                condition.unlock()
                return -Int(EAGAIN)
            }
            guard condition.wait(until: deadline) else {
                condition.unlock()
                return -Int(ETIMEDOUT)
            }
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
        condition.unlock()

        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            self?.completeSend(id: sendID, error: error)
        })

        guard shouldWait else { return count }
        guard let sendID else { return -Int(EIO) }

        condition.lock()
        defer { condition.unlock() }
        while !completedSends.contains(sendID) {
            if let error = ioError(for: state) {
                return error
            }
            guard condition.wait(until: deadline) else {
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
        let deadline = Date().addingTimeInterval(ioTimeout)

        condition.lock()
        defer { condition.unlock() }
        while inputOffset >= bufferedInput.count {
            bufferedInput.removeAll(keepingCapacity: true)
            inputOffset = 0

            if case .ended = state { return 0 }
            if let error = ioError(for: state) { return error }
            guard usesBlockingIO else { return -Int(EAGAIN) }
            guard condition.wait(until: deadline) else { return -Int(ETIMEDOUT) }
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
