import SwiftUI
import KanbanCodeRemoteKit

/// A prompt held back because it carries secrets, waiting for Yes or No.
struct PendingSecretOffer {
    var text: String
    var mode: RemotePromptRequest.Mode
    var proposals: [SecretProposal]
    var error: String?
    var isSaving = false
    /// The stored name the first offer was typed as, while the user decides
    /// whether to replace its value.
    var replaceName: String?
    /// What the save waits on, when the vault asked for an approval.
    var waiting: String?
}

/// Saves secrets through the master's vault. A new name is stored at once.
/// A stored name the user agreed to replace gets only the new value, so it
/// keeps its tier, rules, label and tags; the vault asks for an approval
/// first, and `waiting` is called with what to show until it is answered.
enum PhoneVault {
    static func save(_ offer: PendingSecretOffer, client: RemoteClient,
                     waiting: @MainActor @escaping (String) -> Void) async -> SecretDetector.SaveResult {
        let names = (try? await client.vaultSecretNames()) ?? []
        return await SecretDetector.save(offer.proposals, in: offer.text, existingNames: names) { proposal in
            // A master without the compare route still knows its names.
            if let match = try? await client.compareVaultSecret(name: proposal.name, value: proposal.value) { return match }
            return names.contains(proposal.name) ? .different : .absent
        } add: { proposal, replacing in
            do {
                let r = replacing
                    ? try await client.saveVaultSecret(name: proposal.name, value: proposal.value,
                                                       reason: SecretDetector.replaceReason) {
                        Task { @MainActor in waiting(SecretDetector.waitingForApproval(proposal.name)) }
                    }
                    : try await client.addVaultSecret(name: proposal.name, value: proposal.value,
                                                      tier: SecretDetector.pastedTier, rules: SecretDetector.pastedRules)
                switch r.status {
                case "granted": return nil
                case "pending": return "the vault asked for approval (\(r.message))"
                default: return r.message
                }
            } catch {
                return error.localizedDescription
            }
        }
    }
}

/// The offer above the composer: one editable name per secret, Yes / No.
/// A typed name the vault already holds asks before its value is replaced.
struct VaultSecretOfferCard: View {
    @Binding var offer: PendingSecretOffer
    let onSave: () -> Void
    let onSendAsIs: () -> Void
    /// The answer to "Replace its value?": true replaces, false goes back to the names.
    let onReplace: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(offer.proposals.count == 1 ? "This prompt contains a secret. Save it to the vault?"
                                             : "This prompt contains \(offer.proposals.count) secrets. Save them to the vault?",
                  systemImage: "key.fill")
                .font(.subheadline.weight(.semibold))
            ForEach($offer.proposals) { $proposal in
                VStack(alignment: .leading, spacing: 2) {
                    TextField("Name", text: $proposal.name)
                        .font(.callout.monospaced())
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("vaultSecretName")
                        .disabled(offer.isSaving || offer.replaceName != nil)
                    Text("\(proposal.value.prefix(4))... (\(proposal.value.count) chars)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            if let error = offer.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if let name = offer.replaceName {
                Text(SecretDetector.replaceQuestion(name))
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("vaultReplaceQuestion")
                Text("It keeps its tier, rules and label. Only the value changes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Pick another name") { onReplace(false) }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("vaultPickAnotherName")
                    Spacer()
                    Button("Replace") { onReplace(true) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("vaultReplace")
                }
            } else if let waiting = offer.waiting {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(waiting).font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("vaultWaitingForApproval")
            } else {
                HStack {
                    Button("Send as is", action: onSendAsIs)
                        .buttonStyle(.bordered)
                        .disabled(offer.isSaving)
                        .accessibilityIdentifier("vaultSendAsIs")
                    Spacer()
                    Button(action: onSave) {
                        if offer.isSaving { ProgressView() } else { Text("Save and send") }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(offer.isSaving)
                    .accessibilityIdentifier("vaultSaveAndSend")
                }
            }
        }
        .padding(12)
        .background(Color.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("vaultSecretOffer")
    }
}
