import XCTest
@testable import GhosttyVT
@testable import GhosttyTerminal

/// Tiny images and isolated quotas exercise ownership, not process memory pressure.
@MainActor
final class VTImageSnapshotCacheTests: XCTestCase {
    private nonisolated static func image(level: UInt8 = 64) -> Data {
        let pixels = Data((0..<4).flatMap { _ in [level, level, level, 255] })
        return Data(("\u{1B}_Ga=T,f=32,s=2,v=2,i=1,p=1,c=2,r=2,C=1,q=2;"
            + pixels.base64EncodedString() + "\u{1B}\\").utf8)
    }

    private func layout() throws -> VTLayout {
        try VTLayout(generation: 1, width: 200, height: 180,
                     cellWidth: 10, cellHeight: 20, scale: 2, padding: 0)
    }

    func testScalarMemoryReadsPreserveImageCacheAndNativeMetricsAcrossResize() async throws {
        let cache = VTImageSnapshotCache(limitBytes: 16, limitImages: 1)
        let budget = VTNativeImageBudget(limitBytes: 16)
        let initial = try layout()
        let terminal = try VTTerminal(layout: initial, snapshotCache: cache, nativeImageBudget: budget)
        _ = try await terminal.ingest(Self.image())
        _ = try await terminal.ingest(Data("\u{1B}[4;1Hmarker".utf8))
        XCTAssertEqual(budget.metrics.reservedBytes, 16)
        XCTAssertEqual(cache.metrics.retainedBytes, 0)

        func verifyReads(layout expected: VTLayout, selection expectedSelection: Bool) async throws {
            let cacheBefore = cache.metrics
            let nativeBefore = budget.metrics
            let bytesBefore = await terminal.cachedSnapshotImageBytes
            let observed = await terminal.currentLayout
            let selected = try await terminal.hasSelection()
            let bytesAfter = await terminal.cachedSnapshotImageBytes
            XCTAssertEqual(observed, expected)
            XCTAssertEqual(selected, expectedSelection)
            XCTAssertEqual(bytesAfter, bytesBefore)
            XCTAssertEqual(cache.metrics, cacheBefore, "Scalar reads must not populate, evict or prune image copies")
            XCTAssertEqual(budget.metrics, nativeBefore, "Scalar reads must not mutate native ownership")
        }

        // Native pixels exist, but neither scalar read may extract their first copy.
        try await verifyReads(layout: initial, selection: false)
        let held = try await terminal.snapshot()
        XCTAssertEqual(cache.metrics.retainedBytes, 16)
        try await verifyReads(layout: initial, selection: false)
        let unchanged = try await terminal.snapshot()
        XCTAssertEqual(unchanged, held, "Scalar reads must not change revision or semantic state")
        XCTAssertTrue(unchanged.graphics.placements.first?.image === held.graphics.placements.first?.image)

        let resized = try VTLayout(generation: 2, width: 220, height: 200,
                                   cellWidth: 11, cellHeight: 22, scale: 2, padding: 0)
        _ = try await terminal.resize(to: resized)
        try await terminal.select(.line, at: .init(column: 0, row: 3), generation: resized.generation)
        try await verifyReads(layout: resized, selection: true)
        await terminal.releaseSnapshotCache()
        XCTAssertEqual(cache.metrics.retainedBytes, 0)
        try await verifyReads(layout: resized, selection: true)
        _ = try await terminal.clearSelection()
        try await verifyReads(layout: resized, selection: false)
        _ = try await terminal.retire()
        XCTAssertEqual(cache.metrics.registeredOwners, 0)
        XCTAssertEqual(budget.metrics.reservedBytes, 0)
    }

