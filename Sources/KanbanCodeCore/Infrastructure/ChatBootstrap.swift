import Foundation

/// One-shot, idempotent bootstrap for the chat channels feature:
///   1. Ensures `~/.kanban-code/channels/` exists.
///   2. Ensures the kanban-code skill is symlinked into `skills/kanban-code` of
///      `~/.claude` and of every other Claude config folder, so newly-launched
///      Claude sessions pick it up.
///
/// Called on app launch. Side-effects are all best-effort — failures are logged,
/// not fatal.
public enum ChatBootstrap {

    public static func run(repoRoot: String? = nil) {
        ensureChannelsDir()
        ensureSkillSymlink(repoRoot: repoRoot)
    }

    private static func ensureChannelsDir() {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let dir = (home as NSString).appendingPathComponent(".kanban-code/channels")
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let dm = (dir as NSString).appendingPathComponent("dm")
            try fm.createDirectory(atPath: dm, withIntermediateDirectories: true)
        } catch {
            KanbanCodeLog.warn("bootstrap", "ensureChannelsDir failed: \(error)")
        }
    }

    /// Links the skill into the `skills/` folder of `~/.claude` and of every
    /// other Claude config folder that exists, so sessions of every account
    /// pick it up. Run again when the accounts change.
    public static func ensureSkillSymlink(repoRoot: String? = nil, layout: ClaudeConfigLayout = ClaudeConfigDirectories.current) {
        let fm = FileManager.default
        var configDirs = [layout.standard]
        var isDir: ObjCBool = false
        for dir in layout.writableDirectories where dir != layout.standard
            && fm.fileExists(atPath: dir, isDirectory: &isDir) && isDir.boolValue {
            configDirs.append(dir)
        }
        let links = configDirs.map { $0 + "/skills/kanban-code" }

        // If every link already resolves to a readable SKILL.md we're done.
        let missing = links.filter { !fm.fileExists(atPath: ($0 as NSString).appendingPathComponent("SKILL.md")) }
        guard !missing.isEmpty else { return }

        // Find source. Priority:
        //   1. Explicit argument.
        //   2. Env var KANBAN_CODE_REPO.
        //   3. Walk up from bundle path looking for Package.swift.
        let src = locateRepoRoot(override: repoRoot)
            .map { (($0 as NSString).appendingPathComponent(".claude/skills/kanban-code")) }

        guard let src, fm.fileExists(atPath: src) else {
            KanbanCodeLog.info("bootstrap", "kanban-code skill source not found; skipping symlink")
            return
        }
        linkSkill(source: src, at: missing)
    }

    static func linkSkill(source src: String, at links: [String]) {
        let fm = FileManager.default
        for link in links {
            do {
                try fm.createDirectory(atPath: (link as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                if (try? fm.destinationOfSymbolicLink(atPath: link)) != nil {
                    // A stale or dangling link of ours.
                    try fm.removeItem(atPath: link)
                } else if fm.fileExists(atPath: link) {
                    // Something of the user's: never removed.
                    KanbanCodeLog.warn("bootstrap", "Not linking the kanban-code skill: \(link) exists and is not a link")
                    continue
                }
                try fm.createSymbolicLink(atPath: link, withDestinationPath: src)
                KanbanCodeLog.info("bootstrap", "Linked kanban-code skill \(link) → \(src)")
            } catch {
                KanbanCodeLog.warn("bootstrap", "ensureSkillSymlink failed for \(link): \(error)")
            }
        }
    }

    private static func locateRepoRoot(override: String?) -> String? {
        if let override, FileManager.default.fileExists(atPath: override) {
            return override
        }
        if let env = ProcessInfo.processInfo.environment["KANBAN_CODE_REPO"],
           FileManager.default.fileExists(atPath: env) {
            return env
        }
        // Walk up from the app bundle looking for Package.swift.
        var path = Bundle.main.bundlePath
        for _ in 0..<8 {
            let candidate = (path as NSString).appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: candidate) { return path }
            let parent = (path as NSString).deletingLastPathComponent
            if parent == path { break }
            path = parent
        }
        // Fallback: check ~/Projects/kanban (common location — CLAUDE.md references it)
        let fallback = (NSHomeDirectory() as NSString).appendingPathComponent("Projects/kanban")
        if FileManager.default.fileExists(atPath: (fallback as NSString).appendingPathComponent("Package.swift")) {
            return fallback
        }
        return nil
    }
}
