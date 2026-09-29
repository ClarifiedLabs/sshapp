import XCTest
@testable import GhosttyVT
@testable import GhosttyTerminal
@testable import SSHApp

/// Exercise the packaged actor and native viewport, without remote echo or UI scrolling.
@MainActor
final class VTInputViewportTests: XCTestCase {
    private func pointer(
        _ frame: VTFrameValue, id: UInt64, phase: VTPointerRequest.Phase,
        point: CGPoint = CGPoint(x: 25, y: 10), word: Bool = false
    ) -> VTPointerRequest {
        .init(id: id, terminalID: frame.terminalID, generation: frame.layout.generation,
              revision: frame.revision, phase: phase, source: .pointer, point: point,
              time: id, selectionBehavior: word ? .word : nil)
    }

    private func seedHistory(
        in session: VTTerminalSession
    ) async throws -> (bottom: VTFrameValue, history: VTFrameValue) {
        session.updateViewport(.init(width: 320, height: 80, cellWidth: 10,
                                     cellHeight: 20, scale: 1, padding: 0))
        let lines = (0..<60).map { String(format: "history%02d", $0) + "\r\n" }.joined()
        XCTAssertTrue(session.receiveIfSurfaceAttached(Data((lines + "prompt> ").utf8)))
        let bottom = try await session.snapshot()
        let scroll = try XCTUnwrap(session.enqueueScrollPointer(.init(
            terminalID: bottom.terminalID, generation: bottom.layout.generation,
            point: CGPoint(x: 25, y: 10), delta: CGPoint(x: 0, y: 10_000), modifiers: [])))
        let scrollBytes = try await scroll.value
        XCTAssertTrue(scrollBytes.isEmpty)
        let select = try XCTUnwrap(session.enqueueSelect(.word, at: .init(column: 2, row: 0),
                                                         generation: bottom.layout.generation))
        try await select.value
        let history = try await session.snapshot()
        XCTAssertEqual(history.viewport.offset, 0)
        XCTAssertTrue(history.viewport.canScrollDown)
        XCTAssertNotNil(history.selection)
        let selectedText = await session.selectedText()
        XCTAssertEqual(selectedText, "history00")
        return (bottom, history)
    }

    private struct HistoryFixture {
        let terminal: VTTerminal
        let bottom: VTFrameValue
        let history: VTFrameValue
        let selectedText: String
    }

    private func makeHistory(modes: String = "") async throws -> HistoryFixture {
        let layout = try VTLayout(generation: 1, width: 320, height: 80,
                                  cellWidth: 10, cellHeight: 20, scale: 1, padding: 0)
        let terminal = try VTTerminal(layout: layout)
        let lines = (0..<60).map { String(format: "history%02d", $0) + "\r\n" }.joined()
        let output = try await terminal.ingest(Data((modes + lines + "prompt> ").utf8))
        XCTAssertEqual(output.replies, Data())
        let bottom = try await terminal.snapshot()
        XCTAssertEqual(bottom.viewport.rows, 4)
        XCTAssertEqual(bottom.viewport.totalRows, 61)
        XCTAssertEqual(bottom.viewport.offset, 57)
        XCTAssertFalse(bottom.viewport.canScrollDown)
        XCTAssertTrue(bottom.line(3).hasPrefix("prompt> "))

        try await terminal.scroll(rows: -10_000)
        try await terminal.select(.word, at: .init(column: 2, row: 0), generation: layout.generation)
        let history = try await terminal.snapshot()
        let selectedText = try await terminal.selectedText()
        XCTAssertEqual(history.viewport.offset, 0)
        XCTAssertTrue(history.viewport.canScrollDown)
        XCTAssertTrue(history.line(0).hasPrefix("history00"))
        XCTAssertNotNil(history.selection)
        XCTAssertEqual(selectedText, "history00")
        return HistoryFixture(terminal: terminal, bottom: bottom, history: history,
                              selectedText: selectedText)
    }

