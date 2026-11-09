import Foundation
import Testing
@testable import KanbanCodeCore

/// Every test builds its own `ClaudeConfigLayout`; none touches
/// `ClaudeConfigDirectories`, which stays `~/.claude` alone in tests.
@Suite("Claude config folders")
struct ClaudeConfigLayoutTests {
    let home = "/home/u"

    func tempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "claude-layout-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return ClaudeConfigLayout.resolve(dir)
    }

    @Test("Without accounts or CLAUDE_CONFIG_DIR only ~/.claude is in play, as before")
    func standardOnly() {
        let layout = ClaudeConfigLayout(home: home)
        #expect(layout.directories == ["/home/u/.claude"])
        #expect(layout.projectsDirectories == ["/home/u/.claude/projects"])
        #expect(layout.isStandardOnly)
        #expect(layout.defaultDirectory == "/home/u/.claude")
        #expect(layout.directory(forPath: "/home/u/work/app") == "/home/u/.claude")
        #expect(layout.machineLoginDirectory == "/home/u/.claude")
    }

    @Test("The process-wide layout is ~/.claude alone until a process bootstraps it, whatever the test environment holds")
    func globalUntouchedInTests() {
        // `swift test` run from a direnv folder carries CLAUDE_CONFIG_DIR.
        let current = ClaudeConfigDirectories.current
        #expect(current.isStandardOnly)
        #expect(current.accounts.isEmpty)
        #expect(ClaudeConfigDirectories.settingsPath == nil)
    }

    @Test("CLAUDE_CONFIG_DIR is the default folder; accounts follow, ~ expanded, each once")
    func folders() {
        let layout = ClaudeConfigLayout(
            home: home,
            environment: ["CLAUDE_CONFIG_DIR": "~/.claude-env/"],
            accounts: [
                ClaudeAccount(name: "Work", configDirectory: "~/.claude-work//"),
                ClaudeAccount(name: "Again", configDirectory: "/home/u/./.claude-work"),
                ClaudeAccount(name: "Standard", configDirectory: "~/.claude"),
                ClaudeAccount(name: "Relative", configDirectory: "claude-x"),
                ClaudeAccount(name: "Empty", configDirectory: "  "),
                ClaudeAccount(name: "Half-typed", configDirectory: "~/"),
                ClaudeAccount(name: "Root", configDirectory: "/"),
                ClaudeAccount(name: "Above home", configDirectory: "/home"),
            ])
        #expect(layout.defaultDirectory == "/home/u/.claude-env")
        #expect(layout.directories == ["/home/u/.claude-env", "/home/u/.claude", "/home/u/.claude-work"])
        #expect(!layout.isStandardOnly)
        #expect(layout.accounts.map(\.name) == ["Work", "Again", "Standard"])
        // Nor the login shell's CLAUDE_CONFIG_DIR when it is the home folder.
        #expect(ClaudeConfigLayout(home: home, environment: ["CLAUDE_CONFIG_DIR": "~"]).defaultDirectory == "/home/u/.claude")
    }

    @Test("Two spellings of one folder through a symlink count once")
    func symlinkDedupe() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root + "/.claude-real", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root + "/.claude-link", withDestinationPath: root + "/.claude-real")
        let layout = ClaudeConfigLayout(home: root, accounts: [
            ClaudeAccount(name: "A", configDirectory: root + "/.claude-real"),
            ClaudeAccount(name: "B", configDirectory: root + "/.claude-link"),
        ])
        #expect(layout.directories == [root + "/.claude", root + "/.claude-real"])
    }

    @Test("The longest project folder wins, matched on whole path components")
    func accountMatching() {
        let layout = ClaudeConfigLayout(home: home, accounts: [
            ClaudeAccount(name: "Dev", configDirectory: "~/.claude-dev", projectPaths: ["~/dev"]),
            ClaudeAccount(name: "Client", configDirectory: "~/.claude-client", projectPaths: ["~/dev/client/", "relative/ignored"]),
            ClaudeAccount(name: "Second", configDirectory: "~/.claude-second", projectPaths: ["~/dev"]),
        ])
        #expect(layout.account(forPath: "/home/u/dev")?.name == "Dev")
        #expect(layout.account(forPath: "/home/u/dev/app/src")?.name == "Dev")
        #expect(layout.account(forPath: "/home/u/dev/client")?.name == "Client")
        #expect(layout.account(forPath: "/home/u/dev/client/.claude/worktrees/x")?.name == "Client")
        #expect(layout.account(forPath: "/home/u/dev/clientele")?.name == "Dev")
        #expect(layout.account(forPath: "/home/u/devx") == nil)
        #expect(layout.account(forPath: "relative/ignored") == nil)
        #expect(layout.directory(forPath: "/home/u/other") == "/home/u/.claude")
        #expect(layout.directory(forPath: "/home/u/dev/client/a") == "/home/u/.claude-client")
    }

    @Test("A project reached through a symlink still matches its account")
    func symlinkedProject() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root + "/real/app", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root + "/link", withDestinationPath: root + "/real")
        let layout = ClaudeConfigLayout(home: root, accounts: [
            ClaudeAccount(name: "W", configDirectory: root + "/.claude-w", projectPaths: [root + "/real"]),
        ])
        #expect(layout.account(forPath: root + "/link/app")?.name == "W")
    }

    @Test("A transcript belongs to the folder whose projects/ holds it")
    func containingSession() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root + "/.claude-w/projects/-x", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root + "/w-link", withDestinationPath: root + "/.claude-w")
        let layout = ClaudeConfigLayout(home: root, accounts: [ClaudeAccount(name: "W", configDirectory: root + "/.claude-w")])
        #expect(layout.directory(containingSession: root + "/.claude-w/projects/-x/s.jsonl") == root + "/.claude-w")
        #expect(layout.directory(containingSession: root + "/w-link/projects/-x/s.jsonl") == root + "/.claude-w")
        #expect(layout.directory(containingSession: root + "/.claude/projects/-x/s.jsonl") == root + "/.claude")
        #expect(layout.directory(containingSession: root + "/.claude-w/sessions/s.jsonl") == nil)
        #expect(layout.directory(containingSession: root + "/.codex/sessions/2026/r.jsonl") == nil)
        #expect(layout.projectsDirectory(containingSession: root + "/.claude-w/projects/-x/s.jsonl") == root + "/.claude-w/projects")
    }

    @Test("CLAUDE_CONFIG_DIR is never set to ~/.claude, however it is spelled")
    func launchEnvironment() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root + "/.claude", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root + "/std-link", withDestinationPath: root + "/.claude")
        let layout = ClaudeConfigLayout(home: root)
        #expect(layout.launchEnvironment(directory: root + "/.claude") == [:])
        #expect(layout.launchEnvironment(directory: root + "/.claude/") == [:])
        #expect(layout.launchEnvironment(directory: root + "/std-link") == [:])
        #expect(layout.launchEnvironment(directory: root + "/.claude-w/") == ["CLAUDE_CONFIG_DIR": root + "/.claude-w"])

        // The environment's folder keeps the environment's spelling, also
        // ~/.claude set explicitly: its Keychain item is named after it.
        let fromEnv = ClaudeConfigLayout(home: root, environment: ["CLAUDE_CONFIG_DIR": root + "/.claude-e/"])
        #expect(fromEnv.launchEnvironment(directory: root + "/.claude-e") == ["CLAUDE_CONFIG_DIR": root + "/.claude-e/"])
        let explicit = ClaudeConfigLayout(home: root, environment: ["CLAUDE_CONFIG_DIR": root + "/.claude"])
        #expect(explicit.launchEnvironment(directory: root + "/.claude") == ["CLAUDE_CONFIG_DIR": root + "/.claude"])
    }

    @Test("Only folders Claude Code has used are written to or scrubbed")
    func writableFolders() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        for dir in ["/.claude-used", "/work", "/.claude-proj/projects"] {
            try FileManager.default.createDirectory(atPath: root + dir, withIntermediateDirectories: true)
        }
        try "{}".write(toFile: root + "/.claude-used/.claude.json", atomically: true, encoding: .utf8)
        let layout = ClaudeConfigLayout(home: root, accounts: [
            ClaudeAccount(name: "Used", configDirectory: root + "/.claude-used"),
            ClaudeAccount(name: "Typo", configDirectory: root + "/work"),
            ClaudeAccount(name: "Projects", configDirectory: root + "/.claude-proj"),
        ])
        #expect(layout.directories.count == 4)
        #expect(layout.writableDirectories == [root + "/.claude", root + "/.claude-used", root + "/.claude-proj"])
    }

    @Test("The Keychain item is named as Claude Code names it")
    func keychainService() {
        // Values from `shasum -a 256`; the first matches an item Claude
        // Code made on a Mac for CLAUDE_CONFIG_DIR=/Users/cg/.claude-cg.
        let layout = ClaudeConfigLayout(home: "/Users/cg")
        #expect(layout.keychainService(for: "/Users/cg/.claude") == "Claude Code-credentials")
        #expect(layout.keychainService(for: "/Users/cg/.claude-cg") == "Claude Code-credentials-a6906f39")
        #expect(layout.keychainService(for: "/Users/cg/.claude-cg/") == "Claude Code-credentials-a6906f39")

        // From the environment, its own spelling counts, ~/.claude too.
        let fromEnv = ClaudeConfigLayout(home: "/Users/cg", environment: ["CLAUDE_CONFIG_DIR": "/Users/cg/.claude-cg/"])
        #expect(fromEnv.keychainService(for: "/Users/cg/.claude-cg") == "Claude Code-credentials-aadca299")
        let explicitStandard = ClaudeConfigLayout(home: "/Users/cg", environment: ["CLAUDE_CONFIG_DIR": "/Users/cg/.claude"])
        #expect(explicitStandard.keychainService(for: "/Users/cg/.claude") == "Claude Code-credentials-a93299f0")
        #expect(explicitStandard.accountFile(for: "/Users/cg/.claude") == "/Users/cg/.claude/.claude.json")
    }

    @Test("The signed-in account is in ~/.claude.json for ~/.claude, in the folder otherwise")
    func accountFile() {
        let layout = ClaudeConfigLayout(home: home)
        #expect(layout.accountFile(for: "/home/u/.claude") == "/home/u/.claude.json")
        #expect(layout.accountFile(for: "/home/u/.claude-w") == "/home/u/.claude-w/.claude.json")
    }

    @Test("Machines get the chosen folder's login, the default when it is no longer an account")
    func machineLogin() {
        let accounts = [ClaudeAccount(name: "W", configDirectory: "~/.claude-w")]
        #expect(ClaudeConfigLayout(home: home, accounts: accounts, machineLoginDirectory: "~/.claude-w/").machineLoginDirectory == "/home/u/.claude-w")
        #expect(ClaudeConfigLayout(home: home, accounts: accounts, machineLoginDirectory: "~/.claude-gone").machineLoginDirectory == "/home/u/.claude")
        // CLAUDE_CONFIG_DIR alone does not switch the machines' login.
        #expect(ClaudeConfigLayout(home: home, environment: ["CLAUDE_CONFIG_DIR": "/e"], accounts: accounts).machineLoginDirectory == "/home/u/.claude")
    }

    @Test("Claude owns the transcripts of every configured folder; the others leave them alone")
    func ownership() {
        let layout = ClaudeConfigLayout(home: home, accounts: [ClaudeAccount(name: "W", configDirectory: "~/.claude-work")])
        let path = "/home/u/.claude-work/projects/-home-u-app/s.jsonl"
        #expect(CodingAssistant.claude.owns(sessionPath: path, claudeLayout: layout))
        #expect(!CodingAssistant.codex.owns(sessionPath: path, claudeLayout: layout))
        #expect(CodingAssistant.owner(ofSessionPath: path, claudeLayout: layout) == .claude)
        #expect(CodingAssistant.codex.ownedByOther(sessionPath: path, claudeLayout: layout))
        #expect(CodingAssistant.gemini.ownedByOther(sessionPath: path, claudeLayout: layout))
        #expect(!CodingAssistant.claude.ownedByOther(sessionPath: path, claudeLayout: layout))
        // Without the account the path is nobody's, as before.
        let plain = ClaudeConfigLayout(home: home)
        #expect(CodingAssistant.owner(ofSessionPath: path, claudeLayout: plain) == nil)
        #expect(CodingAssistant.owner(ofSessionPath: "/home/u/.claude/projects/-x/s.jsonl", claudeLayout: plain) == .claude)
        #expect(CodingAssistant.owner(ofSessionPath: "/home/u/.codex/sessions/r.jsonl", claudeLayout: layout) == .codex)
    }
}

