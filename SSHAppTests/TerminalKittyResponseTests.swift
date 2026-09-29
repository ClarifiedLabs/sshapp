import Foundation
import XCTest

final class TerminalKittyResponseTests: XCTestCase {
    private func frame(_ body: String) -> Data {
        Data(("\u{1B}_G" + body + "\u{1B}\\").utf8)
    }

    func testAcceptsExactStatusesWithOptionalFixturePlacementAndDSR() {
        let dsr = Data("\u{1B}[7;6R".utf8)
        for imageID in [1, 2, Int(UInt32.max)] {
            for placement in ["", ",p=1"] {
                for status in ["OK", "ENOMEM", "ENOSPC"] {
                    let reply = frame("i=\(imageID)\(placement);\(status)")
                    XCTAssertTrue(TerminalKittyResponse.matches(reply: reply, imageID: imageID, status: status))
                    XCTAssertTrue(TerminalKittyResponse.matches(
                        reply: reply + dsr, imageID: imageID, status: status, followingDSR: dsr
                    ))
                }
            }
        }
    }

    func testAcceptsNativeErrorExplanationsWithoutMatchingTheirWording() {
        for (status, explanation) in [("ENOMEM", " out of memory"), ("ENOSPC", " quota exceeded"),
                                      ("ENOMEM", "other: detail; more detail")] {
            XCTAssertTrue(TerminalKittyResponse.matches(
                reply: frame("i=1,p=1;\(status):\(explanation)"), imageID: 1, status: status
            ))
        }
    }

    func testRejectsMalformedPrefixAndExtraOrDuplicateResponses() {
        let valid = frame("i=1;ENOMEM: out of memory")
        let invalid = [
            Data(), Data("ENOMEM".utf8), Data("_Gi=1;ENOMEM\u{1B}\\".utf8),
            Data("\u{1B}_gi=1;ENOMEM\u{1B}\\".utf8),
            Data("junk".utf8) + valid, valid + Data("junk".utf8), valid + valid,
            frame("i=1;ENOMEM:\u{1B}_Gi=1;ENOMEM")
        ]
        for reply in invalid {
            XCTAssertFalse(TerminalKittyResponse.matches(reply: reply, imageID: 1, status: "ENOMEM"), "\(reply)")
        }
    }

    func testRejectsStatusSubstringsAndMalformedExplanations() {
        for message in ["", "ENOMEM_NOT_QUOTA", "ENOMEM_NOT_QUOTA: no", "XENOMEM", "ENOMEM ",
                        " ENOMEM", "enomem", "ENOMEM;other", "ENOMEM:", "ENOMEM:\nno",
                        "ENOMEM:\u{0}no", "ENOMEM:\u{7F}", "OK", "ENOSPC: full"] {
            XCTAssertFalse(TerminalKittyResponse.matches(
                reply: frame("i=1;\(message)"), imageID: 1, status: "ENOMEM"
            ), message)
        }
        for message in ["NOT_OK", "OKAY", "OK: explanation"] {
            XCTAssertFalse(TerminalKittyResponse.matches(reply: frame("i=1;\(message)"), imageID: 1, status: "OK"))
        }
        for status in ["", "ENOMEM_NOT_QUOTA", "ENOMEM: out of memory", "EINVAL"] {
            XCTAssertFalse(TerminalKittyResponse.matches(reply: frame("i=1;\(status)"), imageID: 1, status: status))
        }
        let invalidUTF8 = Data("\u{1B}_Gi=1;ENOMEM:".utf8) + Data([0xFF]) + Data("\u{1B}\\".utf8)
        XCTAssertFalse(TerminalKittyResponse.matches(reply: invalidUTF8, imageID: 1, status: "ENOMEM"))
    }

    func testRejectsWrongOrMalformedImageIDAndUnexpectedControls() {
        for header in ["i=2", "i=10", "i=01", "i=+1", "i=-1", "i=1 ", "i=", "I=1",
                       "p=1,i=1", "i=1,p=2", "i=1,p=01", "i=1,p=1,p=1", "i=1,i=1", "i=1,I=1"] {
            XCTAssertFalse(TerminalKittyResponse.matches(reply: frame("\(header);OK"), imageID: 1, status: "OK"), header)
        }
        for imageID in [-1, 0, Int(UInt32.max) + 1] {
            XCTAssertFalse(TerminalKittyResponse.matches(reply: frame("i=\(imageID);OK"), imageID: imageID, status: "OK"))
        }
    }

    func testAnimationRequiresExactExpectedFrameNumber() {
        let reply = frame("i=1,r=2;ENOSPC: animation frame storage full")
        XCTAssertTrue(TerminalKittyResponse.matches(reply: reply, imageID: 1, status: "ENOSPC", frameNumber: 2))
        for number: Int? in [nil, 0, -1, 1, 3] {
            XCTAssertFalse(TerminalKittyResponse.matches(reply: reply, imageID: 1, status: "ENOSPC", frameNumber: number))
        }
        for header in ["i=1", "i=1,r=02", "i=1,r=2,r=2", "r=2,i=1"] {
            XCTAssertFalse(TerminalKittyResponse.matches(reply: frame(header + ";OK"), imageID: 1, status: "OK", frameNumber: 2))
        }
    }

    func testRejectsMissingOrMalformedTerminator() {
        for terminator in ["", "\u{1B}", "\\", "\u{7}", "\u{9C}", "\u{1B}/", "\u{1B}\\\u{1B}\\"] {
            XCTAssertFalse(TerminalKittyResponse.matches(
                reply: Data(("\u{1B}_Gi=1;OK" + terminator).utf8), imageID: 1, status: "OK"
            ), terminator.debugDescription)
        }
    }

    func testRequiresExactlyExpectedFollowingDSRBytes() {
        let valid = frame("i=1;OK")
        let dsr = Data("\u{1B}[7;6R".utf8)
        let invalid: [Data] = [
            valid, valid + Data("\u{1B}[7;5R".utf8), valid + Data(dsr.dropLast()),
            valid + dsr + dsr, valid + dsr + Data([0]), dsr + valid,
            valid + Data([0]) + dsr, valid + valid + dsr
        ]
        for reply in invalid {
            XCTAssertFalse(TerminalKittyResponse.matches(reply: reply, imageID: 1, status: "OK", followingDSR: dsr))
        }
        XCTAssertFalse(TerminalKittyResponse.matches(reply: valid + dsr, imageID: 1, status: "OK"))
        XCTAssertFalse(TerminalKittyResponse.matches(reply: dsr, imageID: 1, status: "OK", followingDSR: dsr))
    }
}
