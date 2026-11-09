import Foundation

/// Application settings, stored at ~/.kanban-code/settings.json.
public struct Settings: Codable, Sendable {
    public var projects: [Project]
    public var globalView: GlobalViewSettings
    public var github: GitHubSettings
    public var notifications: NotificationSettings
    public var remote: RemoteSettings?
    /// Which remote backend the app uses when a card runs remotely.
    public var remoteMode: RemoteMode
    /// Settings of the boxd remote mode.
    public var boxd: BoxdSettings?
    public var sessionTimeout: SessionTimeoutSettings
    public var promptTemplate: String
    public var githubIssuePromptTemplate: String
    public var columnOrder: [KanbanCodeColumn]
    public var hasCompletedOnboarding: Bool
    public var defaultAssistant: CodingAssistant?
    public var enabledAssistants: [CodingAssistant]
    /// User-defined API service configurations (e.g. Ollama, LiteLLM proxy).
    public var apiServices: [APIService]
    /// Maps `CodingAssistant.rawValue` → `APIService.id` for the default service per assistant.
    public var defaultAPIServiceIds: [String: String]
    /// Automatic context-limit guard for Claude sessions.
    public var selfCompact: SelfCompactSettings
    /// First-class subagent hierarchy limits.
    public var subagents: SubagentSettings
    /// Maps `CodingAssistant.rawValue` → the launch command template of that assistant.
    public var assistantCommands: [String: AssistantCommandTemplate]
    /// Maps `CodingAssistant.rawValue` → what keeps the main session of a
    /// card running. Missing means tmux.
    public var assistantRuntimes: [String: SessionRuntime]
    public var remoteControl: RemoteControlSettings
    /// Other masters this one syncs cards with (Settings > Peers).
    public var peers: [PeerConfig]
    /// Claude Code config folders besides `~/.claude`, and the projects that
    /// use each (Settings > Claude accounts).
    public var claudeAccounts: [ClaudeAccount]
    /// The config folder whose Claude login remote machines get. Nil for
    /// the default one.
    public var claudeMachineLoginDirectory: String?

    public init(
        projects: [Project] = [],
        globalView: GlobalViewSettings = GlobalViewSettings(),
        github: GitHubSettings = GitHubSettings(),
        notifications: NotificationSettings = NotificationSettings(),
        remote: RemoteSettings? = nil,
        remoteMode: RemoteMode = .ssh,
        boxd: BoxdSettings? = nil,
        sessionTimeout: SessionTimeoutSettings = SessionTimeoutSettings(),
        promptTemplate: String = "",
        githubIssuePromptTemplate: String = "#${number}: ${title}\n\n${body}",
        columnOrder: [KanbanCodeColumn] = KanbanCodeColumn.allCases,
        hasCompletedOnboarding: Bool = false,
        defaultAssistant: CodingAssistant? = nil,
        enabledAssistants: [CodingAssistant] = CodingAssistant.allCases,
        apiServices: [APIService] = [],
        defaultAPIServiceIds: [String: String] = [:],
        selfCompact: SelfCompactSettings = SelfCompactSettings(),
        subagents: SubagentSettings = SubagentSettings(),
        assistantCommands: [String: AssistantCommandTemplate] = [:],
        assistantRuntimes: [String: SessionRuntime] = [:],
        remoteControl: RemoteControlSettings = RemoteControlSettings(),
        peers: [PeerConfig] = [],
        claudeAccounts: [ClaudeAccount] = [],
        claudeMachineLoginDirectory: String? = nil
    ) {
        self.projects = projects
        self.globalView = globalView
        self.github = github
        self.notifications = notifications
        self.remote = remote
        self.remoteMode = remoteMode
        self.boxd = boxd
        self.sessionTimeout = sessionTimeout
        self.promptTemplate = promptTemplate
        self.githubIssuePromptTemplate = githubIssuePromptTemplate
        self.columnOrder = columnOrder
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.defaultAssistant = defaultAssistant
        self.enabledAssistants = enabledAssistants
        self.apiServices = apiServices
        self.defaultAPIServiceIds = defaultAPIServiceIds
        self.selfCompact = selfCompact
        self.subagents = subagents
        self.assistantCommands = assistantCommands
        self.assistantRuntimes = assistantRuntimes
        self.remoteControl = remoteControl
        self.peers = peers
        self.claudeAccounts = claudeAccounts
        self.claudeMachineLoginDirectory = claudeMachineLoginDirectory
    }

