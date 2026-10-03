#if canImport(CryptoKit) && canImport(LocalAuthentication)
import CryptoKit
import Foundation
import LocalAuthentication

/// This device's key for the owner-only secrets. The private half is made
/// inside the Secure Enclave and cannot leave it; every use needs Touch ID
/// or Face ID with the fingers or face enrolled when the key was made (no
/// passcode fallback). What is stored on disk is the enclave's own handle
/// to the key, useless on any other device.
public struct SecureEnclaveOwnerKey: Sendable {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    public enum KeyError: Error, CustomStringConvertible {
        case unavailable
        case notEnrolled
        case accessControl(String)

        public var description: String {
            switch self {
            case .unavailable: "this device has no Secure Enclave"
            case .notEnrolled: "this device has no vault key yet"
            case .accessControl(let why): "could not set the key's access control: \(why)"
            }
        }
    }

    public static var isAvailable: Bool { SecureEnclave.isAvailable }

    public var exists: Bool { FileManager.default.fileExists(atPath: path) }

    /// The public half, when this device has a key. Needs no biometry.
    public func recipient() -> Age.P256Recipient? {
        guard let handle = FileManager.default.contents(atPath: path),
              let key = try? SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: handle) else { return nil }
        return try? Age.P256Recipient(compressed: key.publicKey.compressedRepresentation)
    }

    /// Makes the key when the device has none. Needs no biometry.
    @discardableResult
    public func create() throws -> Age.P256Recipient {
        if let existing = recipient() { return existing }
        guard SecureEnclave.isAvailable else { throw KeyError.unavailable }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .biometryCurrentSet], &error
        ) else {
            throw KeyError.accessControl(error.map { "\($0.takeRetainedValue())" } ?? "unknown")
        }
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard FileManager.default.createFile(atPath: path, contents: key.dataRepresentation, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return try Age.P256Recipient(compressed: key.publicKey.compressedRepresentation)
    }

    /// The key for one approval: the first use shows the biometry prompt
    /// with `reason`, the rest of the approval reuses that one check.
    public func unlocked(reason: String) throws -> Unlocked {
        guard let handle = FileManager.default.contents(atPath: path) else { throw KeyError.notEnrolled }
        let context = LAContext()
        context.localizedReason = reason
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: handle, authenticationContext: context)
        return Unlocked(key: key, recipient: try Age.P256Recipient(compressed: key.publicKey.compressedRepresentation))
    }

    public struct Unlocked: AgeP256Key, @unchecked Sendable {
        let key: SecureEnclave.P256.KeyAgreement.PrivateKey
        public let recipient: Age.P256Recipient

        public func sharedSecret(withEphemeral compressed: Data) throws -> Data {
            let theirs = try P256.KeyAgreement.PublicKey(compressedRepresentation: compressed)
            return try key.sharedSecretFromKeyAgreement(with: theirs).withUnsafeBytes { Data($0) }
        }
    }

    /// Answers a request's challenge on this device: the biometry prompt,
    /// then the unlocking, off the main thread.
    public func answer(_ challenge: VaultUnsealChallenge, reason: String,
                       mint: @escaping VaultUnsealer.Mint = VaultUnsealer.liveMint) async throws -> VaultUnsealed {
        let key = try unlocked(reason: reason)
        return try await Task.detached(priority: .userInitiated) {
            try await VaultUnsealer.answer(challenge, key: key, mint: mint)
        }.value
    }
}
#endif
