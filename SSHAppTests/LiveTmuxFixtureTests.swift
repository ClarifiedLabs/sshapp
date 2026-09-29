import XCTest

/// Pure regressions for the live tmux acceptance fixture's commands. They
/// launch nothing, so they run in the unit target instead of the UI runner.
final class LiveTmuxFixtureTests: XCTestCase {
    func testOwnedSessionCommandsAreUniqueExactAndBounded() {
        let first = LiveTmuxFixture()
        let second = LiveTmuxFixture()
        XCTAssertNotEqual(first.sessionName, second.sessionName)
        XCTAssertNotNil(first.sessionName.range(of: #"^sshapp_accept_[a-f0-9]{32}$"#, options: .regularExpression))
        XCTAssertEqual(first.cleanupCommand, "tmux kill-session -t '=\(first.sessionName)'")
        XCTAssertFalse(first.startupCommand.contains("new-session -A"))
        XCTAssertTrue(first.startupCommand.contains("trap"))
        XCTAssertTrue(first.startupCommand.contains("-CC attach-session"))
        XCTAssertTrue(first.hiddenAlphaOutputCommand.contains("-le 32"))
        XCTAssertFalse(first.hiddenAlphaOutputCommand.contains("sleep"))
        XCTAssertFalse(first.hiddenAlphaOutputCommand.contains("kill-server"))
        // OCR must observe formatted output, not the shell's echoed command.
        XCTAssertTrue(first.setupCommand.contains("%04d"))
        XCTAssertFalse(first.setupCommand.contains("SETUP READY 0001"))
        XCTAssertFalse(first.hiddenAlphaOutputCommand.contains("HIDDEN QUEUED 0001"))
        XCTAssertEqual(LiveTmuxFixture.quote("a'b"), "'a'\"'\"'b'")
    }
}
