import UIKit
import XCTest
@testable import GhosttyTerminal

final class TerminalControllerWakeupTests: XCTestCase {
    /// VT host teardown is independent of the session FIFO. Recreating the
    /// UIKit host must preserve the parser/screen instead of waiting on a native
    /// surface-pointer lock or replaying output into a replacement engine.
    @MainActor
    func testHostRecreationPreservesVTSemanticState() async throws {
        let mounted = try mountTerminal()
        defer { unmountTerminal(mounted) }
        let terminal = mounted.terminal
        let controller = TerminalController()
        let session = VTTerminalSession(write: { _ in }, resize: { _ in })
        defer { session.finish() }
        let delegate = RecordingLifecycleDelegate()
        terminal.delegate = delegate
        terminal.configuration = TerminalSurfaceOptions(backend: .vt(session))
        terminal.controller = controller
        try await waitUntil("initial VT host attaches") { delegate.attachedSurfaces.count == 1 }
        XCTAssertTrue(session.receiveIfSurfaceAttached(Data("retained VT".utf8)))
        let before = try await session.snapshot()

        terminal.controller = nil
        XCTAssertEqual(delegate.detachCount, 1)
        let detached = try await session.snapshot()
        XCTAssertEqual(detached.line(0), before.line(0))
        terminal.controller = controller
        try await waitUntil("replacement VT host attaches") { delegate.attachedSurfaces.count == 2 }
        let after = try await session.snapshot()
        XCTAssertTrue(after.line(0).hasPrefix("retained VT"))
        XCTAssertTrue(delegate.attachedSurfaces.last === terminal.surface)
        terminal.controller = nil
    }

    @MainActor
    func testExplicitVTFinishClosesAdmissionWithoutBlockingHost() async throws {
        let session = VTTerminalSession(write: { _ in }, resize: { _ in })
        session.updateViewport(.init(width: 390, height: 480, cellWidth: 10, cellHeight: 20, scale: 2))
        session.receive(Data("accepted".utf8))
        let acceptedSnapshot = Task { try await session.snapshot() }
        _ = try await acceptedSnapshot.value
        let start = Date()
        session.finish()
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
        XCTAssertFalse(session.receiveIfSurfaceAttached(Data("late".utf8)))
        XCTAssertNil(session.enqueueSelectedText())
    }

    // MARK: - Surface lifecycle helpers

    @MainActor
    private final class RecordingLifecycleDelegate: NSObject, TerminalSurfaceLifecycleDelegate, TerminalSurfaceGridResizeDelegate {
        var onDetach: (() -> Void)?
        var onResize: (() -> Void)?
        var attachedSurfaces: [TerminalSurface] = []
        var detachCount = 0

        func terminalDidAttachSurface(_ surface: TerminalSurface) {
            attachedSurfaces.append(surface)
        }

        func terminalDidDetachSurface() {
            detachCount += 1
            onDetach?()
        }

        func terminalDidResize(_ size: TerminalGridMetrics) {
            onResize?()
        }
    }

    @MainActor
    private struct MountedTerminal {
        let terminal: UITerminalView
        let window: UIWindow
        let previousKeyWindow: UIWindow?
    }

    @MainActor
    private func mountTerminal() throws -> MountedTerminal {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else {
            throw XCTSkip("The app-hosted unit test has no UIWindowScene")
        }

        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let rootViewController = UIViewController()
        let terminal = UITerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        rootViewController.view.frame = terminal.frame
        rootViewController.view.addSubview(terminal)
        window.rootViewController = rootViewController
        window.frame = scene.coordinateSpace.bounds
        window.makeKeyAndVisible()
        rootViewController.view.layoutIfNeeded()

        return MountedTerminal(
            terminal: terminal,
            window: window,
            previousKeyWindow: previousKeyWindow
        )
    }

    @MainActor
    private func unmountTerminal(_ mounted: MountedTerminal) {
        mounted.terminal.removeFromSuperview()
        mounted.window.isHidden = true
        mounted.previousKeyWindow?.makeKey()
    }
}
