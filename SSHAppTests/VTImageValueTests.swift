import XCTest
@testable import GhosttyVT

final class VTImageValueTests: XCTestCase {
    /// Regression: every CoreText draw (including blink ticks) rebuilt the
    /// CGImage for each placement from the image's pixel data.
    func testCGImageIsBuiltOnceAndShared() throws {
        let image = VTImageValue(generation: 1, width: 2, height: 2,
                                 rgba: Data(repeating: 255, count: 2 * 2 * 4))
        let first = try XCTUnwrap(image.cgImage)
        let second = try XCTUnwrap(image.cgImage)
        XCTAssertTrue(first === second)
        XCTAssertEqual(first.width, 2)
    }
}
