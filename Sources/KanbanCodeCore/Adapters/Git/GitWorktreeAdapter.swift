import Foundation

/// Manages git worktrees via the git CLI.
public final class GitWorktreeAdapter: WorktreeManagerPort, @unchecked Sendable {
    private let gitPath: String

    public init(gitPath: String? = nil) {
        self.gitPath = gitPath ?? ShellCommand.findExecutable("git") ?? "/usr/bin/git"
    }

    public func listWorktrees(repoRoot: String) async throws -> [Worktree] {
        let result = try await ShellCommand.run(
            gitPath,
            arguments: ["worktree", "list", "--porcelain"],
            currentDirectory: repoRoot
        )

        guard result.succeeded else { return [] }

        return parseWorktreeList(result.stdout)
    }

    public func createWorktree(repoRoot: String, name: String) async throws -> Worktree {
        let worktreePath = (repoRoot as NSString).appendingPathComponent(".worktrees/\(name)")
        let result = try await ShellCommand.run(
            gitPath,
            arguments: ["worktree", "add", "-b", name, worktreePath],
            currentDirectory: repoRoot
        )
        if !result.succeeded {
            throw WorktreeError.createFailed(name: name, message: result.stderr)
        }
        return Worktree(path: worktreePath, branch: name)
    }

    public func removeWorktree(path: String, repoRoot: String? = nil, force: Bool) async throws {
        var args = ["worktree", "remove"]
        if force { args.append("--force") }
        args.append(path)

        // Use provided repoRoot, or derive from worktree path as fallback
        let effectiveRoot: String?
        if let repoRoot {
            effectiveRoot = repoRoot
        } else if let range = path.range(of: "/.claude/worktrees/") {
            effectiveRoot = String(path[..<range.lowerBound])
        } else {
            effectiveRoot = (path as NSString).deletingLastPathComponent
        }

        let result = try await ShellCommand.run(gitPath, arguments: args, currentDirectory: effectiveRoot)
        if !result.succeeded {
            throw WorktreeError.removeFailed(path: path, message: result.stderr)
        }
    }

    /// Whether the worktree at `path` holds anything a forced removal would
    /// lose: uncommitted files, or commits its base branch does not have.
    /// Returns nil when the path is not a git worktree on this Mac.
    public func cleanupStatus(worktreePath path: String) async -> WorktreeCleanupStatus? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        guard let status = try? await git(["status", "--porcelain"], in: path),
              status.succeeded else { return nil }
        let uncommitted = status.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .count

        guard let base = await baseBranch(in: path) else {
            return WorktreeCleanupStatus(baseBranch: nil, mergeState: .unknown, uncommittedFileCount: uncommitted)
        }
        let merged = await isMerged(head: "HEAD", into: base, in: path)
        return WorktreeCleanupStatus(baseBranch: base, mergeState: merged, uncommittedFileCount: uncommitted)
    }

    /// The local branch work lands on: whatever origin/HEAD points at, else
    /// `main` or `master` if one exists.
    func baseBranch(in path: String) async -> String? {
        if let result = try? await git(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], in: path),
           result.succeeded {
            let remoteRef = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let local = remoteRef.hasPrefix("origin/") ? String(remoteRef.dropFirst("origin/".count)) : remoteRef
            if !local.isEmpty, await refExists("refs/heads/\(local)", in: path) {
                return local
            }
        }
        for candidate in ["main", "master"] where await refExists("refs/heads/\(candidate)", in: path) {
            return candidate
        }
        return nil
    }

    /// A plain merge leaves HEAD an ancestor of the base. A squash or rebase
    /// merge does not, so the fallback asks whether merging HEAD into the base
    /// would change the base's tree at all.
    func isMerged(head: String, into base: String, in path: String) async -> WorktreeCleanupStatus.MergeState {
        guard let ancestor = try? await git(["merge-base", "--is-ancestor", head, base], in: path) else {
            return .unknown
        }
        // Exit 0 = ancestor, 1 = not an ancestor, anything else = error.
        if ancestor.exitCode == 0 { return .merged }
        guard ancestor.exitCode == 1 else { return .unknown }

        guard let merge = try? await git(["merge-tree", "--write-tree", base, head], in: path),
              let baseTree = try? await git(["rev-parse", "\(base)^{tree}"], in: path),
              baseTree.succeeded else { return .notMerged }
        // A conflicting merge exits 1 and cannot be the base unchanged.
        guard merge.exitCode == 0 else { return .notMerged }
        let mergedTree = merge.stdout.split(separator: "\n").first.map(String.init)
        let unchanged = mergedTree == baseTree.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return unchanged ? .merged : .notMerged
    }

    private func refExists(_ ref: String, in path: String) async -> Bool {
        (try? await git(["show-ref", "--verify", "--quiet", ref], in: path))?.succeeded == true
    }

    private func git(_ arguments: [String], in path: String) async throws -> ShellCommand.Result {
        try await ShellCommand.run(gitPath, arguments: arguments, currentDirectory: path, timeout: 30)
    }

    /// Parse `git worktree list --porcelain` output.
    func parseWorktreeList(_ output: String) -> [Worktree] {
        guard !output.isEmpty else { return [] }

        var worktrees: [Worktree] = []
        var currentPath: String?
        var currentBranch: String?
        var isBare = false

        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("worktree ") {
                // Save previous worktree if any
                if let path = currentPath {
                    worktrees.append(Worktree(path: path, branch: currentBranch, isBare: isBare))
                }
                currentPath = String(line.dropFirst("worktree ".count))
                currentBranch = nil
                isBare = false
            } else if line.hasPrefix("branch refs/heads/") {
                currentBranch = String(line.dropFirst("branch refs/heads/".count))
            } else if line == "bare" {
                isBare = true
            }
        }

        // Save last worktree
        if let path = currentPath {
            worktrees.append(Worktree(path: path, branch: currentBranch, isBare: isBare))
        }

        return worktrees
    }
}

public enum WorktreeError: Error, LocalizedError {
    case createFailed(name: String, message: String)
    case removeFailed(path: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .createFailed(let name, let message): "Failed to create worktree '\(name)': \(message)"
        case .removeFailed(let path, let message): "Failed to remove worktree '\(path)': \(message)"
        }
    }
}
