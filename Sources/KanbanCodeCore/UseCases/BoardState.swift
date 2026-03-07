import Foundation

/// A card on the Kanban board, combining Link + Session data for display.
public struct KanbanCodeCard: Identifiable, Sendable {
    public let id: String // link.id — stable across refreshes
    public let link: Link
    public let session: Session?
    public let activityState: ActivityState?
    /// True when an async operation is in progress on this card
    /// (terminal creating, worktree cleanup, PR discovery).
    public let isBusy: Bool
    /// True when this card's repo is affected by GitHub API rate limiting.
    public let isRateLimited: Bool

    public init(link: Link, session: Session? = nil, activityState: ActivityState? = nil, isBusy: Bool = false, isRateLimited: Bool = false) {
        self.id = link.id
        self.link = link
        self.session = session
        self.activityState = activityState
        self.isBusy = isBusy
        self.isRateLimited = isRateLimited
    }

    /// Whether Claude is confirmed actively working right now (not just waiting).
    public var isActivelyWorking: Bool {
        activityState == .activelyWorking
    }

    /// Whether to show a spinner on the card.
    public var showSpinner: Bool {
        isActivelyWorking || link.isLaunching == true || isBusy
    }

    /// Best display title: link name → session display title → link fallback chain.
    public var displayTitle: String {
        if let name = link.name, !name.isEmpty { return name }
        if let session { return session.displayTitle }
        return link.displayTitle
    }

    /// Project name extracted from project path.
    public var projectName: String? {
        guard let path = link.projectPath ?? session?.projectPath else { return nil }
        return (path as NSString).lastPathComponent
    }

    /// Relative time since last activity.
    public var relativeTime: String {
        let date = link.lastActivity ?? link.updatedAt
        return Self.formatRelativeTime(date)
    }

    /// The column this card is in.
    public var column: KanbanCodeColumn { link.column }

    static func formatRelativeTime(_ date: Date) -> String {
        let interval = Date.now.timeIntervalSince(date)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        let days = Int(interval / 86400)
        if days == 1 { return "yesterday" }
        if days < 30 { return "\(days)d ago" }
        return "\(days / 30)mo ago"
    }
}

/// Observable state for the Kanban board.
/// Holds all cards grouped by column, handles refresh from discovery + coordination.
@Observable
public final class BoardState: @unchecked Sendable {
    public var cards: [KanbanCodeCard] = []
    public var selectedCardId: String?
    public var isLoading: Bool = false
    public var lastRefresh: Date?
    public var error: String?

    /// Currently selected project path (nil = global/All Projects view).
    public var selectedProjectPath: String?

    /// Project paths discovered from sessions but not yet configured.
    public var discoveredProjectPaths: [String] = []

    /// Configured projects (refreshed from settings on each refresh).
    public var configuredProjects: [Project] = []

    /// Cached excluded paths for global view (refreshed from settings).
    private var excludedPaths: [String] = []

    /// Last time GitHub issues were fetched.
    public var lastGitHubRefresh: Date?

    /// Whether a GitHub issue refresh is currently running.
    public var isRefreshingBacklog = false

    private let discovery: SessionDiscovery
    private let coordinationStore: CoordinationStore
    private let activityDetector: ClaudeCodeActivityDetector?
    private let settingsStore: SettingsStore?
    private let ghAdapter: GhCliAdapter?
    private let worktreeAdapter: GitWorktreeAdapter?
    private let tmuxAdapter: TmuxAdapter?
    public let sessionStore: SessionStore

    public init(
        discovery: SessionDiscovery,
        coordinationStore: CoordinationStore,
        activityDetector: ClaudeCodeActivityDetector? = nil,
        settingsStore: SettingsStore? = nil,
        ghAdapter: GhCliAdapter? = nil,
        worktreeAdapter: GitWorktreeAdapter? = nil,
        tmuxAdapter: TmuxAdapter? = TmuxAdapter(),
        sessionStore: SessionStore = ClaudeCodeSessionStore()
    ) {
        self.discovery = discovery
        self.coordinationStore = coordinationStore
        self.activityDetector = activityDetector
        self.settingsStore = settingsStore
        self.ghAdapter = ghAdapter
        self.worktreeAdapter = worktreeAdapter
        self.tmuxAdapter = tmuxAdapter
        self.sessionStore = sessionStore
    }

    /// Cards visible after project filtering.
    public var filteredCards: [KanbanCodeCard] {
        cards.filter { cardMatchesProjectFilter($0) }
    }