    func testNativeSelectionPresenceIncludesTrimmedWhitespace() async throws {
        let cache = VTImageSnapshotCache(limitBytes: 16, limitImages: 1)
        let budget = VTNativeImageBudget(limitBytes: 16)
        let terminal = try VTTerminal(layout: layout(), snapshotCache: cache, nativeImageBudget: budget)
        _ = try await terminal.ingest(Data("x  y".utf8))
        try await terminal.select(.line, generation: 1)
        // Line selection trims its boundaries; move the tracked endpoints to
        // whitespace explicitly so the native selection itself remains present.
        try await terminal.moveSelection(start: true, to: .init(column: 1, row: 0), generation: 1)
        try await terminal.moveSelection(start: false, to: .init(column: 2, row: 0), generation: 1)
        let before = cache.metrics
        let nativeBefore = budget.metrics
        let selected = try await terminal.hasSelection()
        let text = try await terminal.selectedText()
        XCTAssertTrue(selected, "A native whitespace selection is still a selection")
        XCTAssertEqual(text, "", "Trimmed text cannot substitute for native selection presence")
        XCTAssertEqual(cache.metrics, before)
        XCTAssertEqual(budget.metrics, nativeBefore)
        _ = try await terminal.clearSelection()
        let cleared = try await terminal.hasSelection()
        XCTAssertFalse(cleared)
        _ = try await terminal.retire()
    }

    func testNativeSelectionPresenceThrowsAfterRetirement() async throws {
        let cache = VTImageSnapshotCache(limitBytes: 16, limitImages: 1)
        let budget = VTNativeImageBudget(limitBytes: 16)
        let terminal = try VTTerminal(layout: layout(), snapshotCache: cache, nativeImageBudget: budget)
        _ = try await terminal.retire()
        do {
            _ = try await terminal.hasSelection()
            XCTFail("Retirement must not become a successful no-selection result")
        } catch {
            XCTAssertEqual(error as? VTError, .retired)
        }
        XCTAssertEqual(cache.metrics.registeredOwners, 0)
        XCTAssertEqual(cache.metrics.retainedBytes, 0)
        XCTAssertEqual(budget.metrics.reservedBytes, 0)
    }

    func testReleaseIsOwnerScopedAndHeldFramesReusePixelsWithoutChangingNativeState() async throws {
        let cache = VTImageSnapshotCache(limitBytes: 32, limitImages: 2)
        let budget = VTNativeImageBudget(limitBytes: 32)
        let first = try VTTerminal(layout: layout(), snapshotCache: cache, nativeImageBudget: budget)
        let second = try VTTerminal(layout: layout(), snapshotCache: cache, nativeImageBudget: budget)
        _ = try await first.ingest(Self.image())
        _ = try await second.ingest(Self.image(level: 96))
        let held = try await first.snapshot()
        let other = try await second.snapshot()
        let nativeBefore = budget.metrics
        XCTAssertEqual(cache.metrics.retainedBytes, 32)

        await first.releaseSnapshotCache()
        await first.releaseSnapshotCache() // Idempotent, including weak records.
        let firstBytes = await first.cachedSnapshotImageBytes
        let secondBytes = await second.cachedSnapshotImageBytes
        XCTAssertEqual(firstBytes, 0)
        XCTAssertEqual(secondBytes, 16)
        XCTAssertEqual(cache.metrics.retainedBytes, 16)
        XCTAssertEqual(cache.metrics.limitBytes, 32)
        XCTAssertEqual(cache.metrics.limitImages, 2)
        XCTAssertEqual(budget.metrics, nativeBefore)
        let reused = try await first.snapshot()
        XCTAssertEqual(reused, held, "Trimming must not change revision or semantic state")
        XCTAssertTrue(reused.graphics.placements.first?.image === held.graphics.placements.first?.image)
        XCTAssertEqual(reused.graphics.storageLimitBytes, VTTerminal.defaultImageStorageBytes)

        _ = try await first.retire()
        _ = try await second.retire()
        XCTAssertEqual(cache.metrics.registeredOwners, 0)
        XCTAssertEqual(cache.metrics.retainedBytes, 0)
        XCTAssertEqual(budget.metrics.reservedBytes, 0)
        XCTAssertEqual(held.graphics.placements.first?.image.rgba, Data([
            64, 64, 64, 255, 64, 64, 64, 255, 64, 64, 64, 255, 64, 64, 64, 255
        ]))
        XCTAssertEqual(other.graphics.placements.first?.image.rgba.prefix(4), Data([96, 96, 96, 255]))
    }

