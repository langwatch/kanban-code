import Foundation
import KanbanCodeRemoteKit
import Testing

@testable import KanbanCodeCore

@Suite("Remote control mapping")
struct RemoteControlMapperTests {

    private static func link(
        id: String = "card_1",
        column: KanbanCodeColumn = .inProgress,
        tmux: TmuxLink? = TmuxLink(sessionName: "card-abc", extraSessions: ["card-abc-sh1"]),
        remote: RemoteLink? = nil
    ) -> Link {
        var link = Link(
            id: id, name: "Fix the flaky test", projectPath: "/Users/me/acme", column: column,
            sessionLink: SessionLink(sessionId: "s-1", sessionPath: "/tmp/s-1.jsonl"),
            tmuxLink: tmux,
            worktreeLink: WorktreeLink(path: "/Users/me/acme/.claude/worktrees/x", branch: "fix/flaky"),
            prLinks: [PRLink(number: 7, url: "https://github.com/acme/acme/pull/7", status: .approved)],
            queuedPrompts: [QueuedPrompt(body: "also run the tests")],
            assistant: .claude,
            remote: remote
        )
        link.tmuxLink?.tabNames = ["card-abc-sh1": "server"]
        return link
    }

    @Test("a live tmux card maps every field the API sends")
    func tmuxCard() {
        let card = KanbanCodeCard(link: Self.link(), activityState: .activelyWorking)
        let remote = RemoteBoardMapper.card(card, liveSessions: ["card-abc"])
        #expect(remote.id == "card_1")
        #expect(remote.title == "Fix the flaky test")
        #expect(remote.column == .inProgress)
        #expect(remote.projectName == "acme")
        #expect(remote.branch == "fix/flaky")
        #expect(remote.runtime == .tmux)
        #expect(remote.isLive)
        #expect(remote.isBusy)
        #expect(remote.sessionId == "s-1")
        #expect(remote.queuedPromptCount == 1)
        #expect(remote.prs == [RemotePR(number: 7, url: "https://github.com/acme/acme/pull/7", status: "open")])
        #expect(remote.terminals == [
            RemoteTerminal(sessionName: "card-abc", label: "Claude Code", isPrimary: true),
            RemoteTerminal(sessionName: "card-abc-sh1", label: "server", isPrimary: false),
        ])
    }

    @Test("runtime and liveness: agtop, machine, shell only, ended")
    func runtimes() {
        let agtop = Self.link(tmux: TmuxLink(sessionName: "agtop-0123abcd"))
        #expect(RemoteBoardMapper.runtime(of: agtop) == .agtop)
        #expect(RemoteBoardMapper.isLive(agtop, liveSessions: ["agtop-0123abcd"]))

        let machine = Self.link(remote: RemoteLink(machineName: "kanban-acme-1"))
        #expect(RemoteBoardMapper.runtime(of: machine) == .machine)

        let shell = Self.link(tmux: TmuxLink(sessionName: "card-abc", isShellOnly: true))
        #expect(RemoteBoardMapper.runtime(of: shell) == .none)
        #expect(!RemoteBoardMapper.isLive(shell, liveSessions: ["card-abc"]))

        let ended = Self.link()
        #expect(!RemoteBoardMapper.isLive(ended, liveSessions: []))
        #expect(RemoteBoardMapper.liveAssistantSession(ended, liveSessions: []) == nil)
        #expect(RemoteBoardMapper.runtime(of: Self.link(tmux: nil)) == .none)
    }

    @Test("projects resolve by path, then name, case-insensitive")
    func projects() {
        let projects = [Project(path: "/Users/me/langwatch", name: "LangWatch"), Project(path: "/Users/me/scenario", name: "scenario")]
        #expect(RemoteBoardMapper.resolveProject("/Users/me/scenario", in: projects)?.name == "scenario")
        #expect(RemoteBoardMapper.resolveProject("/Users/me/scenario/", in: projects)?.name == "scenario")
        #expect(RemoteBoardMapper.resolveProject("langwatch", in: projects)?.path == "/Users/me/langwatch")
        #expect(RemoteBoardMapper.resolveProject("nope", in: projects) == nil)
    }

    @Test("the board lists newest activity first")
    func boardOrder() {
        var old = Self.link(id: "old")
        old.lastActivity = Date(timeIntervalSince1970: 100)
        var new = Self.link(id: "new")
        new.lastActivity = Date(timeIntervalSince1970: 200)
        let board = RemoteBoardMapper.board(
            cards: [KanbanCodeCard(link: old), KanbanCodeCard(link: new)],
            projects: [Project(path: "/Users/me/acme", name: "acme")],
            liveSessions: []
        )
        #expect(board.cards.map(\.id) == ["new", "old"])
        #expect(board.projects == [RemoteProject(path: "/Users/me/acme", name: "acme")])
    }

    private static func turns() -> [ConversationTurn] {
        [
            ConversationTurn(index: 0, lineNumber: 0, role: "user", textPreview: "fix it",
                             timestamp: "2026-09-26T10:00:00.000Z",
                             contentBlocks: [ContentBlock(kind: .text, text: "fix it")]),
            ConversationTurn(index: 1, lineNumber: 100, role: "assistant", textPreview: "",
                             contentBlocks: [
                                ContentBlock(kind: .thinking, text: "hmm"),
                                ContentBlock(kind: .text, text: "Looking."),
                                ContentBlock(kind: .toolUse(name: "Bash", input: ["command": "pnpm test"]), text: "Bash(pnpm test)\nmore"),
                                ContentBlock(kind: .text, text: "Tests pass."),
                             ]),
            ConversationTurn(index: 2, lineNumber: 200, role: "user", textPreview: "",
                             contentBlocks: [ContentBlock(kind: .toolResult(toolName: "Bash"), text: "ok")]),
            ConversationTurn(index: 3, lineNumber: 300, role: "assistant", textPreview: "",
                             contentBlocks: [ContentBlock(kind: .agentCall(description: "review", subagentType: "Explore", id: nil), text: "review")]),
        ]
    }

    @Test("turns become user, assistant and one-line tool messages")
    func messages() {
        let messages = RemoteTranscriptMapper.messages(from: Self.turns())
        #expect(messages.map(\.role) == [.user, .assistant, .tool, .assistant, .tool])
        #expect(messages.map(\.text) == ["fix it", "Looking.", "Bash(pnpm test)", "Tests pass.", "Agent Explore: review"])
        #expect(messages[0].at != nil)
        #expect(Set(messages.map(\.id)).count == messages.count)
    }

    @Test("pages go back with the cursor until the start")
    func paging() async throws {
        let turns = Self.turns()
        let load: RemoteTranscriptMapper.TailLoader = { maxTurns in
            (Array(turns.suffix(maxTurns)), turns.count > maxTurns)
        }
        let first = try await RemoteTranscriptMapper.page(cardId: "c", limit: 2, before: nil, load: load)
        #expect(first.messages.map(\.text) == ["Tests pass.", "Agent Explore: review"])
        let cursor = try #require(first.olderCursor)
        let second = try await RemoteTranscriptMapper.page(cardId: "c", limit: 2, before: cursor, load: load)
        #expect(second.messages.map(\.text) == ["Looking.", "Bash(pnpm test)"])
        let third = try await RemoteTranscriptMapper.page(cardId: "c", limit: 2, before: second.olderCursor, load: load)
        #expect(third.messages.map(\.text) == ["fix it"])
        #expect(third.olderCursor == nil)
        await #expect(throws: RemoteHostError.self) {
            _ = try await RemoteTranscriptMapper.page(cardId: "c", limit: 2, before: "999.0", load: load)
        }
    }

    @Test("remote control settings are off by default and round trip")
    func settings() throws {
        let decoded = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        #expect(decoded.remoteControl == RemoteControlSettings(enabled: false, port: 7780))
        var settings = Settings()
        settings.remoteControl = RemoteControlSettings(enabled: true, port: 7781)
        let again = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        #expect(again.remoteControl == RemoteControlSettings(enabled: true, port: 7781))
    }
}

