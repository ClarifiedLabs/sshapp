import XCTest
import CryptoKit
import SwiftData
import LocalAuthentication
import Security
@testable import SSHApp

/// Regression tests for the iCloud Keychain credential storage work:
/// `KeychainService` password API and `KeyStore` metadata round-trip via
/// `NSUbiquitousKeyValueStore`.
///
/// The iOS Simulator does not exercise transport between devices, but it does
/// enforce local `kSecAttrSynchronizable` query and deletion scopes. These tests
/// cover those scope transitions and metadata behavior locally; cross-device
/// propagation must still be validated on hardware.
final class KeychainCredentialTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: AppSettingsKey.connectionsAndSettingsICloudSyncEnabled)
        UserDefaults.standard.removeObject(forKey: AppSettingsKey.credentialICloudSyncEnabled)
    }

    // MARK: - Password API

    func testSaveLoadDeletePasswordRoundTrip() throws {
        let connectionId = UUID()
        let password = "correct horse battery staple"

        // Clean slate.
        KeychainService.deletePassword(forConnectionId: connectionId)
        XCTAssertNil(KeychainService.loadPassword(forConnectionId: connectionId))
        XCTAssertFalse(KeychainService.hasPassword(forConnectionId: connectionId))

        try KeychainService.savePassword(password, forConnectionId: connectionId)
        XCTAssertTrue(KeychainService.hasPassword(forConnectionId: connectionId))
        XCTAssertEqual(KeychainService.loadPassword(forConnectionId: connectionId), password)

        KeychainService.deletePassword(forConnectionId: connectionId)
        XCTAssertNil(KeychainService.loadPassword(forConnectionId: connectionId))
        XCTAssertFalse(KeychainService.hasPassword(forConnectionId: connectionId))
    }

    func testSavePasswordOverwritesPreviousValue() throws {
        let connectionId = UUID()
        KeychainService.deletePassword(forConnectionId: connectionId)

        try KeychainService.savePassword("old", forConnectionId: connectionId)
        try KeychainService.savePassword("new", forConnectionId: connectionId)
        XCTAssertEqual(KeychainService.loadPassword(forConnectionId: connectionId), "new")

        KeychainService.deletePassword(forConnectionId: connectionId)
    }

    func testPasswordsAreNamespacedPerConnection() throws {
        let a = UUID()
        let b = UUID()
        KeychainService.deletePassword(forConnectionId: a)
        KeychainService.deletePassword(forConnectionId: b)

        try KeychainService.savePassword("alpha", forConnectionId: a)
        try KeychainService.savePassword("beta", forConnectionId: b)

        XCTAssertEqual(KeychainService.loadPassword(forConnectionId: a), "alpha")
        XCTAssertEqual(KeychainService.loadPassword(forConnectionId: b), "beta")

        KeychainService.deletePassword(forConnectionId: a)
        KeychainService.deletePassword(forConnectionId: b)
        XCTAssertNil(KeychainService.loadPassword(forConnectionId: a))
        XCTAssertNil(KeychainService.loadPassword(forConnectionId: b))
    }

    func testDeletePasswordIsIdempotent() {
        let connectionId = UUID()
        KeychainService.deletePassword(forConnectionId: connectionId)
        // Deleting again must not throw / crash.
        KeychainService.deletePassword(forConnectionId: connectionId)
        XCTAssertNil(KeychainService.loadPassword(forConnectionId: connectionId))
    }

    @MainActor
    func testDeletingConnectionDeletesScopedPassword() throws {
        let connection = SavedConnection(
            host: "example.com",
            username: "test"
        )
        let container = try ModelContainer(
            for: SavedConnection.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let store = ConnectionStore()
        store.setModelContext(container.mainContext)
        store.save(connection)

        try KeychainService.savePassword("secret", forConnectionId: connection.id)
        XCTAssertEqual(KeychainService.loadPassword(forConnectionId: connection.id), "secret")

        store.delete(connection)

        XCTAssertNil(KeychainService.loadPassword(forConnectionId: connection.id))
    }

    // MARK: - Credential protection settings

    func testCredentialProtectionDefaultFollowsBiometricAvailability() throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(
            CredentialProtectionSettings.isEnabled(defaults: defaults, availability: .available)
        )
        XCTAssertTrue(
            CredentialProtectionSettings.isEnabled(defaults: defaults, availability: .lockedOut)
        )
        XCTAssertFalse(
            CredentialProtectionSettings.isEnabled(defaults: defaults, availability: .notEnrolled)
        )
        XCTAssertFalse(
            CredentialProtectionSettings.isEnabled(defaults: defaults, availability: .notAvailable)
        )
    }

    func testBiometricAvailabilityReportsUnavailableWhenPlatformHasNoBiometry() {
        let error = NSError(
            domain: LAError.errorDomain,
            code: LAError.Code.biometryNotEnrolled.rawValue
        )

        XCTAssertEqual(
            BiometricCredentialAuthorizer.biometricAvailability(
                canEvaluatePolicy: false,
                biometryType: .none,
                error: error
            ),
            .notAvailable
        )
        XCTAssertEqual(
            BiometricCredentialAuthorizer.biometricAvailability(
                canEvaluatePolicy: false,
                biometryType: .faceID,
                error: error
            ),
            .notEnrolled
        )
        XCTAssertEqual(CredentialBiometricAvailability.notAvailable.statusText, "Unavailable")
    }

    func testCredentialProtectionExplicitPreferenceOverridesDynamicDefault() throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        CredentialProtectionSettings.setEnabled(false, defaults: defaults)
        XCTAssertFalse(
            CredentialProtectionSettings.isEnabled(defaults: defaults, availability: .available)
        )

        CredentialProtectionSettings.setEnabled(true, defaults: defaults)
        XCTAssertTrue(
            CredentialProtectionSettings.isEnabled(defaults: defaults, availability: .notEnrolled)
        )
    }

    func testCredentialPasscodeFallbackDefaultsOffAndPersists() throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(CredentialProtectionSettings.isPasscodeFallbackEnabled(defaults: defaults))

        CredentialProtectionSettings.setPasscodeFallbackEnabled(true, defaults: defaults)
        XCTAssertTrue(CredentialProtectionSettings.isPasscodeFallbackEnabled(defaults: defaults))

        CredentialProtectionSettings.setPasscodeFallbackEnabled(false, defaults: defaults)
        XCTAssertFalse(CredentialProtectionSettings.isPasscodeFallbackEnabled(defaults: defaults))
    }

    func testAppLaunchPasscodeSettingsDefaultToOffAndImmediate() throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(AppLaunchPasscodeSettings.isEnabled(defaults: defaults))
        XCTAssertEqual(AppLaunchPasscodeSettings.gracePeriodSeconds(defaults: defaults), 0)
        XCTAssertEqual(AppLaunchPasscodeSettings.gracePeriodDisplayText(0), "Immediately")
        XCTAssertEqual(AppLaunchPasscodeSettings.gracePeriodDisplayText(15), "15s")
        XCTAssertEqual(AppLaunchPasscodeSettings.gracePeriodDisplayText(60), "1m")

        AppLaunchPasscodeSettings.setEnabled(true, defaults: defaults)
        XCTAssertTrue(AppLaunchPasscodeSettings.isEnabled(defaults: defaults))

        AppLaunchPasscodeSettings.setGracePeriodSeconds(999, defaults: defaults)
        XCTAssertEqual(
            AppLaunchPasscodeSettings.gracePeriodSeconds(defaults: defaults),
            AppLaunchPasscodeSettings.gracePeriodRange.upperBound
        )

        AppLaunchPasscodeSettings.setGracePeriodSeconds(-1, defaults: defaults)
        XCTAssertEqual(AppLaunchPasscodeSettings.gracePeriodSeconds(defaults: defaults), 0)
    }

    func testCredentialICloudSyncDefaultsOffPersistsAndRespectsBiometricRequirement() throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(CredentialICloudSyncSettings.isConfiguredEnabled(defaults: defaults))
        XCTAssertFalse(CredentialICloudSyncSettings.isEnabled(defaults: defaults, availability: .available))

        CredentialICloudSyncSettings.setConfiguredEnabled(true, defaults: defaults)
        XCTAssertTrue(CredentialICloudSyncSettings.isConfiguredEnabled(defaults: defaults))
        XCTAssertFalse(
            CredentialICloudSyncSettings.isEnabled(defaults: defaults, availability: .available),
            "Credential sync requires the Connections & Settings tier"
        )

        ConnectionsAndSettingsICloudSyncSettings.setEnabled(true, defaults: defaults)
        XCTAssertTrue(CredentialICloudSyncSettings.isEnabled(defaults: defaults, availability: .available))
        XCTAssertEqual(
            ConnectionsAndSettingsICloudSyncSettings.status(defaults: defaults, availability: .available),
            .allData
        )

        CredentialProtectionSettings.setEnabled(true, defaults: defaults)
        XCTAssertFalse(CredentialICloudSyncSettings.isEnabled(defaults: defaults, availability: .notAvailable))
        XCTAssertTrue(
            CredentialICloudSyncSettings.isBlockedByCredentialProtection(
                defaults: defaults,
                availability: .notAvailable
            )
        )

        CredentialICloudSyncSettings.setConfiguredEnabled(false, defaults: defaults)
        XCTAssertFalse(CredentialICloudSyncSettings.isConfiguredEnabled(defaults: defaults))
    }

    func testLegacyCredentialSyncEnablesParentTierWithoutOverridingExplicitChoice() throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        CredentialICloudSyncSettings.setConfiguredEnabled(true, defaults: defaults)
        ConnectionsAndSettingsICloudSyncSettings.migrateLegacyCredentialSyncIfNeeded(defaults: defaults)
        XCTAssertTrue(ConnectionsAndSettingsICloudSyncSettings.isEnabled(defaults: defaults))

        ConnectionsAndSettingsICloudSyncSettings.setEnabled(false, defaults: defaults)
        ConnectionsAndSettingsICloudSyncSettings.migrateLegacyCredentialSyncIfNeeded(defaults: defaults)
        XCTAssertFalse(
            ConnectionsAndSettingsICloudSyncSettings.isEnabled(defaults: defaults),
            "An explicit parent-tier choice must not be overwritten"
        )
    }

    func testAppLockPasscodePolicyRequiresMinimumLength() {
        XCTAssertFalse(AppLockPasscodePolicy.isValid(""))
        XCTAssertFalse(AppLockPasscodePolicy.isValid("1"))
        XCTAssertFalse(AppLockPasscodePolicy.isValid("a"))
        XCTAssertFalse(AppLockPasscodePolicy.isValid("abc"))
        XCTAssertTrue(AppLockPasscodePolicy.isValid("12a4"))
        XCTAssertTrue(AppLockPasscodePolicy.isValid("pass code!"))
        XCTAssertTrue(AppLockPasscodePolicy.isValid("1234"))
    }

    func testAppLockPasscodeVerifierRoundTripsThroughKeychain() throws {
        KeychainService.deleteAppLockPasscode()
        defer { KeychainService.deleteAppLockPasscode() }

        XCTAssertFalse(KeychainService.hasAppLockPasscode())

        try KeychainService.saveAppLockPasscode("pass code!")

        XCTAssertTrue(KeychainService.hasAppLockPasscode())
        XCTAssertTrue(KeychainService.verifyAppLockPasscode("pass code!"))
        XCTAssertFalse(KeychainService.verifyAppLockPasscode("pass code?"))
    }

    func testAppLockPasscodeVerifierRoundTripsWhenStoredLocally() throws {
        KeychainService.deleteAppLockPasscode()
        defer { KeychainService.deleteAppLockPasscode() }

        try KeychainService.saveAppLockPasscode("local passcode", synchronizable: false)

        XCTAssertTrue(KeychainService.hasAppLockPasscode())
        XCTAssertTrue(KeychainService.verifyAppLockPasscode("local passcode"))
        XCTAssertFalse(KeychainService.verifyAppLockPasscode("cloud passcode"))
    }

    func testEnablingSyncMovesKeychainItemsIntoSynchronizableScope() throws {
        let connectionId = UUID()
        let keyId = UUID()
        let keyData = Data("private-key".utf8)
        let passwordData = Data("secret".utf8)
        cleanupScopeTransitionItems(connectionId: connectionId, keyId: keyId)
        defer { cleanupScopeTransitionItems(connectionId: connectionId, keyId: keyId) }

        try KeychainService.savePassword("secret", forConnectionId: connectionId, synchronizable: false)
        try KeychainService.savePrivateKey(keyData, forKeyId: keyId, synchronizable: false)
        try KeychainService.saveAppLockPasscode("scope passcode", synchronizable: false)
        let verifierData = try XCTUnwrap(
            keychainData(service: appLockKeychainService, account: "passcode", synchronizable: false)
        )

        try KeychainService.setStoredPasswordsSynchronizable(true)
        try KeychainService.setPrivateKeysSynchronizable(true, forKeyIds: [keyId])
        try KeychainService.setAppLockPasscodeSynchronizable(true)

        assertKeychainItem(
            service: passwordKeychainService,
            account: connectionId.uuidString,
            expectedData: passwordData,
            synchronizable: true
        )
        assertKeychainItem(
            service: privateKeyKeychainService,
            account: keyId.uuidString,
            expectedData: keyData,
            synchronizable: true
        )
        assertKeychainItem(
            service: appLockKeychainService,
            account: "passcode",
            expectedData: verifierData,
            synchronizable: true
        )
        XCTAssertNil(
            keychainData(service: passwordKeychainService, account: connectionId.uuidString, synchronizable: false)
        )
        XCTAssertNil(
            keychainData(service: privateKeyKeychainService, account: keyId.uuidString, synchronizable: false)
        )
        XCTAssertNil(
            keychainData(service: appLockKeychainService, account: "passcode", synchronizable: false)
        )
    }

    func testDisablingSyncWithRetentionKeepsSyncedAndLocalKeychainCopies() throws {
        let connectionId = UUID()
        let keyId = UUID()
        let keyData = Data("private-key".utf8)
        let passwordData = Data("secret".utf8)
        cleanupScopeTransitionItems(connectionId: connectionId, keyId: keyId)
        defer { cleanupScopeTransitionItems(connectionId: connectionId, keyId: keyId) }

        try KeychainService.savePassword("secret", forConnectionId: connectionId, synchronizable: true)
        try KeychainService.savePrivateKey(keyData, forKeyId: keyId, synchronizable: true)
        try KeychainService.saveAppLockPasscode("scope passcode", synchronizable: true)
        let verifierData = try XCTUnwrap(
            keychainData(service: appLockKeychainService, account: "passcode", synchronizable: true)
        )

        try KeychainService.copyStoredPasswordsToLocal()
        try KeychainService.copyPrivateKeysToLocal(forKeyIds: [keyId])
        try KeychainService.copyAppLockPasscodeToLocal()

        for synchronizable in [false, true] {
            assertKeychainItem(
                service: passwordKeychainService,
                account: connectionId.uuidString,
                expectedData: passwordData,
                synchronizable: synchronizable
            )
            assertKeychainItem(
                service: privateKeyKeychainService,
                account: keyId.uuidString,
                expectedData: keyData,
                synchronizable: synchronizable
            )
            assertKeychainItem(
                service: appLockKeychainService,
                account: "passcode",
                expectedData: verifierData,
                synchronizable: synchronizable
            )
        }
    }

    func testDisablingSyncWithoutRetentionDeletesOnlyLocalCredentialCopies() throws {
        let connectionId = UUID()
        let keyId = UUID()
        let keyData = Data("private-key".utf8)
        let passwordData = Data("secret".utf8)
        cleanupScopeTransitionItems(connectionId: connectionId, keyId: keyId)
        defer { cleanupScopeTransitionItems(connectionId: connectionId, keyId: keyId) }

        try KeychainService.savePassword("secret", forConnectionId: connectionId, synchronizable: true)
        try KeychainService.savePrivateKey(keyData, forKeyId: keyId, synchronizable: true)
        try KeychainService.copyStoredPasswordsToLocal()
        try KeychainService.copyPrivateKeysToLocal(forKeyIds: [keyId])

        KeychainService.deleteLocalStoredPasswords()
        try KeychainService.deleteLocalPrivateKeys(forKeyIds: [keyId])

        XCTAssertNil(
            keychainData(service: passwordKeychainService, account: connectionId.uuidString, synchronizable: false)
        )
        XCTAssertNil(
            keychainData(service: privateKeyKeychainService, account: keyId.uuidString, synchronizable: false)
        )
        assertKeychainItem(
            service: passwordKeychainService,
            account: connectionId.uuidString,
            expectedData: passwordData,
            synchronizable: true
        )
        assertKeychainItem(
            service: privateKeyKeychainService,
            account: keyId.uuidString,
            expectedData: keyData,
            synchronizable: true
        )
    }

    func testDeletingCloudDataDeletesOnlySynchronizableKeychainCopies() throws {
        let connectionId = UUID()
        let keyId = UUID()
        let keyData = Data("private-key".utf8)
        let passwordData = Data("secret".utf8)
        cleanupScopeTransitionItems(connectionId: connectionId, keyId: keyId)
        defer { cleanupScopeTransitionItems(connectionId: connectionId, keyId: keyId) }

        try KeychainService.savePassword("secret", forConnectionId: connectionId, synchronizable: true)
        try KeychainService.savePrivateKey(keyData, forKeyId: keyId, synchronizable: true)
        try KeychainService.saveAppLockPasscode("scope passcode", synchronizable: true)
        let verifierData = try XCTUnwrap(
            keychainData(service: appLockKeychainService, account: "passcode", synchronizable: true)
        )
        try KeychainService.copyStoredPasswordsToLocal()
        try KeychainService.copyPrivateKeysToLocal(forKeyIds: [keyId])
        try KeychainService.copyAppLockPasscodeToLocal()

        KeychainService.deleteSyncedStoredPasswords()
        KeychainService.deleteSyncedPrivateKeys()
        KeychainService.deleteSyncedAppLockPasscode()

        XCTAssertNil(
            keychainData(service: passwordKeychainService, account: connectionId.uuidString, synchronizable: true)
        )
        XCTAssertNil(
            keychainData(service: privateKeyKeychainService, account: keyId.uuidString, synchronizable: true)
        )
        XCTAssertNil(
            keychainData(service: appLockKeychainService, account: "passcode", synchronizable: true)
        )
        assertKeychainItem(
            service: passwordKeychainService,
            account: connectionId.uuidString,
            expectedData: passwordData,
            synchronizable: false
        )
        assertKeychainItem(
            service: privateKeyKeychainService,
            account: keyId.uuidString,
            expectedData: keyData,
            synchronizable: false
        )
        assertKeychainItem(
            service: appLockKeychainService,
            account: "passcode",
            expectedData: verifierData,
            synchronizable: false
        )
    }

    func testAppLaunchPasscodeGracePeriodControlsForegroundAuthentication() {
        let backgroundedAt = Date(timeIntervalSince1970: 100)

        XCTAssertTrue(
            AppLaunchPasscodeSettings.shouldRequireAuthenticationAfterBackgrounding(
                backgroundedAt: nil,
                now: backgroundedAt,
                gracePeriodSeconds: 30
            )
        )
        XCTAssertFalse(
            AppLaunchPasscodeSettings.shouldRequireAuthenticationAfterBackgrounding(
                backgroundedAt: backgroundedAt,
                now: backgroundedAt.addingTimeInterval(14),
                gracePeriodSeconds: 15
            )
        )
        XCTAssertTrue(
            AppLaunchPasscodeSettings.shouldRequireAuthenticationAfterBackgrounding(
                backgroundedAt: backgroundedAt,
                now: backgroundedAt.addingTimeInterval(15),
                gracePeriodSeconds: 15
            )
        )
    }

    func testCredentialsSettingsExposeDisabledBiometricFallbackAndAppLockControls() throws {
        let source = try readSourceFile("SSHApp/Views/CredentialsView.swift")
        let appLockSource = try readSourceFile("SSHApp/Views/AppLockView.swift")
        let syncSource = try readSourceFile("SSHApp/Views/ICloudSyncView.swift")
        let contentViewSource = try readSourceFile("SSHApp/Views/ContentView.swift")

        XCTAssertTrue(
            source.contains(".strikethrough(isBiometricProtectionUnavailable)"),
            "Unavailable biometric protection must be visibly disabled, not just logically non-interactive"
        )
        XCTAssertTrue(
            source.contains("credentials.passcodeFallback"),
            "Credential settings must expose the opt-in device passcode fallback"
        )
        XCTAssertTrue(
            source.contains("if isProtectionEnabled") && source.contains("arrow.turn.down.right"),
            "Device passcode fallback must appear as a child row only when biometric protection is enabled"
        )
        XCTAssertTrue(
            source.contains("appLock.gracePeriod"),
            "The app-lock passcode sheet must expose the app-launch reauthentication grace-period slider"
        )
        XCTAssertTrue(
            source.contains("credentials.iCloudSync.status")
                && source.contains("ICloudSyncView(keyStore: keyStore)"),
            "Credential settings must link to the centralized iCloud Sync screen"
        )
        XCTAssertTrue(
            syncSource.contains("confirmationDialog(\n            \"Keep a local copy of credentials?\"")
                && syncSource.contains("Keep Local Copy")
                && syncSource.contains("Delete From This Device"),
            "Disabling credential iCloud sync must ask whether to retain a local copy"
        )
        XCTAssertTrue(
            syncSource.contains(".strikethrough(credentialSyncSecurityBlocked)")
                && syncSource.contains("Face ID/Touch ID needs to be set up first"),
            "Credential iCloud sync must be visibly blocked when synced credential protection cannot be satisfied"
        )
        XCTAssertTrue(
            source.contains("icloud.slash")
                && source.contains("Not synced with iCloud"),
            "Secure Enclave keys must show a small unsyncable indicator when iCloud sync is on"
        )
        XCTAssertFalse(
            appLockSource.contains("Sync app passcode with iCloud")
                || appLockSource.contains("appLock.syncWithICloud"),
            "App Lock must not expose a separate passcode-specific iCloud sync option"
        )
        XCTAssertFalse(
            source.contains("0s means immediately"),
            "The app-lock timeout UI should show Immediately at zero instead of explaining 0s in footer text"
        )
        XCTAssertTrue(
            appLockSource.contains("appLock.edit")
                && appLockSource.contains("AppLockPasscodeSheet(mode: .edit)")
                && source.contains("hasVerifiedCurrentPasscode"),
            "Credential settings must expose an authenticated edit flow for app-lock passcode and timeout changes"
        )
        XCTAssertTrue(
            source.contains("@FocusState private var focusedField")
                && source.contains(".focused($focusedField")
                && source.contains("focusedField = mode == .set ? .newPasscode : .currentPasscode"),
            "The app-passcode sheet should focus the passcode field automatically"
        )
        XCTAssertTrue(
            appLockSource.contains("AppLockPasscodeSheet(mode: .set)"),
            "Enabling App Lock must open the app-specific passcode setup sheet"
        )
        XCTAssertTrue(
            source.contains("appLockPasscode.change"),
            "Editing App Lock must show that changing the existing passcode is optional and explicit"
        )
        XCTAssertFalse(
            source.contains("Use at least"),
            "App passcode setup should not impose a length or digit-only rule in the footer"
        )
        XCTAssertFalse(
            source.contains("filter(\\.isNumber)") || contentViewSource.contains("filter(\\.isNumber)"),
            "App passcode fields must not strip non-numeric characters"
        )
        XCTAssertFalse(
            source.contains("if isEditingPasscode {\n                                Divider()"),
            "Editing the app passcode should not insert a blank divider row before the entry field"
        )
        XCTAssertTrue(
            source.contains("submitLabel: mode == .edit ? .continue : .done")
                && source.contains("onSubmit: mode == .edit ? { submit() } : nil"),
            "Entering the current app passcode for editing should submit with Return, while Disable remains button-only"
        )
        XCTAssertTrue(
            source.contains("isPasscodeVisible ? \"eye.slash\" : \"eye\""),
            "Setting the app passcode must offer the same reveal affordance as changing an SSH password"
        )
        XCTAssertTrue(
            contentViewSource.contains("KeychainService.verifyAppLockPasscode"),
            "App launch unlocking must verify the app-specific passcode"
        )
        XCTAssertTrue(
            contentViewSource.contains(".submitLabel(.go)")
                && contentViewSource.contains(".onSubmit {")
                && contentViewSource.contains("onUnlock()"),
            "The app launch lock should allow Return to unlock when a passcode has been entered"
        )
        XCTAssertTrue(
            contentViewSource.contains("@FocusState private var isPasscodeFocused")
                && contentViewSource.contains(".focused($isPasscodeFocused)")
                && contentViewSource.contains("isPasscodeFocused = true"),
            "The app launch lock passcode field should focus automatically"
        )
        XCTAssertTrue(
            contentViewSource.contains("if !isRequired {\n                    isAppLaunchLocked = false"),
            "Disabling App Lock must immediately remove the lock screen"
        )
        XCTAssertFalse(
            contentViewSource.contains(".task(id: appLaunchPasscodeRequired)"),
            "Enabling App Lock during an active session must not immediately ask for the new passcode again"
        )
        XCTAssertFalse(
            contentViewSource.contains("BiometricCredentialAuthorizer"),
            "App launch locking must not use device biometric/passcode authentication"
        )
    }

    func testCredentialsSettingsOrderAndSSHKeyActions() throws {
        let source = try readSourceFile("SSHApp/Views/CredentialsView.swift")

        let credentialSyncStatus = try XCTUnwrap(source.range(of: #"credentials.iCloudSync.status"#))
        let credentialProtectionHeader = try XCTUnwrap(source.range(of: #"Text("Credential Protection")"#))
        let generateKeyAction = try XCTUnwrap(source.range(of: #"Label("Generate New Key", systemImage: "plus.circle")"#))
        let sshKeysHeader = try XCTUnwrap(source.range(of: #"Text("SSH Keys")"#))
        let passwordsHeader = try XCTUnwrap(source.range(of: #"Text("Passwords")"#))

        XCTAssertLessThan(
            credentialSyncStatus.lowerBound,
            credentialProtectionHeader.lowerBound,
            "iCloud sync status must be the first credentials settings row"
        )
        XCTAssertLessThan(
            credentialProtectionHeader.lowerBound,
            generateKeyAction.lowerBound,
            "Credential Protection must remain above SSH key management"
        )
        XCTAssertLessThan(
            generateKeyAction.lowerBound,
            sshKeysHeader.lowerBound,
            "Generate New Key should be a row in the SSH Keys section body"
        )
        XCTAssertLessThan(
            sshKeysHeader.lowerBound,
            passwordsHeader.lowerBound,
            "SSH Keys should stay above saved passwords"
        )

        let passwordsEmptyStateStart = try XCTUnwrap(source.range(of: "if storedPasswordConnections.isEmpty"))
        let passwordsEmptyStateEnd = try XCTUnwrap(
            source.range(
                of: "            } header: {\n                Text(\"Passwords\")",
                range: passwordsEmptyStateStart.lowerBound..<source.endIndex
            )
        )
        let passwordsEmptyState = String(source[passwordsEmptyStateStart.lowerBound..<passwordsEmptyStateEnd.lowerBound])
        XCTAssertTrue(
            passwordsEmptyState.contains(#"Text("Saved passwords will appear here")"#),
            "The empty saved-passwords state should be a compact single row."
        )
        XCTAssertFalse(
            passwordsEmptyState.contains(#""No Saved Passwords""#)
                || passwordsEmptyState.contains(#"systemImage: "lock""#)
                || passwordsEmptyState.contains("Saved passwords will appear here by host"),
            "The empty saved-passwords state should not use the oversized icon/title placeholder."
        )
        XCTAssertFalse(
            source.contains("SSH keys provide secure authentication"),
            "The SSH Keys section should not include the old explanatory footer"
        )
        XCTAssertFalse(
            source.contains(#""No SSH Keys""#)
                || source.contains("Generate a key to use for SSH authentication"),
            "The SSH Keys section should not show an empty-state item when no keys exist"
        )
    }

    func testEditSSHKeySheetPublicKeyLayoutAndCopyAffordance() throws {
        let source = try readSourceFile("SSHApp/Views/CredentialsView.swift")
        let editSheetStart = try XCTUnwrap(source.range(of: "private struct EditSSHKeySheet"))
        let nextSheetStart = try XCTUnwrap(
            source.range(of: "private struct ChangePasswordSheet", range: editSheetStart.lowerBound..<source.endIndex)
        )
        let editSheet = String(source[editSheetStart.lowerBound..<nextSheetStart.lowerBound])

        let nameSection = try XCTUnwrap(editSheet.range(of: #"Section("Name")"#))
        let publicKeySection = try XCTUnwrap(editSheet.range(of: #"Section("Public Key")"#))
        let usedBySection = try XCTUnwrap(editSheet.range(of: #"Section("Used By")"#))
        let keyDetailsSection = try XCTUnwrap(editSheet.range(of: #"Section("Key Details")"#))

        XCTAssertLessThan(nameSection.lowerBound, publicKeySection.lowerBound)
        XCTAssertLessThan(publicKeySection.lowerBound, usedBySection.lowerBound)
        XCTAssertLessThan(usedBySection.lowerBound, keyDetailsSection.lowerBound)
        XCTAssertTrue(
            editSheet.contains(".presentationSizing(.page)"),
            "The edit key sheet should use a larger page presentation when the device has room."
        )

        let publicKeyBody = String(editSheet[publicKeySection.lowerBound..<usedBySection.lowerBound])
        let publicKeyText = try XCTUnwrap(publicKeyBody.range(of: "Text(key.publicKey)"))
        let copyIcon = try XCTUnwrap(publicKeyBody.range(of: #"Image(systemName: "doc.on.doc")"#))

        XCTAssertLessThan(publicKeyText.lowerBound, copyIcon.lowerBound)
        XCTAssertTrue(
            publicKeyBody.contains("Button {")
                && publicKeyBody.contains("UIPasteboard.general.string = key.publicKey")
                && publicKeyBody.contains("showCopyAlert = true"),
            "Tapping the public key row should copy the key and show copy feedback."
        )
        XCTAssertTrue(
            publicKeyBody.contains("HStack(alignment: .top")
                && publicKeyBody.contains(".contentShape(Rectangle())")
                && publicKeyBody.contains(".buttonStyle(.plain)")
                && publicKeyBody.contains(#".accessibilityLabel("Copy Public Key")"#),
            "The public key row should be a full-row plain button with a top-aligned copy affordance."
        )
        XCTAssertFalse(
            publicKeyBody.contains(#"Button("Copy Public Key")"#),
            "The edit key sheet should not show a separate Copy Public Key row."
        )
    }

    func testEditSSHKeyCopyConfirmationDismissesSheet() throws {
        let source = try readSourceFile("SSHApp/Views/CredentialsView.swift")
        let editSheetStart = try XCTUnwrap(source.range(of: "private struct EditSSHKeySheet"))
        let nextSheetStart = try XCTUnwrap(
            source.range(of: "private struct ChangePasswordSheet", range: editSheetStart.lowerBound..<source.endIndex)
        )
        let editSheet = String(source[editSheetStart.lowerBound..<nextSheetStart.lowerBound])

        let alertStart = try XCTUnwrap(editSheet.range(of: #".alert("Public Key Copied""#))
        let messageStart = try XCTUnwrap(editSheet.range(of: "} message:", range: alertStart.lowerBound..<editSheet.endIndex))
        let alertActions = String(editSheet[alertStart.lowerBound..<messageStart.lowerBound])

        XCTAssertTrue(
            alertActions.contains(#"Button("OK")"#) && alertActions.contains("dismiss()"),
            "Acknowledging the copied public key should close the edit key sheet and return to Credentials."
        )
        XCTAssertFalse(
            alertActions.contains(#"Button("OK", role: .cancel) {}"#),
            "The copy confirmation OK action must not only dismiss the alert."
        )
    }

    func testDisablingCredentialProtectionRequiresAuthOnlyWhenCredentialsExist() {
        XCTAssertEqual(
            CredentialProtectionSettings.disableAuthorizationRequirement(
                hasStoredCredentials: false,
                availability: .available
            ),
            .none
        )
        XCTAssertEqual(
            CredentialProtectionSettings.disableAuthorizationRequirement(
                hasStoredCredentials: true,
                availability: .available
            ),
            .biometrics
        )
        XCTAssertEqual(
            CredentialProtectionSettings.disableAuthorizationRequirement(
                hasStoredCredentials: true,
                availability: .lockedOut
            ),
            .deviceOwner
        )
        XCTAssertEqual(
            CredentialProtectionSettings.disableAuthorizationRequirement(
                hasStoredCredentials: true,
                availability: .notAvailable
            ),
            .deviceOwner
        )
    }

    // MARK: - KeyStore metadata round-trip

    @MainActor
    func testCredentialMetadataResolverDoesNotReadCloudWhileCredentialSyncIsOff() throws {
        let store = NSUbiquitousKeyValueStore.default
        let syncedKeysKey = "dev.sshapp.sshapp.tests.resolver.synced.\(UUID().uuidString)"
        let localKeysKey = "dev.sshapp.sshapp.tests.resolver.local.\(UUID().uuidString)"
        let suiteName = "dev.sshapp.sshapp.tests.resolver.defaults.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            store.removeObject(forKey: syncedKeysKey)
            store.synchronize()
            defaults.removePersistentDomain(forName: suiteName)
        }

        let cloudOnlyKey = SSHKey(
            id: UUID(),
            name: "cloud-only",
            publicKey: "ssh-ed25519 AAAAcloud-only cloud-only",
            fingerprint: "SHA256:cloud-only",
            createdAt: Date(),
            keyType: .ed25519
        )
        store.set(try JSONEncoder().encode([cloudOnlyKey]), forKey: syncedKeysKey)

        XCTAssertNil(
            SSHKeyMetadataStorage.keyType(
                for: cloudOnlyKey.id,
                ubiquitous: store,
                localDefaults: defaults,
                syncedKeysKey: syncedKeysKey,
                localKeysKey: localKeysKey
            )
        )

        ConnectionsAndSettingsICloudSyncSettings.setEnabled(true, defaults: defaults)
        CredentialICloudSyncSettings.setConfiguredEnabled(true, defaults: defaults)
        XCTAssertEqual(
            SSHKeyMetadataStorage.keyType(
                for: cloudOnlyKey.id,
                ubiquitous: store,
                localDefaults: defaults,
                syncedKeysKey: syncedKeysKey,
                localKeysKey: localKeysKey
            ),
            .ed25519
        )
    }

    @MainActor
    func testKeyStoreMetadataRoundTripsThroughUbiquitousStore() throws {
        let store = NSUbiquitousKeyValueStore.default
        let testKey = "dev.sshapp.sshapp.tests.sshKeys.\(UUID().uuidString)"
        let localKeysKey = "\(testKey).local"
        let suiteName = "dev.sshapp.sshapp.tests.local.\(UUID().uuidString)"
        let localDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        ConnectionsAndSettingsICloudSyncSettings.setEnabled(true, defaults: localDefaults)
        CredentialICloudSyncSettings.setConfiguredEnabled(true, defaults: localDefaults)
        store.removeObject(forKey: testKey)
        localDefaults.removeObject(forKey: localKeysKey)

        let keyStore = KeyStore(
            ubiquitous: store,
            keysKey: testKey,
            localDefaults: localDefaults,
            localKeysKey: localKeysKey
        )
        XCTAssertTrue(keyStore.keys.isEmpty)

        let generated = try keyStore.generateKey(name: "round-trip-test")
        XCTAssertEqual(keyStore.keys.count, 1)
        XCTAssertEqual(keyStore.key(withId: generated.id)?.name, "round-trip-test")

        // A fresh store reading the same ubiquitous key should see the metadata.
        let reloaded = KeyStore(
            ubiquitous: store,
            keysKey: testKey,
            localDefaults: localDefaults,
            localKeysKey: localKeysKey
        )
        XCTAssertEqual(reloaded.keys.count, 1)
        XCTAssertEqual(reloaded.key(withId: generated.id)?.fingerprint, generated.fingerprint)

        // Clean up the private key + metadata.
        try keyStore.deleteKey(generated)
        XCTAssertTrue(keyStore.keys.isEmpty)

        store.removeObject(forKey: testKey)
        localDefaults.removePersistentDomain(forName: suiteName)
        store.synchronize()
    }

    @MainActor
    func testKeyStoreIgnoresUserDefaultsMetadata() throws {
        let store = NSUbiquitousKeyValueStore.default
        let testKey = "dev.sshapp.sshapp.tests.sshKeys.\(UUID().uuidString)"
        let backup = UserDefaults.standard.data(forKey: testKey)
        store.removeObject(forKey: testKey)

        let seeded = SSHKey(
            id: UUID(),
            name: "user-defaults-only",
            publicKey: "ssh-ed25519 AAAA user-defaults-only",
            fingerprint: "SHA256:user-defaults-only",
            createdAt: Date(),
            keyType: .ed25519
        )
        let data = try JSONEncoder().encode([seeded])
        UserDefaults.standard.set(data, forKey: testKey)
        defer {
            UserDefaults.standard.removeObject(forKey: testKey)
            if let backup { UserDefaults.standard.set(backup, forKey: testKey) }
            store.removeObject(forKey: testKey)
            store.synchronize()
        }

        let keyStore = KeyStore(ubiquitous: store, keysKey: testKey)
        XCTAssertTrue(keyStore.keys.isEmpty)
        XCTAssertNotNil(UserDefaults.standard.data(forKey: testKey))
    }

    @MainActor
    func testKeyStoreLoadsSecureEnclaveMetadataFromLocalStore() throws {
        let store = NSUbiquitousKeyValueStore.default
        let testKey = "dev.sshapp.sshapp.tests.sshKeys.\(UUID().uuidString)"
        let localKeysKey = "\(testKey).local"
        let suiteName = "dev.sshapp.sshapp.tests.local.\(UUID().uuidString)"
        guard let localDefaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create local defaults suite")
            return
        }
        ConnectionsAndSettingsICloudSyncSettings.setEnabled(true, defaults: localDefaults)
        CredentialICloudSyncSettings.setConfiguredEnabled(true, defaults: localDefaults)
        defer {
            store.removeObject(forKey: testKey)
            store.synchronize()
            localDefaults.removePersistentDomain(forName: suiteName)
        }

        let syncedKey = SSHKey(
            id: UUID(),
            name: "synced",
            publicKey: "ssh-ed25519 AAAA synced",
            fingerprint: "SHA256:synced",
            createdAt: Date(),
            keyType: .ed25519
        )
        let localKey = SSHKey(
            id: UUID(),
            name: "secure-enclave",
            publicKey: "ecdsa-sha2-nistp256 AAAA secure-enclave",
            fingerprint: "SHA256:secure-enclave",
            createdAt: Date(),
            keyType: .secureEnclaveECDSA
        )

        store.set(try JSONEncoder().encode([syncedKey]), forKey: testKey)
        localDefaults.set(try JSONEncoder().encode([localKey]), forKey: localKeysKey)

        let keyStore = KeyStore(
            ubiquitous: store,
            keysKey: testKey,
            localDefaults: localDefaults,
            localKeysKey: localKeysKey
        )

        XCTAssertEqual(keyStore.keys.count, 2)
        XCTAssertEqual(keyStore.key(withId: syncedKey.id)?.keyType, .ed25519)
        XCTAssertEqual(keyStore.key(withId: localKey.id)?.keyType, .secureEnclaveECDSA)
    }

    @MainActor
    func testGeneratedEd25519MetadataStaysOutOfLocalKeyStore() throws {
        let store = NSUbiquitousKeyValueStore.default
        let testKey = "dev.sshapp.sshapp.tests.sshKeys.\(UUID().uuidString)"
        let localKeysKey = "\(testKey).local"
        let suiteName = "dev.sshapp.sshapp.tests.local.\(UUID().uuidString)"
        guard let localDefaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create local defaults suite")
            return
        }
        ConnectionsAndSettingsICloudSyncSettings.setEnabled(true, defaults: localDefaults)
        CredentialICloudSyncSettings.setConfiguredEnabled(true, defaults: localDefaults)
        defer {
            store.removeObject(forKey: testKey)
            store.synchronize()
            localDefaults.removePersistentDomain(forName: suiteName)
        }

        let keyStore = KeyStore(
            ubiquitous: store,
            keysKey: testKey,
            localDefaults: localDefaults,
            localKeysKey: localKeysKey
        )
        let generated = try keyStore.generateKey(name: "synced-only", keyType: .ed25519)
        defer { try? keyStore.deleteKey(generated) }

        let localData = try XCTUnwrap(localDefaults.data(forKey: localKeysKey))
        let localKeys = try JSONDecoder().decode([SSHKey].self, from: localData)
        XCTAssertTrue(localKeys.isEmpty)
    }

    @MainActor
    func testDisablingCredentialSyncKeepsCloudMetadataUntilExplicitDeletion() throws {
        let store = NSUbiquitousKeyValueStore.default
        let testKey = "dev.sshapp.sshapp.tests.sshKeys.\(UUID().uuidString)"
        let localKeysKey = "\(testKey).local"
        let suiteName = "dev.sshapp.sshapp.tests.local.\(UUID().uuidString)"
        let localDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        ConnectionsAndSettingsICloudSyncSettings.setEnabled(true, defaults: localDefaults)
        CredentialICloudSyncSettings.setConfiguredEnabled(true, defaults: localDefaults)
        defer {
            store.removeObject(forKey: testKey)
            store.synchronize()
            localDefaults.removePersistentDomain(forName: suiteName)
        }

        let syncedKey = SSHKey(
            id: UUID(),
            name: "cloud-copy",
            publicKey: "ssh-ed25519 AAAAcloud cloud-copy",
            fingerprint: "SHA256:cloud-copy",
            createdAt: Date(),
            keyType: .ed25519
        )
        store.set(try JSONEncoder().encode([syncedKey]), forKey: testKey)

        let keyStore = KeyStore(
            ubiquitous: store,
            keysKey: testKey,
            localDefaults: localDefaults,
            localKeysKey: localKeysKey
        )
        keyStore.applyCredentialICloudSync(enabled: false, retainLocalCopy: true)

        let retainedCloudData = try XCTUnwrap(store.data(forKey: testKey))
        XCTAssertEqual(try JSONDecoder().decode([SSHKey].self, from: retainedCloudData).first?.id, syncedKey.id)
        let retainedLocalData = try XCTUnwrap(localDefaults.data(forKey: localKeysKey))
        XCTAssertEqual(try JSONDecoder().decode([SSHKey].self, from: retainedLocalData).first?.id, syncedKey.id)

        keyStore.deleteSyncedCredentialMetadata()
        let deletedCloudData = try XCTUnwrap(store.data(forKey: testKey))
        XCTAssertTrue(try JSONDecoder().decode([SSHKey].self, from: deletedCloudData).isEmpty)
    }

    @MainActor
    func testGeneratedEd25519MetadataStaysLocalWhenCredentialSyncIsOff() throws {
        let store = NSUbiquitousKeyValueStore.default
        let testKey = "dev.sshapp.sshapp.tests.sshKeys.\(UUID().uuidString)"
        let localKeysKey = "\(testKey).local"
        let suiteName = "dev.sshapp.sshapp.tests.local.\(UUID().uuidString)"
        let localDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            store.removeObject(forKey: testKey)
            store.synchronize()
            localDefaults.removePersistentDomain(forName: suiteName)
        }

        let keyStore = KeyStore(
            ubiquitous: store,
            keysKey: testKey,
            localDefaults: localDefaults,
            localKeysKey: localKeysKey
        )
        let generated = try keyStore.generateKey(name: "local-ed25519", keyType: .ed25519)
        defer { try? keyStore.deleteKey(generated) }

        XCTAssertNil(store.data(forKey: testKey))
        let localData = try XCTUnwrap(localDefaults.data(forKey: localKeysKey))
        let localKeys = try JSONDecoder().decode([SSHKey].self, from: localData)
        XCTAssertEqual(localKeys.first?.id, generated.id)
    }

    @MainActor
    func testRenamingKeyPersistsMetadataAndUpdatesPublicKeyComment() throws {
        let store = NSUbiquitousKeyValueStore.default
        let testKey = "dev.sshapp.sshapp.tests.sshKeys.\(UUID().uuidString)"
        let localKeysKey = "\(testKey).local"
        let suiteName = "dev.sshapp.sshapp.tests.local.\(UUID().uuidString)"
        let localDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        ConnectionsAndSettingsICloudSyncSettings.setEnabled(true, defaults: localDefaults)
        CredentialICloudSyncSettings.setConfiguredEnabled(true, defaults: localDefaults)
        store.removeObject(forKey: testKey)
        localDefaults.removeObject(forKey: localKeysKey)

        let keyStore = KeyStore(
            ubiquitous: store,
            keysKey: testKey,
            localDefaults: localDefaults,
            localKeysKey: localKeysKey
        )
        let generated = try keyStore.generateKey(name: "old-name", keyType: .ed25519)
        defer {
            try? keyStore.deleteKey(generated)
            store.removeObject(forKey: testKey)
            localDefaults.removePersistentDomain(forName: suiteName)
            store.synchronize()
        }

        let renamed = try keyStore.renameKey(generated, to: "  new-name  ")

        XCTAssertEqual(renamed.id, generated.id)
        XCTAssertEqual(renamed.name, "new-name")
        XCTAssertEqual(renamed.fingerprint, generated.fingerprint)
        XCTAssertEqual(renamed.keyType, generated.keyType)
        XCTAssertTrue(renamed.publicKey.hasSuffix(" new-name"))
        XCTAssertEqual(keyStore.key(withId: generated.id)?.name, "new-name")

        let reloaded = KeyStore(
            ubiquitous: store,
            keysKey: testKey,
            localDefaults: localDefaults,
            localKeysKey: localKeysKey
        )
        let reloadedKey = try XCTUnwrap(reloaded.key(withId: generated.id))
        XCTAssertEqual(reloadedKey.name, "new-name")
        XCTAssertTrue(reloadedKey.publicKey.hasSuffix(" new-name"))
    }

    @MainActor
    func testRenamingKeyRejectsEmptyNameWithoutChangingMetadata() throws {
        let store = NSUbiquitousKeyValueStore.default
        let testKey = "dev.sshapp.sshapp.tests.sshKeys.\(UUID().uuidString)"
        let localKeysKey = "\(testKey).local"
        let suiteName = "dev.sshapp.sshapp.tests.local.\(UUID().uuidString)"
        let localDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        ConnectionsAndSettingsICloudSyncSettings.setEnabled(true, defaults: localDefaults)
        CredentialICloudSyncSettings.setConfiguredEnabled(true, defaults: localDefaults)
        store.removeObject(forKey: testKey)
        localDefaults.removeObject(forKey: localKeysKey)

        let keyStore = KeyStore(
            ubiquitous: store,
            keysKey: testKey,
            localDefaults: localDefaults,
            localKeysKey: localKeysKey
        )
        let generated = try keyStore.generateKey(name: "original", keyType: .ed25519)
        defer {
            try? keyStore.deleteKey(generated)
            store.removeObject(forKey: testKey)
            localDefaults.removePersistentDomain(forName: suiteName)
            store.synchronize()
        }

        XCTAssertThrowsError(try keyStore.renameKey(generated, to: "   "))
        XCTAssertEqual(keyStore.key(withId: generated.id)?.name, "original")
        XCTAssertTrue(keyStore.key(withId: generated.id)?.publicKey.hasSuffix(" original") == true)
    }

    // MARK: - OpenSSH ECDSA formatting

    func testECDSAP256PublicKeyBlobUsesOpenSSHShape() throws {
        let publicKey = Data([0x04]) + Data(repeating: 0x01, count: 32) + Data(repeating: 0x02, count: 32)
        let blob = SSHKeyGenerator.makeECDSAP256PublicKeyBlob(x963Representation: publicKey)

        var offset = 0
        let keyType = try readSSHString(blob, offset: &offset)
        let curve = try readSSHString(blob, offset: &offset)
        let encodedPublicKey = try readSSHString(blob, offset: &offset)

        XCTAssertEqual(String(data: keyType, encoding: .utf8), "ecdsa-sha2-nistp256")
        XCTAssertEqual(String(data: curve, encoding: .utf8), "nistp256")
        XCTAssertEqual(encodedPublicKey, publicKey)
        XCTAssertEqual(offset, blob.count)

        let authorizedKey = "ecdsa-sha2-nistp256 \(blob.base64EncodedString()) test"
        XCTAssertEqual(try SSHKeyGenerator.publicKeyBlob(fromOpenSSHPublicKey: authorizedKey), blob)
    }

    func testECDSASignatureBlobUsesSSHMPInts() throws {
        var rawSignature = Data(repeating: 0, count: 64)
        rawSignature[31] = 0x01
        rawSignature[32] = 0x80

        let blob = try SSHKeyGenerator.encodeECDSASignatureBlob(rawSignature: rawSignature)
        var offset = 0
        let r = try readSSHString(blob, offset: &offset)
        let s = try readSSHString(blob, offset: &offset)

        XCTAssertEqual(r, Data([0x01]))
        XCTAssertEqual(s.count, 33)
        XCTAssertEqual(s.first, 0)
        XCTAssertEqual(s.dropFirst().first, 0x80)
        XCTAssertEqual(offset, blob.count)
    }

    func testECDSASignatureBlobRejectsInvalidLength() {
        XCTAssertThrowsError(
            try SSHKeyGenerator.encodeECDSASignatureBlob(rawSignature: Data(repeating: 0, count: 63))
        )
    }

    func testPublicKeyAuthenticationUsesCallbackSignerForBothKeyTypes() throws {
        let sessionSource = try readSourceFile("SSHApp/SSH/SSHSession.swift")
        let keySource = try readSourceFile("SSHApp/SSH/SSHKey.swift")
        let transportSource = try readSourceFile("SSHApp/SSH/SSH2Transport.swift")
        let shimSource = try readSourceFile("SSHApp/SSH/CLibSSH2Shim.c")

        // Both key types authenticate through the callback signer; no OpenSSH
        // PEM of the private key is ever produced or handed to libssh2.
        XCTAssertTrue(sessionSource.contains("signSSHPayload"))
        XCTAssertFalse(sessionSource.contains("privateKeyPEM"))
        XCTAssertFalse(sessionSource.contains("encodeOpenSSHPrivateKey"))
        XCTAssertTrue(keySource.contains("signSecureEnclaveECDSAPayload"))
        XCTAssertTrue(keySource.contains("signEd25519Payload"))
        XCTAssertFalse(keySource.contains("encodeOpenSSHPrivateKey"))
        XCTAssertTrue(transportSource.contains("sshapp_userauth_publickey"))
        XCTAssertFalse(transportSource.contains("publickey_frommemory"))
        XCTAssertTrue(shimSource.contains("libssh2_userauth_publickey"))
    }

    func testEd25519CallbackSignatureVerifiesAgainstPublicKey() throws {
        // The refactored Ed25519 auth path signs the challenge with CryptoKit
        // and returns the raw 64-byte signature (libssh2 wraps it as
        // ssh-ed25519). A produced signature must validate against the derived
        // public key, proving the callback path authenticates correctly.
        let privateKey = Curve25519.Signing.PrivateKey()
        let payload = Data("ssh-exchange-hash-challenge".utf8)

        let signature = try SSHKeyGenerator.signEd25519Payload(
            privateKeyData: privateKey.rawRepresentation,
            payload: payload
        )

        XCTAssertEqual(signature.count, 64)
        XCTAssertTrue(privateKey.publicKey.isValidSignature(signature, for: payload))
    }

    func testSignSSHPayloadDispatchesEd25519() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let payload = Data("challenge".utf8)

        let signature = try SSHKeyGenerator.signSSHPayload(
            keyType: .ed25519,
            privateKeyData: privateKey.rawRepresentation,
            payload: payload
        )

        XCTAssertTrue(privateKey.publicKey.isValidSignature(signature, for: payload))
    }

    private let privateKeyKeychainService = "dev.sshapp.sshapp.keys"
    private let passwordKeychainService = "dev.sshapp.sshapp.passwords"
    private let appLockKeychainService = "dev.sshapp.sshapp.appLock"

    private func assertKeychainItem(
        service: String,
        account: String,
        expectedData: Data,
        synchronizable: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            keychainData(service: service, account: account, synchronizable: synchronizable),
            expectedData,
            file: file,
            line: line
        )

        let expectedAccessibility = (
            synchronizable
                ? kSecAttrAccessibleWhenUnlocked
                : kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ) as String
        XCTAssertEqual(
            keychainAttributes(service: service, account: account, synchronizable: synchronizable)?[
                kSecAttrAccessible as String
            ] as? String,
            expectedAccessibility,
            file: file,
            line: line
        )
    }

    private func keychainData(service: String, account: String, synchronizable: Bool) -> Data? {
        var query = keychainQuery(service: service, account: account, synchronizable: synchronizable)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? Data
    }

    private func keychainAttributes(
        service: String,
        account: String,
        synchronizable: Bool
    ) -> [String: Any]? {
        var query = keychainQuery(service: service, account: account, synchronizable: synchronizable)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? [String: Any]
    }

    private func keychainQuery(
        service: String,
        account: String,
        synchronizable: Bool
    ) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizable ? kCFBooleanTrue as Any : kCFBooleanFalse as Any
        ]
    }

    private func cleanupScopeTransitionItems(connectionId: UUID, keyId: UUID) {
        deleteKeychainItems(service: passwordKeychainService, account: connectionId.uuidString)
        deleteKeychainItems(service: privateKeyKeychainService, account: keyId.uuidString)
        deleteKeychainItems(service: appLockKeychainService, account: "passcode")
    }

    private func deleteKeychainItems(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        SecItemDelete(query as CFDictionary)
    }

    private enum SSHStringParseError: Error {
        case invalid
    }

    private func readSSHString(_ data: Data, offset: inout Int) throws -> Data {
        guard offset + 4 <= data.count else { throw SSHStringParseError.invalid }

        let length = data[offset..<offset + 4].reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        }
        offset += 4

        guard offset + Int(length) <= data.count else { throw SSHStringParseError.invalid }
        let value = Data(data[offset..<offset + Int(length)])
        offset += Int(length)
        return value
    }

    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let suiteName = "dev.sshapp.sshapp.tests.defaults.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
