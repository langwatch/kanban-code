import Testing
import Foundation
@testable import KanbanCodeCore

/// Kanban lists the cards it started or the kanban CLI registered. Sessions
/// and worktrees found on disk get no card, and the cards earlier versions
/// made for them are archived (specs/sessions/discovery.feature).
@Suite("Discovery creates no cards")
struct DiscoveryOnlyCardsTests {

    private func state(_ links: [Link], localMachine: String = "") -> AppState {
        var state = AppState()
        state.localMachineId = localMachine
        for link in links { state.links[link.id] = link }
        state.rebuildCards()
        return state
    }

    private func discovered(_ id: String, session: String? = nil) -> Link {
        Link(
            id: id,
            projectPath: "/repo",
            column: .waiting,
            lastActivity: .now,
            source: .discovered,
            sessionLink: session.map { SessionLink(sessionId: $0, sessionPath: "/s/\($0).jsonl") }
        )
    }

    // MARK: - Reconcile

    @Test("A Claude session started outside Kanban gets no card")
    func outsideSessionGetsNoCard() {
        let snapshot = CardReconciler.DiscoverySnapshot(sessions: [
            Session(id: "outside", projectPath: "/repo", messageCount: 4, modifiedTime: .now, jsonlPath: "/s/outside.jsonl"),
        ])
        #expect(CardReconciler.reconcile(existing: [], snapshot: snapshot).isEmpty)
    }

    @Test("A session the kanban CLI started on its card is linked to that card")
    func cliCardTakesItsSession() {
        // `kanban subagent spawn` writes the card and its tmux session before
        // the assistant writes a transcript.
        var card = Link(
            id: "card_cli",
            name: "Subagent",
            projectPath: "/repo",
            column: .inProgress,
            source: .manual,
            parentCardId: "card_parent",
            tmuxLink: TmuxLink(sessionName: "repo-card_cli"),
            launchedAt: .now.addingTimeInterval(-30)
        )
        card.isLaunching = true
        let snapshot = CardReconciler.DiscoverySnapshot(sessions: [
            Session(id: "child", projectPath: "/repo", messageCount: 2, modifiedTime: .now, jsonlPath: "/s/child.jsonl"),
        ])
        let result = CardReconciler.reconcile(existing: [card], snapshot: snapshot)
        #expect(result.count == 1)
        #expect(result[0].id == "card_cli")
        #expect(result[0].sessionLink?.sessionId == "child")
    }

    @Test("A git worktree no card uses gets no card")
    func detectedWorktreeGetsNoCard() {
        let snapshot = CardReconciler.DiscoverySnapshot(worktrees: [
            "/repo": [
                Worktree(path: "/repo", branch: "main", isBare: false),
                Worktree(path: "/repo/.claude/worktrees/feat", branch: "refs/heads/feat", isBare: false),
            ],
        ])
        let manual = Link(id: "card_m", name: "Task", projectPath: "/repo", column: .backlog, source: .manual)
        let result = CardReconciler.reconcile(existing: [manual], snapshot: snapshot)
        #expect(result.map(\.id) == ["card_m"])
        #expect(result[0].worktreeLink == nil)
    }

    // MARK: - Archiving what discovery made

    @Test("Cards only discovery made are archived, cards anyone touched stay")
    func archivesDiscoveryOnlyCards() {
        var named = discovered("card_named", session: "s2")
        named.name = "Renamed"
        var pinned = discovered("card_pinned", session: "s3")
        pinned.pinnedAt = .now
        var launched = discovered("card_launched", session: "s4")
        launched.launchedAt = .now.addingTimeInterval(-3600)
        var withPR = discovered("card_pr", session: "s5")
        withPR.prLinks = [PRLink(number: 7)]
        var moved = discovered("card_moved", session: "s6")
        moved.column = .inReview
        moved.manualOverrides.column = true
        var prompted = discovered("card_prompted", session: "s7")
        prompted.queuedPrompts = [QueuedPrompt(body: "go on")]
        var worktreeOnly = discovered("card_worktree")
        worktreeOnly.worktreeLink = WorktreeLink(path: "/repo/.claude/worktrees/x", branch: "x")
        let manual = Link(id: "card_manual", name: "Mine", projectPath: "/repo", column: .backlog, source: .manual)
        var foreign = discovered("card_foreign", session: "s8")
        foreign.ownerMachine = "machine_box"

        var s = state([
            discovered("card_plain", session: "s1"), named, pinned, launched, withPR, moved, prompted,
            worktreeOnly, manual, foreign,
        ], localMachine: "machine_mac")
        let effects = Reducer.reduce(state: &s, action: .archiveDiscoveryOnlyCards)

        let archived = Set(s.links.values.filter(\.manuallyArchived).map(\.id))
        #expect(archived == ["card_plain", "card_worktree"])
        #expect(s.links["card_plain"]?.column == .allSessions)
        // Archived, not deleted.
        #expect(s.links.count == 10)
        #expect(effects.contains { if case .persistLinks = $0 { true } else { false } })
        // Nothing to kill or destroy for a card with no terminal or machine.
        #expect(effects.killedSessions.isEmpty)
        #expect(effects.destroyedMachines.isEmpty)
    }

