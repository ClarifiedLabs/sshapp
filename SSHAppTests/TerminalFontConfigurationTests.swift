import UIKit
import XCTest
@testable import GhosttyTerminal

@MainActor
final class TerminalFontConfigurationTests: XCTestCase {
    func testUnconfiguredViewUsesDefaultAndMountedHostInheritsController() throws {
        let unmounted = UITerminalView(frame: .zero)
        XCTAssertEqual(unmounted.currentFontSize, 14)
        XCTAssertNil(unmounted.core.fontSize)

        let fixture = try mount(controllerSize: 20)
        defer { fixture.close() }
        try assertFont(fixture.view, 20)
        XCTAssertNil(fixture.view.core.fontSize, "The default property value is not a local override")
    }

    func testSurfaceOptionsOverrideControllerAndUnzoomedUpdatesReachMountedHost() throws {
        let fixture = try mount(controllerSize: 20, optionSize: 22)
        defer { fixture.close() }
        let view = fixture.view
        try assertFont(view, 22)

        XCTAssertTrue(fixture.controller.setTerminalConfiguration(.init().fontSize(24)))
        try assertFont(view, 22)
        view.configuration.fontSize = 26
        try assertFont(view, 26)
        view.configuration.fontSize = nil
        try assertFont(view, 24)
        XCTAssertTrue(fixture.controller.setTerminalConfiguration(.init().fontSize(28)))
        try assertFont(view, 28)
        XCTAssertNil(view.core.fontSize)
    }

    func testExplicitDefaultAssignmentOverridesInheritedFontAndTracksAppUpdates() throws {
        let fixture = try mount(controllerSize: 20, optionSize: 22)
        defer { fixture.close() }
        let view = fixture.view
        view.configuredFontSize = 14
        try assertFont(view, 14)
        XCTAssertNotNil(view.core.fontSize)

        XCTAssertTrue(fixture.controller.setTerminalConfiguration(.init().fontSize(24)))
        view.configuration.fontSize = 26
        try assertFont(view, 14)
        view.configuredFontSize = 18
        try assertFont(view, 18)
    }

    func testHardwareZoomStartsAtInheritedSizeAndHoldsUntilResetToLatestController() throws {
        let fixture = try mount(controllerSize: 20)
        defer { fixture.close() }
        let view = fixture.view
        let plus = TerminalUIKitKeyPress(
            keyCode: .keyboardEqualSign, characters: "=", modifierFlags: .command
        )
        XCTAssertTrue(view.handleKeyPress(plus, action: .press))
        XCTAssertTrue(view.handleKeyPress(plus, action: .release))
        try assertFont(view, 21)
        XCTAssertTrue(view.isFontSizeTransientlyAdjusted)
        XCTAssertNotNil(view.core.fontSize)

        XCTAssertTrue(fixture.controller.setTerminalConfiguration(.init().fontSize(24)))
        try assertFont(view, 21)
        XCTAssertTrue(view.resetFontSize())
        try assertFont(view, 24)
        XCTAssertFalse(view.isFontSizeTransientlyAdjusted)
        XCTAssertNil(view.core.fontSize)
        XCTAssertTrue(fixture.controller.setTerminalConfiguration(.init().fontSize(26)))
        try assertFont(view, 26)
    }

    func testStickyZoomStartsAtSurfaceOptionAndResetUsesLatestOption() throws {
        let fixture = try mount(controllerSize: 20, optionSize: 22)
        defer { fixture.close() }
        let view = fixture.view
        view.toggleStickyModifier(.command)
        XCTAssertTrue(view.handleStickyTextInput("+"))
        try assertFont(view, 23)

        XCTAssertTrue(fixture.controller.setTerminalConfiguration(.init().fontSize(24)))
        view.configuration.fontSize = 26
        try assertFont(view, 23)
        XCTAssertTrue(view.isFontSizeTransientlyAdjusted)
        XCTAssertTrue(view.resetFontSize())
        try assertFont(view, 26)
        XCTAssertNil(view.core.fontSize)
    }

    func testExplicitBaselineUpdatesPreserveZoomAndResetRestoresLatestAppSetting() throws {
        let fixture = try mount(controllerSize: 20, optionSize: 22, configuredSize: 14)
        defer { fixture.close() }
        let view = fixture.view
        try assertFont(view, 14)
        view.scheduleViewportRefreshAfterKeyboardZoom(.increase)
        try assertFont(view, 15)

        view.configuredFontSize = 18
        XCTAssertTrue(fixture.controller.setTerminalConfiguration(.init().fontSize(24)))
        view.configuration.fontSize = 26
        try assertFont(view, 15)
        XCTAssertTrue(view.resetFontSize())
        try assertFont(view, 18)
        XCTAssertNotNil(view.core.fontSize)
        XCTAssertEqual(view.configuredFontSize, 18)
        XCTAssertEqual(view.configuration.fontSize, 26)
        XCTAssertEqual(fixture.controller.vtFontSize, 24)
    }

    func testControllerReplacementResetsZoomBeforeCreatingReplacementHost() throws {
        let fixture = try mount(controllerSize: 20)
        defer { fixture.close() }
        let view = fixture.view
        view.scheduleViewportRefreshAfterKeyboardZoom(.increase)
        try assertFont(view, 21)
        view.controller = TerminalController(
            configSource: .none, theme: .init(), terminalConfiguration: .init().fontSize(24)
        )
        try assertFont(view, 24)
        XCTAssertFalse(view.isFontSizeTransientlyAdjusted)
        XCTAssertNil(view.core.fontSize)
    }

    private func assertFont(
        _ view: UITerminalView, _ expected: Float,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let surface = try XCTUnwrap(view.surface, file: file, line: line)
        XCTAssertEqual(view.currentFontSize, expected, file: file, line: line)
        XCTAssertEqual(surface.contentView.font.pointSize, CGFloat(expected), file: file, line: line)
    }

    private func mount(
        controllerSize: Float, optionSize: Float? = nil, configuredSize: Float? = nil
    ) throws -> Fixture {
        let session = VTTerminalSession(write: { _ in }, resize: { _ in })
        let controller = TerminalController(
            configSource: .none, theme: .init(),
            terminalConfiguration: .init().fontSize(controllerSize)
        )
        let view = UITerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        if let configuredSize { view.configuredFontSize = configuredSize }
        view.configuration = .init(backend: .vt(session), fontSize: optionSize)
        view.controller = controller
        let window = UIWindow(frame: view.bounds)
        let root = UIViewController()
        window.rootViewController = root
        root.view.addSubview(view)
        window.isHidden = false
        view.layoutIfNeeded()
        let fixture = Fixture(view: view, controller: controller, session: session, window: window)
        guard view.surface != nil else {
            fixture.close()
            XCTFail("Mounting a real UIKit terminal must create its surface")
            throw NSError(domain: "TerminalFontConfigurationTests.mount", code: 1)
        }
        return fixture
    }

    @MainActor
    private struct Fixture {
        let view: UITerminalView
        let controller: TerminalController
        let session: VTTerminalSession
        let window: UIWindow

        func close() {
            view.controller = nil
            view.removeFromSuperview()
            window.isHidden = true
            session.finish()
        }
    }
}
