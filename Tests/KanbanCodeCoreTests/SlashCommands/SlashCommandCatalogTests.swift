import Foundation
import KanbanCodeRemoteKit
import Testing

@testable import KanbanCodeCore

/// A home folder with a Claude Code configuration, a project and plugins,
/// laid out the way Claude Code keeps them.
private struct Fixture {
    let root: String
    var home: String { root + "/home" }
    var config: String { home + "/.claude" }
    var project: String { home + "/Projects/shop" }

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("slash-\(UUID().uuidString)").resolvingSymlinksInPath().path
        try FileManager.default.createDirectory(atPath: root + "/home/.claude", withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: root)
    }

    func write(_ path: String, _ text: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func skill(_ folder: String, _ name: String, description: String, extra: String = "") throws {
        try write("\(folder)/skills/\(name)/SKILL.md", "---\nname: \(name)\ndescription: \(description)\n\(extra)---\n\n# \(name)\n")
    }

    /// Installs a plugin with one skill and one command.
    func plugin(_ key: String, name: String, scope: String = "user", projectPath: String? = nil) throws -> [String: Any] {
        let path = config + "/plugins/cache/market/\(name)/1.0.0"
        try write(path + "/.claude-plugin/plugin.json", #"{"name": "\#(name)"}"#)
        try skill(path, "audit", description: "Audit of \(name)")
        try write(path + "/commands/run.md", "---\ndescription: Run \(name)\n---\nGo.\n")
        var entry: [String: Any] = ["scope": scope, "installPath": path]
        if let projectPath { entry["projectPath"] = projectPath }
        return [key: [entry]]
    }

    func install(_ plugins: [[String: Any]], enabled: [String: Bool]) throws {
        var all: [String: Any] = [:]
        for plugin in plugins { all.merge(plugin) { $1 } }
        let installed = try JSONSerialization.data(withJSONObject: ["version": 2, "plugins": all])
        try write(config + "/plugins/installed_plugins.json", String(decoding: installed, as: UTF8.self))
        let settings = try JSONSerialization.data(withJSONObject: ["enabledPlugins": enabled])
        try write(config + "/settings.json", String(decoding: settings, as: UTF8.self))
    }
}

@Suite("Slash command discovery")
struct SlashCommandCatalogTests {
    @Test("user skills and commands are read from the configuration folder")
    func userLevel() throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.skill(f.config, "deploy", description: "\"Ship it: to staging\"")
        try f.write(f.config + "/skills/folder-name/SKILL.md", "---\ndescription: >\n  Named by\n  its folder\n---\n")
        try f.write(f.config + "/skills/not-a-skill/README.md", "nothing")
        try f.write(f.config + "/commands/git/push.md", "---\ndescription: Push the branch\n---\n")
        try f.write(f.config + "/commands/plain.md", "# Plain command\n\nBody.\n")

        let found = ClaudeCommandFiles.commands(configDirectory: nil, cwd: nil, home: f.home)
        #expect(found == [
            RemoteSlashCommand(name: "deploy", description: "Ship it: to staging", source: "user"),
            RemoteSlashCommand(name: "folder-name", description: "Named by its folder", source: "user"),
            RemoteSlashCommand(name: "git:push", description: "Push the branch", source: "user"),
            RemoteSlashCommand(name: "plain", description: "Plain command", source: "user"),
        ])
    }

    @Test("a skill marked not user-invocable is left out")
    func notInvocable() throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.skill(f.config, "hidden", description: "For the model only", extra: "user-invocable: false\n")
        try f.skill(f.config, "shown", description: "For you", extra: "user-invocable: true\n")
        let names = ClaudeCommandFiles.commands(configDirectory: nil, cwd: nil, home: f.home).map(\.name)
        #expect(names == ["shown"])
    }

    @Test("project skills come from the session folder up to the repository root, and win over the user's")
    func projectLevel() throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.write(f.project + "/.git/HEAD", "ref: refs/heads/main\n")
        try f.skill(f.project + "/.claude", "deploy", description: "Ship this shop")
        try f.write(f.project + "/.claude/commands/seed.md", "---\ndescription: Seed the database\n---\n")
        try f.skill(f.project + "/api/.claude", "migrate", description: "Run the migrations")
        // Above the repository root: not this project's.
        try f.skill(f.home + "/Projects/.claude", "outside", description: "Another tree")
        try f.skill(f.config, "deploy", description: "Ship anything")
        try f.skill(f.config, "review", description: "Review the diff")

        let found = ClaudeCommandFiles.commands(configDirectory: nil, cwd: f.project + "/api", home: f.home)
        #expect(found == [
            RemoteSlashCommand(name: "migrate", description: "Run the migrations", source: "project"),
            RemoteSlashCommand(name: "deploy", description: "Ship this shop", source: "project"),
            RemoteSlashCommand(name: "seed", description: "Seed the database", source: "project"),
            RemoteSlashCommand(name: "review", description: "Review the diff", source: "user"),
        ])
    }

    @Test("the user's folder is not read as a project when the session runs in the home folder")
    func homeIsNotAProject() throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.skill(f.config, "deploy", description: "Ship anything")
        let found = ClaudeCommandFiles.commands(configDirectory: nil, cwd: f.home, home: f.home)
        #expect(found.map(\.source) == ["user"])
    }

    @Test("skills and commands of enabled plugins are named plugin:name")
    func plugins() throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.install([
            try f.plugin("catalog@market", name: "catalog"),
            try f.plugin("off@market", name: "off"),
            try f.plugin("unlisted@market", name: "unlisted"),
            try f.plugin("shop-only@market", name: "shop-only", scope: "project", projectPath: f.project),
            try f.plugin("elsewhere@market", name: "elsewhere", scope: "project", projectPath: f.home + "/Projects/other"),
        ], enabled: ["catalog@market": true, "off@market": false, "shop-only@market": true, "elsewhere@market": true])
        try FileManager.default.createDirectory(atPath: f.project, withIntermediateDirectories: true)

        let inProject = ClaudeCommandFiles.commands(configDirectory: nil, cwd: f.project, home: f.home)
        #expect(inProject == [
            RemoteSlashCommand(name: "catalog:audit", description: "Audit of catalog", source: "plugin"),
            RemoteSlashCommand(name: "catalog:run", description: "Run catalog", source: "plugin"),
            RemoteSlashCommand(name: "shop-only:audit", description: "Audit of shop-only", source: "plugin"),
            RemoteSlashCommand(name: "shop-only:run", description: "Run shop-only", source: "plugin"),
        ])
        let outside = ClaudeCommandFiles.commands(configDirectory: nil, cwd: nil, home: f.home).map(\.name)
        #expect(outside == ["catalog:audit", "catalog:run"])
    }

    @Test("a project's settings turn a plugin on for its sessions")
    func projectEnablesPlugin() throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.install([try f.plugin("catalog@market", name: "catalog")], enabled: [:])
        try f.write(f.project + "/.git/HEAD", "ref: refs/heads/main\n")
        try f.write(f.project + "/.claude/settings.json", #"{"enabledPlugins": {"catalog@market": true}}"#)
        #expect(ClaudeCommandFiles.commands(configDirectory: nil, cwd: f.project, home: f.home).map(\.name)
            == ["catalog:audit", "catalog:run"])
        #expect(ClaudeCommandFiles.commands(configDirectory: nil, cwd: nil, home: f.home).isEmpty)
    }

    @Test("a configuration folder given by CLAUDE_CONFIG_DIR is read through its symlinks")
    func configDirectory() throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.skill(f.config, "deploy", description: "Ship anything")
        try f.install([try f.plugin("catalog@market", name: "catalog")], enabled: ["catalog@market": true])
        // An account folder whose entries link to the standard one.
        let account = f.home + "/.config/rush/claude/acct-1"
        try FileManager.default.createDirectory(atPath: account, withIntermediateDirectories: true)
        for entry in ["skills", "plugins", "settings.json"] {
            try FileManager.default.createSymbolicLink(atPath: account + "/" + entry, withDestinationPath: f.config + "/" + entry)
        }
        try f.write(account + "/commands/only-here.md", "---\ndescription: Of this account\n---\n")

        let names = ClaudeCommandFiles.commands(configDirectory: account, cwd: nil, home: f.home).map(\.name)
        #expect(names == ["deploy", "only-here", "catalog:audit", "catalog:run"])
        // The standard folder has no such command.
        #expect(!ClaudeCommandFiles.commands(configDirectory: nil, cwd: nil, home: f.home).map(\.name).contains("only-here"))
    }

    @Test("skills synced for the logged-in account are named anthropic-skills:name")
    func syncedSkills() throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.write(f.home + "/.claude.json", #"{"oauthAccount": {"organizationUuid": "org-1", "accountUuid": "acct-1"}}"#)
        let synced = f.config + "/skills/synced"
        try f.write(synced + "/org-1_acct-1/pdf/SKILL.md", "---\nname: pdf\ndescription: Work with PDF files\n---\n")
        try f.write(synced + "/org-2_acct-2/other/SKILL.md", "---\nname: other\ndescription: Another login\n---\n")
        let found = ClaudeCommandFiles.commands(configDirectory: nil, cwd: nil, home: f.home)
        #expect(found == [RemoteSlashCommand(name: "anthropic-skills:pdf", description: "Work with PDF files", source: "user")])
    }

    @Test("a long description is cut to one line")
    func oneLine() {
        let long = String(repeating: "word ", count: 80)
        let line = ClaudeCommandFiles.oneLine("first\n  second\t" + long)
        #expect(line.hasPrefix("first second word"))
        #expect(line.count == 200)
        #expect(line.hasSuffix("…"))
    }

    @Test("the list puts the chat's commands first, then the agent's, then the ones on disk, each name once")
    func merged() {
        let disk = [
            RemoteSlashCommand(name: "zeta", description: "Last", source: "user"),
            RemoteSlashCommand(name: "compact", description: "The project's own compact", source: "project"),
            RemoteSlashCommand(name: "catchup", description: "A skill with the chat's name", source: "user"),
            RemoteSlashCommand(name: "zeta", description: "Again", source: "plugin"),
            RemoteSlashCommand(name: "alpha", description: "First", source: "user"),
        ]
        let list = SlashCommandCatalog.merged(assistant: .claude, sideChat: true, disk: disk)
        #expect(Array(list.prefix(3).map(\.name)) == ["catchup", "btw", "clear"])
        #expect(list.first?.source == "kanban")
        #expect(Set(list.map(\.name)).count == list.count)
        #expect(list.first { $0.name == "compact" }?.source == "project")
        #expect(list.first { $0.name == "zeta" }?.description == "Last")
        #expect(Array(list.suffix(3).map(\.name)) == ["alpha", "compact", "zeta"])
    }

    @Test("Codex and Gemini cards get the agent's commands and no side chat ones")
    func otherAssistants() {
        let codex = SlashCommandCatalog.merged(assistant: .codex, sideChat: false, disk: [])
        #expect(codex.map(\.name) == ["compact", "new", "init"])
        let gemini = SlashCommandCatalog.merged(assistant: .gemini, sideChat: false, disk: [])
        #expect(gemini.map(\.name) == ["compress", "clear"])
        #expect((codex + gemini).allSatisfy { $0.source == "agent" })
    }

    @Test("the session's configuration folder: the rush account in use, the transcript's, or the process's own")
    func sessionConfigDirectory() throws {
        let f = try Fixture()
        defer { f.remove() }
        let accounts = f.home + "/.config/rush/claude"
        try f.write(accounts + "/using", "acct-1\n")
        try FileManager.default.createDirectory(atPath: accounts + "/acct-1", withIntermediateDirectories: true)
        #expect(SlashCommandSession.claudeConfigDirectory(transcriptPath: nil, isRush: true, home: f.home, environment: [:])
            == accounts + "/acct-1")
        let standard = f.config + "/projects/-x/s.jsonl"
        #expect(SlashCommandSession.claudeConfigDirectory(transcriptPath: standard, isRush: false, home: f.home,
                                                          environment: ["CLAUDE_CONFIG_DIR": "/elsewhere"]) == nil)
        #expect(SlashCommandSession.claudeConfigDirectory(transcriptPath: "/custom/projects/-x/s.jsonl", isRush: false,
                                                          home: f.home, environment: [:]) == "/custom")
        #expect(SlashCommandSession.claudeConfigDirectory(transcriptPath: nil, isRush: false, home: f.home,
                                                          environment: ["CLAUDE_CONFIG_DIR": "/elsewhere"]) == "/elsewhere")
        #expect(SlashCommandSession.claudeConfigDirectory(transcriptPath: nil, isRush: false, home: f.home, environment: [:]) == nil)
    }

    @Test("a card's list is fresh for a short time, and its last one stays for an owner that is away")
    func cache() {
        let cache = SlashCommandCache(lifetime: 30)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        cache.write(cardId: "c1", RemoteSlashCommand.kanban, now: now)
        #expect(cache.read(cardId: "c1", now: now.addingTimeInterval(29)) == RemoteSlashCommand.kanban)
        #expect(cache.read(cardId: "c1", now: now.addingTimeInterval(31)) == nil)
        #expect(cache.read(cardId: "c2", now: now) == nil)
        // For a card whose owner stopped answering.
        #expect(cache.last(cardId: "c1") == RemoteSlashCommand.kanban)
        #expect(cache.last(cardId: "c2") == nil)
    }
}

