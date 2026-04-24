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
    let promptImagePaths: [String]
    let assistant: CodingAssistant
    let apiServiceId: String?

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
        sessionId: String? = nil,
        promptImagePaths: [String] = [],
        assistant: CodingAssistant = .claude,
        apiServiceId: String? = nil
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
        self.promptImagePaths = promptImagePaths
        self.assistant = assistant
        self.apiServiceId = apiServiceId
    }
}

/// Tiny Identifiable wrapper so `.sheet(item:)` can present the rename dialog
/// keyed on the channel name.
private struct RenameTarget: Identifiable, Equatable {
    let name: String
    var id: String { name }
}

struct ContentView: View {
    // Properties are internal (not private) to allow extensions in separate files
    @State var store: BoardStore
    @State var orchestrator: BackgroundOrchestrator
    @State var channelsWatcher: ChannelsWatcher = ChannelsWatcher()
    @State var shareController: ChannelShareController = ChannelShareController()
    @State var searchInitialQuery = ""
    @State var terminalHadFocusBeforeSearch = false
    @State var deepSearchTrigger = false
    @AppStorage("showBoardInExpanded") var showBoardInExpanded = false
    @State var sidebarVisibility: NavigationSplitViewVisibility = .detailOnly
    @State var showNewTask = false
    @State var showOnboarding = false
    @State var showCreateChannel = false
    @State var renameChannelName: String? = nil
    @AppStorage("appearanceMode") var appearanceMode: AppearanceMode = .auto
    @AppStorage("boardViewMode") var boardViewModeRaw = BoardViewMode.kanban.rawValue
    @State var showProcessManager = false
    @State var showQuitConfirmation = false
    @State var quitOwnedSessions: [TmuxSession] = []
    @AppStorage("killTmuxOnQuit") var killTmuxOnQuit = true
    @AppStorage("uiTextSize") var uiTextSize: Int = 1
    @AppStorage("detailExpanded") var detailExpandedPersisted = false
    @AppStorage("selectedCardId") var selectedCardIdPersisted = ""
    @State var showAddFromPath = false
    @State var isDroppingFolder = false
    @State var isDroppingImage = false
    @State var addFromPathText = ""
    @State var renamingCardId: String?
    @State var pendingTerminalSession: String?
    @State var showAddLinkCardId: String?
    @State var launchConfig: LaunchConfig?
    @State var syncStatuses: [String: SyncStatus] = [:]
    @State var isSyncRefreshing = false
    @State var showSyncPopover = false
    @State var rawSyncOutput = ""
    @State var editingQueuedPromptId: String?
    @State var isToolbarMerging = false
    @State var toolbarMergeError: String?
    // showSearch and isExpandedDetail live in AppState (store.state.paletteOpen / detailExpanded)
    var showSearch: Bool {
        get { store.state.paletteOpen }
        nonmutating set { store.dispatch(.setPaletteOpen(newValue)) }
    }
    var isExpandedDetail: Bool {
        get { store.state.detailExpanded }
        nonmutating set { store.dispatch(.setDetailExpanded(newValue)) }
    }
    @State var detailTab: DetailTab = .terminal
    @State var actionsMenuProvider = ActionsMenuProvider()
    @AppStorage("preferredEditorBundleId") var editorBundleId: String = "dev.zed.Zed"
    @AppStorage("selectedProject") var selectedProjectPersisted: String = ""
    @AppStorage("defaultAssistant") var defaultAssistantRaw: String = CodingAssistant.claude.rawValue
    var defaultAssistant: CodingAssistant {
        CodingAssistant(rawValue: defaultAssistantRaw) ?? .claude
    }
    let settingsStore: SettingsStore
    let assistantRegistry: CodingAssistantRegistry
    let launcher: LaunchSession
    let tmuxAdapter: TmuxAdapter
    let systemTray = SystemTray()
    let mutagenAdapter = MutagenAdapter()
    let hookEventsPath: String
    let settingsFilePath: String

    @State var pendingWorktreeCleanup: WorktreeCleanupInfo?
    @State var shouldFocusTerminal = false
    @State var keyMonitor: Any?

    private var boardViewMode: BoardViewMode {
        BoardViewMode(rawValue: boardViewModeRaw) ?? .kanban
    }

