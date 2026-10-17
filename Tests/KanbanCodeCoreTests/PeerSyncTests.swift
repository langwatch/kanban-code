import Testing
import Foundation
@testable import KanbanCodeCore
import KanbanCodeRemoteKit

// MARK: - Helpers

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func stamp(_ counter: Int, _ machine: String) -> SyncStamp {
    SyncStamp(counter: counter, machine: machine)
}

private func card(
    _ id: String = "card_a",
    name: String? = "Card",
    column: KanbanCodeColumn = .inProgress,
    owner: String? = "A",
    rev: SyncStamp? = nil,
    ownerRev: SyncStamp? = nil,
    tmux: String? = nil,
    session: String? = nil
) -> Link {
    Link(
        id: id,
        name: name,
        projectPath: "/p",
        column: column,
        createdAt: now,
        updatedAt: now,
        source: .manual,
        sessionLink: session.map { SessionLink(sessionId: $0) },
        tmuxLink: tmux.map { TmuxLink(sessionName: $0) },
        ownerMachine: owner,
        rev: rev,
        ownerRev: ownerRev
    )
}

private func state(machine: String, _ links: [Link]) -> AppState {
    let s = AppState()
    s.localMachineId = machine
    for link in links { s.links[link.id] = link }
    s.loadSyncState(tombstones: [])
    s.rebuildCards()
    return s
}

/// Applies versions in order, the way a machine sees them arrive.
private func applyAll(
    _ versions: [(Link, String)],
    to local: Link?,
    machine: String
) -> Link? {
    var current = local
    for (version, peer) in versions {
        current = LinkSync.merge(local: current, incoming: version, from: peer, localMachine: machine, now: now)
    }
    return current
}

private func permutations<T>(_ items: [T]) -> [[T]] {
    guard items.count > 1 else { return [items] }
    var out: [[T]] = []
    for (i, item) in items.enumerated() {
        var rest = items
        rest.remove(at: i)
        for p in permutations(rest) { out.append([item] + p) }
    }
    return out
}

// MARK: - Entities

@Suite("Peer sync: entities and storage")
struct PeerSyncEntityTests {
    @Test("links.json written before peer sync still decodes, with no sync fields")
    func oldLinksDecode() throws {
        let json = """
        {"links":[{"id":"card_old","name":"Old","column":"in_progress","createdAt":"2026-01-01T00:00:00Z",
        "updatedAt":"2026-01-01T00:00:00Z","manualOverrides":{},"manuallyArchived":false,"source":"manual",
        "isRemote":false,"tmuxSession":"old-tmux","sessionId":"s1"}]}
        """
        struct Container: Decodable { let links: [Link] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let link = try decoder.decode(Container.self, from: Data(json.utf8)).links[0]
        #expect(link.id == "card_old")
        #expect(link.tmuxLink?.sessionName == "old-tmux")
        #expect(link.ownerMachine == nil)
        #expect(link.rev == nil)
        #expect(link.ownerRev == nil)
        #expect(link.deletedAt == nil)
        #expect(link.migrating == nil)
        #expect(!link.isTombstone)
    }

    @Test("sync fields round-trip through Codable, and a bad stamp does not lose the card")
    func syncFieldsRoundTrip() throws {
        var link = card(rev: stamp(3, "A"), ownerRev: stamp(4, "A"))
        link.migrating = true
        link.deletedAt = now
        let data = try JSONEncoder().encode(link)
        let back = try JSONDecoder().decode(Link.self, from: data)
        #expect(back.rev == stamp(3, "A"))
        #expect(back.ownerRev == stamp(4, "A"))
        #expect(back.ownerMachine == "A")
        #expect(back.migrating == true)
        #expect(back.deletedAt != nil)

        let broken = #"{"id":"card_x","rev":"not a stamp","ownerRev":12}"#
        let decoded = try JSONDecoder().decode(Link.self, from: Data(broken.utf8))
        #expect(decoded.id == "card_x")
        #expect(decoded.rev == nil)
    }

    @Test("every Link property belongs to exactly one sync group")
    func fieldGroupsCoverLink() {
        let names = Set(Mirror(reflecting: card()).children.compactMap(\.label))
        let groups = [LinkSync.sharedFieldNames, LinkSync.ownedFieldNames, LinkSync.localFieldNames]
        let all = groups.reduce(Set<String>()) { $0.union($1) }
        #expect(names.subtracting(all).isEmpty, "unclassified: \(names.subtracting(all).sorted())")
        #expect(all.subtracting(names).isEmpty, "unknown: \(all.subtracting(names).sorted())")
        #expect(groups.map(\.count).reduce(0, +) == all.count, "a field sits in two groups")
    }

    @Test("copyShared and copyOwned move exactly their group")
    func copyGroups() {
        var a = card("card_a", name: "A name", column: .done, owner: "A", tmux: "ta", session: "sa")
        a.sortOrder = 3
        a.queuedPrompts = [QueuedPrompt(id: "q", body: "hi")]
        var b = card("card_a", name: "B name", column: .backlog, owner: "B", tmux: "tb", session: "sb")
        var shared = b
        LinkSync.copyShared(from: a, to: &shared)
        #expect(shared.name == "A name" && shared.column == .done && shared.sortOrder == 3)
        #expect(shared.tmuxLink?.sessionName == "tb" && shared.ownerMachine == "B" && shared.queuedPrompts == nil)
        #expect(LinkSync.sharedEqual(shared, a))
        #expect(!LinkSync.ownedEqual(shared, a))
        LinkSync.copyOwned(from: a, to: &b)
        #expect(b.tmuxLink?.sessionName == "ta" && b.sessionLink?.sessionId == "sa" && b.ownerMachine == "A")
        #expect(b.name == "B name")
        #expect(LinkSync.ownedEqual(b, a))
    }

    @Test("machine identity is created once and kept")
    func machineIdentity() throws {
        let dir = NSTemporaryDirectory() + "peer-sync-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = MachineIdentityStore(basePath: dir)
        #expect(store.read() == nil)
        let first = store.loadOrCreate(defaultName: "mac")
        #expect(first.id.hasPrefix("machine"))
        #expect(first.name == "mac")
        #expect(store.loadOrCreate(defaultName: "other") == first)
        let renamed = try store.rename(to: "studio")
        #expect(renamed.id == first.id && renamed.name == "studio")
        #expect(MachineIdentityStore(basePath: dir).read() == renamed)
    }

    @Test("a broken machine.json is backed up and replaced")
    func brokenMachineIdentity() throws {
        let dir = NSTemporaryDirectory() + "peer-sync-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try Data("{nope".utf8).write(to: URL(fileURLWithPath: dir + "/machine.json"))
        let identity = MachineIdentityStore(basePath: dir).loadOrCreate(defaultName: "box")
        #expect(identity.name == "box")
        #expect(FileManager.default.fileExists(atPath: dir + "/machine.json.bkp"))
    }

    @Test("peers settings round-trip, and old settings have none")
    func peersSettings() async throws {
        let dir = NSTemporaryDirectory() + "peer-sync-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = SettingsStore(basePath: dir)
        var settings = try await store.read()
        #expect(settings.peers.isEmpty)
        settings.peers = [PeerConfig(id: "peer_1", name: "box", url: "http://100.114.220.85:7780", token: "kc_x")]
        try await store.write(settings)
        await store.invalidateCache()
        let back = try await store.read()
        #expect(back.peers == settings.peers)

        let old = #"{"projects":[]}"#
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(old.utf8))
        #expect(decoded.peers.isEmpty)
        let partial = #"{"peers":[{"name":"box","url":"http://h:1","token":"t"}]}"#
        let peer = try JSONDecoder().decode(Settings.self, from: Data(partial.utf8)).peers[0]
        #expect(peer.enabled && peer.id.hasPrefix("peer") && peer.url == "http://h:1")
    }

    @Test("tombstones persist next to links.json without touching it")
    func tombstonesPersist() async throws {
        let dir = NSTemporaryDirectory() + "peer-sync-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = CoordinationStore(basePath: dir)
        try await store.writeLinks([card("card_live")])
        #expect(try await store.readTombstones().isEmpty)
        let t = LinkSync.tombstone(of: card("card_gone"), deletedAt: now, rev: stamp(9, "A"))
        try await store.writeTombstones([t])
        try await store.writeLinks([card("card_live"), card("card_new")])
        let tombstones = try await store.readTombstones()
        #expect(tombstones.map(\.id) == ["card_gone"])
        #expect(tombstones[0].rev == stamp(9, "A"))
        #expect(try await store.readLinks().map(\.id).sorted() == ["card_live", "card_new"])
    }
}

// MARK: - Merge

@Suite("Peer sync: merge")
struct LinkSyncMergeTests {
    @Test("a card never seen is taken as the peer sent it, owned by the peer when unset")
    func newCard() {
        var incoming = card(owner: nil, rev: stamp(1, "B"))
        incoming.browserTabs = [BrowserTabInfo(url: "https://x")]
        let merged = LinkSync.merge(local: nil, incoming: incoming, from: "B", localMachine: "M", now: now)
        #expect(merged?.ownerMachine == "B")
        #expect(merged?.name == "Card")
        #expect(merged?.browserTabs == nil)
    }

