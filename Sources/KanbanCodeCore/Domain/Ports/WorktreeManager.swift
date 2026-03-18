import Foundation

/// Port for managing git worktrees.
public protocol WorktreeManagerPort: Sendable {
    /// List all worktrees for a repository.
    func listWorktrees(repoRoot: String) async throws -> [Worktree]

    /// Create a new worktree.
    func createWorktree(repoRoot: String, name: String) async throws -> Worktree

    /// Remove a worktree.
    func removeWorktree(path: String, repoRoot: String?, force: Bool) async throws
}