    private func assertReturnsToBottom(
        _ input: VTInput, bytes expected: Data, in fixture: HistoryFixture,
        preservesSelection: Bool = false, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let bytes = try await fixture.terminal.input(input)
        let latest = try await fixture.terminal.snapshot()
        let selectedText = try await fixture.terminal.selectedText()
        XCTAssertEqual(bytes, expected, file: file, line: line)
        XCTAssertGreaterThan(latest.revision, fixture.history.revision, file: file, line: line)
        XCTAssertEqual(latest.viewport, fixture.bottom.viewport, file: file, line: line)
        XCTAssertEqual(latest.viewport.offset, latest.viewport.totalRows - latest.viewport.rows,
                       file: file, line: line)
        XCTAssertFalse(latest.viewport.canScrollDown, file: file, line: line)
        XCTAssertEqual(latest.scrollbackRows, fixture.bottom.scrollbackRows, file: file, line: line)
        XCTAssertEqual(latest.text, fixture.bottom.text, "Input must not need echo to reveal the prompt",
                       file: file, line: line)
        if preservesSelection {
            XCTAssertNotNil(latest.selection, file: file, line: line)
            XCTAssertEqual(selectedText, fixture.selectedText, file: file, line: line)
        } else {
            XCTAssertNil(latest.selection, file: file, line: line)
            XCTAssertEqual(selectedText, "", file: file, line: line)
        }

        // Returning to the prompt must not discard scrollback or mutate an owned old frame.
        XCTAssertEqual(fixture.history.viewport.offset, 0, file: file, line: line)
        XCTAssertTrue(fixture.history.line(0).hasPrefix("history00"), file: file, line: line)
        try await fixture.terminal.scroll(rows: -10_000)
        let retained = try await fixture.terminal.snapshot()
        XCTAssertEqual(retained.viewport, fixture.history.viewport, file: file, line: line)
        XCTAssertEqual(retained.text, fixture.history.text, file: file, line: line)
        XCTAssertEqual(retained.scrollbackRows, fixture.history.scrollbackRows, file: file, line: line)
    }

    func testCommittedTextReturnsToBottomAndClearsSelectionWithoutPasteEncoding() async throws {
        for text in ["hello", "漢字🙂", "one\ntwo"] {
            let fixture = try await makeHistory(modes: "\u{1B}[?2004h")
            try await assertReturnsToBottom(.text(text), bytes: Data(text.utf8), in: fixture)
            _ = try await fixture.terminal.retire()
        }
    }

    func testEncodedNonmodifierKeysReturnToBottomAndClearSelection() async throws {
        let cases: [(VTKey, Data)] = [
            (VTKey(hid: 4, text: "a", unshifted: 97), Data("a".utf8)),
            (VTKey(hid: 82), Data("\u{1B}[A".utf8)),
            (VTKey(hid: 40), Data([0x0D])),
            (VTKey(hid: 42), Data([0x7F])),
            (VTKey(hid: 6, text: "c", modifiers: .control, unshifted: 99), Data([0x03])),
            (VTKey(hid: 4, text: "a", unshifted: 97, action: .repeatPress), Data("a".utf8))
        ]
        for (key, bytes) in cases {
            let fixture = try await makeHistory()
            try await assertReturnsToBottom(.key(key), bytes: bytes, in: fixture)
            _ = try await fixture.terminal.retire()
        }
    }

    func testKittyEncodedReleaseAlsoReturnsToBottomAndClearsSelection() async throws {
        let fixture = try await makeHistory(modes: "\u{1B}[>11u")
        XCTAssertEqual(fixture.history.kittyKeyboardFlags, 11)
        let key = VTKey(hid: 4, text: "a", unshifted: 97, action: .release)
        try await assertReturnsToBottom(.key(key), bytes: Data("\u{1B}[97;1:3u".utf8), in: fixture)
        _ = try await fixture.terminal.retire()
    }

