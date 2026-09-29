import Foundation
import XCTest
import GhosttyVT
@testable import GhosttyTerminal

final class TerminalControllerConfigurationTests: XCTestCase {
    @MainActor
    func testRejectedOverrideIsTransactionalAndRecoveryNotifiesBeforeCommit() throws {
        let controller = TerminalController(configSource: .generated("font-size = 8"), theme: .init())
        let source = controller.currentConfigSource
        let rendered = controller.renderedConfig
        let configuration = controller.resolvedVTConfiguration
        var notifications = 0
        XCTAssertFalse(controller.setTerminalConfiguration(.init().fontSize(49), willChange: {
            notifications += 1
        }))
        XCTAssertEqual(notifications, 0)
        XCTAssertEqual(controller.currentConfigSource, source)
        XCTAssertEqual(controller.renderedConfig, rendered)
        XCTAssertEqual(controller.resolvedVTConfiguration, configuration)
        XCTAssertEqual(controller.terminalConfiguration, .init())
        XCTAssertNotNil(controller.lastConfigurationIssue)

        let next = TerminalConfiguration().fontSize(12)
        XCTAssertTrue(controller.setTerminalConfiguration(next, willChange: {
            notifications += 1
            XCTAssertEqual(controller.vtFontSize, 8)
            XCTAssertEqual(controller.terminalConfiguration, .init())
            XCTAssertEqual(controller.renderedConfig, rendered)
        }))
        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(controller.terminalConfiguration, next)
        XCTAssertEqual(controller.vtFontSize, 12)
        XCTAssertNil(controller.lastConfigurationIssue)
    }

    @MainActor
    func testBaseOverrideThemePrecedenceAndSchemeOnlyChange() throws {
        let controller = TerminalController(
            configSource: .generated("font-family = Menlo\nfont-size = 8\nforeground = 111111\npalette = 1=222222"),
            theme: TerminalTheme(
                light: .init().foreground("444444").palette(1, color: "555555"),
                dark: .init().foreground("666666").palette(1, color: "777777")
            ),
            terminalConfiguration: .init().fontSize(12).foreground("333333")
        )
        XCTAssertEqual(controller.vtFontFamily, "Menlo")
        XCTAssertEqual(controller.vtFontSize, 12)
        XCTAssertEqual(controller.vtConfiguration().foreground, try VTColor(hex: "444444"))
        XCTAssertEqual(controller.vtConfiguration().palette[1], try VTColor(hex: "555555"))
        controller.setColorScheme(.dark)
        XCTAssertTrue(controller.vtConfiguration().dark)
        XCTAssertEqual(controller.vtConfiguration().foreground, try VTColor(hex: "666666"))
        XCTAssertEqual(controller.vtConfiguration().palette[1], try VTColor(hex: "777777"))

        let unthemed = TerminalController(configSource: .generated("font-size = 8"), theme: .init())
        let rendered = unthemed.renderedConfig
        let source = unthemed.currentConfigSource
        var notifications = 0
        XCTAssertTrue(unthemed.setColorScheme(.dark, willChange: {
            notifications += 1
            XCTAssertEqual(unthemed.effectiveColorScheme, .light)
            XCTAssertFalse(unthemed.vtConfiguration().dark)
        }))
        XCTAssertEqual(notifications, 1)
        XCTAssertTrue(unthemed.vtConfiguration().dark)
        XCTAssertEqual(unthemed.renderedConfig, rendered)
        XCTAssertEqual(unthemed.currentConfigSource, source)
    }

    @MainActor
    func testRejectedThemeAndSchemeLeaveCommittedStateUnchanged() {
        let theme = TerminalTheme(light: .init().background("112233"), dark: .init().fontSize(49))
        let controller = TerminalController(configSource: .none, theme: theme)
        let rendered = controller.renderedConfig
        let resolved = controller.resolvedVTConfiguration
        var notifications = 0
        XCTAssertFalse(controller.setColorScheme(.dark, willChange: { notifications += 1 }))
        XCTAssertEqual(controller.effectiveColorScheme, .light)
        XCTAssertEqual(controller.theme, theme)
        XCTAssertEqual(controller.renderedConfig, rendered)
        XCTAssertEqual(controller.resolvedVTConfiguration, resolved)
        XCTAssertNotNil(controller.lastConfigurationIssue)
        XCTAssertFalse(controller.setTheme(.init(light: .init().custom("unknown", "value")),
                                           willChange: { notifications += 1 }))
        XCTAssertEqual(notifications, 0)
        XCTAssertEqual(controller.theme, theme)
        XCTAssertEqual(controller.resolvedVTConfiguration, resolved)
        XCTAssertTrue(controller.setTheme(.init(light: .init().background("445566"))))
        XCTAssertNil(controller.lastConfigurationIssue)
    }

    @MainActor
    func testFileContentsAreOwnedAndRawSourceUpdatesDoNotReplaceInitialBase() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try "font-family = Menlo\nfont-size = 8".write(to: url, atomically: true, encoding: .utf8)
        let controller = TerminalController(configSource: .file(url.path), theme: .init())
        XCTAssertEqual(controller.currentConfigSource, .file(url.path))
        try FileManager.default.removeItem(at: url)
        controller.setColorScheme(.dark)
        XCTAssertEqual(controller.vtFontSize, 8)
        XCTAssertNil(controller.lastConfigurationIssue)

