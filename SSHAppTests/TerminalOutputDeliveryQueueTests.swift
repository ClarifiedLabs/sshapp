import XCTest
@testable import SSHApp

final class TerminalOutputDeliveryQueueTests: XCTestCase {
    private final class RecordingReceiver: TerminalOutputReceiver, @unchecked Sendable {
        private let lock = NSLock()
        private let receiveSemaphore = DispatchSemaphore(value: 0)
        private let releaseSemaphore = DispatchSemaphore(value: 0)
        private var remainingBlockedReceives: Int
        private var receivedValues: [Data] = []
        private var receivedOnMainThreadValues: [Bool] = []

        init(blockedReceives: Int = 0) {
            remainingBlockedReceives = blockedReceives
        }

        var received: [Data] {
            lock.withLock { receivedValues }
        }

        var receivedOnMainThread: [Bool] {
            lock.withLock { receivedOnMainThreadValues }
        }

        func receiveIfCurrent(
            _ data: Data,
            ifCurrent: @Sendable () -> Bool
        ) -> Bool {
            guard ifCurrent() else { return false }
            let shouldBlock = lock.withLock { () -> Bool in
                receivedValues.append(data)
                receivedOnMainThreadValues.append(Thread.isMainThread)
                guard remainingBlockedReceives > 0 else { return false }
                remainingBlockedReceives -= 1
                return true
            }

            receiveSemaphore.signal()

            if shouldBlock {
                releaseSemaphore.wait()
            }
            return true
        }

        func waitForReceive(timeout: TimeInterval = 1.0) -> DispatchTimeoutResult {
            receiveSemaphore.wait(timeout: .now() + timeout)
        }

        func releaseBlockedReceive() {
            releaseSemaphore.signal()
        }
    }

    private final class HandoffBlockingReceiver: TerminalOutputReceiver, @unchecked Sendable {
        private let attemptSemaphore = DispatchSemaphore(value: 0)
        private let releaseSemaphore = DispatchSemaphore(value: 0)
        private let rejectionSemaphore = DispatchSemaphore(value: 0)
        private let receiveSemaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var blocksNextAttempt = true
        private var receivedValues: [Data] = []

        var received: [Data] {
            lock.withLock { receivedValues }
        }

        func receiveIfCurrent(
            _ data: Data,
            ifCurrent: @Sendable () -> Bool
        ) -> Bool {
            let shouldBlock = lock.withLock { () -> Bool in
                guard blocksNextAttempt else { return false }
                blocksNextAttempt = false
                return true
            }
            if shouldBlock {
                attemptSemaphore.signal()
                releaseSemaphore.wait()
            }
            guard ifCurrent() else {
                rejectionSemaphore.signal()
                return false
            }
            lock.withLock {
                receivedValues.append(data)
            }
            receiveSemaphore.signal()
            return true
        }

        func waitForAttempt() -> DispatchTimeoutResult {
            attemptSemaphore.wait(timeout: .now() + 2)
        }

        func releaseHandoff() {
            releaseSemaphore.signal()
        }

        func waitForRejection() -> DispatchTimeoutResult {
            rejectionSemaphore.wait(timeout: .now() + 2)
        }

        func waitForReceive() -> DispatchTimeoutResult {
            receiveSemaphore.wait(timeout: .now() + 2)
        }
    }

    private final class InitiallyUnavailableReceiver: TerminalOutputReceiver, @unchecked Sendable {
        private let attemptSemaphore = DispatchSemaphore(value: 0)
        private let receiveSemaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var available = false
        private var receivedValues: [Data] = []

        var received: [Data] {
            lock.withLock { receivedValues }
        }

        func receiveIfCurrent(
            _ data: Data,
            ifCurrent: @Sendable () -> Bool
        ) -> Bool {
            guard ifCurrent() else { return false }
            let shouldReceive = lock.withLock { available }
            guard shouldReceive else {
                attemptSemaphore.signal()
                return false
            }
            lock.withLock {
                receivedValues.append(data)
            }
            receiveSemaphore.signal()
            return true
        }

        func waitForUnavailableAttempt() -> DispatchTimeoutResult {
            attemptSemaphore.wait(timeout: .now() + 2)
        }

        func makeAvailable() {
            lock.withLock {
                available = true
            }
        }

        func waitForReceive() -> DispatchTimeoutResult {
            receiveSemaphore.wait(timeout: .now() + 2)
        }
    }

