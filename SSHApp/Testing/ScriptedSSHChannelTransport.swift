#if DEBUG
import Foundation

/// A deterministic, network-free `SSHChannelTransport` for unit tests and UI-test harnesses.
///
/// All mutable state is protected by one lock. Callbacks, observers, event matchers, and
/// continuations are always invoked or resumed after releasing that lock.
final class ScriptedSSHChannelTransport: SSHChannelTransport, @unchecked Sendable {
    struct OpenRequestID: Hashable, Sendable, CustomStringConvertible {
        let rawValue: UInt64

        var description: String {
            "open-request-\(rawValue)"
        }
    }

    enum CancellationPolicy: Sendable, Equatable {
        case honorTransportCancellation
        case ignoreTransportCancellation
    }

    struct ScriptedError: Error, LocalizedError, Sendable, Equatable, CustomStringConvertible {
        let message: String

        init(_ message: String) {
            self.message = message
        }

        init(message: String) {
            self.message = message
        }

        var description: String {
            message
        }

        var errorDescription: String? {
            message
        }
    }

    enum OpenPlan: Sendable, Equatable {
        case succeed
        case fail(ScriptedError)
        case suspend(cancellation: CancellationPolicy = .honorTransportCancellation)
    }

    enum OpenFailure: Sendable, Equatable {
        case scripted(ScriptedError)
        case cancelled(cancellationEpoch: UInt64)
    }

    enum CallbackTarget: Hashable, Sendable, Equatable {
        /// Addresses callbacks by the open request, including after that open has resolved.
        case openRequest(OpenRequestID)
        case active(SSHTransportChannelID)
    }

    enum InvalidOperation: Sendable, Equatable {
        case unknownOpenRequest(operation: String, requestID: OpenRequestID)
        case unknownChannel(operation: String, channelID: SSHTransportChannelID)
        case callbackAlreadyClosed(operation: String, target: CallbackTarget)
    }

    struct TerminalDimensions: Sendable, Equatable {
        let cols: Int
        let rows: Int
    }

    struct ClientWrite: Sendable, Equatable {
        let channelID: SSHTransportChannelID
        let data: Data
    }

    enum CallbackKind: Sendable, Equatable {
        case data(target: CallbackTarget, data: Data)
        case close(target: CallbackTarget, reason: SSHTransportChannelCloseReason)
    }

    struct PendingCallbackWork: Identifiable, Sendable, Equatable {
        struct ID: Hashable, Sendable, Equatable {
            let rawValue: UInt64
        }

        let id: ID
        let originatingEventSequence: UInt64
        let kind: CallbackKind
    }

    struct PendingRequest: Identifiable, Sendable, Equatable {
        let id: OpenRequestID
        let term: String
        let cols: Int
        let rows: Int
        let plan: OpenPlan
        let cancellationEpoch: UInt64
        let hasDeliveredClose: Bool
    }

    enum Event: Sendable, Equatable {
        case openRequested(
            requestID: OpenRequestID,
            term: String,
            cols: Int,
            rows: Int,
            cancellationEpoch: UInt64,
            plan: OpenPlan
        )
        case openCompleted(requestID: OpenRequestID, channelID: SSHTransportChannelID)
        case openFailed(requestID: OpenRequestID, failure: OpenFailure)
        case dataDelivered(target: CallbackTarget, data: Data)
        case clientWrite(channelID: SSHTransportChannelID, data: Data)
        case resize(channelID: SSHTransportChannelID, cols: Int, rows: Int)
        case localCloseRequested(channelID: SSHTransportChannelID)
        case remoteCloseDelivered(target: CallbackTarget, reason: SSHTransportChannelCloseReason)
        case openingCancellation(
            previousEpoch: UInt64,
            cancellationEpoch: UInt64,
            honoredRequestIDs: [OpenRequestID],
            ignoredRequestIDs: [OpenRequestID]
        )
        case callbackCompleted(PendingCallbackWork)
        case ignoredInvalidOperation(InvalidOperation)
    }

    struct RecordedEvent: Sendable, Equatable {
        let sequence: UInt64
        let event: Event
    }

    struct Snapshot: Sendable, Equatable {
        let ledger: [RecordedEvent]
        let pendingRequests: [PendingRequest]
        let activeChannelIDs: [SSHTransportChannelID]
        let capturedClientWrites: [ClientWrite]
        let latestDimensions: [SSHTransportChannelID: TerminalDimensions]
        let pendingCallbackWork: [PendingCallbackWork]
        let queuedOpenPlans: [OpenPlan]
        let cancellationEpoch: UInt64
        let eventWaiterCount: Int

