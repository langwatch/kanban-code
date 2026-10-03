import Foundation
import Testing
@testable import KanbanCodeCore
import KanbanCodeRemoteKit

private final class CapturingApprovals: VaultApprovals, @unchecked Sendable {
    let lock = NSLock()
    var raised: [AttentionRequest] = []
    func raise(_ request: AttentionRequest) async { lock.withLock { raised.append(request) } }
    func resolution(of id: String) async -> (resolution: String?, by: String)? { nil }
    func close(id: String, resolution: String, by: String) async {}
}

private let card = VaultCaller(cardId: "card_1", sessionId: "s1", pid: 42, ancestry: ["kv", "zsh", "tmux"])

private func broker() async throws -> (VaultBroker, CapturingApprovals) {
    let dir = NSTemporaryDirectory() + "vault-copy-\(UUID().uuidString.prefix(8))"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let store = VaultStore(directory: dir, keys: MemoryVaultKeyProvider())
    try await store.ensureIdentity()
    try await store.upsert(VaultSecret(name: "SLACK_USER_TOKEN", value: "x", tier: .ask))
    try await store.upsert(VaultSecret(name: "DEPLOY_KEY", value: "x", tier: .ask, label: "Docs deploy key"))
    try await store.upsert(VaultSecret(name: "aws:lw-dev", value: "", tier: .ask,
                                       aws: VaultAwsRole(sourceSecret: "aws-key", roleArn: "arn:aws:iam::1:role/dev")))
    let approvals = CapturingApprovals()
    let broker = VaultBroker(store: store, jev: nil, approvals: approvals, machine: "test") { _ in "Kanban Chat Claude" }
    await broker.configure(approvalTimeout: 60, pollInterval: 0.05)
    return (broker, approvals)
}

@Suite("Vault approval copy")
struct VaultApprovalCopyTests {
    @Test func labelsComeFromTheName() {
        #expect(AttentionCopy.secretLabel(name: "aws:lw-dev") == "AWS lw-dev")
        #expect(AttentionCopy.secretLabel(name: "aws:lw-prod:read") == "AWS lw-prod read-only")
        #expect(AttentionCopy.secretLabel(name: "SLACK_USER_TOKEN") == "Slack user token")
        #expect(AttentionCopy.secretLabel(name: "OPENAI_API_KEY") == "OpenAI API key")
        #expect(AttentionCopy.secretLabel(name: "GITHUB_TOKEN") == "GitHub token")
        #expect(AttentionCopy.secretLabel(name: "nexus-key") == "Nexus key")
        #expect(AttentionCopy.secretLabel(name: "SLACK_USER_TOKEN", label: "Slack token") == "Slack token")
        #expect(AttentionCopy.secretLabel(name: "SLACK_USER_TOKEN", label: "  ") == "Slack user token")
    }

    @Test func reasonsMustBeOnePlainSentence() {
        #expect(AttentionCopy.reasonProblem(nil) == .missing)
        #expect(AttentionCopy.reasonProblem("  ") == .missing)
        #expect(AttentionCopy.reasonProblem("change aws:lw-dev: rules") == .tooShort)
        #expect(AttentionCopy.reasonProblem("deploy") == .tooShort)
        #expect(AttentionCopy.reasonProblem("kubectl apply -f deploy.yaml") == .looksLikeCommand)
        #expect(AttentionCopy.reasonProblem("run the deploy with --force please") == .looksLikeCommand)
        #expect(AttentionCopy.reasonProblem("load env && run the migration now") == .looksLikeCommand)
        #expect(AttentionCopy.reasonProblem(String(repeating: "word ", count: 60)) == .tooLong)
        #expect(AttentionCopy.reasonProblem("first line\nsecond line of it") == .tooLong)
        #expect(AttentionCopy.reasonProblem("Deploy the langwatch staging app to check the fix for the login bug") == nil)
    }

