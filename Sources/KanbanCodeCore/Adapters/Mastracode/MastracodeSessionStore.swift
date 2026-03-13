import Foundation

public final class MastracodeSessionStore: SessionStore, @unchecked Sendable {
    private let databasePath: String?

    public init(databasePath: String? = nil) {
        self.databasePath = databasePath
    }

    public func readTranscript(sessionPath: String) async throws -> [ConversationTurn] {
        guard let resolved = resolve(sessionPath: sessionPath) else {
            throw SessionStoreError.fileNotFound(sessionPath)
        }
        guard FileManager.default.fileExists(atPath: resolved.databasePath) else {
            return []
        }
        let messages = try MastracodeDatabase.readMessages(
            databasePath: resolved.databasePath,
            threadId: resolved.threadId
        )
        return MastracodeDatabase.parseTurns(messages: messages)
    }

    public func forkSession(sessionPath: String, targetDirectory: String? = nil) async throws -> String {
        guard let resolved = resolve(sessionPath: sessionPath) else {
            throw SessionStoreError.fileNotFound(sessionPath)
        }
        let turns = try await readTranscript(sessionPath: sessionPath)
        let newThreadId = UUID().uuidString.lowercased()
        let projectPath = targetDirectory ?? databaseProjectPath(for: resolved.databasePath, threadId: resolved.threadId)
        try MastracodeDatabase.writeSession(
            databasePath: resolved.databasePath,
            threadId: newThreadId,
            title: (turns.first?.textPreview ?? "").prefix(120).description,
            projectPath: projectPath,
            turns: turns
        )
        return newThreadId
    }

    public func truncateSession(sessionPath: String, afterTurn: ConversationTurn) async throws {
        guard let resolved = resolve(sessionPath: sessionPath) else {
            throw SessionStoreError.fileNotFound(sessionPath)
        }
        let turns = try await readTranscript(sessionPath: sessionPath)
        let keptTurns = Array(turns.prefix(afterTurn.lineNumber))
        let title = keptTurns.first?.textPreview ?? ""
        try MastracodeDatabase.writeSession(
            databasePath: resolved.databasePath,
            threadId: resolved.threadId,
            title: String(title.prefix(120)),
            projectPath: databaseProjectPath(for: resolved.databasePath, threadId: resolved.threadId),
            turns: keptTurns
        )
    }

    public func searchSessions(query: String, paths: [String]) async throws -> [SearchResult] {
        let terms = BM25Scorer.tokenize(query)
        guard !terms.isEmpty else { return [] }

        struct Doc {
            let path: String
            let tokens: [String]
            let snippets: [String]
            let modifiedTime: Date
        }

        var docs: [Doc] = []
        var docFreqs: [String: Int] = [:]

        for path in paths {
            let turns = try await readTranscript(sessionPath: path)
            let combined = turns.map(\.textPreview).joined(separator: "\n")
            let tokens = BM25Scorer.tokenize(combined)
            guard !tokens.isEmpty else { continue }
            let snippets = turns
                .map(\.textPreview)
                .filter { text in terms.contains { term in text.localizedCaseInsensitiveContains(term) } }
            guard !snippets.isEmpty else { continue }

            let unique = Set(tokens)
            for token in unique {
                docFreqs[token, default: 0] += 1
            }

            let modifiedTime: Date
            if let resolved = resolve(sessionPath: path),
               let updatedAt = try MastracodeDatabase.readUpdatedAt(databasePath: resolved.databasePath, threadId: resolved.threadId),
               let date = makeFractionalISO8601Formatter().date(from: updatedAt) ?? ISO8601DateFormatter().date(from: updatedAt) {
                modifiedTime = date
            } else {
                modifiedTime = .distantPast
            }

            docs.append(Doc(path: path, tokens: tokens, snippets: Array(snippets.prefix(3)), modifiedTime: modifiedTime))
        }

        let avgDocLength = docs.isEmpty ? 1.0 : Double(docs.map { $0.tokens.count }.reduce(0, +)) / Double(docs.count)

        return docs.compactMap { doc in
            let score = BM25Scorer.score(
                terms: terms,
                documentTokens: doc.tokens,
                avgDocLength: avgDocLength,
                docCount: max(docs.count, 1),
                docFreqs: docFreqs,
                recencyBoost: BM25Scorer.recencyBoost(modifiedTime: doc.modifiedTime)
            )
            guard score > 0 else { return nil }
            return SearchResult(sessionPath: doc.path, score: score, snippets: doc.snippets)
        }
        .sorted { $0.score > $1.score }
    }

    public func writeSession(turns: [ConversationTurn], sessionId: String, projectPath: String?) async throws -> String {
        let dbPath = databasePath
            ?? (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/mastracode/mastra.db")
        try MastracodeDatabase.writeSession(
            databasePath: dbPath,
            threadId: sessionId,
            title: String((turns.first?.textPreview ?? sessionId).prefix(120)),
            projectPath: projectPath,
            turns: turns
        )
        return MastracodeSessionPath.encode(databasePath: dbPath, threadId: sessionId)
    }

    public func backupAndDeleteSession(sessionPath: String) async throws -> String {
        guard let resolved = resolve(sessionPath: sessionPath) else {
            throw SessionStoreError.fileNotFound(sessionPath)
        }
        return try MastracodeDatabase.backupAndDeleteSession(
            databasePath: resolved.databasePath,
            threadId: resolved.threadId
        )
    }

    private func resolve(sessionPath: String) -> (databasePath: String, threadId: String)? {
        if let resolved = MastracodeSessionPath.decode(sessionPath) {
            return resolved
        }
        if let databasePath, !sessionPath.contains("#") {
            return (databasePath, sessionPath)
        }
        return nil
    }

    private func databaseProjectPath(for databasePath: String, threadId: String) -> String? {
        let thread = try? MastracodeDatabase.readThreads(databasePath: databasePath).first { $0.id == threadId }
        return MastracodeDatabase.extractProjectPath(from: thread?.metadata)
    }
}
