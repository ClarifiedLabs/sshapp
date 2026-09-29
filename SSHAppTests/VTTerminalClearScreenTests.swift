import XCTest
@testable import GhosttyVT
@testable import GhosttyTerminal

/// Hosted-app regressions for the actor-atomic native clear and the session FIFO.
@MainActor
final class VTTerminalClearScreenTests: XCTestCase {
    private func layout() throws -> VTLayout {
        try VTLayout(generation: 1, width: 320, height: 80,
                     cellWidth: 10, cellHeight: 20, scale: 1, padding: 0)
    }

    private func key(
        action: VTKey.Action = .press, modifiers: VTModifiers = .command,
        hid: UInt16 = 14, unshifted: UInt32 = 107
    ) -> VTKey {
        VTKey(hid: hid, text: unshifted == 75 ? "K" : "k", modifiers: modifiers,
              unshifted: unshifted, action: action)
    }

    private func clear(_ terminal: VTTerminal) async throws -> Data {
        try await terminal.input(.key(key(), clearScreenBinding: true))
    }

    private func seedHistory(_ terminal: VTTerminal) async throws {
        let history = (0..<20).map { "history\($0)\r\n" }.joined()
        _ = try await terminal.ingest(Data((history
            + "\u{1B}[Habove\u{1B}[2;1Hcurrent\u{1B}[3;1Hbelow\u{1B}[2;4H").utf8))
    }

    func testNonpromptClearRemovesHistoryAndSelectionButPreservesCurrentRowBelowAndModes() async throws {
        let terminal = try VTTerminal(layout: layout())
        try await seedHistory(terminal)
        _ = try await terminal.ingest(Data("\u{1B}[?1h\u{1B}[?2004h\u{1B}[?1004h\u{1B}[?25l\u{1B}[5 q\u{1B}[38;2;19;23;31m".utf8))
        let bottom = try await terminal.snapshot()
        try await terminal.scroll(rows: -10_000)
        try await terminal.select(.word, at: .init(column: 1, row: 0), generation: 1)
        let owned = try await terminal.snapshot()
        let ownedText = owned.text
        XCTAssertGreaterThan(owned.scrollbackRows, 0)
        XCTAssertNotNil(owned.selection)

        let bytes = try await clear(terminal)
        let frame = try await terminal.snapshot()
        let selected = try await terminal.selectedText()
        XCTAssertTrue(bytes.isEmpty, "A nonprompt clear must not send Ctrl-L or Cmd-K")
        XCTAssertEqual(frame.scrollbackRows, 0)
        XCTAssertEqual(frame.viewport.totalRows, frame.viewport.rows)
        XCTAssertFalse(frame.viewport.canScrollDown)
        XCTAssertNil(frame.selection)
        XCTAssertEqual(selected, "")
        XCTAssertEqual(frame.line(0), bottom.line(1))
        XCTAssertEqual(frame.line(1), bottom.line(2))
        XCTAssertEqual(frame.cursorColumn, bottom.cursorColumn)
        XCTAssertEqual(frame.cursorRow, 0, "Native erase removes rows above the cursor")
        XCTAssertEqual(frame.cursorVisible, bottom.cursorVisible)
        XCTAssertEqual(frame.cursorBlinking, bottom.cursorBlinking)
        XCTAssertEqual(frame.cursorStyle, bottom.cursorStyle)
        XCTAssertGreaterThan(frame.revision, owned.revision)
        let arrow = try await terminal.input(.key(VTKey(hid: 82)))
        let paste = try await terminal.input(.paste("paste"))
        let focus = try await terminal.input(.focus(true))
        XCTAssertEqual(arrow, Data("\u{1B}OA".utf8))
        XCTAssertEqual(paste, Data("\u{1B}[200~paste\u{1B}[201~".utf8))
        XCTAssertEqual(focus, Data("\u{1B}[I".utf8))
        _ = try await terminal.ingest(Data("X".utf8))
        let styled = try await terminal.snapshot()
        XCTAssertEqual(styled.cells[bottom.cursorColumn].foreground, VTColor(red: 19, green: 23, blue: 31))
        _ = try await terminal.retire()
        XCTAssertEqual(owned.text, ownedText)
        XCTAssertNotNil(owned.selection, "Owned frames survive native selection/history destruction")
    }