    func testReleasePreservesPrimaryAndAlternateImagesAndWeakReuseAcrossScreens() async throws {
        let cache = VTImageSnapshotCache(limitBytes: 16, limitImages: 1)
        let budget = VTNativeImageBudget(limitBytes: 32)
        let terminal = try VTTerminal(layout: layout(), snapshotCache: cache, nativeImageBudget: budget)
        _ = try await terminal.ingest(Self.image())
        _ = try await terminal.ingest(Data("\u{1B}[7;1Hprimary".utf8))
        let primary = try await terminal.snapshot()
        _ = try await terminal.ingest(Data("\u{1B}[?1049h".utf8))
        _ = try await terminal.ingest(Self.image(level: 96))
        let alternate = try await terminal.snapshot()
        XCTAssertEqual(budget.metrics.reservedBytes, 32)

        await terminal.releaseSnapshotCache()
        XCTAssertEqual(cache.metrics.retainedBytes, 0)
        let reusedAlternate = try await terminal.snapshot()
        XCTAssertEqual(reusedAlternate, alternate)
        XCTAssertTrue(reusedAlternate.graphics.placements.first?.image === alternate.graphics.placements.first?.image)
        await terminal.releaseSnapshotCache()
        _ = try await terminal.ingest(Data("\u{1B}[?1049l".utf8))
        let restored = try await terminal.snapshot()
        XCTAssertTrue(restored.line(6).hasPrefix("primary"))
        XCTAssertTrue(restored.graphics.placements.first?.image === primary.graphics.placements.first?.image)
        XCTAssertFalse(restored.graphics.placements.first?.image === alternate.graphics.placements.first?.image)
        XCTAssertEqual(restored.graphics.storageLimitBytes, primary.graphics.storageLimitBytes)
        XCTAssertEqual(cache.metrics.limitBytes, 16)
        XCTAssertEqual(cache.metrics.limitImages, 1)
        _ = try await terminal.retire()
        XCTAssertEqual(budget.metrics.reservedBytes, 0)
        XCTAssertEqual(primary.graphics.placements.first?.image.rgba.prefix(4), Data([64, 64, 64, 255]))
        XCTAssertEqual(alternate.graphics.placements.first?.image.rgba.prefix(4), Data([96, 96, 96, 255]))
    }

    func testReleaseFreesUnheldCopiesAndReconstructsFromNativeStorage() async throws {
        let cache = VTImageSnapshotCache(limitBytes: 16, limitImages: 1)
        let budget = VTNativeImageBudget(limitBytes: 16)
        let terminal = try VTTerminal(layout: layout(), snapshotCache: cache, nativeImageBudget: budget)
        _ = try await terminal.ingest(Self.image())
        var frame: VTFrameValue? = try await terminal.snapshot()
        weak let oldImage = frame?.graphics.placements.first?.image
        let generation = oldImage?.generation
        let revision = frame?.revision
        XCTAssertNotNil(oldImage)
        frame = nil
        XCTAssertNotNil(oldImage, "Reusable cache owns the otherwise-unleased pixels")

        await terminal.releaseSnapshotCache()
        XCTAssertNil(oldImage)
        XCTAssertEqual(cache.metrics.retainedBytes, 0)
        XCTAssertEqual(cache.metrics.trackedImages, 0)
        XCTAssertEqual(cache.metrics.registeredOwners, 1)
        XCTAssertEqual(budget.metrics.reservedBytes, 16)
        let rebuilt = try await terminal.snapshot()
        XCTAssertEqual(rebuilt.revision, revision)
        XCTAssertEqual(rebuilt.graphics.placements.first?.image.generation, generation)
        XCTAssertEqual(rebuilt.graphics.placements.first?.image.rgba.count, 16)
        XCTAssertEqual(rebuilt.graphics.placements.first?.image.rgba.prefix(4), Data([64, 64, 64, 255]))
        XCTAssertEqual(cache.metrics.retainedBytes, 16)
        _ = try await terminal.retire()
        await terminal.releaseSnapshotCache() // Safe after native retirement too.
        XCTAssertEqual(cache.metrics.registeredOwners, 0)
        XCTAssertEqual(budget.metrics.reservedBytes, 0)
    }