    @Test("shared fields: the higher rev wins, ties broken by machine id")
    func sharedLWW() {
        let local = card(name: "local", owner: "A", rev: stamp(5, "M"))
        let older = card(name: "older", owner: "A", rev: stamp(4, "B"))
        let newer = card(name: "newer", owner: "A", rev: stamp(6, "B"))
        let tie = card(name: "tie", owner: "A", rev: stamp(5, "Z"))
        #expect(LinkSync.merge(local: local, incoming: older, from: "B", localMachine: "M", now: now)?.name == "local")
        #expect(LinkSync.merge(local: local, incoming: newer, from: "B", localMachine: "M", now: now)?.name == "newer")
        #expect(LinkSync.merge(local: local, incoming: tie, from: "B", localMachine: "M", now: now)?.name == "tie")
    }

    @Test("owner fields from a machine that does not own the card are refused")
    func ownerFieldsRefusedFromNonOwner() {
        // M owns the card; B sends newer owner fields it stamped itself.
        let local = card(owner: nil, rev: stamp(1, "M"), ownerRev: stamp(2, "M"), tmux: "mine", session: "s-mine")
        let forged = card(owner: "B", rev: stamp(1, "M"), ownerRev: stamp(50, "B"), tmux: "theirs", session: "s-theirs")
        let merged = LinkSync.merge(local: local, incoming: forged, from: "B", localMachine: "M", now: now)
        #expect(merged == local)

        // A owns the card; B relays owner fields stamped by B: refused too.
        let foreign = card(owner: "A", ownerRev: stamp(3, "A"), tmux: "a-tmux")
        let relay = card(owner: "A", ownerRev: stamp(9, "B"), tmux: "b-tmux")
        #expect(LinkSync.merge(local: foreign, incoming: relay, from: "B", localMachine: "M", now: now)?.tmuxLink?.sessionName == "a-tmux")
    }

    @Test("owner fields stamped by the owner are taken, even when relayed by another peer")
    func ownerFieldsFromOwner() {
        let local = card(name: "renamed here", owner: "A", rev: stamp(10, "M"), ownerRev: stamp(3, "A"), tmux: "old")
        let fromOwner = card(name: "stale name", owner: "A", rev: stamp(4, "A"), ownerRev: stamp(5, "A"), tmux: "new")
        for peer in ["A", "B"] {
            let merged = LinkSync.merge(local: local, incoming: fromOwner, from: peer, localMachine: "M", now: now)
            #expect(merged?.tmuxLink?.sessionName == "new")
            #expect(merged?.ownerRev == stamp(5, "A"))
            // The shared edit made here is newer and stays.
            #expect(merged?.name == "renamed here")
            #expect(merged?.rev == stamp(10, "M"))
        }
    }