    func testClearAtRowZeroStillDiscardsHistoryWithoutErasingActiveRows() async throws {
        let terminal = try VTTerminal(layout: layout())
        try await seedHistory(terminal)
        _ = try await terminal.ingest(Data("\u{1B}[H".utf8))
        let before = try await terminal.snapshot()
        XCTAssertGreaterThan(before.scrollbackRows, 0)
        let bytes = try await clear(terminal)
        let after = try await terminal.snapshot()
        XCTAssertTrue(bytes.isEmpty)
        XCTAssertEqual(after.scrollbackRows, 0)
        XCTAssertEqual(after.text, before.text)
        XCTAssertEqual(after.cursorColumn, before.cursorColumn)
        XCTAssertEqual(after.cursorRow, 0)
        _ = try await terminal.retire()
    }

    func testSemanticPromptRequestsExactlyLiteralFormFeedUnderKittyKeyboardProtocol() async throws {
        let terminal = try VTTerminal(layout: layout())
        _ = try await terminal.ingest(Data(("\u{1B}[>31uoutput\r\n"
            + "\u{1B}]133;A\u{1B}\\$ \u{1B}]133;B\u{1B}\\typed").utf8))
        let before = try await terminal.snapshot()
        XCTAssertEqual(before.kittyKeyboardFlags, 31)
        let bytes = try await clear(terminal)
        let after = try await terminal.snapshot()
        XCTAssertEqual(bytes, Data([0x0C]), "Shell repaint is literal FF, never a Kitty Ctrl-L event")
        XCTAssertEqual(after.kittyKeyboardFlags, before.kittyKeyboardFlags)
        XCTAssertNil(after.selection)
        // Native prompt erase can move prompt content into history; do not demand zero history here.
        for action: VTKey.Action in [.repeatPress, .release] {
            let suppressed = try await terminal.input(.key(key(action: action, modifiers: []), clearScreenBinding: true))
            XCTAssertTrue(suppressed.isEmpty, "One semantic prompt clear emits only one FF")
        }
        _ = try await terminal.retire()
    }

    func testBindingUsesUnshiftedCharacterAndIgnoresCapsAndNumLock() async throws {
        let cases: [(UInt32, VTModifiers)] = [
            (107, .command), (75, [.command, .capsLock, .numLock])
        ]
        for (unshifted, modifiers) in cases {
            let terminal = try VTTerminal(layout: layout())
            try await seedHistory(terminal)
            // A non-K physical key represents K on another keyboard layout.
            let bytes = try await terminal.input(.key(key(modifiers: modifiers, hid: 7, unshifted: unshifted),
                                                       clearScreenBinding: true))
            let frame = try await terminal.snapshot()
            XCTAssertTrue(bytes.isEmpty)
            XCTAssertEqual(frame.scrollbackRows, 0)
            XCTAssertTrue(frame.line(0).hasPrefix("current"))
            _ = try await terminal.retire()
        }
    }

    func testExtraModifiersOrMissingUnshiftedKUseNormalEncoder() async throws {
        let candidates = [
            key(modifiers: []), key(modifiers: [.command, .shift]),
            key(modifiers: [.command, .control]), key(modifiers: [.command, .alt]),
            key(unshifted: 0), key(unshifted: 106)
        ]
        for candidate in candidates {
            let terminal = try VTTerminal(layout: layout())
            let control = try VTTerminal(layout: layout())
            for engine in [terminal, control] {
                try await seedHistory(engine)
                _ = try await engine.ingest(Data("\u{1B}[>31u".utf8))
            }
            let before = try await terminal.snapshot()
            let expected = try await control.input(.key(candidate))
            let bytes = try await terminal.input(.key(candidate, clearScreenBinding: true))
            let after = try await terminal.snapshot()
            XCTAssertEqual(bytes, expected)
            XCTAssertEqual(after.text, before.text)
            XCTAssertEqual(after.scrollbackRows, before.scrollbackRows)
            _ = try await terminal.retire()
            _ = try await control.retire()
        }
    }

