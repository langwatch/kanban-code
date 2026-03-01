import Testing
import Foundation
@testable import KanbanCore

@Suite("Reducer")
struct ReducerTests {
    // MARK: - Helpers

    private func makeLink(
        id: String = "card_test123",
        column: KanbanColumn = .backlog,
        tmuxLink: TmuxLink? = nil,
        sessionLink: SessionLink? = nil,
        worktreeLink: WorktreeLink? = nil,
        isLaunching: Bool? = nil,
        source: LinkSource = .manual,
        name: String? = "Test card",
        updatedAt: Date = .now
    ) -> Link {
        Link(
            id: id,
            name: name,
            projectPath: "/test/project",
            column: column,
            updatedAt: updatedAt,
            source: source,
            sessionLink: sessionLink,
            tmuxLink: tmuxLink,
            worktreeLink: worktreeLink,
            isLaunching: isLaunching
        )
    }

    private func stateWith(_ links: [Link]) -> AppState {
        var state = AppState()
        for link in links {
            state.links[link.id] = link
        }
        return state
    }

    // MARK: - Create Manual Task

    @Test("createManualTask adds link to state")
    func createManualTask() {
        var state = AppState()
        let link = makeLink(id: "card_new1", column: .backlog)

        let effects = Reducer.reduce(state: &state, action: .createManualTask(link))

        #expect(state.links["card_new1"] != nil)
        #expect(state.links["card_new1"]?.column == .backlog)
        #expect(effects.count == 1) // upsertLink
    }

    // MARK: - Create Terminal

    @Test("createTerminal sets tmuxLink but does NOT change column")
    func createTerminalKeepsColumn() {
        let link = makeLink(id: "card_t1", column: .waiting)
        var state = stateWith([link])

        let effects = Reducer.reduce(state: &state, action: .createTerminal(cardId: "card_t1"))

        #expect(state.links["card_t1"]?.column == .waiting) // column unchanged!
        #expect(state.links["card_t1"]?.tmuxLink != nil)
        #expect(state.links["card_t1"]?.tmuxLink?.isShellOnly == true)
        #expect(state.links["card_t1"]?.tmuxLink?.sessionName == "project-card_t1")
        #expect(effects.contains(where: { if case .createTmuxSession = $0 { return true }; return false }))
    }

    @Test("createTerminal uses card ID for tmux name, not project name")
    func createTerminalUniqueNaming() {
        let link1 = makeLink(id: "card_abc123def4", column: .waiting)
        let link2 = makeLink(id: "card_xyz789ghi0", column: .waiting)
        var state = stateWith([link1, link2])

        let _ = Reducer.reduce(state: &state, action: .createTerminal(cardId: "card_abc123def4"))
        let _ = Reducer.reduce(state: &state, action: .createTerminal(cardId: "card_xyz789ghi0"))

        let name1 = state.links["card_abc123def4"]?.tmuxLink?.sessionName ?? ""
        let name2 = state.links["card_xyz789ghi0"]?.tmuxLink?.sessionName ?? ""
        #expect(name1 != name2)
        #expect(name1.hasPrefix("project-"))
        #expect(name2.hasPrefix("project-"))
    }

    // MARK: - Launch Card

    @Test("launchCard sets column to inProgress and isLaunching")
    func launchCardImmediateFeedback() {
        let link = makeLink(id: "card_l1", column: .backlog)
        var state = stateWith([link])

        let _ = Reducer.reduce(state: &state, action: .launchCard(
            cardId: "card_l1", prompt: "test", projectPath: "/test",
            worktreeName: nil, runRemotely: false, commandOverride: nil
        ))

        #expect(state.links["card_l1"]?.column == .inProgress)
        #expect(state.links["card_l1"]?.isLaunching == true)
        #expect(state.links["card_l1"]?.tmuxLink != nil)
        #expect(state.selectedCardId == "card_l1")
    }

    // MARK: - Resume Card

    @Test("resumeCard sets column to inProgress and isLaunching")
    func resumeCardImmediateFeedback() {
        let link = makeLink(
            id: "card_r1",
            column: .waiting,
            sessionLink: SessionLink(sessionId: "sess_abc12345")
        )
        var state = stateWith([link])

        let _ = Reducer.reduce(state: &state, action: .resumeCard(cardId: "card_r1"))

        #expect(state.links["card_r1"]?.column == .inProgress)
        #expect(state.links["card_r1"]?.isLaunching == true)
        #expect(state.links["card_r1"]?.tmuxLink?.sessionName == "claude-sess_abc")
        #expect(state.selectedCardId == "card_r1")
    }

