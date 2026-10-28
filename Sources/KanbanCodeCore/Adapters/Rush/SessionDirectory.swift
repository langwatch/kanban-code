import Foundation

/// The working directory of a session, checked before a host starts in it.
/// A worktree deleted under a card leaves rush with a cwd it cannot enter,
/// and rush then fails with `fork/exec <rush>: no such file or directory`.
public enum SessionDirectory {
    public enum Outcome: Equatable, Sendable {
        /// The directory is there.
        case present
        /// The worktree was gone and was added again from its branch.
        case restored(branch: String)
        /// The worktree and its branch are gone; the project root is there.
        case projectRoot(String)
        /// Neither the directory nor a project root it belongs to is there.
        case missing
    }

    /// Whether a rush failure is rush unable to start a process in a
    /// directory that does not exist.
    public static func isMissingCwdError(_ message: String) -> Bool {
        message.contains("fork/exec") && message.contains("no such file or directory")
    }

    /// The error a session whose directory is gone ends with.
    public static func missingMessage(_ dir: String, outcome: Outcome) -> String {
        switch outcome {
        case .projectRoot(let root):
            return "the session's working directory \(dir) no longer exists and its branch is gone too; "
                + "resume the card to continue in the project root \(root)"
        default:
            return "the session's working directory \(dir) no longer exists"
        }
    }

    /// A POSIX shell script that leaves `dir` in place: present, added again
    /// as a worktree of `branch` (the directory's name when nil), or, when
    /// that branch is gone, the project root the worktree belonged to. It
    /// prints one line: `present`, `restored <branch>`, `root <path>` or
    /// `missing`. Without `branch`, the branch git still lists for the
    /// deleted worktree is used, else the directory's name. The project root is `repoRoot`, else the part of `dir`
    /// before `/.claude/worktrees/` or `/.worktrees/`.
    public static func ensureScript(dir: String, branch: String? = nil, repoRoot: String? = nil) -> String {
        """
        dir=\(q(dir)); branch=\(q(branch ?? "")); root=\(q(repoRoot ?? ""))
        if [ -d "$dir" ]; then echo present; exit 0; fi
        if [ -z "$root" ]; then
          r="${dir%/.claude/worktrees/*}"
          [ "$r" = "$dir" ] && r="${dir%/.worktrees/*}"
          [ "$r" != "$dir" ] && root="$r"
        fi
        if [ -n "$root" ] && [ -d "$root" ] && git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
          if [ -z "$branch" ]; then
            branch=$(git -C "$root" worktree list --porcelain 2>/dev/null | awk -v t="${dir#"$root"}" '$1=="worktree"{w=substr($0,10)} $1=="branch"&&substr(w,length(w)-length(t)+1)==t{sub("refs/heads/","",$2); print $2; exit}')
          fi
          [ -z "$branch" ] && branch="${dir##*/}"
          git -C "$root" worktree prune >/dev/null 2>&1
          mkdir -p "${dir%/*}"
          if git -C "$root" show-ref --verify --quiet "refs/heads/$branch"; then
            git -C "$root" worktree add "$dir" "$branch" >/dev/null 2>&1 && { echo "restored $branch"; exit 0; }
          elif git -C "$root" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
            git -C "$root" worktree add --track -b "$branch" "$dir" "origin/$branch" >/dev/null 2>&1 && { echo "restored $branch"; exit 0; }
          fi
          echo "root $root"; exit 0
        fi
        echo missing
        """
    }

    public static func parse(_ output: String) -> Outcome {
        let line = output.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        if line == "present" { return .present }
        if line.hasPrefix("restored ") { return .restored(branch: String(line.dropFirst("restored ".count))) }
        if line.hasPrefix("root ") { return .projectRoot(String(line.dropFirst("root ".count))) }
        return .missing
    }

    /// Runs `ensureScript` on this machine.
    public static func ensureLocal(dir: String, branch: String? = nil, repoRoot: String? = nil) async -> Outcome {
        if FileManager.default.fileExists(atPath: dir) { return .present }
        let script = ensureScript(dir: dir, branch: branch, repoRoot: repoRoot)
        guard let result = try? await ShellCommand.run("/bin/sh", arguments: ["-c", script], timeout: 120) else {
            return .missing
        }
        let outcome = parse(result.stdout)
        log(dir: dir, outcome: outcome)
        return outcome
    }

    static func log(dir: String, outcome: Outcome) {
        switch outcome {
        case .present: break
        case .restored(let branch):
            KanbanCodeLog.warn("worktree", "Worktree \(dir) was gone; added it again from branch \(branch)")
        case .projectRoot(let root):
            KanbanCodeLog.warn("worktree", "Worktree \(dir) is gone and so is its branch; the session continues in \(root)")
        case .missing:
            KanbanCodeLog.warn("worktree", "Working directory \(dir) is gone and no project root was found for it")
        }
    }

    private static func q(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
