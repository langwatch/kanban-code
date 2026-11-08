import Foundation

/// Card sync between masters: which fields each master may write, how two
/// versions of a card merge, and how local edits get stamped.
///
/// A card has one owner, the master that runs its heavy state. Its fields
/// fall in two groups:
/// - owner fields (session, terminals, worktree, launch state, queued
///   prompts, machine): only the owner writes them, versioned by `ownerRev`,
///   and a merge takes them only from a version the owner stamped;
/// - shared fields (name, column, order, pin, archive, prompt, parent...):
///   any master edits them, each field versioned on its own in `fieldRevs`,
///   last writer wins per field. `rev` is the newest of those stamps.
/// A deletion is a shared edit of `deletedAt`: it wins over older edits and
/// loses to newer ones, since every edit of a live card also stamps
/// `deletedAt` (as "still alive").
///
/// The merge picks each shared field, and the owner group, from the version
/// with the higher stamp, so applying the same versions in any order, any
/// number of times, lands on the same card.
public enum LinkSync {
    /// Tombstones older than this are dropped, and ignored when a peer sends one.
    public static let tombstoneLifetime: TimeInterval = 30 * 24 * 3600

    // MARK: - Field groups

    /// One shared field: its property name, and how to compare and copy it.
    struct SharedField: Sendable {
        let name: String
        let same: @Sendable (Link, Link) -> Bool
        let copy: @Sendable (Link, inout Link) -> Void

        init<T: Equatable & Sendable>(_ name: String, _ key: WritableKeyPath<Link, T> & Sendable) {
            self.name = name
            self.same = { $0[keyPath: key] == $1[keyPath: key] }
            self.copy = { src, dst in dst[keyPath: key] = src[keyPath: key] }
        }
    }

    static let sharedFields: [SharedField] = [
        SharedField("name", \.name),
        SharedField("column", \.column),
        SharedField("manualOverrides", \.manualOverrides),
        SharedField("manuallyArchived", \.manuallyArchived),
        SharedField("promptBody", \.promptBody),
        SharedField("promptImagePaths", \.promptImagePaths),
        SharedField("parentCardId", \.parentCardId),
        SharedField("modelOverride", \.modelOverride),
        SharedField("selfCompactContextThresholdTokens", \.selfCompactContextThresholdTokens),
        SharedField("prLinks", \.prLinks),
        SharedField("issueLink", \.issueLink),
        SharedField("sortOrder", \.sortOrder),
        SharedField("pinnedAt", \.pinnedAt),
        SharedField("pinnedSortOrder", \.pinnedSortOrder),
        SharedField("assistant", \.assistant),
        SharedField("deletedAt", \.deletedAt),
    ]

    /// The stamp of shared field `name` in `link`: its own stamp, or `rev`
    /// for a card written before per-field stamps.
    public static func fieldStamp(_ name: String, of link: Link) -> SyncStamp? {
        link.fieldRevs?[name] ?? (link.fieldRevs == nil ? link.rev : nil)
    }

    /// Every shared field's stamp, spelled out (cards written before
    /// per-field stamps get `rev` for each field). nil when nothing is stamped.
    static func explicitFieldRevs(of link: Link) -> [String: SyncStamp]? {
        var out: [String: SyncStamp] = [:]
        for f in sharedFields {
            if let s = fieldStamp(f.name, of: link) { out[f.name] = s }
        }
        return out.isEmpty ? nil : out
    }

    /// Names of the shared fields that differ between `a` and `b`.
    public static func changedSharedFields(_ a: Link, _ b: Link) -> [String] {
        sharedFields.filter { !$0.same(a, b) }.map(\.name)
    }

    /// Copies the shared fields (and the deletion mark) of `src` into `dst`.
    public static func copyShared(from src: Link, to dst: inout Link) {
        for f in sharedFields { f.copy(src, &dst) }
    }

    /// Copies the owner fields of `src` into `dst`.
    public static func copyOwned(from src: Link, to dst: inout Link) {
        dst.projectPath = src.projectPath
        dst.source = src.source
        dst.createdAt = src.createdAt
        dst.lastActivity = src.lastActivity
        dst.sessionLink = src.sessionLink
        dst.tmuxLink = src.tmuxLink
        dst.worktreeLink = src.worktreeLink
        dst.queuedPrompts = src.queuedPrompts
        dst.discoveredBranches = src.discoveredBranches
        dst.discoveredRepos = src.discoveredRepos
        dst.isRemote = src.isRemote
        dst.remote = src.remote
        dst.apiServiceId = src.apiServiceId
        dst.isLaunching = src.isLaunching
        dst.launchedAt = src.launchedAt
        dst.headless = src.headless
        dst.ownerMachine = src.ownerMachine
        dst.migrating = src.migrating
    }

