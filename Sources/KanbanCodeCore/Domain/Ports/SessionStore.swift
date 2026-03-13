import Foundation

/// Port for reading and modifying Claude Code session files.
public protocol SessionStore: Sendable {
    /// Read conversation turns from a session file.
    func readTranscript(sessionPath: String) async throws -> [ConversationTurn]

    /// Fork (duplicate) a session, returning the new session ID.
    /// If targetDirectory is provided, the fork is placed there instead of the original directory.
    func forkSession(sessionPath: String, targetDirectory: String?) async throws -> String

    /// Truncate a session to a given turn (checkpoint). Creates a .bkp backup.
    func truncateSession(sessionPath: String, afterTurn: ConversationTurn) async throws

    /// Full-text search across all session files.
    func searchSessions(query: String, paths: [String]) async throws -> [SearchResult]

    /// Streaming full-text search — calls onResult with accumulated sorted results after each file.
    func searchSessionsStreaming(
        query: String, paths: [String],
        onResult: @MainActor @Sendable ([SearchResult]) -> Void
    ) async throws

    /// Write conversation turns to a new session file in this store's native format.
    /// Returns the path to the new session file.
    func writeSession(turns: [ConversationTurn], sessionId: String, projectPath: String?) async throws -> String

    /// Create a backup of the session and delete the original.
    /// Returns the backup path.
    func backupAndDeleteSession(sessionPath: String) async throws -> String
}

extension SessionStore {
    public func forkSession(sessionPath: String) async throws -> String {
        try await forkSession(sessionPath: sessionPath, targetDirectory: nil)
    }

    /// Default: fall back to batch search, call onResult once at the end.
    public func searchSessionsStreaming(
        query: String, paths: [String],
        onResult: @MainActor @Sendable ([SearchResult]) -> Void
    ) async throws {
        let results = try await searchSessions(query: query, paths: paths)
        await onResult(results)
    }

    /// Default: writing is not supported.
    public func writeSession(turns: [ConversationTurn], sessionId: String, projectPath: String?) async throws -> String {
        throw SessionStoreError.writeNotSupported
    }

    /// Default: backup a file-based session and remove the original.
    public func backupAndDeleteSession(sessionPath: String) async throws -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sessionPath) else {
            throw SessionStoreError.fileNotFound(sessionPath)
        }

        let backupPath = sessionPath + ".bak"
        if fm.fileExists(atPath: backupPath) {
            try? fm.removeItem(atPath: backupPath)
        }
        try fm.copyItem(atPath: sessionPath, toPath: backupPath)
        try? fm.removeItem(atPath: sessionPath)
        return backupPath
    }
}

/// A search result from full-text session search.
public struct SearchResult: Sendable {
    public let sessionPath: String
    public let score: Double
    public let snippets: [String]

    public init(sessionPath: String, score: Double, snippets: [String]) {
        self.sessionPath = sessionPath
        self.score = score
        self.snippets = snippets
    }
}