        var lastEventSequence: UInt64 {
            ledger.last?.sequence ?? 0
        }
    }

    struct EventWaitError: Error, Sendable, CustomStringConvertible {
        enum Reason: String, Sendable {
            case timedOut
            case cancelled
        }

        let reason: Reason
        let afterSequence: UInt64
        let ledger: [RecordedEvent]

        var description: String {
            let renderedLedger: String
            if ledger.isEmpty {
                renderedLedger = "<empty>"
            } else {
                renderedLedger = ledger.map {
                    "#\($0.sequence) \(String(reflecting: $0.event))"
                }.joined(separator: "\n")
            }
            return "Scripted SSH event wait \(reason.rawValue) after sequence "
                + "\(afterSequence). Event ledger:\n\(renderedLedger)"
        }
    }

    typealias EventObserver = @Sendable (RecordedEvent) -> Void

    private typealias DataCallback = @MainActor @Sendable (Data) -> Void
    private typealias CloseCallback = @MainActor @Sendable (SSHTransportChannelCloseReason) -> Void
    private typealias OpenContinuation = CheckedContinuation<SSHTransportChannelID, Error>
    private typealias EventMatcher = @Sendable (Event) -> Bool
    private typealias EventContinuation = CheckedContinuation<RecordedEvent, Error>

    private struct ChannelCallbacks: Sendable {
        let requestID: OpenRequestID
        let onDataReceived: DataCallback
        let onClosed: CloseCallback
    }

    private struct RequestCallbackRegistration: Sendable {
        let callbacks: ChannelCallbacks
        var activeChannelID: SSHTransportChannelID?
        var hasDeliveredClose = false
    }

    private enum QueuedCallbackInvocation: Sendable {
        case data(callback: DataCallback, data: Data)
        case close(callback: CloseCallback, reason: SSHTransportChannelCloseReason)

        @MainActor
        func invoke() {
            switch self {
            case .data(let callback, let data):
                callback(data)
            case .close(let callback, let reason):
                callback(reason)
            }
        }
    }

    private struct QueuedCallbackDelivery: Sendable {
        let work: PendingCallbackWork
        let invocation: QueuedCallbackInvocation
        let completion: CheckedContinuation<Bool, Never>?
    }

    private struct PendingOpen: Sendable {
        let requestID: OpenRequestID
        let term: String
        let cols: Int
        let rows: Int
        let plan: OpenPlan
        let cancellationEpoch: UInt64
        let continuation: OpenContinuation
        let callbacks: ChannelCallbacks
        var hasDeliveredClose = false

        var snapshot: PendingRequest {
            PendingRequest(
                id: requestID,
                term: term,
                cols: cols,
                rows: rows,
                plan: plan,
                cancellationEpoch: cancellationEpoch,
                hasDeliveredClose: hasDeliveredClose
            )
        }
    }

    private struct EventWaiter: Sendable {
        let afterSequence: UInt64
        var scannedThroughSequence: UInt64
        var isEvaluating = false
        let matcher: EventMatcher
        let continuation: EventContinuation
    }

    private struct ObserverRegistration: Sendable {
        let callback: EventObserver
        var nextLedgerIndex: Int
    }

    private struct State: Sendable {
        var queuedOpenPlans: [OpenPlan] = []
        var requestCallbacks: [OpenRequestID: RequestCallbackRegistration] = [:]
        var pendingOpens: [OpenRequestID: PendingOpen] = [:]
        var pendingRequestOrder: [OpenRequestID] = []
        var activeChannels: [SSHTransportChannelID: ChannelCallbacks] = [:]
        var activeChannelOrder: [SSHTransportChannelID] = []
        var capturedClientWrites: [ClientWrite] = []
        var latestDimensions: [SSHTransportChannelID: TerminalDimensions] = [:]
        var pendingCallbackWork: [PendingCallbackWork.ID: PendingCallbackWork] = [:]
        var callbackWorkOrder: [PendingCallbackWork.ID] = []
        var callbackDeliveryQueue: [QueuedCallbackDelivery] = []
        var callbackDeliveryInProgress = false
        var cancellationEpoch: UInt64 = 0
        var nextOpenRequestRawValue: UInt64 = 1
        var nextChannelRawValue: UInt64 = 1
        var nextCallbackWorkRawValue: UInt64 = 1
        var nextEventSequence: UInt64 = 1
        var ledger: [RecordedEvent] = []
        var eventWaiters: [UUID: EventWaiter] = [:]
        var cancelledWaiterIDs: Set<UUID> = []
        var observer: ObserverRegistration?
        var observerDeliveryInProgress = false

