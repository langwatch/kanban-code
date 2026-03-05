import Foundation

/// Pure reconciliation logic: matches discovered resources to existing cards,
/// preventing duplicate card creation (the "triplication bug").
///
/// Responsibilities:
/// - Match discovered sessions to existing cards (by sessionId → tmux name → worktree branch)
/// - Create new cards for truly unmatched sessions
/// - Match discovered worktrees to existing cards (by branch)
/// - Create orphan worktree cards for unmatched worktrees
/// - Add/update PR links via branch matching
/// - Clear dead tmux and worktree links
///
/// NOT responsible for: column assignment, activity detection, GitHub issue syncing.
public enum CardReconciler {

    /// A point-in-time snapshot of all discovered external resources.
    public struct DiscoverySnapshot: Sendable {
        public let sessions: [Session]
        public let tmuxSessions: [TmuxSession]
        public let didScanTmux: Bool                    // true if tmux was queried (even if 0 results)
        public let worktrees: [String: [Worktree]]     // repoRoot → worktrees
        public let pullRequests: [String: PullRequest]  // branch → PR

        public init(
            sessions: [Session] = [],
            tmuxSessions: [TmuxSession] = [],
            didScanTmux: Bool = false,
            worktrees: [String: [Worktree]] = [:],
            pullRequests: [String: PullRequest] = [:]
        ) {
            self.sessions = sessions
            self.tmuxSessions = tmuxSessions
            self.didScanTmux = didScanTmux
            self.worktrees = worktrees
            self.pullRequests = pullRequests
        }
    }

