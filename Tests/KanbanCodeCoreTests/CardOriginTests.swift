import Foundation
import Testing
@testable import KanbanCodeCore
import KanbanCodeRemoteKit

@Suite("Card origin")
struct CardOriginTests {
    @Test("a recorded origin wins; a card under a parent reads as an agent's; else the human's")
    func effectiveOrigin() {
        #expect(Link(origin: .agent).effectiveOrigin == .agent)
        #expect(Link(origin: .human, parentCardId: "card_parent").effectiveOrigin == .human)
        #expect(Link(parentCardId: "card_parent").effectiveOrigin == .agent)
        #expect(Link().effectiveOrigin == .human)
        #expect(Link(source: .manual).isAgentCreated == false)
    }

    @Test("origin round-trips through links.json and older cards read without it")
    func codable() throws {
        let link = Link(id: "card_1", source: .manual, origin: .agent)
        let data = try JSONEncoder().encode(link)
        #expect(String(decoding: data, as: UTF8.self).contains("\"origin\":\"agent\""))
        #expect(try JSONDecoder().decode(Link.self, from: data).origin == .agent)

        let old = Data(#"{"id":"card_2","column":"requires_attention","source":"manual","parentCardId":"card_1"}"#.utf8)
        let decoded = try JSONDecoder().decode(Link.self, from: old)
        #expect(decoded.origin == nil)
        #expect(decoded.effectiveOrigin == .agent)

        // A kind a newer build writes reads as an agent, never as the human.
        let newer = Data(#"{"id":"card_3","column":"requires_attention","source":"manual","origin":"lane"}"#.utf8)
        #expect(try JSONDecoder().decode(Link.self, from: newer).origin == .agent)
    }

    @Test("origin travels with the owner's fields")
    func syncsAsOwnedField() {
        var dst = Link(id: "card_1")
        LinkSync.copyOwned(from: Link(id: "card_1", origin: .agent), to: &dst)
        #expect(dst.origin == .agent)
        #expect(!LinkSync.ownedEqual(Link(id: "card_1"), Link(id: "card_1", origin: .agent)))
    }

    @Test("the remote board says who created each card")
    func remoteCard() {
        let agentCard = KanbanCodeCard(link: Link(id: "card_a", source: .manual, origin: .agent))
        let humanCard = KanbanCodeCard(link: Link(id: "card_h", source: .manual, origin: .human))
        #expect(RemoteBoardMapper.card(agentCard, liveSessions: []).origin == .agent)
        #expect(RemoteBoardMapper.card(humanCard, liveSessions: []).origin == .human)
    }

    @Test("hiding agent cards leaves them out of the filtered board")
    @MainActor
    func hidesAgentCards() async throws {
        let state = AppState()
        state.links = [
            "card_h": Link(id: "card_h", column: .waiting, source: .manual, origin: .human),
            "card_a": Link(id: "card_a", column: .waiting, source: .manual, origin: .agent),
            "card_s": Link(id: "card_s", column: .waiting, source: .manual, parentCardId: "card_h"),
        ]
        state.rebuildCards()
        #expect(Set(state.filteredCards.map(\.id)) == ["card_h", "card_a", "card_s"])
        state.hidesAgentCards = true
        state.rebuildCards()
        #expect(state.filteredCards.map(\.id) == ["card_h"])
    }
}
