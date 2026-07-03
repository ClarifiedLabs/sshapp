import XCTest
import SwiftData
@testable import SSHApp

final class SyncStoreTests: XCTestCase {
    @MainActor
    func testFontSizeSyncsByDeviceClass() throws {
        let ubiquitous = NSUbiquitousKeyValueStore.default
        let cloudPrefix = "dev.sshapp.sshapp.tests.settings.\(UUID().uuidString)."
        defer {
            AppSettingsSyncStore.clearSyncedValues(ubiquitous: ubiquitous, cloudKeyPrefix: cloudPrefix)
            ubiquitous.synchronize()
        }

        let phoneDefaults = try isolatedDefaults().defaults
        phoneDefaults.set(9.0, forKey: AppSettingsKey.terminalFontSize)
        let phoneStore = AppSettingsSyncStore(
            ubiquitous: ubiquitous,
            defaults: phoneDefaults,
            deviceClass: .phone,
            cloudKeyPrefix: cloudPrefix
        )
        phoneStore.syncLocalChangesToCloud()

        let padDefaults = try isolatedDefaults().defaults
        let padStore = AppSettingsSyncStore(
            ubiquitous: ubiquitous,
            defaults: padDefaults,
            deviceClass: .pad,
            cloudKeyPrefix: cloudPrefix
        )
        padStore.reconcileCloudAndLocalValues()
        XCTAssertNil(padDefaults.object(forKey: AppSettingsKey.terminalFontSize))

        padDefaults.set(13.0, forKey: AppSettingsKey.terminalFontSize)
        padStore.syncLocalChangesToCloud()

        let reloadedPhoneDefaults = try isolatedDefaults().defaults
        AppSettingsSyncStore(
            ubiquitous: ubiquitous,
            defaults: reloadedPhoneDefaults,
            deviceClass: .phone,
            cloudKeyPrefix: cloudPrefix
        ).reconcileCloudAndLocalValues()
        XCTAssertEqual(
            reloadedPhoneDefaults.terminalFontSize(AppSettingsKey.terminalFontSize, default: 0),
            9.0
        )
    }

    @MainActor
    func testAppSettingsRoundTripThroughCloudStore() throws {
        let ubiquitous = NSUbiquitousKeyValueStore.default
        let cloudPrefix = "dev.sshapp.sshapp.tests.settings.\(UUID().uuidString)."
        defer {
            AppSettingsSyncStore.clearSyncedValues(ubiquitous: ubiquitous, cloudKeyPrefix: cloudPrefix)
            ubiquitous.synchronize()
        }

        let sourceDefaults = try isolatedDefaults().defaults
        sourceDefaults.set(AppearanceMode.dark.rawValue, forKey: AppSettingsKey.appearanceMode)
        sourceDefaults.set("JetBrains Mono", forKey: AppSettingsKey.terminalFontFamily)
        sourceDefaults.set(false, forKey: AppSettingsKey.showKeyboardBar)
        sourceDefaults.set(8000, forKey: AppSettingsKey.tmuxScrollbackLines)
        CredentialICloudSyncSettings.setConfiguredEnabled(true, defaults: sourceDefaults)

        AppSettingsSyncStore(
            ubiquitous: ubiquitous,
            defaults: sourceDefaults,
            deviceClass: .phone,
            cloudKeyPrefix: cloudPrefix
        ).syncLocalChangesToCloud()

        let reloadedDefaults = try isolatedDefaults().defaults
        AppSettingsSyncStore(
            ubiquitous: ubiquitous,
            defaults: reloadedDefaults,
            deviceClass: .phone,
            cloudKeyPrefix: cloudPrefix
        ).reconcileCloudAndLocalValues()

        XCTAssertEqual(reloadedDefaults.string(forKey: AppSettingsKey.appearanceMode), AppearanceMode.dark.rawValue)
        XCTAssertEqual(reloadedDefaults.string(forKey: AppSettingsKey.terminalFontFamily), "JetBrains Mono")
        XCTAssertFalse(reloadedDefaults.bool(forKey: AppSettingsKey.showKeyboardBar))
        XCTAssertEqual(reloadedDefaults.integer(forKey: AppSettingsKey.tmuxScrollbackLines), 8000)
        XCTAssertTrue(CredentialICloudSyncSettings.isConfiguredEnabled(defaults: reloadedDefaults))
    }

