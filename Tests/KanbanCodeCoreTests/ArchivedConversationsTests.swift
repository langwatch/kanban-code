import Foundation
import Testing

@testable import KanbanCodeCore
import KanbanCodeRemoteKit

@Suite("Archived conversations by card")
struct ArchivedConversationsTests {
    func conversation(_ id: String, archived: Bool, at: TimeInterval) -> RemoteConversation {
        RemoteConversation(id: id, title: id, createdAt: Date(timeIntervalSince1970: 0),
                           updatedAt: Date(timeIntervalSince1970: at), archived: archived)
    }

    func state() -> AppState {
        var state = AppState()
        _ = Reducer.reduce(state: &state, action: .conversationsLoaded(cardId: "laze", conversations: [
            conversation("open-one", archived: false, at: 500),
            conversation("old-otter", archived: true, at: 100),
            conversation("new-heron", archived: true, at: 300),
        ]))
        _ = Reducer.reduce(state: &state, action: .conversationsLoaded(cardId: "docs", conversations: [
            conversation("late-lynx", archived: true, at: 400),
        ]))
        _ = Reducer.reduce(state: &state, action: .conversationsLoaded(cardId: "quiet", conversations: [
            conversation("still-open", archived: false, at: 900),
        ]))
        return state
    }

    @Test("counts only the archived conversations of the card")
    func count() {
        let state = state()
        #expect(state.archivedConversationCount(cardId: "laze") == 2)
        #expect(state.archivedConversationCount(cardId: "quiet") == 0)
        #expect(state.archivedConversationCount(cardId: "missing") == 0)
    }

    @Test("every card's archived ones, grouped, the latest change first; cards with none left out")
    func allGroups() {
        let groups = state().archivedConversationGroups()
        #expect(groups.map(\.cardId) == ["docs", "laze"])
        #expect(groups[1].conversations.map(\.id) == ["new-heron", "old-otter"])
        // Cards that are not on the board are listed by id.
        #expect(groups[0].cardTitle == "docs")
    }

    @Test("one card's archived ones")
    func oneCard() {
        let state = state()
        #expect(state.archivedConversationGroups(cardId: "laze").map(\.cardId) == ["laze"])
        #expect(state.archivedConversationGroups(cardId: "quiet").isEmpty)
    }

    @Test("unarchiving takes it out of the list and the count")
    func unarchive() {
        var state = state()
        _ = Reducer.reduce(state: &state, action: .conversationsLoaded(cardId: "docs", conversations: [
            conversation("late-lynx", archived: false, at: 401),
        ]))
        #expect(state.archivedConversationGroups().map(\.cardId) == ["laze"])
        #expect(state.archivedConversationCount(cardId: "docs") == 0)
    }

    @Test("a board card carries the archived count, and the JSON leaves out zero")
    func remoteCardCount() throws {
        let card = RemoteCard(id: "c", title: "t", column: .waiting, updatedAt: Date(timeIntervalSince1970: 0),
                              archivedConversationCount: 2)
        let data = try JSONEncoder().encode(card)
        #expect(try JSONDecoder().decode(RemoteCard.self, from: data).archivedConversationCount == 2)
        let zero = RemoteCard(id: "c", title: "t", column: .waiting, updatedAt: Date(timeIntervalSince1970: 0))
        #expect(!String(decoding: try JSONEncoder().encode(zero), as: UTF8.self).contains("archivedConversationCount"))
    }

    @Test("the remote board lists the open conversations and counts the archived")
    func mapper() {
        let card = KanbanCodeCard(link: Link(id: "laze", source: .manual))
        let remote = RemoteBoardMapper.card(card, liveSessions: [], conversations: state().conversations["laze"] ?? [])
        #expect(remote.conversations.map(\.id) == ["open-one"])
        #expect(remote.archivedConversationCount == 2)
    }
}
