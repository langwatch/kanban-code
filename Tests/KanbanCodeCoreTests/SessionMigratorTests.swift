import Foundation
import Testing
@testable import KanbanCodeCore

@Suite("SessionMigrator")
struct SessionMigratorTests {
    @Test("Migration writes full history by default")
    func migrateFullHistoryByDefault() async throws {
        let sourcePath = try writeSourceFile()
        defer {
            try? FileManager.default.removeItem(atPath: sourcePath)
            try? FileManager.default.removeItem(atPath: sourcePath + ".bak")
        }
        let source = MockMigrationStore(turns: sampleTurns)
        let target = MockMigrationStore()

        let result = try await SessionMigrator.migrate(
            sourceSessionPath: sourcePath,
            sourceStore: source,
            targetStore: target,
            projectPath: "/tmp/project"
        )
        defer { try? FileManager.default.removeItem(atPath: result.newSessionPath) }

        #expect(target.writtenTurns.map(\.textPreview) == ["message 1", "message 2", "message 3", "message 4", "message 5"])
        #expect(result.sourceTurnCount == 5)
        #expect(result.migratedTurnCount == 5)
        #expect(!FileManager.default.fileExists(atPath: sourcePath))
        #expect(FileManager.default.fileExists(atPath: result.backupPath))
    }

    @Test("Migration can keep only recent turns")
    func migrateRecentTurnsOnly() async throws {
        let sourcePath = try writeSourceFile()
        defer {
            try? FileManager.default.removeItem(atPath: sourcePath)
            try? FileManager.default.removeItem(atPath: sourcePath + ".bak")
        }
        let source = MockMigrationStore(turns: sampleTurns)
        let target = MockMigrationStore()

        let result = try await SessionMigrator.migrate(
            sourceSessionPath: sourcePath,
            sourceStore: source,
            targetStore: target,
            projectPath: "/tmp/project",
            recentTurnLimit: 2
        )
        defer { try? FileManager.default.removeItem(atPath: result.newSessionPath) }

        #expect(target.writtenTurns.map(\.textPreview) == ["message 4", "message 5"])
        #expect(result.sourceTurnCount == 5)
        #expect(result.migratedTurnCount == 2)
        #expect(!FileManager.default.fileExists(atPath: sourcePath))
        #expect(FileManager.default.fileExists(atPath: result.backupPath))
    }

    @Test("Migration can keep recent turns within a character budget")
    func migrateRecentTurnsWithinCharacterBudget() async throws {
        let sourcePath = try writeSourceFile()
        defer {
            try? FileManager.default.removeItem(atPath: sourcePath)
            try? FileManager.default.removeItem(atPath: sourcePath + ".bak")
        }
        let source = MockMigrationStore(turns: sampleTurns)
        let target = MockMigrationStore()

        let result = try await SessionMigrator.migrate(
            sourceSessionPath: sourcePath,
            sourceStore: source,
            targetStore: target,
            projectPath: "/tmp/project",
            recentCharacterLimit: 18
        )
        defer { try? FileManager.default.removeItem(atPath: result.newSessionPath) }

        #expect(target.writtenTurns.map(\.textPreview) == ["message 4", "message 5"])
        #expect(result.sourceTurnCount == 5)
        #expect(result.migratedTurnCount == 2)
    }

    @Test("Character budget always retains the newest turn")
    func characterBudgetRetainsNewestTurn() async throws {
        let sourcePath = try writeSourceFile()
        defer {
            try? FileManager.default.removeItem(atPath: sourcePath)
            try? FileManager.default.removeItem(atPath: sourcePath + ".bak")
        }
        let source = MockMigrationStore(turns: sampleTurns)
        let target = MockMigrationStore()

        let result = try await SessionMigrator.migrate(
            sourceSessionPath: sourcePath,
            sourceStore: source,
            targetStore: target,
            projectPath: "/tmp/project",
            recentCharacterLimit: 1
        )
        defer { try? FileManager.default.removeItem(atPath: result.newSessionPath) }

        #expect(target.writtenTurns.map(\.textPreview) == ["message 5"])
    }

