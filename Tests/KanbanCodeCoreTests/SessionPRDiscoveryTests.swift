import Foundation
import Testing

@testable import KanbanCodeCore

/// What a session says about the branches and pull requests it worked on.
@Suite("Session PR discovery")
struct SessionPRDiscoveryTests {

    private func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "kanban-code-pr-discovery-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ dir: String, _ lines: [String]) throws -> String {
        let path = (dir as NSString).appendingPathComponent("session.jsonl")
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func bash(_ command: String, cwd: String?) -> String {
        let escaped = command.replacingOccurrences(of: "\"", with: "\\\"")
        let cwdField = cwd.map { #""cwd":"\#($0)","# } ?? ""
        return """
            {"type":"assistant",\(cwdField)"message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"\(escaped)"}}]}}
            """
    }

    private func prLink(_ number: Int, repository: String = "langwatch/langwatch") -> String {
        """
        {"type":"pr-link","sessionId":"s1","prNumber":\(number),"prUrl":"https://github.com/\(repository)/pull/\(number)","prRepository":"\(repository)"}
        """
    }

    // MARK: - Which repository a branch belongs to

    @Test("a command with no cd belongs to the repository the session runs in")
    func repoComesFromTheWorkingDirectory() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = try write(dir, [
            bash("git checkout -b feat/sessions-screen", cwd: "/repos/langwatch")
        ])

        let found = try await JsonlParser.extractPushedBranches(from: path)

        #expect(found.count == 1)
        #expect(found.first?.branch == "feat/sessions-screen")
        #expect(found.first?.repoPath == "/repos/langwatch")
    }

    @Test("a worktree the session runs in resolves to the repository holding it")
    func worktreeResolvesToItsRepo() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = try write(dir, [
            bash(
                "git push -q origin feat/sessions-screen",
                cwd: "/repos/langwatch/.claude/worktrees/read-path")
        ])

        let found = try await JsonlParser.extractPushedBranches(from: path)

        #expect(found.first?.repoPath == "/repos/langwatch")
    }

    @Test("an explicit cd still says where the command ran")
    func explicitCdWins() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = try write(dir, [
            bash(
                "cd /repos/other && git push origin feat/elsewhere", cwd: "/repos/langwatch")
        ])

        let found = try await JsonlParser.extractPushedBranches(from: path)

        #expect(found.first?.repoPath == "/repos/other")
    }

    @Test("the newest pushed branch carries its repository too")
    func latestPushedBranchHasRepo() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = try write(dir, [
            bash("git push origin feat/first", cwd: "/repos/langwatch"),
            bash("git push origin feat/second", cwd: "/repos/langwatch/.claude/worktrees/w"),
        ])

        let latest = try await JsonlParser.extractLatestPushedBranch(from: path)

        #expect(latest?.branch == "feat/second")
        #expect(latest?.repoPath == "/repos/langwatch")
    }

    @Test("a push to main through a refspec is not a feature branch")
    func refspecPushToMainIsSkipped() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = try write(dir, [
            bash("git push origin feat/real", cwd: "/repos/langwatch"),
            bash("git push origin HEAD:main", cwd: "/repos/langwatch"),
        ])

        let latest = try await JsonlParser.extractLatestPushedBranch(from: path)

        #expect(latest?.branch == "feat/real")
    }

    @Test("a refspec push names the branch it lands on")
    func refspecPushNamesTheRemoteBranch() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = try write(dir, [
            bash("git push -u origin +HEAD:refs/heads/fix/remote-name", cwd: "/repos/langwatch"),
        ])

        let latest = try await JsonlParser.extractLatestPushedBranch(from: path)
        let all = try await JsonlParser.extractPushedBranches(from: path)

        #expect(latest?.branch == "fix/remote-name")
        #expect(all.map(\.branch) == ["fix/remote-name"])
    }

    @Test("the capped scan does not read a push further back than its window")
    func cappedScanStopsAtTheWindow() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let filler = (0..<200).map { i in bash("echo \(String(repeating: "x", count: 1000)) \(i)", cwd: "/repos/langwatch") }
        let path = try write(dir, [bash("git push origin feat/old", cwd: "/repos/langwatch")] + filler)

        let capped = try await JsonlParser.extractLatestPushedBranch(from: path, maxBytes: 64 * 1024)
        let full = try await JsonlParser.extractLatestPushedBranch(from: path)

        #expect(capped == nil)
        #expect(full?.branch == "feat/old")
    }

    // MARK: - Pull requests the session recorded

    @Test("a pull request the session worked on is found without any push")
    func linkedPRWithoutAPush() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = try write(dir, [
            bash("gh pr view 6849 --json state", cwd: "/repos/langwatch"),
            prLink(6849),
        ])

        let pushed = try await JsonlParser.extractPushedBranches(from: path)
        let linked = try await JsonlParser.extractLinkedPRs(from: path)

        #expect(pushed.isEmpty)
        #expect(linked.count == 1)
        #expect(linked.first?.number == 6849)
        #expect(linked.first?.repository == "langwatch/langwatch")
        #expect(linked.first?.url == "https://github.com/langwatch/langwatch/pull/6849")
    }

    @Test("one pull request is reported once however often it is recorded")
    func linkedPRsAreDeduplicated() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = try write(dir, [
            prLink(6434), prLink(6849), prLink(6434), prLink(6849), prLink(6434),
        ])

        let linked = try await JsonlParser.extractLinkedPRs(from: path)

        #expect(linked.map(\.number) == [6434, 6849])
    }

    @Test("anything that is not a record of a pull request is left alone")
    func ignoresOtherRecords() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = try write(dir, [
            #"{"type":"user","message":{"content":"look at pr-link please"}}"#,
            #"{"type":"pr-link","sessionId":"s1"}"#,
            #"{"type":"pr-link","sessionId":"s1","prNumber":0}"#,
            "{ this is not json but says pr-link",
            prLink(6849),
        ])

        let linked = try await JsonlParser.extractLinkedPRs(from: path)

        #expect(linked.map(\.number) == [6849])
    }

    @Test("a number written as text is still a number")
    func numberAsString() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = try write(dir, [
            #"{"type":"pr-link","sessionId":"s1","prNumber":"6849","prRepository":"langwatch/langwatch"}"#
        ])

        let linked = try await JsonlParser.extractLinkedPRs(from: path)

        #expect(linked.first?.number == 6849)
    }

    @Test("the newest record wins when the session moves to another pull request")
    func latestLinkedPR() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = try write(dir, [prLink(6434), prLink(6773), prLink(6849)])

        let latest = try await JsonlParser.extractLatestLinkedPR(from: path)

        #expect(latest?.number == 6849)
    }

    @Test("a session that recorded no pull request reports none")
    func noLinkedPRs() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = try write(dir, [bash("git push origin feat/x", cwd: "/repos/langwatch")])

        #expect(try await JsonlParser.extractLinkedPRs(from: path).isEmpty)
        #expect(try await JsonlParser.extractLatestLinkedPR(from: path) == nil)
    }

    @Test("a record older than the window is left to explicit discovery")
    func latestLinkedPRWindow() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let filler = String(repeating: "x", count: 4096)
        var lines = [prLink(6434)]
        for _ in 0..<64 {
            lines.append(#"{"type":"user","message":{"content":"\#(filler)"}}"#)
        }
        let path = try write(dir, lines)

        #expect(try await JsonlParser.extractLatestLinkedPR(from: path, within: 8192) == nil)
        #expect(try await JsonlParser.extractLatestLinkedPR(from: path)?.number == 6434)
    }
}
