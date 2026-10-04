import Foundation
import Testing
@testable import KanbanCodeCore
import KanbanCodeRemoteKit

private func tempDir(_ prefix: String = "vaultp") -> String {
    let path = NSTemporaryDirectory() + "\(prefix)-\(UUID().uuidString.prefix(8))"
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return (path as NSString).resolvingSymlinksInPath
}

private func mkdir(_ path: String) {
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
}

private func write(_ path: String, _ text: String = "") {
    mkdir((path as NSString).deletingLastPathComponent)
    FileManager.default.createFile(atPath: path, contents: Data(text.utf8))
}

/// Counts the questions and answers each by its rules text.
private final class CountingJev: JevJudging, @unchecked Sendable {
    let lock = NSLock()
    var questions: [JevReleaseQuestion] = []
    var answers: [String: JevVerdict.Choice] = [:]

    func judge(_ question: JevReleaseQuestion) async -> JevVerdict? {
        lock.withLock { questions.append(question) }
        return JevVerdict(choice: lock.withLock { answers[question.rules] } ?? .allow, confidence: 0.95)
    }
}

private func card(cwd: String?, byToken: Bool? = nil) -> VaultCaller {
    VaultCaller(cardId: "card_1", sessionId: "s1", pid: 42, ancestry: ["kv", "zsh"], cwd: cwd, byToken: byToken)
}

private func makeStore() async throws -> VaultStore {
    let store = VaultStore(directory: tempDir("vault"), keys: MemoryVaultKeyProvider())
    try await store.ensureIdentity()
    return store
}

@Suite("Vault projects and environments")
struct VaultProjectsTests {
    // MARK: Names

    @Test func namesSplitIntoProjectEnvironmentAndKey() {
        #expect(VaultSecretName("OPENAI_API_KEY") == VaultSecretName(key: "OPENAI_API_KEY"))
        #expect(VaultSecretName("OPENAI_API_KEY").project == nil)
        let own = VaultSecretName("shop/dev/OPENAI_API_KEY")
        #expect(own.project == "shop" && own.environment == "dev" && own.key == "OPENAI_API_KEY")
        let sub = VaultSecretName("shop/api/prod/DATABASE_URL")
        #expect(sub.project == "shop/api" && sub.environment == "prod" && sub.key == "DATABASE_URL")
        #expect(VaultSecretName("aws:lw-prod:read").key == "aws:lw-prod:read")
        #expect(VaultSecretName("a/b").project == nil)
        #expect(VaultSecretName(key: "K", project: "shop").canonical == "shop/dev/K")
        #expect(VaultSecretName(key: "K", project: "shop", environment: "prod").canonical == "shop/prod/K")
        #expect(VaultSecretName(key: "K", environment: "prod").canonical == "K")
    }

    @Test func labelsNameTheProjectAndEnvironment() {
        #expect(AttentionCopy.secretLabel(name: "shop/dev/OPENAI_API_KEY") == "OpenAI API key · shop · dev")
        #expect(AttentionCopy.secretLabel(name: "shop/api/prod/DATABASE_URL", label: "Shop database") == "Shop database · shop/api · prod")
        #expect(AttentionCopy.secretLabel(name: "OPENAI_API_KEY") == "OpenAI API key")
        let info = VaultSecret(name: "shop/dev/OPENAI_API_KEY", value: "v", tier: .open).info
        #expect(info.key == "OPENAI_API_KEY" && info.project == "shop" && info.environment == "dev")
        #expect(info.displayLabel == "OpenAI API key · shop · dev")
    }

    // MARK: Folders

    @Test func aFolderIsTheProjectOfItsRepository() {
        let home = tempDir("home")
        let repo = home + "/Projects/shop"
        mkdir(repo + "/.git")
        mkdir(repo + "/api/src")
        #expect(VaultProjects.candidates(forPath: repo, home: home) == ["shop"])
        #expect(VaultProjects.candidates(forPath: repo + "/api/src", home: home) == ["shop/api/src", "shop/api", "shop"])
        #expect(VaultProjects.candidates(forPath: nil, home: home).isEmpty)
        #expect(VaultProjects.candidates(forPath: home, home: home).isEmpty)
    }

