import Foundation

/// Moves a Claude Code session .jsonl file from one project folder to another,
/// updating the `cwd` field in all JSONL lines.
/// Mirrors claude-resume's moveSession() logic.
public enum SessionFileMover {

    /// Move a session file to a new project folder.
    /// Returns the new file path.
    public static func moveSession(
        sessionId: String,
        fromPath: String,
        toProjectPath: String
    ) throws -> String {
        let projectsDir = NSHomeDirectory() + "/.claude/projects"
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

        // Remove original (only if different path)
        if fromPath != targetPath {
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
    /// Matches claude-resume's encodeProjectPath(): replaces / with -
    private static func encodeProjectPath(_ projectPath: String) -> String {
        projectPath.replacingOccurrences(of: "/", with: "-")
    }
}
