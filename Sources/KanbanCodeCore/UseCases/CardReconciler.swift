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
        /// Remote machines whose tmux sessions are in `tmuxSessions`. A remote
        /// card on any other machine keeps its tmux link.
        public let connectedRemoteMachines: Set<String>

        public init(
            sessions: [Session] = [],
            tmuxSessions: [TmuxSession] = [],
            didScanTmux: Bool = false,
            worktrees: [String: [Worktree]] = [:],
            pullRequests: [String: PullRequest] = [:],
            connectedRemoteMachines: Set<String> = []
        ) {
            self.sessions = sessions
            self.tmuxSessions = tmuxSessions
            self.didScanTmux = didScanTmux
            self.worktrees = worktrees
            self.pullRequests = pullRequests
            self.connectedRemoteMachines = connectedRemoteMachines
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
                // Archived cards stay archived — just mark matched to prevent duplicates
                if link.manuallyArchived {
                    matchedSessionIds.insert(session.id)
                    continue
                }
                // Update existing card with session data
                if link.sessionLink == nil {
                    KanbanCodeLog.info("reconciler", "Linking session \(session.id.prefix(8)) to existing card \(cardId.prefix(12))")
                    link.sessionLink = SessionLink(
                        sessionId: session.id,
                        sessionPath: session.jsonlPath
                    )
                    cardIdBySessionId[session.id] = link.id
                } else if link.sessionLink?.sessionId == session.id {
                    // Same session — update path in case it moved
                    link.sessionLink?.sessionPath = session.jsonlPath
                }
                // A card that only exists because discovery found a headless
                // transcript leaves the board. Judged once: a card the user
                // took back holds `headless == false` and is never re-marked.
                if link.headless == nil, session.isHeadless,
                   link.sessionLink?.sessionId == session.id, !link.isClaimed {
                    link.headless = true
                }
                // Different sessionId (e.g., shell tab session) — just mark matched,
                // don't overwrite the card's primary session. Activity only moves
                // forward: a session from days ago that lost its own card lands
                // on the newest card of its project by rule 4, and its age is
                // not the card's.
                if link.lastActivity.map({ session.modifiedTime > $0 }) ?? true {
                    link.lastActivity = session.modifiedTime
                }
                if link.projectPath == nil, let pp = session.projectPath {
                    link.projectPath = pp
                }
                // If session is in a worktree dir, update or set worktreeLink.
                // Handles both initial launch (worktreeLink == nil) and worktree switches
                // (Claude called EnterWorktree → session moved to a different worktree).
                // The cwd of a session can be a directory inside the
                // worktree (a temp folder, a package). The card points at
                // the worktree itself; the deep path would fail the
                // liveness check and flip the link on every pass.
                if let pp = session.projectPath.flatMap(Self.worktreeRoot(of:)) {
                    let needsUpdate = link.worktreeLink == nil
                        || (link.worktreeLink?.path != pp && link.sessionLink?.sessionId == session.id)
                    let shouldUpdate = needsUpdate && (link.isLaunching == true || link.worktreeLink != nil)
                    if shouldUpdate {
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
                            KanbanCodeLog.info("reconciler", "Updating worktreeLink from session path: branch=\(branchName) on card \(cardId.prefix(12))")
                            link.worktreeLink = WorktreeLink(path: pp, branch: branchName)
                            cardIdsByBranch[branchName, default: []].append(cardId)
                        }
                    }
                }
                linksById[cardId] = link
                matchedSessionIds.insert(session.id)
            } else {
                KanbanCodeLog.info("reconciler", "New session \(session.id.prefix(8)) → new card")
                // Truly new session — create discovered card. A headless one
                // is kept off the board columns (see AssignColumn).
                let newLink = Link(
                    projectPath: session.projectPath,
                    column: .allSessions,
                    lastActivity: session.modifiedTime,
                    source: .discovered,
                    sessionLink: SessionLink(
                        sessionId: session.id,
                        sessionPath: session.jsonlPath
                    ),
                    headless: session.isHeadless ? true : nil
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
                    // A hidden headless card does not adopt the branch's worktree:
                    // that worktree gets a card of its own on the board.
                    if linksById[cardId]?.isUnclaimedHeadless == true { continue }
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
                // Skip the main repo checkout — git worktree list always includes it
                // as the first entry, but it's not an actual worktree.
                guard worktree.path != repoRoot else { continue }
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

        // B3. Merge duplicate sessionId cards.
        // Race condition: reconcile discovers a session file before the manual/launched card
        // gets its sessionLink. Both cards end up with the same sessionId.
        // Keep the "richer" card (manual/named), absorb the discovered duplicate.
        var sessionIdToCards: [String: [String]] = [:]
        for (id, link) in linksById {
            guard let sid = link.sessionLink?.sessionId else { continue }
            sessionIdToCards[sid, default: []].append(id)
        }
        for (sid, cardIds) in sessionIdToCards where cardIds.count > 1 {
            // Pick the keeper: prefer manual source, then named, then earliest created
            let sorted = cardIds.sorted { a, b in
                let la = linksById[a]!, lb = linksById[b]!
                if la.source == .manual && lb.source != .manual { return true }
                if la.source != .manual && lb.source == .manual { return false }
                if la.name != nil && lb.name == nil { return true }
                if la.name == nil && lb.name != nil { return false }
                if la.tmuxLink != nil && lb.tmuxLink == nil { return true }
                if la.tmuxLink == nil && lb.tmuxLink != nil { return false }
                return la.createdAt < lb.createdAt
            }
            let keeperId = sorted[0]
            var keeper = linksById[keeperId]!
            for dupId in sorted.dropFirst() {
                if let dup = linksById[dupId] {
                    if keeper.worktreeLink == nil { keeper.worktreeLink = dup.worktreeLink }
                    if keeper.tmuxLink == nil { keeper.tmuxLink = dup.tmuxLink }
                    if keeper.name == nil { keeper.name = dup.name }
                    KanbanCodeLog.info("reconciler", "Dedup: merging duplicate sessionId=\(sid.prefix(8)) card \(dupId.prefix(12)) into \(keeperId.prefix(12))")
                }
                linksById.removeValue(forKey: dupId)
            }
            linksById[keeperId] = keeper
        }

        // B4. Auto-discover external tmux sessions (e.g., git-orchard).
        // Match non-claude sessions to cards by comparing the tmux session's
        // working directory against the card's worktreeLink.path or projectPath.
        if didScanTmux {
            let externalSessions = snapshot.tmuxSessions.filter { sess in
                !sess.name.hasPrefix("claude-") && !sess.path.isEmpty
            }
            // Build a set of tmux names already linked to any card (primary + extras)
            let alreadyLinkedTmux: Set<String> = {
                var names = Set<String>()
                for (_, link) in linksById {
                    if let t = link.tmuxLink {
                        names.insert(t.sessionName)
                        if let extras = t.extraSessions { names.formUnion(extras) }
                    }
                }
                return names
            }()

            for sess in externalSessions {
                guard !alreadyLinkedTmux.contains(sess.name) else { continue }
                // Find the best card: prefer exact worktree/project match over prefix
                var bestMatch: (String, Link)?
                var prefixMatch: (String, Link)?
                for (id, link) in linksById {
                    if let wtPath = link.worktreeLink?.path, sess.path == wtPath {
                        bestMatch = (id, link)
                        break // exact worktree match — can't do better
                    }
                    if let projPath = link.projectPath, sess.path == projPath {
                        bestMatch = (id, link)
                    }
                    // Worktree under project (e.g., .worktrees/name) — weakest match
                    if prefixMatch == nil, let projPath = link.projectPath,
                       sess.path.hasPrefix(projPath + "/.worktrees/") {
                        prefixMatch = (id, link)
                    }
                }
                let matchingCard = bestMatch ?? prefixMatch
                if let (cardId, _) = matchingCard {
                    var link = linksById[cardId]!
                    if link.tmuxLink == nil {
                        link.tmuxLink = TmuxLink(sessionName: sess.name)
                        KanbanCodeLog.info("reconciler", "External tmux \(sess.name) matched to card \(cardId.prefix(12)) by path")
                    } else if link.tmuxLink?.sessionName != sess.name {
                        // Add as extra session
                        var extras = link.tmuxLink?.extraSessions ?? []
                        if !extras.contains(sess.name) {
                            extras.append(sess.name)
                            link.tmuxLink?.extraSessions = extras
                            KanbanCodeLog.info("reconciler", "External tmux \(sess.name) added as extra to card \(cardId.prefix(12))")
                        }
                    }
                    linksById[cardId] = link
                }
            }
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
                        let current = link.prLinks[idx]
                        if current.status != pr.status || current.url != pr.url
                            || current.title != pr.title || current.mergeStateStatus != pr.mergeStateStatus {
                            KanbanCodeLog.info("reconciler", "Updating PR #\(pr.number) on card \(cardId.prefix(12)): status=\(pr.status)")
                            link.prLinks[idx].status = pr.status
                            link.prLinks[idx].url = pr.url
                            link.prLinks[idx].title = pr.title
                            link.prLinks[idx].mergeStateStatus = pr.mergeStateStatus
                        }
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
            // A remote card is only judged when its machine was in the scan.
            let remoteMachineScanned = !link.isRemote
                || (link.remote.map { snapshot.connectedRemoteMachines.contains($0.machineName) } ?? true)
            if link.tmuxLink != nil, link.isLaunching != true, !link.manualOverrides.tmuxSession, didScanTmux, remoteMachineScanned {
                changed = applyTmuxLiveness(to: &link, liveTmuxNames: liveTmuxNames) || changed
            }

            // Clear dead worktree links (path no longer exists on disk).
            // A remote card's worktree lives on its machine, so a missing
            // local path says nothing about it.
            if let wtPath = link.worktreeLink?.path,
               !wtPath.isEmpty,
               !(link.isRemote && link.remote != nil),
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

    /// Apply a tmux liveness scan to one link: drop dead extra sessions, mark
    /// the primary dead when extras survive it, or clear the whole tmuxLink
    /// when nothing is live anymore (e.g. after a reboot killed the tmux
    /// server). Returns true when the link was modified.
    /// Callers gate on isLaunching, manual overrides, and whether tmux was
    /// actually scanned — this only encodes the liveness rules.
    public static func applyTmuxLiveness(to link: inout Link, liveTmuxNames: Set<String>) -> Bool {
        guard var tmux = link.tmuxLink else { return false }
        let primaryAlive = liveTmuxNames.contains(tmux.sessionName)

        // Filter dead extra sessions
        if let extras = tmux.extraSessions {
            let liveExtras = extras.filter { liveTmuxNames.contains($0) }
            tmux.extraSessions = liveExtras.isEmpty ? nil : liveExtras
        }

        if !primaryAlive && tmux.extraSessions == nil {
            // Both primary and all extras dead
            link.tmuxLink = nil
            return true
        }
        // Keep the link for live sessions; primary-dead flag tracks liveness.
        tmux.isPrimaryDead = primaryAlive ? nil : true
        guard tmux != link.tmuxLink else { return false }
        link.tmuxLink = tmux
        return true
    }

    /// The root of the worktree a path sits in: everything up to the segment
    /// after ".claude/worktrees". Nothing for a path outside a worktree.
    public static func worktreeRoot(of path: String) -> String? {
        guard let range = path.range(of: "/.claude/worktrees/") else { return nil }
        let name = path[range.upperBound...].components(separatedBy: "/").first ?? ""
        guard !name.isEmpty else { return nil }
        return String(path[..<range.upperBound]) + name
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
            KanbanCodeLog.debug("reconciler", "findCard: session=\(session.id.prefix(8)) matched by sessionId → card=\(cardId.prefix(12))")
            return cardId
        }

        // A headless session (`claude -p` from a script) is not the one a
        // card's terminal started. Only a card hosted on agtop, which runs
        // Claude headless itself, may take one by the fuzzy rules below.
        let acceptsSession: (Link) -> Bool = { link in
            !session.isHeadless
                || link.tmuxLink.map { AgtopSessionName.isAgtop($0.sessionName) } == true
        }

        // 2. Match by worktree branch (session has gitBranch matching a card's worktreeLink)
        //    Must also match project path to avoid cross-project matches on common branches like "main"
        if let branch = session.gitBranch {
            let baseName = branch.replacingOccurrences(of: "refs/heads/", with: "")
            if let cardIds = cardIdsByBranch[baseName] {
                let sameProject = cardIds.filter { cardId in
                    guard let link = linksById[cardId], acceptsSession(link) else { return false }
                    guard let sessionPath = session.projectPath else { return true }
                    return link.projectPath == sessionPath
                        || isWorktreeUnder(sessionPath: sessionPath, projectRoot: link.projectPath)
                }
                // Prefer cards that don't already have a session (pending cards)
                let pendingCards = sameProject.filter { linksById[$0]?.sessionLink == nil }
                if let cardId = pendingCards.first {
                    KanbanCodeLog.debug("reconciler", "findCard: session=\(session.id.prefix(8)) matched by branch=\(baseName) → card=\(cardId.prefix(12))")
                    return cardId
                }
                if let cardId = sameProject.first {
                    KanbanCodeLog.debug("reconciler", "findCard: session=\(session.id.prefix(8)) matched by branch=\(baseName) (existing) → card=\(cardId.prefix(12))")
                    return cardId
                }
            }
        }

        // 3. Match by project path + tmux (card has tmuxLink, same project, no sessionLink yet)
        //    Also matches when session is in a worktree under the card's project
        //    (e.g., session in <project>/.claude/worktrees/<name> matches card with projectPath=<project>)
        if let projectPath = session.projectPath {
            let candidates = linksById.values.filter { link in
                link.tmuxLink != nil
                    && link.sessionLink == nil
                    && acceptsSession(link)
                    && (link.projectPath == projectPath
                        || isWorktreeUnder(sessionPath: projectPath, projectRoot: link.projectPath))
                    && startedAfterLaunch(session: session, link: link)
            }
            if let link = newestLaunch(candidates) {
                KanbanCodeLog.debug("reconciler", "findCard: session=\(session.id.prefix(8)) matched by projectPath+tmux → card=\(link.id.prefix(12)) (tmux=\(link.tmuxLink?.sessionName ?? "?"))")
                return link.id
            }
            // Log when no match found for debugging
            let tmuxCards = linksById.values.filter { $0.tmuxLink != nil && $0.sessionLink == nil }
            if !tmuxCards.isEmpty {
                for card in tmuxCards {
                    KanbanCodeLog.debug("reconciler", "findCard: session=\(session.id.prefix(8)) projectPath=\(projectPath) — tmux card=\(card.id.prefix(12)) has projectPath=\(card.projectPath ?? "nil") (no match)")
                }
            }
        }

        // 3b. Match worktree sessions by project root extracted from directory name.
        //     When the session file is just created (no cwd yet), metadata.projectPath is nil.
        //     The directory name encodes the full path including worktree, so we extract the
        //     project root from it and match against launching cards.
        if let sessionPath = session.jsonlPath {
            let dirName = URL(fileURLWithPath: sessionPath).deletingLastPathComponent().lastPathComponent
            // Claude encodes ".claude/worktrees/name" as "--claude-worktrees-name" in directory names
            if let worktreeRange = dirName.range(of: "--claude-worktrees-") {
                let rootEncodedName = String(dirName[dirName.startIndex..<worktreeRange.lowerBound])
                let projectRoot = JsonlParser.decodeDirectoryName(rootEncodedName)
                let candidates = linksById.values.filter { link in
                    link.tmuxLink != nil
                        && link.sessionLink == nil
                        && acceptsSession(link)
                        && link.projectPath == projectRoot
                        && startedAfterLaunch(session: session, link: link)
                }
                if let link = newestLaunch(candidates) {
                    KanbanCodeLog.debug("reconciler", "findCard: session=\(session.id.prefix(8)) matched by worktree dir name → card=\(link.id.prefix(12))")
                    return link.id
                }
            }
        }

        // 4. Match by project path for cards that already have a session + active tmux.
        //    When a new Claude session starts in a card's tmux terminal (primary or shell tab),
        //    match it to the existing card to prevent duplicates.
        //    The card keeps its original sessionLink — we just suppress a new card.
        if let projectPath = session.projectPath {
            let candidates = linksById.values.filter { link in
                link.tmuxLink != nil
                    && link.sessionLink != nil
                    && acceptsSession(link)
                    && (link.projectPath == projectPath
                        || isWorktreeUnder(sessionPath: projectPath, projectRoot: link.projectPath))
            }
            if let link = newestLaunch(candidates) {
                KanbanCodeLog.debug("reconciler", "findCard: session=\(session.id.prefix(8)) matched by projectPath+tmux (existing session) → card=\(link.id.prefix(12))")
                return link.id
            }
        }

        KanbanCodeLog.debug("reconciler", "findCard: session=\(session.id.prefix(8)) projectPath=\(session.projectPath ?? "nil") → NO MATCH")
        return nil
    }

    /// How far before a card's launch a session may have been written and
    /// still count as that launch's session. Covers a card whose `updatedAt`
    /// stands in for a launch it does not record, and clock jitter between
    /// the app and the file system.
    private static let launchMatchTolerance: TimeInterval = 120

    /// Whether this session can be the one the card's launch started.
    ///
    /// Project path alone puts every session of a busy project in reach of a
    /// card that waits for one, including sessions last written days before
    /// the card existed. The session a launch starts is always written after
    /// the launch, so anything older belongs to somebody else.
    private static func startedAfterLaunch(session: Session, link: Link) -> Bool {
        session.modifiedTime >= link.launchAnchor.addingTimeInterval(-launchMatchTolerance)
    }

    /// The most recently launched of several candidate cards.
    ///
    /// Two cards launched in the same project both accept a session by
    /// project path, and dictionary order decides nothing useful. The newer
    /// launch is the one a session appearing now most likely came from.
    private static func newestLaunch(_ candidates: some Collection<Link>) -> Link? {
        candidates.max { lhs, rhs in
            if lhs.launchAnchor != rhs.launchAnchor { return lhs.launchAnchor < rhs.launchAnchor }
            return lhs.id < rhs.id
        }
    }

    /// Check if sessionPath is a worktree directory under a project root.
    /// e.g., sessionPath = "/path/to/project/.claude/worktrees/my-branch"
    ///        projectRoot = "/path/to/project"
    private static func isWorktreeUnder(sessionPath: String, projectRoot: String?) -> Bool {
        guard let projectRoot else { return false }
        return sessionPath.hasPrefix(projectRoot + "/.claude/worktrees/")
    }
}
