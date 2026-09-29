import XCTest
@testable import GhosttyTerminal
@testable import GhosttyVT

/// Input router: HID/text/focus/selection over the VT encoder produce the
/// expected terminal byte sequences. The router drives a
/// live session so replies flow through the production write path.
@MainActor
final class VTTerminalInputRouterTests: XCTestCase {
    private var defaultMetrics: VTTerminalSessionMetrics {
        VTTerminalSessionMetrics(
            width: 390,
            height: 480,
            cellWidth: 10,
            cellHeight: 20,
            scale: 2
        )
    }

    private func makeRouter(
        writes: LockBox<[Data]> = LockBox([])
    ) async throws -> VTTerminalInputRouter {
        let session = VTTerminalSession(
            write: { value in writes.mutate { $0.append(value) } },
            resize: { _ in }
        )
        addTeardownBlock { session.finish() }
        session.updateViewport(defaultMetrics)
        let deadline = Date().addingTimeInterval(5)
        while (try? await session.snapshot()) == nil {
            if Date() >= deadline {
                XCTFail("VT engine viewport did not settle")
                throw VTError.invalidLayout
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        return VTTerminalInputRouter(session: session)
    }

    func testUpArrowEncodesCursorUp() async throws {
        let router = try await makeRouter()
        let replies = await router.sendKey(
            hid: 82,
            action: .press,
            text: "",
            unshifted: 0,
            modifiers: [],
            consumedModifiers: []
        )
        XCTAssertEqual(replies, Data("\u{1B}[A".utf8))
    }

    func testNavigationAndBackspaceUseLiveTerminalModes() async throws {
        let router = try await makeRouter()
        defer { router.testSession.finish() }
        router.testSession.receive(Data("\u{1B}[?1h\u{1B}[?67h".utf8))
        let up = await router.sendKey(hid: 0x52, action: .press, text: "", unshifted: 0,
                                      modifiers: [], consumedModifiers: [])
        let backspace = await router.sendKey(hid: 0x2A, action: .press, text: "", unshifted: 0,
                                             modifiers: [], consumedModifiers: [])
        XCTAssertEqual(up, Data("\u{1B}OA".utf8), "DECCKM must not be bypassed by fixed CSI bytes")
        XCTAssertEqual(backspace, Data([0x08]), "DECBKM must be honored by software deletion too")
    }

    func testKittyRepeatAndReleaseReachEncoderWithOriginalHID() async throws {
        let router = try await makeRouter()
        defer { router.testSession.finish() }
        // Disambiguation + event types + report-all (1 | 2 | 8).
        router.testSession.receive(Data("\u{1B}[>11u".utf8))
        let repeated = await router.sendKey(hid: 4, action: .repeatPress, text: "a", unshifted: 97,
                                            modifiers: [], consumedModifiers: [])
        let released = await router.sendKey(hid: 4, action: .release, text: "a", unshifted: 97,
                                            modifiers: [], consumedModifiers: [])
        XCTAssertEqual(repeated, Data("\u{1B}[97;1:2u".utf8))
        XCTAssertEqual(released, Data("\u{1B}[97;1:3u".utf8))
    }

    func testKittyReportAllPreservesLeftAndRightModifierIdentities() async throws {
        let writes = LockBox<[Data]>([])
        let router = try await makeRouter(writes: writes)
        defer { router.testSession.finish() }
        router.testSession.receive(Data("\u{1B}[>11u".utf8))
        // Kitty protocol codes, not GhosttyKey enum ordinals. Modifier state
        // folds sides, but the physical key identity must remain distinct.
        let cases: [(UInt16, TerminalInputModifiers, Int, Int)] = [
            (0xE0, .ctrl, 57442, 5), (0xE1, .shift, 57441, 2),
            (0xE2, .alt, 57443, 3), (0xE3, .super_, 57444, 9),
            (0xE4, .ctrlRight, 57448, 5), (0xE5, .shiftRight, 57447, 2),
            (0xE6, .altRight, 57449, 3), (0xE7, .superRight, 57450, 9),
        ]
        var expectedWrites = Data()
        for (hid, modifiers, code, kittyModifiers) in cases {
            let press = await router.sendKey(hid: hid, action: .press, text: "", unshifted: 0,
                                             modifiers: VTModifiers(modifiers), consumedModifiers: [])
            let release = await router.sendKey(hid: hid, action: .release, text: "", unshifted: 0,
                                               modifiers: [], consumedModifiers: [])
            let expectedPress = Data("\u{1B}[\(code);\(kittyModifiers)u".utf8)
            let expectedRelease = Data("\u{1B}[\(code);1:3u".utf8)
            XCTAssertEqual(press, expectedPress, "HID \(hid) press")
            XCTAssertEqual(release, expectedRelease, "HID \(hid) release")
            expectedWrites.append(expectedPress)
            expectedWrites.append(expectedRelease)
        }
        XCTAssertEqual(Data(writes.get().joined()), expectedWrites)
    }

    func testKittyReportAllRestoresLockAndFunctionKeyEvents() async throws {
        let router = try await makeRouter()
        defer { router.testSession.finish() }
        router.testSession.receive(Data("\u{1B}[>11u".utf8))
        let cases: [(UInt16, TerminalInputModifiers, Int, Int)] = [
            (0x39, .caps, 57358, 65), (0x53, .num, 57360, 129),
            (0x46, [], 57361, 1), (0x47, [], 57359, 1),
            (0x48, [], 57362, 1), (0x67, [], 57415, 1),
        ]
        for (hid, modifiers, code, kittyModifiers) in cases {
            let press = await router.sendKey(hid: hid, action: .press, text: "", unshifted: 0,
                                             modifiers: VTModifiers(modifiers), consumedModifiers: [])
            let release = await router.sendKey(hid: hid, action: .release, text: "", unshifted: 0,
                                               modifiers: VTModifiers(modifiers), consumedModifiers: [])
            let modifierParameter = kittyModifiers == 1 ? "" : ";\(kittyModifiers)"
            XCTAssertEqual(press, Data("\u{1B}[\(code)\(modifierParameter)u".utf8), "HID \(hid) press")
            XCTAssertEqual(release, Data("\u{1B}[\(code);\(kittyModifiers):3u".utf8), "HID \(hid) release")
        }
    }

    func testKittyPreservesCapsAndNumLockStateOnOrdinaryKeys() async throws {
        let router = try await makeRouter()
        defer { router.testSession.finish() }
        router.testSession.receive(Data("\u{1B}[>11u".utf8))
        let cases: [(TerminalInputModifiers, Int)] = [
            (.caps, 65), (.num, 129), ([.caps, .num], 193),
            ([.caps, .num, .shiftRight, .ctrlRight, .altRight, .superRight], 208),
        ]
        for (modifiers, kittyModifiers) in cases {
            let press = await router.sendKey(hid: 4, action: .press, text: "A", unshifted: 97,
                                             modifiers: VTModifiers(modifiers), consumedModifiers: [])
            let release = await router.sendKey(hid: 4, action: .release, text: "A", unshifted: 97,
                                               modifiers: VTModifiers(modifiers), consumedModifiers: [])
            XCTAssertEqual(press, Data("\u{1B}[97;\(kittyModifiers)u".utf8))
            XCTAssertEqual(release, Data("\u{1B}[97;\(kittyModifiers):3u".utf8))
        }
    }

    func testModifierAndLockEventsRemainSilentWithoutKittyReportAll() async throws {
        let writes = LockBox<[Data]>([])
        let router = try await makeRouter(writes: writes)
        defer { router.testSession.finish() }
        // Both legacy and Kitty disambiguation/event-types without report-all
        // must continue to ignore standalone modifiers and lock keys.
        for mode in ["", "\u{1B}[>3u"] {
            router.testSession.receive(Data(mode.utf8))
            for hid: UInt16 in [0x39, 0x53, 0xE0, 0xE1, 0xE2, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7] {
                for action: VTKey.Action in [.press, .release] {
                    let bytes = await router.sendKey(hid: hid, action: action, text: "", unshifted: 0,
                                                     modifiers: [], consumedModifiers: [])
                    XCTAssertTrue(bytes.isEmpty, "HID \(hid), \(action), mode \(mode)")
                }
            }
        }
        XCTAssertTrue(writes.get().isEmpty)
    }

    func testLegacyTextIgnoresLockStateAndRelease() async throws {
        let router = try await makeRouter()
        defer { router.testSession.finish() }
        let modifiers = VTModifiers(TerminalInputModifiers([.caps, .num]))
        let press = await router.sendKey(hid: 4, action: .press, text: "A", unshifted: 97,
                                         modifiers: modifiers, consumedModifiers: [])
        let release = await router.sendKey(hid: 4, action: .release, text: "A", unshifted: 97,
                                           modifiers: modifiers, consumedModifiers: [])
        XCTAssertEqual(press, Data("A".utf8))
        XCTAssertTrue(release.isEmpty)
    }

    func testPasteRejectionIsObservableAndDoesNotWritePartialInput() async throws {
        let writes = LockBox<[Data]>([])
        let router = try await makeRouter(writes: writes)
        let session = router.testSession
        defer { session.finish() }
        let rejected = try XCTUnwrap(session.enqueueInput(.paste("one\ntwo")))
        do {
            _ = try await rejected.value
            XCTFail("Unsafe explicit paste must require confirmation")
        } catch {
            XCTAssertEqual(error as? VTError, .unsafePaste)
        }
        XCTAssertTrue(writes.get().isEmpty)
        let accepted = try XCTUnwrap(session.enqueueInput(.paste("one\ntwo", allowUnsafe: true)))
        let bytes = try await accepted.value
        XCTAssertEqual(bytes, Data("one\rtwo".utf8))
    }

    func testInputAdmissionPreservesKeyTextAndReleaseOrder() async throws {
        let writes = LockBox<[Data]>([])
        let router = try await makeRouter(writes: writes)
        let session = router.testSession
        defer { session.finish() }
        session.receive(Data("\u{1B}[>3u".utf8))
        let press = try XCTUnwrap(session.enqueueInput(.key(VTKey(hid: 4, text: "a", unshifted: 97))))
        let text = try XCTUnwrap(session.enqueueInput(.text("漢字")))
        let release = try XCTUnwrap(session.enqueueInput(.key(VTKey(hid: 4, text: "a", unshifted: 97, action: .release))))
        let expected = try await press.value + text.value + release.value
        XCTAssertEqual(Data(writes.get().joined()), expected)
    }

    func testControlCEncodesETX() async throws {
        let router = try await makeRouter()
        let replies = await router.sendKey(
            hid: 6,
            action: .press,
            text: "c",
            unshifted: 99,
            modifiers: [.control],
            consumedModifiers: []
        )
        XCTAssertEqual(replies, Data([0x03]))
    }

    func testCommittedTextPassesThrough() async throws {
        let router = try await makeRouter()
        let replies = await router.sendText("hello")
        XCTAssertEqual(replies, Data("hello".utf8))
    }

    func testFocusReportsOnlyWhenTheApplicationEnablesIt() async throws {
        let router = try await makeRouter()
        let disabledIn = await router.setFocus(true)
        let disabledOut = await router.setFocus(false)
        XCTAssertEqual(disabledIn, Data())
        XCTAssertEqual(disabledOut, Data())
        router.testSession.receive(Data("\u{1B}[?1004h".utf8))
        let focusIn = await router.setFocus(true)
        let focusOut = await router.setFocus(false)
        XCTAssertEqual(focusIn, Data("\u{1B}[I".utf8))
        XCTAssertEqual(focusOut, Data("\u{1B}[O".utf8))
    }

    func testRepliesReachSessionWritePath() async throws {
        let writes = LockBox<[Data]>([])
        let router = try await makeRouter(writes: writes)
        _ = await router.sendKey(
            hid: 82,
            action: .press,
            text: "",
            unshifted: 0,
            modifiers: [],
            consumedModifiers: []
        )
        XCTAssertEqual(Data(writes.get().joined()), Data("\u{1B}[A".utf8))
    }

    func testWordSelectionRoundTrip() async throws {
        let router = try await makeRouter()
        let session = router.testSession
        session.receive(Data("ALPHA BRAVO CHARLIE".utf8))
        let deadline = Date().addingTimeInterval(5)
        while (try? await session.snapshot().line(0).hasPrefix("ALPHA")) != true {
            if Date() >= deadline {
                XCTFail("VT engine ingest did not settle")
                throw VTError.retired
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        await router.select(.word, at: VTCellPosition(column: 8, row: 0), generation: 1)
        let selected = await router.selectedText()
        XCTAssertEqual(selected, "BRAVO")
        let taken = await router.takeSelectedText()
        XCTAssertEqual(taken, "BRAVO")
        let cleared = await router.selectedText()
        XCTAssertEqual(cleared, "")
    }

    func testModifierMapping() {
        XCTAssertEqual(
            VTModifiers(TerminalInputModifiers([.shift, .shiftRight])),
            [.shift]
        )
        XCTAssertEqual(
            VTModifiers(TerminalInputModifiers([.ctrl, .alt, .super_, .caps, .num])),
            [.control, .alt, .command, .capsLock, .numLock]
        )
        XCTAssertEqual(
            VTModifiers(TerminalInputModifiers([.shiftRight, .ctrlRight, .altRight, .superRight, .caps, .num])),
            [.shift, .control, .alt, .command, .capsLock, .numLock]
        )
        XCTAssertEqual(VTModifiers(TerminalInputModifiers.caps), .capsLock)
        XCTAssertEqual(VTModifiers(TerminalInputModifiers.num), .numLock)
        XCTAssertEqual(VTModifiers(TerminalInputModifiers()), [])
    }
}
