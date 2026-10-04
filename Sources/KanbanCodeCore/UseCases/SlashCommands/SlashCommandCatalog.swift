import Foundation
import KanbanCodeRemoteKit

/// What a card's chat composer offers after `/`: the Kanban chat's own
/// commands, the agent's, and the skills and custom commands on disk.
public enum SlashCommandCatalog {
    /// What the chat handles itself; nothing reaches the session.
    public static let kanban = RemoteSlashCommand.kanban

    /// The agent's own commands that run when sent as a message: each
    /// takes its arguments on the same line and opens no dialog.
    public static func agent(_ assistant: CodingAssistant) -> [RemoteSlashCommand] {
        let pairs: [(String, String)]
        switch assistant {
        case .claude:
            pairs = [
                ("compact", "Summarize the conversation to free context; instructions may follow"),
                ("clear", "Start a new conversation with an empty context"),
                ("context", "Show what fills the context window"),
                ("init", "Write a CLAUDE.md for this project"),
                ("model", "Switch the model, as in /model opus"),
                ("effort", "Set the reasoning effort, as in /effort high"),
                ("code-review", "Review the current diff or a pull request"),
                ("security-review", "Security review of the pending changes"),
                ("simplify", "Clean up the changed code"),
                ("loop", "Run a prompt or a command on an interval"),
            ]
        case .codex:
            pairs = [
                ("compact", "Summarize the conversation to free context"),
                ("new", "Start a new conversation"),
                ("init", "Write an AGENTS.md for this project"),
            ]
        case .gemini:
            pairs = [
                ("compress", "Summarize the conversation to free context"),
                ("clear", "Start a new conversation with an empty context"),
            ]
        }
        return pairs.map { RemoteSlashCommand(name: $0.0, description: $0.1, source: RemoteSlashCommand.Source.agent) }
    }

    /// The list for one card. `sideChat` says whether the card's chat
    /// handles `/btw` and `/catchup`. `disk` are the skills and commands
    /// found on disk, in the order of precedence; one that has the name of
    /// an agent command replaces it.
    public static func merged(assistant: CodingAssistant, sideChat: Bool, disk: [RemoteSlashCommand]) -> [RemoteSlashCommand] {
        var seen = Set<String>()
        var out: [RemoteSlashCommand] = []
        let custom = unique(disk)
        let customNames = Set(custom.map(\.name))
        let lists = [sideChat ? kanban : [], agent(assistant).filter { !customNames.contains($0.name) },
                     custom.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }]
        for command in lists.joined() where seen.insert(command.name).inserted {
            out.append(command)
        }
        return out
    }

    /// Each name once, the first one kept.
    static func unique(_ commands: [RemoteSlashCommand]) -> [RemoteSlashCommand] {
        var seen = Set<String>()
        return commands.filter { !$0.name.isEmpty && seen.insert($0.name).inserted }
    }
}

/// Reads the skills and custom commands a Claude Code session can run from
/// the files Claude Code reads them from.
public enum ClaudeCommandFiles {
    /// Project ones first (the session's folder up to its repository
    /// root), then the user's, the account's synced skills, then those of
    /// the enabled plugins as `plugin:name`.
    ///
    /// `configDirectory` is the session's `CLAUDE_CONFIG_DIR`, or nil for
    /// `~/.claude`.
    public static func commands(configDirectory: String?, cwd: String?, home: String = NSHomeDirectory()) -> [RemoteSlashCommand] {
        let standard = (home as NSString).appendingPathComponent(".claude")
        let config = resolved(configDirectory ?? standard)
        var out: [RemoteSlashCommand] = []
        let projects = projectFolders(cwd: cwd, home: home).filter { resolved($0) != config }
        for folder in projects {
            out += scan(root: folder, prefix: "", source: RemoteSlashCommand.Source.project)
        }
        out += scan(root: config, prefix: "", source: RemoteSlashCommand.Source.user)
        out += syncedSkills(config: config, isStandard: config == resolved(standard), home: home)

        var enabled = enabledPlugins(settingsPath: config + "/settings.json")
        for folder in projects.reversed() {
            for name in ["settings.json", "settings.local.json"] {
                enabled.merge(enabledPlugins(settingsPath: folder + "/" + name)) { _, new in new }
            }
        }
        for plugin in pluginRoots(config: config, cwd: cwd, enabled: enabled) {
            out += scan(root: plugin.root, prefix: plugin.name + ":", source: RemoteSlashCommand.Source.plugin)
        }
        return SlashCommandCatalog.unique(out)
    }

