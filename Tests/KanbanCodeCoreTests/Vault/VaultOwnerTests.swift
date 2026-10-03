import CryptoKit
import Foundation
import Testing
@testable import KanbanCodeCore
@testable import KanbanCodeRemoteKit

/// A P-256 key in memory standing in for a device's Secure Enclave key.
struct SoftwareOwnerKey: AgeP256Key {
    let key = P256.KeyAgreement.PrivateKey()

    var recipient: Age.P256Recipient { try! Age.P256Recipient(compressed: key.publicKey.compressedRepresentation) }

    func sharedSecret(withEphemeral compressed: Data) throws -> Data {
        try key.sharedSecretFromKeyAgreement(with: try P256.KeyAgreement.PublicKey(compressedRepresentation: compressed))
            .withUnsafeBytes { Data($0) }
    }

    func owner(_ name: String, _ kind: VaultOwnerRecipient.Kind = .mac) -> VaultOwnerRecipient {
        VaultOwnerRecipient(name: name, kind: kind, publicKey: recipient.text)
    }
}

private func tempDir() -> String {
    let path = NSTemporaryDirectory() + "vault-owner-\(UUID().uuidString.prefix(8))"
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

/// Approvals the test answers when it wants to.
private final class ManualApprovals: VaultApprovals, @unchecked Sendable {
    let lock = NSLock()
    var raised: [AttentionRequest] = []
    var answers: [String: String] = [:]
    var closed: [String] = []

    func raise(_ request: AttentionRequest) async { lock.withLock { raised.append(request) } }
    func resolution(of id: String) async -> (resolution: String?, by: String)? {
        lock.withLock { answers[id].map { ($0, "mac") } }
    }
    func close(id: String, resolution: String, by: String) async { lock.withLock { closed.append(id) } }
    func answer(_ id: String, _ resolution: String) { lock.withLock { answers[id] = resolution } }
    var last: AttentionRequest? { lock.withLock { raised.last } }
}

private struct AllowJev: JevJudging {
    func judge(_ question: JevReleaseQuestion) async -> JevVerdict? { JevVerdict(choice: .allow, confidence: 0.99) }
}

private let card = VaultCaller(cardId: "card_1", sessionId: "s1", pid: 42, ancestry: ["kv", "zsh", "tmux"])
private let otherCard = VaultCaller(cardId: "card_2", sessionId: "s2", pid: 52, ancestry: ["kv", "zsh", "tmux"])
private let settings = VaultCaller(ancestry: ["settings"])

private struct World {
    let store: VaultStore
    let broker: VaultBroker
    let approvals: ManualApprovals
    let mac: SoftwareOwnerKey
    let recovery: Age.Identity

    func wait(_ id: String) async -> VaultResponse {
        for _ in 0..<300 {
            let r = await broker.poll(id: id)
            if r.status != .pending { return r }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await broker.poll(id: id)
    }

    /// What the Mac does when the human approves: unlock, hand over, answer.
    func approve(_ response: VaultResponse, _ option: String = "Approve once", key: (any AgeP256Key)? = nil,
                 mint: @escaping VaultUnsealer.Mint = { _, _, _ in throw VaultError.invalid("no STS in this test") }) async throws -> VaultResponse {
        let id = try #require(response.id)
        let request = try #require(approvals.lock.withLock { approvals.raised.first { $0.id == id } })
        if let challenge = request.unseal {
            let unsealed = try await VaultUnsealer.answer(challenge, key: key ?? mac, mint: mint)
            await broker.deliver(id: id, unsealed: unsealed)
        }
        approvals.answer(id, option)
        return await wait(id)
    }
}

private func makeWorld(activate: Bool = true, jev: (any JevJudging)? = nil) async throws -> World {
    let store = VaultStore(directory: tempDir(), keys: MemoryVaultKeyProvider())
    try await store.ensureIdentity()
    try await store.upsert(VaultSecret(name: "OPEN", value: "open-value", tier: .open))
    try await store.upsert(VaultSecret(name: "JUDGED", value: "judged-value", tier: .judged))
    try await store.upsert(VaultSecret(name: "ASK", value: "ask-value", tier: .ask))
    try await store.upsert(VaultSecret(name: "NEVER", value: "never-value", tier: .never))
    let approvals = ManualApprovals()
    let broker = VaultBroker(store: store, jev: jev, approvals: approvals, machine: "box", cardTitle: { _ in "Card one" },
                             sts: { _, _, _ in throw VaultError.invalid("the master must not call STS for a sealed key") })
    await broker.configure(approvalTimeout: 5, pollInterval: 0.02)
    let mac = SoftwareOwnerKey()
    let recovery = Age.Identity.generate()
    if activate {
        let keys = [mac.owner("Mac"), VaultOwnerRecipient(name: "Recovery key", kind: .recovery, publicKey: recovery.recipient.text)]
        let r = await broker.setOwnerKeys(keys, caller: settings, trusted: true)
        #expect(r.status == .granted)
    }
    return World(store: store, broker: broker, approvals: approvals, mac: mac, recovery: recovery)
}

@Suite("Age with device keys")
struct AgeDeviceKeyTests {
    @Test func aFileOpensWithTheDeviceKeyAndWithTheRecoveryKey() throws {
        let device = SoftwareOwnerKey()
        let other = SoftwareOwnerKey()
        let recovery = Age.Identity.generate()
        let file = try Age.encrypt(Data("hello".utf8), to: [.p256(device.recipient), .x25519(recovery.recipient)])
        #expect(try Age.decrypt(file, with: device) == Data("hello".utf8))
        #expect(try Age.decrypt(file, with: recovery) == Data("hello".utf8))
        #expect(throws: Age.AgeError.noMatchingIdentity) { try Age.decrypt(file, with: other) }
        #expect(throws: Age.AgeError.noMatchingIdentity) { try Age.decrypt(file, with: Age.Identity.generate()) }
    }

    @Test func deviceRecipientsRoundTripThroughText() throws {
        let device = SoftwareOwnerKey()
        let text = device.recipient.text
        #expect(text.hasPrefix("age1se1"))
        #expect(try Age.AnyRecipient(text: text) == .p256(device.recipient))
        let recovery = Age.Identity.generate().recipient
        #expect(try Age.AnyRecipient(text: recovery.text) == .x25519(recovery))
    }

    @Test func theAgeToolOpensASealedSecretWithTheRecoveryKey() throws {
        guard let age = ShellCommand.findExecutable("age") else { return }
        let recovery = Age.Identity.generate()
        let sealed = try VaultOwnerSeal.seal(name: "ASK", value: "ask-value", to: [
            SoftwareOwnerKey().owner("Mac"),
            VaultOwnerRecipient(name: "Recovery key", kind: .recovery, publicKey: recovery.recipient.text),
        ])
        let dir = tempDir()
        try Data(base64Encoded: sealed)!.write(to: URL(fileURLWithPath: dir + "/s.age"))
        try Data((recovery.text + "\n").utf8).write(to: URL(fileURLWithPath: dir + "/key.txt"))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: age)
        p.arguments = ["-d", "-i", dir + "/key.txt", dir + "/s.age"]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(text.contains("ask-value"))
    }

    @Test func aDeviceRefusesASealedValueOfAnotherSecret() async throws {
        let device = SoftwareOwnerKey()
        let sealed = try VaultOwnerSeal.seal(name: "STRIPE", value: "sk", to: [device.owner("Mac")])
        let lie = VaultUnsealChallenge(secrets: [.init(name: "HARMLESS", sealed: sealed)])
        await #expect(throws: VaultOwnerSeal.SealError.wrongSecret(asked: "HARMLESS", holds: "STRIPE")) {
            try await VaultUnsealer.answer(lie, key: device)
        }
        // An earlier name of the same secret is the same secret.
        let renamed = VaultUnsealChallenge(secrets: [.init(name: "STRIPE_KEY", aliases: ["STRIPE"], sealed: sealed)])
        #expect(try await VaultUnsealer.answer(renamed, key: device).values == ["STRIPE_KEY": "sk"])
    }
}