@Suite("Claude accounts in settings")
struct ClaudeAccountSettingsTests {
    @Test("Settings written before accounts existed read with none, and write none back")
    func backwardCompatible() throws {
        let settings = try JSONDecoder().decode(Settings.self, from: Data(#"{"projects":[]}"#.utf8))
        #expect(settings.claudeAccounts.isEmpty)
        #expect(settings.claudeMachineLoginDirectory == nil)
        let json = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        #expect(!json.contains("claudeAccounts"))
        #expect(!json.contains("claudeMachineLoginDirectory"))
    }

    @Test("Accounts round-trip, a blank GitHub login reads as none")
    func roundTrip() throws {
        var settings = Settings()
        settings.claudeAccounts = [
            ClaudeAccount(name: "Work", configDirectory: "~/.claude-work", projectPaths: ["~/work"], githubUser: "me-work"),
        ]
        settings.claudeMachineLoginDirectory = "~/.claude-work"
        let decoded = try JSONDecoder().decode(Settings.self, from: try JSONEncoder().encode(settings))
        #expect(decoded.claudeAccounts == settings.claudeAccounts)
        #expect(decoded.claudeMachineLoginDirectory == "~/.claude-work")

        let blank = try JSONDecoder().decode(ClaudeAccount.self, from: Data(#"{"configDirectory":"/c","githubUser":"  "}"#.utf8))
        #expect(blank.githubUser == nil)
        #expect(blank.name == "c")
        #expect(blank.projectPaths.isEmpty)
    }

    @Test("An account that does not decode is dropped, not the others nor the rest of the settings")
    func lossy() throws {
        let json = #"{"projects":[{"path":"/p","name":"p","visible":true}],"claudeAccounts":[{"name":"broken"},{"configDirectory":"/ok"},42]}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(settings.claudeAccounts.map(\.configDirectory) == ["/ok"])
        #expect(settings.projects.map(\.path) == ["/p"])
    }

    @Test("A registry follows only the settings file it was bootstrapped from, and says each change once")
    func registry() throws {
        let dir = NSTemporaryDirectory() + "claude-registry-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        final class Count: @unchecked Sendable { let lock = NSLock(); var value = 0 }
        let changes = Count()
        let registry = ClaudeConfigRegistry(home: "/h")
        registry.onChange { _ in changes.lock.withLock { changes.value += 1 } }
        var settings = Settings()
        settings.claudeAccounts = [ClaudeAccount(name: "W", configDirectory: "/h/.claude-w")]

        // Before bootstrap no store's settings apply.
        registry.settingsChanged(settings, at: dir + "/settings.json")
        #expect(registry.current.isStandardOnly)

        registry.bootstrap(settingsPath: dir + "/./settings.json")
        #expect(registry.current.isStandardOnly)
        registry.settingsChanged(settings, at: dir + "/other.json")
        #expect(registry.current.isStandardOnly)
        registry.settingsChanged(settings, at: dir + "/settings.json")
        #expect(registry.current.directories == ["/h/.claude", "/h/.claude-w"])
        registry.settingsChanged(settings, at: dir + "/settings.json")
        #expect(!registry.update(environment: ["PATH": "/bin"]))
        #expect(registry.update(environment: ["CLAUDE_CONFIG_DIR": "/h/.claude-e", "PATH": "/bin"]))
        #expect(registry.current.defaultDirectory == "/h/.claude-e")
        #expect(!registry.update(environment: ["CLAUDE_CONFIG_DIR": "/h/.claude-e"]))
        #expect(changes.lock.withLock { changes.value } == 2)
    }

    @Test("A settings store of another file never changes the process-wide folders")
    func testStoreDoesNotPublish() async throws {
        let dir = NSTemporaryDirectory() + "claude-settings-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = SettingsStore(basePath: dir)
        var settings = Settings()
        settings.claudeAccounts = [ClaudeAccount(name: "W", configDirectory: "/tmp/never-published")]
        try await store.write(settings)
        _ = try await store.read()
        #expect(ClaudeConfigDirectories.current.isStandardOnly)
    }
}
