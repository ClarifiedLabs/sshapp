import XCTest
@testable import GhosttyVT

final class VTMetalImagePlanTests: XCTestCase {
    /// Regression: selection used byte size only, so a wide image that is small
    /// in bytes was planned as one texture beyond Metal's dimension limit, and
    /// every frame containing it failed instead of drawing through tiles.
    func testImagesWiderThanATextureUseTheTilePath() async throws {
        let side = VTMetalImagePlan.maximumTextureSide
        let fits = try await plan(width: side)
        XCTAssertEqual(fits.cachedGenerations.count, 1)
        XCTAssertFalse(fits.needsTile)

        let tooWide = try await plan(width: side + 1)
        XCTAssertTrue(tooWide.cachedGenerations.isEmpty)
        XCTAssertTrue(tooWide.needsTile)
        XCTAssertEqual(tooWide.tileCount, 9)
        XCTAssertEqual(tooWide.pixelBytes, 9 * VTMetalImagePlan.tilePixelBytes)
    }

    /// Hardening: remote-derived geometry reaches Int(floor/ceil), which traps
    /// on non-finite or out-of-range doubles.
    func testNonFiniteOrHugeGeometryIsRejectedWithoutTrapping() throws {
        let layout = try VTLayout(generation: 1, width: 200, height: 160,
                                  cellWidth: 10, cellHeight: 20, scale: 2, padding: 0)
        let image = VTImageValue(generation: 1, width: 4, height: 4, rgba: Data(count: 4 * 4 * 4))
        func placement(size: CGSize, source: CGRect) -> VTImagePlacementValue {
            VTImagePlacementValue(image: image, imageID: 1, placementID: 1, z: 0, column: 0, row: 0,
                                  offset: .zero, pixelSize: size, source: source)
        }
        let size = CGSize(width: 8, height: 8)
        let source = CGRect(x: 0, y: 0, width: 4, height: 4)
        XCTAssertNotNil(placement(size: size, source: source).geometry(in: layout))
        XCTAssertNil(placement(size: CGSize(width: CGFloat.nan, height: 8), source: source).geometry(in: layout))
        XCTAssertNil(placement(size: CGSize(width: 8, height: CGFloat.infinity), source: source).geometry(in: layout))
        XCTAssertNil(placement(size: CGSize(width: -8, height: 8), source: source).geometry(in: layout))
        XCTAssertNil(placement(size: size, source: CGRect(x: CGFloat.nan, y: 0, width: 4, height: 4)).geometry(in: layout))
        XCTAssertNil(placement(size: size, source: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 4)).geometry(in: layout))

        XCTAssertTrue(VTMetalImagePlan.tileRects(image: image,
            source: CGRect(x: CGFloat.nan, y: 0, width: 4, height: 4)).isEmpty)
        let huge = VTMetalImagePlan.tileRects(image: image, source: CGRect(x: -1e300, y: 0, width: 2e300, height: 4))
        XCTAssertEqual(huge.count, 1)
        XCTAssertEqual(huge.first?.width, 4)
    }

    private func plan(width: Int) async throws -> VTMetalImagePlan {
        let layout = try VTLayout(generation: 1, width: 200, height: 160,
                                  cellWidth: 10, cellHeight: 20, scale: 2, padding: 0)
        let terminal = try VTTerminal(layout: layout)
        let pixels = Data(repeating: 200, count: width * 4).base64EncodedString()
        _ = try await terminal.ingest(Data(("\u{1B}_Ga=T,f=32,s=\(width),v=1,i=1,c=4,r=1,q=2;"
            + pixels + "\u{1B}\\").utf8))
        let frame = try await terminal.snapshot()
        _ = try await terminal.retire()
        XCTAssertEqual(frame.graphics.placements.first?.image.width, width)
        return VTMetalImagePlan(frame)
    }
}
