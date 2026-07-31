import Foundation
import GhosttyTerminal
import os

private let terminalOutputDeliveryLogger = Logger(
    subsystem: "dev.sshapp.sshapp",
    category: "TerminalOutputDelivery"
)

protocol TerminalOutputReceiver: AnyObject, Sendable {
    @discardableResult
    func receiveIfCurrent(
        _ data: Data,
        ifCurrent: @Sendable () -> Bool
    ) -> Bool
}

extension InMemoryTerminalSession: TerminalOutputReceiver {
    func receiveIfCurrent(
        _ data: Data,
        ifCurrent: @Sendable () -> Bool
    ) -> Bool {
        receiveIfSurfaceAttached(data, ifCurrent: ifCurrent)
    }
}

/// Ordered, bounded live-output delivery into Ghostty that never calls
/// `receive(_:)` from a
/// SwiftUI or main-actor update path.
///
/// `ghostty_surface_write_buffer` can block on an internal futex during scene
/// transitions. Callers only enqueue; a private serial queue drains after the
/// viewport readiness gate opens. Generation changes cancel work that has not
/// already entered the receiver.
final class TerminalOutputDeliveryQueue: @unchecked Sendable {
    private enum PendingRetention {
        case bounded
        case preserved
    }

    private struct PendingSegment {
        let retention: PendingRetention
        var data: Data
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
    private var firstDrainCompletion: (@Sendable () -> Void)?
    private var generation = 0
    private var contentGeneration = 0

    init(
        label: String = "dev.sshapp.sshapp.terminal-output",
        maxPendingBytes: Int = 512 * 1024,
        trimNewlineScanWindow: Int = 8 * 1024
    ) {
        queue = DispatchQueue(label: label)
        self.maxPendingBytes = max(1, maxPendingBytes)
        self.trimNewlineScanWindow = max(0, trimNewlineScanWindow)
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

    func resetPendingOutput() {
        lock.lock()
        generation += 1
        contentGeneration += 1
        pendingSegments.removeAll(keepingCapacity: true)
        pendingBoundedByteCount = 0
        scheduledGeneration = nil
        firstDrainCompletion = nil
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
        if pendingSegments.last?.retention == retention {
            pendingSegments[pendingSegments.count - 1].data.append(data)
        } else {
            pendingSegments.append(PendingSegment(retention: retention, data: data))
        }
        if retention == .bounded {
            pendingBoundedByteCount += data.count
            trimPendingOutputIfNeededLocked()
        }
        scheduleDrainIfReadyLocked()
        lock.unlock()
    }

    private func trimPendingOutputIfNeededLocked() {
        guard pendingBoundedByteCount > maxPendingBytes else { return }

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

        terminalOutputDeliveryLogger.warning(
            "Trimmed \(originalBoundedByteCount - self.pendingBoundedByteCount, privacy: .public) buffered terminal bytes before viewport readiness"
        )
    }

    private func scheduleDrainIfReadyLocked() {
        guard scheduledGeneration == nil,
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
        while true {
            let receiver: any TerminalOutputReceiver
            let segment: PendingSegment
            let scheduledContentGeneration: Int

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
            receiver = currentReceiver
            scheduledContentGeneration = contentGeneration
            segment = pendingSegments.removeFirst()
            if segment.retention == .bounded {
                pendingBoundedByteCount -= segment.data.count
            }
            lock.unlock()

            let delivered = receiver.receiveIfCurrent(
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
                }
            )

            guard delivered else {
                lock.lock()
                if scheduledContentGeneration == contentGeneration {
                    pendingSegments.insert(segment, at: 0)
                    if segment.retention == .bounded {
                        pendingBoundedByteCount += segment.data.count
                        trimPendingOutputIfNeededLocked()
                    }
                    if scheduledGeneration == generation {
                        isReady = false
                        generation += 1
                        firstDrainCompletion = nil
                    }
                }
                if self.scheduledGeneration == scheduledGeneration {
                    self.scheduledGeneration = nil
                }
                scheduleDrainIfReadyLocked()
                lock.unlock()
                return
            }

            let completion: (@Sendable () -> Void)?
            lock.lock()
            if scheduledGeneration == generation,
               self.scheduledGeneration == scheduledGeneration {
                completion = firstDrainCompletion
                firstDrainCompletion = nil
            } else {
                completion = nil
            }
            lock.unlock()
            completion?()
        }
    }
}
