import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Everything a launch or resume needs after a machine is ready.
public struct BoxdPreparation: Sendable {
    public let machineName: String
    public let remoteHome: String
    /// Repository root on the machine.
    public let remoteProjectPath: String
    /// Directory the assistant starts in: the repository or its worktree.
    public let remoteCwd: String
    /// Local worktree created for a worktree launch, when there is one.
    public let worktree: WorktreeLink?
    /// Environment of the assistant process on the machine.
    public let extraEnv: [String: String]
    public let remoteLink: RemoteLink

    public init(machineName: String, remoteHome: String, remoteProjectPath: String, remoteCwd: String, worktree: WorktreeLink?, extraEnv: [String: String], remoteLink: RemoteLink) {
        self.machineName = machineName
        self.remoteHome = remoteHome
        self.remoteProjectPath = remoteProjectPath
        self.remoteCwd = remoteCwd
        self.worktree = worktree
        self.extraEnv = extraEnv
        self.remoteLink = remoteLink
    }
}

/// A `kanban` command from the machine, resolved to what runs on the Mac.
public struct BoxdProxyInvocation: Sendable {
    public let request: BridgeProxyRequest
    public let cardId: String?
    /// Working directory on the Mac, mapped from the machine.
    public let cwd: String?
    /// Local paths of the images the request carried.
    public let imagePaths: [String]
}

public enum BoxdSupervisorError: Error, LocalizedError, Equatable {
    case machineDestroyed(String)
    case bootstrapFailed(String)
    case initFailed(String)
    case notConnected(String)
    case noCliBundle

    public var errorDescription: String? {
        switch self {
        case .machineDestroyed(let name): "Machine \(name) no longer exists"
        case .bootstrapFailed(let message): "Could not install the kanban CLI on the machine: \(message)"
        case .initFailed(let message): "The initialization command failed: \(message)"
        case .notConnected(let name): "Machine \(name) is not connected"
        case .noCliBundle: "The kanban CLI bundle was not found in the app"
        }
    }
}

