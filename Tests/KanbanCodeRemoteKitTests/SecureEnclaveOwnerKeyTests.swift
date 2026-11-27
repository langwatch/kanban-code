#if canImport(CryptoKit) && canImport(LocalAuthentication)
import CryptoKit
import CryptoTokenKit
import Foundation
import Testing
@testable import KanbanCodeRemoteKit

@Suite("Secure Enclave owner key")
struct SecureEnclaveOwnerKeyTests {
    private func tempKey() throws -> SecureEnclaveOwnerKey {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("se-key-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return SecureEnclaveOwnerKey(path: dir.appendingPathComponent("device-key.bin").path)
    }

    @Test func noFileIsNoKey() throws {
        let key = try tempKey()
        #expect(key.state == .none)
        #expect(!key.exists)
        #expect(key.recipient() == nil)
    }

    @Test func aHandleTheEnclaveNoLongerOpensIsStaleNotMissing() throws {
        let key = try tempKey()
        FileManager.default.createFile(atPath: key.path, contents: Data(repeating: 7, count: 300))
        #expect(key.state == .stale(previous: nil))
        // A stale key is not a key: nothing may treat it as enrolled.
        #expect(!key.exists)
        #expect(key.recipient() == nil)
        #expect(throws: SecureEnclaveOwnerKey.KeyError.self) { _ = try key.unlocked(reason: "test") }
    }

    @Test func aStaleKeyStillNamesItsPublicHalfWhenKept() throws {
        let key = try tempKey()
        let previous = try Age.P256Recipient(compressed: P256.KeyAgreement.PrivateKey().publicKey.compressedRepresentation)
        FileManager.default.createFile(atPath: key.path, contents: Data(repeating: 7, count: 300))
        FileManager.default.createFile(atPath: key.publicKeyPath, contents: Data(previous.text.utf8))
        #expect(key.state == .stale(previous: previous))
    }

    /// The enclave refused the key at use while its handle still opens:
    /// once marked, it is stale, names its own public half for the masters
    /// to drop, and `create()` replaces it.
    @Test(.enabled(if: SecureEnclave.isAvailable))
    func aKeyRefusedAtUseIsStaleOnceMarkedAndReplacedByCreate() throws {
        let key = try tempKey()
        let enclave = try SecureEnclave.P256.KeyAgreement.PrivateKey()
        FileManager.default.createFile(atPath: key.path, contents: enclave.dataRepresentation)
        let old = try Age.P256Recipient(compressed: enclave.publicKey.compressedRepresentation)
        #expect(key.state == .ready(old))

        key.markStale()
        #expect(key.state == .stale(previous: old))
        #expect(!key.exists)
        #expect(key.recipient() == nil)

        let fresh = try key.create()
        #expect(fresh != old)
        #expect(key.state == .ready(fresh))
        #expect(!FileManager.default.fileExists(atPath: key.staleMarkerPath))
    }

    @Test func enclaveErrorsThatNeverHealAreStaleAndFaceIDErrorsAreNot() {
        #expect(SecureEnclaveOwnerKey.isStaleHandle(NSError(domain: TKErrorDomain, code: TKError.Code.corruptedData.rawValue)))
        #expect(SecureEnclaveOwnerKey.isStaleHandle(NSError(domain: TKErrorDomain, code: TKError.Code.objectNotFound.rawValue)))
        #expect(SecureEnclaveOwnerKey.isStaleHandle(SecureEnclaveOwnerKey.KeyError.stale))
        #expect(!SecureEnclaveOwnerKey.isStaleHandle(NSError(domain: TKErrorDomain, code: TKError.Code.canceledByUser.rawValue)))
        #expect(!SecureEnclaveOwnerKey.isStaleHandle(NSError(domain: TKErrorDomain, code: TKError.Code.authenticationFailed.rawValue)))
        #expect(!SecureEnclaveOwnerKey.isStaleHandle(NSError(domain: "com.apple.LocalAuthentication", code: -2)))
        #expect(!SecureEnclaveOwnerKey.isStaleHandle(SecureEnclaveOwnerKey.KeyError.notEnrolled))
    }
}
#endif
