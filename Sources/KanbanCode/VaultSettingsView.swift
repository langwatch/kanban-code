import KanbanCodeRemoteKit
import KanbanCodeCore
import SwiftUI

/// The caller the Mac app acts as when Rogerio edits the vault in Settings.
private let settingsCaller = VaultCaller(ancestry: ["Kanban Code settings"])

/// Settings > Vault: the secrets (names only), their tiers and rules, and
/// the recent releases of this Mac.
struct VaultSettingsView: View {
    @State private var secrets: [VaultSecretInfo] = []
    @State private var log: [VaultAuditEntry] = []
    @State private var status = ""
    @State private var selected: String?
    @State private var showAdd = false
    @State private var showOwner = false
    @State private var error: String?

    private var vault: VaultService { AppComposition.shared.vault }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(status).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Owner Keys...") { showOwner = true }
                Button("Add Secret") { showAdd = true }
                Button("Refresh") { Task { await reload() } }
            }
            ScrubSettingsSection()
            HSplitView {
                List(selection: $selected) {
                    ForEach(VaultTier.allCases, id: \.self) { tier in
                        let inTier = secrets.filter { $0.tier == tier }
                        if !inTier.isEmpty {
                            Section("\(tier.label) (\(inTier.count))") {
                                ForEach(inTier, id: \.name) { s in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(s.key ?? s.name).font(.system(.body, design: .monospaced))
                                            if let project = s.project, let environment = s.environment {
                                                Text("\(project) · \(environment)").font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                        if s.leasePolicy.everyUseAsks {
                                            Image(systemName: "hand.raised").foregroundStyle(.orange).help("Every use asks")
                                        }
                                        if s.aws != nil {
                                            Text("AWS").font(.caption2).foregroundStyle(.secondary)
                                        }
                                        if s.sealed == true {
                                            Image(systemName: "touchid").foregroundStyle(.secondary).help("Opens only on your Mac or phone")
                                        }
                                    }
                                    .tag(s.name)
                                }
                            }
                        }
                    }
                }
                .frame(minWidth: 240)

                Group {
                    if let name = selected, let s = secrets.first(where: { $0.name == name }) {
                        VaultSecretEditor(secret: s) { edit in
                            Task {
                                // Lowering a sealed secret's tier opens it with this Mac's key first.
                                let challenge = await vault.broker.editChallenge(s.name, edit)
                                var unsealed: VaultUnsealed?
                                if !challenge.isEmpty {
                                    do {
                                        unsealed = try await MacVaultDevice.key.answer(challenge, reason: "lower the tier of \(s.name)")
                                    } catch {
                                        if !MacVaultDevice.isCancel(error) { self.error = "Not changed: \(MacVaultDevice.describe(error))" }
                                        return
                                    }
                                }
                                let r = await vault.broker.edit(s.name, edit, caller: settingsCaller, trusted: true, unsealed: unsealed)
                                if r.status != .granted { error = r.message }
                                await vault.replica?.poke()
                                await reload()
                            }
                        } onDelete: {
                            Task {
                                let r = await vault.broker.delete(s.name, caller: settingsCaller, trusted: true)
                                if r.status != .granted { error = r.message }
                                selected = nil
                                await reload()
                            }
                        }
                        .id(s.name + s.updatedAt.description)
                    } else {
                        VaultLogList(entries: log)
                    }
                }
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding()
        .task { await reload() }
        .sheet(isPresented: $showOwner, onDismiss: { Task { await reload() } }) { VaultOwnerSheet() }
        .sheet(isPresented: $showAdd) {
            VaultAddSheet { req in
                Task {
                    let r = await vault.broker.add(req, caller: settingsCaller, trusted: true)
                    if r.status != .granted { error = r.message }
                    await reload()
                    selected = req.name
                }
            }
        }
    }

    private func reload() async {
        let unlocked = await vault.store.isUnlocked
        do {
            secrets = try await vault.store.list()
            error = nil
        } catch {
            secrets = []
            self.error = "\(error)"
        }
        log = await vault.store.log(limit: 200)
        let leases = await vault.store.activeLeases().count
        status = unlocked
            ? "\(secrets.count) secrets, \(leases) active card leases. Values never show here; agents get them with kv."
            : "Locked: this Mac has no vault key yet. The box is the vault's home; its key is imported once."
    }
}

private struct VaultSecretEditor: View {
    let secret: VaultSecretInfo
    let onSave: (VaultEditRequest) -> Void
    let onDelete: () -> Void
    @State private var tier: VaultTier
    @State private var rules: String
    @State private var everyUse: Bool
    @State private var confirmDelete = false

    init(secret: VaultSecretInfo, onSave: @escaping (VaultEditRequest) -> Void, onDelete: @escaping () -> Void) {
        self.secret = secret
        self.onSave = onSave
        self.onDelete = onDelete
        _tier = State(initialValue: secret.tier)
        _rules = State(initialValue: secret.rules)
        _everyUse = State(initialValue: secret.leasePolicy.everyUseAsks)
    }

