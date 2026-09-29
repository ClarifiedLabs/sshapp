import Foundation
import GhosttyVT

/// Host-measured geometry for one VT layout generation, in points.
public struct VTTerminalSessionMetrics: Sendable, Equatable {
    public var width: Double
    public var height: Double
    public var cellWidth: Double
    public var cellHeight: Double
    public var scale: Double
    public var padding: Double

    public init(
        width: Double,
        height: Double,
        cellWidth: Double,
        cellHeight: Double,
        scale: Double,
        padding: Double = 8
    ) {
        self.width = width
        self.height = height
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.scale = scale
        self.padding = padding
    }
}

/// Host-owned semantic session. Every engine operation is admitted to one FIFO,
/// including layout, configuration, input, snapshots and retirement. Actor
/// isolation alone would not order operations launched by independent tasks.
///
/// Live output uses `deliver`: completion means ingestion AND reply/event fan-out
/// finished, so the caller's bounded delivery queue supplies backpressure. No
/// main-thread waits, locks across await, or canceled accepted terminal bytes.
public final class VTTerminalSession: @unchecked Sendable {
    /// Accessed only by the single FIFO drainer.
    private final class State: @unchecked Sendable {
        var terminal: VTTerminal?
        var configuration = VTTerminalConfiguration()
        var layoutGeneration: UInt64 = 0
        var momentumRemainder: CGFloat = 0
        var selectionHost: UUID?
    }

    /// Only the not-yet-started tail may be merged. Every ordinary admission
    /// seals it, including output, keys, focus, layout and button transitions.
    /// One payload and one completion are retained per uninterrupted stream.
    private final class InteractionTail: @unchecked Sendable {
        enum Payload {
            case motion(VTPointerRequest, @Sendable @MainActor (VTPointerRequest, VTPointerResponse?) -> Void)
            case wheel(VTPointerScrollRequest, CGFloat, CGFloat, Bool, @Sendable @MainActor () -> Void)
            case hover(CGPoint, VTModifiers, UUID, UInt64, VTFrameValue?, @Sendable @MainActor (VTLinkHit?) -> Void)
        }
        var payload: Payload
        init(_ payload: Payload) { self.payload = payload }
    }
    private var interactionTail: InteractionTail?
    var queuedInteractionBatches: UInt64 { synchronized { interactionBatchCount } }
    private var interactionBatchCount: UInt64 = 0

    /// Each API task waits only for its own completion, never another task.
    /// Completion may arrive before the wrapper starts waiting.
    private final class OperationCompletion<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<T, Error>?
        private var continuation: CheckedContinuation<T, Error>?

        func value() async throws -> T {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(with: result)
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        }