    private var sampleTurns: [ConversationTurn] {
        (1...5).map { index in
            ConversationTurn(
                index: index - 1,
                lineNumber: index,
                role: index.isMultiple(of: 2) ? "assistant" : "user",
                textPreview: "message \(index)"
            )
        }
    }

    private func writeSourceFile() throws -> String {
        let path = "/tmp/kanban-session-migrator-\(UUID().uuidString).jsonl"
        try "source\n".write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }
}

@Suite("ClaudeCodeSessionStore migration writer")
struct ClaudeMigrationWriterTests {
    /// Claude Code's interactive `--resume` hard-fails ("Failed to resume session")
    /// when an assistant line lacks `message.model`. Print mode tolerates it, which
    /// is why this regressed silently. Every written assistant line must carry model.
    @Test("Written assistant lines always carry message.model")
    func assistantLinesCarryModel() async throws {
        let store = ClaudeCodeSessionStore()
        let sessionId = "aabbccdd-0000-4000-8000-\(String(UUID().uuidString.suffix(12)))".lowercased()
        let projectPath = "/tmp/kanban-migration-writer-test-\(UUID().uuidString.prefix(8))"

        let turns = [
            ConversationTurn(index: 0, lineNumber: 1, role: "user", textPreview: "hello", contentBlocks: [
                ContentBlock(kind: .text, text: "hello")
            ]),
            // No modelName → must get the fallback marker
            ConversationTurn(index: 1, lineNumber: 2, role: "assistant", textPreview: "hi", contentBlocks: [
                ContentBlock(kind: .text, text: "hi"),
                ContentBlock(kind: .toolUse(name: "shell", input: ["command": "ls"]), text: "ls -> ok")
            ]),
            // Source model known (e.g. Codex) → must be preserved verbatim
            ConversationTurn(index: 2, lineNumber: 3, role: "assistant", textPreview: "done", contentBlocks: [
                ContentBlock(kind: .text, text: "done")
            ], modelName: "gpt-5.6-sol")
        ]

        let path = try await store.writeSession(turns: turns, sessionId: sessionId, projectPath: projectPath)
        defer {
            try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
        }

        let content = try String(contentsOfFile: path, encoding: .utf8)
        var assistantModels: [String] = []
        for line in content.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any] else { continue }
            let model = message["model"] as? String
            #expect(model != nil && model?.isEmpty == false, "assistant line missing message.model — breaks claude --resume")
            assistantModels.append(model ?? "")
            #expect(message["usage"] is [String: Any], "assistant line should carry usage for shape fidelity")
        }
        #expect(assistantModels == [ClaudeCodeSessionStore.migratedModelFallback, "gpt-5.6-sol"])
    }

    @Test("TranscriptReader captures assistant model for round-trip")
    func transcriptReaderCapturesModel() async throws {
        let path = "/tmp/kanban-model-roundtrip-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let lines = [
            #"{"type":"user","uuid":"u1","sessionId":"s","message":{"role":"user","content":"hi"}}"#,
            #"{"type":"assistant","uuid":"a1","parentUuid":"u1","sessionId":"s","message":{"role":"assistant","model":"claude-opus-4-7","content":[{"type":"text","text":"hello"}]}}"#
        ]
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let turns = try await TranscriptReader.readTurns(from: path)
        let assistant = turns.first { $0.role == "assistant" }
        #expect(assistant?.modelName == "claude-opus-4-7")
    }
}

private final class MockMigrationStore: SessionStore, @unchecked Sendable {
    private let turns: [ConversationTurn]
    var writtenTurns: [ConversationTurn] = []

    init(turns: [ConversationTurn] = []) {
        self.turns = turns
    }

    func readTranscript(sessionPath: String) async throws -> [ConversationTurn] {
        turns
    }

    func forkSession(sessionPath: String, targetDirectory: String?) async throws -> String {
        "forked"
    }

    func truncateSession(sessionPath: String, afterTurn: ConversationTurn) async throws {}

    func searchSessions(query: String, paths: [String]) async throws -> [SearchResult] {
        []
    }

    func writeSession(turns: [ConversationTurn], sessionId: String, projectPath: String?) async throws -> String {
        writtenTurns = turns
        let path = "/tmp/kanban-session-migrator-target-\(sessionId).jsonl"
        try "target\n".write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }
}
