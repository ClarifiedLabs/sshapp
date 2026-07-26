import CoreGraphics
import UIKit
import XCTest
@testable import SSHApp

/// Tests for `TmuxLayoutParser` — the recursive-descent parser for tmux's
/// `layout-custom` string format used in `%layout-change` notifications and
/// `list-windows -F '#{window_layout}'` responses.
final class TmuxLayoutParserTests: XCTestCase {

    // MARK: - Single pane

    func testParsesSinglePaneLayout() {
        let layout = TmuxLayoutParser.parse("0a1b,80x24,0,0,3")
        XCTAssertEqual(
            layout?.tiledRoot,
            .pane(
                id: TmuxPaneID(rawValue: 3),
                frame: TmuxFrame(cols: 80, rows: 24, xOffset: 0, yOffset: 0)
            )
        )
    }

    func testParsesSinglePaneIgnoresChecksumValue() {
        // Different csum prefixes must not affect the parsed result.
        let a = TmuxLayoutParser.parse("0000,80x24,0,0,3")
        let b = TmuxLayoutParser.parse("ffff,80x24,0,0,3")
        XCTAssertNotNil(a)
        XCTAssertEqual(a, b)
    }

    // MARK: - Single split

    func testParsesVSplitWithBraces() {
        let layout = TmuxLayoutParser.parse("1234,80x24,0,0{40x24,0,0,3,40x24,40,0,4}")
        let expected: TmuxLayoutNode = .vSplit(
            frame: TmuxFrame(cols: 80, rows: 24, xOffset: 0, yOffset: 0),
            children: [
                .pane(
                    id: TmuxPaneID(rawValue: 3),
                    frame: TmuxFrame(cols: 40, rows: 24, xOffset: 0, yOffset: 0)
                ),
                .pane(
                    id: TmuxPaneID(rawValue: 4),
                    frame: TmuxFrame(cols: 40, rows: 24, xOffset: 40, yOffset: 0)
                ),
            ]
        )
        XCTAssertEqual(layout?.tiledRoot, expected)
    }

    func testParsesHSplitWithBrackets() {
        let layout = TmuxLayoutParser.parse("5678,80x24,0,0[80x12,0,0,3,80x12,0,12,4]")
        let expected: TmuxLayoutNode = .hSplit(
            frame: TmuxFrame(cols: 80, rows: 24, xOffset: 0, yOffset: 0),
            children: [
                .pane(
                    id: TmuxPaneID(rawValue: 3),
                    frame: TmuxFrame(cols: 80, rows: 12, xOffset: 0, yOffset: 0)
                ),
                .pane(
                    id: TmuxPaneID(rawValue: 4),
                    frame: TmuxFrame(cols: 80, rows: 12, xOffset: 0, yOffset: 12)
                ),
            ]
        )
        XCTAssertEqual(layout?.tiledRoot, expected)
    }

    // MARK: - Nested

    func testParsesVSplitNestedInsideHSplit() {
        // Outer hSplit: top half is a vSplit (panes 3 and 4), bottom half is pane 5.
        let layout = TmuxLayoutParser.parse(
            "abcd,80x24,0,0[40x12,0,0{20x12,0,0,3,20x12,20,0,4},40x12,40,0,5]"
        )
        let expected: TmuxLayoutNode = .hSplit(
            frame: TmuxFrame(cols: 80, rows: 24),
            children: [
                .vSplit(
                    frame: TmuxFrame(cols: 40, rows: 12),
                    children: [
                        .pane(
                            id: TmuxPaneID(rawValue: 3),
                            frame: TmuxFrame(cols: 20, rows: 12, xOffset: 0, yOffset: 0)
                        ),
                        .pane(
                            id: TmuxPaneID(rawValue: 4),
                            frame: TmuxFrame(cols: 20, rows: 12, xOffset: 20, yOffset: 0)
                        ),
                    ]
                ),
                .pane(
                    id: TmuxPaneID(rawValue: 5),
                    frame: TmuxFrame(cols: 40, rows: 12, xOffset: 40, yOffset: 0)
                ),
            ]
        )
        XCTAssertEqual(layout?.tiledRoot, expected)
    }

