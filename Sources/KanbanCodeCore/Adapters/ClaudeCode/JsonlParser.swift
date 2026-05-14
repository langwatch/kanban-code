import Foundation

/// Parses Claude Code .jsonl files line-by-line using streaming.
/// Handles arbitrarily large lines (57KB+).
public enum JsonlParser {

    /// Metadata extracted from a session .jsonl file.
    public struct SessionMetadata: Sendable {
        public let sessionId: String
        public var firstPrompt: String?
        public var projectPath: String?
        public var gitBranch: String?
        public var messageCount: Int

        public init(
            sessionId: String,
            firstPrompt: String? = nil,
            projectPath: String? = nil,
            gitBranch: String? = nil,
            messageCount: Int = 0
        ) {
            self.sessionId = sessionId
            self.firstPrompt = firstPrompt
            self.projectPath = projectPath
            self.gitBranch = gitBranch
            self.messageCount = messageCount
        }
    }

    /// Extract session metadata by streaming through the .jsonl file.
    /// Stops early once the first user message is found (for efficiency).
    public static func extractMetadata(from filePath: String) async throws -> SessionMetadata? {
        let sessionId = (filePath as NSString).lastPathComponent.replacingOccurrences(of: ".jsonl", with: "")

        guard FileManager.default.fileExists(atPath: filePath) else { return nil }

        let url = URL(fileURLWithPath: filePath)
        var metadata = SessionMetadata(sessionId: sessionId)
        var foundFirstUserMessage = false

        // Stream line-by-line using FileHandle + AsyncBytes
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        for try await line in handle.bytes.lines {
            guard !line.isEmpty else { continue }

            // Quick pre-filter before JSON parsing
            guard line.contains("\"type\"") else { continue }

            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            guard let type = obj["type"] as? String else { continue }

            // Extract project path from cwd
            if metadata.projectPath == nil, let cwd = obj["cwd"] as? String {
                metadata.projectPath = cwd
            }

            // Extract git branch
            if metadata.gitBranch == nil, let branch = obj["gitBranch"] as? String {
                metadata.gitBranch = branch
            }

            if type == "user" || type == "assistant" {
                metadata.messageCount += 1
            }

            // Extract first user message (skip metadata injected by Claude Code)
            if type == "user" && !foundFirstUserMessage {
                if isMetadataMessage(obj) { continue }
                foundFirstUserMessage = true
                if let text = extractTextContent(from: obj) {
                    metadata.firstPrompt = stripMetadataTags(text)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

            // Stop early — we only need first prompt + enough messages to confirm non-empty
            if metadata.messageCount >= 5 && foundFirstUserMessage {
                break
            }
        }

        guard metadata.messageCount > 0 else { return nil }
        return metadata
    }

    /// Extract text content from a message object.
    static func extractTextContent(from obj: [String: Any]) -> String? {
        guard let message = obj["message"] as? [String: Any],
              let content = message["content"] else {
            return nil
        }

        // Content can be a string or an array of content blocks
        if let text = content as? String {
            return text
        }

        if let blocks = content as? [[String: Any]] {
            let texts = blocks.compactMap { block -> String? in
                guard block["type"] as? String == "text" else { return nil }
                return block["text"] as? String
            }
            let joined = texts.joined(separator: "\n")
            return joined.isEmpty ? nil : joined
        }

        return nil
    }

    /// A branch discovered from scanning a conversation, with the repo it was pushed from.
    public struct DiscoveredBranch: Sendable, Equatable, Hashable {
        public let branch: String
        /// Git repo root where the push happened. nil = same as session's projectPath.
        public let repoPath: String?
    }

    /// Scan a session JSONL for branches that were pushed to a remote.
    /// Looks for git branch activity in Bash tool_use blocks:
    /// `git push`, `git checkout -b`, `git switch -c`, `git worktree add -b`, `git branch <name>`.
    /// Returns deduplicated branches with their repo paths (excluding main/master).
    public static func extractPushedBranches(from filePath: String, startOffset: Int? = nil) async throws -> [DiscoveredBranch] {
        guard FileManager.default.fileExists(atPath: filePath) else { return [] }

        let url = URL(fileURLWithPath: filePath)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        // Seek past already-scanned bytes (incremental scanning).
        // The first partial line after seeking will fail JSON parse and be skipped.
        if let offset = startOffset, offset > 0 {
            handle.seek(toFileOffset: UInt64(offset))
        }

        // Regex: git push [flags...] origin|upstream <branch>
        let pushRegex = /git\s+push\s+(?:-[^\s]+\s+)*(?:origin|upstream)\s+(\S+)/
        // Regex: git checkout -b <branch> or git checkout -B <branch>
        let checkoutBranchRegex = /git\s+checkout\s+-[bB]\s+(\S+)/
        // Regex: git switch -c <branch> or git switch --create <branch>
        let switchCreateRegex = /git\s+switch\s+(?:-c|--create)\s+(\S+)/
        // Regex: git worktree add ... -b <branch>
        let worktreeAddRegex = /git\s+worktree\s+add\s+\S+\s+-b\s+(\S+)/
        // Regex: cd <path> && ... (extract the directory before && chains)
        let cdRegex = /cd\s+([^\s;&]+)\s*&&/
        var branches = Set<DiscoveredBranch>()

        for try await line in handle.bytes.lines {
            guard !line.isEmpty else { continue }

            // Only parse lines that might contain tool_use (Bash commands)
            guard line.contains("\"tool_use\"") else { continue }

            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else {
                continue
            }

            for block in content {
                guard block["type"] as? String == "tool_use",
                      block["name"] as? String == "Bash",
                      let input = block["input"] as? [String: Any],
                      let command = input["command"] as? String else { continue }

                // Extract cd path if present (e.g. "cd /path/to/repo && git push ...")
                var repoPath: String?
                if let cdMatch = command.firstMatch(of: cdRegex) {
                    let path = String(cdMatch.output.1)
                    // Resolve to git root: strip .claude/worktrees/<name> suffix
                    repoPath = resolveGitRoot(path)
                }

                func addBranch(_ branch: String) {
                    if branch != "main" && branch != "master" && !branch.hasPrefix("-") {
                        branches.insert(DiscoveredBranch(branch: branch, repoPath: repoPath))
                    }
                }

                for match in command.matches(of: pushRegex) {
                    addBranch(String(match.output.1))
                }
                for match in command.matches(of: checkoutBranchRegex) {
                    addBranch(String(match.output.1))
                }
                for match in command.matches(of: switchCreateRegex) {
                    addBranch(String(match.output.1))
                }
                for match in command.matches(of: worktreeAddRegex) {
                    addBranch(String(match.output.1))
                }
            }
        }

        return Array(branches).sorted { $0.branch < $1.branch }
    }

    /// Scan a session JSONL bottom-up for the most recently pushed branch.
    /// Reads in reverse chunks and stops at the first match — efficient for large files.
    /// `stopAtOffset` is the lower bound (e.g. a watermark); bytes before it are not scanned.
    public static func extractLatestPushedBranch(
        from filePath: String,
        stopAtOffset: Int = 0
    ) async throws -> DiscoveredBranch? {
        guard FileManager.default.fileExists(atPath: filePath) else { return nil }

        let attrs = try FileManager.default.attributesOfItem(atPath: filePath)
        let fileSize = (attrs[.size] as? Int) ?? 0
        guard fileSize > stopAtOffset else { return nil }

        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: filePath))
        defer { try? handle.close() }

        let pushRegex = /git\s+push\s+(?:-[^\s]+\s+)*(?:origin|upstream)\s+(\S+)/
        let cdRegex = /cd\s+([^\s;&]+)\s*&&/

        let chunkSize = 256 * 1024
        var trailingPartial = "" // start of a line split by the chunk boundary
        var currentEnd = fileSize

        while currentEnd > stopAtOffset {
            let readStart = max(currentEnd - chunkSize, stopAtOffset)
            let readCount = currentEnd - readStart

            handle.seek(toFileOffset: UInt64(readStart))
            guard let chunkData = try? handle.read(upToCount: readCount),
                  var chunkStr = String(data: chunkData, encoding: .utf8) else {
                currentEnd = readStart
                continue
            }

            // The trailing partial is the start of a line whose end was in the next chunk.
            // Appending reconstructs the full line at the boundary.
            chunkStr += trailingPartial

            var lines = chunkStr.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

            // First element may be a partial line (unless we're at the start of the scan range)
            if readStart > stopAtOffset {
                trailingPartial = lines.removeFirst()
            } else {
                trailingPartial = ""
            }

            // Process lines newest-first (reverse order)
            for line in lines.reversed() {
                guard !line.isEmpty, line.contains("\"tool_use\"") else { continue }

                guard let lineData = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      let message = obj["message"] as? [String: Any],
                      let content = message["content"] as? [[String: Any]] else { continue }

                // Scan blocks in reverse too — last tool_use in the message is most recent
                for block in content.reversed() {
                    guard block["type"] as? String == "tool_use",
                          block["name"] as? String == "Bash",
                          let input = block["input"] as? [String: Any],
                          let command = input["command"] as? String else { continue }

                    var repoPath: String?
                    if let cdMatch = command.firstMatch(of: cdRegex) {
                        repoPath = resolveGitRoot(String(cdMatch.output.1))
                    }

                    if let match = command.firstMatch(of: pushRegex) {
                        let branch = String(match.output.1)
                        if branch != "main" && branch != "master" && !branch.hasPrefix("-") {
                            return DiscoveredBranch(branch: branch, repoPath: repoPath)
                        }
                    }
                }
            }

            currentEnd = readStart
        }

        return nil
    }

