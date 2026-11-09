import Foundation
import Testing
@testable import KanbanCodeCore

private func tempDir(_ label: String) throws -> String {
    let dir = NSTemporaryDirectory() + "claude-\(label)-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return ClaudeConfigLayout.resolve(dir)
}

private func writeTranscript(_ path: String, cwd: String, prompt: String = "hello", date: Date? = nil) throws {
    try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    let line = #"{"type":"user","message":{"role":"user","content":"\#(prompt)"},"cwd":"\#(cwd)","sessionId":"x"}"#
    try (line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    if let date { try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path) }
}

@Suite("Session discovery across Claude config folders")
struct ClaudeMultiRootDiscoveryTests {
    final class Roots: @unchecked Sendable {
        var value: [String]
        init(_ value: [String]) { self.value = value }
    }

    @Test("Sessions of every folder show, also two project folders of one name")
    func bothRoots() async throws {
        let root = try tempDir("discovery")
        defer { try? FileManager.default.removeItem(atPath: root) }
        try writeTranscript(root + "/a/projects/-p/s1.jsonl", cwd: "/p")
        try writeTranscript(root + "/b/projects/-p/s2.jsonl", cwd: "/p")
        let roots = Roots([root + "/a/projects", root + "/b/projects", root + "/missing/projects"])
        let discovery = ClaudeCodeSessionDiscovery(projectsDirectories: { roots.value })
        let sessions = try await discovery.discoverSessions()
        #expect(Set(sessions.map(\.id)) == ["s1", "s2"])
        #expect(sessions.first { $0.id == "s2" }?.jsonlPath == root + "/b/projects/-p/s2.jsonl")

        // A folder no longer configured takes its sessions with it.
        roots.value = [root + "/a/projects"]
        #expect(try await discovery.discoverSessions().map(\.id) == ["s1"])
    }

    @Test("One session id in two folders keeps the newer transcript, scan after scan")
    func duplicateId() async throws {
        let root = try tempDir("dup")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let old = root + "/a/projects/-p/same.jsonl"
        let new = root + "/b/projects/-p/same.jsonl"
        try writeTranscript(old, cwd: "/p", date: Date(timeIntervalSince1970: 1_000))
        try writeTranscript(new, cwd: "/p", date: Date(timeIntervalSince1970: 2_000))
        for order in [[root + "/b/projects", root + "/a/projects"], [root + "/a/projects", root + "/b/projects"]] {
            let discovery = ClaudeCodeSessionDiscovery(projectsDirectories: { order })
            let sessions = try await discovery.discoverSessions()
            #expect(sessions.count == 1)
            #expect(sessions.first?.jsonlPath == new)
            // The older copy changing does not take over.
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_500)], ofItemAtPath: old)
            #expect(try await discovery.discoverSessions().first?.jsonlPath == new)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: old)
        }

        // The newer copy gone, the other one shows again.
        let discovery = ClaudeCodeSessionDiscovery(projectsDirectories: { [root + "/a/projects", root + "/b/projects"] })
        _ = try await discovery.discoverSessions()
        try FileManager.default.removeItem(atPath: new)
        var paths: [String?] = []
        for _ in 0..<2 { paths.append(try await discovery.discoverSessions().first?.jsonlPath) }
        #expect(paths.last == old)
    }
}

