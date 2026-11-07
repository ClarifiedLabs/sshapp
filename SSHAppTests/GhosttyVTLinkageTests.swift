import CGhosttyVT
import libghosttyvt
import XCTest
@testable import GhosttyVT

/// Regression tests for the production libghostty-vt linkage.
///
/// Executing a real framework call forces the normal unit-test flow to
/// compile and link the GhosttyVT target, and pins the shipped framework's
/// compiled-in optimization mode to the lockfile expectation.
final class GhosttyVTLinkageTests: XCTestCase {
    func testPackagedFrameworkReportsReleaseSafeOptimization() throws {
        XCTAssertEqual(try ghosttyVTOptimizeMode(), .releaseSafe)
    }

    func testPackagedFrameworkReportsStableLibraryRelease() throws {
        let version = try XCTUnwrap(ghostty_version())
        XCTAssertEqual(String(cString: version), "1.0.0")
        XCTAssertEqual(GHOSTTY_VT_VERSION_MAJOR, 1)
        XCTAssertEqual(GHOSTTY_VT_VERSION_MINOR, 0)
        XCTAssertEqual(GHOSTTY_VT_VERSION_PATCH, 0)
    }

    func testBridgeReadsStableStyleFlagsAndUnderlineColor() throws {
        var handle: OpaquePointer?
        XCTAssertEqual(vt_create(10, 4, 0, 0, nil, 0, &handle), 0)
        let live = try XCTUnwrap(handle)
        defer { vt_destroy(live) }
        let text = Array(("\u{1B}[1;2;3;4:3;5;7;8;9;53m\u{1B}[38;2;1;2;3m\u{1B}[48;2;4;5;6m\u{1B}[58;2;7;8;9mA\u{1B}[0mB"
            + "\u{1B}[38;2;10;11;12mC\u{1B}[0;48;2;13;14;15mD").utf8)
        XCTAssertEqual(vt_write(live, text, text.count), 0)
        var frame: UnsafeMutablePointer<VTFrame>?
        XCTAssertEqual(vt_copy_frame(live, nil, 0, &frame), 0)
        let owned = try XCTUnwrap(frame)
        defer { vt_free_frame(owned) }
        let cells = try XCTUnwrap(owned.pointee.cells)
        let styled = cells[0]
        XCTAssertTrue(styled.bold && styled.italic && styled.faint && styled.blink)
        XCTAssertTrue(styled.invisible && styled.strikethrough && styled.overline)
        XCTAssertEqual(styled.underline_style, 3)
        XCTAssertTrue(styled.underline_color_explicit)
        XCTAssertEqual([styled.underline_color.r, styled.underline_color.g, styled.underline_color.b], [7, 8, 9])
        XCTAssertEqual([styled.foreground.r, styled.foreground.g, styled.foreground.b], [4, 5, 6])
        XCTAssertEqual([styled.background.r, styled.background.g, styled.background.b], [1, 2, 3])
        let plain = cells[1]
        XCTAssertFalse(plain.bold || plain.italic || plain.faint || plain.blink)
        XCTAssertFalse(plain.invisible || plain.strikethrough || plain.overline)
        XCTAssertEqual(plain.underline_style, 0)
        XCTAssertFalse(plain.underline_color_explicit)
        let foregroundOnly = cells[2]
        XCTAssertEqual([foregroundOnly.foreground.r, foregroundOnly.foreground.g, foregroundOnly.foreground.b], [10, 11, 12])
        XCTAssertEqual(foregroundOnly.background.r, owned.pointee.background.r)
        XCTAssertEqual(foregroundOnly.background.g, owned.pointee.background.g)
        XCTAssertEqual(foregroundOnly.background.b, owned.pointee.background.b)
        let backgroundOnly = cells[3]
        XCTAssertEqual([backgroundOnly.background.r, backgroundOnly.background.g, backgroundOnly.background.b], [13, 14, 15])
        XCTAssertEqual(backgroundOnly.foreground.r, owned.pointee.foreground.r)
        XCTAssertEqual(backgroundOnly.foreground.g, owned.pointee.foreground.g)
        XCTAssertEqual(backgroundOnly.foreground.b, owned.pointee.foreground.b)
    }

    func testCopyFormatsOnlyTheActiveSelection() throws {
        var handle: OpaquePointer?
        XCTAssertEqual(vt_create(10, 4, 0, 0, nil, 0, &handle), 0)
        let live = try XCTUnwrap(handle)
        defer { vt_destroy(live) }
        let text = Array("alpha beta".utf8)
        XCTAssertEqual(vt_write(live, text, text.count), 0)
        func copiedText() throws -> String {
            var bytes: UnsafeMutablePointer<UInt8>?
            var count = 0
            XCTAssertEqual(vt_copy_selection(live, &bytes, &count), 0)
            defer { vt_free_bytes(bytes) }
            guard count > 0 else { return "" }
            return String(decoding: UnsafeBufferPointer(start: try XCTUnwrap(bytes), count: count), as: UTF8.self)
        }
        XCTAssertEqual(try copiedText(), "")
        XCTAssertEqual(vt_select(live, 1, 1, 0), 0)
        XCTAssertEqual(try copiedText(), "alpha")
        XCTAssertEqual(vt_select(live, 0, 0, 0), 0)
        XCTAssertEqual(try copiedText(), "")
    }

    /// Regression: the bridge dereferenced NULL data with a nonzero length
    /// and NULL gesture input/output instead of rejecting the call.
    func testBridgeRejectsNullBuffersWithNonzeroLength() throws {
        var handle: OpaquePointer?
        XCTAssertEqual(vt_create(10, 4, 0, 0, nil, 0, &handle), 0)
        let live = try XCTUnwrap(handle)
        defer { vt_destroy(live) }
        let invalid: Int32 = -2
        XCTAssertEqual(vt_write(live, nil, 1), invalid)
        XCTAssertEqual(vt_write(live, nil, 0), 0)
        XCTAssertEqual(vt_paste(live, nil, 1, false), invalid)
        XCTAssertEqual(vt_key(live, 4, 1, 0, 0, 0x61, nil, 1), invalid)
        var input = VTGestureInput()
        var result = VTGestureResult()
        XCTAssertEqual(vt_selection_gesture(live, nil, &result), invalid)
        XCTAssertEqual(vt_selection_gesture(live, &input, nil), invalid)
        // Rejections never poison the handle.
        XCTAssertEqual(vt_write(live, Array("ok".utf8), 2), 0)
    }
}