    /// Cards for a specific column, sorted by manual sortOrder then last activity (newest first).
    public func cards(in column: KanbanCodeColumn) -> [KanbanCodeCard] {
        filteredCards.filter { $0.column == column }
            .sorted {
                // Cards with sortOrder come first, ordered by sortOrder ascending
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

    /// Count of cards in a column.
    public func cardCount(in column: KanbanCodeColumn) -> Int {
        filteredCards.filter { $0.column == column }.count
    }

    /// Check if a card matches the current project filter.
    private func cardMatchesProjectFilter(_ card: KanbanCodeCard) -> Bool {
        guard let selectedPath = selectedProjectPath else {
            // Global view — apply exclusions
            return !isExcludedFromGlobalView(card)
        }
        // Project view — match by project path
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
        if let range = normalizedCard.range(of: "/.claude/worktrees/") {
            let repoRoot = String(normalizedCard[..<range.lowerBound])
            if normalizedSelected == repoRoot || normalizedSelected.hasPrefix(repoRoot + "/") {
                return true
            }
        }

        return false
    }

    /// Check if a card should be excluded from the global view.
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

    /// The visible columns (non-empty or always-shown).
    public var visibleColumns: [KanbanCodeColumn] {
        // Always show the main workflow columns; show allSessions only if it has cards
        let alwaysVisible: [KanbanCodeColumn] = [.backlog, .inProgress, .waiting, .inReview, .done]
        var result = alwaysVisible
        if cardCount(in: .allSessions) > 0 {
            result.append(.allSessions)
        }
        return result
    }

    /// Add a new card to the board immediately (synchronous, no disk round-trip).
    /// Caller should persist via coordinationStore.upsertLink() separately.
    public func addCard(link: Link) {
        let card = KanbanCodeCard(link: link)
        cards.append(card)
    }

    /// Update a card's in-memory state for an active launch.
    /// Sets tmuxLink + column to .inProgress. Does NOT persist — caller handles persistence.
    public func updateCardForLaunch(cardId: String, tmuxName: String, isShellOnly: Bool = false) {
        guard let index = cards.firstIndex(where: { $0.id == cardId }) else { return }
        var link = cards[index].link
        link.tmuxLink = TmuxLink(sessionName: tmuxName, isShellOnly: isShellOnly)
        link.column = .inProgress
        link.updatedAt = .now
        let session = cards[index].session
        let activity = cards[index].activityState
        cards[index] = KanbanCodeCard(link: link, session: session, activityState: activity)
    }

    /// Rename a card (manual override).
    public func renameCard(cardId: String, name: String) {
        guard let index = cards.firstIndex(where: { $0.id == cardId }) else { return }
        var link = cards[index].link
        link.name = name
        link.manualOverrides.name = true
        link.updatedAt = .now
        let session = cards[index].session
        let activity = cards[index].activityState
        cards[index] = KanbanCodeCard(link: link, session: session, activityState: activity)

        Task {
            // Persist to our coordination store
            try? await coordinationStore.upsertLink(link)
            // Also update Claude's sessions-index.json so other tools see the rename
            if let sessionId = link.sessionLink?.sessionId {
                try? SessionIndexReader.updateSummary(sessionId: sessionId, summary: name)
            }
        }
    }

    /// Archive a card — sets manuallyArchived and moves to allSessions.
    public func archiveCard(cardId: String) {
        guard let index = cards.firstIndex(where: { $0.id == cardId }) else { return }
        var link = cards[index].link
        link.manuallyArchived = true
        link.column = .allSessions
        link.updatedAt = .now
        let session = cards[index].session
        let activity = cards[index].activityState
        cards[index] = KanbanCodeCard(link: link, session: session, activityState: activity)

        Task {
            try? await coordinationStore.upsertLink(link)
        }
    }

    /// Delete a card permanently (manual tasks or orphan cards with no active links).
    /// Delete a card, removing it from the board and coordination store.
    /// Returns the link for cleanup (tmux kill, jsonl delete) by the caller.
    @discardableResult
    public func deleteCard(cardId: String) -> Link? {
        guard let index = cards.firstIndex(where: { $0.id == cardId }) else { return nil }
        let link = cards[index].link
        cards.remove(at: index)
        if selectedCardId == cardId { selectedCardId = nil }

        Task {
            try? await coordinationStore.removeLink(id: link.id)
        }
        return link
    }

    /// Reorder a card within its column by placing it above or below a target card.
    public func reorderCard(cardId: String, targetCardId: String, above: Bool) {
        guard let draggedIndex = cards.firstIndex(where: { $0.id == cardId }) else { return }
        let column = cards[draggedIndex].link.column
        var columnCards = self.cards(in: column)

        // Remove the dragged card
        columnCards.removeAll { $0.id == cardId }

        // Find insertion index
        let insertIndex: Int
        if let targetIdx = columnCards.firstIndex(where: { $0.id == targetCardId }) {
            insertIndex = above ? targetIdx : targetIdx + 1
        } else {
            insertIndex = columnCards.count
        }
        columnCards.insert(cards[draggedIndex], at: insertIndex)

        // Assign sortOrder and persist
        for (i, card) in columnCards.enumerated() {
            guard let idx = cards.firstIndex(where: { $0.id == card.id }) else { continue }
            var link = cards[idx].link
            link.sortOrder = i
            let session = cards[idx].session
            let activity = cards[idx].activityState
            cards[idx] = KanbanCodeCard(link: link, session: session, activityState: activity)

            Task {
                try? await coordinationStore.upsertLink(link)
            }
        }
    }

    /// Move a card to a different column (manual override — e.g. user drag).
    public func moveCard(cardId: String, to column: KanbanCodeColumn) {
        setCardColumn(cardId: cardId, to: column, manualOverride: true)
    }

    /// Set a card's column programmatically (no manual override — auto-assignment can still take over).
    public func setCardColumn(cardId: String, to column: KanbanCodeColumn, manualOverride: Bool = false) {
        guard let index = cards.firstIndex(where: { $0.id == cardId }) else { return }
        var link = cards[index].link
        link.column = column
        if manualOverride {
            link.manualOverrides.column = true
            // Dragging to allSessions = archive; dragging out = unarchive
            if column == .allSessions {
                link.manuallyArchived = true
            } else if link.manuallyArchived {
                link.manuallyArchived = false
            }
        }
        link.updatedAt = .now
        let session = cards[index].session
        let activity = cards[index].activityState
        cards[index] = KanbanCodeCard(link: link, session: session, activityState: activity)

        Task {
            try? await coordinationStore.upsertLink(link)
        }
    }

    /// Remove a typed link from a card (e.g. unlink PR or issue).
    public enum LinkType: Sendable {
        case pr(number: Int), issue, worktree, tmux
    }

    public func unlinkFromCard(cardId: String, linkType: LinkType) {
        guard let index = cards.firstIndex(where: { $0.id == cardId }) else { return }
        var link = cards[index].link
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
            if let path = link.sessionLink?.sessionPath {
                let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
                link.manualOverrides.branchWatermark = size
            } else {
                link.manualOverrides.branchWatermark = 0
            }
            link.discoveredBranches = nil
            link.worktreeLink = nil
        case .tmux:
            link.tmuxLink = nil
            link.manualOverrides.tmuxSession = true
        }
        link.updatedAt = .now
        let session = cards[index].session
        let activity = cards[index].activityState
        cards[index] = KanbanCodeCard(link: link, session: session, activityState: activity)

        Task {
            try? await coordinationStore.upsertLink(link)
        }
    }

    /// Add a worktree/branch link to a card manually.
    public func addBranchToCard(cardId: String, branch: String) {
        guard let index = cards.firstIndex(where: { $0.id == cardId }) else { return }
        var link = cards[index].link
        if link.worktreeLink != nil {
            link.worktreeLink?.branch = branch
        } else {
            link.worktreeLink = WorktreeLink(path: "", branch: branch)
        }
        link.manualOverrides.worktreePath = true
        link.updatedAt = .now
        let session = cards[index].session
        let activity = cards[index].activityState
        cards[index] = KanbanCodeCard(link: link, session: session, activityState: activity)

        Task {
            try? await coordinationStore.upsertLink(link)
        }
    }

    public func addIssueLinkToCard(cardId: String, issueNumber: Int) {
        guard let index = cards.firstIndex(where: { $0.id == cardId }) else { return }
        var link = cards[index].link
        link.issueLink = IssueLink(number: issueNumber)
        link.manualOverrides.issueLink = true
        link.updatedAt = .now
        let session = cards[index].session
        let activity = cards[index].activityState
        cards[index] = KanbanCodeCard(link: link, session: session, activityState: activity)

        Task {
            try? await coordinationStore.upsertLink(link)
        }
    }

    /// Set an error message that auto-dismisses after a delay.
    public func setError(_ message: String, autoDismissSeconds: Double = 8) {
        error = message
        let dismissId = UUID()
        _lastErrorId = dismissId
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(autoDismissSeconds))
            if _lastErrorId == dismissId {
                error = nil
            }
        }
    }
    private var _lastErrorId: UUID?

    /// Full refresh: discover sessions, load links, merge, assign columns.
    public func refresh() async {
        isLoading = true

        do {
            // Load settings for project filtering
            if let store = settingsStore {
                let settings = try await store.read()
                configuredProjects = settings.projects
                excludedPaths = settings.globalView.excludedPaths
            }

            // Show cached data immediately while discovery runs
            if cards.isEmpty {
                let cached = try await coordinationStore.readLinks()
                if !cached.isEmpty {
                    cards = cached.map { KanbanCodeCard(link: $0) }
                }
            }

            let sessions = try await discovery.discoverSessions()
            let existingLinks = try await coordinationStore.readLinks()
            let sessionsById = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

            // Scan worktrees for each configured project
            var worktreesByRepo: [String: [Worktree]] = [:]
            if let worktreeAdapter {
                for project in configuredProjects {
                    let repoRoot = project.effectiveRepoRoot
                    if let worktrees = try? await worktreeAdapter.listWorktrees(repoRoot: repoRoot) {
                        worktreesByRepo[repoRoot] = worktrees
                        KanbanCodeLog.info("refresh", "Scanned \(worktrees.count) worktrees for \(repoRoot)")
                    }
                }
            }

            // Fetch PRs for each configured project (basic metadata for branch matching)
            var pullRequests: [String: PullRequest] = [:]
            if let ghAdapter {
                for project in configuredProjects {
                    let repoRoot = project.effectiveRepoRoot
                    if let prs = try? await ghAdapter.fetchPRs(repoRoot: repoRoot) {
                        for (branch, pr) in prs {
                            KanbanCodeLog.info("refresh", "PR #\(pr.number) [\(pr.state)] on branch \(branch) — \(pr.title)")
                        }
                        pullRequests.merge(prs, uniquingKeysWith: { existing, _ in existing })
                    }
                }
            }

            // Scan tmux sessions (to detect dead links)
            let tmuxSessions = (try? await tmuxAdapter?.listSessions()) ?? []

            // Reconcile: match sessions/worktrees/PRs to existing cards
            let snapshot = CardReconciler.DiscoverySnapshot(
                sessions: sessions,
                tmuxSessions: tmuxSessions,
                didScanTmux: tmuxAdapter != nil,
                worktrees: worktreesByRepo,
                pullRequests: pullRequests
            )
            var mergedLinks = CardReconciler.reconcile(existing: existingLinks, snapshot: snapshot)
            KanbanCodeLog.info("refresh", "Reconciled: \(existingLinks.count) existing → \(mergedLinks.count) merged (\(sessions.count) sessions, \(worktreesByRepo.values.flatMap { $0 }.count) worktrees, \(pullRequests.count) PRs)")

            // Post-reconciliation: targeted PR discovery + status refresh via batched GraphQL
            if let ghAdapter {
                let coveredBranches = Set(pullRequests.keys)
                let coveredPRNumbers = Set(pullRequests.values.map(\.number))

                // Group lookups by repo for batching
                var branchesByRepo: [String: [(index: Int, branch: String)]] = [:]
                var prNumbersByRepo: [String: [(index: Int, prIndex: Int, number: Int)]] = [:]

                for i in mergedLinks.indices {
                    let link = mergedLinks[i]
                    guard !link.manuallyArchived else { continue }
                    guard let repoRoot = link.projectPath, !repoRoot.isEmpty else { continue }

                    if let branch = link.worktreeLink?.branch, link.prLinks.isEmpty, !coveredBranches.contains(branch) {
                        branchesByRepo[repoRoot, default: []].append((index: i, branch: branch))
                    }
                    // Also look up PRs for discovered branches (from git push scanning)
                    if link.prLinks.isEmpty, let discovered = link.discoveredBranches {
                        for branch in discovered where !coveredBranches.contains(branch) {
                            branchesByRepo[repoRoot, default: []].append((index: i, branch: branch))
                        }
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

                    KanbanCodeLog.info("refresh", "Batch PR lookup for \(repoRoot): \(branches.count) branches, \(numbers.count) PRs to refresh")
                    let (byBranch, byNumber) = (try? await ghAdapter.batchPRLookup(repoRoot: repoRoot, branches: branches, prNumbers: numbers)) ?? ([:], [:])

                    for entry in branchesByRepo[repoRoot] ?? [] {
                        if let pr = byBranch[entry.branch] {
                            mergedLinks[entry.index].prLinks.append(PRLink(number: pr.number, url: pr.url, status: pr.status, title: pr.title, mergeStateStatus: pr.mergeStateStatus))
                            KanbanCodeLog.info("refresh", "Discovered PR #\(pr.number) [\(pr.status)] for branch=\(entry.branch)")
                        }
                    }
                    for entry in prNumbersByRepo[repoRoot] ?? [] {
                        if let pr = byNumber[entry.number] {
                            mergedLinks[entry.index].prLinks[entry.prIndex].status = pr.status
                            mergedLinks[entry.index].prLinks[entry.prIndex].title = pr.title
                            mergedLinks[entry.index].prLinks[entry.prIndex].url = pr.url
                            mergedLinks[entry.index].prLinks[entry.prIndex].mergeStateStatus = pr.mergeStateStatus
                            if pr.approvalCount > 0 {
                                mergedLinks[entry.index].prLinks[entry.prIndex].approvalCount = pr.approvalCount
                            }
                            KanbanCodeLog.info("refresh", "Refreshed PR #\(entry.number) → \(pr.status)")
                        }
                    }
                }
            }

            // Recalculate columns: f(state) = column
            // Column is a derived property, not stored state — always recompute.
            let liveTmuxNames = Set(tmuxSessions.map(\.name))
            var newCards: [KanbanCodeCard] = []
            for i in mergedLinks.indices {
                let sessionId = mergedLinks[i].sessionLink?.sessionId ?? mergedLinks[i].id
                let activity = await activityDetector?.activityState(for: sessionId)
                let hasWorktree = mergedLinks[i].worktreeLink?.branch != nil
                let hasTmux = mergedLinks[i].tmuxLink.map { tmux in
                    tmux.allSessionNames.contains(where: { liveTmuxNames.contains($0) })
                } ?? false
                let oldColumn = mergedLinks[i].column
                UpdateCardColumn.update(link: &mergedLinks[i], activityState: activity, hasWorktree: hasWorktree || hasTmux)
                if mergedLinks[i].column != oldColumn {
                    let sessionIdStr = mergedLinks[i].sessionLink.map { String($0.sessionId.prefix(8)) } ?? "nil"
                    KanbanCodeLog.info("refresh", "Column changed for \(mergedLinks[i].id.prefix(12)): \(oldColumn) → \(mergedLinks[i].column) (activity=\(activity.map { "\($0)" } ?? "nil"), hasWorktree=\(hasWorktree), hasTmux=\(hasTmux), source=\(mergedLinks[i].source), tmux=\(mergedLinks[i].tmuxLink?.sessionName ?? "nil"), session=\(sessionIdStr))")
                }
                // Copy session's firstPrompt into link.promptBody so notifications can use it
                if mergedLinks[i].promptBody == nil,
                   let session = mergedLinks[i].sessionLink.flatMap({ sessionsById[$0.sessionId] }),
                   let firstPrompt = session.firstPrompt, !firstPrompt.isEmpty {
                    mergedLinks[i].promptBody = firstPrompt
                }

                newCards.append(KanbanCodeCard(
                    link: mergedLinks[i],
                    session: mergedLinks[i].sessionLink.flatMap { sessionsById[$0.sessionId] },
                    activityState: activity
                ))
            }

            cards = newCards
            lastRefresh = Date()

            // Compute discovered project paths
            let sessionPaths = newCards.map { $0.link.projectPath ?? $0.session?.projectPath }
            discoveredProjectPaths = ProjectDiscovery.findUnconfiguredPaths(
                sessionPaths: sessionPaths,
                configuredProjects: configuredProjects
            )

            // Persist recalculated columns + merged links (atomic merge to avoid overwriting concurrent additions)
            let mergedById = Dictionary(mergedLinks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            try? await coordinationStore.modifyLinks { freshLinks in
                // Update existing links with reconciled data
                for i in freshLinks.indices {
                    if let merged = mergedById[freshLinks[i].id] {
                        freshLinks[i] = merged
                    }
                }
                // Add newly discovered links that don't exist in the store yet
                let freshIds = Set(freshLinks.map(\.id))
                for link in mergedLinks where !freshIds.contains(link.id) {
                    freshLinks.append(link)
                }
            }

            // Fetch GitHub issues if enough time has elapsed
            await refreshGitHubIssuesIfNeeded()

            // Validate selected card still exists
            if let selectedId = selectedCardId,
               !newCards.contains(where: { $0.id == selectedId }) {
                selectedCardId = nil
            }
        } catch {
            setError(error.localizedDescription)
        }

        isLoading = false
    }

    /// Force-refresh GitHub issues from all configured project filters.
    public func refreshBacklog() async {
        lastGitHubRefresh = nil // reset timer to force fetch
        isRefreshingBacklog = true
        await refreshGitHubIssues()
        isRefreshingBacklog = false
    }

    /// Fetch GitHub issues if enough time has elapsed since last fetch.
    private func refreshGitHubIssuesIfNeeded() async {
        guard ghAdapter != nil else { return }
        let interval: TimeInterval
        if let store = settingsStore, let settings = try? await store.read() {
            interval = TimeInterval(settings.github.pollIntervalSeconds)
        } else {
            interval = 300
        }
        if let last = lastGitHubRefresh, Date.now.timeIntervalSince(last) < interval {
            return
        }
        await refreshGitHubIssues()
    }

    /// Fetch GitHub issues from all configured project filters and sync to links.
    private func refreshGitHubIssues() async {
        guard let ghAdapter else { return }

        let settings: Settings?
        if let store = settingsStore {
            settings = try? await store.read()
        } else {
            settings = nil
        }
        guard let settings else { return }

        guard var links = try? await coordinationStore.readLinks() else { return }

        var fetchedIssueKeys: Set<String> = [] // "projectPath:issueNumber"
        var changed = false

        for project in settings.projects {
            guard let filter = project.githubFilter, !filter.isEmpty else { continue }

            do {
                let issues = try await ghAdapter.fetchIssues(repoRoot: project.effectiveRepoRoot, filter: filter)
                for issue in issues {
                    let key = "\(project.path):\(issue.number)"
                    fetchedIssueKeys.insert(key)

                    // Check if link already exists
                    let existingIndex = links.firstIndex(where: {
                        $0.issueLink?.number == issue.number && $0.projectPath == project.path
                    })
                    if let idx = existingIndex {
                        // Update labels and title on existing issues
                        let newLabels = issue.labels.isEmpty ? nil : issue.labels
                        if links[idx].issueLink?.labels != newLabels || links[idx].issueLink?.title != issue.title {
                            links[idx].issueLink?.labels = newLabels
                            links[idx].issueLink?.title = issue.title
                            changed = true
                        }
                    } else {
                        let link = Link(
                            name: "#\(issue.number): \(issue.title)",
                            projectPath: project.path,
                            column: .backlog,
                            source: .githubIssue,
                            issueLink: IssueLink(number: issue.number, url: issue.url, body: issue.body, title: issue.title, labels: issue.labels.isEmpty ? nil : issue.labels)
                        )
                        links.append(link)
                        changed = true
                    }
                }
            } catch {
                // Surface GitHub API errors briefly
                setError("GitHub: \(error.localizedDescription)")
            }
        }

        // Remove stale GitHub issue links (still in backlog, no longer in fetch results)
        let before = links.count
        links.removeAll { link in
            guard link.source == .githubIssue,
                  link.column == .backlog,
                  let issueNum = link.issueLink?.number,
                  let projPath = link.projectPath else { return false }
            let key = "\(projPath):\(issueNum)"
            return !fetchedIssueKeys.contains(key)
        }
        if links.count != before { changed = true }

        if changed {
            try? await coordinationStore.writeLinks(links)
            // Re-build cards from updated links
            let sessions = (try? await discovery.discoverSessions()) ?? []
            let sessionsById = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var newCards: [KanbanCodeCard] = []
            for link in links {
                let activity: ActivityState?
                if let sessionId = link.sessionLink?.sessionId {
                    activity = await activityDetector?.activityState(for: sessionId)
                } else {
                    activity = nil
                }
                newCards.append(KanbanCodeCard(
                    link: link,
                    session: link.sessionLink.flatMap { sessionsById[$0.sessionId] },
                    activityState: activity
                ))
            }
            cards = newCards
        }

        lastGitHubRefresh = Date()
    }
}