    func testEnqueueReturnsWhileReceiverIsBlocked() {
        let queue = TerminalOutputDeliveryQueue(label: "dev.sshapp.tests.blocked-output")
        let receiver = RecordingReceiver(blockedReceives: 1)
        let first = Data("first".utf8)
        let second = Data("second".utf8)

        queue.setReceiver(receiver)
        queue.setReady(true)
        queue.enqueue(first)
        XCTAssertEqual(receiver.waitForReceive(), .success)

        let returned = expectation(description: "second enqueue returned")
        DispatchQueue.global().async {
            queue.enqueue(second)
            returned.fulfill()
        }

        let result = XCTWaiter.wait(for: [returned], timeout: 1.0)
        receiver.releaseBlockedReceive()

        XCTAssertEqual(result, .completed)
        XCTAssertEqual(receiver.waitForReceive(), .success)
        XCTAssertEqual(receiver.received, [first, second])
    }

    @MainActor
    func testReceiverWorkRunsOffMainEvenWhenEnqueuedFromMainActor() {
        let queue = TerminalOutputDeliveryQueue(label: "dev.sshapp.tests.off-main-receive")
        let receiver = RecordingReceiver()

        queue.setReceiver(receiver)
        queue.setReady(true)
        queue.enqueue(Data("prompt".utf8))

        XCTAssertEqual(receiver.waitForReceive(), .success)
        XCTAssertEqual(receiver.receivedOnMainThread, [false])
    }

    func testResetDuringReceiverHandoffRejectsClaimedStaleOutput() {
        let queue = TerminalOutputDeliveryQueue(label: "dev.sshapp.tests.handoff-reset")
        let receiver = HandoffBlockingReceiver()

        queue.setReceiver(receiver)
        queue.setReady(true)
        queue.enqueue(Data("stale".utf8))
        XCTAssertEqual(receiver.waitForAttempt(), .success)

        queue.resetPendingOutput()
        receiver.releaseHandoff()

        XCTAssertEqual(receiver.waitForRejection(), .success)
        XCTAssertTrue(receiver.received.isEmpty)
    }

    func testShellPromptCannotOvertakeBlockedSessionStatus() {
        let queue = TerminalOutputDeliveryQueue(label: "dev.sshapp.tests.session-shell-order")
        let receiver = RecordingReceiver(blockedReceives: 1)
        let status = Data("Authenticated\r\n".utf8)
        let prompt = Data("host$ ".utf8)

        queue.setReceiver(receiver)
        queue.setReady(true)
        queue.enqueue(status)
        XCTAssertEqual(receiver.waitForReceive(), .success)

        queue.enqueue(prompt)
        XCTAssertEqual(
            receiver.waitForReceive(timeout: 0.1),
            .timedOut,
            "the shell prompt must not enter Ghostty concurrently with older session output"
        )

        receiver.releaseBlockedReceive()
        XCTAssertEqual(receiver.waitForReceive(), .success)
        XCTAssertEqual(receiver.received, [status, prompt])
    }

    func testRelinquishedCoordinatorQueueCannotInvalidateChannelReplacement() {
        let adoptedChannelQueue = TerminalOutputDeliveryQueue(
            label: "dev.sshapp.tests.adopted-channel-output"
        )
        let staleCoordinatorQueue = TerminalOutputDeliveryQueue(
            label: "dev.sshapp.tests.stale-coordinator-output"
        )
        let oldReceiver = RecordingReceiver()
        let replacementReceiver = RecordingReceiver()
        let output = Data("replacement prompt".utf8)

        adoptedChannelQueue.setReceiver(oldReceiver)
        adoptedChannelQueue.setReady(true)
        adoptedChannelQueue.setReceiverPreservingPendingOutput(replacementReceiver)

        // Dismantling the coordinator that opened the channel is only allowed to
        // mutate its replacement local queue after channel ownership transfers.
        staleCoordinatorQueue.setReady(false)
        staleCoordinatorQueue.setReceiver(nil)

        adoptedChannelQueue.enqueue(output)
        XCTAssertEqual(replacementReceiver.waitForReceive(), .success)
        XCTAssertTrue(oldReceiver.received.isEmpty)
        XCTAssertEqual(replacementReceiver.received, [output])
    }