    public static func sharedEqual(_ a: Link, _ b: Link) -> Bool {
        sharedFields.allSatisfy { $0.same(a, b) }
    }

    public static func ownedEqual(_ a: Link, _ b: Link) -> Bool {
        a.projectPath == b.projectPath
            && a.source == b.source
            && a.createdAt == b.createdAt
            && a.lastActivity == b.lastActivity
            && a.sessionLink == b.sessionLink
            && a.tmuxLink == b.tmuxLink
            && a.worktreeLink == b.worktreeLink
            && a.queuedPrompts == b.queuedPrompts
            && a.discoveredBranches == b.discoveredBranches
            && a.discoveredRepos == b.discoveredRepos
            && a.isRemote == b.isRemote
            && a.remote == b.remote
            && a.apiServiceId == b.apiServiceId
            && a.isLaunching == b.isLaunching
            && a.launchedAt == b.launchedAt
            && a.headless == b.headless
            && a.ownerMachine == b.ownerMachine
            && a.migrating == b.migrating
    }

    /// Property names per group; a test checks every `Link` property sits in
    /// exactly one of them, so a new field cannot silently skip sync.
    static var sharedFieldNames: Set<String> { Set(sharedFields.map(\.name)) }
    static let ownedFieldNames: Set<String> = [
        "projectPath", "source", "createdAt", "lastActivity", "sessionLink", "tmuxLink", "worktreeLink",
        "queuedPrompts", "discoveredBranches", "discoveredRepos", "isRemote", "remote", "apiServiceId",
        "isLaunching", "launchedAt", "headless", "ownerMachine", "migrating",
    ]
    /// Per-machine fields that never travel, plus the sync metadata.
    static let localFieldNames: Set<String> = [
        "id", "updatedAt", "lastOpenedAt", "browserTabs", "rev", "ownerRev", "fieldRevs",
    ]

    // MARK: - Ownership

    /// The machine that owns `link`; nil `ownerMachine` means this machine.
    public static func owner(of link: Link, localMachine: String) -> String {
        link.ownerMachine ?? localMachine
    }

    public static func isOwnedLocally(_ link: Link, localMachine: String) -> Bool {
        guard let owner = link.ownerMachine else { return true }
        return owner == localMachine
    }

    // MARK: - Tombstones

    /// The tombstone a deletion stamped `rev` leaves: every field stays
    /// (an edit that brings the card back only brings the fields it wrote),
    /// `deletedAt` is set and stamped.
    public static func tombstone(of link: Link, deletedAt: Date, rev: SyncStamp?) -> Link {
        var t = link
        var revs = explicitFieldRevs(of: link) ?? [:]
        if let rev { revs["deletedAt"] = rev }
        t.fieldRevs = revs.isEmpty ? nil : revs
        t.deletedAt = deletedAt
        t.rev = [link.rev, rev].compactMap { $0 }.max()
        t.browserTabs = nil
        t.lastOpenedAt = nil
        // Nothing brings back a headless run nobody claimed: its prompt
        // would only weigh on every peer for the tombstone's lifetime.
        if link.isUnclaimedHeadless { t.promptBody = nil }
        return t
    }

    public static func isExpired(_ link: Link, now: Date) -> Bool {
        guard let deletedAt = link.deletedAt else { return false }
        return now.timeIntervalSince(deletedAt) > tombstoneLifetime
    }

    // MARK: - Merge

