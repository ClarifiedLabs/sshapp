import XCTest
import GhosttyTerminal
@testable import SSHApp

final class TerminalKeyRepeatSettingsTests: XCTestCase {
    func testTerminalKeyRepeatSettingsDefaultToEnabledAndClampValues() throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(TerminalKeyRepeatSettings.isEnabled(defaults: defaults))
        XCTAssertEqual(
            TerminalKeyRepeatSettings.delayMilliseconds(defaults: defaults),
            TerminalHardwareKeyRepeatConfiguration.defaultDelayMilliseconds
        )
        XCTAssertEqual(
            TerminalKeyRepeatSettings.intervalMilliseconds(defaults: defaults),
            TerminalHardwareKeyRepeatConfiguration.defaultIntervalMilliseconds
        )

        defaults.set(false, forKey: AppSettingsKey.terminalKeyRepeatEnabled)
        defaults.set(10.0, forKey: AppSettingsKey.terminalKeyRepeatDelayMilliseconds)
        defaults.set(10_000.0, forKey: AppSettingsKey.terminalKeyRepeatIntervalMilliseconds)

        let configuration = TerminalKeyRepeatSettings.configuration(defaults: defaults)
        XCTAssertFalse(configuration.enabled)
        XCTAssertEqual(configuration.delayMilliseconds, TerminalHardwareKeyRepeatConfiguration.delayRange.lowerBound)
        XCTAssertEqual(configuration.intervalMilliseconds, TerminalHardwareKeyRepeatConfiguration.intervalRange.upperBound)
    }

    func testTerminalHardwareRepeatConfigurationClampsInitializerValues() {
        let configuration = TerminalHardwareKeyRepeatConfiguration(
            enabled: true,
            delayMilliseconds: 10_000,
            intervalMilliseconds: 1
        )

        XCTAssertTrue(configuration.enabled)
        XCTAssertEqual(configuration.delayMilliseconds, TerminalHardwareKeyRepeatConfiguration.delayRange.upperBound)
        XCTAssertEqual(configuration.intervalMilliseconds, TerminalHardwareKeyRepeatConfiguration.intervalRange.lowerBound)
    }

    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let suiteName = "dev.sshapp.sshapp.tests.defaults.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    func testTerminalViewsApplyHardwareKeyRepeatConfiguration() throws {
        let tabSource = try readSourceFile("SSHApp/Views/TerminalTab.swift")
        XCTAssertTrue(tabSource.contains("AppSettingsKey.terminalKeyRepeatEnabled"))
        XCTAssertTrue(tabSource.contains("AppSettingsKey.terminalKeyRepeatDelayMilliseconds"))
        XCTAssertTrue(tabSource.contains("AppSettingsKey.terminalKeyRepeatIntervalMilliseconds"))
        XCTAssertTrue(tabSource.contains("TerminalHardwareKeyRepeatConfiguration("))
        XCTAssertTrue(tabSource.contains("hardwareKeyRepeatConfiguration: hardwareKeyRepeatConfiguration"))

        for path in [
            "SSHApp/Views/GhosttyTerminalView.swift",
            "SSHApp/Views/TmuxPaneTerminal.swift",
        ] {
            let source = try readSourceFile(path)
            let makeBody = try extractMethodBody(from: source, methodName: "func makeUIView")
            let updateBody = try extractMethodBody(from: source, methodName: "func updateUIView")
            XCTAssertTrue(
                source.contains("var hardwareKeyRepeatConfiguration: TerminalHardwareKeyRepeatConfiguration"),
                "\(path) must accept the app's hardware key repeat configuration"
            )
            XCTAssertTrue(
                makeBody.contains("tv.hardwareKeyRepeatConfiguration = hardwareKeyRepeatConfiguration"),
                "\(path) must apply repeat config during view creation"
            )
            XCTAssertTrue(
                updateBody.contains("hardwareKeyRepeatConfiguration = hardwareKeyRepeatConfiguration"),
                "\(path) must apply repeat config during live SwiftUI updates"
            )
        }
    }

    // MARK: - Helpers

    private func extractMethodBody(from source: String, methodName: String) throws -> String {
        guard let methodRange = source.range(of: methodName) else {
            throw NSError(domain: "Test", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Method '\(methodName)' not found"])
        }

        let afterMethod = source[methodRange.upperBound...]
        guard let braceStart = afterMethod.firstIndex(of: "{") else {
            throw NSError(domain: "Test", code: 2,
                         userInfo: [NSLocalizedDescriptionKey: "No opening brace for '\(methodName)'"])
        }

        var depth = 0
        var braceEnd: String.Index?
        var index = braceStart

        while index < afterMethod.endIndex {
            let char = afterMethod[index]
            if char == "{" { depth += 1 }
            if char == "}" {
                depth -= 1
                if depth == 0 {
                    braceEnd = index
                    break
                }
            }
            index = afterMethod.index(after: index)
        }

        guard let end = braceEnd else {
            throw NSError(domain: "Test", code: 3,
                         userInfo: [NSLocalizedDescriptionKey: "No matching brace for '\(methodName)'"])
        }

        return String(afterMethod[braceStart...end])
    }
}
