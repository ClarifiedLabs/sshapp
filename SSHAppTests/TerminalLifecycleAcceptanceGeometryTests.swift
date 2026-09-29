import CoreGraphics
import XCTest

/// Pure geometry and decode regressions for the physical lifecycle acceptance
/// (SSHAppUITests/TerminalLifecycleAcceptanceUITests). They launch nothing, so
/// they run in the unit target instead of the UI-test runner.
final class TerminalLifecycleAcceptanceGeometryTests: XCTestCase {
    func testWindowResizeAcceptsOSCenteringButRejectsMovementWithoutSizeChange() {
        for (original, floating) in [
            (CGRect(x: 0, y: 0, width: 744, height: 1133), CGRect(x: 148, y: 54, width: 448, height: 910)),
            (CGRect(x: 0, y: 0, width: 1032, height: 1376), CGRect(x: 204.5, y: 89.5, width: 623, height: 1082))
        ] {
            XCTAssertTrue(SystemWindowResizeGeometry.resized(actual: floating, original: original, display: original))
            XCTAssertFalse(SystemWindowResizeGeometry.resized(actual: floating.offsetBy(dx: 5, dy: 5),
                original: floating, display: original), "Movement alone is not resize evidence")
            XCTAssertTrue(SystemWindowRestoration.requiresFullScreenZoom(actual: floating, expected: original, display: original))
            XCTAssertFalse(SystemWindowRestoration.requiresFullScreenZoom(actual: floating, expected: floating, display: original))
            XCTAssertNil(SystemWindowRestoration.correction(actual: floating, expected: original),
                         "Observed OS-centered resize needs the measured Zoom control, not another drag")
        }
    }

    func testWindowRestorationUsesMeasuredSnapNotRequestedEndpoint() {
        let original = CGRect(x: 20, y: 30, width: 800, height: 900)
        let snapped = CGRect(x: 20, y: 30, width: 600, height: 650)
        let correction = SystemWindowRestoration.correction(actual: snapped, expected: original)
        XCTAssertEqual(correction?.dx, 200)
        XCTAssertEqual(correction?.dy, 250)
        XCTAssertFalse(SystemWindowRestoration.matches(snapped, original))
        XCTAssertTrue(SystemWindowRestoration.matches(original, original))
        XCTAssertNil(SystemWindowRestoration.correction(actual: snapped.offsetBy(dx: 40, dy: 0), expected: original),
                     "A moved window needs explicit OS controls, not a guessed resize")
    }

    func testWindowResizeGeometryUsesVisibleInteriorOfMeasuredMiniAndProGrabbers() throws {
        for size in [CGSize(width: 744, height: 1133), CGSize(width: 1032, height: 1376)] {
            let display = CGRect(origin: .zero, size: size)
            let handle = CGRect(x: size.width - 20, y: size.height - 20, width: 40, height: 40)
            let point = try XCTUnwrap(SystemWindowResizeGeometry.start(handle: handle, window: display, display: display))
            XCTAssertEqual(handle.midX, display.maxX, "The raw AX center is on the display boundary")
            XCTAssertEqual(handle.midY, display.maxY)
            XCTAssertEqual(point, CGPoint(x: size.width - 10, y: size.height - 10))
            XCTAssertTrue(handle.intersection(display).contains(point))
            XCTAssertLessThan(point.x, display.maxX)
            XCTAssertLessThan(point.y, display.maxY)
        }
    }

    func testWindowResizeGeometryRejectsUnrelatedClippedAndInvalidBounds() {
        let display = CGRect(x: 0, y: 0, width: 744, height: 1133)
        let handle = CGRect(x: 724, y: 1113, width: 40, height: 40)
        let invalidHandles = [CGRect.zero, .null, .infinite,
            CGRect(x: CGFloat.nan, y: 1113, width: 40, height: 40),
            CGRect(x: 744, y: 1133, width: 40, height: 40), // boundary-only intersection
            handle.offsetBy(dx: -60, dy: 0), handle.offsetBy(dx: 0, dy: -60),
            display] // an unrelated/full-window element is not a resize handle
        for invalid in invalidHandles {
            XCTAssertNil(SystemWindowResizeGeometry.start(handle: invalid, window: display, display: display), "\(invalid)")
        }
        XCTAssertNil(SystemWindowResizeGeometry.start(handle: handle,
            window: display.offsetBy(dx: 10, dy: 0), display: display))
        XCTAssertNil(SystemWindowResizeGeometry.start(handle: handle, window: .zero, display: display))
        XCTAssertNil(SystemWindowResizeGeometry.start(handle: handle, window: display, display: .infinite))
        XCTAssertNil(SystemWindowRestoration.correction(actual: .null, expected: display))
        XCTAssertNil(SystemWindowRestoration.correction(actual: display, expected: .infinite))
        XCTAssertFalse(SystemWindowRestoration.matches(.zero, .zero))
        XCTAssertFalse(SystemWindowResizeGeometry.resized(actual: .null, original: display, display: display))
        XCTAssertFalse(SystemWindowResizeGeometry.resized(actual: display.offsetBy(dx: 1, dy: 0),
            original: display, display: display))
        XCTAssertFalse(SystemWindowRestoration.requiresFullScreenZoom(actual: .null, expected: display, display: display))
    }

    func testWindowResizeRestorationKeepsMeasuredEndpointInsideDisplayAfterSnap() throws {
        // The OS snap differs from the requested 20%/15% shrink. Re-query its
        // new handle and use measured bounds, not the old drag endpoint.
        let original = CGRect(x: 0, y: 0, width: 744, height: 1133)
        let snapped = CGRect(x: 0, y: 0, width: 600, height: 900)
        let handle = CGRect(x: 580, y: 880, width: 40, height: 40)
        let point = try XCTUnwrap(SystemWindowResizeGeometry.start(handle: handle, window: snapped, display: original))
        XCTAssertEqual(point, CGPoint(x: 590, y: 890))
        let correction = try XCTUnwrap(SystemWindowRestoration.correction(actual: snapped, expected: original))
        let destination = try XCTUnwrap(SystemWindowResizeGeometry.destination(from: point, correction: correction, display: original))
        XCTAssertEqual(destination, CGPoint(x: 734, y: 1123))
        XCTAssertNil(SystemWindowResizeGeometry.destination(from: CGPoint(x: handle.midX, y: handle.midY),
            correction: correction, display: original), "Raw handle center would restore to an untouchable display boundary")
        XCTAssertNil(SystemWindowResizeGeometry.destination(from: point,
            correction: CGVector(dx: 1000, dy: 0), display: original))
        XCTAssertNil(SystemWindowResizeGeometry.destination(from: point,
            correction: CGVector(dx: CGFloat.nan, dy: 0), display: original))
        XCTAssertNil(SystemWindowRestoration.correction(actual: snapped.offsetBy(dx: 0, dy: 20), expected: original))
    }

    func testStatusDecodeRejectsMissingEvidence() {
        XCTAssertThrowsError(try JSONDecoder().decode(TerminalLifecycleUIStatus.Status.self, from: Data("{\"phase\":\"resumed\"}".utf8)))
    }
}
