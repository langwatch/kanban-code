import Foundation

/// Conversations the human marked unread while they may be open on screen.
///
/// An open conversation marks itself read whenever it loads and finds it
/// unread, so the agent's replies count as seen. After an explicit "Mark as
/// Unread" that would undo the mark at the next refresh. A hold keeps the
/// open view from marking it read until the human opens the conversation
/// again, sends in it, or marks it read; replies from the agent keep it held.
public struct ConversationReadHolds: Sendable, Equatable {
    public struct Key: Hashable, Sendable {
        public var server: String
        public var cardId: String
        public var conversation: String

        public init(server: String, cardId: String, conversation: String) {
            self.server = server
            self.cardId = cardId
            self.conversation = conversation
        }
    }

    public private(set) var held: Set<Key> = []

    public init() {}

    /// The human marked it unread: the open view leaves it unread.
    public mutating func markedUnread(_ key: Key) {
        held.insert(key)
    }

    /// The human opened it anew (selected it, or a new screen showed it).
    public mutating func opened(_ key: Key) {
        held.remove(key)
    }

    /// The human sent a message in it.
    public mutating func interacted(_ key: Key) {
        held.remove(key)
    }

    /// The human marked it read, or a mark unread failed.
    public mutating func released(_ key: Key) {
        held.remove(key)
    }

    public func isHeld(_ key: Key) -> Bool {
        held.contains(key)
    }

    /// Whether the open view should mark the conversation read after a load
    /// that found it `unread`.
    public func shouldMarkRead(_ key: Key, unread: Bool) -> Bool {
        unread && !held.contains(key)
    }
}