    @Test("a card this machine is launching is left alone")
    func launchingUntouched() {
        var local = card(name: "mine", owner: nil, rev: stamp(1, "M"))
        local.isLaunching = true
        let incoming = card(name: "theirs", owner: "M", rev: stamp(99, "B"))
        #expect(LinkSync.merge(local: local, incoming: incoming, from: "B", localMachine: "M", now: now) == local)

        // A foreign card's launch flag is its owner's, and does not block.
        var foreign = card(name: "a", owner: "A", rev: stamp(1, "A"))
        foreign.isLaunching = true
        let renamed = card(name: "b", owner: "A", rev: stamp(2, "B"))
        #expect(LinkSync.merge(local: foreign, incoming: renamed, from: "B", localMachine: "M", now: now)?.name == "b")
    }

    @Test("a tombstone wins over older revs and loses to newer ones")
    func tombstones() {
        let live = card(name: "live", owner: "A", rev: stamp(5, "A"), ownerRev: stamp(5, "A"), tmux: "t")
        let newerDeath = LinkSync.tombstone(of: live, deletedAt: now, rev: stamp(6, "B"))
        let olderDeath = LinkSync.tombstone(of: live, deletedAt: now, rev: stamp(4, "B"))

        let dead = LinkSync.merge(local: live, incoming: newerDeath, from: "B", localMachine: "M", now: now)
        #expect(dead?.isTombstone == true)
        #expect(dead?.name == "live")
        #expect(dead?.rev == stamp(6, "B"))
        #expect(LinkSync.merge(local: live, incoming: olderDeath, from: "B", localMachine: "M", now: now)?.isTombstone == false)

        // An older edit does not bring the card back; a newer one does.
        let olderEdit = card(name: "old edit", owner: "A", rev: stamp(5, "C"))
        #expect(LinkSync.merge(local: dead, incoming: olderEdit, from: "C", localMachine: "M", now: now)?.isTombstone == true)
        let newerEdit = card(name: "back", owner: "A", rev: stamp(7, "C"))
        let back = LinkSync.merge(local: dead, incoming: newerEdit, from: "C", localMachine: "M", now: now)
        #expect(back?.isTombstone == false)
        #expect(back?.name == "back")
        #expect(back?.tmuxLink?.sessionName == "t")
    }

    @Test("expired tombstones are ignored and pruned")
    func expiredTombstones() {
        let old = now.addingTimeInterval(-LinkSync.tombstoneLifetime - 60)
        let live = card(rev: stamp(1, "A"))
        let expired = LinkSync.tombstone(of: live, deletedAt: old, rev: stamp(9, "B"))
        #expect(LinkSync.merge(local: live, incoming: expired, from: "B", localMachine: "M", now: now) == live)
        let outcome = LinkSync.mergePage(
            [], from: "B", links: [:], tombstones: ["card_a": expired],
            localMachine: "M", clock: 0, now: now)
        #expect(outcome.tombstones.isEmpty)
    }

    @Test("concurrent edits converge whatever the order, and merging again changes nothing")
    func convergesInAnyOrder() {
        let base = card(name: "base", column: .inProgress, owner: "A", rev: stamp(1, "A"), ownerRev: stamp(1, "A"), tmux: "t0")
        var rename = base
        rename.name = "renamed on B"
        rename.rev = stamp(4, "B")
        var move = base
        move.column = .done
        move.manualOverrides.column = true
        move.rev = stamp(4, "C")
        var ownerUpdate = base
        ownerUpdate.tmuxLink = TmuxLink(sessionName: "t1")
        ownerUpdate.lastActivity = now
        ownerUpdate.ownerRev = stamp(3, "A")
        var pin = base
        pin.pinnedAt = now
        pin.rev = stamp(2, "B")
        let delete = LinkSync.tombstone(of: base, deletedAt: now, rev: stamp(3, "C"))

        let versions: [(Link, String)] = [(rename, "B"), (move, "C"), (ownerUpdate, "A"), (pin, "B"), (delete, "C")]
        for machine in ["M", "B"] {
            var results: [Link?] = []
            for order in permutations(versions) {
                let once = applyAll(order, to: base, machine: machine)
                let twice = applyAll(order, to: once, machine: machine)
                #expect(once == twice, "not idempotent for \(machine)")
                results.append(once)
            }
            #expect(Set(results.map { $0.map(\.id) }).count == 1)
            for result in results {
                #expect(result == results[0], "order changed the result on \(machine)")
            }
            // The edit with the highest rev (the move, 4/C beats 4/B) holds
            // the shared fields; the owner's update holds the owner fields.
            #expect(results[0]?.column == .done)
            #expect(results[0]?.name == "base")
            #expect(results[0]?.tmuxLink?.sessionName == "t1")
        }
    }

    @Test("two machines exchanging pages end with the same cards")
    func twoMachinesConverge() {
        // A owns card_1, B owns card_2; both edit shared fields of both.
        let aCards = state(machine: "A", [
            card("card_1", name: "one", owner: nil, rev: stamp(1, "A"), ownerRev: stamp(1, "A"), tmux: "a1"),
        ])
        let bCards = state(machine: "B", [
            card("card_2", name: "two", owner: nil, rev: stamp(1, "B"), ownerRev: stamp(1, "B"), tmux: "b2"),
        ])
        let idA = MachineIdentity(id: "A", name: "a")
        let idB = MachineIdentity(id: "B", name: "b")
        func exchange() {
            _ = Reducer.reduce(state: bCards, action: .peerLinksMerged(peer: "A", links: aCards.linksPage(machine: idA, since: nil, epoch: nil).links))
            _ = Reducer.reduce(state: aCards, action: .peerLinksMerged(peer: "B", links: bCards.linksPage(machine: idB, since: nil, epoch: nil).links))
        }
        exchange()
        _ = Reducer.reduce(state: aCards, action: .renameCard(cardId: "card_2", name: "two, renamed on A"))
        _ = Reducer.reduce(state: bCards, action: .moveCard(cardId: "card_1", to: .done))
        _ = Reducer.reduce(state: bCards, action: .renameCard(cardId: "card_1", name: "one, renamed on B"))
        exchange()
        exchange()

        for id in ["card_1", "card_2"] {
            let a = aCards.links[id]!
            let b = bCards.links[id]!
            #expect(a.name == b.name)
            #expect(a.column == b.column)
            #expect(a.rev == b.rev)
            #expect(a.ownerRev == b.ownerRev)
            #expect(a.tmuxLink == b.tmuxLink)
            #expect(LinkSync.owner(of: a, localMachine: "A") == LinkSync.owner(of: b, localMachine: "B"))
        }
        #expect(aCards.links["card_1"]?.name == "one, renamed on B")
        #expect(aCards.links["card_1"]?.column == .done)
        #expect(bCards.links["card_2"]?.name == "two, renamed on A")
        #expect(bCards.links["card_1"]?.tmuxLink?.sessionName == "a1")
    }