    func testAcceptedPasteReturnsToBottomButPreservesSelection() async throws {
        let cases: [(String, VTInput, String)] = [
            ("", .paste("hello"), "hello"),
            ("", .paste("one\ntwo", allowUnsafe: true), "one\rtwo"),
            ("\u{1B}[?2004h", .paste("漢字🙂"), "\u{1B}[200~漢字🙂\u{1B}[201~")
        ]
        for (modes, input, expected) in cases {
            let fixture = try await makeHistory(modes: modes)
            try await assertReturnsToBottom(input, bytes: Data(expected.utf8), in: fixture,
                                            preservesSelection: true)
            _ = try await fixture.terminal.retire()
        }
    }

    func testEmptyIgnoredModifierAndNormalReleaseInputsLeaveHistoryUnchanged() async throws {
        let fixture = try await makeHistory()
        var inputs: [VTInput] = [
            .text(""), .paste(""), .key(VTKey(hid: 0)),
            .key(VTKey(hid: 4, text: "a", unshifted: 97, action: .release))
        ]
        // USB HID E0...E7 are modifiers, not typing, even if the encoder is invoked.
        inputs += (UInt16(0xE0)...UInt16(0xE7)).map { .key(VTKey(hid: $0)) }
        for input in inputs {
            let bytes = try await fixture.terminal.input(input)
            let latest = try await fixture.terminal.snapshot()
            let selectedText = try await fixture.terminal.selectedText()
            XCTAssertEqual(bytes, Data())
            XCTAssertEqual(latest, fixture.history, "No-op input must not change viewport, selection or revision")
            XCTAssertEqual(selectedText, fixture.selectedText)
        }
        _ = try await fixture.terminal.retire()
    }

    func testRejectedUnsafePasteDoesNotMoveViewportOrClearSelectionOrLeakBytes() async throws {
        let fixture = try await makeHistory()
        do {
            _ = try await fixture.terminal.input(.paste("one\ntwo"))
            XCTFail("Multiline paste must require confirmation")
        } catch {
            XCTAssertEqual(error as? VTError, .unsafePaste)
        }
        let latest = try await fixture.terminal.snapshot()
        let selectedText = try await fixture.terminal.selectedText()
        XCTAssertEqual(latest, fixture.history)
        XCTAssertEqual(selectedText, fixture.selectedText)
        // Disabled focus reporting drains the native reply queue without producing bytes.
        let pending = try await fixture.terminal.input(.focus(true))
        XCTAssertEqual(pending, Data())
        _ = try await fixture.terminal.retire()
    }

    func testIncomingOutputDSRFocusAndMouseReportsDoNotReturnToBottom() async throws {
        // Enable tracking before creating the selection: enabling tracking itself revokes selection.
        let fixture = try await makeHistory(modes: "\u{1B}[?1004h\u{1B}[?1000h\u{1B}[?1006h")
        // Change only the active screen (no newline), then request a cursor-position report.
        let output = try await fixture.terminal.ingest(Data("remote\u{1B}[6n".utf8))
        XCTAssertEqual(output.replies, Data("\u{1B}[4;15R".utf8))
        let afterOutput = try await fixture.terminal.snapshot()
        let selectedAfterOutput = try await fixture.terminal.selectedText()
        XCTAssertGreaterThan(afterOutput.revision, fixture.history.revision)
        XCTAssertEqual(afterOutput.viewport, fixture.history.viewport)
        XCTAssertEqual(afterOutput.scrollbackRows, fixture.history.scrollbackRows)
        XCTAssertEqual(afterOutput.text, fixture.history.text)
        XCTAssertEqual(afterOutput.selection, fixture.history.selection)
        XCTAssertEqual(selectedAfterOutput, fixture.selectedText)

        let reports: [(VTInput, String)] = [
            (.focus(true), "\u{1B}[I"),
            (.focus(false), "\u{1B}[O"),
            (.mouse(action: 0, button: 1, modifiers: [], point: CGPoint(x: 5, y: 10),
                    pressed: true, generation: 1), "\u{1B}[<0;1;1M"),
            (.mouse(action: 1, button: 1, modifiers: [], point: CGPoint(x: 5, y: 10),
                    pressed: false, generation: 1), "\u{1B}[<0;1;1m")
        ]
        for (input, expected) in reports {
            let bytes = try await fixture.terminal.input(input)
            let latest = try await fixture.terminal.snapshot()
            let selectedText = try await fixture.terminal.selectedText()
            XCTAssertEqual(bytes, Data(expected.utf8))
            XCTAssertEqual(latest, afterOutput, "Protocol reports are not typing")
            XCTAssertEqual(selectedText, fixture.selectedText)
        }
        _ = try await fixture.terminal.retire()
    }

