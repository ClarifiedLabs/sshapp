import XCTest
@testable import GhosttyVT

final class VTTerminalRetireTests: XCTestCase {
    /// Regression: with a remote pointer press active, a failed handle made
    /// retire() throw from the pointer cancel before its cleanup was set up,
    /// leaking the native handle and preventing Reset from replacing it.
    func testRetireDestroysAFailedHandleWithAnActiveRemotePointer() async throws {
        let terminal = try VTTerminal(layout: VTLayout(generation: 1, width: 200, height: 100,
            cellWidth: 10, cellHeight: 20, scale: 1, padding: 0))
        _ = try await terminal.ingest(Data("\u{1B}[?1000h\u{1B}[?1006h".utf8))
        let frame = try await terminal.snapshot()
        let press = VTPointerRequest(id: 1, terminalID: frame.terminalID, generation: frame.layout.generation,
            revision: frame.revision, phase: .press, source: .pointer, point: CGPoint(x: 15, y: 10), time: 1)
        let pressed = try await terminal.pointer(press)
        XCTAssertTrue(pressed.active, "The press must be routed to remote mouse tracking")

        try await terminal.markFailedForTesting()
        _ = try await terminal.retire()

        do {
            _ = try await terminal.snapshot()
            XCTFail("A retired terminal must reject use")
        } catch {
            XCTAssertEqual(error as? VTError, .retired, "The failed handle must have been destroyed")
        }
    }

    /// Regression: ingest threw from post-write steps after the parser had
    /// consumed the bytes, so the delivery queue re-fed and duplicated them.
    /// A throw must mean unconsumed; a post-write failure surfaces next call.
    func testIngestReportsBytesConsumedWhenPostWriteStepsFail() async throws {
        let terminal = try VTTerminal(layout: VTLayout(generation: 1, width: 200, height: 100,
            cellWidth: 10, cellHeight: 20, scale: 1, padding: 0))
        await terminal.setFailAfterIngestWriteForTesting(true)
        let output = try await terminal.ingest(Data("ONCE\u{1B}[6n\u{07}".utf8))
        XCTAssertTrue(output.replies.isEmpty)
        XCTAssertTrue(output.events.isEmpty)
        await terminal.setFailAfterIngestWriteForTesting(false)
        do {
            _ = try await terminal.ingest(Data("ONCE".utf8))
            XCTFail("A poisoned handle must reject the next admission")
        } catch {
            XCTAssertEqual(error as? VTError, .native(-2), "GHOSTTY_INVALID_VALUE")
        }
        _ = try await terminal.retire()
    }
}
