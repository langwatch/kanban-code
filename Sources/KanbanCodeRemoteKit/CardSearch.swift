import Foundation

/// Which cards `GET /v1/cards/search` looks at.
public enum RemoteCardSearchScope: String, Codable, Sendable, CaseIterable {
    /// Every card the master knows.
    case all
    /// Cards outside the working set: archived, All Sessions, and Done cards
    /// past the recent ones. What a client that holds the working set lacks.
    case older
    /// Archived cards that are not subagents, as the archive lists them.
    case archived
}

/// Answer of `GET /v1/cards/search`: the best matches, board cards first,
/// then the most recently active.
public struct RemoteCardSearchResult: Codable, Sendable, Equatable {
    public var cards: [RemoteCard]
    /// More cards matched than `limit` let through.
    public var truncated: Bool
    /// Names of the peer masters that did not answer in time; their cards
    /// are in the answer only as far as this master has a copy.
    public var unreachable: [String]

    public init(cards: [RemoteCard], truncated: Bool = false, unreachable: [String] = []) {
        self.cards = cards
        self.truncated = truncated
        self.unreachable = unreachable
    }

    private enum CodingKeys: String, CodingKey {
        case cards, truncated, unreachable
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cards = try c.decode([RemoteCard].self, forKey: .cards)
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        unreachable = try c.decodeIfPresent([String].self, forKey: .unreachable) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(cards, forKey: .cards)
        if truncated { try c.encode(truncated, forKey: .truncated) }
        if !unreachable.isEmpty { try c.encode(unreachable, forKey: .unreachable) }
    }
}

/// A card search as typed: words separated by spaces, each of which must be
/// found somewhere in the card's text, whatever the case or the accents.
public struct CardSearchQuery: Sendable, Equatable {
    public let words: [String]

    public init(_ text: String) {
        words = Self.fold(text).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// No word: every card matches.
    public var isEmpty: Bool { words.isEmpty }

    /// `text` without case, accents or width, the form both sides are compared in.
    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
    }

    /// The searchable text of a card, folded: its title, project, branch,
    /// pull requests (`#N` and title) and whatever `extra` adds.
    public static func haystack(title: String, projectName: String?, branches: [String],
                                prs: [(number: Int, title: String?)], extra: [String] = []) -> String {
        var parts = [title]
        if let projectName { parts.append(projectName) }
        parts.append(contentsOf: branches)
        for pr in prs {
            parts.append("#\(pr.number)")
            if let title = pr.title { parts.append(title) }
        }
        parts.append(contentsOf: extra)
        return fold(parts.filter { !$0.isEmpty }.joined(separator: "\n"))
    }

    public static func haystack(of card: RemoteCard, extra: [String] = []) -> String {
        haystack(title: card.title, projectName: card.projectName, branches: card.branch.map { [$0] } ?? [],
                 prs: card.prs.map { ($0.number, $0.title) }, extra: extra)
    }

    /// Whether every word is in `haystack`, which must be folded already.
    public func matches(folded haystack: String) -> Bool {
        words.allSatisfy { haystack.contains($0) }
    }

    public func matches(_ card: RemoteCard, extra: [String] = []) -> Bool {
        isEmpty || matches(folded: Self.haystack(of: card, extra: extra))
    }
}

public enum CardSearch {
    public static let defaultLimit = 50
    public static let maxLimit = 200

    /// What a search needs of a card to place it in the answer.
    public struct Entry: Sendable, Equatable {
        public var id: String
        public var onBoard: Bool
        public var activity: Date

        public init(id: String, onBoard: Bool, activity: Date) {
            self.id = id
            self.onBoard = onBoard
            self.activity = activity
        }

        public init(_ card: RemoteCard) {
            self.init(id: card.id, onBoard: CardSearch.isOnBoard(card), activity: card.lastActivity ?? card.updatedAt)
        }
    }

    /// On the board: not archived and not in All Sessions.
    public static func isOnBoard(_ card: RemoteCard) -> Bool {
        !card.archived && card.column != .allSessions
    }

    /// Board cards first, then the most recently active, then by id.
    public static func ranks(_ a: Entry, before b: Entry) -> Bool {
        if a.onBoard != b.onBoard { return a.onBoard }
        if a.activity != b.activity { return a.activity > b.activity }
        return a.id < b.id
    }

    public static func ranked(_ cards: [RemoteCard]) -> [RemoteCard] {
        cards.sorted { ranks(Entry($0), before: Entry($1)) }
    }

    /// Searches cards a client already holds, in ranked order.
    public static func search(_ cards: [RemoteCard], query: CardSearchQuery) -> [RemoteCard] {
        ranked(cards.filter { query.matches($0) })
    }

    /// One answer out of this master's and its peers': each card once, the
    /// copy of the master that owns it preferred, ranked again and cut to
    /// `limit`. `peers` name the machine id each answer came from.
    public static func merge(local: RemoteCardSearchResult,
                             peers: [(machineId: String, result: RemoteCardSearchResult)],
                             unreachable: [String], limit: Int) -> RemoteCardSearchResult {
        var byId: [String: RemoteCard] = [:]
        for card in local.cards { byId[card.id] = card }
        var truncated = local.truncated
        for peer in peers {
            truncated = truncated || peer.result.truncated
            for card in peer.result.cards where byId[card.id] == nil || card.machineId == peer.machineId {
                byId[card.id] = card
            }
        }
        let all = ranked(Array(byId.values))
        return RemoteCardSearchResult(cards: Array(all.prefix(limit)), truncated: truncated || all.count > limit,
                                      unreachable: unreachable)
    }
}