    func testHeldWordSelectionIsRevokedByTextAndKeyBeforeAnyPointerMovement() async throws {
        let inputs: [(VTInput, Data)] = [
            (.text("typed"), Data("typed".utf8)),
            (.key(VTKey(hid: 82)), Data("\u{1B}[A".utf8))
        ]
        for (input, expected) in inputs {
            let fixture = try await makeHistory()
            let id: UInt64 = 41
            let press = try await fixture.terminal.pointer(pointer(fixture.history, id: id,
                                                                   phase: .press, word: true))
            XCTAssertTrue(press.active)
            XCTAssertTrue(press.localSelection)
            XCTAssertTrue(press.bytes.isEmpty)
            let held = try await fixture.terminal.snapshot()
            XCTAssertNotNil(held.selection)
            XCTAssertNil(held.revokedSelectionPointerID)

            let bytes = try await fixture.terminal.input(input)
            let latest = try await fixture.terminal.snapshot()
            let selectedText = try await fixture.terminal.selectedText()
            XCTAssertEqual(bytes, expected)
            XCTAssertGreaterThan(latest.revision, held.revision)
            XCTAssertEqual(latest.revokedSelectionPointerID, id)
            XCTAssertNil(latest.selection)
            XCTAssertEqual(selectedText, "")
            XCTAssertEqual(latest.viewport, fixture.bottom.viewport)
            XCTAssertEqual(latest.text, fixture.bottom.text)

            // Requests still carry the press frame: none may revive the canceled gesture.
            for phase: VTPointerRequest.Phase in [.move, .autoscroll, .release] {
                let stale = try await fixture.terminal.pointer(pointer(fixture.history, id: id,
                    phase: phase, point: CGPoint(x: 95, y: 70), word: true))
                XCTAssertFalse(stale.active)
                XCTAssertFalse(stale.localSelection)
                XCTAssertTrue(stale.bytes.isEmpty)
                let afterStale = try await fixture.terminal.snapshot()
                XCTAssertEqual(afterStale, latest)
            }
            let pending = try await fixture.terminal.input(.focus(true))
            XCTAssertTrue(pending.isEmpty)
            _ = try await fixture.terminal.retire()
        }
    }

    func testTypingDoesNotRevokeHeldRemoteMousePressOrLoseItsRelease() async throws {
        let fixture = try await makeHistory(modes: "\u{1B}[?1000h\u{1B}[?1006h")
        let id: UInt64 = 42
        let press = try await fixture.terminal.pointer(pointer(fixture.history, id: id, phase: .press))
        XCTAssertTrue(press.active)
        XCTAssertFalse(press.localSelection)
        XCTAssertEqual(press.bytes, Data("\u{1B}[<0;3;1M".utf8))
        let bytes = try await fixture.terminal.input(.text("x"))
        let latest = try await fixture.terminal.snapshot()
        XCTAssertEqual(bytes, Data("x".utf8), "Typing must not synthesize a mouse release")
        XCTAssertNil(latest.revokedSelectionPointerID)
        XCTAssertEqual(latest.viewport, fixture.bottom.viewport)
        XCTAssertEqual(latest.text, fixture.bottom.text)
        XCTAssertNil(latest.selection)

        let release = try await fixture.terminal.pointer(pointer(fixture.history, id: id, phase: .release))
        XCTAssertFalse(release.active)
        XCTAssertEqual(release.bytes, Data("\u{1B}[<0;3;1m".utf8))
        let afterRelease = try await fixture.terminal.snapshot()
        XCTAssertEqual(afterRelease, latest)
        let retiredBytes = try await fixture.terminal.retire()
        XCTAssertTrue(retiredBytes.isEmpty, "The matched release must not be sent twice")
    }