    @Test("resumeCard does not bounce — isLaunching prevents reconciliation override")
    func resumeCardNoBounce() {
        let link = makeLink(
            id: "card_r2",
            column: .waiting,
            sessionLink: SessionLink(sessionId: "sess_def12345")
        )
        var state = stateWith([link])

        // Step 1: User resumes
        let _ = Reducer.reduce(state: &state, action: .resumeCard(cardId: "card_r2"))
        #expect(state.links["card_r2"]?.column == .inProgress)
        #expect(state.links["card_r2"]?.isLaunching == true)

        // Step 2: Background reconciliation fires with stale snapshot (taken BEFORE resume)
        let reconciledLink = makeLink(
            id: "card_r2",
            column: .waiting, // reconciliation would compute waiting (no activity yet)
            sessionLink: SessionLink(sessionId: "sess_def12345"),
            updatedAt: .now.addingTimeInterval(-5) // stale: from before the resume
        )
        let result = ReconciliationResult(
            links: [reconciledLink],
            sessions: [],
            activityMap: [:],
            tmuxSessions: []
        )
        let _ = Reducer.reduce(state: &state, action: .reconciled(result))

        // Card should STILL be inProgress (preserved because updatedAt is newer)
        #expect(state.links["card_r2"]?.column == .inProgress)
        #expect(state.links["card_r2"]?.isLaunching == true)
    }

    @Test("resumeCompleted keeps isLaunching until reconciliation confirms activity")
    func resumeCompletedKeepsLaunching() {
        let link = makeLink(
            id: "card_r3",
            column: .inProgress,
            tmuxLink: TmuxLink(sessionName: "claude-sess_abc"),
            sessionLink: SessionLink(sessionId: "sess_abc12345"),
            isLaunching: true
        )
        var state = stateWith([link])

        let _ = Reducer.reduce(state: &state, action: .resumeCompleted(
            cardId: "card_r3", tmuxName: "claude-sess_abc"
        ))

        // isLaunching stays true — cleared by reconciliation when activity is confirmed
        #expect(state.links["card_r3"]?.isLaunching == true)
        #expect(state.links["card_r3"]?.column == .inProgress)
    }

    // MARK: - Launch Failure

    @Test("launchFailed clears tmuxLink and isLaunching, sets error")
    func launchFailedReverts() {
        let link = makeLink(
            id: "card_f1",
            column: .inProgress,
            tmuxLink: TmuxLink(sessionName: "test-tmux"),
            isLaunching: true
        )
        var state = stateWith([link])

        let _ = Reducer.reduce(state: &state, action: .launchFailed(
            cardId: "card_f1", error: "Connection refused"
        ))

        #expect(state.links["card_f1"]?.tmuxLink == nil)
        #expect(state.links["card_f1"]?.isLaunching == nil)
        #expect(state.error == "Launch failed: Connection refused")
    }

    // MARK: - Move Card

    @Test("moveCard sets column and manual override")
    func moveCardManualOverride() {
        let link = makeLink(id: "card_m1", column: .backlog)
        var state = stateWith([link])

        let _ = Reducer.reduce(state: &state, action: .moveCard(cardId: "card_m1", to: .inProgress))

        #expect(state.links["card_m1"]?.column == .inProgress)
        #expect(state.links["card_m1"]?.manualOverrides.column == true)
    }

    @Test("moveCard to allSessions sets manuallyArchived")
    func moveCardToArchive() {
        let link = makeLink(id: "card_m2", column: .inProgress)
        var state = stateWith([link])

        let _ = Reducer.reduce(state: &state, action: .moveCard(cardId: "card_m2", to: .allSessions))

        #expect(state.links["card_m2"]?.column == .allSessions)
        #expect(state.links["card_m2"]?.manuallyArchived == true)
    }

    // MARK: - Delete Card

