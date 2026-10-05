import AppKit
import KanbanCodeCore
import KanbanCodeRemoteKit
import SwiftUI

/// Settings > Vault > Owner Keys: the keys that open the secrets of tiers
/// ask and never, the one-time setup with the recovery key, and the check
/// of the audit logs.
struct VaultOwnerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var owner: VaultOwnerSet?
    @State private var counts: (sealed: Int, plain: Int) = (0, 0)
    @State private var thisMac: VaultOwnerRecipient?
    /// The recovery key between making it and the "I stored it" step.
    /// Never written to disk.
    @State private var recovery: Age.Identity?
    @State private var stored = false
    @State private var busy = false
    @State private var message: String?
    @State private var problem: String?
    @State private var checkKey = ""
    @State private var report: VaultAuditReport?
    @State private var removing: VaultOwnerRecipient?

    private var vault: VaultService { AppComposition.shared.vault }
    private let caller = VaultCaller(ancestry: ["Kanban Code settings"])

    private var isActive: Bool { owner?.isActive ?? false }
    private var macEnrolled: Bool {
        guard let thisMac else { return false }
        return owner?.recipients.contains { $0.publicKey == thisMac.publicKey } ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Owner Keys", systemImage: "touchid").font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Secrets of the tiers Always ask and Never are encrypted to these keys. A device key stays in that device's Secure Enclave and works only with Touch ID or Face ID. The machines keep ciphertext: a release is unlocked on the Mac or the phone at the moment you approve it.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    if let owner, !owner.recipients.isEmpty {
                        ForEach(owner.recipients) { key in
                            HStack {
                                Image(systemName: icon(key.kind))
                                Text(key.name)
                                if key.publicKey == thisMac?.publicKey { Text("this Mac").font(.caption).foregroundStyle(.secondary) }
                                Spacer()
                                Text(key.fingerprint).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                if key.kind != .recovery, isActive, macEnrolled, owner.devices.count > 1 || key.publicKey != thisMac?.publicKey {
                                    Button("Remove") { removing = key }.controlSize(.small).disabled(busy)
                                }
                            }
                        }
                    } else {
                        Text("No owner keys yet.").foregroundStyle(.secondary)
                    }
                    Divider()
                    Text(isActive
                         ? "\(counts.sealed) secrets sealed to the owner keys\(counts.plain > 0 ? ", \(counts.plain) still waiting" : "")."
                         : "\(counts.plain) secrets of tier Always ask or Never are still readable with the machine key.")
                        .font(.callout)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            if !isActive {
                setup
            } else if !macEnrolled {
                GroupBox("This Mac") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("This Mac holds no owner key. Enrolling asks for an approval on a device that already has one.")
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Enrol This Mac") { Task { await enrolThisMac() } }.disabled(busy || !SecureEnclaveOwnerKey.isAvailable)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }
            } else {
                GroupBox("Check the recovery key") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Paste the recovery key from your password manager to check that it opens a sealed secret. It is used once, here, and not kept.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            SecureField("AGE-SECRET-KEY-1...", text: $checkKey)
                            Button("Check") { Task { await checkRecovery() } }.disabled(checkKey.isEmpty || busy)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }
            }

            GroupBox("Audit log") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Every line names the hash of the one before. The box sends its lines here as it writes them.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Check Now") { Task { busy = true; report = await vault.audit.check(); busy = false } }.disabled(busy)
                    }
                    if let report { VaultAuditReportView(report: report) }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }

            if let message { Label(message, systemImage: "checkmark.circle").foregroundStyle(.green).fixedSize(horizontal: false, vertical: true) }
            if let problem { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(20)
        .frame(width: 620)
        .task { await reload() }
        .confirmationDialog("Remove \(removing?.name ?? "") from the owner keys?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove and Encrypt Again", role: .destructive) {
                if let key = removing { Task { await remove(key) } }
            }
        } message: {
            Text("Every sealed secret is encrypted again without that key. Touch ID is asked once.")
        }
    }

    @ViewBuilder private var setup: some View {
        GroupBox("Set up") {
            VStack(alignment: .leading, spacing: 10) {
                if let recovery {
                    Text("Recovery key. It is shown this once and kept nowhere on this Mac or the box. Store it in your password manager (e.g. 1Password) now: it is the only way back if the Mac and the phone are both lost.")
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Text(recovery.text)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .padding(8)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(recovery.text, forType: .string)
                        }
                    }
                    Text("Public key \(recovery.recipient.text)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Toggle("I stored the recovery key in my password manager", isOn: $stored)
                    HStack {
                        Button("Seal \(counts.plain) Secrets") { Task { await activate(recovery) } }
                            .keyboardShortcut(.defaultAction)
                            .disabled(!stored || busy)
                        Button("Cancel") { self.recovery = nil; stored = false }.disabled(busy)
                    }
                    Text("Sealing keeps the current vault file as backup-before-owner-seal/vault.age next to it on each machine. Nothing is deleted.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Makes this Mac's key in its Secure Enclave and a recovery key, then encrypts every Always ask and Never secret to both. After that those secrets open only with your Touch ID here, an enrolled phone, or the recovery key.")
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Create Keys") { createKeys() }.disabled(busy || !SecureEnclaveOwnerKey.isAvailable)
                    if !SecureEnclaveOwnerKey.isAvailable {
                        Text("This Mac has no Secure Enclave.").foregroundStyle(.red)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(4)
        }
    }

    private func icon(_ kind: VaultOwnerRecipient.Kind) -> String {
        switch kind {
        case .mac: "laptopcomputer"
        case .phone: "iphone"
        case .recovery: "lifepreserver"
        }
    }

    private func reload() async {
        owner = (try? await vault.store.owner()) ?? nil
        counts = (try? await vault.store.ownerCounts()) ?? (0, 0)
        thisMac = MacVaultDevice.recipient()
    }

    private func createKeys() {
        problem = nil
        do {
            try MacVaultDevice.key.create()
            thisMac = MacVaultDevice.recipient()
            recovery = Age.Identity.generate()
            stored = false
        } catch {
            problem = "Could not make this Mac's key: \(MacVaultDevice.describe(error))"
        }
    }

    private func activate(_ recovery: Age.Identity) async {
        guard let mac = MacVaultDevice.recipient() else { return }
        busy = true
        defer { busy = false }
        let others = (owner?.recipients ?? []).filter { $0.kind != .recovery && $0.publicKey != mac.publicKey }
        let keys = [mac] + others + [VaultOwnerRecipient(name: "Recovery key", kind: .recovery, publicKey: recovery.recipient.text)]
        let r = await vault.broker.setOwnerKeys(keys, caller: caller, trusted: true)
        guard r.status == .granted else {
            problem = r.message
            return
        }
        // The key leaves this Mac: memory here, and the clipboard when it still holds it.
        if NSPasteboard.general.string(forType: .string) == recovery.text { NSPasteboard.general.clearContents() }
        self.recovery = nil
        stored = false
        await vault.replica?.poke()
        await reload()
        message = "Sealed \(counts.sealed) secrets. The box gets them with the next sync, within a minute."
        problem = nil
    }

    private func enrolThisMac() async {
        problem = nil
        do {
            try MacVaultDevice.key.create()
        } catch {
            problem = "Could not make this Mac's key: \(MacVaultDevice.describe(error))"
            return
        }
        guard let mac = MacVaultDevice.recipient() else { return }
        thisMac = mac
        let r = await vault.broker.enrol(mac, caller: caller)
        message = r.status == .denied ? nil : "Asked. Approve it on an enrolled device; compare the fingerprint \(mac.fingerprint)."
        problem = r.status == .denied ? r.message : nil
    }

    private func remove(_ key: VaultOwnerRecipient) async {
        removing = nil
        busy = true
        defer { busy = false }
        let keys = (owner?.recipients ?? []).filter { $0.publicKey != key.publicKey }
        let challenge = await vault.broker.ownerChallenge(keys)
        do {
            let unsealed = challenge.isEmpty ? nil : try await MacVaultDevice.key.answer(challenge, reason: "remove \(key.name) from the owner keys")
            let r = await vault.broker.setOwnerKeys(keys, caller: caller, trusted: true, unsealed: unsealed)
            problem = r.status == .granted ? nil : r.message
            message = r.status == .granted ? "Removed \(key.name)." : nil
            await vault.replica?.poke()
        } catch {
            if !MacVaultDevice.isCancel(error) { problem = "Not changed: \(MacVaultDevice.describe(error))" }
        }
        await reload()
    }

    private func checkRecovery() async {
        defer { checkKey = "" }
        do {
            let identity = try Age.Identity(text: checkKey)
            guard let item = try await vault.store.sealedItems().first else {
                problem = "No sealed secret to try it on."
                return
            }
            _ = try VaultOwnerSeal.open(item.sealed, recovery: identity)
            message = "The recovery key opens the sealed secrets."
            problem = nil
        } catch {
            message = nil
            problem = "That key does not open them: \(MacVaultDevice.describe(error))"
        }
    }
}

struct VaultAuditReportView: View {
    let report: VaultAuditReport

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(report.ok ? "No broken chain, nothing missing." : "Problems found.",
                  systemImage: report.ok ? "checkmark.seal" : "exclamationmark.octagon")
                .foregroundStyle(report.ok ? .green : .red)
            ForEach(report.logs, id: \.name) { log in
                Text("\(log.name): \(log.lines) lines\(log.unchained > 0 ? ", \(log.unchained) from before the chain" : "")"
                     + (log.breaks.isEmpty ? "" : ", chain broken at line \(log.breaks.prefix(5).map(String.init).joined(separator: ", "))"))
                    .font(.caption).foregroundStyle(log.breaks.isEmpty ? Color.secondary : Color.red)
            }
            ForEach(report.missing, id: \.machine) { m in
                Text(m.count == 0
                     ? "\(m.machine): every mirrored line is still in its log\(m.notMirroredYet > 0 ? " (\(m.notMirroredYet) not mirrored yet)" : "")"
                     : "\(m.machine): \(m.count) mirrored lines are gone from its log")
                    .font(.caption).foregroundStyle(m.count == 0 ? Color.secondary : Color.red)
            }
            ForEach(report.unrecordedApprovals, id: \.self) { line in
                Text("Approval not recorded on this Mac: \(line)").font(.caption).foregroundStyle(.red)
            }
            ForEach(report.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
        }
    }
}
