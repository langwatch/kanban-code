import Foundation

/// Migrates a session from one coding assistant to another.
/// Reads the source transcript, writes to the target format, and creates a backup.
public enum SessionMigrator {

    public struct MigrationResult: Sendable {
        public let newSessionId: String
        public let newSessionPath: String
        public let backupPath: String
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
        projectPath: String?
    ) async throws -> MigrationResult {
        // 1. Read transcript from source
        let turns = try await sourceStore.readTranscript(sessionPath: sourceSessionPath)
        guard !turns.isEmpty else {
            throw MigrationError.emptySession
        }

        // 2. Generate new session ID
        let newSessionId = UUID().uuidString.lowercased()

        // 3. Write to target format
        let newPath = try await targetStore.writeSession(
            turns: turns,
            sessionId: newSessionId,
            projectPath: projectPath
        )

        // 4. Backup source session, then remove the original so the reconciler
        //    doesn't rediscover it and create a duplicate card.
        let backupPath = try await sourceStore.backupAndDeleteSession(sessionPath: sourceSessionPath)

        return MigrationResult(
            newSessionId: newSessionId,
            newSessionPath: newPath,
            backupPath: backupPath
        )
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
