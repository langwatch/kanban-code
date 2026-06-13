import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("Card Lifecycle")
struct CardLifecycleTests {

    @Test("Active session moves to inProgress")
    func activeToInProgress() {
        var link = Link(column: .allSessions, sessionLink: SessionLink(sessionId: "s1"))
        UpdateCardColumn.update(link: &link, activityState: .activelyWorking, hasWorktree: false)
        #expect(link.column == .inProgress)
    }

    @Test("Stop with no follow-up moves to waiting")
    func stopToRequiresAttention() {
        var link = Link(column: .inProgress, sessionLink: SessionLink(sessionId: "s1"))
        UpdateCardColumn.update(link: &link, activityState: .needsAttention, hasWorktree: false)
        #expect(link.column == .waiting)
    }

    @Test("PR exists + idle → inReview")
    func prIdleToInReview() {
        var link = Link(
            column: .inProgress,
            sessionLink: SessionLink(sessionId: "s1"),
            worktreeLink: WorktreeLink(path: "", branch: "feature-x"),
            prLinks: [PRLink(number: 42, url: "https://github.com/test/pr/42", status: .approved)]
        )
        UpdateCardColumn.update(link: &link, activityState: .idleWaiting, hasWorktree: true)
        #expect(link.column == .inReview)
    }

    @Test("All PRs merged → done")
    func prMergedToDone() {
        var link = Link(
            column: .inReview,
            sessionLink: SessionLink(sessionId: "s1"),
            prLinks: [PRLink(number: 42, status: .merged)]
        )
        UpdateCardColumn.update(link: &link, activityState: .ended, hasWorktree: false)
        #expect(link.column == .done)
    }

    @Test("Partial PR merge keeps card in review")
    func partialPRMerge() {
        var link = Link(
            column: .inReview,
            sessionLink: SessionLink(sessionId: "s1"),
            prLinks: [
                PRLink(number: 42, status: .merged),
                PRLink(number: 43, status: .approved),
            ]
        )
        UpdateCardColumn.update(link: &link, activityState: .ended, hasWorktree: false)
        #expect(link.column == .inReview)
    }

    @Test("All PRs merged/closed → done")
    func allPRsDone() {
        var link = Link(
            column: .inReview,
            sessionLink: SessionLink(sessionId: "s1"),
            prLinks: [
                PRLink(number: 42, status: .merged),
                PRLink(number: 43, status: .closed),
            ]
        )
        UpdateCardColumn.update(link: &link, activityState: .ended, hasWorktree: false)
        #expect(link.column == .done)
    }

    @Test("Actively working overrides manual column to inProgress")
    func activelyWorkingOverridesManual() {
        var link = Link(column: .done, sessionLink: SessionLink(sessionId: "s1"))
        link.manualOverrides.column = true
        UpdateCardColumn.update(link: &link, activityState: .activelyWorking, hasWorktree: true)
        #expect(link.column == .inProgress)
    }

    @Test("Manual override respected when not actively working")
    func manualOverrideWhenIdle() {
        var link = Link(column: .done, sessionLink: SessionLink(sessionId: "s1"))
        link.manualOverrides.column = true
        UpdateCardColumn.update(link: &link, activityState: .idleWaiting, hasWorktree: true)
        #expect(link.column == .done)
    }

    @Test("Ended session with worktree → allSessions")
    func endedWithWorktree() {
        var link = Link(
            column: .inProgress,
            sessionLink: SessionLink(sessionId: "s1"),
            worktreeLink: WorktreeLink(path: "", branch: "feature-x")
        )
        UpdateCardColumn.update(link: &link, activityState: .ended, hasWorktree: true)
        #expect(link.column == .allSessions)
    }

    @Test("Stale session → allSessions")
    func staleToAllSessions() {
        var link = Link(column: .inProgress, sessionLink: SessionLink(sessionId: "s1"))
        UpdateCardColumn.update(link: &link, activityState: .stale, hasWorktree: false)
        #expect(link.column == .allSessions)
    }

    @Test("Archived card ignores stale active signal without live work")
    func archivedCardIgnoresStaleActiveSignal() {
        var link = Link(column: .allSessions, manuallyArchived: true, sessionLink: SessionLink(sessionId: "s1"))
        UpdateCardColumn.update(link: &link, activityState: .activelyWorking, hasWorktree: false)
        #expect(link.column == .allSessions)
        #expect(link.manuallyArchived == true)
    }

    @Test("Archived card with live work clears manuallyArchived and moves to inProgress")
    func archivedCardRevivedByLiveWork() {
        var link = Link(column: .allSessions, manuallyArchived: true, sessionLink: SessionLink(sessionId: "s1"))
        UpdateCardColumn.update(link: &link, activityState: .activelyWorking, hasWorktree: true)
        #expect(link.column == .inProgress)
        #expect(link.manuallyArchived == false)
    }

    @Test("Archived card stays archived when idle")
    func archivedCardStaysArchived() {
        var link = Link(column: .allSessions, manuallyArchived: true, sessionLink: SessionLink(sessionId: "s1"))
        UpdateCardColumn.update(link: &link, activityState: .idleWaiting, hasWorktree: false)
        #expect(link.column == .allSessions)
        #expect(link.manuallyArchived == true)
    }

    @Test("Revived archived card goes to waiting when work stops")
    func revivedCardGoesToWaiting() {
        var link = Link(column: .allSessions, manuallyArchived: true, sessionLink: SessionLink(sessionId: "s1"))
        // First: actively working clears archive
        UpdateCardColumn.update(link: &link, activityState: .activelyWorking, hasWorktree: true)
        #expect(link.column == .inProgress)
        #expect(link.manuallyArchived == false)
        // Then: work stops → goes to waiting (not back to allSessions)
        UpdateCardColumn.update(link: &link, activityState: .needsAttention, hasWorktree: false)
        #expect(link.column == .waiting)
    }

    @Test("Column doesn't change when state results in same column")
    func noUnnecessaryUpdate() {
        var link = Link(column: .inProgress, sessionLink: SessionLink(sessionId: "s1"))
        let originalUpdatedAt = link.updatedAt
        UpdateCardColumn.update(link: &link, activityState: .activelyWorking, hasWorktree: false)
        // Column is already inProgress, so updatedAt should not change
        #expect(link.updatedAt == originalUpdatedAt)
    }
}
