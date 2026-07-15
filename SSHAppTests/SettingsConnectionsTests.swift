import XCTest

final class SettingsConnectionsTests: XCTestCase {
    func testGearMenuConnectionsDestinationReusesSavedConnectionsHomeView() throws {
        let mainSource = try readSourceFile("SSHApp/Views/MainView.swift")
        let topBarSource = try readSourceFile("SSHApp/Views/UnifiedTopBar.swift")

        XCTAssertTrue(
            topBarSource.contains("onSettings(.connections)"),
            "The gear menu must route Connections through settings destinations."
        )
        XCTAssertTrue(
            topBarSource.contains("Label(\"Connections\", systemImage: \"bookmark\")"),
            "The gear menu must expose a Connections row."
        )
        XCTAssertTrue(
            topBarSource.contains(".accessibilityIdentifier(\"settings.connections\")"),
            "The Connections settings row needs a stable UI automation identifier."
        )
        XCTAssertTrue(
            mainSource.contains("case connections, credentials, appLock, iCloudSync, tmux, keyboard, font, theme, licenses"),
            "SettingsDestination must include the Connections destination."
        )
        XCTAssertTrue(
            mainSource.contains("case .connections:"),
            "MainView must handle the Connections settings destination."
        )
        XCTAssertTrue(
            mainSource.contains("ConnectionsSettingsView("),
            "MainView must present the Connections settings wrapper."
        )

        let wrapperSource = try extractStructSource(named: "ConnectionsSettingsView", from: mainSource)
        XCTAssertTrue(
            wrapperSource.contains("NoTabsConnectionHomeView("),
            "Connections settings must reuse the same saved-connections view as the no-tabs home screen."
        )
        XCTAssertTrue(
            wrapperSource.contains("ConnectionSheet("),
            "Connections settings must keep the existing new/edit connection flow available."
        )
    }

    func testGearMenuExposesAppLockAndHierarchicalICloudSync() throws {
        let mainSource = try readSourceFile("SSHApp/Views/MainView.swift")
        let topBarSource = try readSourceFile("SSHApp/Views/UnifiedTopBar.swift")
        let syncSource = try readSourceFile("SSHApp/Views/ICloudSyncView.swift")
        let appLockSource = try readSourceFile("SSHApp/Views/AppLockView.swift")

        XCTAssertTrue(topBarSource.contains("onSettings(.appLock)"))
        XCTAssertTrue(topBarSource.contains("settings.appLock"))
        XCTAssertTrue(topBarSource.contains("onSettings(.iCloudSync)"))
        XCTAssertTrue(topBarSource.contains("settings.iCloudSync"))
        XCTAssertTrue(topBarSource.contains("iCloudSyncStatus.menuText"))
        XCTAssertTrue(topBarSource.contains("ConnectionsAndSettingsICloudSyncSettings.status()"))
        XCTAssertTrue(mainSource.contains("case .appLock:"))
        XCTAssertTrue(mainSource.contains("AppLockView(keyStore: keyStore)"))
        XCTAssertTrue(mainSource.contains("case .iCloudSync:"))
        XCTAssertTrue(mainSource.contains("ICloudSyncView(keyStore: keyStore)"))

        XCTAssertTrue(syncSource.contains("Sync Connections & Settings"))
        XCTAssertTrue(syncSource.contains("Sync Credentials"))
        XCTAssertTrue(syncSource.contains("!isConnectionsAndSettingsSyncEnabled"))
        XCTAssertTrue(syncSource.contains("Turn on Connections & Settings sync first."))
        XCTAssertTrue(syncSource.contains("CredentialICloudSyncService.enable"))
        XCTAssertTrue(syncSource.contains("ConnectionsAndSettingsICloudSyncService.enable"))
        XCTAssertTrue(syncSource.contains("Delete Data from iCloud"))
        XCTAssertTrue(syncSource.contains("existing iCloud copies are kept"))

        XCTAssertTrue(appLockSource.contains("Require Passcode on App Launch"))
        XCTAssertTrue(appLockSource.contains("appLock.iCloudSync"))
        XCTAssertFalse(appLockSource.contains("Require Face ID/Touch ID"))
    }

    func testGearMenuKeyboardDestinationExposesRepeatSettings() throws {
        let mainSource = try readSourceFile("SSHApp/Views/MainView.swift")
        let topBarSource = try readSourceFile("SSHApp/Views/UnifiedTopBar.swift")
        let settingsSource = try readSourceFile("SSHApp/Views/TerminalKeyboardSettingsView.swift")

        XCTAssertTrue(topBarSource.contains("onSettings(.keyboard)"))
        XCTAssertTrue(topBarSource.contains("Label(\"Keyboard\", systemImage: \"keyboard\")"))
        XCTAssertTrue(topBarSource.contains(".accessibilityIdentifier(\"settings.keyboard\")"))
        XCTAssertTrue(mainSource.contains("case .keyboard:"))
        XCTAssertTrue(mainSource.contains("TerminalKeyboardSettingsView()"))
        XCTAssertTrue(settingsSource.contains("AppSettingsKey.terminalKeyRepeatEnabled"))
        XCTAssertTrue(settingsSource.contains("AppSettingsKey.terminalKeyRepeatDelayMilliseconds"))
        XCTAssertTrue(settingsSource.contains("AppSettingsKey.terminalKeyRepeatIntervalMilliseconds"))
        XCTAssertTrue(settingsSource.contains("Slider(value: value, in: range, step: step)"))
        XCTAssertTrue(settingsSource.contains(".accessibilityIdentifier(\"terminalKeyboard.keyRepeat.enabled\")"))
        XCTAssertTrue(settingsSource.contains(".accessibilityIdentifier(identifier)"))
    }

    private func extractStructSource(named name: String, from source: String) throws -> String {
        let declaration = "struct \(name): View"
        let start = try XCTUnwrap(source.range(of: declaration)?.lowerBound)
        let openBrace = try XCTUnwrap(source[start...].firstIndex(of: "{"))

        var depth = 0
        var index = openBrace

        while index < source.endIndex {
            switch source[index] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(source[start...index])
                }
            default:
                break
            }

            index = source.index(after: index)
        }

        XCTFail("Could not find the end of \(declaration)")
        return ""
    }
}
