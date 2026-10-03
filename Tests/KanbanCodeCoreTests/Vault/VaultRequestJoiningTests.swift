import Foundation
import Testing
@testable import KanbanCodeCore
import KanbanCodeRemoteKit

private func tempVaultDir() -> String {
    let path = NSTemporaryDirectory() + "vault-\(UUID().uuidString.prefix(8))"
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

private struct FixedJev: JevJudging {
    let verdict: JevVerdict?
    func judge(_ question: JevReleaseQuestion) async -> JevVerdict? { verdict }
}

/// Approvals the test answers one request at a time.
private final class ScriptedApprovals: VaultApprovals, @unchecked Sendable {
    let lock = NSLock()
    var raised: [AttentionRequest] = []
    var answers: [String: String] = [:]
    var closed: [(id: String, resolution: String, by: String)] = []

    func raise(_ request: AttentionRequest) async { lock.withLock { raised.append(request) } }
    func resolution(of id: String) async -> (resolution: String?, by: String)? {
        lock.withLock { answers[id].map { ($0, "phone") } }
    }
    func close(id: String, resolution: String, by: String) async { lock.withLock { closed.append((id, resolution, by)) } }

    func answer(_ id: String, _ resolution: String) { lock.withLock { answers[id] = resolution } }
    var raisedIds: [String] { lock.withLock { raised.map(\.id) } }
    var closedIds: [String] { lock.withLock { closed.map(\.id) } }
}

private final class Counter: @unchecked Sendable {
    let lock = NSLock()
    var value = 0
    var expiration = "2030-01-01T00:00:00Z"
    func next() -> (Int, String) { lock.withLock { value += 1; return (value, expiration) } }
    var count: Int { lock.withLock { value } }
}

private let card = VaultCaller(cardId: "card_1", sessionId: "s1", pid: 42, ancestry: ["kv", "aws", "kubectl", "zsh"])
private let otherCard = VaultCaller(cardId: "card_2", sessionId: "s2", pid: 52, ancestry: ["kv", "zsh"])
private let approveOnce = AttentionRequest.vaultApprovalOptions[1]
private let approveForCard = AttentionRequest.vaultApprovalOptions[0]

private func makeBroker(jev: JevVerdict? = nil, sts: Counter = Counter()) async throws -> (VaultBroker, VaultStore, ScriptedApprovals) {
    let store = VaultStore(directory: tempVaultDir(), keys: MemoryVaultKeyProvider())
    try await store.ensureIdentity()
    try await store.upsert(VaultSecret(name: "OPEN", value: "open-value", tier: .open))
    try await store.upsert(VaultSecret(name: "ASK", value: "ask-value", tier: .ask))
    try await store.upsert(VaultSecret(name: "ASK2", value: "ask2-value", tier: .ask))
    try await store.upsert(VaultSecret(name: "AWS_ROOT", value: #"{"accessKeyId":"AKIAX","secretAccessKey":"s"}"#, tier: .never))
    try await store.upsert(VaultSecret(name: "aws:lw-dev", value: "", tier: .judged,
                                       aws: VaultAwsRole(sourceSecret: "AWS_ROOT", roleArn: "arn:aws:iam::1:role/R")))
    let approvals = ScriptedApprovals()
    let broker = VaultBroker(store: store, jev: FixedJev(verdict: jev), approvals: approvals, machine: "test",
                             cardTitle: { _ in "Card one" },
                             sts: { _, _, _ in
                                 let (n, expiration) = sts.next()
                                 return AwsProcessCredentials(Version: 1, AccessKeyId: "ASIA\(n)", SecretAccessKey: "x",
                                                              SessionToken: "t", Expiration: expiration)
                             })
    await broker.configure(approvalTimeout: 5, pollInterval: 0.02)
    return (broker, store, approvals)
}

private func waitResult(_ broker: VaultBroker, _ id: String) async -> VaultResponse {
    for _ in 0..<300 {
        let r = await broker.poll(id: id)
        if r.status != .pending { return r }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await broker.poll(id: id)
}

private func run(_ names: [String], command: String = "deploy.sh") -> VaultReleaseRequest {
    VaultReleaseRequest(mode: "run", names: names, command: command, reason: "Deploy the docs site after the fix")
}

@Suite("Vault requests: one question per thing asked")
struct VaultRequestJoiningTests {
    @Test func theSameRequestAgainWaitsOnTheOpenOne() async throws {
        let (broker, _, approvals) = try await makeBroker()
        let first = await broker.release(run(["ASK"]), caller: card)
        let again = await broker.release(run(["ASK"], command: "deploy.sh --retry"), caller: card)
        let third = await broker.release(run(["ASK"]), caller: card)
        #expect(first.status == .pending && again.status == .pending)
        #expect(again.id == first.id && third.id == first.id)
        #expect(approvals.raisedIds.count == 1)

        approvals.answer(try #require(first.id), approveOnce)
        let a = await waitResult(broker, try #require(first.id))
        // A second caller waiting on the same id gets the same answer.
        let b = await broker.poll(id: try #require(first.id))
        #expect(a.status == .granted && a.values == ["ASK": "ask-value"])
        #expect(b == a)
    }

    @Test func anotherCardAsksItsOwnQuestion() async throws {
        let (broker, _, approvals) = try await makeBroker()
        let mine = await broker.release(run(["ASK"]), caller: card)
        let theirs = await broker.release(run(["ASK"]), caller: otherCard)
        #expect(mine.id != theirs.id)
        #expect(approvals.raisedIds.count == 2)
    }

    @Test func requestsThatAskTheSameSecretsShareOneQuestionAndEachGetsItsOwnAnswer() async throws {
        let (broker, _, approvals) = try await makeBroker()
        let one = await broker.release(run(["ASK"]), caller: card)
        let two = await broker.release(run(["ASK", "OPEN"]), caller: card)
        #expect(one.status == .pending && two.status == .pending)
        #expect(one.id != two.id)
        #expect(approvals.raisedIds == [try #require(one.id)])

        approvals.answer(try #require(one.id), approveOnce)
        #expect(await waitResult(broker, try #require(one.id)).values == ["ASK": "ask-value"])
        #expect(await waitResult(broker, try #require(two.id)).values == ["ASK": "ask-value", "OPEN": "open-value"])
    }

    @Test func aDenialReachesEveryWaiter() async throws {
        let (broker, _, approvals) = try await makeBroker()
        let one = await broker.release(run(["ASK"]), caller: card)
        let two = await broker.release(run(["ASK", "OPEN"]), caller: card)
        approvals.answer(try #require(one.id), "Deny")
        #expect(await waitResult(broker, try #require(one.id)).status == .denied)
        #expect(await waitResult(broker, try #require(two.id)).status == .denied)
    }

    @Test func aCallerThatGaveUpTakesTheAnswerOnItsNextCall() async throws {
        let (broker, _, approvals) = try await makeBroker()
        let first = await broker.release(run(["ASK"]), caller: card)
        approvals.answer(try #require(first.id), approveOnce)
        // Nothing polls: the caller is gone when the human answers.
        try await Task.sleep(for: .milliseconds(300))
        let back = await broker.release(run(["ASK"]), caller: card)
        #expect(back.status == .granted && back.values == ["ASK": "ask-value"])
        #expect(approvals.raisedIds.count == 1)
        // The one-time answer was used: the next call asks again.
        let next = await broker.release(run(["ASK"]), caller: card)
        #expect(next.status == .pending && next.id != first.id)
        #expect(approvals.raisedIds.count == 2)
    }

    @Test func aLeaseSettlesTheOtherOpenRequestsItCovers() async throws {
        let (broker, store, approvals) = try await makeBroker()
        let use = await broker.release(run(["ASK"]), caller: card)
        let lease = await broker.requestLease(VaultLeaseRequest(names: ["ASK"], reason: "Deploy the docs site a few times today"), caller: card)
        let unrelated = await broker.release(run(["ASK2"]), caller: card)
        let elsewhere = await broker.release(run(["ASK"]), caller: otherCard)
        #expect(approvals.raisedIds.count == 4)

        approvals.answer(try #require(use.id), approveForCard)
        #expect(await waitResult(broker, try #require(use.id)).status == .granted)
        let leased = await waitResult(broker, try #require(lease.id))
        #expect(leased.status == .granted)
        // Its attention request closes right after it is settled.
        for _ in 0..<100 where approvals.closedIds.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(approvals.closedIds == [try #require(lease.id)])
        #expect(approvals.lock.withLock { approvals.closed.first?.by } == "phone")
        #expect(await store.activeLeases(cardId: "card_1").count == 1)
        // What the lease does not cover stays open.
        #expect(await broker.poll(id: try #require(unrelated.id)).status == .pending)
        #expect(await broker.poll(id: try #require(elsewhere.id)).status == .pending)
    }

    @Test func approvingPastTheRateLimitStartsTheCountAgain() async throws {
        let (broker, store, approvals) = try await makeBroker()
        for _ in 0..<VaultPolicy.rateLimit { await store.recordRelease("OPEN") }
        let limited = await broker.release(run(["OPEN"]), caller: card)
        #expect(limited.status == .pending)
        #expect(approvals.raised.last?.vault?.whys.first?.contains("released 20 times") == true)
        approvals.answer(try #require(limited.id), approveOnce)
        #expect(await waitResult(broker, try #require(limited.id)).status == .granted)
        #expect(await store.recentReleases("OPEN") == 1)
        #expect(await broker.release(run(["OPEN"]), caller: card).status == .granted)
        #expect(approvals.raisedIds.count == 1)
    }

    @Test func awsCredentialsACardHoldsAreHandedToItAgain() async throws {
        let sts = Counter()
        let (broker, store, approvals) = try await makeBroker(jev: JevVerdict(choice: .allow, confidence: 0.9), sts: sts)
        let ask = VaultReleaseRequest(mode: "aws", names: ["aws:lw-dev"], command: "kubectl get pods  (through: aws eks get-token)")
        let first = await broker.release(ask, caller: card)
        #expect(first.status == .granted && first.credentials?.AccessKeyId == "ASIA1")
        // kubectl asks on every call: 30 more in a row are the same credentials.
        for _ in 0..<30 {
            let r = await broker.release(ask, caller: card)
            #expect(r.status == .granted && r.credentials?.AccessKeyId == "ASIA1")
        }
        #expect(sts.count == 1)
        #expect(approvals.raisedIds.isEmpty)
        #expect(await store.recentReleases("aws:lw-dev") == 1)
        let log = await store.log(limit: 100, secret: "aws:lw-dev")
        #expect(log.filter { $0.decider == .reuse }.count == 30)
        #expect(log.filter { $0.decider == .jev }.count == 1)

        // Another card gets its own.
        #expect(await broker.release(ask, caller: otherCard).credentials?.AccessKeyId == "ASIA2")
        // An edited profile is decided again.
        try await store.update("aws:lw-dev") { $0.rules = "dev only" }
        #expect(await broker.release(ask, caller: card).credentials?.AccessKeyId == "ASIA3")
    }

    @Test func awsCredentialsCloseToExpiryAreNotReused() async throws {
        let sts = Counter()
        sts.expiration = ISO8601DateFormatter().string(from: Date().addingTimeInterval(10 * 60))
        let (broker, _, _) = try await makeBroker(jev: JevVerdict(choice: .allow, confidence: 0.9), sts: sts)
        let ask = VaultReleaseRequest(mode: "aws", names: ["aws:lw-dev"], command: "aws s3 ls")
        #expect(await broker.release(ask, caller: card).credentials?.AccessKeyId == "ASIA1")
        #expect(await broker.release(ask, caller: card).credentials?.AccessKeyId == "ASIA2")
    }

    @Test func aProfileThatAsksOnEveryUseIsNeverReused() async throws {
        let sts = Counter()
        let (broker, store, approvals) = try await makeBroker(sts: sts)
        try await store.upsert(VaultSecret(name: "aws:lw-prod", value: "", tier: .ask, leasePolicy: .everyUse,
                                           aws: VaultAwsRole(sourceSecret: "AWS_ROOT", roleArn: "arn:aws:iam::1:role/P")))
        let ask = VaultReleaseRequest(mode: "aws", names: ["aws:lw-prod"], command: "terraform apply")
        let first = await broker.release(ask, caller: card)
        // Terraform starts several providers at once: one question.
        let parallel = await broker.release(ask, caller: card)
        #expect(parallel.id == first.id && approvals.raisedIds.count == 1)
        approvals.answer(try #require(first.id), approveOnce)
        #expect(await waitResult(broker, try #require(first.id)).credentials?.AccessKeyId == "ASIA1")
        try await Task.sleep(for: .milliseconds(50))
        let next = await broker.release(ask, caller: card)
        #expect(next.status == .pending && next.id != first.id)
    }

    @Test func manySecretsAreDeletedInOneApproval() async throws {
        let (broker, store, approvals) = try await makeBroker()
        let plan = await broker.deleteMany(VaultDeleteRequest(names: ["ASK", "ASK2", "GONE"], dryRun: true), caller: card, trusted: false)
        #expect(plan.resolved == ["ASK": "delete", "ASK2": "delete", "GONE": "missing"])
        #expect(try await store.secret("ASK") != nil)

        let asked = await broker.deleteMany(
            VaultDeleteRequest(names: ["ASK", "ASK2", "GONE"], reason: "Delete two leftover secrets nothing uses any more"),
            caller: card, trusted: false)
        #expect(asked.status == .pending)
        let request = try #require(approvals.raised.last)
        #expect(request.title == "Card one wants to delete the Ask and the Ask2")
        #expect(request.body == "Delete two leftover secrets nothing uses any more")
        #expect(request.requiresBiometry)
        #expect(!request.options.contains(approveForCard))
        approvals.answer(request.id, approveOnce)
        let done = await waitResult(broker, try #require(asked.id))
        #expect(done.status == .granted && done.message == "deleted 2 of 2 secrets")
        #expect(try await store.secret("ASK") == nil)
        #expect(try await store.secret("ASK2") == nil)
        #expect(try await store.secret("OPEN") != nil)
        let log = await store.log(limit: 20)
        #expect(log.filter { $0.action == "delete" && $0.outcome == .allowed && $0.decider == .human }.map(\.secret).sorted() == ["ASK", "ASK2"])
    }

    @Test func aRestartAsksOnceForRequestsSavedAlike() async throws {
        let (broker, store, _) = try await makeBroker()
        let one = await broker.release(run(["ASK"]), caller: card)
        let two = await broker.release(run(["ASK", "OPEN"]), caller: card)
        let approvals = ScriptedApprovals()
        let restarted = VaultBroker(store: store, jev: nil, approvals: approvals, machine: "test")
        await restarted.configure(approvalTimeout: 5, pollInterval: 0.02)
        await restarted.restore()
        #expect(approvals.raisedIds == [try #require(one.id)])
        approvals.answer(try #require(one.id), approveOnce)
        #expect(await waitResult(restarted, try #require(two.id)).values == ["ASK": "ask-value", "OPEN": "open-value"])
    }
}
