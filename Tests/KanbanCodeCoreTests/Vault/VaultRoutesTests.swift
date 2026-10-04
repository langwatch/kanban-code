import Foundation
import Testing
@testable import KanbanCodeCore
import KanbanCodeRemoteKit

@Suite("Vault routes", .serialized)
struct VaultRoutesTests {
    private func fixture() async throws -> (RemoteServerFixture, VaultService) {
        let home = NSTemporaryDirectory() + "vault-routes-\(UUID().uuidString.prefix(8))"
        let vault = VaultService(
            kanbanHome: home, keys: MemoryVaultKeyProvider(), machine: "test", approvals: nil,
            cardTitle: { _ in nil }, cardSessions: { [:] }, peers: nil
        )
        try await vault.store.upsert(VaultSecret(name: "OPEN", value: "open-value", tier: .open))
        return (try await RemoteServerFixture(vault: vault), vault)
    }

    @Test func aLoopbackCallerOutsideACardGetsOpenSecretsAndNothingThatAsks() async throws {
        let (f, vault) = try await fixture()
        defer { f.shutdown() }
        try await vault.store.upsert(VaultSecret(name: "ASK", value: "ask-value", tier: .ask))
        let open = try JSONEncoder().encode(VaultReleaseRequest(mode: "run", names: ["OPEN"], cardId: "card_fake"))
        let (status, data) = try await f.request("POST", "/v1/vault/release", body: open)
        #expect(status == 200)
        #expect(String(decoding: data, as: UTF8.self).contains("open-value"))
        let line = try #require(await vault.store.log(limit: 1, secret: "OPEN").first)
        #expect(line.cardId == "unverified:card_fake" && line.detail?.hasPrefix("open tier, outside any card session") == true)

        let ask = try JSONEncoder().encode(VaultReleaseRequest(mode: "run", names: ["ASK"], cardId: "card_fake"))
        let (askStatus, askData) = try await f.request("POST", "/v1/vault/release", body: ask)
        #expect(askStatus == 403)
        let text = String(decoding: askData, as: UTF8.self)
        #expect(text.contains("human approval") && !text.contains("ask-value"))
        // Other routes still want a token.
        #expect(try await f.request("GET", "/v1/board").0 == 401)
    }

    @Test func listingsNeverCarryValues() async throws {
        let (f, _) = try await fixture()
        defer { f.shutdown() }
        let (status, data) = try await f.request("GET", "/v1/vault/secrets")
        #expect(status == 200)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"OPEN\"") && !text.contains("open-value"))
    }

    @Test func theReplicaIsForFullScopePeers() async throws {
        let (f, vault) = try await fixture()
        defer { f.shutdown() }
        #expect(try await f.request("GET", "/v1/vault/replica").0 == 403)
        #expect(try await f.request("GET", "/v1/vault/replica", token: f.agentToken).0 == 403)
        let (status, data) = try await f.request("GET", "/v1/vault/replica", token: f.fullToken)
        #expect(status == 200)
        let body = try JSONDecoder().decode(VaultReplicaBody.self, from: data)
        #expect(body.blob.flatMap { Data(base64Encoded: $0) } == (await vault.store.encryptedBlob()))
    }

    @Test func vaultHookInstallsOnce() throws {
        let dir = NSTemporaryDirectory() + "vault-hook-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let settings = dir + "/settings.json"
        try #"{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"x"}]}]},"model":"m"}"#
            .write(toFile: settings, atomically: true, encoding: .utf8)
        #expect(try VaultHook.install(settingsPath: settings, scriptPath: dir + "/.kanban-code/vault-hook.sh"))
        #expect(try !VaultHook.install(settingsPath: settings, scriptPath: dir + "/.kanban-code/vault-hook.sh"))
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: settings))) as! [String: Any]
        let hooks = root["hooks"] as! [String: Any]
        #expect((hooks["PreToolUse"] as! [[String: Any]]).count == 1)
        #expect(hooks["Stop"] != nil && root["model"] as? String == "m")
    }

    @Test func codexTrustHashMatchesCodex() {
        // Reference: sha256 of Codex's compact, key-sorted hook identity JSON.
        #expect(VaultHook.codexTrustHash(matcher: "Bash", command: "/h/.kanban-code/vault-hook.sh --codex", timeout: 900)
            == "sha256:1a967e97b4d3ff8483ba90c515b21e38ae12da4f572437f00a5fe287481a86de")
    }

    @Test func codexHookInstallsAndTrustsOnce() throws {
        let home = NSTemporaryDirectory() + "codex-home-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        try #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"x"}]}]}}"#
            .write(toFile: home + "/hooks.json", atomically: true, encoding: .utf8)
        try "model = \"m\"\n\n[projects.\"/x\"]\ntrust_level = \"trusted\"\n"
            .write(toFile: home + "/config.toml", atomically: true, encoding: .utf8)
        let script = home + "/k/vault-hook.sh"
        #expect(try VaultHook.installCodex(codexHome: home, scriptPath: script))
        #expect(try !VaultHook.installCodex(codexHome: home, scriptPath: script))
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: home + "/hooks.json"))) as! [String: Any]
        let hooks = root["hooks"] as! [String: Any]
        let pre = hooks["PreToolUse"] as! [[String: Any]]
        #expect(pre.count == 1 && hooks["Stop"] != nil)
        let config = try String(contentsOfFile: home + "/config.toml", encoding: .utf8)
        let hash = VaultHook.codexTrustHash(matcher: "Bash", command: script + " --codex", timeout: 900)
        #expect(config.hasPrefix("model = \"m\"\n\n[projects.\"/x\"]"))
        #expect(config.contains("[hooks.state.\"\(home)/hooks.json:pre_tool_use:0:0\"]\ntrusted_hash = \"\(hash)\""))
    }

    @Test func codexTrustReplacesAStaleHash() {
        let key = "/c/hooks.json:pre_tool_use:0:0"
        let stale = "a = 1\n\n[hooks.state.\"\(key)\"]\nenabled = true\ntrusted_hash = \"sha256:old\"\n\n[b]\nc = 2\n"
        let out = VaultHook.trustingCodexHook(config: stale, key: key, hash: "sha256:new")
        #expect(out == stale.replacingOccurrences(of: "sha256:old", with: "sha256:new"))
        #expect(VaultHook.trustingCodexHook(config: out, key: key, hash: "sha256:new") == out)
    }
}