    private var viewModePicker: some View {
        Picker("View", selection: viewModePickerBinding) {
            ForEach(BoardViewMode.allCases, id: \.self) { mode in
                Image(systemName: mode.icon)
                    .tag(Optional(mode))
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    /// Binding for the view mode picker — toggles between kanban and expanded+sidebar.
    private var viewModePickerBinding: Binding<BoardViewMode?> {
        Binding(
            get: { isExpandedDetail ? .list : .kanban },
            set: { newMode in
                guard let newMode else { return }
                if newMode == .list {
                    isExpandedDetail = true
                    showBoardInExpanded = true
                } else {
                    isExpandedDetail = false
                }
                boardViewModeRaw = newMode.rawValue
            }
        )
    }

    private var showInspector: Binding<Bool> {
        Binding(
            get: { store.state.openDrawer != .none },
            set: { visible in
                if !visible { store.dispatch(.closeDrawer) }
            }
        )
    }

    init() {
        let claudeDiscovery = ClaudeCodeSessionDiscovery()
        let claudeDetector = ClaudeCodeActivityDetector()
        let claudeStore = ClaudeCodeSessionStore()
        let geminiDiscovery = GeminiSessionDiscovery()
        let geminiDetector = GeminiActivityDetector()
        let geminiStore = GeminiSessionStore()
        let codexDiscovery = CodexSessionDiscovery()
        let codexDetector = CodexActivityDetector()
        let codexStore = CodexSessionStore()

        let enabledAssistants = Self.loadEnabledAssistants()
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
        let tmux = TmuxAdapter()

        let effectHandler = EffectHandler(
            coordinationStore: coordination,
            tmuxAdapter: tmux,
            setClipboardImage: { data in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setData(data, forType: .png)
            },
            notifier: MacOSNotificationClient()
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
        let (pushover, pushoverMode) = Self.loadPushoverConfig()
        let notifier = CompositeNotifier(primary: pushover, fallback: MacOSNotificationClient(), pushoverMode: pushoverMode)

        let orch = BackgroundOrchestrator(
            discovery: discovery,
            coordinationStore: coordination,
            activityDetector: activityDetector,
            tmux: tmux,
            prTracker: GhCliAdapter(),
            notifier: notifier,
            registry: registry
        )

        let launch = LaunchSession(tmux: tmux)

        orch.setDispatch { [weak boardStore] action in
            boardStore?.dispatch(action)
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

        _store = State(initialValue: boardStore)
        _orchestrator = State(initialValue: orch)
        self.settingsStore = settings
        self.assistantRegistry = registry
        self.launcher = launch
        self.tmuxAdapter = tmux
        self.hookEventsPath = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".kanban-code/hook-events.jsonl")
        self.settingsFilePath = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".kanban-code/settings.json")

        // Set sidebar visibility synchronously too
        if persistedExpanded && UserDefaults.standard.bool(forKey: "showBoardInExpanded") {
            _sidebarVisibility = State(initialValue: .doubleColumn)
        }
    }

    private static func loadEnabledAssistants() -> [CodingAssistant] {
        let settingsPath = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".kanban-code/settings.json")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
              let settings = try? JSONDecoder().decode(Settings.self, from: data) else {
            return CodingAssistant.allCases
        }
        return settings.enabledAssistants
    }

    private static func loadPushoverConfig() -> (client: PushoverClient?, mode: PushoverMode) {
        let settingsPath = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".kanban-code/settings.json")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
              let settings = try? JSONDecoder().decode(Settings.self, from: data) else {
            return (nil, .disabled)
        }

        let mode = settings.notifications.pushoverMode
        guard mode != .disabled,
              let token = settings.notifications.pushoverToken,
              let user = settings.notifications.pushoverUserKey,
              !token.isEmpty, !user.isEmpty else {
            return (nil, .disabled)
        }
        return (PushoverClient(token: token, userKey: user), mode)
    }

    private func updateRegisteredAssistants(_ enabled: [CodingAssistant]) {
        for assistant in CodingAssistant.allCases {
            if enabled.contains(assistant) {
                // Re-register if not already registered
                if assistantRegistry.discovery(for: assistant) == nil {
                    switch assistant {
                    case .claude:
                        assistantRegistry.register(.claude, discovery: ClaudeCodeSessionDiscovery(), detector: ClaudeCodeActivityDetector(), store: ClaudeCodeSessionStore())
                    case .gemini:
                        assistantRegistry.register(.gemini, discovery: GeminiSessionDiscovery(), detector: GeminiActivityDetector(), store: GeminiSessionStore())
                    case .codex:
                        assistantRegistry.register(.codex, discovery: CodexSessionDiscovery(), detector: CodexActivityDetector(), store: CodexSessionStore())
                    }
                }
            } else {
                assistantRegistry.unregister(assistant)
            }
        }
    }

    private var boardView: some View {
        BoardView(
            store: store,
            onOpenChannel: { name in store.dispatch(.selectChannel(name: name)) },
            onNewChannel: { showCreateChannel = true },
            onDeleteChannel: { name in store.dispatch(.showDialog(.confirmDeleteChannel(name: name))) },
            onRenameChannel: { name in renameChannelName = name },
            unreadCountForChannel: { ch in unreadCount(for: ch) },
            onlineCountForChannel: { ch in onlineCount(for: ch) },
            onStartCard: { cardId in startCard(cardId: cardId) },
            onResumeCard: { cardId in resumeCard(cardId: cardId) },
            onForkCard: { cardId, _ in store.dispatch(.showDialog(.confirmFork(cardId: cardId))) },
            onCopyResumeCmd: { cardId in
                guard let card = store.state.cards.first(where: { $0.id == cardId }) else { return }
                var cmd = ""
                if let projectPath = card.link.projectPath {
                    cmd += "cd \(projectPath) && "
                }
                if let sessionId = card.link.sessionLink?.sessionId {
                    cmd += card.link.effectiveAssistant.resumeCommand(sessionId: sessionId, skipPermissions: false)
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(cmd, forType: .string)
            },
            onDiscoverCard: { cardId in
                Task {
                    store.dispatch(.setBusy(cardId: cardId, busy: true))
                    if let updatedLink = await orchestrator.discoverBranchesForCard(cardId: cardId) {
                        store.dispatch(.createManualTask(updatedLink))
                    }
                    await store.reconcile()
                    store.dispatch(.setBusy(cardId: cardId, busy: false))
                }
            },
            onCleanupWorktree: { cardId in Task { await cleanupWorktree(cardId: cardId) } },
            canCleanupWorktree: { cardId in
                guard let card = store.state.cards.first(where: { $0.id == cardId }) else { return false }
                return canCleanupWorktree(for: card)
            },
            onArchiveCard: { cardId in archiveCard(cardId: cardId) },
            onDeleteCard: { cardId in store.dispatch(.showDialog(.confirmDelete(cardId: cardId))) },
            availableProjects: projectList,
            onMoveToProject: { cardId, projectPath in
                let name = projectList.first(where: { $0.path == projectPath })?.name ?? (projectPath as NSString).lastPathComponent
                store.dispatch(.showDialog(.confirmMoveToProject(cardId: cardId, projectPath: projectPath, projectName: name)))
            },
            onMoveToFolder: { cardId in selectFolderForMove(cardId: cardId) },
            enabledAssistants: assistantRegistry.available,
            onMigrateAssistant: { cardId, target in
                store.dispatch(.showDialog(.confirmMigration(cardId: cardId, targetAssistant: target)))
            },
            onRefreshBacklog: { Task { await store.refreshBacklog() } },
            canDropCard: { card, column in
                CardDropIntent.resolve(card, to: column).isAllowed
            },
            onDropCard: { cardId, column in handleDrop(cardId: cardId, to: column) },
            onMergeCards: { sourceId, targetId in
                store.dispatch(.mergeCards(sourceId: sourceId, targetId: targetId))
            },
            onNewTask: { presentNewTask() },
            onCardClicked: { cardId in
                if store.state.cards.first(where: { $0.id == cardId })?.link.tmuxLink != nil {
                    shouldFocusTerminal = true
                }
            },
            onColumnBackgroundClick: { column in
                handleColumnBackgroundClick(column)
            }
        )
    }

    /// List view for sidebar — no top padding, marked as sidebar context.
    private var sidebarListView: some View {
        ListBoardView(
            store: store,
            onOpenChannel: { name in store.dispatch(.selectChannel(name: name)) },
            onNewChannel: { showCreateChannel = true },
            onDeleteChannel: { name in store.dispatch(.showDialog(.confirmDeleteChannel(name: name))) },
            onRenameChannel: { name in renameChannelName = name },
            unreadCountForChannel: { ch in unreadCount(for: ch) },
            onlineCountForChannel: { ch in onlineCount(for: ch) },
            onStartCard: { cardId in startCard(cardId: cardId) },
            onResumeCard: { cardId in resumeCard(cardId: cardId) },
            onForkCard: { cardId, _ in store.dispatch(.showDialog(.confirmFork(cardId: cardId))) },
            onCopyResumeCmd: { cardId in
                guard let card = store.state.cards.first(where: { $0.id == cardId }) else { return }
                var cmd = ""
                if let projectPath = card.link.projectPath {
                    cmd += "cd \(projectPath) && "
                }
                if let sessionId = card.link.sessionLink?.sessionId {
                    cmd += card.link.effectiveAssistant.resumeCommand(sessionId: sessionId, skipPermissions: false)
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(cmd, forType: .string)
            },
            onDiscoverCard: { cardId in
                Task {
                    store.dispatch(.setBusy(cardId: cardId, busy: true))
                    if let updatedLink = await orchestrator.discoverBranchesForCard(cardId: cardId) {
                        store.dispatch(.createManualTask(updatedLink))
                    }
                    await store.reconcile()
                    store.dispatch(.setBusy(cardId: cardId, busy: false))
                }
            },
            onCleanupWorktree: { cardId in Task { await cleanupWorktree(cardId: cardId) } },
            canCleanupWorktree: { cardId in
                guard let card = store.state.cards.first(where: { $0.id == cardId }) else { return false }
                return canCleanupWorktree(for: card)
            },
            onArchiveCard: { cardId in archiveCard(cardId: cardId) },
            onDeleteCard: { cardId in store.dispatch(.showDialog(.confirmDelete(cardId: cardId))) },
            availableProjects: projectList,
            onMoveToProject: { cardId, projectPath in
                let name = projectList.first(where: { $0.path == projectPath })?.name ?? (projectPath as NSString).lastPathComponent
                store.dispatch(.showDialog(.confirmMoveToProject(cardId: cardId, projectPath: projectPath, projectName: name)))
            },
            onMoveToFolder: { cardId in selectFolderForMove(cardId: cardId) },
            enabledAssistants: assistantRegistry.available,
            onMigrateAssistant: { cardId, target in
                store.dispatch(.showDialog(.confirmMigration(cardId: cardId, targetAssistant: target)))
            },
            onRefreshBacklog: { Task { await store.refreshBacklog() } },
            onDropCard: { cardId, column in handleDrop(cardId: cardId, to: column) },
            onMergeCards: { sourceId, targetId in
                store.dispatch(.mergeCards(sourceId: sourceId, targetId: targetId))
            },
            canDropCard: { card, column in
                CardDropIntent.resolve(card, to: column).isAllowed
            },
            onNewTask: { showNewTask = true },
            onCardClicked: { cardId in
                if store.state.cards.first(where: { $0.id == cardId })?.link.tmuxLink != nil {
                    shouldFocusTerminal = true
                }
            },
            onRenameCard: { cardId, name in
                store.dispatch(.renameCard(cardId: cardId, name: name))
            },
            inSidebar: true
        )
    }

    /// Sidebar content for expanded mode — always list view.
    /// Toolbar items only included when sidebar is visible to avoid duplication in window toolbar.
    private var sidebarContent: some View {
        sidebarListView
            .toolbar {
                if showBoardInExpanded {
                    ToolbarItemGroup(placement: .automatic) {
                        Button { presentNewTask() } label: {
                            Image(systemName: "square.and.pencil")
                        }
                        .help("New task (⌘N)")

                        Button { showCreateChannel = true } label: {
                            Image(systemName: "number")
                        }
                        .help("New chat channel")

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
                }
            }
    }

    /// Shared factory for CardDetailView — used by both the inspector and expanded mode.
    private func makeCardDetailView(card: KanbanCodeCard) -> CardDetailView {
        CardDetailView(
            card: card,
            sessionStore: assistantRegistry.store(for: card.link.effectiveAssistant) ?? store.sessionStore,
            selectedTab: $detailTab,
            pendingTerminalSession: $pendingTerminalSession,
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
                store.dispatch(.unlinkFromCard(cardId: card.id, linkType: linkType))
            },
            onAddBranch: { branch in
                store.dispatch(.addBranchToCard(cardId: card.id, branch: branch))
            },
            onAddIssue: { number in
                store.dispatch(.addIssueLinkToCard(cardId: card.id, issueNumber: number))
            },
            onAddPR: { number in
                store.dispatch(.addPRToCard(cardId: card.id, prNumber: number))
            },
            onCleanupWorktree: {
                Task { await cleanupWorktree(cardId: card.id) }
            },
            canCleanupWorktree: canCleanupWorktree(for: card),
            onDeleteCard: {
                store.dispatch(.showDialog(.confirmDelete(cardId: card.id)))
            },
            onCreateTerminal: {
                createExtraTerminal(cardId: card.id)
            },
            onKillTerminal: { sessionName in
                store.dispatch(.killTerminal(cardId: card.id, sessionName: sessionName))
            },
            onRenameTerminal: { sessionName, label in
                store.dispatch(.renameTerminalTab(cardId: card.id, sessionName: sessionName, label: label))
            },
            onReorderTerminal: { sessionName, beforeSession in
                store.dispatch(.reorderTerminalTab(cardId: card.id, sessionName: sessionName, beforeSession: beforeSession))
            },
            onPRMerged: { prNumber in
                store.dispatch(.markPRMerged(cardId: card.id, prNumber: prNumber))
            },
            onCancelLaunch: {
                store.dispatch(.cancelLaunch(cardId: card.id))
            },
            onAddQueuedPrompt: { prompt in
                store.dispatch(.addQueuedPrompt(cardId: card.id, prompt: prompt))
            },
            onUpdateQueuedPrompt: { promptId, body, sendAuto in
                store.dispatch(.updateQueuedPrompt(cardId: card.id, promptId: promptId, body: body, sendAutomatically: sendAuto))
            },
            onRemoveQueuedPrompt: { promptId in
                store.dispatch(.removeQueuedPrompt(cardId: card.id, promptId: promptId))
            },
            onSendQueuedPrompt: { promptId in
                store.dispatch(.sendQueuedPrompt(cardId: card.id, promptId: promptId))
            },
            onReorderQueuedPrompts: { promptIds in
                store.dispatch(.reorderQueuedPrompts(cardId: card.id, promptIds: promptIds))
            },
            onEditingQueuedPrompt: { promptId in
                if let prev = editingQueuedPromptId {
                    orchestrator.clearPromptEditing(prev)
                }
                editingQueuedPromptId = promptId
                if let promptId {
                    orchestrator.markPromptEditing(promptId)
                }
            },
            onAddBrowserTab: { tabId, url in
                store.dispatch(.addBrowserTab(cardId: card.id, tabId: tabId, url: url))
            },
            onRemoveBrowserTab: { tabId in
                store.dispatch(.removeBrowserTab(cardId: card.id, tabId: tabId))
            },
            onUpdateBrowserTab: { tabId, url, title in
                store.dispatch(.updateBrowserTab(cardId: card.id, tabId: tabId, url: url, title: title))
            },
            onDiscover: {
                Task {
                    store.dispatch(.setBusy(cardId: card.id, busy: true))
                    if let updatedLink = await orchestrator.discoverBranchesForCard(cardId: card.id) {
                        store.dispatch(.createManualTask(updatedLink))
                    }
                    await store.reconcile()
                    store.dispatch(.setBusy(cardId: card.id, busy: false))
                }
            },
            onUpdatePrompt: { body, imagePaths in
                store.dispatch(.updatePrompt(cardId: card.id, body: body, imagePaths: imagePaths))
            },
            availableProjects: projectList,
            onMoveToProject: { projectPath in
                let name = projectList.first(where: { $0.path == projectPath })?.name ?? (projectPath as NSString).lastPathComponent
                store.dispatch(.showDialog(.confirmMoveToProject(cardId: card.id, projectPath: projectPath, projectName: name)))
            },
            onMoveToFolder: { selectFolderForMove(cardId: card.id) },
            enabledAssistants: assistantRegistry.available,
            onMigrateAssistant: { target in
                store.dispatch(.showDialog(.confirmMigration(cardId: card.id, targetAssistant: target)))
            },
            actionsMenuProvider: actionsMenuProvider,
            focusTerminal: $shouldFocusTerminal,
            isExpanded: Binding(
                get: { isExpandedDetail },
                set: { isExpandedDetail = $0 }
            ),
            isDroppingImage: $isDroppingImage
        )
    }

    @ViewBuilder
    private var inspectorContent: some View {
        if let dm = store.state.selectedDMParticipant {
            dmChatContent(other: dm)
        } else if let name = store.state.selectedChannelName,
                  let ch = store.state.channels.first(where: { $0.name == name }) {
            channelChatContent(channel: ch)
        } else if let card = store.state.selectedCard {
            makeCardDetailView(card: card)
        }
    }

    /// Empty state shown in expanded mode when no card is selected.
    private var expandedEmptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 48))
                .foregroundStyle(.quaternary)
            Text("Select a session or start a new one")
                .font(.app(.title3))
                .foregroundStyle(.secondary)
            Text("⌘N to create a new task")
                .font(.app(.caption))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var boardWithOverlays: some View {
        Group {
            if isExpandedDetail {
                if let dm = store.state.selectedDMParticipant {
                    dmChatContent(other: dm)
                } else if let name = store.state.selectedChannelName,
                          let ch = store.state.channels.first(where: { $0.name == name }) {
                    channelChatContent(channel: ch)
                } else if let card = store.state.selectedCard {
                    makeCardDetailView(card: card)
                } else {
                    expandedEmptyState
                }
            } else {
                // Normal: kanban board with inspector.
                // When a channel/DM is selected the inspector shows chat instead of card detail.
                boardView
                    .ignoresSafeArea(edges: .top)
                    .inspector(isPresented: showInspector) {
                        inspectorContent
                            .inspectorColumnWidth(min: 600, ideal: 800, max: 1000)
                    }
            }
        }
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .navigationTitle("")
            .onChange(of: store.state.selectedCardId) {
                if let cardId = store.state.selectedCardId,
                   let card = store.state.cards.first(where: { $0.id == cardId }) {
                    detailTab = DetailTab.initialTab(for: card)
                    // Auto-focus terminal on any card switch (not just click).
                    // Covers Cmd+K, arrow nav, notification taps, url deep-links.
                    if card.link.tmuxLink != nil {
                        shouldFocusTerminal = true
                    }
                }
                selectedCardIdPersisted = store.state.selectedCardId ?? ""
            }
            .onChange(of: store.state.detailExpanded) {
                if !store.state.detailExpanded {
                    showBoardInExpanded = false
                    sidebarVisibility = .detailOnly
                    boardViewModeRaw = BoardViewMode.kanban.rawValue
                }
                detailExpandedPersisted = store.state.detailExpanded
            }
            .onChange(of: showBoardInExpanded) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    sidebarVisibility = (isExpandedDetail && showBoardInExpanded)
                        ? .doubleColumn : .detailOnly
                }
            }
            .onChange(of: sidebarVisibility) {
                // Sync built-in sidebar toggle back to our state
                showBoardInExpanded = (sidebarVisibility != .detailOnly)
            }
            .overlay {
                FolderDropZone(isTargeted: $isDroppingFolder) { url in
                    addDroppedFolder(url)
                }
                .allowsHitTesting(isDroppingFolder)
            }
            .overlay {
                if isDroppingFolder {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(style: StrokeStyle(lineWidth: 3, dash: [8, 4]))
                        .foregroundStyle(Color.accentColor)
                        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        .overlay {
                            VStack(spacing: 8) {
                                Image(systemName: "folder.badge.plus")
                                    .font(.app(size: 40))
                                    .foregroundStyle(Color.accentColor)
                                Text("Drop to add project")
                                    .font(.app(.title3, weight: .medium))
                                    .foregroundStyle(.primary)
                            }
                        }
                        .padding(20)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: isDroppingFolder)
            .overlay {
                if let card = store.state.selectedCard,
                   let sessionName = card.link.tmuxLink?.sessionName {
                    ImageDropZone(isTargeted: $isDroppingImage) { imageData in
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setData(imageData, forType: .png)
                        Task {
                            try? await self.tmuxAdapter.sendBracketedPaste(to: sessionName)
                            // Send Enter after image paste so Claude processes it
                            let _ = try? await ShellCommand.run(
                                ShellCommand.findExecutable("tmux") ?? "tmux",
                                arguments: ["send-keys", "-t", sessionName, "Enter"]
                            )
                        }
                    }
                    .allowsHitTesting(isDroppingImage)
                } else {
                    // No terminal open — don't show image drop zone
                    Color.clear
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: isDroppingImage)
    }

    private var boardWithSheets: some View {
        boardWithOverlays
            .sheet(isPresented: $showNewTask) {
                NewTaskDialog(
                    isPresented: $showNewTask,
                    projects: store.state.configuredProjects,
                    defaultProjectPath: store.state.selectedProjectPath,
                    globalRemoteSettings: store.state.globalRemoteSettings,
                    enabledAssistants: assistantRegistry.available,
                    onCreate: { prompt, projectPath, title, startImmediately, images in
                        createManualTask(prompt: prompt, projectPath: projectPath, title: title, startImmediately: startImmediately, images: images)
                    },
                    onCreateAndLaunch: { prompt, projectPath, title, createWorktree, runRemotely, skipPermissions, commandOverride, images, assistant, apiServiceId in
                        createManualTaskAndLaunch(prompt: prompt, projectPath: projectPath, title: title, createWorktree: createWorktree, runRemotely: runRemotely, skipPermissions: skipPermissions, commandOverride: commandOverride, images: images, assistant: assistant, apiServiceId: apiServiceId)
                    }
                )
            }
            .sheet(isPresented: $showAddFromPath) {
                addFromPathSheet
            }
            .sheet(isPresented: $showCreateChannel) {
                CreateChannelDialog(isPresented: $showCreateChannel) { name in
                    store.dispatch(.createChannel(name: name))
                }
            }
            .sheet(item: Binding(
                get: { renameChannelName.map { RenameTarget(name: $0) } },
                set: { renameChannelName = $0?.name }
            )) { target in
                RenameChannelDialog(
                    isPresented: Binding(
                        get: { renameChannelName != nil },
                        set: { if !$0 { renameChannelName = nil } }
                    ),
                    currentName: target.name
                ) { newName in
                    store.dispatch(.renameChannel(old: target.name, new: newName))
                }
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
                    promptImagePaths: config.promptImagePaths,
                    assistant: config.assistant,
                    initialServiceId: config.apiServiceId,
                    isPresented: Binding(
                        get: { launchConfig != nil },
                        set: { if !$0 { launchConfig = nil } }
                    )
                ) { editedPrompt, createWorktree, worktreeBranch, runRemotely, skipPermissions, commandOverride, images, selectedServiceId in
                    if config.isResume {
                        executeResume(cardId: config.cardId, runRemotely: runRemotely, skipPermissions: skipPermissions, commandOverride: commandOverride, assistant: config.assistant, serviceIdOverride: selectedServiceId)
                    } else {
                        let wtName: String? = createWorktree ? (worktreeBranch ?? config.worktreeName ?? "") : nil
                        executeLaunch(cardId: config.cardId, prompt: editedPrompt, projectPath: config.projectPath, worktreeName: wtName, runRemotely: runRemotely, skipPermissions: skipPermissions, commandOverride: commandOverride, images: images, assistant: config.assistant, serviceIdOverride: selectedServiceId)
                    }
                }
            }
            .sheet(isPresented: $showOnboarding) {
                OnboardingWizard(
                    settingsStore: settingsStore,
                    onComplete: {
                        showOnboarding = false
                        let (pushover, mode) = Self.loadPushoverConfig()
                        let newNotifier = CompositeNotifier(primary: pushover, fallback: MacOSNotificationClient(), pushoverMode: mode)
                        orchestrator.updateNotifier(newNotifier)
                    }
                )
            }
            .sheet(isPresented: Binding(
                get: { renamingCardId != nil },
                set: { if !$0 { renamingCardId = nil } }
            )) {
                if let cardId = renamingCardId, let card = store.state.cards.first(where: { $0.id == cardId }) {
                    RenameSessionDialog(
                        currentName: card.link.name ?? card.displayTitle,
                        isPresented: Binding(get: { renamingCardId != nil }, set: { if !$0 { renamingCardId = nil } }),
                        onRename: { name in store.dispatch(.renameCard(cardId: cardId, name: name)) }
                    )
                }
            }
            .sheet(isPresented: $showProcessManager) {
                ProcessManagerView(
                    store: store,
                    isPresented: $showProcessManager,
                    onSelectCard: { cardId, terminalSession in
                        store.dispatch(.selectCard(cardId: cardId))
                        pendingTerminalSession = terminalSession
                        shouldFocusTerminal = true
                    }
                )
            }
            .popover(isPresented: Binding(
                get: { showAddLinkCardId != nil },
                set: { if !$0 { showAddLinkCardId = nil } }
            )) {
                if let cardId = showAddLinkCardId {
                    AddLinkPopover(
                        onAddBranch: { branch in
                            store.dispatch(.addBranchToCard(cardId: cardId, branch: branch))
                            showAddLinkCardId = nil
                        },
                        onAddIssue: { number in
                            store.dispatch(.addIssueLinkToCard(cardId: cardId, issueNumber: number))
                            showAddLinkCardId = nil
                        },
                        onAddPR: { number in
                            store.dispatch(.addPRToCard(cardId: cardId, prNumber: number))
                            showAddLinkCardId = nil
                        }
                    )
                }
            }
    }

