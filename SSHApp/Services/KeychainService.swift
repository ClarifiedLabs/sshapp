import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Service for securely storing SSH keys and connection passwords in the iOS Keychain.
///
/// iCloud Ed25519 private keys and remembered passwords are stored as
/// synchronizable (`kSecAttrSynchronizable`) `WhenUnlocked` items so they sync
/// across the user's Apple devices via iCloud Keychain. Device-local key
/// material uses `WhenUnlockedThisDeviceOnly`. Reads/deletes/lists use
/// `kSecAttrSynchronizableAny` so both synced and device-local items resolve.
enum KeychainService {
    /// Current key-item service name.
    private static let keyServiceName = "dev.sshapp.sshapp.keys"
    /// Password-item service name, namespaced apart from keys.
    private static let passwordServiceName = "dev.sshapp.sshapp.passwords"
    /// Device-local app lock passcode verifier.
    private static let appLockServiceName = "dev.sshapp.sshapp.appLock"
    private static let appLockPasscodeAccount = "passcode"
    private static let appLockPasscodeIterations = 50_000
    private static let appLockPasscodeSaltLength = 32

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

    static func saveAppLockPasscode(_ passcode: String) throws {
        guard AppLockPasscodePolicy.isValid(passcode) else {
            throw KeychainError.invalidData
        }

        let salt = try randomBytes(count: appLockPasscodeSaltLength)
        let verifier = AppLockPasscodeVerifier(
            version: 1,
            iterations: appLockPasscodeIterations,
            salt: salt,
            digest: appLockPasscodeDigest(passcode: passcode, salt: salt, iterations: appLockPasscodeIterations)
        )
        let data = try JSONEncoder().encode(verifier)

        SecItemDelete(appLockPasscodeQuery() as CFDictionary)

        var query = appLockPasscodeQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

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

        let digest = appLockPasscodeDigest(
            passcode: passcode,
            salt: verifier.salt,
            iterations: verifier.iterations
        )
        return constantTimeEqual(digest, verifier.digest)
    }

    static func deleteAppLockPasscode() {
        SecItemDelete(appLockPasscodeQuery() as CFDictionary)
    }

    // MARK: - Private Key Storage

    /// Save a private key to the Keychain as a synchronizable item.
    static func savePrivateKey(_ keyData: Data, forKeyId keyId: UUID, synchronizable: Bool = true) throws {
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

        // Delete any existing item first (matches both synced and local).
        SecItemDelete(baseQuery(service: keyServiceName, account: keyId.uuidString) as CFDictionary)

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
        var query = baseQuery(service: keyServiceName, account: keyId.uuidString)
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
        let status = SecItemDelete(baseQuery(service: keyServiceName, account: keyId.uuidString) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    /// List all stored key IDs.
    static func listStoredKeyIds() -> [UUID] {
        var query = baseQuery(service: keyServiceName)
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

    /// Save a connection password to the Keychain as a synchronizable item,
    /// keyed by the connection's UUID.
    static func savePassword(_ password: String, forConnectionId connectionId: UUID) throws {
        guard let data = password.data(using: .utf8) else {
            throw KeychainError.invalidData
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: passwordServiceName,
            kSecAttrAccount as String: connectionId.uuidString,
            kSecValueData as String: data,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        SecItemDelete(baseQuery(service: passwordServiceName, account: connectionId.uuidString) as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    /// Load a stored connection password, if present.
    static func loadPassword(forConnectionId connectionId: UUID) -> String? {
        var query = baseQuery(service: passwordServiceName, account: connectionId.uuidString)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            return nil
        }
        return password
    }

    /// Return whether a stored connection password exists without returning it.
    static func hasPassword(forConnectionId connectionId: UUID) -> Bool {
        var query = baseQuery(service: passwordServiceName, account: connectionId.uuidString)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    /// Delete a stored connection password. No-op if absent.
    static func deletePassword(forConnectionId connectionId: UUID) {
        SecItemDelete(baseQuery(service: passwordServiceName, account: connectionId.uuidString) as CFDictionary)
    }

    /// Return whether any saved password or SSH private key exists.
    static func hasStoredCredentials() -> Bool {
        !listStoredKeyIds().isEmpty || hasStoredPasswords()
    }

    // MARK: - Query Helpers

    /// Base query scoped to a service (and optionally one account) that
    /// matches both synced and device-local items. Used directly for
    /// delete-before-save and explicit deletes; lookup helpers layer their
    /// return/match keys on top.
    private static func baseQuery(service: String, account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        return query
    }

    private static func hasStoredPasswords() -> Bool {
        var query = baseQuery(service: passwordServiceName)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    private static func appLockPasscodeQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: appLockServiceName,
            kSecAttrAccount as String: appLockPasscodeAccount
        ]
    }

    private static func loadAppLockPasscodeVerifier() -> AppLockPasscodeVerifier? {
        var query = appLockPasscodeQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }

        return try? JSONDecoder().decode(AppLockPasscodeVerifier.self, from: data)
    }

    private static func appLockPasscodeDigest(passcode: String, salt: Data, iterations: Int) -> Data {
        var digest = Data(passcode.utf8) + salt
        for _ in 0..<iterations {
            digest = Data(SHA256.hash(data: digest))
        }
        return digest
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
    static func isValid(_ passcode: String) -> Bool {
        !passcode.isEmpty
    }

    static func validationMessage(passcode: String) -> String? {
        guard isValid(passcode) else {
            return "Enter an app passcode."
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