    func testRawKeyDefaultsToEncodingWithoutHostClear() async throws {
        let terminal = try VTTerminal(layout: layout())
        try await seedHistory(terminal)
        _ = try await terminal.ingest(Data("\u{1B}[>31u".utf8))
        let before = try await terminal.snapshot()
        let bytes = try await terminal.input(.key(key()))
        let after = try await terminal.snapshot()
        XCTAssertFalse(bytes.isEmpty)
        XCTAssertNotEqual(bytes, Data([0x0C]))
        XCTAssertEqual(after.text, before.text)
        XCTAssertEqual(after.scrollbackRows, before.scrollbackRows)
        XCTAssertEqual(after.cursorRow, before.cursorRow)
        _ = try await terminal.retire()
    }

    func testAlternateScreenFallbackMatchesRawEncoderInCurrentModes() async throws {
        for modes in ["", "\u{1B}[>31u", "\u{1B}[?1h\u{1B}[?2004h"] {
            let terminal = try VTTerminal(layout: layout())
            let control = try VTTerminal(layout: layout())
            for engine in [terminal, control] {
                _ = try await engine.ingest(Data(("primary\u{1B}[?1049halt\r\nkeep" + modes).utf8))
            }
            let before = try await terminal.snapshot()
            for action: VTKey.Action in [.press, .repeatPress, .release] {
                let candidate = key(action: action)
                let expected = try await control.input(.key(candidate))
                let bytes = try await terminal.input(.key(candidate, clearScreenBinding: true))
                XCTAssertEqual(bytes, expected)
            }
            let after = try await terminal.snapshot()
            XCTAssertEqual(after.text, before.text)
            XCTAssertEqual(after.cursorColumn, before.cursorColumn)
            XCTAssertEqual(after.cursorRow, before.cursorRow)
            XCTAssertEqual(after.kittyKeyboardFlags, before.kittyKeyboardFlags)
            _ = try await terminal.retire()
            _ = try await control.retire()
        }
    }

    func testHandledPrimaryPressCannotLeakRepeatOrReleaseAfterScreenAndModifierChanges() async throws {
        let terminal = try VTTerminal(layout: layout())
        try await seedHistory(terminal)
        _ = try await clear(terminal)
        _ = try await terminal.ingest(Data("\u{1B}[?1049h\u{1B}[>31ualternate".utf8))
        let before = try await terminal.snapshot()
        for action: VTKey.Action in [.repeatPress, .release] {
            let bytes = try await terminal.input(.key(key(action: action, modifiers: [], unshifted: 0),
                                                       clearScreenBinding: true))
            XCTAssertTrue(bytes.isEmpty)
        }
        let after = try await terminal.snapshot()
        XCTAssertEqual(after, before, "A locally owned lifecycle stays local even on a Kitty alternate screen")
        _ = try await terminal.retire()
    }