        @discardableResult
        mutating func record(_ event: Event) -> RecordedEvent {
            let recorded = RecordedEvent(sequence: nextEventSequence, event: event)
            nextEventSequence += 1
            ledger.append(recorded)
            return recorded
        }

        mutating func makeCallbackWork(
            originatingEventSequence: UInt64,
            kind: CallbackKind
        ) -> PendingCallbackWork {
            let id = PendingCallbackWork.ID(rawValue: nextCallbackWorkRawValue)
            nextCallbackWorkRawValue += 1
            let work = PendingCallbackWork(
                id: id,
                originatingEventSequence: originatingEventSequence,
                kind: kind
            )
            pendingCallbackWork[id] = work
            callbackWorkOrder.append(id)
            return work
        }
    }

    private let lock = NSLock()
    private var state = State()

    // MARK: - Script setup and inspection

    /// Adds a plan for the next open. With no queued plan, opens suspend and honor cancellation.
    func queueOpenPlan(_ plan: OpenPlan = .suspend()) {
        withStateLock { state in
            state.queuedOpenPlans.append(plan)
        }
    }

    func queueOpenPlans(_ plans: [OpenPlan]) {
        withStateLock { state in
            state.queuedOpenPlans.append(contentsOf: plans)
        }
    }

    func snapshot() -> Snapshot {
        withStateLock { state in
            Snapshot(
                ledger: state.ledger,
                pendingRequests: state.pendingRequestOrder.compactMap {
                    state.pendingOpens[$0]?.snapshot
                },
                activeChannelIDs: state.activeChannelOrder.filter {
                    state.activeChannels[$0] != nil
                },
                capturedClientWrites: state.capturedClientWrites,
                latestDimensions: state.latestDimensions,
                pendingCallbackWork: state.callbackWorkOrder.compactMap {
                    state.pendingCallbackWork[$0]
                },
                queuedOpenPlans: state.queuedOpenPlans,
                cancellationEpoch: state.cancellationEpoch,
                eventWaiterCount: state.eventWaiters.count
            )
        }
    }

    /// Installs the one supported observer. Delivery is ordered and always occurs outside the lock.
    func setEventObserver(
        _ observer: EventObserver?,
        replayExistingEvents: Bool = false
    ) {
        withStateLock { state in
            state.observer = observer.map {
                ObserverRegistration(
                    callback: $0,
                    nextLedgerIndex: replayExistingEvents ? 0 : state.ledger.count
                )
            }
        }
        drainObserverEvents()
    }

    // MARK: - SSHChannelTransport

    func openShellChannel(
        term: String,
        cols: Int,
        rows: Int,
        onDataReceived: @escaping @MainActor @Sendable (Data) -> Void,
        onClosed: @escaping @MainActor @Sendable (SSHTransportChannelCloseReason) -> Void
    ) async throws -> SSHTransportChannelID {
        try await withCheckedThrowingContinuation { continuation in
            var completion: Result<SSHTransportChannelID, Error>?

            withStateLock { state in
                let requestID = OpenRequestID(rawValue: state.nextOpenRequestRawValue)
                state.nextOpenRequestRawValue += 1
                let plan = state.queuedOpenPlans.isEmpty
                    ? OpenPlan.suspend()
                    : state.queuedOpenPlans.removeFirst()
                let callbacks = ChannelCallbacks(
                    requestID: requestID,
                    onDataReceived: onDataReceived,
                    onClosed: onClosed
                )
                let pending = PendingOpen(
                    requestID: requestID,
                    term: term,
                    cols: cols,
                    rows: rows,
                    plan: plan,
                    cancellationEpoch: state.cancellationEpoch,
                    continuation: continuation,
                    callbacks: callbacks
                )
                state.requestCallbacks[requestID] = RequestCallbackRegistration(
                    callbacks: callbacks,
                    activeChannelID: nil
                )
                state.pendingOpens[requestID] = pending
                state.pendingRequestOrder.append(requestID)
                state.record(.openRequested(
                    requestID: requestID,
                    term: term,
                    cols: cols,
                    rows: rows,
                    cancellationEpoch: state.cancellationEpoch,
                    plan: plan
                ))

                switch plan {
                case .suspend:
                    break

                case .succeed:
                    state.pendingOpens.removeValue(forKey: requestID)
                    let channelID = makeChannelID(state: &state)
                    state.activeChannels[channelID] = callbacks
                    state.activeChannelOrder.append(channelID)
                    state.requestCallbacks[requestID]?.activeChannelID = channelID
                    state.latestDimensions[channelID] = TerminalDimensions(cols: cols, rows: rows)
                    state.record(.openCompleted(requestID: requestID, channelID: channelID))
                    completion = .success(channelID)

                case .fail(let error):
                    state.pendingOpens.removeValue(forKey: requestID)
                    state.record(.openFailed(requestID: requestID, failure: .scripted(error)))
                    completion = .failure(error)
                }
            }

            eventsDidChange()
            switch completion {
            case .success(let channelID):
                continuation.resume(returning: channelID)
            case .failure(let error):
                continuation.resume(throwing: error)
            case nil:
                break
            }
        }
    }