    // MARK: - Global Dialog

    private var dialogTitle: String {
        switch store.state.activeDialog {
        case .none: return ""
        case .confirmDelete: return "Delete Card"
        case .confirmArchive: return "Archive Card?"
        case .confirmFork: return "Fork Session?"
        case .confirmCheckpoint: return "Restore to this point?"
        case .confirmWorktreeCleanup: return "Cleanup Worktree?"
        case .confirmMoveToProject: return "Move to Project?"
        case .confirmMoveToFolder: return "Move to Folder?"
        case .confirmMigration: return "Migrate Session?"
        case .remoteWorktreeCleanup: return "Remote Worktree"
        case .confirmDeleteChannel(let name): return "Delete #\(name)?"
        }
    }

    @ViewBuilder
    private var dialogButtons: some View {
        switch store.state.activeDialog {
        case .none: EmptyView()
        case .confirmDelete(let cardId):
            Button("Cancel", role: .cancel) { store.dispatch(.dismissDialog) }
            Button("Delete", role: .destructive) {
                let card = store.state.cards.first(where: { $0.id == cardId })
                let nextId = cardIdAfterDeletion(cardId)
                store.dispatch(.deleteCard(cardId: cardId))
                store.dispatch(.dismissDialog)
                if let nextId { store.dispatch(.selectCard(cardId: nextId)) }
                offerWorktreeCleanupIfNeeded(card: card)
            }
        case .confirmArchive(let cardId):
            Button("Cancel", role: .cancel) { store.dispatch(.dismissDialog) }
            Button("Archive & Kill Terminals", role: .destructive) {
                let card = store.state.cards.first(where: { $0.id == cardId })
                store.dispatch(.archiveCard(cardId: cardId))
                store.dispatch(.dismissDialog)
                offerWorktreeCleanupIfNeeded(card: card)
            }
        case .confirmFork(let cardId):
            Button("Cancel", role: .cancel) { store.dispatch(.dismissDialog) }
            if store.state.cards.first(where: { $0.id == cardId })?.link.worktreeLink != nil {
                Button("Fork (same worktree)") {
                    forkCard(cardId: cardId, keepWorktree: true)
                    store.dispatch(.dismissDialog)
                }
            }
            Button("Fork (project root)") {
                forkCard(cardId: cardId)
                store.dispatch(.dismissDialog)
            }
        case .confirmCheckpoint(let cardId, _, let turnLineNumber):
            Button("Cancel", role: .cancel) { store.dispatch(.dismissDialog) }
            Button("Restore", role: .destructive) {
                Task { await performCheckpoint(cardId: cardId, turnLineNumber: turnLineNumber) }
                store.dispatch(.dismissDialog)
            }
        case .confirmWorktreeCleanup(let cardId):
            Button("Keep Worktree", role: .cancel) { store.dispatch(.dismissDialog) }
            Button("Remove Worktree", role: .destructive) {
                Task { await cleanupWorktree(cardId: cardId) }
                store.dispatch(.dismissDialog)
            }
        case .confirmMoveToProject(let cardId, let projectPath, _):
            Button("Cancel", role: .cancel) { store.dispatch(.dismissDialog) }
            Button("Move") {
                store.dispatch(.moveCardToProject(cardId: cardId, projectPath: projectPath))
                store.dispatch(.dismissDialog)
            }
        case .confirmMoveToFolder(let cardId, let folderPath, let parentProjectPath, _):
            Button("Cancel", role: .cancel) { store.dispatch(.dismissDialog) }
            Button("Move") {
                store.dispatch(.moveCardToFolder(cardId: cardId, folderPath: folderPath, parentProjectPath: parentProjectPath))
                store.dispatch(.dismissDialog)
            }
        case .confirmMigration(let cardId, let targetAssistant):
            Button("Cancel", role: .cancel) { store.dispatch(.dismissDialog) }
            Button("Migrate") {
                Task { await executeMigration(cardId: cardId, targetAssistant: targetAssistant) }
                store.dispatch(.dismissDialog)
            }
        case .remoteWorktreeCleanup(let cardId, _, let localPath, _):
            Button("Cancel", role: .cancel) { store.dispatch(.dismissDialog) }
            Button("Cleanup Local Copy", role: .destructive) {
                Task { await executeLocalWorktreeCleanup(cardId: cardId, localPath: localPath) }
                store.dispatch(.dismissDialog)
            }
        case .confirmDeleteChannel(let name):
            Button("Cancel", role: .cancel) { store.dispatch(.dismissDialog) }
            Button("Delete #\(name)", role: .destructive) {
                store.dispatch(.deleteChannel(name: name))
                store.dispatch(.dismissDialog)
            }
        }
    }

