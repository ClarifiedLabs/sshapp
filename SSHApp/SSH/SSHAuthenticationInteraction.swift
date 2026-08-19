import Foundation
import os

struct SSHAuthenticationNotice: Equatable, Sendable {
    let message: String
    let languageTag: String?

    init(message: String, languageTag: String?) {
        self.message = message
        self.languageTag = languageTag
    }

    init(messageBytes: Data, languageBytes: Data) {
        message = String(decoding: messageBytes, as: UTF8.self)
        let decodedLanguage = String(decoding: languageBytes, as: UTF8.self)
        languageTag = decodedLanguage.isEmpty ? nil : decodedLanguage
    }
}

enum SSHAuthenticationUptime {
    /// Sleeps in the same suspension-aware clock domain as DispatchTime uptime.
    /// The loop also defends against an early wake on runtime implementations
    /// whose relative sleep primitive uses a different clock.
    static func sleep(until deadlineUptimeNanoseconds: UInt64) async throws {
        let clock = SuspendingClock()
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard deadlineUptimeNanoseconds > now else { return }
            let remaining = deadlineUptimeNanoseconds - now
            let interval = min(remaining, UInt64(Int64.max))
            try await clock.sleep(for: .nanoseconds(Int64(interval)))
        }
    }
}

enum SSHAuthenticationWaitPolicy: Equatable, Sendable {
    case nonInteractive
    case interactive
}

struct SSHKeyboardInteractivePrompt: Equatable, Sendable {
    let text: String
    let echo: Bool
}

struct SSHKeyboardInteractiveRound: Equatable, Sendable {
    let name: String
    let instruction: String
    /// libssh2 1.11.1's established callback ABI omits this deprecated RFC field.
    let languageTag: String?
    let prompts: [SSHKeyboardInteractivePrompt]

    init(
        name: String,
        instruction: String,
        languageTag: String?,
        prompts: [SSHKeyboardInteractivePrompt]
    ) {
        self.name = name
        self.instruction = instruction
        self.languageTag = languageTag
        self.prompts = prompts
    }

    /// Decodes the explicit byte ranges copied from libssh2's callback ABI.
    init(
        nameBytes: Data,
        instructionBytes: Data,
        promptBytes: [(text: Data, echo: Bool)]
    ) {
        name = String(decoding: nameBytes, as: UTF8.self)
        instruction = String(decoding: instructionBytes, as: UTF8.self)
        languageTag = nil
        prompts = promptBytes.map {
            SSHKeyboardInteractivePrompt(
                text: String(decoding: $0.text, as: UTF8.self),
                echo: $0.echo
            )
        }
    }
}

enum SSHKeyboardInteractiveResult: Equatable, Sendable {
    case responses([String])
    case timedOut
    case cancelled
}

final class SSHAuthenticationNoticeInbox: @unchecked Sendable {
    private let notices = OSAllocatedUnfairLock(initialState: [SSHAuthenticationNotice]())

    func append(_ notice: SSHAuthenticationNotice) {
        notices.withLock { $0.append(notice) }
    }

    func drain() -> [SSHAuthenticationNotice] {
        notices.withLock {
            let pending = $0
            $0.removeAll(keepingCapacity: true)
            return pending
        }
    }

    func removeAll() {
        notices.withLock { $0.removeAll(keepingCapacity: true) }
    }
}

struct SSHAuthenticationNoticeDeduplicator: Sendable {
    private(set) var recent: [SSHAuthenticationNotice] = []
    let capacity: Int

    init(capacity: Int = 16) {
        self.capacity = max(1, capacity)
    }

    mutating func shouldDisplay(_ notice: SSHAuthenticationNotice) -> Bool {
        guard !recent.contains(notice) else { return false }
        recent.append(notice)
        if recent.count > capacity {
            recent.removeFirst(recent.count - capacity)
        }
        return true
    }

    mutating func reset() {
        recent.removeAll(keepingCapacity: true)
    }
}

