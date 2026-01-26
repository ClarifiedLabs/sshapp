import XCTest
import SwiftData
import LocalAuthentication
@testable import SSHApp

/// Regression tests for the iCloud Keychain credential storage work:
/// `KeychainService` password API and `KeyStore` metadata round-trip via
/// `NSUbiquitousKeyValueStore`.
///
/// Note: the iOS Simulator does not fully exercise iCloud Keychain sync
/// (`kSecAttrSynchronizable`), and synchronizable items require the iCloud
/// entitlement which the simulator host may not have. These tests therefore
/// focus on the API contract and metadata behavior that can be verified
/// locally; cross-device sync must be validated on hardware.
final class KeychainCredentialTests: XCTestCase {

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

    func testAppLockPasscodePolicyAcceptsAnyNonEmptyPasscode() {
        XCTAssertFalse(AppLockPasscodePolicy.isValid(""))
        XCTAssertTrue(AppLockPasscodePolicy.isValid("1"))
        XCTAssertTrue(AppLockPasscodePolicy.isValid("a"))
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
            source.contains("credentials.appLaunchPasscode.gracePeriod"),
            "The app-lock passcode sheet must expose the app-launch reauthentication grace-period slider"
        )
        XCTAssertFalse(
            source.contains("0s means immediately"),
            "The app-lock timeout UI should show Immediately at zero instead of explaining 0s in footer text"
        )
        XCTAssertTrue(
            source.contains("credentials.appLaunchPasscode.edit")
                && source.contains("AppLockPasscodeSheet(mode: .edit)")
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
            source.contains("AppLockPasscodeSheet(mode: .set)"),
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
        XCTAssertFalse(
            contentViewSource.contains("BiometricCredentialAuthorizer"),
            "App launch locking must not use device biometric/passcode authentication"
        )
    }

    func testCredentialsSettingsOrderAndSSHKeyActions() throws {
        let source = try readSourceFile("SSHApp/Views/CredentialsView.swift")

        let credentialProtectionHeader = try XCTUnwrap(source.range(of: #"Text("Credential Protection")"#))
        let appLockHeader = try XCTUnwrap(source.range(of: #"Text("App Lock")"#))
        let generateKeyAction = try XCTUnwrap(source.range(of: #"Label("Generate New Key", systemImage: "plus.circle")"#))
        let sshKeysHeader = try XCTUnwrap(source.range(of: #"Text("SSH Keys")"#))
        let passwordsHeader = try XCTUnwrap(source.range(of: #"Text("Passwords")"#))

        XCTAssertLessThan(
            credentialProtectionHeader.lowerBound,
            appLockHeader.lowerBound,
            "Credential Protection must be the first credentials settings section"
        )
        XCTAssertLessThan(
            appLockHeader.lowerBound,
            generateKeyAction.lowerBound,
            "App Lock must immediately follow Credential Protection before SSH key management"
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
        XCTAssertFalse(
            source.contains("SSH keys provide secure authentication"),
            "The SSH Keys section should not include the old explanatory footer"
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
    func testKeyStoreMetadataRoundTripsThroughUbiquitousStore() throws {
        let store = NSUbiquitousKeyValueStore.default
        let testKey = "dev.sshapp.sshapp.tests.sshKeys.\(UUID().uuidString)"
        let localKeysKey = "\(testKey).local"
        store.removeObject(forKey: testKey)
        UserDefaults.standard.removeObject(forKey: localKeysKey)

        let keyStore = KeyStore(ubiquitous: store, keysKey: testKey)
        XCTAssertTrue(keyStore.keys.isEmpty)

        let generated = try keyStore.generateKey(name: "round-trip-test")
        XCTAssertEqual(keyStore.keys.count, 1)
        XCTAssertEqual(keyStore.key(withId: generated.id)?.name, "round-trip-test")

        // A fresh store reading the same ubiquitous key should see the metadata.
        let reloaded = KeyStore(ubiquitous: store, keysKey: testKey)
        XCTAssertEqual(reloaded.keys.count, 1)
        XCTAssertEqual(reloaded.key(withId: generated.id)?.fingerprint, generated.fingerprint)

        // Clean up the private key + metadata.
        try keyStore.deleteKey(generated)
        XCTAssertTrue(keyStore.keys.isEmpty)

        store.removeObject(forKey: testKey)
        UserDefaults.standard.removeObject(forKey: localKeysKey)
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
    func testRenamingKeyPersistsMetadataAndUpdatesPublicKeyComment() throws {
        let store = NSUbiquitousKeyValueStore.default
        let testKey = "dev.sshapp.sshapp.tests.sshKeys.\(UUID().uuidString)"
        let localKeysKey = "\(testKey).local"
        store.removeObject(forKey: testKey)
        UserDefaults.standard.removeObject(forKey: localKeysKey)

        let keyStore = KeyStore(ubiquitous: store, keysKey: testKey)
        let generated = try keyStore.generateKey(name: "old-name", keyType: .ed25519)
        defer {
            try? keyStore.deleteKey(generated)
            store.removeObject(forKey: testKey)
            UserDefaults.standard.removeObject(forKey: localKeysKey)
            store.synchronize()
        }

        let renamed = try keyStore.renameKey(generated, to: "  new-name  ")

        XCTAssertEqual(renamed.id, generated.id)
        XCTAssertEqual(renamed.name, "new-name")
        XCTAssertEqual(renamed.fingerprint, generated.fingerprint)
        XCTAssertEqual(renamed.keyType, generated.keyType)
        XCTAssertTrue(renamed.publicKey.hasSuffix(" new-name"))
        XCTAssertEqual(keyStore.key(withId: generated.id)?.name, "new-name")

        let reloaded = KeyStore(ubiquitous: store, keysKey: testKey)
        let reloadedKey = try XCTUnwrap(reloaded.key(withId: generated.id))
        XCTAssertEqual(reloadedKey.name, "new-name")
        XCTAssertTrue(reloadedKey.publicKey.hasSuffix(" new-name"))
    }

    @MainActor
    func testRenamingKeyRejectsEmptyNameWithoutChangingMetadata() throws {
        let store = NSUbiquitousKeyValueStore.default
        let testKey = "dev.sshapp.sshapp.tests.sshKeys.\(UUID().uuidString)"
        let localKeysKey = "\(testKey).local"
        store.removeObject(forKey: testKey)
        UserDefaults.standard.removeObject(forKey: localKeysKey)

        let keyStore = KeyStore(ubiquitous: store, keysKey: testKey)
        let generated = try keyStore.generateKey(name: "original", keyType: .ed25519)
        defer {
            try? keyStore.deleteKey(generated)
            store.removeObject(forKey: testKey)
            UserDefaults.standard.removeObject(forKey: localKeysKey)
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

    func testSecureEnclaveAuthenticationUsesCallbackPath() throws {
        let sessionSource = try readSourceFile("SSHApp/SSH/SSHSession.swift")
        let transportSource = try readSourceFile("SSHApp/SSH/SSH2Transport.swift")
        let shimSource = try readSourceFile("SSHApp/SSH/CLibSSH2Shim.c")

        XCTAssertTrue(sessionSource.contains("case .secureEnclaveECDSA"))
        XCTAssertTrue(sessionSource.contains("signSecureEnclaveECDSAPayload"))
        XCTAssertTrue(transportSource.contains("sshapp_userauth_publickey"))
        XCTAssertTrue(shimSource.contains("libssh2_userauth_publickey"))
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
