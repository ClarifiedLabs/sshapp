import Foundation
import GhosttyVT
import UIKit
import XCTest
@testable import GhosttyTerminal

@MainActor
final class TerminalLocalKeyActionTests: XCTestCase {
    /// Synthetic app lifecycle events go to a private center, not the process.
    private var lifecycle: PrivateLifecycleNotifications!

    override func setUp() async throws {
        try await super.setUp()
        lifecycle = PrivateLifecycleNotifications()
    }

    override func tearDown() async throws {
        lifecycle.restore()
        try await super.tearDown()
    }

    func testOnlySupportedCommandBindingsAreClaimed() {
        let bindings: [(String, TerminalLocalKeyAction)] = [
            ("a", .selectAll), ("c", .copy), ("v", .paste),
            ("+", .increaseFontSize), ("=", .increaseFontSize),
            ("-", .decreaseFontSize), ("_", .decreaseFontSize), ("0", .resetFontSize)
        ]
        for (text, action) in bindings {
            XCTAssertEqual(TerminalLocalKeyAction.resolve(characters: text,
                ignoringModifiers: text, modifiers: .super_), action)
            for modifiers: TerminalInputModifiers in [[], .ctrl, .alt, [.super_, .ctrl], [.super_, .alt]] {
                XCTAssertNil(TerminalLocalKeyAction.resolve(characters: text,
                    ignoringModifiers: text, modifiers: modifiers))
            }
        }
        for text in ["x", "t", "1", "k", "aa"] {
            XCTAssertNil(TerminalLocalKeyAction.resolve(characters: text,
                ignoringModifiers: text, modifiers: .super_))
        }
        XCTAssertNil(TerminalLocalKeyAction.resolve(characters: "A",
            ignoringModifiers: "a", modifiers: [.super_, .shift]))
        XCTAssertEqual(TerminalLocalKeyAction.resolve(characters: "+",
            ignoringModifiers: "=", modifiers: [.super_, .shift]), .increaseFontSize)
    }

    func testHardwareZoomConsumesRepeatAndModifierChangedReleaseWithoutKittyBytes() async throws {
        let fixture = try await mount()
        defer { fixture.close() }
        let view = fixture.view
        view.configuredFontSize = 12
        let plus = key(.keyboardEqualSign, "=", flags: .command)
        XCTAssertTrue(view.handleKeyPress(plus, action: .press))
        XCTAssertEqual(view.currentFontSize, 13)
        let changed = key(.keyboardEqualSign, "=", flags: [])
        XCTAssertTrue(view.handleKeyPress(changed, action: .repeatPress))
        XCTAssertEqual(view.currentFontSize, 14)
        XCTAssertTrue(view.handleKeyPress(changed, action: .release))
        XCTAssertTrue(view.localKeyActionsByKeyCode.isEmpty)
        XCTAssertTrue(view.hardwareTextInputSuppressedKeyCodes.isEmpty)
        let zero = key(.keyboard0, "0", flags: .command)
        XCTAssertTrue(view.handleKeyPress(zero, action: .press))
        XCTAssertTrue(view.handleKeyPress(key(.keyboard0, "0"), action: .release))
        XCTAssertEqual(view.resetCalls, 1, "Command-0 must use the public reset operation")
        XCTAssertEqual(view.currentFontSize, 12)
        XCTAssertFalse(view.isFontSizeTransientlyAdjusted)
        _ = try await fixture.session.snapshot()
        XCTAssertTrue(fixture.writes.data.isEmpty)
    }

    func testStickySoftwareZoomAndResetUseSameLocalActions() async throws {
        let fixture = try await mount()
        defer { fixture.close() }
        fixture.view.configuredFontSize = 12
        for (text, size): (String, Float) in [("+", 13), ("-", 12), ("+", 13), ("0", 12)] {
            fixture.view.toggleStickyModifier(.command)
            XCTAssertTrue(fixture.view.handleStickyTextInput(text))
            XCTAssertEqual(fixture.view.currentFontSize, size)
            XCTAssertFalse(fixture.view.hasActiveStickyModifiers)
        }
        XCTAssertEqual(fixture.view.resetCalls, 1)
        _ = try await fixture.session.snapshot()
        XCTAssertTrue(fixture.writes.data.isEmpty)
    }

