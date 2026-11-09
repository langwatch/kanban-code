#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Where Claude Code keeps its state on this machine: `~/.claude`, the
/// folder `CLAUDE_CONFIG_DIR` names, and the folders of the configured
/// `ClaudeAccount`s. A value: everything here is computed from its inputs
/// and the file system, so tests build their own.
public struct ClaudeConfigLayout: Sendable, Equatable {
    public let home: String
    /// `<home>/.claude`, what Claude Code uses without `CLAUDE_CONFIG_DIR`.
    public let standard: String
    /// What a session gets when no account claims its folder: the
    /// `CLAUDE_CONFIG_DIR` of the environment sessions start in, else
    /// `standard`.
    public let defaultDirectory: String
    /// The accounts whose folder could be read, paths expanded.
    public let accounts: [ClaudeAccount]
    /// Every folder sessions may live in, default first, each once.
    public let directories: [String]
    /// The folder whose login the machines get (Settings > Claude accounts).
    public let machineLoginDirectory: String

    /// `CLAUDE_CONFIG_DIR` as the environment spells it: Claude Code names
    /// its Keychain item after that exact string.
    private let environmentSpelling: String?
    private let resolvedStandard: String
    private let resolvedDirectories: [String]
    /// (project folder, resolved project folder, account index), longest first.
    private let rules: [Rule]

    struct Rule: Sendable, Equatable {
        let path: String
        let resolved: String
        let account: Int
    }

    public init(
        home: String = NSHomeDirectory(),
        environment: [String: String] = [:],
        accounts: [ClaudeAccount] = [],
        machineLoginDirectory: String? = nil
    ) {
        let home = Self.normalize(home) ?? home
        self.home = home
        let standard = home + "/.claude"
        self.standard = standard
        self.resolvedStandard = Self.resolve(standard)
        let fromEnvironment = environment["CLAUDE_CONFIG_DIR"].flatMap { Self.expand($0, home: home) }
        self.environmentSpelling = fromEnvironment == nil ? nil : environment["CLAUDE_CONFIG_DIR"]
        self.defaultDirectory = fromEnvironment ?? standard

        var kept: [ClaudeAccount] = []
        for account in accounts {
            guard let dir = Self.expand(account.configDirectory, home: home) else { continue }
            var copy = account
            copy.configDirectory = dir
            copy.projectPaths = account.projectPaths.compactMap { Self.expand($0, home: home) }
            kept.append(copy)
        }
        self.accounts = kept

        var dirs: [String] = []
        var resolvedDirs: [String] = []
        for dir in [defaultDirectory, standard] + kept.map(\.configDirectory) {
            let resolved = Self.resolve(dir)
            guard !resolvedDirs.contains(resolved) else { continue }
            dirs.append(dir)
            resolvedDirs.append(resolved)
        }
        self.directories = dirs
        self.resolvedDirectories = resolvedDirs

        var rules: [Rule] = []
        for (index, account) in kept.enumerated() {
            for path in account.projectPaths {
                rules.append(Rule(path: path, resolved: Self.resolve(path), account: index))
            }
        }
        // Longest folder first: `~/work/client` wins over `~/work`. Equal
        // lengths keep the order of the accounts.
        self.rules = rules.enumerated()
            .sorted { lhs, rhs in
                lhs.element.path.count != rhs.element.path.count
                    ? lhs.element.path.count > rhs.element.path.count
                    : lhs.offset < rhs.offset
            }
            .map(\.element)

        // A folder that is not one of these (its account was removed)
        // falls back to the default rather than syncing an orphan login.
        let machineLogin = machineLoginDirectory.flatMap { Self.expand($0, home: home) }
        self.machineLoginDirectory = machineLogin.flatMap { wanted in
            dirs.first { Self.resolve($0) == Self.resolve(wanted) }
        } ?? defaultDirectory
    }

    /// `directories`, each with `/projects`.
    public var projectsDirectories: [String] { directories.map { $0 + "/projects" } }

    /// True when nothing but `~/.claude` is in play: the app behaves as it
    /// did before accounts existed.
    public var isStandardOnly: Bool { directories == [standard] }

    // MARK: Lookups

    /// The account whose project folders hold `path`, the longest folder
    /// winning.
    public func account(forPath path: String) -> ClaudeAccount? {
        guard !rules.isEmpty, let literal = Self.normalize(path) else { return nil }
        if let rule = rules.first(where: { Self.isInside(literal, folder: $0.path) }) {
            return accounts[rule.account]
        }
        let resolved = Self.resolve(literal)
        if let rule = rules.first(where: { Self.isInside(resolved, folder: $0.resolved) }) {
            return accounts[rule.account]
        }
        return nil
    }

