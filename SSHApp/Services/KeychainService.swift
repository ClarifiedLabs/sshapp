import CommonCrypto
import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Service for securely storing SSH keys and connection passwords in the iOS Keychain.
///
/// When credential iCloud sync is enabled, Ed25519 private keys and remembered
/// passwords are stored as synchronizable (`kSecAttrSynchronizable`)
/// `WhenUnlocked` items. The App Lock verifier follows Connections & Settings
/// sync independently. Otherwise items use `WhenUnlockedThisDeviceOnly`.
enum KeychainService {
    /// Current key-item service name.
    private static let keyServiceName = "dev.sshapp.sshapp.keys"
    /// Password-item service name, namespaced apart from keys.
    private static let passwordServiceName = "dev.sshapp.sshapp.passwords"
    /// App lock passcode verifier.
    private static let appLockServiceName = "dev.sshapp.sshapp.appLock"
    private static let appLockPasscodeAccount = "passcode"
    /// PBKDF2-HMAC-SHA256 rounds for the app-lock passcode verifier.
    private static let appLockPasscodeIterations = 210_000
    private static let appLockPasscodeSaltLength = 32
    /// Verifier format version. v2 = PBKDF2-HMAC-SHA256 (v1 was iterated SHA-256).
    private static let appLockPasscodeVersion = 2
    private static let appLockPasscodeDigestLength = 32

    enum KeychainError: LocalizedError {
        case saveFailed(OSStatus)
        case loadFailed(OSStatus)
        case deleteFailed(OSStatus)
        case notFound
        case invalidData

        var errorDescription: String? {
            switch self {
            case .saveFailed(let status): return "Failed to save to Keychain: \(status)"
            case .loadFailed(let status): return "Failed to load from Keychain: \(status)"
            case .deleteFailed(let status): return "Failed to delete from Keychain: \(status)"
            case .notFound: return "Key not found in Keychain"
            case .invalidData: return "Invalid data in Keychain"
            }
        }
    }

    // MARK: - App Lock Passcode

    static func saveAppLockPasscode(
        _ passcode: String,
        synchronizable: Bool = ConnectionsAndSettingsICloudSyncSettings.isEnabled()
    ) throws {
        guard AppLockPasscodePolicy.isValid(passcode) else {
            throw KeychainError.invalidData
        }

        let salt = try randomBytes(count: appLockPasscodeSaltLength)
        let verifier = AppLockPasscodeVerifier(
            version: appLockPasscodeVersion,
            iterations: appLockPasscodeIterations,
            salt: salt,
            digest: appLockPasscodeDigest(passcode: passcode, salt: salt, iterations: appLockPasscodeIterations)
        )
        let data = try JSONEncoder().encode(verifier)

        try saveAppLockPasscodeVerifierData(data, synchronizable: synchronizable)
    }

    static func setAppLockPasscodeSynchronizable(_ synchronizable: Bool) throws {
        let preferredScope: KeychainSynchronizableScope = synchronizable ? .localOnly : .syncedOnly
        let fallbackScope: KeychainSynchronizableScope = synchronizable ? .syncedOnly : .localOnly
        guard let data = loadAppLockPasscodeVerifierData(scope: preferredScope)
            ?? loadAppLockPasscodeVerifierData(scope: fallbackScope) else {
            return
        }

        try saveAppLockPasscodeVerifierData(data, synchronizable: synchronizable, deleteScope: .any)
    }

    static func copyAppLockPasscodeToLocal() throws {
        guard let data = loadAppLockPasscodeVerifierData(scope: .any) else { return }
        try saveAppLockPasscodeVerifierData(data, synchronizable: false, deleteScope: .localOnly)
    }

    static func deleteSyncedAppLockPasscode() {
        SecItemDelete(appLockPasscodeQuery(scope: .syncedOnly) as CFDictionary)
    }

