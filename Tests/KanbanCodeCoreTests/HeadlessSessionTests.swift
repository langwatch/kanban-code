import Testing
import Foundation
@testable import KanbanCodeCore

/// Sessions a script runs through `claude -p` (entrypoint "sdk-cli") stay in
/// All Sessions unless a card claims them.
@Suite("Headless sessions")
struct HeadlessSessionTests {

    private func headless(_ id: String, project: String = "/repo") -> Session {
        Session(id: id, projectPath: project, messageCount: 3, modifiedTime: .now, entrypoint: "sdk-cli")
    }

    private func column(of link: Link, activity: ActivityState? = nil, liveTmux: Bool = false) -> KanbanCodeColumn {
        var link = link
        UpdateCardColumn.update(link: &link, activityState: activity, hasWorktree: liveTmux, hasLiveSession: liveTmux)
        return link.column
    }

    // MARK: - Transcript head

    @Test("The entrypoint is read from the transcript head")
    func parserReadsEntrypoint() async throws {
        let dir = NSTemporaryDirectory() + "kanban-headless-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/h1.jsonl"
        try [
            #"{"type":"queue-operation","operation":"enqueue","sessionId":"h1","content":"Judge this"}"#,
            #"{"type":"user","entrypoint":"sdk-cli","cwd":"/repo","message":{"role":"user","content":"Judge this"}}"#,
            #"{"type":"assistant","entrypoint":"sdk-cli","message":{"content":[{"type":"text","text":"ok"}]}}"#,
        ].joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let metadata = try await JsonlParser.extractMetadata(from: path)
        #expect(metadata?.entrypoint == "sdk-cli")
        let session = Session(id: "h1", entrypoint: metadata?.entrypoint)
        #expect(session.isHeadless)
    }

    // MARK: - Reconcile + column

    @Test("A headless session no card claims stays off the board")
    func unclaimedHeadlessStaysInAllSessions() {
        let result = CardReconciler.reconcile(
            existing: [],
            snapshot: .init(sessions: [headless("h1")])
        )
        #expect(result.count == 1)
        #expect(result[0].headless == true)
        #expect(column(of: result[0]) == .allSessions)
        #expect(column(of: result[0], activity: .activelyWorking) == .allSessions)
        #expect(column(of: result[0], activity: .needsAttention) == .allSessions)
    }

    @Test("An existing discovered headless card leaves the board columns")
    func existingHeadlessCardLeavesBoard() {
        let card = Link(
            projectPath: "/repo",
            column: .waiting,
            lastActivity: .now,
            source: .discovered,
            sessionLink: SessionLink(sessionId: "h1")
        )
        let result = CardReconciler.reconcile(existing: [card], snapshot: .init(sessions: [headless("h1")]))
        #expect(result.count == 1)
        #expect(result[0].id == card.id)
        #expect(column(of: result[0], activity: .idleWaiting) == .allSessions)
    }

    @Test("An agtop-hosted card keeps its sdk-cli session on the board")
    func agtopCardStays() {
        let card = Link(
            projectPath: "/repo",
            column: .inProgress,
            source: .manual,
            sessionLink: SessionLink(sessionId: "abcdef12-0000-0000-0000-000000000000"),
            tmuxLink: TmuxLink(sessionName: "agtop-abcdef12"),
            launchedAt: .now
        )
        let session = headless("abcdef12-0000-0000-0000-000000000000")
        let result = CardReconciler.reconcile(existing: [card], snapshot: .init(sessions: [session]))
        #expect(result.count == 1)
        #expect(result[0].headless == nil)
        #expect(column(of: result[0], activity: .activelyWorking, liveTmux: true) == .inProgress)

        // Still on the board after its agtop host is gone.
        var ended = result[0]
        ended.tmuxLink = nil
        #expect(column(of: ended, activity: .idleWaiting) == .waiting)
    }

