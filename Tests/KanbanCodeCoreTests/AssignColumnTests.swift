import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("AssignColumn")
struct AssignColumnTests {

    @Test("Actively working overrides manual column")
    func activelyWorkingOverridesManual() {
        var link = Link(column: .done, sessionLink: SessionLink(sessionId: "s1"))
        link.manualOverrides.column = true
        let col = AssignColumn.assign(link: link, activityState: .activelyWorking)
        #expect(col == .inProgress)
    }

    @Test("Manual column override respected when not actively working")
    func manualOverrideWhenIdle() {
        var link = Link(column: .done, sessionLink: SessionLink(sessionId: "s1"))
        link.manualOverrides.column = true
        let col = AssignColumn.assign(link: link, activityState: .idleWaiting)
        #expect(col == .done)
    }

    @Test("Manually archived + actively working → inProgress (activity overrides archive)")
    func manuallyArchivedButActive() {
        let link = Link(column: .allSessions, manuallyArchived: true, sessionLink: SessionLink(sessionId: "s1"))
        let col = AssignColumn.assign(link: link, activityState: .activelyWorking)
        #expect(col == .inProgress)
    }

    @Test("Manually archived + idle → allSessions (archive still wins when not active)")
    func manuallyArchivedIdle() {
        let link = Link(column: .allSessions, manuallyArchived: true, sessionLink: SessionLink(sessionId: "s1"))
        let col = AssignColumn.assign(link: link, activityState: .idleWaiting)
        #expect(col == .allSessions)
    }

    @Test("All PRs merged → done")
    func allPRsDone() {
        let link = Link(sessionLink: SessionLink(sessionId: "s1"), prLinks: [PRLink(number: 1, status: .merged)])
        let col = AssignColumn.assign(link: link, hasPR: true, allPRsDone: true)
        #expect(col == .done)
    }

    @Test("PR exists + idle → inReview")
    func prExistsIdle() {
        let link = Link(sessionLink: SessionLink(sessionId: "s1"))
        let col = AssignColumn.assign(link: link, activityState: .idleWaiting, hasPR: true)
        #expect(col == .inReview)
    }

    @Test("PR exists + needsAttention → inReview (skips waiting for review workflow)")
    func prExistsNeedsAttention() {
        let link = Link(sessionLink: SessionLink(sessionId: "s1"))
        let col = AssignColumn.assign(link: link, activityState: .needsAttention, hasPR: true)
        #expect(col == .inReview)
    }

    @Test("PR exists + actively working → inProgress (not inReview)")
    func prExistsActive() {
        let link = Link(sessionLink: SessionLink(sessionId: "s1"))
        let col = AssignColumn.assign(link: link, activityState: .activelyWorking, hasPR: true)
        #expect(col == .inProgress)
    }

    @Test("Actively working → inProgress")
    func activelyWorking() {
        let link = Link(sessionLink: SessionLink(sessionId: "s1"))
        let col = AssignColumn.assign(link: link, activityState: .activelyWorking)
        #expect(col == .inProgress)
    }

    @Test("Needs attention → waiting")
    func needsAttention() {
        let link = Link(sessionLink: SessionLink(sessionId: "s1"))
        let col = AssignColumn.assign(link: link, activityState: .needsAttention)
        #expect(col == .waiting)
    }

    @Test("Idle with worktree → waiting (Claude idle, not actively working)")
    func idleWithWorktree() {
        let link = Link(sessionLink: SessionLink(sessionId: "s1"))
        let col = AssignColumn.assign(link: link, activityState: .idleWaiting, hasWorktree: true)
        #expect(col == .waiting)
    }

    @Test("Idle without worktree → waiting")
    func idleNoWorktreeRecent() {
        let link = Link(lastActivity: Date.now.addingTimeInterval(-3600), sessionLink: SessionLink(sessionId: "s1"))
        let col = AssignColumn.assign(link: link, activityState: .idleWaiting)
        #expect(col == .waiting)
    }

    @Test("Idle without worktree, old → waiting (idleWaiting always means waiting)")
    func idleNoWorktreeOld() {
        let link = Link(lastActivity: Date.now.addingTimeInterval(-90000), sessionLink: SessionLink(sessionId: "s1"))
        let col = AssignColumn.assign(link: link, activityState: .idleWaiting)
        #expect(col == .waiting)
    }

    @Test("Ended with worktree → waiting")
    func endedWithWorktree() {
        let link = Link(sessionLink: SessionLink(sessionId: "s1"))
        let col = AssignColumn.assign(link: link, activityState: .ended, hasWorktree: true)
        #expect(col == .waiting)
    }

    @Test("Stale + recent → waiting (falls through to recency check)")
    func staleRecent() {
        let link = Link(lastActivity: Date.now.addingTimeInterval(-3600), sessionLink: SessionLink(sessionId: "s1"))
        let col = AssignColumn.assign(link: link, activityState: .stale)
        #expect(col == .waiting)
    }

    @Test("Stale + old → allSessions")
    func staleOld() {
        let link = Link(lastActivity: Date.now.addingTimeInterval(-90000), sessionLink: SessionLink(sessionId: "s1"))
        let col = AssignColumn.assign(link: link, activityState: .stale)
        #expect(col == .allSessions)
    }

