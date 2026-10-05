import SwiftUI
import KanbanCodeCore
import KanbanCodeRemoteKit

/// The caller the Mac app acts as when a composer saves a pasted secret.
private let composerCaller = VaultCaller(ancestry: ["Kanban Code composer"])

/// A prompt held back because it carries secrets, and the offer to save them
/// to the vault before it is sent. Composers own one each; Yes saves every
/// offered secret under its (editable) name and sends the prompt with
/// `{{vault:NAME}}` references, No sends it unchanged. A name typed over the
/// one offered that the vault already holds asks before its value is replaced.
@MainActor @Observable
final class VaultSecretOffer {
    var proposals: [SecretProposal] = []
    var error: String?
    var isSaving = false
    /// The stored name the first offer was typed as, while the user decides
    /// whether to replace its value.
    var replaceName: String?
    /// What the save waits on, when the vault asked for an approval.
    var waiting: String?
    private var heldText = ""
    private var send: ((String) -> Void)?

    var isActive: Bool { send != nil }

    private var vault: VaultService { AppComposition.shared.vault }

    /// Sends `text` at once when it holds no secret; otherwise holds it and offers.
    func submit(_ text: String, send: @escaping (String) -> Void) {
        guard !isActive else { return }
        guard !SecretDetector.find(in: text).isEmpty else { send(text); return }
        heldText = text
        self.send = send
        error = nil
        Task {
            let names = await existingNames()
            proposals = SecretDetector.proposals(in: text, existingNames: names)
            if proposals.isEmpty { decline() }
        }
    }

    /// No: the prompt goes out as typed.
    func decline() {
        guard let send, !isSaving else { return }
        let text = heldText
        reset()
        send(text)
    }

    /// Esc: back to the names while the replace question shows, else No.
    func escape() {
        if replaceName != nil { answerReplace(false) } else { decline() }
    }

    /// Yes: every offered secret is saved, then the prompt goes out with
    /// references in their place. A typed name the vault holds with another
    /// value stops here and asks (`replaceName`).
    func accept() {
        guard let send, !isSaving, !proposals.isEmpty, replaceName == nil else { return }
        isSaving = true
        error = nil
        let offered = proposals
        let text = heldText
        Task {
            let vault = self.vault
            let result = await SecretDetector.save(offered, in: text, existingNames: await existingNames()) { proposal in
                let check = await vault.broker.compare(VaultAddRequest(name: proposal.name, value: proposal.value))
                return StoredSecretMatch(rawValue: check.outcome.rawValue) ?? .different
            } add: { proposal, replacing in
                await self.store(proposal, replacing: replacing)
            }
            waiting = nil
            isSaving = false
            // Secrets already saved stay referenced, the rest stay offered.
            heldText = result.text
            proposals = result.remaining
            replaceName = result.replace
            error = result.error
            guard result.error == nil, result.replace == nil else { return }
            reset()
            send(result.text)
        }
    }

    /// The answer to "Replace its value?": yes replaces it and goes on with
    /// the save, no puts the free name back for the user to edit.
    func answerReplace(_ replace: Bool) {
        guard replaceName != nil, !isSaving else { return }
        replaceName = nil
        proposals = SecretDetector.answeringReplace(proposals, replace: replace)
        if replace { accept() }
    }

    /// Adds a new secret as a pasted one. A replacement carries only the
    /// value, so the stored secret keeps its tier, rules, label and tags;
    /// it is the user's own choice in this app, so it needs no approval.
    private func store(_ proposal: SecretProposal, replacing: Bool) async -> String? {
        let request = replacing
            ? VaultAddRequest(name: proposal.name, value: proposal.value, reason: SecretDetector.replaceReason)
            : VaultAddRequest(name: proposal.name, value: proposal.value,
                              tier: VaultTier(rawValue: SecretDetector.pastedTier), rules: SecretDetector.pastedRules)
        var response = await vault.broker.add(request, caller: composerCaller, trusted: replacing)
        if response.status == .pending { waiting = SecretDetector.waitingForApproval(proposal.name) }
        while response.status == .pending, let id = response.id {
            try? await Task.sleep(for: .seconds(1))
            response = await vault.broker.poll(id: id)
        }
        waiting = nil
        guard response.status == .granted else { return response.message }
        await vault.replica?.poke()
        return nil
    }

    private func reset() {
        proposals = []
        heldText = ""
        send = nil
        error = nil
        isSaving = false
        replaceName = nil
        waiting = nil
    }

    private func existingNames() async -> Set<String> {
        Set(((try? await vault.store.list()) ?? []).map(\.name))
    }
}

/// The offer shown above a composer: one editable name per secret, Yes / No.
/// Return or y saves, Esc or n sends unchanged. When a typed name is already
/// in the vault it asks whether to replace its value: r replaces, Esc or n
/// goes back to the names.
struct VaultSecretOfferBar: View {
    @Bindable var offer: VaultSecretOffer
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(offer.proposals.count == 1 ? "This prompt contains a secret. Save it to the vault?" : "This prompt contains \(offer.proposals.count) secrets. Save them to the vault?")
                .font(.app(.callout))
                .fontWeight(.semibold)
            ForEach($offer.proposals) { $proposal in
                HStack(spacing: 8) {
                    Image(systemName: "key.fill").foregroundStyle(.secondary)
                    TextField("Name", text: $proposal.name)
                        .textFieldStyle(.roundedBorder)
                        .font(.app(.callout).monospaced())
                        .frame(maxWidth: 260)
                        .onSubmit { offer.accept() }
                        .disabled(offer.isSaving || offer.replaceName != nil)
                    Text(Self.masked(proposal.value))
                        .font(.app(.caption).monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if let error = offer.error {
                Text(error).font(.app(.caption)).foregroundStyle(.red)
            }
            if let name = offer.replaceName {
                HStack {
                    Text(SecretDetector.replaceQuestion(name))
                        .font(.app(.callout))
                        .fontWeight(.semibold)
                    Spacer()
                    Button("Pick another name (n)") { offer.answerReplace(false) }
                    Button("Replace (r)") { offer.answerReplace(true) }
                        .buttonStyle(.borderedProminent)
                }
                Text("It keeps its tier, rules and label. Only the value changes.")
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
            } else if let waiting = offer.waiting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(waiting).font(.app(.caption)).foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    Text("Saved as judged secrets; the prompt gets {{vault:NAME}} instead.")
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("No, send as is (n)") { offer.decline() }
                        .disabled(offer.isSaving)
                    Button("Save and send (y)") { offer.accept() }
                        .buttonStyle(.borderedProminent)
                        .disabled(offer.isSaving)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.yellow.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.yellow.opacity(0.4)))
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(characters: CharacterSet(charactersIn: "yYnNrR")) { press in
            let key = press.characters.lowercased()
            if offer.replaceName != nil {
                if key == "r" { offer.answerReplace(true) } else if key == "n" { offer.answerReplace(false) }
            } else if key == "y" {
                offer.accept()
            } else if key == "n" {
                offer.decline()
            }
            return .handled
        }
        .onKeyPress(.return) { offer.accept(); return .handled }
        .onKeyPress(.escape) { offer.escape(); return .handled }
        .onChange(of: offer.replaceName) { _, name in
            // The name field is off while the question shows, so the keys go to the bar.
            if name != nil { focused = true }
        }
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    /// The first four characters and the length, never the value.
    static func masked(_ value: String) -> String {
        "\(value.prefix(4))... (\(value.count) chars)"
    }
}
