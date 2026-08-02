import Foundation
import Testing
@testable import KanbanCodeCore

@Suite("Block line reading")
struct FileLinesTests {
    private func withTempFile(_ contents: Data, _ body: (FileHandle) async throws -> Void) async throws {
        let path = NSTemporaryDirectory() + "kanban-filelines-\(UUID().uuidString).jsonl"
        try contents.write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }
        let handle = try #require(FileHandle(forReadingAtPath: path))
        defer { try? handle.close() }
        try await body(handle)
    }

    private func collect(_ handle: FileHandle, chunkSize: Int) async throws -> [String] {
        var lines: [String] = []
        for try await line in FileLines(handle: handle, chunkSize: chunkSize) {
            lines.append(line)
        }
        return lines
    }

    @Test("Lines survive being split across chunk boundaries")
    func splitsAcrossChunks() async throws {
        let payload = (0..<500).map { "{\"type\":\"user\",\"n\":\($0)}" }.joined(separator: "\n")
        try await withTempFile(Data(payload.utf8)) { handle in
            let lines = try await collect(handle, chunkSize: 4096)
            #expect(lines.count == 500)
            #expect(lines.first == "{\"type\":\"user\",\"n\":0}")
            #expect(lines.last == "{\"type\":\"user\",\"n\":499}")
        }
    }

    @Test("Multi-byte characters are never cut in half")
    func keepsMultiByteCharactersIntact() async throws {
        // Emoji and accents land on different offsets in every chunk size, so a
        // reader that decoded raw chunks instead of whole lines would corrupt them.
        let payload = (0..<200).map { "line \($0) 🚀 café ✨" }.joined(separator: "\n") + "\n"
        try await withTempFile(Data(payload.utf8)) { handle in
            let lines = try await collect(handle, chunkSize: 4096)
            #expect(lines.count == 200)
            #expect(lines.allSatisfy { $0.contains("🚀") && $0.contains("café") })
            #expect(!lines.contains { $0.contains("\u{FFFD}") })
        }
    }

    @Test("A final line without a trailing newline is still yielded")
    func yieldsUnterminatedFinalLine() async throws {
        try await withTempFile(Data("first\nsecond".utf8)) { handle in
            let lines = try await collect(handle, chunkSize: 4096)
            #expect(lines == ["first", "second"])
        }
    }

    @Test("Blank lines and carriage returns are cleaned up")
    func skipsBlanksAndTrimsCarriageReturns() async throws {
        try await withTempFile(Data("one\r\n\n\ntwo\r\n".utf8)) { handle in
            let lines = try await collect(handle, chunkSize: 4096)
            #expect(lines == ["one", "two"])
        }
    }

    @Test("An empty file yields nothing")
    func emptyFile() async throws {
        try await withTempFile(Data()) { handle in
            let lines = try await collect(handle, chunkSize: 4096)
            #expect(lines.isEmpty)
        }
    }

    @Test("A line longer than one chunk is reassembled")
    func handlesLineLongerThanChunk() async throws {
        let long = String(repeating: "x", count: 20_000)
        try await withTempFile(Data("short\n\(long)\nend\n".utf8)) { handle in
            let lines = try await collect(handle, chunkSize: 4096)
            #expect(lines == ["short", long, "end"])
        }
    }
}
