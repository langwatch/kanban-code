import SwiftUI
import AppKit
import KanbanCodeCore

/// Bundles all parameters for the launch confirmation dialog.
/// Used with `.sheet(item:)` to guarantee all values are captured atomically.
struct LaunchConfig: Identifiable {
    let id = UUID()
    let cardId: String
    let projectPath: String
    let prompt: String
    let worktreeName: String?
    let hasExistingWorktree: Bool
    let isGitRepo: Bool
    let hasRemoteConfig: Bool
    let remoteHost: String?
    let isResume: Bool
    let sessionId: String?

    init(
        cardId: String,
        projectPath: String,
        prompt: String,
        worktreeName: String? = nil,
        hasExistingWorktree: Bool = false,
        isGitRepo: Bool = false,
        hasRemoteConfig: Bool = false,
        remoteHost: String? = nil,
        isResume: Bool = false,
        sessionId: String? = nil
    ) {
        self.cardId = cardId
        self.projectPath = projectPath
        self.prompt = prompt
        self.worktreeName = worktreeName
        self.hasExistingWorktree = hasExistingWorktree
        self.isGitRepo = isGitRepo
        self.hasRemoteConfig = hasRemoteConfig
        self.remoteHost = remoteHost
        self.isResume = isResume
        self.sessionId = sessionId
    }
}

struct ContentView: View {
    @State private var store: BoardStore
    @State private var orchestrator: BackgroundOrchestrator
    @State private var showSearch = false
    @State private var showNewTask = false
    @State private var showOnboarding = false
    @AppStorage("appearanceMode") private var appearanceMode: AppearanceMode = .auto
    @State private var showProcessManager = false
    @State private var showQuitConfirmation = false
    @State private var quitOwnedSessions: [TmuxSession] = []
    @AppStorage("killTmuxOnQuit") private var killTmuxOnQuit = true
    @State private var showAddFromPath = false
    @State private var addFromPathText = ""
    @State private var launchConfig: LaunchConfig?
    @State private var syncStatuses: [String: SyncStatus] = [:]
    @State private var isSyncRefreshing = false
    @State private var showSyncPopover = false
    @State private var rawSyncOutput = ""
    @AppStorage("selectedProject") private var selectedProjectPersisted: String = ""
    private let settingsStore: SettingsStore
    private let launcher: LaunchSession
    private let systemTray = SystemTray()
    private let mutagenAdapter = MutagenAdapter()
    private let hookEventsPath: String
    private let settingsFilePath: String

    private var showInspector: Binding<Bool> {
        Binding(
            get: { store.state.selectedCardId != nil },
            set: { if !$0 { store.dispatch(.selectCard(cardId: nil)) } }
        )
    }

