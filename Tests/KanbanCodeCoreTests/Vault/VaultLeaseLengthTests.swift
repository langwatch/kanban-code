import Foundation
import Testing
@testable import KanbanCodeCore
@testable import KanbanCodeRemoteKit

private func tempVaultDir() -> String {
    let path = NSTemporaryDirectory() + "vault-lease-\(UUID().uuidString.prefix(8))"
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

/// Approvals answered by the test with the option at `pick` of the raised request.
private final class PickingApprovals: VaultApprovals, @unchecked Sendable {
    let lock = NSLock()
    var raised: [AttentionRequest] = []
    /// Picks the answer among the request's options; nil leaves it open.
    var pick: (@Sendable ([String]) -> String?)?

    init(pick: (@Sendable ([String]) -> String?)?) { self.pick = pick }

    func raise(_ request: AttentionRequest) async { lock.withLock { raised.append(request) } }
    func resolution(of id: String) async -> (resolution: String?, by: String)? {
        lock.withLock {
            guard let request = raised.first(where: { $0.id == id }), let answer = pick?(request.options) else { return nil }
            return (answer, "mac")
        }
    }
    func close(id: String, resolution: String, by: String) async {}
}

private let hour: TimeInterval = 3600
private let card = VaultCaller(cardId: "card_1", sessionId: "s1", pid: 42, ancestry: ["kv", "zsh", "tmux"])
private let leaseOption: @Sendable ([String]) -> String? = { $0.first(where: AttentionRequest.isVaultLeaseOption) }

private func makeBroker(pick: (@Sendable ([String]) -> String?)?) async throws -> (VaultBroker, VaultStore, PickingApprovals) {
    let store = VaultStore(directory: tempVaultDir(), keys: MemoryVaultKeyProvider())
    try await store.ensureIdentity()
    try await store.upsert(VaultSecret(name: "HOURLY", value: "hourly-secret-value", tier: .ask,
                                       leasePolicy: VaultLeasePolicy(leaseSeconds: hour)))
    try await store.upsert(VaultSecret(name: "DAYS", value: "two-days-secret-value", tier: .ask))
    try await store.upsert(VaultSecret(name: "OPEN", value: "open-secret-value-0001", tier: .open))
    let approvals = PickingApprovals(pick: pick)
    let broker = VaultBroker(store: store, jev: nil, approvals: approvals, machine: "test") { _ in "Card one" }
    await broker.configure(approvalTimeout: 2, pollInterval: 0.02)
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

@Suite("Vault lease length per secret")
struct VaultLeaseLengthTests {
    @Test func lengthsOutsideOneMinuteToTwoDaysAreRefused() {
        #expect(VaultLeasePolicy.problem(leaseSeconds: 60) == nil)
        #expect(VaultLeasePolicy.problem(leaseSeconds: hour) == nil)
        #expect(VaultLeasePolicy.problem(leaseSeconds: VaultLeasePolicy.maximumLease) == nil)
        #expect(VaultLeasePolicy.problem(leaseSeconds: 59) == "a lease lasts at least 1 minute")
        #expect(VaultLeasePolicy.problem(leaseSeconds: 0) != nil)
        #expect(VaultLeasePolicy.problem(leaseSeconds: -hour) != nil)
        #expect(VaultLeasePolicy.problem(leaseSeconds: .nan) != nil)
        #expect(VaultLeasePolicy.problem(leaseSeconds: VaultLeasePolicy.maximumLease + 1) == "a lease lasts at most 2 days")
    }

    @Test func aStoredLengthOutsideTheBoundsIsBroughtBackInside() throws {
        #expect(VaultLeasePolicy(leaseSeconds: 5).leaseSeconds == 60)
        #expect(VaultLeasePolicy(leaseSeconds: 30 * 86400).leaseSeconds == VaultLeasePolicy.maximumLease)
        // A file written by hand skips the initialiser.
        let decoded = try JSONDecoder().decode(VaultLeasePolicy.self, from: Data(#"{"leaseSeconds":9999999,"everyUseAsks":false}"#.utf8))
        #expect(decoded.leaseSeconds == 9_999_999)
        #expect(decoded.grantedSeconds == VaultLeasePolicy.maximumLease)
    }

    @Test func theLeaseOptionNamesTheLength() {
        #expect(AttentionRequest.vaultApprovalOptions == ["Approve for this card (2 days)", "Approve once", "Deny"])
        #expect(AttentionRequest.vaultLeaseOption(leaseSeconds: hour) == "Approve for this card (1 hour)")
        #expect(AttentionRequest.vaultLeaseOption(leaseSeconds: 15 * 60) == "Approve for this card (15 minutes)")
        #expect(AttentionRequest.vaultLeaseOption(leaseSeconds: 8 * hour) == "Approve for this card (8 hours)")
        #expect(AttentionRequest.vaultLeaseOption(leaseSeconds: 90 * 60) == "Approve for this card (90 minutes)")
        #expect(VaultPolicy.approvalOptions(everyUseAsks: false, insideCard: true, leaseSeconds: hour)
            == ["Approve for this card (1 hour)", "Approve once", "Deny"])
        #expect(VaultPolicy.approvalOptions(everyUseAsks: true, insideCard: true, leaseSeconds: hour) == ["Approve once", "Deny"])
        for length in VaultLeasePolicy.presets {
            #expect(VaultPolicy.approval(from: AttentionRequest.vaultLeaseOption(leaseSeconds: length)) == .lease)
        }
        #expect(VaultPolicy.approval(from: "Approve once") == .once)
    }

    @Test func aOneHourLeaseEndsAfterOneHour() async throws {
        let (broker, store, approvals) = try await makeBroker(pick: leaseOption)
        let r = await broker.release(VaultReleaseRequest(mode: "run", names: ["HOURLY"], command: "psql -f report.sql",
                                                         reason: "Run the weekly report against the database"), caller: card)
        #expect(r.status == .pending)
        let raised = try #require(approvals.raised.first)
        #expect(raised.options == ["Approve for this card (1 hour)", "Approve once", "Deny"])
        #expect(raised.vault?.leaseSeconds == hour)
        #expect(raised.vault?.rows().first { $0.label == "Lease" }?.value == "1 hour if approved for the card")
        let done = await waitResult(broker, try #require(r.id))
        #expect(done.values == ["HOURLY": "hourly-secret-value"])

        let lease = try #require(await store.activeLease(cardId: "card_1", secret: "HOURLY"))
        #expect(lease.expiresAt.timeIntervalSince(lease.grantedAt) == hour)
        #expect(await store.log(secret: "HOURLY").first?.detail == "approved by mac, card lease of 1 hour")

        approvals.pick = nil
        let within = await broker.release(VaultReleaseRequest(mode: "run", names: ["HOURLY"]), caller: card,
                                          now: lease.grantedAt.addingTimeInterval(hour - 1))
        #expect(within.status == .granted)
        let after = await broker.release(VaultReleaseRequest(mode: "run", names: ["HOURLY"]), caller: card,
                                         now: lease.grantedAt.addingTimeInterval(hour + 1))
        #expect(after.status == .pending)
        #expect(await store.activeLease(cardId: "card_1", secret: "HOURLY", now: lease.grantedAt.addingTimeInterval(hour + 1)) == nil)
    }

    @Test func kvRequestLeasesForTheSecretsLength() async throws {
        let (broker, store, approvals) = try await makeBroker(pick: leaseOption)
        let r = await broker.requestLease(VaultLeaseRequest(names: ["HOURLY"], reason: "Run the weekly report against the database"),
                                          caller: card)
        let raised = try #require(approvals.raised.first)
        #expect(raised.options == ["Approve for this card (1 hour)", "Deny"])
        #expect(raised.title == "Card one wants to use the Hourly for 1 hour")
        let done = await waitResult(broker, try #require(r.id))
        #expect(done.message == "leased HOURLY to the card for 1 hour")
        let lease = try #require(await store.activeLease(cardId: "card_1", secret: "HOURLY"))
        #expect(lease.expiresAt.timeIntervalSince(lease.grantedAt) == hour)
    }

    @Test func oneApprovalForSeveralSecretsLastsTheShortestLength() async throws {
        let (broker, store, approvals) = try await makeBroker(pick: leaseOption)
        let r = await broker.release(VaultReleaseRequest(mode: "run", names: ["HOURLY", "DAYS"]), caller: card)
        #expect(approvals.raised.first?.options.first == "Approve for this card (1 hour)")
        _ = await waitResult(broker, try #require(r.id))
        for name in ["HOURLY", "DAYS"] {
            let lease = try #require(await store.activeLease(cardId: "card_1", secret: name))
            #expect(lease.expiresAt.timeIntervalSince(lease.grantedAt) == hour)
        }
    }

    @Test func aSecretWithoutALengthOfItsOwnKeepsTwoDays() async throws {
        let (broker, store, approvals) = try await makeBroker(pick: leaseOption)
        let r = await broker.release(VaultReleaseRequest(mode: "run", names: ["DAYS"]), caller: card)
        #expect(approvals.raised.first?.options.first == "Approve for this card (2 days)")
        _ = await waitResult(broker, try #require(r.id))
        let lease = try #require(await store.activeLease(cardId: "card_1", secret: "DAYS"))
        #expect(lease.expiresAt.timeIntervalSince(lease.grantedAt) == VaultLeasePolicy.maximumLease)
    }

    @Test func aLengthShortenedWhileTheRequestWaitsIsTheOneGranted() async throws {
        let (broker, store, approvals) = try await makeBroker(pick: nil)
        let r = await broker.release(VaultReleaseRequest(mode: "run", names: ["DAYS"]), caller: card)
        try await store.update("DAYS") { $0.leasePolicy = VaultLeasePolicy(leaseSeconds: 15 * 60) }
        approvals.lock.withLock { approvals.pick = leaseOption }
        _ = await waitResult(broker, try #require(r.id))
        let lease = try #require(await store.activeLease(cardId: "card_1", secret: "DAYS"))
        #expect(lease.expiresAt.timeIntervalSince(lease.grantedAt) == 15 * 60)
    }

    @Test func editingTheLengthAsksAndThenStoresIt() async throws {
        let (broker, store, approvals) = try await makeBroker(pick: { $0.first })
        let edit = VaultEditRequest(leasePolicy: VaultLeasePolicy(leaseSeconds: 8 * hour))
        let r = await broker.edit("DAYS", edit, caller: card, trusted: false)
        #expect(r.status == .pending)
        let raised = try #require(approvals.raised.first)
        #expect(raised.title == "Card one wants to change the Days lease time")
        #expect(raised.vault?.changeLines == ["Lease time: 8 hours"])
        #expect(await waitResult(broker, try #require(r.id)).status == .granted)
        #expect(try await store.secret("DAYS")?.leasePolicy == VaultLeasePolicy(leaseSeconds: 8 * hour))
    }

    @Test func aLengthOutOfBoundsIsRefusedBeforeAnyoneIsAsked() async throws {
        let (broker, store, approvals) = try await makeBroker(pick: { $0.first })
        var tooLong = VaultLeasePolicy()
        tooLong.leaseSeconds = 3 * 86400
        var tooShort = VaultLeasePolicy()
        tooShort.leaseSeconds = 10
        let long = await broker.edit("DAYS", VaultEditRequest(leasePolicy: tooLong), caller: card, trusted: true)
        #expect(long == .denied("a lease lasts at most 2 days"))
        let short = await broker.editMany(VaultBatchEditRequest(names: ["DAYS"], edit: VaultEditRequest(leasePolicy: tooShort)),
                                          caller: card, trusted: false)
        #expect(short == .denied("a lease lasts at least 1 minute"))
        let added = await broker.add(VaultAddRequest(name: "NEW", value: "v", leasePolicy: tooLong), caller: card, trusted: true)
        #expect(added.status == .denied)
        #expect(approvals.raised.isEmpty)
        #expect(try await store.secret("DAYS")?.leasePolicy == .standard)
        #expect(try await store.secret("NEW") == nil)
    }

    @Test func theLengthReachesTheOtherMasters() async throws {
        let keys = MemoryVaultKeyProvider(Age.Identity.generate())
        let box = VaultStore(directory: tempVaultDir(), keys: keys)
        let mac = VaultStore(directory: tempVaultDir(), keys: keys)
        let t0 = Date(timeIntervalSince1970: 2_000_000_000)
        try await box.upsert(VaultSecret(name: "A", value: "a1", tier: .ask), now: t0)
        try await mac.mergeReplica(try #require(await box.encryptedBlob()))
        #expect(try await mac.secret("A")?.leasePolicy.leaseSeconds == VaultLeasePolicy.maximumLease)

        try await box.update("A", now: t0.addingTimeInterval(10)) { $0.leasePolicy = VaultLeasePolicy(leaseSeconds: hour) }
        let merged = try await mac.mergeReplica(try #require(await box.encryptedBlob()))
        #expect(merged.changedHere)
        #expect(try await mac.secret("A")?.leasePolicy == VaultLeasePolicy(leaseSeconds: hour))
        #expect(try await mac.list().first?.leasePolicy.leaseSeconds == hour)

        // And back: an edit on the Mac replaces the box's.
        try await mac.update("A", now: t0.addingTimeInterval(20)) { $0.leasePolicy = VaultLeasePolicy(leaseSeconds: 15 * 60) }
        try await box.mergeReplica(try #require(await mac.encryptedBlob()))
        #expect(try await box.secret("A")?.leasePolicy.leaseSeconds == 15 * 60)
    }
}

@Suite("Vault audit keeps the command")
struct VaultAuditCommandTests {
    @Test func everyUseUnderALeaseIsLoggedWithItsCommand() async throws {
        let (broker, store, approvals) = try await makeBroker(pick: leaseOption)
        let first = await broker.release(VaultReleaseRequest(mode: "run", names: ["HOURLY"], command: "psql -f first.sql"), caller: card)
        _ = await waitResult(broker, try #require(first.id))
        approvals.pick = nil
        for file in ["second.sql", "third.sql"] {
            let r = await broker.release(VaultReleaseRequest(mode: "env", names: ["HOURLY"], command: "psql -f \(file)"), caller: card)
            #expect(r.status == .granted)
        }
        let allowed = await store.log(secret: "HOURLY").filter { $0.outcome == .allowed }.reversed()
        #expect(allowed.map(\.command) == ["psql -f first.sql", "psql -f second.sql", "psql -f third.sql"])
        #expect(allowed.map(\.decider) == [.human, .lease, .lease])
        #expect(allowed.map(\.cardId) == ["card_1", "card_1", "card_1"])
        #expect(AuditChain.verify(await store.auditLines()).breaks.isEmpty)
    }

    @Test func aHookWrappedCommandUnderALeaseIsLoggedToo() async throws {
        let (broker, store, approvals) = try await makeBroker(pick: leaseOption)
        let first = await broker.release(VaultReleaseRequest(mode: "run", names: ["HOURLY"], command: "psql -f first.sql"), caller: card)
        _ = await waitResult(broker, try #require(first.id))
        approvals.pick = nil
        let r = await broker.release(VaultReleaseRequest(mode: "hook", names: ["HOURLY"], command: "pnpm test:integration"), caller: card)
        #expect(r.values == ["HOURLY": "hourly-secret-value"])
        let entry = try #require(await store.log(secret: "HOURLY").first)
        #expect(entry.action == "hook" && entry.decider == .lease && entry.command == "pnpm test:integration")
    }

    @Test func aDenialKeepsTheCommandThatAsked() async throws {
        let (broker, store, _) = try await makeBroker(pick: { _ in "Deny" })
        let r = await broker.release(VaultReleaseRequest(mode: "run", names: ["HOURLY"], command: "psql -c 'drop table users'",
                                                         reason: "Clean up the staging database before the test"), caller: card)
        #expect(await waitResult(broker, try #require(r.id)).status == .denied)
        let entry = try #require(await store.log(secret: "HOURLY").first)
        #expect(entry.outcome == .denied && entry.decider == .human && entry.detail == "by mac")
        #expect(entry.command == "psql -c 'drop table users'")
        #expect(entry.reason == "Clean up the staging database before the test")
        #expect(AuditChain.verify(await store.auditLines()).breaks.isEmpty)
    }

    @Test func aValueInTheCommandIsNeverWritten() async throws {
        let (broker, store, _) = try await makeBroker(pick: nil)
        let command = "curl -H 'Authorization: Bearer open-secret-value-0001' https://example.test?k=two-days-secret-value"
        let r = await broker.release(VaultReleaseRequest(mode: "run", names: ["OPEN"], command: command,
                                                         reason: "open-secret-value-0001"), caller: card)
        #expect(r.status == .granted)
        let entry = try #require(await store.log(secret: "OPEN").first)
        #expect(entry.command == "curl -H 'Authorization: Bearer {{vault:OPEN}}' https://example.test?k={{vault:DAYS}}")
        #expect(entry.reason == "{{vault:OPEN}}")
        let raw = String(decoding: FileManager.default.contents(atPath: await store.directory + "/audit.jsonl") ?? Data(), as: UTF8.self)
        #expect(!raw.contains("open-secret-value-0001") && !raw.contains("two-days-secret-value"))
        #expect(AuditChain.verify(await store.auditLines()).breaks.isEmpty)
    }

    @Test func aLongCommandIsCutWithAMark() async throws {
        let (broker, store, _) = try await makeBroker(pick: nil)
        let command = String(repeating: "x", count: VaultBroker.auditCommandLimit + 500)
        _ = await broker.release(VaultReleaseRequest(mode: "run", names: ["OPEN"], command: command), caller: card)
        let kept = try #require(await store.log(secret: "OPEN").first?.command)
        #expect(kept.count == VaultBroker.auditCommandLimit + 3 && kept.hasSuffix("..."))
    }
}

@Suite("Vault: recently approved")
struct VaultRecentApprovalsTests {
    @Test func approvalsAreHumanAllowsInTheWindowOrStillLeased() async throws {
        let store = VaultStore(directory: tempVaultDir(), keys: MemoryVaultKeyProvider())
        try await store.ensureIdentity()
        let now = Date()
        func entry(_ secret: String, hoursAgo: Double, decider: VaultDecider = .human, outcome: VaultOutcome = .allowed,
                   leaseHours: Double? = nil) -> VaultAuditEntry {
            let at = now.addingTimeInterval(-hoursAgo * 3600)
            return VaultAuditEntry(at: at, machine: "mac", cardId: "card_1", secret: secret, tier: .ask, outcome: outcome,
                                   decider: decider, action: "run", leaseUntil: leaseHours.map { at.addingTimeInterval($0 * 3600) })
        }
        await store.append(entry("OLD_ONCE", hoursAgo: 30))
        await store.append(entry("OLD_LEASED", hoursAgo: 30, leaseHours: 48))
        await store.append(entry("OLD_LEASE_ENDED", hoursAgo: 30, leaseHours: 1))
        await store.append(entry("RECENT", hoursAgo: 2, leaseHours: 1))
        await store.append(entry("BY_TIER", hoursAgo: 1, decider: .tier))
        await store.append(entry("DENIED", hoursAgo: 1, outcome: .denied))
        _ = await store.appendMirror(machine: "box", lines: [
            String(decoding: try JSONEncoder.vaultLine.encode(entry("ON_BOX", hoursAgo: 3)), as: UTF8.self),
        ])
        let names = await store.approvals(since: now.addingTimeInterval(-24 * 3600), now: now).map(\.secret)
        #expect(names == ["RECENT", "ON_BOX", "OLD_LEASED"])
        let wider = await store.approvals(since: now.addingTimeInterval(-48 * 3600), now: now).map(\.secret)
        #expect(Set(wider) == ["RECENT", "ON_BOX", "OLD_LEASED", "OLD_ONCE", "OLD_LEASE_ENDED"])
    }
}
