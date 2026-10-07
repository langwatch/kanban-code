import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The login file of a coding assistant.
///
/// Claude Code keeps its OAuth tokens in the Keychain on macOS and in
/// `~/.claude/.credentials.json` on Linux, with the same JSON inside. Codex
/// keeps `~/.codex/auth.json` on both. Both rotate the refresh token on
/// every refresh, so a copy on a machine drifts from the copy on the Mac
/// within hours and one of them shows "Login expired". Kanban Code keeps the
/// copies equal: the newest one wins, in both directions.
public enum AssistantLoginKind: String, CaseIterable, Sendable {
    case claude
    case codex

    /// Path of the login file under the home directory of a machine.
    public var remoteRelativePath: String {
        switch self {
        case .claude: ".claude/.credentials.json"
        case .codex: ".codex/auth.json"
        }
    }

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }
}

/// One copy of a login file, with the moment it was last refreshed.
public struct AssistantLogin: Sendable, Equatable {
    public let kind: AssistantLoginKind
    public let data: Data
    /// Seconds since 1970. A copy with a higher value is the newer one.
    public let freshness: TimeInterval
    /// What the copy holds, independent of how its JSON is written: key
    /// order, spacing or escaping never make two copies differ.
    public let fingerprint: String
    /// The account the tokens belong to, when the file names it (Codex).
    public let accountId: String?

    /// Nil when the bytes are not a login of this kind (no JSON, no token).
    public init?(kind: AssistantLoginKind, data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let freshness = Self.freshness(of: object, kind: kind) else { return nil }
        self.kind = kind
        self.data = data
        self.freshness = freshness
        self.fingerprint = Self.fingerprint(of: object, kind: kind)
        switch kind {
        case .claude: self.accountId = nil
        case .codex: self.accountId = (object["tokens"] as? [String: Any])?["account_id"] as? String
        }
    }

    public static func == (lhs: AssistantLogin, rhs: AssistantLogin) -> Bool {
        lhs.kind == rhs.kind && lhs.fingerprint == rhs.fingerprint
    }

    private static func freshness(of object: [String: Any], kind: AssistantLoginKind) -> TimeInterval? {
        switch kind {
        case .claude:
            guard let oauth = object["claudeAiOauth"] as? [String: Any],
                  let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
            let expiresAtMilliseconds = (oauth["expiresAt"] as? NSNumber)?.doubleValue ?? 0
            return expiresAtMilliseconds / 1000
        case .codex:
            guard let tokens = object["tokens"] as? [String: Any], !tokens.isEmpty else { return nil }
            guard let refreshed = object["last_refresh"] as? String else { return 0 }
            return Self.parseISO8601(refreshed) ?? 0
        }
    }

    /// The tokens and their expiry, canonically serialized.
    private static func fingerprint(of object: [String: Any], kind: AssistantLoginKind) -> String {
        let relevant: Any
        switch kind {
        case .claude: relevant = object["claudeAiOauth"] ?? [:]
        case .codex: relevant = ["tokens": object["tokens"] ?? [:], "last_refresh": object["last_refresh"] ?? ""]
        }
        let data = try? JSONSerialization.data(withJSONObject: relevant, options: [.sortedKeys, .withoutEscapingSlashes])
        return data.map { SyncHash.hex($0) } ?? ""
    }

    private static func parseISO8601(_ text: String) -> TimeInterval? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date.timeIntervalSince1970 }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)?.timeIntervalSince1970
    }

    /// What to do with the two copies of one login.
    public enum Decision: Equatable, Sendable {
        /// Send the Mac's copy to the machine.
        case push
        /// Take the machine's copy on the Mac.
        case pull
        case none
    }

    /// The newest copy wins. Copies holding the same tokens need nothing,
    /// however their JSON is written; equal freshness with different tokens
    /// goes the Mac's way. Freshness only orders two copies of one account:
    /// when the machine is signed in as another account than the Mac, the
    /// Mac's account goes to the machine, whichever copy expires later (an
    /// account switch on the Mac is never undone by a machine). A Mac login
    /// that could not be read is never overwritten: only a Mac that has no
    /// login at all takes the machine's.
    public static func decide(
        local: LocalLogin,
        remote: AssistantLogin?,
        localAccount: String? = nil,
        remoteAccount: String? = nil
    ) -> Decision {
        switch (local, remote) {
        case (.unreadable, _): return .none
        case (.absent, nil): return .none
        case (.absent, .some): return .pull
        case (.present, nil): return .push
        case (.present(let local), .some(let remote)):
            if local.fingerprint == remote.fingerprint { return .none }
            if let localAccount, let remoteAccount, localAccount != remoteAccount { return .push }
            return remote.freshness > local.freshness ? .pull : .push
        }
    }
}

