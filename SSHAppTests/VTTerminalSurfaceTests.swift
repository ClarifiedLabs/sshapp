import UIKit
import XCTest
@testable import GhosttyTerminal
@testable import GhosttyVT

@MainActor
final class VTTerminalSurfaceTests: XCTestCase {
    private var windows: [(window: UIWindow, previousKeyWindow: UIWindow?)] = []
    private var surfaces: [TerminalSurface] = []

    override func tearDown() async throws {
        for surface in surfaces { surface.free() }
        surfaces.removeAll()
        for mounted in windows.reversed() {
            mounted.window.isHidden = true
            mounted.previousKeyWindow?.makeKey()
        }
        windows.removeAll()
        try await super.tearDown()
    }

    private func activeWindowScene() async throws -> UIWindowScene {
        var activeScene: UIWindowScene?
        try await waitUntil("active window scene") {
            activeScene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
            return activeScene != nil
        }
        return try XCTUnwrap(activeScene)
    }

    private func mount(_ content: UIView, in scene: UIWindowScene) {
        // Keep the terminal's 390×480 viewport while giving Metal a real presentation host.
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.addSubview(content)
        windows.append((window, previousKeyWindow))
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        content.layoutIfNeeded()
    }

    private func makeSurface(session: VTTerminalSession? = nil) async throws -> TerminalSurface {
        let scene = try await activeWindowScene()
        let surface = session.map(TerminalSurface.init(session:))
            ?? TerminalSurface(write: { _ in }, resize: { _ in })
        surfaces.append(surface)
        surface.setContentFont(.monospacedSystemFont(ofSize: 12, weight: .regular))
        mount(surface.contentView, in: scene)
        surface.updateViewport(size: CGSize(width: 390, height: 480), scale: 2)
        return surface
    }

    func testQueriesBeforeFirstFrameAreEmpty() {
        let surface = TerminalSurface(write: { _ in }, resize: { _ in })
        defer { surface.free() }
        XCTAssertFalse(surface.hasSelection())
        XCTAssertNil(surface.size())
        XCTAssertNil(surface.gridPadding())
        XCTAssertEqual(surface.imePoint().width, 0)
    }

    func testSizeAndPaddingReflectSharedLayout() async throws {
        let surface = try await makeSurface()
        surface.setContentPadding(13)
        try await waitUntil("grid") { surface.frameValue?.layout.padding == 13 }
        let size = try XCTUnwrap(surface.size())
        let layout = try XCTUnwrap(surface.frameValue?.layout)
        XCTAssertEqual(Int(size.columns), layout.columns)
        XCTAssertEqual(Int(size.rows), layout.rows)
        XCTAssertGreaterThan(size.cellWidthPixels, 0)
        let padding = try XCTUnwrap(surface.gridPadding())
        XCTAssertEqual(padding.leftPixels, 26)
        XCTAssertEqual(padding.topPixels, 26)
        let point = surface.imePoint()
        let cursor = try XCTUnwrap(surface.frameValue?.cursorRect())
        XCTAssertEqual(point.x, cursor.minX)
        XCTAssertEqual(point.y, cursor.minY)
        XCTAssertEqual(point.width, cursor.width)
        XCTAssertEqual(point.height, cursor.height)
    }

    func testSelectionQueriesAndNativeCopy() async throws {
        let surface = try await makeSurface()
        try await waitUntil("grid") { surface.size() != nil }
        surface.session.receive(Data("ALPHA BRAVO CHARLIE".utf8))
        try await waitUntil("content") { surface.frameValue?.line(0).hasPrefix("ALPHA") == true }
        let frame = try XCTUnwrap(surface.frameValue)
        await surface.session.select(.word, at: .init(column: 8, row: 0), generation: frame.layout.generation)
        try await waitUntil("selection") { surface.hasSelection() }
        let selected = await surface.session.selectedText()
        XCTAssertEqual(selected, "BRAVO")
        let inside = frame.layout.rect(column: 8, row: 0)
        XCTAssertTrue(surface.selectionContains(x: inside.midX, y: inside.midY))
        XCTAssertFalse(surface.selectionContains(x: 5, y: 400))
    }