    @Test("merging bumps the Lamport clock past every stamp seen")
    func clockAdvances() {
        let s = state(machine: "M", [])
        _ = Reducer.reduce(state: s, action: .peerLinksMerged(peer: "B", links: [card(owner: "B", rev: stamp(41, "B"), ownerRev: stamp(42, "B"))]))
        #expect(s.syncClock == 42)
        _ = Reducer.reduce(state: s, action: .renameCard(cardId: "card_a", name: "x"))
        #expect(s.links["card_a"]?.rev == stamp(43, "M"))
    }
}

// MARK: - Reducer

@Suite("Peer sync: reducer")
struct PeerSyncReducerTests {
    @Test("local edits stamp rev, owner-field changes stamp ownerRev")
    func localEditsStamp() {
        let s = state(machine: "M", [card(owner: nil, tmux: "t")])
        let effects = Reducer.reduce(state: s, action: .renameCard(cardId: "card_a", name: "new name"))
        let renamed = s.links["card_a"]!
        #expect(renamed.rev == stamp(1, "M"))
        #expect(renamed.ownerRev == nil)
        // The persisted copy carries the stamp.
        let persisted = effects.compactMap { effect -> Link? in
            switch effect {
            case .upsertLink(let l): l
            case .persistLinks(let ls): ls.first { $0.id == "card_a" }
            default: nil
            }
        }
        #expect(!persisted.isEmpty)
        #expect(persisted.allSatisfy { $0.rev == stamp(1, "M") })

        _ = Reducer.reduce(state: s, action: .killTerminal(cardId: "card_a", sessionName: "t"))
        #expect(s.links["card_a"]?.ownerRev == stamp(2, "M"))
        #expect(s.links["card_a"]?.rev == stamp(1, "M"))
        #expect(s.linkSeqs["card_a"] == s.syncSeq)
    }

    @Test("a new card is stamped on both groups")
    func newCardStamped() {
        let s = state(machine: "M", [])
        _ = Reducer.reduce(state: s, action: .createManualTask(card("card_new", owner: nil)))
        #expect(s.links["card_new"]?.rev != nil)
        #expect(s.links["card_new"]?.ownerRev != nil)
    }

    @Test("UI-only actions stamp nothing")
    func uiActionsDoNotStamp() {
        let s = state(machine: "M", [card(owner: nil)])
        _ = Reducer.reduce(state: s, action: .selectCard(cardId: "card_a"))
        _ = Reducer.reduce(state: s, action: .setPaletteOpen(true))
        #expect(s.links["card_a"]?.rev == nil)
        #expect(s.syncSeq == 0)
    }

    @Test("deleting a card leaves a stamped tombstone and persists it")
    func deleteLeavesTombstone() {
        let s = state(machine: "M", [card(owner: nil, rev: stamp(3, "M"))])
        let effects = Reducer.reduce(state: s, action: .deleteCard(cardId: "card_a"))
        #expect(s.links["card_a"] == nil)
        let t = s.tombstones["card_a"]
        #expect(t?.isTombstone == true)
        #expect(t?.rev == stamp(4, "M"))
        #expect(effects.contains { if case .persistTombstones(let ts) = $0 { ts.map(\.id) == ["card_a"] } else { false } })
        let page = s.linksPage(machine: MachineIdentity(id: "M", name: "m"), since: nil, epoch: nil)
        #expect(page.links.map(\.id) == ["card_a"])
        #expect(page.links[0].isTombstone)
    }

    @Test("a tombstone from a peer deletes a card this machine runs and stops its terminal")
    func peerTombstoneDeletesOwned() {
        let s = state(machine: "M", [card(owner: nil, rev: stamp(2, "M"), tmux: "t", session: "s1")])
        let death = LinkSync.tombstone(of: card(owner: "M"), deletedAt: now.addingTimeInterval(1e7), rev: stamp(3, "B"))
        let effects = Reducer.reduce(state: s, action: .peerLinksMerged(peer: "B", links: [death]))
        #expect(s.links["card_a"] == nil)
        #expect(s.tombstones["card_a"] != nil)
        #expect(s.deletedCardIds.contains("card_a"))
        #expect(s.deletedSessionIds.contains("s1"))
        #expect(effects.contains { if case .killTmuxSessions(let n) = $0 { n == ["t"] } else { false } })
    }

    @Test("background actions never touch a card another master owns")
    func foreignCardsFrozen() {
        let foreign = card("card_f", column: .inProgress, owner: "A", rev: stamp(1, "A"), ownerRev: stamp(1, "A"), tmux: "a-tmux", session: "s-a")
        let s = state(machine: "M", [foreign])
        // Liveness scan without the foreign tmux session: it stays.
        _ = Reducer.reduce(state: s, action: .tmuxLivenessScanned(live: []))
        #expect(s.links["card_f"] == foreign)
        // A reconcile that finds nothing for it (and would recompute its column).
        let result = ReconciliationResult(links: [], sessions: [], activityMap: [:], tmuxSessions: [])
        _ = Reducer.reduce(state: s, action: .reconciled(result))
        #expect(s.links["card_f"] == foreign)
        // A reconcile that sends a stale copy of it.
        var stale = foreign
        stale.tmuxLink = nil
        stale.column = .waiting
        stale.updatedAt = now.addingTimeInterval(1e8)
        _ = Reducer.reduce(state: s, action: .reconciled(ReconciliationResult(links: [stale], sessions: [], activityMap: [:], tmuxSessions: [])))
        #expect(s.links["card_f"] == foreign)
        #expect(s.syncSeq == 0)
    }

