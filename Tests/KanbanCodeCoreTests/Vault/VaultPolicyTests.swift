import Foundation
import Testing
@testable import KanbanCodeCore
import KanbanCodeRemoteKit

@Suite("Vault decision engine")
struct VaultPolicyTests {
    private func decide(_ tier: VaultTier, everyUse: Bool = false, inside: Bool = true, lease: Bool = false, recent: Int = 0) -> VaultVerdict {
        VaultPolicy.decide(VaultDecisionInput(tier: tier, everyUseAsks: everyUse, insideCard: inside, hasLease: lease, recentReleases: recent))
    }

    @Test func neverTierRefusesWhateverElseHolds() {
        for inside in [true, false] {
            for lease in [true, false] {
                if case .deny = decide(.never, inside: inside, lease: lease) {} else { Issue.record("never must deny") }
            }
        }
    }

    @Test(arguments: [VaultTier.open, .judged, .ask])
    func outsideACardSessionAsksWhateverTheTier(tier: VaultTier) {
        guard case .ask(let why) = decide(tier, inside: false, lease: true) else {
            Issue.record("outside a card must ask")
            return
        }
        #expect(why.contains("card session"))
    }

    @Test func openTierAllows() {
        #expect(decide(.open) == .allow(.tier, "open tier"))
    }

    @Test func judgedTierConsultsJev() {
        #expect(decide(.judged) == .consultJev)
    }

    @Test func askTierAsks() {
        if case .ask = decide(.ask) {} else { Issue.record("ask tier must ask") }
    }

    @Test(arguments: [VaultTier.judged, .ask])
    func aLeaseAllows(tier: VaultTier) {
        #expect(decide(tier, lease: true) == .allow(.lease, "the card holds a lease"))
    }

    @Test func aLeaseDoesNotCoverEveryUseSecrets() {
        if case .ask = decide(.ask, everyUse: true, lease: true) {} else { Issue.record("every-use must ask despite a lease") }
    }

    @Test func rateLimitPausesEvenOpenAndLeasedSecrets() {
        #expect(decide(.open, recent: 19) == .allow(.tier, "open tier"))
        if case .ask(let why) = decide(.open, recent: 20) { #expect(why.contains("20 times")) } else { Issue.record("must ask") }
        if case .ask = decide(.judged, lease: true, recent: 25) {} else { Issue.record("must ask") }
    }

    @Test func jevUnreachableGoesToTheHuman() {
        if case .ask(let why) = VaultPolicy.afterJev(nil) { #expect(why.contains("Jev")) } else { Issue.record("must ask") }
    }

    @Test func jevAnswers() {
        if case .allow(.jev, _) = VaultPolicy.afterJev(JevVerdict(choice: .allow, confidence: 0.93)) {} else { Issue.record("allow") }
        if case .ask = VaultPolicy.afterJev(JevVerdict(choice: .allow, confidence: 0.51)) {} else { Issue.record("unsure allow asks") }
        if case .ask = VaultPolicy.afterJev(JevVerdict(choice: .ask, confidence: 0.9)) {} else { Issue.record("ask") }
        if case .deny = VaultPolicy.afterJev(JevVerdict(choice: .deny, confidence: 0.99)) {} else { Issue.record("deny") }
    }

    @Test func approvalOptions() {
        #expect(VaultPolicy.approvalOptions(everyUseAsks: false, insideCard: true).count == 3)
        #expect(VaultPolicy.approvalOptions(everyUseAsks: true, insideCard: true) == ["Approve once", "Deny"])
        #expect(VaultPolicy.approvalOptions(everyUseAsks: false, insideCard: false) == ["Approve once", "Deny"])
    }

    @Test func readsResolutions() {
        #expect(VaultPolicy.approval(from: "Approve for this card (2 days)") == .lease)
        #expect(VaultPolicy.approval(from: "Approve once") == .once)
        #expect(VaultPolicy.approval(from: "Deny") == .deny)
        #expect(VaultPolicy.approval(from: nil) == .deny)
        #expect(VaultPolicy.approval(from: "whatever") == .deny)
    }

    @Test func rateCounterSlides() {
        var counter = VaultRateCounter(window: 300)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<5 { counter.record("A", at: t0.addingTimeInterval(Double(i))) }
        #expect(counter.count("A", now: t0.addingTimeInterval(10)) == 5)
        #expect(counter.count("A", now: t0.addingTimeInterval(302)) == 2)
        #expect(counter.count("B", now: t0) == 0)
    }

    @Test func callerResolverWalksAncestry() {
        let table = VaultCallerResolver.parsePS("""
            1 0 /sbin/launchd
          100 1 tmux
          200 100 -zsh
          300 200 node
          400 300 kv
          500 1 malware
          600 500 kv
        """)
        #expect(VaultCallerResolver.card(for: 400, table: table, sessionPids: [200: "card_a"]) == "card_a")
        #expect(VaultCallerResolver.card(for: 600, table: table, sessionPids: [200: "card_a"]) == nil)
        #expect(VaultCallerResolver.ancestry(of: 400, in: table).map(\.name) == ["kv", "node", "-zsh", "tmux"])
    }

    @Test func secretNames() {
        #expect(VaultSecret.isValidName("OPENAI_API_KEY"))
        #expect(VaultSecret.isValidName("aws:lw-prod:read"))
        #expect(!VaultSecret.isValidName("has space"))
        #expect(!VaultSecret.isValidName(""))
    }

    @Test func splitsScopes() {
        #expect(VaultBroker.splitScope("GITHUB_TOKEN") == ("GITHUB_TOKEN", nil))
        #expect(VaultBroker.splitScope("STRIPE:read") == ("STRIPE", "read"))
        #expect(VaultBroker.splitScope("aws:lw-prod:read") == ("aws:lw-prod:read", nil))
    }
}