@Suite("Hooks in every Claude config folder")
struct ClaudeMultiFolderHookTests {
    @Test("Installed into each settings file; installed means installed in all")
    func installAll() throws {
        let root = try tempDir("hooks")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let script = root + "/.kanban-code/hook.sh"
        let status = root + "/.kanban-code/statusline.sh"
        let a = root + "/a/settings.json", b = root + "/b/settings.json"
        try FileManager.default.createDirectory(atPath: root + "/a", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/b", withIntermediateDirectories: true)

        try HookManager.install(for: .claude, settingsPath: a, hookScriptPath: script, statusLineScriptPath: status)
        #expect(!HookManager.isInstalled(for: .claude, settingsPaths: [a, b]))
        try HookManager.install(for: .claude, settingsPaths: [a, b], hookScriptPath: script, statusLineScriptPath: status)
        #expect(HookManager.isInstalled(for: .claude, settingsPaths: [a, b]))
        #expect(HookManager.isStatusLineInstalled(for: .claude, settingsPath: b))
    }

    @Test("A folder added later gets the hooks once another has them, keeping its own status line")
    func propagate() throws {
        let root = try tempDir("propagate")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let script = root + "/.kanban-code/hook.sh"
        let status = root + "/.kanban-code/statusline.sh"
        let a = root + "/a/settings.json", b = root + "/b/settings.json"
        try FileManager.default.createDirectory(atPath: root + "/a", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/b", withIntermediateDirectories: true)
        try #"{"statusLine":{"type":"command","command":"my-status"}}"#.write(toFile: b, atomically: true, encoding: .utf8)

        // Nobody opted in: nothing is installed anywhere.
        #expect(!HookManager.addMissingHooks(for: .claude, settingsPaths: [a, b], hookScriptPath: script, statusLineScriptPath: status))
        #expect(!HookManager.isInstalled(for: .claude, settingsPath: b))

        try HookManager.install(for: .claude, settingsPath: a, hookScriptPath: script, statusLineScriptPath: status)
        #expect(HookManager.addMissingHooks(for: .claude, settingsPaths: [a, b], hookScriptPath: script, statusLineScriptPath: status))
        #expect(HookManager.isInstalled(for: .claude, settingsPath: b))
        let root2 = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: b))) as? [String: Any]
        #expect((root2?["statusLine"] as? [String: Any])?["command"] as? String == "my-status")
    }

    @Test("A settings file that is not JSON is left as it is")
    func unreadableLeftAlone() throws {
        let root = try tempDir("unreadable")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let script = root + "/.kanban-code/hook.sh"
        let status = root + "/.kanban-code/statusline.sh"
        let a = root + "/a/settings.json", b = root + "/b/settings.json"
        try FileManager.default.createDirectory(atPath: root + "/a", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/b", withIntermediateDirectories: true)
        let commented = "{ // the user's comments\n \"model\": \"opus\" }"
        try commented.write(toFile: b, atomically: true, encoding: .utf8)
        try HookManager.install(for: .claude, settingsPaths: [a, b], hookScriptPath: script, statusLineScriptPath: status)
        try HookManager.install(for: .claude, settingsPath: a, hookScriptPath: script, statusLineScriptPath: status)
        _ = HookManager.addMissingHooks(for: .claude, settingsPaths: [a, b], hookScriptPath: script, statusLineScriptPath: status)
        #expect(try String(contentsOfFile: b, encoding: .utf8) == commented)
        #expect(HookManager.isInstalled(for: .claude, settingsPath: a))
        #expect(!HookManager.isRewritable(b))
        #expect(HookManager.isRewritable(root + "/missing/settings.json"))
        // The file left alone does not keep the hooks from counting as installed.
        #expect(HookManager.isInstalled(for: .claude, settingsPaths: [a, b]))
    }

    @Test("The vault and permission hooks follow every folder that has the Kanban hooks")
    func vaultAndPermissionPerFolder() throws {
        let root = try tempDir("vault")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let script = root + "/.kanban-code/hook.sh"
        let status = root + "/.kanban-code/statusline.sh"
        let a = root + "/a/settings.json", b = root + "/b/settings.json"
        for dir in ["/a", "/b"] { try FileManager.default.createDirectory(atPath: root + dir, withIntermediateDirectories: true) }
        try HookManager.install(for: .claude, settingsPaths: [a, b], hookScriptPath: script, statusLineScriptPath: status)
        VaultHook.installWhereHooked(settingsPaths: [a, b, root + "/none/settings.json"], scriptPath: root + "/.kanban-code/vault-hook.sh")
        PermissionHook.installWhereHooked(settingsPaths: [a, b], scriptPath: root + "/.kanban-code/permission-hook.sh")
        for path in [a, b] {
            let text = try String(contentsOfFile: path, encoding: .utf8)
            #expect(text.contains("vault-hook.sh"))
            #expect(text.contains("permission-hook.sh"))
        }
        #expect(!FileManager.default.fileExists(atPath: root + "/none/settings.json"))
    }

    @Test("A folder already partly hooked keeps its own status line when a release adds a hook event")
    func upgradeKeepsStatusLine() throws {
        let root = try tempDir("upgrade")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let script = root + "/.kanban-code/hook.sh"
        let status = root + "/.kanban-code/statusline.sh"
        let a = root + "/a/settings.json", b = root + "/b/settings.json"
        for dir in ["/a", "/b"] { try FileManager.default.createDirectory(atPath: root + dir, withIntermediateDirectories: true) }
        try HookManager.install(for: .claude, settingsPaths: [a], hookScriptPath: script, statusLineScriptPath: status)
        // b has one Kanban hook of an older release and a status line of its own.
        let old = #"{"statusLine":{"type":"command","command":"mine"},"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"\#(script)"}]}]}}"#
        try old.write(toFile: b, atomically: true, encoding: .utf8)
        #expect(HookManager.addMissingHooks(for: .claude, settingsPaths: [a, b], hookScriptPath: script, statusLineScriptPath: status))
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: b))) as? [String: Any]
        #expect((object?["statusLine"] as? [String: Any])?["command"] as? String == "mine")
        #expect(HookManager.isInstalled(for: .claude, settingsPath: b))
    }

    @Test("Only Claude folders that exist are written, ~/.claude when none does, a shared file once")
    func existingFoldersOnly() throws {
        let root = try tempDir("existing")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let layout = ClaudeConfigLayout(home: root, accounts: [
            ClaudeAccount(name: "W", configDirectory: root + "/.claude-w"),
            ClaudeAccount(name: "S", configDirectory: root + "/.claude-s"),
        ])
        #expect(HookManager.claudeSettingsPaths(layout: layout) == [root + "/.claude/settings.json"])
        try FileManager.default.createDirectory(atPath: root + "/.claude-w", withIntermediateDirectories: true)
        // A folder Claude Code never used is not written.
        #expect(HookManager.claudeSettingsPaths(layout: layout) == [root + "/.claude/settings.json"])
        try "{}".write(toFile: root + "/.claude-w/.claude.json", atomically: true, encoding: .utf8)
        #expect(HookManager.claudeSettingsPaths(layout: layout) == [root + "/.claude-w/settings.json"])
        try FileManager.default.createDirectory(atPath: root + "/.claude", withIntermediateDirectories: true)
        try "{}".write(toFile: root + "/.claude/settings.json", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: root + "/.claude-s", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root + "/.claude-s/settings.json", withDestinationPath: root + "/.claude/settings.json")
        #expect(HookManager.claudeSettingsPaths(layout: layout) == [root + "/.claude/settings.json", root + "/.claude-w/settings.json"])

        // A CLAUDE_CONFIG_DIR folder listed first sharing ~/.claude's file: ~/.claude's spelling stays.
        try FileManager.default.createDirectory(atPath: root + "/.claude-e", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root + "/.claude-e/settings.json", withDestinationPath: root + "/.claude/settings.json")
        let withEnv = ClaudeConfigLayout(home: root, environment: ["CLAUDE_CONFIG_DIR": root + "/.claude-e"])
        #expect(HookManager.claudeSettingsPaths(layout: withEnv) == [root + "/.claude/settings.json"])
    }
}