    func testNestedLayoutPaneIDsAreInDeclarationOrder() {
        let layout = TmuxLayoutParser.parse(
            "abcd,80x24,0,0[40x12,0,0{20x12,0,0,3,20x12,20,0,4},40x12,40,0,5]"
        )
        let ids = layout?.paneIDs.map(\.rawValue)
        XCTAssertEqual(ids, [3, 4, 5])
    }

    func testDeeplyNestedPaneIDOrder() {
        // Three levels deep, mixed orientations. Pane id order should match
        // depth-first left-to-right traversal of the source string.
        // Outer hSplit, top is vSplit, top-left is hSplit (panes 1,2), top-right is pane 3, bottom is pane 4.
        let layout = "1111,80x24,0,0[40x12,0,0{20x12,0,0[20x6,0,0,1,20x6,0,6,2],20x12,20,0,3},40x12,40,0,4]"
        let parsed = TmuxLayoutParser.parse(layout)
        XCTAssertEqual(parsed?.paneIDs.map(\.rawValue), [1, 2, 3, 4])
    }

    // MARK: - Frame offsets

    func testFrameOffsetsArePreservedForChildPanes() {
        // Right child has a non-zero xOffset of 40.
        let layout = TmuxLayoutParser.parse("1234,80x24,0,0{40x24,0,0,3,40x24,40,0,4}")
        guard case .vSplit(_, let children) = layout?.tiledRoot, children.count == 2 else {
            XCTFail("expected vSplit with two children, got \(String(describing: layout?.tiledRoot))")
            return
        }
        XCTAssertEqual(children[0].frame, TmuxFrame(cols: 40, rows: 24, xOffset: 0, yOffset: 0))
        XCTAssertEqual(children[1].frame, TmuxFrame(cols: 40, rows: 24, xOffset: 40, yOffset: 0))
    }

    func testStackedHSplitOffsetsArePreserved() {
        let layout = TmuxLayoutParser.parse("5678,80x24,0,0[80x12,0,0,3,80x12,0,12,4]")
        guard case .hSplit(_, let children) = layout?.tiledRoot, children.count == 2 else {
            XCTFail("expected hSplit with two children, got \(String(describing: layout?.tiledRoot))")
            return
        }
        XCTAssertEqual(children[0].frame, TmuxFrame(cols: 80, rows: 12, xOffset: 0, yOffset: 0))
        XCTAssertEqual(children[1].frame, TmuxFrame(cols: 80, rows: 12, xOffset: 0, yOffset: 12))
    }

    func testPanePlacementsExposeLeafFramesInDeclarationOrder() {
        let layout = TmuxLayoutParser.parse("1234,80x24,0,0{40x24,0,0,3,40x24,40,0,4}")
        let placements = layout?.panePlacements

        XCTAssertEqual(placements?.map(\.id.rawValue), [3, 4])
        XCTAssertEqual(placements?.map(\.frame), [
            TmuxFrame(cols: 40, rows: 24, xOffset: 0, yOffset: 0),
            TmuxFrame(cols: 40, rows: 24, xOffset: 40, yOffset: 0),
        ])
    }

    func testPanePlacementMapsCellFrameIntoViewRect() {
        let placement = TmuxPanePlacement(
            id: TmuxPaneID(rawValue: 4),
            frame: TmuxFrame(cols: 40, rows: 12, xOffset: 40, yOffset: 12)
        )
        let rect = placement.rect(
            in: CGSize(width: 800, height: 480),
            rootFrame: TmuxFrame(cols: 80, rows: 24, xOffset: 0, yOffset: 0)
        )

        XCTAssertEqual(rect.origin.x, 400)
        XCTAssertEqual(rect.origin.y, 240)
        XCTAssertEqual(rect.size.width, 400)
        XCTAssertEqual(rect.size.height, 240)
    }

    func testVSplitExposesVerticalDivider() {
        let layout = TmuxLayoutParser.parse("1234,80x24,0,0{40x24,0,0,3,40x24,40,0,4}")
        let divider = layout?.splitDividers.first

        XCTAssertEqual(layout?.splitDividers.count, 1)
        XCTAssertEqual(divider?.axis, .vertical)
        XCTAssertEqual(divider?.targetPaneID, TmuxPaneID(rawValue: 3))
        XCTAssertEqual(divider?.frame, TmuxFrame(cols: 0, rows: 24, xOffset: 40, yOffset: 0))
        XCTAssertEqual(divider?.baseTargetSize, 40)
    }