    func testPreeditIsVisualAndDoesNotEnterTerminal() async throws {
        let surface = try await makeSurface()
        try await waitUntil("grid") { surface.size() != nil }
        surface.preedit("漢字")
        XCTAssertEqual(surface.contentView.markedText, "漢字")
        let snapshot = try await surface.session.snapshot()
        XCTAssertFalse(snapshot.line(0).contains("漢字"))
        surface.preedit("")
        XCTAssertEqual(surface.contentView.markedText, "")
    }

    func testInputAdmissionIsSynchronousAndFIFO() async throws {
        let writes = SurfaceWriteRecorder()
        let session = VTTerminalSession(write: { writes.append($0) }, resize: { _ in })
        defer { session.finish() }
        let surface = try await makeSurface(session: session)
        try await waitUntil("grid") { surface.size() != nil }
        XCTAssertTrue(surface.sendKey(hid: 4, action: .press, text: "a", unshifted: 97,
                                      modifiers: [], consumedModifiers: []))
        XCTAssertTrue(surface.sendText("漢字"))
        XCTAssertTrue(surface.sendKey(hid: 5, action: .press, text: "b", unshifted: 98,
                                      modifiers: [], consumedModifiers: []))
        surface.free()
        _ = try await session.snapshot() // FIFO barrier, including accepted input.
        XCTAssertEqual(String(decoding: writes.value, as: UTF8.self), "a漢字b")
        XCTAssertFalse(surface.sendText("late"))
        XCTAssertFalse(surface.sendKey(hid: 4, action: .release, text: "a", unshifted: 97,
                                       modifiers: [], consumedModifiers: []))
    }

    func testDetachedHostDoesNotFinishRetainedSession() async throws {
        let session = VTTerminalSession(write: { _ in }, resize: { _ in })
        defer { session.finish() }
        let first = try await makeSurface(session: session)
        try await waitUntil("first grid") { first.size() != nil }
        session.receive(Data("retained".utf8))
        let before = try await session.snapshot()
        first.free()
        first.free()
        XCTAssertNil(first.size())
        XCTAssertNil(first.contentView.superview)
        XCTAssertTrue(session.receiveIfSurfaceAttached(Data(" while detached".utf8)))
        let second = try await makeSurface(session: session)
        try await waitUntil("reattached frame") { second.frameValue?.line(0).hasPrefix("retained while detached") == true }
        XCTAssertEqual(second.frameValue?.terminalID, before.terminalID)
    }

    func testOwnedConvenienceSessionFinishesOnFree() async throws {
        let surface = try await makeSurface()
        try await waitUntil("grid") { surface.size() != nil }
        surface.free()
        surface.free()
        XCTAssertNil(surface.session.enqueueInput(.text("late")))
    }

    func testImplicitMainActorReleaseCleansSurfaceImmediately() {
        for ownsSession in [false, true] {
            let supplied = VTTerminalSession(write: { _ in }, resize: { _ in })
            var surface: TerminalSurface? = ownsSession
                ? TerminalSurface(write: { _ in }, resize: { _ in })
                : TerminalSurface(session: supplied)
            let session = surface!.session
            defer { supplied.finish(); session.finish() }
            let content = surface!.contentView
            let parent = UIView()
            parent.addSubview(content)
            content.onFrame = { _ in XCTFail("Retired surface callback") }
            content.onRendered = { _ in XCTFail("Retired render callback") }
            weak let released = surface
            surface = nil
            XCTAssertNil(released)
            XCTAssertNil(content.superview, "Main-thread cleanup must not wait for a task")
            XCTAssertNil(content.onFrame)
            XCTAssertNil(content.onRendered)
            XCTAssertEqual(session.enqueueInput(.text("after teardown")) == nil, ownsSession)
        }
    }

