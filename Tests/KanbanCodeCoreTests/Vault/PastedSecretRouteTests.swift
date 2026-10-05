import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import KanbanCodeRemoteKit
import Testing
@testable import KanbanCodeCore

/// The phone's composer flow against a real server: list names, pick a free
/// one, add the pasted secret, send the prompt with a reference.
@Suite("Pasted secret over the remote vault API", .serialized)
struct PastedSecretRouteTests {
    static let key = "sk-proj-" + "Qm7vT2xLp9Rk4Wn8Zb3Hc6Yd1Fg5Js0Ae" + "_Uq-Vt8Nr2Mx"

    @Test func aPastedKeyIsSavedUnderAFreeNameAndTheStoredOneIsKept() async throws {
        let home = NSTemporaryDirectory() + "vault-paste-\(UUID().uuidString.prefix(8))"
        let vault = VaultService(
            kanbanHome: home, keys: MemoryVaultKeyProvider(), machine: "test", approvals: nil,
            cardTitle: { _ in nil }, cardSessions: { [:] }, peers: nil
        )
        try await vault.store.upsert(VaultSecret(name: "OPENAI_API_KEY", value: "stored-value", tier: .ask))
        let f = try await RemoteServerFixture(vault: vault)
        defer { f.shutdown() }
        let client = RemoteClient(baseURL: URL(string: f.base)!, token: f.fullToken)

        let text = "call the gateway with \(Self.key) and report back"
        let names = try await client.vaultSecretNames()
        #expect(names == ["OPENAI_API_KEY"])
        let offers = SecretDetector.proposals(in: text, existingNames: names)
        #expect(offers.map(\.name) == ["OPENAI_API_KEY_2"])

        let result = await Self.save(offers, in: text, names: names, client: client)
        #expect(result.error == nil)
        #expect(!result.text.contains(Self.key))
        #expect(result.text.hasPrefix("call the gateway with {{vault:OPENAI_API_KEY_2}} and report back\n\n"))

        let saved = try #require(try await vault.store.secret("OPENAI_API_KEY_2"))
        #expect(saved.value == Self.key)
        #expect(saved.tier == .judged)
        #expect(saved.rules == SecretDetector.pastedRules)
        #expect(try await vault.store.secret("OPENAI_API_KEY")?.value == "stored-value")
    }

    /// The phone's save, as `PhoneVault.save` does it.
    static func save(_ offers: [SecretProposal], in text: String, names: Set<String>, client: RemoteClient,
                     waiting: @escaping @Sendable () -> Void = {}) async -> SecretDetector.SaveResult {
        await SecretDetector.save(offers, in: text, existingNames: names) { p in
            (try? await client.compareVaultSecret(name: p.name, value: p.value)) ?? (names.contains(p.name) ? .different : .absent)
        } add: { p, replacing in
            let r = replacing
                ? try? await client.saveVaultSecret(name: p.name, value: p.value, reason: SecretDetector.replaceReason,
                                                    pollEvery: .milliseconds(20), waiting: waiting)
                : try? await client.addVaultSecret(name: p.name, value: p.value,
                                                   tier: SecretDetector.pastedTier, rules: SecretDetector.pastedRules)
            return r?.status == "granted" ? nil : (r?.message ?? "no answer")
        }
    }

    /// A vault holding METABASE_API_KEY as an ask secret with rules, a label
    /// and a tag, behind a real server, with approvals answered by `answer`.
    static func rotation(answer: String?) async throws -> (vault: VaultService, fixture: RemoteServerFixture, client: RemoteClient, approvals: AnsweringApprovals) {
        let home = NSTemporaryDirectory() + "vault-paste-\(UUID().uuidString.prefix(8))"
        let approvals = AnsweringApprovals(answer: answer)
        let vault = VaultService(
            kanbanHome: home, keys: MemoryVaultKeyProvider(), machine: "test", approvals: approvals,
            cardTitle: { _ in nil }, cardSessions: { [:] }, peers: nil
        )
        await vault.broker.configure(pollInterval: 0.02)
        try await vault.store.upsert(VaultSecret(name: "METABASE_API_KEY", value: "old-value", tier: .ask,
                                                 rules: "Only for the metrics job.", tags: ["metabase"], label: "Metabase"))
        let f = try await RemoteServerFixture(vault: vault)
        return (vault, f, RemoteClient(baseURL: URL(string: f.base)!, token: f.fullToken), approvals)
    }

