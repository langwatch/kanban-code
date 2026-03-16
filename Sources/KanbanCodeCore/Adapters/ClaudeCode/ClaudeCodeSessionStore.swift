import Foundation

/// Implements SessionStore for Claude Code .jsonl files.
public final class ClaudeCodeSessionStore: SessionStore, @unchecked Sendable {

    public init() {}

    public func readTranscript(sessionPath: String) async throws -> [ConversationTurn] {
        try await TranscriptReader.readTurns(from: sessionPath)
    }

    public func forkSession(sessionPath: String, targetDirectory: String? = nil) async throws -> String {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sessionPath) else {
            throw SessionStoreError.fileNotFound(sessionPath)
        }

        let newSessionId = UUID().uuidString.lowercased()
        let dir = targetDirectory ?? (sessionPath as NSString).deletingLastPathComponent
        if let targetDirectory, !fileManager.fileExists(atPath: targetDirectory) {
            try fileManager.createDirectory(atPath: targetDirectory, withIntermediateDirectories: true)
        }
        let newPath = (dir as NSString).appendingPathComponent("\(newSessionId).jsonl")

        // Read, replace session IDs, write
        let url = URL(fileURLWithPath: sessionPath)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let oldSessionId = (sessionPath as NSString).lastPathComponent
            .replacingOccurrences(of: ".jsonl", with: "")

        var lines: [String] = []
        for try await line in handle.bytes.lines {
            let replaced = line.replacingOccurrences(
                of: "\"\(oldSessionId)\"",
                with: "\"\(newSessionId)\""
            )
            lines.append(replaced)
        }

        try lines.joined(separator: "\n").write(
            toFile: newPath, atomically: true, encoding: .utf8
        )

        // Preserve the original file's mtime so the activity detector
        // doesn't treat the fork as "actively working" (10-second window).
        if let attrs = try? fileManager.attributesOfItem(atPath: sessionPath),
           let originalMtime = attrs[.modificationDate] as? Date {
            try? fileManager.setAttributes(
                [.modificationDate: originalMtime],
                ofItemAtPath: newPath
            )
        }