    func testReceiverReplacementPreservesClaimedOutputExactlyOnce() {
        let queue = TerminalOutputDeliveryQueue(label: "dev.sshapp.tests.handoff-receiver-replacement")
        let oldReceiver = HandoffBlockingReceiver()
        let replacementReceiver = RecordingReceiver()
        let output = Data("survive receiver replacement".utf8)

        queue.setReceiver(oldReceiver)
        queue.setReady(true)
        queue.enqueue(output)
        XCTAssertEqual(oldReceiver.waitForAttempt(), .success)

        queue.setReceiverPreservingPendingOutput(replacementReceiver)
        oldReceiver.releaseHandoff()

        XCTAssertEqual(oldReceiver.waitForRejection(), .success)
        XCTAssertEqual(replacementReceiver.waitForReceive(), .success)
        XCTAssertTrue(oldReceiver.received.isEmpty)
        XCTAssertEqual(replacementReceiver.received, [output])
    }

    func testReadinessGenerationChangeDuringHandoffRequeuesExactlyOnce() {
        let queue = TerminalOutputDeliveryQueue(label: "dev.sshapp.tests.handoff-rebind")
        let receiver = HandoffBlockingReceiver()
        let output = Data("survive same-session rebind".utf8)

        queue.setReceiver(receiver)
        queue.setReady(true)
        queue.enqueue(output)
        XCTAssertEqual(receiver.waitForAttempt(), .success)

        queue.setReady(false)
        queue.setReady(true)
        receiver.releaseHandoff()

        XCTAssertEqual(receiver.waitForRejection(), .success)
        XCTAssertEqual(receiver.waitForReceive(), .success)
        XCTAssertEqual(receiver.received, [output])
    }

    func testUnavailableSurfaceRequeuesCurrentGenerationForNextReadiness() {
        let queue = TerminalOutputDeliveryQueue(label: "dev.sshapp.tests.surface-requeue")
        let receiver = InitiallyUnavailableReceiver()
        let output = Data("preserve across rebuild".utf8)

        queue.setReceiver(receiver)
        queue.setReady(true)
        queue.enqueue(output)
        XCTAssertEqual(receiver.waitForUnavailableAttempt(), .success)
        XCTAssertTrue(receiver.received.isEmpty)

        receiver.makeAvailable()
        queue.setReady(true)

        XCTAssertEqual(receiver.waitForReceive(), .success)
        XCTAssertEqual(receiver.received, [output])
    }

    func testOutputBuffersUntilSurfaceIsAttached() {
        let queue = TerminalOutputDeliveryQueue(label: "dev.sshapp.tests.surface-buffer")
        let receiver = RecordingReceiver()
        let output = Data("prompt".utf8)

        queue.setReceiver(receiver)
        queue.enqueue(output)

        XCTAssertEqual(receiver.waitForReceive(timeout: 0.1), .timedOut)

        queue.setReady(true)

        XCTAssertEqual(receiver.waitForReceive(), .success)
        XCTAssertEqual(receiver.received, [output])
    }

    /// Regression: duplicate lifecycle notifications used to advance the queue
    /// generation while leaving the old drain marked as scheduled. The stale
    /// drain then exited and no future task owned the buffered snapshot.
    func testRepeatedSurfaceAttachedNotificationDoesNotStrandOutput() {
        let queue = TerminalOutputDeliveryQueue(label: "dev.sshapp.tests.repeated-attach")
        let receiver = RecordingReceiver()
        let output = Data("restored history".utf8)

        queue.setReceiver(receiver)
        queue.enqueue(output)
        queue.setReady(true)
        queue.setReady(true)

        XCTAssertEqual(receiver.waitForReceive(), .success)
        XCTAssertEqual(receiver.received, [output])
    }

    /// A drain already inside the old receiver must not clear the scheduled
    /// marker for a replacement receiver after the surface generation changes.
    func testStaleDrainCannotCancelReplacementGenerationDrain() {
        let queue = TerminalOutputDeliveryQueue(label: "dev.sshapp.tests.replacement-generation")
        let oldReceiver = RecordingReceiver(blockedReceives: 1)
        let newReceiver = RecordingReceiver()
        let oldOutput = Data("old surface".utf8)
        let newOutput = Data("new surface".utf8)

        queue.setReceiver(oldReceiver)
        queue.setReady(true)
        queue.enqueue(oldOutput)
        XCTAssertEqual(oldReceiver.waitForReceive(), .success)

        queue.setReady(false)
        queue.resetPendingOutput()
        queue.setReceiver(newReceiver)
        queue.setReady(true)
        queue.enqueue(newOutput)

        oldReceiver.releaseBlockedReceive()

        XCTAssertEqual(newReceiver.waitForReceive(), .success)
        XCTAssertEqual(oldReceiver.received, [oldOutput])
        XCTAssertEqual(newReceiver.received, [newOutput])
    }

