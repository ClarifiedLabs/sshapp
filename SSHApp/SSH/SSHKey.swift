import Foundation
import Security
import CryptoKit

/// Represents an SSH key pair
struct SSHKey: Identifiable, Codable {
    let id: UUID
    let name: String
    let publicKey: String
    let fingerprint: String
    let createdAt: Date
    let keyType: KeyType

    enum KeyType: String, Codable {
        case ed25519 = "ed25519"
        case secureEnclaveECDSA = "secureEnclaveECDSA"

        var displayName: String {
            switch self {
            case .ed25519: return "Ed25519"
            case .secureEnclaveECDSA: return "Secure Enclave ECDSA"
            }
        }

        var canSyncWithICloud: Bool {
            switch self {
            case .ed25519:
                return true
            case .secureEnclaveECDSA:
                return false
            }
        }
    }

    func renamed(to name: String) -> SSHKey {
        SSHKey(
            id: id,
            name: name,
            publicKey: publicKey.replacingOpenSSHComment(with: name),
            fingerprint: fingerprint,
            createdAt: createdAt,
            keyType: keyType
        )
    }
}

private extension String {
    func replacingOpenSSHComment(with comment: String) -> String {
        let parts = split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            return self
        }
        return "\(parts[0]) \(parts[1]) \(comment)"
    }
}

enum SSHKeyGenerationError: LocalizedError {
    case secureEnclaveUnavailable
    case invalidPublicKey
    case invalidSignature

    var errorDescription: String? {
        switch self {
        case .secureEnclaveUnavailable:
            return "Secure Enclave is not available on this device."
        case .invalidPublicKey:
            return "Invalid SSH public key data."
        case .invalidSignature:
            return "Invalid ECDSA signature data."
        }
    }
}

/// Service for generating and managing SSH keys
enum SSHKeyGenerator {
    static var defaultKeyType: SSHKey.KeyType {
        SecureEnclave.isAvailable ? .secureEnclaveECDSA : .ed25519
    }

    static func isAvailable(_ keyType: SSHKey.KeyType) -> Bool {
        switch keyType {
        case .ed25519:
            return true
        case .secureEnclaveECDSA:
            return SecureEnclave.isAvailable
        }
    }

    /// Generate a new Ed25519 SSH key pair
    static func generateEd25519Key(name: String) throws -> (sshKey: SSHKey, privateKeyData: Data) {
        // Generate Ed25519 key pair using CryptoKit
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey

        // Convert to OpenSSH format
        let publicKeyBlob = makeEd25519PublicKeyBlob(publicKey: publicKey.rawRepresentation)
        let publicKeyOpenSSH = formatOpenSSHPublicKey(keyType: "ssh-ed25519", publicKeyBlob: publicKeyBlob, name: name)

        // Calculate fingerprint (SHA256 of the public key)
        let fingerprint = calculateFingerprint(publicKeyBlob: publicKeyBlob)

        let sshKey = SSHKey(
            id: UUID(),
            name: name,
            publicKey: publicKeyOpenSSH,
            fingerprint: fingerprint,
            createdAt: Date(),
            keyType: .ed25519
        )

        return (sshKey, privateKey.rawRepresentation)
    }

    /// Generate a device-local Secure Enclave P-256 ECDSA key pair.
    static func generateSecureEnclaveECDSAKey(name: String) throws -> (sshKey: SSHKey, privateKeyData: Data) {
        guard SecureEnclave.isAvailable else {
            throw SSHKeyGenerationError.secureEnclaveUnavailable
        }

        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [],
            nil
        ) else {
            throw SSHKeyGenerationError.secureEnclaveUnavailable
        }

        let privateKey = try SecureEnclave.P256.Signing.PrivateKey(accessControl: accessControl)
        let publicKeyBlob = makeECDSAP256PublicKeyBlob(x963Representation: privateKey.publicKey.x963Representation)
        let publicKeyOpenSSH = formatOpenSSHPublicKey(
            keyType: "ecdsa-sha2-nistp256",
            publicKeyBlob: publicKeyBlob,
            name: name
        )

        let sshKey = SSHKey(
            id: UUID(),
            name: name,
            publicKey: publicKeyOpenSSH,
            fingerprint: calculateFingerprint(publicKeyBlob: publicKeyBlob),
            createdAt: Date(),
            keyType: .secureEnclaveECDSA
        )

