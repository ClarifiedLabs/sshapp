#if DEBUG
import QuartzCore
import UIKit
import XCTest
@testable import GhosttyTerminal
@testable import GhosttyVT

@MainActor
final class TerminalLifecycleAcceptanceDebugTests: XCTestCase {
    private final class Notifications { var count = 0 }

    func testFIFOScalarQueryCannotRefillCacheOrNotifyAfterAlreadyAdmittedExtraction() async throws {
        let session = VTTerminalSession(write: { _ in }, resize: { _ in })
        defer { session.finish() }
        session.updateViewport(.init(width: 390, height: 480, cellWidth: 10, cellHeight: 20, scale: 2))
        // Await viewport setup once. No fixture uses this explicit extraction.
        _ = try await session.snapshot()
        let pixels = Data([220, 20, 30, 255]).base64EncodedString()
        session.receive(Data("\u{1B}_Ga=T,f=32,s=1,v=1,i=1,p=1,c=2,r=2,q=2;\(pixels)\u{1B}\\".utf8))
        _ = try await session.snapshot()
        let seeded = try await XCTUnwrap(session.enqueueLifecycleAcceptanceQuery()).value
        XCTAssertGreaterThan(seeded.cachedImageBytes, 0)
        let notifications = Notifications()
        let token = session.observeFrames { notifications.count += 1 }
        defer { session.removeFrameObserver(token) }

        // Same ordering as production takeSnapshotRequest -> hide/release ->
        // didEnterBackground query. Cancellation is not relied on for ordering.
        let alreadyAdmitted = try XCTUnwrap(session.enqueueSnapshot())
        let release = try XCTUnwrap(session.enqueueReleaseSnapshotCache())
        let query = try XCTUnwrap(session.enqueueLifecycleAcceptanceQuery())
        _ = try await alreadyAdmitted.value
        try await release.value
        let released = try await query.value
        XCTAssertEqual(released.terminalID, seeded.terminalID)
        XCTAssertEqual(released.cachedImageBytes, 0)
        XCTAssertEqual(released.processNativeImageBytes, seeded.processNativeImageBytes)
        for _ in 0..<3 {
            let repeated = try await XCTUnwrap(session.enqueueLifecycleAcceptanceQuery()).value
            XCTAssertEqual(repeated, released)
        }
        XCTAssertEqual(notifications.count, 0, "Read-only diagnostics must never request presentation")
    }

    func testScalarQueryDoesNotCreateTerminalAndIsRejectedAfterFinish() async throws {
        let session = VTTerminalSession(write: { _ in }, resize: { _ in })
        let task = try XCTUnwrap(session.enqueueLifecycleAcceptanceQuery())
        do {
            _ = try await task.value
            XCTFail("A query must not manufacture a native engine")
        } catch { XCTAssertEqual(error as? VTError, .retired) }
        session.finish()
        XCTAssertNil(session.enqueueLifecycleAcceptanceQuery())
    }

