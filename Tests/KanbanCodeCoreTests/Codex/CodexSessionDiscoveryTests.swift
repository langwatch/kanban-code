import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("CodexSessionDiscovery")
struct CodexSessionDiscoveryTests {
    private func makeTempCodexDir() throws -> String {
        let dir = "/tmp/kanban-test-codex-discovery-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func createSessionFile(
        at dir: String,
        sessionId: String,
        dayPath: String = "2026/04/19"
    ) throws -> String {
        let sessionDir = "\(dir)/sessions/\(dayPath)"
        try FileManager.default.createDirectory(atPath: sessionDir, withIntermediateDirectories: true)
        let path = "\(sessionDir)/rollout-\(sessionId).jsonl"
        let content = """
        {"timestamp":"2026-04-19T10:00:00Z","type":"session_meta","payload":{"id":"\(sessionId)","cwd":"/tmp/project","git":{"branch":"main"}}}
        {"timestamp":"2026-04-19T10:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Hello \(sessionId)"}]}}
        {"timestamp":"2026-04-19T10:00:02Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hi"}]}}
        """
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    @Test("Discovers nested Codex sessions")
    func discoversSessions() async throws {
        let dir = try makeTempCodexDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        _ = try createSessionFile(at: dir, sessionId: "codex-1")
        _ = try createSessionFile(at: dir, sessionId: "codex-2", dayPath: "2026/04/20")

        let sessions = try await CodexSessionDiscovery(codexDir: dir).discoverSessions()

        #expect(sessions.count == 2)
        #expect(sessions.allSatisfy { $0.assistant == .codex })
        #expect(sessions.allSatisfy { $0.projectPath == "/tmp/project" })
    }

    @Test("Uses thread names from session_index")
    func usesSessionIndex() async throws {
        let dir = try makeTempCodexDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        _ = try createSessionFile(at: dir, sessionId: "codex-indexed")
        try """
        {"id":"codex-indexed","thread_name":"Indexed Codex Session","updated_at":"2026-04-19T10:00:00Z"}
        """.write(toFile: "\(dir)/session_index.jsonl", atomically: true, encoding: .utf8)

        let sessions = try await CodexSessionDiscovery(codexDir: dir).discoverSessions()

        #expect(sessions.count == 1)
        #expect(sessions[0].name == "Indexed Codex Session")
    }

    @Test("Ignores empty Codex session files")
    func ignoresEmptySessions() async throws {
        let dir = try makeTempCodexDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let sessionDir = "\(dir)/sessions/2026/04/19"
        try FileManager.default.createDirectory(atPath: sessionDir, withIntermediateDirectories: true)
        try """
        {"timestamp":"2026-04-19T10:00:00Z","type":"session_meta","payload":{"id":"empty","cwd":"/tmp/project"}}
        """.write(toFile: "\(sessionDir)/rollout-empty.jsonl", atomically: true, encoding: .utf8)

        let sessions = try await CodexSessionDiscovery(codexDir: dir).discoverSessions()
        #expect(sessions.isEmpty)
    }
}