    func testReadinessReleasesSnapshotAndLiveBytesInOrderExactlyOnce() {
        let queue = TerminalOutputDeliveryQueue(label: "dev.sshapp.tests.ordered-ready-batch")
        let receiver = RecordingReceiver()
        let firstDrain = DispatchSemaphore(value: 0)

        queue.setReceiver(receiver)
        queue.enqueue(Data("snapshot-prompt".utf8))
        queue.enqueue(Data("+live".utf8))
        XCTAssertEqual(receiver.waitForReceive(timeout: 0.1), .timedOut)

        queue.setReady(true, onFirstDrain: {
            firstDrain.signal()
        })

        XCTAssertEqual(receiver.waitForReceive(), .success)
        XCTAssertEqual(firstDrain.wait(timeout: .now() + 1.0), .success)
        XCTAssertEqual(receiver.received, [Data("snapshot-prompt+live".utf8)])
        XCTAssertEqual(receiver.waitForReceive(timeout: 0.1), .timedOut)
    }

    func testLogicalReplacementDiscardsBufferedOutputBeforeReady() {
        let queue = TerminalOutputDeliveryQueue(label: "dev.sshapp.tests.logical-replacement")
        let receiver = RecordingReceiver()

        queue.setReceiver(receiver)
        queue.enqueue(Data("stale prompt".utf8))
        queue.resetPendingOutput()
        queue.enqueue(Data("current prompt".utf8))
        queue.setReady(true)

        XCTAssertEqual(receiver.waitForReceive(), .success)
        XCTAssertEqual(receiver.received, [Data("current prompt".utf8)])
    }

    func testPendingOutputIsBoundedAtNewlineWithoutLoggingContents() {
        let queue = TerminalOutputDeliveryQueue(
            label: "dev.sshapp.tests.bounded-output",
            maxPendingBytes: 9,
            trimNewlineScanWindow: 8
        )
        let receiver = RecordingReceiver()

        queue.setReceiver(receiver)
        queue.enqueue(Data("old-line\nPROMPT".utf8))
        queue.setReady(true)

        XCTAssertEqual(receiver.waitForReceive(), .success)
        XCTAssertEqual(receiver.received, [Data("PROMPT".utf8)])
    }

    func testAuthoritativeSnapshotSurvivesWhileFollowingLiveOutputRemainsBounded() {
        let queue = TerminalOutputDeliveryQueue(
            label: "dev.sshapp.tests.preserved-snapshot",
            maxPendingBytes: 5,
            trimNewlineScanWindow: 0
        )
        let receiver = RecordingReceiver()
        let snapshot = Data("authoritative-snapshot".utf8)

        queue.setReceiver(receiver)
        queue.enqueuePreservingPaneReplay(snapshot)
        queue.enqueue(Data("123456789".utf8))
        queue.setReady(true)

        XCTAssertEqual(receiver.waitForReceive(), .success)
        XCTAssertEqual(receiver.waitForReceive(), .success)
        XCTAssertEqual(receiver.received, [snapshot, Data("56789".utf8)])
        XCTAssertEqual(receiver.waitForReceive(timeout: 0.1), .timedOut)
    }

    @MainActor
    func testSixHundredKiBAuthoritativePaneReplaySurvivesDeliveryQueueCap() {
        let queue = TerminalOutputDeliveryQueue(
            label: "dev.sshapp.tests.large-pane-replay",
            maxPendingBytes: 512 * 1024,
            trimNewlineScanWindow: 8 * 1024
        )
        let receiver = RecordingReceiver()
        let pane = TmuxPane(
            id: TmuxPaneID(rawValue: 1),
            windowID: TmuxWindowID(rawValue: 1)
        )
        let snapshot = Data(repeating: 0x53, count: 600 * 1024)
            + Data("\nLARGE_SNAPSHOT_PROMPT $ ".utf8)

        pane.feedSnapshot(snapshot, mode: .freshAttach)
        queue.setReceiver(receiver)
        var isReplayingPaneBacklog = true
        let token = pane.setSink { data in
            if isReplayingPaneBacklog {
                queue.enqueuePreservingPaneReplay(data)
            } else {
                queue.enqueue(data)
            }
        }
        isReplayingPaneBacklog = false
        queue.setReady(true)

        XCTAssertEqual(receiver.waitForReceive(), .success)
        XCTAssertEqual(receiver.received, [snapshot])
        XCTAssertGreaterThan(receiver.received[0].count, 512 * 1024)
        pane.clearSink(token)
    }