/// The Mac's copy of one login, as far as it could be read.
public enum LocalLogin: Sendable, Equatable {
    case present(AssistantLogin)
    /// The Mac has no login of this kind.
    case absent
    /// The store failed or held something that is not a login: the reason,
    /// never the bytes.
    case unreadable(String)

    public init(_ read: LocalLoginRead, kind: AssistantLoginKind) {
        switch read {
        case .found(let data):
            if let login = AssistantLogin(kind: kind, data: data) {
                self = .present(login)
            } else {
                self = .unreadable("\(data.count) bytes that are not a \(kind.displayName) login")
            }
        case .absent: self = .absent
        case .failed(let reason): self = .unreadable(reason)
        }
    }

    var login: AssistantLogin? {
        if case .present(let login) = self { return login }
        return nil
    }
}

/// The outcome of reading a login from the Mac's store.
public enum LocalLoginRead: Sendable, Equatable {
    case found(Data)
    case absent
    case failed(String)
}

/// Where the Mac keeps each login.
public protocol LocalLoginStore: Sendable {
    func read(_ kind: AssistantLoginKind) async -> LocalLoginRead
    func write(_ kind: AssistantLoginKind, data: Data) async throws
    /// The `oauthAccount` block of `~/.claude.json`: who the Claude login is,
    /// shown by Claude and used for its feature flags.
    func claudeAccount() async -> [String: Any]?
}

/// Keychain for Claude, files for the rest, as the assistants do on a Mac.
public struct MacLoginStore: LocalLoginStore {
    public static let keychainService = "Claude Code-credentials"
    private let home: String
    private let account: String

    public init(home: String = NSHomeDirectory(), account: String = NSUserName()) {
        self.home = home
        self.account = account
    }

    /// `security` exits with this when the Keychain has no such item.
    static let keychainItemNotFound: Int32 = 44

    public func read(_ kind: AssistantLoginKind) async -> LocalLoginRead {
        switch kind {
        case .claude:
            guard FileManager.default.isExecutableFile(atPath: "/usr/bin/security") else {
                return readFile(kind)
            }
            let result: ShellCommand.Result
            do {
                result = try await ShellCommand.run(
                    "/usr/bin/security",
                    arguments: ["find-generic-password", "-s", Self.keychainService, "-a", account, "-w"],
                    timeout: 20)
            } catch {
                return .failed("Keychain read: \(error.localizedDescription)")
            }
            if result.succeeded {
                let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return .found(Data(text.utf8)) }
                return readFile(kind)
            }
            if result.exitCode == Self.keychainItemNotFound { return readFile(kind) }
            let reason = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed("Keychain read exited \(result.exitCode): \(reason.prefix(200))")
        case .codex:
            return readFile(kind)
        }
    }

    private func readFile(_ kind: AssistantLoginKind) -> LocalLoginRead {
        let path = "\(home)/\(kind.remoteRelativePath)"
        guard FileManager.default.fileExists(atPath: path) else { return .absent }
        guard let data = FileManager.default.contents(atPath: path) else { return .failed("\(path) is not readable") }
        return .found(data)
    }

    public func write(_ kind: AssistantLoginKind, data: Data) async throws {
        switch kind {
        case .claude:
            guard let text = String(data: data, encoding: .utf8) else { return }
            let result = try await ShellCommand.run(
                "/usr/bin/security",
                arguments: ["add-generic-password", "-U", "-s", Self.keychainService, "-a", account, "-w", text],
                timeout: 20)
            guard result.succeeded else {
                throw NSError(domain: "MacLoginStore", code: Int(result.exitCode),
                              userInfo: [NSLocalizedDescriptionKey: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)])
            }
        case .codex:
            let path = "\(home)/\(kind.remoteRelativePath)"
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
    }

    public func claudeAccount() async -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: "\(home)/.claude.json"),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["oauthAccount"] as? [String: Any]
    }
}

