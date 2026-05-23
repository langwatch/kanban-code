import Testing
@testable import KanbanCode

@Suite("Worktree cleanup eligibility")
struct WorktreeCleanupEligibilityTests {
    @Test("Active card can clean its only active worktree")
    func activeCardCanCleanItsOnlyWorktree() {
        #expect(WorktreeCleanupEligibility.canCleanup(
            branch: "feat/shared",
            cardIsStillActive: true,
            activeBranchCounts: ["feat/shared": 1]
        ))
    }

    @Test("Archived card cannot clean a worktree another active card still uses")
    func archivedCardCannotCleanSharedWorktree() {
        #expect(!WorktreeCleanupEligibility.canCleanup(
            branch: "feat/shared",
            cardIsStillActive: false,
            activeBranchCounts: ["feat/shared": 1]
        ))
    }

    @Test("Archived last card can clean its worktree")
    func archivedLastCardCanCleanWorktree() {
        #expect(WorktreeCleanupEligibility.canCleanup(
            branch: "feat/shared",
            cardIsStillActive: false,
            activeBranchCounts: [:]
        ))
    }
}
