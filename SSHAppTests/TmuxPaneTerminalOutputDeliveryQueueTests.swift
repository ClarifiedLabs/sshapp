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
}