    func testBackgroundLastSurfaceReleasePreservesSessionOwnership() async throws {
        for ownsSession in [false, true] {
            let writes = SurfaceWriteRecorder()
            let supplied = VTTerminalSession(write: { writes.append($0) }, resize: { _ in })
            var surface: TerminalSurface? = ownsSession
                ? TerminalSurface(write: { writes.append($0) }, resize: { _ in })
                : TerminalSurface(session: supplied)
            let session = surface!.session
            defer { supplied.finish(); session.finish() }
            let content = surface!.contentView
            let parent = UIView()
            parent.addSubview(content)
            content.onFrame = { _ in XCTFail("Retired surface callback") }
            session.sendInput(Data("first".utf8))
            session.sendInput(Data("second".utf8))
            let release = VTBackgroundReleaseBox(surface!)
            weak let released = surface
            surface = nil
            release.releaseOnBackgroundSynchronously()
            XCTAssertNil(released)
            try await waitUntil("queued surface cleanup") { content.superview == nil }
            try await waitUntil("accepted FIFO work survives cleanup") {
                String(decoding: writes.value, as: UTF8.self) == "firstsecond"
            }
            XCTAssertNil(content.onFrame)
            XCTAssertEqual(session.enqueueInput(.text("after teardown")) == nil, ownsSession)
        }
    }

    // MARK: - Production coordinator lifecycle

    private func makeUnmountedCoordinator(
        session: VTTerminalSession, controller: TerminalController,
        delegate: SurfaceLifecycleRecorder
    ) -> TerminalSurfaceCoordinator {
        let core = TerminalSurfaceCoordinator()
        core.isAttached = { true }
        core.viewSize = { (390, 480) }
        core.delegate = delegate
        core.configuration = .init(backend: .vt(session))
        core.controller = controller
        return core
    }

    func testImplicitCoordinatorReleaseIsImmediateWithoutLifecycleCallbacks() throws {
        let session = VTTerminalSession(write: { _ in }, resize: { _ in })
        defer { session.finish() }
        let controller = TerminalController()
        let delegate = SurfaceLifecycleRecorder()
        var core: TerminalSurfaceCoordinator? = makeUnmountedCoordinator(
            session: session, controller: controller, delegate: delegate)
        core!.onSurfaceFreed = { _ in XCTFail("Deinit must not call external lifecycle hooks") }
        let surface = try XCTUnwrap(core!.surface)
        weak let released = core
        core = nil
        XCTAssertNil(released)
        XCTAssertTrue(controller.vtHosts.isEmpty)
        XCTAssertNil(session.eventDelegate)
        XCTAssertNil(surface.contentView.onFrame)
        XCTAssertFalse(surface.sendText("retired host"))
        XCTAssertNotNil(session.enqueueInput(.text("retained engine")))
        XCTAssertTrue(delegate.events.isEmpty)
        XCTAssertEqual(controller.vtSessions.filter { $0.value === session }.count, 1)
    }

    func testQueuedCoordinatorCleanupCannotClearSameDelegateOnReplacementHost() async throws {
        let session = VTTerminalSession(write: { _ in }, resize: { _ in })
        defer { session.finish() }
        let controller = TerminalController()
        let delegate = SurfaceLifecycleRecorder()
        var old: TerminalSurfaceCoordinator? = makeUnmountedCoordinator(
            session: session, controller: controller, delegate: delegate)
        old!.onSurfaceFreed = { _ in XCTFail("Implicit cleanup called external hook") }
        let oldSurface = try XCTUnwrap(old!.surface)
        let release = VTBackgroundReleaseBox(old!)
        weak let released = old
        old = nil
        // Main actor stays occupied until the replacement claims the same
        // session AND delegate, making the stale cleanup race deterministic.
        release.releaseOnBackgroundSynchronously()
        XCTAssertNil(released)
        let replacement = makeUnmountedCoordinator(
            session: session, controller: controller, delegate: delegate)
        defer { replacement.freeSurface() }
        try await waitUntil("old host cleanup") { oldSurface.contentView.onFrame == nil }
        XCTAssertTrue(session.eventDelegate === delegate)
        XCTAssertEqual(controller.vtHosts.count, 1)
        XCTAssertTrue(controller.vtHosts.first?.value === replacement)
        XCTAssertNotNil(replacement.surface?.contentView.onFrame)
        XCTAssertNotNil(session.enqueueInput(.text("retained engine")))
        XCTAssertTrue(delegate.events.isEmpty)
    }