    // MARK: Folders

    /// The `.claude` folders of `cwd` and its parents, nearest first, up
    /// to the repository root. The home folder and above are left out:
    /// its `.claude` is the user's.
    static func projectFolders(cwd: String?, home: String) -> [String] {
        guard let cwd, !cwd.isEmpty else { return [] }
        let fm = FileManager.default
        let home = resolved(home)
        var out: [String] = []
        var folder = resolved(cwd)
        while folder != "/", !folder.isEmpty, folder != home {
            let dot = (folder as NSString).appendingPathComponent(".claude")
            if isDirectory(dot) { out.append(dot) }
            if fm.fileExists(atPath: (folder as NSString).appendingPathComponent(".git")) { break }
            folder = (folder as NSString).deletingLastPathComponent
        }
        return out
    }

    struct PluginRoot: Equatable {
        var name: String
        var root: String
    }

    /// The install folders of the plugins that are enabled, for the user
    /// or for a project that holds `cwd`.
    static func pluginRoots(config: String, cwd: String?, enabled: [String: Bool]) -> [PluginRoot] {
        struct Installed: Decodable {
            struct Entry: Decodable {
                var scope: String?
                var projectPath: String?
                var installPath: String?
            }
            var plugins: [String: [Entry]]
        }
        guard let data = FileManager.default.contents(atPath: config + "/plugins/installed_plugins.json"),
              let installed = try? JSONDecoder().decode(Installed.self, from: data) else { return [] }
        let cwd = cwd.map(resolved)
        var roots: [PluginRoot] = []
        for key in installed.plugins.keys.sorted() where enabled[key] == true {
            for entry in installed.plugins[key] ?? [] {
                guard let path = entry.installPath, isDirectory(path) else { continue }
                if entry.scope == "project" || entry.scope == "local" {
                    guard let project = entry.projectPath, let cwd,
                          (cwd + "/").hasPrefix(resolved(project) + "/") else { continue }
                }
                let name = pluginName(root: path) ?? String(key.prefix { $0 != "@" })
                roots.append(PluginRoot(name: name, root: path))
                break
            }
        }
        return roots
    }

    static func pluginName(root: String) -> String? {
        struct Manifest: Decodable { var name: String? }
        guard let data = FileManager.default.contents(atPath: root + "/.claude-plugin/plugin.json"),
              let name = (try? JSONDecoder().decode(Manifest.self, from: data))?.name, !name.isEmpty else { return nil }
        return name
    }

    static func enabledPlugins(settingsPath: String) -> [String: Bool] {
        guard let data = FileManager.default.contents(atPath: settingsPath),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = object["enabledPlugins"] as? [String: Any] else { return [:] }
        return plugins.compactMapValues { $0 as? Bool }
    }

    /// The skills the account syncs from claude.ai, which Claude Code names
    /// `anthropic-skills:<name>`. They sit under
    /// `skills/synced/<organization>_<account>`, the ids of the login.
    static func syncedSkills(config: String, isStandard: Bool, home: String) -> [RemoteSlashCommand] {
        let loginFile = isStandard ? (home as NSString).appendingPathComponent(".claude.json") : config + "/.claude.json"
        guard let data = FileManager.default.contents(atPath: loginFile),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = object["oauthAccount"] as? [String: Any],
              let organizationId = account["organizationUuid"] as? String,
              let accountId = account["accountUuid"] as? String else { return [] }
        let folder = config + "/skills/synced/\(organizationId)_\(accountId)"
        return skills(in: folder, prefix: "anthropic-skills:", source: RemoteSlashCommand.Source.user)
    }