@Suite("Owner-only secrets")
struct VaultOwnerTests {
    @Test func askAndNeverSecretsAreSealedOnceThereAreOwnerKeys() async throws {
        let w = try await makeWorld(activate: false)
        #expect(try await w.store.ownerCounts().plain == 2)
        let onlyDevice = await w.broker.setOwnerKeys([w.mac.owner("Mac")], caller: settings, trusted: true)
        #expect(onlyDevice.status == .granted)
        // No recovery key yet: nothing is sealed.
        #expect(try await w.store.secret("ASK")?.value == "ask-value")

        let keys = [w.mac.owner("Mac"), VaultOwnerRecipient(name: "Recovery key", kind: .recovery, publicKey: w.recovery.recipient.text)]
        #expect(await w.broker.setOwnerKeys(keys, caller: settings, trusted: true).status == .granted)
        let counts = try await w.store.ownerCounts()
        #expect(counts.sealed == 2 && counts.plain == 0)
        for name in ["ASK", "NEVER"] {
            let s = try #require(try await w.store.secret(name))
            #expect(s.value.isEmpty && s.isSealed)
            #expect(try VaultOwnerSeal.open(try #require(s.sealed), with: w.mac).value == "\(name.lowercased())-value")
            #expect(try VaultOwnerSeal.open(try #require(s.sealed), recovery: w.recovery).name == name)
        }
        // The unattended tiers stay as they were.
        #expect(try await w.store.secret("OPEN")?.value == "open-value")
        #expect(try await w.store.secret("JUDGED")?.sealed == nil)
        // The file from before the first seal is kept.
        #expect(FileManager.default.fileExists(atPath: await w.store.preSealBackupPath))
    }

