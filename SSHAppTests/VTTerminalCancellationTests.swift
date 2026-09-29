import XCTest
@testable import GhosttyVT

final class VTTerminalCancellationTests: XCTestCase {
    /// Cancellation that arrives while the native write is executing must not
    /// truncate the write or drop its replies or events.
    func testCancellationArrivingMidWriteKeepsTheWholeWriteRepliesAndEvents() async throws {
        let terminal = try VTTerminal(layout: VTLayout(generation: 1, width: 200, height: 100,
            cellWidth: 10, cellHeight: 20, scale: 1, padding: 0))
        let canceller = MidWriteCanceller()
        await terminal.setDuringIngestForTesting { canceller.cancelFromInsideIngest() }
        let task = Task { try await terminal.ingest(Data("COMPLETE\u{1B}[6n\u{07}".utf8)) }
        let output = try await task.value
        XCTAssertTrue(canceller.observedCancellation, "Cancellation must reach the caller mid-write")
        XCTAssertEqual(output.replies, Data("\u{1B}[1;9R".utf8))
        XCTAssertEqual(output.events, [.bell])
        let frame = try await terminal.snapshot()
        XCTAssertTrue(frame.line(0).hasPrefix("COMPLETE"))
        _ = try await terminal.retire()
    }
}

/// Cancels the caller's own task from inside VTTerminal.ingest (the hook runs
/// on that task) and records whether it observed the cancellation there.
final class MidWriteCanceller: @unchecked Sendable {
    private let lock = NSLock()
    private var observed = false
    var observedCancellation: Bool { lock.withLock { observed } }

    func cancelFromInsideIngest() {
        withUnsafeCurrentTask { $0?.cancel() }
        let cancelled = Task.isCancelled
        lock.withLock { observed = cancelled }
    }
}
