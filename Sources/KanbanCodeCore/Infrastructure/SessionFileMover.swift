import Foundation

/// Moves a Claude Code session .jsonl file from one project folder to another,
/// pointing the top-level `cwd` field of every JSONL line at the new folder.
/// Mirrors claude-resume's moveSession() logic.
///
/// Transcripts reach hundreds of MB, so the file is never parsed as JSON: a
/// byte scan rewrites the `cwd` values, and a file whose lines already name
/// the new folder is renamed, which is instant on the same filesystem.
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
        try fm.createDirectory(atPath: targetDir, withIntermediateDirectories: true)

        let original = try Data(contentsOf: URL(fileURLWithPath: fromPath), options: .alwaysMapped)
        let rewritten = rewriteCwd(original, to: toProjectPath)

        if fromPath != targetPath {
            if rewritten == nil {
                if fm.fileExists(atPath: targetPath) { try fm.removeItem(atPath: targetPath) }
                try fm.moveItem(atPath: fromPath, toPath: targetPath)
            } else {
                try writeReplacing(rewritten!, at: targetPath, tempDir: targetDir, sessionId: sessionId)
                try? fm.removeItem(atPath: fromPath)
            }
        } else if let rewritten {
            try writeReplacing(rewritten, at: targetPath, tempDir: targetDir, sessionId: sessionId)
        }

        // Best-effort: remove from source sessions-index.json
        let sourceDir = (fromPath as NSString).deletingLastPathComponent
        let sourceIndexPath = sourceDir + "/sessions-index.json"
        if sourceDir != targetDir,
           let indexData = fm.contents(atPath: sourceIndexPath),
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

    /// Writes `data` next to `path` and renames it over `path`, so a reader
    /// never sees half a transcript.
    private static func writeReplacing(_ data: Data, at path: String, tempDir: String, sessionId: String) throws {
        let temp = tempDir + "/." + sessionId + ".jsonl.moving-" + UUID().uuidString.prefix(8)
        try data.write(to: URL(fileURLWithPath: temp))
        if rename(temp, path) != 0 {
            let code = errno
            try? FileManager.default.removeItem(atPath: temp)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
    }

    /// The JSONL bytes with the string value of every top-level `"cwd"` key
    /// set to `path`, or nil when every one already is. Strings, escapes and
    /// nesting are tracked byte by byte, so a `cwd` inside a message or a
    /// nested object is left alone. Each line is scanned on its own.
    public static func rewriteCwd(_ data: Data, to path: String) -> Data? {
        let value = Array(jsonStringLiteral(path).utf8)
        let quote = UInt8(ascii: "\""), backslash = UInt8(ascii: "\\"), newline = UInt8(ascii: "\n")
        let open = [UInt8(ascii: "{"), UInt8(ascii: "[")], close = [UInt8(ascii: "}"), UInt8(ascii: "]")]
        let key = Array("cwd\"".utf8)
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data? in
            let bytes = raw.bindMemory(to: UInt8.self)
            let count = bytes.count
            var out: [UInt8] = []
            var changed = false
            var copiedUpTo = 0
            var depth = 0
            var i = 0
            func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0D }
            /// Index just past the closing quote of the string opening at `start`.
            func endOfString(_ start: Int) -> Int {
                var j = start + 1
                while j < count {
                    let b = bytes[j]
                    if b == backslash { j += 2; continue }
                    if b == quote { return j + 1 }
                    if b == newline { return j }
                    j += 1
                }
                return count
            }
            while i < count {
                let b = bytes[i]
                if b == newline { depth = 0; i += 1; continue }
                if open.contains(b) { depth += 1; i += 1; continue }
                if close.contains(b) { depth -= 1; i += 1; continue }
                guard b == quote else { i += 1; continue }
                let keyEnd = endOfString(i)
                guard depth == 1, keyEnd - i == key.count + 1,
                      (0..<key.count).allSatisfy({ bytes[i + 1 + $0] == key[$0] }) else {
                    i = keyEnd
                    continue
                }
                var j = keyEnd
                while j < count, isSpace(bytes[j]) { j += 1 }
                guard j < count, bytes[j] == UInt8(ascii: ":") else { i = keyEnd; continue }
                j += 1
                while j < count, isSpace(bytes[j]) { j += 1 }
                guard j < count, bytes[j] == quote else { i = j; continue }
                let valueEnd = endOfString(j)
                let current = UnsafeBufferPointer(rebasing: bytes[j..<valueEnd])
                if !current.elementsEqual(value) {
                    if out.isEmpty { out.reserveCapacity(count + 4096) }
                    out.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[copiedUpTo..<j]))
                    out.append(contentsOf: value)
                    copiedUpTo = valueEnd
                    changed = true
                }
                i = valueEnd
            }
            guard changed else { return nil }
            out.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[copiedUpTo..<count]))
            return Data(out)
        }
    }

    /// `s` as a JSON string literal, quotes included, escaped the way
    /// JSON.stringify does (no `\/`).
    private static func jsonStringLiteral(_ s: String) -> String {
        var result = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
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