    @Test("The sweep is a no-op once nothing is left to archive")
    func sweepIsIdempotent() {
        var s = state([discovered("card_plain", session: "s1")])
        _ = Reducer.reduce(state: &s, action: .archiveDiscoveryOnlyCards)
        let effects = Reducer.reduce(state: &s, action: .archiveDiscoveryOnlyCards)
        #expect(effects.isEmpty)
    }

    @Test("A discovery-only card the user brings back from the archive stays out")
    func unarchivedCardIsNotArchivedAgain() {
        var s = state([discovered("card_plain", session: "s1")])
        _ = Reducer.reduce(state: &s, action: .archiveDiscoveryOnlyCards)
        _ = Reducer.reduce(state: &s, action: .unarchiveCard(cardId: "card_plain"))
        _ = Reducer.reduce(state: &s, action: .archiveDiscoveryOnlyCards)
        #expect(s.links["card_plain"]?.manuallyArchived == false)
    }

    @Test("An archived discovered card is sent to the peers, so they archive it too")
    func archivedDiscoveredCardIsServed() {
        var s = state([discovered("card_plain", session: "s1")], localMachine: "machine_mac")
        s.links["card_plain"]?.column = .allSessions
        #expect(!LinkSync.isServed(s.links["card_plain"]!))
        _ = Reducer.reduce(state: &s, action: .archiveDiscoveryOnlyCards)
        #expect(LinkSync.isServed(s.links["card_plain"]!))
        let page = s.linksPage(machine: MachineIdentity(id: "machine_mac", name: "mac"), since: nil, epoch: nil)
        #expect(page.links.first { $0.id == "card_plain" }?.manuallyArchived == true)
    }
}

/// Archiving or deleting a card never destroys a machine Kanban did not
/// create for it.
@Suite("Machine safety")
struct MachineSafetyTests {

    private func card(_ id: String, machine: String) -> Link {
        Link(
            id: id,
            name: "Remote",
            projectPath: "/repo",
            column: .waiting,
            source: .manual,
            isRemote: true,
            remote: RemoteLink(machineName: machine, remoteProjectPath: "/root/repo", remoteHome: "/root")
        )
    }

    private func state(_ links: [Link]) -> AppState {
        var state = AppState()
        for link in links { state.links[link.id] = link }
        state.rebuildCards()
        return state
    }

    @Test("Archiving a card on a machine Kanban did not create leaves the machine alone")
    func archiveKeepsForeignMachine() {
        var s = state([card("card_dogfood", machine: "rchaves-platform")])
        #expect(!s.runsOnDisposableMachine("card_dogfood"))
        let effects = Reducer.reduce(state: &s, action: .archiveCard(cardId: "card_dogfood"))
        #expect(effects.destroyedMachines.isEmpty)
        #expect(s.links["card_dogfood"]?.manuallyArchived == true)
        #expect(s.links["card_dogfood"]?.remote == nil)
    }

    @Test("Deleting a card on a machine Kanban did not create leaves the machine alone")
    func deleteKeepsForeignMachine() {
        var s = state([card("card_dogfood", machine: "rchaves-platform")])
        let effects = Reducer.reduce(state: &s, action: .deleteCard(cardId: "card_dogfood"))
        #expect(effects.destroyedMachines.isEmpty)
    }

    @Test("A peer master is never destroyed, even under a Kanban machine name")
    func peerMasterIsNeverDestroyed() {
        var s = state([card("card_1", machine: "kanban-box-12345678")])
        s.peerStatuses["peer_box"] = PeerStatus(
            peerId: "peer_box", machine: MachineIdentity(id: "machine_box", name: "kanban-box-12345678"), online: true)
        #expect(!s.isDisposableMachine("kanban-box-12345678"))
        let effects = Reducer.reduce(state: &s, action: .archiveCard(cardId: "card_1"))
        #expect(effects.destroyedMachines.isEmpty)
    }

    @Test("The machine Kanban created for a card is destroyed with its last card")
    func kanbanMachineIsDestroyed() {
        var s = state([card("card_1", machine: "kanban-repo-abcd1234")])
        #expect(s.runsOnDisposableMachine("card_1"))
        let effects = Reducer.reduce(state: &s, action: .archiveCard(cardId: "card_1"))
        #expect(effects.destroyedMachines == ["kanban-repo-abcd1234"])
    }

    @Test("Only machines named like the ones Kanban creates count as Kanban's")
    func machineNameShape() {
        #expect(BoxdLaunchPlanner.isKanbanMachineName(BoxdLaunchPlanner.machineName(repoName: "langwatch", cardId: "card_3JvU2wgm")))
        #expect(!BoxdLaunchPlanner.isKanbanMachineName("rchaves-platform"))
    }
}
