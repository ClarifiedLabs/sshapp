import Foundation

// Shared by SSHAppUITests (live SSH harness) and SSHAppTests (pure regression
// coverage). Keep this file free of XCUIApplication/device access.

/// Text classification the live SSH harness applies to the connection pill
/// and to OCR'd terminal screens.
enum LiveSSHAuthenticationText {
    static func authenticationIsComplete(connectionPillValue: String?) -> Bool {
        connectionPillValue?.caseInsensitiveCompare("Connected") == .orderedSame
    }

    /// Matches real OpenSSH password prompts by line shape instead of a raw
    /// "PASSWORD" substring, so login banners or authentication-failure text
    /// cannot trick the harness into typing the password at a shell prompt
    /// where it would echo into screenshots.
    ///
    /// The tail allows up to two trailing characters because OCR reads the
    /// terminal's block cursor sitting after the prompt as a glyph (for
    /// example `Password: |`).
    ///
    /// Deliberate tradeoff: a stale prompt scrolled up in the terminal
    /// history can still match. That is safe because the `submittedPassword`
    /// one-shot guard in `completeAuthentication` prevents resubmission.
    static func isPasswordPrompt(screenText: String) -> Bool {
        screenText.split(whereSeparator: \.isNewline).contains { line in
            line.trimmingCharacters(in: .whitespaces)
                .range(
                    of: #"password\s*:.{0,2}$"#,
                    options: [.regularExpression, .caseInsensitive]
                ) != nil
        }
    }
}
