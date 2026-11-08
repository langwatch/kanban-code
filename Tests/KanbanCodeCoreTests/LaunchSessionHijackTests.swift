import Foundation
import Testing

@testable import KanbanCodeCore

/// A launched card waits for the session its launch is about to start, and
/// accepts one by project path. Every idle session of that project matched
/// too, so a card could take a session written days earlier that the user
/// never opened, and the real session, arriving minutes later, then found
/// the card taken and got a duplicate card of its own.
@Suite("A launch takes only its own session")
struct LaunchSessionHijackTests {

    private let project = "/Users/dev/project"
    private let worktree = "/Users/dev/project/.claude/worktrees/feat-x"

    /// A card as the launch leaves it: tmux is up, no session yet.
    private func launchingCard(launchedAt: Date) -> Link {
        var link = Link(projectPath: project, column: .inProgress)
        link.tmuxLink = TmuxLink(sessionName: "project-card")
        link.isLaunching = true
        link.launchedAt = launchedAt
        link.updatedAt = launchedAt
        return link
    }

    @Test("a session idle since before the launch is not taken")
    func staleSessionIsNotAdopted() {
        let launch = Date.now
        let card = launchingCard(launchedAt: launch)
        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [
                Session(
                    id: "old-session", projectPath: project,
                    modifiedTime: launch.addingTimeInterval(-2 * 24 * 3600),
                    jsonlPath: "/sessions/old-session.jsonl")
            ]
        )

        let result = CardReconciler.reconcile(existing: [card], snapshot: snapshot)

        let launched = result.first { $0.id == card.id }
        #expect(launched?.sessionLink == nil)
        // The old session is somebody else's, and it gets no card either.
        #expect(result.count == 1)
    }

    @Test("the session the launch starts is taken")
    func freshSessionIsAdopted() {
        let launch = Date.now
        let card = launchingCard(launchedAt: launch)
        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [
                Session(
                    id: "new-session", projectPath: worktree,
                    modifiedTime: launch.addingTimeInterval(5),
                    jsonlPath: "/sessions/new-session.jsonl")
            ]
        )

        let result = CardReconciler.reconcile(existing: [card], snapshot: snapshot)

        #expect(result.count == 1)
        #expect(result[0].sessionLink?.sessionId == "new-session")
    }

    /// The whole failure, in the order it happened: the old session is
    /// reconciled first and must not take the card the launch is holding,
    /// so the real session still finds it a minute later.
    @Test("the real session still finds its card after a stale one was offered")
    func realSessionKeepsItsCard() {
        let launch = Date.now
        let card = launchingCard(launchedAt: launch)
        let stale = Session(
            id: "old-session", projectPath: project,
            modifiedTime: launch.addingTimeInterval(-2 * 24 * 3600),
            jsonlPath: "/sessions/old-session.jsonl")
        let real = Session(
            id: "real-session", projectPath: worktree,
            modifiedTime: launch.addingTimeInterval(60),
            jsonlPath: "/sessions/real-session.jsonl")

        let afterStale = CardReconciler.reconcile(
            existing: [card],
            snapshot: CardReconciler.DiscoverySnapshot(sessions: [stale]))
        let result = CardReconciler.reconcile(
            existing: afterStale,
            snapshot: CardReconciler.DiscoverySnapshot(sessions: [stale, real]))

        let launched = result.first { $0.id == card.id }
        #expect(launched?.sessionLink?.sessionId == "real-session")
        // And no second card was made for the session that belongs to it.
        #expect(result.count { $0.sessionLink?.sessionId == "real-session" } == 1)
    }

    /// A card launched before the field existed carries no `launchedAt`, and
    /// falls back to `updatedAt`, which a launch stamps too.
    @Test("a card without a launch stamp still rejects a stale session")
    func fallsBackToUpdatedAt() {
        var card = Link(projectPath: project, column: .inProgress)
        card.tmuxLink = TmuxLink(sessionName: "project-card")
        card.updatedAt = .now
        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [
                Session(
                    id: "old-session", projectPath: project,
                    modifiedTime: Date.now.addingTimeInterval(-3600),
                    jsonlPath: "/sessions/old-session.jsonl")
            ]
        )

        let result = CardReconciler.reconcile(existing: [card], snapshot: snapshot)

        #expect(result.first { $0.id == card.id }?.sessionLink == nil)
    }

    @Test("a session written seconds before the launch stamp still counts")
    func toleratesSmallSkew() {
        let launch = Date.now
        let card = launchingCard(launchedAt: launch)
        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [
                Session(
                    id: "new-session", projectPath: worktree,
                    modifiedTime: launch.addingTimeInterval(-5),
                    jsonlPath: "/sessions/new-session.jsonl")
            ]
        )

        let result = CardReconciler.reconcile(existing: [card], snapshot: snapshot)

        #expect(result.first { $0.id == card.id }?.sessionLink?.sessionId == "new-session")
    }

    @Test("of two launching cards the newer launch takes the session")
    func newestLaunchWins() {
        let now = Date.now
        var older = launchingCard(launchedAt: now.addingTimeInterval(-600))
        older.tmuxLink = TmuxLink(sessionName: "project-older")
        var newer = launchingCard(launchedAt: now.addingTimeInterval(-5))
        newer.tmuxLink = TmuxLink(sessionName: "project-newer")
        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [
                Session(
                    id: "new-session", projectPath: worktree, modifiedTime: now,
                    jsonlPath: "/sessions/new-session.jsonl")
            ]
        )

        let result = CardReconciler.reconcile(existing: [older, newer], snapshot: snapshot)

        #expect(result.first { $0.id == newer.id }?.sessionLink?.sessionId == "new-session")
        #expect(result.first { $0.id == older.id }?.sessionLink == nil)
    }

    @Test("a launch stamp survives a save and load")
    func launchedAtRoundTrips() throws {
        let card = launchingCard(launchedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let restored = try decoder.decode(Link.self, from: encoder.encode(card))

        #expect(restored.launchedAt == card.launchedAt)
    }
}