        return newSessionId
    }

    public func writeSession(turns: [ConversationTurn], sessionId: String, projectPath: String?) async throws -> String {
        let base = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects")
        let encodedPath: String
        if let projectPath {
            encodedPath = SessionFileMover.encodeProjectPath(projectPath)
        } else {
            encodedPath = "-unknown"
        }
        let dir = (base as NSString).appendingPathComponent(encodedPath)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let filePath = (dir as NSString).appendingPathComponent("\(sessionId).jsonl")

        var lines: [String] = []
        let isoFormatter = ISO8601DateFormatter()
        var lastUuid = ""

        for turn in turns {
            let uuid = UUID().uuidString.lowercased()
            let timestamp = turn.timestamp ?? isoFormatter.string(from: .now)
            let type = turn.role == "assistant" ? "assistant" : "user"

            var jsonObj: [String: Any] = [
                "type": type,
                "sessionId": sessionId,
                "uuid": uuid,
                "timestamp": timestamp,
                "isSidechain": false,
                "userType": "external"
            ]
            if !lastUuid.isEmpty {
                jsonObj["parentUuid"] = lastUuid
            }
            if let projectPath {
                jsonObj["cwd"] = projectPath
            }

            if turn.role == "assistant" {
                var contentBlocks: [[String: Any]] = []
                // Collect tool calls so we can emit tool_result lines after
                var toolCalls: [(id: String, name: String, resultText: String)] = []

                for block in turn.contentBlocks {
                    switch block.kind {
                    case .text:
                        contentBlocks.append(["type": "text", "text": block.text])
                    case .toolUse(let name, let input, _):
                        let toolId = "toolu_migrated_\(UUID().uuidString.prefix(8))"
                        let claudeName = Self.mapToolName(name)
                        let toolBlock: [String: Any] = [
                            "type": "tool_use",
                            "id": toolId,
                            "name": claudeName,
                            "input": input as [String: Any]
                        ]
                        contentBlocks.append(toolBlock)
                        // Extract result from the block text (after " -> ")
                        let resultText: String
                        if let arrowRange = block.text.range(of: " -> ") {
                            resultText = String(block.text[arrowRange.upperBound...])
                        } else {
                            resultText = "(migrated from another assistant)"
                        }
                        toolCalls.append((id: toolId, name: claudeName, resultText: resultText))
                    case .thinking, .planModeEnter, .planModeExit, .askUserQuestion, .agentCall:
                        break
                    case .toolResult(let toolName, _):
                        // If there's an explicit tool result block, attach it to the last tool call
                        if !toolCalls.isEmpty {
                            toolCalls[toolCalls.count - 1] = (
                                id: toolCalls.last!.id,
                                name: toolCalls.last!.name,
                                resultText: block.text
                            )
                        } else {
                            // Orphan tool result — render as text
                            let label = toolName ?? "tool"
                            contentBlocks.append(["type": "text", "text": "[\(label) result] \(block.text)"])
                        }
                    }
                }
                if contentBlocks.isEmpty {
                    contentBlocks.append(["type": "text", "text": turn.textPreview])
                }

                let hasToolUse = !toolCalls.isEmpty
                let msgId = "msg_migrated_\(UUID().uuidString.prefix(12))"
                var message: [String: Any] = [
                    "id": msgId,
                    "type": "message",
                    "role": "assistant",
                    "content": contentBlocks,
                    "stop_reason": hasToolUse ? "tool_use" : "end_turn",
                    "stop_sequence": NSNull()
                ]
                jsonObj["message"] = message

                if let data = try? JSONSerialization.data(withJSONObject: jsonObj),
                   let line = String(data: data, encoding: .utf8) {
                    lines.append(line)
                }
                lastUuid = uuid

                // Emit tool_result lines (Claude expects a separate user message per tool_use)
                for tc in toolCalls {
                    let resultUuid = UUID().uuidString.lowercased()
                    var resultObj: [String: Any] = [
                        "type": "user",
                        "sessionId": sessionId,
                        "uuid": resultUuid,
                        "parentUuid": lastUuid,
                        "timestamp": timestamp,
                        "isSidechain": false,
                        "userType": "external",
                        "sourceToolAssistantUUID": uuid,
                        "message": [
                            "role": "user",
                            "content": [[
                                "type": "tool_result",
                                "tool_use_id": tc.id,
                                "content": tc.resultText,
                                "is_error": false
                            ] as [String: Any]]
                        ] as [String: Any]
                    ]
                    if let projectPath {
                        resultObj["cwd"] = projectPath
                    }
                    if let data = try? JSONSerialization.data(withJSONObject: resultObj),
                       let line = String(data: data, encoding: .utf8) {
                        lines.append(line)
                    }
                    lastUuid = resultUuid
                }
            } else {
                // User or system message
                let textParts = turn.contentBlocks.compactMap { block -> String? in
                    if case .text = block.kind { return block.text }
                    // Render non-text blocks as text for user messages
                    if case .toolUse(let name, let input, _) = block.kind {
                        let args = input.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
                        return "[\(name)(\(args))] \(block.text)"
                    }
                    return nil
                }
                let text = textParts.isEmpty ? turn.textPreview : textParts.joined(separator: "\n")
                let prefix = turn.role == "system" ? "[system] " : ""
                jsonObj["message"] = ["role": "user", "content": prefix + text] as [String: Any]

                if let data = try? JSONSerialization.data(withJSONObject: jsonObj),
                   let line = String(data: data, encoding: .utf8) {
                    lines.append(line)
                }
                lastUuid = uuid
            }
        }

        let content = lines.joined(separator: "\n") + "\n"
        try content.write(toFile: filePath, atomically: true, encoding: .utf8)
        return filePath
    }

    /// Map tool names from other assistants to Claude Code equivalents.
    private static func mapToolName(_ name: String) -> String {
        switch name.lowercased() {
        case "shell", "run_shell_command", "bash": return "Bash"
        case "readfile", "read_file", "read": return "Read"
        case "writefile", "write_file", "write": return "Write"
        case "editfile", "edit_file", "edit": return "Edit"
        case "glob", "listfiles", "list_files": return "Glob"
        case "grep", "search", "searchfiles": return "Grep"
        default: return name // Keep unknown names as-is, rendered as text fallback
        }
    }

    public func truncateSession(sessionPath: String, afterTurn: ConversationTurn) async throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sessionPath) else {
            throw SessionStoreError.fileNotFound(sessionPath)
        }

        // Backup
        let backupPath = sessionPath + ".bkp"
        try? fileManager.removeItem(atPath: backupPath)
        try fileManager.copyItem(atPath: sessionPath, toPath: backupPath)

        // Read lines up to the target line number
        let url = URL(fileURLWithPath: sessionPath)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var keptLines: [String] = []
        var lineNumber = 0

        for try await line in handle.bytes.lines {
            lineNumber += 1
            keptLines.append(line)
            if lineNumber >= afterTurn.lineNumber {
                break
            }
        }

        try keptLines.joined(separator: "\n").write(
            toFile: sessionPath, atomically: true, encoding: .utf8
        )
    }

    public func searchSessions(query: String, paths: [String]) async throws -> [SearchResult] {
        let box = ResultBox()
        try await searchSessionsStreaming(query: query, paths: paths) { results in
            box.results = results
        }
        return box.results
    }

    /// Thread-safe box to capture streaming results for the batch API.
    private final class ResultBox: @unchecked Sendable {
        var results: [SearchResult] = []
    }

    public func searchSessionsStreaming(
        query: String, paths: [String],
        onResult: @MainActor @Sendable ([SearchResult]) -> Void
    ) async throws {
        let t0 = ContinuousClock.now
        let queryTerms = BM25Scorer.tokenize(query)
        guard !queryTerms.isEmpty else { return }

        struct DocInfo {
            let path: String
            let matchingTokens: [String]
            let wordCount: Int
            let snippets: [String]
            let modifiedTime: Date
        }

        var docs: [DocInfo] = []
        var globalTermFreqs: [String: Int] = [:]
        var totalWordCount = 0

        let fileManager = FileManager.default

        // Filter to existing files and sort by modification time (newest first)
        let validPaths: [(String, Date)] = paths.compactMap { path in
            guard fileManager.fileExists(atPath: path),
                  let attrs = try? fileManager.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date else { return nil }
            return (path, mtime)
        }.sorted { $0.1 > $1.1 }

        KanbanCodeLog.info("search", "searchSessions: \(validPaths.count)/\(paths.count) valid files, terms=\(queryTerms)")

        for (idx, (path, mtime)) in validPaths.enumerated() {
            try Task.checkCancellation()

            let tFile = ContinuousClock.now
            let (matchingTokens, wordCount, snippets) = try await extractMatchingTokens(
                from: path, queryTerms: queryTerms
            )
            let fileName = (path as NSString).lastPathComponent
            if idx < 5 || idx % 20 == 0 {
                let fileSize = (try? fileManager.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
                KanbanCodeLog.info("search", "  [\(idx+1)/\(validPaths.count)] \(fileName) (\(fileSize / 1024)KB) words=\(wordCount) matches=\(matchingTokens.count) \(tFile.duration(to: .now))")
            }
            guard wordCount > 0 else { continue }

            totalWordCount += wordCount

            // Only track and yield when file has matching tokens
            guard !matchingTokens.isEmpty else { continue }

            // Track global document frequencies
            let uniqueTerms = Set(matchingTokens)
            for term in uniqueTerms {
                globalTermFreqs[term, default: 0] += 1
            }

            docs.append(DocInfo(
                path: path,
                matchingTokens: matchingTokens,
                wordCount: wordCount,
                snippets: snippets,
                modifiedTime: mtime
            ))

            // Score all matching docs with running stats and yield immediately
            let avgDocLength = Double(totalWordCount) / max(Double(docs.count), 1.0)
            var results: [SearchResult] = []
            for doc in docs {
                let boost = BM25Scorer.recencyBoost(modifiedTime: doc.modifiedTime)
                let score = BM25Scorer.score(
                    terms: queryTerms,
                    documentTokens: doc.matchingTokens,
                    avgDocLength: avgDocLength,
                    docCount: docs.count,
                    docFreqs: globalTermFreqs,
                    recencyBoost: boost
                )
                if score > 0 {
                    results.append(SearchResult(sessionPath: doc.path, score: score, snippets: doc.snippets))
                }
            }
            results.sort { $0.score > $1.score }
            await onResult(results)
        }

        KanbanCodeLog.info("search", "searchSessions DONE: \(docs.count) docs in \(t0.duration(to: .now))")
    }

    /// Stream through a .jsonl file line-by-line, extracting only tokens that match query terms.
    /// Returns (matchingTokens, totalWordCount, snippets).
    /// Streams via FileHandle — never loads the entire file into memory.
    /// Throws CancellationError if the task is cancelled mid-file.
    private static let maxSnippets = 3

    private func extractMatchingTokens(
        from path: String,
        queryTerms: [String]
    ) async throws -> (tokens: [String], wordCount: Int, snippets: [String]) {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return ([], 0, [])
        }
        defer { try? handle.close() }

        var matchingTokens: [String] = []
        var wordCount = 0
        // Track top snippets sorted by score (number of matching query terms)
        var topSnippets: [(score: Int, text: String)] = []
        var lineCount = 0

        for try await line in handle.bytes.lines {
            // Check cancellation every 100 lines to stay responsive
            lineCount += 1
            if lineCount % 100 == 0 {
                try Task.checkCancellation()
            }

            // Fast string check — skip lines that aren't user/assistant messages
            guard line.contains("\"type\"") else { continue }
            guard line.contains("\"user\"") || line.contains("\"assistant\"") else { continue }

            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = obj["type"] as? String,
                  (type == "user" || type == "assistant"),
                  let text = JsonlParser.extractTextContent(from: obj) else { continue }

            // Tokenize and match — only keep tokens that match query terms
            let docTokens = text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty && $0.count >= 2 }

            wordCount += docTokens.count

            for token in docTokens {
                if let matched = matchQueryTerm(token: token, queryTerms: queryTerms) {
                    matchingTokens.append(matched)
                }
            }

            // Track top snippets by number of matching query terms
            let lower = text.lowercased()
            var snippetScore = 0
            for qt in queryTerms {
                if lower.contains(qt) { snippetScore += 1 }
            }
            if snippetScore > 0 {
                let snippet = extractSnippet(from: text, queryTerms: queryTerms, role: type)
                // Insert if we have room or this scores higher than the worst
                if topSnippets.count < Self.maxSnippets {
                    topSnippets.append((snippetScore, snippet))
                    topSnippets.sort { $0.score > $1.score }
                } else if snippetScore > topSnippets.last!.score {
                    topSnippets[topSnippets.count - 1] = (snippetScore, snippet)
                    topSnippets.sort { $0.score > $1.score }
                }
            }
        }

        return (matchingTokens, wordCount, topSnippets.map(\.text))
    }

    /// Check if a document token matches any query term (exact or prefix match).
    private func matchQueryTerm(token: String, queryTerms: [String]) -> String? {
        for qt in queryTerms {
            if token == qt || token.hasPrefix(qt) || qt.hasPrefix(token) {
                return qt  // normalize to query term for TF counting
            }
        }
        return nil
    }

    /// Extract a snippet around the first query term match in text.
    private func extractSnippet(from text: String, queryTerms: [String], role: String) -> String {
        let lower = text.lowercased()
        for qt in queryTerms {
            if let range = lower.range(of: qt) {
                let idx = lower.distance(from: lower.startIndex, to: range.lowerBound)
                let start = max(0, idx - 40)
                let end = min(text.count, idx + qt.count + 60)
                let startIdx = text.index(text.startIndex, offsetBy: start)
                let endIdx = text.index(text.startIndex, offsetBy: end)
                let prefix = start > 0 ? "..." : ""
                let suffix = end < text.count ? "..." : ""
                let snippet = text[startIdx..<endIdx].replacingOccurrences(of: "\n", with: " ")
                let label = role == "user" ? "You" : "Claude"
                return "\(label): \(prefix)\(snippet)\(suffix)"
            }
        }
        return String(text.prefix(100))
    }
}

public enum SessionStoreError: Error, LocalizedError {
    case fileNotFound(String)
    case writeNotSupported

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path): "Session file not found: \(path)"
        case .writeNotSupported: "This session store does not support writing sessions"
        }
    }
}
