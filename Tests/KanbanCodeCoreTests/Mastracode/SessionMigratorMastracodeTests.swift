import Testing
import Foundation
@testable import KanbanCodeCore

private final class RecordingTargetStore: SessionStore, @unchecked Sendable {
    var writtenTurns: [ConversationTurn] = []
    var writtenProjectPath: String?

    func readTranscript(sessionPath: String) async throws -> [ConversationTurn] { [] }
    func forkSession(sessionPath: String, targetDirectory: String?) async throws -> String { "unused" }
    func truncateSession(sessionPath: String, afterTurn: ConversationTurn) async throws {}
    func searchSessions(query: String, paths: [String]) async throws -> [SearchResult] { [] }
    func writeSession(turns: [ConversationTurn], sessionId: String, projectPath: String?) async throws -> String {
        writtenTurns = turns
        writtenProjectPath = projectPath
        return "/tmp/migrated-\(sessionId).json"
    }
    func backupAndDeleteSession(sessionPath: String) async throws -> String { sessionPath + ".bak" }
}

@Suite("SessionMigrator Mastracode")
struct SessionMigratorMastracodeTests {
    @Test("Migrates Mastra session through normalized turns and removes source thread")
    func migrateFromMastra() async throws {
        let dbPath = try MastracodeTestHelpers.makeTempDatabase()
        defer { MastracodeTestHelpers.cleanupDatabase(at: dbPath) }

        try MastracodeTestHelpers.insertThread(
            dbPath: dbPath,
            id: "thread-migrate",
            metadata: ["projectPath": "/repo/app"]
        )
        try MastracodeTestHelpers.insertMessage(
            dbPath: dbPath,
            threadId: "thread-migrate",
            role: "user",
            content: MastracodeTestHelpers.userContent("Fix auth"),
            createdAt: "2026-03-09T10:00:01Z"
        )
        try MastracodeTestHelpers.insertMessage(
            dbPath: dbPath,
            threadId: "thread-migrate",
            role: "assistant",
            content: MastracodeTestHelpers.assistantContent(text: "Working on it"),
            createdAt: "2026-03-09T10:00:02Z"
        )

        let sourceStore = MastracodeSessionStore(databasePath: dbPath)
        let targetStore = RecordingTargetStore()
        let sourcePath = MastracodeSessionPath.encode(databasePath: dbPath, threadId: "thread-migrate")

        let result = try await SessionMigrator.migrate(
            sourceSessionPath: sourcePath,
            sourceStore: sourceStore,
            targetStore: targetStore,
            projectPath: "/repo/app"
        )

        #expect(targetStore.writtenTurns.count == 2)
        #expect(targetStore.writtenTurns[0].textPreview == "Fix auth")
        #expect(targetStore.writtenTurns[1].textPreview == "Working on it")
        #expect(targetStore.writtenProjectPath == "/repo/app")
        #expect(FileManager.default.fileExists(atPath: result.backupPath))

        let remaining = try await sourceStore.readTranscript(sessionPath: sourcePath)
        #expect(remaining.isEmpty)
        #expect(result.newSessionPath.contains("/tmp/migrated-"))
    }
}

