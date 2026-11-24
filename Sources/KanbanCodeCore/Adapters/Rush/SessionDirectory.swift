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
        /// The worktree and its branch were gone, locally and on origin; the
        /// branch was made again from `base` at the same path.
        case created(branch: String, base: String)
        /// The worktree is gone and git refused to add it again.
        case failed(String)
        /// Neither the directory nor a project root it belongs to is there.
        case missing
    }

    /// The branch a card records for a worktree path, for the callers that
    /// only know a session's cwd. Set by the master that owns the cards.
    public static var branchHint: (@Sendable (String) async -> String?)? {
        get { hintLock.withLock { hint } }
        set { hintLock.withLock { hint = newValue } }
    }
    private nonisolated(unsafe) static var hint: (@Sendable (String) async -> String?)?
    private static let hintLock = NSLock()

    /// Whether a rush failure is rush unable to start a process in a
    /// directory that does not exist.
    public static func isMissingCwdError(_ message: String) -> Bool {
        message.contains("fork/exec") && message.contains("no such file or directory")
    }

    /// The error a session whose directory is gone ends with.
    public static func missingMessage(_ dir: String, outcome: Outcome) -> String {
        switch outcome {
        case .failed(let reason):
            return "the session's working directory \(dir) no longer exists and git could not add the worktree again: \(reason)"
        default:
            return "the session's working directory \(dir) no longer exists"
        }
    }

    /// Whether the directory is there after `ensure`.
    public static func isUsable(_ outcome: Outcome) -> Bool {
        switch outcome {
        case .present, .restored, .created: true
        case .failed, .missing: false
        }
    }

    /// A POSIX shell script that puts the worktree `dir` back in place. It
    /// prints one line: `present`, `restored <branch>`, `created <branch>
    /// <base>`, `failed <git error>` or `missing`.
    ///
    /// The branch is `branch`, else the one git still lists for the deleted
    /// worktree, else a local or origin branch whose name with `/` as `-` is
    /// the directory's name (or `worktree-<name>`), else the directory's
    /// name. After a `git worktree prune` it is added from the local branch,
    /// else from `origin/<branch>` (fetched first), else made from the
    /// latest origin default branch. The project root is `repoRoot`, else
    /// the part of `dir` before `/.claude/worktrees/` or `/.worktrees/`.
    public static func ensureScript(dir: String, branch: String? = nil, repoRoot: String? = nil) -> String {
        """
        dir=\(q(dir)); branch=\(q(branch ?? "")); root=\(q(repoRoot ?? ""))
        if [ -d "$dir" ]; then echo present; exit 0; fi
        if [ -z "$root" ]; then
          r="${dir%/.claude/worktrees/*}"
          [ "$r" = "$dir" ] && r="${dir%/.worktrees/*}"
          [ "$r" != "$dir" ] && root="$r"
        fi
        if [ -z "$root" ] || [ ! -d "$root" ] || ! git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then echo missing; exit 0; fi
        g() { git -C "$root" "$@"; }
        name="${dir##*/}"
        if [ -z "$branch" ]; then
          branch=$(g worktree list --porcelain 2>/dev/null | awk -v t="${dir#"$root"}" '$1=="worktree"{w=substr($0,10)} $1=="branch"&&substr(w,length(w)-length(t)+1)==t{sub("refs/heads/","",$2); print $2; exit}')
        fi
        if [ -z "$branch" ]; then
          branch=$(g for-each-ref --format='%(refname)' refs/heads refs/remotes/origin 2>/dev/null | sed -e 's#^refs/heads/##' -e 's#^refs/remotes/origin/##' | awk -v n="$name" '$0!="HEAD"{s=$0; gsub("/","-",s); if (s==n || s=="worktree-" n) {print $0; exit}}')
        fi
        [ -z "$branch" ] && branch="$name"
        g worktree prune >/dev/null 2>&1
        mkdir -p "${dir%/*}"
        oneline() { printf '%s' "$1" | tr '\\n' ' '; }
        if g show-ref --verify --quiet "refs/heads/$branch"; then
          out=$(g worktree add "$dir" "$branch" 2>&1) && { echo "restored $branch"; exit 0; }
          echo "failed $(oneline "$out")"; exit 0
        fi
        g fetch -q origin "+refs/heads/$branch:refs/remotes/origin/$branch" >/dev/null 2>&1
        if g show-ref --verify --quiet "refs/remotes/origin/$branch"; then
          out=$(g worktree add --track -b "$branch" "$dir" "origin/$branch" 2>&1) && { echo "restored $branch"; exit 0; }
          echo "failed $(oneline "$out")"; exit 0
        fi
        g fetch -q origin >/dev/null 2>&1
        base=$(g symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)
        for c in "$base" origin/main origin/master main master HEAD; do
          [ -n "$c" ] && g rev-parse --verify --quiet "$c^{commit}" >/dev/null 2>&1 && { base="$c"; break; }
        done
        out=$(g worktree add --no-track -b "$branch" "$dir" "$base" 2>&1) && { echo "created $branch $base"; exit 0; }
        echo "failed $(oneline "$out")"
        """
    }

    public static func parse(_ output: String) -> Outcome {
        let line = output.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        if line == "present" { return .present }
        if line.hasPrefix("restored ") { return .restored(branch: String(line.dropFirst("restored ".count))) }
        if line.hasPrefix("created ") {
            let parts = line.dropFirst("created ".count).split(separator: " ", maxSplits: 1).map(String.init)
            return .created(branch: parts.first ?? "", base: parts.count > 1 ? parts[1] : "")
        }
        if line.hasPrefix("failed ") { return .failed(String(line.dropFirst("failed ".count))) }
        return .missing
    }

    /// Runs `ensureScript` on this machine.
    public static func ensureLocal(dir: String, branch: String? = nil, repoRoot: String? = nil) async -> Outcome {
        if FileManager.default.fileExists(atPath: dir) { return .present }
        var known = branch
        if known == nil { known = await branchHint?(dir) }
        let script = ensureScript(dir: dir, branch: known, repoRoot: repoRoot)
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
        case .created(let branch, let base):
            KanbanCodeLog.warn("worktree", "Worktree \(dir) and its branch were gone; made branch \(branch) again from \(base)")
        case .failed(let reason):
            KanbanCodeLog.warn("worktree", "Worktree \(dir) is gone and could not be added again: \(reason)")
        case .missing:
            KanbanCodeLog.warn("worktree", "Working directory \(dir) is gone and no project root was found for it")
        }
    }

    private static func q(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// A card's working directory is gone and could not be put back.
public struct SessionDirectoryUnavailable: Error, LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}
