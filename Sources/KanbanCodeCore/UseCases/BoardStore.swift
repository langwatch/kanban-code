import Foundation
#if DEBUG
import QuartzCore
#endif

// MARK: - Dialog State

/// Which confirmation dialog is active. Lives in AppState so dialogs survive
/// view recreation (e.g., when a card moves between kanban columns).
public enum DialogState: Equatable, Sendable {
    case none
    case confirmDelete(cardId: String)
    case confirmArchive(cardId: String)
    case confirmFork(cardId: String)
    case confirmCheckpoint(cardId: String, turnIndex: Int, turnLineNumber: Int)
    case confirmWorktreeCleanup(cardId: String)
    case confirmMoveToProject(cardId: String, projectPath: String, projectName: String)
    case confirmMoveToFolder(cardId: String, folderPath: String, parentProjectPath: String, displayName: String)
    case confirmMigration(cardId: String, targetAssistant: CodingAssistant, recentTurnLimit: Int?)
    case confirmTrimSession(cardId: String)
    case remoteWorktreeCleanup(cardId: String, remotePath: String, localPath: String, errorMessage: String)
    case confirmDeleteChannel(name: String)
    /// Archive a card that has a boxd machine: the machine is destroyed too.
    case confirmArchiveWithMachine(cardId: String)
    /// Destroy the boxd machine of a card and keep the card.
    case confirmDestroyMachine(cardId: String)
}

// MARK: - AppState

/// A single chat-broadcast target: a tmux session and the assistant running
/// in it. Used by the reducer to describe fan-out targets for channel/DM
/// message effects; the effect handler uses `assistant` to decide whether
/// to paste images via `ImageSender` (Claude/Gemini) or fall back to a
/// text-only notification.
public struct ChannelMemberTarget: Sendable, Equatable {
    public let sessionName: String
    public let assistant: CodingAssistant
    public init(sessionName: String, assistant: CodingAssistant) {
        self.sessionName = sessionName
        self.assistant = assistant
    }
}

/// Which drawer (if any) is currently open. The enum makes it impossible to
/// have a card AND a channel (or DM) selected at the same time — a family of
/// bugs that existed with three independent `Optional` fields.
public enum Drawer: Equatable, Sendable {
    case none
    case card(String)
    case channel(String)
    case dm(ChannelParticipant)
}

/// Single source of truth for the entire board.
/// All mutations go through the Reducer — no direct writes.
/// What a banner is telling you. Everything used to go out as an error, so a
/// copied-to-clipboard confirmation arrived wearing a warning triangle.
public enum NoticeKind: String, Sendable, Equatable, Codable {
    case success
    case warning
    case error
}

public struct Notice: Sendable, Equatable {
    public let message: String
    public let kind: NoticeKind

    public init(_ message: String, kind: NoticeKind = .error) {
        self.message = message
        self.kind = kind
    }
}

/// @Observable gives SwiftUI fine-grained per-property tracking:
/// views reading `state.cards` only re-render when `cards` changes,
/// not when `state.notice` or other unrelated fields change.
@Observable
public final class AppState: @unchecked Sendable {
    public var links: [String: Link] = [:]                     // cardId → Link
    public var sessions: [String: Session] = [:]               // sessionId → Session
    public var activityMap: [String: ActivityState] = [:]       // sessionId → activity
    /// sessionId → model the session is running now, e.g. "opus". Polled from
    /// Claude's statusline rather than derived from the card, so an in-session
    /// `/model` switch shows up.
    public var sessionModels: [String: String] = [:]
    public var tmuxSessions: Set<String> = []                  // live tmux names
    /// Single source of truth for which drawer is open. Only ONE thing can be
    /// selected at a time; the type system enforces that invariant. The legacy
    /// `selectedCardId` / `selectedChannelName` / `selectedDMParticipant`
    /// fields are kept as computed accessors that read/write this enum.
    public var openDrawer: Drawer = .none
    public var selectedProjectPath: String?
    public var paletteOpen: Bool = false
    public var detailExpanded: Bool = false
    public var promptEditorFocused: Bool = false
    public var notice: Notice?
    public var isLoading: Bool = false
    public var lastRefresh: Date?

    /// Configured projects (refreshed from settings on each reconciliation).
    public var configuredProjects: [Project] = []
    /// Cached excluded paths for global view.
    public var excludedPaths: [String] = []
    /// Project paths discovered from sessions but not yet configured.
    public var discoveredProjectPaths: [String] = []

    /// Last time GitHub issues were fetched.
    public var lastGitHubRefresh: Date?
    /// Whether a GitHub issue refresh is currently running.
    public var isRefreshingBacklog = false

    /// Repo paths currently affected by GitHub API rate limiting.
    public var rateLimitedRepos: Set<String> = []

    /// Session IDs that were deliberately deleted by the user.
    /// Prevents the reconciler from recreating cards for these sessions.
    public var deletedSessionIds: Set<String> = []

    /// Card IDs that were deliberately deleted by the user.
    /// Prevents the reconciler from re-adding them during in-flight reconciliation.
    public var deletedCardIds: Set<String> = []

    /// Cards with an async operation in progress (terminal creating, worktree cleanup, PR discovery).
    /// Transient — not persisted. Used to show a spinner on the card.
    public var busyCards: Set<String> = []

    /// Global remote execution settings (from Settings.remote).
    public var globalRemoteSettings: RemoteSettings?

    /// Which remote backend a "Run remotely" launch uses.
    public var remoteMode: RemoteMode = .boxd

    /// Settings of the boxd remote mode (from Settings.boxd).
    public var boxdSettings: BoxdSettings?

    /// Live state of every boxd machine the app knows, by machine name.
    /// Transient: the supervisor reports it, nothing persists it.
    public var remoteMachineStates: [String: RemoteMachineState] = [:]

    /// Last progress line of a launch or resume in flight, by card id.
    /// Transient: shown under the "Starting session" spinner.
    public var launchProgress: [String: String] = [:]

    /// Cards that keep their tmux session on `machineName`.
    public func cardIds(onMachine machineName: String) -> [String] {
        links.values
            .filter { $0.remote?.machineName == machineName }
            .map(\.id)
            .sorted()
    }

    /// Active confirmation dialog — global so it survives view recreation.
    public var activeDialog: DialogState = .none

    // MARK: - Chat channels

    /// All known channels (loaded from ~/.kanban-code/channels/channels.json).
    public var channels: [Channel] = []

    /// Messages per channel, keyed by channel name. Populated lazily when a channel is selected.
    public var channelMessages: [String: [ChannelMessage]] = [:]

    /// Is the "create channel" dialog open?
    public var createChannelDialogOpen: Bool = false

    /// Per-channel "I have read up to this message id". Simpler than timestamps
    /// because message ids are unambiguous — no same-ts collisions, no
    /// `.distantPast` / `.now` guessing, no races with the reducer's clock.
    /// Persisted under `read-state.json`.
    public var channelLastReadMessageId: [String: String] = [:]

    /// Same idea for DM threads, keyed by `Reducer.dmKey(other)`.
    public var dmLastReadMessageId: [String: String] = [:]

    /// Per-channel last-opened timestamp — bumped when the drawer is selected.
    /// Used to order channels in Cmd+K by recency-of-attention (just like
    /// `Link.lastOpenedAt` does for cards).
    public var channelLastOpened: [String: Date] = [:]

    /// Per-channel draft text — preserved across drawer switches so the user
    /// doesn't lose in-progress typing. Keyed by channel name.
    public var channelDrafts: [String: String] = [:]

    /// Per-DM draft text — keyed by `Reducer.dmKey(other)`.
    public var dmDrafts: [String: String] = [:]

    /// DM messages keyed by the other party's handle (or "@handle" for userlike).
    public var dmMessages: [String: [ChannelMessage]] = [:]

    /// Latest DM message id seen per pair key — used to suppress duplicate system notifications.
    public var dmLastSeenMessageId: [String: String] = [:]

    // MARK: - Legacy selected* accessors (shim over `openDrawer`)
    // These preserve the original API so existing views/tests keep working while
    // the single-source-of-truth invariant is enforced by `openDrawer`.

    public var selectedCardId: String? {
        get {
            if case .card(let id) = openDrawer { return id }
            return nil
        }
        set {
            if let id = newValue { openDrawer = .card(id) }
            else if case .card = openDrawer { openDrawer = .none }
        }
    }

    public var selectedChannelName: String? {
        get {
            if case .channel(let name) = openDrawer { return name }
            return nil
        }
        set {
            if let name = newValue { openDrawer = .channel(name) }
            else if case .channel = openDrawer { openDrawer = .none }
        }
    }

    public var selectedDMParticipant: ChannelParticipant? {
        get {
            if case .dm(let p) = openDrawer { return p }
            return nil
        }
        set {
            if let p = newValue { openDrawer = .dm(p) }
            else if case .dm = openDrawer { openDrawer = .none }
        }
    }

    /// Latest channel message id seen per channel name — same idea for channel notifications.
    public var channelLastSeenMessageId: [String: String] = [:]

    /// True when the app is frontmost (visible & focused). When true, notifications
    /// for new messages are suppressed — the unread badges are enough.
    public var appIsFrontmost: Bool = true

    /// The human's handle, derived from `NSUserName()` (slugified, fallback "user").
    public var humanHandle: String = AppState.defaultHumanHandle()

    /// Participant representing the human (cardId=nil).
    public var humanParticipant: ChannelParticipant {
        ChannelParticipant(cardId: nil, handle: humanHandle)
    }

    static func defaultHumanHandle() -> String {
        // Swift on macOS: NSUserName() is available via Foundation.
        let raw = NSUserName()
        let lower = raw.lowercased()
        let slug = lower.replacingOccurrences(of: #"[^a-z0-9]+"#, with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return slug.isEmpty ? "user" : slug
    }

    // MARK: - Derived

    /// Cached cards array — rebuilt by BoardStore after each dispatch.
    public internal(set) var cards: [KanbanCodeCard] = []

    /// The currently selected card — independently tracked so CardDetailView
    /// only re-renders when the selected card's data actually changes.
    public internal(set) var selectedCard: KanbanCodeCard?

    /// Cards visible after project filtering — cached for independent observation.
    public internal(set) var filteredCards: [KanbanCodeCard] = []

    /// Pre-computed cards per column — each column is independently tracked by @Observable,
    /// so only columns with actual changes trigger SwiftUI re-renders.
    public internal(set) var cardsByColumn: [KanbanCodeColumn: [KanbanCodeCard]] = [:]

    /// Visible columns — cached for independent observation.
    public internal(set) var visibleColumns: [KanbanCodeColumn] = []

    /// Cards presented above the normal lanes while retaining their real column.
    public internal(set) var pinnedCards: [KanbanCodeCard] = []

    /// Rebuild all cached card arrays from current state.
    /// Only assigns when the result differs — prevents unnecessary SwiftUI re-renders.
    func rebuildCards() {
        let newCards = links.values.map { link in
            let session = link.sessionLink.flatMap { sessions[$0.sessionId] }
            var activity = link.sessionLink.flatMap { activityMap[$0.sessionId] }
            // The activity of a paused machine is frozen with it; the last
            // hook event may say the assistant was mid-tool.
            if link.remote?.pausedReason != nil, activity == .activelyWorking {
                activity = .idleWaiting
            }
            let rateLimited = link.projectPath.map { rateLimitedRepos.contains($0) } ?? false
            return KanbanCodeCard(
                link: link,
                session: session,
                activityState: activity,
                isBusy: busyCards.contains(link.id),
                isRateLimited: rateLimited,
                liveModel: link.sessionLink.flatMap { sessionModels[$0.sessionId] }
            )
        }
        if newCards != cards { cards = newCards }

        let newSelected = selectedCardId.flatMap { id in cards.first { $0.id == id } }
        if newSelected != selectedCard { selectedCard = newSelected }

        let newFiltered = cards.filter { cardMatchesProjectFilter($0) }
        if newFiltered != filteredCards { filteredCards = newFiltered }

        let newPinned = newFiltered.filter { $0.link.isPinned && $0.link.parentCardId == nil }.sorted {
            switch ($0.link.pinnedSortOrder, $1.link.pinnedSortOrder) {
            case (let a?, let b?) where a != b: return a < b
            case (_?, nil): return true
            case (nil, _?): return false
            default:
                let a = $0.link.pinnedAt ?? .distantPast
                let b = $1.link.pinnedAt ?? .distantPast
                if a != b { return a > b }
                return $0.id < $1.id
            }
        }
        if newPinned != pinnedCards { pinnedCards = newPinned }

        // Per-column sorted arrays
        var newByColumn: [KanbanCodeColumn: [KanbanCodeCard]] = [:]
        for column in KanbanCodeColumn.allCases {
            newByColumn[column] = newFiltered.filter { $0.column == column && $0.link.parentCardId == nil }
                .sorted {
                    switch ($0.link.sortOrder, $1.link.sortOrder) {
                    case (let a?, let b?): return a < b
                    case (_?, nil): return true
                    case (nil, _?): return false
                    case (nil, nil):
                        let t0 = $0.link.lastActivity ?? $0.link.updatedAt
                        let t1 = $1.link.lastActivity ?? $1.link.updatedAt
                        if t0 != t1 { return t0 > t1 }
                        return $0.id < $1.id
                    }
                }
        }
        if newByColumn != cardsByColumn { cardsByColumn = newByColumn }

        let alwaysVisible: [KanbanCodeColumn] = [.backlog, .inProgress, .waiting, .inReview, .done]
        var newVisible = alwaysVisible
        if (newByColumn[.allSessions]?.count ?? 0) > 0 { newVisible.append(.allSessions) }
        if newVisible != visibleColumns { visibleColumns = newVisible }
    }

    /// Cards for a specific column (pre-computed, cached).
    public func cards(in column: KanbanCodeColumn) -> [KanbanCodeCard] {
        cardsByColumn[column] ?? []
    }

    /// Lane presentation excludes pinned cards, but their underlying column is unchanged.
    public func unpinnedCards(in column: KanbanCodeColumn) -> [KanbanCodeCard] {
        cards(in: column).filter { !$0.link.isPinned }
    }

    public func cardCount(in column: KanbanCodeColumn) -> Int {
        cardsByColumn[column]?.count ?? 0
    }

    /// True while a session works on this Mac itself. A card whose session
    /// runs on a boxd machine does not count: its work continues on the
    /// machine while the Mac sleeps, so it must not keep the Mac awake.
    public var hasLocalActiveCards: Bool {
        cards.contains { card in
            card.column == .inProgress && card.link.parentCardId == nil
                && !(card.link.remote?.mode == .boxd && card.link.isRemote)
        }
    }

    private func cardMatchesProjectFilter(_ card: KanbanCodeCard) -> Bool {
        guard let selectedPath = selectedProjectPath else {
            return !isExcludedFromGlobalView(card)
        }
        let cardPath = card.link.projectPath ?? card.session?.projectPath
        guard let cardPath else { return false }
        let normalizedCard = ProjectDiscovery.normalizePath(cardPath)
        let normalizedSelected = ProjectDiscovery.normalizePath(selectedPath)

        // Direct match: card is at or under the selected project
        if normalizedCard == normalizedSelected || normalizedCard.hasPrefix(normalizedSelected + "/") {
            return true
        }

        // Worktree match: card's worktree is at the git root (e.g. repo/.claude/worktrees/name)
        // but the selected project is a subfolder of that repo (monorepo layout).
        // Strip /.claude/worktrees/<name> to get the repo root and check if the selected project is under it.
        if let range = normalizedCard.range(of: "/.claude/worktrees/") {
            let repoRoot = String(normalizedCard[..<range.lowerBound])
            if normalizedSelected == repoRoot || normalizedSelected.hasPrefix(repoRoot + "/") {
                return true
            }
        }

        return false
    }

    private func isExcludedFromGlobalView(_ card: KanbanCodeCard) -> Bool {
        guard !excludedPaths.isEmpty else { return false }
        let cardPath = card.link.projectPath ?? card.session?.projectPath
        guard let cardPath else { return false }
        let normalized = ProjectDiscovery.normalizePath(cardPath)
        let name = (normalized as NSString).lastPathComponent
        for excluded in excludedPaths {
            if excluded.contains("*") || excluded.contains("?") {
                // Glob pattern — match against full path and folder name
                if fnmatch(excluded, normalized, 0) == 0 { return true }
                if fnmatch(excluded, name, 0) == 0 { return true }
            } else {
                let normalizedExcluded = ProjectDiscovery.normalizePath(excluded)
                if normalized == normalizedExcluded || normalized.hasPrefix(normalizedExcluded + "/") {
                    return true
                }
            }
        }
        return false
    }

    public init() {}
}

// MARK: - Action

/// Exhaustive enum of everything that can happen to the board.
public enum Action: Sendable {
    // UI actions
    case createManualTask(Link)
    case createTerminal(cardId: String)
    case addExtraTerminal(cardId: String, sessionName: String)
    case launchCard(cardId: String, prompt: String, projectPath: String, worktreeName: String?, runRemotely: Bool, commandOverride: String?)
    case resumeCard(cardId: String)
    case moveCard(cardId: String, to: KanbanCodeColumn)
    case renameCard(cardId: String, name: String)
    case setCardPinned(cardId: String, isPinned: Bool)
    case setSelfCompactContextThreshold(cardId: String, thresholdTokens: Int?)
    case relinkSession(cardId: String, sessionLink: SessionLink)
    case sessionModelsScanned([String: String])
    case setCardModel(cardId: String, model: String?)
    case archiveCard(cardId: String)
    case deleteCard(cardId: String)
    case selectCard(cardId: String?)
    case setPaletteOpen(Bool)
    case setDetailExpanded(Bool)
    case setPromptEditorFocused(Bool)
    case unlinkFromCard(cardId: String, linkType: LinkType)
    case killTerminal(cardId: String, sessionName: String)
    case cancelLaunch(cardId: String)
    case addBranchToCard(cardId: String, branch: String)
    case addIssueLinkToCard(cardId: String, issueNumber: Int)
    case addPRToCard(cardId: String, prNumber: Int)
    case moveCardToProject(cardId: String, projectPath: String)
    case moveCardToFolder(cardId: String, folderPath: String, parentProjectPath: String)
    case beginMigration(cardId: String)
    case migrateSession(cardId: String, newAssistant: CodingAssistant, newSessionId: String, newSessionPath: String)
    case migrationFailed(cardId: String, error: String)
    case markPRMerged(cardId: String, prNumber: Int)
    case mergeCards(sourceId: String, targetId: String)
    case updatePrompt(cardId: String, body: String, imagePaths: [String]?)
    case reorderCard(cardId: String, targetCardId: String, above: Bool)
    case reorderPinnedCard(cardId: String, targetCardId: String?, above: Bool)