    private func makeCoordinator(session: VTTerminalSession) async throws -> TerminalSurfaceCoordinator {
        // Resolve the scene before installing the synchronous, reentrant lifecycle hook.
        let scene = try await activeWindowScene()
        let core = TerminalSurfaceCoordinator()
        core.isAttached = { true }
        core.viewSize = { (390, 480) }
        core.scaleFactor = { 2 }
        core.onSurfaceCreated = { [weak self] surface in
            self?.surfaces.append(surface)
            self?.mount(surface.contentView, in: scene)
        }
        core.configuration = .init(backend: .vt(session))
        return core
    }

    /// Regression: pointer paths call setFocus(true) per event. Each call used
    /// to admit `.focus` (ESC[I under mode 1004, sealing interaction coalescing)
    /// and notify the delegate. Only transitions may reach either.
    func testRepeatedFocusAdmitsAndNotifiesOnlyTransitions() async throws {
        let writes = SurfaceWriteRecorder()
        let session = VTTerminalSession(write: { writes.append($0) }, resize: { _ in })
        defer { session.finish() }
        let core = try await makeCoordinator(session: session)
        defer { core.freeSurface() }
        let focus = SurfaceFocusRecorder()
        core.delegate = focus
        core.controller = TerminalController()
        try await waitUntil("initial frame") { core.surface?.frameValue != nil }
        XCTAssertTrue(session.receiveIfSurfaceAttached(Data("\u{1b}[?1004h".utf8)))
        _ = try await session.snapshot()

        for _ in 0..<4 { core.setFocus(true) }
        core.setFocus(true, notifyDelegate: false)
        _ = try await session.snapshot()
        XCTAssertEqual(writes.value, Data("\u{1b}[I".utf8))
        XCTAssertEqual(focus.changes, [true])

        core.setFocus(false, notifyDelegate: false)
        core.setFocus(false)
        core.setFocus(false)
        _ = try await session.snapshot()
        XCTAssertEqual(writes.value, Data("\u{1b}[I\u{1b}[O".utf8))
        XCTAssertEqual(focus.changes, [true, false],
                       "A silent programmatic change is still reported once by the next notifying call")

        // A rebuilt host must still seed the retained session with stored focus.
        core.setFocus(true)
        core.rebuildIfReady()
        try await waitUntil("rebuilt frame") { core.surface?.frameValue != nil }
        core.setFocus(true)
        _ = try await session.snapshot()
        XCTAssertEqual(writes.value, Data("\u{1b}[I\u{1b}[O\u{1b}[I\u{1b}[I".utf8))
        XCTAssertEqual(focus.changes, [true, false, true])
    }

    /// Regression: the pre-detach hook runs while the retiring host is still
    /// current, so native pointer cancellation can reach the surviving session.
    func testSurfaceWillDetachRunsWhileRetiringHostIsCurrent() async throws {
        let session = VTTerminalSession(write: { _ in }, resize: { _ in })
        defer { session.finish() }
        let core = try await makeCoordinator(session: session)
        defer { core.freeSurface() }
        core.controller = TerminalController()
        try await waitUntil("initial frame") { core.surface?.frameValue != nil }
        let first = try XCTUnwrap(core.surface)
        var events: [String] = []
        core.onSurfaceWillDetach = { [weak core] retiring in
            XCTAssertTrue(retiring === first)
            XCTAssertTrue(core?.surface === retiring)
            XCTAssertNotNil(retiring.frameValue)
            events.append("will-detach")
        }
        core.onSurfaceFreed = { _ in events.append("freed") }
        core.rebuildIfReady()
        XCTAssertEqual(events, ["will-detach", "freed"])
        XCTAssertFalse(core.surface === first)
        core.onSurfaceWillDetach = nil
        core.onSurfaceFreed = nil
    }