    func testHardwareSelectAllAndStickyCopyPreserveNativeSelectionClear() async throws {
        let fixture = try await mount()
        defer { fixture.close(); UIPasteboard.general.items = [] }
        fixture.session.receive(Data("selected fixture".utf8))
        let a = key(.keyboardA, "a", flags: .command)
        XCTAssertTrue(fixture.view.handleKeyPress(a, action: .press))
        XCTAssertTrue(fixture.view.handleKeyPress(key(.keyboardA, "a"), action: .release))
        let selected = try XCTUnwrap(fixture.session.enqueueSelectedText())
        let text = try await selected.value
        XCTAssertTrue(text.contains("selected fixture"))
        // Copy is advertised from the presented native selection, not merely
        // from actor state. Wait for that same UIKit admission boundary.
        let selectionDeadline = Date().addingTimeInterval(5)
        while fixture.view.surface?.frameValue?.hasSelection != true, Date() < selectionDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(fixture.view.surface?.frameValue?.hasSelection, true)
        UIPasteboard.general.string = "before copy"
        fixture.view.toggleStickyModifier(.command)
        XCTAssertTrue(fixture.view.handleStickyTextInput("c"))
        let deadline = Date().addingTimeInterval(5)
        while UIPasteboard.general.string != text, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(UIPasteboard.general.string, text)
        let snapshot = try await fixture.session.snapshot()
        XCTAssertNil(snapshot.selection, "Copy must retain the native take-and-clear operation")
        XCTAssertEqual(fixture.view.copyCalls, 1)
        XCTAssertTrue(fixture.writes.data.isEmpty)
    }

    func testStickyHardwarePasteRunsOnceAcrossRepeatAndRelease() async throws {
        let fixture = try await mount()
        defer { fixture.close(); UIPasteboard.general.items = [] }
        fixture.session.receive(Data("select before paste\u{1B}[?2004h".utf8))
        fixture.view.toggleStickyModifier(.command)
        XCTAssertTrue(fixture.view.handleStickyTextInput("a"))
        UIPasteboard.general.string = "paste once\n"
        fixture.view.toggleStickyModifier(.command)
        let v = key(.keyboardV, "v")
        XCTAssertTrue(fixture.view.handleKeyPress(v, action: .press))
        XCTAssertTrue(fixture.view.handleKeyPress(v, action: .repeatPress))
        XCTAssertTrue(fixture.view.handleKeyPress(key(.keyboardV, "v", flags: .alternate), action: .release))
        let snapshot = try await fixture.session.snapshot()
        XCTAssertNotNil(snapshot.selection, "Accepted paste preserves selection, unlike typing or Copy")
        XCTAssertEqual(fixture.view.pasteCalls, 1)
        XCTAssertEqual(fixture.writes.data, Data("\u{1B}[200~paste once\n\u{1B}[201~".utf8))
        XCTAssertFalse(fixture.view.hasActiveStickyModifiers)
    }

    func testPhysicalClipboardShortcutsDeferToUIKitWithoutDuplicatePaste() async throws {
        let fixture = try await mount()
        defer { fixture.close(); UIPasteboard.general.items = [] }
        UIPasteboard.general.string = "native paste"
        let v = key(.keyboardV, "v", flags: .command)
        XCTAssertFalse(fixture.view.handleKeyPress(v, action: .press), "UIKit must receive physical Cmd-V")
        XCTAssertEqual(fixture.view.pasteCalls, 0, "Raw hardware handling must not also paste")
        // Model the standard UIKit edit action after forwarding the press.
        fixture.view.paste(nil)
        XCTAssertFalse(fixture.view.handleKeyPress(v, action: .repeatPress))
        XCTAssertFalse(fixture.view.handleKeyPress(key(.keyboardV, "v"), action: .release))
        XCTAssertEqual(fixture.view.pasteCalls, 1)
        let c = key(.keyboardC, "c", flags: .command)
        XCTAssertFalse(fixture.view.handleKeyPress(c, action: .press))
        XCTAssertEqual(fixture.view.copyCalls, 0)
        fixture.view.copy(nil)
        XCTAssertFalse(fixture.view.handleKeyPress(key(.keyboardC, "c"), action: .release))
        _ = try await fixture.session.snapshot()
        XCTAssertEqual(fixture.writes.data, Data("native paste".utf8))
        XCTAssertTrue(fixture.view.localKeyActionsByKeyCode.isEmpty)
    }

