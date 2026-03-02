import Foundation

// MARK: - AppState

/// Single source of truth for the entire board.
/// All mutations go through the Reducer — no direct writes.
public struct AppState: Sendable {
    public var links: [String: Link] = [:]                     // cardId → Link
    public var sessions: [String: Session] = [:]               // sessionId → Session
    public var activityMap: [String: ActivityState] = [:]       // sessionId → activity
    public var tmuxSessions: Set<String> = []                  // live tmux names
    public var selectedCardId: String?
    public var selectedProjectPath: String?
    public var error: String?
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

    // MARK: - Derived

    /// All cards, built from links + sessions + activity.
    public var cards: [KanbanCodeCard] {
        links.values.map { link in
            let session = link.sessionLink.flatMap { sessions[$0.sessionId] }
            let activity = link.sessionLink.flatMap { activityMap[$0.sessionId] }
            return KanbanCodeCard(link: link, session: session, activityState: activity, isBusy: busyCards.contains(link.id))
        }
    }

    /// Cards visible after project filtering.
    public var filteredCards: [KanbanCodeCard] {
        cards.filter { cardMatchesProjectFilter($0) }
    }

    /// Cards for a specific column, sorted by last activity (newest first).
    public func cards(in column: KanbanCodeColumn) -> [KanbanCodeCard] {
        filteredCards.filter { $0.column == column }
            .sorted {
                let t0 = $0.link.lastActivity ?? $0.link.updatedAt
                let t1 = $1.link.lastActivity ?? $1.link.updatedAt
                if t0 != t1 { return t0 > t1 }
                return $0.id < $1.id
            }
    }

    public func cardCount(in column: KanbanCodeColumn) -> Int {
        filteredCards.filter { $0.column == column }.count
    }

    /// The visible columns (non-empty or always-shown).
    public var visibleColumns: [KanbanCodeColumn] {
        let alwaysVisible: [KanbanCodeColumn] = [.backlog, .inProgress, .waiting, .inReview, .done]
        var result = alwaysVisible
        if cardCount(in: .allSessions) > 0 {
            result.append(.allSessions)
        }
        return result
    }

    private func cardMatchesProjectFilter(_ card: KanbanCodeCard) -> Bool {
        guard let selectedPath = selectedProjectPath else {
            return !isExcludedFromGlobalView(card)
        }
        let cardPath = card.link.projectPath ?? card.session?.projectPath
        guard let cardPath else { return false }
        let normalizedCard = ProjectDiscovery.normalizePath(cardPath)
        let normalizedSelected = ProjectDiscovery.normalizePath(selectedPath)
        return normalizedCard == normalizedSelected || normalizedCard.hasPrefix(normalizedSelected + "/")
    }