    /// Reconcile existing cards with discovered resources.
    /// Returns the merged list of links (some updated, some new, some with cleared links).
    public static func reconcile(existing: [Link], snapshot: DiscoverySnapshot) -> [Link] {
        var linksById: [String: Link] = [:]
        for link in existing {
            linksById[link.id] = link
        }

        // Build reverse indexes for matching
        var cardIdBySessionId: [String: String] = [:]
        var cardIdByTmuxName: [String: String] = [:]
        var cardIdsByBranch: [String: [String]] = [:]

        for link in existing {
            if let sid = link.sessionLink?.sessionId {
                cardIdBySessionId[sid] = link.id
            }
            if let tmux = link.tmuxLink {
                for name in tmux.allSessionNames {
                    cardIdByTmuxName[name] = link.id
                }
            }
            if let branch = link.worktreeLink?.branch {
                cardIdsByBranch[branch, default: []].append(link.id)
            }
            // Also index discovered branches (from git push scanning) for PR matching
            if let discovered = link.discoveredBranches {
                for branch in discovered {
                    if !(cardIdsByBranch[branch]?.contains(link.id) ?? false) {
                        cardIdsByBranch[branch, default: []].append(link.id)
                    }
                }
            }
        }

        // Track which sessions we've matched so we can detect new ones
        var matchedSessionIds: Set<String> = []

        // A. Match sessions to existing cards
        for session in snapshot.sessions {
            let cardId = findCardForSession(
                session: session,
                cardIdBySessionId: cardIdBySessionId,
                cardIdByTmuxName: cardIdByTmuxName,
                cardIdsByBranch: cardIdsByBranch,
                linksById: linksById
            )

            if let cardId, var link = linksById[cardId] {
                // Update existing card with session data
                if link.sessionLink == nil {
                    KanbanCodeLog.info("reconciler", "Linking session \(session.id.prefix(8)) to existing card \(cardId.prefix(12))")
                    link.sessionLink = SessionLink(
                        sessionId: session.id,
                        sessionPath: session.jsonlPath
                    )
                    cardIdBySessionId[session.id] = link.id
                } else {
                    // Update existing session link
                    link.sessionLink?.sessionPath = session.jsonlPath
                }
                link.lastActivity = session.modifiedTime
                if link.projectPath == nil, let pp = session.projectPath {
                    link.projectPath = pp
                }
                // If session is in a worktree dir and card doesn't have worktreeLink yet,
                // find the matching worktree in the snapshot to get the correct git branch name.
                // Only do this for cards that are actively launching — avoids re-attaching
                // a worktree to forked cards that were explicitly created without one.
                if link.worktreeLink == nil,
                   link.isLaunching == true,
                   let pp = session.projectPath,
                   pp.contains("/.claude/worktrees/") {
                    // Prefer real git branch from snapshot (directory name may differ from branch)
                    var branchName: String?
                    for (_, worktrees) in snapshot.worktrees {
                        if let wt = worktrees.first(where: { $0.path == pp }),
                           let branch = wt.branch {
                            branchName = branch.replacingOccurrences(of: "refs/heads/", with: "")
                            break
                        }
                    }
                    // Fallback: extract from path if worktree not in snapshot yet
                    if branchName == nil, let range = pp.range(of: "/.claude/worktrees/") {
                        let afterPrefix = String(pp[range.upperBound...])
                        branchName = afterPrefix.components(separatedBy: "/").first
                    }
                    if let branchName, !branchName.isEmpty {
                        KanbanCodeLog.info("reconciler", "Setting worktreeLink from session path: branch=\(branchName) on card \(cardId.prefix(12))")
                        link.worktreeLink = WorktreeLink(path: pp, branch: branchName)
                        cardIdsByBranch[branchName, default: []].append(cardId)
                    }
                }
                linksById[cardId] = link
                matchedSessionIds.insert(session.id)
            } else {
                KanbanCodeLog.info("reconciler", "New session \(session.id.prefix(8)) → new card")
                // Truly new session — create discovered card
                let newLink = Link(
                    projectPath: session.projectPath,
                    column: .allSessions,
                    lastActivity: session.modifiedTime,
                    source: .discovered,
                    sessionLink: SessionLink(
                        sessionId: session.id,
                        sessionPath: session.jsonlPath
                    )
                )
                linksById[newLink.id] = newLink
                cardIdBySessionId[session.id] = newLink.id
                matchedSessionIds.insert(session.id)
            }
        }

        // A2. Update branch index with session gitBranch data.
        // This prevents Section B from creating orphan worktree cards when
        // a session already exists on that branch.
        for session in snapshot.sessions {
            if let branch = session.gitBranch {
                let baseName = branch.replacingOccurrences(of: "refs/heads/", with: "")
                if baseName == "main" || baseName == "master" { continue }
                if let cardId = cardIdBySessionId[session.id],
                   !(cardIdsByBranch[baseName]?.contains(cardId) ?? false) {
                    // Skip cards with branch discovery blocked (watermark or legacy worktreePath) —
                    // the session's baked-in gitBranch belongs to the parent, not this card.
                    if linksById[cardId]?.manualOverrides.isBranchDiscoveryBlocked == true { continue }
                    cardIdsByBranch[baseName, default: []].append(cardId)
                }
            }
        }

        // B. Match worktrees to existing cards
        let liveTmuxNames = Set(snapshot.tmuxSessions.map(\.name))
        let didScanTmux = snapshot.didScanTmux
        var liveWorktreePaths: Set<String> = []
        let didScanWorktrees = !snapshot.worktrees.isEmpty

        for (repoRoot, worktrees) in snapshot.worktrees {
            for worktree in worktrees {
                guard !worktree.isBare else { continue }
                liveWorktreePaths.insert(worktree.path)

                guard let branch = worktree.branch else { continue }
                // Skip main/master branches — they're not worktrees we track
                let baseName = branch.replacingOccurrences(of: "refs/heads/", with: "")
                if baseName == "main" || baseName == "master" { continue }

                let existingCardIds = cardIdsByBranch[baseName] ?? []
                if existingCardIds.isEmpty {
                    // Check if a card is currently launching in this repo — associate the worktree
                    // with it instead of creating an orphan (avoids launch race condition).
                    let launchingCard = linksById.first { (_, link) in
                        link.isLaunching == true
                            && link.projectPath != nil
                            && (repoRoot == link.projectPath
                                || repoRoot.hasPrefix(link.projectPath! + "/")
                                || link.projectPath!.hasPrefix(repoRoot + "/"))
                    }
                    if let (launchingId, _) = launchingCard {
                        KanbanCodeLog.info("reconciler", "Associating worktree branch=\(baseName) with launching card \(launchingId.prefix(12))")
                        var link = linksById[launchingId]!
                        if link.worktreeLink == nil {
                            link.worktreeLink = WorktreeLink(path: worktree.path, branch: baseName)
                        }
                        linksById[launchingId] = link
                        cardIdsByBranch[baseName, default: []].append(launchingId)
                    } else {
                        // Orphan worktree — create a new card
                        KanbanCodeLog.info("reconciler", "Orphan worktree branch=\(baseName) → new card")
                        let newLink = Link(
                            projectPath: repoRoot,
                            source: .discovered,
                            worktreeLink: WorktreeLink(path: worktree.path, branch: baseName)
                        )
                        linksById[newLink.id] = newLink
                        cardIdsByBranch[baseName, default: []].append(newLink.id)
                    }
                } else {
                    // Update existing card's worktree link
                    for cardId in existingCardIds {
                        if var link = linksById[cardId] {
                            if link.worktreeLink != nil {
                                // Already has worktreeLink — only update path if same branch.
                                // Prevents cross-repo flipping when discoveredBranches span repos
                                // (e.g. card indexed for branches in both langwatch and scenario).
                                if link.worktreeLink?.branch == baseName {
                                    link.worktreeLink?.path = worktree.path
                                }
                            } else if link.manualOverrides.isBranchDiscoveryBlocked {
                                // Branch discovery blocked (watermark or legacy) — don't re-attach worktree
                                continue
                            } else {
                                // Attach worktree only if repo matches the card's expected repo for this branch.
                                // discoveredRepos tracks which repo each branch came from; absent = projectPath.
                                let expectedRepo = link.discoveredRepos?[baseName] ?? link.projectPath
                                guard expectedRepo == nil || expectedRepo == repoRoot else { continue }
                                KanbanCodeLog.info("reconciler", "Setting worktreeLink on card \(cardId.prefix(12)) for branch=\(baseName)")
                                link.worktreeLink = WorktreeLink(path: worktree.path, branch: baseName)
                            }
                            linksById[cardId] = link
                        }
                    }
                }
            }
        }

        // B1.5: Refresh worktree branches from snapshot.
        // Claude may switch branches inside an existing worktree — detect this
        // by matching on path and updating the branch if it changed.
        for (_, link) in linksById {
            guard let wtPath = link.worktreeLink?.path,
                  let oldBranch = link.worktreeLink?.branch else { continue }
            for (_, worktrees) in snapshot.worktrees {
                if let wt = worktrees.first(where: { $0.path == wtPath }),
                   let newBranch = wt.branch?.replacingOccurrences(of: "refs/heads/", with: ""),
                   newBranch != oldBranch {
                    var updated = link
                    updated.worktreeLink?.branch = newBranch
                    updated.prLinks = []  // PR was matched via old branch — clear stale link
                    linksById[link.id] = updated
                    // Update branch index
                    cardIdsByBranch[oldBranch]?.removeAll { $0 == link.id }
                    cardIdsByBranch[newBranch, default: []].append(link.id)
                    KanbanCodeLog.info("reconciler", "Branch changed on worktree \(wtPath): \(oldBranch) → \(newBranch)")
                    break
                }
            }
        }

        // B2. Absorb orphan worktree cards (worktreeLink but no session/name/manual)
        // into real cards on the same branch. Multiple sessions on the same branch
        // are legitimate (forked tasks) and must NOT be merged.
        for (branch, cardIds) in cardIdsByBranch where cardIds.count > 1 {
            let orphanIds = cardIds.filter { id in
                let l = linksById[id]!
                return l.sessionLink == nil && l.source != .manual && l.name == nil
            }
            guard !orphanIds.isEmpty else { continue }

            let realIds = cardIds.filter { id in !orphanIds.contains(id) }
            let keeperId = realIds.first ?? orphanIds.first!
            var keeper = linksById[keeperId]!

            for orphanId in orphanIds where orphanId != keeperId {
                if let orphan = linksById[orphanId] {
                    if keeper.worktreeLink == nil { keeper.worktreeLink = orphan.worktreeLink }
                    if keeper.tmuxLink == nil { keeper.tmuxLink = orphan.tmuxLink }
                    KanbanCodeLog.info("reconciler", "Dedup: absorbing orphan \(orphanId.prefix(12)) (branch=\(branch)) into \(keeperId.prefix(12))")
                }
                linksById.removeValue(forKey: orphanId)
            }
            linksById[keeperId] = keeper
            cardIdsByBranch[branch] = cardIds.filter { !orphanIds.contains($0) || $0 == keeperId }
        }

        // C. Match PRs to existing cards via branch (add or update)
        for (branch, pr) in snapshot.pullRequests {
            let cardIds = cardIdsByBranch[branch] ?? []
            if cardIds.isEmpty {
                KanbanCodeLog.info("reconciler", "PR #\(pr.number) on branch=\(branch) has no matching card")
            }
            for cardId in cardIds {
                if var link = linksById[cardId] {
                    // User dismissed this PR — don't re-add
                    if link.manualOverrides.isPRDismissed(pr.number) { continue }
                    if let idx = link.prLinks.firstIndex(where: { $0.number == pr.number }) {
                        KanbanCodeLog.info("reconciler", "Updating PR #\(pr.number) on card \(cardId.prefix(12)): status=\(pr.status)")
                        link.prLinks[idx].status = pr.status
                        link.prLinks[idx].url = pr.url
                        link.prLinks[idx].title = pr.title
                        link.prLinks[idx].mergeStateStatus = pr.mergeStateStatus
                    } else {
                        KanbanCodeLog.info("reconciler", "Adding PR #\(pr.number) to card \(cardId.prefix(12)): status=\(pr.status)")
                        link.prLinks.append(PRLink(number: pr.number, url: pr.url, status: pr.status, title: pr.title, mergeStateStatus: pr.mergeStateStatus))
                    }
                    linksById[cardId] = link
                }
            }
        }

        // D. Clear dead links
        for (id, var link) in linksById {
            var changed = false

            // Clear dead tmux links (tmux session no longer exists)
            // Only clear if we actually scanned tmux (avoid clearing when snapshot has no tmux data)
            // Skip cards mid-launch — the tmux session may not be visible yet
            if var tmux = link.tmuxLink, link.isLaunching != true, !link.manualOverrides.tmuxSession, didScanTmux {
                let primaryAlive = liveTmuxNames.contains(tmux.sessionName)

                // Filter dead extra sessions
                if let extras = tmux.extraSessions {
                    let liveExtras = extras.filter { liveTmuxNames.contains($0) }
                    tmux.extraSessions = liveExtras.isEmpty ? nil : liveExtras
                }

                if !primaryAlive && tmux.extraSessions == nil {
                    // Both primary and all extras dead
                    link.tmuxLink = nil
                    changed = true
                } else if !primaryAlive {
                    // Primary dead but extras alive — mark primary dead
                    tmux.isPrimaryDead = true
                    link.tmuxLink = tmux
                    changed = true
                } else {
                    // Primary alive — ensure isPrimaryDead is cleared
                    if tmux.isPrimaryDead != nil {
                        tmux.isPrimaryDead = nil
                    }
                    if tmux != link.tmuxLink {
                        link.tmuxLink = tmux
                        changed = true
                    }
                }
            }

            // Clear dead worktree links (path no longer exists on disk)
            if let wtPath = link.worktreeLink?.path,
               !wtPath.isEmpty,
               !link.manualOverrides.isBranchDiscoveryBlocked,
               didScanWorktrees, // only clear if we actually scanned worktrees
               !liveWorktreePaths.contains(wtPath) {
                link.worktreeLink = nil
                changed = true
            }

            if changed {
                linksById[id] = link
            }
        }

        return Array(linksById.values)
    }