    var body: some View {
        Form {
            Section(secret.name) {
                if let project = secret.project, let environment = secret.environment {
                    LabeledContent("Project", value: project)
                    LabeledContent("Environment", value: environment)
                }
                if let aliases = secret.aliases, !aliases.isEmpty {
                    LabeledContent("Earlier names") {
                        Text(aliases.joined(separator: "\n")).font(.caption).textSelection(.enabled)
                    }
                }
                Picker("Tier", selection: $tier) {
                    ForEach(VaultTier.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("Every use asks (no card leases)", isOn: $everyUse)
                VStack(alignment: .leading) {
                    Text("Rules for Jev").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $rules)
                        .font(.body)
                        .frame(minHeight: 70)
                }
                if let aws = secret.aws {
                    LabeledContent("AWS role", value: aws.roleArn ?? "session token of \(aws.sourceSecret)")
                    if !aws.policyArns.isEmpty {
                        LabeledContent("Session policy", value: aws.policyArns.joined(separator: ", "))
                    }
                }
                if !secret.sources.isEmpty {
                    LabeledContent("Imported from") {
                        Text(secret.sources.joined(separator: "\n")).font(.caption).textSelection(.enabled)
                    }
                }
                LabeledContent("Updated", value: secret.updatedAt.formatted(date: .abbreviated, time: .shortened))
                HStack {
                    Button("Delete", role: .destructive) { confirmDelete = true }
                    Spacer()
                    Button("Save") {
                        let policy = VaultLeasePolicy(leaseSeconds: secret.leasePolicy.leaseSeconds, everyUseAsks: everyUse)
                        onSave(VaultEditRequest(tier: tier, rules: rules, leasePolicy: policy))
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(tier == secret.tier && rules == secret.rules && everyUse == secret.leasePolicy.everyUseAsks)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete \(secret.name) from the vault on every machine?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive, action: onDelete)
        }
    }
}

private struct VaultAddSheet: View {
    let onAdd: (VaultAddRequest) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var value = ""
    @State private var tier: VaultTier = .judged
    @State private var rules = ""

    var body: some View {
        Form {
            TextField("Name", text: $name)
            SecureField("Value", text: $value)
            Picker("Tier", selection: $tier) {
                ForEach(VaultTier.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            TextField("Rules for Jev", text: $rules, axis: .vertical)
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Add") {
                    onAdd(VaultAddRequest(name: name, value: value, tier: tier, rules: rules))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!VaultSecret.isValidName(name) || value.isEmpty)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding()
    }
}

struct VaultLogList: View {
    let entries: [VaultAuditEntry]

    var body: some View {
        if entries.isEmpty {
            Text("No releases yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(Array(entries.enumerated()), id: \.offset) { _, e in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Image(systemName: icon(e.outcome)).foregroundStyle(color(e.outcome))
                        Text(VaultSecretName(e.secret).key).font(.system(.body, design: .monospaced))
                        if !VaultSecretName(e.secret).scopeParts.isEmpty {
                            Text(VaultSecretName(e.secret).scopeParts.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(e.action).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(e.at.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }
                    Text([e.decider.rawValue, e.detail, e.cardId].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    if let command = e.command, !command.isEmpty {
                        Text(command).font(.system(.caption, design: .monospaced)).lineLimit(2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func icon(_ o: VaultOutcome) -> String {
        switch o {
        case .allowed: "checkmark.circle.fill"
        case .denied: "xmark.octagon.fill"
        case .asked: "hand.raised.fill"
        case .skipped: "arrow.uturn.right.circle"
        }
    }

    private func color(_ o: VaultOutcome) -> Color {
        switch o {
        case .allowed: .green
        case .denied: .red
        case .asked: .orange
        case .skipped: .secondary
        }
    }
}

/// The card's vault activity: what it was given and the leases it holds.
struct CardVaultSheet: View {
    let cardId: String
    @Environment(\.dismiss) private var dismiss
    @State private var leases: [VaultLease] = []
    @State private var log: [VaultAuditEntry] = []

    private var vault: VaultService { AppComposition.shared.vault }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Vault").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Text("Active leases").font(.subheadline.bold())
            if leases.isEmpty {
                Text("None.").foregroundStyle(.secondary)
            } else {
                ForEach(leases) { lease in
                    HStack {
                        Text(lease.secret).font(.system(.body, design: .monospaced))
                        Text("until \(lease.expiresAt.formatted(date: .abbreviated, time: .shortened))").foregroundStyle(.secondary)
                        if let reason = lease.reason { Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        Spacer()
                        Button("Revoke") {
                            Task {
                                try? await vault.store.revokeLease(id: lease.id)
                                await reload()
                            }
                        }
                    }
                }
            }
            Text("Releases").font(.subheadline.bold())
            VaultLogList(entries: log)
        }
        .padding()
        .frame(width: 560, height: 480)
        .task { await reload() }
    }

    private func reload() async {
        leases = await vault.store.activeLeases(cardId: cardId)
        log = await vault.store.log(limit: 200, cardId: cardId)
    }
}
