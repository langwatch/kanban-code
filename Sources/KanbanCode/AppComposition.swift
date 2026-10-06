import AppKit
import KanbanCodeCore

/// The service graph of the app, built once and shared by every
/// `ContentView` value SwiftUI creates. The store, the boxd supervisor and
/// the remote session registry hold references to each other, so a second
/// copy would send its actions to a store nothing renders.
@MainActor
final class AppComposition {
    static var shared: AppComposition {
        if let current { return current }
        let built = AppComposition()
        current = built
        return built
    }
    private static var current: AppComposition?

    let store: BoardStore
    let orchestrator: BackgroundOrchestrator
    let settingsStore: SettingsStore
    let assistantRegistry: CodingAssistantRegistry
    let launcher: LaunchSession
    let tmuxAdapter: RoutingTmuxAdapter
    let boxdSupervisor: BoxdMachineSupervisor
    let engine: MasterEngine
    let peerSync: PeerSync
    let agentSync: AgentSyncEngine
    let vault: VaultService
    let scrubber: SecretScrubber
    let transcriptMirror: PeerTranscriptMirror
    let attentionCenter: AttentionCenter

    private init() {
        let claudeDiscovery = ClaudeCodeSessionDiscovery()
        let claudeDetector = ClaudeCodeActivityDetector()
        let claudeStore = ClaudeCodeSessionStore()
        let geminiDiscovery = GeminiSessionDiscovery()
        let geminiDetector = GeminiActivityDetector()
        let geminiStore = GeminiSessionStore()
        let codexDiscovery = CodexSessionDiscovery()
        let codexDetector = CodexActivityDetector()
        let codexStore = CodexSessionStore()

        let enabledAssistants = ContentView.loadEnabledAssistants()
        let registry = CodingAssistantRegistry()
        if enabledAssistants.contains(.claude) {
            registry.register(.claude, discovery: claudeDiscovery, detector: claudeDetector, store: claudeStore)
        }
        if enabledAssistants.contains(.gemini) {
            registry.register(.gemini, discovery: geminiDiscovery, detector: geminiDetector, store: geminiStore)
        }
        if enabledAssistants.contains(.codex) {
            registry.register(.codex, discovery: codexDiscovery, detector: codexDetector, store: codexStore)
        }

        let discovery = CompositeSessionDiscovery(registry: registry)
        let activityDetector = CompositeActivityDetector(registry: registry, defaultDetector: claudeDetector)

        let coordination = CoordinationStore()
        let settings = SettingsStore()
        let remoteRegistry = RemoteSessionRegistry()
        let tmux = RoutingTmuxAdapter(local: TmuxAdapter(), registry: remoteRegistry)
        let machinePort = MachinePortRouter(
            boxd: BoxdCliAdapter(),
            ssh: SshHostPort(machines: { (try? await settings.read())?.boxd?.sshMachines ?? [] })
        )
        let supervisor = BoxdMachineSupervisor(
            boxd: machinePort,
            registry: remoteRegistry,
            settingsProvider: { (try? await settings.read())?.boxd ?? BoxdSettings() },
            cliBundlePath: AppServices.cliBundlePath,
            appVersion: AppServices.appVersion
        )
        AppServices.tmux = tmux
        AppServices.remoteRegistry = remoteRegistry
        AppServices.boxdSupervisor = supervisor

        let effectHandler = EffectHandler(
            coordinationStore: coordination,
            tmuxAdapter: tmux,
            setClipboardImage: { data in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setData(data, forType: .png)
            },
            notifier: MacOSNotificationClient(),
            remoteMachines: supervisor
        )

        let boardStore = BoardStore(
            effectHandler: effectHandler,
            discovery: discovery,
            coordinationStore: coordination,
            activityDetector: activityDetector,
            settingsStore: settings,
            ghAdapter: GhCliAdapter(),
            worktreeAdapter: GitWorktreeAdapter(),
            tmuxAdapter: tmux
        )

        let orch = BackgroundOrchestrator(
            discovery: discovery,
            coordinationStore: coordination,
            activityDetector: activityDetector,
            tmux: tmux,
            prTracker: GhCliAdapter(),
            registry: registry
        )

        let launch = LaunchSession(tmux: tmux)

        orch.setDispatch { [weak boardStore] action in
            boardStore?.dispatch(action)
        }
        AppServices.pauseMachine = { [weak boardStore] cardId in
            boardStore?.dispatch(.stopRemoteMachine(cardId: cardId, reason: .manual))
        }
        AppServices.destroyMachine = { [weak boardStore] cardId in
            boardStore?.dispatch(.showDialog(.confirmDestroyMachine(cardId: cardId)))
        }
        Task { [weak boardStore] in
            await supervisor.setDispatch { action in
                boardStore?.dispatch(action)
            }
            await supervisor.setProxyRunner { invocation in
                await AppServices.runProxiedCommand(invocation)
            }
            await supervisor.setBusyCheck { machineName in
                await MainActor.run {
                    guard let boardStore else { return false }
                    let state = boardStore.state
                    return state.cardIds(onMachine: machineName).contains { cardId in
                        guard let sessionId = state.links[cardId]?.sessionLink?.sessionId else { return false }
                        return state.activityMap[sessionId] == .activelyWorking
                    }
                }
            }
            await supervisor.setLinksProvider {
                await MainActor.run { boardStore.map { Array($0.state.links.values) } ?? [] }
            }
        }


        // Restore persisted detail expansion and card selection before first render
        // to avoid flicker. @AppStorage values are available synchronously.
        let persistedExpanded = UserDefaults.standard.bool(forKey: "detailExpanded")
        let persistedCardId = UserDefaults.standard.string(forKey: "selectedCardId") ?? ""
        if persistedExpanded {
            boardStore.dispatch(.setDetailExpanded(true))
        }
        if !persistedCardId.isEmpty {
            boardStore.dispatch(.selectCard(cardId: persistedCardId))
        }

        let engine = MasterEngine(
            store: boardStore,
            settingsStore: settings,
            launcher: launch,
            tmux: tmux,
            boxdSupervisor: supervisor,
            registry: registry,
            platform: Self.platform()
        )
        engine.platform.discoverBranches = { [weak boardStore] cardId in
            guard let boardStore else { return }
            boardStore.dispatch(.setBusy(cardId: cardId, busy: true))
            if let updatedLink = await orch.discoverBranchesForCard(cardId: cardId) {
                boardStore.dispatch(.createManualTask(updatedLink))
            }
            await boardStore.reconcile()
            boardStore.dispatch(.setBusy(cardId: cardId, busy: false))
        }
        // The machine identity is on the board before the first reconcile,
        // so every card this Mac stamps carries it.
        let identity = MachineIdentityStore().loadOrCreate(defaultName: RemoteControlServer.defaultHostName)
        boardStore.dispatch(.localMachineLoaded(identity))
        let peerSync = PeerSync(identity: identity, peers: Self.readPeers()) { [weak boardStore] action in
            await MainActor.run { boardStore?.dispatch(action) }
        }
        engine.peerSync = peerSync
        engine.installForeignCardHandler()
        Task.detached { await peerSync.run() }
        Task { await engine.runOwnershipLoop() }
        let mirror = PeerTranscriptMirror(engine: engine)
        Task { await mirror.run() }
        // Channels live on the channels home when it is another master.
        Task { await effectHandler.setChannelsHome { [weak engine] in await engine?.channelsHomeRoute() } }
        Task { await engine.runChannelsMirror() }
        NotificationCenter.default.addObserver(forName: .kanbanCodeSettingsChanged, object: nil, queue: .main) { _ in
            let peers = Self.readPeers()
            Task { await peerSync.setPeers(peers) }
        }
        let agentSync = AgentSyncEngine(identity: identity) { [peerSync] in await peerSync.syncPeers() }
        Task.detached { await agentSync.run() }
        let vault = VaultService(
            kanbanHome: NSHomeDirectory() + "/.kanban-code",
            keys: KeychainVaultKeyProvider(),
            machine: identity.name,
            approvals: StoreVaultApprovals(store: boardStore),
            cardTitle: { [weak boardStore] id in await MainActor.run { boardStore?.vaultCardTitle(id) } },
            cardPrompts: { [weak boardStore] id in
                guard let link = await MainActor.run(body: { boardStore?.vaultCardLink(id) }) else { return nil }
                return CardPromptReader.read(link: link, kanbanHome: NSHomeDirectory() + "/.kanban-code")
            },
            cardFamily: { [weak boardStore] id in await MainActor.run { boardStore?.vaultCardFamily(id) ?? [] } },
            cardSessions: { [weak boardStore] in await MainActor.run { boardStore?.vaultCardSessions() ?? [:] } },
            peers: { await peerSync.configuredPeers() },
            deviceApprovals: (MacVaultDevice.approvals, MacVaultDevice.deviceName)
        )
        engine.cardSessionEnvironment = { [vault] cardId in await vault.sessionEnvironment(cardId: cardId) }
        engine.cardTokenOwner = { [vault] token in await vault.cardTokens.issuedCard(of: token) }
        engine.cardHasToken = { [vault] cardId in await vault.cardTokens.hasToken(cardId: cardId) }
        engine.vaultUnsealed = { [vault] id, unsealed in await vault.broker.deliver(id: id, unsealed: unsealed) }
        Task { await vault.start() }

        // Decisions agents wait on: Mac notification, then the phone.
        let notifications = Self.readNotificationSettings()
        let presence = MacPresenceMonitor.shared
        presence.start()
        Task { @MainActor [weak boardStore] in
            guard let boardStore else { return }
            await presence.follow(store: boardStore)
        }
        let attentionCenter = AttentionCenter(
            settings: notifications.attentionPolicy,
            mac: DockAttentionNotifier(MacAttentionNotificationClient()),
            phone: notifications.phoneSender,
            localPresence: { presence.snapshot() },
            cardName: { [weak boardStore] id in
                await MainActor.run { id.flatMap { boardStore?.state.links[$0]?.displayTitle } }
            },
            localMachineId: { identity.id },
            stateFile: NSHomeDirectory() + "/.kanban-code/attention-deliveries.json")
        engine.attentionCenter = attentionCenter
        Task { await effectHandler.setAttentionDelivery(attentionCenter) }
        orch.onAttentionHook = { [weak engine] event in
            await MainActor.run { engine?.handleAttentionHook(event) }
        }
        Task { await attentionCenter.start() }
        Task { await engine.runAttentionMonitor() }
        Task { await engine.runAttentionPeerSync(presence: { presence.snapshot() }) }
        NotificationCenter.default.addObserver(forName: .kanbanCodeSettingsChanged, object: nil, queue: .main) { _ in
            let notifications = Self.readNotificationSettings()
            Task { await attentionCenter.configure(settings: notifications.attentionPolicy, phone: notifications.phoneSender) }
        }
        AppServices.resolveAttention = { [weak engine] id, resolution, unsealed in
            guard let engine else { return "Kanban Code is still starting." }
            do {
                try await engine.resolveAttention(id: id, resolution: resolution, by: MacVaultDevice.deviceName, unsealed: unsealed)
                return nil
            } catch {
                KanbanCodeLog.warn("attention", "Resolving \(id) from the Mac failed: \(error)")
                return (error as? RemoteHostError)?.message ?? error.localizedDescription
            }
        }
        AppServices.answerCard = { [weak engine] cardId, answer in
            guard let engine else { return false }
            do {
                return try await engine.answerOpenRequest(cardId: cardId, answer: answer, by: "mac")
            } catch {
                KanbanCodeLog.warn("attention", "Answering card \(cardId) from the chat failed: \(error)")
                return false
            }
        }
        let scrubber = SecretScrubber(vault: vault, machine: identity.name) { await peerSync.configuredPeers() }
        Task.detached(priority: .utility) { await scrubber.runSchedule() }
        RemoteControlController.shared.scrubber = scrubber
        RemoteControlController.shared.attach(
            engine: engine,
            peerServer: BoardPeerLinksServer(store: boardStore, peerSync: peerSync),
            syncEngine: agentSync,
            vault: vault,
            settingsStore: settings
        )

        self.store = boardStore
        self.orchestrator = orch
        self.settingsStore = settings
        self.assistantRegistry = registry
        self.launcher = launch
        self.tmuxAdapter = tmux
        self.boxdSupervisor = supervisor
        self.engine = engine
        self.peerSync = peerSync
        self.agentSync = agentSync
        self.vault = vault
        self.scrubber = scrubber
        self.transcriptMirror = mirror
        self.attentionCenter = attentionCenter
        KanbanCodeLog.info("app", "services composed machine=\(identity.name) (\(identity.id))")
    }