    @Test("a user edit of a foreign card changes shared fields only")
    func foreignUserEdit() {
        let foreign = card("card_f", owner: "A", rev: stamp(1, "A"), ownerRev: stamp(1, "A"), tmux: "a-tmux")
        let s = state(machine: "M", [foreign])
        _ = Reducer.reduce(state: s, action: .renameCard(cardId: "card_f", name: "mine now"))
        #expect(s.links["card_f"]?.name == "mine now")
        #expect(s.links["card_f"]?.rev == stamp(2, "M"))
        #expect(s.links["card_f"]?.ownerRev == stamp(1, "A"))
        // Killing its terminal is the owner's job: the owner fields stay.
        _ = Reducer.reduce(state: s, action: .killTerminal(cardId: "card_f", sessionName: "a-tmux"))
        #expect(s.links["card_f"]?.tmuxLink?.sessionName == "a-tmux")
        #expect(s.links["card_f"]?.ownerRev == stamp(1, "A"))
    }

    @Test("ownership transfer: release on the old owner, adopt on the new one")
    func ownershipTransfer() {
        let a = state(machine: "A", [card("card_x", owner: nil, rev: stamp(1, "A"), ownerRev: stamp(1, "A"), tmux: "a-tmux", session: "s1")])
        let b = state(machine: "B", [])
        let c = state(machine: "C", [])
        let idA = MachineIdentity(id: "A", name: "a")
        let idB = MachineIdentity(id: "B", name: "b")
        func pull(_ into: AppState, from: AppState, _ id: MachineIdentity) {
            _ = Reducer.reduce(state: into, action: .peerLinksMerged(peer: id.id, links: from.linksPage(machine: id, since: nil, epoch: nil).links))
        }
        pull(b, from: a, idA)
        pull(c, from: a, idA)

        // B cannot adopt a card nobody released to it.
        _ = Reducer.reduce(state: b, action: .adoptCard(cardId: "card_x", sessionLink: nil, worktreeLink: nil, projectPath: nil))
        #expect(b.links["card_x"]?.ownerMachine == "A")
        // A cannot release a card it is launching.
        a.links["card_x"]?.isLaunching = true
        _ = Reducer.reduce(state: a, action: .releaseCardOwnership(cardId: "card_x", to: "B"))
        #expect(a.links["card_x"]?.ownerMachine == nil)
        a.links["card_x"]?.isLaunching = nil

        _ = Reducer.reduce(state: a, action: .releaseCardOwnership(cardId: "card_x", to: "B"))
        #expect(a.links["card_x"]?.ownerMachine == "B")
        #expect(a.links["card_x"]?.migrating == true)
        #expect(a.isOwnedLocally(a.links["card_x"]!) == false)
        let releaseRev = a.links["card_x"]!.ownerRev!
        #expect(releaseRev.machine == "A")

        pull(b, from: a, idA)
        #expect(b.links["card_x"]?.ownerMachine == "B")
        #expect(b.isOwnedLocally(b.links["card_x"]!))
        _ = Reducer.reduce(state: b, action: .adoptCard(
            cardId: "card_x", sessionLink: SessionLink(sessionId: "s1", sessionPath: "/box/s1.jsonl"),
            worktreeLink: WorktreeLink(path: "/box/wt", branch: "feat"), projectPath: "/box/p"))
        let adopted = b.links["card_x"]!
        #expect(adopted.migrating == nil)
        #expect(adopted.tmuxLink == nil)
        #expect(adopted.sessionLink?.sessionPath == "/box/s1.jsonl")
        #expect(adopted.projectPath == "/box/p")
        #expect(adopted.ownerRev!.machine == "B")
        #expect(adopted.ownerRev! > releaseRev)

        // C sees the adoption before the release: refused, as A still owns
        // it there. Once the release lands, the adoption goes through.
        pull(c, from: b, idB)
        #expect(c.links["card_x"]?.projectPath == "/p")
        pull(c, from: a, idA)
        pull(c, from: b, idB)
        #expect(c.links["card_x"]?.projectPath == "/box/p")
        #expect(c.links["card_x"]?.ownerMachine == "B")

        // A takes B's adoption, and no longer writes the owner fields.
        pull(a, from: b, idB)
        #expect(a.links["card_x"]?.worktreeLink?.path == "/box/wt")
        #expect(a.links["card_x"]?.migrating == nil)
        _ = Reducer.reduce(state: a, action: .killTerminal(cardId: "card_x", sessionName: "whatever"))
        #expect(a.links["card_x"]?.ownerRev == adopted.ownerRev)
    }

    @Test("linksPage serves deltas by seq, and everything on a new epoch")
    func linksPageDeltas() {
        var discovered = card("card_disc", name: nil, column: .allSessions, owner: nil)
        discovered.source = .discovered
        let s = state(machine: "M", [card("card_1", owner: nil), card("card_2", owner: nil), discovered])
        let me = MachineIdentity(id: "M", name: "m")
        let full = s.linksPage(machine: me, since: nil, epoch: nil)
        #expect(full.full)
        #expect(full.links.map(\.id) == ["card_1", "card_2"])
        #expect(full.links.allSatisfy { $0.ownerMachine == "M" })

        let empty = s.linksPage(machine: me, since: full.seq, epoch: full.epoch)
        #expect(!empty.full && empty.links.isEmpty)

        _ = Reducer.reduce(state: s, action: .renameCard(cardId: "card_2", name: "changed"))
        let delta = s.linksPage(machine: me, since: full.seq, epoch: full.epoch)
        #expect(delta.links.map(\.id) == ["card_2"])
        #expect(delta.seq > full.seq)

        let restarted = s.linksPage(machine: me, since: delta.seq, epoch: "epoch_old")
        #expect(restarted.full && restarted.links.count == 2)
    }

