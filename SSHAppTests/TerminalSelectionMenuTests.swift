#if canImport(UIKit) && !targetEnvironment(macCatalyst)
import UIKit
import XCTest
import GhosttyVT
@testable import GhosttyTerminal

@MainActor
final class TerminalSelectionMenuTests: XCTestCase {
    func testSingleLineMenuTargetProtectsBothFullHandleHitTargets() throws {
        let view = makeTerminal()
        // The iPad failure had the menu below the start point and over the end
        // handle. Neither a point nor just the start handle protects this area.
        let start = try showHandle(.start, centeredAt: CGPoint(x: 141.5, y: 278), in: view)
        let end = try showHandle(.end, centeredAt: CGPoint(x: 189.5, y: 294), in: view)

        let target = selectionTarget(in: view, source: start.center)
        XCTAssertEqual(target, start.frame.union(end.frame))
        XCTAssertTrue(target.contains(start.frame))
        XCTAssertTrue(target.contains(end.frame))
        XCTAssertEqual(target.maxY, 318)
    }

    func testCrossedAndMultilineHandlesUseTheirDisplayedUnion() throws {
        let view = makeTerminal()
        let start = try showHandle(.start, centeredAt: CGPoint(x: 260, y: 360), in: view)
        let end = try showHandle(.end, centeredAt: CGPoint(x: 50, y: 100), in: view)
        XCTAssertEqual(selectionTarget(in: view), start.frame.union(end.frame))

        // Requerying must use current display geometry, not a cached native
        // endpoint or the source point from the original menu configuration.
        end.center = CGPoint(x: 24, y: 24)
        end.setDimmed(true)
        XCTAssertEqual(selectionTarget(in: view), start.frame.union(end.frame),
            "A clamped offscreen endpoint remains an interactive handle")
    }

    func testTargetIsConvertedToThePassiveInteractionHost() throws {
        let view = makeTerminal()
        let start = try showHandle(.start, centeredAt: CGPoint(x: 120, y: 140), in: view)
        let end = try showHandle(.end, centeredAt: CGPoint(x: 180, y: 160), in: view)
        let host = try XCTUnwrap(view.selectionEditMenuInteraction.view)
        XCTAssertFalse(host === view)
        XCTAssertFalse(host.isUserInteractionEnabled,
            "Menu anchoring must not add recognizers to the terminal pointer route")
        host.frame = view.bounds.offsetBy(dx: 17, dy: 31)

        XCTAssertEqual(selectionTarget(in: view),
            start.frame.union(end.frame).offsetBy(dx: -17, dy: -31))
    }

    func testHiddenAndDetachedHandlesDoNotReserveStaleMenuSpace() throws {
        let view = makeTerminal()
        let start = try showHandle(.start, centeredAt: CGPoint(x: 100, y: 100), in: view)
        let end = try showHandle(.end, centeredAt: CGPoint(x: 180, y: 120), in: view)
        start.setVisible(false)
        XCTAssertEqual(selectionTarget(in: view), end.frame)

        end.removeFromSuperview()
        let source = CGPoint(x: 73, y: 91)
        XCTAssertEqual(selectionTarget(in: view, source: source),
            CGRect(origin: source, size: CGSize(width: 1, height: 1)),
            "Without displayed handles, preserve the existing source-point fallback")
    }

    func testCursorInputMenuKeepsItsOwnUnexpandedAnchor() throws {
        let view = makeTerminal()
        _ = try showHandle(.start, centeredAt: CGPoint(x: 100, y: 100), in: view)
        _ = try showHandle(.end, centeredAt: CGPoint(x: 180, y: 120), in: view)
        let cursor = CGRect(x: 70, y: 80, width: 8, height: 16)
        view.terminalInputMenuAnchor = cursor
        let configuration = UIEditMenuConfiguration(identifier: nil, sourcePoint: .zero)
        XCTAssertEqual(view.editMenuInteraction(view.terminalInputEditMenuInteraction,
            targetRectFor: configuration), cursor)
    }

    func testNativeSelectionAndCopyAccessibilitySurviveMenuGeometryQueries() async throws {
        let terminal = try VTTerminal(layout: VTLayout(generation: 1, width: 320, height: 480,
            cellWidth: 10, cellHeight: 20, scale: 1, padding: 0))
        _ = try await terminal.ingest(Data("ALPHA BRAVO CHARLIE".utf8))
        try await terminal.select(.word, at: .init(column: 8, row: 0), generation: 1)
        let frame = try await terminal.snapshot()
        XCTAssertEqual(frame.selectedText(), "BRAVO")
        let view = makeTerminal()
        view.nativeInteraction.update(frame)
        let start = try XCTUnwrap(view.selectionStartHandle)
        let end = try XCTUnwrap(view.selectionEndHandle)

        XCTAssertEqual(selectionTarget(in: view), start.frame.union(end.frame))
        XCTAssertTrue(view.selectionHandlesVisible)
        for handle in [start, end] {
            XCTAssertFalse(handle.isHidden)
            XCTAssertTrue(handle.isUserInteractionEnabled)
            XCTAssertTrue(handle.isAccessibilityElement)
            XCTAssertTrue(handle.accessibilityTraits.contains(.adjustable))
            XCTAssertNotNil(handle.onAccessibilityNudge)
        }
        let titles = view.selectionMenuElements().map(\.title)
        XCTAssertEqual(Array(titles.prefix(2)), ["Copy", "Select All"])
        XCTAssertFalse(titles.contains("Paste"))
        let afterQuery = try await terminal.snapshot()
        XCTAssertEqual(afterQuery.selection, frame.selection)
        XCTAssertEqual(afterQuery.selectedText(), "BRAVO")

        _ = try await terminal.clearSelection()
        view.nativeInteraction.update(try await terminal.snapshot())
        XCTAssertFalse(view.selectionHandlesVisible)
        XCTAssertTrue(start.isHidden)
        XCTAssertTrue(end.isHidden)
        XCTAssertFalse(start.isAccessibilityElement)
        XCTAssertFalse(end.isAccessibilityElement)
        XCTAssertNil(view.nativeInteraction.selectionMenuTargetRect(in: view))
        _ = try await terminal.retire()
    }

    private func makeTerminal() -> UITerminalView {
        let view = UITerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        view.layoutIfNeeded()
        return view
    }

    private func showHandle(_ endpoint: TerminalSelectionEndpoint, centeredAt point: CGPoint,
                            in view: UITerminalView) throws -> TerminalSelectionHandleView {
        let handle = try XCTUnwrap(endpoint == .start ? view.selectionStartHandle : view.selectionEndHandle)
        view.addSubview(handle)
        handle.center = point
        handle.setVisible(true)
        return handle
    }

    private func selectionTarget(in view: UITerminalView, source: CGPoint = .zero) -> CGRect {
        view.editMenuInteraction(view.selectionEditMenuInteraction,
            targetRectFor: UIEditMenuConfiguration(identifier: nil, sourcePoint: source))
    }
}
#endif