    @Test("deleteCard removes link and returns cleanup effects")
    func deleteCardCleansUp() {
        let link = makeLink(
            id: "card_d1",
            column: .inProgress,
            tmuxLink: TmuxLink(sessionName: "test-tmux", extraSessions: ["test-tmux-sh1"]),
            sessionLink: SessionLink(sessionId: "sess_123", sessionPath: "/path/to/sess.jsonl")
        )
        var state = stateWith([link])
        state.selectedCardId = "card_d1"

        let effects = Reducer.reduce(state: &state, action: .deleteCard(cardId: "card_d1"))

        #expect(state.links["card_d1"] == nil)
        #expect(state.selectedCardId == nil) // deselected
        #expect(effects.contains(where: { if case .removeLink = $0 { return true }; return false }))
        #expect(effects.contains(where: { if case .killTmuxSessions = $0 { return true }; return false }))
        #expect(effects.contains(where: { if case .deleteSessionFile = $0 { return true }; return false }))
        #expect(effects.contains(where: { if case .cleanupTerminalCache = $0 { return true }; return false }))
    }

    // MARK: - Rename Card

    @Test("renameCard sets name and manual override")
    func renameCard() {
        let link = makeLink(id: "card_n1", name: "Old name")
        var state = stateWith([link])

        let _ = Reducer.reduce(state: &state, action: .renameCard(cardId: "card_n1", name: "New name"))

        #expect(state.links["card_n1"]?.name == "New name")
        #expect(state.links["card_n1"]?.manualOverrides.name == true)
    }

    // MARK: - Unlink

    @Test("unlinkFromCard clears the specified link type")
    func unlinkTypes() {
        let link = makeLink(
            id: "card_u1",
            tmuxLink: TmuxLink(sessionName: "tmux1"),
            worktreeLink: WorktreeLink(path: "/wt", branch: "feature")
        )
        var state = stateWith([link])

        let _ = Reducer.reduce(state: &state, action: .unlinkFromCard(cardId: "card_u1", linkType: .tmux))
        #expect(state.links["card_u1"]?.tmuxLink == nil)

        let _ = Reducer.reduce(state: &state, action: .unlinkFromCard(cardId: "card_u1", linkType: .worktree))
        #expect(state.links["card_u1"]?.worktreeLink == nil)
    }

    // MARK: - Kill Terminal

    @Test("killTerminal removes extra session and kills tmux")
    func killTerminal() {
        let link = makeLink(
            id: "card_k1",
            tmuxLink: TmuxLink(sessionName: "main", extraSessions: ["main-sh1", "main-sh2"])
        )
        var state = stateWith([link])

        let effects = Reducer.reduce(state: &state, action: .killTerminal(
            cardId: "card_k1", sessionName: "main-sh1"
        ))

        #expect(state.links["card_k1"]?.tmuxLink?.extraSessions == ["main-sh2"])
        #expect(effects.contains(where: { if case .killTmuxSession("main-sh1") = $0 { return true }; return false }))
    }

    // MARK: - Reconciliation

    @Test("reconciled preserves cards modified during reconciliation window (updatedAt comparison)")
    func reconciledPreservesNewerCards() {
        // Simulate: reconciliation snapshot was taken at T=0, then user launched a card at T=1.
        // Reconciled data is stale (from T=0 snapshot). In-memory state is fresh (from T=1).
        let snapshotTime = Date.now.addingTimeInterval(-5) // T=0: before launch

        let launching = makeLink(
            id: "card_launching",
            column: .inProgress,
            tmuxLink: TmuxLink(sessionName: "claude-sess_abc"),
            isLaunching: true
            // updatedAt defaults to .now (T=1: after snapshot)
        )
        let idle = makeLink(id: "card_idle", column: .backlog, updatedAt: snapshotTime)
        var state = stateWith([launching, idle])

        // Reconciled data based on stale snapshot (older updatedAt)
        let reconciledLaunching = makeLink(
            id: "card_launching",
            column: .waiting, // stale snapshot would compute waiting
            updatedAt: snapshotTime
        )
        let reconciledIdle = makeLink(id: "card_idle", column: .done, updatedAt: snapshotTime)

        let result = ReconciliationResult(
            links: [reconciledLaunching, reconciledIdle],
            sessions: [],
            activityMap: [:],
            tmuxSessions: []
        )
        let _ = Reducer.reduce(state: &state, action: .reconciled(result))

        // Launching card UNCHANGED (preserved because updatedAt is newer than snapshot)
        #expect(state.links["card_launching"]?.column == .inProgress)
        #expect(state.links["card_launching"]?.isLaunching == true)
        #expect(state.links["card_launching"]?.tmuxLink?.sessionName == "claude-sess_abc")

        // Idle card updated normally (same updatedAt → reconciled data wins)
        #expect(state.links["card_idle"] != nil)
    }

