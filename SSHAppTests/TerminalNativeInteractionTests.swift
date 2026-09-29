#if canImport(UIKit) && !targetEnvironment(macCatalyst)
import UIKit
import XCTest
import GhosttyVT
@testable import GhosttyTerminal

@MainActor
final class TerminalNativeInteractionTests: XCTestCase {
    func testCancelledDragLeaseDoesNotRequireARenderToRecover() {
        var lease = TerminalInteractionLease<Int>()
        XCTAssertTrue(lease.admit(1))
        lease.cancel() // resize/background/detach discards presentation
        XCTAssertNil(lease.current)
        XCTAssertFalse(lease.admit(2), "one native operation remains in flight")
        XCTAssertTrue(lease.complete(1)) // native completion, no rendered frame
        XCTAssertTrue(lease.admit(2))
        XCTAssertFalse(lease.complete(1), "late completion cannot release a newer drag")
        XCTAssertEqual(lease.current, 2)
        XCTAssertTrue(lease.complete(2))
        XCTAssertTrue(lease.admit(3))
    }

    func testAutoscrollHasMiddleDeadZoneAndCapsOutsideViewport() throws {
        let layout = try VTLayout(generation: 1, width: 320, height: 200,
            cellWidth: 8, cellHeight: 16, scale: 2)
        func rows(_ y: Double, up: Bool = true, down: Bool = true) -> Int {
            TerminalSelectionAutoscroll.rows(at: CGPoint(x: 20, y: y), layout: layout,
                canScrollUp: up, canScrollDown: down)
        }
        XCTAssertEqual(rows(100), 0)
        XCTAssertEqual(rows(-1000), -4)
        XCTAssertEqual(rows(1000), 4)
        XCTAssertEqual(rows(-1000, up: false), 0)
        XCTAssertEqual(rows(1000, down: false), 0)
        XCTAssertEqual(rows(.nan), 0)
    }

    func testSmallViewportRetainsDeadZone() throws {
        let layout = try VTLayout(generation: 2, width: 40, height: 40,
            cellWidth: 8, cellHeight: 16, scale: 1)
        XCTAssertEqual(TerminalSelectionAutoscroll.rows(at: CGPoint(x: 16, y: 16),
            layout: layout, canScrollUp: true, canScrollDown: true), 0)
    }

    func testWordPointerContinuationPreservesNativeGestureIdentity() {
        let press = VTPointerRequest(id: 42, terminalID: UUID(), generation: 7, revision: 9,
            phase: .press, source: .touch, point: CGPoint(x: 35, y: 10),
            modifiers: .shift, time: 100, selectionBehavior: .word)
        for phase: VTPointerRequest.Phase in [.move, .autoscroll, .release, .cancel] {
            let next = press.continuing(phase: phase, point: CGPoint(x: 15, y: 30), time: 200)
            XCTAssertEqual(next.id, press.id)
            XCTAssertEqual(next.terminalID, press.terminalID)
            XCTAssertEqual(next.generation, press.generation)
            XCTAssertEqual(next.revision, press.revision)
            XCTAssertEqual(next.source, .touch)
            XCTAssertEqual(next.selectionBehavior, .word)
            XCTAssertEqual(next.phase, phase)
            XCTAssertEqual(next.modifiers, .shift)
            XCTAssertEqual(next.point, CGPoint(x: 15, y: 30))
            XCTAssertEqual(next.time, 200)
        }
        let keyUp = press.continuing(phase: .move, modifiers: [])
        XCTAssertTrue(keyUp.modifiers.isEmpty)
        XCTAssertEqual(keyUp.selectionBehavior, .word)
    }