    @Test func aWorktreeIsTheProjectOfItsMainCheckout() {
        let home = tempDir("home")
        let repo = home + "/Projects/shop"
        mkdir(repo + "/.git/worktrees/fix")
        let tree = home + "/Projects/shop-worktrees/fix"
        write(tree + "/.git", "gitdir: \(repo)/.git/worktrees/fix\n")
        mkdir(tree + "/api")
        #expect(VaultProjects.candidates(forPath: tree, home: home) == ["shop"])
        #expect(VaultProjects.candidates(forPath: tree + "/api", home: home) == ["shop/api", "shop"])
    }

    @Test func aSubmoduleIsASubfolderOfTheRepositoryThatHoldsIt() {
        let home = tempDir("home")
        let repo = home + "/Projects/shop"
        mkdir(repo + "/.git/modules/engine")
        write(repo + "/engine/.git", "gitdir: ../.git/modules/engine\n")
        mkdir(repo + "/engine/nlp")
        #expect(VaultProjects.candidates(forPath: repo + "/engine/nlp", home: home) == ["shop/engine/nlp", "shop/engine", "shop"])
    }

    @Test func outsideARepositoryTheManifestFolderIsTheRoot() {
        let home = tempDir("home")
        let dir = home + "/Projects/local/my tool"
        write(dir + "/.env.vault", "A\n")
        mkdir(dir + "/src")
        #expect(VaultProjects.candidates(forPath: dir + "/src", home: home) == ["my-tool/src", "my-tool"])
        let bare = home + "/Projects/scratch"
        mkdir(bare)
        #expect(VaultProjects.candidates(forPath: bare, home: home) == ["scratch"])
    }

    @Test func anOverrideFileNamesTheProject() {
        let home = tempDir("home")
        let repo = home + "/Projects/local/opensource/shop"
        mkdir(repo + "/.git")
        write(repo + "/.vault-project", "shop-opensource\n")
        mkdir(repo + "/api")
        #expect(VaultProjects.candidates(forPath: repo + "/api", home: home) == ["shop-opensource/api", "shop-opensource"])
    }

    // MARK: Store

    @Test func oldNamesKeepResolvingAfterARename() async throws {
        let store = try await makeStore()
        try await store.upsert(VaultSecret(name: "OPENAI_API_KEY__SHOP", value: "v1", tier: .judged, sources: ["a"]))
        try await store.grantLease(VaultLease(cardId: "card_1", secret: "OPENAI_API_KEY__SHOP",
                                               expiresAt: Date().addingTimeInterval(600), grantedBy: "human:test"))
        #expect(try await store.rename(from: "OPENAI_API_KEY__SHOP", to: "shop/dev/OPENAI_API_KEY") == .rename)
        let renamed = try #require(try await store.secret("OPENAI_API_KEY__SHOP"))
        #expect(renamed.name == "shop/dev/OPENAI_API_KEY" && renamed.value == "v1")
        #expect(renamed.aliases == ["OPENAI_API_KEY__SHOP"])
        #expect(try await store.list().map(\.name) == ["shop/dev/OPENAI_API_KEY"])
        #expect(await store.activeLease(cardId: "card_1", secret: "shop/dev/OPENAI_API_KEY") != nil)
        #expect(try await store.rename(from: "OPENAI_API_KEY__SHOP", to: "shop/dev/OPENAI_API_KEY") == .same)
    }

    @Test func aRenameOntoTheSameValueMergesAndOntoAnotherConflicts() async throws {
        let store = try await makeStore()
        try await store.upsert(VaultSecret(name: "K", value: "same", tier: .open, sources: ["a"]))
        try await store.upsert(VaultSecret(name: "K__ONE", value: "same", tier: .ask, sources: ["b"]))
        try await store.upsert(VaultSecret(name: "K__TWO", value: "other", tier: .open))
        #expect(try await store.renameOutcome(from: "K__ONE", to: "K") == .merge)
        #expect(try await store.rename(from: "K__ONE", to: "K") == .merge)
        let merged = try #require(try await store.secret("K"))
        #expect(merged.tier == .ask && merged.sources == ["a", "b"] && merged.aliases == ["K__ONE"])
        #expect(try await store.rename(from: "K__TWO", to: "K") == .conflict)
        #expect(try await store.secret("K__TWO")?.value == "other")
        #expect(try await store.rename(from: "GONE", to: "K") == .missing)
    }