    static let text = "METABASE_API_KEY=\(key) is the new one"

    @Test func aTypedStoredNameAsksAndReplaceKeepsTheTierRulesLabelAndTags() async throws {
        let (vault, f, client, approvals) = try await Self.rotation(answer: "Allow")
        defer { f.shutdown() }
        let names = try await client.vaultSecretNames()
        var offers = SecretDetector.proposals(in: Self.text, existingNames: names)
        #expect(offers.map(\.name) == ["METABASE_API_KEY_2"])
        offers[0].name = "METABASE_API_KEY"

        let asked = await Self.save(offers, in: Self.text, names: names, client: client)
        #expect(asked.replace == "METABASE_API_KEY")
        #expect(try await vault.store.secret("METABASE_API_KEY")?.value == "old-value")
        #expect(try await vault.store.secret("METABASE_API_KEY_2") == nil)
        #expect(await approvals.raised == 0)

        let waited = WaitFlag()
        let result = await Self.save(SecretDetector.answeringReplace(asked.remaining, replace: true), in: asked.text,
                                     names: names, client: client, waiting: { waited.set() })
        #expect(result.error == nil && result.replace == nil)
        #expect(result.text.hasPrefix("METABASE_API_KEY={{vault:METABASE_API_KEY}} is the new one\n\n"))
        #expect(waited.isSet)
        #expect(await approvals.raised == 1)

        let saved = try #require(try await vault.store.secret("METABASE_API_KEY"))
        #expect(saved.value == Self.key)
        #expect(saved.tier == .ask)
        #expect(saved.rules == "Only for the metrics job.")
        #expect(saved.label == "Metabase")
        #expect(saved.tags == ["metabase"])
        #expect(try await vault.store.secret("METABASE_API_KEY_2") == nil)
    }

    @Test func aDeniedReplaceKeepsTheStoredValueAndThePromptUnsent() async throws {
        let (vault, f, client, _) = try await Self.rotation(answer: "Deny")
        defer { f.shutdown() }
        let names = try await client.vaultSecretNames()
        var offers = SecretDetector.proposals(in: Self.text, existingNames: names)
        offers[0].name = "METABASE_API_KEY"
        offers[0].replaces = "METABASE_API_KEY"
        let result = await Self.save(offers, in: Self.text, names: names, client: client)
        #expect(result.error?.hasPrefix("Could not replace METABASE_API_KEY: ") == true)
        #expect(result.text == Self.text)
        #expect(result.remaining.count == 1)
        #expect(try await vault.store.secret("METABASE_API_KEY")?.value == "old-value")
    }

    @Test func aTypedStoredNameThatHoldsThePastedValueIsUsedAsItIs() async throws {
        let (vault, f, client, approvals) = try await Self.rotation(answer: nil)
        defer { f.shutdown() }
        try await vault.store.upsert(VaultSecret(name: "METABASE_KEY_COPY", value: Self.key, tier: .judged, rules: "Kept."))
        let names = try await client.vaultSecretNames()
        #expect(try await client.compareVaultSecret(name: "METABASE_KEY_COPY", value: Self.key) == .same)
        #expect(try await client.compareVaultSecret(name: "METABASE_API_KEY", value: Self.key) == .different)
        #expect(try await client.compareVaultSecret(name: "NOT_THERE", value: Self.key) == .absent)

        var offers = SecretDetector.proposals(in: Self.text, existingNames: names)
        offers[0].name = "METABASE_KEY_COPY"
        let before = try #require(try await vault.store.secret("METABASE_KEY_COPY"))
        let result = await Self.save(offers, in: Self.text, names: names, client: client)
        #expect(result.error == nil && result.replace == nil)
        #expect(result.text.hasPrefix("METABASE_API_KEY={{vault:METABASE_KEY_COPY}} is the new one\n\n"))
        #expect(try await vault.store.secret("METABASE_KEY_COPY") == before)
        #expect(await approvals.raised == 0)
    }
}

/// Approvals answered at once with `answer`, or never when it is nil.
actor AnsweringApprovals: VaultApprovals {
    let answer: String?
    private(set) var raised = 0
    init(answer: String?) { self.answer = answer }
    func raise(_ request: AttentionRequest) async { raised += 1 }
    func resolution(of id: String) async -> (resolution: String?, by: String)? {
        answer.map { ($0, "test") }
    }
    func close(id: String, resolution: String, by: String) async {}
}

final class WaitFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