    /// Regression: forcedScale was applied before the new frame, admitting
    /// old size + new scale and then the new size: two remote resizes.
    func testScaleAndSizeChangeAdmitsOneViewport() async throws {
        let resizes = LockBox<[InMemoryTerminalViewport]>([])
        let surface = try await makeSurface(session: VTTerminalSession(
            write: { _ in }, resize: { value in resizes.mutate { $0.append(value) } }))
        defer { surface.session.finish() }
        try await waitUntil("initial frame") { surface.frameValue != nil }
        _ = try await surface.session.snapshot()
        let before = resizes.get().count
        surface.updateViewport(size: CGSize(width: 320, height: 400), scale: 3)
        _ = try await surface.session.snapshot()
        XCTAssertEqual(resizes.get().count, before + 1)
        let last = try XCTUnwrap(resizes.get().last)
        XCTAssertEqual(last.widthPixels, 960, "The only admitted viewport carries the new size at the new scale")
        XCTAssertEqual(last.heightPixels, 1200)
    }

    func testDefaultBackendDoesNotCreateSurfaceWithoutSession() {
        let core = TerminalSurfaceCoordinator()
        core.isAttached = { true }
        core.viewSize = { (390, 480) }
        core.controller = TerminalController()
        core.rebuildIfReady()
        XCTAssertNil(core.surface)
    }

    func testCoordinatorPublishesSettledGridBeforeAttachAndRetainsEngine() async throws {
        let session = VTTerminalSession(write: { _ in }, resize: { _ in })
        defer { session.finish() }
        let core = try await makeCoordinator(session: session)
        defer { core.freeSurface() }
        let delegate = SurfaceLifecycleRecorder()
        core.delegate = delegate
        core.controller = TerminalController()
        XCTAssertTrue(delegate.attached.isEmpty, "A provisional host is not a settled native grid")
        try await waitUntil("attach") { delegate.attached.count == 1 }
        XCTAssertEqual(delegate.events.prefix(2), ["resize", "attach"])
        let first = try XCTUnwrap(core.surface)
        let before = try await session.snapshot()
        core.freeSurface()
        XCTAssertEqual(delegate.events.last, "detach")
        core.rebuildIfReady()
        try await waitUntil("reattach") { delegate.attached.count == 2 }
        XCTAssertFalse(core.surface === first)
        XCTAssertEqual(core.surface?.frameValue?.terminalID, before.terminalID)
    }

    func testDetachedRetainedSessionReceivesConfigurationAndSchemeRepliesWithoutDuplicateRegistration() async throws {
        let writes = SurfaceWriteRecorder()
        let session = VTTerminalSession(write: { writes.append($0) }, resize: { _ in })
        defer { session.finish() }
        let controller = TerminalController()
        controller.setColorScheme(.light)
        weak var releasedCoordinator: TerminalSurfaceCoordinator?
        do {
            let core = try await makeCoordinator(session: session)
            releasedCoordinator = core
            core.controller = controller
            try await waitUntil("initial frame") { core.surface?.frameValue != nil }
            XCTAssertTrue(session.receiveIfSurfaceAttached(Data("\u{1b}[?2031h".utf8)))
            _ = try await session.snapshot() // Subscribe before the scheme change.
            let replyStart = writes.value.count

            core.freeSurface()
            XCTAssertTrue(controller.vtHosts.isEmpty)
            XCTAssertEqual(controller.vtSessions.filter { $0.value === session }.count, 1)
            XCTAssertTrue(controller.setTheme(TerminalTheme(
                dark: TerminalConfiguration().foreground("123456"))))
            controller.setColorScheme(.dark)
            XCTAssertTrue(session.receiveIfSurfaceAttached(Data("detached\u{1b}[?996n".utf8)))
            let detached = try await session.snapshot() // FIFO includes config and reply fan-out.
            XCTAssertTrue(detached.line(0).hasPrefix("detached"))
            XCTAssertEqual(detached.foreground, try VTColor(hex: "123456"))
            XCTAssertEqual(String(decoding: writes.value.dropFirst(replyStart), as: UTF8.self),
                           "\u{1b}[?997;1n\u{1b}[?997;1n") // Subscription notification, then query reply.

            core.rebuildIfReady()
            core.rebuildIfReady()
            controller.registerVTSession(session)
            XCTAssertEqual(controller.vtSessions.filter { $0.value === session }.count, 1)
            XCTAssertEqual(controller.vtHosts.filter { $0.value === core }.count, 1)
            _ = try await session.snapshot()
            XCTAssertEqual(writes.value.count - replyStart, Data("\u{1b}[?997;1n\u{1b}[?997;1n".utf8).count)
            core.freeSurface()
        }
        XCTAssertNil(releasedCoordinator)
        // Even destroying the disposable coordinator must not remove the engine
        // from configuration updates while SSH can still feed and query it.
        let replyStart = writes.value.count
        controller.setColorScheme(.light)
        XCTAssertTrue(session.receiveIfSurfaceAttached(Data("\u{1b}[?996n".utf8)))
        _ = try await session.snapshot()
        XCTAssertEqual(String(decoding: writes.value.dropFirst(replyStart), as: UTF8.self),
                       "\u{1b}[?997;2n\u{1b}[?997;2n")
        XCTAssertEqual(controller.vtSessions.filter { $0.value === session }.count, 1)

        session.finish()
        controller.pushVTConfiguration()
        XCTAssertTrue(controller.vtSessions.isEmpty)
        controller.registerVTSession(session)
        XCTAssertTrue(controller.vtSessions.isEmpty, "Retired sessions cannot register again")
    }

