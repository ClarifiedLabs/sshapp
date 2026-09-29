import XCTest
import GhosttyVT
@testable import GhosttyTerminal

@MainActor
final class VTSessionMetadataTests: XCTestCase {
    private final class Probe: TerminalSurfaceTitleDelegate, TerminalSurfacePwdDelegate,
        TerminalSurfaceProgressReportDelegate, TerminalSurfaceBellDelegate,
        TerminalSurfaceDesktopNotificationDelegate {
        var events: [VTEvent] = []
        var onTitle: (() -> Void)?

        func terminalDidChangeTitle(_ title: String) {
            events.append(.title(title))
            onTitle?()
        }

        func terminalDidChangeWorkingDirectory(_ path: String) {
            events.append(.workingDirectory(path))
        }

        func terminalDidReportProgress(state: TerminalProgressState, percent: Int?) {
            let native: VTProgressState
            switch state {
            case .remove: native = .remove
            case .set: native = .set
            case .error: native = .error
            case .indeterminate: native = .indeterminate
            case .pause: native = .pause
            }
            events.append(.progress(native, percent: percent))
        }

        func terminalDidRingBell() { events.append(.bell) }

        func terminalDidRequestDesktopNotification(title: String, body: String) {
            events.append(.notification(title: title, body: body))
        }
    }

    private func makeSession() -> VTTerminalSession {
        let session = VTTerminalSession(write: { _ in }, resize: { _ in })
        session.updateViewport(.init(width: 390, height: 480, cellWidth: 10, cellHeight: 20, scale: 2))
        return session
    }

    private func osc(_ payload: String) -> String { "\u{1B}]\(payload)\u{1B}\\" }

    private func feed(_ text: String, to session: VTTerminalSession) async {
        let accepted = await withCheckedContinuation { continuation in
            session.deliver(Data(text.utf8), ifCurrent: { true }) {
                continuation.resume(returning: $0)
            }
        }
        XCTAssertTrue(accepted)
    }

    func testDetachedOSCZeroTwoAndSevenReplayOnlyCurrentValuesOnPublicBind() async {
        let session = makeSession()
        defer { session.finish() }
        await feed(osc("0;first 日本") + osc("7;file://remote.example/old"), to: session)
        for index in 0..<32 {
            await feed(osc("2;title-\(index)"), to: session)
        }
        await feed(osc("7;file://remote.example/home/a%20b"), to: session)

        let probe = Probe()
        session.eventDelegate = probe
        XCTAssertEqual(probe.events, [.title("title-31"), .workingDirectory("file://remote.example/home/a%20b")])
        session.eventDelegate = probe
        XCTAssertEqual(probe.events.count, 2, "An unchanged binding must not replay again")
    }

    func testDetachedEmptyClearsAndProgressRemovalSurviveOwnerRemount() async {
        let session = makeSession()
        defer { session.finish() }
        let probe = Probe()
        let firstOwner = UUID()
        session.setEventDelegate(probe, owner: firstOwner)
        await feed(osc("2;old") + osc("7;/old") + osc("9;4;1;42"), to: session)
        XCTAssertEqual(probe.events, [.title("old"), .workingDirectory("/old"), .progress(.set, percent: 42)])
        session.clearEventDelegate(owner: firstOwner)
        await feed(osc("0;") + osc("7;") + osc("9;4;0"), to: session)
        probe.events.removeAll()
        session.setEventDelegate(probe, owner: UUID())
        XCTAssertEqual(probe.events, [.title(""), .workingDirectory(""), .progress(.remove, percent: nil)])
    }

    func testLiveMetadataIsNotCoalescedOrDuplicatedAndReplayContainsOnlyLatest() async {
        let session = makeSession()
        defer { session.finish() }
        let live = Probe()
        session.eventDelegate = live
        XCTAssertTrue(live.events.isEmpty, "No invented metadata before the first OSC")
        await feed(osc("0;one") + osc("7;/one") + osc("2;two") + osc("7;/two")
            + osc("9;4;1;42") + osc("9;4;3") + osc("2;"), to: session)
        XCTAssertEqual(live.events, [.title("one"), .workingDirectory("/one"), .title("two"),
            .workingDirectory("/two"), .progress(.set, percent: 42),
            .progress(.indeterminate, percent: nil), .title("")])
        let replacement = Probe()
        session.eventDelegate = replacement
        XCTAssertEqual(replacement.events, [.workingDirectory("/two"),
            .progress(.indeterminate, percent: nil), .title("")])
        await feed(osc("2;next"), to: session)
        XCTAssertEqual(replacement.events.last, .title("next"))
        XCTAssertEqual(replacement.events.count, 4)
        XCTAssertEqual(live.events.count, 7)
    }

    func testBellsAndNotificationsAreLiveOnlyNeverReplayed() async {
        let session = makeSession()
        defer { session.finish() }
        let probe = Probe()
        session.eventDelegate = probe
        let transient = "\u{7}" + osc("777;notify;notice;body")
        await feed(osc("2;kept") + transient, to: session)
        XCTAssertEqual(probe.events, [.title("kept"), .bell, .notification(title: "notice", body: "body")])
        session.eventDelegate = nil
        await feed(transient + osc("9;detached body"), to: session)
        probe.events.removeAll()
        session.setEventDelegate(probe, owner: UUID())
        XCTAssertEqual(probe.events, [.title("kept")])
    }

