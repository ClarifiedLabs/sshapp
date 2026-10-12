import XCTest
@testable import GhosttyVT
@testable import GhosttyTerminal

@MainActor
final class VTSearchTests: XCTestCase {
    private func terminal(columns: Int = 40) throws -> VTTerminal {
        try VTTerminal(layout: VTLayout(generation: 1, width: Double(columns * 10), height: 200,
            cellWidth: 10, cellHeight: 20, scale: 1, padding: 0))
    }

    private func complete(_ terminal: VTTerminal, owner: UUID, generation: UInt64 = 1) async throws -> VTSearchResult {
        for _ in 0..<1000 {
            let result = try await terminal.searchStep(owner: owner, generation: generation)
            if result.isComplete { return result }
            await Task.yield()
        }
        XCTFail("Search did not complete within bounded steps")
        throw VTError.invalidConfiguration
    }

    func testHistoryMatchesNavigateAndHighlightWithoutRemoteInput() async throws {
        let terminal = try terminal()
        let owner = UUID()
        _ = try await terminal.ingest(Data((0..<400).map { "row-\($0) needle\r\n" }.joined().utf8))
        _ = try await terminal.beginSearch(owner: owner)
        _ = try await terminal.search(query: "NEEDLE", owner: owner, generation: 1)
        let result = try await complete(terminal, owner: owner)
        XCTAssertEqual(result.totalMatches, 400)
        XCTAssertNotNil(result.selectedIndex)
        let copied = try await terminal.selectedText()
        XCTAssertEqual(copied, "needle")
        let next = try await terminal.searchStep(owner: owner, generation: 1, direction: 1)
        XCTAssertEqual(next.selectedIndex, (result.selectedIndex! + 1) % 400)
        let previous = try await terminal.searchStep(owner: owner, generation: 1, direction: -1)
        XCTAssertEqual(previous.selectedIndex, result.selectedIndex)
        try await terminal.endSearch(owner: owner)
        let cleared = try await terminal.selectedText()
        XCTAssertEqual(cleared, "")
        _ = try await terminal.retire()
    }

    func testUnicodeAndSoftWrappedMatch() async throws {
        let terminal = try terminal(columns: 8)
        let owner = UUID()
        _ = try await terminal.ingest(Data("12345café界hello".utf8))
        _ = try await terminal.beginSearch(owner: owner)
        _ = try await terminal.search(query: "café界hello", owner: owner, generation: 1)
        let result = try await complete(terminal, owner: owner)
        XCTAssertEqual(result.totalMatches, 1)
        let text = try await terminal.selectedText()
        XCTAssertEqual(text, "café界hello")
        _ = try await terminal.retire()
    }

    func testLiveOutputResizeAlternateScreenAndReset() async throws {
        let terminal = try terminal()
        let owner = UUID()
        _ = try await terminal.ingest(Data("match\r\n".utf8))
        _ = try await terminal.beginSearch(owner: owner)
        _ = try await terminal.search(query: "match", owner: owner, generation: 1)
        _ = try await terminal.ingest(Data("match\r\n\u{1B}[6n".utf8))
        var result = try await complete(terminal, owner: owner)
        XCTAssertEqual(result.totalMatches, 2)
        _ = try await terminal.resize(to: VTLayout(generation: 2, width: 300, height: 200,
            cellWidth: 10, cellHeight: 20, scale: 1, padding: 0))
        result = try await complete(terminal, owner: owner)
        XCTAssertEqual(result.totalMatches, 2)
        _ = try await terminal.ingest(Data("\u{1B}[?1049hmatch".utf8))
        result = try await complete(terminal, owner: owner)
        XCTAssertEqual(result.totalMatches, 1)
        _ = try await terminal.ingest(Data("\u{1B}[?1049l".utf8))
        result = try await complete(terminal, owner: owner)
        XCTAssertEqual(result.totalMatches, 2)
        _ = try await terminal.ingest(Data("\u{1B}cclean".utf8))
        result = try await complete(terminal, owner: owner)
        XCTAssertEqual(result.totalMatches, 0)
        XCTAssertNil(result.selectedIndex)
        _ = try await terminal.retire()
    }

    func testEmptyNoMatchAndUnchangedStepDoNotInvalidatePresentation() async throws {
        let terminal = try terminal()
        let owner = UUID()
        _ = try await terminal.ingest(Data("present".utf8))
        _ = try await terminal.beginSearch(owner: owner)
        _ = try await terminal.search(query: "present", owner: owner, generation: 1)
        _ = try await complete(terminal, owner: owner)
        let stable = try await terminal.searchStep(owner: owner, generation: 1)
        XCTAssertFalse(stable.presentationChanged)
        let none = try await terminal.search(query: "absent", owner: owner, generation: 2)
        XCTAssertEqual(none.totalMatches, 0)
        let empty = try await terminal.search(query: "", owner: owner, generation: 3)
        XCTAssertEqual(empty.totalMatches, 0)
        XCTAssertTrue(empty.isComplete)
        _ = try await terminal.retire()
    }

    func testStaleQueriesAndOldOwnerCleanupCannotMutateNewSearch() async throws {
        let session = VTTerminalSession(write: { _ in }, resize: { _ in })
        defer { session.finish() }
        session.updateViewport(.init(width: 400, height: 200, cellWidth: 10, cellHeight: 20, scale: 1))
        session.receive(Data("alpha beta".utf8))
        let old = UUID(), owner = UUID()
        try await session.enqueueBeginSearch(owner: old)?.value
        try await session.enqueueBeginSearch(owner: owner)?.value
        let current = try XCTUnwrap(session.enqueueSearch(query: "beta", owner: owner, generation: 2))
        _ = try await current.value
        try await session.enqueueEndSearch(owner: old)?.value
        for (who, generation) in [(old, UInt64(3)), (owner, UInt64(1))] {
            do {
                _ = try await session.enqueueSearch(query: "alpha", owner: who, generation: generation)?.value
                XCTFail("Stale search should be rejected")
            } catch { XCTAssertEqual(error as? VTError, .staleSearch) }
        }
        let text = await session.selectedText()
        XCTAssertEqual(text, "beta")
        let end = try XCTUnwrap(session.enqueueEndSearch(owner: owner))
        end.cancel()
        session.finish()
        try await end.value
        XCTAssertNil(session.enqueueBeginSearch(owner: UUID()))
    }

    func testLimitsFailSearchWithoutPoisoningTerminalAndAllowRecovery() async throws {
        let terminal = try terminal()
        let owner = UUID()
        _ = try await terminal.ingest(Data("match".utf8))
        _ = try await terminal.beginSearch(owner: owner)
        do {
            _ = try await terminal.search(query: String(repeating: "é", count: 2049), owner: owner, generation: 1)
            XCTFail("Oversize query accepted")
        } catch { XCTAssertEqual(error as? VTError, .searchQueryTooLong) }
        try await terminal.setSearchAllocationLimitForTesting(1)
        do {
            _ = try await terminal.search(query: "match", owner: owner, generation: 2)
            XCTFail("Search allocation should fail")
        } catch { XCTAssertNotNil(error as? VTError) }
        let reply = try await terminal.ingest(Data("\u{1B}[6n".utf8))
        XCTAssertFalse(reply.replies.isEmpty)
        try await terminal.setSearchAllocationLimitForTesting(0)
        _ = try await terminal.search(query: "match", owner: owner, generation: 3)
        let result = try await complete(terminal, owner: owner, generation: 3)
        XCTAssertEqual(result.totalMatches, 1)
        _ = try await terminal.retire()
    }
}