final class SSHAuthenticationNoticeRelay: @unchecked Sendable {
    private struct State {
        var stream: SSHNetworkStream?
        var interactionDeadlineUptimeNanoseconds: UInt64?
        var handler: @Sendable (SSHAuthenticationNotice) -> Void
    }

    private let waitPolicy: SSHAuthenticationWaitPolicy
    private let waitDuration: TimeInterval
    private let state: OSAllocatedUnfairLock<State>

    init(
        waitPolicy: SSHAuthenticationWaitPolicy,
        waitDuration: TimeInterval = 30 * 60,
        handler: @escaping @Sendable (SSHAuthenticationNotice) -> Void = { _ in }
    ) {
        self.waitPolicy = waitPolicy
        self.waitDuration = waitDuration
        state = OSAllocatedUnfairLock(
            initialState: State(
                stream: nil,
                interactionDeadlineUptimeNanoseconds: nil,
                handler: handler
            )
        )
    }

    func setStream(_ stream: SSHNetworkStream?) {
        let deadline = state.withLock { current -> UInt64? in
            current.stream = stream
            return current.interactionDeadlineUptimeNanoseconds
        }
        if let deadline {
            stream?.beginAuthenticationWait(
                deadlineUptimeNanoseconds: deadline
            )
        }
    }

    func setHandler(_ handler: @escaping @Sendable (SSHAuthenticationNotice) -> Void) {
        state.withLock { $0.handler = handler }
    }

    var interactionDeadlineUptimeNanoseconds: UInt64? {
        state.withLock { $0.interactionDeadlineUptimeNanoseconds }
    }

    var authenticationInteractionHasExpired: Bool {
        guard let deadline = interactionDeadlineUptimeNanoseconds else {
            return false
        }
        return DispatchTime.now().uptimeNanoseconds >= deadline
    }

    func resetAuthenticationInteraction() {
        state.withLock { $0.interactionDeadlineUptimeNanoseconds = nil }
    }

    func beginAuthenticationInteraction(maximumDuration: TimeInterval? = nil) {
        let duration = maximumDuration ?? waitDuration
        guard duration > 0 else { return }
        let durationNanoseconds = UInt64(
            min(duration * 1_000_000_000, Double(UInt64.max))
        )
        let now = DispatchTime.now().uptimeNanoseconds
        let proposedDeadline = now.addingReportingOverflow(durationNanoseconds)
        beginAuthenticationInteraction(
            deadlineUptimeNanoseconds: proposedDeadline.overflow
                ? UInt64.max
                : proposedDeadline.partialValue
        )
    }

    func beginAuthenticationInteraction(deadlineUptimeNanoseconds: UInt64) {
        guard waitPolicy == .interactive else { return }
        let deadline = state.withLock { current -> UInt64 in
            if let existing = current.interactionDeadlineUptimeNanoseconds {
                return existing
            }
            current.interactionDeadlineUptimeNanoseconds = deadlineUptimeNanoseconds
            return deadlineUptimeNanoseconds
        }
        state.withLock { $0.stream }?.beginAuthenticationWait(
            deadlineUptimeNanoseconds: deadline
        )
    }

    func receive(
        message: UnsafePointer<UInt8>?,
        messageLength: Int,
        language: UnsafePointer<UInt8>?,
        languageLength: Int
    ) {
        guard messageLength >= 0, languageLength >= 0,
              messageLength == 0 || message != nil,
              languageLength == 0 || language != nil else {
            return
        }

        // Copy both borrowed native byte ranges before doing any other work.
        let messageData = message.map { Data(bytes: $0, count: messageLength) } ?? Data()
        let languageData = language.map { Data(bytes: $0, count: languageLength) } ?? Data()
        let notice = SSHAuthenticationNotice(
            messageBytes: messageData,
            languageBytes: languageData
        )
        let delivery = state.withLock { $0.handler }
        delivery(notice)
    }
}
