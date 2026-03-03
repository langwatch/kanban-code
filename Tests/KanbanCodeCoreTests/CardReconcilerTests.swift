import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("CardReconciler")
struct CardReconcilerTests {

    // MARK: - Session matching

    @Test("New session creates a discovered card")
    func newSessionCreatesCard() {
        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [Session(id: "s1", messageCount: 1, modifiedTime: .now)]
        )
        let result = CardReconciler.reconcile(existing: [], snapshot: snapshot)
        #expect(result.count == 1)
        #expect(result[0].sessionLink?.sessionId == "s1")
        #expect(result[0].source == .discovered)
        #expect(result[0].column == .allSessions)
    }

    @Test("Existing card matched by sessionId is updated, not duplicated")
    func matchBySessionId() {
        let existing = [
            Link(
                column: .inProgress,
                lastActivity: Date.now.addingTimeInterval(-3600),
                sessionLink: SessionLink(sessionId: "s1", sessionPath: "/old/path.jsonl")
            )
        ]
        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [Session(id: "s1", messageCount: 5, modifiedTime: .now, jsonlPath: "/new/path.jsonl")]
        )

        let result = CardReconciler.reconcile(existing: existing, snapshot: snapshot)
        #expect(result.count == 1)
        #expect(result[0].id == existing[0].id) // Same card
        #expect(result[0].sessionLink?.sessionPath == "/new/path.jsonl") // Updated path
    }

    @Test("Session matched to pending card by worktree branch")
    func matchByWorktreeBranch() {
        let existing = [
            Link(
                name: "#42: Fix login",
                projectPath: "/project",
                column: .backlog,
                source: .githubIssue,
                worktreeLink: WorktreeLink(path: "/worktree", branch: "fix-login"),
                issueLink: IssueLink(number: 42)
            )
        ]
        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [Session(id: "s1", projectPath: "/project", gitBranch: "fix-login", messageCount: 1, modifiedTime: .now)]
        )

        let result = CardReconciler.reconcile(existing: existing, snapshot: snapshot)
        #expect(result.count == 1)
        #expect(result[0].id == existing[0].id) // Reused existing card
        #expect(result[0].sessionLink?.sessionId == "s1") // Session linked
        #expect(result[0].issueLink?.number == 42) // Issue still there
        #expect(result[0].name == "#42: Fix login") // Name preserved
    }

    @Test("Session matched to pending card by tmux + project path")
    func matchByTmuxAndProject() {
        let existing = [
            Link(
                name: "My task",
                projectPath: "/project",
                column: .inProgress,
                source: .manual,
                tmuxLink: TmuxLink(sessionName: "my-task")
            )
        ]
        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [Session(id: "s1", projectPath: "/project", messageCount: 1, modifiedTime: .now)]
        )

        let result = CardReconciler.reconcile(existing: existing, snapshot: snapshot)
        #expect(result.count == 1)
        #expect(result[0].id == existing[0].id)
        #expect(result[0].sessionLink?.sessionId == "s1")
        #expect(result[0].name == "My task")
    }

    // MARK: - Triplication bug

    @Test("Manual task + start + session discovery = 1 card (not 3!)")
    func noTriplication() {
        // Step 1: User creates manual task and clicks Start Immediately
        // This creates a card with tmuxLink + worktreeLink, no sessionLink yet
        let manualCard = Link(
            name: "Fix auth bug",
            projectPath: "/project",
            column: .inProgress,
            source: .manual,
            promptBody: "Fix the authentication bug in the login flow",
            tmuxLink: TmuxLink(sessionName: "fix-auth"),
            worktreeLink: WorktreeLink(path: "/project/.claude/worktrees/fix-auth", branch: "fix-auth")
        )

        // Step 2: Session discovery finds the Claude session running in the worktree
        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [
                Session(
                    id: "claude-uuid-123",
                    projectPath: "/project",
                    gitBranch: "fix-auth",
                    messageCount: 10,
                    modifiedTime: .now,
                    jsonlPath: "/path/to/session.jsonl"
                )
            ],
            tmuxSessions: [
                TmuxSession(name: "fix-auth", path: "/project/.claude/worktrees/fix-auth", attached: false)
            ],
            didScanTmux: true
        )

        let result = CardReconciler.reconcile(existing: [manualCard], snapshot: snapshot)

        // Should be exactly 1 card — the manual card, now with a sessionLink attached
        #expect(result.count == 1)
        #expect(result[0].id == manualCard.id)
        #expect(result[0].name == "Fix auth bug")
        #expect(result[0].source == .manual)
        #expect(result[0].sessionLink?.sessionId == "claude-uuid-123")
        #expect(result[0].tmuxLink?.sessionName == "fix-auth")
        #expect(result[0].worktreeLink?.branch == "fix-auth")
    }

    @Test("GitHub issue + start work = 1 card (issue gains sessionLink)")
    func issueGainsSession() {
        let issueCard = Link(
            name: "#123: Fix the bug",
            projectPath: "/project",
            column: .backlog,
            source: .githubIssue,
            tmuxLink: TmuxLink(sessionName: "issue-123"),
            worktreeLink: WorktreeLink(path: "/worktree", branch: "issue-123"),
            issueLink: IssueLink(number: 123, body: "Fix the bug")
        )

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [
                Session(id: "s1", projectPath: "/project", gitBranch: "issue-123", messageCount: 5, modifiedTime: .now)
            ],
            tmuxSessions: [
                TmuxSession(name: "issue-123", path: "/worktree", attached: false)
            ],
            didScanTmux: true
        )

        let result = CardReconciler.reconcile(existing: [issueCard], snapshot: snapshot)
        #expect(result.count == 1)
        #expect(result[0].id == issueCard.id)
        #expect(result[0].sessionLink?.sessionId == "s1")
        #expect(result[0].issueLink?.number == 123)
    }

    // MARK: - Worktree launch integration scenarios
    //
    // These test the complete flow: user launches a task with --worktree,
    // Claude creates worktree + session, reconciler discovers them.

    @Test("Worktree launch: session before executeLaunch links it (reconciler first)")
    func worktreeLaunchReconcilerFirst() {
        // Scenario: reconciler runs BEFORE executeLaunch finishes polling.
        // Card has tmuxLink but no sessionLink yet.
        // Session appears in the worktree directory (different projectPath from card).
        // Worktree also discovered by git worktree list.
        // Should produce 1 card with session + worktree.
        let manualCard = Link(
            name: "Do a thing",
            projectPath: "/project",
            column: .inProgress,
            source: .manual,
            tmuxLink: TmuxLink(sessionName: "project-wt"),
            isLaunching: true
        )

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [
                Session(
                    id: "session-1",
                    projectPath: "/project/.claude/worktrees/jazzy-floating-bird",
                    gitBranch: nil, // not yet available in first few seconds
                    messageCount: 1,
                    modifiedTime: .now,
                    jsonlPath: "/claude/projects/session-1.jsonl"
                )
            ],
            tmuxSessions: [
                TmuxSession(name: "project-wt", path: "/project", attached: false)
            ],
            didScanTmux: true,
            worktrees: [
                "/project": [
                    Worktree(path: "/project/.claude/worktrees/jazzy-floating-bird", branch: "jazzy-floating-bird", isBare: false)
                ]
            ]
        )

        let result = CardReconciler.reconcile(existing: [manualCard], snapshot: snapshot)

        #expect(result.count == 1)
        #expect(result[0].id == manualCard.id)
        #expect(result[0].sessionLink?.sessionId == "session-1")
        #expect(result[0].worktreeLink?.branch == "jazzy-floating-bird")
    }

    @Test("Worktree launch: executeLaunch already linked session (reconciler second)")
    func worktreeLaunchExecuteLaunchFirst() {
        // Scenario: executeLaunch finished polling and already set sessionLink.
        // Card has tmuxLink + sessionLink, but no worktreeLink yet.
        // Reconciler should match by sessionId and set worktreeLink.
        let manualCard = Link(
            name: "Do a thing",
            projectPath: "/project",
            column: .inProgress,
            source: .manual,
            sessionLink: SessionLink(
                sessionId: "session-1",
                sessionPath: "/claude/projects/session-1.jsonl"
            ),
            tmuxLink: TmuxLink(sessionName: "project-wt"),
            isLaunching: true
        )

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [
                Session(
                    id: "session-1",
                    projectPath: "/project/.claude/worktrees/jazzy-floating-bird",
                    gitBranch: nil,
                    messageCount: 1,
                    modifiedTime: .now,
                    jsonlPath: "/claude/projects/session-1.jsonl"
                )
            ],
            tmuxSessions: [
                TmuxSession(name: "project-wt", path: "/project", attached: false)
            ],
            didScanTmux: true,
            worktrees: [
                "/project": [
                    Worktree(path: "/project/.claude/worktrees/jazzy-floating-bird", branch: "jazzy-floating-bird", isBare: false)
                ]
            ]
        )

        let result = CardReconciler.reconcile(existing: [manualCard], snapshot: snapshot)

        #expect(result.count == 1)
        #expect(result[0].id == manualCard.id)
        #expect(result[0].sessionLink?.sessionId == "session-1")
        #expect(result[0].worktreeLink?.branch == "jazzy-floating-bird")
    }

    @Test("Worktree launch: git branch name differs from worktree directory name")
    func worktreeBranchNameDiffersFromDirName() {
        // Claude Code creates worktree dir "hashed-snacking-pony" but git branch
        // is "worktree-hashed-snacking-pony" (prefixed). The reconciler should use
        // the git branch from the snapshot, not the directory name.
        let manualCard = Link(
            name: "Do a thing",
            projectPath: "/project",
            column: .inProgress,
            source: .manual,
            sessionLink: SessionLink(sessionId: "session-1", sessionPath: "/path.jsonl"),
            tmuxLink: TmuxLink(sessionName: "project-wt"),
            isLaunching: true
        )

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [
                Session(
                    id: "session-1",
                    projectPath: "/project/.claude/worktrees/hashed-snacking-pony",
                    gitBranch: nil,
                    messageCount: 1,
                    modifiedTime: .now,
                    jsonlPath: "/path.jsonl"
                )
            ],
            tmuxSessions: [
                TmuxSession(name: "project-wt", path: "/project", attached: false)
            ],
            didScanTmux: true,
            worktrees: [
                "/project": [
                    // Git branch has different name from directory
                    Worktree(path: "/project/.claude/worktrees/hashed-snacking-pony", branch: "worktree-hashed-snacking-pony", isBare: false)
                ]
            ]
        )

        let result = CardReconciler.reconcile(existing: [manualCard], snapshot: snapshot)

        #expect(result.count == 1)
        // Should use git branch name, not directory name
        #expect(result[0].worktreeLink?.branch == "worktree-hashed-snacking-pony")
    }

    @Test("Worktree launch: existing orphans are deduplicated")
    func worktreeOrphanDedup() {
        // Main card has session + worktree. Three orphan cards exist from
        // previous reconciliation runs (concurrent reconciles created them).
        let mainCard = Link(
            name: "Do a thing",
            projectPath: "/project",
            column: .inProgress,
            source: .manual,
            sessionLink: SessionLink(sessionId: "s1", sessionPath: "/path.jsonl"),
            worktreeLink: WorktreeLink(path: "/project/.claude/worktrees/feat-x", branch: "feat-x")
        )
        let orphan1 = Link(
            projectPath: "/project",
            source: .discovered,
            worktreeLink: WorktreeLink(path: "/project/.claude/worktrees/feat-x", branch: "feat-x")
        )
        let orphan2 = Link(
            projectPath: "/project",
            source: .discovered,
            worktreeLink: WorktreeLink(path: "/project/.claude/worktrees/feat-x", branch: "feat-x")
        )
        let orphan3 = Link(
            projectPath: "/project",
            source: .discovered,
            worktreeLink: WorktreeLink(path: "/project/.claude/worktrees/feat-x", branch: "feat-x")
        )

        let snapshot = CardReconciler.DiscoverySnapshot(
            worktrees: [
                "/project": [
                    Worktree(path: "/project/.claude/worktrees/feat-x", branch: "feat-x", isBare: false)
                ]
            ]
        )

        let result = CardReconciler.reconcile(existing: [mainCard, orphan1, orphan2, orphan3], snapshot: snapshot)

        #expect(result.count == 1)
        #expect(result[0].id == mainCard.id, "Should keep the card with sessionLink")
        #expect(result[0].sessionLink?.sessionId == "s1")
        #expect(result[0].worktreeLink?.branch == "feat-x")
    }

    @Test("Worktree launch: second reconcile after first linked session produces 1 card")
    func worktreeSecondReconcileStable() {
        // After the first successful reconcile, the card has session + worktree.
        // Running reconcile again with the same data should NOT create duplicates.
        let linkedCard = Link(
            name: "Do a thing",
            projectPath: "/project",
            column: .inProgress,
            source: .manual,
            sessionLink: SessionLink(sessionId: "session-1", sessionPath: "/path.jsonl"),
            worktreeLink: WorktreeLink(path: "/project/.claude/worktrees/feat-x", branch: "feat-x")
        )

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [
                Session(
                    id: "session-1",
                    projectPath: "/project/.claude/worktrees/feat-x",
                    gitBranch: "feat-x",
                    messageCount: 10,
                    modifiedTime: .now,
                    jsonlPath: "/path.jsonl"
                )
            ],
            tmuxSessions: [
                TmuxSession(name: "project-wt", path: "/project", attached: false)
            ],
            didScanTmux: true,
            worktrees: [
                "/project": [
                    Worktree(path: "/project/.claude/worktrees/feat-x", branch: "feat-x", isBare: false)
                ]
            ]
        )

        // Run reconcile twice
        let result1 = CardReconciler.reconcile(existing: [linkedCard], snapshot: snapshot)
        #expect(result1.count == 1)

        let result2 = CardReconciler.reconcile(existing: result1, snapshot: snapshot)
        #expect(result2.count == 1)
        #expect(result2[0].id == linkedCard.id)
    }

    // MARK: - Worktree handling

    @Test("Orphan worktree creates new card with just worktreeLink")
    func orphanWorktree() {
        let snapshot = CardReconciler.DiscoverySnapshot(
            worktrees: [
                "/project": [
                    Worktree(path: "/project/.worktrees/fix-auth", branch: "fix-auth", isBare: false)
                ]
            ]
        )

        let result = CardReconciler.reconcile(existing: [], snapshot: snapshot)
        #expect(result.count == 1)
        #expect(result[0].worktreeLink?.branch == "fix-auth")
        #expect(result[0].worktreeLink?.path == "/project/.worktrees/fix-auth")
        #expect(result[0].sessionLink == nil)
        #expect(result[0].source == .discovered)
    }

    @Test("Bare worktree is skipped")
    func bareWorktreeSkipped() {
        let snapshot = CardReconciler.DiscoverySnapshot(
            worktrees: [
                "/project": [
                    Worktree(path: "/project", branch: "main", isBare: true)
                ]
            ]
        )

        let result = CardReconciler.reconcile(existing: [], snapshot: snapshot)
        #expect(result.isEmpty)
    }

    @Test("Main branch worktree is skipped")
    func mainBranchSkipped() {
        let snapshot = CardReconciler.DiscoverySnapshot(
            worktrees: [
                "/project": [
                    Worktree(path: "/project/.worktrees/main", branch: "main", isBare: false),
                    Worktree(path: "/project/.worktrees/master", branch: "master", isBare: false),
                ]
            ]
        )

        let result = CardReconciler.reconcile(existing: [], snapshot: snapshot)
        #expect(result.isEmpty)
    }

    @Test("Existing card's worktree path is updated")
    func worktreePathUpdated() {
        let existing = [
            Link(
                column: .inProgress,
                sessionLink: SessionLink(sessionId: "s1"),
                worktreeLink: WorktreeLink(path: "/old/path", branch: "feat-x")
            )
        ]
        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [Session(id: "s1", gitBranch: "feat-x", messageCount: 1, modifiedTime: .now)],
            worktrees: [
                "/project": [
                    Worktree(path: "/new/path", branch: "feat-x", isBare: false)
                ]
            ]
        )

        let result = CardReconciler.reconcile(existing: existing, snapshot: snapshot)
        #expect(result.count == 1)
        #expect(result[0].worktreeLink?.path == "/new/path")
    }

    @Test("Worktree branch updated when Claude switches branch inside worktree")
    func worktreeBranchRefreshed() {
        let existing = [
            Link(
                column: .inProgress,
                sessionLink: SessionLink(sessionId: "s1"),
                worktreeLink: WorktreeLink(path: "/project/.worktrees/feat-original", branch: "feat-original"),
                prLinks: [PRLink(number: 42, url: "https://github.com/test/pr/42", status: .reviewNeeded, title: "Old PR")]
            )
        ]
        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [Session(id: "s1", gitBranch: "feat-original", messageCount: 1, modifiedTime: .now)],
            worktrees: [
                "/project": [
                    // git worktree list --porcelain shows the NEW branch for the same path
                    Worktree(path: "/project/.worktrees/feat-original", branch: "feat-renamed", isBare: false)
                ]
            ]
        )

        let result = CardReconciler.reconcile(existing: existing, snapshot: snapshot)
        #expect(result.count == 1)
        #expect(result[0].worktreeLink?.path == "/project/.worktrees/feat-original")
        #expect(result[0].worktreeLink?.branch == "feat-renamed")
        #expect(result[0].prLinks.isEmpty, "Stale PR from old branch should be cleared")
    }

    // MARK: - PR matching

    @Test("PR linked to card via branch")
    func prLinkedViaBranch() {
        let existing = [
            Link(
                column: .inProgress,
                sessionLink: SessionLink(sessionId: "s1"),
                worktreeLink: WorktreeLink(path: "/wt", branch: "feat-login")
            )
        ]
        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [Session(id: "s1", gitBranch: "feat-login", messageCount: 1, modifiedTime: .now)],
            pullRequests: [
                "feat-login": PullRequest(number: 42, title: "Add login", state: "open", url: "https://github.com/test/pr/42", headRefName: "feat-login")
            ]
        )

        let result = CardReconciler.reconcile(existing: existing, snapshot: snapshot)
        #expect(result.count == 1)
        #expect(result[0].prLink?.number == 42)
    }

    // MARK: - Dead link cleanup

    @Test("Dead tmux link is cleared when tmux was scanned")
    func deadTmuxCleared() {
        let existing = [
            Link(
                column: .inProgress,
                sessionLink: SessionLink(sessionId: "s1"),
                tmuxLink: TmuxLink(sessionName: "dead-session")
            )
        ]
        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [Session(id: "s1", messageCount: 1, modifiedTime: .now)],
            tmuxSessions: [TmuxSession(name: "other-alive", path: "/tmp")], // Tmux scanned, but "dead-session" not in list
            didScanTmux: true
        )

        let result = CardReconciler.reconcile(existing: existing, snapshot: snapshot)
        #expect(result.count == 1)
        #expect(result[0].tmuxLink == nil) // Cleared
        #expect(result[0].sessionLink?.sessionId == "s1") // Session still there
    }

    @Test("Dead tmux cleared even when zero sessions exist (server killed)")
    func deadTmuxClearedAllDead() {
        let existing = [
            Link(
                column: .inProgress,
                tmuxLink: TmuxLink(sessionName: "test", extraSessions: ["test-sh1", "test-sh2"])
            )
        ]
        // Tmux was scanned but found nothing (tmux kill-server)
        let snapshot = CardReconciler.DiscoverySnapshot(
            tmuxSessions: [],
            didScanTmux: true
        )

        let result = CardReconciler.reconcile(existing: existing, snapshot: snapshot)
        #expect(result.count == 1)
        #expect(result[0].tmuxLink == nil) // All cleared
    }

    @Test("Tmux link preserved when tmux not scanned")
    func tmuxLinkPreservedWithoutScan() {
        let existing = [
            Link(
                column: .inProgress,
                sessionLink: SessionLink(sessionId: "s1"),
                tmuxLink: TmuxLink(sessionName: "my-session")
            )
        ]
        // Snapshot with no tmux data = tmux not scanned (e.g. BoardState.refresh())
        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [Session(id: "s1", messageCount: 1, modifiedTime: .now)]
        )

        let result = CardReconciler.reconcile(existing: existing, snapshot: snapshot)
        #expect(result.count == 1)
        #expect(result[0].tmuxLink?.sessionName == "my-session") // NOT cleared
    }

    @Test("Dead worktree link is cleared when worktrees were scanned")
    func deadWorktreeCleared() {
        let existing = [
            Link(
                column: .done,
                worktreeLink: WorktreeLink(path: "/deleted/worktree", branch: "old-branch")
            )
        ]
        let snapshot = CardReconciler.DiscoverySnapshot(
            worktrees: [
                "/project": [
                    // Only a bare worktree exists (won't create orphan card)
                    Worktree(path: "/project", branch: "main", isBare: true)
                ]
            ]
        )

        let result = CardReconciler.reconcile(existing: existing, snapshot: snapshot)
        #expect(result.count == 1)
        #expect(result[0].worktreeLink == nil) // Cleared
    }

    @Test("Manual tmux override is preserved even when tmux is dead")
    func manualTmuxOverridePreserved() {
        var link = Link(
            column: .inProgress,
            tmuxLink: TmuxLink(sessionName: "my-session")
        )
        link.manualOverrides.tmuxSession = true

        let snapshot = CardReconciler.DiscoverySnapshot(
            tmuxSessions: [], // Dead
            didScanTmux: true
        )

        let result = CardReconciler.reconcile(existing: [link], snapshot: snapshot)
        #expect(result.count == 1)
        #expect(result[0].tmuxLink?.sessionName == "my-session") // Preserved
    }

    // MARK: - Multiple sessions

    @Test("Multiple sessions each get their own card")
    func multipleSessions() {
        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [
                Session(id: "s1", messageCount: 1, modifiedTime: .now),
                Session(id: "s2", messageCount: 1, modifiedTime: .now),
                Session(id: "s3", messageCount: 1, modifiedTime: .now),
            ]
        )

        let result = CardReconciler.reconcile(existing: [], snapshot: snapshot)
        #expect(result.count == 3)
        let sessionIds = Set(result.compactMap(\.sessionLink?.sessionId))
        #expect(sessionIds == ["s1", "s2", "s3"])
    }

    @Test("Existing cards without matching sessions are preserved")
    func existingCardsPreserved() {
        let existing = [
            Link(name: "Manual task", column: .backlog, source: .manual),
            Link(name: "Issue", column: .backlog, source: .githubIssue, issueLink: IssueLink(number: 42)),
        ]
        let snapshot = CardReconciler.DiscoverySnapshot() // No sessions

        let result = CardReconciler.reconcile(existing: existing, snapshot: snapshot)
        #expect(result.count == 2)
        #expect(result.contains(where: { $0.name == "Manual task" }))
        #expect(result.contains(where: { $0.name == "Issue" }))
    }

    @Test("No double reconciliation — running twice produces same result")
    func idempotent() {
        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [
                Session(id: "s1", projectPath: "/p", gitBranch: "feat-x", messageCount: 5, modifiedTime: .now)
            ],
            worktrees: [
                "/p": [Worktree(path: "/p/.wt/feat-x", branch: "feat-x", isBare: false)]
            ],
            pullRequests: [
                "feat-x": PullRequest(number: 1, title: "PR", state: "open", url: "url", headRefName: "feat-x")
            ]
        )

        let first = CardReconciler.reconcile(existing: [], snapshot: snapshot)
        let second = CardReconciler.reconcile(existing: first, snapshot: snapshot)

        #expect(first.count == second.count)
        // Same card IDs
        #expect(Set(first.map(\.id)) == Set(second.map(\.id)))
    }

    @Test("Session gitBranch prevents orphan worktree creation")
    func sessionBranchPreventsOrphanWorktree() {
        // Session discovered on branch "feat-x" (no existing card)
        // Worktree also discovered with branch "feat-x"
        // Should produce ONE card with both sessionLink and worktreeLink
        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [
                Session(id: "s1", projectPath: "/project", gitBranch: "feat-x",
                        messageCount: 5, modifiedTime: .now)
            ],
            worktrees: [
                "/project": [
                    Worktree(path: "/project/.worktrees/feat-x", branch: "feat-x", isBare: false)
                ]
            ]
        )

        let result = CardReconciler.reconcile(existing: [], snapshot: snapshot)
        #expect(result.count == 1)
        #expect(result[0].sessionLink?.sessionId == "s1")
        #expect(result[0].worktreeLink?.branch == "feat-x")
        #expect(result[0].worktreeLink?.path == "/project/.worktrees/feat-x")
    }

    @Test("Worktree creates worktreeLink on session card without existing worktreeLink")
    func worktreeCreatesLinkOnSessionCard() {
        // Existing card has session but no worktreeLink
        let existing = [
            Link(
                projectPath: "/project",
                column: .inProgress,
                sessionLink: SessionLink(sessionId: "s1")
            )
        ]
        // Session has gitBranch, worktree exists with same branch
        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [
                Session(id: "s1", gitBranch: "feat-x", messageCount: 5, modifiedTime: .now)
            ],
            worktrees: [
                "/project": [
                    Worktree(path: "/project/.worktrees/feat-x", branch: "feat-x", isBare: false)
                ]
            ]
        )

        let result = CardReconciler.reconcile(existing: existing, snapshot: snapshot)
        #expect(result.count == 1)
        #expect(result[0].worktreeLink?.branch == "feat-x")
        #expect(result[0].worktreeLink?.path == "/project/.worktrees/feat-x")
    }

    @Test("Orphan worktree card gets projectPath from repoRoot")
    func orphanWorktreeGetsProjectPath() {
        let snapshot = CardReconciler.DiscoverySnapshot(
            worktrees: [
                "/Users/me/Projects/langwatch": [
                    Worktree(path: "/Users/me/Projects/langwatch/.worktrees/feat-x", branch: "feat-x", isBare: false)
                ]
            ]
        )

        let result = CardReconciler.reconcile(existing: [], snapshot: snapshot)
        #expect(result.count == 1)
        #expect(result[0].projectPath == "/Users/me/Projects/langwatch")
    }

    // MARK: - Fork regression

    @Test("Forked card (project root) does NOT get worktreeLink re-attached")
    func forkedCardNoWorktreeReattach() {
        // When a card is forked with "project root" option:
        // - manualOverrides.worktreePath = true (user chose "no worktree")
        // - worktreeLink is nil (explicitly removed)
        // - projectPath is the parent repo
        // - sessionLink is set (forked .jsonl)
        //
        // The forked .jsonl still contains cwd pointing to the worktree.
        // Reconciler should NOT re-attach a worktreeLink because manualOverrides.worktreePath is set.
        //
        // The original card still exists and owns the worktree.
        let originalCard = Link(
            projectPath: "/project",
            column: .inProgress,
            source: .manual,
            sessionLink: SessionLink(
                sessionId: "original-session",
                sessionPath: "/claude/projects/original-session.jsonl"
            ),
            worktreeLink: WorktreeLink(path: "/project/.claude/worktrees/jazzy-floating-bird", branch: "jazzy-floating-bird")
        )

        var forkedCard = Link(
            projectPath: "/project",
            column: .inProgress,
            source: .manual,
            sessionLink: SessionLink(
                sessionId: "forked-session-1",
                sessionPath: "/claude/projects/forked-session-1.jsonl"
            )
            // worktreeLink: nil (default) — explicitly no worktree
        )
        forkedCard.manualOverrides.worktreePath = true  // fork from root sets this

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [
                Session(
                    id: "original-session",
                    projectPath: "/project/.claude/worktrees/jazzy-floating-bird",
                    gitBranch: "jazzy-floating-bird",
                    messageCount: 20,
                    modifiedTime: .now,
                    jsonlPath: "/claude/projects/original-session.jsonl"
                ),
                Session(
                    id: "forked-session-1",
                    // Forked .jsonl still has old worktree cwd
                    projectPath: "/project/.claude/worktrees/jazzy-floating-bird",
                    gitBranch: nil,
                    messageCount: 10,
                    modifiedTime: .now,
                    jsonlPath: "/claude/projects/forked-session-1.jsonl"
                )
            ],
            worktrees: [
                "/project": [
                    Worktree(path: "/project/.claude/worktrees/jazzy-floating-bird", branch: "jazzy-floating-bird", isBare: false)
                ]
            ]
        )

        let result = CardReconciler.reconcile(existing: [originalCard, forkedCard], snapshot: snapshot)

        #expect(result.count == 2)
        let forked = result.first(where: { $0.id == forkedCard.id })!
        let original = result.first(where: { $0.id == originalCard.id })!

        #expect(forked.sessionLink?.sessionId == "forked-session-1")
        // Key assertion: worktreeLink must NOT be re-attached to the fork
        #expect(forked.worktreeLink == nil, "Forked card should not get worktreeLink re-attached from session's old cwd")

        // Original card keeps its worktreeLink
        #expect(original.worktreeLink?.branch == "jazzy-floating-bird")
        #expect(original.sessionLink?.sessionId == "original-session")
    }

    @Test("Fork with same worktree KEEPS worktreeLink")
    func forkSameWorktreeKeepsLink() {
        // Fork with keepWorktree: true — no manualOverrides, worktreeLink is copied
        let originalCard = Link(
            projectPath: "/project",
            column: .inProgress,
            source: .manual,
            sessionLink: SessionLink(sessionId: "original", sessionPath: "/p/original.jsonl"),
            worktreeLink: WorktreeLink(path: "/project/.claude/worktrees/feat", branch: "feat")
        )
        let forkedCard = Link(
            projectPath: "/project",
            column: .waiting,
            source: .discovered,
            sessionLink: SessionLink(sessionId: "forked", sessionPath: "/p/forked.jsonl"),
            worktreeLink: WorktreeLink(path: "/project/.claude/worktrees/feat", branch: "feat")
            // manualOverrides.worktreePath is false (default) — fork kept the worktree
        )

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [
                Session(id: "original", projectPath: "/project/.claude/worktrees/feat",
                        gitBranch: "feat", messageCount: 10, modifiedTime: .now,
                        jsonlPath: "/p/original.jsonl"),
                Session(id: "forked", projectPath: "/project/.claude/worktrees/feat",
                        gitBranch: "feat", messageCount: 10, modifiedTime: .now,
                        jsonlPath: "/p/forked.jsonl"),
            ],
            worktrees: ["/project": [
                Worktree(path: "/project/.claude/worktrees/feat", branch: "feat", isBare: false)
            ]]
        )

        let result = CardReconciler.reconcile(existing: [originalCard, forkedCard], snapshot: snapshot)
        let forked = result.first(where: { $0.id == forkedCard.id })!
        #expect(forked.worktreeLink?.branch == "feat", "Fork with same worktree should keep its worktreeLink")
    }

    @Test("Forked card without manualOverride still gets worktreeLink (backwards compat)")
    func discoveredCardGetsWorktree() {
        // A discovered card (not a fork) has no worktreeLink but session is on a branch.
        // manualOverrides.worktreePath is false → reconciler SHOULD set worktreeLink.
        let card = Link(
            projectPath: "/project",
            column: .waiting,
            source: .discovered,
            sessionLink: SessionLink(sessionId: "s1", sessionPath: "/p/s1.jsonl")
            // no worktreeLink, no manualOverrides
        )

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [
                Session(id: "s1", projectPath: "/project", gitBranch: "feat-y",
                        messageCount: 5, modifiedTime: .now, jsonlPath: "/p/s1.jsonl"),
            ],
            worktrees: ["/project": [
                Worktree(path: "/project/.worktrees/feat-y", branch: "feat-y", isBare: false)
            ]]
        )

        let result = CardReconciler.reconcile(existing: [card], snapshot: snapshot)
        #expect(result.count == 1)
        #expect(result[0].worktreeLink?.branch == "feat-y", "Discovered card without override should get worktreeLink")
    }

    @Test("Existing card with worktreeLink gets path updated (not duplicated)")
    func existingWorktreeLinkPathUpdated() {
        let card = Link(
            projectPath: "/project",
            column: .inProgress,
            source: .manual,
            sessionLink: SessionLink(sessionId: "s1", sessionPath: "/p/s1.jsonl"),
            worktreeLink: WorktreeLink(path: "/old/path", branch: "feat-z")
        )

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [
                Session(id: "s1", projectPath: "/project", gitBranch: "feat-z",
                        messageCount: 5, modifiedTime: .now, jsonlPath: "/p/s1.jsonl"),
            ],
            worktrees: ["/project": [
                Worktree(path: "/project/.worktrees/feat-z", branch: "feat-z", isBare: false)
            ]]
        )

        let result = CardReconciler.reconcile(existing: [card], snapshot: snapshot)
        #expect(result.count == 1)
        #expect(result[0].worktreeLink?.branch == "feat-z")
        #expect(result[0].worktreeLink?.path == "/project/.worktrees/feat-z", "Path should be updated to the live worktree path")
    }

    @Test("Forked card (project root) does NOT get PR from session gitBranch")
    func forkedCardNoPRFromSessionBranch() {
        // A forked card with manualOverrides.worktreePath = true should NOT
        // be indexed by the session's baked-in gitBranch. The gitBranch belongs
        // to the parent card's worktree, not this fork.
        var forkedCard = Link(
            projectPath: "/project",
            column: .waiting,
            source: .discovered,
            sessionLink: SessionLink(sessionId: "forked-s1", sessionPath: "/p/forked.jsonl")
            // no worktreeLink — user chose "project root"
        )
        forkedCard.manualOverrides.worktreePath = true

        let originalCard = Link(
            projectPath: "/project",
            column: .inProgress,
            source: .discovered,
            sessionLink: SessionLink(sessionId: "original-s1", sessionPath: "/p/original.jsonl"),
            worktreeLink: WorktreeLink(path: "/project/.claude/worktrees/feat-x", branch: "feat-x")
        )

        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [
                Session(id: "original-s1", projectPath: "/project/.claude/worktrees/feat-x",
                        gitBranch: "feat-x", messageCount: 10, modifiedTime: .now,
                        jsonlPath: "/p/original.jsonl"),
                // Forked session still has the old gitBranch baked in from the parent
                Session(id: "forked-s1", projectPath: "/project",
                        gitBranch: "feat-x", messageCount: 10, modifiedTime: .now,
                        jsonlPath: "/p/forked.jsonl"),
            ],
            worktrees: ["/project": [
                Worktree(path: "/project/.claude/worktrees/feat-x", branch: "feat-x", isBare: false)
            ]],
            pullRequests: ["feat-x": PullRequest(number: 42, title: "Add feat X", state: "open", url: "https://example.com/pr/42", headRefName: "feat-x")]
        )

        let result = CardReconciler.reconcile(existing: [originalCard, forkedCard], snapshot: snapshot)
        let forked = result.first(where: { $0.id == forkedCard.id })!
        let original = result.first(where: { $0.id == originalCard.id })!

        // Fork should NOT get the PR
        #expect(forked.prLinks.isEmpty, "Forked card with worktreePath override should not inherit parent's PR")
        #expect(forked.worktreeLink == nil, "Forked card should still have no worktreeLink")

        // Original card should get the PR
        #expect(original.prLinks.count == 1)
        #expect(original.prLinks[0].number == 42)
    }

    @Test("Project path filled from session when card has none")
    func projectPathFilledFromSession() {
        // Card has tmuxLink + matching project path context (same project)
        let existing = [
            Link(
                projectPath: "/my/project",
                column: .backlog,
                source: .manual,
                tmuxLink: TmuxLink(sessionName: "task-1"),
                worktreeLink: WorktreeLink(path: "/wt", branch: "task-1")
            )
        ]
        let snapshot = CardReconciler.DiscoverySnapshot(
            sessions: [
                Session(id: "s1", projectPath: "/my/project", gitBranch: "task-1", messageCount: 1, modifiedTime: .now)
            ]
        )

        let result = CardReconciler.reconcile(existing: existing, snapshot: snapshot)
        #expect(result.count == 1)
        #expect(result[0].sessionLink?.sessionId == "s1")
        #expect(result[0].projectPath == "/my/project")
    }
}