    func testSessionReleaseWithoutViewportDoesNotCreateEngineOrNotifyFrames() async throws {
        let session = VTTerminalSession(write: { _ in XCTFail("Unexpected input") }, resize: { _ in
            XCTFail("Cache release must not create a viewport")
        })
        defer { session.finish() }
        let notifications = Counter()
        session.onFramesAvailable = { notifications.value += 1 }
        let release = try XCTUnwrap(session.enqueueReleaseSnapshotCache())
        try await release.value
        let snapshot = try XCTUnwrap(session.enqueueSnapshot())
        do {
            _ = try await snapshot.value
            XCTFail("Cache release must not create an engine")
        } catch { XCTAssertEqual(error as? VTError, .retired) }
        XCTAssertEqual(notifications.value, 0)
        session.finish()
        XCTAssertNil(session.enqueueReleaseSnapshotCache())
        XCTAssertNil(session.enqueueSnapshot())
    }

    func testCanceledSnapshotAndReleaseDrainInFIFOOrderBeforeRetirementWithoutExtraNotifications() async throws {
        let writes = ByteRecorder()
        let session = VTTerminalSession(write: { writes.append($0) }, resize: { _ in })
        defer { session.finish() }
        session.updateViewport(.init(width: 200, height: 180, cellWidth: 10,
                                     cellHeight: 20, scale: 2, padding: 0))
        let initial = try await session.snapshot()
        let notifications = Counter()
        session.onFramesAvailable = { notifications.value += 1 }
        let gate = OpenOnceGate(), entered = OpenOnceGate()
        session.beforeDelivery = { await entered.open(); await gate.wait() }
        let delivered = expectation(description: "accepted output drains before retirement")
        var output = Self.image()
        output.append(Data("\u{1B}[7;1Hkept\u{1B}[6n".utf8))
        session.deliver(output, ifCurrent: { true }) { accepted in
            XCTAssertTrue(accepted)
            delivered.fulfill()
        }
        await entered.wait()
        session.beforeDelivery = nil

        // No task scheduling between these admissions: extraction precedes
        // trimming, and the query observes retention without repopulating it.
        let snapshot = try XCTUnwrap(session.enqueueSnapshot())
        let populated = try XCTUnwrap(session.enqueueInputQuery { await $0.cachedSnapshotImageBytes })
        let release = try XCTUnwrap(session.enqueueReleaseSnapshotCache())
        let trimmed = try XCTUnwrap(session.enqueueInputQuery { terminal in
            (await terminal.cachedSnapshotImageBytes, try await terminal.selectedText())
        })
        let input = try XCTUnwrap(session.enqueueInput(.text("sent")))
        snapshot.cancel()
        release.cancel()
        input.cancel()
        session.finish()
        XCTAssertNil(session.enqueueSnapshot())
        XCTAssertNil(session.enqueueReleaseSnapshotCache())
        XCTAssertNil(session.enqueueInputQuery { await $0.cachedSnapshotImageBytes })
        XCTAssertEqual(notifications.value, 0)
        XCTAssertTrue(writes.data.isEmpty)

        await gate.open()
        let held = try await snapshot.value
        let before = try await populated.value
        try await release.value
        let (after, selection) = try await trimmed.value
        let sent = try await input.value
        await fulfillment(of: [delivered], timeout: 5)
        XCTAssertEqual(before, 16)
        XCTAssertEqual(after, 0)
        XCTAssertEqual(selection, "", "Non-extracting query must run before native retirement")
        XCTAssertEqual(held.revision, initial.revision + 1)
        XCTAssertTrue(held.line(6).hasPrefix("kept"))
        XCTAssertEqual(held.graphics.placements.first?.image.rgba.prefix(4), Data([64, 64, 64, 255]))
        XCTAssertEqual(sent, Data("sent".utf8))
        XCTAssertEqual(writes.data, Data("\u{1B}[7;5Rsent".utf8))
        XCTAssertEqual(notifications.value, 2, "Only output and input notify, never extraction or cache release")
    }

    @MainActor
    private final class Counter {
        var value = 0
    }

}