@Suite("Slash command menu")
struct SlashCommandMenuTests {
    private let commands = [
        RemoteSlashCommand(name: "catchup", description: "", source: "kanban"),
        RemoteSlashCommand(name: "btw", description: "", source: "kanban"),
        RemoteSlashCommand(name: "clear", description: "", source: "agent"),
        RemoteSlashCommand(name: "compact", description: "", source: "agent"),
        RemoteSlashCommand(name: "code-review", description: "", source: "agent"),
        RemoteSlashCommand(name: "posthog:exploring-llm-traces", description: "", source: "plugin"),
        RemoteSlashCommand(name: "review", description: "", source: "user"),
        RemoteSlashCommand(name: "reuse-worktree", description: "", source: "user"),
    ]

    @Test("the list shows while the text is a slash and a name with no whitespace")
    func query() {
        #expect(SlashCommandMenu.query(in: "/") == "")
        #expect(SlashCommandMenu.query(in: "/CatchU") == "catchu")
        #expect(SlashCommandMenu.query(in: "/posthog:sig") == "posthog:sig")
        #expect(SlashCommandMenu.query(in: "/catchup ") == nil)
        #expect(SlashCommandMenu.query(in: "/btw what now") == nil)
        #expect(SlashCommandMenu.query(in: "/compact\n") == nil)
        #expect(SlashCommandMenu.query(in: "hello /catchup") == nil)
        #expect(SlashCommandMenu.query(in: " /catchup") == nil)
        #expect(SlashCommandMenu.query(in: "/Users/me/file.txt") == nil)
        #expect(SlashCommandMenu.query(in: "") == nil)
    }

