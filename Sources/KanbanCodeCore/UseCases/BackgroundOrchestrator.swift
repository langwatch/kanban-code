import Foundation

/// Coordinates all background processes: session discovery, tmux polling,
/// hook event processing, activity detection, PR tracking, and link management.
@Observable
public final class BackgroundOrchestrator: @unchecked Sendable {
    public var isRunning = false

    private let discovery: SessionDiscovery
    private let coordinationStore: CoordinationStore
    private let activityDetector: ClaudeCodeActivityDetector
    private let hookEventStore: HookEventStore
    private let tmux: TmuxManagerPort?
    private let prTracker: PRTrackerPort?
    private let notificationDedup: NotificationDeduplicator
    private var notifier: NotifierPort?

    private var backgroundTask: Task<Void, Never>?
    private var didInitialLoad = false

    public init(
        discovery: SessionDiscovery,
        coordinationStore: CoordinationStore,
        activityDetector: ClaudeCodeActivityDetector = .init(),
        hookEventStore: HookEventStore = .init(),
        tmux: TmuxManagerPort? = nil,
        prTracker: PRTrackerPort? = nil,
        notificationDedup: NotificationDeduplicator = .init(),
        notifier: NotifierPort? = nil
    ) {
        self.discovery = discovery
        self.coordinationStore = coordinationStore
        self.activityDetector = activityDetector
        self.hookEventStore = hookEventStore
        self.tmux = tmux
        self.prTracker = prTracker
        self.notificationDedup = notificationDedup
        self.notifier = notifier
    }