    @Test("terminal created during reconciliation window survives merge")
    func terminalSurvivesReconciliation() {
        let snapshotTime = Date.now.addingTimeInterval(-3) // reconciliation started 3s ago

        // Card had no terminal at snapshot time
        let card = makeLink(id: "card_t1", column: .backlog, updatedAt: snapshotTime)
        var state = stateWith([card])

        // User creates terminal AFTER snapshot was taken → updatedAt = .now
        let _ = Reducer.reduce(state: &state, action: .createTerminal(cardId: "card_t1"))
        #expect(state.links["card_t1"]?.tmuxLink != nil)
        let tmuxName = state.links["card_t1"]!.tmuxLink!.sessionName

        // Reconciliation result arrives with stale data (no terminal)
        let staleCard = makeLink(id: "card_t1", column: .backlog, updatedAt: snapshotTime)
        let result = ReconciliationResult(
            links: [staleCard],
            sessions: [],
            activityMap: [:],
            tmuxSessions: [tmuxName] // tmux IS live
        )
        let _ = Reducer.reduce(state: &state, action: .reconciled(result))

        // Terminal PRESERVED (in-memory updatedAt is newer than reconciled)
        #expect(state.links["card_t1"]?.tmuxLink?.sessionName == tmuxName)
    }

    @Test("launchCompleted survives subsequent reconciliation with stale snapshot")
    func launchCompletedNotOverwritten() {
        let snapshotTime = Date.now.addingTimeInterval(-3)

        // Simulate: launchCard happened, then launchCompleted happened
        let card = makeLink(
            id: "card_lc1",
            column: .inProgress,
            tmuxLink: TmuxLink(sessionName: "proj-card_lc1"),
            sessionLink: SessionLink(sessionId: "sess_new123")
            // updatedAt = .now (after snapshot)
        )
        var state = stateWith([card])

        // Stale reconciliation result (from snapshot before launch)
        let staleCard = makeLink(
            id: "card_lc1",
            column: .backlog, // was backlog at snapshot time
            updatedAt: snapshotTime
        )
        let result = ReconciliationResult(
            links: [staleCard],
            sessions: [],
            activityMap: [:],
            tmuxSessions: ["proj-card_lc1"]
        )
        let _ = Reducer.reduce(state: &state, action: .reconciled(result))

        // Card should NOT bounce back to backlog
        #expect(state.links["card_lc1"]?.column == .inProgress)
        #expect(state.links["card_lc1"]?.tmuxLink?.sessionName == "proj-card_lc1")
        #expect(state.links["card_lc1"]?.sessionLink?.sessionId == "sess_new123")
    }

    @Test("reconciled updates sessions and activity map")
    func reconciledUpdatesMetadata() {
        var state = AppState()

        let session = Session(id: "sess_1", name: "Test", messageCount: 5, modifiedTime: .now)
        let result = ReconciliationResult(
            links: [],
            sessions: [session],
            activityMap: ["sess_1": .activelyWorking],
            tmuxSessions: ["tmux1"],
            configuredProjects: [],
            excludedPaths: ["/excluded"]
        )
        let _ = Reducer.reduce(state: &state, action: .reconciled(result))

        #expect(state.sessions["sess_1"]?.name == "Test")
        #expect(state.activityMap["sess_1"] == .activelyWorking)
        #expect(state.tmuxSessions.contains("tmux1"))
        #expect(state.excludedPaths == ["/excluded"])
    }

    // MARK: - Add Extra Terminal

    @Test("addExtraTerminal appends to extraSessions")
    func addExtraTerminal() {
        let link = makeLink(
            id: "card_e1",
            tmuxLink: TmuxLink(sessionName: "main")
        )
        var state = stateWith([link])

        let effects = Reducer.reduce(state: &state, action: .addExtraTerminal(
            cardId: "card_e1", sessionName: "main-sh1"
        ))

        #expect(state.links["card_e1"]?.tmuxLink?.extraSessions == ["main-sh1"])
        #expect(effects.contains(where: { if case .createTmuxSession = $0 { return true }; return false }))
    }