    func testStickySoftwarePasteDoesNotBypassUnsafePasteConsent() async throws {
        let fixture = try await mount()
        defer { fixture.close(); UIPasteboard.general.items = [] }
        UIPasteboard.general.string = "unconfirmed\ncommand"
        fixture.view.toggleStickyModifier(.command)
        XCTAssertTrue(fixture.view.handleStickyTextInput("v"))
        _ = try await fixture.session.snapshot()
        XCTAssertTrue(fixture.writes.data.isEmpty, "Unsafe paste must write nothing before confirmation")
        XCTAssertEqual(fixture.view.pasteCalls, 1)
    }

    func testCompositionKeepsOwnershipAndStickyStateButCannotLeakClaimedRelease() async throws {
        let fixture = try await mount()
        defer { fixture.close() }
        let view = fixture.view
        let plus = key(.keyboardEqualSign, "=", flags: .command)
        XCTAssertTrue(view.handleKeyPress(plus, action: .press))
        let size = view.currentFontSize
        view.inputHandler.setMarkedText("marked", selectedRange: NSRange(location: 6, length: 0))
        XCTAssertTrue(view.handleKeyPress(key(.keyboardEqualSign, "="), action: .release))
        view.toggleStickyModifier(.command)
        XCTAssertFalse(view.handleKeyPress(plus, action: .press))
        XCTAssertEqual(view.currentFontSize, size)
        XCTAssertTrue(view.inputHandler.hasMarkedText)
        XCTAssertTrue(view.hasActiveStickyModifiers)
        XCTAssertTrue(view.localKeyActionsByKeyCode.isEmpty)
        _ = try await fixture.session.snapshot()
        XCTAssertTrue(fixture.writes.data.isEmpty)
    }

    func testUnsupportedHardwareAndStickyCommandsStillReachKittyEncoder() async throws {
        for hardware in [true, false] {
            let fixture = try await mount()
            defer { fixture.close() }
            if hardware {
                let x = key(.keyboardX, "x", flags: .command)
                XCTAssertTrue(fixture.view.handleKeyPress(x, action: .press))
                XCTAssertTrue(fixture.view.handleKeyPress(x, action: .release))
            } else {
                fixture.view.toggleStickyModifier(.command)
                XCTAssertTrue(fixture.view.handleStickyTextInput("x"))
            }
            _ = try await fixture.session.snapshot()
            XCTAssertFalse(fixture.writes.data.isEmpty, "Unbound Command-X must remain remote")
            XCTAssertTrue(fixture.view.localKeyActionsByKeyCode.isEmpty)
        }
    }

    func testSystemRepeatUsesActiveHIDOwnerWhenModifiersChange() async throws {
        let fixture = try await mount()
        defer { fixture.view.cancelHardwareKeyRepeat(); fixture.close() }
        let view = fixture.view
        view.hardwareKeyRepeatConfiguration = .init(enabled: true, delayMilliseconds: 1200)
        let ordinary = key(.keyboardK, "k")
        let command = key(.keyboardK, "k", flags: .command)
        // Exercise the same ownership setup and per-press change route as UIKit.
        view.startHardwareKeyRepeatIfNeeded(for: ordinary)
        XCTAssertNotNil(view.hardwareKeyRepeatTask)
        XCTAssertTrue(view.handleHardwareKeyRepeatChange(command))
        XCTAssertTrue(view.handleHardwareKeyRepeatChange(ordinary))
        XCTAssertEqual(view.hardwareKeyRepeatKey, ordinary,
                       "Synthetic repeat keeps the initial stroke, never a second UIKit producer")
        view.cancelHardwareKeyRepeat(for: ordinary)
        _ = try await fixture.session.snapshot()
        XCTAssertTrue(fixture.writes.data.isEmpty)

        fixture.session.receive(Data("\u{1B}[?1049h\u{1B}[>31u".utf8))
        XCTAssertTrue(view.handleKeyPress(command, action: .press))
        view.startHardwareKeyRepeatIfNeeded(for: command)
        XCTAssertNil(view.hardwareKeyRepeatTask)
        XCTAssertTrue(view.handleHardwareKeyRepeatChange(command),
                      "An unowned alternate-screen Command-K repeat must reach the VT encoder")
        XCTAssertTrue(view.handleKeyPress(command, action: .release))
        _ = try await fixture.session.snapshot()
        XCTAssertEqual(fixture.writes.data, Data("\u{1B}[107;9u\u{1B}[107;9:2u\u{1B}[107;9:3u".utf8))
    }