    func testSessionRawControlBytesPreserveHistoryButUserTextPublishesBottomWithoutEcho() async throws {
        let writes = LockBox<[Data]>([])
        let session = VTTerminalSession(write: { data in writes.mutate { $0.append(data) } }, resize: { _ in })
        defer { session.finish() }
        let frames = try await seedHistory(in: session)
        var notifications = 0
        session.onFramesAvailable = { notifications += 1 }

        let raw = Data("\u{1B}[0n".utf8)
        session.sendInput(raw)
        let afterRaw = try await session.snapshot() // FIFO barrier, not a remote echo.
        let selectionAfterRaw = await session.selectedText()
        XCTAssertEqual(afterRaw, frames.history)
        XCTAssertEqual(selectionAfterRaw, "history00")
        XCTAssertEqual(writes.get(), [raw])
        XCTAssertEqual(notifications, 0)

        let input = try XCTUnwrap(session.enqueueInput(.text("漢字🙂")))
        let bytes = try await input.value
        let latest = try await session.snapshot()
        let selectionAfterText = await session.selectedText()
        XCTAssertEqual(bytes, Data("漢字🙂".utf8))
        XCTAssertEqual(writes.get(), [raw, bytes])
        XCTAssertGreaterThan(notifications, 0)
        XCTAssertGreaterThan(latest.revision, frames.history.revision)
        XCTAssertEqual(latest.viewport, frames.bottom.viewport)
        XCTAssertEqual(latest.text, frames.bottom.text)
        XCTAssertNil(latest.selection)
        XCTAssertEqual(selectionAfterText, "")
    }

    func testWindowlessSoftwareKeyboardDirectRouteFollowsSeededSessionViewport() async throws {
        let writes = LockBox<[Data]>([])
        let session = VTTerminalSession(write: { data in writes.mutate { $0.append(data) } }, resize: { _ in })
        defer { session.finish() }
        let host = ShortcutAwareTerminalView(frame: .zero)
        host.configuration = TerminalSurfaceOptions(backend: .vt(session))
        let frames = try await seedHistory(in: session)
        XCTAssertNil(host.window)

        host.insertText("direct")

        let latest = try await session.snapshot()
        XCTAssertEqual(writes.get(), [Data("direct".utf8)])
        XCTAssertGreaterThan(latest.revision, frames.history.revision)
        XCTAssertEqual(latest.viewport, frames.bottom.viewport)
        XCTAssertEqual(latest.text, frames.bottom.text)
        XCTAssertNil(latest.selection)
        let selectedText = await session.selectedText()
        XCTAssertEqual(selectedText, "")
    }

    private func assertNoEngine(in session: VTTerminalSession) async throws {
        // Configuration is a FIFO barrier that does not create an engine.
        let barrier = try XCTUnwrap(session.enqueueConfiguration(VTTerminalConfiguration()))
        try await barrier.value
        do {
            _ = try await session.snapshot()
            XCTFail("Software keyboard input must not create an engine before a viewport exists")
        } catch {
            XCTAssertEqual(error as? VTError, .retired)
        }
    }

