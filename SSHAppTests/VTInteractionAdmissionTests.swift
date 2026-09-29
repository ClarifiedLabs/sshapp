import XCTest
import GhosttyVT
@testable import GhosttyTerminal

@MainActor
final class VTInteractionAdmissionTests: XCTestCase {
    private func make(_ writes: ByteRecorder = ByteRecorder()) async throws -> (VTTerminalSession, VTFrameValue) {
        let session = VTTerminalSession(write: { writes.append($0) }, resize: { _ in })
        session.updateViewport(.init(width: 200, height: 100, cellWidth: 10, cellHeight: 20, scale: 1, padding: 0))
        return (session, try await session.snapshot())
    }
    private func hold(_ session: VTTerminalSession) async -> OpenOnceGate {
        let gate = OpenOnceGate(), entered = expectation(description: "delivery entered")
        session.beforeDelivery = { entered.fulfill(); await gate.wait() }
        session.deliver(Data(), ifCurrent: { true }, completion: { _ in })
        await fulfillment(of: [entered], timeout: 5)
        session.beforeDelivery = nil
        return gate
    }
    private func pointer(_ frame: VTFrameValue, id: UInt64, phase: VTPointerRequest.Phase,
                         point: CGPoint = CGPoint(x: 15, y: 10), word: Bool = false) -> VTPointerRequest {
        .init(id: id, terminalID: frame.terminalID, generation: frame.layout.generation,
            revision: frame.revision, phase: phase, source: .touch, point: point,
            time: id, selectionBehavior: word ? .word : nil)
    }

    func testSessionIDsSurviveHostRecreationAndFenceOldCancellation() async throws {
        let (session, frame) = try await make()
        defer { session.finish() }
        session.receive(Data("alpha beta gamma".utf8))
        let oldID = try XCTUnwrap(session.allocatePointerID())
        _ = try await session.enqueuePointer(pointer(frame, id: oldID, phase: .press, word: true))?.value
        let newID = try XCTUnwrap(session.allocatePointerID()) // new UIKit controller
        XCTAssertGreaterThan(newID, oldID)
        _ = try await session.enqueuePointer(pointer(frame, id: newID, phase: .press, word: true))?.value
        _ = try await session.enqueuePointer(pointer(frame, id: oldID, phase: .cancel, word: true))?.value
        let moved = try await session.enqueuePointer(pointer(frame, id: newID, phase: .move,
            point: CGPoint(x: 75, y: 10), word: true))?.value
        XCTAssertEqual(moved?.localSelection, true)
        let text = await session.selectedText()
        XCTAssertEqual(text, "alpha beta")
        _ = try await session.enqueuePointer(pointer(frame, id: newID, phase: .release, word: true))?.value
    }

    func testAtomicTouchTapHonorsQueuedCaptureMode() async throws {
        let writes = ByteRecorder()
        let (session, staleFrame) = try await make(writes)
        defer { session.finish() }
        session.receive(Data("\u{1B}[?1000h\u{1B}[?1006h".utf8))
        let capturedID = try XCTUnwrap(session.allocatePointerID())
        let captured = try await session.enqueuePointer(pointer(staleFrame, id: capturedID, phase: .tap))?.value
        XCTAssertEqual(captured?.showKeyboard, false)
        XCTAssertEqual(writes.data, Data("\u{1B}[<0;2;1M\u{1B}[<0;2;1m".utf8))
        session.receive(Data("\u{1B}[?1000l".utf8))
        let localID = try XCTUnwrap(session.allocatePointerID())
        let local = try await session.enqueuePointer(pointer(staleFrame, id: localID, phase: .tap))?.value
        XCTAssertEqual(local?.showKeyboard, true)
    }

    func testTouchPanKeepsNativeViewportRouteAcrossModeChange() async throws {
        let writes = ByteRecorder()
        let (session, frame) = try await make(writes)
        defer { session.finish() }
        let id = try XCTUnwrap(session.allocatePointerID())
        _ = try await session.enqueuePointer(pointer(frame, id: id, phase: .press))?.value
        session.receive(Data("\u{1B}[?1000h\u{1B}[?1006h".utf8))
        let move = try await session.enqueuePointer(pointer(frame, id: id, phase: .move,
            point: CGPoint(x: 15, y: 50)))?.value
        let release = try await session.enqueuePointer(pointer(frame, id: id, phase: .release,
            point: CGPoint(x: 15, y: 70)))?.value
        XCTAssertNotNil(move?.localScrollRows)
        XCTAssertNotNil(release?.localScrollRows, "only this native route may start local momentum")
        XCTAssertTrue(writes.data.isEmpty, "a mode change must not invent a remote press/move")
    }