@Suite("Remote working set")
struct RemoteWorkingSetTests {
    static func card(_ id: String, _ column: RemoteColumn, archived: Bool = false, minutesAgo: Double = 0) -> RemoteCard {
        RemoteCard(id: id, title: id, column: column, archived: archived,
                   lastActivity: Date(timeIntervalSince1970: 1_800_000_000 - minutesAgo * 60),
                   updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test("drops archived and All Sessions cards, keeps the 30 most recent Done")
    func filter() {
        var cards = [
            Self.card("wip", .inProgress),
            Self.card("wait", .waiting, minutesAgo: 9999),
            Self.card("arch", .inProgress, archived: true),
            Self.card("sess", .allSessions),
            Self.card("done-archived", .done, archived: true),
        ]
        cards += (0..<40).map { Self.card("done\($0)", .done, minutesAgo: Double($0)) }
        let ids = RemoteWorkingSet.filter(cards).map(\.id)
        #expect(ids.contains("wip"))
        #expect(ids.contains("wait"))
        #expect(!ids.contains("arch"))
        #expect(!ids.contains("sess"))
        #expect(!ids.contains("done-archived"))
        #expect(ids.filter { $0.hasPrefix("done") }.count == 30)
        #expect(ids.contains("done0"))
        #expect(ids.contains("done29"))
        #expect(!ids.contains("done30"))
    }
}
