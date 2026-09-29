import Foundation
import GhosttyTerminal
import os

private let terminalOutputDeliveryLogger = Logger(
    subsystem: "dev.sshapp.sshapp",
    category: "TerminalOutputDelivery"
)

protocol TerminalOutputReceiver: AnyObject, Sendable {
    /// True when the receiver keeps the same engine while readiness pauses
    /// for focus, geometry or application activity (a VT session does).
    var preservesStateAcrossReadinessChanges: Bool { get }

    @discardableResult
    func receiveIfCurrent(
        _ data: Data,
        ifCurrent: @Sendable () -> Bool
    ) -> Bool

    /// Completion is the commit boundary, not merely acceptance into a queue.
    func deliver(
        _ data: Data,
        ifCurrent: @escaping @Sendable () -> Bool,
        completion: @escaping @Sendable (Bool) -> Void
    )
}

extension TerminalOutputReceiver {
    var preservesStateAcrossReadinessChanges: Bool { false }

    func deliver(
        _ data: Data,
        ifCurrent: @escaping @Sendable () -> Bool,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        completion(receiveIfCurrent(data, ifCurrent: ifCurrent))
    }
}

extension VTTerminalSession: TerminalOutputReceiver {
    var preservesStateAcrossReadinessChanges: Bool { true }

    func receiveIfCurrent(_ data: Data, ifCurrent: @Sendable () -> Bool) -> Bool {
        receiveIfSurfaceAttached(data, ifCurrent: ifCurrent)
    }
    // VTTerminalSession.deliver is the completion-bearing protocol witness.
}

/// Ordered, bounded live-output delivery without synchronous terminal work on
/// a SwiftUI or main-actor update path. A private serial queue drains after the
/// viewport readiness gate opens, retaining one in-flight delivery until native
/// ingestion and reply/event fan-out commit. Generation changes cancel work
/// that has not entered the receiver; accepted bytes are never replayed into
/// the same retained VT engine.
///
/// Bounding policy (exactly one applies at a time):
/// - Not ready: bounded output is trimmed to `maxPendingBytes` at a line
///   boundary. Nothing has been fed to a live parser yet for these bytes, so a
///   bounded pre-viewport buffer is preferable to stalling the remote.
/// - Ready with an output-gap handler (tmux panes): overflow closes the queue
///   and requests an authoritative snapshot; a trimmed tail is never ingested.
/// - Ready with a flow-control handler (plain SSH channels): live output is
///   never trimmed. Crossing the pause threshold asks the producer to stop
///   reading; draining below the resume threshold resumes it. The producer
///   must honour a pause within a bounded overshoot (see `SSH2Transport`).
/// - Ready with neither (pre-channel auth output): trimmed as when not ready.
final class TerminalOutputDeliveryQueue: @unchecked Sendable {
    private enum PendingRetention {
        case bounded
        case preserved
    }

    private struct PendingSegment {
        let retention: PendingRetention
        var data: Data
        var sequence: UInt64
    }

    private struct DrainBarrier {
        let generation: Int
        let sequence: UInt64
        let completion: @Sendable () -> Void
    }

    private let queue: DispatchQueue
    private let maxPendingBytes: Int
    private let trimNewlineScanWindow: Int
    private let lock = NSLock()
    private weak var receiver: (any TerminalOutputReceiver)?
    private var isReady = false
    private var pendingSegments: [PendingSegment] = []
    private var pendingBoundedByteCount = 0
    private var scheduledGeneration: Int?
    private var deliveryInFlight = false
    private var firstDrainCompletion: (@Sendable () -> Void)?
    private var drainBarriers: [DrainBarrier] = []
    private var enqueuedSequence: UInt64 = 0
    private var committedSequence: UInt64 = 0
    private var lastBarrierSequence: UInt64 = 0
    private var generation = 0
    private var contentGeneration = 0
    // A repeated ready notification is still a new readiness signal. It must
    // survive a concurrent failed handoff without invalidating accepted bytes.
    private var readinessRevision = 0
    private var outputGapHandler: (@Sendable () -> Void)?
    private var hasOutputGap = false
    private let flowPauseThreshold: Int
    private let flowResumeThreshold: Int
    private var inFlightBoundedByteCount = 0
    private var flowControlHandler: (@MainActor @Sendable (Bool) -> Void)?
    private var isFlowPaused = false
    private var consecutiveDeliveryFailures = 0

