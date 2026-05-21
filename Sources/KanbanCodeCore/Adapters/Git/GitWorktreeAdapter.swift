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
        } else if let range = path.range(of: "/.worktrees/") {
            effectiveRoot = String(path[..<range.lowerBound])
        } else {
            effectiveRoot = (path as NSString).deletingLastPathComponent
        }

        let result = try await ShellCommand.run(gitPath, arguments: args, currentDirectory: effectiveRoot)
        if !result.succeeded {
            throw WorktreeError.removeFailed(path: path, message: result.stderr)
        }
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
