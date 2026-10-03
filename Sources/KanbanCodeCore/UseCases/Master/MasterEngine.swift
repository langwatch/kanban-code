import Foundation
import KanbanCodeRemoteKit

/// The master engine: launches and resumes cards, runs the loops that keep
/// them in step (hooks, reconcile, self-compact, the live model), and
/// creates cards for the remote API. The Mac app drives it from its views
/// and a headless master (`kanban-code-server`) from its main loop, so both
/// run the same code.
@MainActor
public final class MasterEngine {
    public let store: BoardStore
    public let settingsStore: SettingsStore
    public let launcher: LaunchSession
    public let tmux: RoutingTmuxAdapter
    /// Boxd and ssh machines; nil where the master runs everything itself.
    public let boxdSupervisor: BoxdMachineSupervisor?
    public let mutagen: MutagenAdapter
    public let registry: CodingAssistantRegistry
    public var platform: MasterPlatform

    /// Cards with a resume in flight. A resume is long (machine creation,
    /// a transcript push); a second one for the same card must not start.
    private var resumingCards: Set<String> = []

    /// Self-compact bookkeeping, by session id.
    var selfCompactTriggeredThresholds: [String: Set<Int>] = [:]
    var selfCompactPolicySignatures: [String: String] = [:]

    /// Handovers this master runs, by card id, so each runs once.
    var handoversInFlight: Set<String> = []
    /// First launches handed to a peer, served with the handover info.
    var pendingPeerLaunches: [String: PeerLaunch] = [:]
    /// Cards this master released, as they were at the release, until the
    /// new owner adopts them.
    var releasedCards: [String: Link] = [:]
    /// Prompts added on a card another master owns and already sent there.
    var forwardedPromptIds: Set<String> = []

    /// Card sync with the other masters; nil when there are none.
    public var peerSync: PeerSync?

    /// Delivers attention requests to the Mac and the phone; nil until the
    /// app or the server sets it up.
    public var attentionCenter: AttentionCenter?
    /// What the attention scan last saw of each transcript, by path.
    var attentionScanMarks: [String: AttentionScanMark] = [:]

    /// What a card's new local session gets in its environment for the
    /// vault (the card id and a fresh session token); nil without a vault.
    public var cardSessionEnvironment: (@Sendable (String) async -> [String: String])?
    /// Hands the vault what a device unlocked for an approval, before the
    /// request resolves.
    public var vaultUnsealed: (@Sendable (String, VaultUnsealed) async -> Void)?

    /// Wakes the channels mirror after a channel write.
    let channelsPoke = AsyncSignal()
    /// Display name of the channels home while it is another master.
    public internal(set) var channelsHomeName: String?

    /// The side chats (`/btw`, `/catchup`) running for this master's cards.
    public lazy var sideChat = SideChatService(runner: ClaudeSideChatRunner(kanbanHome: platform.kanbanHome))
    /// What the human typed and sent from a Kanban chat, by card.
    public lazy var humanMessages = HumanMessageLog(kanbanHome: platform.kanbanHome)
    /// Each card's last catch-up, shown again while the session has nothing new.
    public lazy var catchUps = CatchUpKeep(kanbanHome: platform.kanbanHome)

    /// The inbox of the `kanban` commands the CLI hands to this master.
    public lazy var subagentCommands = SubagentCommandStore(
        baseURL: URL(fileURLWithPath: platform.kanbanHome).appendingPathComponent("commands", isDirectory: true))

    public init(
        store: BoardStore,
        settingsStore: SettingsStore,
        launcher: LaunchSession,
        tmux: RoutingTmuxAdapter,
        boxdSupervisor: BoxdMachineSupervisor? = nil,
        mutagen: MutagenAdapter = MutagenAdapter(),
        registry: CodingAssistantRegistry,
        platform: MasterPlatform = MasterPlatform()
    ) {
        self.store = store
        self.settingsStore = settingsStore
        self.launcher = launcher
        self.tmux = tmux
        self.boxdSupervisor = boxdSupervisor
        self.mutagen = mutagen
        self.registry = registry
        self.platform = platform
    }

    // MARK: - Launch

    /// Starts a card's first session. The card goes to launching at once;
    /// `completion` gets nil once the session runs, or the error.
    public func launch(
        cardId: String,
        prompt: String,
        projectPath: String,
        worktreeName: String?,
        runRemotely: Bool = true,
        skipPermissions: Bool = true,
        commandOverride: String? = nil,
        images: [ImageAttachment] = [],
        assistant: CodingAssistant = .claude,
        serviceIdOverride: String? = nil,
        modelOverride: String? = nil,
        machineChoice: BoxdMachineChoice? = nil,
        keepSelection: Bool = false,
        humanPrompt: Bool = false,
        completion: ((String?) -> Void)? = nil
    ) {
        if humanPrompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // The first prompt is one the human typed: it joins the card's record.
            let log = humanMessages
            Task.detached { log.append(cardId: cardId, HumanMessageRecord(text: prompt)) }
        }
        if isForeign(cardId) {
            // The master that owns the card starts it.
            forwardToOwner(cardId, "start the card", isStart: true) { client in _ = try await client.resume(cardId: cardId) }
            completion?(nil)
            return
        }
        if let moving = stillMovingHere(cardId) {
            // Its project is still the releasing master's; the adoption
            // launches it here once the card has arrived.
            KanbanCodeLog.info("launch", "Launch of card=\(cardId.prefix(12)) deferred: \(moving)")
            completion?(moving)
            return
        }
        if runRemotely, let name = machineChoice?.machineName, let peer = peerMachine(named: name) {
            // Another master runs it: the card moves there and starts there.
            launchOnPeer(cardId: cardId, prompt: prompt, worktree: worktreeName, peer: peer)
            completion?(nil)
            return
        }
        let previouslySelectedCardId = store.state.selectedCardId
        store.dispatch(.launchCard(cardId: cardId, prompt: prompt, projectPath: projectPath, worktreeName: worktreeName, runRemotely: runRemotely, commandOverride: commandOverride))
        if keepSelection { store.dispatch(.selectCard(cardId: previouslySelectedCardId)) }
        let effectiveModelOverride = modelOverride ?? store.state.links[cardId]?.modelOverride
        // The reducer computed the unique tmux name and stored it in the link.
        let predictedTmuxName = store.state.links[cardId]?.tmuxLink?.sessionName ?? cardId
        KanbanCodeLog.info("launch", "Starting launch for card=\(cardId.prefix(12)) tmux=\(predictedTmuxName) project=\(projectPath)")
        // A marker from an earlier run of this session name would let the
        // terminal attach before the machine is ready.
        platform.clearRemoteSessionReady(predictedTmuxName)
        if runRemotely, store.state.remoteMode.runsOnMachines, boxdSupervisor != nil {
            platform.expectRemoteSession(predictedTmuxName)
        }
        let progress = LaunchProgress(cardId: cardId, store: store)

