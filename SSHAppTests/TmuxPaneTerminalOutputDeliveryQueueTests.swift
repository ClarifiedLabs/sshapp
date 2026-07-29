import XCTest
@testable import SSHApp

final class TmuxPaneTerminalOutputDeliveryQueueTests: XCTestCase {
    private final class RecordingReceiver: TerminalOutputReceiver, @unchecked Sendable {
        private let lock = NSLock()
        private let receiveSemaphore = DispatchSemaphore(value: 0)
        private let releaseSemaphore = DispatchSemaphore(value: 0)
        private var remainingBlockedReceives: Int
        private var receivedValues: [Data] = []

        init(blockedReceives: Int = 0) {
            remainingBlockedReceives = blockedReceives
        }

        var received: [Data] {
            lock.withLock { receivedValues }
        }

        func receive(_ data: Data) {
            let shouldBlock = lock.withLock { () -> Bool in
                receivedValues.append(data)
                guard remainingBlockedReceives > 0 else { return false }
                remainingBlockedReceives -= 1
                return true
            }

            receiveSemaphore.signal()

            if shouldBlock {
                releaseSemaphore.wait()
            }
        }

        func waitForReceive(timeout: TimeInterval = 1.0) -> DispatchTimeoutResult {
            receiveSemaphore.wait(timeout: .now() + timeout)
        }

        func releaseBlockedReceive() {
            releaseSemaphore.signal()
        }
    }

    func testEnqueueReturnsWhileReceiverIsBlocked() {
        let queue = TmuxPaneTerminalOutputDeliveryQueue(label: "dev.sshapp.tests.blocked-output")
        let receiver = RecordingReceiver(blockedReceives: 1)
        let first = Data("first".utf8)
        let second = Data("second".utf8)

        queue.setReceiver(receiver)
        queue.setSurfaceAttached(true)
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

    func testOutputBuffersUntilSurfaceIsAttached() {
        let queue = TmuxPaneTerminalOutputDeliveryQueue(label: "dev.sshapp.tests.surface-buffer")
        let receiver = RecordingReceiver()
        let output = Data("prompt".utf8)

        queue.setReceiver(receiver)
        queue.enqueue(output)

        XCTAssertEqual(receiver.waitForReceive(timeout: 0.1), .timedOut)

        queue.setSurfaceAttached(true)

        XCTAssertEqual(receiver.waitForReceive(), .success)
        XCTAssertEqual(receiver.received, [output])
    }

    /// Regression: duplicate lifecycle notifications used to advance the queue
    /// generation while leaving the old drain marked as scheduled. The stale
    /// drain then exited and no future task owned the buffered snapshot.
    func testRepeatedSurfaceAttachedNotificationDoesNotStrandOutput() {
        let queue = TmuxPaneTerminalOutputDeliveryQueue(label: "dev.sshapp.tests.repeated-attach")
        let receiver = RecordingReceiver()
        let output = Data("restored history".utf8)

        queue.setReceiver(receiver)
        queue.enqueue(output)
        queue.setSurfaceAttached(true)
        queue.setSurfaceAttached(true)

        XCTAssertEqual(receiver.waitForReceive(), .success)
        XCTAssertEqual(receiver.received, [output])
    }

    /// A drain already inside the old receiver must not clear the scheduled
    /// marker for a replacement receiver after the surface generation changes.
    func testStaleDrainCannotCancelReplacementGenerationDrain() {
        let queue = TmuxPaneTerminalOutputDeliveryQueue(label: "dev.sshapp.tests.replacement-generation")
        let oldReceiver = RecordingReceiver(blockedReceives: 1)
        let newReceiver = RecordingReceiver()
        let oldOutput = Data("old surface".utf8)
        let newOutput = Data("new surface".utf8)

        queue.setReceiver(oldReceiver)
        queue.setSurfaceAttached(true)
        queue.enqueue(oldOutput)
        XCTAssertEqual(oldReceiver.waitForReceive(), .success)

        queue.setSurfaceAttached(false)
        queue.resetPendingOutput()
        queue.setReceiver(newReceiver)
        queue.setSurfaceAttached(true)
        queue.enqueue(newOutput)

        oldReceiver.releaseBlockedReceive()

        XCTAssertEqual(newReceiver.waitForReceive(), .success)
        XCTAssertEqual(oldReceiver.received, [oldOutput])
        XCTAssertEqual(newReceiver.received, [newOutput])
    }
}