@Suite("Claude account of a launch")
struct ClaudeAccountLaunchTests {
    func layout(_ root: String, env: [String: String] = [:]) -> ClaudeConfigLayout {
        ClaudeConfigLayout(home: root, environment: env, accounts: [
            ClaudeAccount(name: "W", configDirectory: root + "/.claude-w", projectPaths: [root + "/work"]),
        ])
    }

    @Test("A new card in a claimed folder runs with its account; elsewhere the shell decides")
    func newSession() {
        let l = layout("/h")
        let claimed = ClaudeAccountLaunch.forNewSession(assistant: .claude, isLocal: true, projectPath: "/h/work/app", layout: l)
        #expect(claimed.directory == "/h/.claude-w")
        #expect(claimed.environment == ["CLAUDE_CONFIG_DIR": "/h/.claude-w"])
        #expect(!claimed.unsetsConfigDirectory)
        #expect(claimed.projectsDirectoriesToWatch(layout: l) == ["/h/.claude-w/projects"])

        let unclaimed = ClaudeAccountLaunch.forNewSession(assistant: .claude, isLocal: true, projectPath: "/h/home-app", layout: l)
        #expect(unclaimed == .shellDecides)
        #expect(unclaimed.projectsDirectoriesToWatch(layout: l) == ["/h/.claude/projects", "/h/.claude-w/projects"])
        #expect(unclaimed.preamble(shell: "/bin/zsh") == nil)

        #expect(ClaudeAccountLaunch.forNewSession(assistant: .claude, isLocal: false, projectPath: "/h/work/app", layout: l) == .shellDecides)
        #expect(ClaudeAccountLaunch.forNewSession(assistant: .codex, isLocal: true, projectPath: "/h/work/app", layout: l) == .shellDecides)
    }

