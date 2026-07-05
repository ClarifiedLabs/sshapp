import Foundation

enum AutomaticReconnectPolicy {
    static func hasSavedUsername(_ username: String?) -> Bool {
        username?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    static func isEligible(
        username: String?,
        hasStoredPassword: Bool,
        hasUsableKey: Bool
    ) -> Bool {
        hasSavedUsername(username) && (hasStoredPassword || hasUsableKey)
    }

    @MainActor
    static func hasUsableKey(for connection: SavedConnection, keyStore: KeyStore) -> Bool {
        connection.sshKeyId.flatMap { keyStore.key(withId: $0) } != nil
    }

    @MainActor
    static func isEligible(
        for connection: SavedConnection,
        keyStore: KeyStore,
        hasStoredPasswordOverride: Bool? = nil,
        hasUsableKeyOverride: Bool? = nil
    ) -> Bool {
        isEligible(
            username: connection.username,
            hasStoredPassword: hasStoredPasswordOverride ?? KeychainService.hasPassword(forConnectionId: connection.id),
            hasUsableKey: hasUsableKeyOverride ?? hasUsableKey(for: connection, keyStore: keyStore)
        )
    }

    static func normalizedEnabled(
        _ requested: Bool,
        username: String?,
        hasStoredPassword: Bool,
        hasUsableKey: Bool
    ) -> Bool {
        requested && isEligible(
            username: username,
            hasStoredPassword: hasStoredPassword,
            hasUsableKey: hasUsableKey
        )
    }

    @MainActor
    static func normalizedEnabled(
        for connection: SavedConnection,
        keyStore: KeyStore,
        hasStoredPasswordOverride: Bool? = nil,
        hasUsableKeyOverride: Bool? = nil
    ) -> Bool {
        normalizedEnabled(
            connection.autoReconnectOnBackgroundDisconnect,
            username: connection.username,
            hasStoredPassword: hasStoredPasswordOverride ?? KeychainService.hasPassword(forConnectionId: connection.id),
            hasUsableKey: hasUsableKeyOverride ?? hasUsableKey(for: connection, keyStore: keyStore)
        )
    }

    static func unavailableReason(
        username: String?,
        hasStoredPassword: Bool,
        hasUsableKey: Bool
    ) -> String? {
        guard !isEligible(
            username: username,
            hasStoredPassword: hasStoredPassword,
            hasUsableKey: hasUsableKey
        ) else {
            return nil
        }

        if !hasSavedUsername(username) {
            return "Automatic reconnect requires a saved username."
        }

        return "Automatic reconnect requires a saved password or SSH key."
    }
}