    /// The folder a new session started in `path` runs with.
    public func directory(forPath path: String) -> String {
        account(forPath: path)?.configDirectory ?? defaultDirectory
    }

    /// The folder whose `projects/` holds the transcript at `sessionPath`,
    /// nil when it is in none of them.
    public func directory(containingSession sessionPath: String) -> String? {
        guard let literal = Self.normalize(sessionPath) else { return nil }
        for dir in directories where literal.hasPrefix(dir + "/projects/") { return dir }
        for (index, resolved) in resolvedDirectories.enumerated() where literal.hasPrefix(resolved + "/projects/") {
            return directories[index]
        }
        // Only transcript-shaped paths are worth the file system calls.
        guard literal.contains("/projects/") else { return nil }
        let resolved = Self.resolve(literal)
        for (index, dir) in resolvedDirectories.enumerated() where resolved.hasPrefix(dir + "/projects/") {
            return directories[index]
        }
        return nil
    }

    /// The `projects/` folder of the transcript at `sessionPath`.
    public func projectsDirectory(containingSession sessionPath: String) -> String? {
        directory(containingSession: sessionPath).map { $0 + "/projects" }
    }

    public func isStandard(_ directory: String) -> Bool {
        guard let literal = Self.normalize(directory) else { return false }
        return literal == standard || Self.resolve(literal) == resolvedStandard
    }

    /// What a session needs in its environment to run with `directory`.
    /// Empty for `~/.claude`: Claude Code names its Keychain item after the
    /// variable's value whenever it is set, so `CLAUDE_CONFIG_DIR=~/.claude`
    /// would start the session logged out.
    public func launchEnvironment(directory: String) -> [String: String] {
        guard let literal = Self.normalize(directory), !isStandard(literal) else { return [:] }
        return ["CLAUDE_CONFIG_DIR": literal]
    }

    /// The Keychain service Claude Code keeps the login of `directory` in on
    /// macOS: `Claude Code-credentials`, plus `-` and the first 8 hex digits
    /// of the SHA-256 of the folder path when it is not `~/.claude`.
    ///
    /// The default folder, when the environment names it, hashes the
    /// environment's own spelling, `~/.claude` included: that is the string
    /// Claude Code hashes for the sessions it starts. Every other folder is
    /// the spelling Kanban launches sessions with (`launchEnvironment`).
    public func keychainService(for directory: String) -> String {
        let base = "Claude Code-credentials"
        guard let literal = Self.normalize(directory) else { return base }
        let spelling: String
        if let environmentSpelling, literal == defaultDirectory {
            spelling = environmentSpelling
        } else if isStandard(literal) {
            return base
        } else {
            spelling = literal
        }
        let digest = SHA256.hash(data: Data(spelling.utf8)).map { String(format: "%02x", $0) }.joined()
        return base + "-" + digest.prefix(8)
    }

    /// The file holding the signed-in account (`oauthAccount`) of
    /// `directory`: `~/.claude.json` for `~/.claude` without the variable,
    /// `<folder>/.claude.json` otherwise.
    public func accountFile(for directory: String) -> String {
        guard let literal = Self.normalize(directory) else { return home + "/.claude.json" }
        if isStandard(literal), environmentSpelling == nil || literal != defaultDirectory {
            return home + "/.claude.json"
        }
        return literal + "/.claude.json"
    }

    // MARK: Paths

    /// `~` expanded, `.`/`..` and repeated or trailing slashes removed. Nil
    /// for an empty or relative path.
    public static func expand(_ raw: String, home: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded: String
        if trimmed == "~" {
            expanded = home
        } else if trimmed.hasPrefix("~/") {
            expanded = home + "/" + trimmed.dropFirst(2)
        } else {
            expanded = trimmed
        }
        return normalize(expanded)
    }

