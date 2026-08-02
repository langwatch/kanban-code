import Foundation

/// Migrates a session from one coding assistant to another.
/// Reads the source transcript, writes to the target format, and creates a backup.
public enum SessionMigrator {

    /// Keeps cross-assistant resumes comfortably below a 1M-token context window.
    /// Text is a conservative proxy because transcript formats do not expose a
    /// tokenizer shared by every assistant.
    public static let defaultCrossAssistantCharacterLimit = 1_000_000

    public struct MigrationResult: Sendable {
        public let newSessionId: String
        public let newSessionPath: String
        public let backupPath: String
        public let sourceTurnCount: Int
        public let migratedTurnCount: Int
    }

    /// Migrate a session from one assistant to another.
    /// - Parameters:
    ///   - sourceSessionPath: Path to the source session file
    ///   - sourceStore: The session store for the source assistant
    ///   - targetStore: The session store for the target assistant
    ///   - projectPath: The project path for file placement
    /// - Returns: Migration result with new session info and backup path
    public static func migrate(
        sourceSessionPath: String,
        sourceStore: SessionStore,
        targetStore: SessionStore,
        projectPath: String?,
        recentTurnLimit: Int? = nil,
        recentCharacterLimit: Int? = nil
    ) async throws -> MigrationResult {
        // 1. Read transcript from source
        let turns = try await sourceStore.readTranscript(sessionPath: sourceSessionPath)
        guard !turns.isEmpty else {
            throw MigrationError.emptySession
        }
        var turnsToMigrate: [ConversationTurn]
        if let recentTurnLimit, recentTurnLimit > 0, turns.count > recentTurnLimit {
            turnsToMigrate = Array(turns.suffix(recentTurnLimit))
        } else {
            turnsToMigrate = turns
        }
        if let recentCharacterLimit, recentCharacterLimit > 0 {
            turnsToMigrate = recentTurns(
                from: turnsToMigrate,
                fittingCharacterLimit: recentCharacterLimit
            )
        }

        // 2. Generate new session ID
        let newSessionId = UUID().uuidString.lowercased()

        // 3. Write to target format
        let newPath = try await targetStore.writeSession(
            turns: turnsToMigrate,
            sessionId: newSessionId,
            projectPath: projectPath
        )

        // 4. Backup source file, then remove original so the reconciler
        //    doesn't rediscover it and create a duplicate card.
        let backupPath = sourceSessionPath + ".bak"
        let fm = FileManager.default
        if fm.fileExists(atPath: backupPath) {
            try? fm.removeItem(atPath: backupPath)
        }
        try fm.copyItem(atPath: sourceSessionPath, toPath: backupPath)
        try? fm.removeItem(atPath: sourceSessionPath)

        return MigrationResult(
            newSessionId: newSessionId,
            newSessionPath: newPath,
            backupPath: backupPath,
            sourceTurnCount: turns.count,
            migratedTurnCount: turnsToMigrate.count
        )
    }

    static func recentTurns(
        from turns: [ConversationTurn],
        fittingCharacterLimit limit: Int
    ) -> [ConversationTurn] {
        guard limit > 0, !turns.isEmpty else { return turns }
        var selected: [ConversationTurn] = []
        var total = 0
        for turn in turns.reversed() {
            let size = estimatedCharacterCount(of: turn)
            if !selected.isEmpty, total + size > limit { break }
            selected.append(turn)
            total += size
        }
        return selected.reversed()
    }

    private static func estimatedCharacterCount(of turn: ConversationTurn) -> Int {
        guard !turn.contentBlocks.isEmpty else { return turn.textPreview.utf8.count }
        return turn.contentBlocks.reduce(0) { total, block in
            total + block.text.utf8.count + (block.rawInputJSON?.count ?? 0)
        }
    }
}

public enum MigrationError: LocalizedError {
    case emptySession

    public var errorDescription: String? {
        switch self {
        case .emptySession: "Session has no conversation turns to migrate"
        }
    }
}
