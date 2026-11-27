import Foundation
import Testing

@testable import KanbanCodeCore

@Suite("Sidebar banner for open attention requests")
struct AttentionBannerTests {
    func request(_ id: String, card: String?, kind: AttentionRequest.Kind = .vaultApproval, at: TimeInterval) -> AttentionRequest {
        AttentionRequest(
            id: id, cardId: card, kind: kind, title: "A process wants a secret", body: "",
            options: AttentionRequest.vaultApprovalOptions, createdAt: Date(timeIntervalSince1970: at))
    }

    final class DockCount: MacAttentionNotifier, @unchecked Sendable {
        let lock = NSLock()
        var shown = 0
        func post(_ request: AttentionRequest, cardName: String?) async {}
        func remove(id: String) async {}
        func showInApp(_ request: AttentionRequest) async {}
        func showOpenCount(_ count: Int) async { lock.withLock { shown = count } }
        var value: Int { lock.withLock { shown } }
    }

    @Test("no banner while nothing is open")
    func emptyState() {
        #expect(AppState().attentionBanner == nil)
    }

    @Test("one request outside any card opens its own detail sheet")
    func oneCardless() {
        var state = AppState()
        _ = Reducer.reduce(state: &state, action: .attentionRaised(request("vault_a", card: nil, at: 100)))
        let banner = state.attentionBanner
        #expect(banner?.count == 1)
        #expect(banner?.title == "1 decision waiting on you")
        #expect(banner?.target == .request("vault_a"))
    }

    @Test("several requests open the list, oldest first, with and without a card")
    func several() {
        var state = AppState()
        _ = Reducer.reduce(state: &state, action: .attentionRaised(request("late", card: "card_1", kind: .question, at: 300)))
        _ = Reducer.reduce(state: &state, action: .attentionRaised(request("early", card: nil, at: 100)))
        _ = Reducer.reduce(state: &state, action: .attentionRaised(request("middle", card: nil, kind: .permission, at: 200)))
        let banner = state.attentionBanner
        #expect(banner?.count == 3)
        #expect(banner?.title == "3 decisions waiting on you")
        #expect(banner?.target == .list(["early", "middle", "late"]))
    }

    @Test("answered requests leave the banner, and the last one hides it")
    func resolving() {
        var state = AppState()
        _ = Reducer.reduce(state: &state, action: .attentionRaised(request("a", card: nil, at: 100)))
        _ = Reducer.reduce(state: &state, action: .attentionRaised(request("b", card: nil, at: 200)))
        _ = Reducer.reduce(state: &state, action: .attentionResolved(id: "a", resolution: "Allow once", by: "mac"))
        #expect(state.attentionBanner?.target == .request("b"))
        _ = Reducer.reduce(state: &state, action: .attentionResolved(id: "b", resolution: "Deny", by: "phone"))
        #expect(state.attentionBanner == nil)
    }

    @Test("the banner count matches the Dock badge through raise, update and resolve")
    func matchesDock() async {
        let dock = DockCount()
        let center = AttentionCenter(mac: dock)
        var state = AppState()
        func run(_ action: Action) async {
            for effect in Reducer.reduce(state: &state, action: action) {
                switch effect {
                case .deliverAttention(let r): await center.deliver(r)
                case .updateAttention(let r): await center.update(r)
                case .withdrawAttention(let r): await center.withdraw(r)
                default: break
                }
            }
            #expect(dock.value == (state.attentionBanner?.count ?? 0))
        }
        await run(.attentionRaised(request("a", card: nil, at: 100)))
        await run(.attentionRaised(request("b", card: "card_1", kind: .question, at: 200)))
        await run(.attentionRaised(request("a", card: nil, at: 100)))
        await run(.attentionResolved(id: "a", resolution: "Allow once", by: "mac"))
        await run(.attentionRaised(request("a", card: nil, at: 100)))
        await run(.attentionResolved(id: "b", resolution: "Yes", by: "phone"))
        #expect(state.attentionBanner == nil)
        #expect(dock.value == 0)
    }
}
