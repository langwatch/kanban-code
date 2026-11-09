import Foundation

/// Moves a Claude Code session .jsonl file from one project folder to another,
/// updating the `cwd` field in all JSONL lines.
/// Mirrors claude-resume's moveSession() logic.
public enum SessionFileMover {

    /// The `projects/` folder a transcript (`<config>/projects/<key>/<id>.jsonl`)
    /// is in, or `~/.claude`'s when the path has another shape (as
    /// `MasterPlatform.claudeProjectsDirectory`).
    public static func projectsDirectory(
        of transcriptPath: String,
        layout: ClaudeConfigLayout = ClaudeConfigDirectories.current
    ) -> String {
        if let known = layout.projectsDirectory(containingSession: transcriptPath) { return known }
        let projects = ((transcriptPath as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        if (projects as NSString).lastPathComponent == "projects" { return projects }
        return layout.standard + "/projects"
    }

    /// Move a session file to a new project folder of the same Claude config
    /// folder: `claude --resume` finds a session only in the folder it runs
    /// with. Returns the new file path.
    /// `projectsDirectory`: where to move it, by default the `projects/`
    /// folder it is in.
    public static func moveSession(
        sessionId: String,
        fromPath: String,
        toProjectPath: String,
        projectsDirectory: String? = nil
    ) throws -> String {
        let projectsDir = projectsDirectory ?? Self.projectsDirectory(of: fromPath)
        let targetDirName = encodeProjectPath(toProjectPath)
        let targetDir = projectsDir + "/" + targetDirName
        let targetPath = targetDir + "/" + sessionId + ".jsonl"

        let fm = FileManager.default

        // Create target directory if needed
        try fm.createDirectory(atPath: targetDir, withIntermediateDirectories: true)

        // Read original file
        let content = try String(contentsOfFile: fromPath, encoding: .utf8)
        let lines = content.components(separatedBy: "\n")

        // Update cwd in all lines
        var newLines: [String] = []
        for line in lines {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else {
                newLines.append(line)
                continue
            }
            guard let data = line.data(using: .utf8),
                  var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                newLines.append(line)
                continue
            }
            if obj["cwd"] != nil {
                obj["cwd"] = toProjectPath
            }
            if let updated = try? JSONSerialization.data(withJSONObject: obj),
               let updatedLine = String(data: updated, encoding: .utf8) {
                newLines.append(updatedLine)
            } else {
                newLines.append(line)
            }
        }

        // Write to new location
        let newContent = newLines.joined(separator: "\n")
        try newContent.write(toFile: targetPath, atomically: true, encoding: .utf8)

        // Remove original (only if another file: one spelled through a
        // symlink is the same file, just rewritten)
        if fromPath != targetPath, ClaudeConfigLayout.resolve(fromPath) != ClaudeConfigLayout.resolve(targetPath) {
            try? fm.removeItem(atPath: fromPath)
        }

        // Best-effort: remove from source sessions-index.json
        let sourceDir = (fromPath as NSString).deletingLastPathComponent
        let sourceIndexPath = sourceDir + "/sessions-index.json"
        if let indexData = fm.contents(atPath: sourceIndexPath),
           var index = try? JSONSerialization.jsonObject(with: indexData) as? [String: Any],
           var entries = index["entries"] as? [[String: Any]] {
            entries.removeAll { ($0["sessionId"] as? String) == sessionId }
            index["entries"] = entries
            if let updated = try? JSONSerialization.data(withJSONObject: index, options: .prettyPrinted) {
                try? updated.write(to: URL(fileURLWithPath: sourceIndexPath))
            }
        }

        return targetPath
    }

    /// Encode a project path for use as a directory name.
    /// Matches Claude CLI's encoding: resolves symlinks, then replaces / with
    /// - and . with -.
    /// Example: /Users/foo/.claude/worktrees/bar → -Users-foo--claude-worktrees-bar
    ///
    /// The symlink step matters: Claude resolves the working directory before
    /// encoding it, so a session started in a symlinked project lives under
    /// the real path's folder. Encoding the symlink instead puts the file
    /// somewhere Claude never looks and `--resume` reports "No conversation
    /// found". Visible in the wild as `/tmp` paths encoded as `-private-tmp-…`.
    public static func encodeProjectPath(_ projectPath: String) -> String {
        resolveSymlinks(projectPath)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    /// Real path for a project directory, or the input when it can't be
    /// resolved (path doesn't exist yet, permissions). Only the existing
    /// prefix is resolved, so paths for not-yet-created worktrees still
    /// resolve their parent symlinks.
    public static func resolveSymlinks(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        var components = (path as NSString).pathComponents
        var suffix: [String] = []
        while !components.isEmpty {
            let candidate = NSString.path(withComponents: components)
            if FileManager.default.fileExists(atPath: candidate) {
                let resolved = (candidate as NSString).resolvingSymlinksInPath
                return suffix.isEmpty
                    ? resolved
                    : NSString.path(withComponents: [resolved] + suffix)
            }
            suffix.insert(components.removeLast(), at: 0)
        }
        return path
    }
}
