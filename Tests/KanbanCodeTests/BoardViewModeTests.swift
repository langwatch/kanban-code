import Testing
@testable import KanbanCode
import KanbanCodeCore

@Suite("Board View Mode")
struct BoardViewModeTests {
    @Test("View mode raw values stay stable for persistence")
    func rawValues() {
        #expect(BoardViewMode.kanban.rawValue == "kanban")
        #expect(BoardViewMode.list.rawValue == "list")
    }

    @Test("Collapsed list sections round-trip through storage")
    func collapsedSectionsRoundTrip() {
        let encoded = ListSectionCollapseState.encode([SidebarSectionKind.live.id, SidebarSectionKind.column(.waiting).id])
        let decoded = ListSectionCollapseState.decode(encoded)

        #expect(decoded == ["live", "requires_attention"])
        // Sections collapsed before Live existed keep their column names.
        #expect(ListSectionCollapseState.decode("in_review,backlog") == ["in_review", "backlog"])
    }

    @Test("Collapsed list sections ignore empty persisted state")
    func collapsedSectionsEmptyState() {
        #expect(ListSectionCollapseState.encode([]) == "")
        #expect(ListSectionCollapseState.decode("") == [])
    }

    @Test("Pinned and lane rows use distinct SwiftUI identities")
    func pinnedAndLaneRowsUseDistinctIdentities() {
        let cardId = "card_pin1"

        #expect(ListBoardRowIdentity.pinned(cardId) != .section(.column(.waiting), cardId))
        #expect(ListBoardRowIdentity.section(.live, cardId) != .section(.column(.inProgress), cardId))
    }
}