    func testHSplitExposesHorizontalDivider() {
        let layout = TmuxLayoutParser.parse("5678,80x24,0,0[80x12,0,0,3,80x12,0,12,4]")
        let divider = layout?.splitDividers.first

        XCTAssertEqual(layout?.splitDividers.count, 1)
        XCTAssertEqual(divider?.axis, .horizontal)
        XCTAssertEqual(divider?.targetPaneID, TmuxPaneID(rawValue: 3))
        XCTAssertEqual(divider?.frame, TmuxFrame(cols: 80, rows: 0, xOffset: 0, yOffset: 12))
        XCTAssertEqual(divider?.baseTargetSize, 12)
    }

    func testDividerDragMapsToTargetCellSize() {
        let divider = TmuxSplitDivider(
            axis: .vertical,
            targetPaneID: TmuxPaneID(rawValue: 3),
            frame: TmuxFrame(cols: 0, rows: 24, xOffset: 40, yOffset: 0),
            baseTargetSize: 40
        )

        let targetSize = divider.targetSize(
            dragTranslation: CGSize(width: 100, height: 0),
            rootFrame: TmuxFrame(cols: 80, rows: 24),
            viewSize: CGSize(width: 800, height: 480)
        )

        XCTAssertEqual(targetSize, 50)
    }

    @MainActor
    func testDividerInteractionHitTestingUsesLaidOutBoundsForExpandedStrip() {
        let layout = "0000,123x34,0,0{70x34,0,0,1,52x34,71,0,2}"
        guard let parsed = TmuxLayoutParser.parse(layout),
              let divider = parsed.splitDividers.first(where: { $0.axis == .vertical }) else {
            XCTFail("expected vertical divider in \(layout)")
            return
        }

        let boundsSize = CGSize(width: 402, height: 874)
        let view = TmuxSplitDividerInteractionUIView(
            frame: CGRect(origin: .zero, size: boundsSize)
        )
        view.configure(dividers: [divider], rootFrame: parsed.frame, size: .zero)

        let geometry = divider.geometry(
            in: boundsSize,
            rootFrame: parsed.frame,
            hitThickness: 64,
            lineThickness: 2
        )
        let pointInExpandedStrip = CGPoint(
            x: geometry.lineRect.midX - 24,
            y: boundsSize.height / 2
        )

        let oldHitStrip = divider.geometry(
            in: boundsSize,
            rootFrame: parsed.frame,
            hitThickness: 44,
            lineThickness: 2
        )
        XCTAssertFalse(oldHitStrip.hitRect.contains(pointInExpandedStrip))
        XCTAssertTrue(view.containsDividerHit(at: pointInExpandedStrip))
        XCTAssertTrue(view.point(inside: pointInExpandedStrip, with: nil))
    }

    func testThreePaneDividerGeometryKeepsVisibleLinesCenteredInHitTargets() {
        let layout = "0000,127x74,0,0{68x74,0,0,1,58x74,69,0[58x42,69,0,2,58x31,69,43,3]}"
        guard let parsed = TmuxLayoutParser.parse(layout) else {
            XCTFail("failed to parse \(layout)")
            return
        }

        let size = CGSize(width: 1_270, height: 740)
        let rootFrame = TmuxFrame(cols: 127, rows: 74)

        guard let vertical = parsed.splitDividers.first(where: { $0.axis == .vertical }),
              let horizontal = parsed.splitDividers.first(where: { $0.axis == .horizontal }) else {
            XCTFail("expected vertical and horizontal dividers, got \(parsed.splitDividers)")
            return
        }

        let verticalGeometry = vertical.geometry(
            in: size,
            rootFrame: rootFrame,
            hitThickness: 28,
            lineThickness: 2
        )
        XCTAssertEqual(verticalGeometry.hitRect.width, 28)
        XCTAssertEqual(verticalGeometry.lineRect.width, 2)
        XCTAssertEqual(verticalGeometry.hitRect.midX, verticalGeometry.lineRect.midX, accuracy: 0.0001)
        XCTAssertEqual(verticalGeometry.lineRect.midX, 685, accuracy: 0.0001)
        XCTAssertEqual(verticalGeometry.lineRect.minY, 0, accuracy: 0.0001)
        XCTAssertEqual(verticalGeometry.lineRect.maxY, 740, accuracy: 0.0001)

        let horizontalGeometry = horizontal.geometry(
            in: size,
            rootFrame: rootFrame,
            hitThickness: 28,
            lineThickness: 2
        )
        XCTAssertEqual(horizontalGeometry.hitRect.height, 28)
        XCTAssertEqual(horizontalGeometry.lineRect.height, 2)
        XCTAssertEqual(horizontalGeometry.hitRect.midY, horizontalGeometry.lineRect.midY, accuracy: 0.0001)
        XCTAssertEqual(horizontalGeometry.lineRect.midY, 425, accuracy: 0.0001)
        XCTAssertEqual(horizontalGeometry.lineRect.minX, 690, accuracy: 0.0001)
        XCTAssertEqual(horizontalGeometry.lineRect.maxX, 1_270, accuracy: 0.0001)
    }