    private enum CodingKeys: String, CodingKey {
        case projects, globalView, github, notifications, remote, remoteMode, boxd, sessionTimeout
        case promptTemplate, githubIssuePromptTemplate, columnOrder, hasCompletedOnboarding, defaultAssistant
        case enabledAssistants
        case apiServices, defaultAPIServiceIds
        case selfCompact, subagents, assistantCommands, assistantRuntimes, remoteControl, peers
        case claudeAccounts, claudeMachineLoginDirectory
        case skill // backward-compat: old name for promptTemplate
    }

    // Backward-compatible decoding — new fields default gracefully.
    // IMPORTANT: every field is decoded independently via `try?`-style fallbacks
    // so a single bad value can never wipe out the whole settings object. A
    // real-world incident: a future version of the app wrote `codex` into
    // `enabledAssistants`, but the Swift enum only had claude/gemini — the
    // strict `[CodingAssistant]` decode threw, `BoardStore` caught it with
    // `try?`, and every project vanished from the UI on restart.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projects = (try? container.decodeIfPresent([Project].self, forKey: .projects)) ?? []
        globalView = (try? container.decodeIfPresent(GlobalViewSettings.self, forKey: .globalView)) ?? GlobalViewSettings()
        github = (try? container.decodeIfPresent(GitHubSettings.self, forKey: .github)) ?? GitHubSettings()
        notifications = (try? container.decodeIfPresent(NotificationSettings.self, forKey: .notifications)) ?? NotificationSettings()
        remote = try? container.decodeIfPresent(RemoteSettings.self, forKey: .remote)
        boxd = try? container.decodeIfPresent(BoxdSettings.self, forKey: .boxd)
        // A file written before the boxd mode existed has no `remoteMode`. It
        // keeps the mutagen mode when it carries a `remote` block, so an
        // existing remote setup is not switched under the user.
        if let mode = try? container.decodeIfPresent(RemoteMode.self, forKey: .remoteMode) {
            remoteMode = mode
        } else if boxd != nil {
            remoteMode = .boxd
        } else if remote != nil {
            remoteMode = .mutagen
        } else {
            remoteMode = .ssh
        }
        sessionTimeout = (try? container.decodeIfPresent(SessionTimeoutSettings.self, forKey: .sessionTimeout)) ?? SessionTimeoutSettings()
        // Backward-compat: try "promptTemplate" first, fall back to "skill"
        promptTemplate = (try? container.decodeIfPresent(String.self, forKey: .promptTemplate))
            ?? (try? container.decodeIfPresent(String.self, forKey: .skill)) ?? ""
        githubIssuePromptTemplate = (try? container.decodeIfPresent(String.self, forKey: .githubIssuePromptTemplate))
            ?? "#${number}: ${title}\n\n${body}"
        columnOrder = (try? container.decodeIfPresent([KanbanCodeColumn].self, forKey: .columnOrder)) ?? KanbanCodeColumn.allCases
        hasCompletedOnboarding = (try? container.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding)) ?? false
        defaultAssistant = try? container.decodeIfPresent(CodingAssistant.self, forKey: .defaultAssistant)
        // Assistants written by a newer version of the app (or a future CLI)
        // may include values this Swift enum doesn't know about. Decode loose
        // strings, then keep only the ones we recognize — future unknowns
        // round-trip as a no-op rather than nuking the whole config.
        if let rawAssistants = try? container.decodeIfPresent([String].self, forKey: .enabledAssistants) {
            let known = rawAssistants.compactMap(CodingAssistant.init(rawValue:))
            enabledAssistants = known.isEmpty ? CodingAssistant.allCases : known
        } else {
            enabledAssistants = CodingAssistant.allCases
        }
        apiServices = (try? container.decodeIfPresent([APIService].self, forKey: .apiServices)) ?? []
        defaultAPIServiceIds = (try? container.decodeIfPresent([String: String].self, forKey: .defaultAPIServiceIds)) ?? [:]
        selfCompact = (try? container.decodeIfPresent(SelfCompactSettings.self, forKey: .selfCompact)) ?? SelfCompactSettings()
        subagents = (try? container.decodeIfPresent(SubagentSettings.self, forKey: .subagents)) ?? SubagentSettings()
        assistantCommands = (try? container.decodeIfPresent([String: AssistantCommandTemplate].self, forKey: .assistantCommands)) ?? [:]
        if let raw = try? container.decodeIfPresent([String: String].self, forKey: .assistantRuntimes) {
            assistantRuntimes = raw.compactMapValues { SessionRuntime(stored: $0) }
        } else {
            assistantRuntimes = [:]
        }
        remoteControl = (try? container.decodeIfPresent(RemoteControlSettings.self, forKey: .remoteControl)) ?? RemoteControlSettings()
        peers = (try? container.decodeIfPresent([PeerConfig].self, forKey: .peers)) ?? []
        // One account that does not decode is dropped, not the others.
        let lossyAccounts = (try? container.decodeIfPresent([LossyClaudeAccount].self, forKey: .claudeAccounts)) ?? []
        claudeAccounts = lossyAccounts.compactMap(\.account)
        if claudeAccounts.count < lossyAccounts.count {
            KanbanCodeLog.warn("settings", "Dropped \(lossyAccounts.count - claudeAccounts.count) Claude account(s) without a configDirectory; the next save removes them")
        }
        claudeMachineLoginDirectory = (try? container.decodeIfPresent(String.self, forKey: .claudeMachineLoginDirectory))
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(projects, forKey: .projects)
        try container.encode(globalView, forKey: .globalView)
        try container.encode(github, forKey: .github)
        try container.encode(notifications, forKey: .notifications)
        try container.encodeIfPresent(remote, forKey: .remote)
        try container.encode(remoteMode, forKey: .remoteMode)
        try container.encodeIfPresent(boxd, forKey: .boxd)
        try container.encode(sessionTimeout, forKey: .sessionTimeout)
        try container.encode(promptTemplate, forKey: .promptTemplate)
        try container.encode(githubIssuePromptTemplate, forKey: .githubIssuePromptTemplate)
        try container.encode(columnOrder, forKey: .columnOrder)
        try container.encode(hasCompletedOnboarding, forKey: .hasCompletedOnboarding)
        try container.encodeIfPresent(defaultAssistant, forKey: .defaultAssistant)
        try container.encode(enabledAssistants, forKey: .enabledAssistants)
        try container.encode(apiServices, forKey: .apiServices)
        try container.encode(defaultAPIServiceIds, forKey: .defaultAPIServiceIds)
        try container.encode(selfCompact, forKey: .selfCompact)
        try container.encode(subagents, forKey: .subagents)
        try container.encode(assistantCommands, forKey: .assistantCommands)
        if !assistantRuntimes.isEmpty {
            try container.encode(assistantRuntimes.mapValues(\.rawValue), forKey: .assistantRuntimes)
        }
        try container.encode(remoteControl, forKey: .remoteControl)
        if !peers.isEmpty {
            try container.encode(peers, forKey: .peers)
        }
        if !claudeAccounts.isEmpty {
            try container.encode(claudeAccounts, forKey: .claudeAccounts)
        }
        try container.encodeIfPresent(claudeMachineLoginDirectory, forKey: .claudeMachineLoginDirectory)
        // Note: "skill" is NOT encoded — only read for backward-compat
    }

    /// The launch command template of an assistant, or nil when the user did
    /// not set one. A blank template and the bare placeholder both mean "run
    /// the command as it is built", so both read as nil.
    /// What runs the main session of a new or resumed card. Only Claude can
    /// run in rush.
    public func runtime(for assistant: CodingAssistant) -> SessionRuntime {
        guard assistant == .claude else { return .tmux }
        return assistantRuntimes[assistant.rawValue] ?? .tmux
    }

    public func commandTemplate(for assistant: CodingAssistant, remote: Bool) -> String? {
        guard let entry = assistantCommands[assistant.rawValue] else { return nil }
        let candidate = remote ? (entry.remote ?? entry.local) : entry.local
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != AssistantCommandTemplate.placeholder else { return nil }
        return trimmed
    }
}

