import SwiftUI
import KanbanCodeCore
import MarkdownUI

// Helper types (DetailTab, ActionsMenuProvider, HoverFeedbackStyle, HoverBrightness,
// ChatDraft, NSMenuButton, dialogs, etc.) have been extracted to CardDetailHelpers.swift

struct CardDetailView: View {
    let card: KanbanCodeCard
    var onResume: () -> Void = {}
    var onRename: (String) -> Void = { _ in }
    var onFork: (_ keepWorktree: Bool) -> Void = { _ in }
    var onDismiss: () -> Void = {}
    var onUnlink: (Action.LinkType) -> Void = { _ in }
    var onAddBranch: (String) -> Void = { _ in }
    var onAddIssue: (Int) -> Void = { _ in }
    var onAddPR: (Int) -> Void = { _ in }
    var onCleanupWorktree: () -> Void = {}
    var canCleanupWorktree: Bool = true
    var onDeleteCard: () -> Void = {}
    var onCreateTerminal: () -> Void = {}
    var onKillTerminal: (String) -> Void = { _ in }
    var onRenameTerminal: (String, String) -> Void = { _, _ in } // (sessionName, label)
    var onReorderTerminal: (String, String?) -> Void = { _, _ in } // (sessionName, beforeSession)
    var onPRMerged: (Int) -> Void = { _ in }
    var onCancelLaunch: () -> Void = {}
    var onAddQueuedPrompt: (QueuedPrompt) -> Void = { _ in }
    var onUpdateQueuedPrompt: (String, String, Bool) -> Void = { _, _, _ in } // promptId, body, sendAuto
    var onRemoveQueuedPrompt: (String) -> Void = { _ in }
    var onSendQueuedPrompt: (String) -> Void = { _ in }
    var onReorderQueuedPrompts: ([String]) -> Void = { _ in }
    var onEditingQueuedPrompt: (String?) -> Void = { _ in } // promptId when editing, nil when done
    var onAddBrowserTab: (String, String) -> Void = { _, _ in } // (tabId, url)
    var onRemoveBrowserTab: (String) -> Void = { _ in } // tabId
    var onUpdateBrowserTab: (String, String?, String?) -> Void = { _, _, _ in } // (tabId, url?, title?)
    var onDiscover: () -> Void = {}
    var onUpdatePrompt: (String, [String]?) -> Void = { _, _ in } // body, imagePaths
    var availableProjects: [(name: String, path: String)] = []
    var onMoveToProject: (String) -> Void = { _ in }
    var onMoveToFolder: () -> Void = {}
    var enabledAssistants: [CodingAssistant] = []
    var onMigrateAssistant: (CodingAssistant) -> Void = { _ in }
    var actionsMenuProvider: ActionsMenuProvider?
    @Binding var focusTerminal: Bool
    @Binding var isExpanded: Bool
    @Binding var isDroppingImage: Bool

    @AppStorage("preferredEditorBundleId") private var editorBundleId: String = "dev.zed.Zed"
    @AppStorage("sessionDetailFontSize") private var sessionDetailFontSize: Double = 12
    @AppStorage("preferChatView") private var preferChatView = false

    @State private var turns: [ConversationTurn] = []
    @State private var isLoadingHistory = false
    @State private var isReloadingHistory = false
    @State private var hasMoreTurns = false
    // Per-card chat drafts (keyed by card ID, persisted to disk)
    @State private var chatDrafts: [String: ChatDraft] = ChatDraft.loadAll()
    @State private var chatPendingMessage: String?

    private var chatDraftText: Binding<String> {
        Binding(
            get: { chatDrafts[card.id]?.text ?? "" },
            set: { newValue in
                var draft = chatDrafts[card.id] ?? ChatDraft()
                draft.text = newValue
                chatDrafts[card.id] = draft
                ChatDraft.save(cardId: card.id, draft: draft)
            }
        )
    }

    private var chatDraftImages: Binding<[Data]> {
        Binding(
            get: { chatDrafts[card.id]?.images ?? [] },
            set: { newValue in
                var draft = chatDrafts[card.id] ?? ChatDraft()
                draft.images = newValue
                chatDrafts[card.id] = draft
                ChatDraft.save(cardId: card.id, draft: draft)
            }
        )
    }
    @State private var isLoadingMore = false
    @Binding var selectedTab: DetailTab
    @State private var showRenameSheet = false
    @State private var renameText = ""

    // Checkpoint mode
    @State private var checkpointMode = false
    @State private var checkpointTurn: ConversationTurn?
    @State private var showCheckpointConfirm = false

    // Fork (handled by parent via onFork callback)

    // Add link popover
    @State private var showAddLink = false

    // Copy toast
    @State private var copyToast: String?

    // Resolved GitHub base URL for constructing issue/PR links
    @State private var githubBaseURL: String?

    // PR body loading and merge state moved to PRTabView and MergeButton

    // Queued prompts
    @State private var queuedPromptItem: QueuedPromptItem?

    // Edit prompt
    @State private var showEditPromptSheet = false

    // File watcher for real-time history
    @State private var historyWatcherFD: Int32 = -1
    @State private var historyWatcherSource: DispatchSourceFileSystemObject?
    @State private var historyPollTask: Task<Void, Never>?
    @State private var lastReloadTime: Date = .distantPast

    // Multi-terminal
    @State private var selectedTerminalSession: String?
    @State private var knownShellCount: Int = 0
    /// Per-card tab memory: remembers which terminal/browser tab was selected for each card.
    @State private var cardTabMemory: [String: (terminal: String?, browser: String?)] = [:]
    @State private var terminalGrabFocus: Bool = false
    @State private var suppressTerminalFocus: Bool = false
    @State private var tabRenameItem: TabRenameItem?
    @State private var draggingTab: String?
    @State private var lastTabClickTime: Double = 0
    @State private var lastTabClickTarget: String?
    @State private var hoveredTab: String?
    @State private var hoveredCloseBtn: String?
    @State private var dropTargetTab: String?
    /// User's tab ordering — IDs of shell sessions + browser tabs in display order.
    /// When empty, falls back to shells-then-browsers default.
    @State private var customTabOrder: [String] = []
    @State private var terminalPaths: [String: String] = [:]  // sessionName → last path component
    @State private var pathPollTask: Task<Void, Never>?

    // Browser tabs (live WKWebViews in BrowserTabCache, persisted URLs in link.browserTabs)
    @State private var browserTabs: [BrowserTab] = []
    @State private var selectedBrowserTabId: String?

    /// Launch lock older than 30s is stale — stop showing spinner, show terminal instead
    private var isLaunchStale: Bool {
        Date.now.timeIntervalSince(card.link.updatedAt) > 30
    }

    let sessionStore: SessionStore