    func testDetachedControllerReassignmentTransfersConfigurationRegistration() async throws {
        let session = VTTerminalSession(write: { _ in }, resize: { _ in })
        defer { session.finish() }
        let core = try await makeCoordinator(session: session)
        defer { core.freeSurface() }
        let oldController = TerminalController()
        core.controller = oldController
        try await waitUntil("initial frame") { core.surface?.frameValue != nil }
        core.freeSurface()
        core.isAttached = { false }

        let replacement = TerminalController()
        XCTAssertTrue(replacement.setTheme(TerminalTheme(
            light: TerminalConfiguration().foreground("abcdef"),
            dark: TerminalConfiguration().foreground("abcdef"))))
        core.controller = replacement
        XCTAssertNil(core.surface)
        XCTAssertTrue(oldController.vtSessions.isEmpty)
        XCTAssertEqual(replacement.vtSessions.filter { $0.value === session }.count, 1)
        XCTAssertTrue(oldController.setTheme(TerminalTheme(dark: TerminalConfiguration().foreground("123456"))))
        let frame = try await session.snapshot()
        XCTAssertEqual(frame.foreground, try VTColor(hex: "abcdef"), "Only the new controller configures the retained engine")
    }

    func testResizeDelegateReplacementDoesNotAnnounceRetiredSurface() async throws {
        let first = VTTerminalSession(write: { _ in }, resize: { _ in })
        let replacement = VTTerminalSession(write: { _ in }, resize: { _ in })
        defer { first.finish(); replacement.finish() }
        let core = try await makeCoordinator(session: first)
        defer { core.freeSurface() }
        let delegate = SurfaceLifecycleRecorder()
        core.delegate = delegate
        delegate.onResize = { [weak core, weak delegate] in
            delegate?.onResize = nil
            core?.configuration = .init(backend: .vt(replacement))
        }
        core.controller = TerminalController()
        try await waitUntil("replacement attach") { delegate.attached.count == 1 }
        XCTAssertTrue(delegate.attached.first?.session === replacement)
        XCTAssertNotNil(first.enqueueInput(.text("still alive")))
    }

    func testReentrantDetachBuildsOnlyTheLatestReplacement() async throws {
        let first = VTTerminalSession(write: { _ in }, resize: { _ in })
        let replacement = VTTerminalSession(write: { _ in }, resize: { _ in })
        defer { first.finish(); replacement.finish() }
        let core = try await makeCoordinator(session: first)
        defer { core.freeSurface() }
        let delegate = SurfaceLifecycleRecorder()
        core.delegate = delegate
        core.controller = TerminalController()
        try await waitUntil("attach") { delegate.attached.count == 1 }
        var freed = 0
        core.onSurfaceFreed = { [weak core] _ in
            freed += 1
            core?.configuration = .init(backend: .vt(replacement))
        }
        core.rebuildIfReady()
        try await waitUntil("replacement attach") { delegate.attached.count == 2 }
        XCTAssertEqual(freed, 1)
        XCTAssertEqual(delegate.events.filter { $0 == "detach" }.count, 1)
        XCTAssertTrue(core.surface?.session === replacement)
        core.onSurfaceFreed = nil
    }