/// An account entry that decodes to nil instead of failing the list.
private struct LossyClaudeAccount: Decodable {
    let account: ClaudeAccount?
    init(from decoder: Decoder) throws {
        account = try? ClaudeAccount(from: decoder)
    }
}

/// Backend used to run a card on another machine.
public enum RemoteMode: String, Codable, Sendable, CaseIterable {
    /// Cards run on always-on machines reached over ssh (`BoxdSettings.sshMachines`).
    case ssh
    /// Each card runs on its own boxd cloud machine.
    case boxd
    /// One SSH host with Mutagen file sync, the assistant runs on the Mac.
    case mutagen

    /// The card runs on a machine through the machine supervisor: an ssh
    /// machine or a boxd one. The mutagen mode runs it on this Mac.
    public var runsOnMachines: Bool { self != .mutagen }
}

/// Settings of the boxd remote mode.
public struct BoxdSettings: Codable, Sendable, Equatable {
    /// Snapshot every new machine is created from.
    public var snapshotName: String
    /// Machine the snapshot is saved from.
    public var sourceMachine: String
    /// Where the repository is checked out on the machine. `${repo_name}` is
    /// substituted and `~` expands to the home directory of the machine.
    public var folderTemplate: String
    /// Shell snippet that prepares the checkout on the machine.
    /// `${repo_dir}`, `${repo_url}`, `${repo_name}` and `${branch}` are substituted.
    public var initCommand: String
    /// Glob lines of local files copied into the machine after the init command.
    public var copyGlobs: [String]
    /// Seconds without activity before the machine is paused.
    public var inactivityTimeoutSeconds: Int
    /// Optional long-lived Claude token (`claude setup-token`) exported as
    /// `CLAUDE_CODE_OAUTH_TOKEN` in every session on a machine. Without it
    /// the machines get the login of this Mac, kept in sync while they run.
    public var claudeOAuthToken: String
    /// Always-on machines reached over ssh. Cards run on them the way they
    /// run on a boxd machine, several cards on one machine.
    public var sshMachines: [SshMachine]

