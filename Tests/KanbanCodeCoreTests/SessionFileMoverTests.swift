import Foundation
import Testing

@testable import KanbanCodeCore

@Suite("SessionFileMover path encoding")
struct SessionFileMoverTests {
    @Test("Encodes a plain project path the way Claude does")
    func encodesPlainPath() {
        #expect(
            SessionFileMover.encodeProjectPath("/Users/foo/Projects/bar")
                == "-Users-foo-Projects-bar"
        )
        #expect(
            SessionFileMover.encodeProjectPath("/Users/foo/.claude/worktrees/bar")
                == "-Users-foo--claude-worktrees-bar"
        )
    }

    @Test("Resolves a symlinked project to its real path before encoding")
    func resolvesSymlink() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kanban-symlink-\(UUID().uuidString)")
        let real = root.appendingPathComponent("nexus")
        let link = root.appendingPathComponent("traffic-machine")
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createSymbolicLink(at: link, withDestinationURL: real)

        // Claude encodes the resolved cwd, so both spellings must agree —
        // otherwise the session lands where --resume never looks.
        let viaLink = SessionFileMover.encodeProjectPath(link.path)
        let viaReal = SessionFileMover.encodeProjectPath(real.path)
        #expect(viaLink == viaReal)
        #expect(viaLink.hasSuffix("-nexus"))
    }

    @Test("Resolves the existing prefix of a not-yet-created path")
    func resolvesExistingPrefix() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kanban-symlink-\(UUID().uuidString)")
        let real = root.appendingPathComponent("nexus")
        let link = root.appendingPathComponent("traffic-machine")
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createSymbolicLink(at: link, withDestinationURL: real)

        let future = link.appendingPathComponent("worktrees/not-created-yet").path
        let resolved = SessionFileMover.resolveSymlinks(future)
        #expect(resolved.hasSuffix("/nexus/worktrees/not-created-yet"))
        #expect(!resolved.contains("traffic-machine"))
    }

    @Test("Leaves an unresolvable path untouched")
    func leavesMissingPathAlone() {
        let path = "/definitely/not/here-\(UUID().uuidString)"
        #expect(SessionFileMover.resolveSymlinks(path) == path)
    }

    @Test("Rewrites only top-level cwd values and keeps every other byte")
    func rewritesTopLevelCwd() throws {
        let input = [
            #"{"type":"user","cwd":"/old/wt","message":{"content":"run in \"cwd\":\"/x\""},"extra":{"cwd":"/nested"}}"#,
            #"{"type":"summary","summary":"no cwd here"}"#,
            #"{"cwd": "/old/sub" ,"uuid":"a"}"#,
            "",
        ].joined(separator: "\n")
        let output = try #require(SessionFileMover.rewriteCwd(Data(input.utf8), to: "/new/root"))
        let expected = [
            #"{"type":"user","cwd":"/new/root","message":{"content":"run in \"cwd\":\"/x\""},"extra":{"cwd":"/nested"}}"#,
            #"{"type":"summary","summary":"no cwd here"}"#,
            #"{"cwd": "/new/root" ,"uuid":"a"}"#,
            "",
        ].joined(separator: "\n")
        #expect(String(decoding: output, as: UTF8.self) == expected)
        #expect(SessionFileMover.rewriteCwd(output, to: "/new/root") == nil)
    }

    @Test("Moves a 100 MB transcript in seconds, not minutes")
    func movesLargeTranscriptFast() throws {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let sessionId = "mover-test-\(UUID().uuidString)"
        let sourceDir = home + "/.claude/projects/-kanban-mover-test-src-\(sessionId)"
        let target = "/kanban-mover-test-dst-\(sessionId)"
        let targetDir = home + "/.claude/projects/" + SessionFileMover.encodeProjectPath(target)
        try fm.createDirectory(atPath: sourceDir, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(atPath: sourceDir)
            try? fm.removeItem(atPath: targetDir)
        }
        let line = #"{"type":"assistant","cwd":"/kanban-mover-test-src","message":{"content":""# + String(repeating: "x", count: 2000) + #""}}"#
        let source = sourceDir + "/\(sessionId).jsonl"
        let lineCount = 50_000 // ~100 MB
        try Data((Array(repeating: line, count: lineCount).joined(separator: "\n") + "\n").utf8).write(to: URL(fileURLWithPath: source))

        let started = Date()
        let moved = try SessionFileMover.moveSession(sessionId: sessionId, fromPath: source, toProjectPath: target)
        let elapsed = Date().timeIntervalSince(started)

        #expect(moved == targetDir + "/\(sessionId).jsonl")
        #expect(!fm.fileExists(atPath: source))
        let content = try String(contentsOfFile: moved, encoding: .utf8)
        #expect(content.hasPrefix(#"{"type":"assistant","cwd":"/kanban-mover-test-dst-"#))
        #expect(!content.contains("/kanban-mover-test-src\""))
        #expect(elapsed < 10, "took \(elapsed)s")
    }
}
