import Foundation
import KanbanCodeRemoteKit

/// Sample board and conversation for SwiftUI previews.
enum PreviewData {
    static let board: RemoteBoard = {
        let now = Date.now
        return RemoteBoard(cards: [
            RemoteCard(id: "c1", title: "Fix the flaky scheduler test", column: .waiting,
                       projectPath: "/Users/me/Projects/langwatch", projectName: "langwatch",
                       branch: "fix/flaky-scheduler", assistant: "claude", runtime: .rush,
                       isLive: true, terminals: [RemoteTerminal(sessionName: "card-c1", label: "Claude", isPrimary: true),
                                                RemoteTerminal(sessionName: "card-c1-sh1", label: "Shell 1", isPrimary: false)],
                       prs: [RemotePR(number: 8312, status: "open")], lastActivity: now.addingTimeInterval(-120), updatedAt: now,
                       conversations: conversations),
            RemoteCard(id: "c2", title: "Add dark mode to the settings page", column: .inProgress,
                       projectName: "kanban", branch: "feat/dark-settings", runtime: .tmux,
                       isLive: true, isBusy: true, queuedPromptCount: 2,
                       lastActivity: now.addingTimeInterval(-20), updatedAt: now),
            RemoteCard(id: "c3", title: "Upgrade the Postgres driver", column: .inReview, projectName: "langwatch",
                       branch: "chore/pg-driver", prs: [RemotePR(number: 8290, status: "draft")],
                       lastActivity: now.addingTimeInterval(-7200), updatedAt: now),
            RemoteCard(id: "c4", title: "Write the remote control docs", column: .backlog, projectName: "kanban",
                       updatedAt: now.addingTimeInterval(-86_400 * 2)),
            RemoteCard(id: "c5", title: "Ship 0.4.0", column: .done, projectName: "kanban",
                       prs: [RemotePR(number: 150, status: "merged")],
                       lastActivity: now.addingTimeInterval(-86_400 * 9), updatedAt: now),
        ], projects: [
            RemoteProject(path: "/Users/me/Projects/langwatch", name: "langwatch"),
            RemoteProject(path: "/Users/me/Projects/kanban", name: "kanban"),
        ], generatedAt: now)
    }()

    static let boxBoard: RemoteBoard = {
        let now = Date.now
        let box = RemoteMachine(id: "machine_box", name: "rchaves-platform")
        return RemoteBoard(cards: [
            RemoteCard(id: "b1", title: "Nightly data backfill", column: .inProgress, projectName: "langwatch",
                       runtime: .tmux, isLive: true, isBusy: true, lastActivity: now.addingTimeInterval(-1600),
                       updatedAt: now, machineId: box.id, machineName: box.name),
            RemoteCard(id: "b2", title: "Deploy the blog", column: .waiting, projectName: "kanban",
                       runtime: .tmux, isLive: true, lastActivity: now.addingTimeInterval(-1900),
                       updatedAt: now, machineId: box.id, machineName: box.name),
        ], projects: [RemoteProject(path: "/root/Projects/kanban", name: "kanban")], generatedAt: now, machine: box)
    }()

    static let conversations: [RemoteConversation] = {
        let now = Date.now
        return [
            RemoteConversation(id: "swift-otter", title: "Retry policy for the job runner", createdAt: now.addingTimeInterval(-3600),
                               updatedAt: now.addingTimeInterval(-300), messageCount: 2, lastRole: .agent,
                               preview: "Three retries with backoff, then park the job.", unread: true, waiting: true, replied: true),
            RemoteConversation(id: "calm-heron", createdAt: now.addingTimeInterval(-900), updatedAt: now.addingTimeInterval(-600),
                               messageCount: 1, lastRole: .human, preview: "Can we also drop the old cron entry?"),
        ]
    }()

    static let conversationDetail: RemoteConversationDetail = {
        let now = Date.now
        var summary = conversations[0]
        summary.quote = "The scheduler test reads the wall clock twice, so a tick between the reads moves the window."
        return RemoteConversationDetail(conversation: summary, messages: [
            RemoteConversationMessage(id: "h1", role: .human, text: "What should the retry policy be when a job fails?",
                                      at: now.addingTimeInterval(-600)),
            RemoteConversationMessage(id: "a1", role: .agent, text: """
            Three retries with backoff, then park the job:

            - 10 s, 60 s, 5 min
            - after that it goes to **parked** and shows on the board
            """, at: now.addingTimeInterval(-300)),
        ])
    }()

    static let messages: [RemoteMessage] = [
        RemoteMessage(id: "m1", role: .user, text: "The scheduler test fails one run in ten. Find out why."),
        RemoteMessage(id: "m2", role: .assistant, text: """
        ## Cause

        The test reads the **wall clock** twice, so a tick between the reads moves the window.

        - `scheduler.test.ts` builds the window from `Date.now()`
        - the job reads it again inside `nextRun()`

        ```ts
        const now = clock.now()
        expect(nextRun(now)).toBe(now + 60_000)
        ```
        """),
        RemoteMessage(id: "m3", role: .tool, text: "Edit src/scheduler/nextRun.ts (+4 -2)"),
        RemoteMessage(id: "m4", role: .tool, text: "Bash pnpm test scheduler --repeat 50: 50 passed"),
        RemoteMessage(id: "m5", role: .assistant, text: "Fixed by passing a single `now` through. 50 runs in a row pass."),
    ]
}
