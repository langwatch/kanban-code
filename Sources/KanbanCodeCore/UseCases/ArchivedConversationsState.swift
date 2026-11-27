import Foundation
import KanbanCodeRemoteKit

extension AppState {
    /// How many of the card's conversations are archived.
    public func archivedConversationCount(cardId: String) -> Int {
        conversations[cardId]?.count(where: \.archived) ?? 0
    }

    /// Archived conversations grouped by card: the one card's, or every
    /// card's when `cardId` is nil.
    public func archivedConversationGroups(cardId: String? = nil) -> [ArchivedConversationGroup] {
        let source = cardId.map { id in conversations[id].map { [id: $0] } ?? [:] } ?? conversations
        var titles: [String: String] = [:]
        for id in source.keys {
            titles[id] = cards.first { $0.id == id }?.displayTitle ?? links[id]?.displayTitle
        }
        return ArchivedConversationGroup.groups(conversations: source, titles: titles)
    }
}