    @Test("A resume runs with the folder its transcript is in, unsetting the variable for ~/.claude")
    func resume() throws {
        let root = try tempDir("resume")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let l = layout(root)
        let standard = root + "/.claude/projects/-k/s1.jsonl"
        let account = root + "/.claude-w/projects/-k/s2.jsonl"
        let unconfigured = root + "/.claude-old/projects/-k/s3.jsonl"
        for path in [standard, account, unconfigured] { try writeTranscript(path, cwd: "/k") }

        // The project is claimed by W, but this conversation is in ~/.claude.
        let inStandard = ClaudeAccountLaunch.forResume(
            assistant: .claude, isLocal: true, sessionId: "s1", sessionPath: standard,
            projectPath: root + "/work/app", layout: l)
        #expect(inStandard.directory == root + "/.claude")
        #expect(inStandard.environment.isEmpty)
        #expect(inStandard.unsetsConfigDirectory)

        // CLAUDE_CONFIG_DIR=~/.claude set in the login shell is set again, never unset.
        let explicit = ClaudeAccountLaunch.forResume(
            assistant: .claude, isLocal: true, sessionId: "s1", sessionPath: standard, projectPath: "/x",
            layout: layout(root, env: ["CLAUDE_CONFIG_DIR": root + "/.claude"]))
        #expect(explicit.environment == ["CLAUDE_CONFIG_DIR": root + "/.claude"])
        #expect(!explicit.unsetsConfigDirectory)

        let inAccount = ClaudeAccountLaunch.forResume(
            assistant: .claude, isLocal: true, sessionId: "s2", sessionPath: account, projectPath: "/elsewhere", layout: l)
        #expect(inAccount.environment == ["CLAUDE_CONFIG_DIR": root + "/.claude-w"])

        let inOld = ClaudeAccountLaunch.forResume(
            assistant: .claude, isLocal: true, sessionId: "s3", sessionPath: unconfigured, projectPath: "/elsewhere", layout: l)
        #expect(inOld.environment == ["CLAUDE_CONFIG_DIR": root + "/.claude-old"])

        let byId = ClaudeAccountLaunch.forResume(
            assistant: .claude, isLocal: true, sessionId: "s2", sessionPath: nil, projectPath: "/elsewhere", layout: l)
        #expect(byId.directory == root + "/.claude-w")

        let unknown = ClaudeAccountLaunch.forResume(
            assistant: .claude, isLocal: true, sessionId: "nope", sessionPath: nil, projectPath: root + "/work/x", layout: l)
        #expect(unknown.directory == root + "/.claude-w")
    }