    @Test("An agtop card waiting for its session takes a headless one by project")
    func agtopLaunchingCardTakesHeadlessSession() {
        let card = Link(
            projectPath: "/repo",
            column: .inProgress,
            source: .manual,
            tmuxLink: TmuxLink(sessionName: "agtop-abcdef12"),
            launchedAt: .now.addingTimeInterval(-5)
        )
        let result = CardReconciler.reconcile(existing: [card], snapshot: .init(sessions: [headless("h1")]))
        #expect(result.count == 1)
        #expect(result[0].sessionLink?.sessionId == "h1")
    }

    @Test("A launching tmux card does not take a headless session run beside it")
    func tmuxLaunchingCardIgnoresHeadlessSession() {
        let card = Link(
            projectPath: "/repo",
            column: .inProgress,
            source: .manual,
            tmuxLink: TmuxLink(sessionName: "repo-card_1"),
            launchedAt: .now.addingTimeInterval(-5)
        )
        let result = CardReconciler.reconcile(existing: [card], snapshot: .init(sessions: [headless("h1")]))
        #expect(result.count == 2)
        #expect(result.first { $0.id == card.id }?.sessionLink == nil)
        let hidden = result.first { $0.id != card.id }
        #expect(hidden?.headless == true)
    }

    @Test("An interactive cli session is unchanged")
    func interactiveSessionUnchanged() {
        let session = Session(id: "c1", projectPath: "/repo", messageCount: 3, modifiedTime: .now, entrypoint: "cli")
        let result = CardReconciler.reconcile(existing: [], snapshot: .init(sessions: [session]))
        #expect(result[0].headless == nil)
        #expect(column(of: result[0], activity: .needsAttention) == .waiting)
    }

    @Test("A card the user moved onto the board stays there")
    func manualOverrideStays() {
        var card = Link(
            projectPath: "/repo",
            column: .inReview,
            lastActivity: .now,
            source: .discovered,
            sessionLink: SessionLink(sessionId: "h1")
        )
        card.manualOverrides.column = true
        let result = CardReconciler.reconcile(existing: [card], snapshot: .init(sessions: [headless("h1")]))
        #expect(result[0].headless == nil)
        #expect(column(of: result[0]) == .inReview)
    }

    @Test("A renamed headless card stays on the board")
    func renamedCardStays() {
        let card = Link(
            name: "Judge run I care about",
            projectPath: "/repo",
            column: .waiting,
            lastActivity: .now,
            source: .discovered,
            sessionLink: SessionLink(sessionId: "h1"),
            headless: true
        )
        #expect(column(of: card, activity: .idleWaiting) == .waiting)
    }

    @Test("Moving a hidden headless card onto the board claims it for good")
    func movingClaimsCard() {
        var state = AppState()
        let card = Link(
            projectPath: "/repo",
            column: .allSessions,
            lastActivity: .now,
            source: .discovered,
            sessionLink: SessionLink(sessionId: "h1"),
            headless: true
        )
        state.links[card.id] = card
        _ = Reducer.reduce(state: &state, action: .moveCard(cardId: card.id, to: .waiting))
        var moved = state.links[card.id]!
        #expect(moved.headless == false)

        // The drag override is later cleared by activity; the card still stays.
        moved.manualOverrides.column = false
        let again = CardReconciler.reconcile(existing: [moved], snapshot: .init(sessions: [headless("h1")]))
        #expect(again[0].headless == false)
        #expect(column(of: again[0], activity: .idleWaiting) == .waiting)
    }

    @Test("Headless flag survives a JSON round trip and stays out of interactive cards")
    func codable() throws {
        let hidden = Link(sessionLink: SessionLink(sessionId: "h1"), headless: true)
        let decoded = try JSONDecoder().decode(Link.self, from: JSONEncoder().encode(hidden))
        #expect(decoded.headless == true)
        let plain = try JSONEncoder().encode(Link(sessionLink: SessionLink(sessionId: "c1")))
        #expect(!String(decoding: plain, as: UTF8.self).contains("headless"))
    }
}
