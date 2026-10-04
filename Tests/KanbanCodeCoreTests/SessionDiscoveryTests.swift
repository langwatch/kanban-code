import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("ClaudeCodeSessionDiscovery")
struct SessionDiscoveryTests {
    func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "kanban-code-discovery-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    func cleanup(_ dir: String) {
        try? FileManager.default.removeItem(atPath: dir)
    }

    @Test("Discovers sessions from .jsonl files")
    func discoverFromJsonl() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        // Create a fake project directory
        let projectDir = (dir as NSString).appendingPathComponent("-Users-test-project")
        try FileManager.default.createDirectory(atPath: projectDir, withIntermediateDirectories: true)

        // Write a .jsonl file
        let jsonlPath = (projectDir as NSString).appendingPathComponent("session-1.jsonl")
        try [
            #"{"type":"user","sessionId":"session-1","message":{"content":"Hello"},"cwd":"/Users/test/project"}"#,
            #"{"type":"assistant","sessionId":"session-1","message":{"content":[{"type":"text","text":"Hi there"}]}}"#,
        ].joined(separator: "\n").write(toFile: jsonlPath, atomically: true, encoding: .utf8)

        let discovery = ClaudeCodeSessionDiscovery(claudeDir: dir)
        let sessions = try await discovery.discoverSessions()

        #expect(sessions.count == 1)
        #expect(sessions[0].id == "session-1")
        #expect(sessions[0].firstPrompt == "Hello")
        #expect(sessions[0].messageCount >= 2)
    }

    @Test("Merges index metadata with .jsonl scan")
    func mergeIndexAndJsonl() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let projectDir = (dir as NSString).appendingPathComponent("-Users-test-myproject")
        try FileManager.default.createDirectory(atPath: projectDir, withIntermediateDirectories: true)

        // Write index with summary
        let indexPath = (projectDir as NSString).appendingPathComponent("sessions-index.json")
        let indexData = #"{"sessions":[{"sessionId":"sess-2","summary":"Fix login flow"}]}"#
        try indexData.write(toFile: indexPath, atomically: true, encoding: .utf8)

        // Write .jsonl with the actual conversation
        let jsonlPath = (projectDir as NSString).appendingPathComponent("sess-2.jsonl")
        try #"{"type":"user","sessionId":"sess-2","message":{"content":"Fix the login"},"cwd":"/test"}"#
            .write(toFile: jsonlPath, atomically: true, encoding: .utf8)

        let discovery = ClaudeCodeSessionDiscovery(claudeDir: dir)
        let sessions = try await discovery.discoverSessions()

        #expect(sessions.count == 1)
        #expect(sessions[0].id == "sess-2")
        #expect(sessions[0].name == "Fix login flow") // from index
        #expect(sessions[0].firstPrompt == "Fix the login") // from .jsonl
    }

    @Test("Filters out zero-message sessions")
    func filterZeroMessages() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let projectDir = (dir as NSString).appendingPathComponent("-Users-test-empty")
        try FileManager.default.createDirectory(atPath: projectDir, withIntermediateDirectories: true)

        // Write a .jsonl with only system lines
        let jsonlPath = (projectDir as NSString).appendingPathComponent("empty-sess.jsonl")
        try #"{"type":"file-history-snapshot","data":"stuff"}"#
            .write(toFile: jsonlPath, atomically: true, encoding: .utf8)

        let discovery = ClaudeCodeSessionDiscovery(claudeDir: dir)
        let sessions = try await discovery.discoverSessions()

        #expect(sessions.isEmpty)
    }

    @Test("Empty directory returns empty")
    func emptyDir() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let discovery = ClaudeCodeSessionDiscovery(claudeDir: dir)
        let sessions = try await discovery.discoverSessions()

        #expect(sessions.isEmpty)
    }

    @Test("Nonexistent directory returns empty")
    func nonexistentDir() async throws {
        let discovery = ClaudeCodeSessionDiscovery(claudeDir: "/nonexistent/path")
        let sessions = try await discovery.discoverSessions()
        #expect(sessions.isEmpty)
    }

    @Test("Sessions sorted by modification time (newest first)")
    func sortedByModTime() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let projectDir = (dir as NSString).appendingPathComponent("-Users-test-sorted")
        try FileManager.default.createDirectory(atPath: projectDir, withIntermediateDirectories: true)

        // Write two .jsonl files
        let path1 = (projectDir as NSString).appendingPathComponent("old-sess.jsonl")
        try #"{"type":"user","sessionId":"old-sess","message":{"content":"Old"},"cwd":"/test"}"#
            .write(toFile: path1, atomically: true, encoding: .utf8)

        // Small delay to ensure different mtime
        try await Task.sleep(for: .milliseconds(100))

        let path2 = (projectDir as NSString).appendingPathComponent("new-sess.jsonl")
        try #"{"type":"user","sessionId":"new-sess","message":{"content":"New"},"cwd":"/test"}"#
            .write(toFile: path2, atomically: true, encoding: .utf8)

        let discovery = ClaudeCodeSessionDiscovery(claudeDir: dir)
        let sessions = try await discovery.discoverSessions()

        #expect(sessions.count == 2)
        #expect(sessions[0].id == "new-sess") // newest first
        #expect(sessions[1].id == "old-sess")
    }

    @Test("A transcript moved to another project directory keeps its session, at the new path")
    func transcriptMovedBetweenProjectDirs() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let rootDir = (dir as NSString).appendingPathComponent("-Users-test-app")
        let worktreeDir = (dir as NSString).appendingPathComponent("-Users-test-app--claude-worktrees-one")
        for path in [rootDir, worktreeDir] {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        let inRoot = (rootDir as NSString).appendingPathComponent("moved-sess.jsonl")
        let inWorktree = (worktreeDir as NSString).appendingPathComponent("moved-sess.jsonl")
        try #"{"type":"user","sessionId":"moved-sess","message":{"content":"Hi"},"cwd":"/Users/test/app"}"#
            .write(toFile: inRoot, atomically: true, encoding: .utf8)

        let discovery = ClaudeCodeSessionDiscovery(claudeDir: dir)
        #expect(try await discovery.discoverSessions().first?.jsonlPath == inRoot)

        // Both directions, so the result holds whichever directory is scanned first.
        for (from, to) in [(inRoot, inWorktree), (inWorktree, inRoot)] {
            try await Task.sleep(for: .milliseconds(20))
            try FileManager.default.moveItem(atPath: from, toPath: to)
            let first = try await discovery.discoverSessions()
            #expect(first.map(\.jsonlPath) == [to])
            let second = try await discovery.discoverSessions()
            #expect(second.map(\.jsonlPath) == [to])
        }
    }
}
