import Foundation
import Testing
@testable import KanbanCodeCore
@testable import KanbanCodeRemoteKit

private func tempVaultDir() -> String {
    let path = NSTemporaryDirectory() + "vault-\(UUID().uuidString.prefix(8))"
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

private struct FixedJev: JevJudging {
    let verdict: JevVerdict?
    func judge(_ question: JevReleaseQuestion) async -> JevVerdict? { verdict }
}

/// Approvals answered by the test: `answer` is what the human picks.
private final class FakeApprovals: VaultApprovals, @unchecked Sendable {
    let lock = NSLock()
    var raised: [AttentionRequest] = []
    var answer: String?
    var expired: [String] = []
    var closedBy: [String: String] = [:]

    init(answer: String?) { self.answer = answer }

    func raise(_ request: AttentionRequest) async { lock.withLock { raised.append(request) } }
    func resolution(of id: String) async -> (resolution: String?, by: String)? {
        lock.withLock { answer.map { ($0, "phone") } }
    }
    func close(id: String, resolution: String, by: String) async { lock.withLock { expired.append(id); closedBy[id] = by } }
}

private let inside = VaultCaller(cardId: "card_1", sessionId: "s1", pid: 42, ancestry: ["kv", "zsh", "tmux"])
private let outside = VaultCaller(claimedCardId: "card_1", pid: 43, ancestry: ["kv", "launchd"],
                                  commandLines: ["node kv.js run OPEN -- /jobs/daily.sh", "/bin/bash -c /jobs/daily.sh"])
private let overNetwork = VaultCaller(claimedCardId: "card_1", remoteDevice: "tablet")

/// Records what Jev was asked.
private final class RecordingJev: JevJudging, @unchecked Sendable {
    let lock = NSLock()
    let verdict: JevVerdict?
    var questions: [JevReleaseQuestion] = []
    init(verdict: JevVerdict?) { self.verdict = verdict }
    func judge(_ question: JevReleaseQuestion) async -> JevVerdict? {
        lock.withLock { questions.append(question) }
        return verdict
    }
}

private func makeBroker(jev: JevVerdict? = nil, answer: String? = nil, approvals: FakeApprovals? = nil) async throws -> (VaultBroker, VaultStore, FakeApprovals) {
    let store = VaultStore(directory: tempVaultDir(), keys: MemoryVaultKeyProvider())
    try await store.ensureIdentity()
    try await store.upsert(VaultSecret(name: "OPEN", value: "open-value", tier: .open))
    try await store.upsert(VaultSecret(name: "JUDGED", value: "judged-value", tier: .judged, rules: "deploys only"))
    try await store.upsert(VaultSecret(name: "ASK", value: "ask-value", tier: .ask))
    try await store.upsert(VaultSecret(name: "PROD", value: "prod-value", tier: .ask, leasePolicy: .everyUse))
    try await store.upsert(VaultSecret(name: "NEVER", value: "never-value", tier: .never))
    let a = approvals ?? FakeApprovals(answer: answer)
    let broker = VaultBroker(store: store, jev: FixedJev(verdict: jev), approvals: a, machine: "test") { _ in "Card one" }
    await broker.configure(approvalTimeout: 2, pollInterval: 0.02)
    return (broker, store, a)
}

private func waitResult(_ broker: VaultBroker, _ id: String) async -> VaultResponse {
    for _ in 0..<300 {
        let r = await broker.poll(id: id)
        if r.status != .pending { return r }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await broker.poll(id: id)
}

@Suite("Vault store and broker")
struct VaultBrokerTests {
    @Test func storeKeepsValuesEncryptedOnDisk() async throws {
        let dir = tempVaultDir()
        let keys = MemoryVaultKeyProvider()
        let store = VaultStore(directory: dir, keys: keys)
        try await store.upsert(VaultSecret(name: "A", value: "super-secret-value", tier: .open))
        let raw = try #require(FileManager.default.contents(atPath: dir + "/vault.age"))
        #expect(!String(decoding: raw, as: UTF8.self).contains("super-secret-value"))
        let reopened = VaultStore(directory: dir, keys: keys)
        #expect(try await reopened.secret("A")?.value == "super-secret-value")
        #expect(try await reopened.list().map(\.name) == ["A"])
    }

    @Test func replicasConvergeNewestWins() async throws {
        let keys = MemoryVaultKeyProvider(Age.Identity.generate())
        let box = VaultStore(directory: tempVaultDir(), keys: keys)
        let mac = VaultStore(directory: tempVaultDir(), keys: keys)
        let t0 = Date(timeIntervalSince1970: 2_000_000_000)
        try await box.upsert(VaultSecret(name: "A", value: "a1", tier: .open), now: t0)
        try await mac.upsert(VaultSecret(name: "B", value: "b1", tier: .judged), now: t0)
        try await mac.mergeReplica(try #require(await box.encryptedBlob()))
        try await box.mergeReplica(try #require(await mac.encryptedBlob()))
        try await mac.upsert(VaultSecret(name: "A", value: "a2", tier: .open), now: t0.addingTimeInterval(10))
        try await box.delete("B", now: t0.addingTimeInterval(5))
        let result = try await box.mergeReplica(try #require(await mac.encryptedBlob()))
        #expect(result.changedHere)
        #expect(try await box.secret("A")?.value == "a2")
        // Box deleted B after the Mac wrote it: the tombstone wins both ways.
        #expect(try await box.secret("B") == nil)
        try await mac.mergeReplica(try #require(await box.encryptedBlob()))
        #expect(try await mac.secret("B") == nil)
        let again = try await mac.mergeReplica(try #require(await box.encryptedBlob()))
        #expect(!again.changedHere && !again.otherIsBehind)
    }

    @Test func aForgedReplicaIsRefused() async throws {
        let identity = Age.Identity.generate()
        let box = VaultStore(directory: tempVaultDir(), keys: MemoryVaultKeyProvider(identity))
        try await box.upsert(VaultSecret(name: "PROD", value: "p", tier: .ask))
        // Encrypted to the public key, but without the identity's auth.
        let forged = VaultDocument(secrets: ["PROD": VaultSecret(name: "PROD", value: "p", tier: .open, updatedAt: .distantFuture)])
        let blob = try Age.encrypt(try JSONEncoder.vault.encode(forged), to: [identity.recipient])
        await #expect(throws: (any Error).self) { try await box.mergeReplica(blob) }
        #expect(try await box.secret("PROD")?.tier == .ask)
    }

    @Test func aMachineWithoutTheKeyKeepsTheBlob() async throws {
        let box = VaultStore(directory: tempVaultDir(), keys: MemoryVaultKeyProvider(Age.Identity.generate()))
        try await box.upsert(VaultSecret(name: "A", value: "a", tier: .open))
        let mac = VaultStore(directory: tempVaultDir(), keys: MemoryVaultKeyProvider())
        try await mac.mergeReplica(try #require(await box.encryptedBlob()))
        #expect(await mac.encryptedBlob() == (await box.encryptedBlob()))
        await #expect(throws: VaultError.self) { _ = try await mac.secret("A") }
    }

    @Test func openTierReleasesInsideACard() async throws {
        let (broker, store, _) = try await makeBroker()
        let r = await broker.release(VaultReleaseRequest(mode: "run", names: ["OPEN"], command: "curl x"), caller: inside)
        #expect(r.status == .granted)
        #expect(r.values == ["OPEN": "open-value"])
        let log = await store.log()
        #expect(log.first?.outcome == .allowed && log.first?.decider == .tier && log.first?.cardId == "card_1")
        #expect(!(String(data: try JSONEncoder.vault.encode(log), encoding: .utf8) ?? "").contains("open-value"))
    }

    @Test func neverIsDenied() async throws {
        let (broker, _, approvals) = try await makeBroker(answer: "Approve once")
        let r = await broker.release(VaultReleaseRequest(mode: "run", names: ["NEVER"]), caller: inside)
        #expect(r.status == .denied && r.values == nil)
        #expect(approvals.raised.isEmpty)
    }

    @Test func unknownSecretIsDenied() async throws {
        let (broker, _, _) = try await makeBroker()
        let r = await broker.release(VaultReleaseRequest(mode: "run", names: ["NOPE"]), caller: inside)
        #expect(r.status == .denied && r.message.contains("kv add NOPE"))
    }

    @Test func judgedFollowsJev() async throws {
        let (allowB, _, _) = try await makeBroker(jev: JevVerdict(choice: .allow, confidence: 0.95))
        #expect(await allowB.release(VaultReleaseRequest(mode: "run", names: ["JUDGED"], command: "wrangler deploy"), caller: inside).status == .granted)
        let (denyB, _, _) = try await makeBroker(jev: JevVerdict(choice: .deny, confidence: 0.99))
        let denied = await denyB.release(VaultReleaseRequest(mode: "run", names: ["JUDGED"], command: "echo $JUDGED"), caller: inside)
        #expect(denied.status == .denied && denied.message.contains("Jev"))
    }

    @Test func jevUnreachableAsksTheHuman() async throws {
        let (broker, _, approvals) = try await makeBroker(jev: nil, answer: "Approve once")
        let r = await broker.release(VaultReleaseRequest(mode: "run", names: ["JUDGED"], command: "x"), caller: inside)
        #expect(r.status == .pending)
        #expect(approvals.raised.first?.vault?.whys.joined().contains("Jev could not be reached") == true)
        let done = await waitResult(broker, try #require(r.id))
        #expect(done.status == .granted && done.values == ["JUDGED": "judged-value"])
    }

    @Test func aProcessOutsideACardGetsAnOpenSecretWithNoQuestion() async throws {
        let (broker, store, approvals) = try await makeBroker(answer: "Deny")
        let r = await broker.release(VaultReleaseRequest(mode: "run", names: ["OPEN"], command: "/jobs/daily.sh"), caller: outside)
        #expect(r.status == .granted && r.values == ["OPEN": "open-value"])
        #expect(approvals.raised.isEmpty)
        let line = try #require(await store.log(limit: 1, cardId: nil, secret: "OPEN").first)
        #expect(line.outcome == .allowed && line.decider == .tier)
        #expect(line.detail == "open tier, outside any card session, called by: node kv.js run OPEN -- /jobs/daily.sh <- /bin/bash -c /jobs/daily.sh")
    }

    @Test func aProcessOutsideACardIsJudgedByJev() async throws {
        let store = VaultStore(directory: tempVaultDir(), keys: MemoryVaultKeyProvider())
        try await store.ensureIdentity()
        try await store.upsert(VaultSecret(name: "JUDGED", value: "judged-value", tier: .judged, rules: "deploys only"))
        let jev = RecordingJev(verdict: JevVerdict(choice: .allow, confidence: 0.9))
        let approvals = FakeApprovals(answer: nil)
        let broker = VaultBroker(store: store, jev: jev, approvals: approvals, machine: "test")
        let r = await broker.release(
            VaultReleaseRequest(mode: "run", names: ["JUDGED"], command: "/jobs/daily.sh", reason: "Daily deploy of the docs site"),
            caller: outside)
        #expect(r.status == .granted && r.values == ["JUDGED": "judged-value"])
        #expect(approvals.raised.isEmpty)
        let question = try #require(jev.questions.first)
        #expect(question.outsideCard && question.cardTitle == nil && question.prompts == nil)
        #expect(question.processChain == "node kv.js run OPEN -- /jobs/daily.sh <- /bin/bash -c /jobs/daily.sh")
        #expect(question.reason == "Daily deploy of the docs site")
        let state = try #require(JevClient.body(for: question, model: "m")["state"] as? [String: Any])
        #expect((state["caller"] as? String)?.contains("outside any Kanban card session") == true)
        #expect(state["caller_process_chain"] as? String == question.processChain)
        let line = try #require(await store.log(limit: 1, cardId: nil, secret: "JUDGED").first)
        #expect(line.decider == .jev && line.detail?.hasPrefix("Jev allowed (90%), outside any card session, called by: ") == true)
    }

    @Test func anUnsureJevSendsAProcessOutsideACardToTheHuman() async throws {
        let (broker, _, approvals) = try await makeBroker(jev: JevVerdict(choice: .allow, confidence: 0.4), answer: "Approve once")
        let r = await broker.release(VaultReleaseRequest(mode: "run", names: ["JUDGED"]), caller: outside)
        #expect(r.status == .pending)
        let raised = try #require(approvals.raised.first)
        #expect(raised.options == ["Approve once", "Deny"])
        #expect(raised.vault?.origin == .outside)
        #expect(r.message.contains("up to"))
        let done = await waitResult(broker, try #require(r.id))
        #expect(done.status == .granted && done.values == ["JUDGED": "judged-value"])
    }

    @Test func aProcessOutsideACardStillAsksForAnAskSecret() async throws {
        let (broker, _, approvals) = try await makeBroker(answer: "Deny")
        let r = await broker.release(VaultReleaseRequest(mode: "run", names: ["ASK", "OPEN"]), caller: outside)
        #expect(r.status == .pending)
        #expect(approvals.raised.first?.vault?.secrets.map(\.name) == ["ASK"])
        let never = await broker.release(VaultReleaseRequest(mode: "run", names: ["NEVER"]), caller: outside)
        #expect(never.status == .denied)
    }

    @Test func theWaitingMessageNamesTwelveHours() async throws {
        let (broker, _, _) = try await makeBroker(answer: nil)
        await broker.configure(approvalTimeout: VaultPolicy.approvalTimeout)
        let r = await broker.release(VaultReleaseRequest(mode: "run", names: ["ASK"]), caller: inside)
        #expect(r.status == .pending && r.message.contains("up to 12 hours"))
    }

    @Test func overTheNetworkAsksEvenForOpen() async throws {
        let (broker, _, approvals) = try await makeBroker(answer: "Deny")
        let r = await broker.release(VaultReleaseRequest(mode: "run", names: ["OPEN"]), caller: overNetwork)
        #expect(r.status == .pending)
        #expect(approvals.raised.first?.vault?.whys == [VaultPolicy.overNetworkReason])
        let raised = try #require(approvals.raised.first)
        #expect(raised.kind == .vaultApproval)
        #expect(raised.options == ["Approve once", "Deny"])
        #expect(raised.vault?.origin == .outside)
        let done = await waitResult(broker, try #require(r.id))
        #expect(done.status == .denied && done.values == nil)
    }

    @Test func approvalForTheCardGrantsALease() async throws {
        let (broker, store, approvals) = try await makeBroker(answer: "Approve for this card (2 days)")
        let r = await broker.release(VaultReleaseRequest(mode: "run", names: ["ASK", "OPEN"], reason: "migrate"), caller: inside)
        #expect(r.status == .pending)
        #expect(approvals.raised.first?.requiresBiometry == true)
        let done = await waitResult(broker, try #require(r.id))
        #expect(done.values == ["ASK": "ask-value", "OPEN": "open-value"])
        let lease = try #require(await store.activeLease(cardId: "card_1", secret: "ASK"))
        #expect(lease.expiresAt.timeIntervalSince(lease.grantedAt) <= VaultLeasePolicy.maximumLease)
        // Next time the lease answers, no human.
        approvals.answer = nil
        let again = await broker.release(VaultReleaseRequest(mode: "run", names: ["ASK"]), caller: inside)
        #expect(again.status == .granted)
    }

    @Test func everyUseSecretsNeverLease() async throws {
        let (broker, store, approvals) = try await makeBroker(answer: "Approve for this card (2 days)")
        let r = await broker.release(VaultReleaseRequest(mode: "run", names: ["PROD"]), caller: inside)
        #expect(approvals.raised.first?.options == ["Approve once", "Deny"])
        _ = await waitResult(broker, try #require(r.id))
        #expect(await store.activeLease(cardId: "card_1", secret: "PROD") == nil)
        let lease = await broker.requestLease(VaultLeaseRequest(names: ["PROD"], reason: "x"), caller: inside)
        #expect(lease.status == .denied)
    }

    @Test func unansweredRequestsAreDeniedOnTimeout() async throws {
        let (broker, _, approvals) = try await makeBroker(answer: nil)
        await broker.configure(approvalTimeout: 0.2)
        let r = await broker.release(VaultReleaseRequest(mode: "run", names: ["ASK"]), caller: inside)
        let done = await waitResult(broker, try #require(r.id))
        #expect(done.status == .denied && done.message.contains("kv request"))
        #expect(approvals.expired == [r.id!])
    }

    @Test func getNeverPrintsAskingSecrets() async throws {
        let (broker, _, approvals) = try await makeBroker(answer: "Approve once")
        #expect(await broker.release(VaultReleaseRequest(mode: "get", names: ["ASK"]), caller: inside).status == .denied)
        #expect(approvals.raised.isEmpty)
        #expect(await broker.release(VaultReleaseRequest(mode: "get", names: ["OPEN"]), caller: inside).status == .granted)
    }

    @Test func hookModeSkipsWhatNeedsAHuman() async throws {
        let (broker, store, approvals) = try await makeBroker(jev: JevVerdict(choice: .allow, confidence: 0.9), answer: "Approve once")
        let r = await broker.release(VaultReleaseRequest(mode: "hook", names: ["OPEN", "JUDGED", "ASK"], command: "ls"), caller: inside)
        #expect(r.status == .granted)
        #expect(r.values == ["OPEN": "open-value", "JUDGED": "judged-value"])
        #expect(r.skipped == ["ASK"])
        #expect(approvals.raised.isEmpty)
        #expect(await store.log().contains { $0.secret == "ASK" && $0.outcome == .skipped })
    }

    @Test func hookModeLogsJevRefusalsAsSkips() async throws {
        let (broker, store, _) = try await makeBroker(jev: JevVerdict(choice: .deny, confidence: 0.9))
        let r = await broker.release(VaultReleaseRequest(mode: "hook", names: ["OPEN", "JUDGED"], command: "npm test"), caller: inside)
        #expect(r.status == .granted && r.values == ["OPEN": "open-value"] && r.skipped == ["JUDGED"])
        #expect(await store.log().first { $0.secret == "JUDGED" }?.outcome == .skipped)
    }

    @Test func hookReleasesDoNotTripTheRateLimit() async throws {
        let (broker, _, approvals) = try await makeBroker(answer: "Deny")
        for _ in 0..<30 {
            let r = await broker.release(VaultReleaseRequest(mode: "hook", names: ["OPEN"], command: "ls"), caller: inside)
            #expect(r.values == ["OPEN": "open-value"])
        }
        #expect(await broker.release(VaultReleaseRequest(mode: "run", names: ["OPEN"]), caller: inside).status == .granted)
        #expect(approvals.raised.isEmpty)
    }

    @Test func rateLimitAsks() async throws {
        let (broker, _, approvals) = try await makeBroker(answer: "Deny")
        for _ in 0..<20 {
            #expect(await broker.release(VaultReleaseRequest(mode: "run", names: ["OPEN"]), caller: inside).status == .granted)
        }
        let r = await broker.release(VaultReleaseRequest(mode: "run", names: ["OPEN"]), caller: inside)
        #expect(r.status == .pending)
        #expect(approvals.raised.first?.vault?.whys.joined().contains("20 times") == true)
    }

    @Test func leaseRequestNeedsACardAndTheHuman() async throws {
        let (broker, store, _) = try await makeBroker(answer: "Approve for this card (2 days)")
        #expect(await broker.requestLease(VaultLeaseRequest(names: ["ASK"], reason: "x"), caller: outside).status == .denied)
        let r = await broker.requestLease(VaultLeaseRequest(names: ["ASK"], reason: "deploy the docs"), caller: inside)
        #expect(r.status == .pending)
        let done = await waitResult(broker, try #require(r.id))
        #expect(done.status == .granted)
        #expect(await store.activeLease(cardId: "card_1", secret: "ASK")?.reason == "deploy the docs")
    }

    @Test func agentsCannotChangeTiersWithoutTheHuman() async throws {
        let (broker, store, approvals) = try await makeBroker(answer: "Deny")
        let r = await broker.edit("ASK", VaultEditRequest(tier: .open), caller: inside, trusted: false)
        #expect(r.status == .pending)
        #expect(approvals.raised.first?.requiresBiometry == true)
        _ = await waitResult(broker, try #require(r.id))
        #expect(try await store.secret("ASK")?.tier == .ask)
        let trusted = await broker.edit("ASK", VaultEditRequest(tier: .judged, rules: "r"), caller: inside, trusted: true)
        #expect(trusted.status == .granted)
        #expect(try await store.secret("ASK")?.tier == .judged)
    }

    @Test func replacingAValueNeedsTheHuman() async throws {
        let (broker, store, _) = try await makeBroker(answer: "Deny")
        let added = await broker.add(VaultAddRequest(name: "NEW", value: "v"), caller: inside, trusted: false)
        #expect(added.status == .granted)
        #expect(try await store.secret("NEW")?.tier == .judged)
        let replace = await broker.add(VaultAddRequest(name: "OPEN", value: "evil"), caller: inside, trusted: false)
        #expect(replace.status == .pending)
        _ = await waitResult(broker, try #require(replace.id))
        #expect(try await store.secret("OPEN")?.value == "open-value")
    }

    /// The Mac composer's replace: the user's own yes, so no approval, and
    /// only the value changes.
    @Test func aTrustedReplaceWithOnlyAValueKeepsTheTierAndRules() async throws {
        let (broker, store, approvals) = try await makeBroker()
        #expect(await broker.compare(VaultAddRequest(name: "JUDGED", value: "rotated")).outcome == .different)
        #expect(await broker.compare(VaultAddRequest(name: "JUDGED", value: "judged-value")).outcome == .same)
        #expect(await broker.compare(VaultAddRequest(name: "MISSING", value: "rotated")).outcome == .absent)
        #expect(try await store.secret("JUDGED")?.value == "judged-value")

        // The value it already holds: no approval and no write, also for an agent.
        let before = try #require(try await store.secret("JUDGED"))
        let unchanged = await broker.add(VaultAddRequest(name: "JUDGED", value: "judged-value"), caller: inside, trusted: false)
        #expect(unchanged.status == .granted && unchanged.message == "JUDGED already holds this value")
        #expect(try await store.secret("JUDGED") == before)
        #expect(approvals.raised.isEmpty)

        let replaced = await broker.add(VaultAddRequest(name: "JUDGED", value: "rotated"), caller: inside, trusted: true)
        #expect(replaced.status == .granted && replaced.message == "replaced JUDGED")
        let saved = try #require(try await store.secret("JUDGED"))
        #expect(saved.value == "rotated" && saved.tier == .judged && saved.rules == "deploys only")
        #expect(approvals.raised.isEmpty)
    }

    @Test func awsProfilesGoThroughSts() async throws {
        let store = VaultStore(directory: tempVaultDir(), keys: MemoryVaultKeyProvider())
        try await store.upsert(VaultSecret(name: "AWS_ROOT", value: #"{"accessKeyId":"AKIAX","secretAccessKey":"s"}"#, tier: .never))
        try await store.upsert(VaultSecret(name: "aws:lw-dev", value: "", tier: .open,
                                           aws: VaultAwsRole(sourceSecret: "AWS_ROOT", roleArn: "arn:aws:iam::1:role/R")))
        let broker = VaultBroker(store: store, jev: nil, approvals: nil, machine: "t", sts: { key, role, session in
            #expect(key.accessKeyId == "AKIAX")
            #expect(role.roleArn == "arn:aws:iam::1:role/R")
            #expect(session == "kanban-card_1")
            return AwsProcessCredentials(Version: 1, AccessKeyId: "ASIA", SecretAccessKey: "x", SessionToken: "t", Expiration: "2030-01-01T00:00:00Z")
        })
        let r = await broker.release(VaultReleaseRequest(mode: "aws", names: ["aws:lw-dev"]), caller: inside)
        #expect(r.status == .granted && r.credentials?.AccessKeyId == "ASIA" && r.values == nil)
        // The profile is not a plain secret.
        #expect(await broker.release(VaultReleaseRequest(mode: "run", names: ["aws:lw-dev"]), caller: inside).status == .denied)
    }

    @Test func stsSignatureMatchesTheAwsExample() {
        // AWS SigV4 test suite "post-x-www-form-urlencoded" shape.
        let headers = AwsSts.sign(
            method: "POST", url: URL(string: "https://example.amazonaws.com/")!, body: Data("Param1=value1".utf8),
            headers: ["content-type": "application/x-www-form-urlencoded"],
            key: AwsAccessKey(accessKeyId: "AKIDEXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"),
            region: "us-east-1", service: "service", date: Date(timeIntervalSince1970: 1_440_938_160)
        )
        #expect(headers["authorization"] == "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=content-type;host;x-amz-date, Signature=ff11897932ad3f4e8b18135d722051e5ac45fc38421b1da7b9d196a0fe09473a")
    }

    @Test func jevBodyAndParse() throws {
        let body = JevClient.body(for: JevReleaseQuestion(secrets: ["S"], rules: "", command: "c", reason: "r", cardTitle: "t", cwd: nil), model: "jev-latest")
        #expect(body["model"] as? String == "jev-latest")
        let data = Data(#"{"model":"jev","answers":{"release":{"type":"choice","choice":"allow","confidence":0.3,"probabilities":{"allow":0.93,"ask":0.05,"deny":0.02}}}}"#.utf8)
        #expect(JevClient.parse(data) == JevVerdict(choice: .allow, confidence: 0.93))
        #expect(JevClient.parse(Data("{}".utf8)) == nil)
    }
}

@Suite("Vault callers from OpenClaw")
struct OpenClawCallerTests {
    private let layout = OpenClawLayout(
        workspaces: ["main": "/root/.openclaw/workspace", "forge": "/root/.openclaw/workspace-forge"],
        names: ["main": "Chief", "forge": "Forge"]
    )
    private let unitCgroup = "/user.slice/user-0.slice/user@0.service/app.slice/openclaw-gateway.service"

    @Test func layoutReadsAgentsFromTheConfig() throws {
        let json = #"{"agents":{"defaults":{"workspace":"/root/.openclaw/workspace"},"entries":{"main":{"identity":{"name":"Chief"}},"forge":{"workspace":"/root/.openclaw/workspace-forge","identity":{"name":"Forge"}},"sleep":{}}}}"#
        let parsed = try #require(OpenClawLayout.parse(Data(json.utf8), home: "/root"))
        #expect(parsed.workspaces == [
            "main": "/root/.openclaw/workspace",
            "forge": "/root/.openclaw/workspace-forge",
            "sleep": "/root/.openclaw/workspace-sleep",
        ])
        #expect(parsed.names["main"] == "Chief")
        #expect(parsed.agent(forCwd: "/root/.openclaw/workspace-forge/tmp") == "forge")
        #expect(parsed.agent(forCwd: "/root/.openclaw/workspace") == "main")
        #expect(parsed.agent(forCwd: "/root/.openclaw/workspace-other") == nil)
    }

    @Test func theAgentIsTheProcessTheGatewayStarted() {
        // kv < bash < claude (forge) < gateway < systemd
        let chain = [
            VaultProcess(pid: 50, ppid: 40, name: "kv"),
            VaultProcess(pid: 40, ppid: 30, name: "bash"),
            VaultProcess(pid: 30, ppid: 20, name: "claude"),
            VaultProcess(pid: 20, ppid: 10, name: "node"),
            VaultProcess(pid: 10, ppid: 1, name: "systemd"),
        ]
        let inUnit: Set<Int> = [50, 40, 30, 20]
        // The shell moved to the main workspace: the agent is still forge.
        let cwds = [50: "/root/.openclaw/workspace", 40: "/root/.openclaw/workspace", 30: "/root/.openclaw/workspace-forge", 20: "/"]
        let principal = layout.principal(chain: chain, cgroup: { inUnit.contains($0) ? unitCgroup : "/user.slice/session-1.scope" },
                                         cwd: { cwds[$0] })
        #expect(principal == "openclaw:forge")

        let gatewayItself = layout.principal(chain: [chain[0], chain[3], chain[4]], cgroup: { inUnit.contains($0) ? unitCgroup : nil },
                                             cwd: { _ in "/" })
        #expect(gatewayItself == "openclaw:gateway")

        // A shell outside the unit is not OpenClaw, whatever its directory.
        #expect(layout.principal(chain: chain, cgroup: { _ in "/user.slice/session-1.scope" }, cwd: { cwds[$0] }) == nil)
    }

    @Test func procFilesReadToTheirEnd() throws {
        let path = NSTemporaryDirectory() + "proc-\(UUID().uuidString.prefix(8))"
        let text = String(repeating: "0::/user.slice/openclaw-gateway.service\n", count: 4000)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        #expect(VaultCallerResolver.readProcFile(path) == text)
        #expect(VaultCallerResolver.readProcFile(path + "-missing") == nil)
        #if os(Linux)
        #expect(VaultCallerResolver.readProcFile("/proc/self/cgroup")?.isEmpty == false)
        #endif
    }

    @Test func anOpenClawAgentGetsCardTiersLeasesAndJev() async throws {
        let forge = VaultCaller(cardId: VaultCaller.openClawPrincipal(agent: "forge"), pid: 50, ancestry: ["kv", "bash", "claude", "node"])
        #expect(forge.insideCard && forge.openClawAgent == "forge")

        let (broker, store, approvals) = try await makeBroker(jev: JevVerdict(choice: .allow, confidence: 0.9), answer: AttentionRequest.vaultApprovalOptions[0])
        #expect(await broker.release(VaultReleaseRequest(mode: "run", names: ["OPEN"]), caller: forge).status == .granted)
        #expect(await broker.release(VaultReleaseRequest(mode: "run", names: ["JUDGED"], command: "wrangler deploy"), caller: forge).status == .granted)

        let asked = await broker.release(VaultReleaseRequest(mode: "run", names: ["ASK"], command: "x"), caller: forge)
        #expect(asked.status == .pending)
        let request = try #require(approvals.raised.last)
        #expect(request.cardId == nil)
        #expect(request.vault?.origin == .openClaw && request.title.hasPrefix("OpenClaw agent forge wants"))
        #expect(request.options.first == AttentionRequest.vaultApprovalOptions[0])
        #expect(await waitResult(broker, try #require(asked.id)).status == .granted)
        #expect(await store.activeLease(cardId: "openclaw:forge", secret: "ASK", now: Date()) != nil)

        // The lease is the agent's own: Chief still asks.
        let chief = VaultCaller(cardId: VaultCaller.openClawPrincipal(agent: "main"), pid: 51)
        approvals.answer = nil
        #expect(await broker.release(VaultReleaseRequest(mode: "run", names: ["ASK"]), caller: chief).status == .pending)
    }
}

@Suite("Vault callers from rush hosts")
struct RushHostCallerTests {
    private func host(_ id: String, hostPid: Int, claudePid: Int, meta: [String: String]? = nil) -> RushSessionInfo {
        var h = RushSessionInfo(id: id, sessionId: id + "-0000", cwd: "/w", state: "idle", alive: true)
        h.hostPid = hostPid
        h.claudePid = claudePid
        h.meta = meta
        return h
    }

    // A rush view in another terminal started this host: ppid is that view, not the master.
    private let table: [Int: VaultProcess] = [
        5: VaultProcess(pid: 5, ppid: 1, name: "Warp"),
        6: VaultProcess(pid: 6, ppid: 5, name: "rush"),
        20: VaultProcess(pid: 20, ppid: 6, name: "rush"),
        21: VaultProcess(pid: 21, ppid: 20, name: "claude"),
        22: VaultProcess(pid: 22, ppid: 21, name: "kv"),
    ]

    @Test func metaAloneNeverMakesACard() {
        let spoof = host("aaaaaaaa", hostPid: 20, claudePid: 21, meta: ["kanban_card": "card_x"])
        let cards = VaultCallerResolver.rushCards(hosts: [spoof], sessions: [:])
        #expect(cards.isEmpty)
        #expect(VaultCallerResolver.card(for: 22, table: table, sessionPids: cards) == nil)
    }

    @Test func aHostTheLinksMapIsTheCardWhoeverStartedIt() {
        let fromRushView = host("aaaaaaaa", hostPid: 20, claudePid: 21)
        let cards = VaultCallerResolver.rushCards(hosts: [fromRushView], sessions: ["rush-aaaaaaaa": "card_a"])
        #expect(cards == [20: "card_a", 21: "card_a"])
        #expect(VaultCallerResolver.card(for: 22, table: table, sessionPids: cards) == "card_a")
    }

    @Test func aCardNamedBeforeTheRenameStillOwnsItsHost() {
        let h = host("aaaaaaaa", hostPid: 20, claudePid: 21)
        #expect(VaultCallerResolver.rushCards(hosts: [h], sessions: ["agtop-aaaaaaaa": "card_a"]) == [20: "card_a", 21: "card_a"])
    }

    @Test func theLinksWinOverTheMeta() {
        let h = host("aaaaaaaa", hostPid: 20, claudePid: 21, meta: ["kanban_card": "card_x"])
        #expect(VaultCallerResolver.rushCards(hosts: [h], sessions: ["rush-aaaaaaaa": "card_a"]) == [20: "card_a", 21: "card_a"])
    }

    @Test func aStoppedHostOwnsNothing() {
        var h = host("aaaaaaaa", hostPid: 20, claudePid: 21)
        h = RushSessionInfo(id: h.id, sessionId: h.sessionId, cwd: h.cwd, state: "stopped", alive: false)
        #expect(VaultCallerResolver.rushCards(hosts: [h], sessions: ["rush-aaaaaaaa": "card_a"]).isEmpty)
    }
}

@Suite("Vault denials")
struct VaultDenialTests {
    @Test func aJevDenialNamesTheRulesItReadAgainst() async throws {
        let (broker, _, _) = try await makeBroker(jev: JevVerdict(choice: .deny, confidence: 0.91))
        let r = await broker.release(VaultReleaseRequest(mode: "run", names: ["JUDGED"], command: "echo $JUDGED"), caller: inside)
        #expect(r.status == .denied)
        #expect(r.message.contains("JUDGED: Jev denied it against the secret's rules (91%). Its rules: deploys only"))
    }
}

@Suite("Vault batched changes")
struct VaultBatchEditTests {
    @Test func oneApprovalChangesEverySecretAValuePrefixPicks() async throws {
        let (broker, store, approvals) = try await makeBroker(answer: AttentionRequest.vaultApprovalOptions[1])
        try await store.upsert(VaultSecret(name: "STRIPE_LIVE", value: "sk_live_abc", tier: .judged))
        try await store.upsert(VaultSecret(name: "STRIPE_RESTRICTED", value: "rk_live_def", tier: .judged))
        try await store.upsert(VaultSecret(name: "STRIPE_TEST", value: "sk_test_ghi", tier: .judged))
        let edit = VaultEditRequest(tier: .ask, leasePolicy: .everyUse, reason: "Live Stripe keys ask on every use")
        let r = await broker.editMany(VaultBatchEditRequest(valuePrefixes: ["sk_live_", "rk_live_"], edit: edit), caller: inside, trusted: false)
        #expect(r.status == .pending)
        #expect(approvals.raised.count == 1)
        #expect(await waitResult(broker, try #require(r.id)).status == .granted)
        #expect(try await store.secret("STRIPE_LIVE")?.leasePolicy.everyUseAsks == true)
        #expect(try await store.secret("STRIPE_RESTRICTED")?.tier == .ask)
        #expect(try await store.secret("STRIPE_TEST")?.tier == .judged)
        #expect(await broker.editMany(VaultBatchEditRequest(valuePrefixes: ["nope_"], edit: edit), caller: inside, trusted: false).status == .denied)
    }
}

@Suite("Vault requests across a master restart")
struct VaultRestartTests {
    /// The master after a restart: a new store and broker over the same
    /// vault directory and key.
    private func restarted(_ store: VaultStore, answer: String?) async throws -> (VaultBroker, VaultStore, FakeApprovals) {
        let again = VaultStore(directory: await store.directory, keys: await store.keys)
        let approvals = FakeApprovals(answer: answer)
        let broker = VaultBroker(store: again, jev: nil, approvals: approvals, machine: "test") { _ in "Card one" }
        await broker.configure(approvalTimeout: 2, pollInterval: 0.02)
        await broker.restore()
        return (broker, again, approvals)
    }

    @Test func anOpenApprovalIsAskedAgainAndAnsweredAfterARestart() async throws {
        let (broker, store, before) = try await makeBroker(answer: nil)
        await broker.configure(approvalTimeout: 60)
        let edit = VaultEditRequest(tier: .ask, leasePolicy: .everyUse, reason: "Live keys ask on every use")
        let asked = await broker.editMany(VaultBatchEditRequest(names: ["JUDGED", "OPEN"], edit: edit), caller: inside, trusted: false)
        let id = try #require(asked.id)
        #expect(before.raised.count == 1)
        let dir = await store.directory
        #expect(FileManager.default.fileExists(atPath: dir + "/pending.age"))

        let (after, afterStore, approvals) = try await restarted(store, answer: AttentionRequest.vaultApprovalOptions[1])
        #expect(approvals.raised.map(\.id) == before.raised.map(\.id))
        #expect(approvals.raised.map(\.title) == before.raised.map(\.title))
        #expect(await waitResult(after, id).status == .granted)
        #expect(try await afterStore.secret("JUDGED")?.leasePolicy.everyUseAsks == true)
        #expect(try await afterStore.secret("OPEN")?.tier == .ask)
        #expect(!FileManager.default.fileExists(atPath: dir + "/pending.age"))
    }

    @Test func aRestoredReleaseHandsOutItsValues() async throws {
        let (broker, store, _) = try await makeBroker(answer: nil)
        await broker.configure(approvalTimeout: 60)
        let asked = await broker.release(VaultReleaseRequest(mode: "run", names: ["ASK"], reason: "deploy"), caller: inside)
        #expect(asked.status == .pending)
        let (after, _, _) = try await restarted(store, answer: AttentionRequest.vaultApprovalOptions[1])
        let r = await waitResult(after, try #require(asked.id))
        #expect(r.status == .granted)
        #expect(r.values?["ASK"] == "ask-value")
    }

    @Test func theSavedRequestsAreEncrypted() async throws {
        let (broker, store, _) = try await makeBroker(answer: nil)
        await broker.configure(approvalTimeout: 60)
        let r = await broker.add(VaultAddRequest(name: "ASK", value: "replacement-value-xyz"), caller: inside, trusted: false)
        #expect(r.status == .pending)
        let dir = await store.directory
        let file = try #require(FileManager.default.contents(atPath: dir + "/pending.age"))
        #expect(!String(decoding: file, as: UTF8.self).contains("replacement-value-xyz"))
    }

    @Test func aRequestPastItsTimeoutIsDeniedOnRestore() async throws {
        let (broker, store, _) = try await makeBroker(answer: nil)
        await broker.configure(approvalTimeout: 60)
        let asked = await broker.release(VaultReleaseRequest(mode: "run", names: ["ASK"], reason: "deploy"), caller: inside)
        let (after, _, approvals) = try await restarted(store, answer: nil)
        await after.configure(approvalTimeout: 0)
        let r = await waitResult(after, try #require(asked.id))
        #expect(r.status == .denied)
        #expect(approvals.expired == [asked.id])
    }
}
