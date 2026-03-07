import SwiftUI
import KanbanCodeCore
import MarkdownUI

private enum DetailTab: String {
    case terminal, history, issue, pullRequest, prompt
}

/// Button style that provides hover (brighten) and press (dim + scale) feedback
/// for custom-styled plain buttons.
private struct HoverFeedbackStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverableBody(configuration: configuration)
    }

    private struct HoverableBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .brightness(configuration.isPressed ? -0.08 : isHovered ? 0.06 : 0)
                .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
                .onHover { isHovered = $0 }
                .animation(.easeInOut(duration: 0.12), value: isHovered)
                .animation(.easeInOut(duration: 0.08), value: configuration.isPressed)
        }
    }
}

/// View modifier that adds hover brightness feedback (for Menu and other non-Button views).
private struct HoverBrightness: ViewModifier {
    var amount: Double = 0.06
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .brightness(isHovered ? amount : 0)
            .onHover { isHovered = $0 }
            .animation(.easeInOut(duration: 0.12), value: isHovered)
    }
}

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
    var onPRMerged: (Int) -> Void = { _ in }
    var onCancelLaunch: () -> Void = {}
    var onAddQueuedPrompt: (QueuedPrompt) -> Void = { _ in }
    var onUpdateQueuedPrompt: (String, String, Bool) -> Void = { _, _, _ in } // promptId, body, sendAuto
    var onRemoveQueuedPrompt: (String) -> Void = { _ in }
    var onSendQueuedPrompt: (String) -> Void = { _ in }
    var onDiscover: () -> Void = {}
    var onUpdatePrompt: (String, [String]?) -> Void = { _, _ in } // body, imagePaths
    var availableProjects: [(name: String, path: String)] = []
    var onMoveToProject: (String) -> Void = { _ in }
    @Binding var focusTerminal: Bool

    @AppStorage("preferredEditorBundleId") private var editorBundleId: String = "dev.zed.Zed"

    @State private var turns: [ConversationTurn] = []
    @State private var isLoadingHistory = false
    @State private var hasMoreTurns = false
    @State private var isLoadingMore = false
    @State private var selectedTab: DetailTab
    @State private var showRenameSheet = false
    @State private var renameText = ""

    // Checkpoint mode
    @State private var checkpointMode = false
    @State private var checkpointTurn: ConversationTurn?
    @State private var showCheckpointConfirm = false

    // Fork
    @State private var showForkConfirm = false

    // Add link popover
    @State private var showAddLink = false

    // Copy toast
    @State private var copyToast: String?

    // Resolved GitHub base URL for constructing issue/PR links
    @State private var githubBaseURL: String?

    // Lazy PR body loading
    @State private var prBody: String?
    @State private var isLoadingPRBody = false
    @State private var isMerging = false
    @State private var mergeError: String?
    @State private var showMergeBlockedPopover = false

    // Queued prompts
    @State private var showQueuedPromptDialog = false
    @State private var editingQueuedPrompt: QueuedPrompt?

    // Edit prompt
    @State private var showEditPromptSheet = false

    // File watcher for real-time history
    @State private var historyWatcherFD: Int32 = -1
    @State private var historyWatcherSource: DispatchSourceFileSystemObject?
    @State private var historyPollTask: Task<Void, Never>?
    @State private var lastReloadTime: Date = .distantPast

    // Multi-terminal
    @State private var selectedTerminalSession: String?
    @State private var knownTerminalCount: Int = 0
    @State private var terminalGrabFocus: Bool = false
    @State private var suppressTerminalFocus: Bool = false
    @State private var renamingSession: String?
    @State private var tabRenameText: String = ""

    /// Launch lock older than 30s is stale — stop showing spinner, show terminal instead
    private var isLaunchStale: Bool {
        Date.now.timeIntervalSince(card.link.updatedAt) > 30
    }

    let sessionStore: SessionStore

    init(card: KanbanCodeCard, sessionStore: SessionStore = ClaudeCodeSessionStore(), onResume: @escaping () -> Void = {}, onRename: @escaping (String) -> Void = { _ in }, onFork: @escaping (_ keepWorktree: Bool) -> Void = { _ in }, onDismiss: @escaping () -> Void = {}, onUnlink: @escaping (Action.LinkType) -> Void = { _ in }, onAddBranch: @escaping (String) -> Void = { _ in }, onAddIssue: @escaping (Int) -> Void = { _ in }, onAddPR: @escaping (Int) -> Void = { _ in }, onCleanupWorktree: @escaping () -> Void = {}, canCleanupWorktree: Bool = true, onDeleteCard: @escaping () -> Void = {}, onCreateTerminal: @escaping () -> Void = {}, onKillTerminal: @escaping (String) -> Void = { _ in }, onRenameTerminal: @escaping (String, String) -> Void = { _, _ in }, onPRMerged: @escaping (Int) -> Void = { _ in }, onCancelLaunch: @escaping () -> Void = {}, onAddQueuedPrompt: @escaping (QueuedPrompt) -> Void = { _ in }, onUpdateQueuedPrompt: @escaping (String, String, Bool) -> Void = { _, _, _ in }, onRemoveQueuedPrompt: @escaping (String) -> Void = { _ in }, onSendQueuedPrompt: @escaping (String) -> Void = { _ in }, onDiscover: @escaping () -> Void = {}, onUpdatePrompt: @escaping (String, [String]?) -> Void = { _, _ in }, availableProjects: [(name: String, path: String)] = [], onMoveToProject: @escaping (String) -> Void = { _ in }, focusTerminal: Binding<Bool> = .constant(false)) {
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
        self.onPRMerged = onPRMerged
        self.onCancelLaunch = onCancelLaunch
        self.onAddQueuedPrompt = onAddQueuedPrompt
        self.onUpdateQueuedPrompt = onUpdateQueuedPrompt
        self.onRemoveQueuedPrompt = onRemoveQueuedPrompt
        self.onSendQueuedPrompt = onSendQueuedPrompt
        self.onDiscover = onDiscover
        self.onUpdatePrompt = onUpdatePrompt
        self.availableProjects = availableProjects
        self.onMoveToProject = onMoveToProject
        self._focusTerminal = focusTerminal
        _selectedTab = State(initialValue: Self.initialTab(for: card))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
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

                    // Action pills
                    HStack(spacing: 8) {
                        // PR summary pill
                        if let primary = card.link.prLink {
                            prSummaryPill(primary: primary)
                        }

                        // Merge button — only when exactly one open PR exists
                        if let mergePR = card.link.mergeablePR {
                            mergeButton(pr: mergePR)
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
                            //.glassEffect(.regular, in: .capsule)
                            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                            .modifier(HoverBrightness())
                            .help("Open in editor")
                        }

                        actionsMenuButton
                            //.glassEffect(.regular, in: .capsule)
                            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                            .modifier(HoverBrightness())
                            .help("More actions")
                    }
                    .fixedSize()
                }

                // Badge row (only when not a session — sessions show session icon on the ID row)
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

                // Property rows — one per link type
                VStack(alignment: .leading, spacing: 2) {
                    if let branch = card.link.worktreeLink?.branch, !branch.isEmpty {
                        linkPropertyRow(
                            icon: "arrow.triangle.branch", label: "Branch", value: branch,
                            onUnlink: { onUnlink(.worktree) }
                        )
                    } else if let discovered = card.link.discoveredBranches?.first {
                        // Show latest discovered branch (from JSONL scanning) when no worktreeLink.
                        // Dismissing sets watermark + clears discoveredBranches via .worktree unlink.
                        linkPropertyRow(
                            icon: "arrow.triangle.branch", label: "Branch", value: discovered,
                            onUnlink: { onUnlink(.worktree) }
                        )
                    }
                    if let worktreePath = card.link.worktreeLink?.path, !worktreePath.isEmpty {
                        copyableRow(icon: "folder", text: worktreePath)
                    }
                    ForEach(card.link.prLinks, id: \.number) { pr in
                        let detail = pr.status.map { " · \($0.rawValue)" } ?? ""
                        let prURL = pr.url ?? githubBaseURL.map { GitRemoteResolver.prURL(base: $0, number: pr.number) }
                        linkPropertyRow(
                            icon: "arrow.triangle.pull", label: "PR", value: "#\(String(pr.number))\(detail)",
                            url: prURL,
                            onUnlink: { onUnlink(.pr(number: pr.number)) }
                        )
                    }
                    if let issue = card.link.issueLink {
                        let issueURL = issue.url ?? githubBaseURL.map { GitRemoteResolver.issueURL(base: $0, number: issue.number) }
                        linkPropertyRow(
                            icon: "circle.circle", label: "Issue", value: "#\(String(issue.number))",
                            url: issueURL,
                            onUnlink: { onUnlink(.issue) }
                        )
                    }
                    if let projectPath = card.link.projectPath {
                        copyableRow(icon: "folder.badge.gearshape", text: projectPath)
                    }
                    if let sessionId = card.link.sessionLink?.sessionId {
                        SessionIdRow(sessionId: sessionId)
                    }

                    // Add link button
                    Button {
                        showAddLink = true
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "plus")
                                .font(.app(.caption2))
                            Text("Add link")
                                .font(.app(.caption))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showAddLink) {
                        AddLinkPopover(
                            onAddBranch: { branch in
                                onAddBranch(branch)
                                showAddLink = false
                            },
                            onAddIssue: { number in
                                onAddIssue(number)
                                showAddLink = false
                            },
                            onAddPR: { number in
                                onAddPR(number)
                                showAddLink = false
                            }
                        )
                    }
                }
            }
            .padding(16)

            Divider()

            // Tab bar + cleanup worktree button
            HStack {
                Picker("", selection: $selectedTab) {
                    Text("Terminal").tag(DetailTab.terminal)
                    Text("History").tag(DetailTab.history)
                    if card.link.issueLink != nil {
                        Text("Issue").tag(DetailTab.issue)
                    }
                    if !card.link.prLinks.isEmpty {
                        Text("Pull Request").tag(DetailTab.pullRequest)
                    }
                    if card.link.promptBody != nil && card.link.issueLink == nil {
                        Text("Prompt").tag(DetailTab.prompt)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if card.link.worktreeLink != nil, canCleanupWorktree {
                    Spacer()
                    Button(role: .destructive, action: onCleanupWorktree) {
                        Label("Cleanup Worktree", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

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
                issueTabView
            case .pullRequest:
                prTabView
            case .prompt:
                promptTabView
            }
        }
        .frame(maxWidth: .infinity)
        .task(id: card.id) {
            turns = []
            isLoadingHistory = false
            isLoadingMore = false
            hasMoreTurns = false
            checkpointMode = false
            prBody = nil
            isLoadingPRBody = false
            selectedTerminalSession = nil
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
            if selectedTab == .pullRequest {
                await loadPRBody()
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
            if selectedTab == .pullRequest && prBody == nil && !isLoadingPRBody {
                Task { await loadPRBody() }
            }
        }
        .onChange(of: card.link.sessionLink?.sessionPath) {
            // When a session path appears (e.g., after launch discovers the session),
            // restart the watcher so history starts updating live.
            guard selectedTab == .history else { return }
            guard card.link.sessionLink?.sessionPath != nil else { return }
            startHistoryWatcher()
            Task { await loadHistory() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .kanbanCodeHistoryChanged)) { _ in
            guard selectedTab == .history else { return }
            // Debounce: only reload if >0.5s since last reload
            let now = Date()
            guard now.timeIntervalSince(lastReloadTime) > 0.5 else { return }
            lastReloadTime = now
            Task { await loadHistory() }
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
        }
        .sheet(isPresented: $showRenameSheet) {
            RenameSessionDialog(
                currentName: card.link.name ?? card.displayTitle,
                isPresented: $showRenameSheet,
                onRename: onRename
            )
        }
        .sheet(isPresented: $showQueuedPromptDialog) {
            QueuedPromptDialog(
                isPresented: $showQueuedPromptDialog,
                existingPrompt: editingQueuedPrompt,
                onSave: { body, sendAuto, images in
                    let imagePaths: [String]? = images.isEmpty ? nil : images.compactMap { img in
                        var mutable = img
                        return try? mutable.saveToPersistent()
                    }
                    if let existing = editingQueuedPrompt {
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
        .alert("Fork Session?", isPresented: $showForkConfirm) {
            Button("Cancel", role: .cancel) {}
            if card.link.worktreeLink != nil {
                Button("Fork (same worktree)") { onFork(true) }
            }
            Button("Fork (project root)") { onFork(false) }
        } message: {
            if card.link.worktreeLink != nil {
                Text("This creates a duplicate session you can resume independently. Do you want the forked session to continue from the same worktree or from the project root?")
            } else {
                Text("This creates a duplicate session you can resume independently.")
            }
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

    /// Whether the Claude tab is selected (nil = Claude tab).
    private var isClaudeTabSelected: Bool {
        selectedTerminalSession == nil
    }

    /// The tmux session name for the live Claude terminal, if any.
    private var claudeTmuxSession: String? {
        guard let tmux = card.link.tmuxLink,
              tmux.isShellOnly != true,
              tmux.isPrimaryDead != true else { return nil }
        return tmux.sessionName
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

    /// Whether the tab bar should be visible.
    private var showTabBar: Bool {
        card.link.tmuxLink != nil || card.link.sessionLink != nil ||
        card.link.isLaunching == true
    }

    @ViewBuilder
    private var terminalView: some View {
        if showTabBar {
            let isLaunching = card.link.isLaunching == true && !isLaunchStale
            let showOverlay = isClaudeTabSelected && effectiveActiveSession == nil

            VStack(spacing: 0) {
                // Tab bar: [Claude] [shell tabs...] [+]  ···spacer···  [copy tmux attach]
                HStack(spacing: 4) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            // Claude tab — always first
                            claudeTab(isSelected: isClaudeTabSelected, isLaunching: isLaunching)

                            // Shell session tabs
                            ForEach(shellSessions, id: \.self) { sessionName in
                                shellTab(
                                    sessionName: sessionName,
                                    isSelected: selectedTerminalSession == sessionName
                                )
                            }

                            Button(action: onCreateTerminal) {
                                Image(systemName: "plus")
                                    .font(.app(.caption))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                            .help("Open new terminal")
                        }
                    }

                    Spacer()

                    // Copy tmux attach — only for live terminal tabs
                    if let activeTmux = effectiveActiveSession {
                        Button {
                            let cmd = "tmux attach -t \(activeTmux)"
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(cmd, forType: .string)
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "doc.on.doc")
                                    .font(.app(.caption2))
                                Text("Copy tmux attach")
                                    .font(.app(.caption))
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Copy: tmux attach -t \(activeTmux)")

                        Button {
                            showQueuedPromptDialog = true
                            editingQueuedPrompt = nil
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "text.badge.plus")
                                    .font(.app(.caption2))
                                Text("Queue Prompt")
                                    .font(.app(.caption))
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Queue a prompt to send to Claude later")
                    }
                }
                .padding(.leading, 16)
                .padding(.trailing, 8)
                .padding(.vertical, 4)

                Divider()

                // Queued prompts bar
                if let prompts = card.link.queuedPrompts, !prompts.isEmpty {
                    QueuedPromptsBar(
                        prompts: prompts,
                        onSendNow: { promptId in onSendQueuedPrompt(promptId) },
                        onEdit: { prompt in
                            editingQueuedPrompt = prompt
                            showQueuedPromptDialog = true
                        },
                        onRemove: { promptId in onRemoveQueuedPrompt(promptId) }
                    )
                    Divider()
                }

                // Content area: single TerminalContainerView + overlay for non-terminal states
                ZStack {
                    // Single terminal container for ALL live sessions — never recreated on tab switch
                    if !allLiveSessions.isEmpty, let active = effectiveActiveSession ?? allLiveSessions.first {
                        TerminalContainerView(
                            sessions: allLiveSessions,
                            activeSession: active,
                            grabFocus: terminalGrabFocus
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(showOverlay ? 0 : 1)
                        .onAppear {
                            DispatchQueue.main.async { terminalGrabFocus = false }
                        }
                    }

                    // Overlay for non-terminal Claude tab states
                    if showOverlay {
                        claudeTabOverlay(isLaunching: isLaunching)
                    }
                }
            }
            .onChange(of: card.link.tmuxLink) {
                let shells = shellSessions
                let newCount = shells.count + (claudeTmuxSession != nil ? 1 : 0)

                if let selected = selectedTerminalSession, !shells.contains(selected) {
                    // Selected shell was killed — go to next shell or Claude tab
                    selectedTerminalSession = shells.first // nil if no shells left → Claude tab
                } else if newCount > knownTerminalCount, let last = shells.last {
                    // New shell was added — auto-switch to it
                    selectedTerminalSession = last
                }

                knownTerminalCount = newCount
            }
            .onAppear {
                knownTerminalCount = shellSessions.count + (claudeTmuxSession != nil ? 1 : 0)
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
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Claude Tab

    @ViewBuilder
    private func claudeTab(isSelected: Bool, isLaunching: Bool) -> some View {
        let claudeAlive = claudeTmuxSession != nil
        let isDead = !claudeAlive && !isLaunching

        HStack(spacing: 0) {
            Button {
                selectedTerminalSession = nil
                if claudeAlive { terminalGrabFocus = true }
            } label: {
                HStack(spacing: 4) {
                    SessionIcon()
                        .frame(width: CGFloat(12).scaled, height: CGFloat(12).scaled)
                    Text("Claude")
                        .font(.app(.caption))
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isDead ? 0.5 : 1.0)

            // X button only when Claude has a live tmux session
            if claudeAlive {
                Button {
                    if let session = claudeTmuxSession {
                        onKillTerminal(session)
                    }
                    // Stay on Claude tab (will now show Resume)
                } label: {
                    Image(systemName: "xmark")
                        .font(.app(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Stop Claude session")
            }
        }
        .background(
            isSelected ? Color.accentColor.opacity(0.15) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
    }

    /// Overlay shown on the Claude tab when there's no live Claude terminal.
    @ViewBuilder
    private func claudeTabOverlay(isLaunching: Bool) -> some View {
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
                SessionIcon()
                    .frame(width: CGFloat(32).scaled, height: CGFloat(32).scaled)
                    .opacity(0.3)
                Text("Claude session ended")
                    .font(.app(.body))
                    .foregroundStyle(.secondary)
                Button(action: onResume) {
                    Label("Resume Claude", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 12) {
                SessionIcon()
                    .frame(width: CGFloat(32).scaled, height: CGFloat(32).scaled)
                    .opacity(0.3)
                Text("No agent session")
                    .font(.app(.body))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Shell Tab

    @ViewBuilder
    private func shellTab(sessionName: String, isSelected: Bool) -> some View {
        let tmux = card.link.tmuxLink
        let primaryName = tmux?.sessionName ?? ""
        let isPrimary = sessionName == primaryName
        let customName = tmux?.tabNames?[sessionName]
        let displayName: String = customName ?? {
            if isPrimary { return "Shell" }
            let stripped = sessionName.replacingOccurrences(of: "\(primaryName)-", with: "")
            return stripped.isEmpty || stripped == sessionName ? "sh1" : stripped
        }()

        HStack(spacing: 0) {
            Button {
                selectedTerminalSession = sessionName
                terminalGrabFocus = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "terminal")
                        .font(.app(.caption2))
                    if renamingSession == sessionName {
                        TextField("Name", text: $tabRenameText, onCommit: {
                            onRenameTerminal(sessionName, tabRenameText)
                            renamingSession = nil
                        })
                        .font(.app(.caption))
                        .textFieldStyle(.plain)
                        .frame(width: 60)
                    } else {
                        Text(displayName)
                            .font(.app(.caption))
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                onKillTerminal(sessionName)
                if selectedTerminalSession == sessionName {
                    let remaining = shellSessions.filter { $0 != sessionName }
                    selectedTerminalSession = remaining.first
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.app(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Close terminal")
        }
        .background(
            isSelected ? Color.accentColor.opacity(0.15) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .contextMenu {
            Button("Rename") {
                tabRenameText = customName ?? ""
                renamingSession = sessionName
            }
        }
    }

    private static func initialTab(for card: KanbanCodeCard) -> DetailTab {
        if card.link.tmuxLink != nil { return .terminal }
        if card.link.sessionLink != nil { return .history }
        if card.link.issueLink != nil { return .issue }
        if !card.link.prLinks.isEmpty { return .pullRequest }
        if card.link.promptBody != nil { return .prompt }
        return .history
    }

    private func defaultTab(for card: KanbanCodeCard) -> DetailTab {
        Self.initialTab(for: card)
    }

    // MARK: - Issue Tab

    @ViewBuilder
    private var issueTabView: some View {
        if let issue = card.link.issueLink {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Header: title + number + open button
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(issue.title ?? card.displayTitle)
                                .font(.app(.headline))
                                .textSelection(.enabled)
                            Text(verbatim: "#\(issue.number)")
                                .font(.app(.subheadline))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let url = resolvedIssueURL(issue) {
                            Button {
                                NSWorkspace.shared.open(url)
                            } label: {
                                Label("Open in Browser", systemImage: "arrow.up.right.square")
                                    .font(.app(.caption))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    Divider()

                    // Markdown body
                    if let body = issue.body, !body.isEmpty {
                        Markdown(body)
                            .markdownTheme(.compact)
                            .textSelection(.enabled)
                    } else {
                        Text("No description provided.")
                            .foregroundStyle(.tertiary)
                            .italic()
                    }
                }
                .padding(16)
            }
        }
    }

    // MARK: - Pull Request Tab

    @ViewBuilder
    private var prTabView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(card.link.prLinks.enumerated()), id: \.element.number) { index, pr in
                    if index > 0 { Divider().padding(.vertical, 4) }

                    // Header: title + badge
                    VStack(alignment: .leading, spacing: 4) {
                        Text(pr.title ?? "Pull Request")
                            .font(.app(.headline))
                            .textSelection(.enabled)
                        HStack {
                            PRBadge(status: pr.status, prNumber: pr.number)
                            Spacer()
                            if let url = resolvedPRURL(pr) {
                                Button {
                                    NSWorkspace.shared.open(url)
                                } label: {
                                    Label("Open in Browser", systemImage: "arrow.up.right.square")
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }

                    // CI Check Runs
                    if let checks = pr.checkRuns, !checks.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Checks")
                                .font(.app(.subheadline, weight: .bold))
                                .foregroundStyle(.secondary)
                            ForEach(checks, id: \.name) { check in
                                HStack(spacing: 6) {
                                    checkRunIcon(check)
                                    Text(check.name)
                                        .font(.app(.caption))
                                        .lineLimit(1)
                                }
                            }
                        }
                    }

                    // Reviews summary
                    if pr.approvalCount != nil || pr.unresolvedThreads != nil {
                        HStack(spacing: 16) {
                            if let approvals = pr.approvalCount, approvals > 0 {
                                Label("\(approvals) approval\(approvals == 1 ? "" : "s")", systemImage: "checkmark.circle.fill")
                                    .font(.app(.caption))
                                    .foregroundStyle(.green)
                            }
                            if let unresolved = pr.unresolvedThreads, unresolved > 0 {
                                Label("\(unresolved) unresolved", systemImage: "bubble.left.fill")
                                    .font(.app(.caption))
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }

                Divider()

                // PR Body (lazy loaded — shows primary PR body)
                if isLoadingPRBody {
                    HStack {
                        Spacer()
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading PR description...")
                            .font(.app(.caption))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                } else if let body = prBody ?? card.link.prLink?.body, !body.isEmpty {
                    Markdown(htmlToMarkdownImages(body))
                        .markdownTheme(.compact)
                        .textSelection(.enabled)
                } else {
                    Text("No description provided.")
                        .foregroundStyle(.tertiary)
                        .italic()
                }
            }
            .padding(16)
        }
    }

    // MARK: - Prompt Tab

    @ViewBuilder
    private var promptTabView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Prompt")
                        .font(.app(.subheadline, weight: .bold))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        if let body = card.link.promptBody {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(body, forType: .string)
                            showCopyToast("Copied prompt")
                        }
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.app(.caption))
                    }
                    .buttonStyle(.borderless)
                    .help("Copy prompt")

                    Button { showEditPromptSheet = true } label: {
                        Image(systemName: "pencil")
                            .font(.app(.caption))
                    }
                    .buttonStyle(.borderless)
                    .help("Edit prompt")
                }

                if let body = card.link.promptBody {
                    Text(body)
                        .font(.app(.callout).monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Attached images
                if let imagePaths = card.link.promptImagePaths, !imagePaths.isEmpty {
                    Text("Images")
                        .font(.app(.subheadline, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)

                    ForEach(imagePaths, id: \.self) { path in
                        if let nsImage = NSImage(contentsOfFile: path) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: 400, maxHeight: 300)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    // MARK: - PR helpers

    private func checkRunIcon(_ check: CheckRun) -> some View {
        Group {
            switch check.status {
            case .completed:
                switch check.conclusion {
                case .success:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .failure:
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                case .neutral, .skipped:
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.secondary)
                case .cancelled, .timedOut, .actionRequired:
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                case nil:
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(.secondary)
                }
            case .inProgress:
                Image(systemName: "clock.fill")
                    .foregroundStyle(.yellow)
            case .queued:
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.app(.caption))
    }

    private func resolvedIssueURL(_ issue: IssueLink) -> URL? {
        let urlString = issue.url ?? githubBaseURL.map { GitRemoteResolver.issueURL(base: $0, number: issue.number) }
        return urlString.flatMap { URL(string: $0) }
    }

    private func resolvedPRURL(_ pr: PRLink) -> URL? {
        let urlString = pr.url ?? githubBaseURL.map { GitRemoteResolver.prURL(base: $0, number: pr.number) }
        return urlString.flatMap { URL(string: $0) }
    }

    /// Convert HTML img tags to Markdown image syntax so MarkdownUI can render them.
    private func htmlToMarkdownImages(_ text: String) -> String {
        // Match <img ... src="url" ... /> or <img ... src="url" ...>
        guard let regex = try? NSRegularExpression(
            pattern: #"<img\s+[^>]*?src\s*=\s*"([^"]+)"[^>]*?/?>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return text }

        var result = text
        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))

        // Replace in reverse order to preserve ranges
        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: result),
                  let srcRange = Range(match.range(at: 1), in: result) else { continue }
            let src = String(result[srcRange])

            // Try to extract alt text
            var alt = "image"
            if let altRegex = try? NSRegularExpression(pattern: #"alt\s*=\s*"([^"]*)""#, options: .caseInsensitive),
               let altMatch = altRegex.firstMatch(in: String(result[fullRange]), range: NSRange(0..<result[fullRange].count)),
               let altRange = Range(altMatch.range(at: 1), in: String(result[fullRange])) {
                let extracted = String(String(result[fullRange])[altRange])
                if !extracted.isEmpty { alt = extracted }
            }

            result.replaceSubrange(fullRange, with: "![\(alt)](\(src))")
        }

        return result
    }

    private func loadPRBody() async {
        guard let pr = card.link.prLink,
              let projectPath = card.link.projectPath else {
            KanbanCodeLog.warn("detail", "loadPRBody skipped: prLink=\(card.link.prLink != nil), projectPath=\(card.link.projectPath ?? "nil")")
            return
        }
        KanbanCodeLog.info("detail", "Loading PR #\(pr.number) body from \(projectPath)")
        isLoadingPRBody = true
        do {
            let body = try await GhCliAdapter().fetchPRBody(repoRoot: projectPath, prNumber: pr.number)
            prBody = body
            KanbanCodeLog.info("detail", "PR #\(pr.number) body loaded: \(body?.prefix(100) ?? "nil")")
        } catch {
            KanbanCodeLog.error("detail", "PR #\(pr.number) body failed: \(error)")
        }
        isLoadingPRBody = false
    }

    @ViewBuilder
    private func prSummaryPill(primary: PRLink) -> some View {
        let totalApprovals = card.link.prLinks.compactMap(\.approvalCount).reduce(0, +)
        let totalThreads = card.link.prLinks.compactMap(\.unresolvedThreads).reduce(0, +)
        let targetURL = totalThreads > 0
            ? (primary.firstUnresolvedThreadURL ?? primary.url)
            : primary.url

        if totalApprovals > 0 || totalThreads > 0 {
            Button {
                if let urlStr = targetURL, let url = URL(string: urlStr) {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                HStack(spacing: 6) {
                    if totalApprovals > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "checkmark")
                                .font(.app(size: 10, weight: .bold))
                            Text(verbatim: "\(totalApprovals)")
                                .font(.app(size: 12, weight: .medium))
                        }
                        .foregroundStyle(.green)
                    }
                    if totalThreads > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "bubble.left")
                                .font(.app(size: 10))
                            Text(verbatim: "\(totalThreads)")
                                .font(.app(size: 12, weight: .medium))
                        }
                        .foregroundStyle(.orange)
                    }
                }
                .frame(height: 36)
                .padding(.horizontal, 10)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            //.glassEffect(.regular, in: .capsule)
            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
            .modifier(HoverBrightness())
            .help(totalThreads > 0 ? "Open unresolved comment" : "Open pull request")
        }
    }

    private var isMergeable: Bool {
        guard let ms = card.link.mergeablePR?.mergeStateStatus?.uppercased() else { return false }
        return ms == "CLEAN" || ms == "UNSTABLE" || ms == "HAS_HOOKS"
    }

    /// Human-readable reason the PR cannot be merged, or nil if it can.
    private var mergeBlockedReason: String? {
        guard let pr = card.link.mergeablePR else { return nil }
        guard let ms = pr.mergeStateStatus?.uppercased() else { return nil } // still loading
        switch ms {
        case "CLEAN", "UNSTABLE", "HAS_HOOKS": return nil
        case "BLOCKED": return "Blocked by branch protection rules"
        case "BEHIND": return "Branch is behind the base branch and needs to be updated"
        case "DIRTY": return "Merge conflicts must be resolved first"
        case "DRAFT": return "Pull request is still a draft"
        case "UNKNOWN": return "GitHub is still calculating merge status"
        default: return "Merge state: \(ms.lowercased())"
        }
    }

    /// True when mergeStateStatus hasn't been fetched yet.
    private var isMergeStatusLoading: Bool {
        guard let pr = card.link.mergeablePR else { return false }
        return pr.mergeStateStatus == nil
    }


    @ViewBuilder
    private func mergeButton(pr: PRLink) -> some View {
        let canMerge = isMergeable
        let loading = isMergeStatusLoading
        let blocked = mergeBlockedReason
        if canMerge {
            // Mergeable — green button
            Button {
                guard !isMerging, let repoRoot = card.link.projectPath else { return }
                isMerging = true
                mergeError = nil
                Task {
                    let gh = GhCliAdapter()
                    let settings = try await SettingsStore().read()
                    let result = try await gh.mergePR(repoRoot: repoRoot, prNumber: pr.number, commandTemplate: settings.github.mergeCommand)
                    isMerging = false
                    switch result {
                    case .success(let warning):
                        showCopyToast("PR #\(pr.number) merged")
                        onPRMerged(pr.number)
                        if let warning, !warning.isEmpty {
                            KanbanCodeLog.info("merge", "PR #\(pr.number) merged with warning: \(warning)")
                        }
                    case .failure(let msg):
                        mergeError = msg
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    if isMerging {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.triangle.merge")
                    }
                    Text("Merge")
                }
                .font(.app(size: 13))
                .foregroundStyle(Color.green.opacity(0.8))
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(Color.green.opacity(0.08), in: Capsule())
                .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(HoverFeedbackStyle())
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            .disabled(isMerging)
            .help("Merge pull request")
            .popover(isPresented: .init(get: { mergeError != nil }, set: { if !$0 { mergeError = nil } })) {
                if let err = mergeError {
                    Text(err)
                        .font(.app(.caption))
                        .padding(8)
                        .frame(maxWidth: 300)
                }
            }
        } else if loading {
            // Still loading merge status — gray with spinner, click opens PR on GitHub
            Button {
                if let url = pr.url.flatMap({ URL(string: $0 + "#partial-timeline") }) {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small)
                    Text("Merge")
                }
                .font(.app(size: 13))
                .foregroundStyle(Color.secondary.opacity(0.6))
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(Color.secondary.opacity(0.06), in: Capsule())
                .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(HoverFeedbackStyle())
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            .help("Loading merge status… Click to open PR on GitHub")
        } else {
            // Blocked — gray button with reason popover + clickable to open PR
            VStack(spacing: 0) {
                Button {
                    if let url = pr.url.flatMap({ URL(string: $0 + "#partial-timeline") }) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "nosign")
                        Text("Merge")
                    }
                    .font(.app(size: 13))
                    .foregroundStyle(Color.secondary.opacity(0.6))
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(Color.secondary.opacity(0.06), in: Capsule())
                    .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(HoverFeedbackStyle())
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                .onHover { showMergeBlockedPopover = $0 }

                // Invisible anchor below the button — popover opens downward, away from button
                Color.clear
                    .frame(width: 0, height: 0)
                    .popover(isPresented: $showMergeBlockedPopover, arrowEdge: .bottom) {
                        if let reason = blocked {
                            Text(reason)
                                .font(.app(.caption))
                                .padding(8)
                                .frame(maxWidth: 300)
                                .fixedSize()
                        }
                    }
            }
        }
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

        menu.addActionItem("Rename", image: "pencil") { [self] in showRenameSheet = true }

        let forkItem = menu.addActionItem("Fork Session", image: "arrow.branch") { [self] in showForkConfirm = true }
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
            if let sessionImg = SessionIcon.menuImage {
                let sized = NSImage(size: NSSize(width: 16, height: 16))
                sized.lockFocus()
                sessionImg.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16))
                sized.unlockFocus()
                sized.isTemplate = true
                sessionItem.image = sized
            }
        }

        if let tmux = card.link.tmuxLink?.sessionName {
            menu.addActionItem("Copy Tmux Command", image: "terminal") { [self] in copyToClipboard("tmux attach -t \(tmux)") }
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

        let currentPath = card.link.projectPath
        let otherProjects = availableProjects.filter { $0.path != currentPath }
        if !otherProjects.isEmpty {
            menu.addItem(NSMenuItem.separator())
            let moveItem = NSMenuItem(title: "Move to Project", action: nil, keyEquivalent: "")
            moveItem.image = NSImage(systemSymbolName: "folder.badge.arrow.forward", accessibilityDescription: nil)
            let submenu = NSMenu()
            for project in otherProjects {
                let item = submenu.addActionItem(project.name) { [self] in onMoveToProject(project.path) }
                _ = item
            }
            moveItem.submenu = submenu
            menu.addItem(moveItem)
        }

        menu.addItem(NSMenuItem.separator())
        menu.addActionItem("Delete Card", image: "trash") { [self] in onDeleteCard(); onDismiss() }

        return menu
    }

    // MARK: - History loading

    private static let pageSize = 80

    private func loadHistory() async {
        guard let path = card.link.sessionLink?.sessionPath ?? card.session?.jsonlPath else { return }
        if turns.isEmpty { isLoadingHistory = true }
        // Preserve expanded window: if user loaded more than pageSize, keep that many
        let loadCount = max(Self.pageSize, turns.count)
        do {
            let result = try await TranscriptReader.readTail(from: path, maxTurns: loadCount)
            turns = result.turns
            hasMoreTurns = result.hasMore
        } catch {
            // Silently fail — empty history is fine
        }
        isLoadingHistory = false
    }

    private func loadMoreHistory() async {
        guard hasMoreTurns, !isLoadingMore else { return }
        guard let path = card.link.sessionLink?.sessionPath ?? card.session?.jsonlPath else { return }
        guard let firstTurn = turns.first else { return }

        isLoadingMore = true
        let rangeStart = max(0, firstTurn.index - Self.pageSize)
        let rangeEnd = firstTurn.index

        do {
            let earlier = try await TranscriptReader.readRange(from: path, turnRange: rangeStart..<rangeEnd)
            turns = earlier + turns
            hasMoreTurns = rangeStart > 0
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

        // Periodic poll as fallback (every 3s) in case DispatchSource misses events
        historyPollTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, selectedTab == .history else { break }
                await loadHistory()
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

    // MARK: - Fork (handled by onFork callback)

    // MARK: - Checkpoint

    private func performCheckpoint() {
        guard let path = card.link.sessionLink?.sessionPath,
              let turn = checkpointTurn else { return }
        Task {
            do {
                try await sessionStore.truncateSession(sessionPath: path, afterTurn: turn)
                checkpointMode = false
                checkpointTurn = nil
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

private struct SessionIdRow: View {
    let sessionId: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 4) {
                SessionIcon()
                    .frame(width: CGFloat(12).scaled, height: CGFloat(12).scaled)
                    .opacity(0.5)
                Text(sessionId)
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(sessionId, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.app(.caption2))
                    .foregroundStyle(.secondary)
                    .frame(width: CGFloat(12).scaled, height: CGFloat(12).scaled)
            }
            .buttonStyle(.borderless)
            .help("Copy to clipboard")
        }
    }
}

private struct CopyableRow: View {
    let icon: String
    let text: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 4) {
            Label(text, systemImage: icon)
                .font(.app(.caption))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.app(.caption2))
                    .foregroundStyle(.secondary)
                    .frame(width: CGFloat(12).scaled, height: CGFloat(12).scaled)
            }
            .buttonStyle(.borderless)
            .help("Copy to clipboard")
        }
    }
}

// MARK: - Compact Markdown Theme

@MainActor
extension Theme {
    /// Smaller text, tighter spacing, no opaque background on code blocks.
    static let compact = Theme()
        .text { FontSize(.em(0.87)) }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.82))
        }
        .heading1 { configuration in
            configuration.label
                .markdownTextStyle { FontSize(.em(1.25)); FontWeight(.semibold) }
                .markdownMargin(top: 12, bottom: 4)
        }
        .heading2 { configuration in
            configuration.label
                .markdownTextStyle { FontSize(.em(1.12)); FontWeight(.semibold) }
                .markdownMargin(top: 10, bottom: 4)
        }
        .heading3 { configuration in
            configuration.label
                .markdownTextStyle { FontSize(.em(1.0)); FontWeight(.semibold) }
                .markdownMargin(top: 8, bottom: 2)
        }
        .paragraph { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.15))
                .markdownMargin(top: 0, bottom: 8)
        }
        .codeBlock { configuration in
            configuration.label
                .markdownTextStyle {
                    FontFamilyVariant(.monospaced)
                    FontSize(.em(0.8))
                }
                .padding(8)
                .background(.quaternary.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .markdownMargin(top: 4, bottom: 8)
        }
        .listItem { configuration in
            configuration.label
                .markdownMargin(top: 2, bottom: 2)
        }
}

/// Native rename dialog sheet.
struct RenameSessionDialog: View {
    let currentName: String
    @Binding var isPresented: Bool
    var onRename: (String) -> Void = { _ in }

    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Session")
                .font(.app(.title3))
                .fontWeight(.semibold)

            TextField("Session name", text: $name)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Rename") {
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        onRename(trimmed)
                    }
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 350)
        .onAppear {
            name = currentName
        }
    }
}

// MARK: - NSMenuButton (SwiftUI button that shows an NSMenu anchored below it)

/// A SwiftUI view that renders custom SwiftUI content but on click shows an NSMenu
/// anchored directly below the view — no mouse-position hacks needed.
private struct NSMenuButton<Label: View>: NSViewRepresentable {
    let label: Label
    let menuItems: () -> NSMenu

    init(@ViewBuilder label: () -> Label, menuItems: @escaping () -> NSMenu) {
        self.label = label()
        self.menuItems = menuItems
    }

    func makeNSView(context: Context) -> NSMenuButtonNSView {
        let view = NSMenuButtonNSView()
        view.menuBuilder = menuItems
        // Embed the SwiftUI label as a hosting view
        let host = NSHostingView(rootView: label)
        host.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.topAnchor.constraint(equalTo: view.topAnchor),
            host.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        return view
    }

    func updateNSView(_ nsView: NSMenuButtonNSView, context: Context) {
        nsView.menuBuilder = menuItems
        // Update SwiftUI label
        if let host = nsView.subviews.first as? NSHostingView<Label> {
            host.rootView = label
        }
    }
}

private final class NSMenuButtonNSView: NSView {
    var menuBuilder: (() -> NSMenu)?

    override func mouseDown(with event: NSEvent) {
        guard let menu = menuBuilder?() else { return }
        // Anchor below this view — nil positioning avoids pre-selecting an item
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: self)
    }
}

// MARK: - NSMenu closure helper

private final class NSMenuActionItem: NSObject {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func invoke() { handler() }
}

extension NSMenu {
    @discardableResult
    func addActionItem(_ title: String, image: String? = nil, handler: @escaping () -> Void) -> NSMenuItem {
        let target = NSMenuActionItem(handler)
        let item = NSMenuItem(title: title, action: #selector(NSMenuActionItem.invoke), keyEquivalent: "")
        item.target = target
        item.representedObject = target // prevent dealloc
        if let image, let img = NSImage(systemSymbolName: image, accessibilityDescription: nil) {
            item.image = img
        }
        addItem(item)
        return item
    }
}

// MARK: - Edit Prompt Sheet

private struct EditPromptSheet: View {
    @Binding var isPresented: Bool
    @State private var text: String
    @State private var images: [ImageAttachment]
    let existingImagePaths: [String]
    let onSave: (String, [ImageAttachment]) -> Void

    init(isPresented: Binding<Bool>, body: String, existingImagePaths: [String], onSave: @escaping (String, [ImageAttachment]) -> Void) {
        self._isPresented = isPresented
        self._text = State(initialValue: body)
        self.existingImagePaths = existingImagePaths
        self.onSave = onSave
        let loaded = existingImagePaths.compactMap { ImageAttachment.fromPath($0) }
        self._images = State(initialValue: loaded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Prompt")
                .font(.app(.title3))
                .fontWeight(.semibold)

            PromptSection(
                text: $text,
                images: $images,
                placeholder: "Describe what you want Claude to do...",
                maxHeight: 300,
                onSubmit: save
            )

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    private func save() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Separate: images that already have a persistent path vs new ones
        var allImages: [ImageAttachment] = []
        for img in images {
            if let path = img.tempPath, existingImagePaths.contains(path) {
                // Already persisted — pass through as-is
                allImages.append(img)
            } else {
                allImages.append(img)
            }
        }
        onSave(text.trimmingCharacters(in: .whitespacesAndNewlines), allImages)
        isPresented = false
    }
}