    /// Start the slow background loop (columns, PRs, activity polling).
    /// Notifications are handled event-driven via processHookEvents().
    public func start() {
        guard !isRunning else { return }
        isRunning = true

        backgroundTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.backgroundTick()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// Update the notifier (e.g. when settings change).
    public func updateNotifier(_ newNotifier: NotifierPort?) {
        self.notifier = newNotifier
    }

    /// Force re-scan a card's conversation for pushed branches and re-fetch PRs.
    /// Used by the UI "Discover" button to manually trigger discovery for older cards.
    /// Returns the updated Link so callers can sync it to in-memory state.
    @discardableResult
    public func discoverBranchesForCard(cardId: String) async -> Link? {
        do {
            var links = try await coordinationStore.readLinks()
            guard let idx = links.firstIndex(where: { $0.id == cardId }),
                  let sessionPath = links[idx].sessionLink?.sessionPath else { return nil }

            // Explicit discovery: clear watermark, legacy flags, and PR override for full rescan
            links[idx].manualOverrides.branchWatermark = nil
            links[idx].manualOverrides.worktreePath = false
            links[idx].manualOverrides.prLink = false
            links[idx].discoveredBranches = nil
            links[idx].discoveredRepos = nil
            let scanned = (try? await JsonlParser.extractPushedBranches(from: sessionPath)) ?? []
            links[idx].discoveredBranches = scanned.map(\.branch)
            // Store repo paths for branches that differ from projectPath
            var repos: [String: String] = [:]
            for db in scanned {
                if let repo = db.repoPath, repo != links[idx].projectPath {
                    repos[db.branch] = repo
                }
            }
            links[idx].discoveredRepos = repos.isEmpty ? nil : repos

            // Re-fetch PRs — group branches by repo for batch fetching
            if let prTracker {
                let projectPath = links[idx].projectPath
                // Collect all branches with their effective repo paths
                var branchesByRepo: [String: [String]] = [:]
                if let branch = links[idx].worktreeLink?.branch, let pp = projectPath {
                    branchesByRepo[pp, default: []].append(branch)
                }
                for db in scanned {
                    let repo = db.repoPath ?? projectPath ?? ""
                    guard !repo.isEmpty else { continue }
                    branchesByRepo[repo, default: []].append(db.branch)
                }

                // Fetch PRs from each repo
                for (repo, branches) in branchesByRepo {
                    var allPRs: [String: PullRequest] = [:]
                    if var prs = try? await prTracker.fetchPRs(repoRoot: repo) {
                        try? await prTracker.enrichPRDetails(repoRoot: repo, prs: &prs)
                        allPRs = prs
                    }
                    for branch in branches {
                        if let pr = allPRs[branch],
                           !links[idx].prLinks.contains(where: { $0.number == pr.number }) {
                            links[idx].prLinks.append(PRLink(
                                number: pr.number, url: pr.url,
                                status: pr.status, title: pr.title,
                                approvalCount: pr.approvalCount > 0 ? pr.approvalCount : nil,
                                checkRuns: pr.checkRuns.isEmpty ? nil : pr.checkRuns
                            ))
                        }
                    }
                }
            }

            // Run column assignment after discovery
            var activityState: ActivityState?
            if let sessionId = links[idx].sessionLink?.sessionId {
                activityState = await activityDetector.activityState(for: sessionId)
            }
            let hasWorktree = links[idx].worktreeLink?.branch != nil
            UpdateCardColumn.update(link: &links[idx], activityState: activityState, hasWorktree: hasWorktree)

            links[idx].updatedAt = .now
            try await coordinationStore.writeLinks(links)
            return links[idx]
        } catch {
            // Best-effort
            return nil
        }
    }

    /// Stop the background loop.
    public func stop() {
        backgroundTask?.cancel()
        backgroundTask = nil
        isRunning = false
    }

    // MARK: - Event-driven notification path (called from file watcher)

    /// Process new hook events and send notifications. Called directly by file watcher
    /// for instant response — mirrors claude-pushover's hook-driven approach.
    public func processHookEvents() async {
        do {
            let events = try await hookEventStore.readNewEvents()

            if !didInitialLoad {
                // First call: consume all old events without notifying.
                KanbanCodeLog.info("notify", "Initial load: consuming \(events.count) old events")
                for event in events {
                    await activityDetector.handleHookEvent(event)
                }
                let _ = await activityDetector.resolvePendingStops()
                await notificationDedup.clearAllPending()
                didInitialLoad = true
                return
            }

            if !events.isEmpty {
                KanbanCodeLog.info("notify", "Processing \(events.count) hook events")
            }

            for event in events {
                await activityDetector.handleHookEvent(event)

                // Notification logic — mirrors claude-pushover, adapted for batch processing.
                // Uses EVENT TIMESTAMPS (not wall-clock) so batch-processed events
                // behave identically to claude-pushover's one-event-per-process model.
                switch event.eventName {
                case "Stop":
                    // claude-pushover: sleep 1s, check if user prompted, send if not.
                    // NO 62s dedup — Stop always sends (dedup only applies to Notification events).
                    KanbanCodeLog.info("notify", "Stop event for session \(event.sessionId.prefix(8)) at \(event.timestamp)")
                    let stopTime = event.timestamp
                    let sessionId = event.sessionId
                    Task { [weak self] in
                        try? await Task.sleep(for: .seconds(1))
                        guard let self else {
                            KanbanCodeLog.info("notify", "Stop handler: self deallocated")
                            return
                        }
                        // Check if user sent a prompt within 1s after this Stop
                        let prompted = await notificationDedup.hasPromptedWithin(
                            sessionId: sessionId, after: stopTime
                        )
                        if prompted {
                            KanbanCodeLog.info("notify", "Stop skipped: user prompted within 1s after stop")
                            return
                        }
                        // Send directly — no dedup for Stop events (matches claude-pushover)
                        await self.doNotify(sessionId: sessionId)
                    }

                case "Notification":
                    // claude-pushover: send if not within 62s dedup window
                    KanbanCodeLog.info("notify", "Notification event for session \(event.sessionId.prefix(8)) at \(event.timestamp)")
                    let sessionId = event.sessionId
                    let eventTime = event.timestamp
                    Task { [weak self] in
                        // Notification events go through 62s dedup
                        let shouldNotify = await self?.notificationDedup.shouldNotify(
                            sessionId: sessionId, eventTime: eventTime
                        ) ?? false
                        guard shouldNotify else {
                            KanbanCodeLog.info("notify", "Notification deduped for \(sessionId.prefix(8))")
                            return
                        }
                        await self?.doNotify(sessionId: sessionId)
                    }

                case "UserPromptSubmit":
                    KanbanCodeLog.info("notify", "UserPromptSubmit for session \(event.sessionId.prefix(8)) at \(event.timestamp)")
                    await notificationDedup.recordPrompt(sessionId: event.sessionId, at: event.timestamp)

                default:
                    break
                }
            }
        } catch {
            KanbanCodeLog.info("notify", "processHookEvents error: \(error)")
        }
    }

    // MARK: - Private

    /// Send notification — no dedup check, just format and send.
    /// Mirrors claude-pushover's do_notify() exactly.
    private func doNotify(sessionId: String) async {
        guard let notifier else {
            KanbanCodeLog.info("notify", "Notification skipped: notifier is nil")
            return
        }

        let link = try? await coordinationStore.linkForSession(sessionId)
        let title = link?.displayTitle ?? "Session done"

        // Mirrors claude-pushover's do_notify() exactly:
        // 1. Get last assistant response
        // 2. If multi-line: render image + use text preview
        // 3. If single line: use as-is
        // 4. No response: "Waiting for input"
        var message = "Waiting for input"
        var imageData: Data?

        if let transcriptPath = link?.sessionLink?.sessionPath {
            if let lastText = await TranscriptNotificationReader.lastAssistantText(transcriptPath: transcriptPath) {
                let lineCount = lastText.components(separatedBy: "\n").count
                if lineCount > 1 {
                    imageData = await MarkdownImageRenderer.renderToImage(markdown: lastText)
                    message = TranscriptNotificationReader.textPreview(lastText)
                } else {
                    message = lastText
                }
            }
        }

        KanbanCodeLog.info("notify", "Sending notification: title=\(title), message=\(message.prefix(60))..., hasImage=\(imageData != nil)")
        try? await notifier.sendNotification(
            title: title,
            message: message,
            imageData: imageData,
            cardId: link?.id
        )
    }

    /// Slow background tick: poll activity states for sessions without hook events.
    /// Column updates and PR tracking are now handled by BoardStore.reconcile().
    private func backgroundTick() async {
        await updateActivityStates()
    }

    private func updateActivityStates() async {
        do {
            let links = try await coordinationStore.readLinks()
            let sessionPaths = Dictionary(
                links.compactMap { link -> (String, String)? in
                    guard let sessionId = link.sessionLink?.sessionId,
                          let path = link.sessionLink?.sessionPath else { return nil }
                    return (sessionId, path)
                },
                uniquingKeysWith: { a, _ in a }
            )

            // Poll activity for sessions without hook events
            let _ = await activityDetector.pollActivity(sessionPaths: sessionPaths)
        } catch {
            // Continue on error
        }
    }
}