    private func isExcludedFromGlobalView(_ card: KanbanCodeCard) -> Bool {
        guard !excludedPaths.isEmpty else { return false }
        let cardPath = card.link.projectPath ?? card.session?.projectPath
        guard let cardPath else { return false }
        let normalized = ProjectDiscovery.normalizePath(cardPath)
        for excluded in excludedPaths {
            let normalizedExcluded = ProjectDiscovery.normalizePath(excluded)
            if normalized == normalizedExcluded || normalized.hasPrefix(normalizedExcluded + "/") {
                return true
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
    case archiveCard(cardId: String)
    case deleteCard(cardId: String)
    case selectCard(cardId: String?)
    case unlinkFromCard(cardId: String, linkType: LinkType)
    case killTerminal(cardId: String, sessionName: String)
    case addBranchToCard(cardId: String, branch: String)
    case addIssueLinkToCard(cardId: String, issueNumber: Int)
    case moveCardToProject(cardId: String, projectPath: String)

    // Async completions
    case launchCompleted(cardId: String, tmuxName: String, sessionLink: SessionLink?, worktreeLink: WorktreeLink?, isRemote: Bool)
    case launchFailed(cardId: String, error: String)
    case resumeCompleted(cardId: String, tmuxName: String)
    case resumeFailed(cardId: String, error: String)
    case terminalCreated(cardId: String, tmuxName: String)
    case terminalFailed(cardId: String, error: String)
    case extraTerminalCreated(cardId: String, sessionName: String)

    // Background reconciliation
    case reconciled(ReconciliationResult)
    case gitHubIssuesUpdated(links: [Link])
    case activityChanged([String: ActivityState]) // sessionId → state

    // Busy state (transient spinners)
    case setBusy(cardId: String, busy: Bool)

    // Settings / misc
    case setError(String?)
    case setSelectedProject(String?)
    case setLoading(Bool)
    case setIsRefreshingBacklog(Bool)

    public enum LinkType: Sendable {
        case pr, issue, worktree, tmux
    }
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
    case createTmuxSession(cardId: String, name: String, path: String)
    case killTmuxSession(String) // name
    case killTmuxSessions([String])
    case deleteSessionFile(String) // path
    case cleanupTerminalCache(sessionNames: [String])
    case refreshDiscovery
    case updateSessionIndex(sessionId: String, name: String)
    case moveSessionFile(cardId: String, sessionId: String, oldPath: String, newProjectPath: String)
}

// MARK: - Reducer

/// Pure function: (state, action) → (state', effects).
/// No async. No side effects. Fully testable.
public enum Reducer {
    public static func reduce(state: inout AppState, action: Action) -> [Effect] {
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
            return [.createTmuxSession(cardId: cardId, name: sessionName, path: workDir), .upsertLink(link)]

        case .launchCard(let cardId, _, let projectPath, let worktreeName, _, _):
            guard var link = state.links[cardId] else { return [] }
            let projectName = (projectPath as NSString).lastPathComponent
            let tmuxName = worktreeName != nil
                ? "\(projectName)-\(worktreeName!)"
                : "\(projectName)-\(cardId)"
            link.tmuxLink = TmuxLink(sessionName: tmuxName)
            link.column = .inProgress
            link.isLaunching = true
            link.updatedAt = .now
            state.links[cardId] = link
            state.selectedCardId = cardId
            KanbanCodeLog.info("store", "Launch: card=\(cardId.prefix(12)) tmux=\(tmuxName)")
            return [.upsertLink(link)]

        case .resumeCard(let cardId):
            guard var link = state.links[cardId] else { return [] }
            let sid = link.sessionLink?.sessionId ?? link.id
            let tmuxName = "claude-\(String(sid.prefix(8)))"
            link.tmuxLink = TmuxLink(sessionName: tmuxName)
            link.column = .inProgress
            link.isLaunching = true
            link.updatedAt = .now
            state.links[cardId] = link
            state.selectedCardId = cardId
            KanbanCodeLog.info("store", "Resume: card=\(cardId.prefix(12)) tmux=\(tmuxName)")
            return [.upsertLink(link)]

        case .moveCard(let cardId, let column):
            guard var link = state.links[cardId] else { return [] }
            link.column = column
            link.manualOverrides.column = true
            if column == .allSessions {
                link.manuallyArchived = true
            } else if link.manuallyArchived {
                link.manuallyArchived = false
            }
            link.updatedAt = .now
            state.links[cardId] = link
            return [.upsertLink(link)]

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

        case .archiveCard(let cardId):
            guard var link = state.links[cardId] else { return [] }
            link.manuallyArchived = true
            link.column = .allSessions
            link.updatedAt = .now
            // Kill tmux sessions on archive — user expects cleanup
            var effects: [Effect] = []
            if let tmux = link.tmuxLink {
                effects.append(.killTmuxSessions(tmux.allSessionNames))
                effects.append(.cleanupTerminalCache(sessionNames: tmux.allSessionNames))
                link.tmuxLink = nil
            }
            state.links[cardId] = link
            effects.insert(.upsertLink(link), at: 0)
            return effects

        case .deleteCard(let cardId):
            guard let link = state.links.removeValue(forKey: cardId) else { return [] }
            if state.selectedCardId == cardId { state.selectedCardId = nil }
            // Remember deleted IDs so in-flight reconciliation doesn't re-add them
            state.deletedCardIds.insert(cardId)
            if let sessionId = link.sessionLink?.sessionId {
                state.deletedSessionIds.insert(sessionId)
            }
            var effects: [Effect] = [.removeLink(cardId)]
            if let tmux = link.tmuxLink {
                effects.append(.killTmuxSessions(tmux.allSessionNames))
                effects.append(.cleanupTerminalCache(sessionNames: tmux.allSessionNames))
            }
            if let sessionPath = link.sessionLink?.sessionPath {
                effects.append(.deleteSessionFile(sessionPath))
            }
            return effects

        case .selectCard(let cardId):
            state.selectedCardId = cardId
            return []

        case .unlinkFromCard(let cardId, let linkType):
            guard var link = state.links[cardId] else { return [] }
            switch linkType {
            case .pr:
                link.prLinks = []
                link.manualOverrides.prLink = true
            case .issue:
                link.issueLink = nil
                link.manualOverrides.issueLink = true
            case .worktree:
                link.worktreeLink = nil
                link.manualOverrides.worktreePath = true
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
                // Killing primary session — tear down all terminals
                let allNames = link.tmuxLink?.allSessionNames ?? [sessionName]
                link.tmuxLink = nil
                link.isLaunching = nil
                link.isRemote = false
                link.updatedAt = .now
                state.links[cardId] = link
                return [.killTmuxSessions(allNames), .upsertLink(link), .cleanupTerminalCache(sessionNames: allNames)]
            } else {
                // Killing extra session
                link.tmuxLink?.extraSessions?.removeAll { $0 == sessionName }
                if link.tmuxLink?.extraSessions?.isEmpty == true {
                    link.tmuxLink?.extraSessions = nil
                }
                link.updatedAt = .now
                state.links[cardId] = link
                return [.killTmuxSession(sessionName), .upsertLink(link), .cleanupTerminalCache(sessionNames: [sessionName])]
            }

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

        // MARK: Async Completions

        case .launchCompleted(let cardId, let tmuxName, let sessionLink, let worktreeLink, let isRemote):
            guard var link = state.links[cardId] else { return [] }
            link.tmuxLink = TmuxLink(sessionName: tmuxName)
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

        case .launchFailed(let cardId, let error):
            guard var link = state.links[cardId] else { return [] }
            link.tmuxLink = nil
            link.isLaunching = nil
            link.updatedAt = .now
            state.links[cardId] = link
            state.error = "Launch failed: \(error)"
            return [.upsertLink(link)]

        case .resumeCompleted(let cardId, let tmuxName):
            guard var link = state.links[cardId] else { return [] }
            link.tmuxLink = TmuxLink(sessionName: tmuxName)
            link.isLaunching = nil
            link.lastActivity = .now
            link.updatedAt = .now
            state.links[cardId] = link
            return [.upsertLink(link)]

        case .resumeFailed(let cardId, let error):
            guard var link = state.links[cardId] else { return [] }
            link.tmuxLink = nil
            link.isLaunching = nil
            link.updatedAt = .now
            state.links[cardId] = link
            state.error = "Resume failed: \(error)"
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
            state.error = "Terminal failed: \(error)"
            return [.upsertLink(link)]

        case .extraTerminalCreated(let cardId, _):
            state.busyCards.remove(cardId)
            return []

        // MARK: Background Reconciliation

        case .reconciled(let result):
            state.tmuxSessions = result.tmuxSessions
            state.configuredProjects = result.configuredProjects
            state.excludedPaths = result.excludedPaths
            state.discoveredProjectPaths = result.discoveredProjectPaths
            state.globalRemoteSettings = result.globalRemoteSettings

            // Rebuild sessions map
            state.sessions = Dictionary(
                result.sessions.map { ($0.id, $0) },
                uniquingKeysWith: { a, _ in a }
            )
            state.activityMap = result.activityMap

            // Merge reconciled links using last-writer-wins on updatedAt.
            // Reconciliation takes seconds of async work. Any in-memory changes
            // made during that window (launch, create terminal, move card) have a
            // newer updatedAt than the stale snapshot the reconciler used.
            var mergedLinks = state.links
            var preservedIds: Set<String> = []
            for link in result.links {
                // Skip cards deliberately deleted during this reconciliation cycle
                if state.deletedCardIds.contains(link.id) {
                    continue
                }
                // Skip cards whose session was deliberately deleted
                if let sessionId = link.sessionLink?.sessionId, state.deletedSessionIds.contains(sessionId) {
                    continue
                }
                if let existing = mergedLinks[link.id] {
                    if existing.isLaunching == true {
                        // Check if activity hook has confirmed the session is running
                        let activity = result.activityMap[existing.sessionLink?.sessionId ?? ""]
                        if activity != nil {
                            // Activity detected — clear isLaunching, let column recomputation run
                            var cleared = existing
                            cleared.isLaunching = nil
                            mergedLinks[link.id] = cleared
                            KanbanCodeLog.info("store", "Cleared isLaunching on card=\(link.id.prefix(12)) (activity=\(activity!))")
                            continue
                        }
                        // Stale launch timeout: clear isLaunching after 30s (crash recovery)
                        if Date.now.timeIntervalSince(existing.updatedAt) > 30 {
                            var cleared = link
                            cleared.isLaunching = nil
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
            for (id, var link) in mergedLinks where link.isLaunching != true && !preservedIds.contains(id) {
                let activity = result.activityMap[link.sessionLink?.sessionId ?? ""]
                let hasTmux = link.tmuxLink.map { tmux in
                    // Shell-only terminals don't count as "active work" for column assignment
                    guard tmux.isShellOnly != true else { return false }
                    return tmux.allSessionNames.contains(where: { liveTmuxNames.contains($0) })
                } ?? false
                let hasWorktree = link.worktreeLink?.branch != nil

                // Clear manual column override when we have definitive data
                if link.manualOverrides.column {
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
                    hasWorktree: hasWorktree || hasTmux
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

            state.links = mergedLinks
            state.lastRefresh = Date()
            state.isLoading = false

            // Validate selected card still exists
            if let selectedId = state.selectedCardId,
               !mergedLinks.keys.contains(selectedId) {
                state.selectedCardId = nil
            }

            return [.persistLinks(Array(mergedLinks.values))]

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
                let oldColumn = link.column
                UpdateCardColumn.update(link: &link, activityState: activity, hasWorktree: hasWorktree)
                if link.column != oldColumn {
                    state.links[id] = link
                    changed = true
                }
            }
            state.activityMap = activityMap
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

        case .setError(let message):
            state.error = message
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
}

// MARK: - BoardStore

/// The main store. Replaces BoardState as the single source of truth.
/// All mutations go through dispatch() → Reducer → Effects.
@Observable
@MainActor
public final class BoardStore: @unchecked Sendable {
    public private(set) var state: AppState
    private let effectHandler: EffectHandler
    private var _lastErrorId: UUID?

    // Dependencies for reconciliation
    private var isReconciling = false
    private let discovery: SessionDiscovery
    private let coordinationStore: CoordinationStore
    private let activityDetector: ClaudeCodeActivityDetector?
    private let settingsStore: SettingsStore?
    private let ghAdapter: GhCliAdapter?
    private let worktreeAdapter: GitWorktreeAdapter?
    private let tmuxAdapter: TmuxManagerPort?

    public let sessionStore: SessionStore

    public init(
        effectHandler: EffectHandler,
        discovery: SessionDiscovery,
        coordinationStore: CoordinationStore,
        activityDetector: ClaudeCodeActivityDetector? = nil,
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

    /// Dispatch an action. Reducer runs synchronously, effects run async.
    public func dispatch(_ action: Action) {
        let effects = Reducer.reduce(state: &state, action: action)
        for effect in effects {
            Task { [weak self] in
                guard let self else { return }
                await self.effectHandler.execute(effect, dispatch: self.dispatch)
            }
        }

        // Auto-dismiss errors for certain actions
        switch action {
        case .setError(let msg) where msg != nil:
            let dismissId = UUID()
            _lastErrorId = dismissId
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(8))
                if self?._lastErrorId == dismissId {
                    self?.state.error = nil
                }
            }
        case .launchFailed, .resumeFailed, .terminalFailed:
            let dismissId = UUID()
            _lastErrorId = dismissId
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(8))
                if self?._lastErrorId == dismissId {
                    self?.state.error = nil
                }
            }
        default:
            break
        }
    }

    // MARK: - Activity Refresh (fast path)

    /// Lightweight activity-only refresh. Queries the activity detector for all
    /// sessions with hook data and recomputes columns immediately — no discovery,
    /// no worktree scan, no PR fetch. Runs in <1ms.
    public func refreshActivity() async {
        guard let activityDetector else { return }
        var activityMap: [String: ActivityState] = [:]
        for (_, link) in state.links {
            guard let sessionId = link.sessionLink?.sessionId else { continue }
            let activity = await activityDetector.activityState(for: sessionId)
            activityMap[sessionId] = activity
        }
        if !activityMap.isEmpty {
            dispatch(.activityChanged(activityMap))
        }
    }

    // MARK: - Reconciliation

    /// Full reconciliation: discover sessions, load links, merge, assign columns.
    /// Replaces BoardState.refresh(). The async work happens here; the state mutation
    /// happens atomically via dispatch(.reconciled(...)).
    public func reconcile() async {
        // Prevent concurrent reconciliation — overlapping calls create orphan cards
        // with different IDs from the same data.
        guard !isReconciling else { return }
        isReconciling = true
        defer { isReconciling = false }

        dispatch(.setLoading(true))

        do {
            // Load settings for project filtering
            var configuredProjects: [Project] = []
            var excludedPaths: [String] = []
            var globalRemoteSettings: RemoteSettings?
            if let store = settingsStore {
                let settings = try await store.read()
                configuredProjects = settings.projects
                excludedPaths = settings.globalView.excludedPaths
                globalRemoteSettings = settings.remote
            }

            // Show cached data immediately while discovery runs
            if state.links.isEmpty {
                let cached = try await coordinationStore.readLinks()
                if !cached.isEmpty {
                    for link in cached {
                        state.links[link.id] = link
                    }
                }
            }

            let allSessions = try await discovery.discoverSessions()
            // Filter out sessions the user deliberately deleted
            let sessions = allSessions.filter { !state.deletedSessionIds.contains($0.id) }
            // Use in-memory state as source of truth — NOT disk.
            // Disk reads race with async effect writes, causing duplicates.
            let existingLinks = Array(state.links.values)

            // Deduplicate repo roots — multiple projects can share the same repo
            let uniqueRepoRoots = Set(configuredProjects.map(\.effectiveRepoRoot))

            // Scan worktrees once per unique repo
            var worktreesByRepo: [String: [Worktree]] = [:]
            if let worktreeAdapter {
                for repoRoot in uniqueRepoRoots {
                    if let worktrees = try? await worktreeAdapter.listWorktrees(repoRoot: repoRoot) {
                        worktreesByRepo[repoRoot] = worktrees
                    }
                }
            }

            // Fetch PRs once per unique repo
            var pullRequests: [String: PullRequest] = [:]
            if let ghAdapter {
                for repoRoot in uniqueRepoRoots {
                    if let prs = try? await ghAdapter.fetchPRs(repoRoot: repoRoot) {
                        pullRequests.merge(prs, uniquingKeysWith: { existing, _ in existing })
                    }
                }
            }

            // Scan tmux sessions
            let tmuxSessions = (try? await tmuxAdapter?.listSessions()) ?? []

            // Reconcile
            let snapshot = CardReconciler.DiscoverySnapshot(
                sessions: sessions,
                tmuxSessions: tmuxSessions,
                didScanTmux: tmuxAdapter != nil,
                worktrees: worktreesByRepo,
                pullRequests: pullRequests
            )
            var mergedLinks = CardReconciler.reconcile(existing: existingLinks, snapshot: snapshot)

            // Post-reconciliation: targeted PR discovery via batched GraphQL
            if let ghAdapter {
                let coveredBranches = Set(pullRequests.keys)
                let coveredPRNumbers = Set(pullRequests.values.map(\.number))

                var branchesByRepo: [String: [(index: Int, branch: String)]] = [:]
                var prNumbersByRepo: [String: [(index: Int, prIndex: Int, number: Int)]] = [:]

                for i in mergedLinks.indices {
                    let link = mergedLinks[i]
                    guard !link.manuallyArchived else { continue }
                    guard let repoRoot = link.projectPath, !repoRoot.isEmpty else { continue }

                    if let branch = link.worktreeLink?.branch, link.prLinks.isEmpty, !coveredBranches.contains(branch) {
                        branchesByRepo[repoRoot, default: []].append((index: i, branch: branch))
                    }
                    for j in link.prLinks.indices {
                        let prNumber = link.prLinks[j].number
                        if !coveredPRNumbers.contains(prNumber) {
                            prNumbersByRepo[repoRoot, default: []].append((index: i, prIndex: j, number: prNumber))
                        }
                    }
                }

                let allRepos = Set(branchesByRepo.keys).union(prNumbersByRepo.keys)
                for repoRoot in allRepos {
                    let branches = (branchesByRepo[repoRoot] ?? []).map(\.branch)
                    let numbers = (prNumbersByRepo[repoRoot] ?? []).map(\.number)
                    guard !branches.isEmpty || !numbers.isEmpty else { continue }

                    let (byBranch, byNumber) = (try? await ghAdapter.batchPRLookup(repoRoot: repoRoot, branches: branches, prNumbers: numbers)) ?? ([:], [:])

                    for entry in branchesByRepo[repoRoot] ?? [] {
                        if let pr = byBranch[entry.branch] {
                            mergedLinks[entry.index].prLinks.append(PRLink(number: pr.number, url: pr.url, status: pr.status, title: pr.title))
                        }
                    }
                    for entry in prNumbersByRepo[repoRoot] ?? [] {
                        if let pr = byNumber[entry.number] {
                            mergedLinks[entry.index].prLinks[entry.prIndex].status = pr.status
                            mergedLinks[entry.index].prLinks[entry.prIndex].title = pr.title
                            mergedLinks[entry.index].prLinks[entry.prIndex].url = pr.url
                        }
                    }
                }
            }

            // Build activity map
            var activityMap: [String: ActivityState] = [:]
            for link in mergedLinks {
                if let sessionId = link.sessionLink?.sessionId {
                    if let activity = await activityDetector?.activityState(for: sessionId) {
                        activityMap[sessionId] = activity
                    }
                }
            }

            // Compute discovered project paths
            let sessionPaths = mergedLinks.map { $0.projectPath }
            let discoveredProjectPaths = ProjectDiscovery.findUnconfiguredPaths(
                sessionPaths: sessionPaths,
                configuredProjects: configuredProjects
            )

            // Dispatch reconciled result — reducer handles all state mutations atomically
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

            // Fetch GitHub issues if enough time has elapsed
            await refreshGitHubIssuesIfNeeded()
        } catch {
            dispatch(.setError(error.localizedDescription))
            dispatch(.setLoading(false))
        }
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

        let defaultFilter = settings.github.defaultFilter
        var fetchedIssueKeys: Set<String> = []
        var changed = false

        for project in settings.projects {
            let filter = project.githubFilter ?? defaultFilter
            guard !filter.isEmpty else { continue }

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
