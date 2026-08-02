import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("Tmux Session Matching")
struct TmuxMatchingTests {
    let adapter = TmuxAdapter()

    let sessions = [
        TmuxSession(name: "langwatch", path: "/Users/test/Projects/langwatch"),
        TmuxSession(name: "feature-auth", path: "/Users/test/Projects/langwatch/.worktrees/feature-auth"),
        TmuxSession(name: "fix-login", path: "/Users/test/Projects/my-app/.worktrees/fix-login"),
        TmuxSession(name: "main-branch", path: "/Users/test/Projects/other"),
    ]

    @Test("Exact path match (highest priority)")
    func exactPathMatch() {
        let match = adapter.findSessionForWorktree(
            sessions: sessions,
            worktreePath: "/Users/test/Projects/langwatch/.worktrees/feature-auth",
            branch: nil
        )
        #expect(match?.name == "feature-auth")
    }

    @Test("Directory name match")
    func directoryNameMatch() {
        let match = adapter.findSessionForWorktree(
            sessions: sessions,
            worktreePath: "/some/other/path/fix-login",
            branch: nil
        )
        #expect(match?.name == "fix-login")
    }

    @Test("Branch name match")
    func branchNameMatch() {
        let match = adapter.findSessionForWorktree(
            sessions: sessions,
            worktreePath: "/completely/different/path",
            branch: "langwatch"
        )
        #expect(match?.name == "langwatch")
    }

    @Test("Branch with slash → dash normalization")
    func branchSlashToDash() {
        let match = adapter.findSessionForWorktree(
            sessions: sessions,
            worktreePath: "/completely/different/path",
            branch: "main/branch"
        )
        #expect(match?.name == "main-branch")
    }

    @Test("No match returns nil")
    func noMatch() {
        let match = adapter.findSessionForWorktree(
            sessions: sessions,
            worktreePath: "/unknown/path",
            branch: "unknown-branch"
        )
        #expect(match == nil)
    }

    @Test("Empty sessions list returns nil")
    func emptySessions() {
        let match = adapter.findSessionForWorktree(
            sessions: [],
            worktreePath: "/some/path",
            branch: "main"
        )
        #expect(match == nil)
    }

    @Test("Path match takes priority over branch match")
    func pathPriority() {
        let sessions = [
            TmuxSession(name: "by-branch", path: "/other/path"),
            TmuxSession(name: "by-path", path: "/exact/path"),
        ]
        let match = adapter.findSessionForWorktree(
            sessions: sessions,
            worktreePath: "/exact/path",
            branch: "by-branch"
        )
        #expect(match?.name == "by-path")
    }

    @Test("A prompt left in the composer is detected as unsent")
    func detectsUnsentPrompt() {
        let pastedChip = """
        ❯ [Pasted text #1 +9 lines]
          ⏵⏵ bypass permissions on (shift+tab to cycle)
        """
        let typedText = "❯ investigate the parser bug"

        #expect(TmuxAdapter.paneHasUnsentPrompt(pastedChip))
        #expect(TmuxAdapter.paneHasUnsentPrompt(typedText))
    }

    @Test("An empty composer reads as sent")
    func detectsSubmittedPrompt() {
        let working = """
        ⏺ I'll say hi to my parent as instructed.

        ✶ Newspapering… (7s · ↓ 157 tokens)
        ❯
          ⏵⏵ bypass permissions on (shift+tab to cycle)
        """

        #expect(!TmuxAdapter.paneHasUnsentPrompt(working))
        #expect(!TmuxAdapter.paneHasUnsentPrompt("rchaves@host project %"))
    }
}
