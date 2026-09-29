import Foundation

/// Test-only polling adapter. Callback time, not observer resumption, owns the deadline.
@MainActor
enum TerminalInputByteCollector {
    enum Outcome: String, Encodable {
        case matched, missingBytes, excessBytes, mismatchedBytes, lateCallback
    }

    /// Scalar-only evidence: never retain or print terminal input/output text.
    struct Record: Encodable {
        let startTime: Double
        let insertReturnTime: Double
        let deadline: Double
        let firstPollTime: Double
        let finalPollTime: Double
        let maximumPollGap: Double
        let pollCount: Int
        let expectedByteCount: Int
        let byteCount: Int
        let callbackTime: Double
        let outcome: Outcome
    }

    static func collect(
        expected: Data,
        startTime: Double,
        insertReturnTime: Double,
        clock: @MainActor () -> Double,
        suspend: @MainActor () async throws -> Void,
        read: @MainActor () -> (Data, Double)
    ) async throws -> Record {
        let deadline = startTime + 5
        var bytes = Data()
        var callbackTime = 0.0
        var firstPollTime = 0.0, previousPollTime = startTime, maximumPollGap = 0.0
        var pollCount = 0
        while true {
            try Task.checkCancellation()
            let pollTime = clock()
            if pollCount == 0 { firstPollTime = pollTime }
            maximumPollGap = max(maximumPollGap, pollTime - previousPollTime)
            previousPollTime = pollTime
            pollCount += 1
            // Always drain before deciding timeout, including a first/last poll
            // resumed after the deadline. take() retains its old timestamp when
            // empty, so only nonempty chunks may advance the callback boundary.
            let chunk = read()
            bytes.append(chunk.0)
            if !chunk.0.isEmpty { callbackTime = chunk.1 }
            if bytes.count >= expected.count || pollTime >= deadline {
                let outcome: Outcome
                if bytes.count > expected.count { outcome = .excessBytes }
                else if bytes.count < expected.count { outcome = .missingBytes }
                else if bytes != expected { outcome = .mismatchedBytes }
                else if callbackTime >= deadline { outcome = .lateCallback }
                else { outcome = .matched }
                return Record(startTime: startTime, insertReturnTime: insertReturnTime,
                    deadline: deadline, firstPollTime: firstPollTime, finalPollTime: pollTime,
                    maximumPollGap: maximumPollGap, pollCount: pollCount,
                    expectedByteCount: expected.count, byteCount: bytes.count,
                    callbackTime: callbackTime, outcome: outcome)
            }
            try await suspend()
        }
    }
}