    // MARK: - Private

    /// Find an existing card that should own this session.
    /// Match priority: exact sessionId → tmux name → worktree branch.
    private static func findCardForSession(
        session: Session,
        cardIdBySessionId: [String: String],
        cardIdByTmuxName: [String: String],
        cardIdsByBranch: [String: [String]],
        linksById: [String: Link]
    ) -> String? {
        // 1. Exact match by sessionId
        if let cardId = cardIdBySessionId[session.id] {
            KanbanCodeLog.info("reconciler", "findCard: session=\(session.id.prefix(8)) matched by sessionId → card=\(cardId.prefix(12))")
            return cardId
        }

        // 2. Match by worktree branch (session has gitBranch matching a card's worktreeLink)
        //    Must also match project path to avoid cross-project matches on common branches like "main"
        if let branch = session.gitBranch {
            let baseName = branch.replacingOccurrences(of: "refs/heads/", with: "")
            if let cardIds = cardIdsByBranch[baseName] {
                let sameProject = cardIds.filter { cardId in
                    guard let link = linksById[cardId] else { return false }
                    guard let sessionPath = session.projectPath else { return true }
                    return link.projectPath == sessionPath
                        || isWorktreeUnder(sessionPath: sessionPath, projectRoot: link.projectPath)
                }
                // Prefer cards that don't already have a session (pending cards)
                let pendingCards = sameProject.filter { linksById[$0]?.sessionLink == nil }
                if let cardId = pendingCards.first {
                    KanbanCodeLog.info("reconciler", "findCard: session=\(session.id.prefix(8)) matched by branch=\(baseName) → card=\(cardId.prefix(12))")
                    return cardId
                }
                if let cardId = sameProject.first {
                    KanbanCodeLog.info("reconciler", "findCard: session=\(session.id.prefix(8)) matched by branch=\(baseName) (existing) → card=\(cardId.prefix(12))")
                    return cardId
                }
            }
        }

        // 3. Match by project path + tmux (card has tmuxLink, same project, no sessionLink yet)
        //    Also matches when session is in a worktree under the card's project
        //    (e.g., session in <project>/.claude/worktrees/<name> matches card with projectPath=<project>)
        if let projectPath = session.projectPath {
            for (_, link) in linksById {
                if link.tmuxLink != nil,
                   link.sessionLink == nil,
                   (link.projectPath == projectPath || isWorktreeUnder(sessionPath: projectPath, projectRoot: link.projectPath)) {
                    KanbanCodeLog.info("reconciler", "findCard: session=\(session.id.prefix(8)) matched by projectPath+tmux → card=\(link.id.prefix(12)) (tmux=\(link.tmuxLink?.sessionName ?? "?"))")
                    return link.id
                }
            }
            // Log when no match found for debugging
            let tmuxCards = linksById.values.filter { $0.tmuxLink != nil && $0.sessionLink == nil }
            if !tmuxCards.isEmpty {
                for card in tmuxCards {
                    KanbanCodeLog.info("reconciler", "findCard: session=\(session.id.prefix(8)) projectPath=\(projectPath) — tmux card=\(card.id.prefix(12)) has projectPath=\(card.projectPath ?? "nil") (no match)")
                }
            }
        }

        KanbanCodeLog.info("reconciler", "findCard: session=\(session.id.prefix(8)) projectPath=\(session.projectPath ?? "nil") → NO MATCH")
        return nil
    }

    /// Check if sessionPath is a worktree directory under a project root.
    /// e.g., sessionPath = "/path/to/project/.claude/worktrees/my-branch"
    ///        projectRoot = "/path/to/project"
    private static func isWorktreeUnder(sessionPath: String, projectRoot: String?) -> Bool {
        guard let projectRoot else { return false }
        return sessionPath.hasPrefix(projectRoot + "/.claude/worktrees/")
    }
}