    @ViewBuilder
    private var dialogMessage: some View {
        switch store.state.activeDialog {
        case .none: EmptyView()
        case .confirmDelete: Text("This will permanently delete this card and its data.")
        case .confirmArchive: Text("This card has running terminals. Archiving will kill them.")
        case .confirmFork(let cardId):
            if store.state.cards.first(where: { $0.id == cardId })?.link.worktreeLink != nil {
                Text("This creates a duplicate session you can resume independently. Do you want the forked session to continue from the same worktree or from the project root?")
            } else {
                Text("This creates a duplicate session you can resume independently.")
            }
        case .confirmCheckpoint: Text("Everything after this point will be removed. A .bkp backup will be created.")
        case .confirmWorktreeCleanup: Text("This card has a worktree. Do you want to remove it?")
        case .confirmMoveToProject(_, _, let name): Text("Move this card to \(name)?")
        case .confirmMoveToFolder(_, let folderPath, let parentProjectPath, let displayName):
            let relative = folderPath.hasPrefix(parentProjectPath + "/")
                ? String(folderPath.dropFirst(parentProjectPath.count + 1)) : folderPath
            if folderPath != parentProjectPath {
                Text("Move session to \(relative) (under \(displayName))?")
            } else {
                Text("Move session to \(displayName)?")
            }
        case .confirmMigration(let cardId, let targetAssistant):
            let card = store.state.cards.first(where: { $0.id == cardId })
            let source = card?.link.effectiveAssistant.displayName ?? "current assistant"
            Text("Migrate from \(source) to \(targetAssistant.displayName)? A backup will be kept.")
        case .remoteWorktreeCleanup(_, _, _, let errorMessage): Text(errorMessage)
        case .confirmDeleteChannel(let name):
            Text("This removes the channel and its membership metadata. Messages in \(name).jsonl are left on disk so you can recover them manually if needed.")
        }
    }

