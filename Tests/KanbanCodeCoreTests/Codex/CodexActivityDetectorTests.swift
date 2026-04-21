import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("CodexActivityDetector")
struct CodexActivityDetectorTests {
    private func writeTempFile(modified: Date) throws -> String {
        let path = "/tmp/kanban-test-codex-activity-\(UUID().uuidString).jsonl"
        try "{}\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path)
        return path
    }

    @Test("Polls activity from file modification time")
    func pollsMtime() async throws {
        let active = try writeTempFile(modified: .now.addingTimeInterval(-10))
        let stale = try writeTempFile(modified: .now.addingTimeInterval(-90_000))
        defer {
            try? FileManager.default.removeItem(atPath: active)
            try? FileManager.default.removeItem(atPath: stale)
        }

        let detector = CodexActivityDetector(activeThreshold: 60, attentionThreshold: 120)
        let states = await detector.pollActivity(sessionPaths: [
            "active": active,
            "stale": stale
        ])

        #expect(states["active"] == .activelyWorking)
        #expect(states["stale"] == .stale)
    }

    @Test("Ignores hook events")
    func ignoresHooks() async {
        let detector = CodexActivityDetector()
        await detector.handleHookEvent(HookEvent(sessionId: "s1", eventName: "UserPromptSubmit"))
        let state = await detector.activityState(for: "s1")
        #expect(state == .stale)
    }
}
