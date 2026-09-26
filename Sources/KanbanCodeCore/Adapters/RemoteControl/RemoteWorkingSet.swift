import Foundation
import KanbanCodeRemoteKit

/// The cards a client sees unless it asks for `?all=1`: no archived cards,
/// no All Sessions cards, and only the most recent Done cards.
public enum RemoteWorkingSet {
    public static let doneLimit = 30

    public static func filter(_ board: RemoteBoard, doneLimit: Int = RemoteWorkingSet.doneLimit) -> RemoteBoard {
        var out = board
        out.cards = filter(board.cards, doneLimit: doneLimit)
        return out
    }

    public static func filter(_ cards: [RemoteCard], doneLimit: Int = RemoteWorkingSet.doneLimit) -> [RemoteCard] {
        let recentDone = Set(
            cards.filter { $0.column == .done && !$0.archived }
                .sorted { a, b in
                    let da = a.lastActivity ?? a.updatedAt
                    let db = b.lastActivity ?? b.updatedAt
                    return da != db ? da > db : a.id < b.id
                }
                .prefix(doneLimit)
                .map(\.id)
        )
        return cards.filter { card in
            if card.archived || card.column == .allSessions { return false }
            if card.column == .done { return recentDone.contains(card.id) }
            return true
        }
    }
}
