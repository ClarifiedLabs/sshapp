import XCTest
@testable import SSHApp

final class TerminalInputNormalizerTests: XCTestCase {
    func testGhosttyCSIuControlCBecomesETX() {
        let input = Data([0x1B]) + Data("[3;5u".utf8)

        let result = TerminalInputNormalizer.normalize(input)

        XCTAssertEqual(result, Data([0x03]))
    }

    func testGhosttyCSIuControlDBecomesEOT() {
        let input = Data([0x1B]) + Data("[4;5u".utf8)

        let result = TerminalInputNormalizer.normalize(input)

        XCTAssertEqual(result, Data([0x04]))
    }

    func testEmbeddedCSIuControlSequenceIsNormalizedWithoutDroppingText() {
        let input = Data("ab".utf8) + Data([0x1B]) + Data("[3;5u".utf8) + Data("cd".utf8)

        let result = TerminalInputNormalizer.normalize(input)

        XCTAssertEqual(result, Data([UInt8(ascii: "a"), UInt8(ascii: "b"), 0x03, UInt8(ascii: "c"), UInt8(ascii: "d")]))
    }

    func testPrintableControlLetterCSIuBecomesControlByte() {
        let input = Data([0x1B]) + Data("[99;5u".utf8)

        let result = TerminalInputNormalizer.normalize(input)

        XCTAssertEqual(result, Data([0x03]))
    }

    func testNonControlCSIuIsPreserved() {
        let input = Data([0x1B]) + Data("[99;1u".utf8)

        let result = TerminalInputNormalizer.normalize(input)

        XCTAssertEqual(result, input)
    }
}