    func testNewOwnerWithSameDelegateReplaysAndLateCleanupCannotClearIt() async {
        let session = makeSession()
        defer { session.finish() }
        await feed(osc("2;retained"), to: session)
        let probe = Probe()
        let oldOwner = UUID()
        let newOwner = UUID()
        session.setEventDelegate(probe, owner: oldOwner)
        session.setEventDelegate(probe, owner: newOwner)
        session.clearEventDelegate(owner: oldOwner)
        session.setEventDelegate(probe, owner: newOwner)
        XCTAssertTrue(session.eventDelegate === probe)
        XCTAssertEqual(probe.events, [.title("retained"), .title("retained")])
        await feed(osc("2;live"), to: session)
        XCTAssertEqual(probe.events.last, .title("live"))
        session.clearEventDelegate(owner: newOwner)
        XCTAssertNil(session.eventDelegate)
    }

    func testReentrantReplayReplacementStopsOldReplayAndLateCleanup() async {
        let session = makeSession()
        defer { session.finish() }
        await feed(osc("2;retained") + osc("7;/retained") + osc("9;4;1;42"), to: session)
        let old = Probe()
        let replacement = Probe()
        let oldOwner = UUID()
        let newOwner = UUID()
        old.onTitle = {
            session.setEventDelegate(replacement, owner: newOwner)
            session.clearEventDelegate(owner: oldOwner)
        }
        session.setEventDelegate(old, owner: oldOwner)
        XCTAssertEqual(old.events, [.title("retained")])
        XCTAssertEqual(replacement.events, [.title("retained"), .workingDirectory("/retained"),
            .progress(.set, percent: 42)])
        XCTAssertTrue(session.eventDelegate === replacement)
    }

    func testReentrantReplayWithSameDelegateAndNewOwnerDoesNotResumeOldReplay() async {
        let session = makeSession()
        defer { session.finish() }
        await feed(osc("2;retained") + osc("7;/retained"), to: session)
        let probe = Probe()
        let oldOwner = UUID()
        let newOwner = UUID()
        probe.onTitle = { [weak probe] in
            probe?.onTitle = nil
            session.setEventDelegate(probe, owner: newOwner)
            session.clearEventDelegate(owner: oldOwner)
        }
        session.setEventDelegate(probe, owner: oldOwner)
        XCTAssertEqual(probe.events, [.title("retained"), .title("retained"), .workingDirectory("/retained")])
        XCTAssertTrue(session.eventDelegate === probe)
    }

    func testReentrantLiveReplacementResolvesDelegateForEveryEvent() async {
        let session = makeSession()
        defer { session.finish() }
        let old = Probe()
        let replacement = Probe()
        old.onTitle = { session.eventDelegate = replacement }
        session.eventDelegate = old
        await feed(osc("2;one") + osc("2;two") + osc("7;/next") + "\u{7}", to: session)
        XCTAssertEqual(old.events, [.title("one")])
        XCTAssertEqual(replacement.events, [.title("one"), .title("two"), .workingDirectory("/next"), .bell])
    }

    func testMetadataDoesNotRetainDelegate() async {
        let session = makeSession()
        defer { session.finish() }
        var probe: Probe? = Probe()
        weak let weakProbe = probe
        session.eventDelegate = probe
        await feed(osc("2;retained"), to: session)
        probe = nil
        XCTAssertNil(weakProbe)
        XCTAssertNil(session.eventDelegate)
        let replacement = Probe()
        session.eventDelegate = replacement
        XCTAssertEqual(replacement.events, [.title("retained")])
    }

    func testSurfaceReplacedDuringReplayDoesNotInstallRetiredSurface() async throws {
        let session = makeSession()
        defer { session.finish() }
        await feed(osc("2;retained"), to: session)
        let core = TerminalSurfaceCoordinator()
        defer { core.freeSurface() }
        let probe = Probe()
        var retired: TerminalSurface?
        var installed: [TerminalSurface] = []
        core.isAttached = { true }
        core.viewSize = { (390, 480) }
        core.configuration = .init(backend: .vt(session))
        core.delegate = probe
        core.onSurfaceCreated = { installed.append($0) }
        probe.onTitle = { [weak core, weak probe] in
            probe?.onTitle = nil
            retired = core?.surface
            core?.rebuildIfReady()
        }
        core.controller = TerminalController()
        let current = try XCTUnwrap(core.surface)
        XCTAssertFalse(current === retired)
        XCTAssertEqual(installed.count, 1)
        XCTAssertTrue(installed.first === current)
        XCTAssertNil(retired?.contentView.onFrame)
        XCTAssertTrue(session.eventDelegate === probe)
        XCTAssertEqual(probe.events, [.title("retained"), .title("retained")])
    }
}
