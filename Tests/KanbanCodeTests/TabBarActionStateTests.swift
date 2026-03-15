import Testing
@testable import KanbanCode

@Suite("TabBarActionState")
struct TabBarActionStateTests {

    // MARK: - Claude tab selected (default)

    @Test("Claude tab selected with live Claude session: actions target Claude session")
    func claudeTabWithLiveSession() {
        let state = TabBarActionState(
            selectedTerminalSession: nil,
            selectedBrowserTabId: nil,
            claudeTmuxSession: "proj-abc",
            shellSessions: []
        )
        #expect(state.isClaudeTabSelected == true)
        #expect(state.showActionButtons == true)
        #expect(state.tmuxSessionForActions == "proj-abc")
    }

    @Test("Claude tab selected with dead session and no shells: actions hidden")
    func claudeTabDeadNoShells() {
        let state = TabBarActionState(
            selectedTerminalSession: nil,
            selectedBrowserTabId: nil,
            claudeTmuxSession: nil,
            shellSessions: []
        )
        #expect(state.isClaudeTabSelected == true)
        #expect(state.showActionButtons == false)
        #expect(state.tmuxSessionForActions == nil)
    }

    @Test("Claude tab selected with dead session but live shells: actions target first shell")
    func claudeTabDeadWithShells() {
        let state = TabBarActionState(
            selectedTerminalSession: nil,
            selectedBrowserTabId: nil,
            claudeTmuxSession: nil,
            shellSessions: ["proj-abc-sh1", "proj-abc-sh2"]
        )
        #expect(state.isClaudeTabSelected == true)
        #expect(state.showActionButtons == true)
        #expect(state.tmuxSessionForActions == "proj-abc-sh1")
    }

    // MARK: - Shell tab selected

    @Test("Shell tab selected: actions target selected shell")
    func shellTabSelected() {
        let state = TabBarActionState(
            selectedTerminalSession: "proj-abc-sh1",
            selectedBrowserTabId: nil,
            claudeTmuxSession: "proj-abc",
            shellSessions: ["proj-abc-sh1"]
        )
        #expect(state.isClaudeTabSelected == false)
        #expect(state.isBrowserTabSelected == false)
        #expect(state.showActionButtons == true)
        #expect(state.tmuxSessionForActions == "proj-abc-sh1")
    }

    // MARK: - Browser tab selected (the bug fix)

    @Test("Browser tab selected with live Claude: actions still visible, target Claude session")
    func browserTabWithLiveClaude() {
        let state = TabBarActionState(
            selectedTerminalSession: nil,
            selectedBrowserTabId: "browser-123",
            claudeTmuxSession: "proj-abc",
            shellSessions: []
        )
        #expect(state.isBrowserTabSelected == true)
        #expect(state.isClaudeTabSelected == false)
        #expect(state.effectiveActiveSession == nil)
        #expect(state.showActionButtons == true)
        #expect(state.tmuxSessionForActions == "proj-abc")
    }

    @Test("Browser tab selected with live shells: actions still visible, target first shell")
    func browserTabWithLiveShells() {
        let state = TabBarActionState(
            selectedTerminalSession: nil,
            selectedBrowserTabId: "browser-456",
            claudeTmuxSession: nil,
            shellSessions: ["proj-abc-sh1", "proj-abc-sh2"]
        )
        #expect(state.isBrowserTabSelected == true)
        #expect(state.showActionButtons == true)
        #expect(state.tmuxSessionForActions == "proj-abc-sh1")
    }

    @Test("Browser tab selected with Claude and shells: actions target Claude first")
    func browserTabWithClaudeAndShells() {
        let state = TabBarActionState(
            selectedTerminalSession: nil,
            selectedBrowserTabId: "browser-789",
            claudeTmuxSession: "proj-abc",
            shellSessions: ["proj-abc-sh1"]
        )
        #expect(state.showActionButtons == true)
        #expect(state.tmuxSessionForActions == "proj-abc")
    }

    @Test("Browser tab selected with no terminals: actions hidden")
    func browserTabNoTerminals() {
        let state = TabBarActionState(
            selectedTerminalSession: nil,
            selectedBrowserTabId: "browser-000",
            claudeTmuxSession: nil,
            shellSessions: []
        )
        #expect(state.isBrowserTabSelected == true)
        #expect(state.showActionButtons == false)
        #expect(state.tmuxSessionForActions == nil)
    }

    // MARK: - allLiveSessions ordering

    @Test("allLiveSessions puts Claude first, then shells")
    func liveSessionOrdering() {
        let state = TabBarActionState(
            selectedTerminalSession: nil,
            selectedBrowserTabId: nil,
            claudeTmuxSession: "proj-abc",
            shellSessions: ["proj-abc-sh1", "proj-abc-sh2"]
        )
        #expect(state.allLiveSessions == ["proj-abc", "proj-abc-sh1", "proj-abc-sh2"])
    }

    @Test("allLiveSessions with no Claude includes only shells")
    func liveSessionsNoClaudeSession() {
        let state = TabBarActionState(
            selectedTerminalSession: nil,
            selectedBrowserTabId: nil,
            claudeTmuxSession: nil,
            shellSessions: ["proj-abc-sh1"]
        )
        #expect(state.allLiveSessions == ["proj-abc-sh1"])
    }

    @Test("allLiveSessions empty when no sessions")
    func liveSessionsEmpty() {
        let state = TabBarActionState(
            selectedTerminalSession: nil,
            selectedBrowserTabId: nil,
            claudeTmuxSession: nil,
            shellSessions: []
        )
        #expect(state.allLiveSessions.isEmpty)
    }
}