    func testWindowlessShellCoordinatorPreEngineTextAndReturnAreForwardedExactlyOnce() async throws {
        let writes = LockBox<[Data]>([])
        let session = VTTerminalSession(write: { data in writes.mutate { $0.append(data) } }, resize: { _ in })
        defer { session.finish() }
        let host = ShortcutAwareTerminalView(frame: .zero)
        host.configuration = TerminalSurfaceOptions(backend: .vt(session))
        let coordinator = GhosttyTerminalView.Coordinator()
        coordinator.terminalSession = session
        coordinator.updateHostTabActiveState(false, view: host)
        host.onSoftwareKeyboardReturn = { coordinator.forwardSoftwareKeyboardReturn() }
        XCTAssertNil(host.window)

        // Invoke directly so UIKit's own hidden-host guard cannot mask a coordinator regression.
        coordinator.forwardSoftwareKeyboardReturn()
        try await assertNoEngine(in: session)
        XCTAssertTrue(writes.get().isEmpty)

        coordinator.updateHostTabActiveState(true)
        host.insertText("漢字🙂")
        host.insertText("\n")

        try await assertNoEngine(in: session)
        XCTAssertEqual(writes.get(), [Data("漢字🙂".utf8), Data([0x0D])])
    }

    func testWindowlessTmuxCoordinatorPreEngineReturnIsForwardedExactlyOnce() async throws {
        let writes = LockBox<[Data]>([])
        let session = VTTerminalSession(write: { data in writes.mutate { $0.append(data) } }, resize: { _ in })
        defer { session.finish() }
        let host = ShortcutAwareTerminalView(frame: .zero)
        host.configuration = TerminalSurfaceOptions(backend: .vt(session))
        let coordinator = TmuxPaneTerminal.Coordinator()
        coordinator.terminalSession = session
        host.onSoftwareKeyboardReturn = { coordinator.forwardSoftwareKeyboardReturn() }
        XCTAssertNil(host.window)

        coordinator.updateFocusedState(true)
        coordinator.updateHostVisibility(false, view: host)
        coordinator.forwardSoftwareKeyboardReturn()
        try await assertNoEngine(in: session)
        XCTAssertTrue(writes.get().isEmpty)

        coordinator.updateHostVisibility(true, view: host)
        coordinator.updateFocusedState(false)
        coordinator.forwardSoftwareKeyboardReturn()
        try await assertNoEngine(in: session)
        XCTAssertTrue(writes.get().isEmpty)

        coordinator.updateFocusedState(true)
        host.insertText("\n")
        try await assertNoEngine(in: session)
        XCTAssertEqual(writes.get(), [Data([0x0D])])
    }

    private func assertCoordinatorReturnIsIgnored(
        in session: VTTerminalSession, writes: LockBox<[Data]>, forward: () -> Void
    ) async throws {
        let before = try await session.snapshot()
        let previousWrites = writes.get()
        forward()
        let after = try await session.snapshot()
        let selectedText = await session.selectedText()
        XCTAssertEqual(after, before, "Rejected Return must not change viewport, selection or revision")
        XCTAssertEqual(selectedText, "history00")
        XCTAssertEqual(writes.get(), previousWrites)
    }

    private func assertCoordinatorReturnFollowsBottom(
        host: ShortcutAwareTerminalView, session: VTTerminalSession, writes: LockBox<[Data]>,
        frames: (bottom: VTFrameValue, history: VTFrameValue)
    ) async throws {
        host.insertText("\n")
        let latest = try await session.snapshot()
        let selectedText = await session.selectedText()
        XCTAssertEqual(writes.get(), [Data([0x0D])])
        XCTAssertGreaterThan(latest.revision, frames.history.revision)
        XCTAssertEqual(latest.viewport, frames.bottom.viewport)
        XCTAssertFalse(latest.viewport.canScrollDown)
        XCTAssertEqual(latest.scrollbackRows, frames.bottom.scrollbackRows)
        XCTAssertEqual(latest.text, frames.bottom.text, "Return must reveal the prompt without remote echo")
        XCTAssertNil(latest.selection)
        XCTAssertEqual(selectedText, "")
    }