    func testImmediateDrawCannotCompleteFromReplacedHost() async throws {
        let session = VTTerminalSession(write: { _ in }, resize: { _ in })
        defer { session.finish() }
        let core = try await makeCoordinator(session: session)
        defer { core.freeSurface() }
        core.controller = TerminalController()
        try await waitUntil("grid") { core.surface?.frameValue != nil }
        var staleCompleted = false
        core.requestImmediateDraw { staleCompleted = true }
        core.freeSurface()
        core.rebuildIfReady()
        try await waitUntil("replacement grid") { core.surface?.frameValue != nil }
        let completed = expectation(description: "current snapshot rendered")
        core.requestImmediateDraw { completed.fulfill() }
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertFalse(staleCompleted)
    }

    func testPostRenderReplacementInvalidatesImmediateDrawCompletion() async throws {
        let session = VTTerminalSession(write: { _ in }, resize: { _ in })
        defer { session.finish() }
        let core = try await makeCoordinator(session: session)
        defer { core.freeSurface() }
        core.controller = TerminalController()
        try await waitUntil("grid") { core.surface?.frameValue != nil }
        let replaced = expectation(description: "post-render callback replaced host")
        var staleCompleted = false
        core.onPostRender = { [weak core] in
            core?.onPostRender = nil
            core?.freeSurface()
            core?.rebuildIfReady()
            replaced.fulfill()
        }
        core.requestImmediateDraw { staleCompleted = true }
        await fulfillment(of: [replaced], timeout: 5)
        try await waitUntil("replacement grid") { core.surface?.frameValue != nil }
        XCTAssertFalse(staleCompleted)
    }

    /// Regression: on physical iPads the IME fixture's keyboard accessory
    /// shrank the viewport right after readiness. The geometry epoch discarded
    /// the pending first-drain draw completion, so GhosttyTerminalView never
    /// reported onPostFlushDraw and the selection/IME fixture timed out.
    func testImmediateDrawCompletionSurvivesGeometryChangeOnSameHost() async throws {
        let session = VTTerminalSession(write: { _ in }, resize: { _ in })
        defer { session.finish() }
        let core = try await makeCoordinator(session: session)
        defer { core.freeSurface() }
        core.controller = TerminalController()
        try await waitUntil("grid") { core.surface?.frameValue != nil }
        let surface = try XCTUnwrap(core.surface)
        let epochBeforeResize = surface.contentView.presentationEpochForDiagnostics
        let initialRows = try XCTUnwrap(surface.size()?.rows)

        let completed = expectation(description: "draw completes after the resize")
        var completedRows: UInt16?
        core.requestImmediateDraw {
            completedRows = core.surface?.size()?.rows
            completed.fulfill()
        }
        // Same main-actor turn: the content view's frame task has not rendered.
        core.viewSize = { (390, 400) }
        core.synchronizeMetrics()
        XCTAssertNotEqual(
            surface.contentView.presentationEpochForDiagnostics, epochBeforeResize,
            "The resize must invalidate the content view's pending callbacks"
        )

        await fulfillment(of: [completed], timeout: 5)
        XCTAssertTrue(core.surface === surface)
        let rows = try XCTUnwrap(completedRows)
        XCTAssertLessThan(rows, initialRows, "Completion must follow a render of the new geometry")
    }

    func testImmediateDrawCompletionIsDroppedWhenHostIsHidden() async throws {
        let session = VTTerminalSession(write: { _ in }, resize: { _ in })
        defer { session.finish() }
        let core = try await makeCoordinator(session: session)
        defer { core.freeSurface() }
        core.controller = TerminalController()
        try await waitUntil("grid") { core.surface?.frameValue != nil }
        var hiddenCompleted = false
        core.requestImmediateDraw { hiddenCompleted = true }
        core.setDisplayVisible(false)
        core.setDisplayVisible(true)
        let visible = expectation(description: "visible draw completes")
        core.requestImmediateDraw { visible.fulfill() }
        await fulfillment(of: [visible], timeout: 5)
        XCTAssertFalse(hiddenCompleted)
    }

