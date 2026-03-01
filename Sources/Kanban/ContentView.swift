import SwiftUI
import AppKit
import KanbanCore

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
}

struct ContentView: View {
    @State private var store: BoardStore
    @State private var orchestrator: BackgroundOrchestrator
    @State private var showSearch = false
    @State private var showNewTask = false
    @State private var showOnboarding = false
    @AppStorage("appearanceMode") private var appearanceMode: AppearanceMode = .auto
    @State private var showAddFromPath = false
    @State private var addFromPathText = ""
    @State private var launchConfig: LaunchConfig?
    @State private var syncStatuses: [String: SyncStatus] = [:]
    @State private var isSyncRefreshing = false
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
            .appendingPathComponent(".kanban/hook-events.jsonl")
        self.settingsFilePath = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".kanban/settings.json")
    }

    private static func loadPushoverConfig() -> PushoverClient? {
        let settingsPath = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".kanban/settings.json")
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

    var body: some View {
        NavigationStack {
        BoardView(
            store: store,
            onStartCard: { cardId in startCard(cardId: cardId) },
            onResumeCard: { cardId in resumeCard(cardId: cardId) },
            onForkCard: { cardId in
                store.dispatch(.selectCard(cardId: cardId))
            },
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
            onDeleteCard: { cardId in pendingDeleteCardId = cardId },
            availableProjects: projectList,
            onMoveToProject: { cardId, projectPath in
                store.dispatch(.moveCardToProject(cardId: cardId, projectPath: projectPath))
            },
            onRefreshBacklog: { Task { await store.refreshBacklog() } },
            onNewTask: { showNewTask = true }
        )
            .ignoresSafeArea(edges: .top)
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .navigationTitle("")
            .inspector(isPresented: showInspector) {
                if let card = store.state.cards.first(where: { $0.id == store.state.selectedCardId }) {
                    CardDetailView(
                        card: card,
                        sessionStore: store.sessionStore,
                        onResume: { resumeCard(cardId: card.id) },
                        onRename: { name in
                            store.dispatch(.renameCard(cardId: card.id, name: name))
                        },
                        onFork: {},
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
                        onDeleteCard: {
                            pendingDeleteCardId = card.id
                        },
                        onCreateTerminal: {
                            createExtraTerminal(cardId: card.id)
                        },
                        onKillTerminal: { sessionName in
                            store.dispatch(.killTerminal(cardId: card.id, sessionName: sessionName))
                        },
                        onDiscover: {
                            Task {
                                await orchestrator.discoverBranchesForCard(cardId: card.id)
                                await store.reconcile()
                            }
                        }
                    )
                    .inspectorColumnWidth(min: 600, ideal: 800, max: 1000)
                }
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
                        onForkCard: { card in
                            store.dispatch(.selectCard(cardId: card.id))
                        },
                        onCheckpointCard: { card in
                            store.dispatch(.selectCard(cardId: card.id))
                        }
                    )
                    .padding(40)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }
            .animation(.easeInOut(duration: 0.15), value: showSearch)
            .sheet(isPresented: $showNewTask) {
                NewTaskDialog(
                    isPresented: $showNewTask,
                    projects: store.state.configuredProjects,
                    defaultProjectPath: store.state.selectedProjectPath,
                    onCreate: { prompt, projectPath, title, startImmediately in
                        createManualTask(prompt: prompt, projectPath: projectPath, title: title, startImmediately: startImmediately)
                    },
                    onCreateAndLaunch: { prompt, projectPath, title, createWorktree, runRemotely, commandOverride in
                        createManualTaskAndLaunch(prompt: prompt, projectPath: projectPath, title: title, createWorktree: createWorktree, runRemotely: runRemotely, commandOverride: commandOverride)
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
                    isPresented: Binding(
                        get: { launchConfig != nil },
                        set: { if !$0 { launchConfig = nil } }
                    )
                ) { editedPrompt, createWorktree, runRemotely, commandOverride in
                    let wtName: String? = createWorktree ? (config.worktreeName ?? "") : nil
                    executeLaunch(cardId: config.cardId, prompt: editedPrompt, projectPath: config.projectPath, worktreeName: wtName, runRemotely: runRemotely, commandOverride: commandOverride)
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
                        // Find next card to select (the one below, or above if last)
                        let nextId = cardIdAfterDeletion(cardId)
                        store.dispatch(.deleteCard(cardId: cardId))
                        if let nextId {
                            store.dispatch(.selectCard(cardId: nextId))
                        }
                    }
                    pendingDeleteCardId = nil
                }
            } message: {
                Text("This will permanently delete this card and its data.")
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
                // Register TerminalCache relay for KanbanCore effects
                TerminalCacheRelay.removeHandler = { name in
                    TerminalCache.shared.remove(name)
                }
                systemTray.setup(store: store)
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
                    try? await Task.sleep(for: .seconds(5))
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
            .onReceive(NotificationCenter.default.publisher(for: .kanbanToggleSearch)) { _ in
                showSearch.toggle()
            }
            .onReceive(NotificationCenter.default.publisher(for: .kanbanNewTask)) { _ in
                showNewTask = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .kanbanHookEvent)) { _ in
                Task {
                    await orchestrator.processHookEvents()
                    await store.reconcile()
                    systemTray.update()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .kanbanSelectCard)) { notification in
                if let cardId = notification.userInfo?["cardId"] as? String {
                    store.dispatch(.selectCard(cardId: cardId))
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .kanbanSettingsChanged)) { _ in
                Task {
                    await store.reconcile()
                    applyAppearance()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task {
                    await store.reconcile()
                    systemTray.update()
                }
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

    /// Watch ~/.kanban/hook-events.jsonl for writes → post notification.
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

        KanbanLog.info("watcher", "File watcher started for hook-events.jsonl")
        for await _ in events {
            KanbanLog.info("watcher", "hook-events.jsonl changed")
            NotificationCenter.default.post(name: .kanbanHookEvent, object: nil)
        }
        KanbanLog.info("watcher", "File watcher loop exited (cancelled?)")

        close(fd)
    }

    /// Watch ~/.kanban/settings.json for changes → hot-reload.
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
            NotificationCenter.default.post(name: .kanbanSettingsChanged, object: nil)
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
        // Configured projects first
        for project in store.state.configuredProjects {
            guard seen.insert(project.path).inserted else { continue }
            result.append((name: project.name, path: project.path))
        }
        // Then discovered project paths
        for path in store.state.discoveredProjectPaths {
            guard seen.insert(path).inserted else { continue }
            result.append((name: (path as NSString).lastPathComponent, path: path))
        }
        return result
    }

    private var currentProjectHasRemote: Bool {
        guard let path = store.state.selectedProjectPath else {
            return store.state.configuredProjects.contains { $0.remoteConfig != nil }
        }
        return store.state.configuredProjects.first(where: { $0.path == path })?.remoteConfig != nil
    }

    private var currentSyncStatus: SyncStatus {
        if syncStatuses.isEmpty { return .notRunning }
        if syncStatuses.values.contains(.error) { return .error }
        if syncStatuses.values.contains(.paused) { return .paused }
        if syncStatuses.values.contains(.staging) { return .staging }
        if syncStatuses.values.contains(.watching) { return .watching }
        return .notRunning
    }

    @ViewBuilder
    private var syncStatusView: some View {
        Menu {
            let status = currentSyncStatus
            Text("Mutagen Sync: \(syncStatusLabel(status))")

            if !syncStatuses.isEmpty {
                Divider()
                ForEach(Array(syncStatuses.keys.sorted()), id: \.self) { name in
                    if let st = syncStatuses[name] {
                        Label("\(name): \(syncStatusLabel(st))", systemImage: syncStatusIcon(st))
                    }
                }
            }

            Divider()

            Button {
                Task {
                    try? await mutagenAdapter.flushSync()
                    await refreshSyncStatus()
                }
            } label: {
                Label("Flush Sync", systemImage: "arrow.triangle.2.circlepath")
            }

            if currentSyncStatus == .error || currentSyncStatus == .paused {
                Button {
                    Task {
                        for name in syncStatuses.keys {
                            try? await mutagenAdapter.resetSync(name: name)
                        }
                        await refreshSyncStatus()
                    }
                } label: {
                    Label("Reset Sync", systemImage: "arrow.counterclockwise")
                }
            }

            Button {
                Task { await refreshSyncStatus() }
            } label: {
                Label("Refresh Status", systemImage: "arrow.clockwise")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: syncStatusIcon(currentSyncStatus))
                    .font(.caption)
                    .foregroundStyle(syncStatusColor(currentSyncStatus))
                Text("Sync")
                    .font(.caption)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Mutagen file sync status")
        .task { await refreshSyncStatus() }
    }

    private func refreshSyncStatus() async {
        guard await mutagenAdapter.isAvailable() else {
            syncStatuses = [:]
            return
        }
        isSyncRefreshing = true
        defer { isSyncRefreshing = false }
        syncStatuses = (try? await mutagenAdapter.status()) ?? [:]
    }

    private func syncStatusLabel(_ status: SyncStatus) -> String {
        switch status {
        case .watching: "Watching"
        case .staging: "Syncing..."
        case .paused: "Paused"
        case .error: "Error"
        case .notRunning: "Not Running"
        }
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
            // Don't intercept if a terminal, text field, or text view has focus
            if let responder = event.window?.firstResponder {
                let responderType = String(describing: type(of: responder))
                if responderType.contains("Terminal")
                    || responder is NSTextView
                    || responder is NSTextField {
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
        var currentCol: KanbanColumn?
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
        KanbanLog.info("manual-task", "Created manual task card=\(link.id.prefix(12)) name='\(name)' project=\(projectPath ?? "nil") startImmediately=\(startImmediately)")

        if startImmediately {
            startCard(cardId: link.id)
        }
    }

    private func createManualTaskAndLaunch(prompt: String, projectPath: String?, title: String? = nil, createWorktree: Bool, runRemotely: Bool, commandOverride: String? = nil) {
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
        KanbanLog.info("manual-task", "Created & launching task card=\(link.id.prefix(12)) name='\(name)' project=\(effectivePath)")

        Task {
            let settings = try? await settingsStore.read()
            let project = settings?.projects.first(where: { $0.path == effectivePath })
            let builtPrompt = PromptBuilder.buildPrompt(card: link, project: project, settings: settings)

            let wtName: String? = createWorktree ? "" : nil
            executeLaunch(cardId: link.id, prompt: builtPrompt, projectPath: effectivePath, worktreeName: wtName, runRemotely: runRemotely, commandOverride: commandOverride)
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
            if card.link.worktreeLink != nil {
                worktreeName = nil
            } else if let issueNum = card.link.issueLink?.number {
                worktreeName = "issue-\(issueNum)"
            } else {
                worktreeName = nil
            }

            let isGitRepo = FileManager.default.fileExists(
                atPath: (effectivePath as NSString).appendingPathComponent(".git")
            )

            launchConfig = LaunchConfig(
                cardId: cardId,
                projectPath: effectivePath,
                prompt: prompt,
                worktreeName: worktreeName,
                hasExistingWorktree: card.link.worktreeLink != nil,
                isGitRepo: isGitRepo,
                hasRemoteConfig: project?.remoteConfig != nil,
                remoteHost: project?.remoteConfig?.host
            )
        }
    }

    private func executeLaunch(cardId: String, prompt: String, projectPath: String, worktreeName: String?, runRemotely: Bool = true, commandOverride: String? = nil) {
        // IMMEDIATE state update via reducer — no more dual memory+disk writes
        store.dispatch(.launchCard(cardId: cardId, prompt: prompt, projectPath: projectPath, worktreeName: worktreeName, runRemotely: runRemotely, commandOverride: commandOverride))
        // Reducer computed the unique tmux name and stored it in the link
        let predictedTmuxName = store.state.links[cardId]?.tmuxLink?.sessionName ?? cardId
        KanbanLog.info("launch", "Starting launch for card=\(cardId.prefix(12)) tmux=\(predictedTmuxName) project=\(projectPath)")

        Task {
            do {
                let settings = try? await settingsStore.read()
                let project = settings?.projects.first(where: { $0.path == projectPath })

                let shellOverride: String?
                let extraEnv: [String: String]
                let isRemote: Bool

                if runRemotely, let project, project.remoteConfig != nil {
                    try? RemoteShellManager.deploy()
                    shellOverride = RemoteShellManager.shellOverridePath(for: project)
                    extraEnv = RemoteShellManager.setupEnvironment(for: project)
                    isRemote = true

                    if let remote = project.remoteConfig {
                        let syncName = "kanban-\((project.path as NSString).lastPathComponent)"
                        let remoteDest = "\(remote.host):\(remote.remotePath)"
                        try? await mutagenAdapter.startSync(
                            localPath: remote.localPath,
                            remotePath: remoteDest,
                            name: syncName
                        )
                    }
                } else {
                    shellOverride = nil
                    extraEnv = [:]
                    isRemote = false
                }

                // Snapshot existing .jsonl files for session detection
                let claudeProjectsDir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects")
                let encodedProject = projectPath.replacingOccurrences(of: "/", with: "-")
                let sessionDir = (claudeProjectsDir as NSString).appendingPathComponent(encodedProject)
                let existingFiles = Set(
                    ((try? FileManager.default.contentsOfDirectory(atPath: sessionDir)) ?? [])
                        .filter { $0.hasSuffix(".jsonl") }
                )

                let tmuxName = try await launcher.launch(
                    sessionName: predictedTmuxName,
                    projectPath: projectPath,
                    prompt: prompt,
                    worktreeName: worktreeName,
                    shellOverride: shellOverride,
                    extraEnv: extraEnv,
                    commandOverride: commandOverride
                )
                KanbanLog.info("launch", "Tmux session created: \(tmuxName)")

                // Detect new Claude session by polling for new .jsonl file
                var sessionLink: SessionLink?
                for attempt in 0..<6 {
                    try? await Task.sleep(for: .milliseconds(500))
                    let currentFiles = Set(
                        ((try? FileManager.default.contentsOfDirectory(atPath: sessionDir)) ?? [])
                            .filter { $0.hasSuffix(".jsonl") }
                    )
                    if let newFile = currentFiles.subtracting(existingFiles).first {
                        let sessionId = (newFile as NSString).deletingPathExtension
                        let sessionPath = (sessionDir as NSString).appendingPathComponent(newFile)
                        KanbanLog.info("launch", "Detected session file after \(attempt+1) attempts: \(sessionId.prefix(8))")
                        sessionLink = SessionLink(sessionId: sessionId, sessionPath: sessionPath)
                        break
                    }
                }

                store.dispatch(.launchCompleted(cardId: cardId, tmuxName: tmuxName, sessionLink: sessionLink, isRemote: isRemote))
            } catch {
                KanbanLog.error("launch", "Launch failed for card=\(cardId.prefix(12)): \(error.localizedDescription)")
                store.dispatch(.launchFailed(cardId: cardId, error: error.localizedDescription))
            }
        }
    }

    @State private var pendingWorktreeCleanup: WorktreeCleanupInfo?
    @State private var pendingDeleteCardId: String?
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

        let adapter = GitWorktreeAdapter()
        do {
            try await adapter.removeWorktree(path: worktreePath, force: false)
            store.dispatch(.unlinkFromCard(cardId: cardId, linkType: .worktree))
        } catch {
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
        var remote: RemoteSettings?
        if let projectPath {
            let project = store.state.configuredProjects.first(where: {
                $0.path == projectPath || $0.effectiveRepoRoot == projectPath
            })
            remote = project?.remoteConfig
        }
        if remote == nil {
            remote = (try? settingsStore.read())?.remote
        }
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
                    KanbanLog.warn("cleanup", "Remote git worktree remove failed: \(result.stderr)")
                }
            } catch {
                KanbanLog.warn("cleanup", "SSH cleanup failed: \(error)")
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
            let baseName = tmux.sessionName
            var n = 1
            while existing.contains("\(baseName)-sh\(n)") { n += 1 }
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

        // IMMEDIATE state update via reducer — isLaunching prevents background override
        store.dispatch(.resumeCard(cardId: cardId))
        KanbanLog.info("resume", "Starting resume for card=\(cardId.prefix(12)) session=\(sessionId.prefix(8))")

        Task {
            do {
                let settings = try? await settingsStore.read()
                let project = settings?.projects.first(where: { $0.path == projectPath })

                let shellOverride: String?
                let extraEnv: [String: String]

                if let project, project.remoteConfig != nil {
                    try? RemoteShellManager.deploy()
                    shellOverride = RemoteShellManager.shellOverridePath(for: project)
                    extraEnv = RemoteShellManager.setupEnvironment(for: project)

                    if let remote = project.remoteConfig {
                        let syncName = "kanban-\((project.path as NSString).lastPathComponent)"
                        let remoteDest = "\(remote.host):\(remote.remotePath)"
                        try? await mutagenAdapter.startSync(
                            localPath: remote.localPath,
                            remotePath: remoteDest,
                            name: syncName
                        )
                    }
                } else {
                    shellOverride = nil
                    extraEnv = [:]
                }

                let actualTmuxName = try await launcher.resume(
                    sessionId: sessionId,
                    projectPath: projectPath,
                    shellOverride: shellOverride,
                    extraEnv: extraEnv
                )
                KanbanLog.info("resume", "Resume launched for card=\(cardId.prefix(12)) actualTmux=\(actualTmuxName)")

                store.dispatch(.resumeCompleted(cardId: cardId, tmuxName: actualTmuxName))
            } catch {
                KanbanLog.info("resume", "Resume failed for card=\(cardId.prefix(12)): \(error.localizedDescription)")
                store.dispatch(.resumeFailed(cardId: cardId, error: error.localizedDescription))
            }
        }
    }
}
