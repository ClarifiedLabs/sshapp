import Foundation
private import CSSH2

/// Result of checking a host key against the known_hosts file
enum HostKeyStatus {
    case match
    case mismatch(oldFingerprint: String, newFingerprint: String)
    case notFound(fingerprint: String, keyType: String)
}

/// Manages host key verification using libssh2's knownhost API.
/// Stores the known_hosts file in the app's documents directory.
final class KnownHostsManager: @unchecked Sendable {
    private let filePath: String

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.filePath = docs.appendingPathComponent("known_hosts").path
    }

    /// Check the server's host key against the known_hosts file.
    /// Must be called from SSH2Transport's serial queue (takes a raw LIBSSH2_SESSION*).
    func check(
        session: OpaquePointer,
        host: String,
        port: Int,
        keyData: Data,
        fingerprint: String,
        keyType: String
    ) -> HostKeyStatus {
        guard let kh = libssh2_knownhost_init(session) else {
            // Can't initialize — treat as not found so user gets prompted
            return .notFound(fingerprint: fingerprint, keyType: keyType)
        }
        defer { libssh2_knownhost_free(kh) }

        // Load existing known_hosts file (ignore errors — file may not exist yet)
        libssh2_knownhost_readfile(kh, filePath, LIBSSH2_KNOWNHOST_FILE_OPENSSH)

        // Check the key
        var store: UnsafeMutablePointer<libssh2_knownhost>? = nil
        let typeMask = LIBSSH2_KNOWNHOST_TYPE_PLAIN | LIBSSH2_KNOWNHOST_KEYENC_RAW

        let result = keyData.withUnsafeBytes { rawBuf in
            libssh2_knownhost_checkp(
                kh,
                host,
                Int32(port),
                rawBuf.baseAddress?.assumingMemoryBound(to: CChar.self),
                keyData.count,
                Int32(typeMask),
                &store
            )
        }

        switch result {
        case LIBSSH2_KNOWNHOST_CHECK_MATCH:
            return .match

        case LIBSSH2_KNOWNHOST_CHECK_MISMATCH:
            // Get the old key's fingerprint from the stored entry
            let oldFP: String
            if let store, let keyPtr = store.pointee.key {
                oldFP = String(cString: keyPtr)
            } else {
                oldFP = "(unknown)"
            }
            return .mismatch(oldFingerprint: oldFP, newFingerprint: fingerprint)

        default:
            // NOTFOUND or FAILURE
            return .notFound(fingerprint: fingerprint, keyType: keyType)
        }
    }

    /// Add the current server's host key to the known_hosts file.
    func addHost(
        session: OpaquePointer,
        host: String,
        port: Int,
        keyData: Data,
        keyType: String
    ) {
        guard let kh = libssh2_knownhost_init(session) else { return }
        defer { libssh2_knownhost_free(kh) }

        // Load existing file first (so we append, not overwrite)
        libssh2_knownhost_readfile(kh, filePath, LIBSSH2_KNOWNHOST_FILE_OPENSSH)

        let typeMask = LIBSSH2_KNOWNHOST_TYPE_PLAIN |
                       LIBSSH2_KNOWNHOST_KEYENC_RAW |
                       knownHostKeyBit(for: keyType)

        // Add the new host key
        keyData.withUnsafeBytes { rawBuf in
            _ = libssh2_knownhost_addc(
                kh,
                host,
                nil,  // salt (not used for plain type)
                rawBuf.baseAddress?.assumingMemoryBound(to: CChar.self),
                keyData.count,
                nil, 0,  // comment
                Int32(typeMask),
                nil  // store pointer (don't need it)
            )
        }

        // Write back to file
        libssh2_knownhost_writefile(kh, filePath, LIBSSH2_KNOWNHOST_FILE_OPENSSH)
    }

    /// Map key type string to libssh2 knownhost key type bit
    private func knownHostKeyBit(for keyType: String) -> Int32 {
        switch keyType {
        case "ssh-rsa": return LIBSSH2_KNOWNHOST_KEY_SSHRSA
        case "ssh-dss": return LIBSSH2_KNOWNHOST_KEY_SSHDSS
        case "ecdsa-sha2-nistp256": return LIBSSH2_KNOWNHOST_KEY_ECDSA_256
        case "ecdsa-sha2-nistp384": return LIBSSH2_KNOWNHOST_KEY_ECDSA_384
        case "ecdsa-sha2-nistp521": return LIBSSH2_KNOWNHOST_KEY_ECDSA_521
        case "ssh-ed25519": return LIBSSH2_KNOWNHOST_KEY_ED25519
        default: return LIBSSH2_KNOWNHOST_KEY_UNKNOWN
        }
    }
}