    func write(_ data: Data, to id: SSHTransportChannelID) {
        var didRecordEvent = false
        withStateLock { state in
            guard state.activeChannels[id] != nil else {
                state.record(.ignoredInvalidOperation(
                    .unknownChannel(operation: "write", channelID: id)
                ))
                didRecordEvent = true
                return
            }
            state.capturedClientWrites.append(ClientWrite(channelID: id, data: data))
            state.record(.clientWrite(channelID: id, data: data))
            didRecordEvent = true
        }
        if didRecordEvent {
            eventsDidChange()
        }
    }

    func resizePTY(channel id: SSHTransportChannelID, cols: Int, rows: Int) {
        var didRecordEvent = false
        withStateLock { state in
            guard state.activeChannels[id] != nil else {
                state.record(.ignoredInvalidOperation(
                    .unknownChannel(operation: "resizePTY", channelID: id)
                ))
                didRecordEvent = true
                return
            }
            state.latestDimensions[id] = TerminalDimensions(cols: cols, rows: rows)
            state.record(.resize(channelID: id, cols: cols, rows: rows))
            didRecordEvent = true
        }
        if didRecordEvent {
            eventsDidChange()
        }
    }

    func closeChannel(_ id: SSHTransportChannelID) {
        var callback: CloseCallback?
        var callbackWork: PendingCallbackWork?

        withStateLock { state in
            guard let callbacks = state.activeChannels.removeValue(forKey: id) else {
                state.record(.ignoredInvalidOperation(
                    .unknownChannel(operation: "closeChannel", channelID: id)
                ))
                return
            }
            if var registration = state.requestCallbacks[callbacks.requestID] {
                registration.hasDeliveredClose = true
                registration.activeChannelID = nil
                state.requestCallbacks[callbacks.requestID] = registration
            }
            let recorded = state.record(.localCloseRequested(channelID: id))
            let target = CallbackTarget.active(id)
            callbackWork = state.makeCallbackWork(
                originatingEventSequence: recorded.sequence,
                kind: .close(target: target, reason: .local)
            )
            callback = callbacks.onClosed
        }

        eventsDidChange()
        guard let callback, let callbackWork else { return }
        Task { @MainActor [callback, callbackWork] in
            callback(.local)
            self.finishCallbackWork(callbackWork)
        }
    }