    /// Settings > Notifications, read straight from the file.
    static func readNotificationSettings() -> NotificationSettings {
        let path = NSHomeDirectory() + "/.kanban-code/settings.json"
        let settings = FileManager.default.contents(atPath: path).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) }
        return settings?.notifications ?? NotificationSettings()
    }

    /// Settings > Peers, read straight from the file.
    private static func readPeers() -> [PeerConfig] {
        let path = NSHomeDirectory() + "/.kanban-code/settings.json"
        let settings = FileManager.default.contents(atPath: path).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) }
        return settings?.peers ?? []
    }

    /// What the master engine needs from the Mac: the clipboard, the remote
    /// terminals of boxd and ssh machines, and the defaults of the launch
    /// dialogs for launches from the remote API.
    private static func platform() -> MasterPlatform {
        var platform = MasterPlatform()
        platform.setClipboardImage = { data in
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setData(data, forType: .png)
            }
        }
        platform.expectRemoteSession = { AppServices.expectRemoteSession($0) }
        platform.clearRemoteSessionReady = { AppServices.clearRemoteSessionReady($0) }
        platform.markRemoteSessionReady = { AppServices.markRemoteSessionReady($0, machine: $1) }
        platform.unassignRemoteSession = { AppServices.remoteRegistry?.unassign(sessionName: $0) }
        platform.machineForSession = { AppServices.machine(forSession: $0) }
        platform.remoteMachineChoice = { machine, projectPath in
            let options = AppComposition.shared.remoteLaunchOptions()
            return RemoteLaunchOptions.remoteMachineChoice(machine, options: options, projectPath: projectPath)
        }
        platform.defaultAssistant = {
            // The assistant the New Task dialog last used.
            let last = UserDefaults.standard.string(forKey: "selectedAssistant").flatMap(CodingAssistant.init(rawValue:))
            return last.flatMap { ContentView.loadEnabledAssistants().contains($0) ? $0 : nil } ?? .claude
        }
        platform.skipPermissions = { ContentView.remoteSkipPermissions }
        platform.terminalCommand = { session in AppServices.terminalCommand(forSession: session) }
        platform.peerTerminalCommand = { machineId, cardId, session in
            AppServices.peerTerminalCommand(machineId: machineId, cardId: cardId, session: session)
        }
        platform.clonesMissingProjects = false
        platform.cliScript = AppServices.cliBundlePath.map { "\($0)/dist/kanban.js" }
        platform.nodePath = AppServices.findNode()
        return platform
    }

    /// The launch options of a remote API launch: the board's remote mode
    /// and machines, no card.
    func remoteLaunchOptions() -> RemoteLaunchOptions {
        RemoteLaunchOptions(
            mode: store.state.remoteMode,
            mutagen: store.state.globalRemoteSettings,
            boxd: store.state.remoteMode.runsOnMachines ? (store.state.boxdSettings ?? BoxdSettings()) : nil,
            availableMachines: AppServices.boxdMachineNames,
            boxdAvailable: AppServices.boxdAvailable,
            machines: store.state.machineChoices
        )
    }
}
