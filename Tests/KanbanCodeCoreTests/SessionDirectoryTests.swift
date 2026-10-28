import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("session directory of a deleted worktree")
struct SessionDirectoryTests {
    /// A repository with a worktree at `.claude/worktrees/<name>` on branch
    /// `<name>`, which the test then deletes as `rm -rf` plus a prune would.
    struct Repo {
        let root: String
        let name = "clear-meadow-a7ec"
        var worktree: String { "\(root)/.claude/worktrees/\(name)" }

        init() throws {
            root = NSTemporaryDirectory() + "kanban-sessiondir-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            try sh("git init -q -b main && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init && git worktree add -q -b \(name) .claude/worktrees/\(name)")
        }

        func deleteWorktree() throws {
            try sh("rm -rf .claude/worktrees/\(name) && git worktree prune")
        }

        func deleteBranch() throws {
            try sh("git branch -q -D \(name)")
        }

        @discardableResult
        func sh(_ script: String) throws -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", script]
            p.currentDirectoryURL = URL(fileURLWithPath: root)
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            try p.run()
            p.waitUntilExit()
            let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if p.terminationStatus != 0 { throw NSError(domain: "sh", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: text]) }
            return text
        }

        func cleanup() { try? FileManager.default.removeItem(atPath: root) }
    }

    /// A stand-in rush whose `send` fails the way rush does when the host's
    /// cwd is gone: rush cannot fork itself into a directory that is missing.
    struct FakeRush {
        let dir = NSTemporaryDirectory() + "kanban-sessiondir-rush-\(UUID().uuidString)"
        var path: String { "\(dir)/rush" }

        init(cwd: String) throws {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let script = """
            #!/bin/sh
            cwd='\(cwd)'
            echo "ARGS $*" >> '\(dir)/calls.log'
            case "$2" in
              send) cat >/dev/null
                if [ ! -d "$cwd" ]; then echo 'rush: fork/exec /usr/local/bin/rush: no such file or directory' >&2; exit 1; fi
                echo SENT >> '\(dir)/calls.log' ;;
              info) printf '{"id":"%s","sessionId":"22d7452e-1111","cwd":"%s","state":"stopped","alive":false}' "$3" "$cwd" ;;
              start) echo '{"id":"22d7452e","sessionId":"22d7452e-1111","cwd":"x","state":"starting","alive":true}' ;;
              --help|session) ;;
            esac
            """
            try script.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }

        func calls() -> String { (try? String(contentsOfFile: "\(dir)/calls.log", encoding: .utf8)) ?? "" }
        func adapter() -> RushCliAdapter { RushCliAdapter(executable: path, scratchDirectory: "\(dir)/scratch") }
        func cleanup() { try? FileManager.default.removeItem(atPath: dir) }
    }

    @Test("a deleted worktree comes back from its branch")
    func restoresFromBranch() async throws {
        let repo = try Repo()
        defer { repo.cleanup() }
        try repo.deleteWorktree()
        let outcome = await SessionDirectory.ensureLocal(dir: repo.worktree)
        #expect(outcome == .restored(branch: repo.name))
        #expect(try repo.sh("git -C .claude/worktrees/\(repo.name) rev-parse --abbrev-ref HEAD").trimmingCharacters(in: .whitespacesAndNewlines) == repo.name)
    }

    @Test("a worktree deleted on another branch than its name comes back on that branch")
    func restoresRecordedBranch() async throws {
        let repo = try Repo()
        defer { repo.cleanup() }
        try repo.sh("git -C .claude/worktrees/\(repo.name) checkout -q -b feat/run-concurrency && rm -rf .claude/worktrees/\(repo.name)")
        let outcome = await SessionDirectory.ensureLocal(dir: repo.worktree)
        #expect(outcome == .restored(branch: "feat/run-concurrency"))
    }

    @Test("with the branch gone too, the project root is used")
    func fallsBackToRoot() async throws {
        let repo = try Repo()
        defer { repo.cleanup() }
        try repo.deleteWorktree()
        try repo.deleteBranch()
        let outcome = await SessionDirectory.ensureLocal(dir: repo.worktree)
        guard case .projectRoot(let root) = outcome else {
            Issue.record("expected the project root, got \(outcome)")
            return
        }
        #expect((root as NSString).resolvingSymlinksInPath == (repo.root as NSString).resolvingSymlinksInPath)
    }

    @Test("a send to a host whose worktree was deleted restores it and goes out")
    func sendRestoresWorktree() async throws {
        let repo = try Repo()
        defer { repo.cleanup() }
        try repo.deleteWorktree()
        let rush = try FakeRush(cwd: repo.worktree)
        defer { rush.cleanup() }
        try await rush.adapter().send(id: "22d7452e", text: "hello")
        #expect(rush.calls().contains("SENT"))
        #expect(FileManager.default.fileExists(atPath: repo.worktree))
    }

    @Test("a send whose worktree and branch are gone names the missing directory")
    func sendNamesMissingDirectory() async throws {
        let repo = try Repo()
        defer { repo.cleanup() }
        try repo.deleteWorktree()
        try repo.deleteBranch()
        let rush = try FakeRush(cwd: repo.worktree)
        defer { rush.cleanup() }
        do {
            try await rush.adapter().send(id: "22d7452e", text: "hello")
            Issue.record("send should fail")
        } catch let error as RushCommandFailed {
            #expect(error.message.contains(repo.worktree))
            #expect(error.message.contains("no longer exists"))
            #expect(!error.message.contains("fork/exec"))
        }
    }

    @Test("a start in a deleted worktree restores it; with no branch it starts in the project root")
    func startRestoresOrFallsBack() async throws {
        let repo = try Repo()
        defer { repo.cleanup() }
        try repo.deleteWorktree()
        let rush = try FakeRush(cwd: repo.worktree)
        defer { rush.cleanup() }
        _ = try await rush.adapter().start(RushStartRequest(cwd: repo.worktree, sessionId: "22d7452e-1111", resume: true))
        #expect(rush.calls().contains("--cwd \(repo.worktree) "))
        #expect(FileManager.default.fileExists(atPath: repo.worktree))

        try repo.deleteWorktree()
        try repo.deleteBranch()
        _ = try await rush.adapter().start(RushStartRequest(cwd: repo.worktree, sessionId: "22d7452e-1111", resume: true))
        #expect(rush.calls().contains("--cwd \(repo.root) "))
    }

    @Test("rush's fork/exec ENOENT is told apart from other failures")
    func detectsMissingCwdError() {
        #expect(SessionDirectory.isMissingCwdError("rush: fork/exec /usr/local/bin/rush: no such file or directory"))
        #expect(!SessionDirectory.isMissingCwdError("rush: session not found"))
    }
}