    // MARK: - Coalescing

    func testCoalescingFlattensNestedHSplits() {
        // Outer hSplit has an hSplit on top (panes 1, 2) and a leaf pane 3 at bottom.
        // After coalesce(), the structure is a single hSplit with three pane children.
        let layout = "abcd,80x24,0,0[80x12,0,0[80x6,0,0,1,80x6,0,6,2],80x12,0,12,3]"
        guard let parsed = TmuxLayoutParser.parse(layout) else {
            XCTFail("failed to parse \(layout)")
            return
        }
        guard case .hSplit(_, let children) = parsed.tiledRoot else {
            XCTFail("expected outer hSplit, got \(String(describing: parsed.tiledRoot))")
            return
        }
        XCTAssertEqual(children.count, 3)
        XCTAssertEqual(children.map(\.paneIDs).flatMap(\.self).map(\.rawValue), [1, 2, 3])
        // Confirm none of the children are still splits of the same orientation.
        for child in children {
            if case .hSplit = child {
                XCTFail("nested hSplit should have been coalesced away: \(child)")
            }
        }
    }

    func testCoalescingDoesNotFlattenDifferentOrientations() {
        // hSplit containing a vSplit must NOT be flattened.
        let layout = "abcd,80x24,0,0[40x12,0,0{20x12,0,0,3,20x12,20,0,4},40x12,40,0,5]"
        guard let parsed = TmuxLayoutParser.parse(layout) else {
            XCTFail("failed to parse \(layout)")
            return
        }
        XCTAssertEqual(parsed.tiledRoot?.coalesced(), parsed.tiledRoot)
    }

    // MARK: - Malformed input

    func testMalformedUnbalancedBraceReturnsNil() {
        XCTAssertNil(TmuxLayoutParser.parse("1234,80x24,0,0{40x24,0,0,3,40x24,40,0,4"))
    }

    func testMalformedUnbalancedBracketReturnsNil() {
        XCTAssertNil(TmuxLayoutParser.parse("5678,80x24,0,0[80x12,0,0,3,80x12,0,12,4"))
    }

    func testMalformedMismatchedClosersReturnsNil() {
        // Opens with `{` but closes with `]` — must be rejected.
        XCTAssertNil(TmuxLayoutParser.parse("1234,80x24,0,0{40x24,0,0,3,40x24,40,0,4]"))
    }

    func testMalformedMissingChecksumCommaReturnsNil() {
        // First 4 chars present but no comma after them.
        XCTAssertNil(TmuxLayoutParser.parse("80x24,0,0,3"))
    }

    func testMalformedTooShortReturnsNil() {
        XCTAssertNil(TmuxLayoutParser.parse(""))
        XCTAssertNil(TmuxLayoutParser.parse("abc"))
    }

    func testMalformedNonNumericPaneIDReturnsNil() {
        XCTAssertNil(TmuxLayoutParser.parse("abcd,80x24,0,0,xyz"))
    }

    func testMalformedNonNumericDimensionReturnsNil() {
        XCTAssertNil(TmuxLayoutParser.parse("abcd,foox24,0,0,3"))
    }

    func testMalformedMissingDimensionSeparatorReturnsNil() {
        // No `x` between cols and rows.
        XCTAssertNil(TmuxLayoutParser.parse("abcd,8024,0,0,3"))
    }