    /// Merges a version of a card sent by `peer` into the local record
    /// (a live card, a tombstone, or nil when this machine never saw it).
    /// Returns the new local record.
    ///
    /// - A card this machine owns and is launching is left alone.
    /// - Each shared field comes from the version with the higher stamp for
    ///   that field.
    /// - Owner fields come from the incoming version only when its `ownerRev`
    ///   is newer and was stamped by the card's current owner as this
    ///   machine knows it. An ownership release is written by the old owner,
    ///   so it passes; the adopting machine's writes pass once the release
    ///   landed here.
    public static func merge(
        local: Link?,
        incoming raw: Link,
        from peer: String,
        localMachine: String,
        now: Date
    ) -> Link? {
        var incoming = raw
        if incoming.ownerMachine == nil { incoming.ownerMachine = peer }
        incoming.browserTabs = nil
        incoming.lastOpenedAt = nil

        if isExpired(incoming, now: now) { return local }
        guard let local else {
            incoming.updatedAt = now
            return incoming
        }
        if local.isLaunching == true, !local.isTombstone,
           isOwnedLocally(local, localMachine: localMachine) {
            return local
        }

        var result = local
        // Stamps are only spelled out once a field actually moves, so a
        // version with nothing newer leaves the local record as it was.
        if sharedFields.contains(where: { Optional.isNewer(fieldStamp($0.name, of: incoming), than: fieldStamp($0.name, of: local)) }) {
            var revs: [String: SyncStamp] = [:]
            for f in sharedFields {
                let mine = fieldStamp(f.name, of: local)
                let theirs = fieldStamp(f.name, of: incoming)
                if Optional.isNewer(theirs, than: mine) {
                    f.copy(incoming, &result)
                    revs[f.name] = theirs
                } else if let mine {
                    revs[f.name] = mine
                }
            }
            result.fieldRevs = revs
            result.rev = revs.values.max()
        }
        let currentOwner = owner(of: local, localMachine: localMachine)
        if Optional.isNewer(incoming.ownerRev, than: local.ownerRev),
           incoming.ownerRev?.machine == currentOwner {
            copyOwned(from: incoming, to: &result)
            result.ownerRev = incoming.ownerRev
        }
        if result.isTombstone {
            result.browserTabs = nil
            result.lastOpenedAt = nil
        }
        if result != local { result.updatedAt = max(now, local.updatedAt) }
        return result
    }

    public struct MergeOutcome: Sendable {
        public var links: [String: Link]
        public var tombstones: [String: Link]
        /// Ids whose local record changed.
        public var changedIds: Set<String>
        /// Live cards this machine owned that an incoming tombstone deleted.
        public var deletedOwned: [Link]
        /// The Lamport clock after seeing every incoming stamp.
        public var clock: Int
    }

    /// Merges a page of versions from `peer` into the local cards and
    /// tombstones, dropping expired tombstones on the way.
    public static func mergePage(
        _ incoming: [Link],
        from peer: String,
        links: [String: Link],
        tombstones: [String: Link],
        localMachine: String,
        clock: Int,
        now: Date
    ) -> MergeOutcome {
        var out = MergeOutcome(links: links, tombstones: tombstones, changedIds: [], deletedOwned: [], clock: clock)
        for version in incoming {
            out.clock = max(out.clock, version.rev?.counter ?? 0, version.ownerRev?.counter ?? 0)
            let id = version.id
            let local = out.links[id] ?? out.tombstones[id]
            guard let merged = merge(local: local, incoming: version, from: peer, localMachine: localMachine, now: now),
                  merged != local
            else { continue }
            out.changedIds.insert(id)
            if merged.isTombstone {
                if let live = out.links.removeValue(forKey: id),
                   isOwnedLocally(live, localMachine: localMachine) {
                    out.deletedOwned.append(live)
                }
                out.tombstones[id] = merged
            } else {
                out.tombstones.removeValue(forKey: id)
                out.links[id] = merged
            }
        }
        for (id, t) in out.tombstones where isExpired(t, now: now) {
            out.tombstones.removeValue(forKey: id)
        }
        return out
    }

    /// The pull requests of `current` after a poll found `polled` for it:
    /// known ones take the fresh status, new ones are added unless the user
    /// dismissed them, and none is removed.
    public static func mergedPRLinks(current: Link, polled: [PRLink]) -> [PRLink] {
        var out = current.prLinks
        for pr in polled {
            if let i = out.firstIndex(where: { $0.number == pr.number }) {
                out[i].status = pr.status
                out[i].title = pr.title
                out[i].url = pr.url
                out[i].mergeStateStatus = pr.mergeStateStatus
            } else if !current.manualOverrides.isPRDismissed(pr.number) {
                out.append(pr)
            }
        }
        return out
    }

    // MARK: - Local edits

    /// Actions a user takes on a card's shared fields. On a card another
    /// master owns, only these may change it (and never its owner fields);
    /// every other action (reconcile, liveness scans, launches...) leaves
    /// foreign cards exactly as their owner sent them.
    public static func allowsForeignEdits(_ action: Action) -> Bool {
        switch action {
        case .moveCard, .renameCard, .setCardPinned, .setSelfCompactContextThreshold, .setCardModel,
             .archiveCard, .unarchiveCard, .deleteCard, .reorderCard, .reorderPinnedCard, .updatePrompt,
             .addIssueLinkToCard, .addPRToCard, .markPRMerged, .unlinkFromCard, .createManualTask:
            return true
        default:
            return false
        }
    }