    @MainActor
    func testCredentialSettingsSyncOnlyWhenCredentialICloudSyncIsEnabled() throws {
        let ubiquitous = NSUbiquitousKeyValueStore.default
        let cloudPrefix = "dev.sshapp.sshapp.tests.settings.\(UUID().uuidString)."
        defer {
            AppSettingsSyncStore.clearSyncedValues(ubiquitous: ubiquitous, cloudKeyPrefix: cloudPrefix)
            ubiquitous.synchronize()
        }

        let sourceDefaults = try isolatedDefaults().defaults
        CredentialProtectionSettings.setEnabled(true, defaults: sourceDefaults)
        CredentialProtectionSettings.setPasscodeFallbackEnabled(true, defaults: sourceDefaults)
        AppLaunchPasscodeSettings.setEnabled(true, defaults: sourceDefaults)
        AppLaunchPasscodeSettings.setGracePeriodSeconds(60, defaults: sourceDefaults)

        AppSettingsSyncStore(
            ubiquitous: ubiquitous,
            defaults: sourceDefaults,
            deviceClass: .phone,
            cloudKeyPrefix: cloudPrefix
        ).syncLocalChangesToCloud()

        let syncOffReloadedDefaults = try isolatedDefaults().defaults
        AppSettingsSyncStore(
            ubiquitous: ubiquitous,
            defaults: syncOffReloadedDefaults,
            deviceClass: .phone,
            cloudKeyPrefix: cloudPrefix
        ).reconcileCloudAndLocalValues()

        XCTAssertNil(syncOffReloadedDefaults.object(forKey: AppSettingsKey.credentialBiometricProtectionEnabled))
        XCTAssertNil(syncOffReloadedDefaults.object(forKey: AppSettingsKey.credentialPasscodeFallbackEnabled))
        XCTAssertNil(syncOffReloadedDefaults.object(forKey: AppSettingsKey.appLaunchPasscodeRequired))
        XCTAssertNil(syncOffReloadedDefaults.object(forKey: AppSettingsKey.appLaunchPasscodeGracePeriodSeconds))

        CredentialICloudSyncSettings.setConfiguredEnabled(true, defaults: sourceDefaults)
        AppSettingsSyncStore(
            ubiquitous: ubiquitous,
            defaults: sourceDefaults,
            deviceClass: .phone,
            cloudKeyPrefix: cloudPrefix
        ).syncLocalChangesToCloud()

        let syncOnReloadedDefaults = try isolatedDefaults().defaults
        AppSettingsSyncStore(
            ubiquitous: ubiquitous,
            defaults: syncOnReloadedDefaults,
            deviceClass: .phone,
            cloudKeyPrefix: cloudPrefix
        ).reconcileCloudAndLocalValues()

        XCTAssertTrue(CredentialICloudSyncSettings.isConfiguredEnabled(defaults: syncOnReloadedDefaults))
        XCTAssertTrue(CredentialProtectionSettings.isEnabled(defaults: syncOnReloadedDefaults, availability: .available))
        XCTAssertTrue(CredentialProtectionSettings.isPasscodeFallbackEnabled(defaults: syncOnReloadedDefaults))
        XCTAssertTrue(AppLaunchPasscodeSettings.isEnabled(defaults: syncOnReloadedDefaults))
        XCTAssertEqual(AppLaunchPasscodeSettings.gracePeriodSeconds(defaults: syncOnReloadedDefaults), 60)
    }

