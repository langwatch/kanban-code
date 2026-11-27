import Foundation

/// The archived conversations of one card, for the lists that show them
/// on the Mac and the phone.
public struct ArchivedConversationGroup: Equatable, Sendable, Identifiable {
    public let cardId: String
    public let cardTitle: String
    /// Most recent first.
    public var conversations: [RemoteConversation]

    public var id: String { cardId }

    public init(cardId: String, cardTitle: String, conversations: [RemoteConversation]) {
        self.cardId = cardId
        self.cardTitle = cardTitle
        self.conversations = conversations
    }

    /// One group per card with archived conversations, the card whose
    /// conversation changed last first. `conversations` may hold the open
    /// ones too: only the archived are kept. A card `titles` does not name
    /// is listed by its id.
    public static func groups(conversations: [String: [RemoteConversation]],
                              titles: [String: String]) -> [ArchivedConversationGroup] {
        conversations.compactMap { cardId, all in
            let archived = all.filter(\.archived).sorted { $0.updatedAt > $1.updatedAt }
            guard !archived.isEmpty else { return nil }
            return ArchivedConversationGroup(cardId: cardId, cardTitle: titles[cardId] ?? cardId, conversations: archived)
        }
        .sorted {
            let a = $0.conversations[0].updatedAt, b = $1.conversations[0].updatedAt
            return a != b ? a > b : $0.cardId < $1.cardId
        }
    }
}
