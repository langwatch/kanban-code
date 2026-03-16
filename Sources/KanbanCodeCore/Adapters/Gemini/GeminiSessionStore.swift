import Foundation

/// Implements SessionStore for Gemini CLI JSON session files.
public final class GeminiSessionStore: SessionStore, @unchecked Sendable {

    public init() {}

    // MARK: - SessionStore

    public func readTranscript(sessionPath: String) async throws -> [ConversationTurn] {
        guard FileManager.default.fileExists(atPath: sessionPath) else {
            throw SessionStoreError.fileNotFound(sessionPath)
        }

        guard let session = try GeminiSessionParser.parseSession(from: sessionPath) else {
            return []
        }

        var turns: [ConversationTurn] = []
        var turnIndex = 0

        for (messageIndex, message) in session.messages.enumerated() {
            let role: String
            switch message.type {
            case "user":
                role = "user"
            case "gemini":
                role = "assistant"
            case "info", "error":
                role = "system"
            default:
                continue
            }

            var blocks: [ContentBlock] = []

            // Main content
            let textContent = message.content.textValue
            if !textContent.isEmpty {
                blocks.append(ContentBlock(kind: .text, text: textContent))
            }

            // Thinking/reasoning blocks
            if let thoughts = message.thoughts {
                for thought in thoughts {
                    if let text = thought.text, !text.isEmpty {
                        blocks.append(ContentBlock(
                            kind: .thinking,
                            text: String(text.prefix(500))
                        ))
                    }
                }
            }

            // Tool calls
            if let toolCalls = message.toolCalls {
                for call in toolCalls {
                    let name = call.displayName ?? call.name ?? "unknown"
                    let inputMap = call.args ?? [:]
                    let description = call.description ?? name
                    let resultPreview: String
                    if let result = call.result {
                        let lines = result.components(separatedBy: "\n")
                        resultPreview = lines.count > 1
                            ? " -> (\(lines.count) lines)"
                            : " -> \(String(result.prefix(100)))"
                    } else {
                        resultPreview = ""
                    }
                    blocks.append(ContentBlock(
                        kind: .toolUse(name: name, input: inputMap),
                        text: "\(description)\(resultPreview)"
                    ))
                    // Add tool result block with full output for migration support
                    if let result = call.result {
                        blocks.append(ContentBlock(
                            kind: .toolResult(toolName: name),
                            text: result
                        ))
                    }
                }
            }

            let textPreview = buildTextPreview(blocks: blocks, role: role)

            turns.append(ConversationTurn(
                index: turnIndex,
                lineNumber: messageIndex + 1, // 1-based for consistency
                role: role,
                textPreview: textPreview,
                timestamp: message.timestamp,
                contentBlocks: blocks
            ))
            turnIndex += 1
        }

        return turns
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

        // Parse, replace sessionId, write new file
        let data = try Data(contentsOf: URL(fileURLWithPath: sessionPath))
        guard var jsonString = String(data: data, encoding: .utf8) else {
            throw SessionStoreError.fileNotFound(sessionPath)
        }

        // Replace the old sessionId with the new one
        let decoder = JSONDecoder()
        let session = try decoder.decode(GeminiSessionParser.SessionFile.self, from: data)
        jsonString = jsonString.replacingOccurrences(
            of: "\"\(session.sessionId)\"",
            with: "\"\(newSessionId)\""
        )

        // Generate a new filename based on the session naming convention
        let newFileName = "session-forked-\(newSessionId).json"
        let newPath = (dir as NSString).appendingPathComponent(newFileName)

        try jsonString.write(toFile: newPath, atomically: true, encoding: .utf8)

        // Preserve original mtime so activity detector doesn't treat fork as active
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
        // Find slug for project path from ~/.gemini/projects.json
        let slug = resolveSlug(for: projectPath)
        let base = (NSHomeDirectory() as NSString).appendingPathComponent(".gemini/tmp/\(slug)/chats")
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)

        let fileName = "session-migrated-\(sessionId).json"
        let filePath = (base as NSString).appendingPathComponent(fileName)

        let isoFormatter = ISO8601DateFormatter()
        let now = isoFormatter.string(from: .now)
        var messages: [[String: Any]] = []

        for turn in turns {
            let msgId = UUID().uuidString.lowercased()
            var msg: [String: Any] = [
                "id": msgId,
                "timestamp": turn.timestamp ?? now
            ]

            if turn.role == "user" {
                msg["type"] = "user"
                let textParts = turn.contentBlocks.compactMap { block -> String? in
                    if case .text = block.kind { return block.text }
                    return nil
                }
                let text = textParts.isEmpty ? turn.textPreview : textParts.joined(separator: "\n")
                msg["content"] = [["text": text]]
            } else if turn.role == "assistant" {
                msg["type"] = "gemini"
                // Collect text content
                var textParts: [String] = []
                var toolCalls: [[String: Any]] = []

                for block in turn.contentBlocks {
                    switch block.kind {
                    case .text:
                        textParts.append(block.text)
                    case .toolUse(let name, let input, _):
                        toolCalls.append([
                            "id": UUID().uuidString.lowercased(),
                            "name": name,
                            "displayName": name,
                            "description": block.text,
                            "args": input,
                            "status": "completed"
                        ])
                    case .toolResult:
                        // Attach result to last tool call if possible
                        if !toolCalls.isEmpty {
                            toolCalls[toolCalls.count - 1]["result"] = block.text
                        }
                    case .thinking, .planModeEnter, .planModeExit, .askUserQuestion, .agentCall:
                        break
                    }
                }

                msg["content"] = textParts.joined(separator: "\n")
                if !toolCalls.isEmpty {
                    msg["toolCalls"] = toolCalls
                }
            } else {
                // System message -> info type
                let text = turn.contentBlocks.compactMap { block -> String? in
                    if case .text = block.kind { return block.text }
                    return nil
                }.joined(separator: "\n")
                msg["type"] = "info"
                msg["content"] = text.isEmpty ? turn.textPreview : text
            }

            messages.append(msg)
        }