    func testMalformedTrailingGarbageReturnsNil() {
        // Top-level fragment must consume the entire input.
        XCTAssertNil(TmuxLayoutParser.parse("abcd,80x24,0,0,3xyz"))
    }

    func testMalformedBareFragmentNoTailReturnsNil() {
        // `<W>x<H>,<x>,<y>` with nothing after it is malformed at top level.
        XCTAssertNil(TmuxLayoutParser.parse("abcd,80x24,0,0"))
    }

    // MARK: - Malicious-server DoS regressions

    func testDeeplyNestedLayoutReturnsNilNotStackOverflow() {
        // Regression: the recursive-descent parser had no depth bound, so a
        // deeply nested `%layout-change` string from a hostile server would
        // overflow the stack and crash. It must now bail to nil instead.
        let depth = 5000
        var layout = "abcd,"
        layout += String(repeating: "80x24,0,0{", count: depth)
        layout += "80x24,0,0,3"
        layout += String(repeating: "}", count: depth)
        XCTAssertNil(TmuxLayoutParser.parse(layout))
    }

    func testModeratelyNestedLayoutStillParses() {
        // Nesting within the allowed depth must still parse successfully so the
        // bound doesn't reject legitimate (if unusually deep) layouts.
        let depth = 8
        var layout = "abcd,"
        layout += String(repeating: "80x24,0,0{", count: depth)
        layout += "80x24,0,0,3"
        layout += String(repeating: "}", count: depth)
        XCTAssertNotNil(TmuxLayoutParser.parse(layout))
    }

    func testOverlongLayoutStringReturnsNil() {
        // A pathologically long (but shallow) layout is rejected up front.
        let manyChildren = String(repeating: "80x24,0,0,3,", count: 20_000)
        let layout = "abcd,80x24,0,0{\(manyChildren)80x24,0,0,4}"
        XCTAssertNil(TmuxLayoutParser.parse(layout))
    }

    // MARK: - tmux 3.7 floating panes
    //
    // Regression: tmux 3.7 appends a `<...>` floating-cell list to
    // window_layout / window_visible_layout once a window contains a floating
    // pane (`new-pane`, bound to prefix `*`). The parser used to require
    // end-of-input straight after the tiled tree, so it returned nil and the
    // whole window collapsed. Layout strings below are verbatim captures from
    // tmux 3.7b.

    func testParsesLayoutWithSingleFloatingPaneSuffix() {
        let layout = TmuxLayoutParser.parse(
            "64c7,80x24,0,0{40x24,0,0,0,39x24,41,0,1,40x6,4,2,2}<40x6,4,2,2>"
        )

        XCTAssertEqual(layout?.paneIDs.map(\.rawValue), [0, 1, 2])
        XCTAssertEqual(layout?.tiledRoot?.paneIDs.map(\.rawValue), [0, 1])
        XCTAssertEqual(layout?.floatingPanePlacements.map(\.id.rawValue), [2])
        XCTAssertEqual(layout?.panePlacements.map(\.id.rawValue), [0, 1, 2])
        XCTAssertEqual(layout?.splitDividers.count, 1)
    }

    func testFloatingPaneTwoIsFrontmostInCapturedTmux37Layout() {
        assertFloatingCapture(
            "d569,80x24,0,0{40x24,0,0,0,39x24,41,0,1,40x6,4,2,2,40x6,8,4,3}<40x6,4,2,2,40x6,8,4,3>",
            sourceOrder: [2, 3],
            renderOrder: [0, 1, 3, 2]
        )
    }

    func testFloatingPaneThreeIsFrontmostInCapturedTmux37Layout() {
        assertFloatingCapture(
            "f584,80x24,0,0{40x24,0,0,0,39x24,41,0,1,40x6,4,2,2,40x6,8,4,3}<40x6,8,4,3,40x6,4,2,2>",
            sourceOrder: [3, 2],
            renderOrder: [0, 1, 2, 3]
        )
    }

    func testFloatingSuffixDoesNotChangeTheTiledTree() {
        let withFloating = TmuxLayoutParser.parse("64c7,80x24,0,0{40x24,0,0,0,40x24,40,0,1}<40x6,4,2,2>")
        let withoutFloating = TmuxLayoutParser.parse("64c7,80x24,0,0{40x24,0,0,0,40x24,40,0,1}")
        XCTAssertNotNil(withFloating)
        XCTAssertEqual(withFloating?.tiledRoot, withoutFloating?.tiledRoot)
    }

