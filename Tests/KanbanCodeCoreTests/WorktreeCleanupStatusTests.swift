import Foundation
import Testing

@testable import KanbanCodeCore

/// Worktree removal is forced, so the cleanup dialog has to know what it would
/// throw away. These run real git against throwaway repos because the answer
/// depends on how git sees merges, not on anything we parse.
@Suite("Worktree cleanup status")
struct WorktreeCleanupStatusTests {

    private let adapter = GitWorktreeAdapter()

    @Test("a fast-forward merged, clean worktree is safe to remove")
    func mergedAndClean() async throws {
        let repo = try Repo()
        defer { repo.cleanUp() }
        try repo.commitInWorktree("feature.txt")
        try repo.git(["merge", "--ff-only", "feature"])

        let status = try #require(await adapter.cleanupStatus(worktreePath: repo.worktree))
        #expect(status.baseBranch == "main")
        #expect(status.mergeState == .merged)
        #expect(status.uncommittedFileCount == 0)
        #expect(status.isSafeToRemove)
    }

    @Test("a squash merge counts as merged")
    func squashMerged() async throws {
        let repo = try Repo()
        defer { repo.cleanUp() }
        try repo.commitInWorktree("a.txt")
        try repo.commitInWorktree("b.txt")
        try repo.git(["merge", "--squash", "feature"])
        try repo.git(["commit", "-q", "-m", "squash"])

        let status = try #require(await adapter.cleanupStatus(worktreePath: repo.worktree))
        #expect(status.mergeState == .merged)
    }

    @Test("commits the base does not have are reported")
    func notMerged() async throws {
        let repo = try Repo()
        defer { repo.cleanUp() }
        try repo.commitInWorktree("feature.txt")

        let status = try #require(await adapter.cleanupStatus(worktreePath: repo.worktree))
        #expect(status.mergeState == .notMerged)
        #expect(!status.isSafeToRemove)
    }

    @Test("uncommitted and untracked files are counted")
    func dirty() async throws {
        let repo = try Repo()
        defer { repo.cleanUp() }
        try "changed".write(toFile: repo.worktree + "/README", atomically: true, encoding: .utf8)
        try "new".write(toFile: repo.worktree + "/new.txt", atomically: true, encoding: .utf8)

        let status = try #require(await adapter.cleanupStatus(worktreePath: repo.worktree))
        #expect(status.mergeState == .merged)
        #expect(status.uncommittedFileCount == 2)
        #expect(!status.isSafeToRemove)
    }

    @Test("without main or master the merge state is unknown")
    func noBaseBranch() async throws {
        let repo = try Repo(baseBranch: "trunk")
        defer { repo.cleanUp() }

        let status = try #require(await adapter.cleanupStatus(worktreePath: repo.worktree))
        #expect(status.baseBranch == nil)
        #expect(status.mergeState == .unknown)
        #expect(!status.isSafeToRemove)
    }

    @Test("a path that does not exist here cannot be inspected")
    func missingPath() async {
        #expect(await adapter.cleanupStatus(worktreePath: "/nonexistent/.claude/worktrees/x") == nil)
    }
}

/// A repo with one commit on the base branch and a `feature` worktree.
private struct Repo {
    let root: String
    let worktree: String

    init(baseBranch: String = "main") throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("wt-status-\(UUID().uuidString)").path
        root = base + "/repo"
        worktree = base + "/feature"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", baseBranch])
        try "readme".write(toFile: root + "/README", atomically: true, encoding: .utf8)
        try git(["add", "."])
        try git(["commit", "-q", "-m", "init"])
        try git(["worktree", "add", "-q", "-b", "feature", worktree])
    }

    func commitInWorktree(_ file: String) throws {
        try file.write(toFile: worktree + "/" + file, atomically: true, encoding: .utf8)
        try git(["add", "."], in: worktree)
        try git(["commit", "-q", "-m", file], in: worktree)
    }

    @discardableResult
    func git(_ arguments: [String], in directory: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=Test", "-c", "user.email=test@example.com",
                             "-c", "commit.gpgsign=false"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory ?? root)
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "git", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")): \(output)"])
        }
        return output
    }

    func cleanUp() {
        try? FileManager.default.removeItem(atPath: (root as NSString).deletingLastPathComponent)
    }
}