    func testDeclinedAlternatePressCannotClearPrimaryOnRepeat() async throws {
        let terminal = try VTTerminal(layout: layout())
        let control = try VTTerminal(layout: layout())
        for engine in [terminal, control] {
            try await seedHistory(engine)
            _ = try await engine.ingest(Data("\u{1B}[>31u\u{1B}[?1049h\u{1B}[>31ualternate".utf8))
        }
        let expectedPress = try await control.input(.key(key()))
        let press = try await clear(terminal)
        XCTAssertEqual(press, expectedPress)
        for engine in [terminal, control] {
            _ = try await engine.ingest(Data("\u{1B}[?1049l".utf8))
        }
        let before = try await terminal.snapshot()
        for action: VTKey.Action in [.repeatPress, .release] {
            let candidate = key(action: action)
            let expected = try await control.input(.key(candidate))
            let bytes = try await terminal.input(.key(candidate, clearScreenBinding: true))
            XCTAssertEqual(bytes, expected)
        }
        let after = try await terminal.snapshot()
        XCTAssertEqual(after.text, before.text)
        XCTAssertEqual(after.scrollbackRows, before.scrollbackRows)
        XCTAssertGreaterThan(after.scrollbackRows, 0)
        _ = try await terminal.retire()
        _ = try await control.retire()
    }

    func testFreshUnmodifiedPressResetsHandledKeyWhoseReleaseWasLost() async throws {
        let terminal = try VTTerminal(layout: layout())
        _ = try await terminal.ingest(Data("above\r\ncurrent".utf8))
        _ = try await clear(terminal)
        let before = try await terminal.snapshot()
        for action: VTKey.Action in [.press, .repeatPress] {
            let bytes = try await terminal.input(.key(key(action: action, modifiers: []), clearScreenBinding: true))
            XCTAssertEqual(bytes, Data("k".utf8))
        }
        let after = try await terminal.snapshot()
        XCTAssertEqual(after.text, before.text, "Encoding does not require remote echo")
        _ = try await terminal.retire()
    }

    func testClearDoesNotConsumePartialOSCParserState() async throws {
        let terminal = try VTTerminal(layout: layout())
        _ = try await terminal.ingest(Data("above\r\ncurrent\u{1B}]2;before".utf8))
        let bytes = try await clear(terminal)
        let completion = try await terminal.ingest(Data("-after\u{1B}\\X".utf8))
        let frame = try await terminal.snapshot()
        XCTAssertTrue(bytes.isEmpty)
        XCTAssertEqual(completion.events, [.title("before-after")])
        XCTAssertTrue(completion.replies.isEmpty)
        XCTAssertTrue(frame.line(0).hasPrefix("currentX"))
        _ = try await terminal.retire()
    }

    func testClearPreservesPartialCSIAndUTF8() async throws {
        let cases: [(Data, Data, String)] = [
            (Data("\u{1B}[2;".utf8), Data("3HX".utf8), "X"),
            (Data([0xF0, 0x9F]), Data([0x99, 0x82]), "🙂")
        ]
        for (prefix, suffix, expected) in cases {
            let terminal = try VTTerminal(layout: layout())
            _ = try await terminal.ingest(Data("above\r\ncurrent".utf8))
            _ = try await terminal.ingest(prefix)
            let bytes = try await clear(terminal)
            let completion = try await terminal.ingest(suffix)
            let frame = try await terminal.snapshot()
            XCTAssertTrue(bytes.isEmpty)
            XCTAssertTrue(completion.replies.isEmpty)
            XCTAssertTrue(completion.events.isEmpty)
            if expected == "X" {
                XCTAssertEqual(frame.cells[frame.layout.columns + 2].text, "X")
                XCTAssertEqual(frame.cursorRow, 1)
                XCTAssertEqual(frame.cursorColumn, 3)
            } else {
                XCTAssertTrue(frame.line(0).hasPrefix("current🙂"))
                XCTAssertFalse(frame.text.contains("�"))
            }
            _ = try await terminal.retire()
        }
    }

