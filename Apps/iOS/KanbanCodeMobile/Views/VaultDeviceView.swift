import SwiftUI
import KanbanCodeRemoteKit

/// This phone's key for the vault's owner-only secrets: its fingerprint,
/// enrolling it on a master, and the record of what was approved here.
struct VaultDeviceView: View {
    let fleet: FleetModel
    @State private var recipient: VaultOwnerRecipient?
    @State private var owners: [UUID: VaultOwnerStatus] = [:]
    @State private var entries: [VaultDeviceApprovals.Entry] = []
    @State private var chainIntact = true
    @State private var busy = false
    @State private var message: String?
    @State private var problem: String?

    private var enrolledOn: [String] {
        guard let recipient else { return [] }
        return fleet.orderedMasters.compactMap { master in
            owners[master.server.id]?.keys.contains { $0.fingerprint == recipient.fingerprint } == true ? master.machineName : nil
        }
    }

    var body: some View {
        List {
            Section {
                if let recipient {
                    LabeledContent("Fingerprint") {
                        Text(recipient.fingerprint).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    }
                    .accessibilityIdentifier("vaultFingerprint")
                    if enrolledOn.isEmpty {
                        Text("Not enrolled yet.").foregroundStyle(.secondary)
                    } else {
                        Label("Enrolled on \(enrolledOn.joined(separator: ", "))", systemImage: "checkmark.seal")
                            .foregroundStyle(.green)
                    }
                } else {
                    Text("This phone has no vault key.").foregroundStyle(.secondary)
                }
                if enrolledOn.isEmpty {
                    Button(recipient == nil ? "Create key and enrol this phone" : "Enrol this phone") {
                        Task { await enrol() }
                    }
                    .disabled(busy || fleet.onlineMasters.isEmpty || !SecureEnclaveOwnerKey.isAvailable)
                    .accessibilityIdentifier("vaultEnrol")
                }
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                if let problem { Label(problem, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red) }
            } header: {
                Text("This phone")
            } footer: {
                Text("The key is made in this phone's Secure Enclave and never leaves it. It works only with Face ID. Enrolling asks for an approval on the Mac: check that the Mac shows this fingerprint.")
            }

            Section {
                if entries.isEmpty {
                    Text("Nothing yet.").foregroundStyle(.secondary)
                }
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title).font(.callout)
                        Text([entry.resolution, entry.unlocked?.joined(separator: ", "), entry.awsRole, entry.error.map { "failed: \($0)" }]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(entry.error == nil ? Color.secondary : Color.red)
                        Text(entry.at.prefix(19).replacingOccurrences(of: "T", with: " ")).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            } header: {
                Text("Answered on this phone")
            } footer: {
                Text(chainIntact ? "Kept on this phone only. Each line names the one before it."
                                 : "This record was changed: its chain is broken.")
                    .foregroundStyle(chainIntact ? Color.secondary : Color.red)
            }
        }
        .navigationTitle("Vault key")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .refreshable { await reload() }
    }

    private func reload() async {
        recipient = PhoneVaultDevice.recipient()
        entries = PhoneVaultDevice.approvals.entries(limit: 200)
        chainIntact = PhoneVaultDevice.approvals.report().isIntact
        for master in fleet.onlineMasters {
            if let status = try? await master.client?.vaultOwner() { owners[master.server.id] = status }
        }
    }

    private func enrol() async {
        busy = true
        defer { busy = false }
        problem = nil
        do {
            try PhoneVaultDevice.key.create()
        } catch {
            problem = "Could not make the key: \(PhoneVaultDevice.describe(error))"
            return
        }
        guard let mine = PhoneVaultDevice.recipient() else { return }
        recipient = mine
        guard let master = fleet.primary.flatMap({ $0.isOnline ? $0 : nil }) ?? fleet.onlineMasters.first, let client = master.client else {
            problem = "No machine is reachable."
            return
        }
        do {
            try await client.vaultEnrol(name: mine.name, kind: .phone, publicKey: mine.publicKey)
            message = "Asked \(master.machineName). Approve it on the Mac with Touch ID; it shows the fingerprint above."
        } catch {
            problem = error.localizedDescription
        }
        await reload()
    }
}