    // Queued prompts
    case addQueuedPrompt(cardId: String, prompt: QueuedPrompt, placement: QueuedPromptPlacement)
    case updateQueuedPrompt(cardId: String, promptId: String, body: String, sendAutomatically: Bool)
    case removeQueuedPrompt(cardId: String, promptId: String)
    case sendQueuedPrompt(cardId: String, promptId: String)
    case reorderQueuedPrompts(cardId: String, promptIds: [String])

    // Browser tabs
    case addBrowserTab(cardId: String, tabId: String, url: String)
    case removeBrowserTab(cardId: String, tabId: String)
    case updateBrowserTab(cardId: String, tabId: String, url: String?, title: String?)

    // Async completions
    case launchCompleted(cardId: String, tmuxName: String, sessionLink: SessionLink?, worktreeLink: WorktreeLink?, isRemote: Bool)
    case launchTmuxReady(cardId: String)
    case launchFailed(cardId: String, error: String)
    case resumeCompleted(cardId: String, tmuxName: String, isRemote: Bool)
    case resumeFailed(cardId: String, error: String)
    case terminalCreated(cardId: String, tmuxName: String)
    case terminalFailed(cardId: String, error: String)
    case extraTerminalCreated(cardId: String, sessionName: String)
    case extraTerminalFailed(cardId: String, sessionName: String, error: String)
    case renameTerminalTab(cardId: String, sessionName: String, label: String)
    case reorderTerminalTab(cardId: String, sessionName: String, beforeSession: String?)

    // Background reconciliation
    case reconciled(ReconciliationResult)
    /// Fast tmux liveness pass: clears links whose tmux sessions no longer
    /// exist (e.g. after a reboot) without waiting for a full reconcile.
    case tmuxLivenessScanned(live: Set<String>)
    case gitHubIssuesUpdated(links: [Link])
    case activityChanged([String: ActivityState]) // sessionId → state

    // Busy state (transient spinners)
    case setBusy(cardId: String, busy: Bool)

    /// A step of a launch or resume in flight. Keeps the launch alive for
    /// the stale-launch timers and shows the step under the spinner.
    case launchProgress(cardId: String, message: String)

    // Remote machines (boxd)
    /// A card got a machine, or its machine record changed (new cwd, new status).
    case remoteMachineAssigned(cardId: String, remote: RemoteLink)
    /// The supervisor reports the state of a machine.
    case remoteMachineStateChanged(machineName: String, state: RemoteMachineState)
    /// The user or a policy asks to stop the machine of a card.
    case stopRemoteMachine(cardId: String, reason: RemotePausedReason)
    /// The user confirmed the destruction of the machine of a card.
    case destroyRemoteMachine(cardId: String)
    /// The machine no longer exists; every card that used it forgets it.
    case remoteMachineDestroyed(machineName: String)

    // Settings / misc
    case settingsLoaded(projects: [Project], excludedPaths: [String], remote: RemoteSettings?, remoteMode: RemoteMode = .boxd, boxd: BoxdSettings? = nil)
    case setError(String?)
    /// Same banner as `setError`, but says what kind of news it is.
    case setNotice(String?, kind: NoticeKind)
    case setRateLimitedRepos(Set<String>)
    case setSelectedProject(String?)
    case setLoading(Bool)
    case setIsRefreshingBacklog(Bool)

    // Dialog
    case showDialog(DialogState)
    case dismissDialog

    // Drawer (single source of truth — closes whichever is open)
    case closeDrawer

    // Chat channels
    case refreshChannels
    case refreshChannelMessages(channelName: String)
    case channelsLoaded(channels: [Channel])
    case channelMessagesLoaded(channelName: String, messages: [ChannelMessage])
    case selectChannel(name: String?)
    case createChannel(name: String)
    case reorderChannel(channelId: String, targetChannelId: String?, above: Bool)
    case sendChannelMessage(channelName: String, body: String, imagePaths: [String] = [])
    case channelMessageAppended(channelName: String, message: ChannelMessage)
    case markChannelRead(name: String)
    case channelReadStateLoaded(channels: [String: String], dms: [String: String])
    case refreshChannelReadState
    case setAppFrontmost(Bool)
    case deleteChannel(name: String)
    case renameChannel(old: String, new: String)
    /// Kick a member out of a channel (e.g. a dead agent whose card no longer
    /// exists). Persists to channels.json and appends a leave event.
    case kickChannelMember(channelName: String, member: ChannelParticipant)
    case draftsLoaded(channels: [String: String], dms: [String: String])
    case setChannelDraft(channelName: String, body: String)
    case setDMDraft(other: ChannelParticipant, body: String)
    case loadDrafts

    // DMs
    case selectDM(other: ChannelParticipant?)
    case refreshDMMessages(other: ChannelParticipant)
    case dmMessagesLoaded(other: ChannelParticipant, messages: [ChannelMessage])
    case sendDirectMessage(to: ChannelParticipant, body: String, imagePaths: [String] = [])
    case dmMessageAppended(other: ChannelParticipant, message: ChannelMessage)

    public enum LinkType: Sendable {
        case pr(number: Int), issue, worktree, tmux
    }
}

public enum QueuedPromptPlacement: Sendable, Equatable {
    case front
    case back
}

/// Bundles the result of a full background reconciliation cycle.
public struct ReconciliationResult: Sendable {
    public let links: [Link]
    public let sessions: [Session]
    public let activityMap: [String: ActivityState]
    public let tmuxSessions: Set<String>
    public let configuredProjects: [Project]
    public let excludedPaths: [String]
    public let discoveredProjectPaths: [String]
    public let globalRemoteSettings: RemoteSettings?

    public init(
        links: [Link],
        sessions: [Session],
        activityMap: [String: ActivityState],
        tmuxSessions: Set<String>,
        configuredProjects: [Project] = [],
        excludedPaths: [String] = [],
        discoveredProjectPaths: [String] = [],
        globalRemoteSettings: RemoteSettings? = nil
    ) {
        self.links = links
        self.sessions = sessions
        self.activityMap = activityMap
        self.tmuxSessions = tmuxSessions
        self.configuredProjects = configuredProjects
        self.excludedPaths = excludedPaths
        self.discoveredProjectPaths = discoveredProjectPaths
        self.globalRemoteSettings = globalRemoteSettings
    }
}

// MARK: - Effect

/// Side effects returned by the reducer. Executed asynchronously by EffectHandler.
public enum Effect: Sendable {
    case persistLinks([Link])
    case upsertLink(Link)
    case removeLink(String) // id
    case createTmuxSession(cardId: String, name: String, path: String, isExtra: Bool = false)
    /// A shell session on the machine of the card, in its remote checkout.
    case createRemoteTmuxSession(cardId: String, machineName: String, name: String, path: String, isExtra: Bool = false)
    case killTmuxSession(String) // name
    case killTmuxSessions([String])
    case deleteSessionFile(String) // path
    case cleanupTerminalCache(sessionNames: [String])
    case cleanupBrowserCache(cardId: String)
    case refreshDiscovery
    case updateSessionIndex(sessionId: String, name: String)
    case moveSessionFile(cardId: String, sessionId: String, oldPath: String, newProjectPath: String)
    case sendPromptToTmux(sessionName: String, promptBody: String, assistant: CodingAssistant)
    case sendPromptWithImagesToTmux(sessionName: String, promptBody: String, imagePaths: [String], assistant: CodingAssistant)
    case journalQueuedPrompt(cardId: String, prompt: QueuedPrompt, reason: QueuedPromptJournalReason)
    case deleteFiles([String])

    // Remote machines (boxd)
    /// Stops the machine of a card whose work is over: the tab was closed,
    /// or the card was archived. Cheaper than standby, immune to stray
    /// wake-on-traffic, and the card resumes with a cold start. The reason
    /// tells the card's banner why.
    case stopRemoteMachine(machineName: String, reason: RemotePausedReason)
    case destroyRemoteMachine(machineName: String)

    // Channels
    case loadChannels
    case loadChannelMessages(channelName: String)
    case createChannelOnDisk(name: String, by: ChannelParticipant)
    case persistChannels([Channel])
    case sendChannelMessageToDisk(channelName: String, from: ChannelParticipant, body: String, imagePaths: [String], memberTargets: [ChannelMemberTarget])
    case loadChannelReadState
    case persistChannelReadState(channels: [String: String], dms: [String: String])
    case loadDrafts
    case persistDrafts(channels: [String: String], dms: [String: String])
    case loadDMMessages(self_: ChannelParticipant, other: ChannelParticipant)
    case sendDMToDisk(from: ChannelParticipant, to: ChannelParticipant, body: String, imagePaths: [String], toTarget: ChannelMemberTarget?)
    case notifyDMReceived(fromHandle: String, body: String)
    case notifyChannelMessage(channel: String, fromHandle: String, body: String)
    case deleteChannelOnDisk(name: String)
    case renameChannelOnDisk(old: String, new: String)
    case leaveChannelOnDisk(name: String, member: ChannelParticipant)
}

// MARK: - Reducer

/// Pure function: (state, action) → (state', effects).
/// No async. No side effects. Fully testable.
public enum Reducer {
    /// DM state is keyed by a stable identifier for the OTHER party.
    /// Uses cardId when present, else `@handle`.
    public static func dmKey(_ p: ChannelParticipant) -> String {
        p.cardId ?? "@\(p.handle)"
    }

    /// Snapshot of current read-state as a disk-persistable effect.
    static func persistReadState(_ state: AppState) -> Effect {
        .persistChannelReadState(channels: state.channelLastReadMessageId, dms: state.dmLastReadMessageId)
    }

    /// Id of the latest *real* chat message in a channel.
    /// Pinning the read-marker to the last entry of any type was a subtle bug:
    /// when the last line in the jsonl is a join / leave / system event,
    /// `unreadCount` filters it out before searching, can't locate the marker,
    /// and falls back to "count every real message as unread" — so opening the
    /// channel appeared to clear the badge but it came back on the next render.
    /// Always pin to the last `.message`, skipping metadata events.
    static func latestReadableMessageId(in messages: [ChannelMessage]) -> String? {
        messages.last(where: { $0.type == .message })?.id
    }

    private static func tmuxLinkScore(_ link: Link, sessionName: String, liveTmuxNames: Set<String>) -> Int {
        var score = 0
        if sessionName.contains(link.id) { score += 1000 }
        if link.isLaunching == true { score += 200 }
        if link.manuallyArchived == false { score += 100 }
        if link.column != .allSessions { score += 50 }
        if liveTmuxNames.contains(sessionName) { score += 25 }
        if link.worktreeLink != nil { score += 20 }
        if link.sessionLink != nil { score += 10 }
        return score
    }

    private static func deduplicatePrimaryTmuxLinks(_ links: inout [String: Link], liveTmuxNames: Set<String>) {
        var idsBySession: [String: [String]] = [:]
        for (id, link) in links {
            guard let sessionName = link.tmuxLink?.sessionName else { continue }
            idsBySession[sessionName, default: []].append(id)
        }

        for (sessionName, ids) in idsBySession where ids.count > 1 {
            guard let keeperId = ids.max(by: { lhs, rhs in
                guard let left = links[lhs], let right = links[rhs] else { return false }
                let leftScore = tmuxLinkScore(left, sessionName: sessionName, liveTmuxNames: liveTmuxNames)
                let rightScore = tmuxLinkScore(right, sessionName: sessionName, liveTmuxNames: liveTmuxNames)
                if leftScore != rightScore { return leftScore < rightScore }
                return left.updatedAt < right.updatedAt
            }) else { continue }

            for id in ids where id != keeperId {
                guard var link = links[id], link.isLaunching != true else { continue }
                link.tmuxLink = nil
                link.updatedAt = .now
                links[id] = link
                KanbanCodeLog.warn(
                    "store",
                    "Cleared duplicate tmux link \(sessionName) from \(id.prefix(12)); kept \(keeperId.prefix(12))"
                )
            }
        }
    }

    /// True when a card still keeps a tmux session on `machineName`.
    static func machineHasLiveSessions(_ machineName: String, in state: AppState) -> Bool {
        state.links.values.contains { $0.remote?.machineName == machineName && $0.tmuxLink != nil }
    }

    /// Drops the machine record of `link`. When no other card uses the
    /// machine it is destroyed (`destroy`) or paused; a shared machine, for
    /// example one a subagent still runs on, is left alone.
    static func releaseRemoteMachine(of link: inout Link, in state: AppState, destroy: Bool) -> [Effect] {
        guard let remote = link.remote else { return [] }
        link.remote = nil
        link.isRemote = false
        let others = state.cardIds(onMachine: remote.machineName).filter { $0 != link.id }
        guard others.isEmpty else { return [] }
        return destroy
            ? [.destroyRemoteMachine(machineName: remote.machineName)]
            : [.stopRemoteMachine(machineName: remote.machineName, reason: .sessionStopped)]
    }

    public static func reduce(state: inout AppState, action: Action) -> [Effect] {
        reduce(state: state, action: action)
    }