        XCTAssertTrue(controller.updateConfigSource(.generated("font-family = Courier New\nfont-size = 9")))
        XCTAssertEqual(controller.vtFontFamily, "Courier New")
        // Source updates are immediate raw overrides; builder changes still fold
        // the initial base, exactly as before native-config removal.
        XCTAssertTrue(controller.setTerminalConfiguration(.init().fontSize(12)))
        XCTAssertEqual(controller.vtFontFamily, "Menlo")
        XCTAssertEqual(controller.vtFontSize, 12)
        XCTAssertTrue(controller.setTerminalConfiguration(.init()))
        XCTAssertEqual(controller.currentConfigSource, .file(url.path))
        XCTAssertEqual(controller.vtFontSize, 8)
    }

    @MainActor
    func testMissingFileAndMalformedGeneratedUpdatesRejectAndRecover() {
        let controller = TerminalController(configSource: .generated("font-size = 8"), theme: .init())
        let source = controller.currentConfigSource
        let rendered = controller.renderedConfig
        let resolved = controller.resolvedVTConfiguration
        for invalid in [TerminalController.ConfigSource.file("/missing-\(UUID().uuidString)"),
                        .generated("font-size = nan"), .generated("clipboard-read = allow")] {
            XCTAssertFalse(controller.updateConfigSource(invalid))
            XCTAssertEqual(controller.currentConfigSource, source)
            XCTAssertEqual(controller.renderedConfig, rendered)
            XCTAssertEqual(controller.resolvedVTConfiguration, resolved)
            XCTAssertNotNil(controller.lastConfigurationIssue)
        }
        XCTAssertTrue(controller.updateConfigSource(.generated("font-size = 10")))
        XCTAssertEqual(controller.vtFontSize, 10)
        XCTAssertNil(controller.lastConfigurationIssue)
    }

    @MainActor
    func testInvalidInitialSourceFallsBackWithoutHidingIssueAndCanRecover() {
        for source in [TerminalController.ConfigSource.file("/missing-\(UUID().uuidString)"),
                       .generated("unknown = value")] {
            let controller = TerminalController(configSource: source, theme: .init())
            XCTAssertEqual(controller.currentConfigSource, .none)
            XCTAssertEqual(controller.renderedConfig, TerminalConfiguration.default.rendered)
            XCTAssertNotNil(controller.lastConfigurationIssue)
            XCTAssertTrue(controller.setTerminalConfiguration(.init().fontSize(12)))
            XCTAssertNil(controller.lastConfigurationIssue)
            XCTAssertEqual(controller.vtFontSize, 12)
            XCTAssertTrue(controller.setTerminalConfiguration(.init()))
            XCTAssertEqual(controller.currentConfigSource, .none)
        }
    }

    @MainActor
    func testNativePaddingValidationRemainsBoundedWithoutNativeConfig() {
        let controller = TerminalController(configSource: .none, theme: .init())
        let original = controller.resolvedVTConfiguration
        // The old second/native validator rejected these although Double accepted
        // them. Keep the shipped unsigned-integer contract, not a general parser.
        for value in ["2.0", "2e0", "4294967296", "1e100", "-1", "nan"] {
            XCTAssertFalse(controller.updateConfigSource(.generated(
                "window-padding-x = \(value)\nwindow-padding-y = \(value)"
            )), value)
            XCTAssertEqual(controller.resolvedVTConfiguration, original)
            XCTAssertNotNil(controller.lastConfigurationIssue)
        }
        XCTAssertTrue(controller.updateConfigSource(.generated("window-padding-x = 4\nwindow-padding-y = 4")))
        XCTAssertEqual(controller.vtPadding, 4)
        XCTAssertNil(controller.lastConfigurationIssue)
    }

    @MainActor
    func testDetachedSessionsReceiveOnlyCommittedConfigurationInFIFOOrder() async throws {
        let controller = TerminalController(configSource: .generated("background = 112233"), theme: .init())
        let session = VTTerminalSession(write: { _ in }, resize: { _ in })
        defer { session.finish() }
        controller.registerVTSession(session)
        controller.registerVTSession(session)
        XCTAssertEqual(controller.vtSessions.count, 1)
        // No UIKit host is attached. Registration must survive that state.
        session.updateViewport(.init(width: 390, height: 480, cellWidth: 10, cellHeight: 20, scale: 2))
        session.receive(Data("accepted".utf8))
        let first = try await session.snapshot()
        XCTAssertEqual(first.background, try VTColor(hex: "112233"))
        XCTAssertFalse(controller.updateConfigSource(.generated("background = invalid")))
        let rejected = try await session.snapshot()
        XCTAssertEqual(rejected.background, first.background)
        XCTAssertTrue(controller.updateConfigSource(.generated("background = 445566")))
        let committed = try await session.snapshot()
        XCTAssertEqual(committed.background, try VTColor(hex: "445566"))
        XCTAssertTrue(committed.line(0).hasPrefix("accepted"))
        session.finish()
        XCTAssertTrue(controller.updateConfigSource(.generated("background = 778899")))
        XCTAssertTrue(controller.vtSessions.isEmpty)
    }

    @MainActor
    func testControllerDoesNotRetainRegisteredSession() async throws {
        let controller = TerminalController(configSource: .none, theme: .init())
        var session: VTTerminalSession? = VTTerminalSession(write: { _ in }, resize: { _ in })
        weak let weakSession = session
        controller.registerVTSession(try XCTUnwrap(session))
        // Drain the accepted registration before checking weak ownership.
        try await session?.enqueueConfiguration(controller.vtConfiguration())?.value
        session = nil
        // Completion is resolved just before the FIFO drainer releases its
        // accepted-work retain. Do not confuse that short lifetime with ownership.
        let deadline = Date().addingTimeInterval(2)
        while weakSession != nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertNil(weakSession)
        XCTAssertTrue(controller.updateConfigSource(.generated("font-size = 12")))
        XCTAssertTrue(controller.vtSessions.isEmpty)
    }
}