    // MARK: Files

    static func scan(root: String, prefix: String, source: String) -> [RemoteSlashCommand] {
        skills(in: root + "/skills", prefix: prefix, source: source)
            + customCommands(in: root + "/commands", prefix: prefix, source: source)
    }

    /// `<folder>/<name>/SKILL.md`
    static func skills(in folder: String, prefix: String, source: String) -> [RemoteSlashCommand] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted()
        return names.compactMap { entry in
            guard !entry.hasPrefix("."),
                  let front = frontmatter(path: folder + "/" + entry + "/SKILL.md"), isUserInvocable(front) else { return nil }
            let name = front["name"].flatMap { $0.isEmpty ? nil : $0 } ?? entry
            return RemoteSlashCommand(name: prefix + name, description: oneLine(front["description"] ?? ""), source: source)
        }
    }

    /// `<folder>/**/<name>.md`; a subfolder is part of the name
    /// (`commands/git/push.md` is `git:push`).
    static func customCommands(in folder: String, prefix: String, source: String, path: [String] = []) -> [RemoteSlashCommand] {
        guard path.count < 4 else { return [] }
        let directory = ([folder] + path).joined(separator: "/")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).sorted()
        var out: [RemoteSlashCommand] = []
        for entry in names where !entry.hasPrefix(".") {
            let full = directory + "/" + entry
            if isDirectory(full) {
                out += customCommands(in: folder, prefix: prefix, source: source, path: path + [entry])
            } else if entry.hasSuffix(".md"), let front = frontmatter(path: full), isUserInvocable(front) {
                let name = (path + [String(entry.dropLast(3))]).joined(separator: ":")
                out.append(RemoteSlashCommand(name: prefix + name,
                                              description: oneLine(front["description"] ?? front[""] ?? ""), source: source))
            }
        }
        return out
    }

    static func isUserInvocable(_ front: [String: String]) -> Bool {
        let value = (front["user-invocable"] ?? front["user_invocable"] ?? "").lowercased()
        return value != "false" && value != "no"
    }

    /// The `key: value` lines between the `---` fences that open a
    /// markdown file, block scalars (`|`, `>`) included. A file with no
    /// fence gives its first line of text under the key `""`. Nil when the
    /// file cannot be read.
    static func frontmatter(path: String) -> [String: String]? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 16 << 10) else { return nil }
        let text = String(decoding: head, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.hasSuffix("\r") ? String(line.dropLast()) : String(line)
        }
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            let first = lines.lazy
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces)) }
                .first { !$0.isEmpty }
            return first.map { ["": $0] } ?? [:]
        }
        var out: [String: String] = [:]
        var blockKey: String?
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            if let key = blockKey, line.first?.isWhitespace == true || line.isEmpty {
                let piece = line.trimmingCharacters(in: .whitespaces)
                if !piece.isEmpty { out[key] = out[key].map { $0.isEmpty ? piece : $0 + " " + piece } ?? piece }
                continue
            }
            blockKey = nil
            guard line.first?.isWhitespace != true, let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.isEmpty || ["|", ">", "|-", ">-", "|+", ">+"].contains(value) {
                blockKey = key
                out[key] = ""
            } else {
                out[key] = unquoted(value)
            }
        }
        return out
    }

    static func unquoted(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" else { return value }
        let inner = String(value.dropFirst().dropLast())
        return first == "\"" ? inner.replacingOccurrences(of: "\\\"", with: "\"") : inner.replacingOccurrences(of: "''", with: "'")
    }

    /// One line of at most 200 characters.
    static func oneLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.count > 200 ? String(line.prefix(199)) + "…" : line
    }

    static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
