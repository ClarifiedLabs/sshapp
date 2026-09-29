import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import GhosttyVT

/// Tiny isolated quotas exercise refusal, not device memory exhaustion.
@MainActor
final class VTNativeImageBudgetTests: XCTestCase {
    private func layout() throws -> VTLayout {
        try VTLayout(generation: 1, width: 200, height: 180,
                     cellWidth: 10, cellHeight: 20, scale: 2, padding: 0)
    }

    private nonisolated static func command(_ controls: String, pixels: Data? = nil) -> Data {
        Data(("\u{1B}_G" + controls + (pixels.map { ";" + $0.base64EncodedString() } ?? "") + "\u{1B}\\").utf8)
    }

    private nonisolated static func image(id: Int = 1, side: Int = 2) -> Data {
        let pixels = Data((0..<(side * side)).flatMap { _ in [UInt8(64), 64, 64, 255] })
        return Data(("\u{1B}_Ga=T,f=32,s=\(side),v=\(side),i=\(id),p=1,c=2,r=2,C=1;"
            + pixels.base64EncodedString() + "\u{1B}\\").utf8)
    }

    /// Straight RGBA pixels, top row first, encoded as a real PNG.
    private nonisolated static func png(side: Int, pixels: [UInt8]) throws -> Data {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var premultiplied = pixels
        for index in stride(from: 0, to: premultiplied.count, by: 4) {
            let alpha = UInt16(premultiplied[index + 3])
            for channel in 0..<3 {
                premultiplied[index + channel] = UInt8((UInt16(premultiplied[index + channel]) * alpha + 127) / 255)
            }
        }
        let image = try premultiplied.withUnsafeMutableBytes { buffer -> CGImage in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: side * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            return try XCTUnwrap(context.makeImage())
        }
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// Regression: the PNG decoder allocated and zero-filled up to the
    /// upstream 400 MB cap before this terminal's storage limit or the shared
    /// budget refused the result. It must refuse from the header, never
    /// reaching a budget reservation (no denial), yet still decode images that
    /// fit, including fully transparent pixels in a non-zeroed buffer.
    func testPNGBeyondBudgetOrStorageIsRefusedBeforeDecodingAndFittingPNGDecodes() async throws {
        let red: [UInt8] = [255, 0, 0, 255], clear: [UInt8] = [0, 0, 0, 0]
        let pixels = [red, clear, red, clear, red, clear, red, clear, red].flatMap { $0 }
        let transmission = try Self.command("a=T,f=100,i=1,p=1,C=1", pixels: Self.png(side: 3, pixels: pixels))
        for (budgetBytes, storageBytes) in [(35, UInt64(1 << 20)), (1 << 20, UInt64(35))] {
            let budget = VTNativeImageBudget(limitBytes: budgetBytes)
            let terminal = try VTTerminal(layout: layout(), imageStorageBytes: storageBytes,
                                          snapshotCache: VTImageSnapshotCache(limitBytes: 64, limitImages: 1),
                                          nativeImageBudget: budget)
            do {
                let refused = try await terminal.ingest(transmission)
                XCTAssertFalse(refused.replies.isEmpty)
                XCTAssertFalse(TerminalKittyResponse.matches(reply: refused.replies, imageID: 1, status: "OK"))
                let frame = try await terminal.snapshot()
                XCTAssertTrue(frame.graphics.placements.isEmpty)
                XCTAssertEqual(budget.metrics.reservedBytes, 0)
                XCTAssertEqual(budget.metrics.denials, 0, "Refused before any budget reservation")
                _ = try await terminal.retire()
            } catch {
                _ = try? await terminal.retire()
                throw error
            }
        }

        let budget = VTNativeImageBudget(limitBytes: 36)
        let terminal = try VTTerminal(layout: layout(), imageStorageBytes: 36,
                                      snapshotCache: VTImageSnapshotCache(limitBytes: 64, limitImages: 1),
                                      nativeImageBudget: budget)
        do {
            let accepted = try await terminal.ingest(transmission)
            XCTAssertTrue(TerminalKittyResponse.matches(reply: accepted.replies, imageID: 1, status: "OK"))
            XCTAssertEqual(budget.metrics.reservedBytes, 36)
            let frame = try await terminal.snapshot()
            let image = try XCTUnwrap(frame.graphics.placements.first?.image)
            XCTAssertEqual(image.width, 3)
            XCTAssertEqual(image.height, 3)
            XCTAssertEqual(image.rgba, Data(pixels))
            _ = try await terminal.retire()
            XCTAssertEqual(budget.metrics.reservedBytes, 0)
        } catch {
            _ = try? await terminal.retire()
            throw error
        }
    }

    func testChunkedReplacementDeletesOnFirstChunkBeforeEventualRefusal() async throws {
        let budget = VTNativeImageBudget(limitBytes: 16)
        let cache = VTImageSnapshotCache(limitBytes: 16, limitImages: 1)
        let terminal = try VTTerminal(layout: layout(), snapshotCache: cache, nativeImageBudget: budget)
        do {
            _ = try await terminal.ingest(Self.image())
            let displayed = try await terminal.snapshot()
            XCTAssertEqual(budget.metrics.reservedBytes, 16)

            // A 36-byte replacement cannot fit, but its first chunk already
            // deletes the old ID. Loading bytes are outside the retained quota.
            _ = try await terminal.ingest(Self.command("a=T,f=32,s=3,v=3,i=1,p=1,C=1,m=1",
                                                       pixels: Data(repeating: 64, count: 33)))
            let loading = try await terminal.snapshot()
            XCTAssertTrue(loading.graphics.placements.isEmpty)
            XCTAssertEqual(budget.metrics.reservedBytes, 0)
            XCTAssertEqual(budget.metrics.denials, 0)
            var completion = Self.command("m=0", pixels: Data([64, 64, 255]))
            completion.append(Data("\u{1B}[7;1Hafter\u{1B}[6n".utf8))
            let refused = try await terminal.ingest(completion)
            XCTAssertTrue(TerminalKittyResponse.matches(
                reply: refused.replies, imageID: 1, status: "ENOMEM", followingDSR: Data("\u{1B}[7;6R".utf8)
            ))
            XCTAssertEqual(refused.replies.suffix(6), Data("\u{1B}[7;6R".utf8))
            let removed = try await terminal.snapshot()
            XCTAssertTrue(removed.graphics.placements.isEmpty)
            XCTAssertTrue(removed.line(6).hasPrefix("after"))
            XCTAssertEqual(budget.metrics.reservedBytes, 0)
            XCTAssertEqual(budget.metrics.denials, 1)
            XCTAssertEqual(displayed.graphics.placements.first?.image.rgba.count, 16)

            _ = try await terminal.ingest(Self.command("a=T,f=32,s=1,v=1,i=1,p=1,C=1,m=1",
                                                       pixels: Data([1, 2, 3])))
            XCTAssertEqual(budget.metrics.reservedBytes, 0)
            let accepted = try await terminal.ingest(Self.command("m=0", pixels: Data([255])))
            XCTAssertTrue(TerminalKittyResponse.matches(reply: accepted.replies, imageID: 1, status: "OK"))
            XCTAssertEqual(budget.metrics.reservedBytes, 4)
            let recovered = try await terminal.snapshot()
            XCTAssertEqual(recovered.graphics.placements.first?.image.rgba, Data([1, 2, 3, 255]))
            XCTAssertEqual(budget.metrics.peakBytes, 16)
            _ = try await terminal.retire()
            XCTAssertEqual(budget.metrics.reservedBytes, 0)
        } catch {
            _ = try? await terminal.retire()
            throw error
        }
    }

    func testPrimaryAndAlternateReleaseAndInheritQuotaAfterResetAndResize() async throws {
        let budget = VTNativeImageBudget(limitBytes: 32)
        let cache = VTImageSnapshotCache(limitBytes: 32, limitImages: 2)
        let terminal = try VTTerminal(layout: layout(), snapshotCache: cache, nativeImageBudget: budget)
        do {
            _ = try await terminal.ingest(Self.image())
            let original = try await terminal.snapshot()
            _ = try await terminal.ingest(Data("\u{1B}[?1049h".utf8))
            _ = try await terminal.ingest(Self.image())
            XCTAssertEqual(budget.metrics.reservedBytes, 32)
            let replaced = try await terminal.ingest(Self.image())
            XCTAssertTrue(TerminalKittyResponse.matches(reply: replaced.replies, imageID: 1, status: "OK"))
            XCTAssertEqual(budget.metrics.reservedBytes, 32)
            XCTAssertEqual(budget.metrics.denials, 0)
            _ = try await terminal.ingest(Self.image(side: 1))
            XCTAssertEqual(budget.metrics.reservedBytes, 20)
            _ = try await terminal.ingest(Self.command("a=d,d=I,i=1"))
            XCTAssertEqual(budget.metrics.reservedBytes, 16)
            _ = try await terminal.ingest(Data("\u{1B}[?1049l".utf8))
            let primary = try await terminal.snapshot()
            XCTAssertTrue(primary.graphics.placements.first?.image === original.graphics.placements.first?.image)
            _ = try await terminal.ingest(Data("\u{1B}c".utf8))
            XCTAssertEqual(budget.metrics.reservedBytes, 0)

            _ = try await terminal.ingest(Self.image())
            _ = try await terminal.ingest(Data("\u{1B}[?1049h".utf8))
            let resized = try VTLayout(generation: 2, width: 240, height: 200,
                                       cellWidth: 10, cellHeight: 20, scale: 2, padding: 0)
            _ = try await terminal.resize(to: resized)
            _ = try await terminal.ingest(Self.image())
            XCTAssertEqual(budget.metrics.reservedBytes, 32)
            let refused = try await terminal.ingest(Self.image(id: 2))
            XCTAssertTrue(TerminalKittyResponse.matches(reply: refused.replies, imageID: 2, status: "ENOMEM"))
            XCTAssertEqual(budget.metrics.reservedBytes, 32)
            XCTAssertEqual(budget.metrics.peakBytes, 32)
            XCTAssertEqual(budget.metrics.denials, 1)
            _ = try await terminal.retire()
            XCTAssertEqual(budget.metrics.reservedBytes, 0)
        } catch {
            _ = try? await terminal.retire()
            throw error
        }
    }

    func testAnimationGrowthRefusalFrameDeletionAndReplacementAccounting() async throws {
        let budget = VTNativeImageBudget(limitBytes: 8)
        let cache = VTImageSnapshotCache(limitBytes: 8, limitImages: 2)
        let terminal = try VTTerminal(layout: layout(), snapshotCache: cache, nativeImageBudget: budget)
        do {
            _ = try await terminal.ingest(Self.image(side: 1))
            let frame = Self.command("a=f,i=1,f=32,s=1,v=1", pixels: Data([128, 128, 128, 255]))
            let accepted = try await terminal.ingest(frame)
            XCTAssertTrue(TerminalKittyResponse.matches(reply: accepted.replies, imageID: 1, status: "OK", frameNumber: 2))
            XCTAssertEqual(budget.metrics.reservedBytes, 8)
            var stream = frame
            stream.append(Data("\u{1B}[7;1Hafter\u{1B}[6n".utf8))
            let refused = try await terminal.ingest(stream)
            XCTAssertTrue(TerminalKittyResponse.matches(
                reply: refused.replies, imageID: 1, status: "ENOSPC", followingDSR: Data("\u{1B}[7;6R".utf8), frameNumber: 3
            ))
            XCTAssertEqual(refused.replies.suffix(6), Data("\u{1B}[7;6R".utf8))
            let unchanged = try await terminal.snapshot()
            XCTAssertEqual(unchanged.graphics.placements.count, 1)
            XCTAssertTrue(unchanged.line(6).hasPrefix("after"))
            XCTAssertEqual(budget.metrics.reservedBytes, 8)
            XCTAssertEqual(budget.metrics.denials, 1)
            _ = try await terminal.ingest(Self.command("a=d,d=f,i=1,r=2"))
            XCTAssertEqual(budget.metrics.reservedBytes, 4)
            _ = try await terminal.ingest(frame)
            XCTAssertEqual(budget.metrics.reservedBytes, 8)
            _ = try await terminal.ingest(Self.image(side: 1)) // Release the animation's extra frame.
            XCTAssertEqual(budget.metrics.reservedBytes, 4)
            _ = try await terminal.ingest(frame)
            XCTAssertEqual(budget.metrics.reservedBytes, 8)
            _ = try await terminal.ingest(Self.command("a=d,d=f,i=1,r=1")) // Promote frame 2 to root.
            XCTAssertEqual(budget.metrics.reservedBytes, 4)
            _ = try await terminal.ingest(Self.command("a=d,d=F,i=1"))
            XCTAssertEqual(budget.metrics.reservedBytes, 0)
            XCTAssertEqual(budget.metrics.peakBytes, 8)
            _ = try await terminal.retire()
            XCTAssertEqual(budget.metrics.reservedBytes, 0)
        } catch {
            _ = try? await terminal.retire()
            throw error
        }
    }

    func testConcurrentTerminalsCannotOverbookAndStillDrainTextAndReplies() async throws {
        let budget = VTNativeImageBudget(limitBytes: 32)
        let cache = VTImageSnapshotCache(limitBytes: 32, limitImages: 2)
        let terminals = try (0..<8).map { _ in
            try VTTerminal(layout: layout(), snapshotCache: cache, nativeImageBudget: budget)
        }
        do {
            let results = try await withThrowingTaskGroup(of: (Bool, Int).self,
                                                         returning: [(Bool, Int)].self) { group in
                for terminal in terminals {
                    group.addTask {
                        var admitted = false
                        var denials = 0
                        // One producer per actor; await every write before the next.
                        // Only distinct terminals race for the shared reservation.
                        for _ in 0..<4 {
                            var stream = Self.image()
                            stream.append(Data("\u{1B}[7;1Hafter\u{1B}[6n".utf8))
                            let result = try await terminal.ingest(stream)
                            XCTAssertEqual(result.replies.suffix(6), Data("\u{1B}[7;6R".utf8))
                            admitted = TerminalKittyResponse.matches(
                                reply: result.replies, imageID: 1, status: "OK", followingDSR: Data("\u{1B}[7;6R".utf8)
                            )
                            if !admitted {
                                XCTAssertTrue(TerminalKittyResponse.matches(
                                    reply: result.replies, imageID: 1, status: "ENOMEM", followingDSR: Data("\u{1B}[7;6R".utf8)
                                ))
                                denials += 1
                            }
                            let metrics = budget.metrics
                            XCTAssertLessThanOrEqual(metrics.reservedBytes, metrics.limitBytes)
                            XCTAssertLessThanOrEqual(metrics.peakBytes, metrics.limitBytes)
                        }
                        let snapshot = try await terminal.snapshot()
                        XCTAssertEqual(snapshot.graphics.placements.count, admitted ? 1 : 0)
                        XCTAssertTrue(snapshot.line(6).hasPrefix("after"))
                        return (admitted, denials)
                    }
                }
                var values: [(Bool, Int)] = []
                for try await value in group { values.append(value) }
                return values
            }
            XCTAssertEqual(results.filter { $0.0 }.count, 2)
            XCTAssertEqual(budget.metrics.reservedBytes, 32)
            XCTAssertEqual(budget.metrics.peakBytes, 32)
            // Same-ID writes release first: another terminal may win the bytes.
            XCTAssertEqual(budget.metrics.denials, results.reduce(0) { $0 + $1.1 })
            XCTAssertGreaterThanOrEqual(budget.metrics.denials, 6)
            for terminal in terminals { _ = try await terminal.retire() }
            XCTAssertEqual(budget.metrics.reservedBytes, 0)
            XCTAssertEqual(cache.metrics.registeredOwners, 0)
        } catch {
            for terminal in terminals { _ = try? await terminal.retire() }
            throw error
        }
    }

    func testSharedRefusalPreservesDisplayedImageAndFollowingTextAndReplies() async throws {
        let budget = VTNativeImageBudget(limitBytes: 16)
        let cache = VTImageSnapshotCache(limitBytes: 32, limitImages: 2)
        let layout = try VTLayout(generation: 1, width: 200, height: 180,
                                  cellWidth: 10, cellHeight: 20, scale: 2, padding: 0)
        let first = try VTTerminal(layout: layout, snapshotCache: cache, nativeImageBudget: budget)
        let second = try VTTerminal(layout: layout, snapshotCache: cache, nativeImageBudget: budget)
        do {
            _ = try await first.ingest(Self.image())
            let displayed = try await first.snapshot()
            XCTAssertEqual(displayed.graphics.placements.count, 1)
            // A different ID is essential: same-ID retransmission intentionally
            // deletes the old image before decoding, even if replacement fails.
            var stream = Self.image(id: 2, side: 3)
            stream.append(Data("\u{1B}[7;1Hafter\u{1B}[6n".utf8))
            let refused = try await first.ingest(stream)
            XCTAssertTrue(TerminalKittyResponse.matches(
                reply: refused.replies, imageID: 2, status: "ENOMEM", followingDSR: Data("\u{1B}[7;6R".utf8)
            ))
            XCTAssertEqual(refused.replies.suffix(6), Data("\u{1B}[7;6R".utf8))
            let unchanged = try await first.snapshot()
            XCTAssertEqual(unchanged.graphics.placements.count, 1)
            XCTAssertTrue(unchanged.graphics.placements.first?.image === displayed.graphics.placements.first?.image)
            XCTAssertTrue(unchanged.line(6).hasPrefix("after"))

            var otherStream = Self.image()
            otherStream.append(Data("\u{1B}[7;1Hother\u{1B}[6n".utf8))
            let denied = try await second.ingest(otherStream)
            XCTAssertTrue(TerminalKittyResponse.matches(
                reply: denied.replies, imageID: 1, status: "ENOMEM", followingDSR: Data("\u{1B}[7;6R".utf8)
            ))
            XCTAssertEqual(denied.replies.suffix(6), Data("\u{1B}[7;6R".utf8))
            let empty = try await second.snapshot()
            XCTAssertTrue(empty.graphics.placements.isEmpty)
            XCTAssertTrue(empty.line(6).hasPrefix("other"))
            XCTAssertEqual(budget.metrics.reservedBytes, 16)
            XCTAssertEqual(budget.metrics.peakBytes, 16)
            XCTAssertEqual(budget.metrics.denials, 2)

            _ = try await first.retire()
            XCTAssertEqual(budget.metrics.reservedBytes, 0)
            let accepted = try await second.ingest(Self.image())
            XCTAssertTrue(TerminalKittyResponse.matches(reply: accepted.replies, imageID: 1, status: "OK"))
            let replacement = try await second.snapshot()
            XCTAssertEqual(replacement.graphics.placements.count, 1)
            XCTAssertEqual(budget.metrics.reservedBytes, 16)
            _ = try await second.retire()
            XCTAssertEqual(budget.metrics.reservedBytes, 0)
            XCTAssertEqual(cache.metrics.registeredOwners, 0)
            XCTAssertEqual(cache.metrics.retainedBytes, 0)
            XCTAssertEqual(cache.metrics.trackedImages, 0)
            // Immutable held frames survive native and reusable-cache release.
            XCTAssertEqual(displayed.graphics.placements.first?.image.rgba.prefix(4), Data([64, 64, 64, 255]))
            XCTAssertEqual(replacement.graphics.placements.first?.image.rgba.count, 16)
        } catch {
            _ = try? await first.retire()
            _ = try? await second.retire()
            throw error
        }
    }
}