    // MARK: - Select Card

    @Test("selectCard updates selectedCardId")
    func selectCard() {
        var state = AppState()

        let _ = Reducer.reduce(state: &state, action: .selectCard(cardId: "card_1"))
        #expect(state.selectedCardId == "card_1")

        let _ = Reducer.reduce(state: &state, action: .selectCard(cardId: nil))
        #expect(state.selectedCardId == nil)
    }

    // MARK: - Error Handling

    @Test("setError sets and clears error")
    func setError() {
        var state = AppState()

        let _ = Reducer.reduce(state: &state, action: .setError("Something went wrong"))
        #expect(state.error == "Something went wrong")

        let _ = Reducer.reduce(state: &state, action: .setError(nil))
        #expect(state.error == nil)
    }

    // MARK: - AppState Computed Properties

    @Test("cards computed property combines links, sessions, and activity")
    func cardsComputed() {
        var state = AppState()
        let link = makeLink(id: "card_c1", sessionLink: SessionLink(sessionId: "sess_1"))
        state.links["card_c1"] = link
        state.sessions["sess_1"] = Session(id: "sess_1", name: "My Session", messageCount: 3, modifiedTime: .now)
        state.activityMap["sess_1"] = .activelyWorking

        let cards = state.cards
        #expect(cards.count == 1)
        #expect(cards[0].session?.name == "My Session")
        #expect(cards[0].activityState == .activelyWorking)
    }

    @Test("filteredCards respects selectedProjectPath")
    func filteredCardsProjectFilter() {
        var state = AppState()
        state.links["c1"] = makeLink(id: "c1")  // projectPath = /test/project
        let otherLink = Link(id: "c2", name: "Other", projectPath: "/other/project", column: .backlog, source: .manual)
        state.links["c2"] = otherLink

        state.selectedProjectPath = "/test/project"
        #expect(state.filteredCards.count == 1)
        #expect(state.filteredCards[0].id == "c1")

        state.selectedProjectPath = nil // global view
        #expect(state.filteredCards.count == 2)
    }

    // MARK: - isShellOnly preserved through terminal creation

    @Test("createTerminal creates shell-only terminal with correct tab label")
    func createTerminalIsShellOnly() {
        let link = makeLink(id: "card_sh1", column: .backlog)
        var state = stateWith([link])

        let _ = Reducer.reduce(state: &state, action: .createTerminal(cardId: "card_sh1"))

        #expect(state.links["card_sh1"]?.tmuxLink?.isShellOnly == true)
        #expect(state.links["card_sh1"]?.column == .backlog) // unchanged
    }

    @Test("launchCard uses unique tmux name per card, not just project name")
    func launchCardUniqueTmuxName() {
        let link1 = makeLink(id: "card_a1", column: .backlog)
        let link2 = makeLink(id: "card_b2", column: .backlog)
        var state = stateWith([link1, link2])

        let _ = Reducer.reduce(state: &state, action: .launchCard(
            cardId: "card_a1", prompt: "test", projectPath: "/test/project",
            worktreeName: nil, runRemotely: false, commandOverride: nil
        ))
        let _ = Reducer.reduce(state: &state, action: .launchCard(
            cardId: "card_b2", prompt: "test", projectPath: "/test/project",
            worktreeName: nil, runRemotely: false, commandOverride: nil
        ))

        let name1 = state.links["card_a1"]?.tmuxLink?.sessionName ?? ""
        let name2 = state.links["card_b2"]?.tmuxLink?.sessionName ?? ""
        #expect(name1 != name2) // Different cards in same project get different tmux names
        #expect(name1.contains("project")) // Still includes project name for readability
        #expect(name1.contains("card_a1")) // Includes card ID for uniqueness
    }

    @Test("launchCard creates Claude terminal (not shell-only)")
    func launchCardNotShellOnly() {
        let link = makeLink(id: "card_cl1", column: .backlog)
        var state = stateWith([link])

        let _ = Reducer.reduce(state: &state, action: .launchCard(
            cardId: "card_cl1", prompt: "test", projectPath: "/test",
            worktreeName: nil, runRemotely: false, commandOverride: nil
        ))

        #expect(state.links["card_cl1"]?.tmuxLink?.isShellOnly != true)
    }
}