    public static let defaultSnapshotName = "kanban-code-base"
    public static let defaultSourceMachine = "good-wolf"
    public static let defaultFolderTemplate = "~/${repo_name}"
    public static let defaultCopyGlobs = ["**/.env"]
    public static let defaultInactivityTimeoutSeconds = 1800
    /// Shortest timeout the app accepts. A smaller value pauses a machine
    /// while it is still starting up.
    public static let minimumInactivityTimeoutSeconds = 60

    public static let defaultInitCommand = """
    if [ -d "${repo_dir}" ]; then
      cd "${repo_dir}" || exit 1
      git pull --ff-only || {
        git stash push --include-untracked --message "kanban-code init $(date -u +%Y-%m-%dT%H:%M:%SZ)" || exit 1
        git pull --ff-only
      }
    else
      git clone "${repo_url}" "${repo_dir}"
    fi
    """

    /// Init commands shipped by earlier versions. A stored command that still
    /// matches one of them is replaced by the current default, so a checkout
    /// with changed files does not block every launch.
    static let supersededInitCommands = [
        """
        if [ -d "${repo_dir}" ]; then
          cd "${repo_dir}" && git pull --ff-only
        else
          git clone "${repo_url}" "${repo_dir}" && cd "${repo_dir}"
        fi
        """
    ]

    public init(
        snapshotName: String = BoxdSettings.defaultSnapshotName,
        sourceMachine: String = BoxdSettings.defaultSourceMachine,
        folderTemplate: String = BoxdSettings.defaultFolderTemplate,
        initCommand: String = BoxdSettings.defaultInitCommand,
        copyGlobs: [String] = BoxdSettings.defaultCopyGlobs,
        inactivityTimeoutSeconds: Int = BoxdSettings.defaultInactivityTimeoutSeconds,
        claudeOAuthToken: String = "",
        sshMachines: [SshMachine] = []
    ) {
        self.snapshotName = snapshotName
        self.sourceMachine = sourceMachine
        self.folderTemplate = folderTemplate
        self.initCommand = initCommand
        self.copyGlobs = copyGlobs
        self.inactivityTimeoutSeconds = max(Self.minimumInactivityTimeoutSeconds, inactivityTimeoutSeconds)
        self.claudeOAuthToken = claudeOAuthToken
        self.sshMachines = sshMachines
    }

