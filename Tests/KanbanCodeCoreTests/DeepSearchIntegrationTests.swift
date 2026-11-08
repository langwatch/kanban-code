import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("Deep Search")
struct DeepSearchIntegrationTests {

    let store = ClaudeCodeSessionStore()

    func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "kanban-code-search-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    func cleanup(_ dir: String) {
        try? FileManager.default.removeItem(atPath: dir)
    }

    @Test("Deep search completes and returns results")
    func searchCompletes() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let path = (dir as NSString).appendingPathComponent("s1.jsonl")
        try #"{"type":"user","sessionId":"s1","message":{"content":"Fix the authentication bug"},"cwd":"/test"}"#
            .write(toFile: path, atomically: true, encoding: .utf8)

        let results = try await store.searchSessions(query: "authentication", paths: [path])
        #expect(!results.isEmpty)
        #expect(results[0].score > 0)
        #expect(!results[0].snippets.isEmpty)
    }

    @Test("Deep search handles missing files gracefully")
    func searchMissingFiles() async throws {
        let results = try await store.searchSessions(
            query: "test",
            paths: ["/nonexistent/path/session.jsonl", "/another/missing.jsonl"]
        )
        #expect(results.isEmpty)
    }

    @Test("Deep search handles empty query")
    func searchEmptyQuery() async throws {
        let results = try await store.searchSessions(query: "", paths: ["/test.jsonl"])
        #expect(results.isEmpty)
    }

    @Test("Deep search handles mix of valid and invalid paths")
    func searchMixedPaths() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let validPath = (dir as NSString).appendingPathComponent("s1.jsonl")
        try #"{"type":"user","sessionId":"s1","message":{"content":"Implement the database migration"},"cwd":"/test"}"#
            .write(toFile: validPath, atomically: true, encoding: .utf8)

        let results = try await store.searchSessions(
            query: "database migration",
            paths: ["/nonexistent.jsonl", validPath, "/also-missing.jsonl"]
        )
        #expect(results.count == 1)
        #expect(results[0].sessionPath == validPath)
    }

    @Test("Deep search yields each match as it lands, not in batches")
    func searchYieldsPerMatch() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        // More files than fit in the scanning window, so a barrier between
        // groups of files would show up as far fewer callbacks than matches.
        let matchCount = 4 * max(4, ProcessInfo.processInfo.activeProcessorCount)
        var paths: [String] = []
        for index in 0..<matchCount {
            let path = (dir as NSString).appendingPathComponent("s\(index).jsonl")
            try #"{"type":"user","sessionId":"s\#(index)","message":{"content":"Fix the authentication bug"},"cwd":"/test"}"#
                .write(toFile: path, atomically: true, encoding: .utf8)
            paths.append(path)
        }

        let deliveries = Counter()
        try await store.searchSessionsStreaming(query: "authentication", paths: paths) { results in
            deliveries.record(results.count)
        }

        // One delivery per matching file, each carrying every match found so far.
        #expect(deliveries.counts == Array(1...matchCount))
    }

    /// Collects the size of every streamed delivery.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int] = []
        func record(_ count: Int) { lock.lock(); values.append(count); lock.unlock() }
        var counts: [Int] { lock.lock(); defer { lock.unlock() }; return values }
    }

    @Test("Deep search respects task cancellation")
    func searchCancellation() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        // Create several files
        var paths: [String] = []
        for i in 0..<10 {
            let path = (dir as NSString).appendingPathComponent("s\(i).jsonl")
            try #"{"type":"user","sessionId":"s\#(i)","message":{"content":"Some content \#(i)"},"cwd":"/test"}"#
                .write(toFile: path, atomically: true, encoding: .utf8)
            paths.append(path)
        }

        let task = Task {
            try await store.searchSessions(query: "content", paths: paths)
        }
        task.cancel()
        // Should complete without hanging — either returns partial results or throws CancellationError
        do {
            let results = try await task.value
            #expect(results.count <= 10)
        } catch is CancellationError {
            // Expected — cancellation is cooperative and may throw
        }
    }
}

@Suite("SessionIndexReader Update")
struct SessionIndexUpdateTests {

    func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "kanban-code-index-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    func cleanup(_ dir: String) {
        try? FileManager.default.removeItem(atPath: dir)
    }

    @Test("updateSummary updates session in index file")
    func updateSummary() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        // Create a project directory with sessions-index.json
        let projectDir = (dir as NSString).appendingPathComponent("-test-project")
        try FileManager.default.createDirectory(atPath: projectDir, withIntermediateDirectories: true)

        let indexPath = (projectDir as NSString).appendingPathComponent("sessions-index.json")
        let indexContent: [String: Any] = [
            "version": 1,
            "entries": [
                ["sessionId": "abc-123", "summary": "Old Name", "messageCount": 5] as [String: Any],
                ["sessionId": "def-456", "summary": "Other Session", "messageCount": 3] as [String: Any],
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: indexContent, options: [.prettyPrinted])
        try data.write(to: URL(fileURLWithPath: indexPath))

        // Update summary
        try SessionIndexReader.updateSummary(
            sessionId: "abc-123",
            summary: "My Custom Name",
            claudeDir: dir
        )

        // Verify
        let updated = try Data(contentsOf: URL(fileURLWithPath: indexPath))
        let root = try JSONSerialization.jsonObject(with: updated) as! [String: Any]
        let entries = root["entries"] as! [[String: Any]]
        let target = entries.first { $0["sessionId"] as? String == "abc-123" }
        #expect(target?["summary"] as? String == "My Custom Name")

        // Other session untouched
        let other = entries.first { $0["sessionId"] as? String == "def-456" }
        #expect(other?["summary"] as? String == "Other Session")
    }

    @Test("updateSummary handles missing session gracefully")
    func updateSummaryMissing() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        // No index files — should not throw
        try SessionIndexReader.updateSummary(
            sessionId: "nonexistent",
            summary: "Name",
            claudeDir: dir
        )
    }
}
