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

    static let staleKeyText = "This phone's vault key stopped working after the app was reinstalled. Enrol it again under Machines > Vault key."

    /// This phone's public key as an owner key, when it has one that opens.
    static func recipient() -> VaultOwnerRecipient? {
        key.recipient().map { VaultOwnerRecipient(name: UIDevice.current.name, kind: .phone, publicKey: $0.text) }
    }

    struct EnrolOutcome {
        var message: String?
        var problem: String?
    }

    /// Makes a key when the phone has none or its old one stopped opening,
    /// then asks a master to enrol it, dropping the dead key in the same
    /// approval when it can tell which one that is.
    @MainActor
    static func enrol(fleet: FleetModel) async -> EnrolOutcome {
        let before = key.state
        do {
            try key.create()
        } catch {
            return EnrolOutcome(problem: "Could not make the key: \(describe(error))")
        }
        guard let mine = recipient() else { return EnrolOutcome(problem: "Could not make the key.") }
        guard let master = fleet.primary.flatMap({ $0.isOnline ? $0 : nil }) ?? fleet.onlineMasters.first, let client = master.client else {
            return EnrolOutcome(problem: "No machine is reachable.")
        }
        var replaces: [String] = []
        if case .stale(let previous) = before, let status = try? await client.vaultOwner() {
            replaces = status.keysToReplace(previous: previous.map { VaultOwnerRecipient.fingerprint(of: $0.text) },
                                            name: mine.name, kind: .phone, new: mine.fingerprint)
        }
        do {
            try await client.vaultEnrol(name: mine.name, kind: .phone, publicKey: mine.publicKey, replaces: replaces)
        } catch {
            return EnrolOutcome(problem: error.localizedDescription)
        }
        let dropping = replaces.isEmpty ? "" : " It also removes this phone's old key (\(replaces.joined(separator: ", ")))."
        return EnrolOutcome(message: "Asked \(master.machineName). Approve it on the Mac with Touch ID; it shows the fingerprint above.\(dropping)")
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