    func testWordPointerContinuationReversesAcrossWrappedRows() async throws {
        let terminal = try VTTerminal(layout: VTLayout(generation: 1, width: 100, height: 100,
            cellWidth: 10, cellHeight: 20, scale: 1, padding: 0))
        _ = try await terminal.ingest(Data("alpha beta gamma".utf8))
        let frame = try await terminal.snapshot()
        let press = VTPointerRequest(id: 1, terminalID: frame.terminalID, generation: frame.layout.generation,
            revision: frame.revision, phase: .press, source: .touch,
            point: CGPoint(x: 75, y: 10), time: 1, selectionBehavior: .word)
        let response = try await terminal.pointer(press)
        XCTAssertTrue(response.localSelection)
        _ = try await terminal.pointer(press.continuing(phase: .move, point: CGPoint(x: 35, y: 30)))
        let forward = try await terminal.selectedText()
        XCTAssertEqual(forward, "beta gamma")
        // Final release position must reach native selection even when the
        // preceding intermediate move was coalesced by UIKit admission.
        _ = try await terminal.pointer(press.continuing(phase: .release, point: CGPoint(x: 15, y: 10)))
        let reverse = try await terminal.selectedText()
        XCTAssertEqual(reverse, "alpha beta")
        _ = try await terminal.retire()
    }

    func testWordPointerCaptureAndShiftOverrideAreNativeDecisions() async throws {
        let terminal = try VTTerminal(layout: VTLayout(generation: 1, width: 200, height: 100,
            cellWidth: 10, cellHeight: 20, scale: 1, padding: 0))
        _ = try await terminal.ingest(Data("alpha beta\u{1B}[?1000h\u{1B}[?1006h".utf8))
        let frame = try await terminal.snapshot()
        let captured = VTPointerRequest(id: 1, terminalID: frame.terminalID, generation: frame.layout.generation,
            revision: frame.revision, phase: .press, source: .touch,
            point: CGPoint(x: 15, y: 10), time: 1, selectionBehavior: .word)
        let remote = try await terminal.pointer(captured)
        XCTAssertTrue(remote.active)
        XCTAssertFalse(remote.localSelection)
        XCTAssertFalse(remote.bytes.isEmpty)
        let cancelled = try await terminal.pointer(captured.continuing(phase: .cancel))
        XCTAssertFalse(cancelled.bytes.isEmpty)
        let local = VTPointerRequest(id: 2, terminalID: frame.terminalID, generation: frame.layout.generation,
            revision: frame.revision, phase: .press, source: .touch,
            point: CGPoint(x: 15, y: 10), modifiers: .shift, time: 2, selectionBehavior: .word)
        let selected = try await terminal.pointer(local)
        XCTAssertTrue(selected.localSelection)
        XCTAssertTrue(selected.bytes.isEmpty)
        _ = try await terminal.pointer(local.continuing(phase: .release))
        let text = try await terminal.selectedText()
        XCTAssertEqual(text, "alpha")
        _ = try await terminal.retire()
    }

    func testCrossingSelectionRetainsInclusiveFixedNativeEndpoint() async throws {
        let terminal = try VTTerminal(layout: VTLayout(generation: 1, width: 400, height: 100,
            cellWidth: 10, cellHeight: 20, scale: 1, padding: 0))
        _ = try await terminal.ingest(Data("ALPHA BRAVO CHARLIE DELTA ECHO".utf8))
        try await terminal.select(.word, at: .init(column: 8, row: 0), generation: 1)
        try await terminal.moveSelection(start: false, to: .init(column: 18, row: 0), generation: 1)
        let expanded = try await terminal.snapshot()
        XCTAssertEqual(expanded.selectedText(), "BRAVO CHARLIE")
        try await terminal.moveSelection(start: true, to: .init(column: 24, row: 0), generation: 1)
        let crossed = try await terminal.snapshot()
        let selection = try XCTUnwrap(crossed.selection)
        XCTAssertTrue(selection.reversed)
        XCTAssertEqual(selection.endEndpoint, expanded.selection?.endEndpoint,
            "The fixed endpoint stays on CHARLIE's final E, not the following space")
        XCTAssertEqual(selection.startEndpoint.position, .init(column: 24, row: 0))
        let text = try await terminal.selectedText()
        XCTAssertEqual(text, "E DELTA")
        XCTAssertEqual(crossed.selectedText(), text)
        _ = try await terminal.retire()
    }

    func testHoverCancellationDoesNotInventPointerExit() {
        XCTAssertNil(UITerminalView.pointerHoverPosition(for: .cancelled, location: .zero))
        XCTAssertNil(UITerminalView.pointerHoverPosition(for: .failed, location: .zero))
        XCTAssertEqual(UITerminalView.pointerHoverPosition(for: .ended, location: .zero), CGPoint(x: -1, y: -1))
    }
}
#endif