        return (sshKey, privateKey.dataRepresentation)
    }

    /// Encode a raw Ed25519 private key into OpenSSH PEM format.
    /// This is needed because libssh2's `publickey_frommemory()` expects PEM,
    /// but we store raw 32-byte keys in Keychain.
    static func encodeOpenSSHPrivateKey(rawPrivateKey: Data) -> Data {
        // Derive the public key from the private key
        let privateKey = try! Curve25519.Signing.PrivateKey(rawRepresentation: rawPrivateKey)
        let rawPublicKey = privateKey.publicKey.rawRepresentation

        let keyType = "ssh-ed25519"
        let keyTypeData = keyType.data(using: .utf8)!

        // Build the public key blob (for the "publickeys" section)
        var pubKeyBlob = Data()
        appendSSHString(&pubKeyBlob, keyTypeData)
        appendSSHString(&pubKeyBlob, rawPublicKey)

        // Build the private key section (padded, with check integers)
        // Two random-ish check integers (must match for integrity)
        let checkInt = UInt32.random(in: 0...UInt32.max)
        var privSection = Data()
        appendUInt32(&privSection, checkInt)
        appendUInt32(&privSection, checkInt)
        appendSSHString(&privSection, keyTypeData)               // key type
        appendSSHString(&privSection, rawPublicKey)               // public key
        // Ed25519 "private key" in OpenSSH format = 64 bytes (private + public concatenated)
        let ed25519PrivBlob = rawPrivateKey + rawPublicKey
        appendSSHString(&privSection, ed25519PrivBlob)
        appendSSHString(&privSection, Data())                     // comment (empty)

        // Pad to block size (8 bytes for "none" cipher)
        let blockSize = 8
        let padLen = (blockSize - (privSection.count % blockSize)) % blockSize
        for i in 0..<padLen {
            privSection.append(UInt8((i + 1) & 0xFF))
        }

        // Assemble the full openssh-key-v1 binary payload
        let magic = "openssh-key-v1\0".data(using: .utf8)!
        let cipherNone = "none".data(using: .utf8)!
        let kdfNone = "none".data(using: .utf8)!

        var payload = Data()
        payload.append(magic)
        appendSSHString(&payload, cipherNone)          // ciphername
        appendSSHString(&payload, kdfNone)             // kdfname
        appendSSHString(&payload, Data())              // kdf options (empty)
        appendUInt32(&payload, 1)                      // number of keys
        appendSSHString(&payload, pubKeyBlob)          // public key blob
        appendSSHString(&payload, privSection)         // private key section

        // Wrap in PEM armor
        let base64 = payload.base64EncodedString(options: .lineLength76Characters)
        let pem = "-----BEGIN OPENSSH PRIVATE KEY-----\n\(base64)\n-----END OPENSSH PRIVATE KEY-----\n"
        return pem.data(using: .utf8)!
    }

    static func publicKeyBlob(fromOpenSSHPublicKey publicKey: String) throws -> Data {
        let parts = publicKey.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2,
              let keyData = Data(base64Encoded: String(parts[1])) else {
            throw SSHKeyGenerationError.invalidPublicKey
        }
        return keyData
    }

    static func signSecureEnclaveECDSAPayload(privateKeyData: Data, payload: Data) throws -> Data {
        let privateKey = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: privateKeyData)
        let digest = SHA256.hash(data: payload)
        let signature = try privateKey.signature(for: digest)
        return try encodeECDSASignatureBlob(rawSignature: signature.rawRepresentation)
    }

    static func makeECDSAP256PublicKeyBlob(x963Representation: Data) -> Data {
        var keyData = Data()
        appendSSHString(&keyData, Data("ecdsa-sha2-nistp256".utf8))
        appendSSHString(&keyData, Data("nistp256".utf8))
        appendSSHString(&keyData, x963Representation)
        return keyData
    }

    static func encodeECDSASignatureBlob(rawSignature: Data) throws -> Data {
        guard rawSignature.count == 64 else {
            throw SSHKeyGenerationError.invalidSignature
        }

        let r = rawSignature.prefix(32)
        let s = rawSignature.suffix(32)

        var signature = Data()
        appendSSHMPInt(&signature, Data(r))
        appendSSHMPInt(&signature, Data(s))
        return signature
    }

    // MARK: - Binary encoding helpers

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        var be = value.bigEndian
        data.append(Data(bytes: &be, count: 4))
    }

    private static func appendSSHString(_ data: inout Data, _ value: Data) {
        appendUInt32(&data, UInt32(value.count))
        data.append(value)
    }

    private static func appendSSHMPInt(_ data: inout Data, _ value: Data) {
        let stripped = Data(value.drop(while: { $0 == 0 }))
        guard let first = stripped.first else {
            appendUInt32(&data, 0)
            return
        }

        var encoded = Data()
        if first & 0x80 != 0 {
            encoded.append(0)
        }
        encoded.append(stripped)
        appendSSHString(&data, encoded)
    }

    private static func makeEd25519PublicKeyBlob(publicKey: Data) -> Data {
        var keyData = Data()
        appendSSHString(&keyData, Data("ssh-ed25519".utf8))
        appendSSHString(&keyData, publicKey)
        return keyData
    }

    private static func formatOpenSSHPublicKey(keyType: String, publicKeyBlob: Data, name: String) -> String {
        return "\(keyType) \(publicKeyBlob.base64EncodedString()) \(name)"
    }

    /// Calculate SHA256 fingerprint of public key
    private static func calculateFingerprint(publicKeyBlob: Data) -> String {
        // SHA256 hash
        let hash = SHA256.hash(data: publicKeyBlob)

        // Format as colon-separated hex
        let fingerprint = hash.map { String(format: "%02x", $0) }.joined(separator: ":")
        return "SHA256:\(fingerprint)"
    }
}