    func testShellCoordinatorReturnFollowsBottomAndClearsSelectionOnlyWhenVisible() async throws {
        let writes = LockBox<[Data]>([])
        let session = VTTerminalSession(write: { data in writes.mutate { $0.append(data) } }, resize: { _ in })
        defer { session.finish() }
        let host = ShortcutAwareTerminalView(frame: .zero)
        host.configuration = TerminalSurfaceOptions(backend: .vt(session))
        let coordinator = GhosttyTerminalView.Coordinator()
        coordinator.terminalSession = session
        host.onSoftwareKeyboardReturn = { coordinator.forwardSoftwareKeyboardReturn() }
        let frames = try await seedHistory(in: session)

        coordinator.updateHostTabActiveState(false, view: host)
        try await assertCoordinatorReturnIsIgnored(in: session, writes: writes) {
            coordinator.forwardSoftwareKeyboardReturn()
        }
        coordinator.updateHostTabActiveState(true)
        host.isHostVisible = false
        try await assertCoordinatorReturnIsIgnored(in: session, writes: writes) {
            coordinator.forwardSoftwareKeyboardReturn()
        }

        host.isHostVisible = true
        try await assertCoordinatorReturnFollowsBottom(host: host, session: session,
                                                       writes: writes, frames: frames)
    }

    func testTmuxCoordinatorReturnFollowsBottomAndClearsSelectionOnlyWhenVisibleAndFocused() async throws {
        let writes = LockBox<[Data]>([])
        let session = VTTerminalSession(write: { data in writes.mutate { $0.append(data) } }, resize: { _ in })
        defer { session.finish() }
        let host = ShortcutAwareTerminalView(frame: .zero)
        host.configuration = TerminalSurfaceOptions(backend: .vt(session))
        let coordinator = TmuxPaneTerminal.Coordinator()
        coordinator.terminalSession = session
        host.onSoftwareKeyboardReturn = { coordinator.forwardSoftwareKeyboardReturn() }
        let frames = try await seedHistory(in: session)

        coordinator.updateFocusedState(true)
        coordinator.updateHostVisibility(false, view: host)
        try await assertCoordinatorReturnIsIgnored(in: session, writes: writes) {
            coordinator.forwardSoftwareKeyboardReturn()
        }
        coordinator.updateHostVisibility(true, view: host)
        coordinator.updateFocusedState(false)
        try await assertCoordinatorReturnIsIgnored(in: session, writes: writes) {
            coordinator.forwardSoftwareKeyboardReturn()
        }

        coordinator.updateFocusedState(true)
        try await assertCoordinatorReturnFollowsBottom(host: host, session: session,
                                                       writes: writes, frames: frames)
    }

    func testTypingInOneTerminalDoesNotMoveOrClearAnotherTerminal() async throws {
        let first = try await makeHistory()
        let second = try await makeHistory()
        XCTAssertNotEqual(first.history.terminalID, second.history.terminalID)
        let bytes = try await first.terminal.input(.text("first"))
        let firstLatest = try await first.terminal.snapshot()
        let secondLatest = try await second.terminal.snapshot()
        let secondSelection = try await second.terminal.selectedText()
        XCTAssertEqual(bytes, Data("first".utf8))
        XCTAssertEqual(firstLatest.viewport, first.bottom.viewport)
        XCTAssertEqual(firstLatest.text, first.bottom.text)
        XCTAssertGreaterThan(firstLatest.revision, first.history.revision)
        XCTAssertNil(firstLatest.selection)
        XCTAssertEqual(secondLatest, second.history)
        XCTAssertEqual(secondSelection, second.selectedText)

        // A paste in the second terminal follows its own viewport and selection rules.
        try await assertReturnsToBottom(.paste("second"), bytes: Data("second".utf8),
                                       in: second, preservesSelection: true)
        let firstAfterSecondInput = try await first.terminal.snapshot()
        XCTAssertEqual(firstAfterSecondInput, firstLatest)
        _ = try await first.terminal.retire()
        _ = try await second.terminal.retire()
    }
}
