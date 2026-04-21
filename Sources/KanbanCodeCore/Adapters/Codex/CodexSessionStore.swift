import Foundation

/// Implements SessionStore for Codex CLI JSONL session files.
public final class CodexSessionStore: SessionStore, @unchecked Sendable {
    private let codexDir: String

    public init(codexDir: String? = nil) {
        self.codexDir = codexDir
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".codex")
    }

    public func readTranscript(sessionPath: String) async throws -> [ConversationTurn] {
        guard FileManager.default.fileExists(atPath: sessionPath) else {
            throw SessionStoreError.fileNotFound(sessionPath)
        }
        return try await CodexSessionParser.readTurns(from: sessionPath)
    }

    public func forkSession(sessionPath: String, targetDirectory: String? = nil) async throws -> String {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sessionPath) else {
            throw SessionStoreError.fileNotFound(sessionPath)
        }

        let oldSessionId = await CodexSessionParser.extractSessionId(from: sessionPath)
            ?? (sessionPath as NSString).lastPathComponent
                .replacingOccurrences(of: ".jsonl", with: "")
                .replacingOccurrences(of: "rollout-", with: "")
        let newSessionId = UUID().uuidString.lowercased()
        let dir = targetDirectory ?? (sessionPath as NSString).deletingLastPathComponent
        if let targetDirectory, !fileManager.fileExists(atPath: targetDirectory) {
            try fileManager.createDirectory(atPath: targetDirectory, withIntermediateDirectories: true)
        }

        let content = try String(contentsOfFile: sessionPath, encoding: .utf8)
            .replacingOccurrences(of: "\"\(oldSessionId)\"", with: "\"\(newSessionId)\"")
        let newPath = Self.sessionFilePath(sessionId: newSessionId, in: dir, prefix: "rollout-forked")
        try content.write(toFile: newPath, atomically: true, encoding: .utf8)

        if let attrs = try? fileManager.attributesOfItem(atPath: sessionPath),
           let originalMtime = attrs[.modificationDate] as? Date {
            try? fileManager.setAttributes([.modificationDate: originalMtime], ofItemAtPath: newPath)
        }

        return newSessionId
    }

    public func writeSession(
        turns: [ConversationTurn],
        sessionId: String,
        projectPath: String?
    ) async throws -> String {
        let now = ISO8601DateFormatter().string(from: .now)
        let dir = Self.defaultSessionDirectory(codexDir: codexDir)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let filePath = Self.sessionFilePath(sessionId: sessionId, in: dir, prefix: "rollout-migrated")
        var lines: [String] = []

        let metaPayload: [String: Any] = [
            "id": sessionId,
            "timestamp": now,
            "cwd": projectPath ?? NSHomeDirectory(),
            "originator": "kanban-code",
            "source": "kanban-code",
            "cli_version": "migrated",
            "model_provider": "openai"
        ]
        lines.append(try encodeLine(type: "session_meta", timestamp: now, payload: metaPayload))

        for turn in turns {
            let timestamp = turn.timestamp ?? now
            if turn.role == "assistant" {
                try appendAssistantTurn(turn, sessionId: sessionId, timestamp: timestamp, to: &lines)
            } else {
                let text = textContent(from: turn)
                let payload: [String: Any] = [
                    "type": "message",
                    "role": "user",
                    "content": [["type": "input_text", "text": text]]
                ]
                lines.append(try encodeLine(type: "response_item", timestamp: timestamp, payload: payload))
            }
        }

        try (lines.joined(separator: "\n") + "\n").write(
            toFile: filePath,
            atomically: true,
            encoding: .utf8
        )
        try appendSessionIndex(sessionId: sessionId, turns: turns, updatedAt: now)
        return filePath
    }

    public func truncateSession(sessionPath: String, afterTurn: ConversationTurn) async throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sessionPath) else {
            throw SessionStoreError.fileNotFound(sessionPath)
        }

        let backupPath = sessionPath + ".bkp"
        try? fileManager.removeItem(atPath: backupPath)
        try fileManager.copyItem(atPath: sessionPath, toPath: backupPath)

        let content = try String(contentsOfFile: sessionPath, encoding: .utf8)
        var lines = content.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let keepCount = min(max(afterTurn.lineNumber, 0), lines.count)
        let truncated = Array(lines.prefix(keepCount)).joined(separator: "\n")
        try (truncated + (truncated.isEmpty ? "" : "\n")).write(
            toFile: sessionPath,
            atomically: true,
            encoding: .utf8
        )
    }

    public func searchSessions(query: String, paths: [String]) async throws -> [SearchResult] {
        let box = ResultBox()
        try await searchSessionsStreaming(query: query, paths: paths) { results in
            box.results = results
        }
        return box.results
    }

    public func searchSessionsStreaming(
        query: String,
        paths: [String],
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

        let fileManager = FileManager.default
        let validPaths: [(String, Date)] = paths.compactMap { path in
            guard fileManager.fileExists(atPath: path),
                  let attrs = try? fileManager.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date else { return nil }
            return (path, mtime)
        }.sorted { $0.1 > $1.1 }

        var docs: [DocInfo] = []
        var globalTermFreqs: [String: Int] = [:]
        var totalWordCount = 0

        for (path, mtime) in validPaths {
            try Task.checkCancellation()
            let (tokens, wordCount, snippets) = try await extractMatchingTokens(
                from: path,
                queryTerms: queryTerms
            )
            guard wordCount > 0 else { continue }
            totalWordCount += wordCount
            guard !tokens.isEmpty else { continue }

            for term in Set(tokens) {
                globalTermFreqs[term, default: 0] += 1
            }

            docs.append(DocInfo(
                path: path,
                matchingTokens: tokens,
                wordCount: wordCount,
                snippets: snippets,
                modifiedTime: mtime
            ))

            let avgDocLength = Double(totalWordCount) / max(Double(docs.count), 1.0)
            var results: [SearchResult] = []
            for doc in docs {
                let score = BM25Scorer.score(
                    terms: queryTerms,
                    documentTokens: doc.matchingTokens,
                    avgDocLength: avgDocLength,
                    docCount: docs.count,
                    docFreqs: globalTermFreqs,
                    recencyBoost: BM25Scorer.recencyBoost(modifiedTime: doc.modifiedTime)
                )
                if score > 0 {
                    results.append(SearchResult(sessionPath: doc.path, score: score, snippets: doc.snippets))
                }
            }
            results.sort { $0.score > $1.score }
            await onResult(results)
        }
    }

    private final class ResultBox: @unchecked Sendable {
        var results: [SearchResult] = []
    }

    // MARK: - Writing Helpers

    private func appendAssistantTurn(
        _ turn: ConversationTurn,
        sessionId: String,
        timestamp: String,
        to lines: inout [String]
    ) throws {
        var messageText: [String] = []
        var pendingCallId: String?

        for block in turn.contentBlocks {
            switch block.kind {
            case .text:
                messageText.append(block.text)
            case .thinking:
                let payload: [String: Any] = [
                    "type": "reasoning",
                    "summary": [["type": "summary_text", "text": block.text]]
                ]
                lines.append(try encodeLine(type: "response_item", timestamp: timestamp, payload: payload))
            case .toolUse(let name, let input, let id):
                if !messageText.isEmpty {
                    try appendAssistantMessage(messageText.joined(separator: "\n"), timestamp: timestamp, to: &lines)
                    messageText.removeAll()
                }
                let callId = id ?? "call_\(UUID().uuidString.lowercased())"
                pendingCallId = callId
                let argsData = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
                let argsString = String(data: argsData, encoding: .utf8) ?? "{}"
                let payload: [String: Any] = [
                    "type": "function_call",
                    "call_id": callId,
                    "name": name,
                    "arguments": argsString
                ]
                lines.append(try encodeLine(type: "response_item", timestamp: timestamp, payload: payload))
            case .toolResult(_, let toolUseId):
                let payload: [String: Any] = [
                    "type": "function_call_output",
                    "call_id": toolUseId ?? pendingCallId ?? "call_\(UUID().uuidString.lowercased())",
                    "output": block.text
                ]
                lines.append(try encodeLine(type: "response_item", timestamp: timestamp, payload: payload))
            case .planModeEnter, .planModeExit, .askUserQuestion, .agentCall:
                break
            }
        }

        if !messageText.isEmpty || turn.contentBlocks.isEmpty {
            try appendAssistantMessage(
                messageText.isEmpty ? turn.textPreview : messageText.joined(separator: "\n"),
                timestamp: timestamp,
                to: &lines
            )
        }
    }

    private func appendAssistantMessage(
        _ text: String,
        timestamp: String,
        to lines: inout [String]
    ) throws {
        let payload: [String: Any] = [
            "type": "message",
            "role": "assistant",
            "content": [["type": "output_text", "text": text]]
        ]
        lines.append(try encodeLine(type: "response_item", timestamp: timestamp, payload: payload))
    }

    private func textContent(from turn: ConversationTurn) -> String {
        let parts = turn.contentBlocks.compactMap { block -> String? in
            switch block.kind {
            case .text:
                block.text
            case .toolUse(let name, let input, _):
                "[\(name)] \(input.map { "\($0.key): \($0.value)" }.sorted().joined(separator: ", "))"
            case .toolResult(let toolName, _):
                "[\(toolName ?? "tool") result] \(block.text)"
            case .thinking, .planModeEnter, .planModeExit, .askUserQuestion, .agentCall:
                nil
            }
        }
        return parts.isEmpty ? turn.textPreview : parts.joined(separator: "\n")
    }

    private func encodeLine(type: String, timestamp: String, payload: [String: Any]) throws -> String {
        let obj: [String: Any] = [
            "timestamp": timestamp,
            "type": type,
            "payload": payload
        ]
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func appendSessionIndex(sessionId: String, turns: [ConversationTurn], updatedAt: String) throws {
        let indexPath = (codexDir as NSString).appendingPathComponent("session_index.jsonl")
        try FileManager.default.createDirectory(
            atPath: (indexPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        let firstPrompt = turns.first(where: { $0.role == "user" })?.textPreview ?? String(sessionId.prefix(8))
        let obj: [String: Any] = [
            "id": sessionId,
            "thread_name": String(firstPrompt.prefix(100)),
            "updated_at": updatedAt
        ]
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        guard let line = String(data: data, encoding: .utf8) else { return }
        if FileManager.default.fileExists(atPath: indexPath),
           let handle = FileHandle(forWritingAtPath: indexPath) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((line + "\n").utf8))
        } else {
            try (line + "\n").write(toFile: indexPath, atomically: true, encoding: .utf8)
        }
    }

    private static func defaultSessionDirectory(codexDir: String) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: .now)
        let year = components.year ?? 1970
        let month = components.month ?? 1
        let day = components.day ?? 1
        return (codexDir as NSString).appendingPathComponent(
            String(format: "sessions/%04d/%02d/%02d", year, month, day)
        )
    }

    public static func sessionFilePath(sessionId: String, in directory: String, prefix: String) -> String {
        (directory as NSString).appendingPathComponent("\(prefix)-\(sessionId).jsonl")
    }

    // MARK: - Search Helpers

    private static let maxSnippets = 3

    private func extractMatchingTokens(
        from path: String,
        queryTerms: [String]
    ) async throws -> (tokens: [String], wordCount: Int, snippets: [String]) {
        let turns = try await readTranscript(sessionPath: path)
        var matchingTokens: [String] = []
        var wordCount = 0
        var topSnippets: [(score: Int, text: String)] = []

        for turn in turns {
            let text = ([turn.textPreview] + turn.contentBlocks.map(\.text))
                .filter { !$0.isEmpty && $0 != "(empty)" }
                .joined(separator: "\n")
            guard !text.isEmpty else { continue }

            let docTokens = BM25Scorer.tokenize(text)
            wordCount += docTokens.count
            for token in docTokens {
                if let matched = matchQueryTerm(token: token, queryTerms: queryTerms) {
                    matchingTokens.append(matched)
                }
            }

            let lower = text.lowercased()
            var snippetScore = 0
            for term in queryTerms where lower.contains(term) {
                snippetScore += 1
            }
            if snippetScore > 0 {
                let snippet = extractSnippet(from: text, queryTerms: queryTerms, role: turn.role)
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
        for term in queryTerms {
            if token == term || token.hasPrefix(term) || term.hasPrefix(token) {
                return term
            }
        }
        return nil
    }

    private func extractSnippet(from text: String, queryTerms: [String], role: String) -> String {
        let lower = text.lowercased()
        for term in queryTerms {
            if let range = lower.range(of: term) {
                let idx = lower.distance(from: lower.startIndex, to: range.lowerBound)
                let start = max(0, idx - 40)
                let end = min(text.count, idx + term.count + 60)
                let startIdx = text.index(text.startIndex, offsetBy: start)
                let endIdx = text.index(text.startIndex, offsetBy: end)
                let prefix = start > 0 ? "..." : ""
                let suffix = end < text.count ? "..." : ""
                let snippet = text[startIdx..<endIdx].replacingOccurrences(of: "\n", with: " ")
                let label = role == "user" ? "You" : "Codex"
                return "\(label): \(prefix)\(snippet)\(suffix)"
            }
        }
        return String(text.prefix(100))
    }
}
