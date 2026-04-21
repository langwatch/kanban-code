import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("CodexSessionParser")
struct CodexSessionParserTests {
    private func writeTempSession(_ content: String) throws -> String {
        let path = "/tmp/kanban-test-codex-\(UUID().uuidString).jsonl"
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private let sampleSession = """
    {"timestamp":"2026-04-19T10:00:00Z","type":"session_meta","payload":{"id":"019da64f-874c-7a03-bde4-7660c09931f2","cwd":"/tmp/project","git":{"branch":"main"}}}
    {"timestamp":"2026-04-19T10:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Fix login"}]}}
    {"timestamp":"2026-04-19T10:00:02Z","type":"response_item","payload":{"type":"reasoning","summary":[{"type":"summary_text","text":"Need inspect files"}]}}
    {"timestamp":"2026-04-19T10:00:03Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"I'll inspect the login code."}]}}
    {"timestamp":"2026-04-19T10:00:04Z","type":"response_item","payload":{"type":"function_call","call_id":"call-1","name":"exec_command","arguments":"{\\"cmd\\":\\"rg login\\",\\"workdir\\":\\"/tmp/project\\"}"}}
    {"timestamp":"2026-04-19T10:00:05Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call-1","output":"login.ts:1"}}
    """

    @Test("Extracts Codex metadata")
    func extractsMetadata() async throws {
        let path = try writeTempSession(sampleSession)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let metadata = try await CodexSessionParser.extractMetadata(from: path)

        #expect(metadata?.sessionId == "019da64f-874c-7a03-bde4-7660c09931f2")
        #expect(metadata?.projectPath == "/tmp/project")
        #expect(metadata?.gitBranch == "main")
        #expect(metadata?.firstPrompt == "Fix login")
        #expect((metadata?.messageCount ?? 0) >= 2)
    }

    @Test("Reads Codex transcript turns")
    func readsTranscript() async throws {
        let path = try writeTempSession(sampleSession)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let turns = try await CodexSessionParser.readTurns(from: path)

        #expect(turns.count == 2)
        #expect(turns[0].role == "user")
        #expect(turns[0].textPreview == "Fix login")
        #expect(turns[1].role == "assistant")
        #expect(turns[1].contentBlocks.contains {
            if case .thinking = $0.kind { return true }
            return false
        })
        #expect(turns[1].contentBlocks.contains {
            if case .toolUse(let name, let input, let id) = $0.kind {
                return name == "exec_command" && input["cmd"] == "rg login" && id == "call-1"
            }
            return false
        })
        #expect(turns[1].contentBlocks.contains {
            if case .toolResult(let toolName, let toolUseId) = $0.kind {
                return toolName == "exec_command" && toolUseId == "call-1"
            }
            return false
        })
    }

    @Test("Extracts session id from session_meta")
    func extractsSessionId() async throws {
        let path = try writeTempSession(sampleSession)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let id = await CodexSessionParser.extractSessionId(from: path)
        #expect(id == "019da64f-874c-7a03-bde4-7660c09931f2")
    }

    @Test("Returns nil metadata for empty interactive launch")
    func emptySessionReturnsNil() async throws {
        let path = try writeTempSession("""
        {"timestamp":"2026-04-19T10:00:00Z","type":"session_meta","payload":{"id":"empty","cwd":"/tmp/project"}}
        """)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let metadata = try await CodexSessionParser.extractMetadata(from: path)
        #expect(metadata == nil)
    }

    @Test("Scans Codex command calls for pushed branches")
    func extractsPushedBranches() async throws {
        let session = """
        {"timestamp":"2026-04-19T10:00:00Z","type":"session_meta","payload":{"id":"branch","cwd":"/tmp/project"}}
        {"timestamp":"2026-04-19T10:00:01Z","type":"response_item","payload":{"type":"function_call","call_id":"call-1","name":"exec_command","arguments":"{\\"cmd\\":\\"git checkout -b feature/codex && git push origin feature/codex\\",\\"workdir\\":\\"/tmp/project\\"}"}}
        """
        let path = try writeTempSession(session)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let branches = try await CodexSessionParser.extractPushedBranches(from: path)
        #expect(branches.contains(JsonlParser.DiscoveredBranch(branch: "feature/codex", repoPath: "/tmp/project")))
    }
}