    private static func saveAppLockPasscodeVerifierData(
        _ data: Data,
        synchronizable: Bool,
        deleteScope: KeychainSynchronizableScope = .effective
    ) throws {
        SecItemDelete(appLockPasscodeQuery(scope: deleteScope) as CFDictionary)

        var query = appLockPasscodeQuery(scope: synchronizable ? .syncedOnly : .localOnly)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = synchronizable
            ? kSecAttrAccessibleWhenUnlocked
            : kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    static func hasAppLockPasscode() -> Bool {
        loadAppLockPasscodeVerifier() != nil
    }

    static func verifyAppLockPasscode(_ passcode: String) -> Bool {
        guard let verifier = loadAppLockPasscodeVerifier() else {
            return false
        }
        // Only the current PBKDF2 format is accepted; anything else fails closed
        // (the user re-sets their passcode) rather than being verified with a
        // weaker/legacy scheme.
        guard verifier.version == appLockPasscodeVersion else {
            return false
        }

        let digest = appLockPasscodeDigest(
            passcode: passcode,
            salt: verifier.salt,
            iterations: verifier.iterations
        )
        return !digest.isEmpty && constantTimeEqual(digest, verifier.digest)
    }

    static func deleteAppLockPasscode() {
        SecItemDelete(appLockPasscodeQuery(scope: .effective) as CFDictionary)
    }

    // MARK: - Private Key Storage

    /// Save a private key to the Keychain using the current credential sync mode.
    static func savePrivateKey(
        _ keyData: Data,
        forKeyId keyId: UUID,
        synchronizable: Bool = CredentialICloudSyncSettings.isEnabledForCurrentDevice()
    ) throws {
        try savePrivateKeyData(keyData, forKeyId: keyId, synchronizable: synchronizable)
    }

    private static func savePrivateKeyData(
        _ keyData: Data,
        forKeyId keyId: UUID,
        synchronizable: Bool,
        deleteScope: KeychainSynchronizableScope = .effective
    ) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keyServiceName,
            kSecAttrAccount as String: keyId.uuidString,
            kSecValueData as String: keyData,
            kSecAttrSynchronizable as String: (synchronizable ? kCFBooleanTrue : kCFBooleanFalse) as Any,
            kSecAttrAccessible as String: synchronizable
                ? kSecAttrAccessibleWhenUnlocked
                : kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        SecItemDelete(baseQuery(service: keyServiceName, account: keyId.uuidString, scope: deleteScope) as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    /// Save non-exportable Secure Enclave key representation as a device-local item.
    static func saveDevicePrivateKey(_ keyData: Data, forKeyId keyId: UUID) throws {
        try savePrivateKey(keyData, forKeyId: keyId, synchronizable: false)
    }

    /// Load a private key from the Keychain.
    static func loadPrivateKey(forKeyId keyId: UUID) throws -> Data {
        var query = baseQuery(service: keyServiceName, account: keyId.uuidString, scope: .effective)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                throw KeychainError.notFound
            }
            throw KeychainError.loadFailed(status)
        }

        guard let data = result as? Data else {
            throw KeychainError.invalidData
        }

        return data
    }

    /// Delete a private key from the Keychain.
    static func deletePrivateKey(forKeyId keyId: UUID) throws {
        let status = SecItemDelete(
            baseQuery(service: keyServiceName, account: keyId.uuidString, scope: .effective) as CFDictionary
        )
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    /// List all stored key IDs.
    static func listStoredKeyIds() -> [UUID] {
        listStoredKeyIds(scope: .effective)
    }

    private static func listStoredKeyIds(scope: KeychainSynchronizableScope) -> [UUID] {
        var query = baseQuery(service: keyServiceName, scope: scope)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let items = result as? [[String: Any]] else {
            return []
        }

        return items.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String else {
                return nil
            }
            return UUID(uuidString: account)
        }
    }

    // MARK: - Connection Password Storage

    /// Save a connection password to the Keychain, keyed by the connection's UUID.
    static func savePassword(
        _ password: String,
        forConnectionId connectionId: UUID,
        synchronizable: Bool = CredentialICloudSyncSettings.isEnabledForCurrentDevice()
    ) throws {
        guard let data = password.data(using: .utf8) else {
            throw KeychainError.invalidData
        }
        try savePasswordData(data, forConnectionId: connectionId, synchronizable: synchronizable)
    }

