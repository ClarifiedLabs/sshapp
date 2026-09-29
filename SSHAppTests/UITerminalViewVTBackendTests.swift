import Foundation
import UIKit
import XCTest
@testable import GhosttyTerminal

@MainActor
final class UITerminalViewVTBackendTests: XCTestCase {
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

    func testDefaultBackendDoesNotImplicitlyCreateSessionOrSurface() {
        let coordinator = TerminalSurfaceCoordinator()
        coordinator.isAttached = { true }
        coordinator.viewSize = { (320, 480) }
        coordinator.controller = TerminalController()
        guard case .exec = coordinator.configuration.backend else {
            return XCTFail("Default options must remain unconfigured until a VT session is supplied")
        }
        XCTAssertNil(coordinator.surface)
    }

    func testPointerButtonsPreserveDiagnosticsReleaseAndCancellation() async throws {
        let writes = ByteRecorder()
        let session = VTTerminalSession(write: { writes.append($0) }, resize: { _ in })
        let (view, window) = try await mount(session)
        defer { view.controller = nil; window.isHidden = true; session.finish() }
        session.receive(Data("\u{1B}[?1000h\u{1B}[?1006h".utf8))
        _ = try await session.snapshot()
        let frame = try XCTUnwrap(view.surface?.frameValue)
        let cell = frame.layout.rect(column: 0, row: 0)
        let point = CGPoint(x: cell.midX, y: cell.midY)

        for (button, identity) in [(Int32(1), TerminalPointerButton.left), (Int32(2), .right)] {
            XCTAssertNotNil(view.nativePointer.begin(at: point, button: button, modifiers: []))
            XCTAssertEqual(view.activePointerButton, identity)
            XCTAssertEqual(view.activePointerButton?.rawValue, Int(button))
            XCTAssertTrue(view.nativePointer.isPressed)
            view.nativePointer.end(at: point, modifiers: [])
            XCTAssertNil(view.activePointerButton)
            XCTAssertFalse(view.nativePointer.isPressed)
            _ = try await session.snapshot()
        }
        XCTAssertEqual(writes.data, Data(("\u{1B}[<0;1;1M\u{1B}[<0;1;1m"
            + "\u{1B}[<2;1;1M\u{1B}[<2;1;1m").utf8))

        XCTAssertNotNil(view.nativePointer.begin(at: point, button: 2, modifiers: []))
        view.nativePointer.cancel()
        XCTAssertNil(view.activePointerButton)
        XCTAssertFalse(view.nativePointer.isPressed)
        XCTAssertFalse(view.nativePointer.isAutoscrollScheduled)
        _ = try await session.snapshot()
        // Cancellation is idempotent and cannot leave a stale pressed identity.
        view.nativePointer.cancel()
        XCTAssertNil(view.activePointerButton)
        XCTAssertNotNil(view.nativePointer.begin(at: point, modifiers: []))
        XCTAssertEqual(view.activePointerButton, .left)
        view.nativePointer.cancel()
    }

    func testUIKitHardwareNavigationUsesLiveVTCursorKeyMode() async throws {
        let writes = ByteRecorder()
        let session = VTTerminalSession(write: { writes.append($0) }, resize: { _ in })
        let (view, window) = try await mount(session)
        defer { view.controller = nil; window.isHidden = true; session.finish() }
        session.receive(Data("\u{1B}[?1h".utf8))
        let key = TerminalUIKitKeyPress(keyCode: .keyboardUpArrow, characters: "")
        view.handleKeyPress(key, action: .press)
        view.handleKeyPress(key, action: .release)
        // The snapshot is admitted after both key events in the same FIFO.
        _ = try await session.snapshot()
        XCTAssertEqual(writes.data, Data("\u{1B}OA".utf8))
    }

    func testFoldAndRotationSizedBoundsResizeTheRetainedTerminal() async throws {
        let resizes = LockBox<[InMemoryTerminalViewport]>([])
        let session = VTTerminalSession(write: { _ in }, resize: { size in
            resizes.mutate { $0.append(size) }
        })
        let (view, window) = try await mount(session)
        defer { view.controller = nil; window.isHidden = true; session.finish() }
        let surface = try XCTUnwrap(view.surface)

        // Closed landscape -> open portrait -> open landscape -> closed
        // portrait. Resize the same host without rotation notifications or
        // responder changes, as a display switch can deliver bounds alone.
        for size in [CGSize(width: 678, height: 382), CGSize(width: 669, height: 867),
                     CGSize(width: 951, height: 585), CGSize(width: 466, height: 594)] {
            view.frame = CGRect(origin: .zero, size: size)
            view.setNeedsLayout()
            view.layoutIfNeeded()
            // A FIFO snapshot barrier waits for viewport delivery to the
            // actor-owned terminal, without sleeping or recreating a session.
            let frame = try await session.snapshot()
            XCTAssertTrue(view.surface === surface, "Folding must retain the live terminal")
            XCTAssertEqual(frame.layout.viewportWidth, size.width, accuracy: 1)
            XCTAssertEqual(frame.layout.viewportHeight, size.height, accuracy: 1)
            let resize = try XCTUnwrap(resizes.get().last)
            XCTAssertEqual(Double(resize.widthPixels), size.width * frame.layout.scale, accuracy: 1)
            XCTAssertEqual(Double(resize.heightPixels), size.height * frame.layout.scale, accuracy: 1)
        }
    }

    private func mount(_ session: VTTerminalSession) async throws -> (UITerminalView, UIWindow) {
        let view = UITerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let window = UIWindow(frame: view.bounds)
        let root = UIViewController()
        window.rootViewController = root
        root.view.addSubview(view)
        window.isHidden = false
        view.configuration = .init(backend: .vt(session))
        view.controller = TerminalController()
        view.layoutIfNeeded()
        lifecycle.post(UIApplication.didBecomeActiveNotification, object: nil)
        let deadline = Date().addingTimeInterval(5)
        while view.surface?.frameValue == nil {
            guard Date() < deadline else {
                view.controller = nil
                window.isHidden = true
                session.finish()
                XCTFail("VT frame did not settle")
                throw NSError(domain: "UITerminalViewVTBackendTests", code: 1)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        return (view, window)
    }

}