        Task {
            defer { progress.finish() }
            do {
                let settings = try? await settingsStore.read()

                let shellOverride: String?
                let extraEnv: [String: String]
                let isRemote: Bool
                let preamble: String?
                // Where the assistant starts and which worktree flag it gets.
                // On a boxd machine the app creates the worktree itself.
                var launchPath = projectPath
                var launchWorktreeName = assistant.supportsWorktree ? worktreeName : nil
                var boxdPreparation: BoxdPreparation?

                let cardLink = store.state.cards.first(where: { $0.id == cardId })?.link
                let globalRemote = settings?.remote
                let remoteMode = settings?.remoteMode ?? .ssh
                if runRemotely, remoteMode.runsOnMachines, let boxdSupervisor {
                    let existingMachine = machineChoice?.machineName
                        ?? (machineChoice == nil ? cardLink?.remote?.machineName : nil)
                    progress.start()
                    let preparation = try await boxdSupervisor.prepare(
                        cardId: cardId,
                        localProjectPath: projectPath,
                        existingMachine: existingMachine,
                        worktreeName: worktreeName,
                        existingWorktree: cardLink?.worktreeLink,
                        sessionNames: [predictedTmuxName],
                        log: { line in progress.report(line) }
                    )
                    progress.report("Starting \(assistant.displayName) on \(preparation.machineName)")
                    boxdPreparation = preparation
                    shellOverride = nil
                    extraEnv = preparation.extraEnv
                    isRemote = true
                    preamble = BoxdMachineSupervisor.sessionPreamble
                    launchPath = preparation.remoteCwd
                    launchWorktreeName = nil
                } else if runRemotely, let remote = globalRemote, projectPath.hasPrefix(remote.localPath) {
                    let mutagenSetup = await mutagenEnvironment(remote: remote, projectPath: projectPath, assistant: assistant)
                    shellOverride = mutagenSetup.0
                    extraEnv = mutagenSetup.1
                    preamble = mutagenSetup.2
                    isRemote = true
                } else {
                    shellOverride = nil
                    extraEnv = [:]
                    isRemote = false
                    preamble = nil
                }
                let commandTemplate = settings?.commandTemplate(for: assistant, remote: isRemote)

                // Resolve API service for this card and inject base URL env var if needed
                let resolvedServiceId = serviceIdOverride ?? cardLink?.apiServiceId ?? settings?.defaultAPIServiceIds[assistant.rawValue]
                let resolvedService = resolvedServiceId.flatMap { sid in
                    settings?.apiServices.first { $0.id == sid && $0.assistant == assistant }
                }
                var serviceExtraEnv = extraEnv
                if let svc = resolvedService,
                   let envKey = assistant.baseURLEnvKey,
                   let url = svc.baseURL, !url.isEmpty {
                    serviceExtraEnv[envKey] = url
                }
                if let parentEnv = Self.subagentCacheEnv(parentCardId: cardLink?.parentCardId, assistant: assistant) {
                    serviceExtraEnv.merge(parentEnv) { _, new in new }
                }
                serviceExtraEnv.merge(platform.sessionEnvironment) { current, _ in current }
                // The vault runs on this master: only a session on this
                // machine can use its token.
                if !isRemote, let cardSessionEnvironment {
                    serviceExtraEnv.merge(await cardSessionEnvironment(cardId)) { _, new in new }
                }

                if boxdPreparation == nil,
                   rushChoice(settings: settings, assistant: assistant, remote: isRemote, commandOverride: commandOverride) == .rush {
                    var cwd = projectPath
                    var worktreeLink: WorktreeLink?
                    if let worktreeName {
                        let name = worktreeName.isEmpty ? BoxdLaunchPlanner.randomWorktreeName() : worktreeName
                        progress.report("Creating worktree \(name)")
                        let worktree = try await BoxdMachineSupervisor.createLocalWorktree(repoRoot: projectPath, name: name)
                        cwd = worktree.path
                        worktreeLink = worktree
                    }
                    let sessionId = UUID().uuidString.lowercased()
                    let name = try await startOnRush(
                        cardId: cardId,
                        cwd: cwd,
                        sessionId: sessionId,
                        resume: false,
                        prompt: prompt,
                        images: images,
                        extraEnv: serviceExtraEnv,
                        skipPermissions: skipPermissions,
                        model: effectiveModelOverride,
                        commandTemplate: commandTemplate,
                        service: resolvedService,
                        human: humanPrompt
                    )
                    let sessionLink = SessionLink(
                        sessionId: sessionId,
                        sessionPath: transcriptPath(cwd: cwd, sessionId: sessionId)
                    )
                    store.dispatch(.launchCompleted(cardId: cardId, tmuxName: name, sessionLink: sessionLink, worktreeLink: worktreeLink, isRemote: false))
                    completion?(nil)
                    return
                }

                if let preparation = boxdPreparation,
                   let machineRush = await machineRush(
                       machineName: preparation.machineName, settings: settings, assistant: assistant,
                       commandOverride: commandOverride, service: resolvedService) {
                    let sessionId = UUID().uuidString.lowercased()
                    let name = try await startOnRush(
                        cardId: cardId,
                        cwd: preparation.remoteCwd,
                        sessionId: sessionId,
                        resume: false,
                        prompt: prompt,
                        images: images,
                        extraEnv: serviceExtraEnv,
                        skipPermissions: skipPermissions,
                        model: effectiveModelOverride,
                        commandTemplate: nil,
                        service: resolvedService,
                        rush: machineRush,
                        human: humanPrompt
                    )
                    await boxdSupervisor?.assignSession(name, to: preparation.machineName)
                    platform.markRemoteSessionReady(name, preparation.machineName)
                    let localCwd = BoxdLaunchPlanner.localPath(
                        ofRemote: preparation.remoteCwd, remoteRoot: preparation.remoteProjectPath,
                        localRoot: BoxdMachineSupervisor.repositoryRoot(of: projectPath))
                    let sessionLink = SessionLink(sessionId: sessionId, sessionPath: transcriptPath(cwd: localCwd, sessionId: sessionId))
                    store.dispatch(.launchCompleted(cardId: cardId, tmuxName: name, sessionLink: sessionLink, worktreeLink: preparation.worktree, isRemote: true))
                    completion?(nil)
                    return
                }

                // Snapshot existing session files for detection
                let sessionFileExt = ".\(assistant.sessionFileExtension)"
                let configDir = (NSHomeDirectory() as NSString).appendingPathComponent(assistant.configDirName)
                let claudeProjectsDir = (configDir as NSString).appendingPathComponent("projects")
                let encodedProject = SessionFileMover.encodeProjectPath(projectPath)
                let sessionDir = (claudeProjectsDir as NSString).appendingPathComponent(encodedProject)
                let existingCodexFiles = assistant == .codex
                    ? Set(CodexSessionDiscovery.sessionFiles())
                    : []

                // When worktree is enabled, also snapshot worktree-related directories
                // (worktrees create sessions in dirs like <encodedProject>-.claude-worktrees-<name>)
                let dirsToSnapshot: [String]
                if assistant == .gemini {
                    // Gemini stores sessions in ~/.gemini/tmp/<slug>/chats/
                    let tmpDir = (configDir as NSString).appendingPathComponent("tmp")
                    let slugDirs = (try? FileManager.default.contentsOfDirectory(atPath: tmpDir)) ?? []
                    dirsToSnapshot = slugDirs.map { slug in
                        (tmpDir as NSString).appendingPathComponent(slug).appending("/chats")
                    }
                } else if assistant == .codex {
                    // Codex stores sessions recursively under ~/.codex/sessions.
                    dirsToSnapshot = []
                } else if worktreeName != nil {
                    let allDirs = (try? FileManager.default.contentsOfDirectory(atPath: claudeProjectsDir)) ?? []
                    dirsToSnapshot = [sessionDir] + allDirs
                        .filter { $0.hasPrefix(encodedProject) && $0 != encodedProject }
                        .map { (claudeProjectsDir as NSString).appendingPathComponent($0) }
                } else {
                    dirsToSnapshot = [sessionDir]
                }
                var existingFilesByDir: [String: Set<String>] = [:]
                for dir in dirsToSnapshot {
                    existingFilesByDir[dir] = Set(
                        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
                            .filter { $0.hasSuffix(sessionFileExt) }
                    )
                }

                let tmuxName = try await launcher.launch(
                    sessionName: predictedTmuxName,
                    projectPath: launchPath,
                    prompt: prompt,
                    worktreeName: launchWorktreeName,
                    shellOverride: shellOverride,
                    extraEnv: serviceExtraEnv,
                    commandOverride: commandOverride,
                    commandTemplate: commandTemplate,
                    skipPermissions: skipPermissions,
                    preamble: preamble,
                    assistant: assistant,
                    service: resolvedService,
                    modelOverride: effectiveModelOverride
                )
                KanbanCodeLog.info("launch", "Tmux session created: \(tmuxName)")
                if let preparation = boxdPreparation, let boxdSupervisor {
                    await boxdSupervisor.exportSessionEnvironment(
                        machineName: preparation.machineName, sessionName: tmuxName, env: preparation.extraEnv)
                    platform.markRemoteSessionReady(tmuxName, preparation.machineName)
                }

                // Show terminal immediately — clear isLaunching so UI switches
                // from spinner to terminal view without waiting for session detection.
                store.dispatch(.launchTmuxReady(cardId: cardId))

                // Send images + prompt via send-keys after assistant is ready.
                // Once tmux exists, prompt delivery is best-effort: a readiness
                // timeout must not turn a live Codex session into a failed launch.
                var promptDeliveryError: String?
                if !prompt.isEmpty || !images.isEmpty {
                    do {
                        let imageSender = ImageSender(tmux: tmux)
                        try await imageSender.waitForReady(sessionName: tmuxName, assistant: assistant)

                        if let preparation = boxdPreparation, !images.isEmpty {
                            // The clipboard does not reach the machine: the
                            // images go over the bridge and the prompt points
                            // at them by path.
                            let remotePaths = try await uploadPromptImages(
                                images, cardId: cardId, preparation: preparation)
                            let promptToSend = PromptImageLayout.replacingMarkersWithMarkdown(in: prompt, imagePaths: remotePaths)
                            if assistant.submitsPromptWithPaste {
                                try await tmux.pastePrompt(to: tmuxName, text: promptToSend)
                            } else {
                                try await tmux.sendPrompt(to: tmuxName, text: promptToSend)
                            }
                        } else if !images.isEmpty && assistant.supportsImageUpload, let setClipboard = platform.setClipboardImage {
                            try await imageSender.sendPromptWithImages(
                                sessionName: tmuxName,
                                prompt: prompt,
                                images: images,
                                assistant: assistant,
                                setClipboard: setClipboard
                            )
                        } else if !prompt.isEmpty {
                            let imagePaths = images.compactMap { image -> String? in
                                if let tempPath = image.tempPath { return tempPath }
                                var copy = image
                                return try? copy.saveToTemp()
                            }
                            let promptToSend = PromptImageLayout.replacingMarkersWithMarkdown(in: prompt, imagePaths: imagePaths)
                            if assistant.submitsPromptWithPaste {
                                try await tmux.pastePrompt(to: tmuxName, text: promptToSend)
                            } else {
                                try await tmux.sendPrompt(to: tmuxName, text: promptToSend)
                            }
                        }
                    } catch {
                        promptDeliveryError = error.localizedDescription
                        KanbanCodeLog.warn("launch", "Initial prompt delivery failed for card=\(cardId.prefix(12)) tmux=\(tmuxName): \(error.localizedDescription)")
                    }
                }

                // Detect new session by polling for new session file
                // Worktree launches, Gemini, and Codex need more attempts (slower startup)
                // A remote session shows up after the bridge streams its first
                // lines, so it gets the longest window.
                let maxAttempts = boxdPreparation != nil ? 30
                    : (worktreeName != nil || assistant == .gemini || assistant == .codex) ? 12 : 6
                var sessionLink: SessionLink?
                for attempt in 0..<maxAttempts {
                    try? await Task.sleep(for: .milliseconds(500))

                    if assistant == .codex {
                        let currentFiles = Set(CodexSessionDiscovery.sessionFiles())
                        let newFiles = currentFiles.subtracting(existingCodexFiles)
                        if let sessionPath = Self.newestFile(from: Array(newFiles)),
                           let sessionId = await CodexSessionParser.extractSessionId(from: sessionPath) {
                            KanbanCodeLog.info("launch", "Detected Codex session file after \(attempt+1) attempts: \(sessionId.prefix(8))")
                            sessionLink = SessionLink(sessionId: sessionId, sessionPath: sessionPath)
                            break
                        }
                        continue
                    }

                    // Build list of dirs to scan (re-list for worktree — dir may appear mid-poll)
                    let dirsToScan: [String]
                    if assistant == .gemini {
                        let tmpDir = (configDir as NSString).appendingPathComponent("tmp")
                        let slugDirs = (try? FileManager.default.contentsOfDirectory(atPath: tmpDir)) ?? []
                        dirsToScan = slugDirs.map { slug in
                            (tmpDir as NSString).appendingPathComponent(slug).appending("/chats")
                        }
                    } else if worktreeName != nil {
                        let allDirs = (try? FileManager.default.contentsOfDirectory(atPath: claudeProjectsDir)) ?? []
                        dirsToScan = allDirs
                            .filter { $0.hasPrefix(encodedProject) }
                            .map { (claudeProjectsDir as NSString).appendingPathComponent($0) }
                    } else {
                        dirsToScan = [sessionDir]
                    }

                    for dir in dirsToScan {
                        let baseline = existingFilesByDir[dir] ?? [] // empty for newly-created dirs
                        let currentFiles = Set(
                            ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
                                .filter { $0.hasSuffix(sessionFileExt) }
                        )
                        if let newFile = currentFiles.subtracting(baseline).first {
                            let sessionId: String
                            if assistant == .gemini {
                                // Gemini: extract sessionId from inside the JSON file
                                let filePath = (dir as NSString).appendingPathComponent(newFile)
                                if let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
                                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                                   let sid = obj["sessionId"] as? String {
                                    sessionId = sid
                                } else {
                                    sessionId = (newFile as NSString).deletingPathExtension
                                }
                            } else {
                                sessionId = (newFile as NSString).deletingPathExtension
                            }
                            let sessionPath = (dir as NSString).appendingPathComponent(newFile)
                            KanbanCodeLog.info("launch", "Detected session file after \(attempt+1) attempts in \((dir as NSString).lastPathComponent): \(sessionId.prefix(8))")
                            sessionLink = SessionLink(sessionId: sessionId, sessionPath: sessionPath)
                            break
                        }
                    }
                    if sessionLink != nil { break }
                }

                // If worktree launch, try to extract branch from the session file immediately
                var worktreeLink: WorktreeLink? = boxdPreparation?.worktree
                if worktreeLink == nil, worktreeName != nil, let sl = sessionLink, let sp = sl.sessionPath {
                    worktreeLink = Self.extractWorktreeLink(sessionPath: sp, projectPath: projectPath)
                }

                store.dispatch(.launchCompleted(cardId: cardId, tmuxName: tmuxName, sessionLink: sessionLink, worktreeLink: worktreeLink, isRemote: isRemote))
                if let promptDeliveryError, assistant.supportsImageUpload && !images.isEmpty {
                    store.dispatch(.setError("Initial prompt/image delivery failed: \(promptDeliveryError)"))
                }
                completion?(promptDeliveryError)
            } catch {
                KanbanCodeLog.error("launch", "Launch failed for card=\(cardId.prefix(12)): \(error.localizedDescription)")
                store.dispatch(.launchFailed(cardId: cardId, error: BoxdCliAdapter.shortMessage(of: error)))
                completion?(error.localizedDescription)
            }
        }
    }

    /// The shell override, environment and preamble of a mutagen launch.
    private func mutagenEnvironment(remote: RemoteSettings, projectPath: String, assistant: CodingAssistant) async -> (String?, [String: String], String?) {
        try? RemoteShellManager.deploy()
        let shellOverride = RemoteShellManager.shellOverridePath()
        var env = RemoteShellManager.setupEnvironment(remote: remote, projectPath: projectPath)
        // Some CLIs use `bash -c` directly, so prepend our remote
        // dir to PATH so they find Kanban's bash wrapper first.
        if assistant.requiresRemotePathWrapper {
            let remoteDir = RemoteShellManager.remoteDirPath()
            env["PATH"] = "\(remoteDir):$PATH"
        }
        let remoteDest = "\(remote.host):\(remote.remotePath)"
        let ignores = remote.syncIgnores ?? MutagenAdapter.defaultIgnores
        try? await mutagen.startSync(
            localPath: remote.localPath,
            remotePath: remoteDest,
            name: "kanban-code-sync",
            ignores: ignores
        )
        return (shellOverride, env, Self.remotePreamble(host: remote.host))
    }

    /// Writes prompt images to the machine and returns their paths there.
    public func uploadPromptImages(_ images: [ImageAttachment], cardId: String, preparation: BoxdPreparation) async throws -> [String] {
        guard let bridge = await boxdSupervisor?.bridge(for: preparation.machineName) else {
            throw BoxdSupervisorError.notConnected(preparation.machineName)
        }
        var paths: [String] = []
        for (index, image) in images.enumerated() {
            let localPath: String
            if let tempPath = image.tempPath {
                localPath = tempPath
            } else {
                var copy = image
                localPath = try copy.saveToTemp()
            }
            guard let data = FileManager.default.contents(atPath: localPath) else { continue }
            let ext = (localPath as NSString).pathExtension.isEmpty ? "png" : (localPath as NSString).pathExtension
            let remotePath = "\(preparation.remoteHome)/.kanban-code/images/\(cardId)/\(index + 1).\(ext)"
            try await bridge.put(path: remotePath, data: data, mode: nil)
            paths.append(remotePath)
        }
        return paths
    }

    nonisolated static func newestFile(from paths: [String]) -> String? {
        paths.compactMap { path -> (String, Date)? in
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date else { return nil }
            return (path, mtime)
        }
        .max { $0.1 < $1.1 }?
        .0
    }

    /// Extract worktreeLink from a newly-created session file by reading its first line for gitBranch and cwd.
    public nonisolated static func extractWorktreeLink(sessionPath: String, projectPath: String) -> WorktreeLink? {
        // Read metadata from the first line of the .jsonl — it has the actual cwd and gitBranch
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: sessionPath)),
              let firstNewline = data.firstIndex(of: UInt8(ascii: "\n")),
              let firstLine = String(data: data[data.startIndex..<firstNewline], encoding: .utf8),
              let lineData = firstLine.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
            return nil
        }

        // Use the cwd from the session metadata — it has the exact worktree path
        // (avoids lossy decoding of the directory name which mangles dashes in worktree names)
        let worktreePath: String
        if let cwd = obj["cwd"] as? String,
           cwd.contains("/.claude/worktrees/") || cwd.contains("/.claude-worktrees/") {
            worktreePath = cwd
        } else {
            // Fallback: derive from directory name structure
            // suffix is like ".claude-worktrees-<name>" or "claude-worktrees-<name>"
            let sessionDir = (sessionPath as NSString).deletingLastPathComponent
            let dirName = (sessionDir as NSString).lastPathComponent
            let encodedProject = SessionFileMover.encodeProjectPath(projectPath)
            guard dirName.hasPrefix(encodedProject) else { return nil }
            let rest = String(dirName.dropFirst(encodedProject.count))
            // Match known pattern: [-.]claude-worktrees-<worktreeName>
            // Only convert the structural separators, keep worktree name dashes intact
            guard let wtRange = rest.range(of: "claude-worktrees-") else { return nil }
            let worktreeName = String(rest[wtRange.upperBound...])
            worktreePath = projectPath + "/.claude/worktrees/" + worktreeName
        }

        var branchName: String?
        if let branch = obj["gitBranch"] as? String {
            branchName = branch.replacingOccurrences(of: "refs/heads/", with: "")
        }

        // Fallback: extract worktree name from path
        if branchName == nil {
            let components = worktreePath.components(separatedBy: "/.claude/worktrees/")
            if components.count == 2 {
                branchName = components[1]
            }
        }

        guard let branchName, !branchName.isEmpty else { return nil }
        KanbanCodeLog.info("launch", "Extracted worktreeLink: branch=\(branchName) path=\(worktreePath)")
        return WorktreeLink(path: worktreePath, branch: branchName)
    }

    /// Subagents run on the 5-minute prompt cache tier. Their turns come in
    /// short bursts, and the default 1-hour cache bills every cache write at
    /// a higher rate, which makes a fleet of children far more expensive than
    /// plain Claude Code subagents. Claude Code reads this env var since
    /// v2.1.242; the other assistants ignore it, so it is only set for Claude.
    public nonisolated static func subagentCacheEnv(parentCardId: String?, assistant: CodingAssistant) -> [String: String]? {
        guard assistant == .claude, parentCardId != nil else { return nil }
        return ["CLAUDE_CODE_PROMPT_CACHE_TTL": "5m"]
    }

    /// A shell preamble that flushes mutagen and shows the remote uname before the assistant starts.
    public nonisolated static func remotePreamble(host: String) -> String {
        // Use ; instead of && so a flush failure doesn't block claude from starting
        "printf '\\e[2mSyncing files...\\e[0m' && mutagen sync flush --label-selector kanban=true 2>/dev/null; printf '\\e[2mRemote: %s\\e[0m\\n' \"$(ssh -o ConnectTimeout=5 \(host) uname -snr 2>/dev/null || echo 'unavailable')\""
    }

    // MARK: - Resume

    /// Starts a card's session again from its conversation, here or on a
    /// machine. Returns false when a resume of the card is already running.
    @discardableResult
    public func resume(
        cardId: String,
        runRemotely: Bool,
        skipPermissions: Bool = true,
        commandOverride: String?,
        assistant: CodingAssistant = .claude,
        serviceIdOverride: String? = nil,
        modelOverride: String? = nil,
        machineChoice: BoxdMachineChoice? = nil,
        keepSelection: Bool = false,
        afterDispatch: (() -> Void)? = nil
    ) -> Bool {
        guard let card = store.state.cards.first(where: { $0.id == cardId }) else { return false }
        if isForeign(cardId) {
            // The master that owns the card resumes it.
            forwardToOwner(cardId, "resume the card", isStart: true) { client in _ = try await client.resume(cardId: cardId) }
            return false
        }
        if let moving = stillMovingHere(cardId) {
            // Its paths are still the releasing master's and its transcript
            // is on the way; the adoption resumes it once both are here.
            KanbanCodeLog.info("resume", "Resume of card=\(cardId.prefix(12)) deferred: \(moving)")
            return false
        }
        if runRemotely,
           let name = machineChoice?.machineName ?? (machineChoice == nil ? card.link.remote?.machineName : nil),
           let peer = peerMachine(named: name) {
            // The machine runs a master: the card moves there and that
            // master continues the conversation, also while this one is off.
            // A card that ran there over ssh moves the same way.
            KanbanCodeLog.info("resume", "Card=\(cardId.prefix(12)) continues on \(peer.name), handing it over")
            afterDispatch?()
            Task {
                do {
                    try await handover(cardId: cardId, to: peer.id)
                } catch {
                    store.dispatch(.cardStartReported(
                        cardId: cardId, report: .failed("Could not continue on \(peer.name): \(error.localizedDescription)")))
                }
            }
            return true
        }
        let effectiveModelOverride = modelOverride ?? card.link.modelOverride
        let sessionId = card.link.sessionLink?.sessionId ?? card.link.id
        // For worktree cards, cd into the worktree — that's where Claude stored the session data.
        let projectPath: String
        if let worktreePath = card.link.worktreeLink?.path, !worktreePath.isEmpty {
            projectPath = worktreePath
        } else {
            projectPath = card.link.projectPath ?? NSHomeDirectory()
        }

        // If the session file lives under a different project key (e.g. a cleaned-up worktree),
        // move it to the current projectPath so `claude --resume` can find it.
        // Only applicable to Claude Code sessions (Gemini uses its own path scheme).
        if assistant == .claude,
           let sessionLink = card.link.sessionLink,
           let sessionPath = sessionLink.sessionPath {
            let expectedDir = platform.claudeProjectsDirectory + "/" + SessionFileMover.encodeProjectPath(projectPath)
            let expectedPath = expectedDir + "/" + sessionId + ".jsonl"
            if sessionPath != expectedPath,
               FileManager.default.fileExists(atPath: sessionPath) {
                KanbanCodeLog.info("resume", "Moving session file from worktree project key to \(expectedDir)")
                if let newPath = try? SessionFileMover.moveSession(
                    sessionId: sessionId, fromPath: sessionPath, toProjectPath: projectPath
                ) {
                    var updatedLink = card.link
                    updatedLink.sessionLink = SessionLink(sessionId: sessionId, sessionPath: newPath)
                    store.dispatch(.createManualTask(updatedLink))
                }
            }
        }

        // The terminal of the resumed session mounts as soon as the card
        // resumes, so a card that leaves its machine routes its names
        // locally first; otherwise the terminal would connect to the machine.
        if !runRemotely {
            let names = (card.link.tmuxLink?.allSessionNames ?? []) + ["\(assistant.cliCommand)-\(String(sessionId.prefix(8)))"]
            for name in names { platform.unassignRemoteSession(name) }
        }

        let previouslySelectedCardId = store.state.selectedCardId
        store.dispatch(.resumeCard(cardId: cardId))
        if keepSelection { store.dispatch(.selectCard(cardId: previouslySelectedCardId)) }
        afterDispatch?()
        // A second click while a resume runs would race the first one on the
        // machine: two transcript pushes to the same file corrupted each
        // other before this guard existed.
        guard resumingCards.insert(cardId).inserted else {
            KanbanCodeLog.info("resume", "Resume already running for card=\(cardId.prefix(12)), ignoring")
            return false
        }
        KanbanCodeLog.info("resume", "Starting resume for card=\(cardId.prefix(12)) session=\(sessionId.prefix(8))")
        let progress = LaunchProgress(cardId: cardId, store: store)

        Task {
            defer {
                progress.finish()
                resumingCards.remove(cardId)
            }
            do {
                let settings = try? await settingsStore.read()

                let shellOverride: String?
                let extraEnv: [String: String]
                let isRemote: Bool
                let preamble: String?
                var resumePath = projectPath
                var boxdPreparation: BoxdPreparation?
                let resumeSessionName = "\(assistant.cliCommand)-\(String(sessionId.prefix(8)))"
                platform.clearRemoteSessionReady(resumeSessionName)
                if runRemotely, store.state.remoteMode.runsOnMachines, boxdSupervisor != nil {
                    platform.expectRemoteSession(resumeSessionName)
                }

                let globalRemote = settings?.remote
                let remoteMode = settings?.remoteMode ?? .ssh
                if runRemotely, remoteMode.runsOnMachines, let boxdSupervisor {
                    let currentMachine = card.link.remote?.machineName
                    let existingMachine = machineChoice?.machineName
                        ?? (machineChoice == nil ? currentMachine : nil)
                    progress.start()
                    // A card that moves from this Mac to a machine ends its
                    // local session first, so the conversation never runs in
                    // two places, and the transcript it pushes is complete.
                    if !card.link.isRemote, let previous = card.link.tmuxLink?.sessionName,
                       platform.machineForSession(previous) == nil {
                        progress.report("Ending the session on this Mac")
                        KanbanCodeLog.info("resume", "Ending local session \(previous) before moving card=\(cardId.prefix(12)) to a machine")
                        try? await tmux.killSession(name: previous)
                    }
                    let preparation = try await boxdSupervisor.prepare(
                        cardId: cardId,
                        localProjectPath: projectPath,
                        existingMachine: existingMachine,
                        worktreeName: nil,
                        existingWorktree: card.link.worktreeLink,
                        sessionNames: [resumeSessionName],
                        runInit: existingMachine == nil || existingMachine != currentMachine,
                        log: { line in progress.report(line) }
                    )
                    boxdPreparation = preparation
                    shellOverride = nil
                    extraEnv = preparation.extraEnv
                    isRemote = true
                    preamble = BoxdMachineSupervisor.sessionPreamble
                    resumePath = preparation.remoteCwd

                    // The tmux session survives a pause, so a live one is
                    // attached as it is. Otherwise the newer transcript wins
                    // before a fresh `--resume` starts on the machine.
                    if existingMachine == currentMachine, card.link.isRemote,
                       let rushName = card.link.tmuxLink?.sessionName,
                       RushSessionName.rushId(fromName: rushName) == RushSessionName.rushId(sessionId: sessionId) {
                        await boxdSupervisor.assignSession(rushName, to: preparation.machineName)
                        if await boxdSupervisor.hasSession(machineName: preparation.machineName, sessionName: rushName) {
                            KanbanCodeLog.info("resume", "Attaching to live rush \(rushName) on \(preparation.machineName)")
                            platform.markRemoteSessionReady(rushName, preparation.machineName)
                            store.dispatch(.resumeCompleted(cardId: cardId, tmuxName: rushName, isRemote: true))
                            return
                        }
                    }
                    var liveOnMachine = false
                    if existingMachine == currentMachine {
                        liveOnMachine = await boxdSupervisor.hasSession(machineName: preparation.machineName, sessionName: resumeSessionName)
                    }
                    if liveOnMachine, card.link.isRemote {
                        KanbanCodeLog.info("resume", "Attaching to live remote tmux \(resumeSessionName) on \(preparation.machineName)")
                        platform.markRemoteSessionReady(resumeSessionName, preparation.machineName)
                        store.dispatch(.resumeCompleted(cardId: cardId, tmuxName: resumeSessionName, isRemote: true))
                        return
                    }
                    if liveOnMachine {
                        // The card continued locally after that session; the
                        // newer transcript wins and a fresh --resume starts.
                        KanbanCodeLog.info("resume", "Dropping stale remote tmux \(resumeSessionName) on \(preparation.machineName)")
                        try? await tmux.killSession(name: resumeSessionName)
                    }
                    if let localTranscript = store.state.links[cardId]?.sessionLink?.sessionPath,
                       FileManager.default.fileExists(atPath: localTranscript) {
                        let localLines = BoxdLaunchPlanner.lineCount(ofFileAt: localTranscript)
                        let remoteLines = await boxdSupervisor.remoteTranscriptLines(
                            machineName: preparation.machineName, localPath: localTranscript, remoteCwd: preparation.remoteCwd)
                        let decision = BoxdLaunchPlanner.resumeDecision(
                            tmuxAlive: false, localTranscriptLines: localLines, remoteTranscriptLines: remoteLines)
                        if decision == .pushThenResume {
                            KanbanCodeLog.info("resume", "Pushing transcript \(sessionId.prefix(8)) to \(preparation.machineName) (\(localLines) > \(remoteLines) lines)")
                            try await boxdSupervisor.pushTranscript(
                                machineName: preparation.machineName,
                                localPath: localTranscript,
                                sessionId: sessionId,
                                remoteCwd: preparation.remoteCwd,
                                remoteLines: remoteLines,
                                log: { progress.report($0) }
                            )
                        } else {
                            KanbanCodeLog.info("resume", "Transcript \(sessionId.prefix(8)) already on \(preparation.machineName) (\(remoteLines) lines)")
                        }
                    }
                } else if runRemotely, let remote = globalRemote, projectPath.hasPrefix(remote.localPath) {
                    let mutagenSetup = await mutagenEnvironment(remote: remote, projectPath: projectPath, assistant: assistant)
                    shellOverride = mutagenSetup.0
                    extraEnv = mutagenSetup.1
                    preamble = mutagenSetup.2
                    isRemote = true
                } else {
                    shellOverride = nil
                    extraEnv = [:]
                    isRemote = false
                    preamble = nil
                    // A card that leaves its machine continues from the local
                    // mirror. The machine is kept, stopped, and its tmux name
                    // is released so the local tmux server can own it. A
                    // worktree that only existed on the machine is created
                    // here first.
                    if let remote = card.link.remote, remote.mode == .boxd, let boxdSupervisor {
                        progress.start()
                        progress.report("Leaving \(remote.machineName)")
                        // Every session the card has there ends: the one of
                        // its launch may carry another name than the resume.
                        let names = (card.link.tmuxLink?.allSessionNames ?? []) + [resumeSessionName]
                        await boxdSupervisor.leave(
                            machineName: remote.machineName,
                            sessionNames: Array(Set(names)),
                            localTranscript: store.state.links[cardId]?.sessionLink?.sessionPath,
                            remoteCwd: remote.remoteCwd)
                        if let worktree = card.link.worktreeLink,
                           let repoRoot = card.link.projectPath,
                           !FileManager.default.fileExists(atPath: worktree.path) {
                            let name = (worktree.path as NSString).lastPathComponent
                            progress.start()
                            progress.report("Creating worktree \(name) locally")
                            _ = try await BoxdMachineSupervisor.createLocalWorktree(repoRoot: repoRoot, name: name)
                        }
                    }
                }
                let commandTemplate = settings?.commandTemplate(for: assistant, remote: isRemote)

                let resumeServiceId = serviceIdOverride ?? card.link.apiServiceId ?? settings?.defaultAPIServiceIds[assistant.rawValue]
                let resolvedService = resumeServiceId.flatMap { sid in
                    settings?.apiServices.first { $0.id == sid && $0.assistant == assistant }
                }
                var serviceExtraEnv = extraEnv
                if let svc = resolvedService,
                   let envKey = assistant.baseURLEnvKey,
                   let url = svc.baseURL, !url.isEmpty {
                    serviceExtraEnv[envKey] = url
                }
                if let parentEnv = Self.subagentCacheEnv(parentCardId: card.link.parentCardId, assistant: assistant) {
                    serviceExtraEnv.merge(parentEnv) { _, new in new }
                }
                serviceExtraEnv.merge(platform.sessionEnvironment) { current, _ in current }
                // The vault runs on this master: only a session on this
                // machine can use its token.
                if !isRemote, let cardSessionEnvironment {
                    serviceExtraEnv.merge(await cardSessionEnvironment(cardId)) { _, new in new }
                }

                if boxdPreparation == nil,
                   rushChoice(settings: settings, assistant: assistant, remote: isRemote, commandOverride: commandOverride) == .rush {
                    await killTmuxSessions(of: sessionId)
                    let name = try await startOnRush(
                        cardId: cardId,
                        cwd: resumePath,
                        sessionId: sessionId,
                        resume: true,
                        prompt: nil,
                        images: [],
                        extraEnv: serviceExtraEnv,
                        skipPermissions: skipPermissions,
                        model: effectiveModelOverride,
                        commandTemplate: commandTemplate,
                        service: resolvedService
                    )
                    store.dispatch(.resumeCompleted(cardId: cardId, tmuxName: name, isRemote: false))
                    return
                }

                if let preparation = boxdPreparation,
                   let machineRush = await machineRush(
                       machineName: preparation.machineName, settings: settings, assistant: assistant,
                       commandOverride: commandOverride, service: resolvedService) {
                    // The conversation runs in one place only: its tmux
                    // sessions, here or on the machine, end first.
                    await killTmuxSessions(of: sessionId)
                    let name = try await startOnRush(
                        cardId: cardId,
                        cwd: resumePath,
                        sessionId: sessionId,
                        resume: true,
                        prompt: nil,
                        images: [],
                        extraEnv: serviceExtraEnv,
                        skipPermissions: skipPermissions,
                        model: effectiveModelOverride,
                        commandTemplate: nil,
                        service: resolvedService,
                        rush: machineRush
                    )
                    await boxdSupervisor?.assignSession(name, to: preparation.machineName)
                    platform.markRemoteSessionReady(name, preparation.machineName)
                    store.dispatch(.resumeCompleted(cardId: cardId, tmuxName: name, isRemote: true))
                    return
                }

                let actualTmuxName = try await launcher.resume(
                    sessionId: sessionId,
                    projectPath: resumePath,
                    shellOverride: shellOverride,
                    extraEnv: serviceExtraEnv,
                    commandOverride: commandOverride,
                    commandTemplate: commandTemplate,
                    skipPermissions: skipPermissions,
                    preamble: preamble,
                    assistant: assistant,
                    service: resolvedService,
                    modelOverride: effectiveModelOverride
                )
                KanbanCodeLog.info("resume", "Resume launched for card=\(cardId.prefix(12)) actualTmux=\(actualTmuxName)")
                if let preparation = boxdPreparation, let boxdSupervisor {
                    await boxdSupervisor.exportSessionEnvironment(
                        machineName: preparation.machineName, sessionName: actualTmuxName, env: preparation.extraEnv)
                    platform.markRemoteSessionReady(actualTmuxName, preparation.machineName)
                }

                store.dispatch(.resumeCompleted(cardId: cardId, tmuxName: actualTmuxName, isRemote: isRemote))
            } catch {
                KanbanCodeLog.warn("resume", "Resume failed for card=\(cardId.prefix(12)): \(error.localizedDescription)")
                store.dispatch(.resumeFailed(cardId: cardId, error: BoxdCliAdapter.shortMessage(of: error)))
                // The machine would sit running, billed by the hour, waiting
                // for a retry that may never come. A stop keeps its disk and
                // the next resume brings it back with a cold start.
                if runRemotely, store.state.remoteMode.runsOnMachines,
                   let remote = store.state.links[cardId]?.remote,
                   let boxdSupervisor,
                   await boxdSupervisor.isConnected(remote.machineName) {
                    KanbanCodeLog.info("resume", "Stopping \(remote.machineName) after the failed resume")
                    await boxdSupervisor.stop(machineName: remote.machineName, reason: .manual)
                }
            }
        }
        return true
    }

    // MARK: - rush

    /// Where a card's Claude session runs, from the settings and the launch.
    public func rushChoice(
        settings: Settings?,
        assistant: CodingAssistant,
        remote: Bool,
        commandOverride: String?
    ) -> RushLaunchPlanner.Choice {
        let choice = RushLaunchPlanner.choose(
            assistant: assistant,
            runtime: settings?.runtime(for: assistant) ?? .tmux,
            remote: remote,
            commandOverride: commandOverride,
            rushInstalled: tmux.rush.isAvailable
        )
        if case .fallback(let fallback) = choice {
            KanbanCodeLog.info("rush", "Running on tmux: \(fallback.reason)")
            if fallback == .notInstalled {
                store.dispatch(.setError("rush is not installed, the session runs on tmux"))
            }
        }
        return choice
    }

    /// rush on an ssh machine, when a card launched or resumed there runs
    /// on it: the settings pick rush for the assistant and the machine has
    /// it. A command template or an API service launcher wraps `claude` in a
    /// script of this machine, so those cards stay on tmux there.
    public func machineRush(
        machineName: String,
        settings: Settings?,
        assistant: CodingAssistant,
        commandOverride: String?,
        service: APIService?
    ) async -> RushCliAdapter? {
        guard settings?.runtime(for: assistant) == .rush else { return nil }
        guard let boxdSupervisor, await boxdSupervisor.isHost(machineName) else { return nil }
        let choice = RushLaunchPlanner.choose(
            assistant: assistant, runtime: .rush, remote: false,
            commandOverride: commandOverride, rushInstalled: tmux.registry.rush(for: machineName) != nil)
        guard choice == .rush, let rush = tmux.registry.rush(for: machineName) else {
            if case .fallback(let fallback) = choice {
                KanbanCodeLog.info("rush", "Running on tmux on \(machineName): \(fallback.reason)")
            }
            return nil
        }
        let template = settings?.commandTemplate(for: assistant, remote: true)
        guard RushLaunchPlanner.wrapperCommand(template: template, service: service) == nil else {
            KanbanCodeLog.info("rush", "Running on tmux on \(machineName): the command template or API service wraps claude")
            return nil
        }
        return rush
    }

    /// Starts, or resumes, a card's Claude session on a rush host and
    /// returns its session name (`rush-<id>`).
    public func startOnRush(
        cardId: String,
        cwd: String,
        sessionId: String,
        resume: Bool,
        prompt: String?,
        images: [ImageAttachment],
        extraEnv: [String: String],
        skipPermissions: Bool,
        model: String?,
        commandTemplate: String?,
        service: APIService?,
        rush: RushCliAdapter? = nil,
        human: Bool = false
    ) async throws -> String {
        let imagePaths = images.compactMap { image -> String? in
            if let tempPath = image.tempPath { return tempPath }
            var copy = image
            return try? copy.saveToTemp()
        }
        let adapter = rush ?? tmux.rush
        let wrapper = try RushLaunchPlanner.wrapperCommand(template: commandTemplate, service: service)
            .map { try Self.writeRushWrapper(cardId: cardId, command: $0) }
        let binary = RushLaunchPlanner.binary(
            wrapper: wrapper, remote: adapter.isRemote, findExecutable: ShellCommand.findExecutable)
        let request = RushLaunchPlanner.request(
            cardId: cardId,
            cwd: cwd,
            sessionId: sessionId,
            resume: resume,
            name: store.state.links[cardId]?.name,
            // rush puts each image right after its [Image #N] marker.
            prompt: prompt,
            imagePaths: imagePaths,
            extraEnv: extraEnv,
            skipPermissions: skipPermissions,
            model: model ?? service?.modelFlag,
            binary: binary
        )
        let info = try await adapter.start(request, human: human)
        let name = RushSessionName.name(for: info)
        KanbanCodeLog.info("rush", "Started \(name) for card=\(cardId.prefix(12)) session=\(sessionId.prefix(8)) resume=\(resume)")
        return name
    }

    /// Stops the tmux sessions of `sessionId` so its rush host is the only
    /// process writing the transcript.
    public func killTmuxSessions(of sessionId: String) async {
        let sid8 = String(sessionId.prefix(8))
        guard let sessions = try? await tmux.listSessions() else { return }
        for session in sessions where session.name.contains(sid8) && !RushSessionName.isRush(session.name) {
            try? await tmux.killSession(name: session.name)
        }
    }

    /// The transcript Claude writes here for a session started in `cwd`.
    public func transcriptPath(cwd: String, sessionId: String) -> String {
        "\(platform.claudeProjectsDirectory)/\(SessionFileMover.encodeProjectPath(cwd))/\(sessionId).jsonl"
    }

    private static func writeRushWrapper(cardId: String, command: String) throws -> String {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code/rush")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = "\(dir)/\(cardId)-claude.sh"
        try RushLaunchPlanner.wrapperScript(command: command).write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }
}