    init(card: KanbanCodeCard, sessionStore: SessionStore = ClaudeCodeSessionStore(), selectedTab: Binding<DetailTab>, onResume: @escaping () -> Void = {}, onRename: @escaping (String) -> Void = { _ in }, onFork: @escaping (_ keepWorktree: Bool) -> Void = { _ in }, onDismiss: @escaping () -> Void = {}, onUnlink: @escaping (Action.LinkType) -> Void = { _ in }, onAddBranch: @escaping (String) -> Void = { _ in }, onAddIssue: @escaping (Int) -> Void = { _ in }, onAddPR: @escaping (Int) -> Void = { _ in }, onCleanupWorktree: @escaping () -> Void = {}, canCleanupWorktree: Bool = true, onDeleteCard: @escaping () -> Void = {}, onCreateTerminal: @escaping () -> Void = {}, onKillTerminal: @escaping (String) -> Void = { _ in }, onRenameTerminal: @escaping (String, String) -> Void = { _, _ in }, onReorderTerminal: @escaping (String, String?) -> Void = { _, _ in }, onPRMerged: @escaping (Int) -> Void = { _ in }, onCancelLaunch: @escaping () -> Void = {}, onAddQueuedPrompt: @escaping (QueuedPrompt) -> Void = { _ in }, onUpdateQueuedPrompt: @escaping (String, String, Bool) -> Void = { _, _, _ in }, onRemoveQueuedPrompt: @escaping (String) -> Void = { _ in }, onSendQueuedPrompt: @escaping (String) -> Void = { _ in }, onReorderQueuedPrompts: @escaping ([String]) -> Void = { _ in }, onEditingQueuedPrompt: @escaping (String?) -> Void = { _ in }, onAddBrowserTab: @escaping (String, String) -> Void = { _, _ in }, onRemoveBrowserTab: @escaping (String) -> Void = { _ in }, onUpdateBrowserTab: @escaping (String, String?, String?) -> Void = { _, _, _ in }, onDiscover: @escaping () -> Void = {}, onUpdatePrompt: @escaping (String, [String]?) -> Void = { _, _ in }, availableProjects: [(name: String, path: String)] = [], onMoveToProject: @escaping (String) -> Void = { _ in }, onMoveToFolder: @escaping () -> Void = {}, enabledAssistants: [CodingAssistant] = [], onMigrateAssistant: @escaping (CodingAssistant) -> Void = { _ in }, actionsMenuProvider: ActionsMenuProvider? = nil, focusTerminal: Binding<Bool> = .constant(false), isExpanded: Binding<Bool> = .constant(false), isDroppingImage: Binding<Bool> = .constant(false)) {
        self.card = card
        self.sessionStore = sessionStore
        self.onResume = onResume
        self.onRename = onRename
        self.onFork = onFork
        self.onDismiss = onDismiss
        self.onUnlink = onUnlink
        self.onAddBranch = onAddBranch
        self.onAddIssue = onAddIssue
        self.onAddPR = onAddPR
        self.onCleanupWorktree = onCleanupWorktree
        self.canCleanupWorktree = canCleanupWorktree
        self.onDeleteCard = onDeleteCard
        self.onCreateTerminal = onCreateTerminal
        self.onKillTerminal = onKillTerminal
        self.onRenameTerminal = onRenameTerminal
        self.onReorderTerminal = onReorderTerminal
        self.onPRMerged = onPRMerged
        self.onCancelLaunch = onCancelLaunch
        self.onAddQueuedPrompt = onAddQueuedPrompt
        self.onUpdateQueuedPrompt = onUpdateQueuedPrompt
        self.onRemoveQueuedPrompt = onRemoveQueuedPrompt
        self.onSendQueuedPrompt = onSendQueuedPrompt
        self.onReorderQueuedPrompts = onReorderQueuedPrompts
        self.onEditingQueuedPrompt = onEditingQueuedPrompt
        self.onAddBrowserTab = onAddBrowserTab
        self.onRemoveBrowserTab = onRemoveBrowserTab
        self.onUpdateBrowserTab = onUpdateBrowserTab
        self.onDiscover = onDiscover
        self.onUpdatePrompt = onUpdatePrompt
        self.availableProjects = availableProjects
        self.onMoveToProject = onMoveToProject
        self.onMoveToFolder = onMoveToFolder
        self.enabledAssistants = enabledAssistants
        self.onMigrateAssistant = onMigrateAssistant
        self.actionsMenuProvider = actionsMenuProvider
        self._focusTerminal = focusTerminal
        self._isExpanded = isExpanded
        self._isDroppingImage = isDroppingImage
        self._selectedTab = selectedTab
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !isExpanded {
                normalHeader
            }

            // Content
            switch selectedTab {
            case .terminal:
                terminalView
            case .history:
                SessionHistoryView(
                    turns: turns,
                    isLoading: isLoadingHistory,
                    checkpointMode: checkpointMode,
                    hasMoreTurns: hasMoreTurns,
                    isLoadingMore: isLoadingMore,
                    assistant: card.link.effectiveAssistant,
                    onCancelCheckpoint: { checkpointMode = false },
                    onSelectTurn: { turn in
                        checkpointTurn = turn
                        showCheckpointConfirm = true
                    },
                    onLoadMore: { Task { await loadMoreHistory() } },
                    onLoadAroundTurn: { turnIndex in Task { await loadAroundTurn(turnIndex) } },
                    sessionPath: card.link.sessionLink?.sessionPath ?? card.session?.jsonlPath
                )
            case .issue:
                if let issue = card.link.issueLink {
                    IssueTabView(issue: issue, cardTitle: card.displayTitle, githubBaseURL: githubBaseURL)
                }
            case .pullRequest:
                PRTabView(card: card, githubBaseURL: githubBaseURL)
            case .prompt:
                PromptTabView(card: card, onCopyToast: showCopyToast, showEditPromptSheet: $showEditPromptSheet)
            }
        }
        .frame(maxWidth: .infinity)
        .sheet(isPresented: Binding(
            get: { showAddLink && isExpanded },
            set: { if !$0 { showAddLink = false } }
        )) {
            AddLinkPopover(
                onAddBranch: { onAddBranch($0); showAddLink = false },
                onAddIssue: { onAddIssue($0); showAddLink = false },
                onAddPR: { onAddPR($0); showAddLink = false }
            )
        }
        .onChange(of: card.id) { oldId, _ in
            // Save current tab selection for the old card before switching
            if !oldId.isEmpty {
                cardTabMemory[oldId] = (terminal: selectedTerminalSession, browser: selectedBrowserTabId)
            }
            // Restore tab selection for the new card (synchronous — no flicker).
            // Validate that the saved session still exists — if not, fall back to Claude tab.
            let saved = cardTabMemory[card.id]
            let validShells = card.link.tmuxLink?.extraSessions ?? []
            if let savedTerminal = saved?.terminal, validShells.contains(savedTerminal) {
                selectedTerminalSession = savedTerminal
            } else {
                selectedTerminalSession = nil
            }
            selectedBrowserTabId = saved?.browser
            // Clear stale state synchronously so the new card never renders
            // with the previous card's turns or chat state.
            turns = []
            chatPendingMessage = nil
            checkpointMode = false
            // Set knownShellCount to current shells so onChange(of: tmuxLink)
            // doesn't think new shells were added and auto-switch away.
            knownShellCount = card.link.tmuxLink?.extraSessions?.count ?? 0
        }
        .task(id: card.id) {
            actionsMenuProvider?.builder = { [self] in buildActionsMenu() }
            isLoadingHistory = false
            isLoadingMore = false
            hasMoreTurns = false
            browserTabs = hydrateBrowserTabs()
            terminalGrabFocus = false
            // Reset tab to a valid one for this card (skip auto-focus)
            suppressTerminalFocus = true
            selectedTab = defaultTab(for: card)
            // Resolve GitHub base URL for constructing issue/PR links
            if let projectPath = card.link.projectPath {
                githubBaseURL = await GitRemoteResolver.shared.githubBaseURL(for: projectPath)
            } else {
                githubBaseURL = nil
            }
            await loadHistory()
            if selectedTab == .history {
                startHistoryWatcher()
            }
        }
        .onChange(of: selectedTab) {
            if selectedTab == .terminal {
                if suppressTerminalFocus {
                    suppressTerminalFocus = false
                } else {
                    terminalGrabFocus = true
                }
            }
            if selectedTab == .history {
                Task { await loadHistory() }
                startHistoryWatcher()
            } else {
                stopHistoryWatcher()
            }
        }
        .onChange(of: card.link.sessionLink?.sessionPath) {
            // When a session path appears (e.g., after launch discovers the session),
            // restart the watcher so history starts updating live.
            guard selectedTab == .history || (selectedTab == .terminal && preferChatView) else { return }
            guard card.link.sessionLink?.sessionPath != nil else { return }
            startHistoryWatcher()
            Task { await loadHistory() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .kanbanCodeHistoryChanged)) { _ in
            guard selectedTab == .history || (selectedTab == .terminal && preferChatView) else { return }
            // Debounce: only reload if >0.2s since last reload
            let now = Date()
            guard now.timeIntervalSince(lastReloadTime) > 0.2 else { return }
            lastReloadTime = now
            Task { await loadHistory() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .kanbanSelectTerminalTab)) { notif in
            guard let index = notif.userInfo?["index"] as? Int else { return }
            selectedTab = .terminal

            // Unified tab order: [assistant, ...unifiedExtraTabs]
            let tabs = unifiedExtraTabs
            if index == 0 {
                // Claude/assistant tab
                selectedTerminalSession = nil
                selectedBrowserTabId = nil
                terminalGrabFocus = true
            } else if index - 1 < tabs.count {
                let tab = tabs[index - 1]
                switch tab {
                case .shell(let session):
                    selectedTerminalSession = session
                    selectedBrowserTabId = nil
                    terminalGrabFocus = true
                case .browser(let browserTab):
                    selectedTerminalSession = nil
                    selectedBrowserTabId = browserTab.id
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .kanbanCloseTerminalTab)) { _ in
            guard selectedTab == .terminal else { return }
            // Close the currently selected tab — shell or browser
            if let browserId = selectedBrowserTabId,
               let tab = browserTabs.first(where: { $0.id == browserId }) {
                closeBrowserTab(tab)
            } else if let session = selectedTerminalSession {
                onKillTerminal(session)
                let remaining = shellSessions.filter { $0 != session }
                selectedTerminalSession = remaining.first
            }
        }
        .onChange(of: focusTerminal) {
            if focusTerminal {
                if card.link.tmuxLink != nil {
                    // Terminal already loaded — focus now
                    selectedTab = .terminal
                    terminalGrabFocus = true
                    focusTerminal = false
                }
                // Otherwise wait for tmuxLink to appear (handled below)
            }
        }
        .onChange(of: card.link.tmuxLink?.sessionName) {
            if focusTerminal && card.link.tmuxLink != nil {
                selectedTab = .terminal
                terminalGrabFocus = true
                focusTerminal = false
            }
        }
        .overlay(alignment: .bottom) {
            if let copyToast {
                Text(copyToast)
                    .font(.app(.caption, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: copyToast)
        .onDisappear {
            stopHistoryWatcher()
            pathPollTask?.cancel()
            pathPollTask = nil
        }
        .sheet(isPresented: $showRenameSheet) {
            RenameSessionDialog(
                currentName: card.link.name ?? card.displayTitle,
                isPresented: $showRenameSheet,
                onRename: onRename
            )
        }
        .sheet(item: $queuedPromptItem) { item in
            QueuedPromptDialog(
                isPresented: Binding(
                    get: { queuedPromptItem != nil },
                    set: { if !$0 { onEditingQueuedPrompt(nil); queuedPromptItem = nil } }
                ),
                existingPrompt: item.existingPrompt,
                assistant: card.link.effectiveAssistant,
                onSave: { body, sendAuto, images in
                    onEditingQueuedPrompt(nil)
                    let imagePaths: [String]? = images.isEmpty ? nil : images.compactMap { img in
                        var mutable = img
                        return try? mutable.saveToPersistent()
                    }
                    if let existing = item.existingPrompt {
                        onUpdateQueuedPrompt(existing.id, body, sendAuto)
                    } else {
                        onAddQueuedPrompt(QueuedPrompt(body: body, sendAutomatically: sendAuto, imagePaths: imagePaths))
                    }
                }
            )
        }
        .sheet(isPresented: $showEditPromptSheet) {
            let existingPaths = Set(card.link.promptImagePaths ?? [])
            EditPromptSheet(
                isPresented: $showEditPromptSheet,
                body: card.link.promptBody ?? "",
                existingImagePaths: card.link.promptImagePaths ?? [],
                onSave: { body, images in
                    let imagePaths: [String]? = images.isEmpty ? nil : images.compactMap { img in
                        // Already persisted — keep existing path
                        if let path = img.tempPath, existingPaths.contains(path) {
                            return path
                        }
                        var mutable = img
                        return try? mutable.saveToPersistent()
                    }
                    onUpdatePrompt(body, imagePaths)
                }
            )
        }
        .sheet(item: $tabRenameItem) { item in
            RenameTerminalTabDialog(
                currentName: item.currentName,
                isPresented: Binding(
                    get: { tabRenameItem != nil },
                    set: { if !$0 { tabRenameItem = nil } }
                ),
                onRename: { newName in
                    onRenameTerminal(item.sessionName, newName)
                }
            )
        }
        .alert("Restore to Turn \(checkpointTurn.map { String($0.index + 1) } ?? "")?", isPresented: $showCheckpointConfirm) {
            Button("Cancel", role: .cancel) {
                checkpointTurn = nil
            }
            Button("Restore") { performCheckpoint() }
        } message: {
            Text("Everything after this point will be removed. A .bkp backup will be created.")
        }
    }

    // MARK: - Terminal View

    /// Whether the Claude tab is selected (nil = Claude tab, no browser tab selected).
    private var isClaudeTabSelected: Bool {
        selectedTerminalSession == nil && selectedBrowserTabId == nil
    }

    /// The tmux session name for the live Claude terminal, if any.
    private var claudeTmuxSession: String? {
        guard let tmux = card.link.tmuxLink,
              tmux.isShellOnly != true,
              tmux.isPrimaryDead != true else { return nil }
        return tmux.sessionName
    }

    /// Reorder a tab by moving `movedId` before `beforeId`. If `beforeId` is nil, move to end.
    private func reorderTab(_ movedId: String, before beforeId: String?) {
        var order = unifiedExtraTabs.map(\.id)
        order.removeAll { $0 == movedId }
        if let beforeId, let idx = order.firstIndex(of: beforeId) {
            order.insert(movedId, at: idx)
        } else {
            order.append(movedId)
        }
        customTabOrder = order
    }

    /// Unified tab item for the tab bar (shells + browser tabs interleaved).
    private enum UnifiedTab: Identifiable {
        case shell(String)
        case browser(BrowserTab)

        var id: String {
            switch self {
            case .shell(let name): return name
            case .browser(let tab): return tab.id
            }
        }
    }

    /// Merged list of shell + browser tabs in display order.
    /// Respects `customTabOrder` for user-defined ordering.
    private var unifiedExtraTabs: [UnifiedTab] {
        let shells = shellSessions.map { UnifiedTab.shell($0) }
        let browsers = browserTabs.map { UnifiedTab.browser($0) }
        let all = shells + browsers
        guard !customTabOrder.isEmpty else { return all }
        // Sort by custom order; new tabs (not in order) go at the end
        let byId = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var ordered: [UnifiedTab] = customTabOrder.compactMap { byId[$0] }
        // Append any tabs not in the order (newly created)
        let orderedIds = Set(customTabOrder)
        for tab in all where !orderedIds.contains(tab.id) {
            ordered.append(tab)
        }
        return ordered
    }

    /// All live shell session names (extras + live shell-only primary).
    private var shellSessions: [String] {
        guard let tmux = card.link.tmuxLink else { return [] }
        var sessions = tmux.extraSessions ?? []
        if tmux.isShellOnly == true && tmux.isPrimaryDead != true {
            sessions.insert(tmux.sessionName, at: 0)
        }
        return sessions
    }

    /// All live tmux sessions (Claude + shells) for TerminalContainerView.
    private var allLiveSessions: [String] {
        var sessions: [String] = []
        if let claude = claudeTmuxSession { sessions.append(claude) }
        sessions.append(contentsOf: shellSessions)
        return sessions
    }

    /// The effective tmux session to show in the terminal, based on selected tab.
    private var effectiveActiveSession: String? {
        if isClaudeTabSelected { return claudeTmuxSession }
        return selectedTerminalSession
    }

    /// Snapshot of tab bar state for action button visibility.
    private var tabBarActionState: TabBarActionState {
        TabBarActionState(
            selectedTerminalSession: selectedTerminalSession,
            selectedBrowserTabId: selectedBrowserTabId,
            claudeTmuxSession: claudeTmuxSession,
            shellSessions: shellSessions
        )
    }

    /// Whether the tab bar should be visible.
    private var showTabBar: Bool {
        card.link.tmuxLink != nil || card.link.sessionLink != nil ||
        card.link.isLaunching == true || !browserTabs.isEmpty
    }

    @ViewBuilder
    private var chatViewForCurrentCard: some View {
        ChatView(
            turns: turns,
            isLoading: isLoadingHistory,
            activityState: card.activityState,
            assistant: card.link.effectiveAssistant,
            hasMoreTurns: hasMoreTurns,
            isLoadingMore: isLoadingMore,
            tmuxSessionName: card.link.tmuxLink?.sessionName,
            cardId: card.id,
            onSendPrompt: { text, imagePaths in
                let prompt = QueuedPrompt(
                    id: UUID().uuidString,
                    body: text,
                    sendAutomatically: true,
                    imagePaths: imagePaths.isEmpty ? nil : imagePaths
                )
                onAddQueuedPrompt(prompt)
                onSendQueuedPrompt(prompt.id)
            },
            onQueuePrompt: { body, sendAuto, imagePaths in
                let prompt = QueuedPrompt(
                    body: body,
                    sendAutomatically: sendAuto,
                    imagePaths: imagePaths.isEmpty ? nil : imagePaths
                )
                onAddQueuedPrompt(prompt)
            },
            onLoadMore: { Task { await loadMoreHistory() } },
            onLoadAroundTurn: { turnIndex in Task { await loadAroundTurn(turnIndex) } },
            sessionPath: card.link.sessionLink?.sessionPath ?? card.session?.jsonlPath,
            onFork: { onFork(true) },
            onCheckpoint: { turn in
                checkpointTurn = turn
                showCheckpointConfirm = true
            },
            draftText: chatDraftText,
            draftImages: chatDraftImages,
            pendingMessage: $chatPendingMessage
        )
    }

    @ViewBuilder
    private var terminalView: some View {
        if showTabBar {
            let isLaunching = card.link.isLaunching == true && !isLaunchStale
            let showOverlay = isClaudeTabSelected && effectiveActiveSession == nil

            VStack(spacing: 0) {
                // Finder-style tab bar — single row
                HStack(spacing: 0) {
                    // Tab capsule — fills available space
                    HStack(spacing: 1) {
                        assistantTab(isSelected: isClaudeTabSelected, isLaunching: isLaunching)
                            .frame(maxWidth: .infinity)

                        ForEach(unifiedExtraTabs, id: \.id) { item in
                            if dropTargetTab == item.id, let drag = draggingTab, drag != item.id {
                                tabDropIndicator
                            }

                            switch item {
                            case .shell(let sessionName):
                                shellTab(
                                    sessionName: sessionName,
                                    isSelected: selectedTerminalSession == sessionName
                                )
                                .frame(maxWidth: .infinity)
                                .opacity(draggingTab == sessionName ? 0.3 : 1.0)
                            case .browser(let tab):
                                browserTab(
                                    tab: tab,
                                    isSelected: selectedBrowserTabId == tab.id
                                )
                                .frame(maxWidth: .infinity)
                                .opacity(draggingTab == tab.id ? 0.3 : 1.0)
                            }
                        }

                        if dropTargetTab == "_end_", draggingTab != nil {
                            tabDropIndicator
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(3)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                    .layoutPriority(1)
                    .animation(.easeInOut(duration: 0.2), value: dropTargetTab)
                    .onChange(of: dropTargetTab) {
                        if dropTargetTab == nil, draggingTab != nil {
                            Task {
                                try? await Task.sleep(for: .milliseconds(300))
                                if dropTargetTab == nil {
                                    draggingTab = nil
                                }
                            }
                        }
                    }

                    // + button outside capsule, like Finder
                    Button(action: onCreateTerminal) {
                        Image(systemName: "terminal")
                            .font(.app(.caption))
                    }
                    .buttonStyle(.borderless)
                    .help("Open new terminal")
                    .padding(.leading, 8)
                    .fixedSize()
                    .dropDestination(for: String.self) { items, _ in
                        guard let dropped = items.first else { return false }
                        reorderTab(dropped, before: nil)
                        draggingTab = nil
                        dropTargetTab = nil
                        return true
                    } isTargeted: { targeted in
                        dropTargetTab = targeted ? "_end_" : (dropTargetTab == "_end_" ? nil : dropTargetTab)
                    }

                    // Globe button for new browser tab
                    Button {
                        let tabId = "browser-\(UUID().uuidString)"
                        let defaultURL = "http://localhost:5560/"
                        onAddBrowserTab(tabId, defaultURL)
                        let tab = BrowserTabCache.shared.getOrCreate(cardId: card.id, tabId: tabId, url: URL(string: defaultURL)!)
                        browserTabs.append(tab)
                        selectedBrowserTabId = tabId
                        selectedTerminalSession = nil
                    } label: {
                        Image(systemName: "globe")
                            .font(.app(.caption))
                    }
                    .buttonStyle(.borderless)
                    .help("Open new browser tab")
                    .padding(.leading, 4)
                    .fixedSize()

                    // Action buttons with gaps — show whenever any tmux session is alive
                    // (even when a browser tab is selected)
                    if let activeTmux = tabBarActionState.tmuxSessionForActions {
                        Button {
                            let cmd = "tmux attach -t \(activeTmux)"
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(cmd, forType: .string)
                        } label: {
                            Label("Copy tmux attach", systemImage: "doc.on.doc")
                                .font(.app(.caption))
                        }
                        .buttonStyle(.borderless)
                        .help("Copy: tmux attach -t \(activeTmux)")
                        .padding(.leading, 16)
                        .fixedSize()

                        Button {
                            queuedPromptItem = QueuedPromptItem(existingPrompt: nil)
                        } label: {
                            Label("Queue Prompt", systemImage: "text.badge.plus")
                                .font(.app(.caption))
                        }
                        .buttonStyle(.borderless)
                        .help("Queue a prompt to send to Claude later")
                        .padding(.leading, 16)
                        .fixedSize()
                    }

                }
                .padding(.horizontal, 12)
                .padding(.vertical, 0)
                .padding(.bottom, 6)

                // Queued prompts bar
                if let prompts = card.link.queuedPrompts, !prompts.isEmpty {
                    QueuedPromptsBar(
                        prompts: prompts,
                        onSendNow: { promptId in
                            if preferChatView, let prompt = card.link.queuedPrompts?.first(where: { $0.id == promptId }) {
                                chatPendingMessage = prompt.body
                            }
                            onSendQueuedPrompt(promptId)
                        },
                        onEdit: { prompt in
                            onEditingQueuedPrompt(prompt.id)
                            queuedPromptItem = QueuedPromptItem(existingPrompt: prompt)
                        },
                        onRemove: { promptId in onRemoveQueuedPrompt(promptId) },
                        onReorder: { promptIds in onReorderQueuedPrompts(promptIds) }
                    )
                    Divider()
                }

                // Content area: either ChatView or TerminalContainerView (not both)
                ZStack {
                    if preferChatView && isClaudeTabSelected {
                        // Chat mode: no terminal mounted (saves CPU, fixes scroll)
                        ZStack {
                            chatViewForCurrentCard

                            // Dead session overlay in chat mode
                            if showOverlay && !isLaunching && card.link.sessionLink != nil {
                                chatModeResumeOverlay
                            } else if showOverlay && isLaunching {
                                VStack(spacing: 12) {
                                    ProgressView().controlSize(.large)
                                    Text("Starting session…")
                                        .font(.app(.body))
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(.ultraThinMaterial)
                            }
                        }
                        .task(id: "chatview-\(card.id)") {
                            await loadHistory()
                            startHistoryWatcher()
                        }
                    }
                    if !preferChatView || (selectedTerminalSession != nil || selectedBrowserTabId != nil) {
                        // Terminal mode
                        TerminalContainerView(
                            sessions: allLiveSessions,
                            activeSession: effectiveActiveSession ?? allLiveSessions.first ?? "",
                            grabFocus: terminalGrabFocus
                        )
                        .equatable()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(allLiveSessions.isEmpty || showOverlay || selectedBrowserTabId != nil ? 0 : 1)
                        .onChange(of: terminalGrabFocus) {
                            if terminalGrabFocus {
                                let session = effectiveActiveSession ?? allLiveSessions.first ?? ""
                                if !session.isEmpty {
                                    TerminalCache.shared.focusTerminal(for: session)
                                }
                                DispatchQueue.main.async { terminalGrabFocus = false }
                            }
                        }

                        // Overlay for non-terminal Claude tab states
                        if showOverlay && selectedBrowserTabId == nil {
                            assistantTabOverlay(isLaunching: isLaunching)
                        }

                        // Browser tab content — use opacity to preserve WKWebView state
                        ForEach(browserTabs, id: \.id) { tab in
                            BrowserContentView(tab: tab, onNavigated: { tabId, url, title in
                                onUpdateBrowserTab(tabId, url, title)
                            })
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .opacity(selectedBrowserTabId == tab.id ? 1 : 0)
                        }

                    } // else (terminal mode)

                    // Drop target — works in both chat and terminal mode
                    if isDroppingImage && !allLiveSessions.isEmpty {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                            .overlay {
                                VStack(spacing: 6) {
                                    Image(systemName: "photo.on.rectangle.angled")
                                        .font(.app(size: 28))
                                        .foregroundStyle(Color.accentColor)
                                    Text(preferChatView ? "Drop image to attach" : "Drop image to send")
                                        .font(.app(.caption, weight: .medium))
                                        .foregroundStyle(.white)
                                }
                            }
                            .padding(8)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                // Floating chat/terminal toggle — only on assistant tab
                .overlay(alignment: .topTrailing) {
                    if isClaudeTabSelected {
                    Button {
                        preferChatView.toggle()
                        if !preferChatView {
                            terminalGrabFocus = true
                        }
                    } label: {
                        Image(systemName: preferChatView ? "terminal" : "bubble.left.and.text.bubble.right")
                            .font(.system(size: 15))
                            .frame(width: 36, height: 36)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular, in: .circle)
                    .help(preferChatView ? "Show terminal" : "Show chat")
                    .padding(10)
                    }
                }
            }
            .onChange(of: effectiveActiveSession) {
                // In expanded (fullscreen) mode, auto-focus terminal when active session changes
                // (e.g. closing a tab falls back to Claude tab — user should be able to type immediately)
                if isExpanded && selectedBrowserTabId == nil {
                    terminalGrabFocus = true
                }
            }
            .onChange(of: card.link.tmuxLink) {
                let shells = shellSessions
                if let selected = selectedTerminalSession, !shells.contains(selected) {
                    // Selected shell was killed — go to Claude tab (not another shell)
                    selectedTerminalSession = nil
                } else if shells.count > knownShellCount, let last = shells.last, knownShellCount >= 0 {
                    // New SHELL was added (not Claude resuming) — auto-switch to it
                    selectedTerminalSession = last
                    selectedBrowserTabId = nil
                    terminalGrabFocus = true
                }

                knownShellCount = shells.count
                draggingTab = nil
                dropTargetTab = nil
            }
            .onAppear {
                knownShellCount = shellSessions.count
                startPathPolling()
            }
        } else {
            // No session at all — bare placeholder
            VStack(spacing: 12) {
                Image(systemName: "terminal")
                    .font(.app(size: 32))
                    .foregroundStyle(.tertiary)
                Text("No session yet")
                    .font(.app(.body))
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button(action: onCreateTerminal) {
                        Label("New Terminal", systemImage: "terminal")
                    }
                    .buttonStyle(.bordered)
                    Button {
                        let tabId = "browser-\(UUID().uuidString)"
                        let defaultURL = "http://localhost:5560/"
                        onAddBrowserTab(tabId, defaultURL)
                        let tab = BrowserTabCache.shared.getOrCreate(cardId: card.id, tabId: tabId, url: URL(string: defaultURL)!)
                        browserTabs.append(tab)
                        selectedBrowserTabId = tabId
                        selectedTerminalSession = nil
                    } label: {
                        Label("New Browser", systemImage: "globe")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Assistant Tab

    @ViewBuilder
    private func assistantTab(isSelected: Bool, isLaunching: Bool) -> some View {
        let assistant = card.link.effectiveAssistant
        let assistantAlive = claudeTmuxSession != nil
        let isDead = !assistantAlive && !isLaunching
        let tabLabel = assistant.displayName

        let tabId = "_assistant_"
        let isHovered = hoveredTab == tabId

        Button {
            selectedTerminalSession = nil
            selectedBrowserTabId = nil
            if assistantAlive { terminalGrabFocus = true }
        } label: {
            HStack(spacing: 4) {
                HStack {
                    // Close button on left, only on hover
                    if assistantAlive && isHovered {
                        Button {
                            if let session = claudeTmuxSession {
                                onKillTerminal(session)
                            }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.app(size: 8, weight: .bold))
                                .foregroundStyle(.primary.opacity(0.6))
                                .frame(width: 14, height: 14)
                                .background {
                                    if hoveredCloseBtn == tabId {
                                        Circle().fill(Color.primary.opacity(0.12))
                                    }
                                }
                                .contentShape(Circle())
                        }
                        .buttonStyle(.borderless)
                        .onHover { hoveredCloseBtn = $0 ? tabId : nil }
                        .help("Stop \(assistant.displayName) session")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                AssistantIcon(assistant: assistant)
                    .frame(width: CGFloat(12).scaled, height: CGFloat(12).scaled)
                    .padding(.vertical, 2)
                Text(tabLabel)
                    .font(.app(.caption))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
                    .padding(.vertical, 2)

                Spacer()
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(isDead ? 0.5 : 1.0)
        .background {
            if isSelected {
                Capsule().fill(.background)
                    .shadow(color: .black.opacity(0.1), radius: 1, y: 1)
            } else if isHovered {
                Capsule().fill(Color.primary.opacity(0.04))
            }
        }
        .onHover { hoveredTab = $0 ? tabId : (hoveredTab == tabId ? nil : hoveredTab) }
    }

    /// Overlay shown on the assistant tab when there's no live terminal.
    @ViewBuilder
    /// Resume overlay shown at the bottom of chat mode when session is dead.
    private var chatModeResumeOverlay: some View {
        let assistant = card.link.effectiveAssistant
        HStack(spacing: 8) {
            Text("\(assistant.displayName) session ended")
                .font(.app(.callout))
                .foregroundStyle(.secondary)
            Button(action: onResume) {
                Label("Resume", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    @ViewBuilder
    private func assistantTabOverlay(isLaunching: Bool) -> some View {
        let assistant = card.link.effectiveAssistant
        if isLaunching {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("Starting session…")
                    .font(.app(.body))
                    .foregroundStyle(.secondary)
                Button(action: onCancelLaunch) {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if card.link.sessionLink != nil {
            VStack(spacing: 12) {
                AssistantIcon(assistant: assistant)
                    .frame(width: CGFloat(32).scaled, height: CGFloat(32).scaled)
                    .foregroundStyle(Color.primary.opacity(0.3))
                Text("\(assistant.displayName) session ended")
                    .font(.app(.body))
                    .foregroundStyle(.secondary)
                Button(action: onResume) {
                    Label("Resume \(assistant.displayName)", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 12) {
                AssistantIcon(assistant: assistant)
                    .frame(width: CGFloat(32).scaled, height: CGFloat(32).scaled)
                    .foregroundStyle(Color.primary.opacity(0.3))
                Text("No agent session")
                    .font(.app(.body))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Shell Tab

    /// Blue vertical bar shown at the insertion point during tab drag-and-drop.
    private var tabDropIndicator: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.accentColor)
            .frame(width: 3, height: 20)
            .padding(.horizontal, -1)
    }

    /// Default shell name (e.g. "zsh", "bash") from the SHELL environment variable.
    private static let userShellName: String = {
        if let shell = ProcessInfo.processInfo.environment["SHELL"] {
            return (shell as NSString).lastPathComponent
        }
        return "shell"
    }()

    @ViewBuilder
    private func shellTab(sessionName: String, isSelected: Bool) -> some View {
        let customName = card.link.tmuxLink?.tabNames?[sessionName]
        // Priority: 1) user-set custom name, 2) polled cwd folder, 3) shell name
        let displayName: String = customName ?? {
            if let folder = terminalPaths[sessionName], !folder.isEmpty {
                return String(folder.prefix(12))
            }
            return Self.userShellName
        }()

        let isHovered = hoveredTab == sessionName

        HStack(spacing: 4) {
            HStack {
                // Close button on left, only on hover
                if isHovered {
                    Button {
                        onKillTerminal(sessionName)
                        if selectedTerminalSession == sessionName {
                            let remaining = shellSessions.filter { $0 != sessionName }
                            selectedTerminalSession = remaining.first
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.app(size: 8, weight: .bold))
                            .foregroundStyle(.primary.opacity(0.6))
                            .frame(width: 14, height: 14)
                            .background {
                                if hoveredCloseBtn == sessionName {
                                    Circle().fill(Color.primary.opacity(0.12))
                                }
                            }
                            .contentShape(Circle())
                    }
                    .buttonStyle(.borderless)
                    .onHover { hoveredCloseBtn = $0 ? sessionName : nil }
                    .help("Close terminal")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "terminal")
                .font(.app(.caption2))
                .padding(.vertical, 2)
            Text(displayName)
                .font(.app(.caption))
                .lineLimit(1)
                .padding(.vertical, 2)

            Spacer()
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .contentShape(Capsule())
        .onTapGesture {
            // Instant switch on every click; detect double-click manually
            // so SwiftUI doesn't delay the first tap for disambiguation.
            let now = CACurrentMediaTime()
            if selectedTerminalSession == sessionName,
               now - lastTabClickTime < NSEvent.doubleClickInterval,
               lastTabClickTarget == sessionName {
                // Second click on same tab within threshold → rename
                tabRenameItem = TabRenameItem(sessionName: sessionName, currentName: customName ?? displayName)
            }
            selectedTerminalSession = sessionName
            selectedBrowserTabId = nil
            terminalGrabFocus = true
            lastTabClickTime = now
            lastTabClickTarget = sessionName
        }
        .background {
            if isSelected {
                Capsule().fill(.background)
                    .shadow(color: .black.opacity(0.1), radius: 1, y: 1)
            } else if isHovered {
                Capsule().fill(Color.primary.opacity(0.04))
            }
        }
        .onHover { hoveredTab = $0 ? sessionName : (hoveredTab == sessionName ? nil : hoveredTab) }
        .onDrag {
            draggingTab = sessionName
            return NSItemProvider(object: sessionName as NSString)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let dropped = items.first, dropped != sessionName else { return false }
            reorderTab(dropped, before: sessionName)
            draggingTab = nil
            dropTargetTab = nil
            return true
        } isTargeted: { targeted in
            if targeted {
                dropTargetTab = sessionName
            } else if dropTargetTab == sessionName {
                dropTargetTab = nil
            }
        }
        .contextMenu {
            Button("Rename") {
                tabRenameItem = TabRenameItem(sessionName: sessionName, currentName: customName ?? displayName)
            }
        }
    }

    // MARK: - Browser Tab

    @ViewBuilder
    private func browserTab(tab: BrowserTab, isSelected: Bool) -> some View {
        let displayName = tab.pageTitle.isEmpty ? "New Tab" : String(tab.pageTitle.prefix(12))
        let isHovered = hoveredTab == tab.id

        HStack(spacing: 4) {
            HStack {
                if isHovered {
                    Button {
                        closeBrowserTab(tab)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.app(size: 8, weight: .bold))
                            .foregroundStyle(.primary.opacity(0.6))
                            .frame(width: 14, height: 14)
                            .background {
                                if hoveredCloseBtn == tab.id {
                                    Circle().fill(Color.primary.opacity(0.12))
                                }
                            }
                            .contentShape(Circle())
                    }
                    .buttonStyle(.borderless)
                    .onHover { hoveredCloseBtn = $0 ? tab.id : nil }
                    .help("Close browser tab")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "globe")
                .font(.app(.caption2))
                .padding(.vertical, 2)
            Text(displayName)
                .font(.app(.caption))
                .lineLimit(1)
                .padding(.vertical, 2)

            Spacer()
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .contentShape(Capsule())
        .onTapGesture(count: 1) {
            selectedBrowserTabId = tab.id
            selectedTerminalSession = nil
        }
        .background {
            if isSelected {
                Capsule().fill(.background)
                    .shadow(color: .black.opacity(0.1), radius: 1, y: 1)
            } else if isHovered {
                Capsule().fill(Color.primary.opacity(0.04))
            }
        }
        .onHover { hoveredTab = $0 ? tab.id : (hoveredTab == tab.id ? nil : hoveredTab) }
        .onDrag {
            draggingTab = tab.id
            return NSItemProvider(object: tab.id as NSString)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let dropped = items.first, dropped != tab.id else { return false }
            reorderTab(dropped, before: tab.id)
            draggingTab = nil
            dropTargetTab = nil
            return true
        } isTargeted: { targeted in
            if targeted {
                dropTargetTab = tab.id
            } else if dropTargetTab == tab.id {
                dropTargetTab = nil
            }
        }
    }

    /// Hydrate live BrowserTab instances from persisted BrowserTabInfo in the link.
    /// Creates or reuses WKWebViews via BrowserTabCache.
    private func hydrateBrowserTabs() -> [BrowserTab] {
        guard let savedTabs = card.link.browserTabs else { return [] }
        return savedTabs.compactMap { tabInfo in
            guard let url = URL(string: tabInfo.url) else { return nil }
            return BrowserTabCache.shared.getOrCreate(cardId: card.id, tabId: tabInfo.id, url: url)
        }
    }

    /// Close a browser tab and fall back to the previous tab if it was selected.
    private func closeBrowserTab(_ tab: BrowserTab) {
        let wasSelected = selectedBrowserTabId == tab.id
        BrowserTabCache.shared.remove(cardId: card.id, tabId: tab.id)
        browserTabs.removeAll { $0.id == tab.id }
        onRemoveBrowserTab(tab.id)

        if wasSelected {
            if let last = browserTabs.last {
                selectedBrowserTabId = last.id
            } else if let lastShell = shellSessions.last {
                selectedBrowserTabId = nil
                selectedTerminalSession = lastShell
            } else {
                selectedBrowserTabId = nil
                selectedTerminalSession = nil
            }
        }
    }

    private func defaultTab(for card: KanbanCodeCard) -> DetailTab {
        DetailTab.initialTab(for: card)
    }
    // MARK: - Normal Header (collapsed inspector)

    @ViewBuilder
    private var normalHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(card.displayTitle)
                    .font(.app(.headline))
                    .textCase(nil)
                    .lineLimit(2)
                    .layoutPriority(0)

                if card.link.cardLabel == .session {
                    Text(card.relativeTime)
                        .font(.app(.caption))
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 8)

                HStack(spacing: 8) {
                    if let primary = card.link.prLink {
                        PRSummaryPill(prLinks: card.link.prLinks, primary: primary)
                    }
                    if let mergePR = card.link.mergeablePR {
                        MergeButton(pr: mergePR, projectPath: card.link.projectPath, onMerged: { onPRMerged($0) }, onToast: showCopyToast)
                    }
                    if card.link.tmuxLink == nil {
                        let hasSession = card.link.sessionLink != nil
                        let isStart = card.column == .backlog || !hasSession
                        Button(action: onResume) {
                            Label(isStart ? "Start" : "Resume", systemImage: "play.fill")
                                .font(.app(size: 13))
                                .foregroundStyle(isStart ? Color.green.opacity(0.8) : Color.blue.opacity(0.8))
                                .padding(.horizontal, 12)
                                .frame(height: 36)
                                .background((isStart ? Color.green : Color.blue).opacity(0.08), in: Capsule())
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        .buttonStyle(HoverFeedbackStyle())
                        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                        .help(isStart ? "Start work on this task" : "Resume session")
                    }

                    if let path = card.link.worktreeLink?.path ?? card.link.projectPath {
                        Button {
                            EditorDiscovery.open(path: path, bundleId: editorBundleId)
                        } label: {
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                                .font(.app(size: 13))
                                .frame(width: CGFloat(36).scaled, height: CGFloat(36).scaled)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular, in: .capsule)
                        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                        .modifier(HoverBrightness())
                        .help("Open in editor")
                    }

                    actionsMenuButton
                        .glassEffect(.regular, in: .capsule)
                        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                        .modifier(HoverBrightness())
                        .help("More actions")
                }
                .fixedSize()
            }

            if card.link.cardLabel != .session {
                HStack(spacing: 6) {
                    CardLabelBadge(label: card.link.cardLabel)
                    Spacer()
                    Text(card.relativeTime)
                        .font(.app(.caption))
                        .foregroundStyle(.tertiary)
                }
            }

            if card.link.isRemote {
                HStack(spacing: 2) {
                    Image(systemName: "cloud")
                        .font(.app(.caption))
                        .foregroundStyle(.teal)
                    Text("Remote")
                        .font(.app(.caption))
                        .foregroundStyle(.teal)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                if let branch = card.link.worktreeLink?.branch, !branch.isEmpty {
                    linkPropertyRow(icon: "arrow.triangle.branch", label: "Branch", value: branch, onUnlink: { onUnlink(.worktree) })
                } else if let discovered = card.link.discoveredBranches?.first {
                    linkPropertyRow(icon: "arrow.triangle.branch", label: "Branch", value: discovered, onUnlink: { onUnlink(.worktree) })
                }
                if let worktreePath = card.link.worktreeLink?.path, !worktreePath.isEmpty {
                    copyableRow(icon: "folder", text: worktreePath)
                }
                ForEach(card.link.prLinks, id: \.number) { pr in
                    let detail = pr.status.map { " · \($0.rawValue)" } ?? ""
                    let prURL = pr.url ?? githubBaseURL.map { GitRemoteResolver.prURL(base: $0, number: pr.number) }
                    linkPropertyRow(icon: "arrow.triangle.pull", label: "PR", value: "#\(String(pr.number))\(detail)", url: prURL, onUnlink: { onUnlink(.pr(number: pr.number)) })
                }
                if let issue = card.link.issueLink {
                    let issueURL = issue.url ?? githubBaseURL.map { GitRemoteResolver.issueURL(base: $0, number: issue.number) }
                    linkPropertyRow(icon: "circle.circle", label: "Issue", value: "#\(String(issue.number))", url: issueURL, onUnlink: { onUnlink(.issue) })
                }
                if let projectPath = card.link.projectPath {
                    copyableRow(icon: "folder.badge.gearshape", text: projectPath)
                }
                if let sessionId = card.link.sessionLink?.sessionId {
                    SessionIdRow(sessionId: sessionId, assistant: card.link.effectiveAssistant)
                }
                Button { showAddLink = true } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "plus").font(.app(.caption2))
                        Text("Add link").font(.app(.caption))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showAddLink) {
                    AddLinkPopover(
                        onAddBranch: { onAddBranch($0); showAddLink = false },
                        onAddIssue: { onAddIssue($0); showAddLink = false },
                        onAddPR: { onAddPR($0); showAddLink = false }
                    )
                }
            }
        }
        .padding(16)

        Divider()

        // Tab bar
        HStack {
            Picker("", selection: $selectedTab) {
                Text("Terminal").tag(DetailTab.terminal)
                Text("History").tag(DetailTab.history)
                if card.link.issueLink != nil { Text("Issue").tag(DetailTab.issue) }
                if !card.link.prLinks.isEmpty { Text("Pull Request").tag(DetailTab.pullRequest) }
                if card.link.promptBody != nil && card.link.issueLink == nil { Text("Prompt").tag(DetailTab.prompt) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Expand/Collapse Button

    private var expandCollapseButton: some View {
        Button {
            isExpanded.toggle()
        } label: {
            Image(systemName: isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                .font(.app(size: 13))
                .frame(width: CGFloat(36).scaled, height: CGFloat(36).scaled)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: .capsule)
        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
        .modifier(HoverBrightness())
        .help(isExpanded ? "Contract (⌘⏎)" : "Expand (⌘⏎)")
    }

    private var actionsMenuButton: some View {
        NSMenuButton {
            Image(systemName: "ellipsis")
                .font(.app(.caption))
                .frame(width: CGFloat(36).scaled, height: CGFloat(36).scaled)
                .contentShape(Circle())
        } menuItems: {
            buildActionsMenu()
        }
    }

    private func buildActionsMenu() -> NSMenu {
        let menu = NSMenu()

        if isExpanded {
            // Card info section — replaces the inspector header in expanded mode
            if let branch = card.link.worktreeLink?.branch ?? card.link.discoveredBranches?.first, !branch.isEmpty {
                let branchItem = NSMenuItem(title: "Branch: \(branch)", action: nil, keyEquivalent: "")
                branchItem.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)
                let branchSub = NSMenu()
                branchSub.addActionItem("Copy Branch Name") { [self] in copyToClipboard(branch) }
                if card.link.worktreeLink != nil {
                    branchSub.addActionItem("Unlink Branch") { [self] in onUnlink(.worktree) }
                }
                branchItem.submenu = branchSub
                menu.addItem(branchItem)
            }
            for pr in card.link.prLinks {
                let detail = pr.status.map { " · \($0.rawValue)" } ?? ""
                let prItem = NSMenuItem(title: "PR: #\(pr.number)\(detail)", action: nil, keyEquivalent: "")
                prItem.image = NSImage(systemSymbolName: "arrow.triangle.pull", accessibilityDescription: nil)
                let prSub = NSMenu()
                if let url = pr.url.flatMap({ URL(string: $0) }) {
                    prSub.addActionItem("Open on GitHub") { NSWorkspace.shared.open(url) }
                }
                prSub.addActionItem("Copy PR Number") { [self] in copyToClipboard("#\(pr.number)") }
                prSub.addActionItem("Unlink PR") { [self] in onUnlink(.pr(number: pr.number)) }
                prItem.submenu = prSub
                menu.addItem(prItem)
            }
            if let issue = card.link.issueLink {
                let issueItem = NSMenuItem(title: "Issue: #\(issue.number)", action: nil, keyEquivalent: "")
                issueItem.image = NSImage(systemSymbolName: "circle.circle", accessibilityDescription: nil)
                let issueSub = NSMenu()
                if let url = (issue.url ?? githubBaseURL.map { GitRemoteResolver.issueURL(base: $0, number: issue.number) }).flatMap({ URL(string: $0) }) {
                    issueSub.addActionItem("Open on GitHub") { NSWorkspace.shared.open(url) }
                }
                issueSub.addActionItem("Copy Issue Number") { [self] in copyToClipboard("#\(issue.number)") }
                issueSub.addActionItem("Unlink Issue") { [self] in onUnlink(.issue) }
                issueItem.submenu = issueSub
                menu.addItem(issueItem)
            }
            menu.addActionItem("Add Link", image: "plus") { [self] in showAddLink = true }
            menu.addItem(NSMenuItem.separator())
        }

        menu.addActionItem("Rename", image: "pencil") { [self] in showRenameSheet = true }

        let forkItem = menu.addActionItem("Fork Session", image: "arrow.branch") { [self] in onFork(true) }
        forkItem.isEnabled = card.link.sessionLink?.sessionPath != nil

        let cpItem = menu.addActionItem("Checkpoint / Restore", image: "clock.arrow.circlepath") { [self] in
            checkpointMode = true
            selectedTab = .history
        }
        cpItem.isEnabled = card.link.sessionLink?.sessionPath != nil && !turns.isEmpty

        menu.addItem(NSMenuItem.separator())

        menu.addActionItem("Copy Resume Command", image: "doc.on.doc") { [self] in copyResumeCommand() }
        menu.addActionItem("Copy Card ID", image: "number") { [self] in copyToClipboard(card.id) }

        if let sessionId = card.link.sessionLink?.sessionId {
            let sessionItem = menu.addActionItem("Copy Session ID") { [self] in copyToClipboard(sessionId) }
            if let img = AssistantIcon.menuImage(for: card.link.effectiveAssistant) {
                sessionItem.image = img
            }
        }

        if let tmux = card.link.tmuxLink?.sessionName {
            menu.addActionItem("Copy Tmux Command", image: "terminal") { [self] in copyToClipboard("tmux attach -t \(tmux)") }
        }

        if let projectPath = card.link.projectPath {
            menu.addActionItem("Copy Project Path", image: "folder.badge.gearshape") { [self] in copyToClipboard(projectPath) }
        }
        if let worktreePath = card.link.worktreeLink?.path, !worktreePath.isEmpty {
            menu.addActionItem("Copy Worktree Path", image: "folder") { [self] in copyToClipboard(worktreePath) }
        }

        if !card.link.prLinks.isEmpty {
            menu.addItem(NSMenuItem.separator())
            for pr in card.link.prLinks {
                menu.addActionItem("Open PR #\(pr.number)", image: "arrow.up.right.square") {
                    if let url = pr.url.flatMap({ URL(string: $0) }) { NSWorkspace.shared.open(url) }
                }
            }
        }

        if card.link.sessionLink != nil || card.link.worktreeLink != nil {
            menu.addItem(NSMenuItem.separator())
            menu.addActionItem("Discover Branch", image: "arrow.triangle.pull") { [self] in onDiscover() }
        }

        if let issue = card.link.issueLink {
            menu.addActionItem("Open Issue #\(issue.number)", image: "arrow.up.right.square") {
                if let url = issue.url.flatMap({ URL(string: $0) }) { NSWorkspace.shared.open(url) }
            }
        }

        if card.link.worktreeLink != nil, canCleanupWorktree {
            menu.addItem(NSMenuItem.separator())
            menu.addActionItem("Cleanup Worktree", image: "trash") { [self] in onCleanupWorktree() }
        }

        if card.link.sessionLink != nil {
            let currentPath = card.link.projectPath
            let otherProjects = availableProjects.filter { $0.path != currentPath }
            menu.addItem(NSMenuItem.separator())
            let moveItem = NSMenuItem(title: "Move to Project", action: nil, keyEquivalent: "")
            moveItem.image = NSImage(systemSymbolName: "folder.badge.arrow.forward", accessibilityDescription: nil)
            let submenu = NSMenu()
            for project in otherProjects {
                let item = submenu.addActionItem(project.name) { [self] in onMoveToProject(project.path) }
                _ = item
            }
            if !otherProjects.isEmpty {
                submenu.addItem(NSMenuItem.separator())
            }
            submenu.addActionItem("Select Folder...") { [self] in onMoveToFolder() }
            moveItem.submenu = submenu
            menu.addItem(moveItem)
        }

        if card.link.sessionLink != nil {
            let migrationTargets = enabledAssistants.filter { $0 != card.link.effectiveAssistant }
            if !migrationTargets.isEmpty {
                menu.addItem(NSMenuItem.separator())
                let migrateItem = NSMenuItem(title: "Migrate to Assistant", action: nil, keyEquivalent: "")
                migrateItem.image = NSImage(systemSymbolName: "arrow.triangle.swap", accessibilityDescription: nil)
                let migrateSubmenu = NSMenu()
                for target in migrationTargets {
                    let item = migrateSubmenu.addActionItem(target.displayName) { [self] in onMigrateAssistant(target) }
                    _ = item
                }
                migrateItem.submenu = migrateSubmenu
                menu.addItem(migrateItem)
            }
        }

        menu.addItem(NSMenuItem.separator())
        menu.addActionItem("Delete Card", image: "trash") { [self] in onDeleteCard(); onDismiss() }

        return menu
    }

    // MARK: - History loading

    private static let pageSize = 80
    private static let chatPageSize = 30

    private func loadHistory() async {
        guard let path = card.link.sessionLink?.sessionPath ?? card.session?.jsonlPath else { return }
        // Prevent concurrent reloads — they race on lastLineNumber and duplicate turns
        guard !isReloadingHistory else { return }
        isReloadingHistory = true
        defer { isReloadingHistory = false }

        if turns.isEmpty { isLoadingHistory = true }
        let baseSize = preferChatView ? Self.chatPageSize : Self.pageSize
        let loadCount = max(baseSize, turns.count)
        let assistant = card.link.effectiveAssistant
        let store = sessionStore
        let lastLineNumber = turns.last?.lineNumber ?? 0
        let isEmpty = turns.isEmpty

        do {
            // File I/O + JSON parsing runs OFF the main actor to avoid freezing
            let parsed = try await Task.detached { () -> TranscriptReader.ReadResult in
                if assistant == .gemini {
                    let allTurns = try await store.readTranscript(sessionPath: path)
                    return TranscriptReader.ReadResult(turns: allTurns, totalLineCount: -1, hasMore: false)
                } else {
                    return try await TranscriptReader.readTail(from: path, maxTurns: loadCount)
                }
            }.value

            // Back on main actor — update @State
            if isEmpty {
                turns = parsed.turns
                hasMoreTurns = parsed.hasMore
            } else {
                // Deduplicate: only append turns with lineNumbers not already present
                let existingLineNumbers = Set(turns.map(\.lineNumber))
                let newTurns = parsed.turns.filter { $0.lineNumber > lastLineNumber && !existingLineNumbers.contains($0.lineNumber) }
                if !newTurns.isEmpty {
                    turns.append(contentsOf: newTurns)
                }
            }
        } catch {
            // Silently fail — empty history is fine
        }
        isLoadingHistory = false
    }

    private func loadMoreHistory() async {
        guard hasMoreTurns, !isLoadingMore else { return }
        guard let path = card.link.sessionLink?.sessionPath ?? card.session?.jsonlPath else { return }

        isLoadingMore = true
        let newCount = turns.count + (preferChatView ? Self.chatPageSize : Self.pageSize)
        do {
            let result = try await Task.detached {
                try await TranscriptReader.readTail(from: path, maxTurns: newCount)
            }.value
            turns = result.turns
            hasMoreTurns = result.hasMore
        } catch {
            // Silently fail
        }
        isLoadingMore = false
    }

    /// Load turns around a specific turn index (for search match navigation).
    /// Loads a page-sized chunk around the target, merging with existing turns.
    private func loadAroundTurn(_ targetIndex: Int) async {
        guard let path = card.link.sessionLink?.sessionPath ?? card.session?.jsonlPath else { return }
        isLoadingMore = true

        let halfPage = Self.pageSize / 2
        let rangeStart = max(0, targetIndex - halfPage)
        let rangeEnd = targetIndex + halfPage

        do {
            let chunk = try await TranscriptReader.readRange(from: path, turnRange: rangeStart..<rangeEnd)
            var byIndex: [Int: ConversationTurn] = [:]
            for t in turns { byIndex[t.index] = t }
            for t in chunk { byIndex[t.index] = t }
            turns = byIndex.values.sorted { $0.index < $1.index }
            hasMoreTurns = (turns.first?.index ?? 0) > 0
        } catch { }
        isLoadingMore = false
    }

    // MARK: - File watcher

    private func startHistoryWatcher() {
        stopHistoryWatcher()
        guard let path = card.link.sessionLink?.sessionPath ?? card.session?.jsonlPath else { return }

        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        historyWatcherFD = fd

        let source = Self.makeHistorySource(fd: fd)
        historyWatcherSource = source

        // Periodic poll as fallback — handles DispatchSource dying (inode changes
        // from atomic writes) and tab switches. Checks file mtime to avoid
        // unnecessary reloads.
        historyPollTask = Task { @MainActor in
            var lastMtime: Date = .distantPast
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { break }
                // Continue polling even if tab changed — don't break, just skip
                guard selectedTab == .history || (selectedTab == .terminal && preferChatView) else { continue }

                // Only reload if file was actually modified
                if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                   let mtime = attrs[.modificationDate] as? Date,
                   mtime > lastMtime {
                    lastMtime = mtime
                    await loadHistory()

                    // Re-open DispatchSource if inode changed (atomic write detection)
                    let newFd = open(path, O_EVTONLY)
                    if newFd >= 0 && newFd != historyWatcherFD {
                        historyWatcherSource?.cancel()
                        historyWatcherFD = newFd
                        historyWatcherSource = Self.makeHistorySource(fd: newFd)
                    } else if newFd >= 0 && newFd == historyWatcherFD {
                        close(newFd) // same fd, don't leak
                    }
                }
            }
        }
    }

    /// Must be nonisolated so GCD closures don't inherit @MainActor isolation (causes crash).
    private nonisolated static func makeHistorySource(fd: Int32) -> DispatchSourceFileSystemObject {
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib],
            queue: .global(qos: .userInitiated)
        )
        source.setEventHandler {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .kanbanCodeHistoryChanged, object: nil)
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        return source
    }

    private func stopHistoryWatcher() {
        historyWatcherSource?.cancel()
        historyWatcherSource = nil
        historyWatcherFD = -1
        historyPollTask?.cancel()
        historyPollTask = nil
    }

    // MARK: - Terminal path polling

    /// Polls tmux for each managed session's current working directory every 3 seconds.
    /// Uses tmux `list-panes` with the session name to get `pane_current_path`.
    private func startPathPolling() {
        pathPollTask?.cancel()
        // Capture the base session name — stable for the card's lifetime.
        guard let baseName = card.link.tmuxLink?.sessionName else { return }
        pathPollTask = Task {
            let tmux = TerminalCache.tmuxPath
            while !Task.isCancelled {
                // Only poll when a shell tab is selected — no need to update
                // folder names for tabs that aren't visible.
                if selectedTerminalSession != nil {
                    // Query panes for extra shell sessions (base-sh1, base-sh2, ...).
                    // Skip the primary session — it always shows the assistant name.
                    if let result = try? await ShellCommand.run(
                        tmux, arguments: [
                            "list-panes", "-a",
                            "-F", "#{session_name}\t#{pane_current_path}",
                            "-f", "#{m:\(baseName)-*,#{session_name}}"
                        ]
                    ) {
                        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                        for line in output.components(separatedBy: "\n") where !line.isEmpty {
                            let parts = line.components(separatedBy: "\t")
                            guard parts.count >= 2 else { continue }
                            let session = parts[0]
                            let folder = (parts[1] as NSString).lastPathComponent
                            if !folder.isEmpty && folder != terminalPaths[session] {
                                terminalPaths[session] = folder
                            }
                        }
                    }
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    // MARK: - Fork (handled by onFork callback)

    // MARK: - Checkpoint

    private func performCheckpoint() {
        guard let path = card.link.sessionLink?.sessionPath,
              let turn = checkpointTurn else { return }
        Task {
            do {
                // Kill the active Claude session first so it doesn't rewrite the truncated file
                if let sessionName = card.link.tmuxLink?.sessionName {
                    onKillTerminal(sessionName)
                }
                try await sessionStore.truncateSession(sessionPath: path, afterTurn: turn)
                checkpointMode = false
                checkpointTurn = nil
                // Force clear and reload turns so the view updates
                turns = []
                await loadHistory()
            } catch {
                // Could show error toast
            }
        }
    }

    private func copyResumeCommand() {
        var cmd = ""
        if let projectPath = card.link.projectPath {
            cmd += "cd \(projectPath) && "
        }
        if let sessionId = card.link.sessionLink?.sessionId {
            cmd += "claude --resume \(sessionId)"
        } else {
            cmd += "# no session yet"
        }
        copyToClipboard(cmd)
    }

    /// Property row: icon + "Label: value", all secondary color, with optional link and × buttons.
    private func linkPropertyRow(
        icon: String, label: String, value: String,
        color: Color = .secondary,
        url: String? = nil,
        onUnlink: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 4) {
            Label {
                Text("\(label): \(value)")
            } icon: {
                Image(systemName: icon)
            }
            .font(.app(.caption))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)

            if let url, let parsed = URL(string: url) {
                Button {
                    NSWorkspace.shared.open(parsed)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.app(.caption2))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Open in browser")

                Button {
                    copyToClipboard(url)
                    showCopyToast("\(label) link copied to clipboard")
                } label: {
                    Image(systemName: "link")
                        .font(.app(.caption2))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .help("Copy link")
            }

            if let onUnlink {
                Button {
                    onUnlink()
                } label: {
                    Image(systemName: "xmark")
                        .font(.app(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .help("Remove link")
            }
        }
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func showCopyToast(_ message: String) {
        copyToast = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if copyToast == message { copyToast = nil }
        }
    }

    private func copyableRow(icon: String, text: String) -> some View {
        CopyableRow(icon: icon, text: text)
    }
}
