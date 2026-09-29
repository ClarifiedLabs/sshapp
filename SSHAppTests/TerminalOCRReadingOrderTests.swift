import XCTest

final class TerminalOCRReadingOrderTests: XCTestCase {
    func testReconstructsScrambledColumnMajorRowsIncludingLastLine() {
        let numbers = Array(14...32)
        let prefixes = numbers.reversed().map { number in
            observation("ALPHA BOTTOM", x: 0.05, y: rowY(number), width: 0.38)
        }
        let middles = numbers.map { number in
            observation("LINE", x: 0.46, y: rowY(number) + 0.001, width: 0.15)
        }
        let suffixes = numbers.reversed().map { number in
            observation(String(format: "%04d", number), x: 0.66, y: rowY(number) - 0.001)
        }

        let result = TerminalOCRReadingOrder.text(from: prefixes + middles + suffixes)

        XCTAssertEqual(result, numbers.map { String(format: "ALPHA BOTTOM LINE %04d", $0) }
            .joined(separator: "\n"))
        XCTAssertEqual(result.components(separatedBy: "\n").last, "ALPHA BOTTOM LINE 0032")
    }

    func testMergesVariableHeightsWithAlignedBaselines() {
        let fragments = [
            observation("0032", x: 0.7, y: 0.2, height: 0.012),
            observation("LINE", x: 0.5, y: 0.201, height: 0.02),
            observation("ALPHA BOTTOM", x: 0.05, y: 0.2, width: 0.4, height: 0.032)
        ]

        XCTAssertEqual(TerminalOCRReadingOrder.text(from: fragments), "ALPHA BOTTOM LINE 0032")
    }

    func testMergesCenteredFragmentsDespiteDifferentLowerEdges() {
        let fragments = [
            observation("RIGHT", x: 0.5, y: 0.205, height: 0.01),
            observation("LEFT", x: 0.1, y: 0.2, height: 0.02)
        ]

        XCTAssertEqual(TerminalOCRReadingOrder.text(from: fragments), "LEFT RIGHT")
    }

    func testDoesNotMergeAdjacentRowsEvenWhenBoxesOverlap() {
        let fragments = [
            observation("BOTTOM", x: 0.1, y: 0.4, height: 0.02),
            observation("2", x: 0.6, y: 0.401, height: 0.02),
            observation("1", x: 0.6, y: 0.415, height: 0.02),
            observation("TOP", x: 0.1, y: 0.414, height: 0.02)
        ]

        XCTAssertEqual(TerminalOCRReadingOrder.text(from: fragments), "TOP 1\nBOTTOM 2")
    }

    func testDoesNotChainSmallVerticalOffsetsIntoOneRow() {
        let fragments = [
            observation("A", x: 0.1, y: 0.5, height: 0.02),
            observation("B", x: 0.3, y: 0.494, height: 0.02),
            observation("C", x: 0.5, y: 0.488, height: 0.02)
        ]

        XCTAssertEqual(TerminalOCRReadingOrder.text(from: fragments), "A B\nC")
    }

    func testDoesNotMergeDistantUnrelatedVerticalPositions() {
        let fragments = [
            observation("FOOTER", x: 0.8, y: 0.1),
            observation("HEADER", x: 0.1, y: 0.9),
            observation("MIDDLE", x: 0.5, y: 0.5)
        ]

        XCTAssertEqual(TerminalOCRReadingOrder.text(from: fragments), "HEADER\nMIDDLE\nFOOTER")
    }

    func testPreservesExactTextIncludingConfusablesWhitespaceAndDuplicates() {
        let fragments = [
            observation("O0 lI  003Z", x: 0.5, y: 0.5),
            observation("ALPHA", x: 0.1, y: 0.5),
            observation("ALPHA", x: 0.1, y: 0.4)
        ]

        XCTAssertEqual(TerminalOCRReadingOrder.text(from: fragments), "ALPHA O0 lI  003Z\nALPHA")
    }

    func testEmptyInputProducesEmptyString() {
        XCTAssertEqual(TerminalOCRReadingOrder.text(from: []), "")
    }

    private func rowY(_ number: Int) -> CGFloat {
        0.9 - CGFloat(number - 14) * 0.035
    }

    private func observation(
        _ text: String,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat = 0.12,
        height: CGFloat = 0.02
    ) -> TerminalOCRReadingOrder.Observation {
        .init(text: text, boundingBox: CGRect(x: x, y: y, width: width, height: height))
    }
}