    /// Whether a served card is worth sending to peers: tombstones, every
    /// card someone placed on the board, and archived cards, so an archive
    /// reaches the peers even when the card was only a discovered
    /// transcript. Discovered transcripts nobody touched stay home.
    public static func isServed(_ link: Link) -> Bool {
        link.isTombstone || link.isClaimed || link.manuallyArchived || link.column != .allSessions
    }
}

// MARK: - AppState sync bookkeeping

extension AppState {
    /// Next Lamport stamp of this machine.
    func nextSyncStamp() -> SyncStamp {
        syncClock += 1
        return SyncStamp(counter: syncClock, machine: localMachineId)
    }

    /// Records that `id` changed, for the delta a peer pulls next.
    func markSyncChanged(_ id: String) {
        syncSeq += 1
        linkSeqs[id] = syncSeq
    }

    public func isOwnedLocally(_ link: Link) -> Bool {
        LinkSync.isOwnedLocally(link, localMachine: localMachineId)
    }

    /// Whether this master polls GitHub for pull requests (see
    /// `MasterRoles.prPollingLeader`). A master with no identity yet is alone.
    public var isPRPollingLeader: Bool {
        guard let local = localMachineIdentity else { return true }
        return MasterRoles.prPollingLeader(local: local, peers: Array(peerStatuses.values)) == local.id
    }

    /// Takes the tombstones and clock from what links.json held at startup.
    public func loadSyncState(tombstones stored: [Link], now: Date = .now) {
        var kept: [String: Link] = [:]
        for t in stored where t.isTombstone && !LinkSync.isExpired(t, now: now) && links[t.id] == nil {
            kept[t.id] = t
        }
        tombstones = kept
        var clock = syncClock
        for link in links.values {
            clock = max(clock, link.rev?.counter ?? 0, link.ownerRev?.counter ?? 0)
        }
        for t in kept.values {
            clock = max(clock, t.rev?.counter ?? 0, t.ownerRev?.counter ?? 0)
        }
        syncClock = clock
    }

    /// The page a peer gets from `GET /v1/links?since=&epoch=`: every served
    /// card and tombstone when the epoch differs (or none was sent), else
    /// those changed after `since`. Cards this machine owns go out with its
    /// id as `ownerMachine`.
    public func linksPage(machine: MachineIdentity, since: Int?, epoch: String?) -> LinksPage {
        let full = since == nil || epoch != syncEpoch
        let threshold = full ? Int.min : since!
        var out: [Link] = []
        func add(_ link: Link) {
            guard LinkSync.isServed(link) else { return }
            if !full, (linkSeqs[link.id] ?? 0) <= threshold { return }
            var copy = link
            if copy.ownerMachine == nil { copy.ownerMachine = machine.id }
            copy.browserTabs = nil
            copy.lastOpenedAt = nil
            out.append(copy)
        }
        for link in links.values { add(link) }
        for t in tombstones.values { add(t) }
        out.sort { $0.id < $1.id }
        return LinksPage(machine: machine, epoch: syncEpoch, seq: syncSeq, full: full, links: out)
    }
}

// MARK: - Reducer hooks