    func cancelOpeningShellChannel() {
        var continuations: [OpenContinuation] = []

        withStateLock { state in
            let previousEpoch = state.cancellationEpoch
            state.cancellationEpoch += 1
            let cancellationEpoch = state.cancellationEpoch
            var honoredRequestIDs: [OpenRequestID] = []
            var ignoredRequestIDs: [OpenRequestID] = []

            for requestID in state.pendingRequestOrder {
                guard let pending = state.pendingOpens[requestID],
                      pending.cancellationEpoch < cancellationEpoch else {
                    continue
                }
                switch pending.plan {
                case .suspend(cancellation: .honorTransportCancellation):
                    honoredRequestIDs.append(requestID)
                case .suspend(cancellation: .ignoreTransportCancellation):
                    ignoredRequestIDs.append(requestID)
                case .succeed, .fail:
                    break
                }
            }

            state.record(.openingCancellation(
                previousEpoch: previousEpoch,
                cancellationEpoch: cancellationEpoch,
                honoredRequestIDs: honoredRequestIDs,
                ignoredRequestIDs: ignoredRequestIDs
            ))
            for requestID in honoredRequestIDs {
                guard let pending = state.pendingOpens.removeValue(forKey: requestID) else {
                    continue
                }
                state.record(.openFailed(
                    requestID: requestID,
                    failure: .cancelled(cancellationEpoch: cancellationEpoch)
                ))
                continuations.append(pending.continuation)
            }
        }

        eventsDidChange()
        for continuation in continuations {
            continuation.resume(throwing: CancellationError())
        }
    }

    // MARK: - Explicit open drivers

    @discardableResult
    func completeOpen(_ requestID: OpenRequestID) async -> SSHTransportChannelID? {
        var result: (OpenContinuation, SSHTransportChannelID)?

        withStateLock { state in
            guard let pending = state.pendingOpens.removeValue(forKey: requestID) else {
                state.record(.ignoredInvalidOperation(
                    .unknownOpenRequest(operation: "completeOpen", requestID: requestID)
                ))
                return
            }
            let channelID = makeChannelID(state: &state)
            if !pending.hasDeliveredClose {
                state.activeChannels[channelID] = pending.callbacks
                state.activeChannelOrder.append(channelID)
                state.requestCallbacks[requestID]?.activeChannelID = channelID
                state.latestDimensions[channelID] = TerminalDimensions(
                    cols: pending.cols,
                    rows: pending.rows
                )
            }
            state.record(.openCompleted(requestID: requestID, channelID: channelID))
            result = (pending.continuation, channelID)
        }

        eventsDidChange()
        guard let (continuation, channelID) = result else { return nil }
        continuation.resume(returning: channelID)
        return channelID
    }

    @discardableResult
    func failOpen(_ requestID: OpenRequestID, with error: ScriptedError) async -> Bool {
        var continuation: OpenContinuation?

        withStateLock { state in
            guard let pending = state.pendingOpens.removeValue(forKey: requestID) else {
                state.record(.ignoredInvalidOperation(
                    .unknownOpenRequest(operation: "failOpen", requestID: requestID)
                ))
                return
            }
            state.record(.openFailed(requestID: requestID, failure: .scripted(error)))
            continuation = pending.continuation
        }

        eventsDidChange()
        guard let continuation else { return false }
        continuation.resume(throwing: error)
        return true
    }

    // MARK: - Explicit callback drivers

    @discardableResult
    func deliverServerData(_ data: Data, to requestID: OpenRequestID) async -> Bool {
        await deliverServerData(data, to: .openRequest(requestID))
    }

    @discardableResult
    func deliverServerData(_ data: Data, to channelID: SSHTransportChannelID) async -> Bool {
        await deliverServerData(data, to: .active(channelID))
    }

    @discardableResult
    func deliverClose(
        _ reason: SSHTransportChannelCloseReason,
        to requestID: OpenRequestID
    ) async -> Bool {
        await deliverClose(reason, to: .openRequest(requestID))
    }

    @discardableResult
    func deliverClose(
        _ reason: SSHTransportChannelCloseReason,
        to channelID: SSHTransportChannelID
    ) async -> Bool {
        await deliverClose(reason, to: .active(channelID))
    }

    // MARK: - Event waiting

    /// Returns the earliest matching event after `sequence`, or a diagnostic bounded-wait error.
    func nextEvent(
        after sequence: UInt64 = 0,
        timeout: Duration = .seconds(2),
        matching matcher: @escaping @Sendable (Event) -> Bool
    ) async throws -> RecordedEvent {
        let waiterID = UUID()
        defer {
            _ = withStateLock { state in
                state.cancelledWaiterIDs.remove(waiterID)
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var immediateError: EventWaitError?
                withStateLock { state in
                    let wasCancelledBeforeRegistration = state.cancelledWaiterIDs.remove(waiterID) != nil
                    if wasCancelledBeforeRegistration || Task.isCancelled {
                        immediateError = EventWaitError(
                            reason: .cancelled,
                            afterSequence: sequence,
                            ledger: state.ledger
                        )
                    } else {
                        state.eventWaiters[waiterID] = EventWaiter(
                            afterSequence: sequence,
                            scannedThroughSequence: sequence,
                            matcher: matcher,
                            continuation: continuation
                        )
                    }
                }

                if let immediateError {
                    continuation.resume(throwing: immediateError)
                    return
                }

                resolveWaiter(waiterID)
                if timeout <= .zero {
                    timeOutWaiter(waiterID)
                } else {
                    Task { [weak self] in
                        try? await Task.sleep(for: timeout)
                        self?.timeOutWaiter(waiterID)
                    }
                }
            }
        } onCancel: {
            cancelWaiter(waiterID)
        }
    }

