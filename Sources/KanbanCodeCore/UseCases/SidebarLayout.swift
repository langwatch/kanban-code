import Foundation

/// A section of the card list in the Mac sidebar.
public enum SidebarSectionKind: Hashable, Sendable {
    case pinned
    /// Cards whose assistant session runs now, whatever their column.
    case live
    case column(KanbanCodeColumn)

    /// Stable key, for collapse state and row identity.
    public var id: String {
        switch self {
        case .pinned: "pinned"
        case .live: "live"
        case .column(let column): column.rawValue
        }
    }

    public var title: String {
        switch self {
        case .pinned: "Pinned"
        case .live: "Live"
        case .column(let column): column.displayName
        }
    }

    public var column: KanbanCodeColumn? {
        if case .column(let column) = self { return column }
        return nil
    }
}

public struct SidebarSection: Equatable, Sendable {
    public let kind: SidebarSectionKind
    public let cards: [KanbanCodeCard]

    public init(kind: SidebarSectionKind, cards: [KanbanCodeCard]) {
        self.kind = kind
        self.cards = cards
    }
}

/// The sidebar lists cards the way the phone does: Pinned, then the cards
/// running now, then the columns in the phone's order with Backlog last.
/// All Sessions is not listed; the board view keeps it.
public enum SidebarLayout {
    /// Columns after Pinned and Live.
    public static let columnOrder: [KanbanCodeColumn] = [.waiting, .inProgress, .inReview, .done, .backlog]

    /// `cardsByColumn` holds the unpinned top-level cards of each column in
    /// their board order. Empty sections are left out, except Backlog, which
    /// stays as the place to drop and refresh tasks.
    public static func sections(
        pinned: [KanbanCodeCard],
        cardsByColumn: [KanbanCodeColumn: [KanbanCodeCard]],
        isLive: (KanbanCodeCard) -> Bool,
        isBusy: (KanbanCodeCard) -> Bool
    ) -> [SidebarSection] {
        var out: [SidebarSection] = []
        if !pinned.isEmpty { out.append(SidebarSection(kind: .pinned, cards: pinned)) }
        let live = columnOrder.flatMap { cardsByColumn[$0] ?? [] }.filter(isLive).sorted { a, b in
            let busyA = isBusy(a), busyB = isBusy(b)
            if busyA != busyB { return busyA }
            let timeA = a.link.lastActivity ?? a.link.updatedAt
            let timeB = b.link.lastActivity ?? b.link.updatedAt
            return timeA != timeB ? timeA > timeB : a.id < b.id
        }
        if !live.isEmpty { out.append(SidebarSection(kind: .live, cards: live)) }
        let liveIds = Set(live.map(\.id))
        for column in columnOrder {
            let cards = (cardsByColumn[column] ?? []).filter { !liveIds.contains($0.id) }
            if !cards.isEmpty || column == .backlog {
                out.append(SidebarSection(kind: .column(column), cards: cards))
            }
        }
        return out
    }
}