    private static func savePasswordData(
        _ data: Data,
        forConnectionId connectionId: UUID,
        synchronizable: Bool,
        deleteScope: KeychainSynchronizableScope = .effective
    ) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: passwordServiceName,
            kSecAttrAccount as String: connectionId.uuidString,
            kSecValueData as String: data,
            kSecAttrSynchronizable as String: (synchronizable ? kCFBooleanTrue : kCFBooleanFalse) as Any,
            kSecAttrAccessible as String: synchronizable
                ? kSecAttrAccessibleWhenUnlocked
                : kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        SecItemDelete(
            baseQuery(service: passwordServiceName, account: connectionId.uuidString, scope: deleteScope) as CFDictionary
        )

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    /// Load a stored connection password, if present.
    static func loadPassword(forConnectionId connectionId: UUID) -> String? {
        guard let data = loadPasswordData(forConnectionId: connectionId, scope: .effective) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func loadPasswordData(forConnectionId connectionId: UUID, scope: KeychainSynchronizableScope) -> Data? {
        var query = baseQuery(service: passwordServiceName, account: connectionId.uuidString, scope: scope)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return data
    }

    /// Return whether a stored connection password exists without returning it.
    static func hasPassword(forConnectionId connectionId: UUID) -> Bool {
        var query = baseQuery(service: passwordServiceName, account: connectionId.uuidString, scope: .effective)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    /// Delete a stored connection password. No-op if absent.
    static func deletePassword(forConnectionId connectionId: UUID) {
        SecItemDelete(
            baseQuery(service: passwordServiceName, account: connectionId.uuidString, scope: .effective) as CFDictionary
        )
    }

    /// Return whether any saved password or SSH private key exists.
    static func hasStoredCredentials() -> Bool {
        !listStoredKeyIds().isEmpty || hasStoredPasswords()
    }

    static func setPrivateKeysSynchronizable(_ synchronizable: Bool, forKeyIds keyIds: [UUID]) throws {
        let preferredScope: KeychainSynchronizableScope = synchronizable ? .localOnly : .syncedOnly
        let fallbackScope: KeychainSynchronizableScope = synchronizable ? .syncedOnly : .localOnly
        for keyId in keyIds {
            guard let keyData = loadPrivateKeyData(forKeyId: keyId, scope: preferredScope)
                ?? loadPrivateKeyData(forKeyId: keyId, scope: fallbackScope) else {
                continue
            }

            try savePrivateKeyData(
                keyData,
                forKeyId: keyId,
                synchronizable: synchronizable,
                deleteScope: .any
            )
        }
    }

    static func copyPrivateKeysToLocal(forKeyIds keyIds: [UUID]) throws {
        for keyId in keyIds {
            guard let keyData = loadPrivateKeyData(forKeyId: keyId, scope: .syncedOnly)
                ?? loadPrivateKeyData(forKeyId: keyId, scope: .localOnly) else {
                continue
            }
            try savePrivateKeyData(
                keyData,
                forKeyId: keyId,
                synchronizable: false,
                deleteScope: .localOnly
            )
        }
    }

    static func deleteLocalPrivateKeys(forKeyIds keyIds: [UUID]) throws {
        try deletePrivateKeys(forKeyIds: keyIds, scope: .localOnly)
    }

    static func deleteSyncedPrivateKeys() {
        SecItemDelete(baseQuery(service: keyServiceName, scope: .syncedOnly) as CFDictionary)
    }

    private static func deletePrivateKeys(
        forKeyIds keyIds: [UUID],
        scope: KeychainSynchronizableScope
    ) throws {
        for keyId in keyIds {
            let status = SecItemDelete(
                baseQuery(service: keyServiceName, account: keyId.uuidString, scope: scope) as CFDictionary
            )
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError.deleteFailed(status)
            }
        }
    }

    static func setStoredPasswordsSynchronizable(_ synchronizable: Bool) throws {
        let preferredScope: KeychainSynchronizableScope = synchronizable ? .localOnly : .syncedOnly
        let fallbackScope: KeychainSynchronizableScope = synchronizable ? .syncedOnly : .localOnly
        for connectionId in listStoredPasswordConnectionIds(scope: .any) {
            guard let data = loadPasswordData(forConnectionId: connectionId, scope: preferredScope)
                ?? loadPasswordData(forConnectionId: connectionId, scope: fallbackScope) else {
                continue
            }

            try savePasswordData(
                data,
                forConnectionId: connectionId,
                synchronizable: synchronizable,
                deleteScope: .any
            )
        }
    }

    static func copyStoredPasswordsToLocal() throws {
        for connectionId in listStoredPasswordConnectionIds(scope: .any) {
            guard let data = loadPasswordData(forConnectionId: connectionId, scope: .syncedOnly)
                ?? loadPasswordData(forConnectionId: connectionId, scope: .localOnly) else {
                continue
            }
            try savePasswordData(
                data,
                forConnectionId: connectionId,
                synchronizable: false,
                deleteScope: .localOnly
            )
        }
    }

    static func deleteLocalStoredPasswords() {
        SecItemDelete(baseQuery(service: passwordServiceName, scope: .localOnly) as CFDictionary)
    }

    static func deleteSyncedStoredPasswords() {
        SecItemDelete(baseQuery(service: passwordServiceName, scope: .syncedOnly) as CFDictionary)
    }

    // MARK: - Query Helpers

    private enum KeychainSynchronizableScope {
        case effective
        case any
        case localOnly
        case syncedOnly
    }

    /// Base query scoped to a service (and optionally one account) that
    /// applies the intended synchronizable lookup scope. Lookup helpers layer
    /// their return/match keys on top.
    private static func baseQuery(
        service: String,
        account: String? = nil,
        scope: KeychainSynchronizableScope
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: synchronizableQueryValue(for: scope)
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        return query
    }

    private static func synchronizableQueryValue(for scope: KeychainSynchronizableScope) -> Any {
        switch scope {
        case .effective:
            if CredentialICloudSyncSettings.isEnabledForCurrentDevice() {
                return kSecAttrSynchronizableAny
            }
            return kCFBooleanFalse as Any
        case .any:
            return kSecAttrSynchronizableAny
        case .localOnly:
            return kCFBooleanFalse as Any
        case .syncedOnly:
            return kCFBooleanTrue as Any
        }
    }

    private static func loadPrivateKeyData(forKeyId keyId: UUID, scope: KeychainSynchronizableScope) -> Data? {
        var query = baseQuery(service: keyServiceName, account: keyId.uuidString, scope: scope)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return data
    }

    private static func hasStoredPasswords() -> Bool {
        var query = baseQuery(service: passwordServiceName, scope: .effective)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    private static func listStoredPasswordConnectionIds(scope: KeychainSynchronizableScope) -> [UUID] {
        var query = baseQuery(service: passwordServiceName, scope: scope)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let items = result as? [[String: Any]] else {
            return []
        }

        return items.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String else {
                return nil
            }
            return UUID(uuidString: account)
        }
    }

    private static func appLockPasscodeQuery(scope: KeychainSynchronizableScope) -> [String: Any] {
        let synchronizable: Any
        switch scope {
        case .effective:
            synchronizable = ConnectionsAndSettingsICloudSyncSettings.isEnabled()
                ? kSecAttrSynchronizableAny
                : kCFBooleanFalse as Any
        case .any, .localOnly, .syncedOnly:
            synchronizable = synchronizableQueryValue(for: scope)
        }

        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: appLockServiceName,
            kSecAttrAccount as String: appLockPasscodeAccount,
            kSecAttrSynchronizable as String: synchronizable
        ]
    }

