import XCTest
@testable import GhosttyVT
@testable import GhosttyTerminal

@MainActor
final class VTScrollbackCompressionTests: XCTestCase {
    private func makeTerminal() throws -> VTTerminal {
        try VTTerminal(layout: VTLayout(generation: 1, width: 800, height: 480,
            cellWidth: 10, cellHeight: 20, scale: 1, padding: 0))
    }

    private var history: Data {
        Data((0..<8_000).map { "\u{1B}[32mrow-\($0) café 界 👩🏽‍💻\u{1B}[0m\r\n" }.joined().utf8)
    }

    private func waitForCompression(_ terminal: VTTerminal) async throws {
        try await waitUntil("bounded compression pass", timeout: 10) {
            let steps = await terminal.compressionStepsForTesting
            let scheduled = await terminal.compressionScheduledForTesting
            return steps > 0 && !scheduled
        }
        let usage = try await terminal.scrollbackMemoryForTesting()
        XCTAssertTrue(usage.supported, "Darwin should support native page reclamation")
        XCTAssertGreaterThan(usage.compressedPages, 0)
    }

    func testCompressionPreservesHistoryStylesImagesAndParserContinuation() async throws {
        let terminal = try makeTerminal()
        _ = try await terminal.ingest(history)
        let image = TerminalGraphicsMemoryWorkload(side: 16)
        _ = try await terminal.ingest(image.payload(0))
        try await terminal.selectAll()
        let expected = try await terminal.selectedText()
        _ = try await terminal.clearSelection()
        let before = try await terminal.snapshot()
        let memoryBefore = try await terminal.scrollbackMemoryForTesting()
        // A split control sequence must resume after maintenance unchanged.
        _ = try await terminal.ingest(Data("\u{1B}[".utf8))
        let revisionBefore = try await terminal.snapshot().revision
        await terminal.scheduleScrollbackCompression()
        try await waitForCompression(terminal)
        let memoryAfter = try await terminal.scrollbackMemoryForTesting()
        XCTAssertLessThan(memoryAfter.residentBytes, memoryBefore.residentBytes)
        let after = try await terminal.snapshot()
        XCTAssertEqual(after.revision, revisionBefore, "Storage maintenance must not produce frames")
        XCTAssertEqual(after.scrollbackRows, before.scrollbackRows)
        XCTAssertEqual(after.cells, before.cells)
        XCTAssertEqual(after.graphics, before.graphics)
        XCTAssertFalse(after.graphics.placements.isEmpty)
        let reply = try await terminal.ingest(Data("6n".utf8))
        XCTAssertFalse(reply.replies.isEmpty, "The parser must retain a pending CSI across compression")
        try await terminal.selectAll()
        let actual = try await terminal.selectedText()
        XCTAssertEqual(actual, expected, "Copying all history restores compressed pages losslessly")
        _ = try await terminal.clearSelection()
        try await terminal.scroll(rows: -100_000)
        let oldest = try await terminal.snapshot()
        XCTAssertTrue(oldest.line(0).hasPrefix("row-0 café"))
        let resized = try VTLayout(generation: 2, width: 600, height: 480,
            cellWidth: 10, cellHeight: 20, scale: 1, padding: 0)
        _ = try await terminal.resize(to: resized)
        try await terminal.selectAll()
        let reflowed = try await terminal.selectedText()
        XCTAssertEqual(reflowed, expected)
        _ = try await terminal.retire()
    }

    func testActivityPostponesCompressionAndCompletedPassDoesNotPoll() async throws {
        let terminal = try makeTerminal()
        _ = try await terminal.ingest(history)
        await terminal.scheduleScrollbackCompression()
        for _ in 0..<8 {
            _ = try await terminal.ingest(Data("busy\r\n".utf8))
            await terminal.scheduleScrollbackCompression()
            let steps = await terminal.compressionStepsForTesting
            XCTAssertEqual(steps, 0, "Do not compress an actively changing terminal")
            try await Task.sleep(for: .milliseconds(200))
        }
        try await waitForCompression(terminal)
        let steps = await terminal.compressionStepsForTesting
        for _ in 0..<4 { await terminal.scheduleScrollbackCompression() }
        let scheduled = await terminal.compressionScheduledForTesting
        XCTAssertFalse(scheduled, "Unchanged activity must not restart a completed pass")
        try await Task.sleep(for: .milliseconds(100))
        let laterSteps = await terminal.compressionStepsForTesting
        XCTAssertEqual(steps, laterSteps)
        _ = try await terminal.retire()
    }

    func testSessionAutomaticallyCompressesAndRestartsAfterHistoryAccess() async throws {
        let session = VTTerminalSession(write: { _ in }, resize: { _ in })
        defer { session.finish() }
        session.updateViewport(.init(width: 800, height: 480, cellWidth: 10, cellHeight: 20, scale: 1))
        _ = try await session.snapshot()
        session.receive(history)
        let query = try XCTUnwrap(session.enqueueInputQuery { $0 })
        let terminal = try await query.value
        try await waitForCompression(terminal)
        let steps = await terminal.compressionStepsForTesting
        let access = try XCTUnwrap(session.enqueueInputQuery {
            try await $0.selectAll()
            let text = try await $0.selectedText()
            _ = try await $0.clearSelection()
            return text
        })
        let text = try await access.value
        XCTAssertTrue(text.hasPrefix("row-0 café"))
        // Native copy uses scratch decoding and can leave pages compressed.
        // Scrolling into history, then away, makes a restored page cold again.
        let scroll = try XCTUnwrap(session.enqueueInputQuery {
            try await $0.scroll(rows: -100_000)
            _ = try await $0.snapshot()
            try await $0.scroll(rows: 100_000)
        })
        try await scroll.value
        try await waitUntil("compression after restored history", timeout: 10) {
            let laterSteps = await terminal.compressionStepsForTesting
            let scheduled = await terminal.compressionScheduledForTesting
            return laterSteps > steps && !scheduled
        }
        let usage = try await terminal.scrollbackMemoryForTesting()
        XCTAssertGreaterThan(usage.compressedPages, 0)
    }

    func testRetirementAndFailedHandlesStopMaintenance() async throws {
        let terminal = try makeTerminal()
        _ = try await terminal.ingest(history)
        await terminal.scheduleScrollbackCompression()
        try await terminal.markFailedForTesting()
        await terminal.scheduleScrollbackCompression()
        let failedScheduled = await terminal.compressionScheduledForTesting
        XCTAssertFalse(failedScheduled)
        _ = try await terminal.retire()
        await terminal.scheduleScrollbackCompression()
        let retiredScheduled = await terminal.compressionScheduledForTesting
        XCTAssertFalse(retiredScheduled)
        let steps = await terminal.compressionStepsForTesting
        XCTAssertEqual(steps, 0)
    }

    func testPendingMaintenanceDoesNotRetainTerminal() async throws {
        weak var released: VTTerminal?
        do {
            let terminal = try makeTerminal()
            released = terminal
            _ = try await terminal.ingest(history)
            await terminal.scheduleScrollbackCompression()
        }
        try await waitUntil("idle terminal deallocation") { released == nil }
    }
}