    // MARK: - Callback delivery internals

    private func deliverServerData(_ data: Data, to target: CallbackTarget) async -> Bool {
        var callback: DataCallback?
        var callbackWork: PendingCallbackWork?

        withStateLock { state in
            switch target {
            case .openRequest(let requestID):
                guard let registration = state.requestCallbacks[requestID] else {
                    state.record(.ignoredInvalidOperation(
                        .unknownOpenRequest(operation: "deliverServerData", requestID: requestID)
                    ))
                    return
                }
                guard !registration.hasDeliveredClose else {
                    state.record(.ignoredInvalidOperation(
                        .callbackAlreadyClosed(operation: "deliverServerData", target: target)
                    ))
                    return
                }
                callback = registration.callbacks.onDataReceived

            case .active(let channelID):
                guard let callbacks = state.activeChannels[channelID] else {
                    state.record(.ignoredInvalidOperation(
                        .unknownChannel(operation: "deliverServerData", channelID: channelID)
                    ))
                    return
                }
                callback = callbacks.onDataReceived
            }

            let recorded = state.record(.dataDelivered(target: target, data: data))
            callbackWork = state.makeCallbackWork(
                originatingEventSequence: recorded.sequence,
                kind: .data(target: target, data: data)
            )
        }

        eventsDidChange()
        guard let callback, let callbackWork else { return false }
        await MainActor.run {
            callback(data)
        }
        finishCallbackWork(callbackWork)
        return true
    }

    private func deliverClose(
        _ reason: SSHTransportChannelCloseReason,
        to target: CallbackTarget
    ) async -> Bool {
        var callback: CloseCallback?
        var callbackWork: PendingCallbackWork?

        withStateLock { state in
            switch target {
            case .openRequest(let requestID):
                guard var registration = state.requestCallbacks[requestID] else {
                    state.record(.ignoredInvalidOperation(
                        .unknownOpenRequest(operation: "deliverClose", requestID: requestID)
                    ))
                    return
                }
                guard !registration.hasDeliveredClose else {
                    state.record(.ignoredInvalidOperation(
                        .callbackAlreadyClosed(operation: "deliverClose", target: target)
                    ))
                    return
                }
                registration.hasDeliveredClose = true
                if let channelID = registration.activeChannelID {
                    state.activeChannels.removeValue(forKey: channelID)
                    registration.activeChannelID = nil
                }
                state.requestCallbacks[requestID] = registration
                if var pending = state.pendingOpens[requestID] {
                    pending.hasDeliveredClose = true
                    state.pendingOpens[requestID] = pending
                }
                callback = registration.callbacks.onClosed

            case .active(let channelID):
                guard let callbacks = state.activeChannels.removeValue(forKey: channelID) else {
                    state.record(.ignoredInvalidOperation(
                        .unknownChannel(operation: "deliverClose", channelID: channelID)
                    ))
                    return
                }
                if var registration = state.requestCallbacks[callbacks.requestID] {
                    registration.hasDeliveredClose = true
                    registration.activeChannelID = nil
                    state.requestCallbacks[callbacks.requestID] = registration
                }
                callback = callbacks.onClosed
            }

            let recorded = state.record(.remoteCloseDelivered(target: target, reason: reason))
            callbackWork = state.makeCallbackWork(
                originatingEventSequence: recorded.sequence,
                kind: .close(target: target, reason: reason)
            )
        }

        eventsDidChange()
        guard let callback, let callbackWork else { return false }
        await MainActor.run {
            callback(reason)
        }
        finishCallbackWork(callbackWork)
        return true
    }

