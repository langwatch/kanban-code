import Foundation

/// Tokens of the GitHub accounts `ClaudeAccount.githubUser` names, read
/// from `gh auth token --user <login>` and kept a while, so `gh` for a
/// project, and a card's session, act as that account instead of the one
/// `gh` has active.
public actor GitHubAccountTokens {
    public static let shared = GitHubAccountTokens()

    public typealias Fetch = @Sendable (_ user: String) async -> String?

    private let fetch: Fetch
    private let lifetime: TimeInterval
    private let retryAfter: TimeInterval
    private var tokens: [String: (token: String?, at: Date)] = [:]
    /// A fetch under way, which callers arriving meanwhile wait for.
    private var fetching: [String: Task<String?, Never>] = [:]

    /// `lifetime`: how long a token is reused. `retryAfter`: how long a
    /// login whose token could not be read is left alone, so a missing
    /// login does not run `gh` on every poll.
    public init(lifetime: TimeInterval = 600, retryAfter: TimeInterval = 60, fetch: Fetch? = nil) {
        self.fetch = fetch ?? Self.ghAuthToken
        self.lifetime = lifetime
        self.retryAfter = retryAfter
    }

    public func token(for user: String, now: Date = Date()) async -> String? {
        if let cached = tokens[user],
           now.timeIntervalSince(cached.at) < (cached.token == nil ? retryAfter : lifetime) {
            return cached.token
        }
        if let running = fetching[user] { return await running.value }
        let fetch = self.fetch
        let task = Task { await fetch(user) }
        fetching[user] = task
        let token = await task.value
        fetching[user] = nil
        if token == nil {
            KanbanCodeLog.warn("github", "No gh token for \(user); gh runs as the active account (gh auth login --user \(user))")
        }
        tokens[user] = (token, now)
        return token
    }

    /// `GH_TOKEN` for commands run in `path`, empty when no account claims
    /// it, it names no GitHub login, or the token cannot be read.
    public func environment(forPath path: String, layout: ClaudeConfigLayout) async -> [String: String] {
        guard let user = layout.account(forPath: path)?.githubUser,
              let token = await token(for: user) else { return [:] }
        return ["GH_TOKEN": token]
    }

    static func ghAuthToken(user: String) async -> String? {
        guard let gh = ShellCommand.findExecutable("gh") else { return nil }
        var env = ShellCommand.loginEnvironment
        // Set, these make `gh auth token` print them instead.
        env.removeValue(forKey: "GH_TOKEN")
        env.removeValue(forKey: "GITHUB_TOKEN")
        guard let result = try? await ShellCommand.run(
            gh, arguments: ["auth", "token", "--hostname", "github.com", "--user", user],
            environment: env, timeout: 20),
              result.succeeded else { return nil }
        let token = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }
}
