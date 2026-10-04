import Foundation
import KanbanCodeRemoteKit
import Synchronization

/// A parsed `GET /v1/cards/search` request.
public struct RemoteCardSearchRequest: Sendable, Equatable {
    public var query: String
    public var scope: RemoteCardSearchScope
    public var limit: Int
    /// Answer from this master's own cards only, without asking its peers.
    public var local: Bool

    public init(query: String, scope: RemoteCardSearchScope = .all, limit: Int = CardSearch.defaultLimit, local: Bool = false) {
        self.query = query
        self.scope = scope
        self.limit = min(max(limit, 1), CardSearch.maxLimit)
        self.local = local
    }
}

extension RemoteWorkingSet {
    /// What the working set rule needs of a card.
    public struct Member: Sendable {
        public var id: String
        public var column: RemoteColumn
        public var archived: Bool
        public var activity: Date

        public init(id: String, column: RemoteColumn, archived: Bool, activity: Date) {
            self.id = id
            self.column = column
            self.archived = archived
            self.activity = activity
        }
    }

    /// The ids of the working set among `members`.
    public static func ids(_ members: [Member], doneLimit: Int = RemoteWorkingSet.doneLimit) -> Set<String> {
        let recentDone = members.filter { $0.column == .done && !$0.archived }
            .sorted { $0.activity != $1.activity ? $0.activity > $1.activity : $0.id < $1.id }
            .prefix(doneLimit)
        var out = Set(recentDone.map(\.id))
        for member in members where !member.archived && member.column != .allSessions && member.column != .done {
            out.insert(member.id)
        }
        return out
    }
}

/// Card search over wire cards: what a host without richer card text does.
public enum RemoteCardSearch {
    /// Whether `scope` takes the card. `workingSet` is only read for `.older`.
    public static func admits(scope: RemoteCardSearchScope, id: String, archived: Bool, isSubagent: Bool,
                              workingSet: Set<String>) -> Bool {
        switch scope {
        case .all: true
        case .older: !workingSet.contains(id)
        case .archived: archived && !isSubagent
        }
    }

    public static func search(_ cards: [RemoteCard], _ request: RemoteCardSearchRequest) -> RemoteCardSearchResult {
        let query = CardSearchQuery(request.query)
        let workingSet = request.scope == .older ? Set(RemoteWorkingSet.filter(cards).map(\.id)) : []
        let matches = CardSearch.ranked(cards.filter { card in
            admits(scope: request.scope, id: card.id, archived: card.archived, isSubagent: card.parentCardId != nil,
                   workingSet: workingSet) && query.matches(card)
        })
        return RemoteCardSearchResult(cards: Array(matches.prefix(request.limit)), truncated: matches.count > request.limit)
    }

    /// A peer master to ask, and how.
    public struct Peer: Sendable {
        public var machineId: String
        public var name: String
        public var search: @Sendable () async throws -> RemoteCardSearchResult

        public init(machineId: String, name: String, search: @escaping @Sendable () async throws -> RemoteCardSearchResult) {
            self.machineId = machineId
            self.name = name
            self.search = search
        }
    }

    /// How long a peer has to answer a search before the answer goes out
    /// without it.
    public static let peerTimeout: TimeInterval = 2.5

    /// `local` merged with what each peer answers within `timeout`. A peer
    /// that fails or is late is named in `unreachable`; one that has no
    /// search route (an older build) is skipped silently.
    public static func fanOut(local: RemoteCardSearchResult, peers: [Peer], offline: [String] = [], limit: Int,
                              timeout: TimeInterval = RemoteCardSearch.peerTimeout) async -> RemoteCardSearchResult {
        guard !peers.isEmpty else {
            return CardSearch.merge(local: local, peers: [], unreachable: offline, limit: limit)
        }
        enum Answer: Sendable {
            case result(Int, RemoteCardSearchResult)
            case failed(Int)
            case unsupported(Int)
            case deadline
        }
        var answers: [(machineId: String, result: RemoteCardSearchResult)] = []
        var pending = Set(peers.indices)
        var unreachable = offline
        await withTaskGroup(of: Answer.self) { group in
            for (index, peer) in peers.enumerated() {
                group.addTask {
                    do {
                        return .result(index, try await peer.search())
                    } catch RemoteClientError.notFound {
                        return .unsupported(index)
                    } catch {
                        return .failed(index)
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return .deadline
            }
            for await answer in group {
                switch answer {
                case .result(let index, let result):
                    pending.remove(index)
                    answers.append((peers[index].machineId, result))
                case .unsupported(let index):
                    pending.remove(index)
                case .failed(let index):
                    pending.remove(index)
                    unreachable.append(peers[index].name)
                case .deadline:
                    unreachable.append(contentsOf: pending.sorted().map { peers[$0].name })
                    pending.removeAll()
                }
                if pending.isEmpty { break }
            }
            group.cancelAll()
        }
        return CardSearch.merge(local: local, peers: answers, unreachable: unreachable, limit: limit)
    }
}

/// The folded search text of each card, kept between searches: a search
/// runs on every keystroke over every card, and folding a card's text costs
/// far more than looking a word up in it.
public final class CardSearchIndex: Sendable {
    private struct Item {
        var stamp: Date
        var title: String
        var text: String
    }

    private let items = Mutex<[String: Item]>([:])

    public init() {}

    /// Lines of a prompt that count for search.
    static let promptLines = 6
    static let promptCharacters = 600

    static func head(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return "" }
        let stripped = InjectedPromptText.strip(text)
        let lines = stripped.split(separator: "\n", omittingEmptySubsequences: true).prefix(promptLines)
        return String(lines.joined(separator: "\n").prefix(promptCharacters))
    }

    static func text(of card: KanbanCodeCard) -> String {
        let link = card.link
        var branches: [String] = []
        if let branch = link.worktreeLink?.branch { branches.append(branch) }
        for branch in link.discoveredBranches ?? [] where !branches.contains(branch) { branches.append(branch) }
        let firstPrompt = card.session?.firstPrompt
        var extra = [head(link.promptBody)]
        if firstPrompt != link.promptBody { extra.append(head(firstPrompt)) }
        if let name = link.name, name != card.displayTitle { extra.append(name) }
        return CardSearchQuery.haystack(
            title: card.displayTitle, projectName: card.projectName, branches: branches,
            prs: link.prLinks.map { ($0.number, $0.title) }, extra: extra)
    }

    /// The cards of `cards` that match, unranked. Text of a card is folded
    /// again only when the card changed since the last search.
    public func matching(_ cards: [KanbanCodeCard], query: CardSearchQuery) -> [KanbanCodeCard] {
        guard !query.isEmpty else { return cards }
        return items.withLock { items in
            if items.count > cards.count * 2 + 64 {
                let live = Set(cards.map(\.id))
                items = items.filter { live.contains($0.key) }
            }
            return cards.filter { card in
                let title = card.displayTitle
                if let item = items[card.id], item.stamp == card.link.updatedAt, item.title == title {
                    return query.matches(folded: item.text)
                }
                let text = Self.text(of: card)
                items[card.id] = Item(stamp: card.link.updatedAt, title: title, text: text)
                return query.matches(folded: text)
            }
        }
    }
}