extension Reducer {
    /// Stamps what `action` changed in the cards, and holds foreign cards to
    /// what their owner sent. Runs after every action that persists cards.
    ///
    /// For each changed card: a card another master owns is put back as it
    /// was unless the action is a user edit of shared fields, and even then
    /// its owner fields are put back. Then `rev` is stamped when a shared
    /// field changed and `ownerRev` when an owner field of a card this
    /// machine owns changed. A card that disappeared leaves a tombstone.
    static func stampLocalChanges(state: AppState, before: [String: Link], action: Action, effects: [Effect]) -> [Effect] {
        var fullScan = false
        var upserted: Set<String> = []
        for effect in effects {
            switch effect {
            case .persistLinks, .removeLink: fullScan = true
            case .upsertLink(let link): upserted.insert(link.id)
            default: break
            }
        }
        guard fullScan || !upserted.isEmpty else { return effects }

        let allowsForeign = LinkSync.allowsForeignEdits(action)
        var linksRewritten = false
        var tombstonesChanged = false
        var restoredRemovals: Set<String> = []

        func stamp(_ id: String, _ after: Link) {
            let old = before[id]
            if let old, old == after { return }
            var link = after
            let owned = state.isOwnedLocally(old ?? after)
            if !owned, let old {
                if !allowsForeign {
                    // The master that polls GitHub keeps every card's pull
                    // requests, its own or not; nothing else a background
                    // pass does touches a card another master runs.
                    guard case .reconciled = action, state.isPRPollingLeader, old.prLinks != after.prLinks else {
                        state.links[id] = old
                        linksRewritten = true
                        return
                    }
                    link = old
                    link.prLinks = after.prLinks
                }
                LinkSync.copyOwned(from: old, to: &link)
            }
            if old == nil, state.tombstones.removeValue(forKey: id) != nil {
                tombstonesChanged = true
            }
            let changedFields = old.map { LinkSync.changedSharedFields($0, link) }
                ?? LinkSync.sharedFields.map(\.name)
            let sharedChanged = !changedFields.isEmpty
            let ownedChanged = owned && (old.map { !LinkSync.ownedEqual($0, link) } ?? true)
            if sharedChanged {
                let s = state.nextSyncStamp()
                var revs = old.flatMap { LinkSync.explicitFieldRevs(of: $0) } ?? [:]
                for name in changedFields { revs[name] = s }
                // Any edit of a live card says it is alive: it wins over an
                // older deletion made on another master.
                revs["deletedAt"] = s
                link.fieldRevs = revs
                link.rev = s
            }
            if ownedChanged { link.ownerRev = state.nextSyncStamp() }
            if sharedChanged || ownedChanged { state.markSyncChanged(id) }
            if link != after {
                state.links[id] = link
                linksRewritten = true
            }
        }

        if fullScan {
            for (id, after) in state.links { stamp(id, after) }
            let now = Date()
            for (id, old) in before where state.links[id] == nil {
                if !state.isOwnedLocally(old), !allowsForeign {
                    state.links[id] = old
                    restoredRemovals.insert(id)
                    linksRewritten = true
                    continue
                }
                state.tombstones[id] = LinkSync.tombstone(of: old, deletedAt: now, rev: state.nextSyncStamp())
                state.markSyncChanged(id)
                tombstonesChanged = true
            }
        } else {
            for id in upserted {
                if let after = state.links[id] { stamp(id, after) }
            }
        }

        guard linksRewritten || tombstonesChanged else { return effects }
        var out: [Effect] = effects.compactMap { effect in
            switch effect {
            case .upsertLink(let link):
                return .upsertLink(state.links[link.id] ?? link)
            case .persistLinks:
                return .persistLinks(Array(state.links.values))
            case .removeLink(let id):
                return restoredRemovals.contains(id) ? nil : effect
            default:
                return effect
            }
        }
        if tombstonesChanged {
            out.append(.persistTombstones(Array(state.tombstones.values)))
        }
        return out
    }

    /// `.peerLinksMerged`: merges a peer's page into the board. A tombstone
    /// that deletes a card this machine runs also stops its terminals and
    /// keeps the reconciler from bringing it back.
    static func reducePeerLinksMerged(state: AppState, peer: String, incoming: [Link]) -> [Effect] {
        let outcome = LinkSync.mergePage(
            incoming, from: peer,
            links: state.links, tombstones: state.tombstones,
            localMachine: state.localMachineId, clock: state.syncClock, now: Date())
        state.syncClock = outcome.clock
        let tombstonesPruned = outcome.tombstones.count != state.tombstones.count
        guard !outcome.changedIds.isEmpty || tombstonesPruned else { return [] }

        let before = state.links
        state.links = outcome.links
        state.tombstones = outcome.tombstones
        for id in outcome.changedIds.sorted() { state.markSyncChanged(id) }

        var effects: [Effect] = []
        // A card this master runs, archived on another master: its sessions
        // end here, as an archive here ends them.
        for id in outcome.changedIds.sorted() {
            guard let link = state.links[id], link.manuallyArchived, before[id]?.manuallyArchived == false,
                  link.ownerMachine == nil || link.ownerMachine == state.localMachineId,
                  let tmux = link.tmuxLink else { continue }
            effects.append(.killTmuxSessions(tmux.allSessionNames))
            effects.append(.cleanupTerminalCache(sessionNames: tmux.allSessionNames))
        }
        for link in outcome.deletedOwned {
            state.deletedCardIds.insert(link.id)
            if let sessionId = link.sessionLink?.sessionId { state.deletedSessionIds.insert(sessionId) }
            if let tmux = link.tmuxLink {
                effects.append(.killTmuxSessions(tmux.allSessionNames))
                effects.append(.cleanupTerminalCache(sessionNames: tmux.allSessionNames))
            }
        }
        if let selected = state.selectedCardId, state.links[selected] == nil {
            state.selectedCardId = nil
        }
        effects.append(.persistLinks(Array(state.links.values)))
        effects.append(.persistTombstones(Array(state.tombstones.values)))
        return effects
    }
}