    static func normalize(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// Symlinks resolved, for comparing two spellings of one folder. The
    /// part that does not exist yet (a transcript about to be written) is
    /// kept as it is, after its deepest existing folder is resolved.
    static func resolve(_ path: String) -> String {
        let fm = FileManager.default
        var existing = path
        var missing: [String] = []
        while existing.count > 1, !fm.fileExists(atPath: existing) {
            missing.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        let base = URL(fileURLWithPath: existing).resolvingSymlinksInPath().path
        guard !missing.isEmpty else { return base }
        return (base == "/" ? "" : base) + "/" + missing.joined(separator: "/")
    }

    static func isInside(_ path: String, folder: String) -> Bool {
        folder == "/" || path == folder || path.hasPrefix(folder + "/")
    }
}

/// The layout the app runs with, built from the settings
/// (`Settings.claudeAccounts`) and the environment sessions start in.
///
/// It stays `~/.claude` alone until a process opts in with `bootstrap`:
/// the app and the server do, at start. Tests never do, so neither the
/// developer's `CLAUDE_CONFIG_DIR` nor their real settings reach them.
public enum ClaudeConfigDirectories {
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var layout = ClaudeConfigLayout()
        var accounts: [ClaudeAccount] = []
        var machineLogin: String?
        var environment: [String: String] = [:]
        var settingsPath: String?
        var onChange: (@Sendable (ClaudeConfigLayout) -> Void)?
    }

    private static let box = Box()

    /// The settings file whose accounts apply, once `bootstrap` ran.
    public static var settingsPath: String? {
        box.lock.lock()
        defer { box.lock.unlock() }
        return box.settingsPath
    }

    public static var current: ClaudeConfigLayout {
        box.lock.lock()
        defer { box.lock.unlock() }
        return box.layout
    }

    /// Applies the accounts of the settings. Returns true when the layout
    /// changed.
    @discardableResult
    public static func update(accounts: [ClaudeAccount], machineLoginDirectory: String?) -> Bool {
        box.lock.lock()
        guard accounts != box.accounts || machineLoginDirectory != box.machineLogin else {
            box.lock.unlock()
            return false
        }
        box.accounts = accounts
        box.machineLogin = machineLoginDirectory
        return rebuildAndNotify()
    }

    /// Called, off the lock, after the layout changed.
    public static func onChange(_ handler: @escaping @Sendable (ClaudeConfigLayout) -> Void) {
        box.lock.lock()
        box.onChange = handler
        box.lock.unlock()
    }

    /// Takes `CLAUDE_CONFIG_DIR` from the environment sessions start in
    /// (the user's login shell, which tmux and every command the app runs
    /// get), instead of the app's own, which Finder starts without it.
    @discardableResult
    public static func update(environment: [String: String]) -> Bool {
        box.lock.lock()
        let relevant = Self.relevant(environment)
        guard relevant != box.environment else {
            box.lock.unlock()
            return false
        }
        box.environment = relevant
        return rebuildAndNotify()
    }

    /// Opts the process in: the `SettingsStore` of `settingsPath` keeps the
    /// accounts current from then on, and they are read once now, before
    /// anything scans for sessions.
    public static func bootstrap(settingsPath: String = (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code/settings.json")) {
        let path = (settingsPath as NSString).standardizingPath
        box.lock.lock()
        box.settingsPath = path
        box.lock.unlock()
        guard let data = FileManager.default.contents(atPath: path),
              let settings = try? JSONDecoder().decode(Settings.self, from: data) else { return }
        update(accounts: settings.claudeAccounts, machineLoginDirectory: settings.claudeMachineLoginDirectory)
    }

    /// Called by a `SettingsStore` with every settings value it read or
    /// wrote; applied only for the file `bootstrap` named.
    static func settingsChanged(_ settings: Settings, at path: String) {
        guard let bootstrapped = Self.settingsPath, bootstrapped == (path as NSString).standardizingPath else { return }
        update(accounts: settings.claudeAccounts, machineLoginDirectory: settings.claudeMachineLoginDirectory)
    }

    /// Caller holds the lock; this releases it.
    private static func rebuildAndNotify() -> Bool {
        let layout = ClaudeConfigLayout(
            environment: box.environment, accounts: box.accounts,
            machineLoginDirectory: box.machineLogin)
        guard layout != box.layout else {
            box.lock.unlock()
            return false
        }
        box.layout = layout
        let handler = box.onChange
        box.lock.unlock()
        KanbanCodeLog.info("claude-accounts", "Claude config folders: \(layout.directories.joined(separator: ", "))")
        handler?(layout)
        return true
    }

    private static func relevant(_ environment: [String: String]) -> [String: String] {
        environment["CLAUDE_CONFIG_DIR"].map { ["CLAUDE_CONFIG_DIR": $0] } ?? [:]
    }
}