    private static func loadAppLockPasscodeVerifier() -> AppLockPasscodeVerifier? {
        guard let data = loadAppLockPasscodeVerifierData(scope: .effective) else {
            return nil
        }

        return try? JSONDecoder().decode(AppLockPasscodeVerifier.self, from: data)
    }

    private static func loadAppLockPasscodeVerifierData(scope: KeychainSynchronizableScope) -> Data? {
        var query = appLockPasscodeQuery(scope: scope)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }

        return data
    }

    /// Derive the app-lock verifier with PBKDF2-HMAC-SHA256. Returns an empty
    /// `Data` on the (essentially impossible) derivation failure so callers fail
    /// closed rather than matching a predictable value.
    private static func appLockPasscodeDigest(passcode: String, salt: Data, iterations: Int) -> Data {
        let password = [UInt8](passcode.utf8)
        let saltBytes = [UInt8](salt)
        var derived = [UInt8](repeating: 0, count: appLockPasscodeDigestLength)

        let status = derived.withUnsafeMutableBufferPointer { derivedPtr in
            password.withUnsafeBufferPointer { passwordPtr in
                saltBytes.withUnsafeBufferPointer { saltPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordPtr.baseAddress, password.count,
                        saltPtr.baseAddress, saltBytes.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        derivedPtr.baseAddress, derivedPtr.count
                    )
                }
            }
        }

        return status == kCCSuccess ? Data(derived) : Data()
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else {
            return false
        }

        var diff: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            diff |= left ^ right
        }
        return diff == 0
    }

    private static func randomBytes(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
        return Data(bytes)
    }
}

enum AppLockPasscodePolicy {
    /// Minimum app-lock passcode length. Combined with the PBKDF2 verifier this
    /// keeps a trivially short passcode (e.g. a single character) from being
    /// accepted while still allowing a short PIN.
    static let minimumLength = 4

    static func isValid(_ passcode: String) -> Bool {
        passcode.count >= minimumLength
    }

    static func validationMessage(passcode: String) -> String? {
        if passcode.isEmpty {
            return "Enter an app passcode."
        }
        if passcode.count < minimumLength {
            return "Use at least \(minimumLength) characters."
        }
        return nil
    }
}

