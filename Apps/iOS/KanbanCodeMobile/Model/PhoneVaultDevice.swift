import Foundation
import KanbanCodeRemoteKit
import UIKit

/// This phone as a device of the vault's owner: its Secure Enclave key and
/// the record of the vault requests answered here.
enum PhoneVaultDevice {
    private nonisolated static var directory: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("vault", isDirectory: true).path
    }

    nonisolated static var key: SecureEnclaveOwnerKey {
        SecureEnclaveOwnerKey(path: directory + "/device-key.bin")
    }

    nonisolated static var approvals: VaultDeviceApprovals {
        VaultDeviceApprovals(path: directory + "/device-approvals.jsonl")
    }

    /// This phone's public key as an owner key, when it has one.
    static func recipient() -> VaultOwnerRecipient? {
        key.recipient().map { VaultOwnerRecipient(name: UIDevice.current.name, kind: .phone, publicKey: $0.text) }
    }

    /// Why an approval could not be unlocked here.
    struct Problem: LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }

    static func isCancel(_ error: Error) -> Bool {
        let ns = error as NSError
        // LAError.userCancel, .appCancel, .systemCancel
        return ns.domain == "com.apple.LocalAuthentication" && [-2, -4, -9].contains(ns.code)
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case let e as VaultOwnerSeal.SealError: e.description
        case let e as Age.AgeError: e.description
        case let e as SecureEnclaveOwnerKey.KeyError: e.description
        case let e as AwsSts.StsError: e.description
        default: error.localizedDescription
        }
    }
}
