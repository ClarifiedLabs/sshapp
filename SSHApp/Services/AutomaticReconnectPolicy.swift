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
