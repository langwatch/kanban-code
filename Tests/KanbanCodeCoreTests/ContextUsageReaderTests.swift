import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("ContextUsageReader")
struct ContextUsageReaderTests {

    private func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "kanban-context-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ dir: String) {
        try? FileManager.default.removeItem(atPath: dir)
    }

    @Test("Reads valid context usage file")
    func readsValid() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let json = """
        {"usedPercentage":42.5,"contextWindowSize":200000,"totalInputTokens":50000,"totalOutputTokens":12000,"totalCostUsd":0.23,"model":"Claude Opus 4"}
        """
        try json.write(toFile: (dir as NSString).appendingPathComponent("s1.json"), atomically: true, encoding: .utf8)

        let usage = ContextUsageReader.read(sessionId: "s1", basePath: dir)
        #expect(usage != nil)
        #expect(usage?.usedPercentage == 42.5)
        #expect(usage?.contextWindowSize == 200000)
        #expect(usage?.totalInputTokens == 50000)
        #expect(usage?.totalOutputTokens == 12000)
        #expect(usage?.totalCostUsd == 0.23)
        #expect(usage?.model == "Claude Opus 4")
    }

    @Test("Returns nil for missing file")
    func missingFile() {
        let usage = ContextUsageReader.read(sessionId: "nonexistent", basePath: "/tmp/nonexistent-dir")
        #expect(usage == nil)
    }

    @Test("Returns nil for malformed JSON")
    func malformedJson() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        try "not json".write(toFile: (dir as NSString).appendingPathComponent("bad.json"), atomically: true, encoding: .utf8)

        let usage = ContextUsageReader.read(sessionId: "bad", basePath: dir)
        #expect(usage == nil)
    }

    @Test("Handles missing optional fields (cost, model)")
    func missingOptionals() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let json = """
        {"usedPercentage":10.0,"contextWindowSize":1000000,"totalInputTokens":5000,"totalOutputTokens":1000}
        """
        try json.write(toFile: (dir as NSString).appendingPathComponent("s2.json"), atomically: true, encoding: .utf8)

        let usage = ContextUsageReader.read(sessionId: "s2", basePath: dir)
        #expect(usage != nil)
        #expect(usage?.usedPercentage == 10.0)
        #expect(usage?.contextWindowSize == 1000000)
        #expect(usage?.totalCostUsd == nil)
        #expect(usage?.model == nil)
    }

    @Test("Statusline display names reduce to a --model alias")
    func modelAliasFromDisplayName() {
        func usage(_ model: String?) -> ContextUsage {
            ContextUsage(
                usedPercentage: 10,
                contextWindowSize: 1_000_000,
                totalInputTokens: 0,
                totalOutputTokens: 0,
                model: model
            )
        }

        #expect(usage("Opus 5 (1M context)").modelAlias == "opus")
        #expect(usage("Fable 5").modelAlias == "fable")
        #expect(usage("Claude Sonnet 4.5").modelAlias == "sonnet")
        #expect(usage("claude-opus-4-5-20251101").modelAlias == "opus")
        #expect(usage(nil).modelAlias == nil)
        #expect(usage("5").modelAlias == nil)
    }

    @Test("Returns nil when required fields are missing")
    func missingRequired() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let json = """
        {"usedPercentage":42.5,"model":"Claude"}
        """
        try json.write(toFile: (dir as NSString).appendingPathComponent("s3.json"), atomically: true, encoding: .utf8)

        let usage = ContextUsageReader.read(sessionId: "s3", basePath: dir)
        #expect(usage == nil, "Missing contextWindowSize/tokens should return nil")
    }
}
