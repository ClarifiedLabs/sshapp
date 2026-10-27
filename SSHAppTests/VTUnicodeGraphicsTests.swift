import XCTest
@testable import GhosttyVT

final class VTUnicodeGraphicsTests: XCTestCase {
    /// Integer source rectangles rounded each third of this one-pixel image
    /// to zero height, so geometry(in:) silently discarded every visible row.
    func testOnePixelUnicodeImagePreservesFractionalSourceRows() async throws {
        let layout = try Self.layout()
        var input = "\u{1B}[?2027h"
            + "\u{1B}_Ga=T,t=d,f=24,i=1,p=1,s=1,v=1,U=1,c=3,r=3,C=1,q=2;////\u{1B}\\"
            + "\u{1B}[38;5;1;58;5;1m"
        for (row, diacritic) in ["\u{0305}", "\u{030D}", "\u{030E}"].enumerated() {
            // Only the first placeholder specifies its column. The remaining
            // placeholders inherit the row and advance the inferred column.
            input += "\u{1B}[\(row + 1);1H\u{10EEEE}\(diacritic)\u{0305}\u{10EEEE}\u{10EEEE}"
        }
        let frame = try await Self.snapshot(input, layout: layout)
        let placements = frame.graphics.placements.sorted { $0.row < $1.row }
        XCTAssertEqual(frame.graphics.virtualPlacementCount, 1)
        XCTAssertEqual(placements.count, 3)
        var previousDestination: CGRect?
        for (row, placement) in placements.enumerated() {
            XCTAssertTrue(placement.isUnicode)
            XCTAssertEqual(placement.imageID, 1)
            XCTAssertEqual(placement.placementID, 1)
            XCTAssertEqual(placement.image.width, 1)
            XCTAssertEqual(placement.image.height, 1)
            XCTAssertEqual(placement.column, 0)
            XCTAssertEqual(placement.row, row)
            XCTAssertEqual(placement.offset, .zero)
            XCTAssertEqual(placement.pixelSize, CGSize(width: 30, height: 10))
            let source = CGRect(x: 0, y: Double(row) / 3, width: 1, height: 1.0 / 3)
            Self.assertRect(placement.source, equals: source)

            let geometry = try XCTUnwrap(placement.geometry(in: layout))
            Self.assertRect(geometry.source, equals: source)
            Self.assertRect(geometry.destination,
                            equals: CGRect(x: 0, y: row * 10, width: 30, height: 10))
            if let previousDestination {
                XCTAssertEqual(geometry.destination.minY, previousDestination.maxY, accuracy: 0.000001)
            }
            previousDestination = geometry.destination
        }
    }

    func testFragmentedUnicodeImagePreservesFractionalWidthsAndCenteredOffset() async throws {
        let layout = try Self.layout()
        // A 2x1 image aspect-fits the 30x30 virtual grid at 30x15, centered
        // vertically at y=7.5. Only its first and third cells in row zero are
        // visible: each samples 2/3 by 1/6 source pixels into 10x2.5 pixels.
        // Default-underline placeholders (run.placement_id == 0) must still
        // report the resolved external virtual placement ID (p=1).
        let input = "\u{1B}[?2027h"
            + "\u{1B}_Ga=T,t=d,f=24,i=1,p=1,s=2,v=1,U=1,c=3,r=3,C=1,q=2;////////\u{1B}\\"
            + "\u{1B}[38;5;1m\u{1B}[1;1H"
            + "\u{10EEEE}\u{0305}\u{0305} \u{10EEEE}\u{0305}\u{030E}"
        let frame = try await Self.snapshot(input, layout: layout)
        let placements = frame.graphics.placements.sorted { $0.column < $1.column }
        XCTAssertEqual(frame.graphics.virtualPlacementCount, 1)
        XCTAssertEqual(placements.count, 2)
        for (index, placement) in placements.enumerated() {
            let column = index * 2
            XCTAssertTrue(placement.isUnicode)
            XCTAssertEqual(placement.imageID, 1)
            XCTAssertEqual(placement.placementID, 1)
            XCTAssertEqual(placement.image.width, 2)
            XCTAssertEqual(placement.image.height, 1)
            XCTAssertEqual(placement.column, column)
            XCTAssertEqual(placement.row, 0)
            XCTAssertEqual(placement.offset.x, 0, accuracy: 0.000001)
            XCTAssertEqual(placement.offset.y, 7.5, accuracy: 0.000001)
            XCTAssertEqual(placement.pixelSize.width, 10, accuracy: 0.000001)
            XCTAssertEqual(placement.pixelSize.height, 2.5, accuracy: 0.000001)
            let source = CGRect(x: Double(column) * 2 / 3, y: 0, width: 2.0 / 3, height: 1.0 / 6)
            Self.assertRect(placement.source, equals: source)

            let geometry = try XCTUnwrap(placement.geometry(in: layout))
            Self.assertRect(geometry.source, equals: source)
            Self.assertRect(geometry.destination,
                            equals: CGRect(x: Double(column * 10), y: 7.5, width: 10, height: 2.5))
        }
    }

    func testUnnamedSameCellPlacementsSortDeterministicallyByGeometry() async throws {
        let layout = try Self.layout()
        let input = "\u{1B}_Ga=t,t=d,f=24,i=1,s=2,v=2,q=2;////////////////\u{1B}\\"
            + "\u{1B}[1;1H\u{1B}_Ga=p,i=1,X=4,Y=2,w=1,h=2,C=1,q=2\u{1B}\\"
            + "\u{1B}[1;1H\u{1B}_Ga=p,i=1,X=1,Y=2,w=2,h=1,C=1,q=2\u{1B}\\"
        let frame = try await Self.snapshot(input, layout: layout)
        XCTAssertEqual(frame.graphics.placements.count, 2)
        XCTAssertEqual(frame.graphics.placements.map(\.placementID), [0, 0])
        XCTAssertEqual(frame.graphics.placements.map(\.offset.x), [1, 4])
        XCTAssertEqual(frame.graphics.placements.map(\.source.width), [2, 1])
    }

    private static func layout() throws -> VTLayout {
        try VTLayout(generation: 1, width: 100, height: 100,
                     cellWidth: 10, cellHeight: 10, scale: 1, padding: 0)
    }

    private static func snapshot(_ input: String, layout: VTLayout) async throws -> VTFrameValue {
        let terminal = try VTTerminal(layout: layout)
        do {
            _ = try await terminal.ingest(Data(input.utf8))
            let frame = try await terminal.snapshot()
            _ = try await terminal.retire()
            return frame
        } catch {
            _ = try? await terminal.retire()
            throw error
        }
    }

    private static func assertRect(_ actual: CGRect, equals expected: CGRect,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.000001, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.000001, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.000001, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.000001, file: file, line: line)
    }
}
