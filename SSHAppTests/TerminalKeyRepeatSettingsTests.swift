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
}
