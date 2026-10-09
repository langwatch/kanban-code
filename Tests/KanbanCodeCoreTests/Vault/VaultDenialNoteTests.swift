import Foundation
import Testing
@testable import KanbanCodeCore
@testable import KanbanCodeRemoteKit

/// Approvals the test answers by hand, with the whole answer.
private final class NotingApprovals: VaultApprovals, @unchecked Sendable {
    let lock = NSLock()
    var raised: [AttentionRequest] = []
    var answers: [String: VaultHumanAnswer] = [:]
    var closed: [String: String] = [:]

    func raise(_ request: AttentionRequest) async { lock.withLock { raised.append(request) } }
    func resolution(of id: String) async -> (resolution: String?, by: String)? {
        lock.withLock { answers[id].map { ($0.resolution, $0.by) } }
    }
    func answer(of id: String) async -> VaultHumanAnswer? { lock.withLock { answers[id] } }
    func close(id: String, resolution: String, by: String) async { lock.withLock { closed[id] = by } }

    func set(_ id: String, _ answer: VaultHumanAnswer) { lock.withLock { answers[id] = answer } }
}

private struct DenyingJev: JevJudging {
    func judge(_ question: JevReleaseQuestion) async -> JevVerdict? {
        JevVerdict(choice: .deny, confidence: 0.91)
    }
}

private let card = VaultCaller(cardId: "card_1", sessionId: "s1", pid: 42, ancestry: ["kv", "zsh", "tmux"])

private func makeBroker(timeout: TimeInterval = 5, jev: (any JevJudging)? = nil) async throws -> (VaultBroker, VaultStore, NotingApprovals) {
    let dir = NSTemporaryDirectory() + "vault-note-\(UUID().uuidString.prefix(8))"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let store = VaultStore(directory: dir, keys: MemoryVaultKeyProvider())
    try await store.ensureIdentity()
    try await store.upsert(VaultSecret(name: "PROD_KEY", value: "prod-value", tier: .ask))
    try await store.upsert(VaultSecret(name: "JUDGED", value: "judged-value", tier: .judged, rules: "deploys only"))
    let approvals = NotingApprovals()
    let broker = VaultBroker(store: store, jev: jev, approvals: approvals, machine: "test") { _ in "Card one" }
    await broker.configure(approvalTimeout: timeout, pollInterval: 0.02)
    return (broker, store, approvals)
}

private func ask(_ broker: VaultBroker, name: String = "PROD_KEY") async -> VaultResponse {
    await broker.release(VaultReleaseRequest(mode: "run", names: [name], command: "deploy.sh", reason: "Deploy the docs site to production"),
                         caller: card)
}