    @Test("loadSyncState keeps live tombstones and sets the clock past every stamp")
    func loadSyncState() {
        let s = AppState()
        s.localMachineId = "M"
        s.links["card_1"] = card("card_1", rev: stamp(7, "A"), ownerRev: stamp(3, "A"))
        let t = LinkSync.tombstone(of: card("card_2"), deletedAt: now.addingTimeInterval(1e8), rev: stamp(11, "B"))
        let expired = LinkSync.tombstone(of: card("card_3"), deletedAt: Date(timeIntervalSince1970: 0), rev: stamp(20, "B"))
        s.loadSyncState(tombstones: [t, expired], now: now)
        #expect(s.tombstones.keys.sorted() == ["card_2"])
        #expect(s.syncClock == 11)
    }
}

// MARK: - PeerSync loop and routes

private final class FakeTransport: PeerLinksTransport, @unchecked Sendable {
    let lock = NSLock()
    var pages: [String: LinksPage] = [:]
    var failing: Set<String> = []
    var requests: [(peer: String, since: Int?, epoch: String?)] = []
    var notified: [String] = []

    func fetchLinks(peer: PeerConfig, since: Int?, epoch: String?) async throws -> LinksPage {
        try lock.withLock {
            requests.append((peer.id, since, epoch))
            if failing.contains(peer.id) { throw PeerSyncError.http(502, "down") }
            guard let page = pages[peer.id] else { throw PeerSyncError.http(404, "none") }
            return page
        }
    }

    func notifyChanged(peer: PeerConfig, machineId: String) async {
        lock.withLock { notified.append(peer.id) }
    }
}

private actor Dispatched {
    var actions: [Action] = []
    func append(_ action: Action) { actions.append(action) }
}

@Suite("Peer sync: loop and routes")
struct PeerSyncLoopTests {
    let me = MachineIdentity(id: "M", name: "mac")
    let box = MachineIdentity(id: "BOX", name: "box")
    let peer = PeerConfig(id: "peer_box", name: "box", url: "http://box:7780", token: "kc_t")

    @Test("a pull dispatches the page, then asks only for what changed since")
    func pullsDeltas() async {
        let transport = FakeTransport()
        transport.pages["peer_box"] = LinksPage(machine: box, epoch: "e1", seq: 7, full: true, links: [card(owner: "BOX", rev: stamp(1, "BOX"))])
        let dispatched = Dispatched()
        let sync = PeerSync(identity: me, peers: [peer], transport: transport) { await dispatched.append($0) }

        #expect(await sync.pull(peerId: "peer_box"))
        let actions = await dispatched.actions
        #expect(actions.contains { if case .peerLinksMerged(let p, let links) = $0 { p == "BOX" && links.count == 1 } else { false } })
        #expect(actions.contains { if case .peerStatusChanged(let st) = $0 { st.online && st.machine == box } else { false } })
        let status = await sync.status(of: "peer_box")
        #expect(status?.online == true && status?.lastSeen != nil)
        #expect(await sync.peer(forMachine: "BOX")?.id == "peer_box")

        transport.pages["peer_box"] = LinksPage(machine: box, epoch: "e1", seq: 7, full: false, links: [])
        #expect(await sync.pull(peerId: "peer_box"))
        #expect(transport.requests.map(\.since) == [nil, 7])
        #expect(transport.requests.last?.epoch == "e1")
        // An empty page dispatches no merge.
        let merges = await dispatched.actions.filter { if case .peerLinksMerged = $0 { true } else { false } }
        #expect(merges.count == 1)
    }

    @Test("an unreachable peer goes offline with the error, and back online when it answers")
    func offlineOnline() async {
        let transport = FakeTransport()
        transport.failing = ["peer_box"]
        let dispatched = Dispatched()
        let sync = PeerSync(identity: me, peers: [peer], transport: transport) { await dispatched.append($0) }
        #expect(await sync.pull(peerId: "peer_box") == false)
        #expect(await sync.status(of: "peer_box")?.online == false)
        #expect(await sync.status(of: "peer_box")?.lastError?.contains("502") == true)

        transport.failing = []
        transport.pages["peer_box"] = LinksPage(machine: box, epoch: "e", seq: 1, full: true, links: [])
        #expect(await sync.pull(peerId: "peer_box"))
        let statuses = await dispatched.actions.compactMap { if case .peerStatusChanged(let s) = $0 { s } else { nil } }
        #expect(statuses.map(\.online) == [false, true])
    }

    @Test("a peer that turns out to be this machine is refused")
    func selfPeer() async {
        let transport = FakeTransport()
        transport.pages["peer_box"] = LinksPage(machine: me, epoch: "e", seq: 1, full: true, links: [card()])
        let dispatched = Dispatched()
        let sync = PeerSync(identity: me, peers: [peer], transport: transport) { await dispatched.append($0) }
        #expect(await sync.pull(peerId: "peer_box") == false)
        #expect(await dispatched.actions.allSatisfy { if case .peerLinksMerged = $0 { false } else { true } })
    }

    @Test("changing a peer's URL starts it over with a full pull; disabled peers are skipped")
    func setPeers() async {
        let transport = FakeTransport()
        transport.pages["peer_box"] = LinksPage(machine: box, epoch: "e", seq: 3, full: true, links: [])
        let sync = PeerSync(identity: me, peers: [peer], transport: transport) { _ in }
        await sync.pull(peerId: "peer_box")
        var moved = peer
        moved.url = "http://elsewhere:7780"
        await sync.setPeers([moved])
        await sync.pull(peerId: "peer_box")
        #expect(transport.requests.map(\.since) == [nil, nil])
        moved.enabled = false
        await sync.setPeers([moved])
        #expect(await sync.pull(peerId: "peer_box") == false)
        #expect(transport.requests.count == 2)
    }

