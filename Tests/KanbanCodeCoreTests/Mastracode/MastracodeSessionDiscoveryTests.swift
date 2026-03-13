import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("MastracodeSessionDiscovery")
struct MastracodeSessionDiscoveryTests {

    @Test("Discovers sessions from Mastra DB")
    func discoversSessions() async throws {
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
            content: MastracodeTestHelpers.userContent("Fix the login bug"),
            createdAt: "2026-03-09T10:00:01Z"
        )

        let discovery = MastracodeSessionDiscovery(databasePath: dbPath)
        let sessions = try await discovery.discoverSessions()

        #expect(sessions.count == 1)
        #expect(sessions[0].assistant == .mastracode)
        #expect(sessions[0].projectPath == "/repo/app")
        #expect(sessions[0].firstPrompt == "Fix the login bug")
        #expect(sessions[0].jsonlPath == MastracodeSessionPath.encode(databasePath: dbPath, threadId: "thread-1"))
    }

    @Test("Sorts sessions by updated time descending")
    func sortsByUpdatedAt() async throws {
        let dbPath = try MastracodeTestHelpers.makeTempDatabase()
        defer { MastracodeTestHelpers.cleanupDatabase(at: dbPath) }

        try MastracodeTestHelpers.insertThread(
            dbPath: dbPath,
            id: "older",
            metadata: ["projectPath": "/repo/a"],
            updatedAt: "2026-03-09T10:00:00Z"
        )
        try MastracodeTestHelpers.insertThread(
            dbPath: dbPath,
            id: "newer",
            metadata: ["projectPath": "/repo/b"],
            updatedAt: "2026-03-09T10:10:00Z"
        )

        let discovery = MastracodeSessionDiscovery(databasePath: dbPath)
        let sessions = try await discovery.discoverSessions()

        #expect(sessions.map(\.id) == ["newer", "older"])
    }

    @Test("Returns empty when database is missing")
    func missingDatabase() async throws {
        let discovery = MastracodeSessionDiscovery(databasePath: "/tmp/does-not-exist.sqlite")
        let sessions = try await discovery.discoverSessions()
        #expect(sessions.isEmpty)
    }
}

