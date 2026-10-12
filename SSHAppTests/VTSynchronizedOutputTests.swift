import XCTest
@testable import GhosttyVT
@testable import GhosttyTerminal

@MainActor
final class VTSynchronizedOutputTests: XCTestCase {
    private let begin = "\u{1B}[?2026h"
    private let end = "\u{1B}[?2026l"

    private func terminal() throws -> VTTerminal {
        try VTTerminal(layout: VTLayout(generation: 1, width: 400, height: 200,
            cellWidth: 10, cellHeight: 20, scale: 1, padding: 0))
    }

    func testBoundaryCapturedInsideWriteAndRepliesContinue() async throws {
        let terminal = try terminal()
        _ = try await terminal.ingest(Data("old".utf8))
        _ = try await terminal.snapshot()
        let output = try await terminal.ingest(Data(("\rready" + begin + "\rpartial\u{1B}[6n\u{7}").utf8))
        XCTAssertFalse(output.replies.isEmpty)
        XCTAssertEqual(output.events, [.bell])
        let held = try await terminal.snapshot()
        XCTAssertTrue(held.renderHeld)
        XCTAssertTrue(held.line(0).hasPrefix("ready"), "Capture the boundary, not the last published frame")
        _ = try await terminal.ingest(Data("more".utf8))
        let repeated = try await terminal.snapshot()
        XCTAssertEqual(repeated, held)
        _ = try await terminal.ingest(Data(end.utf8))
        let released = try await terminal.snapshot()
        XCTAssertFalse(released.renderHeld)
        XCTAssertTrue(released.line(0).hasPrefix("partialmore"))
        _ = try await terminal.retire()
    }

    func testAdjacentHoldsAndSplitSequences() async throws {
        let terminal = try terminal()
        _ = try await terminal.ingest(Data(("first" + begin + "\rsecond" + end + begin + "\rthird").utf8))
        let held = try await terminal.snapshot()
        XCTAssertTrue(held.line(0).hasPrefix("second"))
        _ = try await terminal.ingest(Data("\u{1B}[?2026".utf8))
        let split = try await terminal.snapshot()
        XCTAssertEqual(split, held)
        _ = try await terminal.ingest(Data("l".utf8))
        let released = try await terminal.snapshot()
        XCTAssertTrue(released.line(0).hasPrefix("third"))
        _ = try await terminal.retire()
    }

    func testResetAndResizeReleaseHold() async throws {
        let terminal = try terminal()
        _ = try await terminal.ingest(Data(("old" + begin + "\rnew").utf8))
        _ = try await terminal.resize(to: VTLayout(generation: 2, width: 500, height: 200,
            cellWidth: 10, cellHeight: 20, scale: 1, padding: 0))
        let resized = try await terminal.snapshot()
        XCTAssertFalse(resized.renderHeld)
        XCTAssertEqual(resized.layout.columns, 50)
        _ = try await terminal.ingest(Data((begin + "hidden\u{1B}creset").utf8))
        let reset = try await terminal.snapshot()
        XCTAssertFalse(reset.renderHeld)
        XCTAssertTrue(reset.line(0).hasPrefix("reset"))
        _ = try await terminal.retire()
    }

    func testSessionTimeoutPublishesWithoutFurtherOutput() async throws {
        let session = VTTerminalSession(write: { _ in }, resize: { _ in })
        defer { session.finish() }
        session.updateViewport(.init(width: 400, height: 200, cellWidth: 10, cellHeight: 20, scale: 1))
        session.receive(Data(("before" + begin + "\rafter").utf8))
        let held = try await session.snapshot()
        XCTAssertTrue(held.renderHeld)
        var invalidations = 0
        session.onFramesAvailable = { invalidations += 1 }
        try await waitUntil("render-hold timeout invalidation", timeout: 3) { invalidations > 0 }
        let released = try await session.snapshot()
        XCTAssertFalse(released.renderHeld)
        XCTAssertTrue(released.line(0).hasPrefix("after"))
    }