    func testHandledClearReleasesNativeImagesAndReusableCopiesButKeepsOwnedFramePixels() async throws {
        let cache = VTImageSnapshotCache(limitBytes: 16, limitImages: 1)
        let budget = VTNativeImageBudget(limitBytes: 16)
        let terminal = try VTTerminal(layout: layout(), snapshotCache: cache, nativeImageBudget: budget)
        let pixels = Data((0..<4).flatMap { _ in [UInt8(64), 64, 64, 255] })
        let image = "\u{1B}_Ga=T,f=32,s=2,v=2,i=1,p=1,c=2,r=2,C=1,q=2;"
            + pixels.base64EncodedString() + "\u{1B}\\"
        _ = try await terminal.ingest(Data(image.utf8))
        let owned = try await terminal.snapshot()
        XCTAssertEqual(owned.graphics.placements.count, 1)
        XCTAssertEqual(cache.metrics.retainedBytes, 16)
        XCTAssertEqual(budget.metrics.reservedBytes, 16)

        let bytes = try await clear(terminal)
        let retained = await terminal.cachedSnapshotImageBytes
        XCTAssertTrue(bytes.isEmpty)
        XCTAssertEqual(retained, 0, "Clear must release adapter retention before another snapshot")
        XCTAssertEqual(cache.metrics.retainedBytes, 0)
        XCTAssertEqual(budget.metrics.reservedBytes, 0)
        let after = try await terminal.snapshot()
        XCTAssertTrue(after.graphics.placements.isEmpty)
        XCTAssertEqual(owned.graphics.placements.first?.image.rgba, pixels)
        _ = try await terminal.retire()
        XCTAssertEqual(cache.metrics.registeredOwners, 0)
        XCTAssertEqual(owned.graphics.placements.first?.image.rgba, pixels)
    }

    func testSessionChoosesClearRouteAfterPrecedingOutputNotFromDisplayedFrame() async throws {
        for enteringAlternate in [true, false] {
            let writes = ByteRecorder()
            let session = VTTerminalSession(write: { writes.append($0) }, resize: { _ in })
            defer { session.finish() }
            session.updateViewport(.init(width: 320, height: 80, cellWidth: 10,
                                         cellHeight: 20, scale: 1, padding: 0))
            let initial = "primary\r\ncurrent" + (enteringAlternate ? "" : "\u{1B}[?1049halt")
            XCTAssertTrue(session.receiveIfSurfaceAttached(Data(initial.utf8)))
            let displayed = try await session.snapshot()
            let control = try VTTerminal(layout: layout())
            _ = try await control.ingest(Data(initial.utf8))
            let transition = enteringAlternate ? "\u{1B}[?1049h\u{1B}[H\u{1B}[>31ualternate" : "\u{1B}[?1049l"
            _ = try await control.ingest(Data(transition.utf8))
            let expected: Data
            if enteringAlternate { expected = try await control.input(.key(key())) }
            else { expected = Data() }
            _ = try await control.retire()

            let gate = OpenOnceGate(), entered = OpenOnceGate()
            session.beforeDelivery = { await entered.open(); await gate.wait() }
            let delivered = expectation(description: "screen switch precedes clear")
            session.deliver(Data(transition.utf8), ifCurrent: { true }) { accepted in
                XCTAssertTrue(accepted)
                delivered.fulfill()
            }
            await entered.wait()
            session.beforeDelivery = nil
            let input = try XCTUnwrap(session.enqueueInput(.key(key(), clearScreenBinding: true)))
            XCTAssertTrue(writes.data.isEmpty)
            await gate.open()
            let bytes = try await input.value
            let frame = try await session.snapshot() // FIFO barrier; no presentation or echo required.
            await fulfillment(of: [delivered], timeout: 5)
            XCTAssertEqual(bytes, expected)
            XCTAssertEqual(writes.data, expected)
            XCTAssertGreaterThan(frame.revision, displayed.revision)
            XCTAssertTrue(frame.line(0).hasPrefix(enteringAlternate ? "alternate" : "current"))
            if enteringAlternate { XCTAssertFalse(expected.isEmpty) }
        }
    }