    private func finishCallbackWork(_ work: PendingCallbackWork) {
        let didFinish = withStateLock { state in
            guard state.pendingCallbackWork.removeValue(forKey: work.id) != nil else {
                return false
            }
            state.record(.callbackCompleted(work))
            return true
        }
        if didFinish {
            eventsDidChange()
        }
    }

    // MARK: - Event delivery internals

    private func eventsDidChange() {
        drainObserverEvents()
        let waiterIDs = withStateLock { state in
            Array(state.eventWaiters.keys)
        }
        for waiterID in waiterIDs {
            resolveWaiter(waiterID)
        }
    }

    /// Serializes observer delivery by ledger index without calling the observer under the lock.
    private func drainObserverEvents() {
        let shouldDrain = withStateLock { state in
            guard state.observer != nil, !state.observerDeliveryInProgress else {
                return false
            }
            state.observerDeliveryInProgress = true
            return true
        }
        guard shouldDrain else { return }

        while true {
            let delivery: (EventObserver, RecordedEvent)? = withStateLock { state in
                guard var observer = state.observer else {
                    state.observerDeliveryInProgress = false
                    return nil
                }
                guard observer.nextLedgerIndex < state.ledger.count else {
                    state.observerDeliveryInProgress = false
                    return nil
                }
                let event = state.ledger[observer.nextLedgerIndex]
                observer.nextLedgerIndex += 1
                state.observer = observer
                return (observer.callback, event)
            }
            guard let (observer, event) = delivery else { return }
            observer(event)
        }
    }

    /// Each waiter has one evaluator, preserving earliest-match semantics without evaluating under lock.
    private func resolveWaiter(_ waiterID: UUID) {
        while true {
            let evaluation: (EventMatcher, [RecordedEvent])? = withStateLock { state in
                guard var waiter = state.eventWaiters[waiterID], !waiter.isEvaluating else {
                    return nil
                }
                let events = state.ledger.filter { $0.sequence > waiter.scannedThroughSequence }
                guard !events.isEmpty else { return nil }
                waiter.isEvaluating = true
                state.eventWaiters[waiterID] = waiter
                return (waiter.matcher, events)
            }
            guard let (matcher, events) = evaluation else { return }

            let match = events.first { matcher($0.event) }
            var continuationAndResult: (EventContinuation, RecordedEvent)?
            var shouldContinue = false

            withStateLock { state in
                guard var waiter = state.eventWaiters[waiterID] else { return }
                if let match {
                    state.eventWaiters.removeValue(forKey: waiterID)
                    continuationAndResult = (waiter.continuation, match)
                    return
                }

                waiter.scannedThroughSequence = events.last?.sequence
                    ?? waiter.scannedThroughSequence
                waiter.isEvaluating = false
                state.eventWaiters[waiterID] = waiter
                shouldContinue = state.ledger.last?.sequence ?? 0 > waiter.scannedThroughSequence
            }

            if let (continuation, result) = continuationAndResult {
                continuation.resume(returning: result)
                return
            }
            guard shouldContinue else { return }
        }
    }

    private func timeOutWaiter(_ waiterID: UUID) {
        let continuationAndError: (EventContinuation, EventWaitError)? = withStateLock { state in
            guard let waiter = state.eventWaiters.removeValue(forKey: waiterID) else {
                return nil
            }
            return (
                waiter.continuation,
                EventWaitError(
                    reason: .timedOut,
                    afterSequence: waiter.afterSequence,
                    ledger: state.ledger
                )
            )
        }
        guard let (continuation, error) = continuationAndError else { return }
        continuation.resume(throwing: error)
    }

    private func cancelWaiter(_ waiterID: UUID) {
        let continuationAndError: (EventContinuation, EventWaitError)? = withStateLock { state in
            guard let waiter = state.eventWaiters.removeValue(forKey: waiterID) else {
                state.cancelledWaiterIDs.insert(waiterID)
                return nil
            }
            return (
                waiter.continuation,
                EventWaitError(
                    reason: .cancelled,
                    afterSequence: waiter.afterSequence,
                    ledger: state.ledger
                )
            )
        }
        guard let (continuation, error) = continuationAndError else { return }
        continuation.resume(throwing: error)
    }

    // MARK: - Locked state helpers

    private func withStateLock<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }

    private func makeChannelID(state: inout State) -> SSHTransportChannelID {
        let id = SSHTransportChannelID(rawValue: state.nextChannelRawValue)
        state.nextChannelRawValue += 1
        return id
    }
}
#endif