    func testHardwareCommandKClearsAtPromptOnceWithoutKittyRelease() async throws {
        let fixture = try await mount()
        defer { fixture.close() }
        fixture.session.receive(Data("old output\r\n\u{1B}]133;A\u{7}$ \u{1B}]133;B\u{7}".utf8))
        _ = try await fixture.session.snapshot()
        let k = key(.keyboardK, "k", flags: .command)
        XCTAssertTrue(fixture.view.handleKeyPress(k, action: .press))
        XCTAssertTrue(fixture.view.handleKeyPress(k, action: .repeatPress))
        XCTAssertTrue(fixture.view.handleKeyPress(key(.keyboardK, "k"), action: .release))
        _ = try await fixture.session.snapshot()
        XCTAssertEqual(fixture.writes.data, Data([0x0C]), "Repaint is literal FF even with Kitty enabled")
    }

    func testStickySoftwareCommandKUsesTheSameNativeClear() async throws {
        let fixture = try await mount()
        defer { fixture.close() }
        fixture.session.receive(Data("old output\r\n\u{1B}]133;A\u{7}$ \u{1B}]133;B\u{7}".utf8))
        fixture.view.toggleStickyModifier(.command)
        XCTAssertTrue(fixture.view.handleStickyTextInput("k"))
        _ = try await fixture.session.snapshot()
        XCTAssertEqual(fixture.writes.data, Data([0x0C]))
        XCTAssertFalse(fixture.view.hasActiveStickyModifiers)
    }

    func testHardwareAndStickyCommandKRemainRemoteOnAlternateScreen() async throws {
        for hardware in [true, false] {
            let fixture = try await mount()
            defer { fixture.close() }
            // Admission must inspect these queued modes, not the last UIKit frame.
            fixture.session.receive(Data("\u{1B}[?1049h\u{1B}[>31u".utf8))
            if hardware {
                let k = key(.keyboardK, "k", flags: .command)
                XCTAssertTrue(fixture.view.handleKeyPress(k, action: .press))
                XCTAssertTrue(fixture.view.handleKeyPress(k, action: .release))
            } else {
                fixture.view.toggleStickyModifier(.command)
                XCTAssertTrue(fixture.view.handleStickyTextInput("k"))
            }
            _ = try await fixture.session.snapshot()
            XCTAssertEqual(fixture.writes.data, Data("\u{1B}[107;9u\u{1B}[107;9:3u".utf8))
        }
    }

    func testLifecycleChangesDropHeldLocalShortcutsAndTextSuppression() async throws {
        let fixture = try await mount()
        defer { fixture.close() }
        let view = fixture.view
        let plus = key(.keyboardEqualSign, "=", flags: .command)
        for transition: () -> Void in [
            { view.isHostVisible = false },
            { view.applicationWillResignActive(Notification(name: UIApplication.willResignActiveNotification)) },
            { view.applicationDidEnterBackground(Notification(name: UIApplication.didEnterBackgroundNotification)) },
            {
                XCTAssertTrue(view.becomeFirstResponder())
                XCTAssertTrue(view.resignFirstResponder())
            },
            { view.removeFromSuperview() }
        ] {
            view.isHostVisible = true
            XCTAssertTrue(view.handleKeyPress(plus, action: .press))
            XCTAssertFalse(view.localKeyActionsByKeyCode.isEmpty)
            XCTAssertFalse(view.hardwareTextInputSuppressedKeyCodes.isEmpty)
            transition()
            XCTAssertTrue(view.localKeyActionsByKeyCode.isEmpty)
            XCTAssertTrue(view.hardwareTextInputSuppressedKeyCodes.isEmpty)
            XCTAssertFalse(view.hardwareKeyHandled)
            XCTAssertTrue(view.handleKeyPress(key(.keyboardEqualSign, "="), action: .repeatPress))
            XCTAssertTrue(view.handleKeyPress(key(.keyboardEqualSign, "="), action: .release))
            XCTAssertTrue(view.cancelledLocalKeyCodes.isEmpty)
        }
        _ = try await fixture.session.snapshot()
        XCTAssertTrue(fixture.writes.data.isEmpty, "Cancelled local releases must not reach Kitty")
    }