    @Test func theMachineKeyAloneReadsNoOwnerOnlyValue() async throws {
        let w = try await makeWorld()
        let identity = try #require(await w.store.currentIdentity())
        let blob = try #require(await w.store.encryptedBlob())
        let plain = String(decoding: try Age.decrypt(blob, with: identity), as: UTF8.self)
        let wrapper = try JSONSerialization.jsonObject(with: Data(plain.utf8)) as? [String: String]
        let doc = try #require(Data(base64Encoded: wrapper?["doc"] ?? ""))
        let text = String(decoding: doc, as: UTF8.self)
        #expect(text.contains("open-value") && text.contains("judged-value"))
        #expect(!text.contains("ask-value") && !text.contains("never-value"))
    }

    @Test func aNewAskSecretIsSealedAsItIsStored() async throws {
        let w = try await makeWorld()
        let r = await w.broker.add(VaultAddRequest(name: "NEW", value: "new-value", tier: .ask), caller: card, trusted: false)
        #expect(r.status == .granted)
        let s = try #require(try await w.store.secret("NEW"))
        #expect(s.value.isEmpty)
        #expect(try VaultOwnerSeal.open(try #require(s.sealed), with: w.mac).value == "new-value")
        #expect(try await w.store.list().first { $0.name == "NEW" }?.sealed == true)
    }

    @Test func anApprovalUnlocksOnTheDeviceAndHandsTheValueOver() async throws {
        let w = try await makeWorld()
        let asked = await w.broker.release(VaultReleaseRequest(mode: "run", names: ["ASK", "OPEN"], command: "deploy"), caller: card)
        #expect(asked.status == .pending)
        let request = try #require(w.approvals.last)
        #expect(request.requiresBiometry && request.needsDeviceKey)
        #expect(request.unseal?.secrets.map(\.name) == ["ASK"])
        let done = try await w.approve(asked)
        #expect(done.status == .granted)
        #expect(done.values == ["ASK": "ask-value", "OPEN": "open-value"])
        let line = try #require(await w.store.log().first { $0.secret == "ASK" && $0.outcome == .allowed })
        #expect(line.detail?.contains("unlocked by key") == true)
    }