    @Test func headlinesNameWhoWantsWhat() {
        func details(_ action: VaultApprovalDetails.Action, _ names: [String], changes: [String] = [],
                     origin: VaultApprovalDetails.Origin = .card, lease: Double? = nil) -> VaultApprovalDetails {
            VaultApprovalDetails(action: action, origin: origin, principal: origin == .outside ? nil : "Kanban Chat Claude",
                                 secrets: names.map { .init(name: $0, label: AttentionCopy.secretLabel(name: $0), tier: "Always ask") },
                                 changes: changes, leaseSeconds: lease)
        }
        #expect(AttentionCopy.vaultHeadline(details(.aws, ["aws:lw-dev"])) == "Kanban Chat Claude wants AWS lw-dev access")
        #expect(AttentionCopy.vaultHeadline(details(.edit, ["aws:lw-dev"], changes: ["rules"]))
            == "Kanban Chat Claude wants to change the AWS lw-dev rules")
        #expect(AttentionCopy.vaultHeadline(details(.use, ["SLACK_USER_TOKEN"])) == "Kanban Chat Claude wants to use the Slack user token")
        #expect(AttentionCopy.vaultHeadline(details(.use, ["SLACK_USER_TOKEN", "OPENAI_API_KEY"]))
            == "Kanban Chat Claude wants to use the Slack user token and the OpenAI API key")
        #expect(AttentionCopy.vaultHeadline(details(.lease, ["SLACK_USER_TOKEN"], lease: 2 * 86400))
            == "Kanban Chat Claude wants to use the Slack user token for 2 days")
        #expect(AttentionCopy.vaultHeadline(details(.lease, ["aws:lw-dev"], lease: 12 * 3600))
            == "Kanban Chat Claude wants AWS lw-dev access for 12 hours")
        #expect(AttentionCopy.vaultHeadline(details(.delete, ["SLACK_USER_TOKEN"])) == "Kanban Chat Claude wants to delete the Slack user token")
        #expect(AttentionCopy.vaultHeadline(details(.replace, ["SLACK_USER_TOKEN"])) == "Kanban Chat Claude wants to replace the Slack user token")
        #expect(AttentionCopy.vaultHeadline(details(.use, ["SLACK_USER_TOKEN"], origin: .outside))
            == "A process outside any card wants to use the Slack user token")
        #expect(AttentionCopy.vaultHeadline(details(.use, ["SLACK_USER_TOKEN"], origin: .openClaw))
            == "OpenClaw agent Kanban Chat Claude wants to use the Slack user token")
    }

    @Test func otherKindsKeepTheirTextUnderTheSameTitleStyle() {
        let q = AttentionRequest(id: "q", cardId: "c", kind: .question, title: "Database", body: "Which one?")
        #expect(AttentionCopy.notification(for: q, cardName: "Card").title == "Card is asking you a question")
        #expect(AttentionCopy.notification(for: q, cardName: "Card").body == "Database: Which one?")
        let plan = AttentionRequest(id: "p", cardId: "c", kind: .planApproval, title: "Plan ready for review", body: "1. do it")
        #expect(AttentionCopy.notification(for: plan, cardName: "Card") == ("Card wants you to approve a plan", "1. do it"))
        let perm = AttentionRequest(id: "x", cardId: nil, kind: .permission, title: "Permission needed", body: "Bash")
        #expect(AttentionCopy.notification(for: perm, cardName: nil) == ("Permission needed", "Bash"))
    }

    @Test func theNotificationIsTheHeadlineAndOnlyTheReason() async throws {
        let (broker, approvals) = try await broker()
        let reason = "Post the release notes to the team channel for the 3.20 release"
        let r = await broker.release(VaultReleaseRequest(mode: "run", names: ["SLACK_USER_TOKEN"], command: "node post.js",
                                                         reason: reason, cwd: "/repo"), caller: card)
        #expect(r.status == .pending)
        #expect(!r.message.contains("no reason"))
        let request = try #require(approvals.raised.last)
        #expect(request.title == "Kanban Chat Claude wants to use the Slack user token")
        #expect(request.body == reason)

        let push = Dictionary(PushoverAttentionSender.fields(for: request, cardName: "Kanban Chat Claude", level: .timeSensitive),
                              uniquingKeysWith: { a, _ in a })
        #expect(push["title"] == "Kanban Chat Claude wants to use the Slack user token")
        #expect(push["message"] == reason)
        #expect(AttentionCopy.notification(for: request, cardName: "Kanban Chat Claude") == (request.title, reason))
    }

    @Test func aMissingOrCommandLikeReasonIsReplacedAndTheAgentIsTold() async throws {
        let (broker, approvals) = try await broker()
        let r = await broker.release(VaultReleaseRequest(mode: "run", names: ["DEPLOY_KEY"], command: "./deploy.sh",
                                                         reason: "./deploy.sh --prod"), caller: card)
        #expect(r.message.contains("one short plain sentence"))
        let request = try #require(approvals.raised.last)
        #expect(request.title == "Kanban Chat Claude wants to use the Docs deploy key")
        #expect(request.body == "No reason given. Asked by: ./deploy.sh")

        _ = await broker.edit("aws:lw-dev", VaultEditRequest(rules: "dev deploys only"), caller: card, trusted: false)
        let edit = try #require(approvals.raised.last)
        #expect(edit.title == "Kanban Chat Claude wants to change the AWS lw-dev rules")
        #expect(edit.body == "No reason given.")
    }

    @Test func theDetailSheetHasEverything() async throws {
        let (broker, approvals) = try await broker()
        let reason = "Check the dev cluster nodes after the autoscaler change"
        _ = await broker.release(VaultReleaseRequest(mode: "aws", names: ["aws:lw-dev"], command: "aws eks list-nodegroups",
                                                     reason: reason, cwd: "/repo/infra"), caller: card)
        let request = try #require(approvals.raised.last)
        #expect(request.title == "Kanban Chat Claude wants AWS lw-dev access")
        let details = try #require(request.vault)
        #expect(details.action == .aws && details.origin == .card && details.principal == "Kanban Chat Claude")
        #expect(details.secrets == [.init(name: "aws:lw-dev", label: "AWS lw-dev", tier: "Always ask")])
        #expect(!details.whys.isEmpty)
        #expect(details.leaseSeconds == VaultLeasePolicy.maximumLease)

        let rows = Dictionary(details.rows().map { ($0.label, $0.value) }, uniquingKeysWith: { a, _ in a })
        #expect(rows["Card"] == "Kanban Chat Claude")
        #expect(rows["Reason"] == reason)
        #expect(rows["Secret"] == "AWS lw-dev (aws:lw-dev), Always ask")
        #expect(rows["Wants to"] == "wants AWS lw-dev access")
        #expect(rows["Command"] == "aws eks list-nodegroups")
        #expect(rows["Directory"] == "/repo/infra")
        #expect(rows["Lease"] == "2 days if approved for the card")
        #expect(rows["Process"] == "kv < zsh < tmux")
        #expect(rows["Why it asks"] != nil)
        #expect(request.options == AttentionRequest.vaultApprovalOptions)

        // Older devices decode a request without details.
        var legacy = request
        legacy.vault = nil
        let decoded = try JSONDecoder().decode(AttentionRequest.self, from: JSONEncoder().encode(legacy))
        #expect(decoded.vault == nil && decoded.title == request.title)
    }

    @Test func anEditShowsWhatItChanges() async throws {
        let (broker, approvals) = try await broker()
        _ = await broker.edit("SLACK_USER_TOKEN", VaultEditRequest(tier: .judged, rules: "only to post release notes",
                                                                    reason: "Let Jev decide the release note posts on its own"),
                              caller: card, trusted: false)
        let request = try #require(approvals.raised.last)
        #expect(request.title == "Kanban Chat Claude wants to change the Slack user token tier and rules")
        #expect(request.body == "Let Jev decide the release note posts on its own")
        #expect(request.vault?.changeLines == ["Tier: Judged by Jev", "Rules: only to post release notes"])
    }
}