    /// Regression: key-up is never delivered after deactivation or responder
    /// loss, so a synthesized hardware repeat kept writing to the session.
    func testLifecycleChangesCancelHardwareKeyRepeat() async throws {
        let fixture = try await mount()
        defer { fixture.view.cancelHardwareKeyRepeat(); fixture.close() }
        let view = fixture.view
        view.hardwareKeyRepeatConfiguration = .init(enabled: true, delayMilliseconds: 1200)
        let k = key(.keyboardK, "k")
        for transition: () -> Void in [
            { view.applicationWillResignActive(Notification(name: UIApplication.willResignActiveNotification)) },
            { view.applicationDidEnterBackground(Notification(name: UIApplication.didEnterBackgroundNotification)) },
            {
                XCTAssertTrue(view.becomeFirstResponder())
                XCTAssertTrue(view.resignFirstResponder())
            },
            { view.removeFromSuperview() }
        ] {
            view.startHardwareKeyRepeatIfNeeded(for: k)
            XCTAssertNotNil(view.hardwareKeyRepeatTask)
            transition()
            XCTAssertNil(view.hardwareKeyRepeatTask)
            XCTAssertNil(view.hardwareKeyRepeatKey)
        }
    }

    func testLostLocalKeyUpDoesNotSuppressSoftwareInputOrReuseStickyCommand() async throws {
        let fixture = try await mount()
        defer { fixture.close() }
        let view = fixture.view
        view.toggleStickyModifier(.command)
        let plus = key(.keyboardEqualSign, "=")
        XCTAssertTrue(view.handleKeyPress(plus, action: .press))
        XCTAssertFalse(view.hardwareStickyModifiersByKeyCode.isEmpty)
        view.applicationWillResignActive(Notification(name: UIApplication.willResignActiveNotification))
        XCTAssertTrue(view.hardwareStickyModifiersByKeyCode.isEmpty)
        view.insertText("after cancellation")
        _ = try await fixture.session.snapshot()
        XCTAssertEqual(fixture.writes.data, Data("after cancellation".utf8))

        let size = view.currentFontSize
        XCTAssertTrue(view.handleKeyPress(plus, action: .press))
        XCTAssertEqual(view.currentFontSize, size, "Fresh unmodified '=' must not zoom")
        XCTAssertTrue(view.cancelledLocalKeyCodes.isEmpty)
        XCTAssertTrue(view.handleKeyPress(plus, action: .release))
        _ = try await fixture.session.snapshot()
        XCTAssertGreaterThan(fixture.writes.data.count, "after cancellation".utf8.count)
    }

    private func key(_ code: UIKeyboardHIDUsage, _ text: String,
                     flags: UIKeyModifierFlags = []) -> TerminalUIKitKeyPress {
        .init(keyCode: code, characters: text, modifierFlags: flags)
    }

    private func mount() async throws -> Fixture {
        let writes = ByteRecorder()
        let session = VTTerminalSession(write: { writes.append($0) }, resize: { _ in })
        let view = LocalActionView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let window = UIWindow(frame: view.bounds)
        let root = UIViewController()
        window.rootViewController = root
        root.view.addSubview(view)
        window.isHidden = false
        view.configuration = .init(backend: .vt(session))
        view.controller = TerminalController()
        view.layoutIfNeeded()
        lifecycle.post(UIApplication.didBecomeActiveNotification, object: nil)
        let fixture = Fixture(view: view, window: window, session: session, writes: writes)
        let deadline = Date().addingTimeInterval(5)
        while view.surface?.frameValue == nil {
            guard Date() < deadline else {
                fixture.close()
                throw NSError(domain: "TerminalLocalKeyActionTests.mount", code: 1)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        // Report all keys, including repeats/releases: accidental remote local
        // shortcut delivery cannot hide behind the legacy encoder's silence.
        session.receive(Data("\u{1B}[>31u".utf8))
        _ = try await session.snapshot()
        return fixture
    }

    @MainActor
    private struct Fixture {
        let view: LocalActionView
        let window: UIWindow
        let session: VTTerminalSession
        let writes: ByteRecorder
        func close() {
            view.controller = nil
            window.isHidden = true
            session.finish()
        }
    }

    private final class LocalActionView: UITerminalView {
        var pasteCalls = 0
        var copyCalls = 0
        var resetCalls = 0
        override func paste(_ sender: Any?) { pasteCalls += 1; super.paste(sender) }
        override func copy(_ sender: Any?) { copyCalls += 1; super.copy(sender) }
        override func resetFontSize() -> Bool { resetCalls += 1; return super.resetFontSize() }
    }

}
