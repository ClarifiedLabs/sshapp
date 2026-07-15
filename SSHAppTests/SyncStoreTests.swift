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
            cloudKeyPrefix: cloudPrefix,
            isSyncEnabled: { true }
        )
        phoneStore.syncLocalChangesToCloud()

        let padDefaults = try isolatedDefaults().defaults
        let padStore = AppSettingsSyncStore(
            ubiquitous: ubiquitous,
            defaults: padDefaults,
            deviceClass: .pad,
            cloudKeyPrefix: cloudPrefix,
            isSyncEnabled: { true }
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
            cloudKeyPrefix: cloudPrefix,
            isSyncEnabled: { true }
        ).reconcileCloudAndLocalValues()
        XCTAssertEqual(
            reloadedPhoneDefaults.terminalFontSize(AppSettingsKey.terminalFontSize, default: 0),
            9.0
        )
    }

    @MainActor
    func testTerminalKeyRepeatSettingsSyncByDeviceClass() throws {
        let ubiquitous = NSUbiquitousKeyValueStore.default
        let cloudPrefix = "dev.sshapp.sshapp.tests.settings.\(UUID().uuidString)."
        defer {
            AppSettingsSyncStore.clearSyncedValues(ubiquitous: ubiquitous, cloudKeyPrefix: cloudPrefix)
            ubiquitous.synchronize()
        }

        let phoneDefaults = try isolatedDefaults().defaults
        phoneDefaults.set(false, forKey: AppSettingsKey.terminalKeyRepeatEnabled)
        phoneDefaults.set(300.0, forKey: AppSettingsKey.terminalKeyRepeatDelayMilliseconds)
        phoneDefaults.set(35.0, forKey: AppSettingsKey.terminalKeyRepeatIntervalMilliseconds)
        AppSettingsSyncStore(
            ubiquitous: ubiquitous,
            defaults: phoneDefaults,
            deviceClass: .phone,
            cloudKeyPrefix: cloudPrefix,
            isSyncEnabled: { true }
        ).syncLocalChangesToCloud()

        let padDefaults = try isolatedDefaults().defaults
        let padStore = AppSettingsSyncStore(
            ubiquitous: ubiquitous,
            defaults: padDefaults,
            deviceClass: .pad,
            cloudKeyPrefix: cloudPrefix,
            isSyncEnabled: { true }
        )
        padStore.reconcileCloudAndLocalValues()
        XCTAssertNil(padDefaults.object(forKey: AppSettingsKey.terminalKeyRepeatEnabled))
        XCTAssertNil(padDefaults.object(forKey: AppSettingsKey.terminalKeyRepeatDelayMilliseconds))
        XCTAssertNil(padDefaults.object(forKey: AppSettingsKey.terminalKeyRepeatIntervalMilliseconds))

        padDefaults.set(true, forKey: AppSettingsKey.terminalKeyRepeatEnabled)
        padDefaults.set(700.0, forKey: AppSettingsKey.terminalKeyRepeatDelayMilliseconds)
        padDefaults.set(80.0, forKey: AppSettingsKey.terminalKeyRepeatIntervalMilliseconds)
        padStore.syncLocalChangesToCloud()

        let reloadedPhoneDefaults = try isolatedDefaults().defaults
        AppSettingsSyncStore(
            ubiquitous: ubiquitous,
            defaults: reloadedPhoneDefaults,
            deviceClass: .phone,
            cloudKeyPrefix: cloudPrefix,
            isSyncEnabled: { true }
        ).reconcileCloudAndLocalValues()
        XCTAssertFalse(TerminalKeyRepeatSettings.isEnabled(defaults: reloadedPhoneDefaults))
        XCTAssertEqual(TerminalKeyRepeatSettings.delayMilliseconds(defaults: reloadedPhoneDefaults), 300.0)
        XCTAssertEqual(TerminalKeyRepeatSettings.intervalMilliseconds(defaults: reloadedPhoneDefaults), 35.0)
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
            cloudKeyPrefix: cloudPrefix,
            isSyncEnabled: { true }
        ).syncLocalChangesToCloud()

        let reloadedDefaults = try isolatedDefaults().defaults
        AppSettingsSyncStore(
            ubiquitous: ubiquitous,
            defaults: reloadedDefaults,
            deviceClass: .phone,
            cloudKeyPrefix: cloudPrefix,
            isSyncEnabled: { true }
        ).reconcileCloudAndLocalValues()

        XCTAssertEqual(reloadedDefaults.string(forKey: AppSettingsKey.appearanceMode), AppearanceMode.dark.rawValue)
        XCTAssertEqual(reloadedDefaults.string(forKey: AppSettingsKey.terminalFontFamily), "JetBrains Mono")
        XCTAssertFalse(reloadedDefaults.bool(forKey: AppSettingsKey.showKeyboardBar))
        XCTAssertEqual(reloadedDefaults.integer(forKey: AppSettingsKey.tmuxScrollbackLines), 8000)
        XCTAssertFalse(
            CredentialICloudSyncSettings.isConfiguredEnabled(defaults: reloadedDefaults),
            "The credential sync choice must remain local to each device"
        )
    }

    @MainActor
    func testCredentialProtectionRequiresCredentialSyncWhileAppLockFollowsSettingsSync() throws {
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
            cloudKeyPrefix: cloudPrefix,
            isSyncEnabled: { true }
        ).syncLocalChangesToCloud()

        let syncOffReloadedDefaults = try isolatedDefaults().defaults
        AppSettingsSyncStore(
            ubiquitous: ubiquitous,
            defaults: syncOffReloadedDefaults,
            deviceClass: .phone,
            cloudKeyPrefix: cloudPrefix,
            isSyncEnabled: { true }
        ).reconcileCloudAndLocalValues()

        XCTAssertNil(syncOffReloadedDefaults.object(forKey: AppSettingsKey.credentialBiometricProtectionEnabled))
        XCTAssertNil(syncOffReloadedDefaults.object(forKey: AppSettingsKey.credentialPasscodeFallbackEnabled))
        XCTAssertTrue(AppLaunchPasscodeSettings.isEnabled(defaults: syncOffReloadedDefaults))
        XCTAssertEqual(AppLaunchPasscodeSettings.gracePeriodSeconds(defaults: syncOffReloadedDefaults), 60)

        CredentialICloudSyncSettings.setConfiguredEnabled(true, defaults: sourceDefaults)
        AppSettingsSyncStore(
            ubiquitous: ubiquitous,
            defaults: sourceDefaults,
            deviceClass: .phone,
            cloudKeyPrefix: cloudPrefix,
            isSyncEnabled: { true }
        ).syncLocalChangesToCloud()

        let syncOnReloadedDefaults = try isolatedDefaults().defaults
        CredentialICloudSyncSettings.setConfiguredEnabled(true, defaults: syncOnReloadedDefaults)
        AppSettingsSyncStore(
            ubiquitous: ubiquitous,
            defaults: syncOnReloadedDefaults,
            deviceClass: .phone,
            cloudKeyPrefix: cloudPrefix,
            isSyncEnabled: { true }
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

        let connectionId = UUID()
        let keyId = UUID()
        let keyTypes: [UUID: SSHKey.KeyType] = [keyId: .ed25519]

        let firstContainer = try ModelContainer(
            for: SavedConnection.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let firstSync = ConnectionSyncStore(
            ubiquitous: ubiquitous,
            keyPrefix: keyPrefix,
            keyTypeResolver: { keyTypes[$0] },
            isSyncEnabled: { true }
        )
        let firstStore = ConnectionStore(syncStore: firstSync)
        firstStore.setModelContext(firstContainer.mainContext)

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
            autoReconnectOnBackgroundDisconnect: true,
            autoRunCommandEnabled: true,
            autoRunCommand: "echo synced-startup",
            tmuxBackfillOverride: false,
            tmuxPauseModeOverride: true
        )
        firstStore.save(connection)

        let secondContainer = try ModelContainer(
            for: SavedConnection.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let secondSync = ConnectionSyncStore(
            ubiquitous: ubiquitous,
            keyPrefix: keyPrefix,
            keyTypeResolver: { keyTypes[$0] },
            isSyncEnabled: { true }
        )
        secondSync.setModelContext(secondContainer.mainContext)

        let imported = try XCTUnwrap(fetchConnections(from: secondContainer.mainContext).first)
        XCTAssertEqual(imported.id, connectionId)
        XCTAssertEqual(imported.host, "example.com")
        XCTAssertEqual(imported.port, 2222)
        XCTAssertEqual(imported.username, "dev")
        XCTAssertEqual(imported.sshKeyId, keyId)
        XCTAssertTrue(imported.autoReconnectOnBackgroundDisconnect)
        XCTAssertTrue(imported.autoRunCommandEnabled)
        XCTAssertEqual(imported.autoRunCommand, "echo synced-startup")
        XCTAssertFalse(imported.tmuxBackfillOverride ?? true)
        XCTAssertTrue(imported.tmuxPauseModeOverride ?? false)

        try KeychainService.savePassword("secret", forConnectionId: connectionId)
        firstStore.delete(connection)
        secondSync.synchronize()

        XCTAssertTrue(fetchConnections(from: secondContainer.mainContext).isEmpty)
        XCTAssertNil(KeychainService.loadPassword(forConnectionId: connectionId))
    }

    @MainActor
    func testSecureEnclaveSelectionStaysLocalWhenEd25519SelectionSyncs() throws {
        let ubiquitous = NSUbiquitousKeyValueStore.default
        let keyPrefix = "dev.sshapp.sshapp.tests.connections.\(UUID().uuidString)"
        defer {
            ConnectionSyncStore.clearSyncedValues(ubiquitous: ubiquitous, keyPrefix: keyPrefix)
            ubiquitous.synchronize()
        }

        let connectionId = UUID()
        let secureKeyId = UUID()
        let ed25519KeyId = UUID()
        let firstTypes: [UUID: SSHKey.KeyType] = [
            secureKeyId: .secureEnclaveECDSA,
            ed25519KeyId: .ed25519
        ]
        let syncableTypes: [UUID: SSHKey.KeyType] = [ed25519KeyId: .ed25519]

        let firstContainer = try makeConnectionContainer()
        let firstSync = ConnectionSyncStore(
            ubiquitous: ubiquitous,
            keyPrefix: keyPrefix,
            keyTypeResolver: { firstTypes[$0] },
            isSyncEnabled: { true }
        )
        firstSync.setModelContext(firstContainer.mainContext)

        let firstConnection = SavedConnection(
            id: connectionId,
            host: "example.com",
            port: 22,
            username: "dev",
            sshKeyId: secureKeyId,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        firstContainer.mainContext.insert(firstConnection)
        try firstContainer.mainContext.save()
        firstSync.save(firstConnection)

        let secondContainer = try makeConnectionContainer()
        let secondSync = ConnectionSyncStore(
            ubiquitous: ubiquitous,
            keyPrefix: keyPrefix,
            keyTypeResolver: { syncableTypes[$0] },
            isSyncEnabled: { true }
        )
        secondSync.setModelContext(secondContainer.mainContext)

        let secondConnection = try XCTUnwrap(fetchConnections(from: secondContainer.mainContext).first)
        XCTAssertNil(secondConnection.sshKeyId)

        secondConnection.sshKeyId = ed25519KeyId
        secondConnection.port = 2222
        secondConnection.updatedAt = Date(timeIntervalSince1970: 300)
        try secondContainer.mainContext.save()
        secondSync.save(secondConnection)

        firstSync.synchronize()

        XCTAssertEqual(firstConnection.sshKeyId, secureKeyId)
        XCTAssertEqual(firstConnection.port, 2222)

        let thirdContainer = try makeConnectionContainer()
        let thirdSync = ConnectionSyncStore(
            ubiquitous: ubiquitous,
            keyPrefix: keyPrefix,
            keyTypeResolver: { syncableTypes[$0] },
            isSyncEnabled: { true }
        )
        thirdSync.setModelContext(thirdContainer.mainContext)

        let thirdConnection = try XCTUnwrap(fetchConnections(from: thirdContainer.mainContext).first)
        XCTAssertEqual(thirdConnection.sshKeyId, ed25519KeyId)
        XCTAssertEqual(thirdConnection.port, 2222)
    }

    @MainActor
    func testSecureEnclaveSelectionDoesNotOverwriteExistingSyncedEd25519Selection() throws {
        let ubiquitous = NSUbiquitousKeyValueStore.default
        let keyPrefix = "dev.sshapp.sshapp.tests.connections.\(UUID().uuidString)"
        defer {
            ConnectionSyncStore.clearSyncedValues(ubiquitous: ubiquitous, keyPrefix: keyPrefix)
            ubiquitous.synchronize()
        }

        let connectionId = UUID()
        let secureKeyId = UUID()
        let ed25519KeyId = UUID()
        let firstTypes: [UUID: SSHKey.KeyType] = [
            secureKeyId: .secureEnclaveECDSA,
            ed25519KeyId: .ed25519
        ]
        let syncableTypes: [UUID: SSHKey.KeyType] = [ed25519KeyId: .ed25519]

        let sourceContainer = try makeConnectionContainer()
        let sourceSync = ConnectionSyncStore(
            ubiquitous: ubiquitous,
            keyPrefix: keyPrefix,
            keyTypeResolver: { syncableTypes[$0] },
            isSyncEnabled: { true }
        )
        sourceSync.setModelContext(sourceContainer.mainContext)

        let sourceConnection = SavedConnection(
            id: connectionId,
            host: "example.com",
            port: 22,
            username: "dev",
            sshKeyId: ed25519KeyId,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        sourceContainer.mainContext.insert(sourceConnection)
        try sourceContainer.mainContext.save()
        sourceSync.save(sourceConnection)

        let firstContainer = try makeConnectionContainer()
        let firstSync = ConnectionSyncStore(
            ubiquitous: ubiquitous,
            keyPrefix: keyPrefix,
            keyTypeResolver: { firstTypes[$0] },
            isSyncEnabled: { true }
        )
        firstSync.setModelContext(firstContainer.mainContext)

        let firstConnection = try XCTUnwrap(fetchConnections(from: firstContainer.mainContext).first)
        XCTAssertEqual(firstConnection.sshKeyId, ed25519KeyId)

        firstConnection.sshKeyId = secureKeyId
        firstConnection.host = "renamed.example.com"
        firstConnection.updatedAt = Date(timeIntervalSince1970: 300)
        try firstContainer.mainContext.save()
        firstSync.save(firstConnection)

        let thirdContainer = try makeConnectionContainer()
        let thirdSync = ConnectionSyncStore(
            ubiquitous: ubiquitous,
            keyPrefix: keyPrefix,
            keyTypeResolver: { syncableTypes[$0] },
            isSyncEnabled: { true }
        )
        thirdSync.setModelContext(thirdContainer.mainContext)

        let thirdConnection = try XCTUnwrap(fetchConnections(from: thirdContainer.mainContext).first)
        XCTAssertEqual(thirdConnection.host, "renamed.example.com")
        XCTAssertEqual(thirdConnection.sshKeyId, ed25519KeyId)
    }

    @MainActor
    func testSyncStoresDoNotPublishWhenConnectionsAndSettingsSyncIsOff() throws {
        let ubiquitous = NSUbiquitousKeyValueStore.default
        let identifier = UUID().uuidString
        let settingsPrefix = "dev.sshapp.sshapp.tests.disabled.settings.\(identifier)."
        let connectionPrefix = "dev.sshapp.sshapp.tests.disabled.connections.\(identifier)"
        let knownHostsKey = "dev.sshapp.sshapp.tests.disabled.knownHosts.\(identifier)"
        defer {
            AppSettingsSyncStore.clearSyncedValues(
                ubiquitous: ubiquitous,
                cloudKeyPrefix: settingsPrefix
            )
            ConnectionSyncStore.clearSyncedValues(
                ubiquitous: ubiquitous,
                keyPrefix: connectionPrefix
            )
            ubiquitous.removeObject(forKey: knownHostsKey)
            ubiquitous.synchronize()
        }

        let defaults = try isolatedDefaults().defaults
        defaults.set(AppearanceMode.dark.rawValue, forKey: AppSettingsKey.appearanceMode)
        AppSettingsSyncStore(
            ubiquitous: ubiquitous,
            defaults: defaults,
            deviceClass: .phone,
            cloudKeyPrefix: settingsPrefix,
            isSyncEnabled: { false }
        ).syncLocalChangesToCloud()

        let container = try makeConnectionContainer()
        let connectionSync = ConnectionSyncStore(
            ubiquitous: ubiquitous,
            keyPrefix: connectionPrefix,
            isSyncEnabled: { false }
        )
        connectionSync.setModelContext(container.mainContext)
        let connection = SavedConnection(host: "private.example.com")
        container.mainContext.insert(connection)
        connectionSync.save(connection)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sshapp-disabled-sync-\(identifier)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let knownHostsFile = directory.appendingPathComponent("known_hosts")
        try "private.example.com ssh-ed25519 AAAAprivate\n".write(
            to: knownHostsFile,
            atomically: true,
            encoding: .utf8
        )
        KnownHostsSyncStore(
            ubiquitous: ubiquitous,
            cloudKey: knownHostsKey,
            isSyncEnabled: { false }
        ).syncFileWithCloud(fileURL: knownHostsFile)

        XCTAssertFalse(
            ubiquitous.dictionaryRepresentation.keys.contains { $0.hasPrefix(settingsPrefix) }
        )
        XCTAssertFalse(
            ubiquitous.dictionaryRepresentation.keys.contains { $0.hasPrefix(connectionPrefix) }
        )
        XCTAssertNil(ubiquitous.object(forKey: knownHostsKey))
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

        let firstStore = KnownHostsSyncStore(
            ubiquitous: ubiquitous,
            cloudKey: cloudKey,
            isSyncEnabled: { true }
        )
        firstStore.syncFileWithCloud(fileURL: firstFile)

        let secondStore = KnownHostsSyncStore(
            ubiquitous: ubiquitous,
            cloudKey: cloudKey,
            isSyncEnabled: { true }
        )
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

    private func makeConnectionContainer() throws -> ModelContainer {
        try ModelContainer(
            for: SavedConnection.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private func isolatedDefaults() throws -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "dev.sshapp.sshapp.tests.defaults.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