    func testWheelBurstIsBoundedAndPreservesRemoteStepsAcrossInputBarrier() async throws {
        let writes = ByteRecorder()
        let (session, frame) = try await make(writes)
        defer { session.finish() }
        session.receive(Data("\u{1B}[?1000h\u{1B}[?1006h".utf8))
        _ = try await session.snapshot()
        let gate = await hold(session)
        func wheel(_ y: CGFloat) {
            session.enqueueWheel(.init(terminalID: frame.terminalID, generation: frame.layout.generation,
                point: CGPoint(x: 15, y: 10), delta: CGPoint(x: 0, y: y), modifiers: []),
                cellWidth: 10, cellHeight: 20, completion: {})
        }
        for _ in 0..<1000 { wheel(20) }
        XCTAssertEqual(session.queuedInteractionBatches, 1)
        session.sendInput(Data("barrier".utf8))
        for _ in 0..<1000 { wheel(-20) }
        XCTAssertEqual(session.queuedInteractionBatches, 2)
        await gate.open()
        _ = try await session.snapshot()
        let expected = String(repeating: "\u{1B}[<64;2;1M", count: 1000)
            + "barrier" + String(repeating: "\u{1B}[<65;2;1M", count: 1000)
        XCTAssertEqual(writes.data, Data(expected.utf8))
        XCTAssertEqual(session.queuedInteractionBatches, 0)
    }

    func testLocalMomentumNeverEncodesRemoteWheelAfterModeChange() async throws {
        let writes = ByteRecorder()
        let (session, frame) = try await make(writes)
        defer { session.finish() }
        session.receive(Data("\u{1B}[?1000h\u{1B}[?1006h".utf8))
        session.enqueueWheel(.init(terminalID: frame.terminalID, generation: frame.layout.generation,
            point: CGPoint(x: 15, y: 10), delta: CGPoint(x: 0, y: 40), modifiers: []),
            cellWidth: 10, cellHeight: 20, localOnly: true, completion: {})
        _ = try await session.snapshot()
        XCTAssertTrue(writes.data.isEmpty)
    }

    func testHoverBurstKeepsLatestPerOutputAndModifierSegment() async throws {
        let (session, frame) = try await make()
        defer { session.finish() }
        let gate = await hold(session)
        // Coalescing replaces a queued hover's completion, so exactly the
        // latest hover of each segment reports.
        let fired = FiredHovers()
        for column in 0..<1000 {
            session.enqueueHover(at: CGPoint(x: column % 10 * 10 + 5, y: 10), modifiers: [],
                frame: frame, detectLink: false, completion: { _ in fired.ids.append(column) })
        }
        XCTAssertEqual(session.queuedInteractionBatches, 1)
        session.receive(Data("output barrier".utf8))
        session.enqueueHover(at: CGPoint(x: 5, y: 10), modifiers: [], frame: frame,
            detectLink: false, completion: { _ in fired.ids.append(1000) })
        session.sealInteractionAdmission()
        session.enqueueHover(at: CGPoint(x: 5, y: 10), modifiers: .command, frame: frame,
            detectLink: true, completion: { _ in fired.ids.append(1001) })
        XCTAssertEqual(session.queuedInteractionBatches, 3)
        await gate.open()
        let after = try await session.snapshot()
        XCTAssertTrue(after.line(0).hasPrefix("output barrier"))
        XCTAssertEqual(fired.ids, [999, 1000, 1001])
    }

    func testMotionNeverMovesAcrossKeyAdmissionBarrier() async throws {
        let (session, frame) = try await make()
        defer { session.finish() }
        let id = try XCTUnwrap(session.allocatePointerID())
        _ = try await session.enqueuePointer(pointer(frame, id: id, phase: .press))?.value
        let gate = await hold(session)
        var completions: [CGPoint] = []
        for row in 0..<1000 {
            session.enqueuePointerMotion(pointer(frame, id: id, phase: .move,
                point: CGPoint(x: 15, y: row % 4 * 20 + 10))) { request, _ in completions.append(request.point) }
        }
        XCTAssertEqual(session.queuedInteractionBatches, 1)
        _ = session.enqueueInput(.text("key barrier"))
        session.enqueuePointerMotion(pointer(frame, id: id, phase: .move,
            point: CGPoint(x: 15, y: 10))) { request, _ in completions.append(request.point) }
        XCTAssertEqual(session.queuedInteractionBatches, 2)
        await gate.open()
        _ = try await session.snapshot()
        XCTAssertEqual(completions, [CGPoint(x: 15, y: 70), CGPoint(x: 15, y: 10)])
    }
}

@MainActor
private final class FiredHovers {
    var ids: [Int] = []
}
