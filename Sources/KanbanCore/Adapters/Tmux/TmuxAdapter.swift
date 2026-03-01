import Foundation

/// Manages tmux sessions via the tmux CLI.
public final class TmuxAdapter: TmuxManagerPort, @unchecked Sendable {
    private let tmuxPath: String

    public init(tmuxPath: String? = nil) {
        self.tmuxPath = tmuxPath ?? Self.findTmux()
    }

    /// Resolve tmux path: check common locations, fall back to bare "tmux" for PATH lookup.
    private static func findTmux() -> String {
        for candidate in ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return "tmux" // Let the shell resolve it via PATH
    }

    public func listSessions() async throws -> [TmuxSession] {
        let result = try await ShellCommand.run(
            tmuxPath,
            arguments: ["list-sessions", "-F", "#{session_name}\t#{session_path}\t#{session_attached}"]
        )

        // tmux returns exit code 1 with "no server running" when there are no sessions
        guard result.succeeded, !result.stdout.isEmpty else { return [] }

        return result.stdout.components(separatedBy: "\n").compactMap { line -> TmuxSession? in
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 3 else { return nil }
            return TmuxSession(
                name: parts[0],
                path: parts[1],
                attached: parts[2] == "1"
            )
        }
    }

    public func createSession(name: String, path: String, command: String?) async throws {
        // Kill any stale session with the same name first.
        // This handles the case where a card got disconnected from its tmux session
        // (e.g., reconciler cleared the link) but the tmux session is still alive.
        let check = try await ShellCommand.run(tmuxPath, arguments: ["has-session", "-t", name])
        if check.succeeded {
            _ = try? await ShellCommand.run(tmuxPath, arguments: ["kill-session", "-t", name])
        }

        var args = ["new-session", "-d", "-s", name, "-c", path]
        if let command {
            args.append(command)
        }
        let result = try await ShellCommand.run(tmuxPath, arguments: args)
        if !result.succeeded {
            throw TmuxError.createFailed(name: name, message: result.stderr)
        }
    }

    public func killSession(name: String) async throws {
        let result = try await ShellCommand.run(
            tmuxPath,
            arguments: ["kill-session", "-t", name]
        )
        if !result.succeeded {
            throw TmuxError.killFailed(name: name, message: result.stderr)
        }
    }

    public func findSessionForWorktree(
        sessions: [TmuxSession],
        worktreePath: String,
        branch: String?
    ) -> TmuxSession? {
        // Priority 1: Exact path match
        if let match = sessions.first(where: { $0.path == worktreePath }) {
            return match
        }

        // Priority 2: Session name matches directory name
        let dirName = (worktreePath as NSString).lastPathComponent
        if let match = sessions.first(where: { $0.name == dirName }) {
            return match
        }

        // Priority 3: Branch name match
        if let branch {
            if let match = sessions.first(where: { $0.name == branch }) {
                return match
            }

            // Priority 4: Branch with slashes replaced by dashes
            let dashBranch = branch.replacingOccurrences(of: "/", with: "-")
            if dashBranch != branch {
                if let match = sessions.first(where: { $0.name == dashBranch }) {
                    return match
                }
            }
        }

        return nil
    }

    public func isAvailable() async -> Bool {
        await ShellCommand.isAvailable("tmux")
    }
}

public enum TmuxError: Error, LocalizedError {
    case createFailed(name: String, message: String)
    case killFailed(name: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .createFailed(let name, let message): "Failed to create tmux session '\(name)': \(message)"
        case .killFailed(let name, let message): "Failed to kill tmux session '\(name)': \(message)"
        }
    }
}