    // Per-field `try?` decoding, same rule as `Settings`: one bad value must
    // never drop the whole boxd configuration.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        snapshotName = (try? c.decodeIfPresent(String.self, forKey: .snapshotName)) ?? Self.defaultSnapshotName
        sourceMachine = (try? c.decodeIfPresent(String.self, forKey: .sourceMachine)) ?? Self.defaultSourceMachine
        folderTemplate = (try? c.decodeIfPresent(String.self, forKey: .folderTemplate)) ?? Self.defaultFolderTemplate
        let storedInit = (try? c.decodeIfPresent(String.self, forKey: .initCommand)) ?? Self.defaultInitCommand
        initCommand = Self.supersededInitCommands.contains(storedInit) ? Self.defaultInitCommand : storedInit
        copyGlobs = (try? c.decodeIfPresent([String].self, forKey: .copyGlobs)) ?? Self.defaultCopyGlobs
        let seconds = (try? c.decodeIfPresent(Int.self, forKey: .inactivityTimeoutSeconds)) ?? Self.defaultInactivityTimeoutSeconds
        inactivityTimeoutSeconds = max(Self.minimumInactivityTimeoutSeconds, seconds)
        claudeOAuthToken = (try? c.decodeIfPresent(String.self, forKey: .claudeOAuthToken)) ?? ""
        sshMachines = (try? c.decodeIfPresent([SshMachine].self, forKey: .sshMachines)) ?? []
    }

    /// The ssh machine of that name, when there is one.
    public func sshMachine(named name: String) -> SshMachine? {
        sshMachines.first { $0.name == name && $0.isComplete }
    }

    private enum CodingKeys: String, CodingKey {
        case snapshotName, sourceMachine, folderTemplate, initCommand, copyGlobs, inactivityTimeoutSeconds
        case claudeOAuthToken, sshMachines
    }
}

/// Launch command template of one assistant. `${cli_command}` stands for the
/// command Kanban Code builds; `remote` is used when the card runs on a remote
/// machine and falls back to `local` when it is nil.
public struct AssistantCommandTemplate: Codable, Sendable, Equatable {
    public static let placeholder = "${cli_command}"

    public var local: String
    public var remote: String?

    public init(local: String = AssistantCommandTemplate.placeholder, remote: String? = nil) {
        self.local = local
        self.remote = remote
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        local = (try? c.decodeIfPresent(String.self, forKey: .local)) ?? Self.placeholder
        remote = try? c.decodeIfPresent(String.self, forKey: .remote)
    }

    private enum CodingKeys: String, CodingKey {
        case local, remote
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

/// Whether attention requests go to the phone through Pushover.
public enum PushoverMode: String, Codable, Sendable, CaseIterable {
    case disabled
    case enabled

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        // "whenLidClosed" was a mode before the presence policy; the policy
        // now decides when the phone alerts.
        self = raw == PushoverMode.disabled.rawValue ? .disabled : .enabled
    }
}

/// Settings > Notifications: how decisions agents wait on reach Rogerio.
public struct NotificationSettings: Codable, Sendable, Equatable {
    /// Notify on the Mac when a request is raised and he is not looking at it.
    public var macNotifications: Bool
    /// Phone delivery through Pushover.
    public var pushoverMode: PushoverMode
    public var pushoverToken: String?
    public var pushoverUserKey: String?
    /// The phone alerts when a request is still open after this long.
    public var phoneAlertDelaySeconds: Int
    /// The Mac counts as away after this long without keyboard or mouse input.
    public var awayAfterSeconds: Int

    public static let defaultPhoneAlertDelaySeconds = 180
    public static let defaultAwayAfterSeconds = 120

    public var pushoverEnabled: Bool { pushoverMode != .disabled }

    public init(
        macNotifications: Bool = true, pushoverMode: PushoverMode = .disabled, pushoverToken: String? = nil,
        pushoverUserKey: String? = nil, phoneAlertDelaySeconds: Int = NotificationSettings.defaultPhoneAlertDelaySeconds,
        awayAfterSeconds: Int = NotificationSettings.defaultAwayAfterSeconds
    ) {
        self.macNotifications = macNotifications
        self.pushoverMode = pushoverMode
        self.pushoverToken = pushoverToken
        self.pushoverUserKey = pushoverUserKey
        self.phoneAlertDelaySeconds = phoneAlertDelaySeconds
        self.awayAfterSeconds = awayAfterSeconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let mode = try c.decodeIfPresent(PushoverMode.self, forKey: .pushoverMode) {
            pushoverMode = mode
        } else {
            let legacy = try c.decodeIfPresent(Bool.self, forKey: .pushoverEnabled) ?? false
            pushoverMode = legacy ? .enabled : .disabled
        }
        macNotifications = try c.decodeIfPresent(Bool.self, forKey: .macNotifications) ?? true
        pushoverToken = try c.decodeIfPresent(String.self, forKey: .pushoverToken)
        pushoverUserKey = try c.decodeIfPresent(String.self, forKey: .pushoverUserKey)
        phoneAlertDelaySeconds = try c.decodeIfPresent(Int.self, forKey: .phoneAlertDelaySeconds) ?? Self.defaultPhoneAlertDelaySeconds
        awayAfterSeconds = try c.decodeIfPresent(Int.self, forKey: .awayAfterSeconds) ?? Self.defaultAwayAfterSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case macNotifications, pushoverMode, pushoverEnabled, pushoverToken, pushoverUserKey
        case phoneAlertDelaySeconds, awayAfterSeconds
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(macNotifications, forKey: .macNotifications)
        try c.encode(pushoverMode, forKey: .pushoverMode)
        try c.encodeIfPresent(pushoverToken, forKey: .pushoverToken)
        try c.encodeIfPresent(pushoverUserKey, forKey: .pushoverUserKey)
        try c.encode(phoneAlertDelaySeconds, forKey: .phoneAlertDelaySeconds)
        try c.encode(awayAfterSeconds, forKey: .awayAfterSeconds)
    }

