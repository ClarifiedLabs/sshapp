import CGhosttyVT
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
