import GhosttyKit
import UIKit
import XCTest
@testable import GhosttyTerminal

final class TerminalLinkInteractionTests: XCTestCase {
    @MainActor
    func testStationaryCommandClickOpensVisibleURLExactlyOnce() async throws {
        let mounted = try mountTerminal()
        let terminal = mounted.terminal
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        let controller = TerminalController()
        let delegate = RecordingLinkDelegate()
        defer {
            terminal.delegate = nil
            terminal.controller = nil
            unmountTerminal(mounted)
        }

        terminal.delegate = delegate
        terminal.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        terminal.controller = controller

        await waitUntil("terminal surface attachment") {
            delegate.surface != nil
        }
        let surface = try XCTUnwrap(delegate.surface)

        let expectedURL = "https://example.com/sshapp-link"
        let output = "\u{1B}[2J\u{1B}[H\(expectedURL)\r\n"
        XCTAssertTrue(
            session.receiveIfSurfaceAttached(Data(output.utf8)),
            "The URL must be written to the attached Ghostty surface"
        )

        let metrics = try XCTUnwrap(surface.size())
        let padding = try XCTUnwrap(surface.gridPadding())
        let scale = terminal.resolvedDisplayScale()
        XCTAssertGreaterThan(metrics.columns, 0)
        XCTAssertGreaterThan(metrics.rows, 0)
        XCTAssertGreaterThan(metrics.cellWidthPixels, 0)
        XCTAssertGreaterThan(metrics.cellHeightPixels, 0)
        XCTAssertGreaterThan(scale, 0)

        let column = 10
        let point = CGPoint(
            x: (
                CGFloat(padding.leftPixels)
                    + (CGFloat(column) + 0.5) * CGFloat(metrics.cellWidthPixels)
            ) / scale,
            y: (
                CGFloat(padding.topPixels)
                    + 0.5 * CGFloat(metrics.cellHeightPixels)
            ) / scale
        )
        XCTAssertLessThan(column, expectedURL.count)
        XCTAssertTrue(terminal.bounds.contains(point))

        let noModifiers = TerminalInputModifiers().ghosttyMods
        let command = TerminalInputModifiers.super_.ghosttyMods

        surface.sendMousePos(x: point.x, y: point.y, mods: noModifiers)
        surface.sendMousePos(x: point.x, y: point.y, mods: command)
        surface.sendMouseButton(
            state: GHOSTTY_MOUSE_PRESS,
            button: GHOSTTY_MOUSE_LEFT,
            mods: command
        )
        surface.sendMousePos(x: point.x, y: point.y, mods: command)
        surface.sendMouseButton(
            state: GHOSTTY_MOUSE_RELEASE,
            button: GHOSTTY_MOUSE_LEFT,
            mods: command
        )

        await waitUntil("open-URL delegate callback") {
            !delegate.openedURLs.isEmpty
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(delegate.openedURLs, [expectedURL])
    }

    @MainActor
    func testHoverStatePositionForwardsOnlyMovementAndTrueExit() {
        let inViewPoint = CGPoint(x: 42, y: 84)
        let offGridPoint = CGPoint(x: -1, y: -1)

        XCTAssertEqual(
            UITerminalView.pointerHoverPosition(
                for: .began,
                location: inViewPoint
            ),
            inViewPoint
        )
        XCTAssertEqual(
            UITerminalView.pointerHoverPosition(
                for: .changed,
                location: inViewPoint
            ),
            inViewPoint
        )
        XCTAssertEqual(
            UITerminalView.pointerHoverPosition(
                for: .ended,
                location: inViewPoint
            ),
            offGridPoint
        )
        XCTAssertNil(
            UITerminalView.pointerHoverPosition(
                for: .cancelled,
                location: inViewPoint
            )
        )
        XCTAssertNil(
            UITerminalView.pointerHoverPosition(
                for: .failed,
                location: inViewPoint
            )
        )
    }

    @MainActor
    func testHoverRecognizerPassivelyObservesPointerInput() throws {
        let terminal = UITerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let recognizer = try XCTUnwrap(
            terminal.gestureRecognizers?.compactMap { $0 as? UIHoverGestureRecognizer }.first
        )

        XCTAssertFalse(recognizer.cancelsTouchesInView)
        XCTAssertFalse(recognizer.delaysTouchesBegan)
        XCTAssertFalse(recognizer.delaysTouchesEnded)
    }

    @MainActor
    private final class RecordingLinkDelegate:
        NSObject,
        TerminalSurfaceLifecycleDelegate,
        TerminalSurfaceOpenURLDelegate
    {
        private(set) var surface: TerminalSurface?
        private(set) var openedURLs: [String] = []

        func terminalDidAttachSurface(_ surface: TerminalSurface) {
            self.surface = surface
        }

        func terminalDidDetachSurface() {
            surface = nil
        }

        func terminalDidRequestOpenURL(
            _ url: String,
            kind _: TerminalOpenURLKind
        ) {
            openedURLs.append(url)
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
            ?? UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first
        else {
            throw XCTSkip("The app-hosted unit test has no UIWindowScene")
        }

        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let rootViewController = UIViewController()
        let terminal = UITerminalView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 600)
        )
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

    @MainActor
    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("Timed out waiting for \(description)", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