    @Test("Without accounts a ~/.claude resume changes nothing")
    func resumeStandardOnly() throws {
        let root = try tempDir("plain")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let path = root + "/.claude/projects/-k/s.jsonl"
        try writeTranscript(path, cwd: "/k")
        let launch = ClaudeAccountLaunch.forResume(
            assistant: .claude, isLocal: true, sessionId: "s", sessionPath: path, projectPath: "/k",
            layout: ClaudeConfigLayout(home: root))
        #expect(launch.environment.isEmpty)
        #expect(!launch.unsetsConfigDirectory)
        #expect(launch.preamble(shell: "/bin/zsh") == nil)
    }

    @Test("The unset is a shell builtin run first, so an alias named claude still works")
    func preamble() {
        let unset = ClaudeAccountLaunch(directory: "/h/.claude", environment: [:], unsetsConfigDirectory: true)
        #expect(unset.preamble(shell: "/bin/zsh") == "unset CLAUDE_CONFIG_DIR")
        #expect(unset.preamble(shell: nil) == "unset CLAUDE_CONFIG_DIR")
        // Global only: fish's plain `set -e` would erase a universal variable.
        #expect(unset.preamble(shell: "/opt/homebrew/bin/fish") == "begin; set -eg CLAUDE_CONFIG_DIR; true; end")
        #expect(MasterEngine.joinedPreamble(nil, nil) == nil)
        #expect(MasterEngine.joinedPreamble("a", nil) == "a")
        #expect(MasterEngine.joinedPreamble("a", "b") == "a && b")
    }
}

@Suite("Claude account environment of a tmux session")
struct ClaudeAccountSessionEnvironmentTests {
    final class RecordingTmux: TmuxManagerPort, @unchecked Sendable {
        var command: String?
        var environment: [String: String] = [:]
        func createSession(name: String, path: String, command: String?) async throws { self.command = command }
        func createSession(name: String, path: String, command: String?, environment: [String: String]) async throws {
            self.command = command
            self.environment = environment
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

    @Test("GH_TOKEN reaches the session through tmux only, never the typed command; the config folder goes both ways")
    func split() async throws {
        let env = ["GH_TOKEN": "gho_secret", "CLAUDE_CONFIG_DIR": "/h/.claude-w"]
        for resume in [false, true] {
            let tmux = RecordingTmux()
            let launcher = LaunchSession(tmux: tmux)
            if resume {
                _ = try await launcher.resume(sessionId: "abcdef12", projectPath: "/p", shellOverride: nil, extraEnv: env)
            } else {
                _ = try await launcher.launch(sessionName: "c", projectPath: "/p", prompt: "", worktreeName: nil,
                                              shellOverride: nil, extraEnv: env)
            }
            let command = try #require(tmux.command)
            #expect(!command.contains("gho_secret"))
            #expect(command.contains("CLAUDE_CONFIG_DIR='/h/.claude-w' claude"))
            #expect(tmux.environment == env)
        }
        // A command of the user's own still gets the folder from tmux.
        let tmux = RecordingTmux()
        _ = try await LaunchSession(tmux: tmux).launch(
            sessionName: "c", projectPath: "/p", prompt: "", worktreeName: nil, shellOverride: nil,
            extraEnv: env, commandOverride: "my-claude")
        #expect(tmux.environment["CLAUDE_CONFIG_DIR"] == "/h/.claude-w")
    }

    @Test("An app started from a card's shell drops the accounts Kanban gave it, and only those")
    func inherited() {
        let marker = InheritedSessionEnvironment.accountMarker
        let card = ["CLAUDE_CONFIG_DIR": "/h/.claude-w", "GH_TOKEN": "t", marker: "CLAUDE_CONFIG_DIR,GH_TOKEN", "HOME": "/h"]
        #expect(InheritedSessionEnvironment.inherited(in: card).sorted() == ["CLAUDE_CONFIG_DIR", "GH_TOKEN", marker])
        // Kanban gave only the folder: the user's own GH_TOKEN stays.
        let folderOnly = ["CLAUDE_CONFIG_DIR": "/h/.claude-w", "GH_TOKEN": "mine", marker: "CLAUDE_CONFIG_DIR"]
        #expect(InheritedSessionEnvironment.inherited(in: folderOnly).sorted() == ["CLAUDE_CONFIG_DIR", marker])
        // Without the marker, the user's own exports stay.
        #expect(InheritedSessionEnvironment.inherited(in: ["CLAUDE_CONFIG_DIR": "/h/.claude-w", "GH_TOKEN": "t"]).isEmpty)
        #expect(InheritedSessionEnvironment.tmuxUnsetArguments(serverTMPDIR: nil, accountMarker: "GH_TOKEN").contains("GH_TOKEN"))
        #expect(!InheritedSessionEnvironment.tmuxUnsetArguments(serverTMPDIR: nil, accountMarker: "GH_TOKEN").contains("CLAUDE_CONFIG_DIR"))
        #expect(!InheritedSessionEnvironment.tmuxUnsetArguments(serverTMPDIR: nil).contains("GH_TOKEN"))
    }
}

@Suite("Claude transcripts stay in their config folder")
struct ClaudeTranscriptFolderTests {
    @Test("Moving a session to another project keeps it in its folder")
    func mover() throws {
        let root = try tempDir("mover")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let from = root + "/.claude-w/projects/-old/s.jsonl"
        try writeTranscript(from, cwd: "/old")
        let moved = try SessionFileMover.moveSession(sessionId: "s", fromPath: from, toProjectPath: "/new/place")
        #expect(moved == root + "/.claude-w/projects/-new-place/s.jsonl")
        let line = try #require(try String(contentsOfFile: moved, encoding: .utf8).split(separator: "\n").first)
        let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        #expect(object?["cwd"] as? String == "/new/place")
        #expect(!FileManager.default.fileExists(atPath: from))
    }