    @Test("run pulls on its own and at once after a poke; notifyPeers reaches online peers")
    func runLoop() async throws {
        let transport = FakeTransport()
        transport.pages["peer_box"] = LinksPage(machine: box, epoch: "e", seq: 1, full: true, links: [])
        let sync = PeerSync(identity: me, peers: [peer], transport: transport) { _ in }
        let task = Task { await sync.run(interval: .seconds(60), offlineInterval: .seconds(60)) }
        defer { task.cancel() }
        for _ in 0..<40 where transport.lock.withLock({ transport.requests.count }) < 1 {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(transport.lock.withLock { transport.requests.count } == 1)
        await sync.poke(machineId: "BOX")
        for _ in 0..<40 where transport.lock.withLock({ transport.requests.count }) < 2 {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(transport.lock.withLock { transport.requests.count } == 2)
        await sync.notifyPeers()
        #expect(transport.lock.withLock { transport.notified } == ["peer_box"])
    }

    @Test("a peer that was down is pulled again within seconds of coming back")
    func offlinePeerRetriesSoon() async throws {
        #expect(PeerSync.offlineRetry <= .seconds(5))
        let transport = FakeTransport()
        transport.pages["peer_box"] = LinksPage(machine: box, epoch: "e", seq: 1, full: true, links: [])
        transport.failing = ["peer_box"]
        let sync = PeerSync(identity: me, peers: [peer], transport: transport) { _ in }
        let task = Task { await sync.run(interval: .seconds(60), offlineInterval: .milliseconds(200)) }
        defer { task.cancel() }
        for _ in 0..<40 where transport.lock.withLock({ transport.requests.count }) < 1 {
            try await Task.sleep(for: .milliseconds(50))
        }
        transport.lock.withLock { transport.failing = [] }
        for _ in 0..<40 where await sync.status(of: "peer_box")?.online != true {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(await sync.status(of: "peer_box")?.online == true)
    }

    @Test("links URL is built from the peer base URL")
    func linksURL() {
        #expect(HTTPPeerLinksTransport.linksURL(base: "http://h:7780/", since: 5, epoch: "e1")?.absoluteString
            == "http://h:7780/v1/links?since=5&epoch=e1")
        #expect(HTTPPeerLinksTransport.linksURL(base: "http://h:7780", since: nil, epoch: nil)?.absoluteString
            == "http://h:7780/v1/links")
        #expect(HTTPPeerLinksTransport.linksURL(base: "not a url", since: nil, epoch: nil) == nil)
    }

    private final class FakeServer: PeerLinksServing, @unchecked Sendable {
        var page: LinksPage
        var changed: [String?] = []
        var asked: [(Int?, String?)] = []
        init(page: LinksPage) { self.page = page }
        func linksPage(since: Int?, epoch: String?) async -> LinksPage {
            asked.append((since, epoch))
            return page
        }
        func peerLinksChanged(machineId: String?) async { changed.append(machineId) }
        func peersOverview() async -> PeersOverview {
            PeersOverview(machine: page.machine, peers: [PeerOverview(peer: PeerConfig(name: "b", url: "u", token: "secret"), status: nil)])
        }
    }

    @Test("routes: GET /v1/links, POST /v1/links/changed, GET /v1/peers")
    func routes() async throws {
        let page = LinksPage(machine: box, epoch: "e", seq: 4, full: true, links: [card(owner: "BOX", rev: stamp(2, "BOX"))])
        let server = FakeServer(page: page)

        let ok = await RemoteLinksRoutes.handle(method: "GET", rest: ["links"], query: ["since": "3", "epoch": "e"], server: server)
        #expect(ok?.status == 200)
        let decoded = try JSONDecoder.remote.decode(LinksPage.self, from: ok!.body)
        #expect(decoded.links.map(\.id) == ["card_a"])
        #expect(decoded.links[0].rev == stamp(2, "BOX"))
        #expect(server.asked.first?.0 == 3 && server.asked.first?.1 == "e")

        #expect(await RemoteLinksRoutes.handle(method: "GET", rest: ["links"], query: ["since": "-1"], server: server)?.status == 400)
        #expect(await RemoteLinksRoutes.handle(method: "PUT", rest: ["links"], query: [:], server: server)?.status == 405)

        let changed = await RemoteLinksRoutes.handle(method: "POST", rest: ["links", "changed"], query: ["machine": "M"], server: server)
        #expect(changed?.status == 204)
        #expect(server.changed == ["M"])

        let peers = await RemoteLinksRoutes.handle(method: "GET", rest: ["peers"], query: [:], server: server)
        #expect(peers?.status == 200)
        #expect(!String(decoding: peers!.body, as: UTF8.self).contains("secret"))

        #expect(await RemoteLinksRoutes.handle(method: "GET", rest: ["board"], query: [:], server: server) == nil)
    }
}

// MARK: - Per-field last writer wins

/// A shared-field edit stamped the way the reducer stamps it.
private func edit(_ base: Link, at s: SyncStamp, _ change: (inout Link) -> Void) -> Link {
    var link = base
    change(&link)
    var revs = LinkSync.explicitFieldRevs(of: base) ?? [:]
    for name in LinkSync.changedSharedFields(base, link) { revs[name] = s }
    revs["deletedAt"] = s
    link.fieldRevs = revs
    link.rev = s
    return link
}

@Suite("Peer sync: per-field last writer wins")
struct LinkSyncPerFieldTests {
    @Test("edits of different fields on two masters both survive")
    func differentFieldsBothSurvive() {
        let base = card(name: "base", owner: "A", rev: stamp(1, "A"))
        let rename = edit(base, at: stamp(2, "A")) { $0.name = "renamed on A" }
        let move = edit(base, at: stamp(2, "B")) { $0.column = .done; $0.manualOverrides.column = true }
        for (first, second) in [(rename, move), (move, rename)] {
            let merged = applyAll([(first, "A"), (second, "B")], to: base, machine: "M")
            #expect(merged?.name == "renamed on A")
            #expect(merged?.column == .done)
            #expect(merged?.manualOverrides.column == true)
            #expect(merged?.rev == stamp(2, "B"))
            #expect(merged?.fieldRevs?["name"] == stamp(2, "A"))
            #expect(merged?.fieldRevs?["column"] == stamp(2, "B"))
        }
    }

