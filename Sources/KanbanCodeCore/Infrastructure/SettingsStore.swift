import Foundation

/// Application settings, stored at ~/.kanban-code/settings.json.
public struct Settings: Codable, Sendable {
    public var projects: [Project]
    public var globalView: GlobalViewSettings
    public var github: GitHubSettings
    public var notifications: NotificationSettings
    public var remote: RemoteSettings?
    public var sessionTimeout: SessionTimeoutSettings
    public var promptTemplate: String
    public var githubIssuePromptTemplate: String
    public var columnOrder: [KanbanCodeColumn]
    public var hasCompletedOnboarding: Bool
    public var defaultAssistant: CodingAssistant?
    public var enabledAssistants: [CodingAssistant]

    public init(
        projects: [Project] = [],
        globalView: GlobalViewSettings = GlobalViewSettings(),
        github: GitHubSettings = GitHubSettings(),
        notifications: NotificationSettings = NotificationSettings(),
        remote: RemoteSettings? = nil,
        sessionTimeout: SessionTimeoutSettings = SessionTimeoutSettings(),
        promptTemplate: String = "",
        githubIssuePromptTemplate: String = "#${number}: ${title}\n\n${body}",
        columnOrder: [KanbanCodeColumn] = KanbanCodeColumn.allCases,
        hasCompletedOnboarding: Bool = false,
        defaultAssistant: CodingAssistant? = nil,
        enabledAssistants: [CodingAssistant] = CodingAssistant.allCases
    ) {
        self.projects = projects
        self.globalView = globalView
        self.github = github
        self.notifications = notifications
        self.remote = remote
        self.sessionTimeout = sessionTimeout
        self.promptTemplate = promptTemplate
        self.githubIssuePromptTemplate = githubIssuePromptTemplate
        self.columnOrder = columnOrder
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.defaultAssistant = defaultAssistant
        self.enabledAssistants = enabledAssistants
    }

    private enum CodingKeys: String, CodingKey {
        case projects, globalView, github, notifications, remote, sessionTimeout
        case promptTemplate, githubIssuePromptTemplate, columnOrder, hasCompletedOnboarding, defaultAssistant
        case enabledAssistants
        case skill // backward-compat: old name for promptTemplate
    }

    // Backward-compatible decoding — new fields default gracefully
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projects = try container.decodeIfPresent([Project].self, forKey: .projects) ?? []
        globalView = try container.decodeIfPresent(GlobalViewSettings.self, forKey: .globalView) ?? GlobalViewSettings()
        github = try container.decodeIfPresent(GitHubSettings.self, forKey: .github) ?? GitHubSettings()
        notifications = try container.decodeIfPresent(NotificationSettings.self, forKey: .notifications) ?? NotificationSettings()
        remote = try container.decodeIfPresent(RemoteSettings.self, forKey: .remote)
        sessionTimeout = try container.decodeIfPresent(SessionTimeoutSettings.self, forKey: .sessionTimeout) ?? SessionTimeoutSettings()
        // Backward-compat: try "promptTemplate" first, fall back to "skill"
        promptTemplate = try container.decodeIfPresent(String.self, forKey: .promptTemplate)
            ?? container.decodeIfPresent(String.self, forKey: .skill) ?? ""
        githubIssuePromptTemplate = try container.decodeIfPresent(String.self, forKey: .githubIssuePromptTemplate)
            ?? "#${number}: ${title}\n\n${body}"
        columnOrder = try container.decodeIfPresent([KanbanCodeColumn].self, forKey: .columnOrder) ?? KanbanCodeColumn.allCases
        hasCompletedOnboarding = try container.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? false
        defaultAssistant = try container.decodeIfPresent(CodingAssistant.self, forKey: .defaultAssistant)
        enabledAssistants = try container.decodeIfPresent([CodingAssistant].self, forKey: .enabledAssistants)
            ?? CodingAssistant.allCases
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(projects, forKey: .projects)
        try container.encode(globalView, forKey: .globalView)
        try container.encode(github, forKey: .github)
        try container.encode(notifications, forKey: .notifications)
        try container.encodeIfPresent(remote, forKey: .remote)
        try container.encode(sessionTimeout, forKey: .sessionTimeout)
        try container.encode(promptTemplate, forKey: .promptTemplate)
        try container.encode(githubIssuePromptTemplate, forKey: .githubIssuePromptTemplate)
        try container.encode(columnOrder, forKey: .columnOrder)
        try container.encode(hasCompletedOnboarding, forKey: .hasCompletedOnboarding)
        try container.encodeIfPresent(defaultAssistant, forKey: .defaultAssistant)
        try container.encode(enabledAssistants, forKey: .enabledAssistants)
        // Note: "skill" is NOT encoded — only read for backward-compat
    }
}

public struct GlobalViewSettings: Codable, Sendable {
    public var excludedPaths: [String]

    public init(excludedPaths: [String] = []) {
        self.excludedPaths = excludedPaths
    }
}

public struct GitHubSettings: Codable, Sendable {
    public var defaultFilter: String
    public var pollIntervalSeconds: Int
    public var mergeCommand: String