    @Test func aRenameReachesTheOtherReplicaAsATombstoneAndAnAlias() async throws {
        let keys = MemoryVaultKeyProvider(Age.Identity.generate())
        let box = VaultStore(directory: tempDir("vault"), keys: keys)
        let mac = VaultStore(directory: tempDir("vault"), keys: keys)
        try await box.upsert(VaultSecret(name: "K__SHOP", value: "v", tier: .open), now: Date(timeIntervalSince1970: 100))
        try await mac.mergeReplica(try #require(await box.encryptedBlob()))
        try await box.rename(from: "K__SHOP", to: "shop/dev/K", now: Date(timeIntervalSince1970: 200))
        try await mac.mergeReplica(try #require(await box.encryptedBlob()))
        #expect(try await mac.list().map(\.name) == ["shop/dev/K"])
        #expect(try await mac.secret("K__SHOP")?.value == "v")
    }

    @Test func fingerprintsMatchForEqualValuesOnly() async throws {
        let store = try await makeStore()
        try await store.upsert(VaultSecret(name: "A", value: "one", tier: .open))
        try await store.upsert(VaultSecret(name: "B", value: "one", tier: .open))
        try await store.upsert(VaultSecret(name: "C", value: "two", tier: .open))
        let prints = Dictionary(uniqueKeysWithValues: try await store.list().map { ($0.name, $0.fingerprint) })
        #expect(prints["A"] == prints["B"] && prints["A"] != prints["C"] && prints["A"]??.count == 16)
    }

    // MARK: Manifest resolution

    private func manifestBroker(jev: (any JevJudging)? = nil) async throws -> (VaultBroker, VaultStore) {
        let store = try await makeStore()
        try await store.upsert(VaultSecret(name: "OPENAI_API_KEY", value: "shared-openai", tier: .open))
        try await store.upsert(VaultSecret(name: "SHARED_ONLY", value: "shared-only", tier: .open))
        try await store.upsert(VaultSecret(name: "shop/dev/OPENAI_API_KEY", value: "shop-openai", tier: .open))
        try await store.upsert(VaultSecret(name: "shop/dev/DATABASE_URL", value: "shop-db", tier: .open))
        try await store.upsert(VaultSecret(name: "shop/prod/DATABASE_URL", value: "shop-prod-db", tier: .open))
        try await store.upsert(VaultSecret(name: "shop/api/dev/DATABASE_URL", value: "api-db", tier: .open))
        let broker = VaultBroker(store: store, jev: jev, approvals: nil, machine: "test")
        await broker.configure(projectsOf: { path in
            switch path {
            case "/p/shop": ["shop"]
            case "/p/shop/api": ["shop/api", "shop"]
            case "/p/shop/web": ["shop/web", "shop"]
            case "/p/other": ["other"]
            default: []
            }
        })
        return (broker, store)
    }

    @Test func aBareKeyTakesTheProjectValueThenTheSharedOne() async throws {
        let (broker, _) = try await manifestBroker()
        let shop = await broker.release(.init(mode: "env", names: [], keys: ["OPENAI_API_KEY", "SHARED_ONLY"], dir: "/p/shop"),
                                        caller: card(cwd: "/p/shop"))
        #expect(shop.env == ["OPENAI_API_KEY": "shop-openai", "SHARED_ONLY": "shared-only"])
        #expect(shop.resolved?["OPENAI_API_KEY"] == "shop/dev/OPENAI_API_KEY")
        let other = await broker.release(.init(mode: "env", names: [], keys: ["OPENAI_API_KEY"], dir: "/p/other"),
                                         caller: card(cwd: "/p/other"))
        #expect(other.env == ["OPENAI_API_KEY": "shared-openai"])
        let missing = await broker.release(.init(mode: "env", names: [], keys: ["NOPE"], dir: "/p/shop"), caller: card(cwd: "/p/shop"))
        #expect(missing.status == .denied && missing.message.contains("no secret NOPE for shop (dev)"))
    }

    @Test func theGroupIsTheProjectsOwnSecretsForTheEnvironment() async throws {
        let (broker, _) = try await manifestBroker()
        let dev = await broker.release(.init(mode: "env", names: [], group: true, dir: "/p/shop"), caller: card(cwd: "/p/shop"))
        #expect(dev.env == ["OPENAI_API_KEY": "shop-openai", "DATABASE_URL": "shop-db"])
        let prod = await broker.release(.init(mode: "env", names: [], group: true, dir: "/p/shop", environment: "prod"),
                                        caller: card(cwd: "/p/shop"))
        #expect(prod.env == ["DATABASE_URL": "shop-prod-db"])
        // A subfolder with secrets of its own gets those, not its parent's.
        let api = await broker.release(.init(mode: "env", names: [], group: true, dir: "/p/shop/api"), caller: card(cwd: "/p/shop/api"))
        #expect(api.env == ["DATABASE_URL": "api-db"])
        // A manifest's folder without secrets of its own gets no group;
        // a folder without a manifest gets the nearest project's.
        let web = await broker.release(.init(mode: "env", names: [], group: true, dir: "/p/shop/web"), caller: card(cwd: "/p/shop/web"))
        #expect(web.env == [:])
        let deep = await broker.release(.init(mode: "env", names: [], group: true, dir: "/p/shop/web", nearest: true),
                                        caller: card(cwd: "/p/shop/web"))
        #expect(deep.env == ["OPENAI_API_KEY": "shop-openai", "DATABASE_URL": "shop-db"])
        // A project without secrets of its own gets an empty group, not an error.
        let none = await broker.release(.init(mode: "env", names: [], group: true, dir: "/p/other"), caller: card(cwd: "/p/other"))
        #expect(none.status == .granted && none.env == [:])
        // What the manifest sets itself is left out of the group.
        let partly = await broker.release(.init(mode: "env", names: ["shop/prod/DATABASE_URL"], group: true, defined: ["DATABASE_URL"],
                                                dir: "/p/shop"), caller: card(cwd: "/p/shop"))
        #expect(partly.env == ["OPENAI_API_KEY": "shop-openai"])
        #expect(partly.values == ["shop/prod/DATABASE_URL": "shop-prod-db"])
    }

    @Test func aNamedProjectReplacesTheFoldersProject() async throws {
        let (broker, _) = try await manifestBroker()
        let r = await broker.release(.init(mode: "env", names: [], group: true, dir: "/p/other", project: "shop"),
                                     caller: card(cwd: "/p/other"))
        #expect(r.env?["DATABASE_URL"] == "shop-db")
    }

    @Test func anOldNameIsAnsweredUnderTheNameAsked() async throws {
        let (broker, store) = try await manifestBroker()
        try await store.upsert(VaultSecret(name: "TOKEN__SHOP", value: "tok", tier: .open))
        try await store.rename(from: "TOKEN__SHOP", to: "shop/dev/TOKEN")
        let r = await broker.release(.init(mode: "run", names: ["TOKEN__SHOP"]), caller: card(cwd: "/p/other"))
        #expect(r.values == ["TOKEN__SHOP": "tok"])
        #expect(await store.log().first?.secret == "shop/dev/TOKEN")
        let names = await broker.resolve(.init(mode: "env", names: ["TOKEN__SHOP"], keys: ["DATABASE_URL"], dir: "/p/shop"))
        #expect(names.resolved == ["TOKEN__SHOP": "shop/dev/TOKEN", "DATABASE_URL": "shop/dev/DATABASE_URL"])
        #expect(names.values == nil && names.env == nil)
    }

    @Test func addStoresUnderTheProjectAndEnvironment() async throws {
        let (broker, store) = try await manifestBroker()
        let own = await broker.add(.init(name: "NEW_KEY", value: "v", project: ".", environment: "prod", dir: "/p/shop"),
                                   caller: card(cwd: "/p/shop"), trusted: false)
        #expect(own.message == "added shop/prod/NEW_KEY")
        #expect(try await store.secret("shop/prod/NEW_KEY")?.value == "v")
        let named = await broker.add(.init(name: "NEW_KEY", value: "v2", project: "other"), caller: card(cwd: nil), trusted: false)
        #expect(named.message == "added other/dev/NEW_KEY")
        let nowhere = await broker.add(.init(name: "NEW_KEY", value: "v", project: ".", dir: "/nowhere"), caller: card(cwd: nil), trusted: false)
        #expect(nowhere.status == .denied)
        #expect(try await store.list(project: "shop").map(\.name).contains("shop/prod/NEW_KEY"))
        #expect(try await store.list(project: "other").map(\.name) == ["other/dev/NEW_KEY"])
    }

    // MARK: The project's own development secrets

    private func policyBroker() async throws -> (VaultBroker, VaultStore, CountingJev) {
        let store = try await makeStore()
        try await store.upsert(VaultSecret(name: "shop/dev/API_KEY", value: "dev", tier: .judged))
        try await store.upsert(VaultSecret(name: "shop/prod/API_KEY", value: "prod", tier: .judged))
        try await store.upsert(VaultSecret(name: "shop/dev/RULED", value: "ruled", tier: .judged, rules: "deploys only"))
        try await store.upsert(VaultSecret(name: "shop/dev/EVERY", value: "every", tier: .ask, leasePolicy: .everyUse))
        try await store.upsert(VaultSecret(name: "shop/dev/ASKS", value: "asks", tier: .ask))
        try await store.upsert(VaultSecret(name: "shop/dev/NEVER", value: "never", tier: .never))
        try await store.upsert(VaultSecret(name: "API_KEY", value: "shared", tier: .judged))
        let jev = CountingJev()
        let broker = VaultBroker(store: store, jev: jev, approvals: nil, machine: "test")
        await broker.configure(projectsOf: { $0 == "/p/shop" || $0 == "/p/shop-worktrees/fix" ? ["shop"] : ($0 == "/p/other" ? ["other"] : []) })
        return (broker, store, jev)
    }

    @Test func aCardInTheProjectGetsItsDevelopmentSecretWithoutJev() async throws {
        let (broker, store, jev) = try await policyBroker()
        let r = await broker.release(.init(mode: "run", names: ["shop/dev/API_KEY"]), caller: card(cwd: "/p/shop"))
        #expect(r.status == .granted && r.values == ["shop/dev/API_KEY": "dev"])
        #expect(jev.questions.isEmpty)
        let entry = try #require(await store.log().first)
        #expect(entry.decider == .rule && entry.detail == VaultPolicy.ownProjectDevReason)
        // A worktree of the project counts as the project.
        let tree = await broker.release(.init(mode: "run", names: ["shop/dev/API_KEY"]), caller: card(cwd: "/p/shop-worktrees/fix"))
        #expect(tree.status == .granted && jev.questions.isEmpty)
    }

    @Test func theFolderTheCallerClaimsDoesNotCount() async throws {
        let (broker, _, jev) = try await policyBroker()
        _ = await broker.release(.init(mode: "run", names: ["shop/dev/API_KEY"], cwd: "/p/shop", dir: "/p/shop"), caller: card(cwd: "/p/other"))
        #expect(jev.questions.count == 1)
        _ = await broker.release(.init(mode: "run", names: ["shop/dev/API_KEY"], cwd: "/p/shop"), caller: card(cwd: nil))
        #expect(jev.questions.count == 2)
    }

    @Test func otherSecretsKeepTheirPath() async throws {
        let (broker, _, jev) = try await policyBroker()
        let inShop = card(cwd: "/p/shop")
        _ = await broker.release(.init(mode: "run", names: ["shop/prod/API_KEY"]), caller: inShop)
        #expect(jev.questions.map(\.secrets) == [["shop/prod/API_KEY"]])
        _ = await broker.release(.init(mode: "run", names: ["shop/dev/RULED"]), caller: inShop)
        #expect(jev.questions.count == 2)
        _ = await broker.release(.init(mode: "run", names: ["API_KEY"]), caller: inShop)
        #expect(jev.questions.count == 3)
        // ask and never are decided before the project is looked at.
        let asks = await broker.release(.init(mode: "run", names: ["shop/dev/ASKS"]), caller: inShop)
        #expect(asks.status == .denied && asks.message.contains("cannot ask"))
        let every = await broker.release(.init(mode: "run", names: ["shop/dev/EVERY"]), caller: inShop)
        #expect(every.status == .denied)
        let never = await broker.release(.init(mode: "run", names: ["shop/dev/NEVER"]), caller: inShop)
        #expect(never.status == .denied && never.message.contains("never released"))
        #expect(jev.questions.count == 3)
    }

    @Test func onlyACardGetsThePolicy() async throws {
        let dev = VaultSecret(name: "shop/dev/API_KEY", value: "v", tier: .judged)
        #expect(VaultPolicy.isOwnProjectDev(dev, caller: card(cwd: "/p/shop"), callerProjects: ["shop/api", "shop"]))
        #expect(!VaultPolicy.isOwnProjectDev(dev, caller: card(cwd: "/p/other"), callerProjects: ["other"]))
        let outside = VaultCaller(claimedCardId: "card_1", pid: 1, cwd: "/p/shop")
        #expect(!VaultPolicy.isOwnProjectDev(dev, caller: outside, callerProjects: ["shop"]))
        let agent = VaultCaller(cardId: VaultCaller.openClawPrincipal(agent: "main"), cwd: "/p/shop")
        #expect(!VaultPolicy.isOwnProjectDev(dev, caller: agent, callerProjects: ["shop"]))
        let remote = VaultCaller(cardId: "card_1", remoteDevice: "phone", cwd: "/p/shop")
        #expect(!VaultPolicy.isOwnProjectDev(dev, caller: remote, callerProjects: ["shop"]))
        #expect(VaultPolicy.decide(.init(tier: .judged, insideCard: true, ownProjectDev: true)) == .allow(.rule, VaultPolicy.ownProjectDevReason))
        #expect(VaultPolicy.decide(.init(tier: .ask, insideCard: true, ownProjectDev: true)) == .ask("this secret always asks"))
        #expect(VaultPolicy.decide(.init(tier: .judged, insideCard: false)) == .consultJev)
    }

    // MARK: Jev batching

    @Test func jevGetsOneQuestionPerRulesText() async throws {
        let store = try await makeStore()
        for i in 1...6 { try await store.upsert(VaultSecret(name: "PLAIN_\(i)", value: "p\(i)", tier: .judged)) }
        for i in 1...3 { try await store.upsert(VaultSecret(name: "DEPLOY_\(i)", value: "d\(i)", tier: .judged, rules: "deploys only")) }
        let jev = CountingJev()
        jev.answers["deploys only"] = .deny
        let broker = VaultBroker(store: store, jev: jev, approvals: nil, machine: "test")
        let names = (1...6).map { "PLAIN_\($0)" } + (1...3).map { "DEPLOY_\($0)" }
        let r = await broker.release(.init(mode: "hook", names: names, command: "pnpm test"), caller: card(cwd: nil))
        #expect(jev.questions.count == 2)
        #expect(Set(jev.questions.map { $0.secrets.count }) == [6, 3])
        #expect(r.values?.count == 6 && r.skipped?.sorted() == ["DEPLOY_1", "DEPLOY_2", "DEPLOY_3"])
        // Each secret still has its own audit line.
        let log = await store.log()
        #expect(log.count == 9)
        #expect(log.filter { $0.outcome == .allowed && $0.decider == .jev }.count == 6)
        #expect(log.filter { $0.outcome == .skipped }.count == 3)
        let body = JevClient.body(for: jev.questions.first { $0.secrets.count == 6 }!, model: "m")
        #expect((body["state"] as? [String: Any])?["secret_names"] as? String == (1...6).map { "PLAIN_\($0)" }.joined(separator: ", "))
    }

    // MARK: Session tokens

    @Test func aTokenNamesItsCardWhileTheCardHasASession() async throws {
        let dir = tempDir("vault")
        let tokens = VaultCardTokens(directory: dir)
        let token = await tokens.issue(cardId: "card_1")
        #expect(token.hasPrefix("kct_") && token.count == 68)
        #expect(await tokens.verify(token, liveCards: ["card_1"]) == "card_1")
        #expect(await tokens.verify("kct_wrong", liveCards: ["card_1"]) == nil)
        #expect(await tokens.verify(nil, liveCards: ["card_1"]) == nil)
        #expect(await tokens.verify(token, liveCards: []) == nil)
        // Only the hash is on disk, and it survives a restart.
        let raw = String(decoding: try #require(FileManager.default.contents(atPath: dir + "/card-tokens.json")), as: UTF8.self)
        #expect(!raw.contains(token) && raw.contains(VaultCardTokens.hash(token)))
        let reopened = VaultCardTokens(directory: dir)
        #expect(await reopened.verify(token, liveCards: ["card_1"]) == "card_1")
    }

    @Test func aNewSessionReplacesTheCardsTokenAndAnEndedOneIsDropped() async throws {
        let tokens = VaultCardTokens(directory: tempDir("vault"))
        let start = Date(timeIntervalSince1970: 1000)
        let first = await tokens.issue(cardId: "card_1", now: start)
        let second = await tokens.issue(cardId: "card_1", now: start)
        #expect(await tokens.verify(first, liveCards: ["card_1"], now: start) == nil)
        #expect(await tokens.verify(second, liveCards: ["card_1"], now: start) == "card_1")
        // No session yet, within the grace period: refused but kept.
        #expect(await tokens.verify(second, liveCards: [], now: start.addingTimeInterval(60)) == nil)
        #expect(await tokens.count == 1)
        // The session ended: dropped, and a session with the card's id later does not revive it.
        #expect(await tokens.verify(second, liveCards: [], now: start.addingTimeInterval(VaultCardTokens.grace + 1)) == nil)
        #expect(await tokens.count == 0)
        #expect(await tokens.verify(second, liveCards: ["card_1"], now: start.addingTimeInterval(VaultCardTokens.grace + 2)) == nil)
    }

    @Test func theResolverFallsBackToTheTokenOnly() async throws {
        let tokens = VaultCardTokens(directory: tempDir("vault"))
        let token = await tokens.issue(cardId: "card_1")
        let resolver = LiveVaultCallerResolver(rush: nil, tokens: tokens, cardSessions: { ["claude-abc": "card_1"] })
        #expect(await resolver.card(forToken: token) == "card_1")
        #expect(await resolver.card(forToken: "kct_nope") == nil)
        #expect(await resolver.card(forToken: nil) == nil)
        let without = LiveVaultCallerResolver(rush: nil, cardSessions: { ["claude-abc": "card_1"] })
        #expect(await without.card(forToken: token) == nil)
    }

    @Test func aTokenCallerIsInsideTheCardAndTheAuditSaysSo() async throws {
        let (broker, store, _) = try await policyBroker()
        let detached = VaultCaller(cardId: "card_1", claimedCardId: "card_1", pid: 9, ancestry: ["kv", "launchd"], cwd: "/p/shop", byToken: true)
        #expect(detached.insideCard)
        let r = await broker.release(.init(mode: "run", names: ["shop/dev/API_KEY"]), caller: detached)
        #expect(r.status == .granted)
        #expect(await store.log().first?.detail == "\(VaultPolicy.ownProjectDevReason), by session token")
    }

    @Test func theSessionVariablesStayOutOfThePaneAndOutOfOtherSessions() {
        #expect(InheritedSessionEnvironment.names.contains("KANBAN_CARD_TOKEN"))
        #expect(InheritedSessionEnvironment.names.contains("KANBAN_CARD_ID"))
        #expect(InheritedSessionEnvironment.tmuxUnsetArguments(serverTMPDIR: nil).contains("KANBAN_CARD_TOKEN"))
        #expect(InheritedSessionEnvironment.inherited(in: ["KANBAN_CARD_TOKEN": "kct_x", "HOME": "/h"]) == ["KANBAN_CARD_TOKEN"])
        let env = ["KANBAN_CARD_ID": "card_1", "KANBAN_CARD_TOKEN": "kct_x", "ANTHROPIC_BASE_URL": "http://x"]
        #expect(LaunchSession.sessionEnvironment(env) == ["KANBAN_CARD_ID": "card_1", "KANBAN_CARD_TOKEN": "kct_x"])
        #expect(TmuxAdapter.newSessionArguments(name: "s", path: "/p", environment: LaunchSession.sessionEnvironment(env))
            == ["new-session", "-d", "-s", "s", "-c", "/p", "-e", "KANBAN_CARD_ID=card_1", "-e", "KANBAN_CARD_TOKEN=kct_x"])
        #expect(VaultCallerResolver.parseLsofCwd("p123\nfcwd\nn/Users/x/Projects/shop\n") == "/Users/x/Projects/shop")
    }
}