        let sessionObj: [String: Any] = [
            "sessionId": sessionId,
            "startTime": turns.first?.timestamp ?? now,
            "lastUpdated": turns.last?.timestamp ?? now,
            "messages": messages,
            "kind": "main"
        ]

        let data = try JSONSerialization.data(withJSONObject: sessionObj, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: filePath))
        return filePath
    }

    // MARK: - Slug Resolution

    /// Resolve the Gemini project slug for a given project path.
    /// Reads `~/.gemini/projects.json` which maps `{ "projects": { "/path": "slug" } }`.
    /// Falls back to the last path component if no mapping is found.
    private func resolveSlug(for projectPath: String?) -> String {
        guard let projectPath else { return "unknown" }

        let projectsJsonPath = (NSHomeDirectory() as NSString).appendingPathComponent(".gemini/projects.json")
        guard let data = FileManager.default.contents(atPath: projectsJsonPath) else {
            // No projects.json — derive slug from path
            return (projectPath as NSString).lastPathComponent
        }

        // projects.json schema: { "projects": { "/absolute/path": "slug" } }
        struct ProjectsFile: Codable {
            let projects: [String: String]
        }

        do {
            let decoded = try JSONDecoder().decode(ProjectsFile.self, from: data)
            if let slug = decoded.projects[projectPath] {
                return slug
            }
        } catch {
            // Fall through
        }

        // Not found — derive from path
        return (projectPath as NSString).lastPathComponent
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

        // Parse, truncate messages, write back
        let data = try Data(contentsOf: URL(fileURLWithPath: sessionPath))

        guard var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = obj["messages"] as? [[String: Any]] else {
            return
        }

        // lineNumber is 1-based message index, so keep messages[0..<lineNumber]
        let keepCount = min(afterTurn.lineNumber, messages.count)
        obj["messages"] = Array(messages.prefix(keepCount))

        let truncatedData = try JSONSerialization.data(
            withJSONObject: obj,
            options: [.prettyPrinted, .sortedKeys]
        )

        try truncatedData.write(to: URL(fileURLWithPath: sessionPath))
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

        for (path, mtime) in validPaths {
            try Task.checkCancellation()

            let (matchingTokens, wordCount, snippets) = extractMatchingTokens(
                from: path, queryTerms: queryTerms
            )
            guard wordCount > 0 else { continue }
            totalWordCount += wordCount
            guard !matchingTokens.isEmpty else { continue }

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

            // Score all matching docs with running stats and yield
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
                    results.append(SearchResult(
                        sessionPath: doc.path, score: score, snippets: doc.snippets
                    ))
                }
            }
            results.sort { $0.score > $1.score }
            await onResult(results)
        }
    }

    // MARK: - Search Helpers

    private static let maxSnippets = 3

    /// Extract matching tokens and snippets from a Gemini session JSON file.
    private func extractMatchingTokens(
        from path: String,
        queryTerms: [String]
    ) -> (tokens: [String], wordCount: Int, snippets: [String]) {
        guard let data = FileManager.default.contents(atPath: path),
              let session = try? JSONDecoder().decode(
                  GeminiSessionParser.SessionFile.self, from: data
              ) else {
            return ([], 0, [])
        }

        var matchingTokens: [String] = []
        var wordCount = 0
        var topSnippets: [(score: Int, text: String)] = []

        for message in session.messages {
            let text = message.content.textValue
            guard !text.isEmpty else { continue }

            let role: String
            switch message.type {
            case "user": role = "user"
            case "gemini": role = "assistant"
            default: role = "system"
            }

            let docTokens = text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty && $0.count >= 2 }

            wordCount += docTokens.count

            for token in docTokens {
                if let matched = matchQueryTerm(token: token, queryTerms: queryTerms) {
                    matchingTokens.append(matched)
                }
            }

            // Track top snippets
            let lower = text.lowercased()
            var snippetScore = 0
            for qt in queryTerms {
                if lower.contains(qt) { snippetScore += 1 }
            }
            if snippetScore > 0 {
                let snippet = extractSnippet(from: text, queryTerms: queryTerms, role: role)
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

    private func matchQueryTerm(token: String, queryTerms: [String]) -> String? {
        for qt in queryTerms {
            if token == qt || token.hasPrefix(qt) || qt.hasPrefix(token) {
                return qt
            }
        }
        return nil
    }

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
                let label = role == "user" ? "You" : "Gemini"
                return "\(label): \(prefix)\(snippet)\(suffix)"
            }
        }
        return String(text.prefix(100))
    }

    // MARK: - Text Preview

    private func buildTextPreview(blocks: [ContentBlock], role: String) -> String {
        let textOnly = blocks.filter { if case .text = $0.kind { true } else { false } }
            .map(\.text).joined(separator: "\n")

        if !textOnly.isEmpty {
            return String(textOnly.prefix(500))
        }

        if blocks.isEmpty { return "(empty)" }

        if role == "user" {
            let resultCount = blocks.filter {
                if case .toolResult = $0.kind { true } else { false }
            }.count
            if resultCount > 0 {
                return "[tool result x\(resultCount)]"
            }
        } else {
            let toolNames = blocks.compactMap { block -> String? in
                if case .toolUse(let name, _, _) = block.kind { return name }
                return nil
            }
            if !toolNames.isEmpty {
                let unique = Array(NSOrderedSet(array: toolNames)) as! [String]
                return "[tool: \(unique.joined(separator: ", "))]"
            }
        }

        return "(empty)"
    }
}
