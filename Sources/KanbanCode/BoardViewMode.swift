import SwiftUI
import KanbanCodeCore

enum BoardViewMode: String, CaseIterable {
    case kanban
    case list

    var label: String {
        switch self {
        case .kanban: "Kanban"
        case .list: "List"
        }
    }

    var icon: String {
        switch self {
        case .kanban: "square.split.2x1"
        case .list: "list.bullet"
        }
    }
}

/// SwiftUI row identity includes presentation location so pinning is modeled
/// as a clean lane removal plus pinned insertion, never as a cross-section move.
enum ListBoardRowIdentity: Hashable {
    case pinned(String)
    case section(SidebarSectionKind, String)
}

/// Collapsed sidebar sections, stored by `SidebarSectionKind.id`.
enum ListSectionCollapseState {
    static func encode(_ ids: Set<String>) -> String {
        ids.sorted().joined(separator: ",")
    }

    static func decode(_ rawValue: String) -> Set<String> {
        Set(rawValue.split(separator: ",").map(String.init))
    }
}
