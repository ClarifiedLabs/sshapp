import XCTest
import GhosttyTerminal
@testable import SSHApp

final class TerminalOutputDeliveryQueueTests: XCTestCase {
    private final class RecordingReceiver: TerminalOutputReceiver, @unchecked Sendable {
        private let lock = NSLock()
        private let receiveSemaphore = DispatchSemaphore(value: 0)
        private let releaseSemaphore = DispatchSemaphore(value: 0)
        private var remainingBlockedReceives: Int
        private var receivedValues: [Data] = []
        private var receivedOnMainThreadValues: [Bool] = []

        let preservesStateAcrossReadinessChanges: Bool

        init(blockedReceives: Int = 0, persistent: Bool = false) {
            remainingBlockedReceives = blockedReceives
            preservesStateAcrossReadinessChanges = persistent
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

    /// Returns from deliver immediately, retaining the real commit completion.
    /// A blocked synchronous receiver cannot detect an erroneously early barrier
    /// because it also blocks the delivery queue's callback executor.
    private final class DeferredCommitReceiver: TerminalOutputReceiver, @unchecked Sendable {
        let preservesStateAcrossReadinessChanges = true
        private let lock = NSLock()
        private let accepted = DispatchSemaphore(value: 0)
        private var completions: [@Sendable (Bool) -> Void] = []
        private var values: [Data] = []

        var received: [Data] { lock.withLock { values } }

        func receiveIfCurrent(_ data: Data, ifCurrent: @Sendable () -> Bool) -> Bool {
            XCTFail("Queue must use completion-bearing delivery")
            return false
        }

        func deliver(_ data: Data, ifCurrent: @escaping @Sendable () -> Bool,
                     completion: @escaping @Sendable (Bool) -> Void) {
            guard ifCurrent() else { completion(false); return }
            lock.withLock {
                values.append(data)
                completions.append(completion)
            }
            accepted.signal()
        }

        func waitForAcceptance() -> DispatchTimeoutResult {
            accepted.wait(timeout: .now() + 2)
        }

        func commitNext() {
            let completion = lock.withLock { completions.removeFirst() }
            completion(true)
        }
    }

    func testEmptyDrainBarrierCompletesWithoutConsumingFirstDrain() {
        let queue = TerminalOutputDeliveryQueue()
        let receiver = RecordingReceiver()
        let emptyBarrier = DispatchSemaphore(value: 0)
        let firstDrain = DispatchSemaphore(value: 0)
        queue.setReceiver(receiver)
        queue.setReady(true, onFirstDrain: { firstDrain.signal() })
        queue.notifyWhenDrained { emptyBarrier.signal() }

        XCTAssertEqual(emptyBarrier.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(receiver.received.isEmpty, "An empty barrier must not synthesize bytes")
        XCTAssertEqual(firstDrain.wait(timeout: .now() + 0.1), .timedOut)
        queue.enqueue(Data("prompt".utf8))
        XCTAssertEqual(firstDrain.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(receiver.received, [Data("prompt".utf8)])
    }

    func testDrainBarrierWaitsForInFlightCommitWithEmptyPendingQueue() {
        let queue = TerminalOutputDeliveryQueue()
        let receiver = DeferredCommitReceiver()
        let drained = DispatchSemaphore(value: 0)
        queue.setReceiver(receiver)
        queue.setReady(true)
        queue.enqueue(Data("retained".utf8))
        XCTAssertEqual(receiver.waitForAcceptance(), .success)
        queue.notifyWhenDrained { drained.signal() }

        XCTAssertEqual(drained.wait(timeout: .now() + 0.1), .timedOut)
        receiver.commitNext()
        XCTAssertEqual(drained.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(receiver.received, [Data("retained".utf8)])
    }

    func testDrainBarrierWaitsForAllCurrentSegmentsButNotLaterOutput() {
        let queue = TerminalOutputDeliveryQueue()
        let receiver = DeferredCommitReceiver()
        let firstDrain = DispatchSemaphore(value: 0)
        let drained = DispatchSemaphore(value: 0)
        queue.setReceiver(receiver)
        queue.enqueuePreservingPaneReplay(Data("snapshot".utf8))
        queue.enqueue(Data("live".utf8))
        queue.setReady(true, onFirstDrain: { firstDrain.signal() })
        XCTAssertEqual(receiver.waitForAcceptance(), .success)
        queue.notifyWhenDrained { drained.signal() }
        receiver.commitNext()
        XCTAssertEqual(firstDrain.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(receiver.waitForAcceptance(), .success)
        XCTAssertEqual(drained.wait(timeout: .now() + 0.1), .timedOut)

        queue.enqueue(Data("later".utf8))
        receiver.commitNext()
        XCTAssertEqual(drained.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(receiver.waitForAcceptance(), .success)
        receiver.commitNext()
        XCTAssertEqual(receiver.received, ["snapshot", "live", "later"].map { Data($0.utf8) })
    }

    func testLaterBytesDoNotCoalesceAcrossRegisteredBarrier() {
        let queue = TerminalOutputDeliveryQueue()
        let receiver = DeferredCommitReceiver()
        let drained = DispatchSemaphore(value: 0)
        queue.setReceiver(receiver)
        queue.setReady(true)
        queue.enqueue(Data("in-flight".utf8))
        XCTAssertEqual(receiver.waitForAcceptance(), .success)
        queue.enqueue(Data("current".utf8))
        queue.notifyWhenDrained { drained.signal() }
        queue.enqueue(Data("later".utf8))
        receiver.commitNext()
        XCTAssertEqual(receiver.waitForAcceptance(), .success)
        XCTAssertEqual(receiver.received, ["in-flight", "current"].map { Data($0.utf8) })
        receiver.commitNext()
        XCTAssertEqual(drained.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(receiver.waitForAcceptance(), .success)
        receiver.commitNext()
        XCTAssertEqual(receiver.received, ["in-flight", "current", "later"].map { Data($0.utf8) })
    }

    func testRemountBarrierCancelsRetiredGenerationWithoutReplayingAcceptedBytes() {
        let queue = TerminalOutputDeliveryQueue()
        let receiver = DeferredCommitReceiver()
        let retired = DispatchSemaphore(value: 0)
        let replacement = DispatchSemaphore(value: 0)
        queue.setReceiver(receiver)
        queue.setReady(true)
        queue.enqueue(Data("once".utf8))
        XCTAssertEqual(receiver.waitForAcceptance(), .success)
        queue.notifyWhenDrained { retired.signal() }
        queue.setReady(false)
        queue.setReady(true)
        queue.notifyWhenDrained { replacement.signal() }
        XCTAssertEqual(replacement.wait(timeout: .now() + 0.1), .timedOut)
        receiver.commitNext()

        XCTAssertEqual(replacement.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(retired.wait(timeout: .now() + 0.1), .timedOut)
        XCTAssertEqual(receiver.received, [Data("once".utf8)])
    }

    func testResetCancelsPendingBarrier() {
        let queue = TerminalOutputDeliveryQueue()
        let receiver = DeferredCommitReceiver()
        let retired = DispatchSemaphore(value: 0)
        let replacement = DispatchSemaphore(value: 0)
        queue.setReceiver(receiver)
        queue.setReady(true)
        queue.enqueue(Data("old content".utf8))
        XCTAssertEqual(receiver.waitForAcceptance(), .success)
        queue.notifyWhenDrained { retired.signal() }
        queue.resetPendingOutput()
        queue.notifyWhenDrained { replacement.signal() }
        XCTAssertEqual(replacement.wait(timeout: .now() + 0.1), .timedOut)
        receiver.commitNext()
        XCTAssertEqual(replacement.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(retired.wait(timeout: .now() + 0.1), .timedOut)
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
        private let handoffSemaphore = DispatchSemaphore(value: 0)
        private let blocksUnavailableHandoff: Bool
        private let lock = NSLock()
        private var available = false
        private var receivedValues: [Data] = []

        init(blocksUnavailableHandoff: Bool = false) {
            self.blocksUnavailableHandoff = blocksUnavailableHandoff
        }

        func releaseUnavailableHandoff() {
            handoffSemaphore.signal()
        }

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
                if blocksUnavailableHandoff {
                    handoffSemaphore.wait()
                }
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

    #if DEBUG
    @MainActor
    func testChannelDetachDuringCommittedPersistentDeliveryDoesNotReplay() {
        let owner = SSHSession()
        let channel = SSHChannel(transport: ScriptedSSHChannelTransport(),
                                 owner: owner, tmuxSettings: .default)
        let receiver = RecordingReceiver(blockedReceives: 1, persistent: true)
        let token = channel.registerTerminalOutputReceiver(receiver)
        channel.setTerminalOutputReady(true, token: token)
        channel.deliverTerminalOutput(Data("committed".utf8))
        XCTAssertEqual(receiver.waitForReceive(), .success)
        // Ingest has committed, but completion is deliberately held until the
        // ephemeral host token is revoked. No replacement is registered yet.
        channel.unregisterTerminalOutputReceiver(token)
        receiver.releaseBlockedReceive()
        channel.deliverTerminalOutput(Data("detached".utf8))
        XCTAssertEqual(receiver.waitForReceive(), .success)
        let replacement = channel.registerTerminalOutputReceiver(receiver)
        let drained = DispatchSemaphore(value: 0)
        channel.setTerminalOutputReady(true, token: replacement,
                                       onFirstDrain: { drained.signal() })
        channel.deliverTerminalOutput(Data("replacement".utf8))
        XCTAssertEqual(drained.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(receiver.received, ["committed", "detached", "replacement"].map { Data($0.utf8) })
    }
    #endif

    func testSnapshotRecoveryGateCannotBeOpenedByHostReadiness() async {
        let queue = TerminalOutputDeliveryQueue(maxPendingBytes: 8)
        let receiver = RecordingReceiver()
        let gap = expectation(description: "gap reported once")
        queue.setReceiver(receiver)
        queue.setOutputGapHandler { gap.fulfill() }
        queue.enqueue(Data(repeating: 65, count: 32))
        queue.enqueue(Data(repeating: 66, count: 32))
        queue.setReady(true)
        await fulfillment(of: [gap], timeout: 1)
        XCTAssertTrue(queue.requiresSnapshotRecovery)
        XCTAssertTrue(receiver.received.isEmpty, "Never ingest a trimmed VT tail")
        queue.resetPendingOutput()
        queue.enqueuePreservingPaneReplay(Data("snapshot".utf8))
        queue.setReady(true)
        XCTAssertEqual(receiver.waitForReceive(), .success)
        XCTAssertEqual(receiver.received, [Data("snapshot".utf8)])
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

    func testReadinessDuringRejectedHandoffIsNotLost() {
        let queue = TerminalOutputDeliveryQueue(label: "dev.sshapp.tests.readiness-during-rejection")
        let receiver = InitiallyUnavailableReceiver(blocksUnavailableHandoff: true)
        defer { receiver.releaseUnavailableHandoff() }
        let output = Data("preserve readiness during resize".utf8)

        queue.setReceiver(receiver)
        queue.setReady(true)
        queue.enqueue(output)
        XCTAssertEqual(receiver.waitForUnavailableAttempt(), .success)

        // The view becomes ready before the old handoff returns false. Its
        // ready notification must not be replaced by that stale rejection.
        receiver.makeAvailable()
        queue.setReady(true)
        receiver.releaseUnavailableHandoff()

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
    func testSemanticPaneSinkPreservesLargeReplayAndBoundsSubsequentLiveOutput() {
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
        let lifetime = TerminalSemanticLifetime()
        lifetime.outputDelivery = queue
        pane.terminalLifetime = lifetime
        defer { pane.finishTerminalSession() }

        pane.feedSnapshot(snapshot, mode: .freshAttach)
        queue.setReceiver(receiver)
        XCTAssertNotNil(pane.installSemanticSink { false })
        XCTAssertFalse(pane.requiresOutputRecovery)
        queue.setReady(true)

        XCTAssertEqual(receiver.waitForReceive(), .success)
        XCTAssertEqual(receiver.received, [snapshot])
        XCTAssertGreaterThan(receiver.received[0].count, 512 * 1024)
        // After synchronous replay, new live bytes must obey the queue's cap.
        // Keep delivery paused so overflow does not depend on drain timing.
        queue.setReady(false)
        pane.feed(Data(repeating: 0x4c, count: 600 * 1024))
        XCTAssertTrue(queue.requiresSnapshotRecovery)
        XCTAssertTrue(pane.requiresOutputRecovery)
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

    // MARK: - Live-output flow control

    @MainActor
    private final class FlowTransitions {
        var values: [Bool] = []
    }

    /// Regression: live output of a visible plain SSH tab was trimmed from the
    /// middle of the stream (possibly inside OSC/DCS/APC) whenever one slow
    /// commit let more than `maxPendingBytes` accumulate. Flow-controlled
    /// output must instead pause the producer and deliver every byte in order.
    @MainActor
    func testFlowControlledLiveOutputPausesProducerInsteadOfTrimming() async {
        let queue = TerminalOutputDeliveryQueue(
            label: "dev.sshapp.tests.flow-control",
            maxPendingBytes: 16,
            trimNewlineScanWindow: 0
        )
        let receiver = DeferredCommitReceiver()
        let transitions = FlowTransitions()
        let paused = expectation(description: "producer paused")
        let resumed = expectation(description: "producer resumed")
        queue.setFlowControlHandler { value in
            transitions.values.append(value)
            (value ? paused : resumed).fulfill()
        }
        queue.setReceiver(receiver)
        queue.setReady(true)

        let first = Data(repeating: 0x61, count: 4)
        queue.enqueue(first)
        XCTAssertEqual(receiver.waitForAcceptance(), .success)
        // The first commit is held (a main-actor stall); live output arrives
        // far past the cap, including an OSC that trimming could have split.
        let live = [Data("\u{1b}]0;title\u{7}".utf8)]
            + (0..<5).map { Data(repeating: UInt8(0x62 + $0), count: 8) }
        for chunk in live { queue.enqueue(chunk) }
        await fulfillment(of: [paused], timeout: 2)

        receiver.commitNext()
        XCTAssertEqual(receiver.waitForAcceptance(), .success)
        receiver.commitNext()
        await fulfillment(of: [resumed], timeout: 2)

        XCTAssertEqual(transitions.values, [true, false])
        XCTAssertEqual(receiver.received, [first, live.reduce(Data(), +)])
    }

    /// Before viewport readiness nothing is feeding a live parser, so the
    /// bounded pre-readiness buffer is kept and the remote is never paused.
    /// Once ready, the retained backlog is live output: it may apply
    /// backpressure while draining, but must not leave the producer paused.
    @MainActor
    func testPreReadinessOutputRemainsBoundedWithoutPausingProducer() async {
        let queue = TerminalOutputDeliveryQueue(
            label: "dev.sshapp.tests.flow-control-pre-ready",
            maxPendingBytes: 9,
            trimNewlineScanWindow: 8
        )
        let receiver = RecordingReceiver()
        let transitions = FlowTransitions()
        queue.setFlowControlHandler { transitions.values.append($0) }
        queue.setReceiver(receiver)
        queue.enqueue(Data("old-line\nPROMPT".utf8))
        await flushMainQueue()
        XCTAssertEqual(transitions.values, [], "Never pause the remote before readiness")

        queue.setReady(true)
        XCTAssertEqual(receiver.waitForReceive(), .success)
        XCTAssertEqual(receiver.received, [Data("PROMPT".utf8)])
        let deadline = Date().addingTimeInterval(2)
        while transitions.values.last == true, Date() < deadline {
            await flushMainQueue()
        }
        XCTAssertNotEqual(transitions.values.last, true, "Drained output must resume the producer")
        XCTAssertTrue(transitions.values.count % 2 == 0)
    }

    @MainActor
    private func flushMainQueue() async {
        let flushed = expectation(description: "main queue flushed")
        DispatchQueue.main.async { flushed.fulfill() }
        await fulfillment(of: [flushed], timeout: 2)
    }

    private final class FlakyPersistentReceiver: TerminalOutputReceiver, @unchecked Sendable {
        let preservesStateAcrossReadinessChanges = true
        private let lock = NSLock()
        private let receiveSemaphore = DispatchSemaphore(value: 0)
        private var remainingFailures: Int
        private var attemptCount = 0
        private var values: [Data] = []

        init(failures: Int) { remainingFailures = failures }

        var received: [Data] { lock.withLock { values } }
        var attempts: Int { lock.withLock { attemptCount } }

        func receiveIfCurrent(_ data: Data, ifCurrent: @Sendable () -> Bool) -> Bool {
            guard ifCurrent() else { return false }
            let accepted = lock.withLock { () -> Bool in
                attemptCount += 1
                guard remainingFailures == 0 else {
                    remainingFailures -= 1
                    return false
                }
                values.append(data)
                return true
            }
            if accepted { receiveSemaphore.signal() }
            return accepted
        }

        func waitForReceive() -> DispatchTimeoutResult {
            receiveSemaphore.wait(timeout: .now() + 2)
        }
    }

    /// Regression: an engine rejection closed queue readiness, but the channel
    /// treats a persistent engine as always ready and never re-signals, so a
    /// visible plain SSH tab stalled until the next viewport settle.
    func testPersistentEngineRejectionRetriesWithoutNewReadinessSignal() {
        let queue = TerminalOutputDeliveryQueue(label: "dev.sshapp.tests.engine-retry")
        let receiver = FlakyPersistentReceiver(failures: 2)
        queue.setReceiver(receiver)
        queue.setReady(true)

        queue.enqueue(Data("prompt".utf8))
        XCTAssertEqual(receiver.waitForReceive(), .success)
        XCTAssertEqual(receiver.attempts, 3)

        queue.enqueue(Data("next".utf8))
        XCTAssertEqual(receiver.waitForReceive(), .success)
        XCTAssertEqual(receiver.received, [Data("prompt".utf8), Data("next".utf8)])
    }

    #if DEBUG
    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition() {
            guard Date() < deadline else { return XCTFail("condition not met") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @MainActor
    func testChannelPausesTransportReadsWhileLiveOutputIsBacklogged() async throws {
        let transport = ScriptedSSHChannelTransport()
        transport.queueOpenPlan(.succeed)
        let queue = TerminalOutputDeliveryQueue(
            label: "dev.sshapp.tests.channel-flow-control",
            maxPendingBytes: 16
        )
        let channel = SSHChannel(transport: transport, owner: SSHSession(),
                                 tmuxSettings: .default, terminalOutputDelivery: queue)
        try await channel.openShell()
        let id = try XCTUnwrap(transport.snapshot().activeChannelIDs.first)
        let receiver = DeferredCommitReceiver()
        let token = channel.registerTerminalOutputReceiver(receiver)
        channel.setTerminalOutputReady(true, token: token)

        channel.deliverTerminalOutput(Data(repeating: 0x61, count: 4))
        XCTAssertEqual(receiver.waitForAcceptance(), .success)
        channel.deliverTerminalOutput(Data(repeating: 0x62, count: 32))
        try await waitUntil { transport.isReadPaused(id) }
        XCTAssertTrue(channel.isTransportReadPaused)

        receiver.commitNext()
        XCTAssertEqual(receiver.waitForAcceptance(), .success)
        receiver.commitNext()
        try await waitUntil { !transport.isReadPaused(id) }
        XCTAssertEqual(receiver.received.reduce(Data(), +).count, 36,
                       "Backpressure must not drop live bytes")
        channel.close()
    }

    /// A retired engine can never display output; the channel must neither
    /// retry it nor keep the remote paused on its behalf.
    @MainActor
    func testRetiredEngineReleasesChannelBackpressure() async throws {
        let transport = ScriptedSSHChannelTransport()
        transport.queueOpenPlan(.succeed)
        let queue = TerminalOutputDeliveryQueue(
            label: "dev.sshapp.tests.retired-engine-flow-control",
            maxPendingBytes: 16
        )
        let channel = SSHChannel(transport: transport, owner: SSHSession(),
                                 tmuxSettings: .default, terminalOutputDelivery: queue)
        try await channel.openShell()
        let id = try XCTUnwrap(transport.snapshot().activeChannelIDs.first)
        let receiver = DeferredCommitReceiver()
        let token = channel.registerTerminalOutputReceiver(receiver)
        channel.setTerminalOutputReady(true, token: token)
        channel.deliverTerminalOutput(Data(repeating: 0x61, count: 4))
        XCTAssertEqual(receiver.waitForAcceptance(), .success)
        channel.deliverTerminalOutput(Data(repeating: 0x62, count: 32))
        try await waitUntil { transport.isReadPaused(id) }

        channel.retireTerminalOutputReceiver(receiver)
        try await waitUntil { !transport.isReadPaused(id) }
        channel.setTerminalOutputReady(true, token: token) // stale host token
        channel.deliverTerminalOutput(Data(repeating: 0x63, count: 64))
        let flushed = expectation(description: "main queue flushed")
        DispatchQueue.main.async { flushed.fulfill() }
        await fulfillment(of: [flushed], timeout: 2)
        XCTAssertFalse(transport.isReadPaused(id))
        XCTAssertFalse(channel.isTransportReadPaused)
        channel.close()
    }
    #endif
}


@MainActor
final class VTPersistentOutputDeliveryTests: XCTestCase {
    private final class BellProbe: TerminalSurfaceBellDelegate {
        let queue: TerminalOutputDeliveryQueue
        let committed: XCTestExpectation
        var rings = 0

        init(queue: TerminalOutputDeliveryQueue, committed: XCTestExpectation) {
            self.queue = queue
            self.committed = committed
        }

        func terminalDidRingBell() {
            rings += 1
            guard rings == 1 else { return }
            // Ingest has committed, but deliver has not completed its event fan-out.
            queue.setReady(false)
            queue.setReady(true, onFirstDrain: { [committed] in committed.fulfill() })
        }
    }

    func testReadinessToggleDoesNotReplayCommittedVTBytesOrEvents() async throws {
        let queue = TerminalOutputDeliveryQueue()
        let session = VTTerminalSession(write: { _ in }, resize: { _ in })
        session.updateViewport(VTTerminalSessionMetrics(
            width: 390, height: 480, cellWidth: 10, cellHeight: 20, scale: 2
        ))
        _ = try await session.snapshot()
        let committed = expectation(description: "new readiness observes completed delivery")
        let probe = BellProbe(queue: queue, committed: committed)
        session.eventDelegate = probe
        queue.setReceiver(session)
        queue.setReady(true)
        queue.enqueue(Data("hello\u{7}".utf8))
        await fulfillment(of: [committed], timeout: 5)
        let frame = try await session.snapshot()
        XCTAssertEqual(frame.line(0).trimmingCharacters(in: .whitespaces), "hello")
        XCTAssertEqual(probe.rings, 1)
        session.finish()
    }
}