    func testPendingTimeoutDoesNotStarveNewerHold() async throws {
        let session = VTTerminalSession(write: { _ in }, resize: { _ in })
        defer { session.finish() }
        session.updateViewport(.init(width: 400, height: 200, cellWidth: 10, cellHeight: 20, scale: 1))
        session.receive(Data(("before" + begin).utf8))
        // The replacement hold starts while hold one's timeout task is still
        // pending, so its drain-end scheduling sees the occupied timer slot and
        // skips. The fired timer's own FIFO admission must leave the newer hold
        // with a live timeout: the drain re-schedules after every operation.
        session.receive(Data((end + "\rmid" + begin + "\rhidden").utf8))
        let held = try await session.snapshot()
        XCTAssertTrue(held.renderHeld)
        XCTAssertTrue(held.line(0).hasPrefix("mid"))
        var invalidations = 0
        session.onFramesAvailable = { invalidations += 1 }
        try await waitUntil("newer hold still times out without further output", timeout: 3) { invalidations > 0 }
        let released = try await session.snapshot()
        XCTAssertFalse(released.renderHeld)
        XCTAssertTrue(released.line(0).hasPrefix("hidden"))
    }

    func testRepeatedBeginDoesNotExtendDeadline() async throws {
        let terminal = try terminal()
        _ = try await terminal.ingest(Data(("before" + begin + "\rafter").utf8))
        try await Task.sleep(for: .milliseconds(600))
        _ = try await terminal.ingest(Data(begin.utf8))
        try await Task.sleep(for: .milliseconds(450))
        let released = try await terminal.snapshot()
        XCTAssertFalse(released.renderHeld)
        XCTAssertTrue(released.line(0).hasPrefix("after"))
        _ = try await terminal.retire()
    }

    func testHoldFloodFallsBackWithoutDroppingReplies() async throws {
        let terminal = try terminal()
        let flood = String(repeating: begin + end, count: 1000) + begin + "live\u{1B}[6n"
        let output = try await terminal.ingest(Data(flood.utf8))
        let frame = try await terminal.snapshot()
        XCTAssertFalse(frame.renderHeld)
        XCTAssertTrue(frame.line(0).hasPrefix("live"))
        XCTAssertFalse(output.replies.isEmpty)
        _ = try await terminal.retire()
    }

    func testOversizeBoundaryCopyFallsBackToLiveRendering() async throws {
        let terminal = try terminal()
        let payload = TerminalGraphicsMemoryWorkload(side: 1024).payload(0)
        _ = try await terminal.ingest(payload)
        let second = String(decoding: payload, as: UTF8.self).replacingOccurrences(of: "i=1", with: "i=2")
        _ = try await terminal.ingest(Data(second.utf8))
        _ = try await terminal.ingest(Data((begin + "live").utf8))
        let frame = try await terminal.snapshot()
        XCTAssertFalse(frame.renderHeld, "An aggregate >8 MiB boundary must not allocate an extra held copy")
        XCTAssertFalse(frame.graphics.placements.isEmpty, "Budget exhaustion must not discard native images")
        _ = try await terminal.retire()
    }

    func testCommandClickDuringHoldPreservesRemoteRelease() async throws {
        let terminal = try terminal()
        _ = try await terminal.ingest(Data("\u{1B}[?1000h\u{1B}[?1006h".utf8))
        var frame = try await terminal.snapshot()
        let press = VTPointerRequest(id: 1, terminalID: frame.terminalID, generation: frame.layout.generation,
            revision: frame.revision, phase: .press, source: .pointer, point: CGPoint(x: 5, y: 5), time: 1)
        _ = try await terminal.pointer(press)
        _ = try await terminal.ingest(Data(begin.utf8))
        frame = try await terminal.snapshot()
        let replacement = VTPointerRequest(id: 2, terminalID: frame.terminalID, generation: frame.layout.generation,
            revision: frame.revision, phase: .press, source: .pointer, point: CGPoint(x: 5, y: 5),
            modifiers: .command, time: 2)
        let response = try await terminal.pointer(replacement)
        XCTAssertTrue(String(decoding: response.bytes, as: UTF8.self).contains("m"), "Previous mouse release must reach transport")
        XCTAssertNil(response.link)
        _ = try await terminal.retire()
    }

    func testHeldImagesSurviveRemoteDeletion() async throws {
        let terminal = try terminal()
        _ = try await terminal.ingest(TerminalGraphicsMemoryWorkload(side: 16).payload(0))
        let before = try await terminal.snapshot()
        XCTAssertFalse(before.graphics.placements.isEmpty)
        _ = try await terminal.ingest(Data((begin + "\u{1B}_Ga=d,d=A\u{1B}\\").utf8))
        let held = try await terminal.snapshot()
        XCTAssertEqual(held.graphics, before.graphics)
        _ = try await terminal.ingest(Data(end.utf8))
        let released = try await terminal.snapshot()
        XCTAssertTrue(released.graphics.placements.isEmpty)
        _ = try await terminal.retire()
    }
}