    /// Offer worktree cleanup after archive/delete if applicable.
    private func offerWorktreeCleanupIfNeeded(card: KanbanCodeCard?) {
        guard let card, let wt = card.link.worktreeLink,
              !wt.path.isEmpty, wt.path.contains("/.claude/worktrees/"),
              canCleanupWorktree(for: card) else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            store.dispatch(.showDialog(.confirmWorktreeCleanup(cardId: card.id)))
        }
    }

    private var boardWithAlerts: some View {
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
            // Global dialog driven by store.state.activeDialog
            .alert(
                dialogTitle,
                isPresented: Binding(
                    get: { store.state.activeDialog != .none },
                    set: { if !$0 { store.dispatch(.dismissDialog) } }
                )
            ) {
                dialogButtons
            } message: {
                dialogMessage
            }
    }

    private var boardWithHandlers: some View {
        boardWithAlerts
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
                BrowserTabCacheRelay.removeAllHandler = { cardId in
                    BrowserTabCache.shared.removeAllForCard(cardId)
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
                    // Adaptive: 3s when active, 10s when backgrounded
                    let interval: Duration = store.appIsActive ? .seconds(3) : .seconds(10)
                    try? await Task.sleep(for: interval)
                    guard !Task.isCancelled else { break }
                    await store.reconcile()
                    systemTray.update()
                }
            }
            .task(id: "channels-bootstrap") {
                // Initial load + start the file-system watcher (no polling).
                store.dispatch(.refreshChannels)
                store.dispatch(.refreshChannelReadState)
                store.dispatch(.loadDrafts)
                channelsWatcher.start()
                // Load one-shot: the watcher will push changes from here on.
                for ch in store.state.channels {
                    store.dispatch(.refreshChannelMessages(channelName: ch.name))
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .kanbanCodeChannelsChanged)) { _ in
                store.dispatch(.refreshChannels)
                channelsWatcher.syncChannelLogs(store.state.channels.map(\.name))
            }
            .onReceive(NotificationCenter.default.publisher(for: .kanbanCodeChannelMessagesChanged)) { note in
                if let name = note.userInfo?["channelName"] as? String {
                    store.dispatch(.refreshChannelMessages(channelName: name))
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .kanbanCodeDMLogsChanged)) { _ in
                if let other = store.state.selectedDMParticipant {
                    store.dispatch(.refreshDMMessages(other: other))
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .kanbanCodeReadStateChanged)) { _ in
                store.dispatch(.refreshChannelReadState)
            }
            .onReceive(NotificationCenter.default.publisher(for: .kanbanCodeSelectChannel)) { note in
                if let name = note.userInfo?["channelName"] as? String {
                    store.dispatch(.selectChannel(name: name))
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .kanbanCodeSelectDM)) { note in
                if let handle = note.userInfo?["dmHandle"] as? String {
                    // Look up the card for this handle in any channel's membership.
                    var cardId: String?
                    for ch in store.state.channels {
                        if let m = ch.members.first(where: { $0.handle == handle }), let cid = m.cardId {
                            cardId = cid
                            break
                        }
                    }
                    let other = ChannelParticipant(cardId: cardId, handle: handle)
                    store.dispatch(.selectDM(other: other))
                }
            }
            .onAppear { installKeyMonitor() }
            .onDisappear {
                if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
                keyMonitor = nil
                channelsWatcher.stop()
            }
            .onReceive(NotificationCenter.default.publisher(for: .kanbanCodeToggleSearch)) { _ in
                if showSearch { closePalette() } else { openPalette() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .kanbanCodeNewTask)) { _ in
                presentNewTask()
            }
            .onReceive(NotificationCenter.default.publisher(for: .kanbanCodeHookEvent)) { _ in
                Task {
                    await orchestrator.processHookEvents()
                    await store.refreshActivity()
                    systemTray.update()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .kanbanCodeSelectCard)) { notification in
                if let cardId = notification.userInfo?["cardId"] as? String {
                    store.dispatch(.selectCard(cardId: cardId))
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .kanbanCodeOpenProject)) { notification in
                if let path = notification.userInfo?["path"] as? String {
                    openOrCreateProject(path: path)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .kanbanCodeAddLink)) { notification in
                if let cardId = notification.userInfo?["cardId"] as? String {
                    showAddLinkCardId = cardId
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .kanbanCodeSettingsChanged)) { _ in
                Task {
                    await store.loadSettingsAndCache()
                    await store.reconcile()
                    applyAppearance()
                    // Refresh notifier so Pushover credentials changes take effect immediately
                    let (pushover, mode) = Self.loadPushoverConfig()
                    let newNotifier = CompositeNotifier(primary: pushover, fallback: MacOSNotificationClient(), pushoverMode: mode)
                    orchestrator.updateNotifier(newNotifier)
                    // Update registry for enabled/disabled assistants
                    if let settings = try? await settingsStore.read() {
                        updateRegisteredAssistants(settings.enabledAssistants)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .kanbanCodeQuitRequested)) { _ in
                // Tear down any active channel shares first — they're the only
                // child processes we own that survive an unclean exit.
                Task { await shareController.stopAll() }
                let sessions = store.state.cards.compactMap { card -> TmuxSession? in
                    guard let tmux = card.link.tmuxLink else { return nil }
                    return TmuxSession(name: tmux.sessionName, path: card.link.projectPath ?? "")
                }
                if sessions.isEmpty {
                    NSApp.reply(toApplicationShouldTerminate: true)
                } else {
                    quitOwnedSessions = sessions
                    showQuitConfirmation = true
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
                store.dispatch(.setAppFrontmost(true))
                Task {
                    await store.reconcile()
                    systemTray.update()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                store.appIsActive = false
                store.dispatch(.setAppFrontmost(false))
            }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            sidebarContent
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 420)
        } detail: {
        boardWithHandlers
            .toolbar {
                // Use tested ToolbarVisibility model to drive all conditions
                let tbVis = ToolbarVisibility(
                    isExpandedDetail: isExpandedDetail,
                    showBoardInExpanded: showBoardInExpanded,
                    hasSelectedCard: store.state.selectedCardId != nil
                )

                if tbVis.showBoardControls {
                    ToolbarItemGroup(placement: .navigation) {
                        Button { presentNewTask() } label: {
                            Image(systemName: "square.and.pencil")
                        }
                        .help("New task (⌘N)")

                        Button { showCreateChannel = true } label: {
                            Image(systemName: "number")
                        }
                        .help("New chat channel")

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

                }

                ToolbarItem(placement: .navigation) {
                    projectSelectorMenu
                }

                if tbVis.showViewModePicker {
                    ToolbarItem(placement: .navigation) {
                        viewModePicker
                    }
                }

                ToolbarItem(placement: .navigation) {
                    if currentProjectHasRemote {
                        syncStatusView
                    }
                }

                if tbVis.showExpandedCardInfo, let card = store.state.selectedCard {
                    ToolbarItemGroup(placement: .navigation) {
                        HStack {
                            Text("⠀⠀" + card.displayTitle)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: 200)

                            if card.link.cardLabel == .session {
                                Text(card.relativeTime)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .fixedSize()
                            }

                            Picker("", selection: $detailTab) {
                                Text("Terminal").tag(DetailTab.terminal)
                                Text("History").tag(DetailTab.history)
                                if card.link.issueLink != nil { Text("Issue").tag(DetailTab.issue) }
                                if !card.link.prLinks.isEmpty { Text("Pull Request").tag(DetailTab.pullRequest) }
                                if card.link.promptBody != nil && card.link.issueLink == nil { Text("Prompt").tag(DetailTab.prompt) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                        }
                    }

                    if let pr = card.link.mergeablePR {
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                guard !isToolbarMerging, let repoRoot = card.link.projectPath else { return }
                                isToolbarMerging = true
                                toolbarMergeError = nil
                                Task {
                                    let gh = GhCliAdapter()
                                    let settings = try await SettingsStore().read()
                                    let result = try await gh.mergePR(repoRoot: repoRoot, prNumber: pr.number, commandTemplate: settings.github.mergeCommand)
                                    isToolbarMerging = false
                                    switch result {
                                    case .success:
                                        store.dispatch(.markPRMerged(cardId: card.id, prNumber: pr.number))
                                    case .failure(let msg):
                                        toolbarMergeError = msg
                                    }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    if isToolbarMerging {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Image(systemName: "arrow.triangle.merge")
                                    }
                                    Text("Merge")
                                }
                                .font(.app(size: 13))
                                .foregroundStyle(Color.green.opacity(0.8))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.green.opacity(0.08), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(isToolbarMerging)
                            .help("Merge PR #\(pr.number)")
                            .popover(isPresented: .init(get: { toolbarMergeError != nil }, set: { if !$0 { toolbarMergeError = nil } })) {
                                if let err = toolbarMergeError {
                                    Text(err).font(.app(.caption)).padding(8).frame(maxWidth: 300)
                                }
                            }
                        }
                    }

                    ToolbarSpacer(.fixed, placement: .primaryAction)

                    ToolbarItem(placement: .primaryAction) {
                        if let path = card.link.worktreeLink?.path ?? card.link.projectPath {
                            Button {
                                EditorDiscovery.open(path: path, bundleId: editorBundleId)
                            } label: {
                                Image(systemName: "chevron.left.forwardslash.chevron.right")
                            }
                            .help("Open in editor")
                        }
                    }

                    ToolbarItem(placement: .primaryAction) {
                        if let card = store.state.selectedCard {
                            expandedActionsMenu(for: card)
                        }
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Button { if showSearch { closePalette() } else { openPalette() } } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                            Text("Search")
                            Text("⌘P")
                                .font(.app(.caption))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                        }
                        .padding(.horizontal, 4)
                    }
                    .help("Search sessions (⌘K / ⌘P)")
                }

                if tbVis.showInspectorToggle {
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
            }
            .background { shortcutButtons }
        } // detail
        .toolbar(removing: .sidebarToggle)
        .overlay {
            if showSearch {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture { closePalette() }

                SearchOverlay(
                    isPresented: Binding(
                        get: { showSearch },
                        set: { if !$0 { closePalette() } }
                    ),
                    cards: store.state.cards,
                    sessionStore: store.sessionStore,
                    onSelectCard: { card in
                        switchToProjectIfNeeded(for: card)
                        store.dispatch(.selectCard(cardId: card.id))
                    },
                    onResumeCard: { card in
                        switchToProjectIfNeeded(for: card)
                        resumeCard(cardId: card.id)
                    },
                    onForkCard: { card in store.dispatch(.showDialog(.confirmFork(cardId: card.id))) },
                    onCheckpointCard: { card in
                        switchToProjectIfNeeded(for: card)
                        store.dispatch(.selectCard(cardId: card.id))
                    },
                    channels: store.state.channels,
                    channelLastOpened: store.state.channelLastOpened,
                    channelLastActivity: store.state.channels.reduce(into: [String: Date]()) { acc, ch in
                        if let ts = store.state.channelMessages[ch.name]?.last?.ts { acc[ch.name] = ts }
                    },
                    onSelectChannel: { name in
                        store.dispatch(.selectChannel(name: name))
                    },
                    commands: paletteCommands,
                    initialQuery: searchInitialQuery,
                    deepSearchTrigger: deepSearchTrigger
                )
                .padding(40)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: showSearch)
        .id(uiTextSize) // Force full re-render when UI scale changes
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
    /// Only needed for external edits (e.g. manual file editing).
    /// In-app settings changes post `.kanbanCodeSettingsChanged` directly.
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

    // MARK: - Project Selector

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
                        .font(.app(.caption))
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
                                    .font(.app(.caption))
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
                .font(.app(.headline))
        }
    }

    // MARK: - Keyboard Shortcuts

    private var shortcutContext: AppShortcutContext {
        AppShortcutContext(from: store.state, terminalTabActive: detailTab == .terminal)
    }

    @ViewBuilder
    private var shortcutButtons: some View {
        // Always render all shortcut buttons — SwiftUI doesn't reliably
        // register/deregister .keyboardShortcut when views appear/disappear.
        // Instead, check isActive inside the action closure.

        // Palette open/close
        Button("") { if showSearch { closePalette() } else { openPalette() } }
            .keyboardShortcut(AppShortcut.openPaletteK.key, modifiers: AppShortcut.openPaletteK.modifiers)
            .hidden()
        Button("") { if showSearch { closePalette() } else { openPalette() } }
            .keyboardShortcut(AppShortcut.openPaletteP.key, modifiers: AppShortcut.openPaletteP.modifiers)
            .hidden()
        Button("") { if showSearch { closePalette() } else { openPalette(initialQuery: ">") } }
            .keyboardShortcut(AppShortcut.openCommandMode.key, modifiers: AppShortcut.openCommandMode.modifiers)
            .hidden()

        // Cmd+Enter — expand detail OR deep search depending on context.
        // When the prompt editor is focused, forward to it for queue prompt.
        Button("") {
            if let textView = NSApp.keyWindow?.firstResponder as? SubmitTextView {
                textView.onCmdSubmit?()
                return
            }
            let ctx = shortcutContext
            if AppShortcut.deepSearch.isActive(in: ctx) {
                deepSearchTrigger.toggle()
            } else if AppShortcut.toggleExpanded.isActive(in: ctx) {
                if isExpandedDetail {
                    isExpandedDetail = false
                    boardViewModeRaw = BoardViewMode.kanban.rawValue
                } else {
                    isExpandedDetail = true
                    boardViewModeRaw = BoardViewMode.list.rawValue
                }
            }
        }
        .keyboardShortcut(AppShortcut.toggleExpanded.key, modifiers: AppShortcut.toggleExpanded.modifiers)
        .hidden()

        // Cmd+B — toggle sidebar in expanded mode
        Button("") {
            if AppShortcut.toggleSidebar.isActive(in: shortcutContext) {
                showBoardInExpanded.toggle()
            }
        }
        .keyboardShortcut(AppShortcut.toggleSidebar.key, modifiers: AppShortcut.toggleSidebar.modifiers)
        .hidden()

        // Cmd+T — new terminal tab (only when detail open on terminal tab)
        Button("") {
            if AppShortcut.newTerminal.isActive(in: shortcutContext),
               let cardId = store.state.selectedCardId {
                createExtraTerminal(cardId: cardId)
            }
        }
        .keyboardShortcut(AppShortcut.newTerminal.key, modifiers: AppShortcut.newTerminal.modifiers)
        .hidden()

        // Escape + prompt focused: send interrupt (Ctrl+C) to stop the assistant
        Button("") {
            guard AppShortcut.stopAssistant.isActive(in: shortcutContext) else { return }
            if let card = store.state.selectedCard,
               let session = card.link.tmuxLink?.sessionName {
                Task { try? await TmuxAdapter().sendEscape(sessionName: session) }
            }
        }
        .keyboardShortcut(AppShortcut.stopAssistant.key, modifiers: AppShortcut.stopAssistant.modifiers)
        .hidden()

        // Cmd+R — reload active browser tab
        Button("") {
            guard AppShortcut.browserReload.isActive(in: shortcutContext) else { return }
            NotificationCenter.default.post(name: .browserReload, object: nil)
        }
        .keyboardShortcut(AppShortcut.browserReload.key, modifiers: AppShortcut.browserReload.modifiers)
        .hidden()

        // Cmd+L — focus the active browser tab's address bar
        Button("") {
            guard AppShortcut.browserFocusAddress.isActive(in: shortcutContext) else { return }
            NotificationCenter.default.post(name: .browserFocusAddressBar, object: nil)
        }
        .keyboardShortcut(AppShortcut.browserFocusAddress.key, modifiers: AppShortcut.browserFocusAddress.modifiers)
        .hidden()

        // Cmd+Shift+T — reopen last closed tab (browser or terminal)
        Button("") {
            guard AppShortcut.reopenClosedTab.isActive(in: shortcutContext) else { return }
            NotificationCenter.default.post(name: .kanbanReopenClosedTab, object: nil)
        }
        .keyboardShortcut(AppShortcut.reopenClosedTab.key, modifiers: AppShortcut.reopenClosedTab.modifiers)
        .hidden()

        // Escape — context-dependent:
        // 1. In fullscreen mode: do nothing (don't close the card)
        // 2. In chat mode with Claude working: send interrupt (Ctrl+C)
        // 3. Otherwise: deselect card (close drawer)
        Button("") {
            guard AppShortcut.deselect.isActive(in: shortcutContext) else { return }
            if isExpandedDetail { return }
            if let card = store.state.selectedCard,
               let session = card.link.tmuxLink?.sessionName,
               card.activityState == .activelyWorking || card.activityState == .idleWaiting {
                if UserDefaults.standard.bool(forKey: "preferChatView") {
                    Task { try? await TmuxAdapter().sendInterrupt(sessionName: session) }
                    return
                }
            }
            store.dispatch(.selectCard(cardId: nil))
        }
            .keyboardShortcut(AppShortcut.deselect.key, modifiers: AppShortcut.deselect.modifiers)
            .hidden()
        Button("") { if AppShortcut.deleteCard.isActive(in: shortcutContext) { deleteSelectedCard() } }
            .keyboardShortcut(AppShortcut.deleteCard.key, modifiers: AppShortcut.deleteCard.modifiers)
            .hidden()
        Button("") { if AppShortcut.deleteCardForward.isActive(in: shortcutContext) { deleteSelectedCard() } }
            .keyboardShortcut(AppShortcut.deleteCardForward.key, modifiers: AppShortcut.deleteCardForward.modifiers)
            .hidden()

        // Cmd+1-9: terminal tab switching (when detail open) or project switching
        ForEach(Array(AppShortcut.allCases.filter { $0.projectIndex != nil }), id: \.projectIndex) { shortcut in
            Button("") {
                let ctx = shortcutContext
                if ctx.detailOpen && !ctx.paletteOpen {
                    selectTerminalTab(at: shortcut.projectIndex!)
                } else {
                    selectProject(at: shortcut.projectIndex!)
                }
            }
            .keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers)
            .hidden()
        }
    }

    private var paletteCommands: [CommandItem] {
        var cmds: [CommandItem] = [
            CommandItem("Open Settings", icon: "gear", shortcut: AppShortcut.openSettings.displayString) {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            },
            CommandItem("Toggle View Mode", icon: isExpandedDetail ? "square.split.2x1" : "list.bullet", shortcut: AppShortcut.toggleExpanded.displayString) { [self] in
                if isExpandedDetail {
                    isExpandedDetail = false
                    boardViewModeRaw = BoardViewMode.kanban.rawValue
                } else {
                    isExpandedDetail = true
                    showBoardInExpanded = true
                    boardViewModeRaw = BoardViewMode.list.rawValue
                }
            },
            CommandItem("New Task", icon: "plus", shortcut: AppShortcut.newTask.displayString) { [self] in
                presentNewTask()
            },
        ]

        // Project switching
        let visibleProjects = store.state.configuredProjects.filter(\.visible)
        if !visibleProjects.isEmpty {
            cmds.append(CommandItem("Show All Projects", icon: "folder", shortcut: AppShortcut.project1.displayString) { [self] in
                setSelectedProject(nil)
            })
            for (i, project) in visibleProjects.enumerated() {
                let projectShortcuts: [AppShortcut] = [.project2, .project3, .project4, .project5, .project6, .project7, .project8, .project9]
                let shortcut = i < projectShortcuts.count ? projectShortcuts[i].displayString : nil
                let path = project.path
                cmds.append(CommandItem("Switch to \(project.name)", icon: "folder", shortcut: shortcut) { [self] in
                    setSelectedProject(path)
                })
            }
        }

        return cmds
    }

    var currentProjectName: String {
        guard let path = store.state.selectedProjectPath else { return "All Projects" }
        return store.state.configuredProjects.first(where: { $0.path == path })?.name
            ?? (path as NSString).lastPathComponent
    }

    var projectList: [(name: String, path: String)] {
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

    var currentProjectHasRemote: Bool {
        store.state.globalRemoteSettings != nil
    }

    var currentSyncStatus: SyncStatus {
        if syncStatuses.isEmpty { return .notRunning }
        if syncStatuses.values.contains(.error) { return .error }
        if syncStatuses.values.contains(.conflicts) { return .conflicts }
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
                    .font(.app(.largeTitle))
                    .foregroundStyle(.secondary)
                Text("Quit Kanban?")
                    .font(.app(.headline))
                Text("You have \(quitOwnedSessions.count) managed tmux session\(quitOwnedSessions.count == 1 ? "" : "s") running.")
                    .font(.app(.subheadline))
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
                        Task {
                            // Kill tmux sessions and remove terminal associations from cards
                            let killedNames = Set(quitOwnedSessions.map(\.name))
                            for card in store.state.cards {
                                if let tmux = card.link.tmuxLink, killedNames.contains(tmux.sessionName) {
                                    await store.dispatchAndWait(.killTerminal(cardId: card.id, sessionName: tmux.sessionName))
                                }
                            }
                            NSApp.reply(toApplicationShouldTerminate: true)
                        }
                    } else {
                        NSApp.reply(toApplicationShouldTerminate: true)
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 520, height: 380)
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
            store.dispatch(.showDialog(.confirmDelete(cardId: cardId)))
        }
    }

    // MARK: - Expanded Actions Menu

    private func expandedActionsMenu(for card: KanbanCodeCard) -> some View {
        Menu {
            CardActionsMenu(
                card: card,
                showBranchInfo: true,
                onStart: { startCard(cardId: card.id) },
                onResume: { resumeCard(cardId: card.id) },
                onFork: { keepWorktree in forkCard(cardId: card.id, keepWorktree: keepWorktree) },
                onRenameRequest: { renamingCardId = card.id },
                onCopyResumeCmd: {
                    var cmd = ""
                    if let pp = card.link.projectPath { cmd += "cd \(pp) && " }
                    if let sid = card.link.sessionLink?.sessionId {
                        cmd += card.link.effectiveAssistant.resumeCommand(sessionId: sid, skipPermissions: false)
                    }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(cmd, forType: .string)
                },
                onCheckpoint: {
                    detailTab = .history
                    // CardDetailView picks up checkpointMode from its own menu
                    // but from here we just navigate to history tab
                },
                onAddLink: { showAddLinkCardId = card.id },
                onUnlink: { linkType in store.dispatch(.unlinkFromCard(cardId: card.id, linkType: linkType)) },
                onDiscover: {
                    Task {
                        store.dispatch(.setBusy(cardId: card.id, busy: true))
                        if let updatedLink = await orchestrator.discoverBranchesForCard(cardId: card.id) {
                            store.dispatch(.createManualTask(updatedLink))
                        }
                        await store.reconcile()
                        store.dispatch(.setBusy(cardId: card.id, busy: false))
                    }
                },
                onCleanupWorktree: { Task { await cleanupWorktree(cardId: card.id) } },
                canCleanupWorktree: canCleanupWorktree(for: card),
                onDelete: { store.dispatch(.showDialog(.confirmDelete(cardId: card.id))) },
                availableProjects: projectList,
                onMoveToProject: { path in store.dispatch(.moveCardToProject(cardId: card.id, projectPath: path)) },
                onMoveToFolder: { selectFolderForMove(cardId: card.id) },
                enabledAssistants: assistantRegistry.available,
                onMigrateAssistant: { target in
                    store.dispatch(.showDialog(.confirmMigration(cardId: card.id, targetAssistant: target)))
                }
            )
        } label: {
            Image(systemName: "ellipsis")
        }
        .help("More actions")
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
                if case .confirmDelete(let cardId) = store.state.activeDialog {
                    let card = store.state.cards.first(where: { $0.id == cardId })
                    let nextId = cardIdAfterDeletion(cardId)
                    store.dispatch(.deleteCard(cardId: cardId))
                    store.dispatch(.dismissDialog)
                    if let nextId {
                        store.dispatch(.selectCard(cardId: nextId))
                    }
                    offerWorktreeCleanupIfNeeded(card: card)
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

    private var isTerminalFocused: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        return String(describing: type(of: responder)).contains("Terminal")
    }

    private func openPalette(initialQuery: String = "") {
        // Check terminal focus via first responder first, fall back to tab+tmux heuristic
        // (by the time this runs, the shortcut may have stolen first responder from terminal)
        let terminalWasFocused = isTerminalFocused || (
            detailTab == .terminal
            && store.state.selectedCardId.flatMap({ store.state.links[$0]?.tmuxLink }) != nil
        )
        terminalHadFocusBeforeSearch = terminalWasFocused
        searchInitialQuery = initialQuery
        showSearch = true
    }

    private func closePalette() {
        showSearch = false
        if terminalHadFocusBeforeSearch {
            // Delay past the dismiss animation (150ms) so the terminal can accept focus.
            // Use direct AppKit focus as the SwiftUI binding path can miss updates.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                refocusTerminal()
            }
        }
    }

    private func refocusTerminal() {
        guard let window = NSApp.keyWindow,
              let contentView = window.contentView else { return }
        func findTerminal(in view: NSView) -> NSView? {
            let typeName = String(describing: type(of: view))
            if typeName.contains("TerminalView"), view.acceptsFirstResponder, !view.isHidden {
                return view
            }
            for sub in view.subviews where !sub.isHidden {
                if let found = findTerminal(in: sub) { return found }
            }
            return nil
        }
        if let terminal = findTerminal(in: contentView) {
            window.makeFirstResponder(terminal)
        }
    }

    /// When a card is selected from the palette and we're filtering by project,
    /// switch to the card's project so it's visible in the sidebar.
    private func switchToProjectIfNeeded(for card: KanbanCodeCard) {
        guard store.state.selectedProjectPath != nil,
              let cardProject = card.link.projectPath,
              cardProject != store.state.selectedProjectPath else { return }
        setSelectedProject(cardProject)
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

    private func selectTerminalTab(at index: Int) {
        NotificationCenter.default.post(
            name: .kanbanSelectTerminalTab,
            object: nil,
            userInfo: ["index": index]
        )
    }

    private func addDroppedFolder(_ url: URL) {
        let path = url.path
        let project = Project(path: path)
        Task {
            try? await settingsStore.addProject(project)
            await store.loadSettingsAndCache()
            await store.reconcile()
            setSelectedProject(path)
        }
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
            await store.loadSettingsAndCache()
            await store.reconcile()
            setSelectedProject(path)
        }
    }

    private func addDiscoveredProject(path: String) {
        let project = Project(path: path)
        Task {
            try? await settingsStore.addProject(project)
            await store.loadSettingsAndCache()
            await store.reconcile()
            setSelectedProject(path)
        }
    }

    /// Open a project by path — select it if it exists, otherwise create and select it.
    /// Called from the `kanban` CLI via file-based IPC.
    private func openOrCreateProject(path: String) {
        // Check if project already exists (match by path or repoRoot)
        if store.state.configuredProjects.contains(where: { $0.path == path || $0.repoRoot == path }) {
            setSelectedProject(path)
            return
        }
        // Project doesn't exist — create it, select first to avoid empty flash
        let project = Project(path: path)
        setSelectedProject(path)
        Task {
            try? await settingsStore.addProject(project)
            await store.loadSettingsAndCache()
            await store.reconcile()
        }
    }

    // MARK: - Add from Path Sheet

    private var addFromPathSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Project")
                .font(.app(.title3))
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
                        await store.loadSettingsAndCache()
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

    private func presentNewTask() {
        showNewTask = true
    }

    private func handleColumnBackgroundClick(_ column: KanbanCodeColumn) {
        guard column.allowsBoardTaskCreation else { return }
        presentNewTask()
    }

    private func createManualTask(prompt: String, projectPath: String?, title: String? = nil, startImmediately: Bool = false, images: [ImageAttachment] = []) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let name: String
        if let title, !title.isEmpty {
            name = String(title.prefix(100))
        } else {
            let firstLine = trimmed.components(separatedBy: .newlines).first ?? trimmed
            name = String(firstLine.prefix(100))
        }
        let imagePaths: [String]? = images.isEmpty ? nil : images.compactMap { img in
            var mutable = img
            return try? mutable.saveToPersistent()
        }
        let link = Link(
            name: name,
            projectPath: projectPath,
            column: startImmediately ? .inProgress : .backlog,
            source: .manual,
            promptBody: trimmed,
            promptImagePaths: imagePaths
        )

        store.dispatch(.createManualTask(link))
        KanbanCodeLog.info("manual-task", "Created manual task card=\(link.id.prefix(12)) name='\(name)' project=\(projectPath ?? "nil") startImmediately=\(startImmediately)")

        if startImmediately {
            startCard(cardId: link.id)
        }
    }

    private func createManualTaskAndLaunch(prompt: String, projectPath: String?, title: String? = nil, createWorktree: Bool, runRemotely: Bool, skipPermissions: Bool = true, commandOverride: String? = nil, images: [ImageAttachment] = [], assistant: CodingAssistant = .claude, apiServiceId: String? = nil) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let name: String
        if let title, !title.isEmpty {
            name = String(title.prefix(100))
        } else {
            let firstLine = trimmed.components(separatedBy: .newlines).first ?? trimmed
            name = String(firstLine.prefix(100))
        }
        let imagePaths: [String]? = images.isEmpty ? nil : images.compactMap { img in
            var mutable = img
            return try? mutable.saveToPersistent()
        }
        var link = Link(
            name: name,
            projectPath: projectPath,
            column: .inProgress,
            source: .manual,
            promptBody: trimmed,
            promptImagePaths: imagePaths,
            assistant: assistant
        )
        link.apiServiceId = apiServiceId
        let effectivePath = projectPath ?? NSHomeDirectory()

        store.dispatch(.createManualTask(link))
        KanbanCodeLog.info("manual-task", "Created & launching task card=\(link.id.prefix(12)) name='\(name)' project=\(effectivePath)")

        Task {
            let settings = try? await settingsStore.read()
            let project = settings?.projects.first(where: { $0.path == effectivePath })
            let builtPrompt = PromptBuilder.buildPrompt(card: link, project: project, settings: settings)

            let wtName: String? = (createWorktree && assistant.supportsWorktree) ? "" : nil
            executeLaunch(cardId: link.id, prompt: builtPrompt, projectPath: effectivePath, worktreeName: wtName, runRemotely: runRemotely, skipPermissions: skipPermissions, commandOverride: commandOverride, images: images, assistant: assistant)
        }
    }


    // MARK: - Archive

    private func archiveCard(cardId: String) {
        guard let card = store.state.cards.first(where: { $0.id == cardId }) else { return }
        if card.link.tmuxLink != nil {
            store.dispatch(.showDialog(.confirmArchive(cardId: cardId)))
        } else {
            store.dispatch(.archiveCard(cardId: cardId))
            offerWorktreeCleanupIfNeeded(card: card)
        }
    }

    // MARK: - Drag & Drop

    private func handleDrop(cardId: String, to column: KanbanCodeColumn) {
        guard let card = store.state.cards.first(where: { $0.id == cardId }) else { return }
        switch CardDropIntent.resolve(card, to: column) {
        case .start:
            startCard(cardId: cardId)
        case .resume:
            resumeCard(cardId: cardId)
        case .archive:
            archiveCard(cardId: cardId)
        case .move:
            store.dispatch(.moveCard(cardId: cardId, to: column))
        case .invalid(let message):
            store.dispatch(.setError(message))
        }
    }


    // MARK: - Channels UI

    private func onlineCount(for ch: Channel) -> Int {
        let live = store.state.tmuxSessions
        return ch.members.reduce(0) { acc, m in
            guard let cardId = m.cardId, let link = store.state.links[cardId] else {
                return acc + (m.cardId == nil ? 1 : 0)
            }
            if let sess = link.tmuxLink?.sessionName, live.contains(sess) {
                return acc + 1
            }
            return acc
        }
    }

    private func unreadCount(for ch: Channel) -> Int {
        // If the user is actively looking at this channel, there are no unread
        // messages — by definition.
        if store.state.selectedChannelName == ch.name && store.state.appIsFrontmost {
            return 0
        }
        let msgs = store.state.channelMessages[ch.name] ?? []
        guard !msgs.isEmpty else { return 0 }
        let myHandle = store.state.humanHandle

        // Only real chat messages (not joins/leaves) count toward unread.
        let realMsgs = msgs.filter { $0.type == .message }
        guard !realMsgs.isEmpty else { return 0 }

        // No marker = treat as fully read. The reducer seeds the marker on
        // first-load to avoid blasting N unreads for pre-existing history.
        guard let lastReadId = store.state.channelLastReadMessageId[ch.name] else {
            return 0
        }

        // Count messages strictly after `lastReadId`, skipping my own.
        if let idx = realMsgs.firstIndex(where: { $0.id == lastReadId }) {
            return realMsgs[(idx + 1)...].filter {
                !($0.from.cardId == nil && $0.from.handle == myHandle)
            }.count
        }
        // lastReadId isn't in the current slice (rare — rotation, message
        // deletion). Fall back to counting everything not from me.
        return realMsgs.filter {
            !($0.from.cardId == nil && $0.from.handle == myHandle)
        }.count
    }

    @ViewBuilder
    private func channelChatContent(channel: Channel) -> some View {
        let msgs = store.state.channelMessages[channel.name] ?? []
        let onlineMap = channelOnlineByHandle(channel)
        let activityMap = channelActivityByHandle(channel)
        ChannelChatView(
            channel: channel,
            messages: msgs,
            onlineByHandle: onlineMap,
            onSend: { body, imagePaths in
                store.dispatch(.sendChannelMessage(channelName: channel.name, body: body, imagePaths: imagePaths))
            },
            onClose: { store.dispatch(.selectChannel(name: nil)) },
            onCopyDMCommand: { m in
                let cmd = "kanban dm @\(m.handle) \"your message here\""
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(cmd, forType: .string)
            },
            onOpenDM: { m in
                let other = ChannelParticipant(cardId: m.cardId, handle: m.handle)
                store.dispatch(.selectDM(other: other))
            },
            onKickMember: { m in
                let who = ChannelParticipant(cardId: m.cardId, handle: m.handle)
                store.dispatch(.kickChannelMember(channelName: channel.name, member: who))
            },
            activityByHandle: activityMap,
            draft: Binding(
                get: { store.state.channelDrafts[channel.name] ?? "" },
                set: { store.dispatch(.setChannelDraft(channelName: channel.name, body: $0)) }
            ),
            shareController: shareController
        )
    }

    private func channelActivityByHandle(_ ch: Channel) -> [String: ActivityState] {
        var out: [String: ActivityState] = [:]
        for m in ch.members {
            guard let cardId = m.cardId, let link = store.state.links[cardId],
                  let sid = link.sessionLink?.sessionId,
                  let state = store.state.activityMap[sid]
            else { continue }
            out[m.handle] = state
        }
        return out
    }

    @ViewBuilder
    private func dmChatContent(other: ChannelParticipant) -> some View {
        let key = Reducer.dmKey(other)
        let msgs = store.state.dmMessages[key] ?? []
        let online: Bool = {
            guard let cid = other.cardId, let link = store.state.links[cid],
                  let sess = link.tmuxLink?.sessionName else { return false }
            return store.state.tmuxSessions.contains(sess)
        }()
        DMChatView(
            other: other,
            messages: msgs,
            onlineForOther: online,
            onSend: { body, imagePaths in
                store.dispatch(.sendDirectMessage(to: other, body: body, imagePaths: imagePaths))
            },
            onClose: { store.dispatch(.selectDM(other: nil)) },
            draft: Binding(
                get: { store.state.dmDrafts[key] ?? "" },
                set: { store.dispatch(.setDMDraft(other: other, body: $0)) }
            )
        )
    }

    private func channelOnlineByHandle(_ ch: Channel) -> [String: Bool] {
        let live = store.state.tmuxSessions
        var out: [String: Bool] = [:]
        for m in ch.members {
            if let cardId = m.cardId, let link = store.state.links[cardId],
               let sess = link.tmuxLink?.sessionName {
                out[m.handle] = live.contains(sess)
            } else {
                // User / cardless: always "online" (the human is the app)
                out[m.handle] = m.cardId == nil
            }
        }
        return out
    }

    // Launch, resume, fork, migration, worktree cleanup, and sync status
    // methods have been extracted to:
    // - ContentView+Launch.swift
    // - ContentView+Sync.swift
    // - ContentView+Worktree.swift
}