    @Test func anApprovalWithoutTheDeviceKeyReleasesNothing() async throws {
        let w = try await makeWorld()
        let asked = await w.broker.release(VaultReleaseRequest(mode: "run", names: ["ASK"]), caller: card)
        w.approvals.answer(try #require(asked.id), "Approve once")
        let done = await w.wait(try #require(asked.id))
        #expect(done.status == .denied && done.values == nil)
        #expect(done.message.contains("not unlocked on a device"))
    }

    @Test func aLeaseKeepsTheValueForItsWindowAndARestartForgetsIt() async throws {
        let w = try await makeWorld()
        let asked = await w.broker.release(VaultReleaseRequest(mode: "run", names: ["ASK"]), caller: card)
        let done = try await w.approve(asked, "Approve for this card (2 days)")
        #expect(done.values == ["ASK": "ask-value"])
        // The lease covers the next use: no question, the held value.
        let again = await w.broker.release(VaultReleaseRequest(mode: "run", names: ["ASK"]), caller: card)
        #expect(again.status == .granted && again.values == ["ASK": "ask-value"])
        // Another card has no lease.
        #expect(await w.broker.release(VaultReleaseRequest(mode: "run", names: ["ASK"]), caller: otherCard).status == .pending)
        // After a restart the lease is there but the value is not.
        await w.broker.forgetHeld()
        let afterRestart = await w.broker.release(VaultReleaseRequest(mode: "run", names: ["ASK"]), caller: card)
        #expect(afterRestart.status == .pending)
        #expect(w.approvals.last?.vault?.whys == [VaultBroker.lockedWhy])
    }

    @Test func aHookWrappedCommandGoesOnWithoutASealedSecret() async throws {
        let w = try await makeWorld()
        let r = await w.broker.release(VaultReleaseRequest(mode: "hook", names: ["ASK", "OPEN"]), caller: card)
        #expect(r.status == .granted && r.values == ["OPEN": "open-value"] && r.skipped == ["ASK"])
    }

    @Test func neverStaysRefused() async throws {
        let w = try await makeWorld()
        #expect(await w.broker.release(VaultReleaseRequest(mode: "run", names: ["NEVER"]), caller: card).status == .denied)
    }

    @Test func movingATierIntoAskSealsAndOutOfItNeedsADevice() async throws {
        let w = try await makeWorld()
        // Into ask: the master still has the value and seals it.
        #expect(await w.broker.edit("JUDGED", VaultEditRequest(tier: .ask), caller: settings, trusted: true).status == .granted)
        let sealed = try #require(try await w.store.secret("JUDGED"))
        #expect(sealed.value.isEmpty && sealed.isSealed)

        // Out of ask without a device: refused, nothing changes.
        let refused = await w.broker.edit("JUDGED", VaultEditRequest(tier: .judged), caller: settings, trusted: true)
        #expect(refused.status == .denied)
        #expect(try await w.store.secret("JUDGED")?.tier == .ask)

        // Out of ask from an agent: the approval carries the value to open.
        let asked = await w.broker.edit("JUDGED", VaultEditRequest(tier: .judged, reason: "it is a dev key"), caller: card, trusted: false)
        #expect(asked.status == .pending)
        #expect(w.approvals.last?.unseal?.secrets.map(\.name) == ["JUDGED"])
        #expect(try await w.approve(asked).status == .granted)
        let back = try #require(try await w.store.secret("JUDGED"))
        #expect(back.tier == .judged && back.value == "judged-value" && back.sealed == nil)

        // The trusted path with this Mac's own key.
        _ = await w.broker.edit("JUDGED", VaultEditRequest(tier: .never), caller: settings, trusted: true)
        let challenge = await w.broker.editChallenge("JUDGED", VaultEditRequest(tier: .open))
        let unsealed = try await VaultUnsealer.answer(challenge, key: w.mac)
        #expect(await w.broker.edit("JUDGED", VaultEditRequest(tier: .open), caller: settings, trusted: true, unsealed: unsealed).status == .granted)
        #expect(try await w.store.secret("JUDGED")?.value == "judged-value")
    }

    @Test func aRuleEditLeavesASealedValueSealed() async throws {
        let w = try await makeWorld()
        let before = try #require(try await w.store.secret("ASK")?.sealed)
        #expect(await w.broker.edit("ASK", VaultEditRequest(rules: "deploys only"), caller: settings, trusted: true).status == .granted)
        let after = try #require(try await w.store.secret("ASK"))
        #expect(after.sealed == before && after.rules == "deploys only")
    }

    @Test func aSecondDeviceIsEnrolledByADeviceThatHoldsAKey() async throws {
        let w = try await makeWorld()
        let phone = SoftwareOwnerKey()
        let asked = await w.broker.enrol(phone.owner("iPhone", .phone), caller: VaultCaller(remoteDevice: "iPhone"))
        #expect(asked.status == .pending)
        let request = try #require(w.approvals.last)
        #expect(request.unseal?.reseal.count == 2)
        #expect(request.unseal?.resealTo.map(\.name) == ["Mac", "Recovery key", "iPhone"])
        #expect(request.vault?.changeLines.contains { $0.contains(phone.owner("iPhone", .phone).fingerprint) } == true)
        // The phone cannot let itself in.
        await #expect(throws: (any Error).self) { try await w.approve(asked, key: phone) }

        let again = await w.broker.enrol(phone.owner("iPhone", .phone), caller: VaultCaller(remoteDevice: "iPhone"))
        #expect(try await w.approve(again).status == .granted)
        let s = try #require(try await w.store.secret("ASK"))
        #expect(try VaultOwnerSeal.open(try #require(s.sealed), with: phone).value == "ask-value")
        #expect(try VaultOwnerSeal.open(try #require(s.sealed), with: w.mac).value == "ask-value")
        #expect(try VaultOwnerSeal.open(try #require(s.sealed), recovery: w.recovery).value == "ask-value")
        #expect(try await w.store.owner()?.devices.count == 2)

        // Removing it again: its key no longer opens anything.
        let keys = try #require(try await w.store.owner()).recipients.filter { $0.kind != .phone }
        let unsealed = try await VaultUnsealer.answer(await w.broker.ownerChallenge(keys), key: w.mac)
        #expect(await w.broker.setOwnerKeys(keys, caller: settings, trusted: true, unsealed: unsealed).status == .granted)
        let after = try #require(try await w.store.secret("ASK"))
        #expect(throws: Age.AgeError.noMatchingIdentity) { try VaultOwnerSeal.open(try #require(after.sealed), with: phone) }
    }

    @Test func changingTheOwnerKeysWithoutEncryptingAgainIsRefused() async throws {
        let w = try await makeWorld()
        let intruder = SoftwareOwnerKey()
        let keys = try #require(try await w.store.owner()).recipients + [intruder.owner("Intruder")]
        #expect(await w.broker.setOwnerKeys(keys, caller: settings, trusted: true).status == .denied)
        #expect(try await w.store.owner()?.recipients.count == 2)
    }

    @Test func aReplicaThatStillHoldsAPlainValueIsSealedOnMerge() async throws {
        let w = try await makeWorld()
        let identity = try #require(await w.store.currentIdentity())
        let other = VaultStore(directory: tempDir(), keys: MemoryVaultKeyProvider(identity))
        try await other.upsert(VaultSecret(name: "LATE", value: "late-value", tier: .ask))
        try await w.store.mergeReplica(try #require(await other.encryptedBlob()))
        let s = try #require(try await w.store.secret("LATE"))
        #expect(s.value.isEmpty && s.isSealed)
        // The sealed copy goes back and wins there.
        try await other.mergeReplica(try #require(await w.store.encryptedBlob()))
        #expect(try await other.secret("LATE")?.value.isEmpty == true)
        #expect(try await other.secret("ASK")?.isSealed == true)
    }
}

@Suite("AWS credentials minted on the device")
struct VaultDeviceAwsTests {
    static let longLived = #"{"accessKeyId":"AKIAX","secretAccessKey":"s"}"#

    private func world(tier: VaultTier, everyUse: Bool = false) async throws -> World {
        let w = try await makeWorld(activate: false, jev: AllowJev())
        try await w.store.upsert(VaultSecret(name: "AWS_ROOT", value: Self.longLived, tier: .never))
        try await w.store.upsert(VaultSecret(name: "aws:lw-dev", value: "", tier: tier,
                                             leasePolicy: everyUse ? .everyUse : .standard,
                                             aws: VaultAwsRole(sourceSecret: "AWS_ROOT", roleArn: "arn:aws:iam::1:role/R")))
        let keys = [w.mac.owner("Mac"), VaultOwnerRecipient(name: "Recovery key", kind: .recovery, publicKey: w.recovery.recipient.text)]
        #expect(await w.broker.setOwnerKeys(keys, caller: settings, trusted: true).status == .granted)
        return w
    }

    private func mint(_ id: String, minutes: Double = 600) -> VaultUnsealer.Mint {
        { key, role, session in
            #expect(key.accessKeyId == "AKIAX")
            #expect(role.roleArn == "arn:aws:iam::1:role/R")
            return AwsProcessCredentials(AccessKeyId: id, SecretAccessKey: "x", SessionToken: session,
                                         Expiration: ISO8601DateFormatter().string(from: Date().addingTimeInterval(minutes * 60)))
        }
    }

    @Test func theDeviceMintsAndTheMasterNeverSeesTheLongLivedKey() async throws {
        let w = try await world(tier: .judged)
        let asked = await w.broker.release(VaultReleaseRequest(mode: "aws", names: ["aws:lw-dev"], command: "kubectl get pods"), caller: card)
        // Jev allows it, but only a device can mint.
        #expect(asked.status == .pending)
        let request = try #require(w.approvals.last)
        #expect(request.vault?.whys == [VaultBroker.mintWhy])
        #expect(request.unseal?.aws.first?.role.roleArn == "arn:aws:iam::1:role/R")
        #expect(request.unseal?.aws.first?.sessionName == "kanban-card_1")
        let done = try await w.approve(asked, mint: mint("ASIA1"))
        #expect(done.status == .granted && done.credentials?.AccessKeyId == "ASIA1")

        // The same card: its own credentials again, no question.
        let reuse = await w.broker.release(VaultReleaseRequest(mode: "aws", names: ["aws:lw-dev"]), caller: card)
        #expect(reuse.status == .granted && reuse.credentials?.AccessKeyId == "ASIA1")
        // Another card Jev allows: the credentials the master still holds.
        let second = await w.broker.release(VaultReleaseRequest(mode: "aws", names: ["aws:lw-dev"]), caller: otherCard)
        #expect(second.status == .granted && second.credentials?.AccessKeyId == "ASIA1")
        #expect(w.approvals.raised.count == 1)
        let line = try #require(await w.store.log().first { $0.cardId == "card_2" && $0.outcome == .allowed })
        #expect(line.decider == .jev && line.detail?.contains("a device minted") == true)
    }

    @Test func credentialsCloseToExpiryAreMintedAgain() async throws {
        let w = try await world(tier: .judged)
        let asked = await w.broker.release(VaultReleaseRequest(mode: "aws", names: ["aws:lw-dev"]), caller: card)
        _ = try await w.approve(asked, mint: mint("ASIA1", minutes: 10))
        let later = await w.broker.release(VaultReleaseRequest(mode: "aws", names: ["aws:lw-dev"]), caller: otherCard)
        #expect(later.status == .pending)
        #expect(try await w.approve(later, mint: mint("ASIA2")).credentials?.AccessKeyId == "ASIA2")
    }

    @Test func anAskProfileStillAsksPerCardButMintsOnce() async throws {
        let w = try await world(tier: .ask)
        let asked = await w.broker.release(VaultReleaseRequest(mode: "aws", names: ["aws:lw-dev"]), caller: card)
        let first = try await w.approve(asked, mint: mint("ASIA1"))
        #expect(first.credentials?.AccessKeyId == "ASIA1")
        let other = await w.broker.release(VaultReleaseRequest(mode: "aws", names: ["aws:lw-dev"]), caller: otherCard)
        #expect(other.status == .pending)
        // Nothing to mint this time: the approval alone releases the held ones.
        #expect(w.approvals.last?.needsDeviceKey == false)
        w.approvals.answer(try #require(other.id), "Approve once")
        #expect(await w.wait(try #require(other.id)).credentials?.AccessKeyId == "ASIA1")
    }

    @Test func everyUseAsksMintsEveryTime() async throws {
        let w = try await world(tier: .ask, everyUse: true)
        let a = await w.broker.release(VaultReleaseRequest(mode: "aws", names: ["aws:lw-dev"]), caller: card)
        #expect(try await w.approve(a, mint: mint("ASIA1")).credentials?.AccessKeyId == "ASIA1")
        let b = await w.broker.release(VaultReleaseRequest(mode: "aws", names: ["aws:lw-dev"]), caller: card)
        #expect(b.status == .pending && w.approvals.last?.needsDeviceKey == true)
        #expect(try await w.approve(b, mint: mint("ASIA2")).credentials?.AccessKeyId == "ASIA2")
    }

    @Test func theLongestSessionTheRoleAllowsIsUsed() async throws {
        let tried = Tried()
        let sts = AwsSts(region: "us-east-1") { request in
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            let seconds = Int(body.components(separatedBy: "DurationSeconds=").last?.prefix { $0.isNumber } ?? "") ?? 0
            await tried.add(seconds)
            #expect(request.value(forHTTPHeaderField: "authorization")?.contains("Credential=AKIAX/") == true)
            if seconds > 14400 {
                let message = "The requested DurationSeconds exceeds the MaxSessionDuration set for this role."
                return (Data("<ErrorResponse><Error><Code>ValidationError</Code><Message>\(message)</Message></Error></ErrorResponse>".utf8), 400)
            }
            return (Data("""
            <AssumeRoleResponse><AssumeRoleResult><Credentials><AccessKeyId>ASIA</AccessKeyId><SecretAccessKey>x</SecretAccessKey>\
            <SessionToken>t</SessionToken><Expiration>2030-01-01T04:00:00Z</Expiration></Credentials></AssumeRoleResult></AssumeRoleResponse>
            """.utf8), 200)
        }
        let role = VaultAwsRole(sourceSecret: "AWS_ROOT", roleArn: "arn:aws:iam::1:role/R")
        let credentials = try await sts.longestCredentials(key: AwsAccessKey(accessKeyId: "AKIAX", secretAccessKey: "s"), role: role, sessionName: "kanban-card_1")
        #expect(credentials.AccessKeyId == "ASIA")
        #expect(await tried.seconds == [43200, 28800, 14400])

        // Another refusal is not retried shorter.
        let denied = AwsSts(region: "us-east-1") { _ in
            (Data("<ErrorResponse><Error><Code>AccessDenied</Code><Message>not authorized to perform sts:AssumeRole</Message></Error></ErrorResponse>".utf8), 403)
        }
        await #expect(throws: (any Error).self) {
            try await denied.longestCredentials(key: AwsAccessKey(accessKeyId: "AKIAX", secretAccessKey: "s"), role: role, sessionName: "x")
        }
    }

    private actor Tried {
        var seconds: [Int] = []
        func add(_ s: Int) { seconds.append(s) }
    }
}

@Suite("Audit chain")
struct VaultAuditChainTests {
    private func entry(_ secret: String, machine: String = "box", detail: String? = nil, requestId: String? = nil,
                       decider: VaultDecider = .tier) -> VaultAuditEntry {
        VaultAuditEntry(machine: machine, cardId: "card_1", secret: secret, tier: .open, outcome: .allowed, decider: decider,
                        action: "run", detail: detail, requestId: requestId)
    }

    private func store() -> VaultStore { VaultStore(directory: tempDir(), keys: MemoryVaultKeyProvider()) }

    @Test func everyLineNamesTheOneBefore() async throws {
        let s = store()
        for name in ["A", "B", "C"] { await s.append(entry(name)) }
        let lines = await s.auditLines()
        #expect(lines.count == 3)
        #expect(AuditChain.verify(lines) == AuditChain.Report(lines: 3, unchained: 0, breaks: []))
        // A second store over the same file goes on from the last line.
        let reopened = VaultStore(directory: await s.directory, keys: MemoryVaultKeyProvider())
        await reopened.append(entry("D"))
        #expect(AuditChain.verify(await reopened.auditLines()).isIntact)
    }

    @Test func aChangedOrRemovedLineBreaksTheChain() async throws {
        let s = store()
        for name in ["A", "B", "C", "D"] { await s.append(entry(name)) }
        var lines = await s.auditLines()
        lines[1] = Data(String(decoding: lines[1], as: UTF8.self).replacingOccurrences(of: "\"B\"", with: "\"X\"").utf8)
        #expect(AuditChain.verify(lines).breaks == [3])
        var removed = await s.auditLines()
        removed.remove(at: 2)
        #expect(AuditChain.verify(removed).breaks == [3])
        // Cutting the end off leaves a valid chain: only the mirror shows that.
        #expect(AuditChain.verify(Array((await s.auditLines()).dropLast())).isIntact)
    }

    @Test func linesFromBeforeTheChainAreCountedNotBroken() async throws {
        let s = store()
        let legacy = Data(#"{"action":"run","at":"2026-10-01T10:00:00.000Z","decider":"tier","machine":"box","outcome":"allowed","secret":"OLD"}"#.utf8)
        AuditChain.appendRaw(legacy + Data([0x0A]), to: await s.auditPath)
        await s.append(entry("A"))
        await s.append(entry("B"))
        let report = AuditChain.verify(await s.auditLines())
        #expect(report.unchained == 1 && report.isIntact)
        // The first chained line pins the old ones.
        var lines = await s.auditLines()
        lines[0] = Data(String(decoding: lines[0], as: UTF8.self).replacingOccurrences(of: "OLD", with: "NEW").utf8)
        #expect(AuditChain.verify(lines).breaks == [2])
    }

    /// Two masters wired to each other without a network.
    private func pair(deviceApprovals: VaultDeviceApprovals? = nil) -> (box: VaultStore, mac: VaultStore, boxSync: VaultAuditSync, macSync: VaultAuditSync) {
        let box = store(), mac = store()
        @Sendable func serve(_ target: VaultStore, machine: String) -> VaultAuditSync.Fetch {
            { request in
                let url = request.url!
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                if url.path.hasSuffix("/audit/hashes") {
                    return (try JSONEncoder().encode(VaultAuditHashes(machine: machine, hashes: await target.auditLines().map(AuditChain.hash))), 200)
                }
                if request.httpMethod == "GET" {
                    return (try JSONEncoder().encode(await target.mirrorTail(machine: query.first { $0.name == "machine" }?.value ?? "")), 200)
                }
                let push = try JSONDecoder().decode(VaultAuditMirrorPush.self, from: request.httpBody ?? Data())
                return (try JSONEncoder().encode(await target.appendMirror(machine: push.machine, lines: push.lines)), 200)
            }
        }
        let macPeer = PeerConfig(id: "mac", name: "Mac", url: "http://mac", token: "t", enabled: true)
        let boxPeer = PeerConfig(id: "box", name: "box", url: "http://box", token: "t", enabled: true)
        let boxSync = VaultAuditSync(store: box, machine: "box", peers: { [macPeer] }, fetch: serve(mac, machine: "Mac"))
        let macSync = VaultAuditSync(store: mac, machine: "Mac", peers: { [boxPeer] },
                                     deviceApprovals: deviceApprovals.map { ($0, "mac") }, fetch: serve(box, machine: "box"))
        return (box, mac, boxSync, macSync)
    }

    @Test func theBoxPushesEveryLineAndTheMacKeepsThem() async throws {
        let (box, mac, boxSync, macSync) = pair()
        for name in ["A", "B", "C"] { await box.append(entry(name)) }
        await boxSync.pushAll()
        #expect(await mac.mirrorLines(machine: "box") == box.auditLines())
        await box.append(entry("D"))
        await boxSync.pushAll()
        await boxSync.pushAll()
        #expect(await mac.mirrorLines(machine: "box").count == 4)
        let report = await macSync.check()
        #expect(report.ok)
        #expect(report.missing == [.init(machine: "box", count: 0, samples: [], notMirroredYet: 0)])
    }

    @Test func linesRemovedOnTheBoxShowOnTheMac() async throws {
        let (box, mac, boxSync, macSync) = pair()
        for name in ["A", "B", "C", "D"] { await box.append(entry(name)) }
        await boxSync.pushAll()
        // Root on the box cuts the last two lines and goes on writing.
        let kept = (await box.auditLines()).prefix(2)
        try Data(kept.joined(separator: [0x0A]) + [0x0A]).write(to: URL(fileURLWithPath: await box.auditPath))
        let rewritten = VaultStore(directory: await box.directory, keys: MemoryVaultKeyProvider())
        await rewritten.append(entry("E"))
        let boxAfter = VaultAuditSync(store: rewritten, machine: "box", peers: { [] })
        #expect((await boxAfter.check()).ok)   // the box alone cannot tell

        let (_, _, _, _) = (box, mac, boxSync, macSync)
        let macPeer = PeerConfig(id: "box", name: "box", url: "http://box", token: "t", enabled: true)
        let check = VaultAuditSync(store: mac, machine: "Mac", peers: { [macPeer] }) { request in
            (try JSONEncoder().encode(VaultAuditHashes(machine: "box", hashes: await rewritten.auditLines().map(AuditChain.hash))), 200)
        }
        let report = await check.check()
        #expect(!report.ok)
        #expect(report.missing.first?.count == 2)
        #expect(report.missing.first?.samples.contains { $0.contains("\"C\"") } == true)

        // The mirror only grows: the pushed line E does not follow D there.
        _ = await mac.appendMirror(machine: "box", lines: [String(decoding: (await rewritten.auditLines()).last!, as: UTF8.self)])
        #expect(await mac.mirrorLines(machine: "box").count == 5)
        #expect(AuditChain.verify(await mac.mirrorLines(machine: "box")).breaks == [5])
    }

    @Test func anApprovalTheDeviceDidNotRecordIsReported() async throws {
        let approvals = VaultDeviceApprovals(path: tempDir() + "/device-approvals.jsonl")
        let (box, _, boxSync, macSync) = pair(deviceApprovals: approvals)
        let real = AttentionRequest(id: "vault_real", cardId: "card_1", kind: .vaultApproval, title: "Card wants X", body: "")
        approvals.record(real, resolution: "Approve once", now: Date().addingTimeInterval(-60))
        await box.append(entry("X", detail: "approved by mac", requestId: "vault_real", decider: .human))
        await box.append(entry("Y", detail: "approved by mac", requestId: "vault_forged", decider: .human))
        await box.append(entry("Z", detail: "approved by phone", requestId: "vault_phone", decider: .human))
        await boxSync.pushAll()
        let report = await macSync.check()
        #expect(report.unrecordedApprovals.count == 1)
        #expect(report.unrecordedApprovals.first?.contains("vault_forged") == true)
        #expect(!report.ok)
        #expect(approvals.report().isIntact && approvals.entries().count == 1)
    }
}
