import Foundation
import Testing
@testable import KanbanCodeCore

@Suite("Merging cards with the same session")
struct DuplicateSessionMergeTests {
    private func pair(owner: String?) -> (keeper: Link, duplicate: Link) {
        let keeper = Link(id: "card_keeper", name: "firefighting", projectPath: "/project", column: .allSessions,
                          createdAt: Date(timeIntervalSince1970: 100), source: .manual,
                          sessionLink: SessionLink(sessionId: "s1", sessionPath: "/p/s1.jsonl"), ownerMachine: owner)
        let duplicate = Link(id: "card_dup", projectPath: "/project", column: .allSessions,
                             createdAt: Date(timeIntervalSince1970: 200), source: .discovered,
                             sessionLink: SessionLink(sessionId: "s1", sessionPath: "/p/s1.jsonl"),
                             worktreeLink: WorktreeLink(path: "/project/.wt/a", branch: "a"), ownerMachine: owner)
        return (keeper, duplicate)
    }

    @Test("the merged duplicate is reported and the reducer drops it, so the next pass has nothing to merge")
    func mergePersists() {
        let (keeper, duplicate) = pair(owner: "M")
        let state = AppState()
        state.localMachineId = "M"
        state.links = [keeper.id: keeper, duplicate.id: duplicate]
        state.loadSyncState(tombstones: [])
        let snapshot = CardReconciler.DiscoverySnapshot(localMachineId: "M")

        let existing = Array(state.links.values)
        let reconciled = CardReconciler.reconcile(existing: existing, snapshot: snapshot)
        #expect(reconciled.map(\.id) == ["card_keeper"])
        let merged = CardReconciler.mergedDuplicates(existing: existing, reconciled: reconciled)
        #expect(merged == ["card_dup": "card_keeper"])

        var s = state
        _ = Reducer.reduce(state: &s, action: .reconciled(ReconciliationResult(
            links: reconciled, sessions: [], activityMap: [:], tmuxSessions: [], mergedDuplicates: merged)))
        #expect(s.links["card_dup"] == nil)
        #expect(s.links["card_keeper"]?.worktreeLink?.branch == "a")
        #expect(s.tombstones["card_dup"] != nil)

        // The second pass finds one card for the session: no merge again.
        let again = CardReconciler.reconcile(existing: Array(s.links.values), snapshot: snapshot)
        #expect(CardReconciler.mergedDuplicates(existing: Array(s.links.values), reconciled: again).isEmpty)
    }

    @Test("cards another master runs are left to that master")
    func foreignCardsAreNotMerged() {
        let (keeper, duplicate) = pair(owner: "MAC")
        let reconciled = CardReconciler.reconcile(existing: [keeper, duplicate],
                                                  snapshot: .init(localMachineId: "BOX"))
        #expect(Set(reconciled.map(\.id)) == ["card_keeper", "card_dup"])
        #expect(CardReconciler.mergedDuplicates(existing: [keeper, duplicate], reconciled: reconciled).isEmpty)
    }

    @Test("a duplicate that is still launching stays")
    func launchingDuplicateStays() {
        var (keeper, duplicate) = pair(owner: nil)
        duplicate.isLaunching = true
        let state = AppState()
        state.links = [keeper.id: keeper, duplicate.id: duplicate]
        var s = state
        _ = Reducer.reduce(state: &s, action: .reconciled(ReconciliationResult(
            links: [keeper], sessions: [], activityMap: [:], tmuxSessions: [], mergedDuplicates: ["card_dup": "card_keeper"])))
        #expect(s.links["card_dup"] != nil)
    }
}