    func testInstallingMomentumObserverIsInertAndVisibilityStopsActualLink() async throws {
        let view = UITerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 480))
        var samples: [TerminalLifecycleMomentumSample] = []
        view.lifecycleMomentumObserver = { samples.append($0) }
        XCTAssertNil(view.momentumDisplayLink)
        XCTAssertEqual(view.momentumVelocity, .zero)
        XCTAssertEqual(view.lifecycleMomentumTicks, 0)
        XCTAssertTrue(samples.isEmpty)
        XCTAssertNil(view.lifecycleAcceptanceSample)
        // Unit-level stimulation, not the physical fixture's gesture path.
        view.startMomentumScrolling(velocity: CGPoint(x: 0, y: 1200))
        XCTAssertEqual(samples.map(\.kind), [.started])
        XCTAssertNotNil(view.momentumDisplayLink)
        view.isHostVisible = false
        XCTAssertNil(view.momentumDisplayLink)
        XCTAssertEqual(samples.map(\.kind), [.started, .stopped])
        XCTAssertEqual(samples.last?.stopCause, .visibility)
        XCTAssertEqual(samples.last?.velocityY, 1200, "Observe pre-reset cancellation velocity")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(samples.map(\.kind), [.started, .stopped], "No ticks may follow visibility cancellation")
        view.lifecycleMomentumObserver = nil
    }

    func testStaleDisplayLinkCannotMutateReplacementMomentumGeneration() throws {
        let view = UITerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 480))
        var samples: [TerminalLifecycleMomentumSample] = []
        view.lifecycleMomentumObserver = { samples.append($0) }
        defer { view.stopMomentumScrolling(); view.lifecycleMomentumObserver = nil }
        view.startMomentumScrolling(velocity: CGPoint(x: 0, y: 1200))
        let oldLink = try XCTUnwrap(view.momentumDisplayLink)
        view.stopMomentumScrolling()
        XCTAssertEqual(samples.last?.stopCause, .cancelled)
        XCTAssertEqual(samples.last?.velocityY, 1200)
        view.startMomentumScrolling(velocity: CGPoint(x: 70, y: 1300))
        let replacement = try XCTUnwrap(view.momentumDisplayLink)
        let generation = view.lifecycleMomentumGeneration
        let velocity = view.momentumVelocity
        let sampleCount = samples.count
        view.momentumScrollFrame(oldLink)
        XCTAssertTrue(view.momentumDisplayLink === replacement)
        XCTAssertEqual(view.momentumVelocity, velocity)
        XCTAssertEqual(view.lifecycleMomentumGeneration, generation)
        XCTAssertEqual(view.lifecycleMomentumTicks, 0)
        XCTAssertEqual(samples.count, sampleCount, "Stale A must not emit evidence attributed to B")
    }

    func testActualDecelerationStopRecordsPreResetVelocityAndCause() throws {
        let view = UITerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 480))
        var samples: [TerminalLifecycleMomentumSample] = []
        view.lifecycleMomentumObserver = { samples.append($0) }
        defer { view.stopMomentumScrolling(); view.lifecycleMomentumObserver = nil }
        view.startMomentumScrolling(velocity: CGPoint(x: 0, y: 51))
        let link = try XCTUnwrap(view.momentumDisplayLink)
        view.momentumScrollFrame(link) // 51 * 0.92 crosses the real stop threshold.
        XCTAssertNil(view.momentumDisplayLink)
        XCTAssertEqual(view.momentumVelocity, .zero)
        XCTAssertEqual(samples.map(\.kind), [.started, .stopped])
        let stop = try XCTUnwrap(samples.last)
        XCTAssertEqual(stop.stopCause, .deceleration)
        XCTAssertEqual(stop.velocityY, 51 * 0.92, accuracy: 0.0001)
        XCTAssertGreaterThan(stop.velocityY, 0)
        view.momentumScrollFrame(link)
        XCTAssertEqual(samples.count, 2, "The stopped link is stale too")
    }

    func testNativeReleaseBoundaryIncludesFinalPanEffectsWithoutExtractingFrame() async throws {
        let layout = try VTLayout(generation: 1, width: 320, height: 160,
            cellWidth: 10, cellHeight: 20, scale: 1, padding: 0)
        let terminal = try VTTerminal(layout: layout)
        let history = (0..<60).map { String(format: "LIFE%05d", $0) }.joined(separator: "\r\n")
        let pixels = Data([220, 20, 30, 255]).base64EncodedString()
        _ = try await terminal.ingest(Data((history + "\u{1B}[1;1H\u{1B}_Ga=T,f=32,s=1,v=1,i=1,p=1,c=2,r=2,C=1,q=2;\(pixels)\u{1B}\\").utf8))
        let before = try await terminal.snapshot()
        let seededBytes = await terminal.cachedSnapshotImageBytes
        XCTAssertGreaterThan(seededBytes, 0)
        func request(_ phase: VTPointerRequest.Phase, id: UInt64 = 1, y: Double) -> VTPointerRequest {
            .init(id: id, terminalID: before.terminalID, generation: layout.generation,
                revision: before.revision, phase: phase, source: .touch,
                point: CGPoint(x: 15, y: y), time: id)
        }
        _ = try await terminal.pointer(request(.press, y: 20))
        await terminal.releaseSnapshotCache()
        var releaseRequest = request(.release, y: 100)
        releaseRequest.recordsLifecycleReleaseBoundary = true
        let response = try await terminal.pointer(releaseRequest)
        let boundary = try XCTUnwrap(response.lifecycleReleaseBoundary)
        let retainedBytes = await terminal.cachedSnapshotImageBytes
        XCTAssertEqual(retainedBytes, 0, "Boundary cannot extract or repopulate adapter image copies")
        XCTAssertEqual(boundary.pointerID, 1)
        XCTAssertEqual(boundary.terminalID, before.terminalID)
        XCTAssertEqual(boundary.generation, layout.generation)
        XCTAssertEqual(boundary.offset, before.viewport.offset - 4)
        XCTAssertGreaterThan(boundary.revision, before.revision)
        let finalPan = try await terminal.snapshot()
        XCTAssertEqual(boundary.revision, finalPan.revision)
        XCTAssertEqual(boundary.offset, finalPan.viewport.offset)
        XCTAssertEqual(boundary.totalRows, finalPan.viewport.totalRows)
        XCTAssertEqual(boundary.rows, finalPan.viewport.rows)
        // Output after release must not alter the already-captured boundary.
        _ = try await terminal.ingest(Data("\r\nLIFE AFTER RELEASE".utf8))
        XCTAssertEqual(response.lifecycleReleaseBoundary, boundary)
        _ = try await terminal.pointer(request(.press, id: 2, y: 20))
        let unobserved = try await terminal.pointer(request(.release, id: 2, y: 40))
        XCTAssertNil(unobserved.lifecycleReleaseBoundary, "No opt-in means no additional native read")
        _ = try await terminal.retire()
    }

    func testOnlyActualMomentumLinkEmitsTicksAndFixtureNeverSynthesizesScroll() throws {
        let root = try projectRoot()
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        let path = "Packages/SSHAppGhostty/Sources/GhosttyTerminal/Platform/UIKit/"
        let interaction = try source(path + "UITerminalView+Interaction.swift")
        let tick = try XCTUnwrap(interaction.range(of: "emitLifecycleMomentum(.tick"))
        let actual = try XCTUnwrap(interaction.range(of: "@objc func momentumScrollFrame"))
        let stop = try XCTUnwrap(interaction.range(of: "func stopMomentumScrolling"))
        XCTAssertTrue(actual.lowerBound < tick.lowerBound && tick.lowerBound < stop.lowerBound)
        let fixture = try source("SSHApp/Testing/TerminalLifecycleAcceptanceFixture.swift")
        for forbidden in ["stopMomentumScrolling(", "startMomentumScrolling(", "sendNativeScroll(",
                          "enqueueScrollPointer(", "enqueueSnapshot(", "VTFrameValue", "setActive("] {
            XCTAssertFalse(fixture.contains(forbidden), forbidden)
        }
        // Transport snapshot is its scalar ledger, not VT frame extraction.
        // Whitelist that receiver only; a future engine/session snapshot still fails.
        let withoutTransportLedger = fixture.replacingOccurrences(of: "model.transport.snapshot()", with: "transportLedger")
        XCTAssertFalse(withoutTransportLedger.contains(".snapshot()"))
        let pointer = try source(path + "TerminalNativePointerController.swift")
        let cancellation = try XCTUnwrap(pointer.range(of: "guard request.id == nextID, request.id > cancelledThroughID else {"))
        let restart = try XCTUnwrap(pointer.range(of: "view.startMomentumScrolling(velocity:"))
        XCTAssertLessThan(cancellation.lowerBound, restart.lowerBound, "Stale release cannot restart a hidden host")
        let hooks = try source(path + "TerminalLifecycleAcceptanceDebug.swift")
        XCTAssertTrue(hooks.contains("renderedRevision: content.lifecycleRenderedRevision"))
        XCTAssertFalse(hooks.contains("renderedRevision: content.metalRenderer?.diagnostics.lastCompletedRevision"),
                       "GPU readiness must not be coupled to layer publication")
        for forbidden in ["VTFrameValue", "VTImageValue", "CADisplayLink(", "requestFrame(", "refresh("] {
            XCTAssertFalse(hooks.contains(forbidden), forbidden)
        }
    }
}
#endif