    public static let defaultMergeCommand = "gh pr merge ${number} --squash --delete-branch"

    public init(defaultFilter: String = "assignee:@me is:open", pollIntervalSeconds: Int = 60, mergeCommand: String? = nil) {
        self.defaultFilter = defaultFilter
        self.pollIntervalSeconds = pollIntervalSeconds
        self.mergeCommand = mergeCommand ?? Self.defaultMergeCommand
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defaultFilter = try c.decodeIfPresent(String.self, forKey: .defaultFilter) ?? "assignee:@me is:open"
        pollIntervalSeconds = try c.decodeIfPresent(Int.self, forKey: .pollIntervalSeconds) ?? 60
        mergeCommand = try c.decodeIfPresent(String.self, forKey: .mergeCommand) ?? Self.defaultMergeCommand
    }
}

public struct NotificationSettings: Codable, Sendable {
    public var pushoverEnabled: Bool
    public var pushoverToken: String?
    public var pushoverUserKey: String?
    public var renderMarkdownImage: Bool

    public init(pushoverEnabled: Bool = false, pushoverToken: String? = nil, pushoverUserKey: String? = nil, renderMarkdownImage: Bool = false) {
        self.pushoverEnabled = pushoverEnabled
        self.pushoverToken = pushoverToken
        self.pushoverUserKey = pushoverUserKey
        self.renderMarkdownImage = renderMarkdownImage
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pushoverEnabled = try c.decodeIfPresent(Bool.self, forKey: .pushoverEnabled) ?? false
        pushoverToken = try c.decodeIfPresent(String.self, forKey: .pushoverToken)
        pushoverUserKey = try c.decodeIfPresent(String.self, forKey: .pushoverUserKey)
        renderMarkdownImage = try c.decodeIfPresent(Bool.self, forKey: .renderMarkdownImage) ?? false
    }
}

public struct RemoteSettings: Codable, Sendable {
    public var host: String
    public var remotePath: String
    public var localPath: String
    public var syncIgnores: [String]?  // nil = use MutagenAdapter.defaultIgnores

    public init(host: String, remotePath: String, localPath: String, syncIgnores: [String]? = nil) {
        self.host = host
        self.remotePath = remotePath
        self.localPath = localPath
        self.syncIgnores = syncIgnores
    }
}

public struct SessionTimeoutSettings: Codable, Sendable {
    public var activeThresholdMinutes: Int

    public init(activeThresholdMinutes: Int = 1440) {
        self.activeThresholdMinutes = activeThresholdMinutes
    }
}

/// Reads and writes ~/.kanban-code/settings.json.
public actor SettingsStore {
    private let filePath: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(basePath: String? = nil) {
        let base = basePath ?? (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code")
        self.filePath = (base as NSString).appendingPathComponent("settings.json")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        self.decoder = JSONDecoder()
    }

    /// Read settings, creating defaults if file doesn't exist.
    public func read() throws -> Settings {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: filePath) else {
            let defaults = Settings()
            try write(defaults)
            return defaults
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
        return try decoder.decode(Settings.self, from: data)
    }

    /// Write settings atomically.
    public func write(_ settings: Settings) throws {
        let fileManager = FileManager.default
        let dir = (filePath as NSString).deletingLastPathComponent
        try fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let data = try encoder.encode(settings)
        let tmpPath = filePath + ".tmp"
        try data.write(to: URL(fileURLWithPath: tmpPath))
        _ = try? fileManager.removeItem(atPath: filePath)
        try fileManager.moveItem(atPath: tmpPath, toPath: filePath)
    }

    /// The file path for external access.
    public var path: String { filePath }

    // MARK: - Project convenience methods

    /// Add a project to settings. Throws if path already exists.
    public func addProject(_ project: Project) throws {
        var settings = try read()
        guard !settings.projects.contains(where: { $0.path == project.path }) else {
            throw SettingsError.duplicateProject(project.path)
        }
        settings.projects.append(project)
        try write(settings)
    }

    /// Update an existing project (matched by path).
    public func updateProject(_ project: Project) throws {
        var settings = try read()
        guard let index = settings.projects.firstIndex(where: { $0.path == project.path }) else {
            throw SettingsError.projectNotFound(project.path)
        }
        settings.projects[index] = project
        try write(settings)
    }

    /// Remove a project by path.
    public func removeProject(path: String) throws {
        var settings = try read()
        guard settings.projects.contains(where: { $0.path == path }) else {
            throw SettingsError.projectNotFound(path)
        }
        settings.projects.removeAll { $0.path == path }
        try write(settings)
    }

    /// Save the reordered projects list.
    public func reorderProjects(_ projects: [Project]) throws {
        var settings = try read()
        settings.projects = projects
        try write(settings)
    }
}

public enum SettingsError: LocalizedError {
    case duplicateProject(String)
    case projectNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .duplicateProject(let path): "Project already configured: \(path)"
        case .projectNotFound(let path): "Project not found: \(path)"
        }
    }
}
