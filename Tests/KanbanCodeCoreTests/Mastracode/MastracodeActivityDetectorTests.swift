import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("MastracodeActivityDetector")
struct MastracodeActivityDetectorTests {

    @Test("Recent thread update is actively working")
    func activeByUpdatedAt() async throws {
        let dbPath = try MastracodeTestHelpers.makeTempDatabase()
        defer { MastracodeTestHelpers.cleanupDatabase(at: dbPath) }

        try MastracodeTestHelpers.insertThread(
            dbPath: dbPath,
            id: "thread-1",
            updatedAt: ISO8601DateFormatter().string(from: .now.addingTimeInterval(-20))
        )

        let detector = MastracodeActivityDetector()
        let result = await detector.pollActivity(sessionPaths: [
            "thread-1": MastracodeSessionPath.encode(databasePath: dbPath, threadId: "thread-1")
        ])

        #expect(result["thread-1"] == .activelyWorking)
    }

    @Test("Older thread update becomes ended")
    func endedByUpdatedAt() async throws {
        let dbPath = try MastracodeTestHelpers.makeTempDatabase()
        defer { MastracodeTestHelpers.cleanupDatabase(at: dbPath) }

        try MastracodeTestHelpers.insertThread(
            dbPath: dbPath,
            id: "thread-1",
            updatedAt: ISO8601DateFormatter().string(from: .now.addingTimeInterval(-7200))
        )

        let detector = MastracodeActivityDetector()
        let result = await detector.pollActivity(sessionPaths: [
            "thread-1": MastracodeSessionPath.encode(databasePath: dbPath, threadId: "thread-1")
        ])

        #expect(result["thread-1"] == .ended)
    }

    @Test("Hook state overrides DB polling")
    func hookPriority() async throws {
        let dbPath = try MastracodeTestHelpers.makeTempDatabase()
        defer { MastracodeTestHelpers.cleanupDatabase(at: dbPath) }

        try MastracodeTestHelpers.insertThread(
            dbPath: dbPath,
            id: "thread-1",
            updatedAt: ISO8601DateFormatter().string(from: .now.addingTimeInterval(-7200))
        )

        let detector = MastracodeActivityDetector()
        await detector.handleHookEvent(HookEvent(sessionId: "thread-1", eventName: "UserPromptSubmit"))
        let result = await detector.pollActivity(sessionPaths: [
            "thread-1": MastracodeSessionPath.encode(databasePath: dbPath, threadId: "thread-1")
        ])

        #expect(result["thread-1"] == .activelyWorking)
    }
}