    func testAcceptedPromptClearAndLifecycleDrainAfterImmediateSessionFinish() async throws {
        let writes = ByteRecorder()
        let session = VTTerminalSession(write: { writes.append($0) }, resize: { _ in })
        defer { session.finish() }
        session.updateViewport(.init(width: 320, height: 80, cellWidth: 10,
                                     cellHeight: 20, scale: 1, padding: 0))
        _ = try await session.snapshot()
        let gate = OpenOnceGate(), entered = OpenOnceGate()
        session.beforeDelivery = { await entered.open(); await gate.wait() }
        let delivered = expectation(description: "accepted prompt output survives finish")
        session.deliver(Data("\u{1B}[>31u\u{1B}]133;A\u{1B}\\$ \u{1B}]133;B\u{1B}\\".utf8), ifCurrent: { true }) { accepted in
            XCTAssertTrue(accepted)
            delivered.fulfill()
        }
        await entered.wait()
        session.beforeDelivery = nil
        let press = try XCTUnwrap(session.enqueueInput(.key(key(), clearScreenBinding: true)))
        let repeated = try XCTUnwrap(session.enqueueInput(.key(key(action: .repeatPress), clearScreenBinding: true)))
        let release = try XCTUnwrap(session.enqueueInput(.key(key(action: .release), clearScreenBinding: true)))
        let snapshot = try XCTUnwrap(session.enqueueSnapshot())
        press.cancel() // Canceling wrappers must not cancel already accepted operations.
        session.finish()
        XCTAssertNil(session.enqueueInput(.key(key(), clearScreenBinding: true)))
        XCTAssertTrue(writes.data.isEmpty)
        await gate.open()
        let pressedBytes = try await press.value
        let repeatedBytes = try await repeated.value
        let releasedBytes = try await release.value
        let frame = try await snapshot.value
        await fulfillment(of: [delivered], timeout: 5)
        XCTAssertEqual(pressedBytes, Data([0x0C]))
        XCTAssertTrue(repeatedBytes.isEmpty)
        XCTAssertTrue(releasedBytes.isEmpty)
        XCTAssertEqual(writes.data, Data([0x0C]))
        XCTAssertEqual(frame.kittyKeyboardFlags, 31)
    }

    func testClearRevokesHeldLocalSelectionButPreservesRemoteMouseRelease() async throws {
        for remote in [false, true] {
            let terminal = try VTTerminal(layout: layout())
            _ = try await terminal.ingest(Data(("above\r\ncurrent"
                + (remote ? "\u{1B}[?1000h\u{1B}[?1006h" : "")).utf8))
            let before = try await terminal.snapshot()
            let id: UInt64 = 41
            func request(_ phase: VTPointerRequest.Phase) -> VTPointerRequest {
                .init(id: id, terminalID: before.terminalID, generation: before.layout.generation,
                      revision: before.revision, phase: phase, source: .pointer,
                      point: CGPoint(x: 25, y: 10), time: 1, selectionBehavior: .word)
            }
            let press = try await terminal.pointer(request(.press))
            XCTAssertTrue(press.active)
            XCTAssertEqual(press.localSelection, !remote)
            let bytes = try await clear(terminal)
            let cleared = try await terminal.snapshot()
            XCTAssertTrue(bytes.isEmpty)
            XCTAssertNil(cleared.selection)
            XCTAssertEqual(cleared.revokedSelectionPointerID, remote ? nil : id)
            if remote {
                XCTAssertEqual(press.bytes, Data("\u{1B}[<0;3;1M".utf8))
                let release = try await terminal.pointer(request(.release))
                XCTAssertEqual(release.bytes, Data("\u{1B}[<0;3;1m".utf8))
            } else {
                for phase: VTPointerRequest.Phase in [.move, .autoscroll, .release] {
                    let stale = try await terminal.pointer(request(phase))
                    XCTAssertFalse(stale.active)
                    XCTAssertTrue(stale.bytes.isEmpty)
                    let after = try await terminal.snapshot()
                    XCTAssertEqual(after, cleared)
                }
            }
            let retired = try await terminal.retire()
            XCTAssertTrue(retired.isEmpty)
        }
    }

}