    @Test("A move to the key a transcript already has, spelled through a symlink, keeps the file")
    func moverSameFile() throws {
        let root = try tempDir("samefile")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let real = root + "/.claude-w/projects/-p/s.jsonl"
        try writeTranscript(real, cwd: "/p")
        try FileManager.default.createSymbolicLink(atPath: root + "/link", withDestinationPath: root + "/.claude-w")
        let moved = try SessionFileMover.moveSession(
            sessionId: "s", fromPath: root + "/link/projects/-p/s.jsonl", toProjectPath: "/p",
            projectsDirectory: root + "/.claude-w/projects")
        #expect(moved == real)
        #expect(FileManager.default.fileExists(atPath: real))
    }

    @Test("A session migrated from another assistant goes where its project's account looks")
    func migratedSession() async throws {
        let root = try tempDir("migrate")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let layout = ClaudeConfigLayout(home: root, accounts: [
            ClaudeAccount(name: "W", configDirectory: root + "/.claude-w", projectPaths: [root + "/work"]),
        ])
        let store = ClaudeCodeSessionStore(claudeLayout: { layout })
        let turn = ConversationTurn(index: 0, lineNumber: 1, role: "user", textPreview: "hi")
        let claimed = try await store.writeSession(turns: [turn], sessionId: "m1", projectPath: root + "/work/app")
        #expect(claimed.hasPrefix(root + "/.claude-w/projects/"))
        let other = try await store.writeSession(turns: [turn], sessionId: "m2", projectPath: root + "/else")
        #expect(other.hasPrefix(root + "/.claude/projects/"))
    }