    @Test("Ended without worktree, recent → waiting")
    func endedNoWorktreeRecent() {
        let link = Link(lastActivity: Date.now.addingTimeInterval(-3600), sessionLink: SessionLink(sessionId: "s1"))
        let col = AssignColumn.assign(link: link, activityState: .ended)
        #expect(col == .waiting)
    }

    @Test("Ended without worktree, old → allSessions")
    func endedNoWorktreeOld() {
        let link = Link(lastActivity: Date.now.addingTimeInterval(-90000), sessionLink: SessionLink(sessionId: "s1"))
        let col = AssignColumn.assign(link: link, activityState: .ended)
        #expect(col == .allSessions)
    }

    @Test("GitHub issue without session → backlog")
    func githubIssueBacklog() {
        let link = Link(source: .githubIssue)
        let col = AssignColumn.assign(link: link)
        #expect(col == .backlog)
    }

    @Test("Manual task without session → backlog")
    func manualTaskBacklog() {
        let link = Link(source: .manual)
        let col = AssignColumn.assign(link: link)
        #expect(col == .backlog)
    }

    @Test("Manual task with tmuxLink but no session → inProgress (launching)")
    func manualTaskWithTmuxLinkInProgress() {
        var link = Link(source: .manual)
        link.tmuxLink = TmuxLink(sessionName: "test-project")
        let col = AssignColumn.assign(link: link)
        #expect(col == .inProgress)
    }

    @Test("Manual task without tmuxLink or session → backlog (not launched)")
    func manualTaskWithoutTmuxLinkBacklog() {
        let link = Link(source: .manual)
        let col = AssignColumn.assign(link: link)
        #expect(col == .backlog)
    }

    @Test("No signals → allSessions")
    func noSignals() {
        let link = Link(sessionLink: SessionLink(sessionId: "s1"))
        let col = AssignColumn.assign(link: link)
        #expect(col == .allSessions)
    }

    @Test("Recently active session (within 24h) → waiting (not inProgress)")
    func recentlyActive() {
        let link = Link(lastActivity: Date.now.addingTimeInterval(-3600), sessionLink: SessionLink(sessionId: "s1"))
        let col = AssignColumn.assign(link: link)
        #expect(col == .waiting)
    }

    @Test("Session active 2h ago → waiting")
    func activeToday() {
        let link = Link(lastActivity: Date.now.addingTimeInterval(-7200), sessionLink: SessionLink(sessionId: "s1"))
        let col = AssignColumn.assign(link: link)
        #expect(col == .waiting)
    }

    @Test("Only activelyWorking activity state → inProgress")
    func onlyActivelyWorkingIsInProgress() {
        // Without activityState, recent sessions should NOT be inProgress
        let recentLink = Link(lastActivity: Date.now.addingTimeInterval(-60), sessionLink: SessionLink(sessionId: "s1"))
        let col = AssignColumn.assign(link: recentLink)
        #expect(col == .waiting)

        // With activityState = activelyWorking → inProgress
        let col2 = AssignColumn.assign(link: recentLink, activityState: .activelyWorking)
        #expect(col2 == .inProgress)
    }

    @Test("Archive sets manuallyArchived → allSessions regardless of recency")
    func archivedRecentSession() {
        let link = Link(lastActivity: Date.now.addingTimeInterval(-300), manuallyArchived: true, sessionLink: SessionLink(sessionId: "s1"))
        let col = AssignColumn.assign(link: link)
        #expect(col == .allSessions)
    }

    @Test("Session active 25h ago → allSessions (stale)")
    func staleSession() {
        let link = Link(lastActivity: Date.now.addingTimeInterval(-90000), sessionLink: SessionLink(sessionId: "s1"))
        let col = AssignColumn.assign(link: link)
        #expect(col == .allSessions)
    }

    // MARK: - Fork scenario (user reported "fork → In Progress")

    @Test("Freshly forked card (source=.discovered, recent parent activity, no worktree, no activity state) → waiting")
    func forkedCardLandsInWaiting() {
        // Mirrors what forkCard (ContentView+Launch.swift:441-449) produces:
        // source=.discovered, sessionLink set to the newly-copied jsonl,
        // lastActivity inherited from parent (recent), NO tmux session yet.
        var link = Link(
            name: "parent (fork)",
            projectPath: "/tmp/some-project",
            column: .waiting,
            lastActivity: .now,
            source: .discovered,
            sessionLink: SessionLink(sessionId: "forked-session-id")
        )
        link.manualOverrides = ManualOverrides()
        // No activity state — fork runs before the detector has seen the new session.
        let col = AssignColumn.assign(link: link)
        #expect(col == .waiting, "Fork with recent lastActivity + no worktree should be Waiting, not In Progress")
    }

    @Test("Forked card with inherited worktree → waiting (not inProgress)")
    func forkedCardWithWorktreeLandsInWaiting() {
        // keepWorktree: true path — worktreeLink inherited from parent.
        var link = Link(
            name: "parent (fork)",
            projectPath: "/tmp/some-project",
            column: .waiting,
            lastActivity: .now,
            source: .discovered,
            sessionLink: SessionLink(sessionId: "forked-session-id"),
            worktreeLink: WorktreeLink(path: "/tmp/wt", branch: "feat")
        )
        link.manualOverrides = ManualOverrides()
        let col = AssignColumn.assign(link: link, hasWorktree: true)
        #expect(col == .waiting, "Fork with worktree but no activity should still be Waiting")
    }
}
