import Foundation

/// A Claude Code config folder (`CLAUDE_CONFIG_DIR`) and the projects that
/// use it. Lets one Kanban board show sessions of several Claude accounts,
/// for instance a work one in `~/.claude-work` for `~/work` and the default
/// `~/.claude` for everything else.
public struct ClaudeAccount: Codable, Sendable, Equatable, Identifiable {
    public var id: String { configDirectory }
    /// Display name in Settings.
    public var name: String
    /// The folder Claude Code runs with as `CLAUDE_CONFIG_DIR`. `~` is the
    /// home folder.
    public var configDirectory: String
    /// Folders whose sessions run with this account: a folder and everything
    /// under it. `~` is the home folder.
    public var projectPaths: [String]
    /// The GitHub login `gh` uses for these projects (`gh auth token
    /// --user`), nil for the active `gh` account.
    public var githubUser: String?

    public init(name: String, configDirectory: String, projectPaths: [String] = [], githubUser: String? = nil) {
        self.name = name
        self.configDirectory = configDirectory
        self.projectPaths = projectPaths
        self.githubUser = githubUser
    }

    private enum CodingKeys: String, CodingKey {
        case name, configDirectory, projectPaths, githubUser
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        configDirectory = try c.decode(String.self, forKey: .configDirectory)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? (configDirectory as NSString).lastPathComponent
        projectPaths = (try? c.decodeIfPresent([String].self, forKey: .projectPaths)) ?? []
        let user = (try? c.decodeIfPresent(String.self, forKey: .githubUser))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        githubUser = (user?.isEmpty ?? true) ? nil : user
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(configDirectory, forKey: .configDirectory)
        try c.encode(projectPaths, forKey: .projectPaths)
        try c.encodeIfPresent(githubUser, forKey: .githubUser)
    }
}
