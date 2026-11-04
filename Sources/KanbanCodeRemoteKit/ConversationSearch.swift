import Foundation

/// Finds a card's conversations (docs/conversations.md) by what they are
/// called and by their last message, for the quick searches of the Mac and
/// the phone. Works only on what the client already holds in memory.
public enum ConversationSearch {
    /// A conversation with the card it belongs to.
    public struct Entry: Sendable, Equatable {
        public var cardId: String
        public var cardTitle: String
        public var conversation: RemoteConversation

        public init(cardId: String, cardTitle: String, conversation: RemoteConversation) {
            self.cardId = cardId
            self.cardTitle = cardTitle
            self.conversation = conversation
        }
    }

    public struct Hit: Sendable, Equatable, Identifiable {
        public var entry: Entry
        /// Found by its title (with the card's name), not only by its last message.
        public var inTitle: Bool

        public init(entry: Entry, inTitle: Bool) {
            self.entry = entry
            self.inTitle = inTitle
        }

        public var id: String { Self.id(cardId: entry.cardId, conversationId: entry.conversation.id) }

        private static let prefix = "conversation:"

        public static func id(cardId: String, conversationId: String) -> String {
            "\(prefix)\(cardId):\(conversationId)"
        }

        /// The card and conversation of an id made by `id(cardId:conversationId:)`.
        public static func parse(id: String) -> (cardId: String, conversationId: String)? {
            guard id.hasPrefix(prefix) else { return nil }
            let rest = id.dropFirst(prefix.count)
            guard let colon = rest.lastIndex(of: ":") else { return nil }
            let cardId = String(rest[..<colon])
            let conversationId = String(rest[rest.index(after: colon)...])
            guard !cardId.isEmpty, !conversationId.isEmpty else { return nil }
            return (cardId, conversationId)
        }
    }

    /// The conversations of the cards in `cardTitles`, each with its card's name.
    public static func entries(conversations: [String: [RemoteConversation]],
                               cardTitles: [String: String]) -> [Entry] {
        var out: [Entry] = []
        for (cardId, list) in conversations {
            guard let cardTitle = cardTitles[cardId] else { continue }
            for conversation in list {
                out.append(Entry(cardId: cardId, cardTitle: cardTitle, conversation: conversation))
            }
        }
        return out
    }

    /// Every word must be in the conversation's title, its last message or
    /// its card's name, and at least one in the conversation itself, so a
    /// card's name alone does not list all its conversations. Title matches
    /// come first, then those found only in the last message; within each,
    /// conversations that are not archived, then the most recent.
    public static func search(_ entries: [Entry], query: CardSearchQuery, includeArchived: Bool = false,
                              limit: Int? = nil) -> [Hit] {
        guard !query.isEmpty else { return [] }
        var hits: [Hit] = []
        for entry in entries {
            let conversation = entry.conversation
            if conversation.archived && !includeArchived { continue }
            let title = CardSearchQuery.fold(conversation.title ?? "")
            let preview = CardSearchQuery.fold(conversation.preview ?? "")
            let card = CardSearchQuery.fold(entry.cardTitle)
            var inOwnText = false
            var inTitleOrCard = true
            var matches = true
            for word in query.words {
                let t = title.contains(word)
                let p = preview.contains(word)
                let c = card.contains(word)
                guard t || p || c else { matches = false; break }
                if t || p { inOwnText = true }
                if !t && !c { inTitleOrCard = false }
            }
            guard matches, inOwnText else { continue }
            let inTitle = inTitleOrCard && query.words.contains { title.contains($0) }
            hits.append(Hit(entry: entry, inTitle: inTitle))
        }
        hits.sort { a, b in
            if a.inTitle != b.inTitle { return a.inTitle }
            let ca = a.entry.conversation, cb = b.entry.conversation
            if ca.archived != cb.archived { return !ca.archived }
            if ca.updatedAt != cb.updatedAt { return ca.updatedAt > cb.updatedAt }
            return a.id < b.id
        }
        if let limit, hits.count > limit { return Array(hits.prefix(limit)) }
        return hits
    }
}