    public static func reduce(state: AppState, action: Action) -> [Effect] {
        switch action {

        // MARK: UI Actions

        case .createManualTask(let link):
            state.links[link.id] = link
            return [.upsertLink(link)]

        case .createTerminal(let cardId):
            guard var link = state.links[cardId] else { return [] }
            let projectName = link.projectPath.map { ($0 as NSString).lastPathComponent } ?? "shell"
            let tmuxName = "\(projectName)-\(link.id)"
            link.tmuxLink = TmuxLink(sessionName: tmuxName, isShellOnly: true)
            // Do NOT change column. Terminal ≠ in progress.
            link.updatedAt = .now
            state.links[cardId] = link
            state.busyCards.insert(cardId)
            if let remote = link.remote, remote.mode == .boxd, remote.pausedReason == nil, let cwd = remote.remoteCwd {
                return [.createRemoteTmuxSession(cardId: cardId, machineName: remote.machineName, name: tmuxName, path: cwd), .upsertLink(link)]
            }
            let workDir = link.worktreeLink?.path.isEmpty == false
                ? link.worktreeLink!.path
                : (link.projectPath ?? NSHomeDirectory())
            return [.createTmuxSession(cardId: cardId, name: tmuxName, path: workDir), .upsertLink(link)]

        case .addExtraTerminal(let cardId, let sessionName):
            guard var link = state.links[cardId] else { return [] }
            let workDir = link.worktreeLink?.path.isEmpty == false
                ? link.worktreeLink!.path
                : (link.projectPath ?? NSHomeDirectory())
            // Add to extra sessions list
            var extras = link.tmuxLink?.extraSessions ?? []
            extras.append(sessionName)
            link.tmuxLink?.extraSessions = extras
            link.updatedAt = .now
            state.links[cardId] = link
            state.busyCards.insert(cardId)
            // A card that runs on a machine opens its shells there, in the
            // remote checkout, whatever the app holds as the machine state:
            // a machine that runs again is reconnected by the effect, and a
            // machine that is really paused says so, instead of opening a
            // shell on the Mac that has nothing to do with the work.
            if let remote = link.remote, remote.mode == .boxd, link.isRemote {
                let cwd = remote.remoteCwd ?? remote.remoteProjectPath ?? remote.remoteHome ?? "."
                return [
                    .createRemoteTmuxSession(
                        cardId: cardId, machineName: remote.machineName,
                        name: sessionName, path: cwd, isExtra: true),
                    .upsertLink(link),
                ]
            }
            return [.createTmuxSession(cardId: cardId, name: sessionName, path: workDir, isExtra: true), .upsertLink(link)]

        case .launchCard(let cardId, _, let projectPath, let worktreeName, _, _):
            guard var link = state.links[cardId] else { return [] }
            let projectName = (projectPath as NSString).lastPathComponent
            let effectiveName = (worktreeName?.isEmpty == false) ? worktreeName! : nil
            let tmuxName = effectiveName != nil
                ? "\(projectName)-\(effectiveName!)"
                : "\(projectName)-\(cardId)"
            // Preserve existing shell sessions as extras
            var extras = link.tmuxLink?.extraSessions ?? []
            if link.tmuxLink?.isShellOnly == true, let oldPrimary = link.tmuxLink?.sessionName {
                extras.insert(oldPrimary, at: 0)
            }
            link.tmuxLink = TmuxLink(sessionName: tmuxName, extraSessions: extras.isEmpty ? nil : extras)
            link.column = .inProgress
            link.manualOverrides.column = false // Let automatic assignment take over
            link.isLaunching = true
            link.launchedAt = .now
            link.updatedAt = .now
            state.links[cardId] = link
            state.selectedCardId = cardId
            KanbanCodeLog.info("store", "Launch: card=\(cardId.prefix(12)) tmux=\(tmuxName)")
            return [.upsertLink(link)]

        case .resumeCard(let cardId):
            guard var link = state.links[cardId] else { return [] }
            let sid = link.sessionLink?.sessionId ?? link.id
            let tmuxName = "\(link.effectiveAssistant.cliCommand)-\(String(sid.prefix(8)))"
            // Preserve existing shell sessions as extras
            var extras = link.tmuxLink?.extraSessions ?? []
            if link.tmuxLink?.isShellOnly == true, let oldPrimary = link.tmuxLink?.sessionName {
                extras.insert(oldPrimary, at: 0)
            }
            link.tmuxLink = TmuxLink(sessionName: tmuxName, extraSessions: extras.isEmpty ? nil : extras)
            link.column = .inProgress
            link.manualOverrides.column = false // Let automatic assignment take over
            link.isLaunching = true
            link.launchedAt = .now
            link.updatedAt = .now
            state.links[cardId] = link
            state.selectedCardId = cardId
            KanbanCodeLog.info("store", "Resume: card=\(cardId.prefix(12)) tmux=\(tmuxName)")
            return [.upsertLink(link)]

        case .moveCard(let cardId, let column):
            guard var link = state.links[cardId] else { return [] }
            // Clear sortOrder when moving to a different column
            link.sortOrder = nil
            link.column = column
            link.manualOverrides.column = true
            if column == .allSessions {
                link.manuallyArchived = true
                link.pinnedAt = nil
                link.pinnedSortOrder = nil
            } else {
                link.manuallyArchived = false
                // The user put a headless session's card on the board: it stays.
                if link.headless == true { link.headless = false }
            }
            link.updatedAt = .now
            state.links[cardId] = link
            return [.upsertLink(link)]

        case .reorderCard(let cardId, let targetCardId, let above):
            guard let link = state.links[cardId] else { return [] }
            let column = link.column
            // Get current sorted order for the column
            var columnCards = state.cards(in: column)
            // Remove the dragged card
            columnCards.removeAll { $0.id == cardId }
            // Find insertion index
            let insertIndex: Int
            if let targetIdx = columnCards.firstIndex(where: { $0.id == targetCardId }) {
                insertIndex = above ? targetIdx : targetIdx + 1
            } else {
                insertIndex = columnCards.count
            }
            // Re-insert the dragged card as a placeholder (we only need the id)
            let draggedCard = state.cards.first { $0.id == cardId }!
            columnCards.insert(draggedCard, at: insertIndex)
            // Assign sortOrder 0, 1, 2, ... to all cards in the column
            var effects: [Effect] = []
            for (i, card) in columnCards.enumerated() {
                if state.links[card.id] != nil {
                    state.links[card.id]!.sortOrder = i
                    effects.append(.upsertLink(state.links[card.id]!))
                }
            }
            return effects

        case .renameCard(let cardId, let name):
            guard var link = state.links[cardId] else { return [] }
            link.name = name
            link.manualOverrides.name = true
            link.updatedAt = .now
            state.links[cardId] = link
            var effects: [Effect] = [.upsertLink(link)]
            if let sessionId = link.sessionLink?.sessionId {
                effects.append(.updateSessionIndex(sessionId: sessionId, name: name))
            }
            return effects

        case .setCardPinned(let cardId, let isPinned):
            guard var link = state.links[cardId] else { return [] }
            guard link.parentCardId == nil else { return [] }
            if isPinned {
                if link.pinnedAt != nil { return [] }
                link.pinnedAt = .now
                if link.headless == true { link.headless = false }
                let firstOrder = state.pinnedCards.compactMap(\.link.pinnedSortOrder).min() ?? 0
                link.pinnedSortOrder = firstOrder - 1
                // Pinning an archived card brings it back: leaving it archived
                // pins something that stays hidden in All Sessions.
                if link.manuallyArchived {
                    link.manuallyArchived = false
                    if link.column == .allSessions {
                        link.column = .backlog
                        // Let reconciliation promote it by real activity.
                        link.manualOverrides.column = false
                    }
                }
            } else {
                if link.pinnedAt == nil { return [] }
                link.pinnedAt = nil
                link.pinnedSortOrder = nil
            }
            link.updatedAt = .now
            state.links[cardId] = link
            return [.upsertLink(link)]

        case .setSelfCompactContextThreshold(let cardId, let thresholdTokens):
            guard var link = state.links[cardId] else { return [] }
            if let thresholdTokens {
                guard thresholdTokens > 0,
                      thresholdTokens <= Int.max - SelfCompactPolicy.forcedCompactOffsetTokens
                else { return [] }
            }
            guard link.selfCompactContextThresholdTokens != thresholdTokens else { return [] }
            link.selfCompactContextThresholdTokens = thresholdTokens
            link.queuedPrompts?.removeAll { $0.selfCompactThresholdTokens != nil }
            link.updatedAt = .now
            state.links[cardId] = link
            return [.upsertLink(link)]

        case .reorderPinnedCard(let cardId, let targetCardId, let above):
            guard state.links[cardId]?.isPinned == true,
                  let draggedCard = state.pinnedCards.first(where: { $0.id == cardId })
            else { return [] }
            var cards = state.pinnedCards.filter { $0.id != cardId }
            let insertIndex: Int
            if let targetCardId,
               let targetIndex = cards.firstIndex(where: { $0.id == targetCardId }) {
                insertIndex = above ? targetIndex : targetIndex + 1
            } else {
                insertIndex = cards.count
            }
            cards.insert(draggedCard, at: insertIndex)
            return cards.enumerated().compactMap { index, card in
                guard var link = state.links[card.id] else { return nil }
                link.pinnedSortOrder = index
                state.links[card.id] = link
                return .upsertLink(link)
            }

        case .updatePrompt(let cardId, let body, let imagePaths):
            guard var link = state.links[cardId] else { return [] }
            let oldImages = link.promptImagePaths ?? []
            let newImages = Set(imagePaths ?? [])
            let removedImages = oldImages.filter { !newImages.contains($0) }
            link.promptBody = body
            link.promptImagePaths = imagePaths
            link.updatedAt = .now
            state.links[cardId] = link
            var effects: [Effect] = [.upsertLink(link)]
            if !removedImages.isEmpty {
                effects.append(.deleteFiles(removedImages))
            }
            return effects

        case .relinkSession(let cardId, let sessionLink):
            guard var link = state.links[cardId] else { return [] }
            guard link.sessionLink?.sessionId != sessionLink.sessionId else { return [] }
            KanbanCodeLog.info(
                "store",
                "Relink: card=\(cardId.prefix(12)) session=\(sessionLink.sessionId.prefix(8))"
            )
            link.sessionLink = sessionLink
            link.updatedAt = .now
            state.links[cardId] = link
            return [.upsertLink(link)]

        case .sessionModelsScanned(let models):
            // Polled every few seconds, so rebuild only on a real change rather
            // than walking every card each time the scan comes back identical.
            guard state.sessionModels != models else { return [] }
            state.sessionModels = models
            state.rebuildCards()
            return []

        case .setCardModel(let cardId, let model):
            guard var link = state.links[cardId] else { return [] }
            let normalized = model?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolved = (normalized?.isEmpty ?? true) ? nil : normalized
            guard link.modelOverride != resolved else { return [] }
            link.modelOverride = resolved
            link.updatedAt = .now
            state.links[cardId] = link
            return [.upsertLink(link)]

        case .archiveCard(let cardId):
            guard var link = state.links[cardId] else { return [] }
            link.manuallyArchived = true
            link.column = .allSessions
            link.pinnedAt = nil
            link.pinnedSortOrder = nil
            link.updatedAt = .now
            // Kill tmux sessions on archive — user expects cleanup
            var effects: [Effect] = []
            if let tmux = link.tmuxLink {
                effects.append(.killTmuxSessions(tmux.allSessionNames))
                effects.append(.cleanupTerminalCache(sessionNames: tmux.allSessionNames))
                link.tmuxLink = nil
            }
            if link.browserTabs != nil {
                effects.append(.cleanupBrowserCache(cardId: cardId))
                link.browserTabs = nil
            }
            // An archived card no longer needs its boxd machine. The machine
            // is only destroyed when no other card (a subagent, for example)
            // still runs on it.
            if let remote = link.remote, remote.mode == .boxd {
                effects.append(contentsOf: releaseRemoteMachine(of: &link, in: state, destroy: true))
            }
            state.links[cardId] = link
            effects.insert(.upsertLink(link), at: 0)
            return effects

        case .deleteCard(let cardId):
            guard state.links[cardId] != nil else { return [] }
            let descendants = SubagentHierarchy.descendantIds(of: cardId, in: state.links)
            let idsToDelete = [cardId] + descendants.sorted()
            if let selected = state.selectedCardId, idsToDelete.contains(selected) {
                state.selectedCardId = nil
            }
            var effects: [Effect] = []
            for id in idsToDelete {
                guard let link = state.links.removeValue(forKey: id) else { continue }
                state.deletedCardIds.insert(id)
                if let sessionId = link.sessionLink?.sessionId {
                    state.deletedSessionIds.insert(sessionId)
                }
                effects.append(.removeLink(id))
                if let tmux = link.tmuxLink {
                    effects.append(.killTmuxSessions(tmux.allSessionNames))
                    effects.append(.cleanupTerminalCache(sessionNames: tmux.allSessionNames))
                }
                if link.browserTabs != nil {
                    effects.append(.cleanupBrowserCache(cardId: id))
                }
                if let sessionPath = link.sessionLink?.sessionPath {
                    effects.append(.deleteSessionFile(sessionPath))
                }
                if let remote = link.remote, remote.mode == .boxd,
                   state.cardIds(onMachine: remote.machineName).isEmpty {
                    effects.append(.destroyRemoteMachine(machineName: remote.machineName))
                }
                var imagesToDelete = link.promptImagePaths ?? []
                imagesToDelete += (link.queuedPrompts ?? []).flatMap { $0.imagePaths ?? [] }
                if !imagesToDelete.isEmpty {
                    effects.append(.deleteFiles(imagesToDelete))
                }
            }
            return effects

        case .closeDrawer:
            state.openDrawer = .none
            return []

        case .selectCard(let cardId):
            state.selectedCardId = cardId
            if let cardId, var link = state.links[cardId] {
                link.lastOpenedAt = Date()
                state.links[cardId] = link
                return [.upsertLink(link)]
            }
            return []

        case .setPaletteOpen(let open):
            state.paletteOpen = open
            return []

        case .setDetailExpanded(let expanded):
            state.detailExpanded = expanded
            return []

        case .setPromptEditorFocused(let focused):
            state.promptEditorFocused = focused
            return []

        case .showDialog(let dialog):
            state.activeDialog = dialog
            return []

        case .dismissDialog:
            state.activeDialog = .none
            return []

        // MARK: Channels

        case .refreshChannels:
            return [.loadChannels]

        case .refreshChannelMessages(let name):
            return [.loadChannelMessages(channelName: name)]

        case .channelsLoaded(let channels):
            let sortedChannels = channels.sorted {
                switch ($0.sortOrder, $1.sortOrder) {
                case (let a?, let b?) where a != b: return a < b
                case (_?, nil): return true
                case (nil, _?): return false
                default:
                    if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                    return $0.id < $1.id
                }
            }
            if state.channels != sortedChannels {
                state.channels = sortedChannels
            }
            // Initial channel discovery needs message tails for sidebar
            // timestamps. Later metadata refreshes must not reload every
            // channel tail: that fans out into many channelMessagesLoaded
            // mutations and can make SwiftUI relayout the whole channel UI.
            return sortedChannels.compactMap { channel in
                state.channelMessages[channel.name] == nil
                    ? .loadChannelMessages(channelName: channel.name)
                    : nil
            }

        case .reorderChannel(let channelId, let targetChannelId, let above):
            guard let draggedChannel = state.channels.first(where: { $0.id == channelId }) else {
                return []
            }
            var channels = state.channels.filter { $0.id != channelId }
            let insertIndex: Int
            if let targetChannelId,
               let targetIndex = channels.firstIndex(where: { $0.id == targetChannelId }) {
                insertIndex = above ? targetIndex : targetIndex + 1
            } else {
                insertIndex = channels.count
            }
            channels.insert(draggedChannel, at: insertIndex)
            for index in channels.indices {
                channels[index].sortOrder = index
            }
            state.channels = channels
            return [.persistChannels(channels)]

        case .channelMessagesLoaded(let name, let messages):
            let existingMessages = state.channelMessages[name]
            let isFirstLoad = existingMessages == nil
            if !isFirstLoad, messages.isEmpty, existingMessages?.isEmpty == false {
                KanbanCodeLog.warn("channels", "Ignoring empty reload for #\(name); preserving existing messages")
                return []
            }
            let messagesChanged = existingMessages != messages
            if messagesChanged {
                state.channelMessages[name] = messages
                Self.logChannelPayloadIfLarge(kind: "channel", name: name, messages: messages)
            }
            var effects: [Effect] = []

            // First time ever loading this channel (and there's no persisted
            // marker either): treat everything as read so the tile doesn't
            // blast a badge for pre-existing history.
            if isFirstLoad, state.channelLastReadMessageId[name] == nil,
               let latestId = Self.latestReadableMessageId(in: messages) {
                state.channelLastReadMessageId[name] = latestId
                effects.append(Self.persistReadState(state))
            }

            // Notify only if: not first load, message is from someone else,
            // drawer isn't focused on this channel, AND app isn't frontmost.
            if messagesChanged,
               !isFirstLoad,
               !state.appIsFrontmost,
               let latest = messages.last(where: { $0.type == .message }),
               latest.id != state.channelLastSeenMessageId[name],
               latest.from.handle != state.humanHandle,
               state.selectedChannelName != name {
                effects.append(.notifyChannelMessage(channel: name, fromHandle: latest.from.handle, body: latest.body))
            }
            if let latest = messages.last, state.channelLastSeenMessageId[name] != latest.id {
                state.channelLastSeenMessageId[name] = latest.id
            }

            // If this channel's drawer is open, auto-mark-read so inbound
            // messages don't resurrect the unread badge.
            if state.selectedChannelName == name,
               let latestId = Self.latestReadableMessageId(in: messages) {
                if state.channelLastReadMessageId[name] != latestId {
                    state.channelLastReadMessageId[name] = latestId
                    effects.append(Self.persistReadState(state))
                }
            }
            return effects

        case .selectChannel(let name):
            state.selectedChannelName = name
            // Mutual exclusion is enforced by the `openDrawer` enum.
            if let name = name {
                state.channelLastOpened[name] = .now
                var effects: [Effect] = [.loadChannelMessages(channelName: name)]
                // Mark-as-read: pin lastRead to the latest real message id. If
                // messages haven't loaded yet, the subsequent
                // `channelMessagesLoaded` path will pin it to the real latest.
                if let latestId = Self.latestReadableMessageId(in: state.channelMessages[name] ?? []) {
                    if state.channelLastReadMessageId[name] != latestId {
                        state.channelLastReadMessageId[name] = latestId
                        effects.append(Self.persistReadState(state))
                    }
                }
                return effects
            }
            return []

        case .markChannelRead(let name):
            guard let latestId = Self.latestReadableMessageId(in: state.channelMessages[name] ?? []) else { return [] }
            if state.channelLastReadMessageId[name] != latestId {
                state.channelLastReadMessageId[name] = latestId
                return [Self.persistReadState(state)]
            }
            return []

        case .channelReadStateLoaded(let channelIds, let dmIds):
            guard state.channelLastReadMessageId != channelIds || state.dmLastReadMessageId != dmIds else {
                return []
            }
            state.channelLastReadMessageId = channelIds
            state.dmLastReadMessageId = dmIds
            return []

        case .refreshChannelReadState:
            return [.loadChannelReadState]

        case .loadDrafts:
            return [.loadDrafts]

        case .draftsLoaded(let channels, let dms):
            guard state.channelDrafts != channels || state.dmDrafts != dms else {
                return []
            }
            state.channelDrafts = channels
            state.dmDrafts = dms
            return []

        case .setChannelDraft(let name, let body):
            let current = state.channelDrafts[name] ?? ""
            guard current != body else { return [] }
            if body.isEmpty {
                state.channelDrafts.removeValue(forKey: name)
            } else {
                state.channelDrafts[name] = body
            }
            return [.persistDrafts(channels: state.channelDrafts, dms: state.dmDrafts)]

        case .setDMDraft(let other, let body):
            let key = Self.dmKey(other)
            let current = state.dmDrafts[key] ?? ""
            guard current != body else { return [] }
            if body.isEmpty {
                state.dmDrafts.removeValue(forKey: key)
            } else {
                state.dmDrafts[key] = body
            }
            return [.persistDrafts(channels: state.channelDrafts, dms: state.dmDrafts)]

        case .setAppFrontmost(let active):
            state.appIsFrontmost = active
            return []

        // MARK: DMs

        case .selectDM(let other):
            state.selectedDMParticipant = other
            if let other = other {
                let me = state.humanParticipant
                var effects: [Effect] = [.loadDMMessages(self_: me, other: other)]
                let key = Self.dmKey(other)
                if let latestId = state.dmMessages[key]?.last?.id {
                    if state.dmLastReadMessageId[key] != latestId {
                        state.dmLastReadMessageId[key] = latestId
                        effects.append(Self.persistReadState(state))
                    }
                }
                return effects
            }
            return []

        case .refreshDMMessages(let other):
            return [.loadDMMessages(self_: state.humanParticipant, other: other)]

        case .dmMessagesLoaded(let other, let messages):
            let key = Self.dmKey(other)
            let existingMessages = state.dmMessages[key]
            let isFirstLoad = existingMessages == nil
            if !isFirstLoad, messages.isEmpty, existingMessages?.isEmpty == false {
                KanbanCodeLog.warn("channels", "Ignoring empty DM reload for @\(other.handle); preserving existing messages")
                return []
            }
            let messagesChanged = existingMessages != messages
            if messagesChanged {
                state.dmMessages[key] = messages
                Self.logChannelPayloadIfLarge(kind: "dm", name: key, messages: messages)
            }
            var effects: [Effect] = []

            // Seed lastRead to the latest id on first-ever load so we don't
            // blast unreads for pre-existing history.
            if isFirstLoad, state.dmLastReadMessageId[key] == nil,
               let latestId = messages.last?.id {
                state.dmLastReadMessageId[key] = latestId
                effects.append(Self.persistReadState(state))
            }

            if messagesChanged,
               !isFirstLoad,
               !state.appIsFrontmost,
               let latest = messages.last(where: { $0.type == .message }),
               latest.id != state.dmLastSeenMessageId[key],
               latest.from.handle != state.humanHandle,
               state.selectedDMParticipant != other {
                effects.append(.notifyDMReceived(fromHandle: latest.from.handle, body: latest.body))
            }
            if let latest = messages.last {
                state.dmLastSeenMessageId[key] = latest.id
            }

            // Auto-mark-read if the drawer is focused on this DM.
            if state.selectedDMParticipant == other, let latestId = messages.last?.id {
                if state.dmLastReadMessageId[key] != latestId {
                    state.dmLastReadMessageId[key] = latestId
                    effects.append(Self.persistReadState(state))
                }
            }
            return effects

        case .sendDirectMessage(let to, let body, let imagePaths):
            let from = state.humanParticipant
            let target: ChannelMemberTarget? = {
                guard let cid = to.cardId,
                      let link = state.links[cid],
                      let sess = link.tmuxLink?.sessionName
                else { return nil }
                return ChannelMemberTarget(sessionName: sess, assistant: link.effectiveAssistant)
            }()
            return [.sendDMToDisk(from: from, to: to, body: body, imagePaths: imagePaths, toTarget: target)]

        case .dmMessageAppended(let other, let message):
            let key = Self.dmKey(other)
            var msgs = state.dmMessages[key] ?? []
            if !msgs.contains(where: { $0.id == message.id }) {
                msgs.append(message)
                msgs.sort { $0.ts < $1.ts }
            }
            state.dmMessages[key] = msgs
            let mine = message.from.cardId == nil && message.from.handle == state.humanHandle
            let focused = state.selectedDMParticipant == other
            if mine || focused {
                state.dmLastReadMessageId[key] = message.id
                return [Self.persistReadState(state)]
            }
            return []

        case .deleteChannel(let name):
            let clean = name.replacingOccurrences(of: "#", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !clean.isEmpty else { return [] }
            state.channels.removeAll { $0.name == clean }
            state.channelMessages.removeValue(forKey: clean)
            state.channelLastSeenMessageId.removeValue(forKey: clean)
            state.channelLastReadMessageId.removeValue(forKey: clean)
            state.channelLastOpened.removeValue(forKey: clean)
            state.channelDrafts.removeValue(forKey: clean)
            if state.selectedChannelName == clean {
                state.selectedChannelName = nil
            }
            return [.deleteChannelOnDisk(name: clean), .loadChannels]

        case .renameChannel(let old, let new):
            let oldName = old.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let newName = new
                .replacingOccurrences(of: "#", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !oldName.isEmpty, !newName.isEmpty, oldName != newName else { return [] }
            guard state.channels.contains(where: { $0.name == oldName }) else { return [] }
            guard !state.channels.contains(where: { $0.name == newName }) else {
                state.notice = Notice("Channel #\(newName) already exists")
                return []
            }
            // Carry in-memory state over to the new key so the UI updates instantly;
            // disk rename happens asynchronously and triggers a refresh.
            if let idx = state.channels.firstIndex(where: { $0.name == oldName }) {
                state.channels[idx].name = newName
            }
            if let msgs = state.channelMessages.removeValue(forKey: oldName) {
                state.channelMessages[newName] = msgs
            }
            if let seen = state.channelLastSeenMessageId.removeValue(forKey: oldName) {
                state.channelLastSeenMessageId[newName] = seen
            }
            if let read = state.channelLastReadMessageId.removeValue(forKey: oldName) {
                state.channelLastReadMessageId[newName] = read
            }
            if let opened = state.channelLastOpened.removeValue(forKey: oldName) {
                state.channelLastOpened[newName] = opened
            }
            if let draft = state.channelDrafts.removeValue(forKey: oldName) {
                state.channelDrafts[newName] = draft
            }
            if state.selectedChannelName == oldName {
                state.selectedChannelName = newName
            }
            return [.renameChannelOnDisk(old: oldName, new: newName), .loadChannels]

        case .createChannel(let rawName):
            let name = rawName
                .replacingOccurrences(of: "#", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !name.isEmpty else { return [] }
            let by = state.humanParticipant
            return [.createChannelOnDisk(name: name, by: by), .loadChannels]

        case .kickChannelMember(let channelName, let member):
            let clean = channelName
                .replacingOccurrences(of: "#", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !clean.isEmpty,
                  let idx = state.channels.firstIndex(where: { $0.name == clean })
            else { return [] }
            // Optimistic removal so the UI chip disappears immediately; the
            // disk effect + watcher refresh will re-confirm.
            state.channels[idx].members.removeAll { m in
                if let cA = m.cardId, let cB = member.cardId { return cA == cB }
                return m.handle == member.handle
            }
            return [.leaveChannelOnDisk(name: clean, member: member), .loadChannels]

        case .sendChannelMessage(let channelName, let body, let imagePaths):
            let from = state.humanParticipant
            let memberTargets: [ChannelMemberTarget] = {
                guard let ch = state.channels.first(where: { $0.name == channelName }) else { return [] }
                return ch.members.compactMap { m -> ChannelMemberTarget? in
                    guard let cardId = m.cardId,
                          let link = state.links[cardId],
                          let sess = link.tmuxLink?.sessionName
                    else { return nil }
                    return ChannelMemberTarget(sessionName: sess, assistant: link.effectiveAssistant)
                }
            }()
            return [.sendChannelMessageToDisk(channelName: channelName, from: from, body: body, imagePaths: imagePaths, memberTargets: memberTargets)]

        case .channelMessageAppended(let channelName, let msg):
            var msgs = state.channelMessages[channelName] ?? []
            let didAppend = !msgs.contains(where: { $0.id == msg.id })
            if didAppend {
                msgs.append(msg)
                msgs.sort { $0.ts < $1.ts }
                state.channelMessages[channelName] = msgs
            }
            // If I sent this message OR I'm currently looking at this channel,
            // bump the read marker — but ONLY for real chat messages. Joins /
            // leaves / system events don't count as "read content", and pinning
            // to them makes the unread counter's lookup miss (→ every real
            // message re-counts as unread).
            let mine = msg.from.cardId == nil && msg.from.handle == state.humanHandle
            let focused = state.selectedChannelName == channelName
            if (mine || focused), msg.type == .message {
                if state.channelLastReadMessageId[channelName] != msg.id {
                    state.channelLastReadMessageId[channelName] = msg.id
                    return [Self.persistReadState(state)]
                }
            }
            return []

        case .unlinkFromCard(let cardId, let linkType):
            guard var link = state.links[cardId] else { return [] }
            switch linkType {
            case .pr(let number):
                link.prLinks.removeAll { $0.number == number }
                var dismissed = link.manualOverrides.dismissedPRs ?? []
                if !dismissed.contains(number) { dismissed.append(number) }
                link.manualOverrides.dismissedPRs = dismissed
            case .issue:
                link.issueLink = nil
                link.manualOverrides.issueLink = true
            case .worktree:
                // Set watermark = current JSONL file size. Data before this point is ignored.
                if let path = link.sessionLink?.sessionPath {
                    let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
                    link.manualOverrides.branchWatermark = size
                } else {
                    link.manualOverrides.branchWatermark = 0
                }
                link.discoveredBranches = nil  // clear old cached branches
                link.worktreeLink = nil
            case .tmux:
                link.tmuxLink = nil
                link.manualOverrides.tmuxSession = true
            }
            link.updatedAt = .now
            state.links[cardId] = link
            return [.upsertLink(link)]

        case .killTerminal(let cardId, let sessionName):
            guard var link = state.links[cardId] else { return [] }
            if sessionName == link.tmuxLink?.sessionName {
                // Killing primary session
                if link.tmuxLink?.extraSessions != nil {
                    // Extras exist — keep tmuxLink, mark primary dead
                    link.tmuxLink?.isPrimaryDead = true
                    link.isLaunching = nil
                    if link.remote == nil { link.isRemote = false }
                    link.updatedAt = .now
                    state.links[cardId] = link
                    return [.killTmuxSession(sessionName), .upsertLink(link), .cleanupTerminalCache(sessionNames: [sessionName])]
                } else {
                    // No extras — full teardown. A boxd card keeps its machine
                    // record so a later resume finds it; the machine itself
                    // is stopped when no other card runs on it.
                    link.tmuxLink = nil
                    link.isLaunching = nil
                    if link.remote == nil { link.isRemote = false }
                    link.updatedAt = .now
                    state.links[cardId] = link
                    var effects: [Effect] = [.killTmuxSession(sessionName), .upsertLink(link), .cleanupTerminalCache(sessionNames: [sessionName])]
                    if let remote = link.remote, remote.mode == .boxd, !machineHasLiveSessions(remote.machineName, in: state) {
                        // The tab was closed: the work on this card is over,
                        // so the machine is stopped, not kept in standby.
                        effects.append(.stopRemoteMachine(machineName: remote.machineName, reason: .sessionStopped))
                    }
                    return effects
                }
            } else {
                // Killing extra session
                link.tmuxLink?.extraSessions?.removeAll { $0 == sessionName }
                if link.tmuxLink?.extraSessions?.isEmpty == true {
                    link.tmuxLink?.extraSessions = nil
                }
                // If primary is dead and no extras left, full teardown
                if link.tmuxLink?.isPrimaryDead == true && link.tmuxLink?.extraSessions == nil {
                    link.tmuxLink = nil
                }
                link.updatedAt = .now
                state.links[cardId] = link
                return [.killTmuxSession(sessionName), .upsertLink(link), .cleanupTerminalCache(sessionNames: [sessionName])]
            }

        case .cancelLaunch(let cardId):
            guard var link = state.links[cardId] else { return [] }
            state.launchProgress[cardId] = nil
            let tmuxName = link.tmuxLink?.sessionName
            link.isLaunching = nil
            link.tmuxLink = nil
            link.updatedAt = .now
            state.links[cardId] = link
            var effects: [Effect] = [.upsertLink(link)]
            if let tmuxName {
                effects.append(.killTmuxSession(tmuxName))
                effects.append(.cleanupTerminalCache(sessionNames: [tmuxName]))
            }
            return effects

        case .addBranchToCard(let cardId, let branch):
            guard var link = state.links[cardId] else { return [] }
            if link.worktreeLink != nil {
                link.worktreeLink?.branch = branch
            } else {
                link.worktreeLink = WorktreeLink(path: "", branch: branch)
            }
            link.manualOverrides.worktreePath = true
            link.updatedAt = .now
            state.links[cardId] = link
            return [.upsertLink(link)]

        case .addIssueLinkToCard(let cardId, let issueNumber):
            guard var link = state.links[cardId] else { return [] }
            link.issueLink = IssueLink(number: issueNumber)
            link.manualOverrides.issueLink = true
            link.updatedAt = .now
            state.links[cardId] = link
            return [.upsertLink(link)]

        case .addPRToCard(let cardId, let prNumber):
            guard var link = state.links[cardId] else { return [] }
            if !link.prLinks.contains(where: { $0.number == prNumber }) {
                link.prLinks.append(PRLink(number: prNumber))
            }
            // Un-dismiss if it was previously dismissed
            link.manualOverrides.dismissedPRs?.removeAll { $0 == prNumber }
            if link.manualOverrides.dismissedPRs?.isEmpty == true {
                link.manualOverrides.dismissedPRs = nil
            }
            link.manualOverrides.prLink = false
            link.updatedAt = .now
            state.links[cardId] = link
            return [.upsertLink(link)]

        case .markPRMerged(let cardId, let prNumber):
            guard var link = state.links[cardId] else { return [] }
            if let idx = link.prLinks.firstIndex(where: { $0.number == prNumber }) {
                link.prLinks[idx].status = .merged
            }
            link.column = .done
            link.updatedAt = .now
            state.links[cardId] = link
            return [.upsertLink(link)]

        case .addQueuedPrompt(let cardId, let prompt, let placement):
            guard var link = state.links[cardId] else { return [] }
            var prompts = link.queuedPrompts ?? []
            switch placement {
            case .front:
                prompts.insert(prompt, at: 0)
            case .back:
                prompts.append(prompt)
            }
            link.queuedPrompts = prompts
            link.updatedAt = .now
            state.links[cardId] = link
            return [.upsertLink(link), .journalQueuedPrompt(cardId: cardId, prompt: prompt, reason: .queued)]

        case .updateQueuedPrompt(let cardId, let promptId, let body, let sendAutomatically):
            guard var link = state.links[cardId] else { return [] }
            guard var prompts = link.queuedPrompts,
                  let idx = prompts.firstIndex(where: { $0.id == promptId }) else { return [] }
            prompts[idx].body = body
            prompts[idx].sendAutomatically = sendAutomatically
            link.queuedPrompts = prompts
            link.updatedAt = .now
            state.links[cardId] = link
            return [
                .upsertLink(link),
                .journalQueuedPrompt(cardId: cardId, prompt: prompts[idx], reason: .edited),
            ]

        case .removeQueuedPrompt(let cardId, let promptId):
            guard var link = state.links[cardId] else { return [] }
            let removed = link.queuedPrompts?.first { $0.id == promptId }
            link.queuedPrompts?.removeAll { $0.id == promptId }
            if link.queuedPrompts?.isEmpty == true { link.queuedPrompts = nil }
            link.updatedAt = .now
            state.links[cardId] = link
            var effects: [Effect] = [.upsertLink(link)]
            if let removed {
                effects.append(
                    .journalQueuedPrompt(cardId: cardId, prompt: removed, reason: .removed))
            }
            return effects

        case .sendQueuedPrompt(let cardId, let promptId):
            guard var link = state.links[cardId] else { return [] }
            guard let prompts = link.queuedPrompts,
                  let prompt = prompts.first(where: { $0.id == promptId }),
                  let sessionName = link.tmuxLink?.sessionName else { return [] }
            link.queuedPrompts?.removeAll { $0.id == promptId }
            if link.queuedPrompts?.isEmpty == true { link.queuedPrompts = nil }
            link.updatedAt = .now
            state.links[cardId] = link
            let sendEffect: Effect
            if let imagePaths = prompt.imagePaths, !imagePaths.isEmpty {
                sendEffect = .sendPromptWithImagesToTmux(sessionName: sessionName, promptBody: prompt.body, imagePaths: imagePaths, assistant: link.effectiveAssistant)
            } else {
                sendEffect = .sendPromptToTmux(sessionName: sessionName, promptBody: prompt.body, assistant: link.effectiveAssistant)
            }
            // Journalled before the send, because the send is what loses it:
            // the prompt is already gone from the card by the time tmux is
            // asked to take it, and nothing retries.
            return [
                .journalQueuedPrompt(cardId: cardId, prompt: prompt, reason: .sent),
                .upsertLink(link),
                sendEffect,
            ]

        case .reorderQueuedPrompts(let cardId, let promptIds):
            guard var link = state.links[cardId],
                  let prompts = link.queuedPrompts else { return [] }
            let byId = Dictionary(prompts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            link.queuedPrompts = promptIds.compactMap { byId[$0] }
            state.links[cardId] = link
            return [.upsertLink(link)]

        case .addBrowserTab(let cardId, let tabId, let url):
            guard var link = state.links[cardId] else { return [] }
            var tabs = link.browserTabs ?? []
            tabs.append(BrowserTabInfo(id: tabId, url: url))
            link.browserTabs = tabs
            link.updatedAt = .now
            state.links[cardId] = link
            return [.upsertLink(link)]

        case .removeBrowserTab(let cardId, let tabId):
            guard var link = state.links[cardId] else { return [] }
            link.browserTabs?.removeAll { $0.id == tabId }
            if link.browserTabs?.isEmpty == true { link.browserTabs = nil }
            link.updatedAt = .now
            state.links[cardId] = link
            return [.upsertLink(link)]

        case .updateBrowserTab(let cardId, let tabId, let url, let title):
            guard var link = state.links[cardId] else { return [] }
            guard var tabs = link.browserTabs,
                  let idx = tabs.firstIndex(where: { $0.id == tabId }) else { return [] }
            if let url { tabs[idx].url = url }
            if let title { tabs[idx].title = title }
            link.browserTabs = tabs
            state.links[cardId] = link
            return [.upsertLink(link)]

        case .moveCardToProject(let cardId, let projectPath):
            guard var link = state.links[cardId] else { return [] }
            let oldProjectPath = link.projectPath
            link.projectPath = projectPath
            // Clear repo-specific links — different project means different repo
            link.worktreeLink = nil
            link.prLinks = []
            link.discoveredBranches = nil
            link.discoveredRepos = nil
            // Kill tmux sessions — they're running in the old project
            var effects: [Effect] = []
            if let tmux = link.tmuxLink {
                effects.append(.killTmuxSessions(tmux.allSessionNames))
                effects.append(.cleanupTerminalCache(sessionNames: tmux.allSessionNames))
                link.tmuxLink = nil
            }
            link.updatedAt = .now
            state.links[cardId] = link
            effects.insert(.upsertLink(link), at: 0)
            // Move the .jsonl file to the new project folder
            if let sessionId = link.sessionLink?.sessionId,
               let oldPath = link.sessionLink?.sessionPath,
               oldProjectPath != projectPath {
                effects.append(.moveSessionFile(
                    cardId: cardId,
                    sessionId: sessionId,
                    oldPath: oldPath,
                    newProjectPath: projectPath
                ))
            }
            KanbanCodeLog.info("store", "MoveToProject: card=\(cardId.prefix(12)) → \(projectPath)")
            return effects

        case .moveCardToFolder(let cardId, let folderPath, let parentProjectPath):
            guard var link = state.links[cardId] else { return [] }
            let oldProjectPath = link.projectPath
            link.projectPath = parentProjectPath
            // Only clear repo-specific links if the parent project actually changed
            if oldProjectPath != parentProjectPath {
                link.worktreeLink = nil
                link.prLinks = []
                link.discoveredBranches = nil
                link.discoveredRepos = nil
            }
            var effects: [Effect] = []
            if let tmux = link.tmuxLink {
                effects.append(.killTmuxSessions(tmux.allSessionNames))
                effects.append(.cleanupTerminalCache(sessionNames: tmux.allSessionNames))
                link.tmuxLink = nil
            }
            link.updatedAt = .now
            state.links[cardId] = link
            effects.insert(.upsertLink(link), at: 0)
            // Move the session file — use folderPath for file location (not parentProjectPath)
            if let sessionId = link.sessionLink?.sessionId,
               let oldPath = link.sessionLink?.sessionPath {
                effects.append(.moveSessionFile(
                    cardId: cardId,
                    sessionId: sessionId,
                    oldPath: oldPath,
                    newProjectPath: folderPath
                ))
            }
            KanbanCodeLog.info("store", "MoveToFolder: card=\(cardId.prefix(12)) folder=\(folderPath) project=\(parentProjectPath)")
            return effects

        case .beginMigration(let cardId):
            guard var link = state.links[cardId] else { return [] }
            link.isLaunching = true
            link.launchedAt = .now
            link.updatedAt = .now
            state.links[cardId] = link
            state.busyCards.insert(cardId)
            return []

        case .migrateSession(let cardId, let newAssistant, let newSessionId, let newSessionPath):
            guard var link = state.links[cardId] else { return [] }
            // Mark old session as deleted so reconciler won't recreate a card for it
            if let oldSessionId = link.sessionLink?.sessionId {
                state.deletedSessionIds.insert(oldSessionId)
            }
            if link.effectiveAssistant != newAssistant {
                link.apiServiceId = nil
                link.modelOverride = nil
                if !newAssistant.supportsContextThresholdSelfCompact {
                    link.queuedPrompts?.removeAll { $0.selfCompactThresholdTokens != nil }
                }
            }
            link.assistant = newAssistant
            link.sessionLink = SessionLink(sessionId: newSessionId, sessionPath: newSessionPath)
            // Kill tmux sessions — the old assistant process must stop
            var effects: [Effect] = []
            if let tmux = link.tmuxLink {
                effects.append(.killTmuxSessions(tmux.allSessionNames))
                effects.append(.cleanupTerminalCache(sessionNames: tmux.allSessionNames))
                link.tmuxLink = nil
            }
            link.isLaunching = nil
            link.updatedAt = .now
            state.links[cardId] = link
            state.busyCards.remove(cardId)
            KanbanCodeLog.info("store", "MigrateSession: card=\(cardId.prefix(12)) → \(newAssistant)")
            effects.insert(.upsertLink(link), at: 0)
            return effects

        case .migrationFailed(let cardId, let error):
            guard var link = state.links[cardId] else { return [] }
            link.isLaunching = nil
            link.updatedAt = .now
            state.links[cardId] = link
            state.busyCards.remove(cardId)
            state.notice = Notice("Migration failed: \(error)")
            return []

        case .mergeCards(let sourceId, let targetId):
            guard let source = state.links[sourceId],
                  var target = state.links[targetId],
                  sourceId != targetId else { return [] }

            // Validation: don't merge two cards that both have sessions
            if source.sessionLink != nil && target.sessionLink != nil {
                state.notice = Notice("Cannot merge: both cards have sessions")
                return []
            }
            // Don't merge two cards that both have tmux terminals
            if source.tmuxLink != nil && target.tmuxLink != nil {
                state.notice = Notice("Cannot merge: both cards have terminals")
                return []
            }
            // Don't merge two cards that both have different issues
            if source.issueLink != nil && target.issueLink != nil
                && source.issueLink != target.issueLink {
                state.notice = Notice("Cannot merge: both cards have different issues")
                return []
            }

            // Transfer links from source → target (only fill nil slots)
            if target.sessionLink == nil { target.sessionLink = source.sessionLink }
            if target.tmuxLink == nil { target.tmuxLink = source.tmuxLink }
            if target.worktreeLink == nil { target.worktreeLink = source.worktreeLink }
            if target.issueLink == nil { target.issueLink = source.issueLink }
            if target.projectPath == nil { target.projectPath = source.projectPath }
            if target.name == nil { target.name = source.name }
            if target.promptBody == nil { target.promptBody = source.promptBody }
            if target.pinnedAt == nil {
                target.pinnedAt = source.pinnedAt
                target.pinnedSortOrder = source.pinnedSortOrder
            }
            // Merge PR links (deduplicate by PR number)
            let existingPRNumbers = Set(target.prLinks.map(\.number))
            for pr in source.prLinks where !existingPRNumbers.contains(pr.number) {
                target.prLinks.append(pr)
            }
            // Merge discovered branches
            if let sourceBranches = source.discoveredBranches {
                var branches = target.discoveredBranches ?? []
                for b in sourceBranches where !branches.contains(b) { branches.append(b) }
                target.discoveredBranches = branches
            }
            if let sourceRepos = source.discoveredRepos {
                var repos = target.discoveredRepos ?? [:]
                for (k, v) in sourceRepos { repos[k] = v }
                target.discoveredRepos = repos
            }
            // Preserve the more recent lastActivity
            if let sourceActivity = source.lastActivity {
                if target.lastActivity == nil || sourceActivity > target.lastActivity! {
                    target.lastActivity = sourceActivity
                }
            }
            // If source is remote, inherit that
            if source.isRemote { target.isRemote = true }

            target.updatedAt = .now
            state.links[targetId] = target

            // Remove source card
            state.links.removeValue(forKey: sourceId)
            state.deletedCardIds.insert(sourceId)
            if let sessionId = source.sessionLink?.sessionId, target.sessionLink?.sessionId != sessionId {
                state.deletedSessionIds.insert(sessionId)
            }
            if state.selectedCardId == sourceId { state.selectedCardId = targetId }

            KanbanCodeLog.info("store", "Merge: \(sourceId.prefix(12)) → \(targetId.prefix(12))")
            return [.upsertLink(target), .removeLink(sourceId)]

        // MARK: Async Completions

        case .launchProgress(let cardId, let message):
            guard var link = state.links[cardId], link.isLaunching == true else { return [] }
            state.launchProgress[cardId] = message
            link.updatedAt = .now
            state.links[cardId] = link
            return []

        case .launchCompleted(let cardId, let tmuxName, let sessionLink, let worktreeLink, let isRemote):
            guard var link = state.links[cardId] else { return [] }
            state.launchProgress[cardId] = nil
            let existingExtras = link.tmuxLink?.extraSessions
            link.tmuxLink = TmuxLink(sessionName: tmuxName, extraSessions: existingExtras)
            if let sl = sessionLink { link.sessionLink = sl }
            if let wl = worktreeLink, link.worktreeLink == nil { link.worktreeLink = wl }
            // Clear isLaunching immediately so the terminal shows without waiting
            // for reconciliation (5s). Setting lastActivity prevents column bounce
            // to .allSessions — card lands in .waiting until hooks confirm .inProgress.
            link.isLaunching = nil
            link.lastActivity = .now
            link.isRemote = isRemote
            link.updatedAt = .now
            state.links[cardId] = link
            return [.upsertLink(link)]

        case .launchTmuxReady(let cardId):
            guard var link = state.links[cardId] else { return [] }
            state.launchProgress[cardId] = nil
            // Clear isLaunching so the UI shows the terminal immediately.
            // tmuxLink was already set by launchCard — we just flip the flag.
            link.isLaunching = nil
            link.lastActivity = .now
            link.updatedAt = .now
            state.links[cardId] = link
            return [.upsertLink(link)]

        case .launchFailed(let cardId, let error):
            guard var link = state.links[cardId] else { return [] }
            state.launchProgress[cardId] = nil
            link.tmuxLink = nil
            link.isLaunching = nil
            link.updatedAt = .now
            state.links[cardId] = link
            state.notice = Notice("Launch failed: \(error)")
            return [.upsertLink(link)]

        case .resumeCompleted(let cardId, let tmuxName, let isRemote):
            guard var link = state.links[cardId] else { return [] }
            state.launchProgress[cardId] = nil
            let existingExtras = link.tmuxLink?.extraSessions
            link.tmuxLink = TmuxLink(sessionName: tmuxName, extraSessions: existingExtras)
            link.isRemote = isRemote
            link.isLaunching = nil
            link.lastActivity = .now
            link.updatedAt = .now
            state.links[cardId] = link
            return [.upsertLink(link)]

        case .resumeFailed(let cardId, let error):
            guard var link = state.links[cardId] else { return [] }
            state.launchProgress[cardId] = nil
            link.tmuxLink = nil
            link.isLaunching = nil
            link.updatedAt = .now
            state.links[cardId] = link
            state.notice = Notice("Resume failed: \(error)")
            return [.upsertLink(link)]

        case .terminalCreated(let cardId, _):
            state.busyCards.remove(cardId)
            return []

        case .terminalFailed(let cardId, let error):
            guard var link = state.links[cardId] else { return [] }
            link.tmuxLink = nil
            link.updatedAt = .now
            state.links[cardId] = link
            state.busyCards.remove(cardId)
            state.notice = Notice("Terminal failed: \(error)")
            return [.upsertLink(link)]

        case .extraTerminalCreated(let cardId, _):
            state.busyCards.remove(cardId)
            return []

        case .extraTerminalFailed(let cardId, let sessionName, let error):
            guard var link = state.links[cardId] else { return [] }
            // Only the shell that failed goes away. The session of the card
            // keeps running: it has nothing to do with this tab.
            let remaining = (link.tmuxLink?.extraSessions ?? []).filter { $0 != sessionName }
            link.tmuxLink?.extraSessions = remaining
            link.updatedAt = .now
            state.links[cardId] = link
            state.busyCards.remove(cardId)
            state.notice = Notice("Terminal failed: \(error)", kind: .error)
            return [.upsertLink(link)]

        case .renameTerminalTab(let cardId, let sessionName, let label):
            guard var link = state.links[cardId],
                  var tmux = link.tmuxLink else { return [] }
            var names = tmux.tabNames ?? [:]
            if label.isEmpty {
                names.removeValue(forKey: sessionName)
            } else {
                names[sessionName] = label
            }
            tmux.tabNames = names.isEmpty ? nil : names
            link.tmuxLink = tmux
            link.updatedAt = .now
            state.links[cardId] = link
            return [.upsertLink(link)]

        case .reorderTerminalTab(let cardId, let sessionName, let beforeSession):
            guard var link = state.links[cardId],
                  var tmux = link.tmuxLink,
                  var extras = tmux.extraSessions,
                  let fromIndex = extras.firstIndex(of: sessionName) else { return [] }
            extras.remove(at: fromIndex)
            if let before = beforeSession, let toIndex = extras.firstIndex(of: before) {
                extras.insert(sessionName, at: toIndex)
            } else {
                extras.append(sessionName)
            }
            tmux.extraSessions = extras
            link.tmuxLink = tmux
            link.updatedAt = .now
            state.links[cardId] = link
            return [.upsertLink(link)]

        // MARK: Background Reconciliation

        case .tmuxLivenessScanned(let live):
            if state.tmuxSessions != live { state.tmuxSessions = live }

            var linksChanged = false
            var removedSessionNames: [String] = []
            for (id, var link) in state.links {
                guard link.tmuxLink != nil, link.isLaunching != true,
                      !link.manualOverrides.tmuxSession else { continue }
                // A remote card whose machine is paused or unreachable is not
                // in the scan; its tmux session is still there.
                if let remote = link.remote, link.isRemote,
                   state.remoteMachineStates[remote.machineName]?.isConnected != true { continue }
                let before = link.tmuxLink?.allSessionNames ?? []
                guard CardReconciler.applyTmuxLiveness(to: &link, liveTmuxNames: live) else { continue }
                let after = link.tmuxLink?.allSessionNames ?? []
                removedSessionNames.append(contentsOf: before.filter { !after.contains($0) })
                link.updatedAt = .now
                state.links[id] = link
                linksChanged = true
            }
            guard linksChanged else { return [] }

            KanbanCodeLog.info(
                "reconcile",
                "tmux liveness: cleared \(removedSessionNames.count) dead session(s): \(removedSessionNames.prefix(5).joined(separator: ", "))\(removedSessionNames.count > 5 ? ", …" : "")"
            )
            state.rebuildCards()
            var effects: [Effect] = [.persistLinks(Array(state.links.values))]
            if !removedSessionNames.isEmpty {
                effects.append(.cleanupTerminalCache(sessionNames: removedSessionNames))
            }
            return effects

        case .reconciled(let result):
            var cardInputsChanged = false

            // Equality-gated assignments — only trigger @Observable change notifications
            // for fields that actually differ. Prevents unnecessary SwiftUI re-renders
            // when reconciliation produces the same data as the previous cycle.
            //
            // NOTE: configuredProjects, excludedPaths, and globalRemoteSettings are
            // NOT updated from the reconciled result. Reconcile captures them at the
            // start (~250ms ago) and a concurrent addProject would be reverted.
            // settingsLoaded is the only action that updates them.
            if state.tmuxSessions != result.tmuxSessions { state.tmuxSessions = result.tmuxSessions }
            if state.discoveredProjectPaths != result.discoveredProjectPaths { state.discoveredProjectPaths = result.discoveredProjectPaths }

            // Rebuild sessions map
            let newSessions = Dictionary(
                result.sessions.map { ($0.id, $0) },
                uniquingKeysWith: { a, _ in a }
            )
            if state.sessions != newSessions {
                state.sessions = newSessions
                cardInputsChanged = true
            }
            if state.activityMap != result.activityMap {
                state.activityMap = result.activityMap
                cardInputsChanged = true
            }

            // Merge reconciled links using last-writer-wins on updatedAt.
            // Reconciliation takes seconds of async work. Any in-memory changes
            // made during that window (launch, create terminal, move card) have a
            // newer updatedAt than the stale snapshot the reconciler used.
            var mergedLinks = state.links
            var preservedIds: Set<String> = []
            for reconciledLink in result.links {
                var link = reconciledLink
                // Skip cards deliberately deleted during this reconciliation cycle
                if state.deletedCardIds.contains(link.id) {
                    continue
                }
                // Skip cards whose session was deliberately deleted
                if let sessionId = link.sessionLink?.sessionId, state.deletedSessionIds.contains(sessionId) {
                    continue
                }
                if let existing = mergedLinks[link.id] {
                    link.parentCardId = existing.parentCardId
                    link.modelOverride = existing.modelOverride
                    link.selfCompactContextThresholdTokens = existing.selfCompactContextThresholdTokens
                    // The machine record is written by the supervisor, never
                    // by the reconciler. A snapshot taken before the machine
                    // was assigned must not take it away again.
                    if link.remote == nil, let remote = existing.remote {
                        link.remote = remote
                        link.isRemote = existing.isRemote
                    }
                    // Manual ordering is UI-owned: the reconciler only ever echoes
                    // back whatever links.json held when it took its snapshot. A
                    // drag that lands mid-cycle carries no updatedAt bump (it would
                    // reset every "x ago" label in the column), so last-writer-wins
                    // cannot protect it and the card would visibly jump back.
                    link.sortOrder = existing.sortOrder
                    link.pinnedSortOrder = existing.pinnedSortOrder
                    if existing.isLaunching == true {
                        // Check if activity hook has confirmed the session is running.
                        // A card on a machine keeps the flag until its launch
                        // reports: its mirrored transcript looks active as
                        // soon as the bridge reconnects, long before the
                        // session is back. So does a launch that is still
                        // reporting progress, and a resume whose old
                        // transcript only says the session it replaces ended.
                        let activity = result.activityMap[existing.sessionLink?.sessionId ?? ""]
                        let stillReporting = state.launchProgress[link.id] != nil
                        if let activity, activity != .ended, activity != .stale, existing.remote == nil, !stillReporting {
                            // Activity detected — clear isLaunching, let column recomputation run
                            var cleared = existing
                            cleared.isLaunching = nil
                            mergedLinks[link.id] = cleared
                            KanbanCodeLog.info("store", "Cleared isLaunching on card=\(link.id.prefix(12)) (activity=\(activity))")
                            continue
                        }
                        // Stale launch timeout: clear isLaunching after 30s
                        // (crash recovery). The in-memory link is kept, so
                        // everything the launch wrote so far (machine, worktree)
                        // survives; only the flag goes.
                        if Date.now.timeIntervalSince(existing.updatedAt) > 30 {
                            var cleared = existing
                            cleared.isLaunching = nil
                            cleared.updatedAt = .now
                            mergedLinks[link.id] = cleared
                            KanbanCodeLog.info("store", "Cleared stale isLaunching on card=\(link.id.prefix(12))")
                            continue
                        }
                        // Still launching, no activity yet — preserve
                        preservedIds.insert(link.id)
                        continue
                    }
                    // In-memory state is newer → preserve it, skip stale reconciled data.
                    // The next reconciliation cycle (5s) will incorporate these changes.
                    if existing.updatedAt > link.updatedAt {
                        preservedIds.insert(link.id)
                        continue
                    }
                }
                mergedLinks[link.id] = link
            }

            // Honor reconciler removals for bare orphan worktree cards.
            //
            // `mergedLinks` starts from full in-memory state so concurrent edits
            // survive an async reconcile. That also means cards removed by the
            // reconciler stay alive unless the reducer explicitly drops them.
            // When worktree branches are refreshed by path, several stale orphan
            // worktree cards can collapse to one keeper in `CardReconciler`. If
            // we keep the removed orphans here, the next reconcile sees them
            // again, logs the same branch-change/dedup work every few seconds,
            // and creates avoidable UI hitches.
            let reconciledIds = Set(result.links.map(\.id))
            for (id, link) in mergedLinks {
                guard !reconciledIds.contains(id),
                      link.sessionLink == nil,
                      link.source != .manual,
                      link.name == nil,
                      link.worktreeLink != nil
                else { continue }
                mergedLinks.removeValue(forKey: id)
                KanbanCodeLog.info("store", "Dropped reconciler-removed orphan \(id.prefix(12))")
            }

            if !preservedIds.isEmpty {
                KanbanCodeLog.info("store", "Preserved \(preservedIds.count) card(s) modified during reconciliation")
            }

            // Absorb orphan worktree cards (worktreeLink but no sessionLink) into
            // cards that have a session on the same branch. Multiple sessions on the
            // same branch are legitimate (e.g., forked tasks) and must NOT be merged.
            var branchToIds: [String: [String]] = [:]
            for (id, link) in mergedLinks {
                if let branch = link.worktreeLink?.branch, !branch.isEmpty {
                    branchToIds[branch, default: []].append(id)
                }
            }
            for (branch, ids) in branchToIds where ids.count > 1 {
                // Split into "real" cards (have a session or were manually created) vs orphans
                let realIds = ids.filter { id in
                    let l = mergedLinks[id]!
                    return l.sessionLink != nil || l.source == .manual || l.name != nil
                }
                let orphanIds = ids.filter { id in
                    let l = mergedLinks[id]!
                    return l.sessionLink == nil && l.source != .manual && l.name == nil
                }
                guard !orphanIds.isEmpty else { continue } // all legitimate — no dedup needed

                // Pick a keeper among real cards (or the first orphan if no real cards)
                let keeperId = realIds.first ?? orphanIds.first!
                var keeper = mergedLinks[keeperId]!

                // Remove all orphans (transfer their data to keeper first)
                for orphanId in orphanIds where orphanId != keeperId {
                    if let orphan = mergedLinks[orphanId] {
                        if keeper.worktreeLink == nil { keeper.worktreeLink = orphan.worktreeLink }
                        if keeper.tmuxLink == nil { keeper.tmuxLink = orphan.tmuxLink }
                        KanbanCodeLog.info("store", "Dedup: absorbing orphan \(orphanId.prefix(12)) (branch=\(branch)) into \(keeperId.prefix(12))")
                    }
                    mergedLinks.removeValue(forKey: orphanId)
                }
                mergedLinks[keeperId] = keeper
            }

            // Recompute columns for cards NOT mid-launch and NOT preserved.
            // Preserved cards have stale tmux/activity data — skip them until
            // the next reconciliation cycle picks up their current state.
            let liveTmuxNames = result.tmuxSessions
            deduplicatePrimaryTmuxLinks(&mergedLinks, liveTmuxNames: liveTmuxNames)

            for (id, var link) in mergedLinks where link.isLaunching != true && !preservedIds.contains(id) {
                let activity = result.activityMap[link.sessionLink?.sessionId ?? ""]
                let hasTmux = link.tmuxLink.map { tmux in
                    // Shell-only terminals don't count as "active work" for column assignment
                    guard tmux.isShellOnly != true else { return false }
                    return tmux.allSessionNames.contains(where: { liveTmuxNames.contains($0) })
                } ?? false
                let hasWorktree = link.worktreeLink?.branch != nil

                // Clear manual column override when we have definitive data.
                // Backlog is sticky — the user explicitly parked this card.
                if link.manualOverrides.column && link.column != .backlog {
                    if activity != nil && activity != .stale {
                        link.manualOverrides.column = false
                    } else if link.tmuxLink != nil && !hasTmux {
                        link.tmuxLink = nil
                        link.manualOverrides.column = false
                    }
                }

                UpdateCardColumn.update(
                    link: &link,
                    activityState: activity,
                    hasWorktree: hasWorktree || hasTmux,
                    hasLiveSession: hasTmux
                )

                // Copy session's firstPrompt into link.promptBody
                if link.promptBody == nil,
                   let sessionId = link.sessionLink?.sessionId,
                   let session = result.sessions.first(where: { $0.id == sessionId }),
                   let firstPrompt = session.firstPrompt, !firstPrompt.isEmpty {
                    link.promptBody = firstPrompt
                }

                mergedLinks[id] = link
            }

            let linksChanged = state.links != mergedLinks
            if linksChanged {
                state.links = mergedLinks
                cardInputsChanged = true
            }
            state.lastRefresh = Date()
            if state.isLoading { state.isLoading = false }

            // Validate selected card still exists
            if let selectedId = state.selectedCardId,
               !mergedLinks.keys.contains(selectedId) {
                state.selectedCardId = nil
                cardInputsChanged = true
            }

            if cardInputsChanged {
                state.rebuildCards()
            }

            return linksChanged ? [.persistLinks(Array(mergedLinks.values))] : []

        case .gitHubIssuesUpdated(let updatedLinks):
            let updatedIds = Set(updatedLinks.map(\.id))
            for link in updatedLinks {
                // Don't overwrite cards modified since the GitHub refresh started
                if let existing = state.links[link.id], existing.updatedAt > link.updatedAt {
                    continue
                }
                state.links[link.id] = link
            }
            // Remove stale GitHub issues no longer in the fetched set
            for (id, link) in state.links {
                if link.source == .githubIssue, link.column == .backlog, !updatedIds.contains(id) {
                    state.links.removeValue(forKey: id)
                }
            }
            state.lastGitHubRefresh = Date()
            return [.persistLinks(Array(state.links.values))]

        case .activityChanged(let activityMap):
            // Lightweight column update — no full reconciliation, just activity → column
            var changed = false
            for (id, var link) in state.links where link.isLaunching != true {
                guard let sessionId = link.sessionLink?.sessionId,
                      let activity = activityMap[sessionId] else { continue }
                let hasWorktree = link.worktreeLink?.branch != nil
                let hasLiveSession = link.tmuxLink.map { tmux in
                    guard tmux.isShellOnly != true else { return false }
                    return tmux.allSessionNames.contains(where: { state.tmuxSessions.contains($0) })
                } ?? false
                let oldColumn = link.column
                UpdateCardColumn.update(
                    link: &link, activityState: activity,
                    hasWorktree: hasWorktree, hasLiveSession: hasLiveSession)
                if link.column != oldColumn {
                    state.links[id] = link
                    changed = true
                }
            }
            if state.activityMap != activityMap { state.activityMap = activityMap }
            return changed ? [.persistLinks(Array(state.links.values))] : []

        // MARK: Busy State

        case .setBusy(let cardId, let busy):
            if busy {
                state.busyCards.insert(cardId)
            } else {
                state.busyCards.remove(cardId)
            }
            return []

        // MARK: Settings / Misc

        case .settingsLoaded(let projects, let excludedPaths, let remote, let remoteMode, let boxd):
            state.configuredProjects = projects
            state.excludedPaths = excludedPaths
            state.globalRemoteSettings = remote
            state.remoteMode = remoteMode
            state.boxdSettings = boxd
            return []

        // MARK: Remote machines

        case .remoteMachineAssigned(let cardId, let remote):
            guard var link = state.links[cardId] else { return [] }
            link.remote = remote
            link.isRemote = true
            link.updatedAt = .now
            state.links[cardId] = link
            return [.upsertLink(link)]

        case .remoteMachineStateChanged(let machineName, let machineState):
            if case .destroyed = machineState {
                state.remoteMachineStates[machineName] = nil
            } else {
                state.remoteMachineStates[machineName] = machineState
            }
            var effects: [Effect] = []
            for id in state.cardIds(onMachine: machineName) {
                guard var link = state.links[id], var remote = link.remote else { continue }
                switch machineState {
                case .paused(let reason):
                    remote.pausedReason = reason
                    remote.pausedAt = .now
                    remote.lastStatus = "standby"
                case .connected, .connecting:
                    remote.pausedReason = nil
                    remote.pausedAt = nil
                    remote.lastStatus = "running"
                case .unreachable, .reconnecting:
                    break
                case .destroyed:
                    link.remote = nil
                    link.isRemote = false
                    link.updatedAt = .now
                    state.links[id] = link
                    effects.append(.upsertLink(link))
                    continue
                }
                guard remote != link.remote else { continue }
                link.remote = remote
                link.updatedAt = .now
                state.links[id] = link
                effects.append(.upsertLink(link))
            }
            return effects

        case .stopRemoteMachine(let cardId, let reason):
            guard let remote = state.links[cardId]?.remote, remote.mode == .boxd else { return [] }
            return [.stopRemoteMachine(machineName: remote.machineName, reason: reason)]

        case .destroyRemoteMachine(let cardId):
            guard var link = state.links[cardId], let remote = link.remote, remote.mode == .boxd else { return [] }
            var effects: [Effect] = []
            if let tmux = link.tmuxLink {
                effects.append(.killTmuxSessions(tmux.allSessionNames))
                effects.append(.cleanupTerminalCache(sessionNames: tmux.allSessionNames))
                link.tmuxLink = nil
                link.isLaunching = nil
            }
            effects.append(contentsOf: releaseRemoteMachine(of: &link, in: state, destroy: true))
            state.links[cardId] = link
            effects.insert(.upsertLink(link), at: 0)
            return effects

        case .remoteMachineDestroyed(let machineName):
            state.remoteMachineStates[machineName] = nil
            state.notice = Notice("Machine \(machineName) destroyed", kind: .success)
            var effects: [Effect] = []
            for id in state.cardIds(onMachine: machineName) {
                guard var link = state.links[id] else { continue }
                link.remote = nil
                link.isRemote = false
                if link.tmuxLink != nil {
                    effects.append(.cleanupTerminalCache(sessionNames: link.tmuxLink?.allSessionNames ?? []))
                    link.tmuxLink = nil
                    link.isLaunching = nil
                }
                link.updatedAt = .now
                state.links[id] = link
                effects.append(.upsertLink(link))
            }
            return effects

        case .setError(let message):
            state.notice = message.map { Notice($0) }
            return []

        case .setNotice(let message, let kind):
            state.notice = message.map { Notice($0, kind: kind) }
            return []

        case .setRateLimitedRepos(let repos):
            guard state.rateLimitedRepos != repos else { return [] }
            state.rateLimitedRepos = repos
            state.rebuildCards()
            return []

        case .setSelectedProject(let path):
            state.selectedProjectPath = path
            return []

        case .setLoading(let loading):
            state.isLoading = loading
            return []

        case .setIsRefreshingBacklog(let refreshing):
            state.isRefreshingBacklog = refreshing
            return []
        }
    }

    private static func logChannelPayloadIfLarge(kind: String, name: String, messages: [ChannelMessage]) {
        let bodyChars = messages.reduce(0) { $0 + $1.body.count }
        let imageCount = messages.reduce(0) { $0 + ($1.imagePaths?.count ?? 0) }
        guard messages.count >= 250 || bodyChars >= 250_000 || imageCount >= 25 else { return }
        KanbanCodeLog.info(
            "memory-context",
            "\(kind)MessagesLoaded name=\(name) messages=\(messages.count) bodyChars=\(bodyChars) images=\(imageCount)"
        )
    }
}

// MARK: - BoardStore

/// Cheap stat()-based fingerprint that detects both worktree add/remove
/// (parent dir mtime) and branch checkout inside an existing worktree
/// (per-worktree HEAD mtime).
struct WorktreeCacheFingerprint: Equatable, Sendable {
    let parentMtime: Date?
    let maxHeadMtime: Date?

    static func capture(repoRoot: String) -> WorktreeCacheFingerprint {
        let fm = FileManager.default
        let parent = (repoRoot as NSString).appendingPathComponent(".git/worktrees")
        let parentMtime = (try? fm.attributesOfItem(atPath: parent))?[.modificationDate] as? Date
        var maxHead: Date?
        if let entries = try? fm.contentsOfDirectory(atPath: parent) {
            for name in entries {
                let head = (parent as NSString).appendingPathComponent("\(name)/HEAD")
                guard let m = (try? fm.attributesOfItem(atPath: head))?[.modificationDate] as? Date else { continue }
                if maxHead == nil || m > maxHead! { maxHead = m }
            }
        }
        return WorktreeCacheFingerprint(parentMtime: parentMtime, maxHeadMtime: maxHead)
    }
}

/// The main store. Replaces BoardState as the single source of truth.
/// All mutations go through dispatch() → Reducer → Effects.
@Observable
@MainActor
public final class BoardStore: @unchecked Sendable {
    public private(set) var state: AppState
    private let effectHandler: EffectHandler

    // Dependencies for reconciliation
    private var isReconciling = false
    private var lastGHLookup: ContinuousClock.Instant = .now - .seconds(600)
    private var ghRateLimitedUntil: ContinuousClock.Instant = .now
    private var lastAutoBranchDiscovery: ContinuousClock.Instant = .now - .seconds(120)
    private var lastAutoBranchDiscoveryByCard: [String: ContinuousClock.Instant] = [:]
    public var appIsActive: Bool = true
    /// True between NSWorkspace willSleep and didWake (set by the app layer).
    /// Reconciles are skipped while the machine sleeps: overnight maintenance
    /// (dark) wakes otherwise fire the refresh timer every few minutes, each
    /// pass spawning discovery work and dozens of gh subprocesses all night.
    public var isSystemSleeping: Bool = false
    /// Cached worktree results by repo root. The fingerprint pairs the
    /// `.git/worktrees/` dir mtime (changes on add/remove) with the max
    /// `.git/worktrees/<name>/HEAD` mtime (changes when Claude does
    /// `git checkout -b` inside an existing worktree). Without the HEAD piece
    /// the cache stays stale across branch switches and reconciler section
    /// B1.5 never picks up Claude's renamed branch — leaving cards unlinked
    /// from PRs whose branch differs from the worktree dir name.
    private var worktreeCache: [String: (fingerprint: WorktreeCacheFingerprint, worktrees: [Worktree])] = [:]
    /// The background GitHub fetch in flight, if any. Reconcile passes never
    /// wait on it: they apply `cachedPRsByBranch`/`cachedPRsByRepoAndNumber`
    /// from the last completed fetch and move on.
    private var prFetchTask: Task<Void, Never>?

    /// Session names seen by the previous reconcile pass, nil before the
    /// first scan. Sudden disappearances point at an outside kill and get
    /// captured by SessionDeathRecorder while the unified log still has
    /// the evidence.
    private var lastTmuxSessionNames: Set<String>?
    private var cachedPRsByBranch: [String: PullRequest] = [:]
    private var cachedPRsByRepoAndNumber: [String: [Int: PullRequest]] = [:]
    /// "host/owner/name" → number → PR, for pull requests routed by the
    /// repository their own URL names rather than by the card's project.
    private var cachedPRsByRepoKeyAndNumber: [String: [Int: PullRequest]] = [:]
    private let discovery: SessionDiscovery
    private let coordinationStore: CoordinationStore
    private let activityDetector: (any ActivityDetector)?
    private let settingsStore: SettingsStore?
    private let ghAdapter: GhCliAdapter?
    private let worktreeAdapter: GitWorktreeAdapter?
    private let tmuxAdapter: TmuxManagerPort?

    public let sessionStore: SessionStore

    public init(
        effectHandler: EffectHandler,
        discovery: SessionDiscovery,
        coordinationStore: CoordinationStore,
        activityDetector: (any ActivityDetector)? = nil,
        settingsStore: SettingsStore? = nil,
        ghAdapter: GhCliAdapter? = nil,
        worktreeAdapter: GitWorktreeAdapter? = nil,
        tmuxAdapter: TmuxManagerPort? = nil,
        sessionStore: SessionStore = ClaudeCodeSessionStore()
    ) {
        self.state = AppState()
        self.effectHandler = effectHandler
        self.discovery = discovery
        self.coordinationStore = coordinationStore
        self.activityDetector = activityDetector
        self.settingsStore = settingsStore
        self.ghAdapter = ghAdapter
        self.worktreeAdapter = worktreeAdapter
        self.tmuxAdapter = tmuxAdapter
        self.sessionStore = sessionStore
    }

    /// Actions that only toggle UI state and don't affect card data — skip rebuildCards().
    private static func needsRebuild(_ action: Action) -> Bool {
        switch action {
        case .reconciled, .setRateLimitedRepos, .tmuxLivenessScanned, .sessionModelsScanned:
            // These reducers diff their card inputs and rebuild only when the
            // derived card snapshots can actually change. A periodic PR/status
            // pass that produces the same links must not relayout the board.
            return false
        case .setPaletteOpen, .setDetailExpanded, .setPromptEditorFocused,
             .showDialog, .dismissDialog, .setError, .setNotice, .setLoading, .setIsRefreshingBacklog,
             .launchProgress:
            return false
        case .refreshChannels, .refreshChannelMessages, .channelsLoaded,
             .channelMessagesLoaded, .createChannel, .sendChannelMessage,
             .channelMessageAppended, .markChannelRead, .channelReadStateLoaded,
             .refreshChannelReadState, .setAppFrontmost, .deleteChannel,
             .renameChannel, .reorderChannel, .kickChannelMember, .draftsLoaded,
             .setChannelDraft, .setDMDraft, .loadDrafts,
             .refreshDMMessages, .dmMessagesLoaded, .sendDirectMessage,
             .dmMessageAppended:
            // Channel/DM history, read markers, and drafts are deliberately
            // independent from card layout. Rebuilding cards here was a major
            // source of channel hangs because every JSONL tail reload forced
            // board/sidebar recomputation while chat was rendering.
            return false
        default:
            return true
        }
    }

    /// Dispatch an action. Reducer runs synchronously, effects run async.
    public func dispatch(_ action: Action) {
        #if DEBUG
        let t = CACurrentMediaTime()
        #endif
        let effects = Reducer.reduce(state: state, action: action)
        if Self.needsRebuild(action) { state.rebuildCards() }
        #if DEBUG
        let totalMs = (CACurrentMediaTime() - t) * 1000
        if totalMs > 4 {
            // Use Mirror to get just the action case name without serializing associated values
            let actionName = Mirror(reflecting: action).children.first?.label ?? String(describing: action)
            KanbanCodeLog.info("dispatch-perf", String(format: "dispatch(%@): %.1fms", actionName, totalMs))
        }
        #endif
        for effect in effects {
            Task { [weak self] in
                guard let self else { return }
                await self.effectHandler.execute(effect, dispatch: self.dispatch)
            }
        }

    }

    /// Dispatch an action and wait for all its effects to complete.
    public func dispatchAndWait(_ action: Action) async {
        let effects = Reducer.reduce(state: state, action: action)
        if Self.needsRebuild(action) { state.rebuildCards() }
        await withTaskGroup(of: Void.self) { group in
            for effect in effects {
                group.addTask { [weak self] in
                    guard let self else { return }
                    await self.effectHandler.execute(effect, dispatch: self.dispatch)
                }
            }
        }
    }

    // MARK: - Activity Refresh (fast path)

    /// Lightweight activity-only refresh. Queries the activity detector for all
    /// sessions with hook data and recomputes columns immediately — no discovery,
    /// no worktree scan, no PR fetch. Runs in <1ms.
    public func refreshActivity() async {
        guard let activityDetector else { return }
        if state.sessions.isEmpty {
            // Session discovery has not delivered yet (first reconcile still
            // running); there is nothing to map hook events onto.
            KanbanCodeLog.info("activity", "hook refresh skipped: no sessions yet")
            return
        }
        let activityMap = await currentActivityMap(
            sessions: Array(state.sessions.values),
            detector: activityDetector
        )
        if state.activityMap != activityMap {
            let started = activityMap.filter {
                $0.value == .activelyWorking && state.activityMap[$0.key] != .activelyWorking
            }.keys.map { $0.prefix(8) }.joined(separator: ",")
            let stopped = state.activityMap.filter {
                $0.value == .activelyWorking && activityMap[$0.key] != .activelyWorking
            }.keys.map { $0.prefix(8) }.joined(separator: ",")
            var transitions = ""
            if !started.isEmpty { transitions += " started=[\(started)]" }
            if !stopped.isEmpty { transitions += " stopped=[\(stopped)]" }
            KanbanCodeLog.info("activity", "hook refresh: \(activitySummary(activityMap))\(transitions)")
            dispatch(.activityChanged(activityMap))
        }
    }

    private func currentActivityMap(
        sessions: [Session],
        detector: ActivityDetector
    ) async -> [String: ActivityState] {
        let sessionPaths: [String: String] = Dictionary(
            uniqueKeysWithValues: sessions.compactMap { session in
                guard let path = session.jsonlPath else { return nil }
                return (session.id, path)
            }
        )
        guard !sessionPaths.isEmpty else { return [:] }

        // Poll first to seed per-detector path/mtime caches, then ask for the
        // resolved state so hook-confirmed activity can still win for Claude and Gemini.
        _ = await detector.pollActivity(sessionPaths: sessionPaths)

        var activityMap: [String: ActivityState] = [:]
        for sessionId in sessionPaths.keys {
            let activity = await detector.activityState(for: sessionId)
            if activity != .stale {
                activityMap[sessionId] = activity
            }
        }
        return activityMap
    }

    private func activitySummary(_ activityMap: [String: ActivityState]) -> String {
        let working = activityMap.values.filter { $0 == .activelyWorking }.count
        let needsAttention = activityMap.values.filter { $0 == .needsAttention }.count
        let idle = activityMap.values.filter { $0 == .idleWaiting }.count
        let ended = activityMap.values.filter { $0 == .ended }.count
        return "\(activityMap.count) tracked, \(working) working, \(needsAttention) attention, \(idle) idle, \(ended) ended"
    }

    // MARK: - Eager settings load

    /// Load settings and cached links immediately — populates project list
    /// and cards before the full reconcile finishes.
    public func loadSettingsAndCache() async {
        if let store = settingsStore {
            if let settings = try? await store.read() {
                dispatch(.settingsLoaded(
                    projects: settings.projects,
                    excludedPaths: settings.globalView.excludedPaths,
                    remote: settings.remote,
                    remoteMode: settings.remoteMode,
                    boxd: settings.boxd
                ))
            }
        }
        // Also load cached links so cards appear instantly
        if state.links.isEmpty {
            if let cached = try? await coordinationStore.readLinks(), !cached.isEmpty {
                for link in cached {
                    state.links[link.id] = link
                }
                state.rebuildCards()
            }
        }
    }

    // MARK: - Reconciliation

    /// Full reconciliation: discover sessions, load links, merge, assign columns.
    /// Replaces BoardState.refresh(). The async work happens here; the state mutation
    /// happens atomically via dispatch(.reconciled(...)).
    public func reconcile() async {
        // Skip entirely while the machine sleeps — dark wakes still run timers.
        guard !isSystemSleeping else { return }
        // Prevent concurrent reconciliation — overlapping calls create orphan cards
        // with different IDs from the same data.
        guard !isReconciling else { return }
        isReconciling = true
        defer { isReconciling = false }

        // Only show loading indicator on first reconcile, not periodic refreshes
        if state.links.isEmpty { dispatch(.setLoading(true)) }
        let reconcileStart = ContinuousClock.now

        do {
            // Use in-memory settings (loaded at startup, updated via .settingsLoaded action)
            // Fall back to reading from disk if settings haven't been loaded yet
            var configuredProjects = state.configuredProjects
            var excludedPaths = state.excludedPaths
            var globalRemoteSettings = state.globalRemoteSettings
            if configuredProjects.isEmpty, let store = settingsStore {
                if let settings = try? await store.read() {
                    configuredProjects = settings.projects
                    excludedPaths = settings.globalView.excludedPaths
                    globalRemoteSettings = settings.remote
                    dispatch(.settingsLoaded(
                        projects: configuredProjects,
                        excludedPaths: excludedPaths,
                        remote: globalRemoteSettings,
                        remoteMode: settings.remoteMode,
                        boxd: settings.boxd
                    ))
                }
            }

            // Show cached data immediately while discovery runs
            if state.links.isEmpty {
                let t = ContinuousClock.now
                let cached = try await coordinationStore.readLinks()
                if !cached.isEmpty {
                    for link in cached {
                        state.links[link.id] = link
                    }
                }
                KanbanCodeLog.info("reconcile", "cached links: \(t.duration(to: .now)) (\(cached.count) links)")
            }

            // Fast tmux liveness pass. The full pass below can spend a long
            // time in session discovery and gh PR lookups before it reaches
            // the tmux scan (a minute or more at cold start), and the
            // isReconciling guard keeps other reconciles out meanwhile.
            // After a reboot every cached tmux link is stale, so clear dead
            // ones up front — otherwise cards keep offering a terminal whose
            // attach fails in the pane until the first full pass lands.
            if let tmuxAdapter, let live = try? await tmuxAdapter.listSessions() {
                dispatch(.tmuxLivenessScanned(live: Set(live.map(\.name))))
            }

            let t1 = ContinuousClock.now
            let allSessions = try await discovery.discoverSessions()
            let sessions = allSessions.filter { !state.deletedSessionIds.contains($0.id) }
            KanbanCodeLog.info("reconcile", "discoverSessions: \(t1.duration(to: .now)) (\(sessions.count) sessions)")

            // Use in-memory state as source of truth — NOT disk.
            var existingLinks = Array(state.links.values)

            // Deduplicate repo roots — multiple projects can share the same repo
            let uniqueRepoRoots = Set(configuredProjects.map(\.effectiveRepoRoot))

            // Scan worktrees once per unique repo (parallel, with fingerprint caching)
            var worktreesByRepo: [String: [Worktree]] = [:]
            if let worktreeAdapter {
                let t = ContinuousClock.now

                // Re-scan when EITHER the parent dir mtime OR any worktree's HEAD
                // mtime changed since last cache. The parent catches add/remove,
                // the HEAD piece catches `git checkout -b` inside a worktree.
                var reposToScan: [String] = []
                var fingerprints: [String: WorktreeCacheFingerprint] = [:]
                for repoRoot in uniqueRepoRoots {
                    let fp = WorktreeCacheFingerprint.capture(repoRoot: repoRoot)
                    fingerprints[repoRoot] = fp
                    if let cached = worktreeCache[repoRoot], cached.fingerprint == fp {
                        worktreesByRepo[repoRoot] = cached.worktrees
                    } else {
                        reposToScan.append(repoRoot)
                    }
                }

                if !reposToScan.isEmpty {
                    let results = await withTaskGroup(of: (String, [Worktree])?.self) { group in
                        for repoRoot in reposToScan {
                            group.addTask {
                                guard let worktrees = try? await worktreeAdapter.listWorktrees(repoRoot: repoRoot) else {
                                    return nil
                                }
                                return (repoRoot, worktrees)
                            }
                        }
                        var collected: [(String, [Worktree])] = []
                        for await result in group {
                            if let result { collected.append(result) }
                        }
                        return collected
                    }
                    for (repo, worktrees) in results {
                        // Re-capture in case HEAD mtime changed during the scan;
                        // otherwise we'd cache a fingerprint older than the
                        // worktree data we just read and miss the next change.
                        let fp = WorktreeCacheFingerprint.capture(repoRoot: repo)
                        worktreeCache[repo] = (fingerprint: fp, worktrees: worktrees)
                        worktreesByRepo[repo] = worktrees
                    }
                }
                // Evict repos no longer configured
                worktreeCache = worktreeCache.filter { uniqueRepoRoots.contains($0.key) }

                let total = worktreesByRepo.values.flatMap { $0 }.count
                KanbanCodeLog.info("reconcile", "worktrees: \(t.duration(to: .now)) (\(total) across \(uniqueRepoRoots.count) repos, \(reposToScan.count) scanned)")
            }

            // Incremental branch scan for watermarked cards.
            // Reads bottom-up from EOF to watermark — stops at the most recent push.
            for i in existingLinks.indices {
                guard let watermark = existingLinks[i].manualOverrides.branchWatermark,
                      let sessionPath = existingLinks[i].sessionLink?.sessionPath else { continue }
                let attrs = try? FileManager.default.attributesOfItem(atPath: sessionPath)
                let fileSize = (attrs?[.size] as? Int) ?? 0
                guard fileSize > watermark else { continue }
                if let latest = try? await JsonlParser.extractLatestPushedBranch(
                    from: sessionPath, stopAtOffset: watermark
                ) {
                    existingLinks[i].discoveredBranches = [latest.branch]
                    if let repo = latest.repoPath, repo != existingLinks[i].projectPath {
                        existingLinks[i].discoveredRepos = [latest.branch: repo]
                    } else {
                        existingLinks[i].discoveredRepos = nil
                    }
                }
                existingLinks[i].manualOverrides.branchWatermark = fileSize
            }

            // Automatic branch discovery for recently active in-progress cards.
            // This intentionally scans at most one card per pass and is throttled
            // separately from PR refresh. Manual "Discover Branches and PRs" still
            // does the full eager scan for a single card.
            var earlyActivityMap: [String: ActivityState] = [:]
            if let activityDetector {
                earlyActivityMap = await currentActivityMap(
                    sessions: sessions,
                    detector: activityDetector
                )
            }
            await autoDiscoverBranchesForRecentlyActiveCards(
                links: &existingLinks,
                activityMap: earlyActivityMap
            )

            // Collect branches + PR numbers that can still change. Finished
            // cards' merged PRs never move again, and looking them all up made
            // one pass take minutes across a hundred repos.
            let refreshScope = PRRefreshScope.collect(links: existingLinks)
            let branchesByRepo = refreshScope.branchesByRepo
            let prNumbersByRepo = refreshScope.prNumbersByRepo
            let prNumbersByRepoKey = refreshScope.prNumbersByRepoKey
            let lookupDirForRepoKey = refreshScope.lookupDirForRepoKey

            // PR data comes from the last completed background fetch. The
            // fetch can take minutes on a cold gh cache, and running it inline
            // held `isReconciling` for that long: no discovery, no activity
            // map, no column moves, and no spinner for a session that had
            // already started working.
            // Throttle: 30s when active, 5min when backgrounded/hidden, 5min after rate limit.
            let ghInterval: Duration = ghRateLimitedUntil > .now ? .seconds(300)
                : appIsActive ? .seconds(30) : .seconds(300)
            let shouldFetchPRs = ContinuousClock.now - lastGHLookup >= ghInterval
            let pullRequests = cachedPRsByBranch  // branch → PR for reconciler
            let prsByRepoAndNumber = cachedPRsByRepoAndNumber  // repo → number → PR
            let prsByRepoKeyAndNumber = cachedPRsByRepoKeyAndNumber  // "host/owner/name" → number → PR
            if let ghAdapter, shouldFetchPRs, prFetchTask == nil {
                lastGHLookup = .now
                prFetchTask = Task { [weak self] in
                    await self?.fetchPRData(
                        ghAdapter: ghAdapter,
                        branchesByRepo: branchesByRepo,
                        prNumbersByRepo: prNumbersByRepo,
                        prNumbersByRepoKey: prNumbersByRepoKey,
                        lookupDirForRepoKey: lookupDirForRepoKey
                    )
                    guard let self else { return }
                    self.prFetchTask = nil
                    // Apply the fresh data right away. If a pass is already
                    // running, its guard skips this call and the refresh
                    // timer applies the cache moments later.
                    await self.reconcile()
                }
            }

            // Scan tmux sessions
            let t2 = ContinuousClock.now
            let tmuxSessions = (try? await tmuxAdapter?.listSessions()) ?? []
            KanbanCodeLog.info("reconcile", "tmux: \(t2.duration(to: .now)) (\(tmuxSessions.count) sessions)")
            if tmuxAdapter != nil {
                let currentNames = Set(tmuxSessions.map(\.name))
                let home = (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code")
                // The disk snapshot covers the first pass of a fresh app run:
                // sessions that died while the app was closed (or died with
                // it) would otherwise vanish with no diff to notice them.
                let previous = lastTmuxSessionNames ?? SessionDeathRecorder.readSnapshot(kanbanHome: home)
                if let previous {
                    let vanished = previous.subtracting(currentNames)
                        .filter { !SessionDeathRecorder.isExpectedDeath($0) }.sorted()
                    if !vanished.isEmpty {
                        KanbanCodeLog.warn("reconcile", "tmux sessions gone since the last pass: \(vanished.joined(separator: ", "))")
                    }
                    if vanished.count >= 2 {
                        SessionDeathRecorder.capture(vanished: vanished, kanbanHome: home)
                    }
                }
                if previous != currentNames {
                    SessionDeathRecorder.writeSnapshot(currentNames, kanbanHome: home)
                }
                lastTmuxSessionNames = currentNames
            }

            // Reconcile — pullRequests map feeds branch→PR matching in the reconciler
            let t3 = ContinuousClock.now
            let connectedMachines = Set(state.remoteMachineStates.filter { $0.value.isConnected }.keys)
            let snapshot = CardReconciler.DiscoverySnapshot(
                sessions: sessions,
                tmuxSessions: tmuxSessions,
                didScanTmux: tmuxAdapter != nil,
                worktrees: worktreesByRepo,
                pullRequests: pullRequests,
                connectedRemoteMachines: connectedMachines
            )
            var mergedLinks = CardReconciler.reconcile(existing: existingLinks, snapshot: snapshot)
            KanbanCodeLog.info("reconcile", "reconciler: \(t3.duration(to: .now)) (\(existingLinks.count) existing → \(mergedLinks.count) merged)")

            // Update existing PR statuses from the by-number results. A pull
            // request is matched by the repository its own URL names, so a
            // card carrying a sibling repository's pull request refreshes it
            // instead of asking its own repository for that number. Cards
            // whose pull request has no URL yet fall back to their project.
            if !prsByRepoKeyAndNumber.isEmpty || !prsByRepoAndNumber.isEmpty {
                for i in mergedLinks.indices {
                    let repoRoot = mergedLinks[i].projectPath
                    for j in mergedLinks[i].prLinks.indices {
                        let number = mergedLinks[i].prLinks[j].number
                        let fromRepoKey = mergedLinks[i].prLinks[j].repoKey
                            .flatMap { prsByRepoKeyAndNumber[$0]?[number] }
                        let fromRoot = repoRoot.flatMap { prsByRepoAndNumber[$0]?[number] }
                        guard let pr = fromRepoKey ?? fromRoot else { continue }
                        mergedLinks[i].prLinks[j].status = pr.status
                        mergedLinks[i].prLinks[j].title = pr.title
                        mergedLinks[i].prLinks[j].url = pr.url
                        mergedLinks[i].prLinks[j].mergeStateStatus = pr.mergeStateStatus
                    }
                }
            }

            // Build activity map — computed here, at the end of the pass, so
            // the dispatched map reflects sessions as they are now. Reusing
            // `earlyActivityMap` shipped a snapshot as old as the pass was
            // long, and a slow pass then turned off the spinner of a session
            // that had started working while the pass ran.
            let t4 = ContinuousClock.now
            var activityMap = earlyActivityMap
            if let activityDetector {
                activityMap = await currentActivityMap(sessions: sessions, detector: activityDetector)
            }
            KanbanCodeLog.info("reconcile", "activityMap: \(t4.duration(to: .now)) (\(activitySummary(activityMap)))")

            // Compute discovered project paths
            let sessionPaths = mergedLinks.map { $0.projectPath }
            let discoveredProjectPaths = ProjectDiscovery.findUnconfiguredPaths(
                sessionPaths: sessionPaths,
                configuredProjects: configuredProjects
            )

            // Dispatch reconciled result — reducer handles all state mutations atomically
            let t5 = ContinuousClock.now
            let result = ReconciliationResult(
                links: mergedLinks,
                sessions: sessions,
                activityMap: activityMap,
                tmuxSessions: Set(tmuxSessions.map(\.name)),
                configuredProjects: configuredProjects,
                excludedPaths: excludedPaths,
                discoveredProjectPaths: discoveredProjectPaths,
                globalRemoteSettings: globalRemoteSettings
            )
            dispatch(.reconciled(result))
            KanbanCodeLog.info("reconcile", "dispatch: \(t5.duration(to: .now))")

            // Fetch GitHub issues if enough time has elapsed
            let t6 = ContinuousClock.now
            await refreshGitHubIssuesIfNeeded()
            KanbanCodeLog.info("reconcile", "gitHubIssues: \(t6.duration(to: .now))")

            KanbanCodeLog.info("reconcile", "TOTAL: \(reconcileStart.duration(to: .now))")
        } catch {
            KanbanCodeLog.info("reconcile", "FAILED after \(reconcileStart.duration(to: .now)): \(error)")
            dispatch(.setError(error.localizedDescription))
            dispatch(.setLoading(false))
        }
    }

    /// Fetch PR data via targeted GraphQL — concurrent across repos (max 5).
    /// Runs as a background task kicked off by reconcile; the results land in
    /// `cachedPRsByBranch`/`cachedPRsByRepoAndNumber` for the next pass.
    private func fetchPRData(
        ghAdapter: GhCliAdapter,
        branchesByRepo: [String: Set<String>],
        prNumbersByRepo: [String: Set<Int>],
        prNumbersByRepoKey: [String: Set<Int>],
        lookupDirForRepoKey: [String: String]
    ) async {
        let t = ContinuousClock.now
        let allRepos = Set(branchesByRepo.keys).union(prNumbersByRepo.keys)

        // Worktrees of one repository are one GitHub repo: group the
        // lookups by remote slug so N worktrees cost one batched query
        // instead of N. Slug resolution is local git plus a cache, so
        // the grouping itself spends no API points.
        let groups = await PRLookupGrouping.group(
            branchesByRepo: branchesByRepo,
            prNumbersByRepo: prNumbersByRepo,
            prNumbersByRepoKey: prNumbersByRepoKey,
            lookupDirForRepoKey: lookupDirForRepoKey,
            slugForRoot: { await ghAdapter.resolveRepoSlug(repoRoot: $0) }
        )

        typealias PRResult = (String, [String: PullRequest], [Int: PullRequest], Bool)
        let results: [PRResult] = await withTaskGroup(of: PRResult.self) { group in
            var pending = 0
            var collected: [PRResult] = []
            for (key, repoRoot) in groups.representativeRoot.sorted(by: { $0.key < $1.key }) {
                let branches = Array(groups.branches[key] ?? [])
                let numbers = Array(groups.numbers[key] ?? [])
                let explicitRepo = groups.explicitRepo[key]

                // Concurrency limit: drain one before adding more
                if pending >= 5, let result = await group.next() {
                    collected.append(result)
                    pending -= 1
                }

                group.addTask {
                    let tBatch = ContinuousClock.now
                    do {
                        let (byBranch, byNumber) = try await ghAdapter.batchPRLookup(
                            repoRoot: repoRoot, branches: branches, prNumbers: numbers,
                            repoOwner: explicitRepo?.owner, repoName: explicitRepo?.name
                        )
                        KanbanCodeLog.info("reconcile", "  batchPRLookup(\(key)): \(tBatch.duration(to: .now)) (\(branches.count) branches, \(numbers.count) PRs)")
                        return (key, byBranch, byNumber, false)
                    } catch is GhCliError {
                        return (key, [:], [:], true)
                    } catch {
                        return (key, [:], [:], false)
                    }
                }
                pending += 1
            }
            for await result in group { collected.append(result) }
            return collected
        }

        var pullRequests: [String: PullRequest] = [:]
        var prsByRepoAndNumber: [String: [Int: PullRequest]] = [:]
        var prsByRepoKeyAndNumber: [String: [Int: PullRequest]] = [:]
        var rateLimitedRepos: Set<String> = []
        for (key, byBranch, byNumber, rateLimited) in results {
            let members = groups.members[key] ?? []
            if rateLimited { rateLimitedRepos.formUnion(members) }
            for (branch, pr) in byBranch {
                pullRequests[branch] = pr
            }
            if !byNumber.isEmpty { prsByRepoKeyAndNumber[key] = byNumber }
            PRLookupGrouping.distribute(
                byNumber: byNumber,
                toMembers: members,
                requestedNumbers: prNumbersByRepo,
                into: &prsByRepoAndNumber
            )
        }
        if !rateLimitedRepos.isEmpty {
            ghRateLimitedUntil = .now + .seconds(300)
            dispatch(.setError("GitHub API rate limit exceeded — pausing PR lookups for 5 minutes"))
        }
        dispatch(.setRateLimitedRepos(rateLimitedRepos))
        cachedPRsByBranch = pullRequests
        cachedPRsByRepoAndNumber = prsByRepoAndNumber
        cachedPRsByRepoKeyAndNumber = prsByRepoKeyAndNumber
        let totalByNumber = prsByRepoKeyAndNumber.values.reduce(0) { $0 + $1.count }
        KanbanCodeLog.info("reconcile", "PR lookup: \(t.duration(to: .now)) (\(pullRequests.count) by branch, \(totalByNumber) by number, \(allRepos.count) repos, background)")
    }

    private func autoDiscoverBranchesForRecentlyActiveCards(
        links: inout [Link],
        activityMap: [String: ActivityState]
    ) async {
        let now = ContinuousClock.now
        guard now - lastAutoBranchDiscovery >= .seconds(120) else { return }

        let recentCutoff = Date.now.addingTimeInterval(-30 * 60)
        var candidates: [(index: Int, activityDate: Date)] = []
        for i in links.indices {
            let link = links[i]
            guard link.column == .inProgress,
                  let session = link.sessionLink,
                  let sessionPath = session.sessionPath,
                  !sessionPath.isEmpty else { continue }

            let activity = activityMap[session.sessionId]
            let lastActivity = link.lastActivity ?? link.updatedAt
            let isRecentlyActive = activity == .activelyWorking || lastActivity >= recentCutoff
            guard isRecentlyActive else { continue }

            if let lastScan = lastAutoBranchDiscoveryByCard[link.id],
               now - lastScan < .seconds(600) {
                continue
            }

            candidates.append((i, lastActivity))
        }

        guard let candidate = candidates.max(by: { $0.activityDate < $1.activityDate }) else { return }
        let i = candidate.index
        let link = links[i]
        guard let sessionPath = link.sessionLink?.sessionPath else { return }

        let scanned: [JsonlParser.DiscoveredBranch]
        do {
            switch link.effectiveAssistant {
            case .claude, .gemini:
                if let latest = try await JsonlParser.extractLatestPushedBranch(from: sessionPath) {
                    scanned = [latest]
                } else {
                    scanned = []
                }
            case .codex:
                scanned = try await CodexSessionParser.extractPushedBranches(from: sessionPath)
            }
        } catch {
            lastAutoBranchDiscovery = now
            lastAutoBranchDiscoveryByCard[link.id] = now
            return
        }

        lastAutoBranchDiscovery = now
        lastAutoBranchDiscoveryByCard[link.id] = now
        lastAutoBranchDiscoveryByCard = lastAutoBranchDiscoveryByCard.filter { cardId, _ in
            links.contains { $0.id == cardId }
        }

        await autoLinkRecordedPR(links: &links, index: i, sessionPath: sessionPath)

        guard !scanned.isEmpty else { return }

        var branches = links[i].discoveredBranches ?? []
        var repos = links[i].discoveredRepos ?? [:]
        for discovered in scanned {
            if !branches.contains(discovered.branch) {
                branches.append(discovered.branch)
            }
            if let repo = discovered.repoPath,
               repo != links[i].projectPath {
                repos[discovered.branch] = repo
            }
        }
        links[i].discoveredBranches = branches
        links[i].discoveredRepos = repos.isEmpty ? nil : repos
        KanbanCodeLog.info(
            "reconcile",
            "auto branch discovery: card=\(link.id.prefix(12)) branches=\(scanned.map(\.branch).joined(separator: ","))"
        )
    }

    /// Link the pull request the session is working on, when its branch is not
    /// one the session pushed.
    ///
    /// Branch scanning covers the pull requests a card opens itself. It cannot
    /// see one that was opened from another worktree or by someone else, which
    /// is what the session's own record of the pull request is for.
    private func autoLinkRecordedPR(links: inout [Link], index: Int, sessionPath: String) async {
        guard let ghAdapter, links[index].effectiveAssistant != .codex else { return }
        guard let discovered = try? await JsonlParser.extractLatestLinkedPR(from: sessionPath),
            let repository = discovered.repository,
            !links[index].prLinks.contains(where: { $0.number == discovered.number }),
            !links[index].manualOverrides.isPRDismissed(discovered.number)
        else { return }

        guard
            let pr = (try? await ghAdapter.fetchPRs(
                repository: repository, numbers: [discovered.number]))?[discovered.number]
        else { return }

        links[index].prLinks.append(PRLink(
            number: pr.number, url: pr.url, status: pr.status, title: pr.title,
            approvalCount: pr.approvalCount > 0 ? pr.approvalCount : nil,
            mergeStateStatus: pr.mergeStateStatus
        ))
        KanbanCodeLog.info(
            "reconcile",
            "auto PR discovery: card=\(links[index].id.prefix(12)) PR #\(pr.number) in \(repository)"
        )
    }

    // MARK: - GitHub Issues

    public func refreshBacklog() async {
        state.lastGitHubRefresh = nil
        dispatch(.setIsRefreshingBacklog(true))
        await refreshGitHubIssues()
        dispatch(.setIsRefreshingBacklog(false))
    }

    private func refreshGitHubIssuesIfNeeded() async {
        guard ghAdapter != nil else { return }
        let interval: TimeInterval
        if let store = settingsStore, let settings = try? await store.read() {
            interval = TimeInterval(settings.github.pollIntervalSeconds)
        } else {
            interval = 300
        }
        if let last = state.lastGitHubRefresh, Date.now.timeIntervalSince(last) < interval {
            return
        }
        await refreshGitHubIssues()
    }

    private func refreshGitHubIssues() async {
        guard let ghAdapter else { return }
        guard let settings = try? await settingsStore?.read() else { return }
        // Use in-memory state as source of truth — same principle as reconcile().
        var links = Array(state.links.values)

        var fetchedIssueKeys: Set<String> = []
        var changed = false

        for project in settings.projects {
            guard let filter = project.githubFilter, !filter.isEmpty else { continue }

            do {
                let issues = try await ghAdapter.fetchIssues(repoRoot: project.effectiveRepoRoot, filter: filter)
                for issue in issues {
                    let key = "\(project.path):\(issue.number)"
                    fetchedIssueKeys.insert(key)

                    let existing = links.first(where: {
                        $0.issueLink?.number == issue.number && $0.projectPath == project.path
                    })
                    if existing == nil {
                        let link = Link(
                            name: "#\(issue.number): \(issue.title)",
                            projectPath: project.path,
                            column: .backlog,
                            source: .githubIssue,
                            issueLink: IssueLink(number: issue.number, url: issue.url, body: issue.body, title: issue.title)
                        )
                        links.append(link)
                        changed = true
                    }
                }
            } catch {
                dispatch(.setError("GitHub: \(error.localizedDescription)"))
            }
        }

        // Remove stale GitHub issue links
        let before = links.count
        links.removeAll { link in
            guard link.source == .githubIssue,
                  link.column == .backlog,
                  let issueNum = link.issueLink?.number,
                  let projPath = link.projectPath else { return false }
            return !fetchedIssueKeys.contains("\(projPath):\(issueNum)")
        }
        if links.count != before { changed = true }

        if changed {
            dispatch(.gitHubIssuesUpdated(links: links))
        } else {
            state.lastGitHubRefresh = Date()
        }
    }
}
