import XCTest
import GhosttyVT

/// Exercises the public production engine API with a plain (non-testable)
/// import, so any API the production UI needs but is not public fails here.
final class VTEnginePublicAPITests: XCTestCase {
    private func makeTerminal() throws -> VTTerminal {
        let layout = try VTLayout(
            generation: 1,
            width: 390,
            height: 480,
            cellWidth: 10,
            cellHeight: 20,
            scale: 2
        )
        return try VTTerminal(layout: layout)
    }

    func testPublicReceiveSnapshotFlow() async throws {
        let terminal = try makeTerminal()
        let output = try await terminal.ingest(Data("hello".utf8))
        XCTAssertTrue(output.replies.isEmpty)
        XCTAssertTrue(output.events.isEmpty)
        let frame = try await terminal.snapshot()
        XCTAssertEqual(frame.layout.columns, 37)
        XCTAssertTrue(frame.line(0).hasPrefix("hello"))
        let selection = try await terminal.selectedText()
        XCTAssertEqual(selection, "")
        _ = try await terminal.retire()
    }

    func testPublicResizeChangesGrid() async throws {
        let terminal = try makeTerminal()
        let next = try VTLayout(
            generation: 2,
            width: 390,
            height: 480,
            cellWidth: 20,
            cellHeight: 20,
            scale: 2
        )
        _ = try await terminal.resize(to: next)
        let frame = try await terminal.snapshot()
        XCTAssertEqual(frame.layout.columns, 18)
        _ = try await terminal.retire()
    }

    func testPublicFocusInputEncodesOnlyWhenReportingIsEnabled() async throws {
        let terminal = try makeTerminal()
        let disabled = try await terminal.input(.focus(true))
        XCTAssertEqual(disabled, Data())
        _ = try await terminal.ingest(Data("\u{1B}[?1004h".utf8))
        let focusIn = try await terminal.input(.focus(true))
        let focusOut = try await terminal.input(.focus(false))
        XCTAssertEqual(focusIn, Data("\u{1B}[I".utf8))
        XCTAssertEqual(focusOut, Data("\u{1B}[O".utf8))
        _ = try await terminal.retire()
    }
    func testPublicWordDragUsesNativeWholeWordBoundsAndOwnedEndpoints() async throws {
        let terminal = try VTTerminal(layout: VTLayout(generation: 1, width: 100, height: 100,
            cellWidth: 10, cellHeight: 20, scale: 1, padding: 0))
        _ = try await terminal.ingest(Data("alpha beta gamma".utf8))
        let frame = try await terminal.snapshot()
        func request(_ phase: VTPointerRequest.Phase, column: Int, row: Int = 0) -> VTPointerRequest {
            .init(id: 1, terminalID: frame.terminalID, generation: frame.layout.generation,
                  revision: frame.revision, phase: phase, source: .touch,
                  point: CGPoint(x: column * 10 + 5, y: row * 20 + 10), time: 1,
                  selectionBehavior: .word)
        }
        let press = try await terminal.pointer(request(.press, column: 7))
        XCTAssertTrue(press.localSelection)
        _ = try await terminal.pointer(request(.move, column: 3, row: 1))
        let forward = try await terminal.selectedText()
        XCTAssertEqual(forward, "beta gamma")
        _ = try await terminal.pointer(request(.move, column: 1))
        let reverse = try await terminal.selectedText()
        XCTAssertEqual(reverse, "alpha beta")
        _ = try await terminal.pointer(request(.release, column: 1))
        let selected = try await terminal.snapshot()
        let endpoints = try XCTUnwrap(selected.selection)
        XCTAssertTrue(endpoints.startEndpoint.isVisible)
        XCTAssertTrue(endpoints.endEndpoint.isVisible)
        XCTAssertNotEqual(endpoints.startEndpoint.position, endpoints.endEndpoint.position)
        XCTAssertGreaterThan(selected.viewport.rows, 0)
        _ = try await terminal.retire()
        XCTAssertEqual(selected.terminalID, frame.terminalID)
        XCTAssertNotNil(selected.selection)
    }

    func testPublicLinkHitOwnsRevisionBoundHighlight() async throws {
        let terminal = try makeTerminal()
        _ = try await terminal.ingest(Data("\u{1B}]8;;https://example.com\u{1B}\\link\u{1B}]8;;\u{1B}\\".utf8))
        let frame = try await terminal.snapshot()
        let hit = try await terminal.linkHit(at: .init(column: 1, row: 0), in: frame, geometry: true)
        let owned = try XCTUnwrap(hit)
        XCTAssertEqual(owned.link.uri, "https://example.com")
        XCTAssertTrue(owned.link.explicit)
        XCTAssertTrue(owned.highlight.matches(frame))
        XCTAssertTrue(owned.highlight.contains(1))
        _ = try await terminal.retire()
        XCTAssertFalse(owned.highlight.ranges.isEmpty)
    }

    /// Regression: native line selection trims whitespace, so a command-click
    /// on indentation or trailing blanks lay outside the line. The prefix then
    /// opened an adjacent URL, or produced an invalid offset that threw.
    func testLinkLookupOnWhitespaceOutsideTrimmedLineIsNoHit() async throws {
        let terminal = try makeTerminal()
        _ = try await terminal.ingest(Data("    https://example.com/a".utf8))
        let frame = try await terminal.snapshot()
        for column in [0, 1, 3, 25, 30] {
            let link = try await terminal.link(at: .init(column: column, row: 0), in: frame)
            XCTAssertNil(link, "column \(column)")
            let hit = try await terminal.linkHit(at: .init(column: column, row: 0), in: frame, geometry: true)
            XCTAssertNil(hit, "column \(column)")
        }
        let link = try await terminal.link(at: .init(column: 8, row: 0), in: frame)
        XCTAssertEqual(link?.uri, "https://example.com/a")
        let blank = try await terminal.link(at: .init(column: 4, row: 3), in: frame)
        XCTAssertNil(blank)
        _ = try await terminal.retire()
    }

}
