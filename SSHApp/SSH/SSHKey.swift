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

    /// Produce the inner SSH signature blob for a public-key auth challenge,
    /// dispatched by key type. libssh2 wraps the returned bytes as
    /// `string(algorithm) || string(signature)`, so this returns only the
    /// algorithm-specific inner signature. Neither path materialises the key as
    /// an OpenSSH PEM — Ed25519 signs with CryptoKit, Secure Enclave signs
    /// in-enclave — so no decoded private-key file ever exists in memory.
    static func signSSHPayload(keyType: SSHKey.KeyType, privateKeyData: Data, payload: Data) throws -> Data {
        switch keyType {
        case .ed25519:
            return try signEd25519Payload(privateKeyData: privateKeyData, payload: payload)
        case .secureEnclaveECDSA:
            return try signSecureEnclaveECDSAPayload(privateKeyData: privateKeyData, payload: payload)
        }
    }

    /// Sign an auth challenge with a raw Ed25519 private key. Ed25519 signs the
    /// message directly (no pre-hash); the 64-byte raw signature is exactly the
    /// inner `ssh-ed25519` signature libssh2 expects from the callback.
    static func signEd25519Payload(privateKeyData: Data, payload: Data) throws -> Data {
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)
        return try privateKey.signature(for: payload)
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