    func testEmptyOutputIsANoop() {
        let queue = TerminalOutputDeliveryQueue(label: "dev.sshapp.tests.empty-output")
        let receiver = RecordingReceiver()

        queue.setReceiver(receiver)
        queue.setReady(true)
        queue.enqueue(Data())

        XCTAssertEqual(receiver.waitForReceive(timeout: 0.1), .timedOut)
        XCTAssertTrue(receiver.received.isEmpty)
    }

    /// Regression: output accepted by a surface that is retired mid-write used
    /// to vanish. A readiness handoff while the accepted receive is blocked
    /// must replay the segment once for the new surface epoch.
    func testReadinessToggleDuringAcceptedReceiveReplaysSegmentOncePerEpoch() {
        let queue = TerminalOutputDeliveryQueue(label: "dev.sshapp.tests.epoch-replay")
        let receiver = RecordingReceiver(blockedReceives: 1)
        let output = Data("survive epoch handoff".utf8)

        queue.setReceiver(receiver)
        queue.setReady(true)
        queue.enqueue(output)
        XCTAssertEqual(receiver.waitForReceive(), .success)

        queue.setReady(false)
        queue.setReady(true)
        receiver.releaseBlockedReceive()

        XCTAssertEqual(receiver.waitForReceive(), .success)
        XCTAssertEqual(receiver.received, [output, output])
        XCTAssertEqual(receiver.waitForReceive(timeout: 0.1), .timedOut)
    }

    /// Regression: replacing the receiver with a preserving handoff while an
    /// accepted receive is blocked must replay that segment to the replacement
    /// receiver ahead of later bytes.
    func testPreservingReceiverReplacementDuringAcceptedReceiveReplaysToReplacement() {
        let queue = TerminalOutputDeliveryQueue(label: "dev.sshapp.tests.accepted-handoff-replay")
        let oldReceiver = RecordingReceiver(blockedReceives: 1)
        let replacementReceiver = RecordingReceiver()
        let first = Data("claimed prompt".utf8)
        let second = Data("later prompt".utf8)

        queue.setReceiver(oldReceiver)
        queue.setReady(true)
        queue.enqueue(first)
        XCTAssertEqual(oldReceiver.waitForReceive(), .success)

        queue.setReceiverPreservingPendingOutput(replacementReceiver)
        queue.enqueue(second)
        oldReceiver.releaseBlockedReceive()

        XCTAssertEqual(replacementReceiver.waitForReceive(), .success)
        XCTAssertEqual(replacementReceiver.waitForReceive(), .success)
        XCTAssertEqual(oldReceiver.received, [first])
        XCTAssertEqual(
            replacementReceiver.received,
            [first, second],
            "the accepted segment must replay to the replacement before later bytes"
        )
    }

    /// An explicit content reset during an accepted receive discards the
    /// claimed segment instead of replaying it onto the replacement surface.
    func testResetDuringAcceptedReceiveDiscardsClaimedSegment() {
        let queue = TerminalOutputDeliveryQueue(label: "dev.sshapp.tests.accepted-reset")
        let receiver = RecordingReceiver(blockedReceives: 1)
        let output = Data("stale tab output".utf8)

        queue.setReceiver(receiver)
        queue.setReady(true)
        queue.enqueue(output)
        XCTAssertEqual(receiver.waitForReceive(), .success)

        queue.resetPendingOutput()
        receiver.releaseBlockedReceive()

        XCTAssertEqual(receiver.received, [output])
        XCTAssertEqual(receiver.waitForReceive(timeout: 0.1), .timedOut)
    }

    /// The first-drain completion belongs to the generation that commits the
    /// replayed segment, never to the retiring generation that accepted it.
    func testFirstDrainCompletionBelongsOnlyToReplacementGeneration() {
        let queue = TerminalOutputDeliveryQueue(label: "dev.sshapp.tests.replacement-first-drain")
        let receiver = RecordingReceiver(blockedReceives: 1)
        let retiringDrain = DispatchSemaphore(value: 0)
        let replacementDrain = DispatchSemaphore(value: 0)
        let output = Data("epoch output".utf8)

        queue.setReceiver(receiver)
        queue.setReady(true, onFirstDrain: { retiringDrain.signal() })
        queue.enqueue(output)
        XCTAssertEqual(receiver.waitForReceive(), .success)

        queue.setReady(false)
        queue.setReady(true, onFirstDrain: { replacementDrain.signal() })
        receiver.releaseBlockedReceive()

        XCTAssertEqual(replacementDrain.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(receiver.received, [output, output])
        XCTAssertEqual(
            retiringDrain.wait(timeout: .now() + 0.1),
            .timedOut,
            "the retiring generation must not claim the replacement's first drain"
        )
    }
}