        func resolve(_ result: Result<T, Error>) {
            lock.lock()
            self.result = result
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(with: result)
        }
    }

    private typealias Operation = @Sendable (State) async -> Void
    private let state = State()
    private let lock = NSLock()
    private var operations: [Operation?] = []
    private var operationHead = 0
    private var isDraining = false
    private var pointerID: UInt64 = 0

    /// A retained engine outlives UIKit hosts. IDs must share that lifetime;
    /// an old host's late cancellation can never name a new host's stream.
    public func allocatePointerID() -> UInt64? {
        synchronized {
            guard !finished, pointerID < UInt64.max else { return nil }
            pointerID += 1
            return pointerID
        }
    }
    private var finished = false
    private var metrics: VTTerminalSessionMetrics?
    private var layoutGeneration: UInt64 = 0
    private var bufferedBytes = 0
    private let maxBufferedBytes = 512 * 1024
    @MainActor private weak var storedEventDelegate: (any TerminalSurfaceViewDelegate)?
    @MainActor private var eventDelegateOwner: UUID?
    @MainActor private var eventDelegateBinding = UUID()
    /// At most three values, never an event backlog. Empty strings and progress
    /// removal are durable clears and must survive a disposable host's lifetime.
    @MainActor private var metadata: [VTEvent] = []
    private var frameObservers: [UUID: @Sendable @MainActor () -> Void] = [:]
    private var framesHook: (@Sendable @MainActor () -> Void)?
    private var deliveryHook: (@Sendable () async -> Void)?
    private var layoutHook: (@Sendable () throws -> Void)?

    /// Internal deterministic handoff seam for lifetime/generation tests.
    var beforeDelivery: (@Sendable () async -> Void)? {
        get { synchronized { deliveryHook } }
        set { synchronized { deliveryHook = newValue } }
    }

    /// Internal failure-injection seam, run on the FIFO before a layout applies.
    var beforeLayoutApply: (@Sendable () throws -> Void)? {
        get { synchronized { layoutHook } }
        set { synchronized { layoutHook = newValue } }
    }
    private let writeHandler: @Sendable (Data) -> Void
    private let resizeHandler: @Sendable (InMemoryTerminalViewport) -> Void

    @MainActor
    public var eventDelegate: (any TerminalSurfaceViewDelegate)? {
        get { storedEventDelegate }
        set { bindEventDelegate(newValue, owner: nil) }
    }

    /// Host ownership, not delegate identity: a replacement may reuse both the
    /// session and delegate before an old host's main-actor cleanup runs.
    @MainActor
    func setEventDelegate(_ delegate: (any TerminalSurfaceViewDelegate)?, owner: UUID) {
        bindEventDelegate(delegate, owner: owner)
    }

    @MainActor
    private func bindEventDelegate(_ delegate: (any TerminalSurfaceViewDelegate)?, owner: UUID?) {
        guard storedEventDelegate !== delegate || eventDelegateOwner != owner else { return }
        storedEventDelegate = delegate
        eventDelegateOwner = owner
        let binding = UUID()
        eventDelegateBinding = binding
        // Callouts may synchronously bind/clear another host, even with the same
        // delegate. Fence each replay value, not just the initial snapshot.
        for event in metadata {
            guard eventDelegateBinding == binding, let current = storedEventDelegate else { return }
            dispatch(event, to: current)
        }
    }

    @MainActor
    func clearEventDelegate(owner: UUID) {
        guard eventDelegateOwner == owner else { return }
        bindEventDelegate(nil, owner: nil)
    }

    public var onFramesAvailable: (@Sendable @MainActor () -> Void)? {
        get { synchronized { framesHook } }
        set { synchronized { framesHook = newValue } }
    }

    func observeFrames(_ observer: @escaping @Sendable @MainActor () -> Void) -> UUID {
        synchronized {
            let token = UUID()
            frameObservers[token] = observer
            return token
        }
    }

    func removeFrameObserver(_ token: UUID) {
        synchronized { _ = frameObservers.removeValue(forKey: token) }
    }

    public init(
        write: @escaping @Sendable (Data) -> Void,
        resize: @escaping @Sendable (InMemoryTerminalViewport) -> Void
    ) {
        writeHandler = write
        resizeHandler = resize
    }

    // MARK: - Ordered admission

    private func synchronized<T>(_ work: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return work()
    }

    /// Caller holds lock. Admission is synchronous, but execution belongs to a
    /// single independent drainer. Linking predecessor tasks here makes Swift's
    /// priority escalation recurse through the entire backlog (and overflow).
    private func appendLocked<T: Sendable>(
        _ operation: @escaping @Sendable (State) async throws -> T
    ) -> Task<T, Error> {
        interactionTail = nil
        let completion = OperationCompletion<T>()
        operations.append { state in
            do { completion.resolve(.success(try await operation(state))) }
            catch { completion.resolve(.failure(error)) }
        }
        if !isDraining {
            isDraining = true
            // Retain the session until all accepted work, including retirement,
            // drains. Neither caller cancellation nor wrapper priority owns it.
            Task.detached { await self.drain() }
        }
        return Task { try await completion.value() }
    }

    private func drain() async {
        while let operation = synchronized({ () -> Operation? in
            guard operationHead < operations.count else {
                operations.removeAll(keepingCapacity: true)
                operationHead = 0
                isDraining = false
                return nil
            }
            let operation = operations[operationHead]
            operations[operationHead] = nil // Release completed payloads promptly.
            operationHead += 1
            if operationHead >= 1024, operationHead >= operations.count / 2 {
                operations.removeFirst(operationHead)
                operationHead = 0
            }
            return operation
        }) {
            await operation(state)
        }
    }

    private func submit<T: Sendable>(
        _ operation: @escaping @Sendable (State) async throws -> T
    ) -> Task<T, Error>? {
        synchronized {
            guard !finished else { return nil }
            return appendLocked(operation)
        }
    }

    /// A modifier transition without encoded key bytes is still a barrier.
    func sealInteractionAdmission() { synchronized { interactionTail = nil } }

    private func appendInteractionLocked(_ payload: InteractionTail.Payload) {
        let entry = InteractionTail(payload)
        interactionBatchCount += 1
        _ = appendLocked { [self] state in
            let payload = synchronized {
                if interactionTail === entry { interactionTail = nil }
                return entry.payload
            }
            defer { synchronized { interactionBatchCount -= 1 } }
            switch payload {
            case let .motion(request, completion):
                let response = try? await state.terminal?.pointer(request)
                if let bytes = response?.bytes, !bytes.isEmpty { writeHandler(bytes) }
                await completion(request, response)
                await notifyFrames()
            case let .hover(point, modifiers, _, generation, frame, completion):
                if let terminal = state.terminal {
                    let bytes = try? await terminal.input(.mouse(action: 2, button: 0,
                        modifiers: modifiers, point: point, pressed: false, generation: generation))
                    if let bytes, !bytes.isEmpty { writeHandler(bytes) }
                    var hit: VTLinkHit?
                    if let frame, let cell = frame.layout.cell(at: point) {
                        hit = try? await terminal.linkHit(at: .init(column: cell.column, row: cell.row), in: frame, geometry: true)
                    }
                    await completion(hit)
                } else { await completion(nil) }
            case let .wheel(request, cellWidth, cellHeight, localOnly, completion):
                // Each receipt was clamped before accumulation, exactly like
                // native scrollPointer. Replay bounded chunks; never collapse
                // opposing directions or interleave X/Y remote button reports.
                var remaining = request.delta
                while remaining != .zero, let terminal = state.terminal {
                    let delta = CGPoint(x: min(max(remaining.x, -64 * cellWidth), 64 * cellWidth),
                        y: min(max(remaining.y, -64 * cellHeight), 64 * cellHeight))
                    do {
                        if localOnly {
                            guard state.layoutGeneration == request.generation else { break }
                            let y = delta.y / cellHeight + state.momentumRemainder
                            let rows = Int(y)
                            state.momentumRemainder = y - CGFloat(rows)
                            if rows != 0 { try await terminal.scroll(rows: -rows) }
                        } else {
                            state.momentumRemainder = 0
                            let bytes = try await terminal.scrollPointer(.init(terminalID: request.terminalID,
                                generation: request.generation, point: request.point, delta: delta, modifiers: request.modifiers))
                            if !bytes.isEmpty { writeHandler(bytes) }
                        }
                    } catch { break }
                    remaining.x -= delta.x
                    remaining.y -= delta.y
                }
                await completion()
                await notifyFrames()
            }
        }
        interactionTail = entry
    }

    func enqueuePointerMotion(_ request: VTPointerRequest,
        completion: @escaping @Sendable @MainActor (VTPointerRequest, VTPointerResponse?) -> Void) {
        synchronized {
            guard !finished else { return }
            if let entry = interactionTail, case let .motion(old, _) = entry.payload,
               old.id == request.id, old.terminalID == request.terminalID,
               old.generation == request.generation, old.modifiers == request.modifiers {
                entry.payload = .motion(request, completion)
            } else { appendInteractionLocked(.motion(request, completion)) }
        }
    }

    func enqueueHover(at point: CGPoint, modifiers: VTModifiers, frame: VTFrameValue,
        detectLink: Bool, completion: @escaping @Sendable @MainActor (VTLinkHit?) -> Void) {
        synchronized {
            guard !finished else { return }
            let payload = InteractionTail.Payload.hover(point, modifiers, frame.terminalID,
                frame.layout.generation, detectLink ? frame : nil, completion)
            if let entry = interactionTail, case let .hover(_, oldMods, id, generation, _, _) = entry.payload,
               oldMods == modifiers, id == frame.terminalID, generation == frame.layout.generation {
                entry.payload = payload
            } else { appendInteractionLocked(payload) }
        }
    }

    func enqueueWheel(_ request: VTPointerScrollRequest, cellWidth: CGFloat, cellHeight: CGFloat, localOnly: Bool = false,
        completion: @escaping @Sendable @MainActor () -> Void) {
        guard request.delta.x.isFinite, request.delta.y.isFinite, cellWidth > 0, cellHeight > 0 else { return }
        let delta = CGPoint(x: min(max(request.delta.x, -64 * cellWidth), 64 * cellWidth),
            y: min(max(request.delta.y, -64 * cellHeight), 64 * cellHeight))
        guard delta != .zero else { return }
        synchronized {
            guard !finished else { return }
            if let entry = interactionTail, case let .wheel(old, width, height, oldLocalOnly, _) = entry.payload,
               oldLocalOnly == localOnly,
               old.terminalID == request.terminalID, old.generation == request.generation,
               old.modifiers == request.modifiers, old.point == request.point,
               width == cellWidth, height == cellHeight,
               ((delta.x == 0 && old.delta.x == 0 && delta.y.sign == old.delta.y.sign)
                || (delta.y == 0 && old.delta.y == 0 && delta.x.sign == old.delta.x.sign)) {
                let total = CGPoint(x: old.delta.x + delta.x, y: old.delta.y + delta.y)
                entry.payload = .wheel(.init(terminalID: old.terminalID, generation: old.generation,
                    point: old.point, delta: total, modifiers: old.modifiers), width, height, localOnly, completion)
            } else {
                appendInteractionLocked(.wheel(.init(terminalID: request.terminalID, generation: request.generation,
                    point: request.point, delta: delta, modifiers: request.modifiers), cellWidth, cellHeight, localOnly, completion))
            }
        }
    }

    // MARK: - Output

    /// Small synchronous feeds for previews/tests. Production must use deliver
    /// and await completion rather than introduce another unbounded byte queue.
    public func receive(_ data: Data) {
        _ = receiveIfSurfaceAttached(data)
    }

    @discardableResult
    public func receiveIfSurfaceAttached(
        _ data: Data,
        ifCurrent: @Sendable () -> Bool = { true }
    ) -> Bool {
        synchronized {
            guard !finished, metrics != nil, ifCurrent(),
                  data.count <= maxBufferedBytes - bufferedBytes else { return false }
            bufferedBytes += data.count
            _ = appendLocked { [self] state in
                defer { synchronized { bufferedBytes -= data.count } }
                guard let terminal = state.terminal else { return }
                await publish(try await terminal.ingest(data))
            }
            return true
        }
    }

    /// Validates at the actual engine handoff, not when a task was scheduled.
    /// One caller-owned segment stays in flight until the completion callback.
    /// Callers (TerminalOutputDeliveryQueue) must not start another delivery
    /// before completion: that one-in-flight contract is the output backpressure.
    public func deliver(
        _ data: Data,
        ifCurrent: @escaping @Sendable () -> Bool,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        let task = submit { [self] state -> Bool in
            if let hook = synchronized({ deliveryHook }) { await hook() }
            guard ifCurrent(), let terminal = state.terminal else { return false }
            await publish(try await terminal.ingest(data))
            return true
        }
        guard let task else { completion(false); return }
        Task { completion((try? await task.value) ?? false) }
    }

    /// Direct host control bytes still share ordering with native replies.
    public func sendInput(_ data: Data) {
        _ = submit { [writeHandler] _ in writeHandler(data) }
    }

    public func finish() {
        synchronized {
            guard !finished else { return }
            finished = true
            metrics = nil
            _ = appendLocked { [writeHandler] state in
                defer { state.terminal = nil }
                if let terminal = state.terminal {
                    let replies = try await terminal.retire()
                    if !replies.isEmpty { writeHandler(replies) }
                }
            }
        }
    }

    // MARK: - Layout and configuration

    public func updateViewport(_ metrics: VTTerminalSessionMetrics?) {
        guard let metrics else { return }
        synchronized {
            guard !finished, self.metrics != metrics,
                  let layout = try? VTLayout(
                    generation: layoutGeneration + 1,
                    width: metrics.width, height: metrics.height,
                    cellWidth: metrics.cellWidth, cellHeight: metrics.cellHeight,
                    scale: metrics.scale, padding: metrics.padding
                  ) else { return }
            // Admission records the generation synchronously so later layouts
            // stay ordered; a failed apply below forgets these metrics.
            self.metrics = metrics
            layoutGeneration = layout.generation
            _ = appendLocked { [self] state in
                let created: VTTerminal?
                do {
                    try synchronized({ layoutHook })?()
                    if let terminal = state.terminal {
                        let replies = try await terminal.resize(to: layout)
                        if !replies.isEmpty { writeHandler(replies) }
                        created = nil
                    } else {
                        created = try VTTerminal(layout: layout)
                        state.terminal = created
                    }
                } catch {
                    // Otherwise identical metrics are deduped forever while the
                    // content view rejects every snapshot against them. Only the
                    // newest admission may reset; a newer layout supersedes this.
                    synchronized {
                        if layoutGeneration == layout.generation { self.metrics = nil }
                    }
                    throw error
                }
                if let created {
                    await publish(try await created.configure(state.configuration))
                }
                state.layoutGeneration = layout.generation
                state.momentumRemainder = 0
                resizeHandler(InMemoryTerminalViewport(
                    columns: UInt16(clamping: layout.columns),
                    rows: UInt16(clamping: layout.rows),
                    widthPixels: UInt32((layout.viewportWidth * layout.scale).rounded()),
                    heightPixels: UInt32((layout.viewportHeight * layout.scale).rounded()),
                    cellWidthPixels: UInt32((layout.cellWidth * layout.scale).rounded()),
                    cellHeightPixels: UInt32((layout.cellHeight * layout.scale).rounded())
                ))
                await notifyFrames()
            }
        }
    }

    @discardableResult
    public func enqueueConfiguration(_ configuration: VTTerminalConfiguration) -> Task<Void, Error>? {
        submit { [self] state in
            state.configuration = configuration
            if let terminal = state.terminal {
                await publish(try await terminal.configure(configuration))
            }
        }
    }

    public func configure(_ configuration: VTTerminalConfiguration) async {
        _ = try? await enqueueConfiguration(configuration)?.value
    }

    // MARK: - Input, selection and owned render state

    @discardableResult
    public func enqueueInput(_ input: VTInput) -> Task<Data, Error>? {
        submit { [self] state -> Data in
            let replies: Data
            if let terminal = state.terminal {
                replies = try await terminal.input(input)
            } else if case .text(let text) = input {
                // Literal committed text needs no terminal modes. Preserve the
                // pre-surface direct input contract without dropping accepted
                // bytes while viewport creation is still pending. There is no
                // viewport or selection to update until an engine exists.
                replies = Data(text.utf8)
            } else {
                throw VTError.retired
            }
            if !replies.isEmpty { writeHandler(replies) }
            await notifyFrames()
            return replies
        }
    }

    @discardableResult
    public func perform(_ input: VTInput) async -> Data {
        (try? await enqueueInput(input)?.value) ?? Data()
    }

    /// Admission is synchronous: accepted work remains in FIFO order even if
    /// its returned task is canceled or finish() is called before completion.
    /// nil means retirement has closed admission; native errors remain on Task.
    @discardableResult
    public func enqueueSelect(_ kind: VTSelectionKind, at position: VTCellPosition,
                              generation: UInt64) -> Task<Void, Error>? {
        submit { [self] state in
            guard let terminal = state.terminal else { throw VTError.retired }
            try await terminal.select(kind, at: position, generation: generation)
            await notifyFrames()
        }
    }

    /// Host replacement and cleanup share the same FIFO as selection input.
    /// A retiring host cannot clear a newer host's retained-session selection.
    func claimSelectionHost(_ host: UUID) {
        _ = submit { [self] state in
            guard state.selectionHost != host else { return }
            // Clear the previous owner's selection before the new host can
            // enqueue input, even when the previous host has not detached yet.
            if state.selectionHost != nil, let terminal = state.terminal {
                _ = try await terminal.clearSelection()
                await notifyFrames()
            }
            state.selectionHost = host
        }
    }

    @discardableResult
    public func enqueueClearSelection(host: UUID? = nil) -> Task<VTSelectionClearBoundary?, Error>? {
        submit { [self] state in
            guard host == nil || state.selectionHost == host else { return nil }
            guard let terminal = state.terminal else { throw VTError.retired }
            let boundary = try await terminal.clearSelection()
            await notifyFrames()
            return boundary
        }
    }

    @discardableResult
    public func enqueueSelectAll() -> Task<Void, Error>? {
        submit { [self] state in
            guard let terminal = state.terminal else { throw VTError.retired }
            try await terminal.selectAll()
            await notifyFrames()
        }
    }

    @discardableResult
    public func enqueueMoveSelection(start: Bool, to position: VTCellPosition,
                                     generation: UInt64) -> Task<Void, Error>? {
        submit { [self] state in
            guard let terminal = state.terminal else { throw VTError.retired }
            try await terminal.moveSelection(start: start, to: position, generation: generation)
            await notifyFrames()
        }
    }

    @discardableResult
    public func enqueueDragSelection(_ request: VTSelectionDragRequest) -> Task<Void, Error>? {
        submit { [self] state in
            guard let terminal = state.terminal else { throw VTError.retired }
            try await terminal.dragSelection(request)
            await notifyFrames()
        }
    }

    @discardableResult
    public func enqueueAdjustSelection(start: Bool, forward: Bool, terminalID: UUID,
                                       generation: UInt64) -> Task<Bool, Error>? {
        submit { [self] state in
            guard let terminal = state.terminal else { throw VTError.retired }
            let changed = try await terminal.adjustSelection(start: start, forward: forward,
                terminalID: terminalID, generation: generation)
            if changed { await notifyFrames() }
            return changed
        }
    }

    @discardableResult
    public func enqueuePointer(_ request: VTPointerRequest) -> Task<VTPointerResponse, Error>? {
        synchronized {
            guard !finished else { return nil }
            pointerID = max(pointerID, request.id)
            return appendLocked { [self] state in
            guard let terminal = state.terminal else { throw VTError.retired }
            let response = try await terminal.pointer(request)
            if !response.bytes.isEmpty { writeHandler(response.bytes) }
            await notifyFrames()
            return response
            }
        }
    }

    @discardableResult
    public func enqueueScrollPointer(_ request: VTPointerScrollRequest) -> Task<Data, Error>? {
        submit { [self] state in
            guard let terminal = state.terminal else { throw VTError.retired }
            let replies = try await terminal.scrollPointer(request)
            if !replies.isEmpty { writeHandler(replies) }
            await notifyFrames()
            return replies
        }
    }

    @discardableResult
    public func enqueueLinkHit(at position: VTCellPosition, in frame: VTFrameValue,
                               geometry: Bool = true) -> Task<VTLinkHit?, Error>? {
        submit { state in
            guard let terminal = state.terminal else { throw VTError.retired }
            return try await terminal.linkHit(at: position, in: frame, geometry: geometry)
        }
    }

    @discardableResult
    public func enqueueSelectedText() -> Task<String, Error>? {
        submit { state in
            guard let terminal = state.terminal else { throw VTError.retired }
            return try await terminal.selectedText()
        }
    }

    @discardableResult
    public func enqueueTakeSelectedText() -> Task<String, Error>? {
        submit { [self] state in
            guard let terminal = state.terminal else { throw VTError.retired }
            let text = try await terminal.takeSelectedText()
            await notifyFrames()
            return text
        }
    }

    public func select(_ kind: VTSelectionKind, at position: VTCellPosition, generation: UInt64) async {
        _ = try? await enqueueSelect(kind, at: position, generation: generation)?.value
    }

    public func moveSelection(start: Bool, to position: VTCellPosition, generation: UInt64) async {
        _ = try? await enqueueMoveSelection(start: start, to: position, generation: generation)?.value
    }

    public func selectedText() async -> String {
        (try? await enqueueSelectedText()?.value) ?? ""
    }

    @discardableResult
    public func takeSelectedText() async -> String {
        (try? await enqueueTakeSelectedText()?.value) ?? ""
    }

    @discardableResult
    public func scrollPointer(_ request: VTPointerScrollRequest) async -> Data {
        (try? await enqueueScrollPointer(request)?.value) ?? Data()
    }

    /// Admit extraction synchronously so a later host teardown can release its
    /// reusable copies after every already-requested frame, even if canceled.
    func enqueueSnapshot() -> Task<VTFrameValue, Error>? {
        submit { state in
            guard let terminal = state.terminal else { throw VTError.retired }
            return try await terminal.snapshot()
        }
    }

    public func snapshot() async throws -> VTFrameValue {
        guard let task = enqueueSnapshot() else { throw VTError.retired }
        return try await task.value
    }

    /// Release only reusable adapter copies, without creating an engine or
    /// requesting a frame that would immediately repopulate the cache.
    @discardableResult
    func enqueueReleaseSnapshotCache() -> Task<Void, Error>? {
        submit { state in
            await state.terminal?.releaseSnapshotCache()
        }
    }

    /// Ordered, non-extracting engine queries must not repopulate render caches
    /// or emit frame notifications.
    func enqueueInputQuery<T: Sendable>(
        _ query: @escaping @Sendable (VTTerminal) async throws -> T
    ) -> Task<T, Error>? {
        submit { state in
            guard let terminal = state.terminal else { throw VTError.retired }
            return try await query(terminal)
        }
    }

    #if DEBUG
    /// Synchronous FIFO admission after production cache release; no notification.
    public func enqueueLifecycleAcceptanceQuery() -> Task<VTLifecycleEngineScalars, Error>? {
        enqueueInputQuery { await $0.lifecycleAcceptanceScalars() }
    }
    #endif

    private func publish(_ output: VTOutput) async {
        if !output.replies.isEmpty { writeHandler(output.replies) }
        await dispatch(output.events)
        await notifyFrames()
    }

    private func notifyFrames() async {
        let callbacks = synchronized { Array(frameObservers.values) + (framesHook.map { [$0] } ?? []) }
        for callback in callbacks { await callback() }
    }

    private func dispatch(_ events: [VTEvent]) async {
        guard !events.isEmpty else { return }
        await MainActor.run {
            for event in events {
                if let key = event.metadataKey {
                    metadata.removeAll { $0.metadataKey == key }
                    metadata.append(event)
                }
                // Resolve only after the actor hop, and again after every
                // callout. Live events remain ordered and are never coalesced.
                if let delegate = storedEventDelegate { dispatch(event, to: delegate) }
            }
        }
    }

    @MainActor
    private func dispatch(_ event: VTEvent, to delegate: any TerminalSurfaceViewDelegate) {
        switch event {
        case .title(let title):
            (delegate as? any TerminalSurfaceTitleDelegate)?.terminalDidChangeTitle(title)
        case .bell:
            (delegate as? any TerminalSurfaceBellDelegate)?.terminalDidRingBell()
        case .progress(let state, let percent):
            (delegate as? any TerminalSurfaceProgressReportDelegate)?
                .terminalDidReportProgress(state: state.mapped, percent: percent)
        case .notification(let title, let body):
            (delegate as? any TerminalSurfaceDesktopNotificationDelegate)?
                .terminalDidRequestDesktopNotification(title: title, body: body)
        case .workingDirectory(let path):
            (delegate as? any TerminalSurfacePwdDelegate)?.terminalDidChangeWorkingDirectory(path)
        }
    }
}

private extension VTEvent {
    enum MetadataKey { case title, workingDirectory, progress }

    var metadataKey: MetadataKey? {
        switch self {
        case .title: .title
        case .workingDirectory: .workingDirectory
        case .progress: .progress
        case .bell, .notification: nil
        }
    }
}

private extension VTProgressState {
    var mapped: TerminalProgressState {
        switch self {
        case .remove: .remove
        case .set: .set
        case .error: .error
        case .indeterminate: .indeterminate
        case .pause: .pause
        }
    }
}