    @Test("the same field edited on two masters: the newer stamp wins")
    func sameFieldNewerWins() {
        let base = card(name: "base", owner: "A", rev: stamp(1, "A"))
        let onA = edit(base, at: stamp(3, "A")) { $0.name = "A" }
        let onB = edit(base, at: stamp(3, "B")) { $0.name = "B" }
        #expect(applyAll([(onA, "A"), (onB, "B")], to: base, machine: "M")?.name == "B")
        #expect(applyAll([(onB, "B"), (onA, "A")], to: base, machine: "M")?.name == "B")
    }

    @Test("a deletion loses to a newer edit of any field, and keeps the fields it did not see")
    func deletionAndResurrection() {
        let base = card(name: "base", owner: "A", rev: stamp(1, "A"))
        let pinned = edit(base, at: stamp(2, "B")) { $0.pinnedAt = now }
        let delete = LinkSync.tombstone(of: base, deletedAt: now, rev: stamp(3, "A"))
        let rename = edit(base, at: stamp(4, "C")) { $0.name = "back" }
        let result = applyAll([(pinned, "B"), (delete, "A"), (rename, "C")], to: base, machine: "M")
        #expect(result?.isTombstone == false)
        #expect(result?.name == "back")
        #expect(result?.pinnedAt == now)

        let lateDelete = LinkSync.tombstone(of: base, deletedAt: now, rev: stamp(5, "A"))
        #expect(applyAll([(rename, "C"), (lateDelete, "A")], to: base, machine: "M")?.isTombstone == true)
    }

    @Test("per-field versions, an old peer's whole-group version and owner updates converge in every order")
    func convergesInEveryOrder() {
        var base = card(name: "base", column: .inProgress, owner: "A", rev: stamp(1, "A"), ownerRev: stamp(1, "A"), tmux: "t0")
        base.fieldRevs = LinkSync.explicitFieldRevs(of: base)
        let rename = edit(base, at: stamp(4, "B")) { $0.name = "renamed on B" }
        let move = edit(base, at: stamp(4, "C")) { $0.column = .done; $0.manualOverrides.column = true }
        let pin = edit(base, at: stamp(2, "B")) { $0.pinnedAt = now; $0.pinnedSortOrder = 1 }
        let prompt = edit(base, at: stamp(5, "A")) { $0.promptBody = "new prompt" }
        let delete = LinkSync.tombstone(of: base, deletedAt: now, rev: stamp(3, "C"))
        var legacy = base
        legacy.fieldRevs = nil
        legacy.name = "old peer"
        legacy.sortOrder = 9
        legacy.rev = stamp(1, "D")
        var ownerUpdate = base
        ownerUpdate.tmuxLink = TmuxLink(sessionName: "t1")
        ownerUpdate.ownerRev = stamp(3, "A")

        let versions: [(Link, String)] = [
            (rename, "B"), (move, "C"), (pin, "B"), (prompt, "A"), (delete, "C"), (legacy, "D"), (ownerUpdate, "A"),
        ]
        let orders = permutations(versions)
        #expect(orders.count == 5040)
        for machine in ["M", "B"] {
            let first = applyAll(orders[0], to: base, machine: machine)
            for order in orders {
                let once = applyAll(order, to: base, machine: machine)
                #expect(once == first, "order changed the result on \(machine)")
                #expect(applyAll(order, to: once, machine: machine) == once, "not idempotent on \(machine)")
            }
            #expect(first?.isTombstone == false)
            #expect(first?.name == "renamed on B")
            #expect(first?.column == .done)
            #expect(first?.pinnedAt == now)
            #expect(first?.pinnedSortOrder == 1)
            #expect(first?.promptBody == "new prompt")
            #expect(first?.sortOrder == 9)
            #expect(first?.tmuxLink?.sessionName == "t1")
            #expect(first?.rev == stamp(5, "A"))
        }
    }

    @Test("merge is commutative for every pair of versions")
    func pairwiseCommutative() {
        let base = card(name: "base", owner: "A", rev: stamp(1, "A"))
        let versions = [
            edit(base, at: stamp(2, "A")) { $0.name = "x" },
            edit(base, at: stamp(2, "B")) { $0.column = .done },
            edit(base, at: stamp(3, "B")) { $0.name = "y"; $0.sortOrder = 4 },
            LinkSync.tombstone(of: base, deletedAt: now, rev: stamp(3, "A")),
            card(name: "legacy", owner: "A", rev: stamp(2, "C")),
        ]
        for a in versions {
            for b in versions {
                let ab = applyAll([(a, "P"), (b, "Q")], to: base, machine: "M")
                let ba = applyAll([(b, "Q"), (a, "P")], to: base, machine: "M")
                #expect(ab == ba)
            }
        }
    }

    @Test("two machines edit different fields of the same card and end equal")
    func twoMachinesDifferentFields() {
        let aCards = state(machine: "A", [
            card("card_1", name: "one", owner: nil, rev: stamp(1, "A"), ownerRev: stamp(1, "A"), tmux: "a1"),
        ])
        let bCards = state(machine: "B", [])
        let idA = MachineIdentity(id: "A", name: "a")
        let idB = MachineIdentity(id: "B", name: "b")
        func exchange() {
            _ = Reducer.reduce(state: bCards, action: .peerLinksMerged(peer: "A", links: aCards.linksPage(machine: idA, since: nil, epoch: nil).links))
            _ = Reducer.reduce(state: aCards, action: .peerLinksMerged(peer: "B", links: bCards.linksPage(machine: idB, since: nil, epoch: nil).links))
        }
        exchange()
        // B's clock runs ahead, so its edit carries the newer stamp overall.
        bCards.syncClock = 20
        _ = Reducer.reduce(state: aCards, action: .renameCard(cardId: "card_1", name: "renamed on A"))
        _ = Reducer.reduce(state: bCards, action: .moveCard(cardId: "card_1", to: .done))
        exchange()
        exchange()
        let a = aCards.links["card_1"]!
        let b = bCards.links["card_1"]!
        #expect(a.name == "renamed on A" && b.name == "renamed on A")
        #expect(a.column == .done && b.column == .done)
        #expect(a.fieldRevs == b.fieldRevs)
        #expect(a.rev == b.rev)
    }
}
