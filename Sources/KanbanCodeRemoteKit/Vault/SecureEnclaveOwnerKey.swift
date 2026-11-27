#if canImport(CryptoKit) && canImport(LocalAuthentication)
import CryptoKit
import CryptoTokenKit
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
        /// The handle on disk no longer opens in the enclave.
        case stale
        case accessControl(String)

        public var description: String {
            switch self {
            case .unavailable: "this device has no Secure Enclave"
            case .notEnrolled: "this device has no vault key yet"
            case .stale: "this device's vault key no longer opens"
            case .accessControl(let why): "could not set the key's access control: \(why)"
            }
        }
    }

    public static var isAvailable: Bool { SecureEnclave.isAvailable }

    /// Where the public half is kept next to the handle, so a key whose
    /// handle stops opening can still be named on the masters.
    public var publicKeyPath: String { path + ".pub" }

    public enum State: Equatable, Sendable {
        /// No key on this device.
        case none
        case ready(Age.P256Recipient)
        /// A handle is on disk but the enclave no longer opens it: the
        /// fingers or faces enrolled changed (the key is bound to the set
        /// it was made with), or the device was restored. `previous` is its
        /// public key when it was kept.
        case stale(previous: Age.P256Recipient?)
    }

    /// Needs no biometry.
    public var state: State {
        guard let handle = FileManager.default.contents(atPath: path) else { return .none }
        guard let key = try? SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: handle),
              let recipient = try? Age.P256Recipient(compressed: key.publicKey.compressedRepresentation) else {
            return .stale(previous: previousRecipient())
        }
        return .ready(recipient)
    }

    /// A key that opens: false for no key and for a stale one.
    public var exists: Bool {
        if case .ready = state { return true }
        return false
    }

    /// The public half, when this device has a key that opens. Needs no biometry.
    public func recipient() -> Age.P256Recipient? {
        if case .ready(let recipient) = state { return recipient }
        return nil
    }

    func previousRecipient() -> Age.P256Recipient? {
        guard let data = FileManager.default.contents(atPath: publicKeyPath),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return try? Age.P256Recipient(text: text)
    }

    /// Errors from opening the handle that mean it will never open again,
    /// as opposed to a cancelled or failed Face ID.
    public static func isStaleHandle(_ error: Error) -> Bool {
        if let key = error as? KeyError, case .stale = key { return true }
        let ns = error as NSError
        guard ns.domain == TKErrorDomain else { return false }
        return [TKError.Code.corruptedData.rawValue, TKError.Code.objectNotFound.rawValue,
                TKError.Code.tokenNotFound.rawValue].contains(ns.code)
    }

    /// Makes the key when the device has none, and a new one in place of
    /// a stale one. Needs no biometry.
    @discardableResult
    public func create() throws -> Age.P256Recipient {
        switch state {
        case .ready(let existing): return existing
        case .stale: try? FileManager.default.removeItem(atPath: path)
        case .none: break
        }
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
        let recipient = try Age.P256Recipient(compressed: key.publicKey.compressedRepresentation)
        FileManager.default.createFile(atPath: publicKeyPath, contents: Data(recipient.text.utf8), attributes: [.posixPermissions: 0o600])
        return recipient
    }

    /// The key for one approval: the first use shows the biometry prompt
    /// with `reason`, the rest of the approval reuses that one check.
    public func unlocked(reason: String) throws -> Unlocked {
        guard let handle = FileManager.default.contents(atPath: path) else { throw KeyError.notEnrolled }
        let context = LAContext()
        context.localizedReason = reason
        let key: SecureEnclave.P256.KeyAgreement.PrivateKey
        do {
            key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: handle, authenticationContext: context)
        } catch where Self.isStaleHandle(error) {
            throw KeyError.stale
        }
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
                       mint: @escaping VaultUnsealer.Mint = VaultUnsealer.liveMint,
                       sso: @escaping AwsSso.Source = AwsSso.unavailable) async throws -> VaultUnsealed {
        let key = try unlocked(reason: reason)
        return try await Task.detached(priority: .userInitiated) {
            try await VaultUnsealer.answer(challenge, key: key, mint: mint, sso: sso)
        }.value
    }
}
#endif