    @MainActor
    func testConnectionSyncRoundTripsAndDeletesByUUID() throws {
        let ubiquitous = NSUbiquitousKeyValueStore.default
        let keyPrefix = "dev.sshapp.sshapp.tests.connections.\(UUID().uuidString)"
        defer {
            ConnectionSyncStore.clearSyncedValues(ubiquitous: ubiquitous, keyPrefix: keyPrefix)
            ubiquitous.synchronize()
        }

        let firstContainer = try ModelContainer(
            for: SavedConnection.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let firstSync = ConnectionSyncStore(ubiquitous: ubiquitous, keyPrefix: keyPrefix)
        let firstStore = ConnectionStore(syncStore: firstSync)
        firstStore.setModelContext(firstContainer.mainContext)

        let connectionId = UUID()
        let keyId = UUID()
        let createdAt = Date(timeIntervalSince1970: 100)
        let connection = SavedConnection(
            id: connectionId,
            host: "example.com",
            port: 2222,
            username: "dev",
            sshKeyId: keyId,
            createdAt: createdAt,
            updatedAt: createdAt,
            neverAskSaveUsername: true,
            neverAskSavePassword: true,
            tmuxBackfillOverride: false,
            tmuxPauseModeOverride: true
        )
        firstStore.save(connection)

        let secondContainer = try ModelContainer(
            for: SavedConnection.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let secondSync = ConnectionSyncStore(ubiquitous: ubiquitous, keyPrefix: keyPrefix)
        secondSync.setModelContext(secondContainer.mainContext)

        let imported = try XCTUnwrap(fetchConnections(from: secondContainer.mainContext).first)
        XCTAssertEqual(imported.id, connectionId)
        XCTAssertEqual(imported.host, "example.com")
        XCTAssertEqual(imported.port, 2222)
        XCTAssertEqual(imported.username, "dev")
        XCTAssertEqual(imported.sshKeyId, keyId)
        XCTAssertFalse(imported.tmuxBackfillOverride ?? true)
        XCTAssertTrue(imported.tmuxPauseModeOverride ?? false)

        try KeychainService.savePassword("secret", forConnectionId: connectionId)
        firstStore.delete(connection)
        secondSync.synchronize()

        XCTAssertTrue(fetchConnections(from: secondContainer.mainContext).isEmpty)
        XCTAssertNil(KeychainService.loadPassword(forConnectionId: connectionId))
    }

    func testKnownHostsSyncMergesAndRoundTripsThroughCloudStore() throws {
        let ubiquitous = NSUbiquitousKeyValueStore.default
        let cloudKey = "dev.sshapp.sshapp.tests.knownHosts.\(UUID().uuidString)"
        defer {
            ubiquitous.removeObject(forKey: cloudKey)
            ubiquitous.synchronize()
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sshapp-known-hosts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstFile = directory.appendingPathComponent("first_known_hosts")
        let secondFile = directory.appendingPathComponent("second_known_hosts")
        try "example.com ssh-ed25519 AAAAexample\n".write(to: firstFile, atomically: true, encoding: .utf8)

        let firstStore = KnownHostsSyncStore(ubiquitous: ubiquitous, cloudKey: cloudKey)
        firstStore.syncFileWithCloud(fileURL: firstFile)

        let secondStore = KnownHostsSyncStore(ubiquitous: ubiquitous, cloudKey: cloudKey)
        secondStore.syncFileWithCloud(fileURL: secondFile)
        XCTAssertEqual(
            try String(contentsOf: secondFile, encoding: .utf8),
            "example.com ssh-ed25519 AAAAexample\n"
        )

        try "other.example.com ssh-ed25519 AAAAother\n".write(to: secondFile, atomically: true, encoding: .utf8)
        secondStore.syncFileWithCloud(fileURL: secondFile)
        firstStore.syncFileWithCloud(fileURL: firstFile)

        let merged = try String(contentsOf: firstFile, encoding: .utf8)
        XCTAssertTrue(merged.contains("example.com ssh-ed25519 AAAAexample"))
        XCTAssertTrue(merged.contains("other.example.com ssh-ed25519 AAAAother"))
    }

    private func fetchConnections(from context: ModelContext) -> [SavedConnection] {
        (try? context.fetch(FetchDescriptor<SavedConnection>())) ?? []
    }

    private func isolatedDefaults() throws -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "dev.sshapp.sshapp.tests.defaults.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
