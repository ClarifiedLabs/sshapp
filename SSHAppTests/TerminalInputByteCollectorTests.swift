import XCTest

@MainActor
final class TerminalInputByteCollectorTests: XCTestCase {
    private let expected = Data([0x31, 0x32, 0x33, 0x34])

    func testOnTimeWriteSurvivesLateResumptionAndPreservesCallbackBoundary() async throws {
        var now = 10.1, reads = 0, suspensions = 0
        let result = try await TerminalInputByteCollector.collect(
            expected: expected, startTime: 10, insertReturnTime: 10.05,
            clock: { now }, suspend: { suspensions += 1; now = 16 }, read: {
                reads += 1
                return reads == 1 ? (Data(), 0) : (self.expected, 14.9)
            })
        XCTAssertEqual(result.outcome, .matched)
        XCTAssertEqual(result.callbackTime, 14.9)
        XCTAssertEqual(result.startTime, 10)
        XCTAssertEqual(result.insertReturnTime, 10.05)
        XCTAssertEqual(result.deadline, 15)
        XCTAssertEqual(result.firstPollTime, 10.1)
        XCTAssertEqual(result.finalPollTime, 16)
        XCTAssertEqual(result.maximumPollGap, 5.9, accuracy: 0.000_001)
        XCTAssertEqual(result.pollCount, 2)
        XCTAssertEqual(result.byteCount, expected.count)
        XCTAssertEqual(reads, 2, "Timeout must perform exactly one final drain")
        XCTAssertEqual(suspensions, 1)
    }

    func testAlreadyExpiredFirstPollStillDrainsOnTimeCallback() async throws {
        var reads = 0
        let result = try await TerminalInputByteCollector.collect(
            expected: expected, startTime: 10, insertReturnTime: 10.05,
            clock: { 16 }, suspend: { XCTFail("Must not suspend after timeout") }, read: {
                reads += 1
                return (self.expected, 14.9)
            })
        XCTAssertEqual(result.outcome, .matched)
        XCTAssertEqual(result.pollCount, 1)
        XCTAssertEqual(result.maximumPollGap, 6)
        XCTAssertEqual(reads, 1)
    }

    func testActualLateWriteAndExactDeadlineFail() async throws {
        for callback in [15.0, 15.1] {
            let result = try await TerminalInputByteCollector.collect(
                expected: expected, startTime: 10, insertReturnTime: 10.05,
                clock: { 16 }, suspend: { XCTFail("Must not suspend after timeout") },
                read: { (self.expected, callback) })
            XCTAssertEqual(result.outcome, .lateCallback)
            XCTAssertEqual(result.callbackTime, callback)
            XCTAssertEqual(result.byteCount, expected.count)
        }
    }

    func testEmptyOutputTimesOutWithFinalDrainAndIgnoresRetainedTimestamp() async throws {
        var now = 10.1, reads = 0
        let result = try await TerminalInputByteCollector.collect(
            expected: expected, startTime: 10, insertReturnTime: 10.05,
            clock: { now }, suspend: { now = 15 }, read: {
                reads += 1
                return (Data(), 9)
            })
        XCTAssertEqual(result.outcome, .missingBytes)
        XCTAssertEqual(result.byteCount, 0)
        XCTAssertEqual(result.callbackTime, 0)
        XCTAssertEqual(result.finalPollTime, 15)
        XCTAssertEqual(reads, 2)
    }

    func testMultipleChunksPreserveByteOrderAndLatestNonemptyCallback() async throws {
        var now = 10.1
        var chunks: [(Data, Double)] = [(Data([0x31, 0x32]), 10.05),
            (Data(), 10.05), (Data([0x33, 0x34]), 12.05)]
        let result = try await TerminalInputByteCollector.collect(
            expected: expected, startTime: 10, insertReturnTime: 10.05,
            clock: { now }, suspend: { now += 1 }, read: { chunks.removeFirst() })
        XCTAssertEqual(result.outcome, .matched)
        XCTAssertEqual(result.callbackTime, 12.05)
        XCTAssertEqual(result.pollCount, 3)
        XCTAssertEqual(result.byteCount, 4)
    }

    func testExcessAndWrongOrderAreDistinctFailures() async throws {
        for (bytes, outcome) in [(expected + Data([0x35]), TerminalInputByteCollector.Outcome.excessBytes),
                                 (Data(expected.reversed()), .mismatchedBytes)] {
            let result = try await TerminalInputByteCollector.collect(
                expected: expected, startTime: 10, insertReturnTime: 10.05,
                clock: { 10.1 }, suspend: { XCTFail("Complete bytes must not suspend") },
                read: { (bytes, 10.05) })
            XCTAssertEqual(result.outcome, outcome)
            XCTAssertEqual(result.byteCount, bytes.count)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
            XCTAssertEqual(Set(object.keys), Set(["startTime", "insertReturnTime", "deadline", "firstPollTime",
                "finalPollTime", "maximumPollGap", "pollCount", "expectedByteCount", "byteCount", "callbackTime", "outcome"]))
        }
    }

    func testPartialOutputIsMissingAndEmptyFinalDrainKeepsCallbackTime() async throws {
        var now = 10.1, reads = 0
        let result = try await TerminalInputByteCollector.collect(
            expected: expected, startTime: 10, insertReturnTime: 10.05,
            clock: { now }, suspend: { now = 16 }, read: {
                reads += 1
                return reads == 1 ? (Data([0x31]), 10.05) : (Data(), 99)
            })
        XCTAssertEqual(result.outcome, .missingBytes)
        XCTAssertEqual(result.byteCount, 1)
        XCTAssertEqual(result.callbackTime, 10.05)
        XCTAssertEqual(reads, 2)
    }

    func testCancellationFromSuspendPropagatesWithoutFurtherReads() async throws {
        var reads = 0
        do {
            _ = try await TerminalInputByteCollector.collect(
                expected: expected, startTime: 10, insertReturnTime: 10.05,
                clock: { 10.1 }, suspend: { throw CancellationError() }, read: {
                    reads += 1
                    return (Data(), 0)
                })
            XCTFail("Cancellation must propagate")
        } catch is CancellationError {
            XCTAssertEqual(reads, 1)
        }
    }

    func testTaskCancellationIsCheckedEvenWhenSuspendDoesNotThrow() async throws {
        var reads = 0
        let task = Task { @MainActor in
            try await TerminalInputByteCollector.collect(
                expected: self.expected, startTime: 10, insertReturnTime: 10.05,
                clock: { 10.1 }, suspend: {
                    withUnsafeCurrentTask { $0?.cancel() }
                }, read: {
                    reads += 1
                    return (Data(), 0)
                })
        }
        do {
            _ = try await task.value
            XCTFail("Cancellation must propagate before the next drain")
        } catch is CancellationError {
            XCTAssertEqual(reads, 1)
        }
    }
}
