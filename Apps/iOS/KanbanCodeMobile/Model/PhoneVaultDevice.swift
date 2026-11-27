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

    static let staleKeyText = "This phone's vault key stopped working, which happens when Face ID changes on the phone. Enrol it again under Machines > Vault key."

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
    /// approval when it can tell which one that is. The ask goes to a
    /// master with a screen (the Mac), where the owner approves with a key
    /// that works; an always-on box only when no other master answers.
    @MainActor
    static func enrol(fleet: FleetModel) async -> EnrolOutcome {
        let before = key.state
        do {
            try key.create()
        } catch {
            return EnrolOutcome(problem: "Could not make the key: \(describe(error))")
        }
        guard let mine = recipient() else { return EnrolOutcome(problem: "Could not make the key.") }
        guard let (master, client, isMac) = await enrolTarget(fleet) else {
            return EnrolOutcome(problem: "No machine is reachable.")
        }
        var replaces: [String] = []
        if case .stale(let previous) = before, let status = try? await client.vaultOwner() {
            replaces = status.keysToReplace(previous: previous.map { VaultOwnerRecipient.fingerprint(of: $0.text) },
                                            name: mine.name, kind: .phone, new: mine.fingerprint)
        }
        let answer: RemoteVaultResponse
        do {
            answer = try await client.vaultEnrol(name: mine.name, kind: .phone, publicKey: mine.publicKey, replaces: replaces)
        } catch {
            return EnrolOutcome(problem: "\(master.machineName) did not take it: \(error.localizedDescription)")
        }
        switch answer.status {
        case "granted":
            return EnrolOutcome(message: "Already enrolled on \(master.machineName): \(answer.message)")
        case "pending":
            let dropping = replaces.isEmpty ? "" : " It also removes this phone's old key (\(replaces.joined(separator: ", ")))."
            if !isMac {
                return EnrolOutcome(message: "Waiting for your Mac to come online. \(master.machineName) holds the request and it shows on the Mac when the Mac is back; approve it there with Touch ID, it shows the fingerprint above.\(dropping)")
            }
            return EnrolOutcome(message: "Asked \(master.machineName). Approve it there with Touch ID; it shows the fingerprint above.\(dropping)")
        default:
            return EnrolOutcome(problem: "\(master.machineName) refused: \(answer.message)")
        }
    }

    /// The master to ask: one that is not always on (a Mac, with a screen
    /// and a Touch ID owner key), else the primary, else any online one.
    /// `isMac` is false for an always-on master: it holds the request until
    /// the Mac comes online and shows it there.
    @MainActor
    private static func enrolTarget(_ fleet: FleetModel) async -> (BoardModel, RemoteClient, isMac: Bool)? {
        let online = fleet.onlineMasters.compactMap { m in m.client.map { (m, $0) } }
        for (master, client) in online {
            if let list = try? await client.machines(),
               let this = list.machines.first(where: { $0.kind == .this }), this.alwaysOn != true {
                return (master, client, true)
            }
        }
        if let primary = fleet.primary, primary.isOnline, let client = primary.client { return (primary, client, false) }
        return online.first.map { ($0.0, $0.1, false) }
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
