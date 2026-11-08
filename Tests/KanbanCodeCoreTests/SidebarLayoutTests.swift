import Testing
import Foundation
@testable import KanbanCodeCore

/// The Mac sidebar lists cards like the phone: Pinned, Live, the columns in
/// the phone's order, Backlog last, no All Sessions.
@Suite("Sidebar layout")
struct SidebarLayoutTests {

    private func link(_ id: String, _ column: KanbanCodeColumn, minutesAgo: Double = 0) -> Link {
        Link(id: id, name: id, projectPath: "/repo", column: column,
             lastActivity: .now.addingTimeInterval(-minutesAgo * 60), source: .manual)
    }

    private func state(_ links: [Link], live: Set<String> = []) -> AppState {
        let state = AppState()
        for link in links { state.links[link.id] = link }
        state.tmuxSessions = live
        state.rebuildCards()
        return state
    }

    @Test("Sections run Pinned, Live, Waiting, In Progress, In Review, Done, then Backlog")
    func sectionOrder() {
        var pinned = link("card_pin", .done)
        pinned.pinnedAt = .now
        var live = link("card_live", .waiting)
        live.tmuxLink = TmuxLink(sessionName: "repo-card_live")
        let s = state([
            pinned, live,
            link("card_wait", .waiting), link("card_prog", .inProgress), link("card_rev", .inReview),
            link("card_done", .done), link("card_back", .backlog), link("card_old", .allSessions),
        ], live: ["repo-card_live"])

        #expect(s.sidebarSections.map(\.kind) == [
            .pinned, .live, .column(.waiting), .column(.inProgress), .column(.inReview), .column(.done), .column(.backlog),
        ])
        #expect(s.sidebarSections.map(\.kind.title) == ["Pinned", "Live", "Waiting", "In Progress", "In Review", "Done", "Backlog"])
        // A live card shows once, under Live, and a pinned card only under Pinned.
        #expect(s.sidebarSections[1].cards.map(\.id) == ["card_live"])
        #expect(s.sidebarSections[2].cards.map(\.id) == ["card_wait"])
        #expect(s.sidebarSections[5].cards.map(\.id) == ["card_done"])
        // All Sessions is the board's, not the sidebar's.
        #expect(!s.sidebarCardOrder.contains { $0.id == "card_old" })
    }

    @Test("Empty sections are left out, except Backlog")
    func emptySections() {
        let s = state([link("card_done", .done)])
        #expect(s.sidebarSections.map(\.kind) == [.column(.done), .column(.backlog)])
        #expect(s.sidebarSections.last?.cards.isEmpty == true)
    }

    @Test("Live lists working cards first, then the most recent")
    func liveOrder() {
        var idleRecent = link("card_idle", .waiting, minutesAgo: 1)
        idleRecent.tmuxLink = TmuxLink(sessionName: "t-idle")
        var idleOld = link("card_old", .waiting, minutesAgo: 60)
        idleOld.tmuxLink = TmuxLink(sessionName: "t-old")
        var busy = link("card_busy", .inProgress, minutesAgo: 30)
        busy.tmuxLink = TmuxLink(sessionName: "t-busy")
        busy.isLaunching = true
        let s = state([idleRecent, idleOld, busy], live: ["t-idle", "t-old", "t-busy"])
        #expect(s.sidebarSections.first?.kind == .live)
        #expect(s.sidebarSections.first?.cards.map(\.id) == ["card_busy", "card_idle", "card_old"])
    }

    @Test("A card leaves Live for its column when its session ends")
    func sessionEndMovesCardBack() {
        var card = link("card_1", .waiting)
        card.tmuxLink = TmuxLink(sessionName: "t-1")
        let s = state([card], live: ["t-1"])
        #expect(s.sidebarSections.first?.kind == .live)
        s.tmuxSessions = []
        s.rebuildCards()
        #expect(s.sidebarSections.first?.kind == .column(.waiting))
        #expect(s.sidebarSections.first?.cards.map(\.id) == ["card_1"])
    }

    @Test("A shell terminal is not a live session")
    func shellIsNotLive() {
        var card = link("card_1", .backlog)
        card.tmuxLink = TmuxLink(sessionName: "t-sh", isShellOnly: true)
        let s = state([card], live: ["t-sh"])
        #expect(!s.sidebarSections.contains { $0.kind == .live })
    }
}