private func waitResult(_ broker: VaultBroker, _ id: String, tries: Int = 300) async -> VaultResponse {
    for _ in 0..<tries {
        let r = await broker.poll(id: id)
        if r.status != .pending { return r }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await broker.poll(id: id)
}

private let why = "what? why do you need prod credentials? you are testing lw-dev"

@Suite("Vault denial note")
struct VaultDenialNoteTests {
    // MARK: The note itself

    @Test("a note is trimmed, made one line, stripped of control characters and cut at the limit")
    func cleaning() {
        #expect(DenialNote.clean("  use the dev key  ") == "use the dev key")
        #expect(DenialNote.clean("line one\nline two\r\n\tthree") == "line one line two three")
        #expect(DenialNote.clean("no\u{1B}[31m colour\u{07}\u{00} here\u{202E}") == "no[31m colour here")
        #expect(DenialNote.clean(nil) == nil)
        #expect(DenialNote.clean("") == nil)
        #expect(DenialNote.clean(" \n\t ") == nil)
        let long = String(repeating: "a", count: 2 * DenialNote.limit)
        #expect(DenialNote.clean(long)?.count == DenialNote.limit)
        #expect(DenialNote.clean("você está testando lw-dev 🙂") == "você está testando lw-dev 🙂")
    }

    @Test("the note field waits 20s, then 45s from each keystroke, 120s at most, and signs every 8s")
    func pacing() {
        let t0 = Date(timeIntervalSince1970: 2_000_000_000)
        var pacer = DenialNotePacer(deniedAt: t0)
        #expect(pacer.deadline == t0.addingTimeInterval(20))
        let first = pacer.typed(now: t0.addingTimeInterval(5))
        #expect(first)
        #expect(pacer.deadline == t0.addingTimeInterval(50))
        let soon = pacer.typed(now: t0.addingTimeInterval(9))
        #expect(!soon)
        #expect(pacer.deadline == t0.addingTimeInterval(54))
        let later = pacer.typed(now: t0.addingTimeInterval(14))
        #expect(later)
        _ = pacer.typed(now: t0.addingTimeInterval(100))
        #expect(pacer.deadline == t0.addingTimeInterval(120))
    }

    // MARK: The broker

    @Test("a refusal with a note gives the caller the note, and the audit log and the asks summary keep it")
    func deniedWithNote() async throws {
        let (broker, store, approvals) = try await makeBroker()
        let pending = await ask(broker)
        let id = try #require(pending.id)
        #expect(pending.status == .pending)
        approvals.set(id, VaultHumanAnswer(resolution: "Deny", by: "mac", note: "  \(why)\n"))
        let r = await waitResult(broker, id)
        #expect(r.status == .denied)
        #expect(r.ownerNote == why)
        #expect(r.message == "Rogerio denied it: \(why)")
        #expect(r.values == nil)

        let line = try #require(await store.log().first { $0.outcome == .denied })
        #expect(line.decider == .human)
        #expect(line.detail == "by mac")
        #expect(line.note == why)
        #expect(line.requestId == id)
        // The line on disk carries it, so the mirrors on the peers do too.
        let raw = try String(contentsOfFile: await store.auditPath, encoding: .utf8)
        #expect(raw.contains("\"note\":\"what? why do you need prod credentials? you are testing lw-dev\""))

        let summary = try #require(await store.askSummary(since: Date().addingTimeInterval(-60)).first { $0.secret == "PROD_KEY" })
        #expect(summary.denied == 1)
        #expect(summary.notes == [.init(text: why, count: 1)])
    }

    @Test("a refusal without a note reads as it always did")
    func deniedWithoutNote() async throws {
        let (broker, store, approvals) = try await makeBroker()
        let id = try #require(await ask(broker).id)
        approvals.set(id, VaultHumanAnswer(resolution: "Deny", by: "phone"))
        let r = await waitResult(broker, id)
        #expect(r.status == .denied)
        #expect(r.message == "Rogerio denied it.")
        #expect(r.ownerNote == nil)
        let line = try #require(await store.log().first { $0.outcome == .denied })
        #expect(line.note == nil)
        let raw = try String(contentsOfFile: await store.auditPath, encoding: .utf8)
        #expect(!raw.contains("\"note\""))
        let encoded = String(decoding: try JSONEncoder.vault.encode(r), as: UTF8.self)
        #expect(!encoded.contains("ownerNote"))
    }

    @Test("a refusal whose device shows the note field is held until the note arrives")
    func heldForTheNote() async throws {
        let (broker, _, approvals) = try await makeBroker()
        let id = try #require(await ask(broker).id)
        approvals.set(id, VaultHumanAnswer(resolution: "Deny", by: "mac", noteUntil: Date().addingTimeInterval(4)))
        try await Task.sleep(for: .milliseconds(300))
        #expect(await broker.poll(id: id).status == .pending)
        // The owner is writing: the window moves.
        approvals.set(id, VaultHumanAnswer(resolution: "Deny", by: "mac", noteUntil: Date().addingTimeInterval(8)))
        try await Task.sleep(for: .milliseconds(200))
        #expect(await broker.poll(id: id).status == .pending)
        let sent = Date()
        approvals.set(id, VaultHumanAnswer(resolution: "Deny", by: "mac", note: why))
        let r = await waitResult(broker, id)
        #expect(r.ownerNote == why)
        #expect(Date().timeIntervalSince(sent) < 2)
    }

    @Test("Skip releases a held refusal at once, without a note")
    func skipped() async throws {
        let (broker, _, approvals) = try await makeBroker()
        let id = try #require(await ask(broker).id)
        approvals.set(id, VaultHumanAnswer(resolution: "Deny", by: "mac", noteUntil: Date().addingTimeInterval(4)))
        try await Task.sleep(for: .milliseconds(150))
        #expect(await broker.poll(id: id).status == .pending)
        let skippedAt = Date()
        approvals.set(id, VaultHumanAnswer(resolution: "Deny", by: "mac"))
        let r = await waitResult(broker, id)
        #expect(r.message == "Rogerio denied it.")
        #expect(r.ownerNote == nil)
        #expect(Date().timeIntervalSince(skippedAt) < 2)
    }

    @Test("a held refusal goes out without a note when the window ends")
    func windowEnds() async throws {
        let (broker, _, approvals) = try await makeBroker()
        let id = try #require(await ask(broker).id)
        let denied = Date()
        approvals.set(id, VaultHumanAnswer(resolution: "Deny", by: "phone", noteUntil: denied.addingTimeInterval(0.6)))
        let r = await waitResult(broker, id)
        #expect(r.status == .denied)
        #expect(r.message == "Rogerio denied it.")
        #expect(r.ownerNote == nil)
        // Held for the whole window, and well short of the approval timeout.
        #expect(Date().timeIntervalSince(denied) >= 0.6)
        #expect(Date().timeIntervalSince(denied) < 4)
    }

    @Test("every caller waiting on the same question gets the note")
    func joinedCallers() async throws {
        let (broker, _, approvals) = try await makeBroker()
        let first = try #require(await ask(broker).id)
        let second = try #require(await broker.release(
            VaultReleaseRequest(mode: "run", names: ["PROD_KEY"], command: "other.sh", reason: "Deploy the docs site to production"),
            caller: card).id)
        approvals.set(first, VaultHumanAnswer(resolution: "Deny", by: "mac", note: why))
        #expect(await waitResult(broker, first).ownerNote == why)
        #expect(await waitResult(broker, second).ownerNote == why)
    }

    @Test("an approval takes no note and no wait")
    func approvalIgnoresNote() async throws {
        let (broker, store, approvals) = try await makeBroker()
        let id = try #require(await ask(broker).id)
        approvals.set(id, VaultHumanAnswer(resolution: "Approve once", by: "mac", note: why, noteUntil: Date().addingTimeInterval(30)))
        let r = await waitResult(broker, id)
        #expect(r.status == .granted)
        #expect(r.ownerNote == nil)
        #expect(await store.log().allSatisfy { $0.note == nil })
    }

    @Test("a timeout and a Jev denial carry no owner note")
    func notOwnerDenials() async throws {
        let (broker, store, _) = try await makeBroker(timeout: 0.3)
        let id = try #require(await ask(broker).id)
        let timedOut = await waitResult(broker, id)
        #expect(timedOut.status == .denied)
        #expect(timedOut.message.hasPrefix("No answer in"))
        #expect(timedOut.ownerNote == nil)
        #expect(await store.log().first { $0.decider == .timeout }?.note == nil)

        let (judged, judgedStore, approvals) = try await makeBroker(jev: DenyingJev())
        let r = await ask(judged, name: "JUDGED")
        #expect(r.status == .denied)
        #expect(r.message.contains("Jev denied it against the secret's rules (91%)"))
        #expect(r.ownerNote == nil)
        #expect(approvals.raised.isEmpty)
        #expect(await judgedStore.log().allSatisfy { $0.note == nil })
    }

    // MARK: Older peers and devices

    @Test("an answer, a request, a response and an audit line from an older build decode without the note")
    func olderBuilds() throws {
        let resolve = try JSONDecoder.remote.decode(AttentionResolveRequest.self, from: Data(#"{"resolution":"Deny","by":"phone"}"#.utf8))
        #expect(resolve.note == nil && resolve.noteFollows == nil)

        let old = AttentionRequest(id: "vault_1", cardId: nil, kind: .vaultApproval, title: "t", body: "",
                                   options: AttentionRequest.vaultApprovalOptions, createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let wire = String(decoding: try JSONEncoder.remote.encode(old), as: UTF8.self)
        #expect(!wire.contains("resolutionNote") && !wire.contains("noteUntil"))
        #expect(try JSONDecoder.remote.decode(AttentionRequest.self, from: Data(wire.utf8)) == old)

        let response = try JSONDecoder.vault.decode(VaultResponse.self, from: Data(#"{"status":"denied","message":"Rogerio denied it.","id":"vault_1"}"#.utf8))
        #expect(response.ownerNote == nil)

        let line = #"{"at":"2026-10-09T10:00:00Z","machine":"box","secret":"A","outcome":"denied","decider":"human","action":"run","detail":"by phone"}"#
        #expect(try JSONDecoder.vault.decode(VaultAuditEntry.self, from: Data(line.utf8)).note == nil)

        let summary = #"{"secret":"A","asks":1,"approved":0,"denied":1,"outsideCard":0,"lastAt":"2026-10-09T10:00:00Z","reasons":[],"why":[],"commands":[]}"#
        #expect(try JSONDecoder.vault.decode(VaultAskSummary.self, from: Data(summary.utf8)).notes == nil)
    }

    // MARK: The routes a device or a peer master calls

    @Test("resolve carries the note and noteFollows to the host; an older body carries neither")
    func resolveRoute() async throws {
        let f = try await RemoteServerFixture()
        defer { f.shutdown() }
        for id in ["vault_a", "vault_b", "vault_c"] {
            f.host.raise(AttentionRequest(id: id, cardId: nil, kind: .vaultApproval, title: "t", body: "",
                                          options: AttentionRequest.vaultApprovalOptions))
        }
        let withNote = try JSONEncoder.remote.encode(AttentionResolveRequest(resolution: "Deny", by: "mac", note: why))
        #expect(try await f.request("POST", "/v1/attention/vault_a/resolve", token: f.fullToken, body: withNote).0 == 204)
        let follows = try JSONEncoder.remote.encode(AttentionResolveRequest(resolution: "Deny", noteFollows: true))
        #expect(try await f.request("POST", "/v1/attention/vault_b/resolve", token: f.fullToken, body: follows).0 == 204)
        #expect(try await f.request("POST", "/v1/attention/vault_c/resolve", token: f.fullToken,
                                    body: Data(#"{"resolution":"Deny"}"#.utf8)).0 == 204)
        let got = f.host.state.withLock { $0.resolutionNotes }
        #expect(got.map(\.id) == ["vault_a", "vault_b", "vault_c"])
        #expect(got.map(\.note) == [why, nil, nil])
        #expect(got.map(\.noteFollows) == [false, true, false])
    }

    @Test("the note route takes a note, a skip and a typing sign, and no agent token")
    func noteRoute() async throws {
        let f = try await RemoteServerFixture()
        defer { f.shutdown() }
        let note = try JSONEncoder.remote.encode(AttentionNoteRequest(note: why))
        #expect(try await f.request("POST", "/v1/attention/vault_a/note", token: f.fullToken, body: note).0 == 204)
        #expect(try await f.request("POST", "/v1/attention/vault_a/note", token: f.fullToken, body: Data("{}".utf8)).0 == 204)
        let typing = try JSONEncoder.remote.encode(AttentionNoteRequest(note: nil, typing: true))
        #expect(try await f.request("POST", "/v1/attention/vault_a/note", token: f.fullToken, body: typing).0 == 204)
        #expect(try await f.request("POST", "/v1/attention/vault_a/note", token: f.agentToken, body: note).0 == 403)
        let got = f.host.state.withLock { $0.notes }
        #expect(got.map(\.note) == [why, nil, nil])
        #expect(got.map(\.typing) == [false, false, true])
        #expect(RemoteScopePolicy.peer.contains("POST attention/*/note"))
    }

    // MARK: The master

    @MainActor private func makeEngine() -> (MasterEngine, BoardStore) {
        let dir = NSTemporaryDirectory() + "kanban-denial-note-\(UUID().uuidString)"
        let store = BoardStore(
            effectHandler: EffectHandler(coordinationStore: CoordinationStore(basePath: dir)),
            discovery: ClaudeCodeSessionDiscovery(),
            coordinationStore: CoordinationStore(basePath: dir)
        )
        let rush = RushCliAdapter(executable: "/nonexistent/rush")
        let engine = MasterEngine(store: store, settingsStore: SettingsStore(basePath: dir),
                                  launcher: LaunchSession(tmux: RoutingTmuxAdapter(rush: rush)),
                                  tmux: RoutingTmuxAdapter(rush: rush), registry: CodingAssistantRegistry())
        return (engine, store)
    }

    @MainActor private func raise(_ store: BoardStore, _ id: String, kind: AttentionRequest.Kind = .vaultApproval) {
        store.dispatch(.attentionRaised(AttentionRequest(
            id: id, cardId: nil, kind: kind, title: "A card wants to use the prod key", body: "",
            options: AttentionRequest.vaultApprovalOptions, requiresBiometry: true)))
    }

    @Test("Deny with a note keeps the cleaned note on the request, for the vault to read")
    @MainActor func engineDeniesWithNote() async throws {
        let (engine, store) = makeEngine()
        raise(store, "vault_1")
        try await engine.resolveAttention(id: "vault_1", resolution: "Deny", by: "mac", note: " \(why)\n", noteFollows: true)
        let request = try #require(store.state.attentionRequests["vault_1"])
        #expect(!request.isOpen)
        #expect(request.resolutionNote == why)
        // The note came with the answer: no wait for another.
        #expect(request.noteUntil == nil)
        let answer = await StoreVaultApprovals(store: store).answer(of: "vault_1")
        #expect(answer == VaultHumanAnswer(resolution: "Deny", by: "mac", note: why))
    }

    @Test("Deny with noteFollows waits for the note, which Send attaches and Skip leaves out")
    @MainActor func engineWaitsForTheNote() async throws {
        let (engine, store) = makeEngine()
        raise(store, "vault_1")
        try await engine.resolveAttention(id: "vault_1", resolution: "Deny", by: "phone", noteFollows: true)
        let until = try #require(store.state.attentionRequests["vault_1"]?.noteUntil)
        #expect(abs(until.timeIntervalSinceNow - DenialNote.window) < 2)
        #expect(store.state.openAttentionRequests.isEmpty)

        try await engine.noteAttention(id: "vault_1", note: nil, typing: true)
        let longer = try #require(store.state.attentionRequests["vault_1"]?.noteUntil)
        #expect(abs(longer.timeIntervalSinceNow - DenialNote.typingWindow) < 2)
        #expect(store.state.attentionRequests["vault_1"]?.resolutionNote == nil)

        try await engine.noteAttention(id: "vault_1", note: why)
        #expect(store.state.attentionRequests["vault_1"]?.resolutionNote == why)
        #expect(store.state.attentionRequests["vault_1"]?.noteUntil == nil)

        // A second note finds the refusal already sent.
        await #expect(throws: RemoteHostError.self) { try await engine.noteAttention(id: "vault_1", note: "again") }
        #expect(store.state.attentionRequests["vault_1"]?.resolutionNote == why)

        raise(store, "vault_2")
        try await engine.resolveAttention(id: "vault_2", resolution: "Deny", by: "phone", noteFollows: true)
        try await engine.noteAttention(id: "vault_2", note: nil)
        #expect(store.state.attentionRequests["vault_2"]?.resolutionNote == nil)
        #expect(store.state.attentionRequests["vault_2"]?.noteUntil == nil)
    }

    @Test("a plain Deny, as a notification action or an older phone sends it, waits for no note")
    @MainActor func plainDeny() async throws {
        let (engine, store) = makeEngine()
        raise(store, "vault_1")
        try await engine.resolveAttention(id: "vault_1", resolution: "Deny", by: "mac")
        let request = try #require(store.state.attentionRequests["vault_1"])
        #expect(request.resolution == "Deny" && request.resolutionNote == nil && request.noteUntil == nil)
        do {
            try await engine.noteAttention(id: "vault_1", note: why)
            Issue.record("a refusal that went out takes no note")
        } catch let error as RemoteHostError {
            #expect(error.kind == .conflict)
            #expect(error.message == AttentionAnswerCopy.noteTooLate)
        }
        #expect(store.state.attentionRequests["vault_1"]?.resolutionNote == nil)
    }

    @Test("a note past its window is refused, and an approval never takes one")
    @MainActor func lateAndApproved() async throws {
        let (engine, store) = makeEngine()
        raise(store, "vault_1")
        store.dispatch(.attentionResolved(id: "vault_1", resolution: "Deny", by: "mac",
                                          noteUntil: Date().addingTimeInterval(-DenialNote.slack - 1)))
        await #expect(throws: RemoteHostError.self) { try await engine.noteAttention(id: "vault_1", note: why) }
        #expect(store.state.attentionRequests["vault_1"]?.resolutionNote == nil)

        raise(store, "vault_2")
        try await engine.resolveAttention(id: "vault_2", resolution: "Approve once", by: "mac", note: why, noteFollows: true)
        let approved = try #require(store.state.attentionRequests["vault_2"])
        #expect(approved.resolutionNote == nil && approved.noteUntil == nil)
        await #expect(throws: RemoteHostError.self) { try await engine.noteAttention(id: "vault_2", note: why) }
        await #expect(throws: RemoteHostError.self) { try await engine.noteAttention(id: "vault_gone", note: why) }
    }
}
