/// Credentials newly typed during a login that are candidates for saving.
/// A field is non-nil only when the user typed it this session and it is not
/// already persisted.
struct CredentialSaveOffer: Equatable {
    /// Newly-typed username; nil if the username was already saved or not typed.
    var username: String?
    /// Newly-typed password that just authenticated; nil if none was typed
    /// (key auth, stored password, or multi-prompt keyboard-interactive).
    var password: String?
}

/// The user's choices from the combined save-credentials dialog.
struct CredentialSaveDecision: Equatable {
    var saveUsername: Bool
    var savePassword: Bool
    var neverAskUsername: Bool
    var neverAskPassword: Bool

    static let declined = CredentialSaveDecision(
        saveUsername: false,
        savePassword: false,
        neverAskUsername: false,
        neverAskPassword: false
    )

    /// Decision for the dialog's Save button given the toggle states.
    static func saving(username: Bool, password: Bool) -> CredentialSaveDecision {
        CredentialSaveDecision(
            saveUsername: username,
            savePassword: password,
            neverAskUsername: false,
            neverAskPassword: false
        )
    }

    /// Decision for the dialog's Don't Ask Again button: suppress future
    /// prompts for whichever rows were on offer; save nothing.
    static func neverAsking(rows: CredentialSaveRows) -> CredentialSaveDecision {
        CredentialSaveDecision(
            saveUsername: false,
            savePassword: false,
            neverAskUsername: rows.showUsernameRow,
            neverAskPassword: rows.showPasswordRow
        )
    }
}

/// Which rows the combined save-credentials dialog should present.
struct CredentialSaveRows: Equatable {
    var showUsernameRow: Bool
    var showPasswordRow: Bool
    /// True when no username is saved yet, so the password toggle is gated on
    /// the username toggle being checked.
    var passwordDependsOnUsername: Bool

    var isEmpty: Bool { !showUsernameRow && !showPasswordRow }
}

/// Pure decision logic for when to offer saving credentials and when to
/// confirm sending saved credentials, kept free of UI/session state so it
/// can be unit tested.
enum CredentialSavePolicy {
    /// Which rows to offer in the combined post-auth save dialog. A password
    /// is only meaningful with a username to associate it with — one saved
    /// already, or one being offered in the same dialog.
    static func rowsToOffer(
        offer: CredentialSaveOffer,
        hasSavedUsername: Bool,
        neverAskUsername: Bool,
        neverAskPassword: Bool
    ) -> CredentialSaveRows {
        let showUsername = offer.username != nil && !neverAskUsername
        let usernameWillExist = hasSavedUsername || showUsername
        let showPassword = offer.password != nil && !neverAskPassword && usernameWillExist
        return CredentialSaveRows(
            showUsernameRow: showUsername,
            showPasswordRow: showPassword,
            passwordDependsOnUsername: showPassword && !hasSavedUsername
        )
    }

    /// When the user saves the username but declines the offered password,
    /// suppress future password prompts for this connection.
    static func shouldSuppressFuturePassword(
        rows: CredentialSaveRows,
        decision: CredentialSaveDecision
    ) -> Bool {
        rows.showPasswordRow && decision.saveUsername && !decision.savePassword
            && !decision.neverAskPassword
    }

    /// Whether a keyboard-interactive prompt round is a plain password prompt:
    /// exactly one prompt with echo off (the shape PAM uses for password-only
    /// auth). Multi-prompt rounds (e.g. password + OTP) never qualify, so 2FA
    /// responses are never captured or auto-filled as passwords.
    static func isLonePasswordPrompt(_ prompts: [(text: String, echo: Bool)]) -> Bool {
        prompts.count == 1 && !prompts[0].echo
    }

    /// Whether to ask the user to confirm sending saved credentials after the
    /// host's key fingerprint changed. Only worth asking when something saved
    /// (username, SSH key, or stored password) would otherwise be sent.
    static func shouldConfirmSavedCredentials(
        hostKeyChanged: Bool,
        hasSavedUsername: Bool,
        hasKey: Bool,
        hasStoredPassword: Bool
    ) -> Bool {
        hostKeyChanged && (hasSavedUsername || hasKey || hasStoredPassword)
    }
}