    func testFloatingSuffixOnSinglePaneLayoutParses() {
        let layout = TmuxLayoutParser.parse("b25e,80x24,0,0,1<40x6,4,2,2>")
        XCTAssertEqual(
            layout?.tiledRoot,
            .pane(id: TmuxPaneID(rawValue: 1), frame: TmuxFrame(cols: 80, rows: 24))
        )
        XCTAssertEqual(layout?.paneIDs.map(\.rawValue), [1, 2])
        XCTAssertEqual(layout?.floatingPanePlacements.map(\.id.rawValue), [2])
    }

    func testPruningFloatCollapsesOneChildSplitWithoutShrinkingRootFrame() {
        let layout = TmuxLayoutParser.parse(
            "abcd,80x24,0,0{40x24,0,0,0,40x6,4,2,2}<40x6,4,2,2>"
        )

        XCTAssertEqual(layout?.frame, TmuxFrame(cols: 80, rows: 24))
        XCTAssertEqual(
            layout?.tiledRoot,
            .pane(
                id: TmuxPaneID(rawValue: 0),
                frame: TmuxFrame(cols: 40, rows: 24)
            )
        )
        XCTAssertEqual(layout?.splitDividers, [])
    }

    func testUnterminatedFloatingSuffixReturnsNil() {
        XCTAssertNil(TmuxLayoutParser.parse("64c7,80x24,0,0{40x24,0,0,0,40x24,40,0,1}<40x6,4,2,2"))
    }

    func testMalformedFloatingSuffixContentsReturnNil() {
        XCTAssertNil(TmuxLayoutParser.parse("64c7,80x24,0,0{40x24,0,0,0,40x24,40,0,1}<nonsense>"))
    }

    func testTrailingBytesAfterFloatingSuffixStillReturnNil() {
        XCTAssertNil(TmuxLayoutParser.parse("64c7,80x24,0,0{40x24,0,0,0,40x24,40,0,1}<40x6,4,2,2>junk"))
    }

    func testOverNestedFloatingSuffixReturnsNil() {
        let depth = 100
        var layout = "abcd,80x24,0,0,1<"
        layout += String(repeating: "40x6,4,2{", count: depth)
        layout += "40x6,4,2,2"
        layout += String(repeating: "}", count: depth)
        layout += ">"
        XCTAssertNil(TmuxLayoutParser.parse(layout))
    }

    func testOverlongFloatingSuffixReturnsNil() {
        let suffix = String(repeating: "40x6,4,2,2,", count: 6_000) + "40x6,4,2,3"
        XCTAssertNil(TmuxLayoutParser.parse("abcd,80x24,0,0,1<\(suffix)>"))
    }

    private func assertFloatingCapture(
        _ source: String,
        sourceOrder: [Int],
        renderOrder: [Int],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let layout = TmuxLayoutParser.parse(source) else {
            XCTFail("failed to parse captured floating layout", file: file, line: line)
            return
        }

        XCTAssertEqual(layout.frame, TmuxFrame(cols: 80, rows: 24), file: file, line: line)
        XCTAssertEqual(layout.paneIDs.map(\.rawValue), [0, 1, 2, 3], file: file, line: line)
        XCTAssertEqual(layout.tiledRoot?.paneIDs.map(\.rawValue), [0, 1], file: file, line: line)
        XCTAssertEqual(
            layout.floatingPanePlacements.map(\.id.rawValue),
            sourceOrder,
            file: file,
            line: line
        )
        XCTAssertEqual(layout.panePlacements.map(\.id.rawValue), renderOrder, file: file, line: line)

        XCTAssertEqual(layout.splitDividers.count, 1, file: file, line: line)
        XCTAssertEqual(layout.splitDividers.first?.axis, .vertical, file: file, line: line)
        XCTAssertEqual(
            layout.splitDividers.first?.targetPaneID,
            TmuxPaneID(rawValue: 0),
            file: file,
            line: line
        )
        XCTAssertTrue(
            layout.splitDividers.allSatisfy { ![2, 3].contains($0.targetPaneID.rawValue) },
            file: file,
            line: line
        )
    }
}
