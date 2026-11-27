import Foundation
import KanbanCodeRemoteKit
import Testing
@testable import KanbanCodeCore

@Suite("Laze agent on board cards")
struct LazeAgentCardTests {
    private func peerState() -> (AppState, Link) {
        var state = AppState()
        state.localMachineId = "machine_mac"
        state.peerStatuses["peer_box"] = PeerStatus(peerId: "peer_box", machine: MachineIdentity(id: "machine_box", name: "box"), online: true)
        var link = Link(id: "card_video", name: "Rogerio Video Maker", projectPath: "/repo", column: .inProgress,
                        tmuxLink: TmuxLink(sessionName: "rush-aaaa1111"))
        link.ownerMachine = "machine_box"
        link.sessionLink = SessionLink(sessionId: "aaaa1111-0000-0000-0000-000000000000")
        state.links[link.id] = link
        return (state, link)
    }

    @Test("a card another master runs takes the agent its owner reports over the wire")
    func peerCard() throws {
        var (state, link) = peerState()
        let agent = RemoteLazeAgent(id: "agent_video", name: "Rogerio Video Maker", emoji: "🎬")
        let owner = RemoteCard(id: link.id, title: link.name ?? "", column: .inProgress, isLive: true, updatedAt: Date(), lazeAgent: agent)
        let decoded = try JSONDecoder.remote.decode(RemoteCard.self, from: JSONEncoder.remote.encode(owner))

        _ = Reducer.reduce(state: &state, action: .peerActivityScanned(cards: [link.id: PeerTranscriptMirror.state(of: decoded)]))
        state.rebuildCards()
        let card = try #require(state.cards.first { $0.id == link.id })
        #expect(card.lazeAgent == agent)
        #expect(RemoteBoardMapper.card(card, liveSessions: []).lazeAgent == agent)
    }

    @Test("a rename of the agent alone reaches the peer card")
    func peerAgentRename() throws {
        var (state, link) = peerState()
        let before = PeerCardState(isLive: true, isBusy: false, lazeAgent: RemoteLazeAgent(id: "agent_video", name: "Video"))
        _ = Reducer.reduce(state: &state, action: .peerActivityScanned(cards: [link.id: before]))
        state.rebuildCards()
        #expect(state.cards.first { $0.id == link.id }?.lazeAgent?.name == "Video")

        var after = before
        after.lazeAgent?.name = "Rogerio Video Maker"
        _ = Reducer.reduce(state: &state, action: .peerCardRead(cardId: link.id, state: after))
        state.rebuildCards()
        #expect(state.cards.first { $0.id == link.id }?.lazeAgent?.name == "Rogerio Video Maker")
    }

    @Test("a card this Mac runs takes the agent of its session from the local Laze profiles")
    func localCard() throws {
        var state = AppState()
        state.localMachineId = "machine_mac"
        var link = Link(id: "card_klickie", name: "Klickie", projectPath: "/repo", column: .inProgress)
        link.sessionLink = SessionLink(sessionId: "138c92b5-44a4-45c6-be51-e438f45e8bc3")
        state.links[link.id] = link
        let agent = RemoteLazeAgent(id: "agent_klickie", name: "Klickie investigation")

        _ = Reducer.reduce(state: &state, action: .lazeAgentsLoaded(["138c92b5-44a4-45c6-be51-e438f45e8bc3": agent]))
        state.rebuildCards()
        #expect(state.cards.first { $0.id == link.id }?.lazeAgent == agent)

        // A peer's report for a card this Mac runs is not its agent.
        _ = Reducer.reduce(state: &state, action: .lazeAgentsLoaded([:]))
        state.peerCards[link.id] = PeerCardState(isLive: true, isBusy: false, lazeAgent: RemoteLazeAgent(id: "x", name: "Other"))
        state.rebuildCards()
        #expect(state.cards.first { $0.id == link.id }?.lazeAgent == nil)
    }
}
