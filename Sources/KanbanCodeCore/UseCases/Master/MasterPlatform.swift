import Foundation

/// Which boxd machine a launch or resume goes to.
public enum BoxdMachineChoice: Equatable, Hashable, Sendable {
    /// A new machine from the configured snapshot.
    case newMachine
    /// A machine that already exists, by name.
    case existing(String)

    public var machineName: String? {
        if case .existing(let name) = self { return name }
        return nil
    }
}

/// What a remote `POST /v1/tasks` asks a master to create and launch.
public struct RemoteLaunchRequest: Sendable, Equatable {
    public var projectPath: String
    public var prompt: String
    public var title: String?
    /// A worktree name, "" for a random one, nil for the project checkout.
    public var worktree: String?
    public var assistant: CodingAssistant
    public var model: String?
    public var launch: Bool
    /// Image files for the first prompt, already written.
    public var imagePaths: [String]
    /// "mac", a machine name, or nil for the project default.
    public var machine: String?
    /// The human typed the prompt himself.
    public var human: Bool

    public init(projectPath: String, prompt: String, title: String? = nil, worktree: String? = nil,
                assistant: CodingAssistant = .claude, model: String? = nil, launch: Bool = true,
                imagePaths: [String] = [], machine: String? = nil, human: Bool = false) {
        self.projectPath = projectPath
        self.prompt = prompt
        self.title = title
        self.worktree = worktree
        self.assistant = assistant
        self.model = model
        self.launch = launch
        self.imagePaths = imagePaths
        self.machine = machine
        self.human = human
    }
}

/// What the master engine asks of the platform it runs on. The Mac app
/// fills it with its clipboard, its remote terminals and the defaults of its
/// launch dialogs; a headless master keeps the defaults: sessions run here,
/// on tmux or rush, with no clipboard.
public struct MasterPlatform: Sendable {
    /// Puts a PNG on the clipboard, for assistants that take images by paste.
    public var setClipboardImage: (@Sendable (Data) -> Void)?

    /// Remote session readiness, for the terminals that attach to sessions
    /// on boxd and ssh machines.
    public var expectRemoteSession: @Sendable (String) -> Void = { _ in }
    public var clearRemoteSessionReady: @Sendable (String) -> Void = { _ in }
    public var markRemoteSessionReady: @Sendable (_ session: String, _ machine: String?) -> Void = { _, _ in }
    /// Routes a session name back to the local tmux server.
    public var unassignRemoteSession: @Sendable (String) -> Void = { _ in }
    /// Machine that hosts a tmux session, when it is remote.
    public var machineForSession: @Sendable (String) -> String? = { _ in nil }

    /// Where a remote API launch runs: "mac", a machine name, or nil for the
    /// defaults of the project. Returns whether it runs remotely and on
    /// which machine.
    public var remoteMachineChoice: @MainActor @Sendable (_ machine: String?, _ projectPath: String) -> (runRemotely: Bool, machine: BoxdMachineChoice?) = { _, _ in (false, nil) }
    /// The assistant a remote task uses when the request names none.
    public var defaultAssistant: @MainActor @Sendable () -> CodingAssistant = { .claude }
    /// The "Skip permissions" choice for launches the remote API starts.
    public var skipPermissions: @MainActor @Sendable () -> Bool = { true }
    /// The command a remote terminal viewer runs for a session, when the
    /// platform has its own; nil for `rush open <id>` or
    /// `tmux attach`.
    public var terminalCommand: @MainActor @Sendable (String) -> [String]? = { _ in nil }
    /// The command that shows a terminal of a card another master owns
    /// (owner machine id, card id, session name); nil when there is none.
    public var peerTerminalCommand: @MainActor @Sendable (String, String, String) -> [String]? = { _, _, _ in nil }
    /// Re-scans a card this master owns for pushed branches and pull
    /// requests, and puts what it found on the card.
    public var discoverBranches: @MainActor @Sendable (String) async -> Void = { _ in }

    /// Where repositories are cloned when a card from a peer needs one this
    /// master does not have yet.
    public var projectsDirectory: String = (NSHomeDirectory() as NSString).appendingPathComponent("Projects")
    /// Whether a missing repository is cloned (a headless master) or the
    /// adoption stops and asks for the project (the Mac).
    public var clonesMissingProjects = true

    /// Environment every session this master starts gets (a root host sets
    /// `IS_SANDBOX=1` so Claude accepts skipped permissions).
    public var sessionEnvironment: [String: String] = [:]

    /// This master's kanban home: links.json, settings.json, the command inbox.
    public var kanbanHome: String = (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code")

    /// The bundled `kanban` CLI (`dist/kanban.js`) and the node that runs it,
    /// for commands other masters hand to this one (`POST /v1/cli`).
    public var cliScript: String?
    public var nodePath: String?

    /// Claude's projects directory, where transcripts live by working directory.
    public var claudeProjectsDirectory: String = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects")

    /// The Claude config folders (Settings > Claude accounts) launches and
    /// resumes pick from.
    public var claudeLayout: @Sendable () -> ClaudeConfigLayout = { ClaudeConfigDirectories.current }

    /// Tokens of the GitHub logins the accounts name.
    public var gitHubTokens: GitHubAccountTokens = .shared

    /// The shell a card's tmux pane runs: tmux's `default-shell` (a
    /// tmux.conf may name another than the login shell), else `SHELL`.
    public var paneShell: @Sendable () async -> String? = {
        if let tmux = ShellCommand.findExecutable("tmux"),
           let result = try? await ShellCommand.run(tmux, arguments: ["show-options", "-gv", "default-shell"], timeout: 5),
           result.succeeded {
            let shell = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !shell.isEmpty { return shell }
        }
        return ShellCommand.loginEnvironment["SHELL"] ?? ProcessInfo.processInfo.environment["SHELL"]
    }

    public init() {}
}
