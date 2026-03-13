import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("MastracodeSessionStore")
struct MastracodeSessionStoreTests {

    @Test("Reads transcript from Mastra DB")
    func readTranscript() async throws {
        let dbPath = try MastracodeTestHelpers.makeTempDatabase()
        defer { MastracodeTestHelpers.cleanupDatabase(at: dbPath) }

        try MastracodeTestHelpers.insertThread(
            dbPath: dbPath,
            id: "thread-1",
            metadata: ["projectPath": "/repo/app"]
        )
        try MastracodeTestHelpers.insertMessage(
            dbPath: dbPath,
            threadId: "thread-1",
            role: "user",
            content: MastracodeTestHelpers.userContent("Fix login"),
            createdAt: "2026-03-09T10:00:01Z"
        )
        try MastracodeTestHelpers.insertMessage(
            dbPath: dbPath,
            threadId: "thread-1",
            role: "assistant",
            content: MastracodeTestHelpers.assistantContent(
                reasoning: "I should inspect the auth flow",
                toolName: "view",
                toolArgs: ["path": "src/auth.ts"],
                toolResult: "file contents",
                text: "I found the issue."
            ),
            createdAt: "2026-03-09T10:00:02Z"
        )
        try MastracodeTestHelpers.insertMessage(
            dbPath: dbPath,
            threadId: "thread-1",
            role: "system",
            type: "notification",
            content: MastracodeTestHelpers.systemContent("Checkpoint saved"),
            createdAt: "2026-03-09T10:00:03Z"
        )

        let store = MastracodeSessionStore(databasePath: dbPath)
        let turns = try await store.readTranscript(
            sessionPath: MastracodeSessionPath.encode(databasePath: dbPath, threadId: "thread-1")
        )

        #expect(turns.count == 3)
        #expect(turns[0].role == "user")
        #expect(turns[0].textPreview == "Fix login")
        #expect(turns[1].role == "assistant")
        #expect(turns[1].contentBlocks.contains { if case .thinking = $0.kind { return true } else { return false } })
        #expect(turns[1].contentBlocks.contains { if case .toolUse(let name, let input) = $0.kind { return name == "view" && input["path"] == "src/auth.ts" } else { return false } })
        #expect(turns[1].contentBlocks.contains { if case .toolResult(let toolName) = $0.kind { return toolName == "view" && $0.text == "file contents" } else { return false } })
        #expect(turns[2].role == "system")
    }

    @Test("Writes migrated session into Mastra DB")
    func writeSession() async throws {
        let dbPath = try MastracodeTestHelpers.makeTempDatabase()
        defer { MastracodeTestHelpers.cleanupDatabase(at: dbPath) }

        let store = MastracodeSessionStore(databasePath: dbPath)
        let path = try await store.writeSession(
            turns: [
                ConversationTurn(index: 0, lineNumber: 1, role: "user", textPreview: "Plan it", contentBlocks: [ContentBlock(kind: .text, text: "Plan it")]),
                ConversationTurn(index: 1, lineNumber: 2, role: "assistant", textPreview: "Doing it", contentBlocks: [ContentBlock(kind: .text, text: "Doing it")]),
            ],
            sessionId: "thread-migrated",
            projectPath: "/repo/migrate"
        )

        #expect(path == MastracodeSessionPath.encode(databasePath: dbPath, threadId: "thread-migrated"))

        let transcript = try await store.readTranscript(sessionPath: path)
        #expect(transcript.count == 2)
        #expect(transcript[0].textPreview == "Plan it")
        #expect(transcript[1].textPreview == "Doing it")
    }

    @Test("Backup and delete exports session and removes thread")
    func backupAndDelete() async throws {
        let dbPath = try MastracodeTestHelpers.makeTempDatabase()
        defer { MastracodeTestHelpers.cleanupDatabase(at: dbPath) }

        try MastracodeTestHelpers.insertThread(
            dbPath: dbPath,
            id: "thread-delete",
            metadata: ["projectPath": "/repo/app"]
        )
        try MastracodeTestHelpers.insertMessage(
            dbPath: dbPath,
            threadId: "thread-delete",
            role: "user",
            content: MastracodeTestHelpers.userContent("Delete me"),
            createdAt: "2026-03-09T10:00:01Z"
        )

        let store = MastracodeSessionStore(databasePath: dbPath)
        let sessionPath = MastracodeSessionPath.encode(databasePath: dbPath, threadId: "thread-delete")
        let backupPath = try await store.backupAndDeleteSession(sessionPath: sessionPath)

        #expect(FileManager.default.fileExists(atPath: backupPath))
        let remaining = try await store.readTranscript(sessionPath: sessionPath)
        #expect(remaining.isEmpty)
    }
}

