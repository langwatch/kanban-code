import Foundation
import Testing
@testable import KanbanCodeCore

/// Launches and resumes through `MasterEngine`, with the Claude config
/// folders given to the engine (`MasterPlatform.claudeLayout`), sessions
/// recorded instead of run.
@Suite("Claude accounts in launches and resumes", .serialized)
@MainActor
struct MasterEngineClaudeAccountsTests {
    final class RecordingTmux: TmuxManagerPort, @unchecked Sendable {
        struct Created { var name: String; var command: String?; var environment: [String: String] }
        private let lock = NSLock()
        private var _created: [Created] = []
        var created: [Created] { lock.withLock { _created } }
        func createSession(name: String, path: String, command: String?) async throws {
            try await createSession(name: name, path: path, command: command, environment: [:])
        }
        func createSession(name: String, path: String, command: String?, environment: [String: String]) async throws {
            lock.withLock { _created.append(Created(name: name, command: command, environment: environment)) }
        }
        func killSession(name: String) async throws {}
        func listSessions() async throws -> [TmuxSession] { [] }
        func sendPrompt(to sessionName: String, text: String) async throws {}
        func pastePrompt(to sessionName: String, text: String) async throws {}
        func pasteText(to sessionName: String, text: String) async throws {}
        func submitPrompt(to sessionName: String) async throws {}
        func capturePane(sessionName: String) async throws -> String { "" }
        func sendBracketedPaste(to sessionName: String) async throws {}
        func findSessionForWorktree(sessions: [TmuxSession], worktreePath: String, branch: String?) -> TmuxSession? { nil }
        func isAvailable() async -> Bool { true }
    }

    struct Harness {
        let root: String
        let store: BoardStore
        let engine: MasterEngine
        let tmux: RecordingTmux
        let account: String
        let work: String
    }

    /// `root/work` is claimed by the account in `root/.claude-w`, whose
    /// GitHub login has the token `gho_test`.
    func harness() throws -> Harness {
        let raw = NSTemporaryDirectory() + "claude-engine-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: raw, withIntermediateDirectories: true)
        let root = ClaudeConfigLayout.resolve(raw)
        let account = root + "/.claude-w"
        let work = root + "/work"
        for dir in [account + "/projects", root + "/.claude/projects", work + "/app", root + "/home-app"] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        let layout = ClaudeConfigLayout(home: root, accounts: [
            ClaudeAccount(name: "W", configDirectory: account, projectPaths: [work], githubUser: "me-work"),
        ])
        let tmux = RecordingTmux()
        let coordination = CoordinationStore(basePath: root + "/.kanban-code")
        let store = BoardStore(
            effectHandler: EffectHandler(
                coordinationStore: coordination, tmuxAdapter: tmux,
                queuedPromptJournal: QueuedPromptJournal(basePath: root + "/.kanban-code")),
            discovery: ClaudeCodeSessionDiscovery(projectsDirectories: { layout.projectsDirectories }),
            coordinationStore: coordination
        )
        var platform = MasterPlatform()
        platform.kanbanHome = root + "/.kanban-code"
        platform.projectsDirectory = root + "/Projects"
        platform.claudeProjectsDirectory = root + "/.claude/projects"
        platform.claudeLayout = { layout }
        platform.gitHubTokens = GitHubAccountTokens { _ in "gho_test" }
        platform.paneShell = { "/bin/zsh" }
        let engine = MasterEngine(
            store: store,
            settingsStore: SettingsStore(basePath: root + "/.kanban-code"),
            launcher: LaunchSession(tmux: tmux),
            tmux: RoutingTmuxAdapter(rush: RushCliAdapter(executable: "/nonexistent/rush")),
            registry: CodingAssistantRegistry(),
            platform: platform
        )
        return Harness(root: root, store: store, engine: engine, tmux: tmux, account: account, work: work)
    }

    func waitForSession(_ h: Harness) async throws -> RecordingTmux.Created {
        for _ in 0..<100 where h.tmux.created.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        return try #require(h.tmux.created.last)
    }

