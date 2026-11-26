import Foundation

/// Card edits sent from this device that the boards may not show yet.
///
/// Each master sends its own board, and several masters can list the same
/// card (the owner's copy and a peer's synced copy). After an edit the
/// master that took it sends the new card right away, but a peer keeps
/// sending its old copy until it syncs, and a board frame read before the
/// edit can still land after it. Laid over every board, a pending edit
/// keeps the card as edited until each board agrees, so the card does not
/// come back for a moment.
///
/// An edit shows from the moment it is sent. It is dropped when the
/// request fails, or once it succeeded and every board either agrees or,
/// after `grace`, has sent data newer than the success and still disagrees:
/// then something else changed the card and that board wins. A board with
/// nothing newer than the success (a master that is off, showing its cache)
/// keeps the edit.
public struct PendingCardEdits: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case archive
        case unarchive
        case delete
        case rename(String)
        case move(RemoteColumn)
        case pin(Bool)

        /// Edits of the same field replace each other.
        fileprivate enum Field { case presence, title, column, pin }

        fileprivate var field: Field {
            switch self {
            case .archive, .unarchive, .delete: .presence
            case .rename: .title
            case .move: .column
            case .pin: .pin
            }
        }
    }

    public struct Edit: Sendable, Equatable, Identifiable {
        public let id: UUID
        public let cardId: String
        public let kind: Kind
        public let startedAt: Date
        /// When the master took the edit; nil while the request runs.
        public var succeededAt: Date?

        /// The board's copy shows the edit. A board that does not list the
        /// card has nothing to contradict it.
        public func isShown(by card: RemoteCard?) -> Bool {
            guard let card else { return true }
            switch kind {
            case .archive: return card.archived
            case .unarchive: return !card.archived
            case .delete: return false
            case .rename(let name): return card.title == name
            case .move(let column): return card.column == column
            case .pin(let pinned): return card.pinned == pinned
            }
        }

        func applied(to card: RemoteCard) -> RemoteCard? {
            var out = card
            switch kind {
            case .archive: out.archived = true
            case .unarchive: out.archived = false
            case .delete: return nil
            case .rename(let name): out.title = name
            case .move(let column): out.column = column
            case .pin(let pinned):
                out.pinned = pinned
                out.pinnedAt = pinned ? (card.pinnedAt ?? startedAt) : nil
            }
            return out
        }
    }

    /// What one master's board holds and when it last sent data.
    public struct Listing: Sendable {
        public var cards: [RemoteCard]
        public var receivedAt: Date?

        public init(cards: [RemoteCard], receivedAt: Date?) {
            self.cards = cards
            self.receivedAt = receivedAt
        }
    }

    /// How long after a success a board that still disagrees is taken as
    /// slow to sync rather than changed by someone else.
    public static let grace: TimeInterval = 30

    public private(set) var edits: [Edit] = []

    public init() {}

    public var isEmpty: Bool { edits.isEmpty }

    /// Starts an edit; it shows at once. An earlier edit of the same field
    /// of the card is replaced.
    @discardableResult
    public mutating func begin(cardId: String, _ kind: Kind, at now: Date = .now) -> UUID {
        edits.removeAll { $0.cardId == cardId && $0.kind.field == kind.field }
        let edit = Edit(id: UUID(), cardId: cardId, kind: kind, startedAt: now)
        edits.append(edit)
        return edit.id
    }

    public mutating func succeeded(_ id: UUID, at now: Date = .now) {
        guard let index = edits.firstIndex(where: { $0.id == id }) else { return }
        edits[index].succeededAt = now
    }

    /// The request failed: the boards show the card as they have it.
    public mutating func failed(_ id: UUID) {
        edits.removeAll { $0.id == id }
    }

    /// Drops the edits every board has caught up with.
    public mutating func settle(_ listings: [Listing], now: Date = .now) {
        edits.removeAll { edit in
            guard let succeededAt = edit.succeededAt else { return false }
            let pastGrace = now.timeIntervalSince(succeededAt) >= Self.grace
            return listings.allSatisfy { listing in
                if edit.isShown(by: listing.cards.first(where: { $0.id == edit.cardId })) { return true }
                guard pastGrace, let received = listing.receivedAt else { return false }
                return received >= succeededAt
            }
        }
    }

    /// `cards` with the pending edits laid over them, in order.
    public func apply(to cards: [RemoteCard]) -> [RemoteCard] {
        guard !edits.isEmpty else { return cards }
        let byCard = Dictionary(grouping: edits, by: \.cardId)
        return cards.compactMap { card in
            guard let pending = byCard[card.id] else { return card }
            var out: RemoteCard? = card
            for edit in pending {
                guard let current = out else { break }
                out = edit.applied(to: current)
            }
            return out
        }
    }

    /// Cards a pending edit deletes.
    public var deletedIds: Set<String> {
        Set(edits.filter { $0.kind == .delete }.map(\.cardId))
    }
}
