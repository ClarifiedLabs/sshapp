import Foundation

struct AuthorizedKeysInstallResult: Equatable, Sendable {
    let selectedCount: Int
    let installedCount: Int
    let existingCount: Int

    var summary: String {
        if installedCount == selectedCount {
            return "\(installedCount) \(Self.keyLabel(installedCount)) installed."
        }

        if installedCount == 0 {
            return "\(existingCount) \(Self.keyLabel(existingCount)) already present."
        }

        return "\(installedCount) \(Self.keyLabel(installedCount)) installed; \(existingCount) already present."
    }

    private static func keyLabel(_ count: Int) -> String {
        count == 1 ? "key" : "keys"
    }
}

enum AuthorizedKeysInstaller {
    enum InstallError: LocalizedError, Equatable {
        case noKeysSelected
        case invalidPublicKey(String)
        case commandFailed(exitStatus: Int32, output: String)
        case missingSummary(String)

        var errorDescription: String? {
            switch self {
            case .noKeysSelected:
                return "Select at least one SSH key."
            case .invalidPublicKey(let name):
                return "The public key for '\(name)' is not valid."
            case .commandFailed(let exitStatus, let output):
                let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmedOutput.isEmpty {
                    return "The remote install command failed with exit status \(exitStatus)."
                }
                return trimmedOutput
            case .missingSummary:
                return "The remote install command completed but did not return a result."
            }
        }
    }

    @MainActor
    static func install(keys: [SSHKey], using session: SSHSession) async throws -> AuthorizedKeysInstallResult {
        let command = try makeInstallCommand(keys: keys)
        let result = try await session.executeCommand(command, timeout: 30)
        let combinedOutput = result.combinedOutputString

        guard result.exitStatus == 0 else {
            throw InstallError.commandFailed(exitStatus: result.exitStatus, output: combinedOutput)
        }

        return try parseInstallSummary(from: combinedOutput, selectedCount: keys.count)
    }

    static func makeInstallCommand(keys: [SSHKey]) throws -> String {
        let publicKeyLines = try validatedPublicKeyLines(from: keys)
        let payload = publicKeyLines.joined(separator: "\n")
        let delimiter = heredocDelimiter(avoiding: payload)

        // Remote file handling mirrors the OpenSSH ssh-copy-id installkeys_sh
        // path: https://github.com/openssh/openssh-portable/blob/a5ecfdc21864b29ef9a939b9cfe7a2a8ffcdf439/contrib/ssh-copy-id#L280-L313
        let script = """
        umask 077
        cd || exit 1
        AUTH_KEY_FILE=".ssh/authorized_keys"
        if [ -f /etc/openwrt_release ] && { [ "$LOGNAME" = "root" ] || [ "$(id -u)" = "0" ]; }; then
            AUTH_KEY_FILE=/etc/dropbear/authorized_keys
        fi
        if [ "$(uname -s)" = "Haiku" ]; then
            AUTH_KEY_FILE=config/settings/ssh/authorized_keys
        fi
        AUTH_KEY_DIR=$(dirname "$AUTH_KEY_FILE")
        mkdir -p "$AUTH_KEY_DIR" || exit 1
        : >> "$AUTH_KEY_FILE" || exit 1
        chmod 700 "$AUTH_KEY_DIR" 2>/dev/null || true
        chmod 600 "$AUTH_KEY_FILE" 2>/dev/null || true
        if [ -z "$(tail -1c "$AUTH_KEY_FILE" 2>/dev/null)" ]; then
            :
        else
            echo >> "$AUTH_KEY_FILE" || exit 1
        fi
        installed=0
        existing=0
        invalid=0
        while IFS= read -r key || [ -n "$key" ]; do
            [ -n "$key" ] || continue
            key_id=$(printf '%s\\n' "$key" | awk '{print $1 " " $2}')
            if [ -z "$key_id" ] || [ "$key_id" = " " ]; then
                invalid=$((invalid + 1))
                continue
            fi
            if awk -v key_id="$key_id" '
                {
                    for (i = 1; i < NF; i++) {
                        if ($i " " $(i + 1) == key_id) {
                            found = 1
                        }
                    }
                }
                END { exit found ? 0 : 1 }
            ' "$AUTH_KEY_FILE"; then
                existing=$((existing + 1))
            else
                printf '%s\\n' "$key" >> "$AUTH_KEY_FILE" || exit 1
                installed=$((installed + 1))
            fi
        done <<'\(delimiter)'
        \(payload)
        \(delimiter)
        if type restorecon >/dev/null 2>&1; then
            restorecon -F "$AUTH_KEY_DIR" "$AUTH_KEY_FILE"
        fi
        printf 'sshapp-installed=%s existing=%s invalid=%s\\n' "$installed" "$existing" "$invalid"
        [ "$invalid" -eq 0 ]
        """

        return "exec sh -c \(shellSingleQuoted(script))"
    }

    static func parseInstallSummary(from output: String, selectedCount: Int) throws -> AuthorizedKeysInstallResult {
        var installedCount: Int?
        var existingCount: Int?
        var invalidCount: Int?

        for token in output.split(whereSeparator: \.isWhitespace) {
            if token.hasPrefix("sshapp-installed=") {
                installedCount = Int(token.dropFirst("sshapp-installed=".count))
            } else if token.hasPrefix("existing=") {
                existingCount = Int(token.dropFirst("existing=".count))
            } else if token.hasPrefix("invalid=") {
                invalidCount = Int(token.dropFirst("invalid=".count))
            }
        }

        guard let installedCount, let existingCount, let invalidCount else {
            throw InstallError.missingSummary(output)
        }

        guard invalidCount == 0 else {
            throw InstallError.commandFailed(exitStatus: 1, output: output)
        }

        return AuthorizedKeysInstallResult(
            selectedCount: selectedCount,
            installedCount: installedCount,
            existingCount: existingCount
        )
    }

    private static func validatedPublicKeyLines(from keys: [SSHKey]) throws -> [String] {
        guard !keys.isEmpty else {
            throw InstallError.noKeysSelected
        }

        return try keys.map { key in
            let publicKey = key.publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !publicKey.isEmpty,
                  !publicKey.contains(where: { $0 == "\n" || $0 == "\r" }) else {
                throw InstallError.invalidPublicKey(key.name)
            }

            do {
                _ = try SSHKeyGenerator.publicKeyBlob(fromOpenSSHPublicKey: publicKey)
                return publicKey
            } catch {
                throw InstallError.invalidPublicKey(key.name)
            }
        }
    }

    private static func heredocDelimiter(avoiding payload: String) -> String {
        var suffix = 0
        while true {
            let delimiter = "__SSHAPP_AUTHORIZED_KEYS_\(suffix)__"
            if !payload.contains(delimiter) {
                return delimiter
            }
            suffix += 1
        }
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