    func writeTranscript(_ path: String, cwd: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try (#"{"type":"user","message":{"role":"user","content":"hi"},"cwd":"\#(cwd)"}"# + "\n")
            .write(toFile: path, atomically: true, encoding: .utf8)
    }

    @Test("A card in a claimed folder starts with its account, and its transcript there links")
    func launchClaimed() async throws {
        let h = try harness()
        defer { try? FileManager.default.removeItem(atPath: h.root) }
        let project = h.work + "/app"
        h.store.dispatch(.createManualTask(Link(id: "c1", name: "Work", projectPath: project, column: .backlog)))
        h.engine.launch(cardId: "c1", prompt: "", projectPath: project, worktreeName: nil, runRemotely: false)

        let session = try await waitForSession(h)
        let command = try #require(session.command)
        #expect(command.contains("CLAUDE_CONFIG_DIR='\(h.account)' claude"))
        #expect(!command.contains("unset CLAUDE_CONFIG_DIR"))
        #expect(!command.contains("gho_test"))
        #expect(session.environment["CLAUDE_CONFIG_DIR"] == h.account)
        #expect(session.environment["GH_TOKEN"] == "gho_test")
        #expect(session.environment[InheritedSessionEnvironment.accountMarker] == "CLAUDE_CONFIG_DIR,GH_TOKEN")

        let transcript = "\(h.account)/projects/\(SessionFileMover.encodeProjectPath(project))/new-session.jsonl"
        try writeTranscript(transcript, cwd: project)
        for _ in 0..<200 where h.store.state.links["c1"]?.sessionLink?.sessionPath == nil {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(h.store.state.links["c1"]?.sessionLink?.sessionPath == transcript)
    }

    @Test("A card no account claims starts as before, and its transcript links from any folder")
    func launchUnclaimed() async throws {
        let h = try harness()
        defer { try? FileManager.default.removeItem(atPath: h.root) }
        let project = h.root + "/home-app"
        h.store.dispatch(.createManualTask(Link(id: "c2", name: "Home", projectPath: project, column: .backlog)))
        h.engine.launch(cardId: "c2", prompt: "", projectPath: project, worktreeName: nil, runRemotely: false)

        let session = try await waitForSession(h)
        let command = try #require(session.command)
        #expect(!command.contains("CLAUDE_CONFIG_DIR"))
        #expect(session.environment["CLAUDE_CONFIG_DIR"] == nil)
        #expect(session.environment["GH_TOKEN"] == nil)

        // direnv in that folder picked the account: still found.
        let transcript = "\(h.account)/projects/\(SessionFileMover.encodeProjectPath(project))/s-direnv.jsonl"
        try writeTranscript(transcript, cwd: project)
        for _ in 0..<200 where h.store.state.links["c2"]?.sessionLink?.sessionPath == nil {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(h.store.state.links["c2"]?.sessionLink?.sessionPath == transcript)
    }

    @Test("A ~/.claude conversation resumes with the variable unset, in a claimed folder too")
    func resumeStandard() async throws {
        let h = try harness()
        defer { try? FileManager.default.removeItem(atPath: h.root) }
        let project = h.work + "/app"
        let transcript = "\(h.root)/.claude/projects/\(SessionFileMover.encodeProjectPath(project))/s1.jsonl"
        try writeTranscript(transcript, cwd: project)
        h.store.dispatch(.createManualTask(Link(
            id: "c3", name: "Old", projectPath: project, column: .waiting,
            sessionLink: SessionLink(sessionId: "s1", sessionPath: transcript))))
        #expect(h.engine.resume(cardId: "c3", runRemotely: false, commandOverride: nil))

        let session = try await waitForSession(h)
        let command = try #require(session.command)
        #expect(command.contains("&& unset CLAUDE_CONFIG_DIR && "))
        #expect(command.contains("claude --dangerously-skip-permissions --resume s1"))
        #expect(!command.contains("CLAUDE_CONFIG_DIR='"))
        #expect(session.environment["CLAUDE_CONFIG_DIR"] == nil)
        #expect(session.environment["GH_TOKEN"] == "gho_test")
        // The transcript was not moved out of its folder.
        #expect(FileManager.default.fileExists(atPath: transcript))
    }

    @Test("An account's conversation resumes with its folder, also with a command of the user's own")
    func resumeAccount() async throws {
        let h = try harness()
        defer { try? FileManager.default.removeItem(atPath: h.root) }
        let project = h.root + "/home-app"
        let transcript = "\(h.account)/projects/\(SessionFileMover.encodeProjectPath(project))/s2.jsonl"
        try writeTranscript(transcript, cwd: project)
        h.store.dispatch(.createManualTask(Link(
            id: "c4", name: "Account", projectPath: project, column: .waiting,
            sessionLink: SessionLink(sessionId: "s2", sessionPath: transcript))))
        #expect(h.engine.resume(cardId: "c4", runRemotely: false, commandOverride: "my-claude --resume s2"))

        let session = try await waitForSession(h)
        #expect(session.environment["CLAUDE_CONFIG_DIR"] == h.account)
        #expect(session.command?.contains("my-claude --resume s2") == true)
        // No GitHub login for a project the account does not claim.
        #expect(session.environment["GH_TOKEN"] == nil)
    }

    @Test("A fork stays in the folder of the conversation it copies")
    func fork() async throws {
        let h = try harness()
        defer { try? FileManager.default.removeItem(atPath: h.root) }
        let project = h.work + "/app"
        let transcript = "\(h.account)/projects/\(SessionFileMover.encodeProjectPath(project))/s5.jsonl"
        try writeTranscript(transcript, cwd: project)
        h.store.dispatch(.createManualTask(Link(
            id: "c5", name: "Forked", projectPath: project, column: .waiting,
            sessionLink: SessionLink(sessionId: "s5", sessionPath: transcript))))
        let newCard = try await h.engine.forkCard(cardId: "c5")
        let path = try #require(h.store.state.links[newCard]?.sessionLink?.sessionPath)
        #expect(path.hasPrefix("\(h.account)/projects/\(SessionFileMover.encodeProjectPath(project))/"))
        #expect(FileManager.default.fileExists(atPath: path))
    }
}