    var requiresSnapshotRecovery: Bool { lock.withLock { hasOutputGap } }

    /// Snapshot-capable transports must recover after truncation instead of
    /// feeding a byte tail whose parser/mode prefix has been lost.
    func setOutputGapHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { outputGapHandler = handler }
    }

    /// Installs live-output backpressure. While the queue is ready, `handler`
    /// receives `true` when pending plus in-flight bounded bytes exceed half of
    /// `maxPendingBytes`, and `false` once they drain to an eighth of it (or the
    /// queue stops being ready). Calls arrive on the main queue in transition
    /// order; the producer must stop reading while paused instead of relying
    /// on this queue to trim live output.
    func setFlowControlHandler(_ handler: (@MainActor @Sendable (Bool) -> Void)?) {
        lock.lock()
        flowControlHandler = handler
        isFlowPaused = false
        updateFlowControlLocked()
        lock.unlock()
    }

    init(
        label: String = "dev.sshapp.sshapp.terminal-output",
        maxPendingBytes: Int = 512 * 1024,
        trimNewlineScanWindow: Int = 8 * 1024
    ) {
        queue = DispatchQueue(label: label)
        self.maxPendingBytes = max(1, maxPendingBytes)
        self.trimNewlineScanWindow = max(0, trimNewlineScanWindow)
        flowPauseThreshold = max(1, self.maxPendingBytes / 2)
        flowResumeThreshold = self.maxPendingBytes / 8
    }

    func setReceiver(_ receiver: (any TerminalOutputReceiver)?) {
        setReceiver(receiver, preservingPendingOutput: false)
    }

    func setReceiverPreservingPendingOutput(
        _ receiver: (any TerminalOutputReceiver)?
    ) {
        setReceiver(receiver, preservingPendingOutput: true)
    }

    private func setReceiver(
        _ receiver: (any TerminalOutputReceiver)?,
        preservingPendingOutput: Bool
    ) {
        lock.lock()
        let receiverChanged: Bool
        switch (self.receiver, receiver) {
        case (nil, nil):
            receiverChanged = false
        case let (current?, replacement?):
            receiverChanged = current !== replacement
        default:
            receiverChanged = true
        }

        guard receiverChanged else {
            scheduleDrainIfReadyLocked()
            lock.unlock()
            return
        }

        self.receiver = receiver
        generation += 1
        if !preservingPendingOutput {
            contentGeneration += 1
            pendingSegments.removeAll(keepingCapacity: true)
            pendingBoundedByteCount = 0
            committedSequence = enqueuedSequence
        }
        scheduledGeneration = nil
        firstDrainCompletion = nil
        scheduleDrainIfReadyLocked()
        lock.unlock()
    }

    func setReady(
        _ ready: Bool,
        onFirstDrain completion: (@Sendable () -> Void)? = nil
    ) {
        lock.lock()
        readinessRevision &+= 1
        guard !ready || !hasOutputGap else { lock.unlock(); return }
        guard isReady != ready else {
            if ready, firstDrainCompletion == nil, let completion {
                firstDrainCompletion = completion
            }
            scheduleDrainIfReadyLocked()
            lock.unlock()
            return
        }

        isReady = ready
        generation += 1
        scheduledGeneration = nil
        firstDrainCompletion = ready ? completion : nil
        scheduleDrainIfReadyLocked()
        lock.unlock()
    }

    /// Completes after all output currently queued or in flight has committed.
    /// Unlike onFirstDrain, an already empty queue satisfies this barrier too.
    /// Later output does not extend the barrier; readiness/content/receiver
    /// invalidation cancels it without revoking bytes already accepted by VT.
    func notifyWhenDrained(_ completion: @escaping @Sendable () -> Void) {
        lock.lock()
        lastBarrierSequence = enqueuedSequence
        drainBarriers.append(DrainBarrier(
            generation: generation, sequence: enqueuedSequence, completion: completion
        ))
        scheduleDrainIfReadyLocked()
        lock.unlock()
    }

    func resetPendingOutput() {
        lock.lock()
        hasOutputGap = false
        generation += 1
        contentGeneration += 1
        pendingSegments.removeAll(keepingCapacity: true)
        pendingBoundedByteCount = 0
        committedSequence = enqueuedSequence
        scheduledGeneration = nil
        firstDrainCompletion = nil
        drainBarriers.removeAll()
        consecutiveDeliveryFailures = 0
        updateFlowControlLocked()
        lock.unlock()
    }

    func enqueue(_ data: Data) {
        enqueue(data, retention: .bounded)
    }

    /// Enqueues pane-owned replay without applying this queue's live-output cap.
    /// Tmux already keeps snapshots uncapped and bounds live bytes before a sink
    /// is installed, so preserving the complete synchronous replay prevents
    /// truncating a recreated surface's authoritative reset/render sequence.
    func enqueuePreservingPaneReplay(_ data: Data) {
        enqueue(data, retention: .preserved)
    }

    private func enqueue(_ data: Data, retention: PendingRetention) {
        guard !data.isEmpty else { return }

        lock.lock()
        enqueuedSequence &+= 1
        if let last = pendingSegments.last,
           last.retention == retention, last.sequence > lastBarrierSequence {
            pendingSegments[pendingSegments.count - 1].data.append(data)
            pendingSegments[pendingSegments.count - 1].sequence = enqueuedSequence
        } else {
            pendingSegments.append(PendingSegment(retention: retention, data: data, sequence: enqueuedSequence))
        }
        if retention == .bounded {
            pendingBoundedByteCount += data.count
            trimPendingOutputIfNeededLocked()
        }
        scheduleDrainIfReadyLocked()
        lock.unlock()
    }

    /// Live output under flow control is already feeding a VT parser; cutting
    /// bytes out of its middle can split OSC/DCS/APC or mode sequences.
    private var isFlowControlledLocked: Bool {
        flowControlHandler != nil && isReady && !hasOutputGap
    }

    private func updateFlowControlLocked() {
        guard let flowControlHandler else { return }
        let bufferedBytes = pendingBoundedByteCount + inFlightBoundedByteCount
        let shouldPause: Bool
        if !isFlowControlledLocked {
            shouldPause = false
        } else if isFlowPaused {
            shouldPause = bufferedBytes > flowResumeThreshold
        } else {
            shouldPause = bufferedBytes > flowPauseThreshold
        }
        guard shouldPause != isFlowPaused else { return }
        isFlowPaused = shouldPause
        // Enqueued under the lock so the main queue observes transitions in
        // the order they were decided; client code itself runs unlocked.
        DispatchQueue.main.async {
            MainActor.assumeIsolated { flowControlHandler(shouldPause) }
        }
    }

    private func trimPendingOutputIfNeededLocked() {
        guard pendingBoundedByteCount > maxPendingBytes else { return }
        // Backpressure bounds live output instead; the overshoot is limited
        // by the producer's pause latency, not by dropping parser input.
        guard !isFlowControlledLocked else { return }
        let wasReady = isReady

        if let outputGapHandler, !hasOutputGap {
            hasOutputGap = true
            isReady = false
            generation += 1
            scheduledGeneration = nil
            firstDrainCompletion = nil
            // Never call client code under the queue lock.
            DispatchQueue.main.async(execute: outputGapHandler)
        }
        let originalBoundedByteCount = pendingBoundedByteCount
        while pendingBoundedByteCount > maxPendingBytes,
              let segmentIndex = pendingSegments.firstIndex(where: { $0.retention == .bounded }) {
            let overflow = pendingBoundedByteCount - maxPendingBytes
            let segment = pendingSegments[segmentIndex].data
            if segment.count <= overflow {
                pendingBoundedByteCount -= segment.count
                pendingSegments.remove(at: segmentIndex)
                continue
            }

            var cutIndex = segment.startIndex + overflow
            let scanLimit = min(cutIndex + trimNewlineScanWindow, segment.endIndex)
            if cutIndex < scanLimit,
               let newline = segment[cutIndex..<scanLimit].firstIndex(of: 0x0A) {
                cutIndex = newline + 1
            }
            pendingBoundedByteCount -= cutIndex - segment.startIndex
            pendingSegments[segmentIndex].data = Data(segment[cutIndex...])
        }

        let reason = hasOutputGap
            ? "pending snapshot recovery"
            : wasReady ? "from live output without flow control" : "before viewport readiness"
        terminalOutputDeliveryLogger.warning(
            "Trimmed \(originalBoundedByteCount - self.pendingBoundedByteCount, privacy: .public) buffered terminal bytes \(reason, privacy: .public)"
        )
    }

    private func scheduleDrainIfReadyLocked() {
        updateFlowControlLocked()
        drainBarriers.removeAll { $0.generation != generation }
        if isReady, receiver != nil, !hasOutputGap, !deliveryInFlight {
            let satisfied = drainBarriers.filter { $0.sequence <= committedSequence }
            drainBarriers.removeAll { $0.sequence <= committedSequence }
            for barrier in satisfied {
                queue.async { [weak self] in
                    guard let self else { return }
                    let current = self.lock.withLock {
                        self.generation == barrier.generation && self.isReady
                            && self.receiver != nil && !self.hasOutputGap
                    }
                    if current { barrier.completion() }
                }
            }
        }
        guard !deliveryInFlight, scheduledGeneration == nil,
              isReady,
              receiver != nil,
              !pendingSegments.isEmpty else {
            return
        }

        let scheduledGeneration = generation
        self.scheduledGeneration = scheduledGeneration
        queue.async { [weak self] in
            self?.drain(generation: scheduledGeneration)
        }
    }

    private func drain(generation scheduledGeneration: Int) {
        do {
            let receiver: any TerminalOutputReceiver
            let segment: PendingSegment
            let scheduledContentGeneration: Int
            let scheduledReadinessRevision: Int

            lock.lock()
            guard self.scheduledGeneration == scheduledGeneration else {
                lock.unlock()
                return
            }
            guard scheduledGeneration == generation,
                  isReady,
                  let currentReceiver = self.receiver,
                  !pendingSegments.isEmpty else {
                self.scheduledGeneration = nil
                scheduleDrainIfReadyLocked()
                lock.unlock()
                return
            }
            deliveryInFlight = true
            receiver = currentReceiver
            scheduledContentGeneration = contentGeneration
            scheduledReadinessRevision = readinessRevision
            segment = pendingSegments.removeFirst()
            if segment.retention == .bounded {
                pendingBoundedByteCount -= segment.data.count
                // Still counts toward flow control until it commits.
                inFlightBoundedByteCount = segment.data.count
            }
            lock.unlock()

            receiver.deliver(
                segment.data,
                ifCurrent: { [weak self] in
                    guard let self else { return false }
                    self.lock.lock()
                    defer { self.lock.unlock() }
                    return scheduledGeneration == self.generation
                        && self.scheduledGeneration == scheduledGeneration
                        && scheduledContentGeneration == self.contentGeneration
                        && self.isReady
                        && self.receiver === receiver
                },
                completion: { [self] delivered in
                    // Re-enter the same serial queue; synchronous and async
                    // receivers share identical commit and generation
                    // semantics without blocking an executor.
                    queue.async { [self] in
                        completeDelivery(
                            delivered, receiver: receiver, segment: segment,
                            scheduledGeneration: scheduledGeneration,
                            scheduledContentGeneration: scheduledContentGeneration,
                            scheduledReadinessRevision: scheduledReadinessRevision
                        )
                    }
                }
            )
        }
    }

    private func completeDelivery(
        _ delivered: Bool,
        receiver: any TerminalOutputReceiver,
        segment: PendingSegment,
        scheduledGeneration: Int,
        scheduledContentGeneration: Int,
        scheduledReadinessRevision: Int
    ) {
        guard delivered else {
            lock.lock()
            deliveryInFlight = false
            inFlightBoundedByteCount = 0
            var retry: (generation: Int, delay: TimeInterval)?
            if scheduledContentGeneration == contentGeneration {
                prependSegmentLocked(segment)
                if scheduledGeneration == generation,
                   scheduledReadinessRevision == readinessRevision {
                    if receiver.preservesStateAcrossReadinessChanges,
                       self.receiver === receiver, isReady {
                        // A retained engine that rejects a current handoff has
                        // not committed the segment. Host readiness is not the
                        // cause and no new readiness signal will arrive (the
                        // channel treats a persistent engine as always ready),
                        // so closing readiness here would stall the tab and,
                        // through flow control, the remote. Retry with backoff.
                        let delay = min(0.016 * pow(2, Double(consecutiveDeliveryFailures)), 1)
                        if consecutiveDeliveryFailures == 0 {
                            terminalOutputDeliveryLogger.warning(
                                "Terminal engine rejected \(segment.data.count, privacy: .public) output bytes; retrying"
                            )
                        }
                        consecutiveDeliveryFailures = min(consecutiveDeliveryFailures + 1, 16)
                        retry = (generation, delay)
                    } else {
                        // A per-surface receiver is unavailable: keep the bytes
                        // for the next readiness signal.
                        isReady = false
                        generation += 1
                        firstDrainCompletion = nil
                    }
                }
            }
            if self.scheduledGeneration == scheduledGeneration {
                self.scheduledGeneration = nil
            }
            if let retry, self.scheduledGeneration == nil {
                // Owns the drain slot; any generation change clears it and the
                // delayed drain then exits without delivering.
                self.scheduledGeneration = retry.generation
                queue.asyncAfter(deadline: .now() + retry.delay) { [weak self] in
                    self?.drain(generation: retry.generation)
                }
            }
            scheduleDrainIfReadyLocked()
            lock.unlock()
            return
        }

        let completion: (@Sendable () -> Void)?
        lock.lock()
        deliveryInFlight = false
        inFlightBoundedByteCount = 0
        consecutiveDeliveryFailures = 0
        if scheduledGeneration == generation,
           self.scheduledGeneration == scheduledGeneration,
           isReady,
           self.receiver === receiver {
            // The segment was committed while its scheduled generation was
            // still current: normal delivery.
            committedSequence = max(committedSequence, segment.sequence)
            completion = firstDrainCompletion
            firstDrainCompletion = nil
        } else {
            // The delivery generation changed while the receiver was
            // executing (e.g. a preserving lifecycle handoff). Output the
            // retiring surface accepted must still reach the replacement
            // surface — replay it for the new generation — unless the
            // logical content was explicitly reset.
            let samePersistentEngine = self.receiver === receiver
                && receiver.preservesStateAcrossReadinessChanges
                && scheduledContentGeneration == contentGeneration
            if samePersistentEngine {
                // The bytes already changed this engine. A readiness pause is
                // not a reset: replay would duplicate text, replies and bells.
                committedSequence = max(committedSequence, segment.sequence)
                completion = isReady ? firstDrainCompletion : nil
                if isReady { firstDrainCompletion = nil }
            } else {
                completion = nil
                if scheduledContentGeneration == contentGeneration {
                    prependSegmentLocked(segment)
                }
            }
            if self.scheduledGeneration == scheduledGeneration {
                self.scheduledGeneration = nil
            }
            scheduleDrainIfReadyLocked()
        }
        scheduleDrainIfReadyLocked()
        lock.unlock()
        completion?()
        drain(generation: scheduledGeneration)
    }

    /// Reinserts a claimed segment at the head of the pending queue, restoring
    /// bounded byte accounting so both false-delivery and stale-success paths
    /// apply the same trim policy.
    private func prependSegmentLocked(_ segment: PendingSegment) {
        pendingSegments.insert(segment, at: 0)
        if segment.retention == .bounded {
            pendingBoundedByteCount += segment.data.count
            trimPendingOutputIfNeededLocked()
        }
    }
}
