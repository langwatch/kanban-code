import Foundation

extension Notification.Name {
    /// Posted when hook events are processed that should trigger a UI refresh.
    public static let kanbanCodeHookEvent = Notification.Name("kanbanCodeHookEvent")
}

/// Coordinates all background processes: session discovery, tmux polling,
/// hook event processing, activity detection, PR tracking, and link management.
@Observable
public final class BackgroundOrchestrator: @unchecked Sendable {
    public var isRunning = false

    private let discovery: SessionDiscovery
    private let coordinationStore: CoordinationStore
    private let activityDetector: any ActivityDetector
    private let hookEventStore: HookEventStore
    private let tmux: TmuxManagerPort?
    private let prTracker: PRTrackerPort?
    private let notificationDedup: NotificationDeduplicator
    private var notifier: NotifierPort?
    private let registry: CodingAssistantRegistry?

    private var backgroundTask: Task<Void, Never>?
    private var didInitialLoad = false
    private var dispatch: (@MainActor @Sendable (Action) -> Void)?

    /// Prompt IDs currently being edited in the UI — skip auto-send for these.
    private var editingQueuedPromptIds: Set<String> = []

    public init(
        discovery: SessionDiscovery,
        coordinationStore: CoordinationStore,
        activityDetector: any ActivityDetector,
        hookEventStore: HookEventStore = .init(),
        tmux: TmuxManagerPort? = nil,
        prTracker: PRTrackerPort? = nil,
        notificationDedup: NotificationDeduplicator = .init(),
        notifier: NotifierPort? = nil,
        registry: CodingAssistantRegistry? = nil
    ) {
        self.discovery = discovery
        self.coordinationStore = coordinationStore
        self.activityDetector = activityDetector
        self.hookEventStore = hookEventStore
        self.tmux = tmux
        self.prTracker = prTracker
        self.notificationDedup = notificationDedup
        self.notifier = notifier
        self.registry = registry
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

    /// Mark a queued prompt as being edited — auto-send will skip it.
    public func markPromptEditing(_ promptId: String) {
        editingQueuedPromptIds.insert(promptId)
    }

    /// Clear the editing mark so auto-send can proceed.
    public func clearPromptEditing(_ promptId: String) {
        editingQueuedPromptIds.remove(promptId)
    }

    /// Set the dispatch callback for sending actions to the BoardStore.
    public func setDispatch(_ dispatch: @MainActor @Sendable @escaping (Action) -> Void) {
        self.dispatch = dispatch
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
            links[idx].manualOverrides.dismissedPRs = nil
            links[idx].discoveredBranches = nil
            links[idx].discoveredRepos = nil
            let scanned: [JsonlParser.DiscoveredBranch]
            if links[idx].effectiveAssistant == .codex {
                scanned = (try? await CodexSessionParser.extractPushedBranches(from: sessionPath)) ?? []
            } else {
                scanned = (try? await JsonlParser.extractPushedBranches(from: sessionPath)) ?? []
            }
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
                                checkRuns: pr.checkRuns.isEmpty ? nil : pr.checkRuns,
                                firstUnresolvedThreadURL: pr.firstUnresolvedThreadURL,
                                mergeStateStatus: pr.mergeStateStatus
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
                // Normalize Gemini event names (AfterAgent → Stop, BeforeAgent → UserPromptSubmit).
                let eventName = HookManager.normalizeEventName(event.eventName)
                switch eventName {
                case "Stop":
                    // claude-pushover: sleep 0.5s, check if user prompted, send if not.
                    // NO 62s dedup — Stop always sends (dedup only applies to Notification events).
                    KanbanCodeLog.info("notify", "Stop event for session \(event.sessionId.prefix(8)) at \(event.timestamp)")
                    let stopTime = event.timestamp
                    let sessionId = event.sessionId
                    Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(500))
                        guard let self else {
                            KanbanCodeLog.info("notify", "Stop handler: self deallocated")
                            return
                        }
                        // Check if user sent a prompt within 0.5s after this Stop
                        let prompted = await notificationDedup.hasPromptedWithin(
                            sessionId: sessionId, after: stopTime
                        )
                        if prompted {
                            KanbanCodeLog.info("notify", "Stop skipped: user prompted within 0.5s after stop")
                            return
                        }
                        // Send directly — no dedup for Stop events (matches claude-pushover)
                        await self.doNotify(sessionId: sessionId)

                        // Auto-send queued prompt: wait 0.5 more seconds (1s total from Stop),
                        // re-check that user hasn't prompted, then send first auto prompt.
                        try? await Task.sleep(for: .milliseconds(500))
                        let promptedAgain = await notificationDedup.hasPromptedWithin(
                            sessionId: sessionId, after: stopTime
                        )
                        if promptedAgain {
                            KanbanCodeLog.info("notify", "Auto-send skipped: user prompted after stop")
                            return
                        }
                        await self.autoSendQueuedPrompt(sessionId: sessionId)
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
        // 2. If multi-line + render enabled: render image, message = "Task completed"
        // 3. If multi-line + no image: truncate to 1000 chars
        // 4. If single line: use as-is
        // 5. No response: "Waiting for input"
        var message = "Waiting for input"
        var imageData: Data?

        let renderMarkdown = (try? await SettingsStore().read())?.notifications.renderMarkdownImage ?? false

        if let transcriptPath = link?.sessionLink?.sessionPath {
            // Use the correct session store for the assistant (Gemini=JSON, Claude=JSONL)
            let assistant = link?.assistant ?? .claude
            let lastText: String?
            if let store = registry?.store(for: assistant),
               let turns = try? await store.readTranscript(sessionPath: transcriptPath) {
                lastText = TranscriptNotificationReader.lastAssistantText(from: turns)
            } else {
                lastText = await TranscriptNotificationReader.lastAssistantText(transcriptPath: transcriptPath)
            }

            if let lastText {
                let lineCount = lastText.components(separatedBy: "\n").count
                if lineCount > 1 {
                    if renderMarkdown {
                        imageData = await MarkdownImageRenderer.renderToImage(markdown: lastText)
                    }
                    if imageData != nil {
                        message = "Task completed"
                    } else {
                        message = String(lastText.prefix(1000)) + (lastText.count > 1000 ? "..." : "")
                    }
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

    /// Auto-send the first queued prompt with sendAutomatically=true for a session.
    private func autoSendQueuedPrompt(sessionId: String) async {
        do {
            guard let link = try await coordinationStore.linkForSession(sessionId) else {
                KanbanCodeLog.info("notify", "Auto-send: no link found for session \(sessionId.prefix(8))")
                return
            }
            guard let prompts = link.queuedPrompts,
                  let first = prompts.first,
                  first.sendAutomatically && !editingQueuedPromptIds.contains(first.id) else {
                let qCount = link.queuedPrompts?.count ?? 0
                let firstAuto = link.queuedPrompts?.first?.sendAutomatically ?? false
                KanbanCodeLog.info("notify", "Auto-send: no eligible prompt for \(sessionId.prefix(8)) (queued: \(qCount), firstIsAuto: \(firstAuto), editing: \(editingQueuedPromptIds))")
                return
            }
            let prompt = first
            guard link.tmuxLink?.sessionName != nil else {
                KanbanCodeLog.info("notify", "Auto-send skipped: no tmux session for \(sessionId.prefix(8))")
                return
            }

            KanbanCodeLog.info("notify", "Auto-sending queued prompt to \(sessionId.prefix(8)): \(prompt.body.prefix(40))...")

            // Dispatch through BoardStore — this removes from in-memory state,
            // persists to disk, and sends to tmux via effects, all in sync.
            if let dispatch {
                await dispatch(.sendQueuedPrompt(cardId: link.id, promptId: prompt.id))
            }

            // Record that we "prompted" so the next stop can trigger the next queued prompt
            await notificationDedup.recordPrompt(sessionId: sessionId, at: .now)
        } catch {
            KanbanCodeLog.warn("notify", "autoSendQueuedPrompt failed: \(error)")
        }
    }

    /// Slow background tick: poll activity states for sessions without hook events.
    /// Also processes any missed hook events as a fallback in case the file watcher missed a write.
    /// Column updates and PR tracking are now handled by BoardStore.reconcile().
    private func backgroundTick() async {
        await processHookEvents()
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