    /// The phone channel these settings configure, or nil when off.
    public var phoneSender: (any PhonePushSender)? {
        guard pushoverMode != .disabled, let token = pushoverToken, let user = pushoverUserKey,
              !token.isEmpty, !user.isEmpty else { return nil }
        return PushoverAttentionSender(token: token, userKey: user)
    }

    /// The escalation policy these settings describe.
    public var attentionPolicy: AttentionPolicySettings {
        AttentionPolicySettings(
            macNotifications: macNotifications, phoneEnabled: phoneSender != nil,
            phoneAlertDelay: TimeInterval(max(0, phoneAlertDelaySeconds)),
            idleThreshold: TimeInterval(max(30, awayAfterSeconds)))
    }
}

public struct RemoteSettings: Codable, Sendable, Equatable {
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

public struct SubagentSettings: Codable, Sendable, Equatable {
    public static let maximumSupportedDepth = 5

    public var maximumDepth: Int {
        didSet {
            maximumDepth = min(Self.maximumSupportedDepth, max(0, maximumDepth))
        }
    }

    public init(maximumDepth: Int = 1) {
        self.maximumDepth = min(Self.maximumSupportedDepth, max(0, maximumDepth))
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maximumDepth = min(
            Self.maximumSupportedDepth,
            max(0, try c.decodeIfPresent(Int.self, forKey: .maximumDepth) ?? 1)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case maximumDepth
    }
}

/// Reads and writes ~/.kanban-code/settings.json.
/// Caches settings in memory and only re-reads from disk when mtime changes.
public actor SettingsStore {
    private let filePath: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var cachedSettings: Settings?
    private var cachedMtime: Date?

    public init(basePath: String? = nil) {
        let base = basePath ?? (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code")
        self.filePath = (base as NSString).appendingPathComponent("settings.json")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        self.decoder = JSONDecoder()
    }

    /// Invalidate the in-memory cache so the next read() re-reads from disk.
    public func invalidateCache() {
        cachedSettings = nil
        cachedMtime = nil
    }

    /// Read settings, creating defaults if file doesn't exist.
    /// Returns cached value if the file hasn't changed since last read.
    public func read() throws -> Settings {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: filePath) else {
            let defaults = Settings()
            try write(defaults)
            return defaults
        }

        // Check mtime — return cached if unchanged
        let attrs = try? fileManager.attributesOfItem(atPath: filePath)
        let mtime = attrs?[.modificationDate] as? Date
        if let cached = cachedSettings, let cachedMtime, mtime == cachedMtime {
            return cached
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
        let settings = try decoder.decode(Settings.self, from: data)
        cachedSettings = settings
        cachedMtime = mtime
        publishClaudeAccounts(settings)
        return settings
    }

    /// Write settings atomically.
    public func write(_ settings: Settings) throws {
        let fileManager = FileManager.default
        let dir = (filePath as NSString).deletingLastPathComponent
        try fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // .atomic renames a temp file over the old one, so a reader never
        // finds the file missing and mistakes that for a first run.
        let data = try encoder.encode(settings)
        try data.write(to: URL(fileURLWithPath: filePath), options: .atomic)

        // Update cache with the just-written value
        cachedSettings = settings
        cachedMtime = (try? fileManager.attributesOfItem(atPath: filePath))?[.modificationDate] as? Date
        publishClaudeAccounts(settings)
    }

    /// The Claude config folders follow the settings file the process
    /// bootstrapped them from (`ClaudeConfigDirectories.bootstrap`), whatever
    /// store reads it; other files (a test's) leave them alone.
    private func publishClaudeAccounts(_ settings: Settings) {
        ClaudeConfigDirectories.settingsChanged(settings, at: filePath)
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