private struct AppLockPasscodeVerifier: Codable {
    let version: Int
    let iterations: Int
    let salt: Data
    let digest: Data
}

enum CredentialAuthorizationResult: Equatable, Sendable {
    case authorized
    case denied(String)

    var isAuthorized: Bool {
        self == .authorized
    }

    var message: String? {
        guard case .denied(let message) = self else {
            return nil
        }
        return message
    }
}

enum BiometricCredentialAuthorizer {
    static func biometricAvailability() -> CredentialBiometricAvailability {
        let context = LAContext()
        var error: NSError?
        let canEvaluateBiometrics = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)

        return biometricAvailability(
            canEvaluatePolicy: canEvaluateBiometrics,
            biometryType: context.biometryType,
            error: error
        )
    }

    static func biometricAvailability(
        canEvaluatePolicy: Bool,
        biometryType: LABiometryType,
        error: NSError?
    ) -> CredentialBiometricAvailability {
        if canEvaluatePolicy {
            return .available
        }

        if biometryType == .none {
            return .notAvailable
        }

        return availability(from: error)
    }

    static func deviceOwnerAuthenticationAvailability() -> CredentialDeviceOwnerAuthenticationAvailability {
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            return .available
        }

        guard let error else {
            return .unknown
        }

        switch LAError.Code(rawValue: error.code) {
        case .passcodeNotSet:
            return .passcodeNotSet
        case .biometryNotAvailable:
            return .unavailable
        default:
            return .unknown
        }
    }

    static func authorizeStoredCredentialUse(
        reason: String,
        allowsPasscodeFallback: Bool = CredentialProtectionSettings.isPasscodeFallbackEnabled()
    ) async -> CredentialAuthorizationResult {
        let policy: LAPolicy = allowsPasscodeFallback
            ? .deviceOwnerAuthentication
            : .deviceOwnerAuthenticationWithBiometrics
        let unavailableMessage = allowsPasscodeFallback
            ? "Device authentication is required to use saved SSH credentials."
            : "Face ID or Touch ID is required to use saved SSH credentials."

        return await authorize(
            policy: policy,
            reason: reason,
            unavailableMessage: unavailableMessage
        )
    }

    static func authorizeSettingsChangeWithBiometrics(reason: String) async -> CredentialAuthorizationResult {
        await authorize(
            policy: .deviceOwnerAuthenticationWithBiometrics,
            reason: reason,
            unavailableMessage: "Face ID or Touch ID is required to change this setting."
        )
    }

    static func authorizeSettingsChangeWithDeviceOwner(reason: String) async -> CredentialAuthorizationResult {
        await authorize(
            policy: .deviceOwnerAuthentication,
            reason: reason,
            unavailableMessage: "Device authentication is required to change this setting."
        )
    }

    private static func authorize(
        policy: LAPolicy,
        reason: String,
        unavailableMessage: String
    ) async -> CredentialAuthorizationResult {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"

        var error: NSError?
        guard context.canEvaluatePolicy(policy, error: &error) else {
            return .denied(message(for: error) ?? unavailableMessage)
        }

        do {
            return try await context.evaluatePolicy(policy, localizedReason: reason)
                ? .authorized
                : .denied(unavailableMessage)
        } catch {
            return .denied(message(for: error as NSError) ?? unavailableMessage)
        }
    }

    private static func availability(from error: NSError?) -> CredentialBiometricAvailability {
        guard let error else {
            return .unknown
        }

        switch LAError.Code(rawValue: error.code) {
        case .biometryLockout:
            return .lockedOut
        case .biometryNotEnrolled:
            return .notEnrolled
        case .biometryNotAvailable:
            return .notAvailable
        case .passcodeNotSet:
            return .passcodeNotSet
        default:
            return .unknown
        }
    }

    private static func message(for error: NSError?) -> String? {
        guard let error else {
            return nil
        }

        switch LAError.Code(rawValue: error.code) {
        case .userCancel, .appCancel, .systemCancel:
            return "Authentication was canceled."
        case .authenticationFailed:
            return "Authentication failed."
        case .biometryLockout:
            return "Face ID or Touch ID is locked."
        case .biometryNotEnrolled:
            return "Face ID or Touch ID is not set up."
        case .biometryNotAvailable:
            return "Face ID or Touch ID is not available."
        case .passcodeNotSet:
            return "A device passcode is not set."
        default:
            return error.localizedDescription
        }
    }
}