    @Test("A summary is updated in whichever folder's index has the session")
    func summaryAcrossRoots() throws {
        let root = try tempDir("summary")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let index = root + "/b/projects/-p/sessions-index.json"
        try FileManager.default.createDirectory(atPath: root + "/a/projects/-p", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/b/projects/-p", withIntermediateDirectories: true)
        try #"{"version":1,"entries":[{"sessionId":"s","summary":"old"}]}"#.write(toFile: index, atomically: true, encoding: .utf8)
        try SessionIndexReader.updateSummary(sessionId: "s", summary: "new", claudeDir: root + "/a/projects")
        #expect(try String(contentsOfFile: index, encoding: .utf8).contains("old"))
        // No folder named: every folder of the layout, an unreadable one skipped.
        let layout = ClaudeConfigLayout(home: root, accounts: [
            ClaudeAccount(name: "Unreadable", configDirectory: root + "/broken"),
            ClaudeAccount(name: "A", configDirectory: root + "/a"),
            ClaudeAccount(name: "B", configDirectory: root + "/b"),
        ])
        try "not a folder".write(toFile: root + "/broken", atomically: true, encoding: .utf8)
        try SessionIndexReader.updateSummary(sessionId: "s", summary: "new", layout: layout)
        #expect(try String(contentsOfFile: index, encoding: .utf8).contains("new"))
    }

    @Test("Export finds a card's transcript in an account folder its settings name")
    func exportLookup() throws {
        let root = try tempDir("export")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let kanban = root + "/.kanban-code"
        try FileManager.default.createDirectory(atPath: kanban, withIntermediateDirectories: true)
        var settings = Settings()
        settings.claudeAccounts = [ClaudeAccount(name: "W", configDirectory: root + "/.claude-w")]
        try JSONEncoder().encode(settings).write(to: URL(fileURLWithPath: kanban + "/settings.json"))
        let transcript = root + "/.claude-w/projects/-p/sid.jsonl"
        try writeTranscript(transcript, cwd: "/p")
        var link = Link(projectPath: "/p")
        link.sessionLink = SessionLink(sessionId: "sid", sessionPath: root + "/gone.jsonl")
        #expect(ConversationExportCommand.transcriptPath(for: link, kanbanHome: kanban, userHome: root, environment: [:]) == transcript)
    }

    @Test("Machines get the login of the chosen folder: its Keychain item and files")
    func machineLoginLocation() {
        let standard = MacLoginStore(home: "/Users/cg", claudeLayout: { ClaudeConfigLayout(home: "/Users/cg") })
        #expect(standard.claudeLoginLocation() == .init(
            keychainService: "Claude Code-credentials",
            credentialsFile: "/Users/cg/.claude/.credentials.json",
            accountFile: "/Users/cg/.claude.json"))
        let chosen = MacLoginStore(home: "/Users/cg", claudeLayout: {
            ClaudeConfigLayout(home: "/Users/cg", accounts: [ClaudeAccount(name: "cg", configDirectory: "~/.claude-cg")],
                               machineLoginDirectory: "~/.claude-cg")
        })
        #expect(chosen.claudeLoginLocation() == .init(
            keychainService: "Claude Code-credentials-a6906f39",
            credentialsFile: "/Users/cg/.claude-cg/.credentials.json",
            accountFile: "/Users/cg/.claude-cg/.claude.json"))
    }

    @Test("The skill is linked into every config folder that exists")
    func skillLinks() throws {
        let root = try tempDir("skill")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let source = root + "/repo/.claude/skills/kanban-code"
        try FileManager.default.createDirectory(atPath: source, withIntermediateDirectories: true)
        try "x".write(toFile: source + "/SKILL.md", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: root + "/.claude-w/projects", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/.claude-unused", withIntermediateDirectories: true)
        let layout = ClaudeConfigLayout(home: root, accounts: [
            ClaudeAccount(name: "W", configDirectory: root + "/.claude-w"),
            ClaudeAccount(name: "Gone", configDirectory: root + "/.claude-gone"),
            ClaudeAccount(name: "Unused", configDirectory: root + "/.claude-unused"),
        ])
        ChatBootstrap.ensureSkillSymlink(repoRoot: root + "/repo", layout: layout)
        #expect(FileManager.default.fileExists(atPath: root + "/.claude/skills/kanban-code/SKILL.md"))
        #expect(FileManager.default.fileExists(atPath: root + "/.claude-w/skills/kanban-code/SKILL.md"))
        #expect(!FileManager.default.fileExists(atPath: root + "/.claude-gone"))
        #expect(!FileManager.default.fileExists(atPath: root + "/.claude-unused/skills"))
    }

    @Test("The scrubber reads the transcripts of the account folders")
    func scrubTargets() {
        let targets = ScrubTargets.standard(home: "/h", kanbanHome: "/h/.kanban-code", claudeDirectories: ["/h/.claude", "/h/.claude-w"])
        #expect(targets.roots.contains("/h/.claude-w/projects"))
        #expect(targets.roots.filter { $0 == "/h/.claude/projects" }.count == 1)
    }

    @Test("Side chat and slash commands find a tmux card's account folder from its transcript, or its project")
    func sideChatFolder() {
        #expect(SideChatSession.claudeConfigDirectory(
            transcriptPath: "/h/.claude-w/projects/-p/s.jsonl", isRush: false, home: "/h") == "/h/.claude-w")
        let layout = ClaudeConfigLayout(home: "/h", accounts: [
            ClaudeAccount(name: "W", configDirectory: "/h/.claude-w", projectPaths: ["/h/work"]),
        ])
        #expect(SlashCommandSession.claudeConfigDirectory(
            transcriptPath: nil, isRush: false, home: "/h", environment: [:], projectPath: "/h/work/app", layout: layout) == "/h/.claude-w")
        #expect(SlashCommandSession.claudeConfigDirectory(
            transcriptPath: nil, isRush: false, home: "/h", environment: [:], projectPath: "/h/else", layout: layout) == nil)
    }
}

