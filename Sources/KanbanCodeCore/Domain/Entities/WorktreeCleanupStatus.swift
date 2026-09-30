import Foundation

/// What removing a worktree would throw away, checked just before the cleanup
/// dialog asks. Removal is forced, so uncommitted files and unmerged commits
/// are gone for good once the user confirms.
public struct WorktreeCleanupStatus: Equatable, Sendable {
    public enum MergeState: Equatable, Sendable {
        /// Everything on the worktree's HEAD is already in the base branch,
        /// either as ancestors or as content (squash or rebase merges).
        case merged
        case notMerged
        /// No base branch was found, or git could not answer.
        case unknown
    }

    /// The local branch the worktree was compared against, e.g. `main`.
    public var baseBranch: String?
    public var mergeState: MergeState
    /// Modified, staged and untracked files; nil when git status failed.
    public var uncommittedFileCount: Int?

    public init(baseBranch: String?, mergeState: MergeState, uncommittedFileCount: Int?) {
        self.baseBranch = baseBranch
        self.mergeState = mergeState
        self.uncommittedFileCount = uncommittedFileCount
    }

    /// Removing the worktree loses nothing.
    public var isSafeToRemove: Bool {
        mergeState == .merged && uncommittedFileCount == 0
    }
}