/// Whose account the tokens of a Claude login belong to. The account a
/// `~/.claude.json` names can lag the tokens beside it (another tool
/// switched one and not the other), so the tokens themselves are asked.
public protocol ClaudeTokenOwnerResolver: Sendable {
    /// The account uuid, nil when it can't be told (expired token, offline).
    func owner(of login: AssistantLogin) async -> String?
}

/// Asks Anthropic's profile endpoint, once per set of tokens.
public actor AnthropicTokenOwner: ClaudeTokenOwnerResolver {
    public static let shared = AnthropicTokenOwner()
    private var owners: [String: String] = [:]

    public func owner(of login: AssistantLogin) async -> String? {
        guard login.kind == .claude else { return nil }
        if let known = owners[login.fingerprint] { return known }
        guard login.freshness > Date().timeIntervalSince1970,
              let object = try? JSONSerialization.jsonObject(with: login.data) as? [String: Any],
              let token = (object["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String,
              let url = URL(string: "https://api.anthropic.com/api/oauth/profile") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let profile = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let uuid = (profile["account"] as? [String: Any])?["uuid"] as? String, !uuid.isEmpty else { return nil }
        if owners.count > 64 { owners.removeAll() }
        owners[login.fingerprint] = uuid
        return uuid
    }
}

/// The account each machine and the Mac last agreed on, per login kind,
/// so a sync can tell which side switched when the two differ.
public protocol LoginAccountMemory: Sendable {
    func agreed(_ kind: AssistantLoginKind, machine: String) async -> String?
    func record(_ kind: AssistantLoginKind, machine: String, account: String) async
}

/// `LoginAccountMemory` kept in a JSON file (`login-accounts.json` in the
/// Kanban home): `{"<machine>": {"claude": "<account>", ...}}`.
public actor FileLoginAccountMemory: LoginAccountMemory {
    public let path: String
    private var cache: [String: [String: String]]?

    public init(path: String) {
        self.path = path
    }

    public static func inKanbanHome(_ kanbanHome: String = (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code")) -> FileLoginAccountMemory {
        FileLoginAccountMemory(path: (kanbanHome as NSString).appendingPathComponent("login-accounts.json"))
    }

    private func load() -> [String: [String: String]] {
        if let cache { return cache }
        let loaded = FileManager.default.contents(atPath: path)
            .flatMap { try? JSONDecoder().decode([String: [String: String]].self, from: $0) } ?? [:]
        cache = loaded
        return loaded
    }

    public func agreed(_ kind: AssistantLoginKind, machine: String) -> String? {
        load()[machine]?[kind.rawValue]
    }

    public func record(_ kind: AssistantLoginKind, machine: String, account: String) {
        var all = load()
        guard all[machine]?[kind.rawValue] != account else { return }
        all[machine, default: [:]][kind.rawValue] = account
        cache = all
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(all) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}

/// `LoginAccountMemory` for one process.
public actor InMemoryLoginAccountMemory: LoginAccountMemory {
    private var accounts: [String: String] = [:]

    public init(_ seed: [String: String] = [:]) {
        accounts = seed
    }

    public func agreed(_ kind: AssistantLoginKind, machine: String) -> String? {
        accounts["\(machine)|\(kind.rawValue)"]
    }

    public func record(_ kind: AssistantLoginKind, machine: String, account: String) {
        accounts["\(machine)|\(kind.rawValue)"] = account
    }
}

/// Brings the logins of one machine and the Mac to the same copy.
public struct AssistantLoginSync: Sendable {
    public struct Change: Equatable, Sendable {
        public let kind: AssistantLoginKind
        public let decision: AssistantLogin.Decision
        /// The copy that moved belongs to another account than the one it
        /// replaced. False when either account is unknown.
        public let accountChanged: Bool

        public init(kind: AssistantLoginKind, decision: AssistantLogin.Decision, accountChanged: Bool = false) {
            self.kind = kind
            self.decision = decision
            self.accountChanged = accountChanged
        }
    }

    private let runner: any RemoteCommandRunner
    private let store: any LocalLoginStore
    private let remoteHome: String
    private let machineName: String
    private let owners: any ClaudeTokenOwnerResolver
    private let accounts: any LoginAccountMemory

    public init(
        runner: any RemoteCommandRunner,
        store: any LocalLoginStore,
        remoteHome: String,
        machineName: String = "machine",
        owners: any ClaudeTokenOwnerResolver = AnthropicTokenOwner.shared,
        accounts: any LoginAccountMemory = InMemoryLoginAccountMemory()
    ) {
        self.runner = runner
        self.store = store
        self.remoteHome = remoteHome
        self.machineName = machineName
        self.owners = owners
        self.accounts = accounts
    }

    /// When the Mac and the machine are signed in as different accounts:
    /// the side that switched since they last agreed keeps its account.
    /// The Mac's goes to the machine when the Mac switched, or when they
    /// never agreed (a machine started from a snapshot). A machine that
    /// switched keeps its own, and its tokens are left alone until the two
    /// agree again.
    static func differentAccounts(local: String, remote: String, agreed: String?) -> AssistantLogin.Decision {
        guard let agreed else { return .push }
        if local != agreed { return .push }
        return remote == agreed ? .push : .none
    }

    /// Runs node wherever the machine has it: boxd machines keep it in
    /// /usr/local/bin, Debian in /usr/bin.
    static let nodePrefix = "PATH=\"$PATH:/usr/local/bin:/usr/bin\"; "

    /// One command reads every login file of the machine, one line each,
    /// base64 so the JSON never meets the shell, then the `accountUuid` of
    /// the machine's Claude account on the last line.
    public static func readScript(remoteHome: String) -> String {
        let paths = AssistantLoginKind.allCases.map { "\(remoteHome)/\($0.remoteRelativePath)" }
        let config = BoxdMachineSupervisor.shellEscape("\(remoteHome)/.claude.json")
        let account = "try{const a=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8')).oauthAccount;"
            + "if(a&&typeof a.accountUuid==='string')process.stdout.write(a.accountUuid)}catch(e){}"
        return "for f in " + paths.map(BoxdMachineSupervisor.shellEscape).joined(separator: " ")
            + "; do if [ -f \"$f\" ]; then base64 -w0 \"$f\"; fi; echo; done; "
            + nodePrefix + "if command -v node >/dev/null 2>&1; then node -e "
            + BoxdMachineSupervisor.shellEscape(account) + " " + config + " 2>/dev/null; fi; echo"
    }

    /// Merges the Mac's `oauthAccount` into the machine's `~/.claude.json`.
    public static func accountScript(account: [String: Any], claudeConfigPath: String) -> String {
        let accountJSON = (try? JSONSerialization.data(withJSONObject: account, options: [.withoutEscapingSlashes, .sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let pathJSON = (try? JSONSerialization.data(withJSONObject: [claudeConfigPath], options: .withoutEscapingSlashes)).flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return """
        const fs = require('fs');
        const file = \(pathJSON)[0];
        let config = {};
        try { config = JSON.parse(fs.readFileSync(file, 'utf8')); } catch (e) {}
        config.oauthAccount = \(accountJSON);
        fs.writeFileSync(file, JSON.stringify(config, null, 2));
        """
    }

    /// Returns the logins that moved, in either direction.
    public func run() async -> [Change] {
        guard let result = try? await runner.exec(["bash", "-c", Self.readScript(remoteHome: remoteHome)], stdin: nil, cwd: nil, timeout: 30),
              result.succeeded else { return [] }
        let lines = result.stdout.components(separatedBy: "\n")
        let kinds = AssistantLoginKind.allCases
        let accountLine = kinds.count < lines.count ? lines[kinds.count].trimmingCharacters(in: .whitespaces) : ""
        let remoteClaudeAccount = accountLine.isEmpty ? nil : accountLine
        var changes: [Change] = []
        for (index, kind) in kinds.enumerated() {
            let line = index < lines.count ? lines[index].trimmingCharacters(in: .whitespaces) : ""
            let remote = line.isEmpty ? nil : Data(base64Encoded: line).flatMap { AssistantLogin(kind: kind, data: $0) }
            let local = LocalLogin(await store.read(kind), kind: kind)
            if case .unreadable(let reason) = local {
                KanbanCodeLog.warn("boxd", "\(machineName): \(kind.displayName) login on this Mac could not be read, not synced: \(reason)")
                continue
            }
            let localAccount: String?
            let remoteAccount: String?
            switch kind {
            case .claude:
                // Asked only when the tokens differ: equal tokens move nothing.
                let differ = local.login != nil && remote != nil && local.login?.fingerprint != remote?.fingerprint
                var localOwner: String?
                var remoteOwner: String?
                if differ, let localLogin = local.login, let remote {
                    localOwner = await owners.owner(of: localLogin)
                    remoteOwner = await owners.owner(of: remote)
                }
                let named = await store.claudeAccount()?["accountUuid"] as? String
                localAccount = localOwner ?? named
                remoteAccount = remoteOwner ?? remoteClaudeAccount
            case .codex:
                localAccount = local.login?.accountId
                remoteAccount = remote?.accountId
            }
            var decision = AssistantLogin.decide(
                local: local, remote: remote, localAccount: localAccount, remoteAccount: remoteAccount)
            let accountChanged = localAccount != nil && remoteAccount != nil && localAccount != remoteAccount
            if accountChanged, let localAccount, let remoteAccount {
                let agreed = await accounts.agreed(kind, machine: machineName)
                if decision == .push {
                    decision = Self.differentAccounts(local: localAccount, remote: remoteAccount, agreed: agreed)
                }
                if decision == .none, agreed == nil {
                    await accounts.record(kind, machine: machineName, account: localAccount)
                }
            } else if let localAccount, localAccount == remoteAccount {
                await accounts.record(kind, machine: machineName, account: localAccount)
            }
            guard decision != .none else { continue }
            if decision == .push, let localAccount {
                await accounts.record(kind, machine: machineName, account: localAccount)
            } else if decision == .pull, let remoteAccount {
                await accounts.record(kind, machine: machineName, account: remoteAccount)
            }
            let remotePath = "\(remoteHome)/\(kind.remoteRelativePath)"
            do {
                switch decision {
                case .none:
                    continue
                case .push:
                    guard let login = local.login else { continue }
                    try await runner.put(path: remotePath, data: login.data, mode: 0o600)
                    if kind == .claude, let account = await store.claudeAccount() {
                        let script = Self.accountScript(account: account, claudeConfigPath: "\(remoteHome)/.claude.json")
                        _ = try? await runner.exec(
                            ["bash", "-c", Self.nodePrefix + "exec node -e \"$1\"", "node", script],
                            stdin: nil, cwd: nil, timeout: 30)
                    }
                case .pull:
                    guard let remote else { continue }
                    try await store.write(kind, data: remote.data)
                }
                KanbanCodeLog.info("boxd", "\(machineName): \(kind.displayName) login "
                    + "\(decision == .push ? "sent to the machine" : "taken from the machine")"
                    + "\(accountChanged ? ", another account" : ""): Mac \(Self.describe(local)), machine \(Self.describe(remote))")
                changes.append(Change(kind: kind, decision: decision, accountChanged: accountChanged))
            } catch {
                KanbanCodeLog.warn("boxd", "\(machineName): \(kind.displayName) login sync failed: \(error)")
            }
        }
        return changes
    }

    /// What a log line may say about a copy: its expiry and a short digest,
    /// never a token.
    static func describe(_ local: LocalLogin) -> String {
        switch local {
        case .present(let login): describe(login)
        case .absent: "none"
        case .unreadable(let reason): "unreadable (\(reason))"
        }
    }

    static func describe(_ login: AssistantLogin?) -> String {
        guard let login else { return "none" }
        let when = Date(timeIntervalSince1970: login.freshness).ISO8601Format()
        return "\(when) #\(login.fingerprint.prefix(8))"
    }
}

