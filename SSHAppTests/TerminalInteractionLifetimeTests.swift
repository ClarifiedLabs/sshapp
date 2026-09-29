#if canImport(UIKit) && !targetEnvironment(macCatalyst)
import UIKit
import XCTest
import GhosttyVT
@testable import GhosttyTerminal

@MainActor
final class TerminalInteractionLifetimeTests: XCTestCase {
    private var window: UIWindow?
    private weak var previousKeyWindow: UIWindow?
    private var terminal: UITerminalView?

    /// Completions observed through the DEBUG hook; see awaitCompletion.
    private var completions: [TerminalNativeInteraction.DebugCompletion] = []

    override func setUp() async throws {
        try await super.setUp()
        completions = []
        TerminalNativeInteraction.debugCompletionObserver = { [weak self] in self?.completions.append($0) }
    }

    override func tearDown() async throws {
        TerminalNativeInteraction.debugCompletionObserver = nil
        releaseTerminal()
        window?.isHidden = true
        window = nil
        previousKeyWindow?.makeKey()
        try await super.tearDown()
    }

    private func mount(_ session: VTTerminalSession) async throws {
        try await waitUntil("active scene") {
            UIApplication.shared.connectedScenes.contains {
                ($0 as? UIWindowScene)?.activationState == .foregroundActive
            }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let root = UIViewController()
        window.rootViewController = root
        let terminal = UITerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 480))
        self.terminal = terminal
        terminal.configuration = .init(backend: .vt(session))
        terminal.controller = TerminalController()
        root.view.addSubview(terminal)
        self.window = window
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        root.view.layoutIfNeeded()
        terminal.layoutIfNeeded()
        try await waitUntil("terminal frame") { terminal.surface?.frameValue != nil }
    }

    private func releaseTerminal() {
        autoreleasepool {
            terminal?.removeFromSuperview()
            terminal = nil
        }
    }

    // Existing FIFO seam: native operations are admitted now, but cannot run
    // until the delivery ahead of them is released. No production test hook.
    private func hold(_ session: VTTerminalSession) async -> OpenOnceGate {
        let gate = OpenOnceGate()
        let entered = expectation(description: "delivery entered")
        session.beforeDelivery = { entered.fulfill(); await gate.wait() }
        session.deliver(Data(), ifCurrent: { true }, completion: { _ in })
        await fulfillment(of: [entered], timeout: 5)
        session.beforeDelivery = nil
        return gate
    }

    /// Waits until a native completion has actually run, so a "no UI work"
    /// assertion cannot pass merely because the completion had not run yet.
    private func awaitCompletion(_ completion: TerminalNativeInteraction.DebugCompletion) async throws {
        try await waitUntil("\(completion)") { self.completions.contains(completion) }
    }

    private func inputPoint() throws -> CGPoint {
        let frame = try XCTUnwrap(terminal?.surface?.frameValue)
        let rect = frame.layout.rect(column: 1, row: 0)
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    func testPendingPointerWorkDoesNotRetainOwnersOrDropAcceptedBytes() async throws {
        let writes = ByteRecorder()
        let session = VTTerminalSession(write: { writes.append($0) }, resize: { _ in })
        defer { session.finish() }
        try await mount(session)
        session.receive(Data("\u{1B}[?1000h\u{1B}[?1006h".utf8))
        _ = try await session.snapshot()
        let point = try inputPoint()
        let gate = await hold(session)
        defer { Task { await gate.open() } }
        XCTAssertNotNil(terminal?.nativePointer.begin(at: point, modifiers: []))
        terminal?.nativePointer.end(at: point, modifiers: [])
        // Let completion tasks start and suspend on the held native operations.
        try await Task.sleep(for: .milliseconds(20))
        weak let releasedView = terminal
        weak let releasedPointer = terminal?.nativePointer
        releaseTerminal()
        XCTAssertNil(releasedView, "Native completion must not retain the UIView")
        XCTAssertNil(releasedPointer, "Do not upgrade weak self across the native await")

        await gate.open()
        _ = try await session.snapshot()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(writes.data, Data("\u{1B}[<0;2;1M\u{1B}[<0;2;1m".utf8),
            "Releasing the host must not cancel or reorder admitted press/release bytes")
    }

    /// Regression: a host rebuild detached the surface before cancelling native
    /// interactions, so the cancel could not route to the retained session and
    /// the remote kept a press with no release.
    func testHostRebuildMidPressReleasesRemotePointer() async throws {
        let writes = ByteRecorder()
        let session = VTTerminalSession(write: { writes.append($0) }, resize: { _ in })
        defer { session.finish() }
        try await mount(session)
        session.receive(Data("\u{1B}[?1000h\u{1B}[?1006h".utf8))
        _ = try await session.snapshot()
        let point = try inputPoint()
        let terminal = try XCTUnwrap(self.terminal)
        XCTAssertNotNil(terminal.nativePointer.begin(at: point, modifiers: []))
        let retiring = terminal.surface
        terminal.core.rebuildIfReady()
        XCTAssertFalse(terminal.surface === retiring)
        _ = try await session.snapshot()
        try await waitUntil("remote release") { writes.data.count > Data("\u{1B}[<0;2;1M".utf8).count }
        XCTAssertEqual(writes.data, Data("\u{1B}[<0;2;1M\u{1B}[<0;2;1m".utf8),
            "The retained session must see the abandoned press released")
    }

    func testPendingNudgeDoesNotRetainOwnersAndStillAdjustsNativeSelection() async throws {
        let session = VTTerminalSession(write: { _ in }, resize: { _ in })
        defer { session.finish() }
        try await mount(session)
        session.receive(Data("alpha beta".utf8))
        let frame = try await session.snapshot()
        try await session.enqueueSelect(.word, at: .init(column: 1, row: 0),
            generation: frame.layout.generation)?.value
        try await waitUntil("selection frame") { self.terminal?.surface?.frameValue?.hasSelection == true }
        let before = try await session.snapshot()
        let gate = await hold(session)
        defer { Task { await gate.open() } }
        terminal?.nativeInteraction.nudge(start: false, delta: 1)
        // Capture the FIFO result before teardown admits selection cleanup.
        let adjusted = try XCTUnwrap(session.enqueueSnapshot())
        try await Task.sleep(for: .milliseconds(20))
        weak let releasedView = terminal
        let releasedInteraction = WeakReference(terminal?.nativeInteraction)
        releaseTerminal()
        XCTAssertNil(releasedView)
        XCTAssertNil(releasedInteraction.value, "The nudge waiter must not retain its unowned-view controller")

        await gate.open()
        let after = try await adjusted.value
        XCTAssertNotEqual(after.selection, before.selection, "Accepted native adjustment still executes")
        _ = try await session.snapshot()
        try await Task.sleep(for: .milliseconds(20))
    }

    func testLatePointerCompletionWithRetainedControllerDoesNotPerformUIWork() async throws {
        let session = VTTerminalSession(write: { _ in }, resize: { _ in })
        defer { session.finish() }
        try await mount(session)
        let point = try inputPoint()
        let gate = await hold(session)
        defer { Task { await gate.open() } }
        let pointer = try XCTUnwrap(terminal?.nativePointer)
        let staleUI = expectation(description: "stale pointer UI completion")
        staleUI.isInverted = true
        pointer.onDiagnostic = { _ in staleUI.fulfill() }
        pointer.tap(at: point, modifiers: [], onLocalTap: { staleUI.fulfill() })
        try await Task.sleep(for: .milliseconds(20))
        weak let releasedView = terminal
        releaseTerminal()
        XCTAssertNil(releasedView)

        await gate.open()
        try await awaitCompletion(.pointer(applied: false))
        await fulfillment(of: [staleUI], timeout: 0)
        withExtendedLifetime(pointer) {}
    }

    func testLateCopyDoesNotOverwritePasteboardAfterViewRelease() async throws {
        let session = VTTerminalSession(write: { _ in }, resize: { _ in })
        defer { session.finish() }
        try await mount(session)
        session.receive(Data("alpha beta".utf8))
        let frame = try await session.snapshot()
        try await session.enqueueSelect(.word, at: .init(column: 1, row: 0),
            generation: frame.layout.generation)?.value
        try await waitUntil("selection frame") { self.terminal?.surface?.frameValue?.hasSelection == true }
        // Never read another app's clipboard to save/restore it: the physical
        // device permission sheet steals focus and invalidates this fixture.
        // This test owns only the sentinel it writes, like the local-key tests.
        defer { UIPasteboard.general.items = [] }
        let sentinel = UUID().uuidString
        UIPasteboard.general.string = sentinel
        let gate = await hold(session)
        defer { Task { await gate.open() } }
        XCTAssertEqual(terminal?.nativeInteraction.copySelection(), true)
        let copied = try XCTUnwrap(session.enqueueSnapshot())
        try await Task.sleep(for: .milliseconds(20))
        weak let releasedView = terminal
        releaseTerminal()
        XCTAssertNil(releasedView)

        await gate.open()
        let afterCopy = try await copied.value
        XCTAssertNil(afterCopy.selection, "Accepted native take-and-clear still executes")
        try await awaitCompletion(.copy(applied: false))
        XCTAssertEqual(UIPasteboard.general.string, sentinel, "Stale completion must not update global UI")
    }

    func testLateSelectionClearWithRetainedControllerDoesNotUpdateUIState() async throws {
        let session = VTTerminalSession(write: { _ in }, resize: { _ in })
        defer { session.finish() }
        try await mount(session)
        let gate = await hold(session)
        defer { Task { await gate.open() } }
        let interaction = try XCTUnwrap(terminal?.nativeInteraction)
        interaction.clearSelection()
        XCTAssertTrue(interaction.isSelectionClearPending)
        try await Task.sleep(for: .milliseconds(20))
        weak let releasedView = terminal
        releaseTerminal()
        XCTAssertNil(releasedView)

        await gate.open()
        try await awaitCompletion(.selectionClear(applied: false))
        XCTAssertTrue(interaction.isSelectionClearPending,
            "A controller surviving its view must ignore stale UI completion state")
        withExtendedLifetime(interaction) {}
    }

    func testTapCapturedByRemoteMouseTrackingStillTakesKeyboardFocus() async throws {
        let session = VTTerminalSession(write: { _ in }, resize: { _ in })
        defer { session.finish() }
        try await mount(session)
        session.receive(Data("\u{1B}[?1000h\u{1B}[?1006h".utf8))
        _ = try await session.snapshot()
        let terminal = try XCTUnwrap(terminal)
        terminal.resignFirstResponderForApplicationAction()
        XCTAssertFalse(terminal.isFirstResponder)
        terminal.nativeInteraction.tap(at: try inputPoint(), modifiers: [])
        try await waitUntil("focus after captured tap") { terminal.isFirstResponder }
    }

    func testMomentumTickDoesNotDropANewerQueuedTap() async throws {
        let session = VTTerminalSession(write: { _ in }, resize: { _ in })
        defer { session.finish() }
        try await mount(session)
        let point = try inputPoint()
        let gate = await hold(session)
        defer { Task { await gate.open() } }
        let pointer = try XCTUnwrap(terminal?.nativePointer)
        var tapped = false
        pointer.tap(at: point, modifiers: [], onLocalTap: { tapped = true })
        // A display-link momentum tick from an earlier fling lands before the
        // tap's native completion.
        pointer.scroll(at: point, delta: CGPoint(x: 0, y: -4), modifiers: [], localOnly: true)
        await gate.open()
        try await waitUntil("local tap action") { tapped }
    }

    func testSupersededWordReleaseEndsLongPressSelection() async throws {
        let session = VTTerminalSession(write: { _ in }, resize: { _ in })
        defer { session.finish() }
        try await mount(session)
        session.receive(Data("alpha beta".utf8))
        _ = try await session.snapshot()
        let point = try inputPoint()
        let interaction = try XCTUnwrap(terminal?.nativeInteraction)
        let gate = await hold(session)
        defer { Task { await gate.open() } }
        interaction.wordSelection(state: .began, at: point, modifiers: [])
        interaction.wordSelection(state: .ended, at: point, modifiers: [])
        XCTAssertTrue(interaction.isSelecting)
        // A selection-handle grab cancels the pointer while the release is queued.
        terminal?.nativePointer.cancel()
        await gate.open()
        try await waitUntil("word selection ended") { !interaction.isSelecting }
    }
}
#endif