    func testLiveHostFontAndPaddingUpdateWithoutLayoutPreservesZoom() async throws {
        let session = VTTerminalSession(write: { _ in }, resize: { _ in })
        defer { session.finish() }
        let core = try await makeCoordinator(session: session)
        defer { core.freeSurface() }
        core.fontSize = { 23 } // Surface-local transient zoom.
        let controller = TerminalController()
        core.controller = controller
        try await waitUntil("initial frame") { core.surface?.frameValue != nil }
        let replacement = TerminalConfiguration { builder in
            builder.withFontFamily("Courier New")
            builder.withFontSize(12)
            builder.withWindowPaddingX(7)
            builder.withWindowPaddingY(7)
        }
        XCTAssertTrue(controller.setTerminalConfiguration(replacement))
        XCTAssertEqual(core.surface?.contentView.font.familyName, "Courier New")
        XCTAssertEqual(core.surface?.contentView.font.pointSize, 23)
        try await waitUntil("new padding") { core.surface?.frameValue?.layout.padding == 7 }
    }

    func testRetiringOldHostCannotRemoveNewHostsFrameObserver() async throws {
        let session = VTTerminalSession(write: { _ in }, resize: { _ in })
        defer { session.finish() }
        let first = try await makeSurface(session: session)
        try await waitUntil("first frame") { first.frameValue != nil }
        let second = try await makeSurface(session: session)
        try await waitUntil("second frame") { second.frameValue != nil }
        first.free()
        XCTAssertTrue(session.receiveIfSurfaceAttached(Data("replacement live".utf8)))
        try await waitUntil("new host receives output after old host retires") {
            second.frameValue?.line(0).hasPrefix("replacement live") == true
        }
    }

    func testFamilyResolutionPrefersRegularFace() {
        let font = TerminalSurfaceCoordinator.resolveFont(family: "Courier New", size: 17)
        XCTAssertEqual(font.familyName, "Courier New")
        XCTAssertEqual(font.pointSize, 17)
        XCTAssertFalse(font.fontDescriptor.symbolicTraits.contains(.traitBold))
        XCTAssertFalse(font.fontDescriptor.symbolicTraits.contains(.traitItalic))
    }
}

/// Tests deliberately hold the main actor while forcing the last strong release
/// onto a worker. Production teardown must enqueue, never synchronously dispatch.
final class VTBackgroundReleaseBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    init(_ value: Value) { self.value = value }

    func releaseOnBackgroundSynchronously() {
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            self.lock.lock()
            self.value = nil
            self.lock.unlock()
            done.signal()
        }
        precondition(done.wait(timeout: .now() + 5) == .success, "Background release deadlocked")
    }
}

private final class SurfaceWriteRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    func append(_ data: Data) { lock.lock(); defer { lock.unlock() }; storage.append(data) }
    var value: Data { lock.lock(); defer { lock.unlock() }; return storage }
}

@MainActor
private final class SurfaceFocusRecorder: TerminalSurfaceFocusDelegate {
    var changes: [Bool] = []
    func terminalDidChangeFocus(_ focused: Bool) { changes.append(focused) }
}

@MainActor
private final class SurfaceLifecycleRecorder: TerminalSurfaceLifecycleDelegate, TerminalSurfaceGridResizeDelegate {
    var attached: [TerminalSurface] = []
    var events: [String] = []
    var onResize: (() -> Void)?
    func terminalDidResize(_ size: TerminalGridMetrics) {
        XCTAssertGreaterThan(size.columns, 0)
        XCTAssertGreaterThan(size.rows, 0)
        events.append("resize")
        onResize?()
    }
    func terminalDidAttachSurface(_ surface: TerminalSurface) {
        XCTAssertNotNil(surface.frameValue)
        attached.append(surface)
        events.append("attach")
    }
    func terminalDidDetachSurface() { events.append("detach") }
}
