import Foundation
import KanbanCodeRemoteKit

/// What one events socket last sent, to turn the next board into a `cards`
/// delta: the cards whose encoded value changed, and the ids that left.
struct RemoteBoardDeltaTracker {
    private var sentCards: [String: Data] = [:]
    private var sentProjects: [RemoteProject] = []
    /// Sorted keys, so equal cards always encode to equal bytes.
    private let encoder: JSONEncoder = {
        let e = JSONEncoder.remote
        e.outputFormatting = .sortedKeys
        return e
    }()

    /// A `board` event, and the new baseline for later deltas.
    mutating func fullBoard(_ board: RemoteBoard) -> RemoteEvent {
        sentCards = Dictionary(board.cards.map { ($0.id, encode($0)) }, uniquingKeysWith: { _, last in last })
        sentProjects = board.projects
        return RemoteEvent(type: .board, board: board)
    }

    /// A `cards` event with what changed since the last frame, or nil when
    /// nothing did.
    mutating func delta(_ board: RemoteBoard) -> RemoteEvent? {
        var upserted: [RemoteCard] = []
        var next: [String: Data] = [:]
        for card in board.cards {
            let data = encode(card)
            next[card.id] = data
            if sentCards[card.id] != data { upserted.append(card) }
        }
        let removed = sentCards.keys.filter { next[$0] == nil }.sorted()
        let projectsChanged = board.projects != sentProjects
        sentCards = next
        sentProjects = board.projects
        guard !upserted.isEmpty || !removed.isEmpty || projectsChanged else { return nil }
        return RemoteEvent(
            type: .cards,
            upserted: upserted,
            removed: removed,
            projects: projectsChanged ? board.projects : nil
        )
    }

    private func encode(_ card: RemoteCard) -> Data {
        (try? encoder.encode(card)) ?? Data()
    }
}