/// Runs the boxd machines behind remote cards: creates and bootstraps them,
/// keeps one bridge per running machine, mirrors their files, pauses them
/// when work stops and answers the `kanban` commands their assistants run.
public actor BoxdMachineSupervisor: RemoteMachineControl {
    public typealias Dispatch = @MainActor @Sendable (Action) -> Void
    /// Runs a proxied `kanban` command on the Mac and returns its result.
    public typealias ProxyRunner = @Sendable (BoxdProxyInvocation) async -> ShellCommand.Result
    /// True while a card on the machine is actively working.
    public typealias BusyCheck = @Sendable (String) async -> Bool

    public static let subsystem = "boxd"
    public static let defaultRemoteHome = "/home/boxd"
    /// Node on a boxd machine.
    public static let defaultNodePath = "/usr/local/bin/node"

    private struct MachineRuntime {
        var bridge: BoxdBridge?
        var mirror: BoxdMirror
        var eventTask: Task<Void, Never>?
        var keepaliveTask: Task<Void, Never>?
        var lastActivity: Date
        var pausedReason: RemotePausedReason?
        var remoteHome: String
        var localProjectPath: String
        var remoteProjectPath: String
        /// Other checkouts on the machine, remote to local. A shared ssh
        /// machine runs cards of several projects over one bridge.
        var otherProjects: [PathMapping] = []
        var reconnectAttempts = 0
        /// True from the moment a person brought the machine back until the
        /// first work arrives on it. A peek that ends with nothing done
        /// pauses the machine again at once.
        var resumedForPeek = false
        /// True once `boxd machine stop` succeeded for the current paused
        /// spell. The idle sweep keeps the original paused reason for the
        /// UI, so this flag is what stops it from issuing a new stop on
        /// every tick.
        var machineHalted = false
    }

    private let boxd: any BoxdPort
    public let registry: RemoteSessionRegistry
    private let settingsProvider: @Sendable () async -> BoxdSettings
    private let cliBundlePath: String?
    private let appVersion: String
    private let localHome: String
    private let localKanbanHome: String
    private let loginStore: any LocalLoginStore
    private let loginAccounts: any LoginAccountMemory
    /// Current links of the board, read when a sweep decides what a machine is for.
    public typealias LinksProvider = @Sendable () async -> [Link]

    private var dispatch: Dispatch?
    private var proxyRunner: ProxyRunner?
    private var busyCheck: BusyCheck?
    private var linksProvider: LinksProvider?
    private var machines: [String: MachineRuntime] = [:]
    /// Machines a card left focus for while their resume was still running.
    private var peekPauseRequested: Set<String> = []
    private var inactivityTask: Task<Void, Never>?
    private var timerTicks = 0
    /// `accountUuid` of the Claude login seen on the last tick. A token
    /// rotation keeps it; an account switch changes it.
    private var lastClaudeAccountId: String?
    /// Minutes between two sweeps of the machine list.
    public static let sweepIntervalMinutes = 10
    private let now: @Sendable () -> Date

    public init(
        boxd: any BoxdPort,
        registry: RemoteSessionRegistry,
        settingsProvider: @escaping @Sendable () async -> BoxdSettings,
        cliBundlePath: String?,
        appVersion: String,
        localHome: String = NSHomeDirectory(),
        localKanbanHome: String? = nil,
        loginStore: any LocalLoginStore = MacLoginStore(),
        loginAccounts: any LoginAccountMemory = FileLoginAccountMemory.inKanbanHome(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.boxd = boxd
        self.registry = registry
        self.settingsProvider = settingsProvider
        self.cliBundlePath = cliBundlePath
        self.appVersion = appVersion
        self.localHome = localHome
        self.localKanbanHome = localKanbanHome ?? "\(localHome)/.kanban-code"
        self.loginStore = loginStore
        self.loginAccounts = loginAccounts
        self.now = now
    }

    public func setDispatch(_ dispatch: @escaping Dispatch) {
        self.dispatch = dispatch
    }

    public func setProxyRunner(_ runner: @escaping ProxyRunner) {
        self.proxyRunner = runner
    }

    public func setBusyCheck(_ check: @escaping BusyCheck) {
        self.busyCheck = check
    }

    public func setLinksProvider(_ provider: @escaping LinksProvider) {
        self.linksProvider = provider
    }

    // MARK: - Queries

    public func isConnected(_ machineName: String) -> Bool {
        registry.state(of: machineName)?.isConnected == true
    }

    public func bridge(for machineName: String) -> BoxdBridge? {
        machines[machineName]?.bridge
    }

    public func mirror(for machineName: String) -> BoxdMirror? {
        machines[machineName]?.mirror
    }

    public func lastActivity(of machineName: String) -> Date? {
        machines[machineName]?.lastActivity
    }

    /// True for an always-on ssh machine, which the app never stops.
    public func isHost(_ machineName: String) async -> Bool {
        await boxd.hostProfile(name: machineName) != nil
    }

    /// A card leaves its machine to continue on the Mac. A boxd machine is
    /// stopped with the session on it. An ssh machine keeps running for its
    /// other cards, so the sessions of this card are killed there, and the
    /// last lines of the transcript are given a few seconds to reach the
    /// mirror. The tmux names route locally afterwards either way.
    public func leave(
        machineName: String,
        sessionNames: [String],
        localTranscript: String?,
        remoteCwd: String?,
        settle: Duration = .seconds(10)
    ) async {
        guard await isHost(machineName) else {
            releaseSessions(sessionNames)
            if isConnected(machineName) {
                await stop(machineName: machineName, reason: .manual)
            }
            return
        }
        if let bridge = machines[machineName]?.bridge {
            for name in sessionNames {
                if let id = RushSessionName.rushId(fromName: name) {
                    try? await registry.rush(for: machineName)?.stop(id: id)
                } else {
                    _ = try? await bridge.exec(["tmux", "kill-session", "-t", name], stdin: nil, cwd: nil, timeout: 20)
                }
                registry.forgetSession(name, on: machineName)
            }
            if let localTranscript, let remoteCwd {
                let deadline = ContinuousClock.now + settle
                while ContinuousClock.now < deadline {
                    let remote = await remoteTranscriptLines(machineName: machineName, localPath: localTranscript, remoteCwd: remoteCwd)
                    let local = BoxdLaunchPlanner.lineCount(ofFileAt: localTranscript)
                    if remote <= local { break }
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            KanbanCodeLog.info(Self.subsystem, "\(machineName): \(sessionNames.joined(separator: ", ")) left for the Mac")
        }
        releaseSessions(sessionNames)
    }

    /// What the machine records as the installed CLI: the app version and a
    /// digest of the bundle. The version alone does not move between two
    /// builds of the same version, so a fix in the CLI would never reach a
    /// machine that already has one.
    public nonisolated static func bundleStamp(appVersion: String, cliBundlePath: String) -> String {
        let distPath = (cliBundlePath as NSString).appendingPathComponent("dist")
        let manager = FileManager.default
        var hasher = SHA256()
        let files = (manager.enumerator(atPath: distPath)?.allObjects as? [String] ?? []).sorted()
        for file in files where file.hasSuffix(".js") {
            let full = (distPath as NSString).appendingPathComponent(file)
            guard let data = manager.contents(atPath: full) else { continue }
            hasher.update(data: Data(file.utf8))
            hasher.update(data: data)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined().prefix(12)
        return "\(appVersion)-\(digest)"
    }

    /// Command the embedded terminal runs to attach to a remote tmux session.
    public nonisolated static func attachCommand(boxdPath: String, machineName: String, sessionName: String) -> String {
        "\(shellEscape(boxdPath)) machine exec --tty \(shellEscape(machineName)) -- tmux attach -t \(shellEscape(sessionName))"
    }

    // MARK: - Startup

    /// Re-seeds the registry from persisted links and reconnects the
    /// machines that are running. Paused machines stay paused, with their
    /// markers written so the terminal waits for a resume instead of
    /// waking them.
    public func restore(links: [Link]) async {
        defer { startInactivityTimer() }
        registry.seed(from: links)
        var seen: Set<String> = []
        for link in links {
            guard let remote = link.remote, remote.mode == .boxd else { continue }
            let projectPath = link.projectPath ?? localHome
            if seen.contains(remote.machineName) {
                if await isHost(remote.machineName) {
                    await addProject(
                        machineName: remote.machineName,
                        localProjectPath: Self.repositoryRoot(of: projectPath),
                        remoteProjectPath: remote.remoteProjectPath)
                }
                continue
            }
            seen.insert(remote.machineName)
            do {
                let machine = try await boxd.getMachine(name: remote.machineName)
                switch machine.status {
                case .running, .booting:
                    try await connect(
                        machineName: remote.machineName,
                        localProjectPath: projectPath,
                        remoteProjectPath: remote.remoteProjectPath,
                        remoteHome: remote.remoteHome ?? Self.defaultRemoteHome
                    )
                case .destroyed:
                    await report(remote.machineName, state: .destroyed)
                default:
                    let reason = remote.pausedReason ?? .manual
                    machines[remote.machineName] = makeRuntime(
                        machineName: remote.machineName,
                        localProjectPath: projectPath,
                        remoteProjectPath: remote.remoteProjectPath,
                        remoteHome: remote.remoteHome ?? Self.defaultRemoteHome,
                        pausedReason: reason
                    )
                    // A machine already off disk-only billing must not be
                    // stopped again by the sweep or the sleep hook.
                    machines[remote.machineName]?.machineHalted = machine.status == .stopped
                    setPausedMarkers(machineName: remote.machineName, paused: true)
                    await report(remote.machineName, state: .paused(reason))
                }
            } catch {
                KanbanCodeLog.warn(Self.subsystem, "restore \(remote.machineName): \(error.localizedDescription)")
                if remote.pausedReason == nil {
                    // Nothing paused this machine, so it is running as far as
                    // anyone knows: keep trying to reach it, as after a lost
                    // bridge, instead of waiting for a click.
                    machines[remote.machineName] = makeRuntime(
                        machineName: remote.machineName,
                        localProjectPath: projectPath,
                        remoteProjectPath: remote.remoteProjectPath,
                        remoteHome: remote.remoteHome ?? Self.defaultRemoteHome
                    )
                    registry.disconnectMachine(remote.machineName, state: .reconnecting(attempt: 1))
                    await report(remote.machineName, state: .reconnecting(attempt: 1))
                    Task { [weak self] in await self?.reconnect(machineName: remote.machineName) }
                } else {
                    await report(remote.machineName, state: .unreachable)
                }
            }
        }
        startInactivityTimer()
    }

    // MARK: - Prepare a launch or a resume

    /// Brings a machine up for a card and prepares the checkout on it.
    ///
    /// - `existingMachine`: the machine the card already has, or another
    ///   machine the user picked. Nil creates a new machine from the snapshot.
    /// - `worktreeName`: the worktree to create locally and on the machine.
    ///   An empty name asks for a random one, as `claude --worktree` does.
    /// - `sessionNames`: tmux names the card will use, registered as remote
    ///   before anything runs.
    public func prepare(
        cardId: String,
        localProjectPath: String,
        existingMachine: String?,
        worktreeName: String?,
        existingWorktree: WorktreeLink?,
        sessionNames: [String],
        runInit: Bool = true,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> BoxdPreparation {
        let settings = await settingsProvider()
        let repoRoot = Self.repositoryRoot(of: localProjectPath)
        let originURL = await Self.originURL(of: repoRoot)
        let repoName = BoxdLaunchPlanner.repoName(fromOriginURL: originURL, fallbackFolder: (repoRoot as NSString).lastPathComponent)
        let machineName = existingMachine ?? BoxdLaunchPlanner.machineName(repoName: repoName, cardId: cardId)
        let host = await boxd.hostProfile(name: machineName)
        let remoteHome = machines[machineName]?.remoteHome ?? host?.remoteHome ?? Self.defaultRemoteHome
        let remoteProjectPath = BoxdLaunchPlanner.remoteProjectPath(
            folderTemplate: host?.folderTemplate ?? settings.folderTemplate, repoName: repoName, remoteHome: remoteHome)

        let previousState = registry.state(of: machineName)
        let newNames = sessionNames.filter { registry.machine(forSession: $0) != machineName }
        for name in sessionNames { registry.assign(sessionName: name, to: machineName) }
        // A machine whose bridge is open stays connected: connect() returns
        // at once and would leave a `.connecting` report in the registry,
        // where it blocks every tmux command.
        if machines[machineName]?.bridge == nil {
            await report(machineName, state: .connecting)
        }

        log("Preparing machine \(machineName)")
        let machine: BoxdMachine
        do {
            machine = try await ensureRunning(machineName: machineName, settings: settings, log: log)
        } catch {
            await abandonStart(
                machineName: machineName, previousState: previousState, newSessionNames: newNames)
            throw error
        }
        do {
            try await connect(
                machineName: machineName,
                localProjectPath: repoRoot,
                remoteProjectPath: remoteProjectPath,
                remoteHome: remoteHome,
                log: log
            )
        } catch {
            // The machine is up but the CLI or the bridge did not make it:
            // it must not sit running with nothing on it. Its disk stays, so
            // a retry starts it again.
            log("Preparation failed, stopping \(machineName)")
            await stop(machineName: machineName, reason: .sessionStopped)
            throw error
        }
        guard let bridge = machines[machineName]?.bridge else { throw BoxdSupervisorError.notConnected(machineName) }

        // The card remembers its machine from here on, so a failed step
        // further down still leaves a machine to pause, retry or destroy.
        await dispatch?(.remoteMachineAssigned(cardId: cardId, remote: RemoteLink(
            mode: .boxd,
            machineName: machineName,
            machineId: machine.id,
            remoteProjectPath: remoteProjectPath,
            remoteCwd: remoteProjectPath,
            remoteHome: remoteHome,
            lastStatus: "running"
        )))

        do {
            return try await prepareCheckout(
                cardId: cardId, machine: machine, machineName: machineName, bridge: bridge,
                settings: settings, repoRoot: repoRoot, originURL: originURL, repoName: repoName,
                remoteHome: remoteHome, remoteProjectPath: remoteProjectPath,
                worktreeName: worktreeName, existingWorktree: existingWorktree, runInit: runInit, log: log)
        } catch {
            // A card with no session must not keep a running machine. The
            // machine keeps its disk, so a retry starts it again.
            log("Preparation failed, stopping \(machineName)")
            await stop(machineName: machineName, reason: .sessionStopped)
            throw error
        }
    }

    /// Undoes what `prepare` recorded before the machine was up, when it
    /// could not be started or created (out of credits, offline). A machine
    /// the app did not know before this call is forgotten with its session
    /// names; a known one goes back to the state it had. Left as it was, the
    /// machine would stay "connecting" and every tmux command of its
    /// sessions, local resumes included, would be refused.
    private func abandonStart(machineName: String, previousState: RemoteMachineState?, newSessionNames: [String]) async {
        guard machines[machineName]?.bridge == nil else { return }
        guard let previousState, previousState != .connecting else {
            machines[machineName] = nil
            await report(machineName, state: .destroyed)
            registry.removeMachine(machineName)
            return
        }
        for name in newSessionNames { registry.unassign(sessionName: name) }
        await report(machineName, state: previousState)
    }

    private func prepareCheckout(
        cardId: String,
        machine: BoxdMachine,
        machineName: String,
        bridge: BoxdBridge,
        settings: BoxdSettings,
        repoRoot: String,
        originURL: String?,
        repoName: String,
        remoteHome: String,
        remoteProjectPath: String,
        worktreeName: String?,
        existingWorktree: WorktreeLink?,
        runInit: Bool,
        log: @escaping @Sendable (String) -> Void
    ) async throws -> BoxdPreparation {
        // A new worktree lives on the machine only. The link keeps the
        // local path it would have, so the card shows its branch and a local
        // resume knows where to create it. A worktree the card already has
        // is checked out from origin, where its branch was pushed.
        var worktree = existingWorktree
        var branch = existingWorktree?.branch
        var worktreeIsNew = false
        if let requested = worktreeName, worktree == nil {
            let name = requested.trimmingCharacters(in: .whitespacesAndNewlines)
            let worktreeName = name.isEmpty ? BoxdLaunchPlanner.randomWorktreeName() : name
            worktree = WorktreeLink(path: "\(repoRoot)/.claude/worktrees/\(worktreeName)", branch: worktreeName)
            branch = worktreeName
            worktreeIsNew = true
        }

        if runInit {
            log("Running the initialization command")
            let localBranch = await Self.currentBranch(of: repoRoot)
            let script = BoxdLaunchPlanner.initScript(
                template: settings.initCommand,
                repoDir: remoteProjectPath,
                repoURL: originURL ?? "",
                repoName: repoName,
                branch: branch ?? localBranch ?? "main"
            )
            let result = try await bridge.exec(["bash", "-lc", script], stdin: nil, cwd: remoteHome, timeout: 900)
            if !result.stdout.isEmpty { log(result.stdout.trimmingCharacters(in: .newlines)) }
            if !result.succeeded {
                throw BoxdSupervisorError.initFailed(Self.failureMessage(of: result))
            }
        }

        var remoteCwd = remoteProjectPath
        if let worktree, let branch = worktree.branch {
            let remoteWorktree = "\(remoteProjectPath)/.claude/worktrees/\((worktree.path as NSString).lastPathComponent)"
            log(worktreeIsNew ? "Creating worktree \(branch) on the machine" : "Checking out \(branch) on the machine")
            let script = Self.remoteWorktreeScript(
                repo: remoteProjectPath, worktreePath: remoteWorktree, branch: branch, fetch: !worktreeIsNew)
            let result = try await bridge.exec(["bash", "-lc", script], stdin: nil, cwd: remoteHome, timeout: 300)
            if !result.succeeded {
                throw BoxdSupervisorError.initFailed(Self.failureMessage(of: result))
            }
            remoteCwd = remoteWorktree
        }

        // Claude asks whether a folder is trusted the first time it starts
        // there, and that question would swallow the first prompt. The user
        // trusts the repository they configured, so the answer is recorded
        // before the assistant starts.
        try await trustClaudeFolders([remoteProjectPath, remoteCwd], bridge: bridge, remoteHome: remoteHome)

        // Files that never reach git, like .env, go over the bridge.
        let matches = await BoxdLaunchPlanner.copyMatches(globs: settings.copyGlobs, projectRoot: repoRoot)
        if !matches.isEmpty { log("Copying \(matches.count) file(s)") }
        for relative in matches {
            guard let data = FileManager.default.contents(atPath: "\(repoRoot)/\(relative)") else { continue }
            try await bridge.put(path: "\(remoteProjectPath)/\(relative)", data: data, mode: nil)
            if remoteCwd != remoteProjectPath {
                try await bridge.put(path: "\(remoteCwd)/\(relative)", data: data, mode: nil)
            }
        }

        let remoteLink = RemoteLink(
            mode: .boxd,
            machineName: machineName,
            machineId: machine.id,
            remoteProjectPath: remoteProjectPath,
            remoteCwd: remoteCwd,
            remoteHome: remoteHome,
            lastStatus: "running"
        )
        await dispatch?(.remoteMachineAssigned(cardId: cardId, remote: remoteLink))
        touch(machineName)

        return BoxdPreparation(
            machineName: machineName,
            remoteHome: remoteHome,
            remoteProjectPath: remoteProjectPath,
            remoteCwd: remoteCwd,
            worktree: worktree,
            extraEnv: Self.sessionEnvironment(cardId: cardId, remoteHome: remoteHome, claudeOAuthToken: settings.claudeOAuthToken),
            remoteLink: remoteLink
        )
    }

    /// What a failed script says, in the words a user can act on. Git and the
    /// package managers print their progress first and the reason last, so the
    /// tail of the output carries the error.
    static func failureMessage(of result: ShellCommand.Result, lines: Int = 6) -> String {
        let text = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? result.stdout : result.stderr
        let kept = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(lines)
        return kept.joined(separator: "\n")
    }

    /// Marks folders as trusted in the machine's `~/.claude.json`.
    private func trustClaudeFolders(_ folders: [String], bridge: BoxdBridge, remoteHome: String) async throws {
        let unique = Array(Set(folders)).sorted()
        let script = Self.trustFoldersScript(folders: unique, claudeConfigPath: "\(remoteHome)/.claude.json")
        let node = await boxd.hostProfile(name: bridge.machineName)?.nodePath ?? Self.defaultNodePath
        let result = try await bridge.exec([node, "-e", script], stdin: nil, cwd: remoteHome, timeout: 30)
        if !result.succeeded {
            KanbanCodeLog.warn(Self.subsystem, "could not mark folders trusted: \(result.stderr)")
        }
    }

    /// Node script that sets `hasTrustDialogAccepted` for each folder in
    /// `~/.claude.json`, skips the renderer question, and sets
    /// `skipDangerousModePermissionPrompt` in `~/.claude/settings.json`, which
    /// is what silences the bypass permissions question. Each of these
    /// questions blocks the first prompt on a fresh machine.
    nonisolated static func trustFoldersScript(folders: [String], claudeConfigPath: String) -> String {
        let foldersJSON = (try? JSONSerialization.data(withJSONObject: folders)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let pathJSON = (try? JSONSerialization.data(withJSONObject: [claudeConfigPath])).flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return """
        const fs = require('fs');
        const file = \(pathJSON)[0];
        let config = {};
        try { config = JSON.parse(fs.readFileSync(file, 'utf8')); } catch (e) {}
        config.projects = config.projects || {};
        config.bypassPermissionsModeAccepted = true;
        config.fullscreenUpsellSeenCount = Math.max(config.fullscreenUpsellSeenCount || 0, 3);
        for (const folder of \(foldersJSON)) {
          const entry = config.projects[folder] || {};
          entry.hasTrustDialogAccepted = true;
          config.projects[folder] = entry;
        }
        fs.writeFileSync(file, JSON.stringify(config, null, 2));
        const settingsFile = require('path').join(require('path').dirname(file), '.claude', 'settings.json');
        let settings = {};
        try { settings = JSON.parse(fs.readFileSync(settingsFile, 'utf8')); } catch (e) {}
        settings.skipDangerousModePermissionPrompt = true;
        fs.mkdirSync(require('path').dirname(settingsFile), { recursive: true });
        fs.writeFileSync(settingsFile, JSON.stringify(settings, null, 2));
        """
    }

    /// Readies an ssh machine for sessions: its tmux server stops handing
    /// `NO_COLOR` to new panes (a server started from a shell that had it
    /// set, such as an agent's, passes it to every session after), and its
    /// rush (or agtop, its name before the rename), when it has one, is
    /// recorded so cards set to rush run there.
    private func prepareSessions(machineName: String, bridge: BoxdBridge, remoteHome: String) async {
        _ = try? await bridge.exec(["sh", "-c", Self.tmuxColorScript], stdin: nil, cwd: nil, timeout: 20)
        let found = try? await bridge.exec(
            ["sh", "-c", "command -v rush || command -v agtop"], stdin: nil, cwd: nil, timeout: 20)
        let path = found?.succeeded == true
            ? found?.stdout.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            : ""
        guard !path.isEmpty else {
            registry.setRush(nil, on: machineName)
            KanbanCodeLog.info(Self.subsystem, "\(machineName): no rush, cards run on tmux there")
            return
        }
        let rush = RushCliAdapter(remote: bridge, executable: path, scratchDirectory: "\(remoteHome)/.kanban-code/tmp/rush")
        registry.setRush(rush, on: machineName)
        let remoteVersion = await rush.version()
        let localVersion = await RushCliAdapter().version()
        KanbanCodeLog.info(Self.subsystem, "\(machineName): rush at \(path) (\(remoteVersion ?? "?"), here \(localVersion ?? "none"))")
        if let remoteVersion, let localVersion,
           RushCliAdapter.build(ofVersion: remoteVersion) != RushCliAdapter.build(ofVersion: localVersion) {
            KanbanCodeLog.warn(Self.subsystem, "\(machineName) runs \(remoteVersion), this machine \(localVersion): Scripts/rush-to-machine.sh <ssh target> updates it")
        }
    }

    /// Runs before the assistant in a tmux session on a machine: a tmux
    /// server started with `NO_COLOR` set would otherwise pass it on.
    public static let sessionPreamble = "unset NO_COLOR"

    /// Shell script for a machine's running tmux server, if any: no
    /// `NO_COLOR` for new panes, and truecolor for the programs in them.
    static let tmuxColorScript = "tmux has-session 2>/dev/null || exit 0; "
        + "tmux set-environment -g -u NO_COLOR 2>/dev/null; tmux set-environment -g COLORTERM truecolor"

    /// Environment every assistant process gets on the machine.
    public nonisolated static func sessionEnvironment(cardId: String, remoteHome: String, claudeOAuthToken: String? = nil) -> [String: String] {
        var env = [
            "KANBAN_REMOTE_PROXY": "1",
            "KANBAN_CARD_ID": cardId,
            "KANBAN_CODE_HOME": "\(remoteHome)/.kanban-code",
            "LANG": "C.UTF-8",
            // What the terminals that show the session support, as on the Mac.
            "COLORTERM": "truecolor",
        ]
        // Claude Code refuses --dangerously-skip-permissions for root unless
        // it is told it runs in a sandbox; an ssh machine may log in as root.
        if remoteHome == "/root" {
            env["IS_SANDBOX"] = "1"
        }
        if let token = claudeOAuthToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            env["CLAUDE_CODE_OAUTH_TOKEN"] = token
        }
        return env
    }

    /// Makes the session environment visible to every pane of the tmux
    /// session, not only the first command.
    public func exportSessionEnvironment(machineName: String, sessionName: String, env: [String: String]) async {
        guard let bridge = machines[machineName]?.bridge else { return }
        for (key, value) in env {
            _ = try? await bridge.exec(["tmux", "set-environment", "-t", sessionName, key, value], stdin: nil, cwd: nil, timeout: 20)
        }
    }

    /// Routes a tmux name to a machine, for a session created after the
    /// launch, such as an extra terminal.
    public func assignSession(_ sessionName: String, to machineName: String) {
        registry.assign(sessionName: sessionName, to: machineName)
    }

    public func uploadImages(sessionName: String, imagePaths: [String]) async throws -> [String]? {
        guard let machineName = registry.machine(forSession: sessionName) else { return nil }
        guard let runtime = machines[machineName], let bridge = runtime.bridge else {
            throw BoxdSupervisorError.notConnected(machineName)
        }
        let folder = String(UUID().uuidString.lowercased().prefix(8))
        var remotePaths: [String] = []
        for (index, localPath) in imagePaths.enumerated() {
            guard let data = FileManager.default.contents(atPath: localPath) else { continue }
            let pathExtension = (localPath as NSString).pathExtension
            let suffix = pathExtension.isEmpty ? "png" : pathExtension
            let remotePath = "\(runtime.remoteHome)/.kanban-code/images/\(folder)/\(index + 1).\(suffix)"
            try await upload(machineName: machineName, bridge: bridge, remotePath: remotePath, data: data)
            remotePaths.append(remotePath)
        }
        return remotePaths
    }

    /// One image from the Mac clipboard, pasted straight into the terminal of
    /// a session on `machineName`: the bytes go over the bridge and the
    /// terminal types the path that comes back.
    public func uploadPastedImage(machineName: String, data: Data) async throws -> String {
        if machines[machineName]?.bridge == nil {
            _ = await reconnectIfRunning(machineName: machineName)
        }
        guard let runtime = machines[machineName], let bridge = runtime.bridge else {
            throw BoxdSupervisorError.notConnected(machineName)
        }
        let name = String(UUID().uuidString.lowercased().prefix(8))
        let remotePath = "\(runtime.remoteHome)/.kanban-code/images/pasted/\(name).png"
        try await upload(machineName: machineName, bridge: bridge, remotePath: remotePath, data: data)
        return remotePath
    }

    /// Writes the ready marker of a session that now exists on a machine.
    /// The terminal waits for it before it attaches, and its content names
    /// the machine to attach to.
    public func markSessionReady(_ sessionName: String, on machineName: String) {
        let marker = readyMarkerPath(sessionName)
        try? FileManager.default.createDirectory(
            atPath: (marker as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: marker, contents: Data(machineName.utf8))
        try? FileManager.default.removeItem(atPath: marker + Self.pausedMarkerSuffix)
    }

    /// Forgets the machine of these tmux names, so they route locally again.
    public func releaseSessions(_ sessionNames: [String]) {
        for name in sessionNames { registry.unassign(sessionName: name) }
    }

    /// Whether the tmux session of a card is still alive on its machine.
    public func hasSession(machineName: String, sessionName: String) async -> Bool {
        guard let bridge = machines[machineName]?.bridge else { return false }
        let alive: Bool
        if let id = RushSessionName.rushId(fromName: sessionName) {
            alive = (try? await registry.rush(for: machineName)?.info(id: id))??.alive == true
        } else {
            let result = try? await bridge.exec(["tmux", "has-session", "-t", sessionName], stdin: nil, cwd: nil, timeout: 20)
            alive = result?.succeeded == true
        }
        if !alive { registry.forgetSession(sessionName, on: machineName) }
        return alive
    }

    /// Transcript pushes in flight, so two resumes of the same card never
    /// write the same file on the machine at once.
    private var transcriptPushes: Set<String> = []

    /// Copies a local transcript to the machine, rewritten to machine paths,
    /// together with its sidecar directory and statusline context. The agent
    /// holds every pushed file while it is written, so the bytes do not come
    /// back over the bridge.
    public func pushTranscript(
        machineName: String,
        localPath: String,
        sessionId: String,
        remoteCwd: String,
        remoteLines: Int = 0,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws {
        let pushKey = "\(machineName):\(sessionId)"
        guard !transcriptPushes.contains(pushKey) else {
            KanbanCodeLog.warn(Self.subsystem, "Transcript \(sessionId.prefix(8)) is already being pushed to \(machineName), skipping")
            return
        }
        transcriptPushes.insert(pushKey)
        defer { transcriptPushes.remove(pushKey) }
        guard let runtime = machines[machineName], let bridge = runtime.bridge else {
            throw BoxdSupervisorError.notConnected(machineName)
        }
        let mirror = runtime.mirror
        guard let remotePath = await mirror.remotePath(forLocal: localPath, remoteCwd: remoteCwd) else { return }
        let reversed = await mirror.rewriter.reversed
        let temporary = (NSTemporaryDirectory() as NSString).appendingPathComponent("kanban-push-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(atPath: temporary) }
        let localSize = (try? FileManager.default.attributesOfItem(atPath: localPath)[.size] as? Int) ?? 0
        log("Preparing transcript (\(Self.sizeText(localSize)))")
        // The rewrite reads the whole file line by line: off the actor, so
        // the bridge events of the other machines keep flowing meanwhile.
        try await Task.detached(priority: .userInitiated) {
            try reversed.rewriteFile(at: localPath, to: temporary)
        }.value
        let data = try Data(contentsOf: URL(fileURLWithPath: temporary))
        await mirror.suspend(remotePath: remotePath)
        defer { Task { await mirror.resume(remotePath: remotePath) } }

        // The transcript only ever grows, so when the machine already holds
        // its first lines, byte for byte, only the tail crosses the wire.
        // The rewrite is deterministic, which makes the comparison a hash of
        // the prefix on each side.
        var pushed = false
        if remoteLines > 0,
           let prefix = BoxdLaunchPlanner.transcriptPrefix(fileAt: temporary, lineCount: remoteLines),
           prefix.bytes < data.count {
            let result = try? await bridge.exec(
                ["sh", "-c", "head -n \"$1\" \"$2\" | shasum -a 256 2>/dev/null || head -n \"$1\" \"$2\" | sha256sum", "sh", String(remoteLines), remotePath],
                stdin: nil, cwd: nil, timeout: 60)
            let remoteHash = result?.stdout.components(separatedBy: .whitespaces).first ?? ""
            if remoteHash == prefix.sha256 {
                let delta = data.subdata(in: prefix.bytes..<data.count)
                log("Appending to the transcript on the machine (\(Self.sizeText(delta.count)) of \(Self.sizeText(data.count)))")
                KanbanCodeLog.info(Self.subsystem, "Transcript \(sessionId.prefix(8)): appending \(delta.count) bytes after \(remoteLines) matching lines on \(machineName)")
                try await append(machineName: machineName, bridge: bridge, remotePath: remotePath, data: delta,
                                 onEvent: Self.uploadReporter(prefix: "Appending to the transcript", log: log))
                pushed = true
            } else {
                KanbanCodeLog.info(Self.subsystem, "Transcript \(sessionId.prefix(8)): prefix on \(machineName) differs (\(remoteHash.prefix(12)) vs \(prefix.sha256.prefix(12))), pushing whole")
            }
        }
        if !pushed {
            log("Pushing transcript (\(Self.sizeText(data.count)))")
            try await upload(machineName: machineName, bridge: bridge, remotePath: remotePath, data: data,
                             onEvent: Self.uploadReporter(prefix: "Pushing transcript", log: log))
        }
        await mirror.recordPushed(
            remotePath: remotePath,
            bytes: data.count,
            localProjectDirectory: (localPath as NSString).deletingLastPathComponent
        )

        let localSidecar = ((localPath as NSString).deletingLastPathComponent as NSString).appendingPathComponent(sessionId)
        let remoteSidecar = ((remotePath as NSString).deletingLastPathComponent as NSString).appendingPathComponent(sessionId)
        if let enumerator = FileManager.default.enumerator(atPath: localSidecar) {
            let entries = enumerator.allObjects.compactMap { $0 as? String }
            for (index, relative) in entries.enumerated() {
                let path = "\(localSidecar)/\(relative)"
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
                      let bytes = FileManager.default.contents(atPath: path) else { continue }
                let payload = path.hasSuffix(".jsonl") ? Self.rewrite(bytes, with: reversed) : bytes
                let target = "\(remoteSidecar)/\(relative)"
                log("Pushing session files (\(index + 1) of \(entries.count), \(Self.sizeText(payload.count)))")
                try await upload(machineName: machineName, bridge: bridge, remotePath: target, data: payload,
                                 onEvent: Self.uploadReporter(prefix: "Pushing session files (\(index + 1) of \(entries.count))", log: log))
                await mirror.recordPushed(remotePath: target, bytes: payload.count)
            }
        }

        let localContext = "\(localKanbanHome)/context/\(sessionId).json"
        if let bytes = FileManager.default.contents(atPath: localContext) {
            let target = "\(runtime.remoteHome)/.kanban-code/context/\(sessionId).json"
            try await upload(machineName: machineName, bridge: bridge, remotePath: target, data: bytes)
            await mirror.recordPushed(remotePath: target, bytes: bytes.count)
        }
    }

    /// Lines of a transcript on the machine, or zero when it is not there.
    public func remoteTranscriptLines(machineName: String, localPath: String, remoteCwd: String) async -> Int {
        guard let runtime = machines[machineName], let bridge = runtime.bridge,
              let remotePath = await runtime.mirror.remotePath(forLocal: localPath, remoteCwd: remoteCwd) else { return 0 }
        let result = try? await bridge.exec(["sh", "-c", "wc -l < \"$1\"", "sh", remotePath], stdin: nil, cwd: nil, timeout: 20)
        return Int(result?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
    }

    /// Turns the events of an upload into launch status lines.
    nonisolated static func uploadReporter(
        prefix: String, log: @escaping @Sendable (String) -> Void
    ) -> @Sendable (BoxdUploadEvent) -> Void {
        { event in
            switch event {
            case .progress(let sent, let total):
                log("\(prefix): \(sizeText(sent)) of \(sizeText(total))")
            case .retry(let attempt, let of, let reason):
                log("\(prefix) interrupted (\(reason)), trying again \(attempt)/\(of)")
            }
        }
    }

    nonisolated static func sizeText(_ bytes: Int) -> String {
        if bytes >= 1024 * 1024 { return "\(bytes / (1024 * 1024)) MB" }
        if bytes >= 1024 { return "\(bytes / 1024) KB" }
        return "\(bytes) bytes"
    }

    /// Runs a shell command on a machine (over ssh for an ssh machine).
    public func exec(machineName: String, command: String, timeout: TimeInterval) async throws -> ShellCommand.Result {
        try await boxd.exec(name: machineName, command: command, timeout: timeout)
    }

    // MARK: - RemoteMachineControl

    /// Stops a machine: nothing of it has to stay in memory. It costs its
    /// disk only, and comes back with a cold start when the card is resumed.
    /// The reason tells the card why: over from the work being done, or idle
    /// for the whole window.
    public func stop(machineName: String) async {
        await stop(machineName: machineName, reason: .stopped)
    }

    public func stop(machineName: String, reason: RemotePausedReason) async {
        // An ssh machine is always on and shared by its cards: the sessions
        // of a card are killed on their own, the machine and its bridge stay.
        if await isHost(machineName) {
            KanbanCodeLog.info(Self.subsystem, "\(machineName): ssh machine, not stopped")
            return
        }
        setPausedMarkers(machineName: machineName, paused: true)
        if var runtime = machines[machineName] {
            runtime.pausedReason = reason
            runtime.resumedForPeek = false
            runtime.eventTask?.cancel()
            runtime.keepaliveTask?.cancel()
            runtime.eventTask = nil
            runtime.keepaliveTask = nil
            if let bridge = runtime.bridge { await bridge.stop() }
            runtime.bridge = nil
            machines[machineName] = runtime
        }
        peekPauseRequested.remove(machineName)
        registry.disconnectMachine(machineName, state: .paused(reason))
        do {
            try await boxd.stop(name: machineName)
            machines[machineName]?.machineHalted = true
            KanbanCodeLog.info(Self.subsystem, "\(machineName): stopped")
        } catch {
            KanbanCodeLog.warn(Self.subsystem, "\(machineName): stop failed: \(error.localizedDescription)")
        }
        await report(machineName, state: .paused(reason))
    }

    public func destroy(machineName: String) async throws {
        if await isHost(machineName) {
            KanbanCodeLog.info(Self.subsystem, "\(machineName): ssh machine, not removed")
            return
        }
        if var runtime = machines[machineName] {
            runtime.eventTask?.cancel()
            runtime.keepaliveTask?.cancel()
            if let bridge = runtime.bridge { await bridge.stop() }
            runtime.bridge = nil
            await runtime.mirror.forget()
            machines[machineName] = nil
        }
        registry.removeMachine(machineName)
        do {
            try await boxd.remove(name: machineName)
        } catch {
            // A machine that is already gone is the state we want.
            if Self.isNotFound(error) {
                KanbanCodeLog.info(Self.subsystem, "\(machineName): already removed")
            } else {
                throw error
            }
        }
        KanbanCodeLog.info(Self.subsystem, "\(machineName): destroyed")
    }

    /// Stops every running machine, in parallel, within `deadline`. For the
    /// quit path, which kills the sessions first: nothing warm is left to
    /// keep, and a stopped machine cannot be woken by stray traffic to its
    /// public URL the way a standby machine can. Returns when every machine
    /// is stopped or when `deadline` passes, whichever comes first; a stop
    /// that hangs keeps running on its own, the quit must not wait for it.
    public func stopAll(reason: RemotePausedReason, deadline: Duration = .seconds(8)) async {
        var running: [String] = []
        for (name, runtime) in machines where runtime.bridge != nil {
            if await !isHost(name) { running.append(name) }
        }
        guard !running.isEmpty else { return }
        let stops = running.map { name in
            Task { await self.stop(machineName: name, reason: reason) }
        }
        let gate = FirstToFinish()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task {
                for stop in stops { await stop.value }
                if gate.claim() { continuation.resume() }
            }
            Task {
                try? await Task.sleep(for: deadline)
                if gate.claim() {
                    KanbanCodeLog.warn(Self.subsystem, "stopAll: deadline passed with machines still stopping")
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - Sweep

    /// What the sweep did to the machines it found.
    public struct SweepReport: Sendable, Equatable {
        public var destroyed: [String] = []
        public var stopped: [String] = []
        public init(destroyed: [String] = [], stopped: [String] = []) {
            self.destroyed = destroyed
            self.stopped = stopped
        }
    }

    /// Cleans up machines this app created (`kanban-*`) that no card needs:
    /// - a machine no card references, or only archived cards reference, is
    ///   destroyed once it is not running (a running one is paused first, so
    ///   a machine in use by another process gets a grace period);
    /// - a running machine whose cards have no tmux session and no bridge in
    ///   this app is paused.
    /// `sourceMachine` and machines with an open bridge are never touched.
    public func sweep(links: [Link]) async -> SweepReport {
        let settings = await settingsProvider()
        var report = SweepReport()
        guard let listed = try? await boxd.listMachines() else { return report }

        var referencedBy: [String: [Link]] = [:]
        for link in links {
            guard let remote = link.remote, remote.mode == .boxd else { continue }
            referencedBy[remote.machineName, default: []].append(link)
        }

        for machine in listed where BoxdLaunchPlanner.isManagedMachineName(machine.name) {
            let name = machine.name
            guard name != settings.sourceMachine, machine.status != .destroyed else { continue }
            if machines[name]?.bridge != nil { continue }

            let holders = referencedBy[name] ?? []
            let liveHolders = holders.filter { !$0.manuallyArchived }
            if liveHolders.isEmpty {
                if machine.status == .running || machine.status == .booting {
                    KanbanCodeLog.info(Self.subsystem, "sweep: \(name) has no card, stopping")
                    try? await boxd.stop(name: name)
                    report.stopped.append(name)
                } else {
                    KanbanCodeLog.info(Self.subsystem, "sweep: \(name) has no card, destroying")
                    do {
                        try await destroy(machineName: name)
                        report.destroyed.append(name)
                        if !holders.isEmpty { await self.report(name, state: .destroyed) }
                    } catch {
                        KanbanCodeLog.warn(Self.subsystem, "sweep: destroy \(name) failed: \(error.localizedDescription)")
                    }
                }
                continue
            }

            let hasSession = liveHolders.contains { $0.tmuxLink != nil }
            if !hasSession, machine.status == .running {
                KanbanCodeLog.info(Self.subsystem, "sweep: \(name) has no session, stopping")
                await stop(machineName: name, reason: .sessionStopped)
                report.stopped.append(name)
            }
        }
        return report
    }

    /// A sweep with the links the app provided, or nothing when it did not.
    public func sweepIfPossible() async -> SweepReport {
        guard let linksProvider else { return SweepReport() }
        return await sweep(links: await linksProvider())
    }

    /// Machines paused for system sleep come back after wake.
    /// Names of machines with an open bridge.
    public var connectedMachines: [String] {
        machines.filter { $0.value.bridge != nil }.map(\.key).sorted()
    }

    // MARK: - Machine lifecycle

    private func ensureRunning(machineName: String, settings: BoxdSettings, log: @escaping @Sendable (String) -> Void) async throws -> BoxdMachine {
        if await isHost(machineName) {
            log("Reaching \(machineName) over ssh")
            return try await boxd.getMachine(name: machineName)
        }
        var machine: BoxdMachine
        do {
            machine = try await boxd.getMachine(name: machineName)
        } catch {
            log("Creating machine \(machineName) from snapshot \(settings.snapshotName)")
            machine = try await boxd.createMachine(
                name: machineName,
                snapshot: settings.snapshotName.isEmpty ? nil : settings.snapshotName,
                autoSuspendSeconds: settings.inactivityTimeoutSeconds
            )
            KanbanCodeLog.info(Self.subsystem, "\(machineName): created from \(settings.snapshotName)")
            machine = try await waitUntilRunning(machineName: machineName, fallback: machine)
            return machine
        }
        switch machine.status {
        case .running:
            return machine
        case .standby:
            log("Resuming machine \(machineName)")
            try await boxd.resume(name: machineName)
        case .hibernated:
            log("Waking machine \(machineName)")
            try await boxd.wake(name: machineName)
        case .stopped, .unknown:
            log("Starting machine \(machineName)")
            try await boxd.start(name: machineName)
        case .booting, .stopping:
            break
        case .destroyed:
            await report(machineName, state: .destroyed)
            throw BoxdSupervisorError.machineDestroyed(machineName)
        }
        return try await waitUntilRunning(machineName: machineName, fallback: machine)
    }

    private func waitUntilRunning(machineName: String, fallback: BoxdMachine) async throws -> BoxdMachine {
        var latest = fallback
        for _ in 0..<60 {
            if let machine = try? await boxd.getMachine(name: machineName) {
                latest = machine
                if machine.status == .running { return machine }
                if machine.status == .destroyed { throw BoxdSupervisorError.machineDestroyed(machineName) }
            }
            try await Task.sleep(for: .seconds(2))
        }
        return latest
    }

    private func makeRuntime(machineName: String, localProjectPath: String, remoteProjectPath: String?, remoteHome: String, pausedReason: RemotePausedReason? = nil, otherProjects: [PathMapping] = []) -> MachineRuntime {
        let primary = remoteProjectPath ?? "\(remoteHome)/\((localProjectPath as NSString).lastPathComponent)"
        let others = otherProjects.filter { $0.from != primary }
        let mappings = BoxdLaunchPlanner.mappings(
            localProjectPath: localProjectPath,
            remoteProjectPath: primary,
            localHome: localHome,
            remoteHome: remoteHome,
            localKanbanHome: localKanbanHome,
            remoteKanbanHome: "\(remoteHome)/.kanban-code"
        ) + others
        let mirror = BoxdMirror(
            machineName: machineName,
            rewriter: TranscriptPathRewriter(mappings),
            remoteHome: remoteHome,
            localHome: localHome,
            localKanbanHome: localKanbanHome
        )
        return MachineRuntime(
            bridge: nil,
            mirror: mirror,
            lastActivity: now(),
            pausedReason: pausedReason,
            remoteHome: remoteHome,
            localProjectPath: localProjectPath,
            remoteProjectPath: primary,
            otherProjects: others
        )
    }

    /// Every checkout a runtime maps, remote to local, primary first.
    private static func projectMappings(of runtime: MachineRuntime) -> [PathMapping] {
        [PathMapping(from: runtime.remoteProjectPath, to: runtime.localProjectPath)] + runtime.otherProjects
    }

    /// Adds a checkout to a machine that already has a runtime. A machine
    /// shared by several projects maps them all, so the transcripts of every
    /// card come back with local paths. Returns false when there is no
    /// runtime yet.
    @discardableResult
    private func addProject(machineName: String, localProjectPath: String, remoteProjectPath: String?) async -> Bool {
        guard var runtime = machines[machineName] else { return false }
        guard let remoteProjectPath else { return true }
        let mapping = PathMapping(from: remoteProjectPath, to: localProjectPath)
        let known = Self.projectMappings(of: runtime)
        if known.contains(mapping) { return true }
        runtime.otherProjects = runtime.otherProjects.filter { $0.from != mapping.from } + [mapping]
        machines[machineName] = runtime
        let mappings = BoxdLaunchPlanner.mappings(
            localProjectPath: runtime.localProjectPath,
            remoteProjectPath: runtime.remoteProjectPath,
            localHome: localHome,
            remoteHome: runtime.remoteHome,
            localKanbanHome: localKanbanHome,
            remoteKanbanHome: "\(runtime.remoteHome)/.kanban-code"
        ) + runtime.otherProjects
        await runtime.mirror.setRewriter(TranscriptPathRewriter(mappings))
        KanbanCodeLog.info(Self.subsystem, "\(machineName): maps \(remoteProjectPath) to \(localProjectPath)")
        return true
    }

    /// Opens the bridge to a running machine, installing the CLI first when
    /// the machine does not have this app's version of it.
    private func connect(
        machineName: String,
        localProjectPath: String,
        remoteProjectPath: String?,
        remoteHome: String,
        keepActivityClock: Bool = false,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws {
        let host = await isHost(machineName)
        if machines[machineName]?.bridge != nil {
            if host {
                await addProject(machineName: machineName, localProjectPath: localProjectPath, remoteProjectPath: remoteProjectPath)
            }
            return
        }
        let previousActivity = machines[machineName]?.lastActivity
        var runtime = machines[machineName] ?? makeRuntime(
            machineName: machineName, localProjectPath: localProjectPath,
            remoteProjectPath: remoteProjectPath, remoteHome: remoteHome)
        if let remoteProjectPath, runtime.remoteProjectPath != remoteProjectPath || runtime.localProjectPath != localProjectPath {
            let kept = host ? Self.projectMappings(of: runtime) : []
            runtime = makeRuntime(machineName: machineName, localProjectPath: localProjectPath, remoteProjectPath: remoteProjectPath, remoteHome: remoteHome, pausedReason: runtime.pausedReason, otherProjects: kept)
        }
        runtime.pausedReason = nil
        runtime.machineHalted = false
        machines[machineName] = runtime

        try await bootstrapIfNeeded(machineName: machineName, remoteHome: remoteHome, log: log)
        // The self-park watchdog stops an idle boxd machine; an ssh machine
        // is always on.
        if !host {
            await startWatchdog(machineName: machineName, remoteHome: runtime.remoteHome)
        }

        log("Connecting to \(machineName)")
        let bridge = BoxdBridge(
            machineName: machineName,
            channel: try await boxd.bridgeChannel(name: machineName, remoteHome: remoteHome))
        try await bridge.start()
        runtime.bridge = bridge
        runtime.reconnectAttempts = 0
        if let home = await bridge.remoteHome, !home.isEmpty, !home.hasSuffix("/.kanban-code"), home != runtime.remoteHome {
            runtime = makeRuntime(machineName: machineName, localProjectPath: localProjectPath, remoteProjectPath: remoteProjectPath, remoteHome: home, otherProjects: runtime.otherProjects)
            runtime.bridge = bridge
        }
        if keepActivityClock, let previousActivity {
            runtime.lastActivity = Self.activityAfterOutsideResume(
                previous: previousActivity,
                now: now(),
                timeout: TimeInterval(await settingsProvider().inactivityTimeoutSeconds),
                grace: Self.outsideResumeGrace)
        } else {
            runtime.lastActivity = now()
        }
        machines[machineName] = runtime

        let mirror = runtime.mirror
        if await mirror.offsets.isEmpty {
            // First contact: what the snapshot brought along stays there.
            let sizes = await existingFileSizes(bridge: bridge, mirror: mirror)
            await mirror.seedOffsets(sizes)
        }
        try await bridge.watch(roots: await mirror.watchRoots, offsets: await mirror.offsets)

        // The machine starts with the login of the snapshot. The session
        // must not: it gets the login of this Mac before it starts.
        log("Syncing logins")
        if lastClaudeAccountId == nil {
            lastClaudeAccountId = await loginStore.claudeAccount()?["accountUuid"] as? String
        }
        _ = await AssistantLoginSync(runner: bridge, store: loginStore, remoteHome: runtime.remoteHome, machineName: machineName, accounts: loginAccounts).run()

        let transport = BridgeTmuxTransport(runner: bridge, remoteHome: runtime.remoteHome)
        registry.setMachine(machineName, state: .connected, tmux: TmuxAdapter(transport: transport))
        if host {
            await prepareSessions(machineName: machineName, bridge: bridge, remoteHome: runtime.remoteHome)
        }
        setPausedMarkers(machineName: machineName, paused: false)
        await report(machineName, state: .connected)
        KanbanCodeLog.info(Self.subsystem, "\(machineName): connected (agent \(await bridge.agentVersion ?? "?"))")

        runtime.eventTask = Task { [weak self] in
            for await event in bridge.events {
                await self?.handle(event, from: machineName)
            }
        }
        runtime.keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(45))
                guard let self else { return }
                if !(await self.isConnected(machineName)) { return }
                try? await bridge.ping()
            }
        }
        machines[machineName] = runtime
        startInactivityTimer()
    }

    private func existingFileSizes(bridge: BoxdBridge, mirror: BoxdMirror) async -> [String: Int] {
        let roots = await mirror.watchRoots.map(\.path)
        let script = "for r in " + roots.map(Self.shellEscape).joined(separator: " ")
            + "; do [ -e \"$r\" ] && find \"$r\" -type f -printf '%s %p\\n'; done; true"
        guard let result = try? await bridge.exec(["bash", "-c", script], stdin: nil, cwd: nil, timeout: 60) else { return [:] }
        var sizes: [String: Int] = [:]
        for line in result.stdout.components(separatedBy: "\n") {
            guard let space = line.firstIndex(of: " "), let size = Int(line[..<space]) else { continue }
            sizes[String(line[line.index(after: space)...])] = size
        }
        return sizes
    }

    private func bootstrapIfNeeded(machineName: String, remoteHome: String, log: @escaping @Sendable (String) -> Void) async throws {
        let versionFile = "\(remoteHome)/.kanban-code/cli/VERSION"
        let installed = (try? await boxd.exec(name: machineName, command: "cat \(versionFile) 2>/dev/null; true", timeout: 60))?
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let cliBundlePath, FileManager.default.fileExists(atPath: "\(cliBundlePath)/dist/kanban.js") else {
            throw BoxdSupervisorError.noCliBundle
        }
        let stamp = Self.bundleStamp(appVersion: appVersion, cliBundlePath: cliBundlePath)
        if installed == stamp, !stamp.isEmpty { return }
        log("Installing the kanban CLI \(appVersion) on \(machineName)")
        let archive = (NSTemporaryDirectory() as NSString).appendingPathComponent("kanban-cli-\(UUID().uuidString).tgz")
        defer { try? FileManager.default.removeItem(atPath: archive) }
        // COPYFILE_DISABLE keeps macOS extended attributes out of the archive;
        // GNU tar on the machine would print a warning for every file.
        var tarEnvironment = ShellCommand.loginEnvironment
        tarEnvironment["COPYFILE_DISABLE"] = "1"
        let tar = try await ShellCommand.run(
            "/usr/bin/tar",
            arguments: ["--no-xattrs", "-czf", archive, "-C", (cliBundlePath as NSString).deletingLastPathComponent, (cliBundlePath as NSString).lastPathComponent],
            environment: tarEnvironment,
            timeout: 300
        )
        guard tar.succeeded, let data = FileManager.default.contents(atPath: archive) else {
            throw BoxdSupervisorError.bootstrapFailed(tar.stderr)
        }
        let size = Self.megabytes(data.count)
        log("Uploading the kanban CLI (\(size)) to \(machineName)")
        do {
            try await boxd.upload(name: machineName, remotePath: "/tmp/kanban-cli.tgz", data: data) { event in
                switch event {
                case .progress(let sent, let total):
                    log("Uploading the kanban CLI: \(Self.megabytes(sent)) of \(Self.megabytes(total))")
                case .retry(let attempt, let of, let reason):
                    log("Upload interrupted (\(reason)), trying again \(attempt)/\(of)")
                }
            }
        } catch {
            throw BoxdSupervisorError.bootstrapFailed(
                "the upload of the kanban CLI (\(size)) to \(machineName) failed: \(BoxdCliAdapter.shortMessage(of: error))")
        }
        let bundleName = (cliBundlePath as NSString).lastPathComponent
        let node = await boxd.hostProfile(name: machineName)?.nodePath ?? Self.defaultNodePath
        let script = """
        set -e
        mkdir -p \(remoteHome)/.kanban-code \(remoteHome)/.local/bin
        rm -rf \(remoteHome)/.kanban-code/cli.new
        mkdir -p \(remoteHome)/.kanban-code/cli.new
        tar -xzf /tmp/kanban-cli.tgz -C \(remoteHome)/.kanban-code/cli.new --strip-components=1 \(Self.shellEscape(bundleName))
        rm -rf \(remoteHome)/.kanban-code/cli
        mv \(remoteHome)/.kanban-code/cli.new \(remoteHome)/.kanban-code/cli
        rm -f /tmp/kanban-cli.tgz
        printf '%s' \(Self.shellEscape(stamp)) > \(versionFile)
        printf '#!/bin/sh\\nexec \(node) \(remoteHome)/.kanban-code/cli/dist/kanban.js "$@"\\n' > \(remoteHome)/.local/bin/kanban
        chmod +x \(remoteHome)/.local/bin/kanban
        KANBAN_CODE_HOME=\(remoteHome)/.kanban-code \(remoteHome)/.local/bin/kanban hooks install
        """
        let result = try await boxd.exec(name: machineName, command: "bash -c \(Self.shellEscape(script))", timeout: 300)
        guard result.succeeded else {
            throw BoxdSupervisorError.bootstrapFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        KanbanCodeLog.info(Self.subsystem, "\(machineName): kanban CLI \(appVersion) installed")
    }

    /// Installs and restarts the machine's self-park watchdog and restores
    /// its suspend timers. Every connect runs it: a watchdog park shortens
    /// the timers, and a machine that comes back to work needs them back.
    private func startWatchdog(machineName: String, remoteHome: String) async {
        let idle = await settingsProvider().inactivityTimeoutSeconds
        let script = BoxdLaunchPlanner.watchdogStartScript(remoteHome: remoteHome, idleSeconds: idle)
        do {
            let result = try await boxd.exec(name: machineName, command: "bash -c \(Self.shellEscape(script))", timeout: 60)
            guard result.succeeded else {
                KanbanCodeLog.warn(Self.subsystem, "\(machineName): watchdog start failed: \(result.stderr.isEmpty ? result.stdout : result.stderr)")
                return
            }
            KanbanCodeLog.info(Self.subsystem, "\(machineName): self-park watchdog running (idle \(idle)s)")
        } catch {
            KanbanCodeLog.warn(Self.subsystem, "\(machineName): watchdog start failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Events

    private func handle(_ event: BridgeEvent, from machineName: String) async {
        guard let runtime = machines[machineName] else { return }
        switch event {
        case .file, .removed:
            let outcome = await runtime.mirror.apply(event)
            if case .transcript = outcome { touch(machineName) }
            if case .hookEvents(let count) = outcome, count > 0 { touch(machineName) }
        case .activity:
            touch(machineName)
        case .proxy(let request):
            await runProxy(request, on: machineName)
        case .hello:
            break
        case .disconnected(let reason):
            await handleDisconnect(machineName: machineName, reason: reason)
        }
    }

    private func touch(_ machineName: String) {
        machines[machineName]?.lastActivity = now()
        // Work arrived: the machine is not a look any more.
        machines[machineName]?.resumedForPeek = false
        peekPauseRequested.remove(machineName)
    }

    private func handleDisconnect(machineName: String, reason: String) async {
        guard var runtime = machines[machineName] else { return }
        runtime.bridge = nil
        runtime.keepaliveTask?.cancel()
        runtime.keepaliveTask = nil
        machines[machineName] = runtime
        if let paused = runtime.pausedReason {
            registry.disconnectMachine(machineName, state: .paused(paused))
            return
        }
        registry.disconnectMachine(machineName, state: .reconnecting(attempt: 1))
        await report(machineName, state: .reconnecting(attempt: 1))
        KanbanCodeLog.warn(Self.subsystem, "\(machineName): bridge lost (\(reason)), reconnecting")
        Task { [weak self] in await self?.reconnect(machineName: machineName) }
    }

    /// Tries to reach a machine the app did not pause, for as long as that
    /// holds. The tries back off to one a minute; they end when the bridge
    /// is back, when boxd reports the machine parked or gone, or when a
    /// pause takes over. A Mac without network for hours costs one `boxd
    /// machine get` a minute per machine, and the watchdog on the machine
    /// stops it on its own when the work there dries up.
    private func reconnect(machineName: String) async {
        guard var runtime = machines[machineName], runtime.bridge == nil, runtime.pausedReason == nil else { return }
        runtime.reconnectAttempts += 1
        machines[machineName] = runtime
        let attempt = runtime.reconnectAttempts
        try? await Task.sleep(for: .seconds(Self.reconnectDelay(attempt: attempt)))
        guard let current = machines[machineName], current.bridge == nil, current.pausedReason == nil else { return }
        do {
            let machine = try await boxd.getMachine(name: machineName)
            switch machine.status {
            case .running, .booting:
                try await connect(
                    machineName: machineName,
                    localProjectPath: current.localProjectPath,
                    remoteProjectPath: current.remoteProjectPath,
                    remoteHome: current.remoteHome
                )
            case .stopped:
                machines[machineName]?.pausedReason = .inactivity
                machines[machineName]?.machineHalted = true
                registry.disconnectMachine(machineName, state: .paused(.inactivity))
                await report(machineName, state: .paused(.inactivity))
            case .standby, .hibernated:
                // boxd parked it on its own (auto-suspend). Standby still
                // bills RAM and wakes on stray traffic: stop it for real.
                await stop(machineName: machineName, reason: .inactivity)
            case .destroyed:
                machines[machineName] = nil
                registry.removeMachine(machineName)
                await report(machineName, state: .destroyed)
            case .stopping, .unknown:
                Task { [weak self] in await self?.reconnect(machineName: machineName) }
            }
        } catch {
            if Self.isNotFound(error) {
                // Removed outside the app: nothing left to reach.
                KanbanCodeLog.info(Self.subsystem, "\(machineName): no longer exists, reconnect ends")
                machines[machineName] = nil
                registry.removeMachine(machineName)
                await report(machineName, state: .destroyed)
                return
            }
            KanbanCodeLog.warn(Self.subsystem, "\(machineName): reconnect \(attempt) failed: \(error.localizedDescription)")
            await report(machineName, state: .reconnecting(attempt: attempt + 1))
            Task { [weak self] in await self?.reconnect(machineName: machineName) }
        }
    }

    /// Whether boxd answered that the machine does not exist.
    nonisolated static func isNotFound(_ error: Error) -> Bool {
        if case .commandFailed(_, _, let message) = error as? BoxdError {
            return message.lowercased().contains("not found")
        }
        return false
    }

    nonisolated static func megabytes(_ bytes: Int) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    /// Seconds before reconnect try `attempt`: 5, 10, ... up to a minute.
    nonisolated public static func reconnectDelay(attempt: Int) -> Int {
        min(60, 5 * max(1, attempt))
    }

    private func runProxy(_ request: BridgeProxyRequest, on machineName: String) async {
        guard let runtime = machines[machineName], let bridge = runtime.bridge else { return }
        touch(machineName)
        let rewriter = await runtime.mirror.rewriter
        var imagePaths: [String] = []
        if !request.images.isEmpty {
            let directory = "\(localKanbanHome)/images/proxy/\(request.id)"
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            for image in request.images {
                let path = "\(directory)/\((image.name as NSString).lastPathComponent)"
                try? image.data.write(to: URL(fileURLWithPath: path))
                imagePaths.append(path)
            }
        }
        let invocation = BoxdProxyInvocation(
            request: request,
            cardId: request.env["KANBAN_CARD_ID"],
            cwd: request.cwd.map { rewriter.mapPath($0) },
            imagePaths: imagePaths
        )
        let result: ShellCommand.Result
        if let proxyRunner {
            result = await proxyRunner(invocation)
        } else {
            result = ShellCommand.Result(exitCode: 1, stdout: "", stderr: "kanban proxy is not available in this app")
        }
        do {
            try await bridge.reply(to: request, stdout: result.stdout, stderr: result.stderr, code: result.exitCode)
        } catch {
            KanbanCodeLog.warn(Self.subsystem, "\(machineName): could not answer proxy \(request.id): \(error.localizedDescription)")
        }
    }

    // MARK: - Inactivity

    private func startInactivityTimer() {
        guard inactivityTask == nil else { return }
        inactivityTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await self?.checkInactivity()
                await self?.followExternalResumes()
                await self?.syncAllLogins()
                await self?.sweepOnTick()
            }
        }
    }

    // MARK: - Pause markers

    /// The ready marker of every session on the machine gets a `.paused`
    /// sibling while the app holds the machine paused. The attach loop of
    /// the terminal waits on it instead of reconnecting, because
    /// `boxd machine connect` wakes a paused machine.
    public static let pausedMarkerSuffix = ".paused"

    /// Where the terminal looks for the marker of a session.
    private func readyMarkerPath(_ sessionName: String) -> String {
        "\(localKanbanHome)/remote-ready/\(sessionName)"
    }

    private func setPausedMarkers(machineName: String, paused: Bool) {
        let directory = "\(localKanbanHome)/remote-ready"
        for session in registry.sessionNames(on: machineName) {
            let path = "\(directory)/\(session)\(Self.pausedMarkerSuffix)"
            if paused {
                try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: path, contents: Data())
            } else {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
    }

    // MARK: - External resumes

    /// A machine the app paused can be running again through another path
    /// (`boxd machine resume` in a shell, a `connect` from elsewhere). The
    /// app follows: it reconnects the bridge and the card leaves its paused
    /// state, so proxied commands answer and the sidebar tells the truth.
    public func followExternalResumes() async {
        let targets = await reconnectTargets(pausedOnly: true)
        guard !targets.isEmpty, let listed = try? await boxd.listMachines() else { return }
        for name in Self.machinesToReconnect(paused: Set(targets.keys), listed: listed) {
            guard let target = targets[name] else { continue }
            await reconnect(machineName: name, target: target)
        }
    }

    /// Takes a machine out of standby because a person asked for it: the
    /// card came into focus, or a click reached its terminal. It resumes,
    /// wakes or starts the machine, whatever state it is in, connects the
    /// bridge and clears the pause markers, so the terminal attaches again.
    /// Returns whether the machine is connected afterwards.
    public func resume(machineName: String) async -> Bool {
        if machines[machineName]?.bridge != nil { return true }
        guard let target = await reconnectTargets(pausedOnly: false)[machineName] else { return false }
        await report(machineName, state: .connecting)
        do {
            let settings = await settingsProvider()
            _ = try await ensureRunning(machineName: machineName, settings: settings, log: { _ in })
            try await connect(
                machineName: machineName,
                localProjectPath: target.localProjectPath,
                remoteProjectPath: target.remoteProjectPath,
                remoteHome: target.remoteHome)
        } catch {
            KanbanCodeLog.warn(Self.subsystem, "\(machineName): resume failed: \(error.localizedDescription)")
            peekPauseRequested.remove(machineName)
            if machines[machineName]?.pausedReason == nil {
                // The app never paused it: presumed running, keep trying.
                await report(machineName, state: .reconnecting(attempt: 1))
                Task { [weak self] in await self?.reconnect(machineName: machineName) }
            } else {
                await report(machineName, state: .unreachable)
            }
            return false
        }
        machines[machineName]?.resumedForPeek = await !isHost(machineName)
        // The card lost focus while the machine was still coming back.
        if peekPauseRequested.remove(machineName) != nil {
            await pauseIfPeek(machineName: machineName)
            return false
        }
        return machines[machineName]?.bridge != nil
    }

    /// Brings the machine of a session back for a prompt. The prompt is work,
    /// so the machine is not on approval afterwards: it keeps the normal idle
    /// window. Returns true when the machine is connected, or when the
    /// session is not on a machine at all.
    public func resumeMachine(forSession sessionName: String) async -> Bool {
        guard let machineName = registry.machine(forSession: sessionName) else { return true }
        if machines[machineName]?.bridge != nil { return true }
        KanbanCodeLog.info(Self.subsystem, "\(machineName): resuming for a prompt to \(sessionName)")
        guard await resume(machineName: machineName) else { return false }
        touch(machineName)
        return true
    }

    /// Stops a machine a person brought back but did nothing with. The card
    /// that leaves focus calls it, so a quick look at a session costs the
    /// seconds it took, not the whole idle window. A machine with work on it,
    /// or one that was already running before the look, is left alone.
    public func pauseIfPeek(machineName: String) async {
        guard let runtime = machines[machineName], runtime.resumedForPeek else {
            // Still coming back: stop it as soon as it is here.
            if machines[machineName]?.pausedReason == nil, machines[machineName]?.bridge == nil {
                peekPauseRequested.insert(machineName)
            }
            return
        }
        guard runtime.bridge != nil else { return }
        if let busyCheck, await busyCheck(machineName) {
            machines[machineName]?.resumedForPeek = false
            return
        }
        KanbanCodeLog.info(Self.subsystem, "\(machineName): looked at with no work, stopping again")
        await stop(machineName: machineName, reason: .inactivity)
    }

    /// Reconnects one machine without a bridge when boxd reports it running,
    /// for the terminal, which knows the machine answers before the next
    /// tick does. Returns whether the machine is connected afterwards.
    public func reconnectIfRunning(machineName: String) async -> Bool {
        if machines[machineName]?.bridge != nil { return true }
        guard let target = await reconnectTargets(pausedOnly: false)[machineName],
              let machine = try? await boxd.getMachine(name: machineName),
              machine.status == .running else { return false }
        await reconnect(machineName: machineName, target: target)
        return machines[machineName]?.bridge != nil
    }

    private struct ReconnectTarget {
        let localProjectPath: String
        let remoteProjectPath: String?
        let remoteHome: String
    }

    /// The machines without a bridge, from the runtimes and from the links
    /// of cards paused before this app run, which have no runtime yet.
    private func reconnectTargets(pausedOnly: Bool) async -> [String: ReconnectTarget] {
        var targets: [String: ReconnectTarget] = [:]
        for (name, runtime) in machines where runtime.bridge == nil && (!pausedOnly || runtime.pausedReason != nil) {
            targets[name] = ReconnectTarget(
                localProjectPath: runtime.localProjectPath, remoteProjectPath: runtime.remoteProjectPath,
                remoteHome: runtime.remoteHome)
        }
        for link in await linksProvider?() ?? [] {
            guard let remote = link.remote, remote.mode == .boxd, !pausedOnly || remote.pausedReason != nil,
                  !link.manuallyArchived, machines[remote.machineName] == nil,
                  let projectPath = link.projectPath else { continue }
            targets[remote.machineName] = ReconnectTarget(
                localProjectPath: projectPath, remoteProjectPath: remote.remoteProjectPath,
                remoteHome: remote.remoteHome ?? Self.defaultRemoteHome)
        }
        return targets
    }

    private func reconnect(machineName: String, target: ReconnectTarget) async {
        KanbanCodeLog.info(Self.subsystem, "\(machineName): running outside the app, reconnecting")
        do {
            try await connect(
                machineName: machineName,
                localProjectPath: target.localProjectPath,
                remoteProjectPath: target.remoteProjectPath,
                remoteHome: target.remoteHome,
                keepActivityClock: true)
        } catch {
            KanbanCodeLog.warn(Self.subsystem, "\(machineName): reconnect failed: \(error.localizedDescription)")
        }
    }

    /// The paused machines boxd reports as running, in name order.
    public nonisolated static func machinesToReconnect(paused: Set<String>, listed: [BoxdMachine]) -> [String] {
        listed.filter { $0.status == .running && paused.contains($0.name) }.map(\.name).sorted()
    }

    // MARK: - Logins

    /// Every connected machine gets the login of this Mac, and a login a
    /// machine refreshed comes back to the Mac and on to the other machines.
    public func syncAllLogins() async {
        var pushedClaudeTo: [String] = []
        var accountMoves: [LoginMove] = []
        for (name, runtime) in machines.sorted(by: { $0.key < $1.key }) {
            guard let bridge = runtime.bridge else { continue }
            let sync = AssistantLoginSync(runner: bridge, store: loginStore, remoteHome: runtime.remoteHome, machineName: name, accounts: loginAccounts)
            for change in await sync.run() {
                if change.decision == .push, change.kind == .claude { pushedClaudeTo.append(name) }
                if change.accountChanged {
                    accountMoves.append(LoginMove(kind: change.kind, machineName: name, decision: change.decision))
                }
            }
        }
        let account = await loginStore.claudeAccount()
        let outcome = Self.loginNotices(
            previousAccountId: lastClaudeAccountId,
            account: account,
            pushedClaudeTo: pushedClaudeTo,
            accountMoves: accountMoves,
            time: Self.clockText(now()))
        lastClaudeAccountId = outcome.accountId
        for notice in outcome.notices {
            await dispatch?(.setNotice(notice, kind: .success))
        }
    }

    /// A login that moved between this Mac and a machine and replaced one of
    /// another account.
    public struct LoginMove: Equatable, Sendable {
        public let kind: AssistantLoginKind
        public let machineName: String
        public let decision: AssistantLogin.Decision
        public init(kind: AssistantLoginKind, machineName: String, decision: AssistantLogin.Decision) {
            self.kind = kind
            self.machineName = machineName
            self.decision = decision
        }
    }

    public struct LoginNoticeOutcome: Equatable, Sendable {
        public let notices: [String]
        public let accountId: String?
    }

    /// The notices of one tick. A token refresh keeps the account and stays
    /// quiet in both directions; only a change of account is told, with the
    /// time. The first observation of an account is not a switch.
    public nonisolated static func loginNotices(
        previousAccountId: String?,
        account: [String: Any]?,
        pushedClaudeTo: [String],
        accountMoves: [LoginMove],
        time: String
    ) -> LoginNoticeOutcome {
        var notices: [String] = []
        let accountId = account?["accountUuid"] as? String
        let macSwitched = previousAccountId != nil && accountId != nil && accountId != previousAccountId
        if macSwitched {
            let who = (account?["emailAddress"] as? String).map { " to \($0)" } ?? ""
            let sent: String
            switch pushedClaudeTo.count {
            case 0: sent = ""
            case 1: sent = ", sent to \(pushedClaudeTo[0])"
            default: sent = ", sent to \(pushedClaudeTo.count) machines"
            }
            notices.append("Claude login changed\(who) at \(time)\(sent)")
        }
        for move in accountMoves {
            switch move.decision {
            case .pull:
                notices.append("\(move.kind.displayName) login on \(move.machineName) is another account, this Mac switched to it at \(time)")
            case .push:
                // The Mac's own switch above already names the machines.
                if move.kind == .claude, macSwitched { continue }
                notices.append("\(move.kind.displayName) login on \(move.machineName) was another account, replaced by this Mac's at \(time)")
            case .none:
                break
            }
        }
        return LoginNoticeOutcome(notices: notices, accountId: accountId ?? previousAccountId)
    }

    nonisolated static func clockText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// Pauses machines that had no activity for the configured timeout.
    private func sweepOnTick() async {
        timerTicks += 1
        guard timerTicks % Self.sweepIntervalMinutes == 0 else { return }
        _ = await sweepIfPossible()
    }

    /// How long a machine that came back without the app keeps running when
    /// no work arrives. A machine somebody resumed gets these minutes to show
    /// activity; a machine that woke by itself goes back to standby at the
    /// next tick instead of buying another full timeout.
    public static let outsideResumeGrace: TimeInterval = 300

    /// The activity stamp of a machine that is running again outside the app.
    public nonisolated static func activityAfterOutsideResume(
        previous: Date, now: Date, timeout: TimeInterval, grace: TimeInterval
    ) -> Date {
        max(previous, now.addingTimeInterval(grace - timeout))
    }

    /// Every machine gets the same idle window, whether its card is open or
    /// not: an agent can be waiting on a watcher, a subagent or a review,
    /// with nothing on the screen to show for it. An idle machine is
    /// stopped, not paused: standby keeps its memory on the bill, and a
    /// card left for hours costs its disk only. Machines a quick pause put
    /// in standby (a peek, sleep) get the same treatment once the window
    /// passes them by.
    public func checkInactivity() async {
        let timeout = TimeInterval(await settingsProvider().inactivityTimeoutSeconds)
        let current = now()
        for (name, runtime) in machines where runtime.bridge != nil {
            guard current.timeIntervalSince(runtime.lastActivity) > timeout else { continue }
            if await isHost(name) { continue }
            if let busyCheck, await busyCheck(name) {
                touch(name)
                continue
            }
            KanbanCodeLog.info(Self.subsystem, "\(name): no activity for \(Int(timeout))s, stopping")
            await stop(machineName: name, reason: .inactivity)
        }
        for (name, runtime) in machines where runtime.bridge == nil {
            if await isHost(name) { continue }
            guard Self.shouldStopParked(
                pausedReason: runtime.pausedReason,
                machineHalted: runtime.machineHalted,
                idleFor: current.timeIntervalSince(runtime.lastActivity),
                timeout: timeout) else { continue }
            KanbanCodeLog.info(Self.subsystem, "\(name): in standby past the idle window, stopping")
            await stop(machineName: name, reason: runtime.pausedReason ?? .stopped)
        }
    }

    /// A parked machine (standby after a pause) past the idle window gets
    /// one stop. The stop keeps the original paused reason for the UI, so
    /// `machineHalted` is the marker that the stop already happened.
    nonisolated public static func shouldStopParked(
        pausedReason: RemotePausedReason?,
        machineHalted: Bool,
        idleFor: TimeInterval,
        timeout: TimeInterval
    ) -> Bool {
        guard let pausedReason, pausedReason != .stopped, !machineHalted else { return false }
        return idleFor > timeout
    }

    // MARK: - Reporting

    private func report(_ machineName: String, state: RemoteMachineState) async {
        if registry.state(of: machineName) != state, state != .connected {
            registry.setMachine(machineName, state: state)
        }
        await dispatch?(.remoteMachineStateChanged(machineName: machineName, state: state))
    }

    // MARK: - Uploads

    /// Small payloads ride the bridge; large ones go through `boxd machine cp`
    /// so one JSON line never carries megabytes. The agent holds the path
    /// while the bytes land, and takes them as already on the Mac after.
    private func upload(
        machineName: String, bridge: BoxdBridge, remotePath: String, data: Data,
        onEvent: @escaping @Sendable (BoxdUploadEvent) -> Void = { _ in }
    ) async throws {
        try await bridge.hold(path: remotePath)
        do {
            if data.count <= 2 * 1024 * 1024 {
                try await bridge.put(path: remotePath, data: data, mode: nil)
            } else {
                _ = try await bridge.exec(["mkdir", "-p", (remotePath as NSString).deletingLastPathComponent], stdin: nil, cwd: nil, timeout: 60)
                try await boxd.upload(name: machineName, remotePath: remotePath, data: data, onEvent: onEvent)
            }
        } catch {
            try? await bridge.release(path: remotePath, offset: nil)
            throw error
        }
        try? await bridge.release(path: remotePath, offset: data.count)
    }

    /// Adds bytes to the end of a file on the machine: the delta lands on its
    /// own name and one `cat` folds it in, so a broken transfer never leaves
    /// a half-written transcript.
    private func append(
        machineName: String, bridge: BoxdBridge, remotePath: String, data: Data,
        onEvent: @escaping @Sendable (BoxdUploadEvent) -> Void = { _ in }
    ) async throws {
        let incoming = "\(remotePath).delta-\(UUID().uuidString.prefix(8))"
        try await bridge.hold(path: remotePath)
        do {
            if data.count <= 2 * 1024 * 1024 {
                try await bridge.put(path: incoming, data: data, mode: nil)
            } else {
                try await boxd.upload(name: machineName, remotePath: incoming, data: data, onEvent: onEvent)
            }
            _ = try await bridge.exec(
                ["sh", "-c", "cat \"$1\" >> \"$2\" && rm -f \"$1\"", "sh", incoming, remotePath],
                stdin: nil, cwd: nil, timeout: 60)
        } catch {
            _ = try? await bridge.exec(["rm", "-f", incoming], stdin: nil, cwd: nil, timeout: 30)
            try? await bridge.release(path: remotePath, offset: nil)
            throw error
        }
        let size = try? await bridge.exec(["stat", "-c", "%s", remotePath], stdin: nil, cwd: nil, timeout: 30)
        let total = Int(size?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        try? await bridge.release(path: remotePath, offset: total ?? 0)
    }

    private nonisolated static func rewrite(_ data: Data, with rewriter: TranscriptPathRewriter) -> Data {
        guard let text = String(data: data, encoding: .utf8) else { return data }
        let endsWithNewline = text.hasSuffix("\n")
        var lines = text.components(separatedBy: "\n")
        if endsWithNewline { lines.removeLast() }
        return Data((lines.map(rewriter.rewriteLine).joined(separator: "\n") + (endsWithNewline ? "\n" : "")).utf8)
    }

    // MARK: - Git helpers

    /// The repository root of a path, walking up out of a worktree.
    public nonisolated static func repositoryRoot(of path: String) -> String {
        if let range = path.range(of: "/.claude/worktrees/") {
            return String(path[..<range.lowerBound])
        }
        return path
    }

    private nonisolated static func git(_ arguments: [String], in directory: String) async -> ShellCommand.Result? {
        let gitPath = ShellCommand.findExecutable("git") ?? "/usr/bin/git"
        return try? await ShellCommand.run(gitPath, arguments: arguments, currentDirectory: directory, timeout: 120)
    }

    nonisolated static func originURL(of repoRoot: String) async -> String? {
        guard let result = await git(["remote", "get-url", "origin"], in: repoRoot), result.succeeded else { return nil }
        let url = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return url.isEmpty ? nil : url
    }

    nonisolated static func currentBranch(of repoRoot: String) async -> String? {
        guard let result = await git(["rev-parse", "--abbrev-ref", "HEAD"], in: repoRoot), result.succeeded else { return nil }
        let branch = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return branch.isEmpty || branch == "HEAD" ? nil : branch
    }

    /// Creates `<repo>/.claude/worktrees/<name>`, the layout Claude Code's
    /// `--worktree` uses. A card that ran on a machine has its branch on
    /// origin when the assistant pushed it, so that branch is tracked when
    /// it exists; otherwise the worktree starts a new branch.
    public nonisolated static func createLocalWorktree(repoRoot: String, name: String) async throws -> WorktreeLink {
        guard !name.isEmpty, !name.contains("/") else {
            throw WorktreeError.createFailed(name: name, message: "worktree name must be one non-empty path component")
        }
        let path = "\(repoRoot)/.claude/worktrees/\(name)"
        if FileManager.default.fileExists(atPath: path) {
            let branch = await currentBranch(of: path) ?? name
            return WorktreeLink(path: path, branch: branch)
        }
        try? FileManager.default.createDirectory(atPath: "\(repoRoot)/.claude/worktrees", withIntermediateDirectories: true)
        let arguments: [String]
        if (await git(["show-ref", "--verify", "--quiet", "refs/heads/\(name)"], in: repoRoot))?.succeeded == true {
            arguments = ["worktree", "add", path, name]
        } else {
            _ = await git(["fetch", "origin", name], in: repoRoot)
            if (await git(["show-ref", "--verify", "--quiet", "refs/remotes/origin/\(name)"], in: repoRoot))?.succeeded == true {
                arguments = ["worktree", "add", "--track", "-b", name, path, "origin/\(name)"]
            } else {
                arguments = ["worktree", "add", "-b", name, path]
            }
        }
        guard let result = await git(arguments, in: repoRoot), result.succeeded else {
            throw WorktreeError.createFailed(name: name, message: (await git(arguments, in: repoRoot))?.stderr ?? "git failed")
        }
        return WorktreeLink(path: path, branch: name)
    }

    /// The worktree script of the machine. A worktree that is already there
    /// is left as the assistant left it, with no network access. A new
    /// worktree branches from the checkout as it is; `fetch` is for a branch
    /// the card already has, which may only exist on origin.
    nonisolated static func remoteWorktreeScript(repo: String, worktreePath: String, branch: String, fetch: Bool = true) -> String {
        let repoQ = shellEscape(repo)
        let worktreeQ = shellEscape(worktreePath)
        let branchQ = shellEscape(branch)
        let fetchLine = fetch ? "  git fetch origin \(branchQ) || true\n" : ""
        return """
        set -e
        cd \(repoQ)
        if [ ! -d \(worktreeQ) ]; then
        \(fetchLine)  mkdir -p "$(dirname \(worktreeQ))"
          if git show-ref --verify --quiet refs/heads/\(branchQ); then
            git worktree add \(worktreeQ) \(branchQ)
          elif git show-ref --verify --quiet refs/remotes/origin/\(branchQ); then
            git worktree add --track -b \(branchQ) \(worktreeQ) origin/\(branchQ)
          else
            git worktree add -b \(branchQ) \(worktreeQ)
          fi
        fi
        """
    }

    nonisolated static func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Lets the first of several racing tasks resume a continuation, once.
private final class FirstToFinish: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