    /// Resolve a path to its likely git root.
    /// Strips `.claude/worktrees/<name>` suffix since worktrees are inside the repo.
    private static func resolveGitRoot(_ path: String) -> String {
        // Pattern: /repo/.claude/worktrees/<name> or /repo/.worktrees/<name> → /repo
        if let range = path.range(of: "/.claude/worktrees/") ?? path.range(of: "/.worktrees/") {
            return String(path[path.startIndex..<range.lowerBound])
        }
        return path
    }

    // MARK: - Metadata message detection

    /// Known metadata XML tag names injected by Claude Code.
    private static let metadataTagNames = [
        "local-command-caveat",
        "command-name",
        "command-message",
        "command-args",
        "local-command-stdout",
    ]

    /// Regex matching any known metadata XML tag pair (greedy within each pair).
    private nonisolated(unsafe) static let metadataTagRegex: Regex<(Substring, Substring)> = {
        let tagPattern = metadataTagNames.joined(separator: "|")
        return try! Regex("<(\(tagPattern))>[\\s\\S]*?</\\1>")
    }()

    /// True if this user message is purely internal metadata (skip for prompt extraction).
    /// Matches `isMeta: true` messages and messages whose content is entirely metadata tags.
    public static func isMetadataMessage(_ obj: [String: Any]) -> Bool {
        if obj["isMeta"] as? Bool == true { return true }
        guard let text = extractTextContent(from: obj), !text.isEmpty else { return false }
        let stripped = stripMetadataTags(text)
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// True only for `isMeta: true` messages (the `<local-command-caveat>` wrapper).
    /// These are hidden entirely from the History tab.
    public static func isCaveatMessage(_ obj: [String: Any]) -> Bool {
        obj["isMeta"] as? Bool == true
    }

    /// True if this user message contains `<local-command-stdout>` output.
    /// These should be displayed as assistant-style responses.
    public static func isLocalCommandStdout(_ obj: [String: Any]) -> Bool {
        guard let text = extractTextContent(from: obj) else { return false }
        return text.contains("<local-command-stdout>")
    }

    /// Extract command name from `<command-name>/foo</command-name>` → `/foo`.
    public static func parseLocalCommand(_ text: String) -> String? {
        let regex = try! Regex("<command-name>([\\s\\S]*?)</command-name>")
        guard let match = text.firstMatch(of: regex) else { return nil }
        let command = String(match.output[1].substring!)
        return command.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Extract output text from `<local-command-stdout>text</local-command-stdout>`.
    public static func parseLocalCommandStdout(_ text: String) -> String? {
        let regex = try! Regex("<local-command-stdout>([\\s\\S]*?)</local-command-stdout>")
        guard let match = text.firstMatch(of: regex) else { return nil }
        let output = String(match.output[1].substring!)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Remove all known metadata XML tag pairs, returning the remaining text.
    public static func stripMetadataTags(_ text: String) -> String {
        text.replacing(metadataTagRegex, with: "")
    }

    /// Decode a Claude projects directory name to a filesystem path.
    /// e.g., "-Users-rchaves-Projects-remote-langwatch" → "/Users/rchaves/Projects/remote/langwatch"
    public static func decodeDirectoryName(_ name: String) -> String {
        // Replace leading dash with /, then remaining dashes that are path separators
        // The pattern is: dashes are used as path separators
        var result = name
        if result.hasPrefix("-") {
            result = "/" + String(result.dropFirst())
        }
        // Replace dashes that are path separators (between path components)
        // Heuristic: a dash followed by an uppercase letter is a path separator
        // Actually, Claude uses dashes for ALL path separators
        result = result.replacingOccurrences(of: "-", with: "/")
        return result
    }
}
