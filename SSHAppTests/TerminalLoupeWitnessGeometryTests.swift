#if DEBUG && canImport(UIKit) && !targetEnvironment(macCatalyst)
import UIKit
import XCTest
@testable import GhosttyTerminal

@MainActor
final class TerminalLoupeWitnessGeometryTests: XCTestCase {
    func testMappedBandStaysInsideCircularBorderWithPixelRoundingMargin() {
        let point = CGPoint(x: 200, y: 164)
        let source = CGRect(x: point.x - 6, y: point.y + 18, width: 12, height: 3)
        let mapped = source.offsetBy(dx: 24 - point.x, dy: 24 - point.y)
            .applying(CGAffineTransform(scaleX: 2, y: 2))
        XCTAssertEqual(mapped, CGRect(x: 36, y: 84, width: 24, height: 6))
        for x in [mapped.minX - 1, mapped.maxX + 1] {
            for y in [mapped.minY - 1, mapped.maxY + 1] {
                XCTAssertLessThan(hypot(x - 48, y - 48), 46)
            }
        }
    }

    func testWitnessUsesActualSnappedHandleIncludingShadowNotFingerOrHitTarget() {
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        let handle = TerminalSelectionHandleView(endpoint: .end)
        root.addSubview(handle)
        handle.center = CGPoint(x: 200, y: 160)
        handle.layoutIfNeeded()
        let finger = CGPoint(x: 200, y: 164)
        let source = CGRect(x: finger.x - 6, y: finger.y + 18, width: 12, height: 3)
        let exclusion = handle.acceptanceInkExclusionRect(in: root)
        XCTAssertEqual(exclusion, CGRect(x: 180, y: 141, width: 40, height: 40))
        XCTAssertFalse(exclusion.intersects(source))
        XCTAssertTrue(handle.frame.intersects(source), "Transparent 48pt hit target is not visible ink")
        let oldSource = CGRect(x: finger.x - 12, y: finger.y + 8, width: 24, height: 12)
        XCTAssertTrue(exclusion.intersects(oldSource), "Regression: old witness included the handle shadow")
        handle.center.y += 4
        XCTAssertTrue(handle.acceptanceInkExclusionRect(in: root).intersects(source),
                      "A differently snapped handle must fail closed, not use the finger as its center")
    }
}
#endif