    @Test("a slash alone lists every command in order")
    func all() {
        #expect(SlashCommandMenu.matches(query: "", in: commands) == commands)
    }

    @Test("names that start with the text come first, then parts that do, then names that contain it")
    func ranking() {
        #expect(SlashCommandMenu.matches(query: "catchu", in: commands).map(\.name) == ["catchup"])
        #expect(SlashCommandMenu.matches(query: "c", in: commands).map(\.name)
            == ["catchup", "clear", "compact", "code-review", "posthog:exploring-llm-traces"])
        #expect(SlashCommandMenu.matches(query: "re", in: commands).map(\.name)
            == ["review", "reuse-worktree", "code-review"])
        #expect(SlashCommandMenu.matches(query: "tr", in: commands).map(\.name)
            == ["posthog:exploring-llm-traces", "reuse-worktree"])
        #expect(SlashCommandMenu.matches(query: "review", in: commands).map(\.name) == ["review", "code-review"])
        #expect(SlashCommandMenu.matches(query: "TRACES", in: commands).map(\.name) == ["posthog:exploring-llm-traces"])
        #expect(SlashCommandMenu.matches(query: "nothing", in: commands).isEmpty)
    }

    @Test("Tab completes, Return completes too except on the name typed in full")
    func keys() {
        let catchup = commands[0]
        #expect(SlashCommandMenu.replacement(text: "/catchu", selected: catchup, isReturn: false) == "/catchup ")
        #expect(SlashCommandMenu.replacement(text: "/catchu", selected: catchup, isReturn: true) == "/catchup ")
        #expect(SlashCommandMenu.replacement(text: "/catchup", selected: catchup, isReturn: true) == nil)
        #expect(SlashCommandMenu.replacement(text: "/catchup", selected: catchup, isReturn: false) == "/catchup ")
        // Another command picked with the arrows while a full name is typed.
        #expect(SlashCommandMenu.replacement(text: "/review", selected: commands[4], isReturn: true) == "/code-review ")
        #expect(SlashCommandMenu.replacement(text: "hello", selected: catchup, isReturn: true) == nil)
        #expect(SlashCommandMenu.replacement(text: "/catchu", selected: nil, isReturn: true) == nil)
    }

    @Test("the arrows wrap around the list")
    func arrows() {
        #expect(SlashCommandMenu.move(0, by: 1, count: 3) == 1)
        #expect(SlashCommandMenu.move(2, by: 1, count: 3) == 0)
        #expect(SlashCommandMenu.move(0, by: -1, count: 3) == 2)
        #expect(SlashCommandMenu.move(0, by: -1, count: 0) == 0)
    }
}