    init() {
        let discovery = ClaudeCodeSessionDiscovery()
        let coordination = CoordinationStore()
        let settings = SettingsStore()
        let activityDetector = ClaudeCodeActivityDetector()
        let tmux = TmuxAdapter()

        let effectHandler = EffectHandler(
            coordinationStore: coordination,
            tmuxAdapter: tmux
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

        // Load Pushover from settings.json, wrap in CompositeNotifier with macOS fallback
        let pushover = Self.loadPushoverConfig()
        let notifier = CompositeNotifier(primary: pushover, fallback: MacOSNotificationClient())

        let orch = BackgroundOrchestrator(
            discovery: discovery,
            coordinationStore: coordination,
            activityDetector: activityDetector,
            tmux: tmux,
            prTracker: GhCliAdapter(),
            notifier: notifier
        )

        let launch = LaunchSession(tmux: tmux)

        _store = State(initialValue: boardStore)
        _orchestrator = State(initialValue: orch)
        self.settingsStore = settings
        self.launcher = launch
        self.hookEventsPath = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".kanban-code/hook-events.jsonl")
        self.settingsFilePath = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".kanban-code/settings.json")
    }

    private static func loadPushoverConfig() -> PushoverClient? {
        let settingsPath = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".kanban-code/settings.json")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
              let settings = try? JSONDecoder().decode(Settings.self, from: data) else {
            return nil
        }

        guard let token = settings.notifications.pushoverToken,
              let user = settings.notifications.pushoverUserKey,
              !token.isEmpty, !user.isEmpty else {
            return nil
        }
        return PushoverClient(token: token, userKey: user)
    }

    private var boardView: some View {
        BoardView(
            store: store,
            onStartCard: { cardId in startCard(cardId: cardId) },
            onResumeCard: { cardId in resumeCard(cardId: cardId) },
            onForkCard: { cardId in pendingForkCardId = cardId },
            onCopyResumeCmd: { cardId in
                guard let card = store.state.cards.first(where: { $0.id == cardId }) else { return }
                var cmd = ""
                if let projectPath = card.link.projectPath {
                    cmd += "cd \(projectPath) && "
                }
                if let sessionId = card.link.sessionLink?.sessionId {
                    cmd += "claude --resume \(sessionId)"
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(cmd, forType: .string)
            },
            onCleanupWorktree: { cardId in Task { await cleanupWorktree(cardId: cardId) } },
            canCleanupWorktree: { cardId in
                guard let card = store.state.cards.first(where: { $0.id == cardId }) else { return false }
                return canCleanupWorktree(for: card)
            },
            onArchiveCard: { cardId in archiveCard(cardId: cardId) },
            onDeleteCard: { cardId in pendingDeleteCardId = cardId },
            availableProjects: projectList,
            onMoveToProject: { cardId, projectPath in
                let name = projectList.first(where: { $0.path == projectPath })?.name ?? (projectPath as NSString).lastPathComponent
                pendingMoveToProject = (cardId: cardId, projectPath: projectPath, projectName: name)
            },
            onRefreshBacklog: { Task { await store.refreshBacklog() } },
            onDropCard: { cardId, column in handleDrop(cardId: cardId, to: column) },
            onMergeCards: { sourceId, targetId in
                store.dispatch(.mergeCards(sourceId: sourceId, targetId: targetId))
            },
            onNewTask: { showNewTask = true }
        )
    }

    @ViewBuilder
    private var inspectorContent: some View {
        if let card = store.state.cards.first(where: { $0.id == store.state.selectedCardId }) {
            CardDetailView(
                card: card,
                sessionStore: store.sessionStore,
                onResume: {
                    if card.link.sessionLink != nil {
                        resumeCard(cardId: card.id)
                    } else {
                        startCard(cardId: card.id)
                    }
                },
                onRename: { name in
                    store.dispatch(.renameCard(cardId: card.id, name: name))
                },
                onFork: { keepWorktree in forkCard(cardId: card.id, keepWorktree: keepWorktree) },
                onDismiss: { store.dispatch(.selectCard(cardId: nil)) },
                onUnlink: { linkType in
                    let actionType: Action.LinkType
                    switch linkType {
                    case .pr: actionType = .pr
                    case .issue: actionType = .issue
                    case .worktree: actionType = .worktree
                    case .tmux: actionType = .tmux
                    }
                    store.dispatch(.unlinkFromCard(cardId: card.id, linkType: actionType))
                },
                onAddBranch: { branch in
                    store.dispatch(.addBranchToCard(cardId: card.id, branch: branch))
                },
                onAddIssue: { number in
                    store.dispatch(.addIssueLinkToCard(cardId: card.id, issueNumber: number))
                },
                onCleanupWorktree: {
                    Task { await cleanupWorktree(cardId: card.id) }
                },
                canCleanupWorktree: canCleanupWorktree(for: card),
                onDeleteCard: {
                    pendingDeleteCardId = card.id
                },
                onCreateTerminal: {
                    createExtraTerminal(cardId: card.id)
                },
                onKillTerminal: { sessionName in
                    store.dispatch(.killTerminal(cardId: card.id, sessionName: sessionName))
                },
                onCancelLaunch: {
                    store.dispatch(.cancelLaunch(cardId: card.id))
                },
                onDiscover: {
                    Task {
                        store.dispatch(.setBusy(cardId: card.id, busy: true))
                        await orchestrator.discoverBranchesForCard(cardId: card.id)
                        await store.reconcile()
                        store.dispatch(.setBusy(cardId: card.id, busy: false))
                    }
                },
                availableProjects: projectList,
                onMoveToProject: { projectPath in
                    let name = projectList.first(where: { $0.path == projectPath })?.name ?? (projectPath as NSString).lastPathComponent
                    pendingMoveToProject = (cardId: card.id, projectPath: projectPath, projectName: name)
                },
                focusTerminal: $shouldFocusTerminal
            )
            .inspectorColumnWidth(min: 600, ideal: 800, max: 1000)
        }
    }

    private var boardWithOverlays: some View {
        boardView
            .ignoresSafeArea(edges: .top)
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .navigationTitle("")
            .inspector(isPresented: showInspector) {
                inspectorContent
            }
            .overlay {
                if showSearch {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                        .onTapGesture { showSearch = false }

                    SearchOverlay(
                        isPresented: $showSearch,
                        cards: store.state.cards,
                        sessionStore: store.sessionStore,
                        onSelectCard: { card in
                            store.dispatch(.selectCard(cardId: card.id))
                        },
                        onResumeCard: { card in
                            resumeCard(cardId: card.id)
                        },
                        onForkCard: { card in pendingForkCardId = card.id },
                        onCheckpointCard: { card in
                            store.dispatch(.selectCard(cardId: card.id))
                        }
                    )
                    .padding(40)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }
            .animation(.easeInOut(duration: 0.15), value: showSearch)
    }

    private var boardWithSheets: some View {
        boardWithOverlays
            .sheet(isPresented: $showNewTask) {
                NewTaskDialog(
                    isPresented: $showNewTask,
                    projects: store.state.configuredProjects,
                    defaultProjectPath: store.state.selectedProjectPath,
                    globalRemoteSettings: store.state.globalRemoteSettings,
                    onCreate: { prompt, projectPath, title, startImmediately in
                        createManualTask(prompt: prompt, projectPath: projectPath, title: title, startImmediately: startImmediately)
                    },
                    onCreateAndLaunch: { prompt, projectPath, title, createWorktree, runRemotely, skipPermissions, commandOverride in
                        createManualTaskAndLaunch(prompt: prompt, projectPath: projectPath, title: title, createWorktree: createWorktree, runRemotely: runRemotely, skipPermissions: skipPermissions, commandOverride: commandOverride)
                    }
                )
            }
            .sheet(isPresented: $showAddFromPath) {
                addFromPathSheet
            }
            .sheet(item: $launchConfig) { config in
                LaunchConfirmationDialog(
                    cardId: config.cardId,
                    projectPath: config.projectPath,
                    initialPrompt: config.prompt,
                    worktreeName: config.worktreeName,
                    hasExistingWorktree: config.hasExistingWorktree,
                    isGitRepo: config.isGitRepo,
                    hasRemoteConfig: config.hasRemoteConfig,
                    remoteHost: config.remoteHost,
                    isResume: config.isResume,
                    sessionId: config.sessionId,
                    isPresented: Binding(
                        get: { launchConfig != nil },
                        set: { if !$0 { launchConfig = nil } }
                    )
                ) { editedPrompt, createWorktree, runRemotely, skipPermissions, commandOverride in
                    if config.isResume {
                        executeResume(cardId: config.cardId, runRemotely: runRemotely, skipPermissions: skipPermissions, commandOverride: commandOverride)
                    } else {
                        let wtName: String? = createWorktree ? (config.worktreeName ?? "") : nil
                        executeLaunch(cardId: config.cardId, prompt: editedPrompt, projectPath: config.projectPath, worktreeName: wtName, runRemotely: runRemotely, skipPermissions: skipPermissions, commandOverride: commandOverride)
                    }
                }
            }
            .sheet(isPresented: $showOnboarding) {
                OnboardingWizard(
                    settingsStore: settingsStore,
                    onComplete: {
                        showOnboarding = false
                        let pushover = Self.loadPushoverConfig()
                        let newNotifier = CompositeNotifier(primary: pushover, fallback: MacOSNotificationClient())
                        orchestrator.updateNotifier(newNotifier)
                    }
                )
            }
            .sheet(isPresented: $showProcessManager) {
                ProcessManagerView(
                    store: store,
                    isPresented: $showProcessManager,
                    onSelectCard: { cardId in
                        store.dispatch(.selectCard(cardId: cardId))
                    }
                )
            }
    }

    var body: some View {
        NavigationStack {
        boardWithSheets
            .alert(
                "Remote Worktree",
                isPresented: Binding(
                    get: { pendingWorktreeCleanup != nil },
                    set: { if !$0 { pendingWorktreeCleanup = nil } }
                )
            ) {
                Button("Cleanup Local Copy", role: .destructive) {
                    if let info = pendingWorktreeCleanup {
                        Task { await executeLocalWorktreeCleanup(info) }
                    }
                    pendingWorktreeCleanup = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingWorktreeCleanup = nil
                }
            } message: {
                if let info = pendingWorktreeCleanup {
                    Text("The worktree path is on a remote machine:\n\n\(info.remotePath)\n\nThis will SSH to the remote to run git worktree remove, then delete the local synced copy at:\n\n\(info.localPath)")
                }
            }
            .alert(
                "Delete Card",
                isPresented: Binding(
                    get: { pendingDeleteCardId != nil },
                    set: { if !$0 { pendingDeleteCardId = nil } }
                )
            ) {
                Button("Cancel", role: .cancel) {
                    pendingDeleteCardId = nil
                }
                Button("Delete", role: .destructive) {
                    if let cardId = pendingDeleteCardId {
                        let card = store.state.cards.first(where: { $0.id == cardId })
                        let nextId = cardIdAfterDeletion(cardId)
                        store.dispatch(.deleteCard(cardId: cardId))
                        if let nextId {
                            store.dispatch(.selectCard(cardId: nextId))
                        }
                        if let wt = card?.link.worktreeLink, !wt.path.isEmpty, wt.path.contains("/.claude/worktrees/") {
                            pendingWorktreeCleanupCardId = cardId
                        }
                    }
                    pendingDeleteCardId = nil
                }
            } message: {
                Text("This will permanently delete this card and its data.")
            }
            .alert(
                "Archive Card?",
                isPresented: Binding(
                    get: { pendingArchiveCardId != nil },
                    set: { if !$0 { pendingArchiveCardId = nil } }
                )
            ) {
                Button("Cancel", role: .cancel) {
                    pendingArchiveCardId = nil
                }
                Button("Archive & Kill Terminals", role: .destructive) {
                    if let cardId = pendingArchiveCardId {
                        let card = store.state.cards.first(where: { $0.id == cardId })
                        store.dispatch(.archiveCard(cardId: cardId))
                        if let wt = card?.link.worktreeLink, !wt.path.isEmpty, wt.path.contains("/.claude/worktrees/") {
                            pendingWorktreeCleanupCardId = cardId
                        }
                    }
                    pendingArchiveCardId = nil
                }
            } message: {
                Text("This card has running terminals. Archiving will kill them.")
            }
            .alert(
                "Fork Session?",
                isPresented: Binding(
                    get: { pendingForkCardId != nil },
                    set: { if !$0 { pendingForkCardId = nil } }
                )
            ) {
                Button("Cancel", role: .cancel) {
                    pendingForkCardId = nil
                }
                if let cardId = pendingForkCardId,
                   store.state.cards.first(where: { $0.id == cardId })?.link.worktreeLink != nil {
                    Button("Fork (same worktree)") {
                        if let cardId = pendingForkCardId { forkCard(cardId: cardId, keepWorktree: true) }
                        pendingForkCardId = nil
                    }
                }
                Button("Fork (project root)") {
                    if let cardId = pendingForkCardId { forkCard(cardId: cardId) }
                    pendingForkCardId = nil
                }
            } message: {
                if pendingForkCardId != nil,
                   store.state.cards.first(where: { $0.id == pendingForkCardId })?.link.worktreeLink != nil {
                    Text("This creates a duplicate session you can resume independently. Do you want the forked session to continue from the same worktree or from the project root?")
                } else {
                    Text("This creates a duplicate session you can resume independently.")
                }
            }
            .alert(
                "Move to Project?",
                isPresented: Binding(
                    get: { pendingMoveToProject != nil },
                    set: { if !$0 { pendingMoveToProject = nil } }
                )
            ) {
                Button("Cancel", role: .cancel) {
                    pendingMoveToProject = nil
                }
                Button("Move") {
                    if let pending = pendingMoveToProject {
                        store.dispatch(.moveCardToProject(cardId: pending.cardId, projectPath: pending.projectPath))
                    }
                    pendingMoveToProject = nil
                }
            } message: {
                if let pending = pendingMoveToProject {
                    Text("Move this card to \(pending.projectName)?")
                }
            }
            .alert(
                "Cleanup Worktree?",
                isPresented: Binding(
                    get: { pendingWorktreeCleanupCardId != nil },
                    set: { if !$0 { pendingWorktreeCleanupCardId = nil } }
                )
            ) {
                Button("Keep Worktree", role: .cancel) {
                    pendingWorktreeCleanupCardId = nil
                }
                Button("Remove Worktree", role: .destructive) {
                    if let cardId = pendingWorktreeCleanupCardId {
                        Task { await cleanupWorktree(cardId: cardId) }
                    }
                    pendingWorktreeCleanupCardId = nil
                }
            } message: {
                Text("This card has a worktree. Do you want to remove it?")
            }
            .task {
                // Show onboarding wizard on first launch
                if let settings = try? await settingsStore.read(), !settings.hasCompletedOnboarding {
                    showOnboarding = true
                }
                applyAppearance()
                try? RemoteShellManager.deploy()
                // Restore persisted project selection
                if !selectedProjectPersisted.isEmpty {
                    let settings = try? await settingsStore.read()
                    let validPaths = Set(settings?.projects.map(\.path) ?? [])
                    if validPaths.contains(selectedProjectPersisted) {
                        store.dispatch(.setSelectedProject(selectedProjectPersisted))
                    } else {
                        selectedProjectPersisted = ""
                    }
                }
                // Register TerminalCache relay for KanbanCodeCore effects
                TerminalCacheRelay.removeHandler = { name in
                    TerminalCache.shared.remove(name)
                }
                systemTray.setup(store: store)
                await store.loadSettingsAndCache()
                await store.reconcile()
                systemTray.update()
                orchestrator.start()
            }
            .task(id: "hook-watcher") {
                await watchHookEvents(path: hookEventsPath)
            }
            .task(id: "settings-watcher") {
                await watchSettingsFile(path: settingsFilePath)
            }
            .task(id: "refresh-timer") {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { break }
                    await store.reconcile()
                    systemTray.update()
                }
            }
            .onAppear { installKeyMonitor() }
            .onDisappear {
                if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
                keyMonitor = nil
            }
            .onReceive(NotificationCenter.default.publisher(for: .kanbanCodeToggleSearch)) { _ in
                showSearch.toggle()
            }
            .onReceive(NotificationCenter.default.publisher(for: .kanbanCodeNewTask)) { _ in
                showNewTask = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .kanbanCodeHookEvent)) { _ in
                Task {
                    await orchestrator.processHookEvents()
                    // Fast path: update activity states and columns immediately
                    // without waiting for full reconciliation (which may be blocked
                    // or take seconds due to discovery/PR fetching)
                    await store.refreshActivity()
                    systemTray.update()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .kanbanCodeSelectCard)) { notification in
                if let cardId = notification.userInfo?["cardId"] as? String {
                    store.dispatch(.selectCard(cardId: cardId))
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .kanbanCodeSettingsChanged)) { _ in
                Task {
                    await store.reconcile()
                    applyAppearance()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .kanbanCodeQuitRequested)) { _ in
                // Build session list instantly from store state
                let sessions = store.state.cards.compactMap { card -> TmuxSession? in
                    guard let tmux = card.link.tmuxLink else { return nil }
                    return TmuxSession(name: tmux.sessionName, path: card.link.projectPath ?? "")
                }
                if sessions.isEmpty {
                    NSApp.reply(toApplicationShouldTerminate: true)
                } else {
                    quitOwnedSessions = sessions
                    showQuitConfirmation = true
                    // Update alive status async — green dot = session exists in tmux
                    Task.detached {
                        let live = AppDelegate.listAllTmuxSessionsSync()
                        let liveNames = Set(live.map(\.name))
                        let updated = sessions.map { s in
                            TmuxSession(name: s.name, path: s.path, attached: liveNames.contains(s.name))
                        }
                        await MainActor.run { quitOwnedSessions = updated }
                    }
                }
            }
            .sheet(isPresented: $showQuitConfirmation) {
                quitConfirmationSheet
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                store.appIsActive = true
                Task {
                    await store.reconcile()
                    systemTray.update()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                store.appIsActive = false
            }
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button { showNewTask = true } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .help("New task (⌘N)")

                    Button { Task { await store.reconcile() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(store.state.isLoading)
                    .help("Refresh sessions")

                    Button {
                        appearanceMode = appearanceMode.next
                        applyAppearance()
                    } label: {
                        Image(systemName: appearanceMode.icon)
                    }
                    .help(appearanceMode.helpText)
                }

                ToolbarItem(placement: .navigation) {
                    projectSelectorMenu
                }

                ToolbarItem(placement: .navigation) {
                    if currentProjectHasRemote {
                        syncStatusView
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Button { showSearch.toggle() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                            Text("Search")
                            Text("⌘K")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                        }
                        .padding(.horizontal, 4)
                    }
                    .help("Search sessions (⌘K)")
                }

                ToolbarSpacer(.fixed, placement: .primaryAction)

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        if store.state.selectedCardId != nil {
                            store.dispatch(.selectCard(cardId: nil))
                        }
                    } label: {
                        Image(systemName: "sidebar.right")
                    }
                    .disabled(store.state.selectedCardId == nil)
                    .opacity(store.state.selectedCardId != nil ? 1.0 : 0.3)
                    .help("Toggle session details")
                }
            }
            .background {
                Button("") { showSearch.toggle() }
                    .keyboardShortcut("k", modifiers: .command)
                    .hidden()
                Button("") { selectProject(at: 0) }
                    .keyboardShortcut("1", modifiers: .command)
                    .hidden()
                Button("") { selectProject(at: 1) }
                    .keyboardShortcut("2", modifiers: .command)
                    .hidden()
                Button("") { selectProject(at: 2) }
                    .keyboardShortcut("3", modifiers: .command)
                    .hidden()
                Button("") { selectProject(at: 3) }
                    .keyboardShortcut("4", modifiers: .command)
                    .hidden()
                Button("") { selectProject(at: 4) }
                    .keyboardShortcut("5", modifiers: .command)
                    .hidden()
                Button("") { selectProject(at: 5) }
                    .keyboardShortcut("6", modifiers: .command)
                    .hidden()
                Button("") { selectProject(at: 6) }
                    .keyboardShortcut("7", modifiers: .command)
                    .hidden()
                Button("") { selectProject(at: 7) }
                    .keyboardShortcut("8", modifiers: .command)
                    .hidden()
                Button("") { selectProject(at: 8) }
                    .keyboardShortcut("9", modifiers: .command)
                    .hidden()

                // Board navigation (non-arrow keys only — arrows handled via onKeyPress on BoardView)
                Button("") { store.dispatch(.selectCard(cardId: nil)) }
                    .keyboardShortcut(.escape, modifiers: [])
                    .hidden()
                Button("") { deleteSelectedCard() }
                    .keyboardShortcut(.delete, modifiers: [])
                    .hidden()
                Button("") { deleteSelectedCard() }
                    .keyboardShortcut(.deleteForward, modifiers: [])
                    .hidden()
            }
        } // NavigationStack
    }

    /// Watch ~/.kanban-code/hook-events.jsonl for writes → post notification.
    private nonisolated func watchHookEvents(path: String) async {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }

        guard let fd = open(path, O_EVTONLY) as Int32?,
              fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: .global(qos: .userInitiated)
        )

        let events = AsyncStream<Void> { continuation in
            source.setEventHandler {
                continuation.yield()
            }
            source.setCancelHandler {
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                source.cancel()
            }
            source.resume()
        }

        KanbanCodeLog.info("watcher", "File watcher started for hook-events.jsonl")
        for await _ in events {
            KanbanCodeLog.info("watcher", "hook-events.jsonl changed")
            NotificationCenter.default.post(name: .kanbanCodeHookEvent, object: nil)
        }
        KanbanCodeLog.info("watcher", "File watcher loop exited (cancelled?)")

        close(fd)
    }

    /// Watch ~/.kanban-code/settings.json for changes → hot-reload.
    private nonisolated func watchSettingsFile(path: String) async {
        guard FileManager.default.fileExists(atPath: path) else { return }

        guard let fd = open(path, O_EVTONLY) as Int32?,
              fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .global(qos: .utility)
        )

        let events = AsyncStream<Void> { continuation in
            source.setEventHandler {
                continuation.yield()
            }
            source.setCancelHandler {
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                source.cancel()
            }
            source.resume()
        }

        for await _ in events {
            NotificationCenter.default.post(name: .kanbanCodeSettingsChanged, object: nil)
        }

        close(fd)
    }

    // MARK: - Project Selector Menu

    private var projectSelectorMenu: some View {
        Menu {
            Button {
                setSelectedProject(nil)
            } label: {
                HStack {
                    Text("All Projects")
                    Spacer()
                    Text("\(store.state.cards.count)")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    if store.state.selectedProjectPath == nil {
                        Image(systemName: "checkmark")
                    }
                }
            }

            let visibleProjects = store.state.configuredProjects.filter(\.visible)
            if !visibleProjects.isEmpty {
                Divider()
                ForEach(visibleProjects) { project in
                    Button {
                        setSelectedProject(project.path)
                    } label: {
                        HStack {
                            Text(project.name)
                            Spacer()
                            let count = store.state.cards.filter { $0.link.projectPath == project.path }.count
                            if count > 0 {
                                Text("\(count)")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            }
                            if store.state.selectedProjectPath == project.path {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }

            let discovered = store.state.discoveredProjectPaths
            if !discovered.isEmpty {
                Divider()
                Section("Discovered") {
                    ForEach(discovered.prefix(8), id: \.self) { path in
                        Button {
                            addDiscoveredProject(path: path)
                        } label: {
                            Label(
                                (path as NSString).lastPathComponent,
                                systemImage: "folder.badge.plus"
                            )
                        }
                    }
                }
            }

            Divider()

            Button("Add from folder...") {
                addProjectViaFolderPicker()
            }

            Button("Add from path...") {
                addFromPathText = ""
                showAddFromPath = true
            }

            Button("Process Manager...") {
                showProcessManager = true
            }

            SettingsLink {
                Text("Settings...")
            }
        } label: {
            Text(currentProjectName)
                .font(.headline)
        }
    }

    private var currentProjectName: String {
        guard let path = store.state.selectedProjectPath else { return "All Projects" }
        return store.state.configuredProjects.first(where: { $0.path == path })?.name
            ?? (path as NSString).lastPathComponent
    }

    private var projectList: [(name: String, path: String)] {
        var seen = Set<String>()
        var result: [(name: String, path: String)] = []
        // Only configured projects — discovered paths are auto-assigned,
        // "Move to Project" is for intentionally moving between configured projects.
        for project in store.state.configuredProjects {
            guard seen.insert(project.path).inserted else { continue }
            result.append((name: project.name, path: project.path))
        }
        return result
    }

    private var currentProjectHasRemote: Bool {
        store.state.globalRemoteSettings != nil
    }

    private var currentSyncStatus: SyncStatus {
        if syncStatuses.isEmpty { return .notRunning }
        if syncStatuses.values.contains(.error) { return .error }
        if syncStatuses.values.contains(.paused) { return .paused }
        if syncStatuses.values.contains(.staging) { return .staging }
        if syncStatuses.values.contains(.watching) { return .watching }
        return .notRunning
    }

    // MARK: - Quit Confirmation

    private var quitConfirmationSheet: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Image(systemName: "terminal")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Quit Kanban?")
                    .font(.headline)
                Text("You have \(quitOwnedSessions.count) managed tmux session\(quitOwnedSessions.count == 1 ? "" : "s") running.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 20)
            .padding(.bottom, 12)

            Table(quitOwnedSessions) {
                TableColumn("") { session in
                    Circle()
                        .fill(session.attached ? .green : .gray)
                        .frame(width: 8, height: 8)
                }
                .width(16)

                TableColumn("Session") { session in
                    Text(session.name)
                        .lineLimit(1)
                }

                TableColumn("Card") { session in
                    if let card = store.state.cards.first(where: { card in
                        card.link.tmuxLink?.allSessionNames.contains(session.name) == true
                    }) {
                        Text(card.displayTitle)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                TableColumn("Path") { session in
                    Text(abbreviateHomePath(session.path))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxHeight: .infinity)

            Divider()

            HStack {
                Toggle("Kill managed sessions on quit", isOn: $killTmuxOnQuit)
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Cancel") {
                    showQuitConfirmation = false
                    NSApp.reply(toApplicationShouldTerminate: false)
                }
                .keyboardShortcut(.cancelAction)
                Button("Quit Kanban") {
                    showQuitConfirmation = false
                    if killTmuxOnQuit {
                        for session in quitOwnedSessions {
                            AppDelegate.killTmuxSessionSync(name: session.name)
                        }
                    }
                    NSApp.reply(toApplicationShouldTerminate: true)
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 520, height: 380)
    }

    private func abbreviateHomePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    @ViewBuilder
    private var syncStatusView: some View {
        Button { showSyncPopover.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: syncStatusIcon(currentSyncStatus))
                    .foregroundStyle(syncStatusColor(currentSyncStatus))
                Text("Sync Status")
                    .font(.headline)
            }
            .padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
        .help("Mutagen file sync status")
        .task { await refreshSyncStatus() }
        .popover(isPresented: $showSyncPopover) {
            syncStatusPopover
        }
    }

    @ViewBuilder
    private var syncStatusPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("File sync for remote Claude Code sessions, configured in Settings > Remote.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                Text(rawSyncOutput)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 250)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))

            HStack(spacing: 4) {
                Text("mutagen sync list -l")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("mutagen sync list -l", forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Copy command")
            }

            HStack {
                Button {
                    Task {
                        try? await mutagenAdapter.flushSync()
                        await refreshSyncStatus()
                    }
                } label: {
                    Label("Flush", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if currentSyncStatus == .error || currentSyncStatus == .paused {
                    Button {
                        Task {
                            for name in syncStatuses.keys {
                                try? await mutagenAdapter.resetSync(name: name)
                            }
                            await refreshSyncStatus()
                        }
                    } label: {
                        Label("Restart", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if !syncStatuses.isEmpty {
                    Button {
                        Task {
                            for name in syncStatuses.keys {
                                try? await mutagenAdapter.stopSync(name: name)
                            }
                            await refreshSyncStatus()
                        }
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Spacer()

                Button {
                    Task { await refreshSyncStatus() }
                } label: {
                    if isSyncRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isSyncRefreshing)
                .help("Refresh status")
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    private func refreshSyncStatus() async {
        guard await mutagenAdapter.isAvailable() else {
            syncStatuses = [:]
            rawSyncOutput = "Mutagen is not installed."
            return
        }
        isSyncRefreshing = true
        defer { isSyncRefreshing = false }
        syncStatuses = (try? await mutagenAdapter.status()) ?? [:]
        rawSyncOutput = (try? await mutagenAdapter.rawStatus()) ?? "Failed to fetch status."
    }

    private func syncStatusIcon(_ status: SyncStatus) -> String {
        switch status {
        case .watching: "checkmark.circle.fill"
        case .staging: "arrow.triangle.2.circlepath"
        case .paused: "pause.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        case .notRunning: "circle.dashed"
        }
    }

    private func syncStatusColor(_ status: SyncStatus) -> Color {
        switch status {
        case .watching: .green
        case .staging: .blue
        case .paused: .yellow
        case .error: .red
        case .notRunning: .secondary
        }
    }

    /// Find the card that should be selected after deleting the given card.
    /// Prefers the card directly below; if last in column, selects the one above.
    private func cardIdAfterDeletion(_ cardId: String) -> String? {
        for col in store.state.visibleColumns {
            let colCards = store.state.cards(in: col)
            if let idx = colCards.firstIndex(where: { $0.id == cardId }) {
                if idx + 1 < colCards.count {
                    return colCards[idx + 1].id
                } else if idx > 0 {
                    return colCards[idx - 1].id
                }
                return nil
            }
        }
        return nil
    }

    private func deleteSelectedCard() {
        if let cardId = store.state.selectedCardId {
            pendingDeleteCardId = cardId
        }
    }

    // MARK: - Keyboard Navigation

    /// Installs an NSEvent local monitor for arrow keys + Enter.
    /// Skips handling when a terminal view (LocalProcessTerminalView) is the first responder,
    /// so typing in the Claude Code terminal works normally.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Don't intercept if a terminal, text field, text view, or table has focus
            if let responder = event.window?.firstResponder {
                let responderType = String(describing: type(of: responder))
                if responderType.contains("Terminal")
                    || responder is NSTextView
                    || responder is NSTextField
                    || responder is NSTableView {
                    return event
                }
            }

            switch event.specialKey {
            case .upArrow:
                navigateCard(.up); return nil
            case .downArrow:
                navigateCard(.down); return nil
            case .leftArrow:
                navigateCard(.left); return nil
            case .rightArrow:
                navigateCard(.right); return nil
            case .carriageReturn, .newline, .enter:
                // Confirm pending delete alert via Enter
                if let cardId = pendingDeleteCardId {
                    let nextId = cardIdAfterDeletion(cardId)
                    store.dispatch(.deleteCard(cardId: cardId))
                    if let nextId {
                        store.dispatch(.selectCard(cardId: nextId))
                    }
                    pendingDeleteCardId = nil
                    return nil
                }
                return event
            default:
                return event
            }
        }
    }

    private enum NavDirection { case up, down, left, right, open }

    private func navigateCard(_ direction: NavDirection) {
        let columns = store.state.visibleColumns
        guard !columns.isEmpty else { return }

        // If opening and a card is selected, just ensure inspector is visible (it already is via binding)
        if direction == .open {
            if store.state.selectedCardId == nil {
                // Select first card in first non-empty column
                for col in columns {
                    let colCards = store.state.cards(in: col)
                    if let first = colCards.first {
                        store.dispatch(.selectCard(cardId: first.id))
                        return
                    }
                }
            }
            return
        }

        // Find current card's column and index
        guard let selectedId = store.state.selectedCardId else {
            // Nothing selected — select first card in first non-empty column
            for col in columns {
                let colCards = store.state.cards(in: col)
                if let first = colCards.first {
                    store.dispatch(.selectCard(cardId: first.id))
                    return
                }
            }
            return
        }

        // Find which column and index the selected card is in
        var currentCol: KanbanCodeColumn?
        var currentIndex = 0
        for col in columns {
            let colCards = store.state.cards(in: col)
            if let idx = colCards.firstIndex(where: { $0.id == selectedId }) {
                currentCol = col
                currentIndex = idx
                break
            }
        }

        guard let col = currentCol else { return }
        let colCards = store.state.cards(in: col)

        switch direction {
        case .down:
            let nextIndex = min(currentIndex + 1, colCards.count - 1)
            store.dispatch(.selectCard(cardId: colCards[nextIndex].id))
        case .up:
            let prevIndex = max(currentIndex - 1, 0)
            store.dispatch(.selectCard(cardId: colCards[prevIndex].id))
        case .left, .right:
            guard let colIdx = columns.firstIndex(of: col) else { return }
            let step = direction == .left ? -1 : 1
            var targetColIdx = colIdx + step
            // Skip empty columns
            while targetColIdx >= 0, targetColIdx < columns.count {
                let targetCards = store.state.cards(in: columns[targetColIdx])
                if !targetCards.isEmpty {
                    let targetIndex = min(currentIndex, targetCards.count - 1)
                    store.dispatch(.selectCard(cardId: targetCards[targetIndex].id))
                    return
                }
                targetColIdx += step
            }
        case .open:
            break // handled above
        }
    }

    private func setSelectedProject(_ path: String?) {
        store.dispatch(.setSelectedProject(path))
        selectedProjectPersisted = path ?? ""
    }

    private func selectProject(at index: Int) {
        if index == 0 {
            setSelectedProject(nil)
            return
        }
        let visibleProjects = store.state.configuredProjects.filter(\.visible)
        let projectIndex = index - 1
        guard projectIndex < visibleProjects.count else { return }
        setSelectedProject(visibleProjects[projectIndex].path)
    }

    private func addProjectViaFolderPicker() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a project directory"
        panel.prompt = "Add Project"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path
        let project = Project(path: path)
        Task {
            try? await settingsStore.addProject(project)
            await store.reconcile()
            setSelectedProject(path)
        }
    }

    private func addDiscoveredProject(path: String) {
        let project = Project(path: path)
        Task {
            try? await settingsStore.addProject(project)
            await store.reconcile()
            setSelectedProject(path)
        }
    }

    // MARK: - Add from Path Sheet

    private var addFromPathSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Project")
                .font(.title3)
                .fontWeight(.semibold)

            TextField("Project path (e.g. ~/Projects/my-repo)", text: $addFromPathText)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") {
                    showAddFromPath = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Add") {
                    let path = (addFromPathText as NSString).expandingTildeInPath
                    let project = Project(path: path)
                    Task {
                        try? await settingsStore.addProject(project)
                        await store.reconcile()
                        setSelectedProject(path)
                    }
                    showAddFromPath = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(addFromPathText.isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func applyAppearance() {
        switch appearanceMode {
        case .auto: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func createManualTask(prompt: String, projectPath: String?, title: String? = nil, startImmediately: Bool = false) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let name: String
        if let title, !title.isEmpty {
            name = String(title.prefix(100))
        } else {
            let firstLine = trimmed.components(separatedBy: .newlines).first ?? trimmed
            name = String(firstLine.prefix(100))
        }
        let link = Link(
            name: name,
            projectPath: projectPath,
            column: startImmediately ? .inProgress : .backlog,
            source: .manual,
            promptBody: trimmed
        )

        store.dispatch(.createManualTask(link))
        KanbanCodeLog.info("manual-task", "Created manual task card=\(link.id.prefix(12)) name='\(name)' project=\(projectPath ?? "nil") startImmediately=\(startImmediately)")

        if startImmediately {
            startCard(cardId: link.id)
        }
    }

    private func createManualTaskAndLaunch(prompt: String, projectPath: String?, title: String? = nil, createWorktree: Bool, runRemotely: Bool, skipPermissions: Bool = true, commandOverride: String? = nil) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let name: String
        if let title, !title.isEmpty {
            name = String(title.prefix(100))
        } else {
            let firstLine = trimmed.components(separatedBy: .newlines).first ?? trimmed
            name = String(firstLine.prefix(100))
        }
        let link = Link(
            name: name,
            projectPath: projectPath,
            column: .inProgress,
            source: .manual,
            promptBody: trimmed
        )
        let effectivePath = projectPath ?? NSHomeDirectory()

        store.dispatch(.createManualTask(link))
        KanbanCodeLog.info("manual-task", "Created & launching task card=\(link.id.prefix(12)) name='\(name)' project=\(effectivePath)")

        Task {
            let settings = try? await settingsStore.read()
            let project = settings?.projects.first(where: { $0.path == effectivePath })
            let builtPrompt = PromptBuilder.buildPrompt(card: link, project: project, settings: settings)

            let wtName: String? = createWorktree ? "" : nil
            executeLaunch(cardId: link.id, prompt: builtPrompt, projectPath: effectivePath, worktreeName: wtName, runRemotely: runRemotely, skipPermissions: skipPermissions, commandOverride: commandOverride)
        }
    }

    // MARK: - Worktree cleanup guard

    /// Whether this card's worktree can be cleaned up — false if another active card depends on it.
    private func canCleanupWorktree(for card: KanbanCodeCard) -> Bool {
        guard let branch = card.link.worktreeLink?.branch else { return false }
        let otherCards = store.state.cards.filter {
            $0.id != card.id
            && !$0.link.manuallyArchived
            && $0.link.worktreeLink?.branch == branch
        }
        return otherCards.isEmpty
    }

    // MARK: - Archive

    private func archiveCard(cardId: String) {
        guard let card = store.state.cards.first(where: { $0.id == cardId }) else { return }
        if card.link.tmuxLink != nil {
            pendingArchiveCardId = cardId
        } else {
            store.dispatch(.archiveCard(cardId: cardId))
            // Only offer worktree cleanup if the card has an actual worktree directory
            // and no other active card depends on it
            if let wt = card.link.worktreeLink, !wt.path.isEmpty, wt.path.contains("/.claude/worktrees/"),
               canCleanupWorktree(for: card) {
                pendingWorktreeCleanupCardId = cardId
            }
        }
    }

    // MARK: - Drag & Drop

    private func handleDrop(cardId: String, to column: KanbanCodeColumn) {
        guard let card = store.state.cards.first(where: { $0.id == cardId }) else { return }

        switch column {
        case .inProgress:
            if card.link.tmuxLink != nil {
                // Already has a running terminal — card moves here automatically when Claude is working
                store.dispatch(.setError("Session is already running — card moves to In Progress automatically when Claude is actively working"))
            } else if card.column == .backlog && card.link.sessionLink == nil {
                // Fresh backlog card → start dialog
                startCard(cardId: cardId)
            } else if card.link.sessionLink != nil {
                // Has session but no terminal → resume dialog
                resumeCard(cardId: cardId)
            } else {
                store.dispatch(.moveCard(cardId: cardId, to: column))
            }

        case .inReview:
            if card.link.prLinks.isEmpty {
                store.dispatch(.setError("Cannot move to In Review — card has no pull request"))
            } else {
                store.dispatch(.moveCard(cardId: cardId, to: column))
            }

        case .done:
            let hasMergedPR = card.link.prLinks.contains { $0.status == .merged }
            if !hasMergedPR {
                store.dispatch(.setError("Cannot move to Done — no merged pull request"))
            } else {
                store.dispatch(.moveCard(cardId: cardId, to: column))
            }

        case .allSessions:
            archiveCard(cardId: cardId)

        case .backlog:
            store.dispatch(.moveCard(cardId: cardId, to: column))

        case .waiting:
            store.dispatch(.moveCard(cardId: cardId, to: column))
        }
    }

    // MARK: - Start / Resume

    private func startCard(cardId: String) {
        guard let card = store.state.cards.first(where: { $0.id == cardId }) else { return }
        let effectivePath: String
        if let worktreePath = card.link.worktreeLink?.path, !worktreePath.isEmpty {
            effectivePath = worktreePath
        } else {
            effectivePath = card.link.projectPath ?? NSHomeDirectory()
        }

        Task {
            let settings = try? await settingsStore.read()
            let project = settings?.projects.first(where: { $0.path == (card.link.projectPath ?? effectivePath) })
            var prompt = PromptBuilder.buildPrompt(card: card.link, project: project, settings: settings)
            if prompt.isEmpty {
                prompt = card.link.promptBody ?? card.link.name ?? ""
            }

            let worktreeName: String?
            if let branch = card.link.worktreeLink?.branch {
                worktreeName = branch
            } else if let issueNum = card.link.issueLink?.number {
                worktreeName = "issue-\(issueNum)"
            } else {
                worktreeName = nil
            }

            let isGitRepo = FileManager.default.fileExists(
                atPath: (effectivePath as NSString).appendingPathComponent(".git")
            )

            let globalRemote = store.state.globalRemoteSettings
            let projectIsUnderRemote = globalRemote.map { effectivePath.hasPrefix($0.localPath) } ?? false
            launchConfig = LaunchConfig(
                cardId: cardId,
                projectPath: effectivePath,
                prompt: prompt,
                worktreeName: worktreeName,
                hasExistingWorktree: card.link.worktreeLink != nil,
                isGitRepo: isGitRepo,
                hasRemoteConfig: projectIsUnderRemote,
                remoteHost: globalRemote?.host
            )
        }
    }

    private func executeLaunch(cardId: String, prompt: String, projectPath: String, worktreeName: String?, runRemotely: Bool = true, skipPermissions: Bool = true, commandOverride: String? = nil) {
        // IMMEDIATE state update via reducer — no more dual memory+disk writes
        store.dispatch(.launchCard(cardId: cardId, prompt: prompt, projectPath: projectPath, worktreeName: worktreeName, runRemotely: runRemotely, commandOverride: commandOverride))
        shouldFocusTerminal = true
        // Reducer computed the unique tmux name and stored it in the link
        let predictedTmuxName = store.state.links[cardId]?.tmuxLink?.sessionName ?? cardId
        KanbanCodeLog.info("launch", "Starting launch for card=\(cardId.prefix(12)) tmux=\(predictedTmuxName) project=\(projectPath)")

        Task {
            do {
                let settings = try? await settingsStore.read()

                let shellOverride: String?
                let extraEnv: [String: String]
                let isRemote: Bool

                let globalRemote = settings?.remote
                if runRemotely, let remote = globalRemote, projectPath.hasPrefix(remote.localPath) {
                    try? RemoteShellManager.deploy()
                    shellOverride = RemoteShellManager.shellOverridePath()
                    extraEnv = RemoteShellManager.setupEnvironment(remote: remote, projectPath: projectPath)
                    isRemote = true

                    let syncName = "kanban-code-\((projectPath as NSString).lastPathComponent)"
                    let remoteDest = "\(remote.host):\(remote.remotePath)"
                    let ignores = remote.syncIgnores ?? MutagenAdapter.defaultIgnores
                    try? await mutagenAdapter.startSync(
                        localPath: remote.localPath,
                        remotePath: remoteDest,
                        name: syncName,
                        ignores: ignores
                    )
                } else {
                    shellOverride = nil
                    extraEnv = [:]
                    isRemote = false
                }

                // Snapshot existing .jsonl files for session detection
                let claudeProjectsDir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects")
                let encodedProject = projectPath.replacingOccurrences(of: "/", with: "-")
                let sessionDir = (claudeProjectsDir as NSString).appendingPathComponent(encodedProject)

                // When worktree is enabled, also snapshot worktree-related directories
                // (worktrees create sessions in dirs like <encodedProject>-.claude-worktrees-<name>)
                let dirsToSnapshot: [String]
                if worktreeName != nil {
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
                            .filter { $0.hasSuffix(".jsonl") }
                    )
                }

                let tmuxName = try await launcher.launch(
                    sessionName: predictedTmuxName,
                    projectPath: projectPath,
                    prompt: prompt,
                    worktreeName: worktreeName,
                    shellOverride: shellOverride,
                    extraEnv: extraEnv,
                    commandOverride: commandOverride,
                    skipPermissions: skipPermissions
                )
                KanbanCodeLog.info("launch", "Tmux session created: \(tmuxName)")

                // Show terminal immediately — clear isLaunching so UI switches
                // from spinner to terminal view without waiting for session detection.
                store.dispatch(.launchTmuxReady(cardId: cardId))

                // Detect new Claude session by polling for new .jsonl file
                // Worktree launches need more attempts (git worktree + Claude startup)
                let maxAttempts = worktreeName != nil ? 12 : 6
                var sessionLink: SessionLink?
                for attempt in 0..<maxAttempts {
                    try? await Task.sleep(for: .milliseconds(500))

                    // Build list of dirs to scan (re-list for worktree — dir may appear mid-poll)
                    let dirsToScan: [String]
                    if worktreeName != nil {
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
                                .filter { $0.hasSuffix(".jsonl") }
                        )
                        if let newFile = currentFiles.subtracting(baseline).first {
                            let sessionId = (newFile as NSString).deletingPathExtension
                            let sessionPath = (dir as NSString).appendingPathComponent(newFile)
                            KanbanCodeLog.info("launch", "Detected session file after \(attempt+1) attempts in \((dir as NSString).lastPathComponent): \(sessionId.prefix(8))")
                            sessionLink = SessionLink(sessionId: sessionId, sessionPath: sessionPath)
                            break
                        }
                    }
                    if sessionLink != nil { break }
                }

                // If worktree launch, try to extract branch from the session file immediately
                var worktreeLink: WorktreeLink?
                if worktreeName != nil, let sl = sessionLink, let sp = sl.sessionPath {
                    worktreeLink = Self.extractWorktreeLink(sessionPath: sp, projectPath: projectPath)
                }

                store.dispatch(.launchCompleted(cardId: cardId, tmuxName: tmuxName, sessionLink: sessionLink, worktreeLink: worktreeLink, isRemote: isRemote))
            } catch {
                KanbanCodeLog.error("launch", "Launch failed for card=\(cardId.prefix(12)): \(error.localizedDescription)")
                store.dispatch(.launchFailed(cardId: cardId, error: error.localizedDescription))
            }
        }
    }

    /// Extract worktreeLink from a newly-created session file by reading its first line for gitBranch.
    private static func extractWorktreeLink(sessionPath: String, projectPath: String) -> WorktreeLink? {
        // Derive worktree path from the session's directory encoding
        // Session dir: ~/.claude/projects/<encodedProject>-.claude-worktrees-<name>/
        // Worktree path: <projectPath>/.claude/worktrees/<name>
        let sessionDir = (sessionPath as NSString).deletingLastPathComponent
        let dirName = (sessionDir as NSString).lastPathComponent
        let encodedProject = projectPath.replacingOccurrences(of: "/", with: "-")

        guard dirName.hasPrefix(encodedProject + "-") else { return nil }
        let suffix = String(dirName.dropFirst(encodedProject.count + 1))
        // suffix is like ".claude-worktrees-<name>", decode path separators
        let worktreeSubpath = suffix.replacingOccurrences(of: "-", with: "/")
        let worktreePath = (projectPath as NSString).appendingPathComponent(worktreeSubpath)

        // Try to read gitBranch from the first line of the .jsonl
        var branchName: String?
        if let data = try? Data(contentsOf: URL(fileURLWithPath: sessionPath)),
           let firstNewline = data.firstIndex(of: UInt8(ascii: "\n")),
           let firstLine = String(data: data[data.startIndex..<firstNewline], encoding: .utf8),
           let lineData = firstLine.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
           let branch = obj["gitBranch"] as? String {
            branchName = branch.replacingOccurrences(of: "refs/heads/", with: "")
        }

        // Fallback: extract worktree name from path
        if branchName == nil {
            let components = worktreePath.components(separatedBy: "/.claude/worktrees/")
            if components.count == 2 {
                branchName = components[1].components(separatedBy: "/").first
            }
        }

        guard let branchName, !branchName.isEmpty else { return nil }
        KanbanCodeLog.info("launch", "Extracted worktreeLink: branch=\(branchName) path=\(worktreePath)")
        return WorktreeLink(path: worktreePath, branch: branchName)
    }

    @State private var pendingWorktreeCleanup: WorktreeCleanupInfo?
    @State private var pendingDeleteCardId: String?
    @State private var pendingArchiveCardId: String?
    @State private var pendingForkCardId: String?
    @State private var pendingMoveToProject: (cardId: String, projectPath: String, projectName: String)?
    @State private var pendingWorktreeCleanupCardId: String?
    @State private var shouldFocusTerminal = false
    @State private var keyMonitor: Any?

    struct WorktreeCleanupInfo: Identifiable {
        let id = UUID()
        let cardId: String
        let remotePath: String
        let localPath: String
        let errorMessage: String
    }

    private func cleanupWorktree(cardId: String) async {
        guard let card = store.state.cards.first(where: { $0.id == cardId }),
              let worktreePath = card.link.worktreeLink?.path,
              !worktreePath.isEmpty else { return }

        store.dispatch(.setBusy(cardId: cardId, busy: true))
        let adapter = GitWorktreeAdapter()
        do {
            try await adapter.removeWorktree(path: worktreePath, force: true)
            store.dispatch(.setBusy(cardId: cardId, busy: false))
            // If card has no session, delete it entirely — it was only a worktree
            if card.link.sessionLink == nil {
                store.dispatch(.deleteCard(cardId: cardId))
            } else {
                store.dispatch(.unlinkFromCard(cardId: cardId, linkType: .worktree))
            }
        } catch {
            store.dispatch(.setBusy(cardId: cardId, busy: false))
            if let localPath = translateRemoteWorktreePath(worktreePath, projectPath: card.link.projectPath) {
                pendingWorktreeCleanup = WorktreeCleanupInfo(
                    cardId: cardId,
                    remotePath: worktreePath,
                    localPath: localPath,
                    errorMessage: error.localizedDescription
                )
            } else {
                store.dispatch(.setError("Worktree cleanup failed: \(error.localizedDescription)"))
            }
        }
    }

    private func translateRemoteWorktreePath(_ worktreePath: String, projectPath: String?) -> String? {
        let remote = store.state.globalRemoteSettings
        guard let remote else { return nil }
        guard worktreePath.hasPrefix(remote.remotePath) else { return nil }
        let suffix = String(worktreePath.dropFirst(remote.remotePath.count))
        return remote.localPath + suffix
    }

    private func executeLocalWorktreeCleanup(_ info: WorktreeCleanupInfo) async {
        let remote = try? await settingsStore.read().remote

        if let remote {
            let repoRoot: String
            if let range = info.remotePath.range(of: "/.claude/worktrees/") {
                repoRoot = String(info.remotePath[..<range.lowerBound])
            } else {
                repoRoot = (info.remotePath as NSString).deletingLastPathComponent
            }

            do {
                let sshCmd = "cd '\(repoRoot)' && git worktree remove --force '\(info.remotePath)'"
                let result = try await ShellCommand.run("/usr/bin/ssh", arguments: [remote.host, sshCmd])
                if !result.succeeded {
                    KanbanCodeLog.warn("cleanup", "Remote git worktree remove failed: \(result.stderr)")
                }
            } catch {
                KanbanCodeLog.warn("cleanup", "SSH cleanup failed: \(error)")
            }
        }

        let fm = FileManager.default
        if fm.fileExists(atPath: info.localPath) {
            do {
                try fm.removeItem(atPath: info.localPath)
            } catch {
                store.dispatch(.setError("Failed to remove local copy: \(error.localizedDescription)"))
                return
            }
        }

        // Remove card if it has no session, otherwise just clear worktree link
        let card = store.state.cards.first(where: { $0.id == info.cardId })
        if card?.link.sessionLink == nil {
            store.dispatch(.deleteCard(cardId: info.cardId))
        } else {
            store.dispatch(.unlinkFromCard(cardId: info.cardId, linkType: .worktree))
        }
    }

    // MARK: - Extra Terminals

    private func createExtraTerminal(cardId: String) {
        guard let card = store.state.cards.first(where: { $0.id == cardId }) else { return }

        if let tmux = card.link.tmuxLink {
            // Has existing tmux — add an extra shell session
            let existing = tmux.extraSessions ?? []
            let liveTmux = store.state.tmuxSessions // live tmux sessions from last reconciliation
            let baseName = tmux.sessionName
            var n = 1
            while existing.contains("\(baseName)-sh\(n)") || liveTmux.contains("\(baseName)-sh\(n)") { n += 1 }
            let newName = "\(baseName)-sh\(n)"
            store.dispatch(.addExtraTerminal(cardId: cardId, sessionName: newName))
        } else {
            // No tmux at all — create a primary terminal session (plain shell, no Claude)
            store.dispatch(.createTerminal(cardId: cardId))
        }
    }

    private func resumeCard(cardId: String) {
        guard let card = store.state.cards.first(where: { $0.id == cardId }) else { return }
        let sessionId = card.link.sessionLink?.sessionId ?? card.link.id
        let projectPath = card.link.projectPath ?? NSHomeDirectory()

        let globalRemote = store.state.globalRemoteSettings
        let projectIsUnderRemote = globalRemote.map { projectPath.hasPrefix($0.localPath) } ?? false

        launchConfig = LaunchConfig(
            cardId: cardId,
            projectPath: projectPath,
            prompt: "",
            hasExistingWorktree: card.link.worktreeLink != nil,
            hasRemoteConfig: projectIsUnderRemote,
            remoteHost: globalRemote?.host,
            isResume: true,
            sessionId: sessionId
        )
    }

    private func forkCard(cardId: String, keepWorktree: Bool = false) {
        guard let card = store.state.cards.first(where: { $0.id == cardId }),
              let sessionPath = card.link.sessionLink?.sessionPath else { return }
        Task {
            do {
                // Determine the project path and session directory for the fork.
                // When forking from a worktree (and not keeping it), use the parent project.
                var forkProjectPath = card.link.projectPath
                var targetDir: String? = nil
                if !keepWorktree {
                    // Extract parent project if projectPath is a worktree path
                    if let pp = forkProjectPath,
                       let range = pp.range(of: "/.claude/worktrees/") {
                        forkProjectPath = String(pp[..<range.lowerBound])
                    }
                    // Always place the forked session in the correct project dir
                    // so `claude --resume` can find it from the project root.
                    if let fp = forkProjectPath {
                        let encoded = fp.replacingOccurrences(of: "/", with: "-")
                        let home = NSHomeDirectory()
                        targetDir = "\(home)/.claude/projects/\(encoded)"
                    }
                }

                let newSessionId = try await store.sessionStore.forkSession(
                    sessionPath: sessionPath, targetDirectory: targetDir
                )
                let dir = targetDir ?? (sessionPath as NSString).deletingLastPathComponent
                let newPath = (dir as NSString).appendingPathComponent("\(newSessionId).jsonl")
                var newLink = Link(
                    name: (card.link.name ?? card.link.displayTitle) + " (fork)",
                    projectPath: forkProjectPath,
                    column: .waiting,
                    lastActivity: card.link.lastActivity,
                    source: .discovered,
                    sessionLink: SessionLink(sessionId: newSessionId, sessionPath: newPath),
                    worktreeLink: keepWorktree ? card.link.worktreeLink : nil
                )
                // Mark "no worktree" as intentional so reconciler doesn't re-attach it
                if !keepWorktree && card.link.worktreeLink != nil {
                    newLink.manualOverrides.worktreePath = true
                }
                store.dispatch(.createManualTask(newLink))
                store.dispatch(.selectCard(cardId: newLink.id))
                shouldFocusTerminal = true
            } catch {
                KanbanCodeLog.error("fork", "Fork failed: \(error)")
            }
        }
    }

    private func executeResume(cardId: String, runRemotely: Bool, skipPermissions: Bool = true, commandOverride: String?) {
        guard let card = store.state.cards.first(where: { $0.id == cardId }) else { return }
        let sessionId = card.link.sessionLink?.sessionId ?? card.link.id
        let projectPath = card.link.projectPath ?? NSHomeDirectory()

        store.dispatch(.resumeCard(cardId: cardId))
        shouldFocusTerminal = true
        KanbanCodeLog.info("resume", "Starting resume for card=\(cardId.prefix(12)) session=\(sessionId.prefix(8))")

        Task {
            do {
                let settings = try? await settingsStore.read()

                let shellOverride: String?
                let extraEnv: [String: String]

                let globalRemote = settings?.remote
                if runRemotely, let remote = globalRemote, projectPath.hasPrefix(remote.localPath) {
                    try? RemoteShellManager.deploy()
                    shellOverride = RemoteShellManager.shellOverridePath()
                    extraEnv = RemoteShellManager.setupEnvironment(remote: remote, projectPath: projectPath)

                    let syncName = "kanban-code-\((projectPath as NSString).lastPathComponent)"
                    let remoteDest = "\(remote.host):\(remote.remotePath)"
                    let ignores = remote.syncIgnores ?? MutagenAdapter.defaultIgnores
                    try? await mutagenAdapter.startSync(
                        localPath: remote.localPath,
                        remotePath: remoteDest,
                        name: syncName,
                        ignores: ignores
                    )
                } else {
                    shellOverride = nil
                    extraEnv = [:]
                }

                let actualTmuxName = try await launcher.resume(
                    sessionId: sessionId,
                    projectPath: projectPath,
                    shellOverride: shellOverride,
                    extraEnv: extraEnv,
                    commandOverride: commandOverride,
                    skipPermissions: skipPermissions
                )
                KanbanCodeLog.info("resume", "Resume launched for card=\(cardId.prefix(12)) actualTmux=\(actualTmuxName)")

                store.dispatch(.resumeCompleted(cardId: cardId, tmuxName: actualTmuxName))
            } catch {
                KanbanCodeLog.info("resume", "Resume failed for card=\(cardId.prefix(12)): \(error.localizedDescription)")
                store.dispatch(.resumeFailed(cardId: cardId, error: error.localizedDescription))
            }
        }
    }
}