@Suite("GitHub account tokens")
struct GitHubAccountTokensTests {
    final class Calls: @unchecked Sendable {
        let lock = NSLock()
        var users: [String] = []
        func add(_ user: String) { lock.withLock { users.append(user) } }
    }

    @Test("A token is reused for a while; a missing one is retried later, not on every call")
    func caching() async {
        let calls = Calls()
        let tokens = GitHubAccountTokens(lifetime: 600, retryAfter: 60) { user in
            calls.add(user)
            return user == "ok" ? "gho_\(user)" : nil
        }
        let t0 = Date(timeIntervalSince1970: 0)
        #expect(await tokens.token(for: "ok", now: t0) == "gho_ok")
        #expect(await tokens.token(for: "ok", now: t0.addingTimeInterval(300)) == "gho_ok")
        #expect(await tokens.token(for: "ok", now: t0.addingTimeInterval(601)) == "gho_ok")
        #expect(await tokens.token(for: "bad", now: t0) == nil)
        #expect(await tokens.token(for: "bad", now: t0.addingTimeInterval(30)) == nil)
        #expect(await tokens.token(for: "bad", now: t0.addingTimeInterval(61)) == nil)
        #expect(calls.users == ["ok", "ok", "bad", "bad"])
    }

    @Test("Only a folder an account with a GitHub login claims gets GH_TOKEN")
    func environment() async {
        let tokens = GitHubAccountTokens { user in "gho_\(user)" }
        let layout = ClaudeConfigLayout(home: "/h", accounts: [
            ClaudeAccount(name: "W", configDirectory: "/h/.claude-w", projectPaths: ["/h/work"], githubUser: "me-work"),
            ClaudeAccount(name: "N", configDirectory: "/h/.claude-n", projectPaths: ["/h/nogh"]),
        ])
        #expect(await tokens.environment(forPath: "/h/work/app", layout: layout) == ["GH_TOKEN": "gho_me-work"])
        #expect(await tokens.environment(forPath: "/h/nogh/app", layout: layout).isEmpty)
        #expect(await tokens.environment(forPath: "/h/other", layout: layout).isEmpty)
    }
}
