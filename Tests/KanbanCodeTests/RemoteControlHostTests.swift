import Foundation
import KanbanCodeCore
import KanbanCodeRemoteKit
import Testing

@testable import KanbanCode

private final class SentPrompts: TmuxManagerPort, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [(session: String, text: String)] = []
    private var _escapes: [String] = []

    var sent: [(session: String, text: String)] { lock.withLock { _sent } }
    var escapes: [String] { lock.withLock { _escapes } }
    func escape(_ session: String) { lock.withLock { _escapes.append(session) } }
    private func record(_ session: String, _ text: String) { lock.withLock { _sent.append((session, text)) } }

    func listSessions() async throws -> [TmuxSession] { [] }
    func createSession(name: String, path: String, command: String?) async throws {}
    func killSession(name: String) async throws {}
    func findSessionForWorktree(sessions: [TmuxSession], worktreePath: String, branch: String?) -> TmuxSession? { nil }
    func sendPrompt(to sessionName: String, text: String) async throws { record(sessionName, text) }
    func pastePrompt(to sessionName: String, text: String) async throws { record(sessionName, text) }
    func pasteText(to sessionName: String, text: String) async throws {}
    func submitPrompt(to sessionName: String) async throws {}
    func capturePane(sessionName: String) async throws -> String { "" }
    func sendBracketedPaste(to sessionName: String) async throws {}
    func isAvailable() async -> Bool { true }
}

/// The app's remote control host over a real store: prompts, interrupts and
/// terminals go through the same actions and commands as the UI.
@Suite("Remote control host")
@MainActor
struct RemoteControlHostTests {
    private final class TmuxCommands: @unchecked Sendable {
        private let lock = NSLock()
        private var _runs: [(commands: [[String]], session: String)] = []
        var runs: [(commands: [[String]], session: String)] { lock.withLock { _runs } }
        func record(_ commands: [[String]], _ session: String) { lock.withLock { _runs.append((commands, session)) } }
    }

    private let tmuxCommands = TmuxCommands()

    /// A stand-in `agtop` that logs each call and answers `info` with the
    /// queue in `queue.json`.
    private struct FakeAgtop {
        let dir = NSTemporaryDirectory() + "kanban-remote-agtop-\(UUID().uuidString)"
        var path: String { "\(dir)/agtop" }

        init() throws {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let script = """
            #!/bin/sh
            echo "ARGS $*" >> '\(dir)/calls.log'
            case "$2" in
              send) echo "STDIN $(cat)" >> '\(dir)/calls.log' ;;
              info) printf '{"id":"%s","sessionId":"s","cwd":"/r","state":"working","alive":true,"queue":%s}' "$3" "$(cat '\(dir)/queue.json' 2>/dev/null || echo '[]')" ;;
            esac
            """
            try script.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }

        func setQueue(_ queue: [String]) throws {
            try JSONEncoder().encode(queue).write(to: URL(fileURLWithPath: "\(dir)/queue.json"))
        }

        func calls() -> String { (try? String(contentsOfFile: "\(dir)/calls.log", encoding: .utf8)) ?? "" }
        func adapter() -> AgtopCliAdapter { AgtopCliAdapter(executable: path, scratchDirectory: "\(dir)/scratch") }
        func cleanup() { try? FileManager.default.removeItem(atPath: dir) }
    }

    private func makeHost(agtop: AgtopCliAdapter = AgtopCliAdapter(executable: "/nonexistent/agtop")) -> (AppRemoteControlHost, BoardStore, SentPrompts) {
        let tmux = SentPrompts()
        let dir = NSTemporaryDirectory() + "kanban-remote-host-\(UUID().uuidString)"
        let store = BoardStore(
            effectHandler: EffectHandler(
                coordinationStore: CoordinationStore(basePath: dir),
                tmuxAdapter: tmux,
                queuedPromptJournal: QueuedPromptJournal(basePath: dir)
            ),
            discovery: ClaudeCodeSessionDiscovery(),
            coordinationStore: CoordinationStore(basePath: dir)
        )
        let commands = tmuxCommands
        let host = AppRemoteControlHost(store: store, agtop: agtop, runTmux: { commands.record($0, $1) }) { session in tmux.escape(session) }
        return (host, store, tmux)
    }

    private func addCard(_ store: BoardStore, id: String, session: String, live: Bool, busy: Bool) {
        let link = Link(
            id: id, name: "Card \(id)", projectPath: "/tmp/acme", column: .inProgress,
            sessionLink: SessionLink(sessionId: "sid-\(id)"), tmuxLink: TmuxLink(sessionName: session)
        )
        store.dispatch(.createManualTask(link))
        store.dispatch(.tmuxLivenessScanned(live: live ? store.state.tmuxSessions.union([session]) : store.state.tmuxSessions))
        if busy { store.dispatch(.activityChanged(["sid-\(id)": .activelyWorking])) }
    }

    private func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<50 where !condition() { try? await Task.sleep(for: .milliseconds(20)) }
    }

    @Test("the board lists the store's cards")
    func board() async {
        let (host, store, _) = makeHost()
        addCard(store, id: "card_a", session: "card-a", live: true, busy: false)
        let board = await host.board()
        let card = board.cards.first { $0.id == "card_a" }
        #expect(card?.isLive == true)
        #expect(card?.runtime == .tmux)
    }

    @Test("a prompt to an idle card goes out at once")
    func promptIdle() async throws {
        let (host, store, tmux) = makeHost()
        addCard(store, id: "card_a", session: "card-a", live: true, busy: false)
        try await host.sendPrompt(cardId: "card_a", RemotePromptRequest(text: "hello", mode: .queue), images: [])
        await waitFor { !tmux.sent.isEmpty }
        #expect(tmux.sent.map(\.text) == ["hello"])
        #expect(store.state.links["card_a"]?.queuedPrompts == nil)
    }

    @Test("a queued prompt to a busy card waits in the card's queue")
    func promptBusy() async throws {
        let (host, store, tmux) = makeHost()
        addCard(store, id: "card_a", session: "card-a", live: true, busy: true)
        try await host.sendPrompt(cardId: "card_a", RemotePromptRequest(text: "after this", mode: .queue), images: [])
        #expect(store.state.links["card_a"]?.queuedPrompts?.map(\.body) == ["after this"])
        #expect(store.state.links["card_a"]?.queuedPrompts?.first?.sendAutomatically == true)
        #expect(tmux.sent.isEmpty)
    }

    @Test("mode now interrupts a busy card, then sends")
    func promptNow() async throws {
        let (host, store, tmux) = makeHost()
        addCard(store, id: "card_a", session: "card-a", live: true, busy: true)
        try await host.sendPrompt(cardId: "card_a", RemotePromptRequest(text: "stop, wrong file", mode: .now), images: [])
        await waitFor { !tmux.sent.isEmpty }
        #expect(tmux.escapes == ["card-a"])
        #expect(tmux.sent.map(\.text) == ["stop, wrong file"])
    }

    @Test("a card without a live session refuses prompts and interrupts with 409")
    func notLive() async {
        let (host, store, _) = makeHost()
        addCard(store, id: "card_a", session: "card-a", live: false, busy: false)
        await #expect(throws: RemoteHostError.conflict("card card_a has no live session; resume it first")) {
            try await host.sendPrompt(cardId: "card_a", RemotePromptRequest(text: "x"), images: [])
        }
        await #expect(throws: RemoteHostError.self) { try await host.interrupt(cardId: "card_a") }
        await #expect(throws: RemoteHostError.notFound("no card nope")) {
            try await host.interrupt(cardId: "nope")
        }
    }

    @Test("a prompt's images are written to files and queued with it")
    func promptImages() async throws {
        let (host, store, _) = makeHost()
        addCard(store, id: "card_a", session: "card-a", live: true, busy: true)
        let jpeg = RemotePromptImages.Decoded(bytes: Data([0xFF, 0xD8, 0xFF, 0xE0]), fileExtension: "jpg")
        try await host.sendPrompt(cardId: "card_a", RemotePromptRequest(text: "this screen"), images: [jpeg])
        let paths = store.state.links["card_a"]?.queuedPrompts?.first?.imagePaths ?? []
        #expect(paths.count == 1)
        #expect(paths.first?.hasSuffix(".jpg") == true)
        #expect(paths.first.flatMap { FileManager.default.contents(atPath: $0) } == jpeg.bytes)
        paths.forEach { try? FileManager.default.removeItem(atPath: $0) }
    }

    @Test("send now on a queued prompt interrupts the turn and sends that prompt")
    func queuedSendNow() async throws {
        let (host, store, tmux) = makeHost()
        addCard(store, id: "card_a", session: "card-a", live: true, busy: true)
        try await host.sendPrompt(cardId: "card_a", RemotePromptRequest(text: "first"), images: [])
        try await host.sendPrompt(cardId: "card_a", RemotePromptRequest(text: "second"), images: [])
        let second = try #require(store.state.links["card_a"]?.queuedPrompts?.last)
        #expect(await host.board().cards.first { $0.id == "card_a" }?.queuedPrompts.map(\.text) == ["first", "second"])

        try await host.sendQueuedPromptNow(cardId: "card_a", promptId: second.id)
        await waitFor { !tmux.sent.isEmpty }
        #expect(tmux.escapes == ["card-a"])
        #expect(tmux.sent.map(\.text) == ["second"])
        #expect(store.state.links["card_a"]?.queuedPrompts?.map(\.body) == ["first"])

        await #expect(throws: RemoteHostError.self) {
            try await host.sendQueuedPromptNow(cardId: "card_a", promptId: second.id)
        }
    }

    @Test("a queued prompt can be removed")
    func queuedRemove() async throws {
        let (host, store, tmux) = makeHost()
        addCard(store, id: "card_a", session: "card-a", live: true, busy: true)
        try await host.sendPrompt(cardId: "card_a", RemotePromptRequest(text: "never mind"), images: [])
        let prompt = try #require(store.state.links["card_a"]?.queuedPrompts?.first)
        try await host.removeQueuedPrompt(cardId: "card_a", promptId: prompt.id)
        #expect(store.state.links["card_a"]?.queuedPrompts == nil)
        #expect(tmux.sent.isEmpty)
        await #expect(throws: RemoteHostError.self) {
            try await host.removeQueuedPrompt(cardId: "card_a", promptId: prompt.id)
        }
    }

    @Test("terminal scroll drives tmux copy-mode; agtop is left to mouse reporting")
    func terminalScroll() async {
        let (host, _, _) = makeHost()
        await host.scrollTerminal(sessionName: "card-a", lines: 4)
        await host.scrollTerminal(sessionName: AgtopSessionName.name(agtopId: "abcd1234"), lines: 4)
        #expect(tmuxCommands.runs.map(\.session) == ["card-a"])
        #expect(tmuxCommands.runs.first?.commands == RemoteTerminalScroll.tmuxCommands(session: "card-a", lines: 4))
    }

    @Test("an agtop card sends through agtop: queue lets agtop queue it, now goes mid-turn, never Esc")
    func agtopPrompts() async throws {
        let fake = try FakeAgtop()
        defer { fake.cleanup() }
        let (host, store, tmux) = makeHost(agtop: fake.adapter())
        addCard(store, id: "card_a", session: "agtop-0a1b2c3d", live: true, busy: true)
        try fake.setQueue(["after this"])
        try await host.sendPrompt(cardId: "card_a", RemotePromptRequest(text: "after this", mode: .queue), images: [])
        try await host.sendPrompt(cardId: "card_a", RemotePromptRequest(text: "right now", mode: .now), images: [])
        let calls = fake.calls()
        #expect(calls.contains("ARGS session send 0a1b2c3d\nSTDIN after this"))
        #expect(calls.contains("ARGS session send 0a1b2c3d --now\nSTDIN right now"))
        #expect(tmux.escapes.isEmpty)
        #expect(tmux.sent.isEmpty)
        #expect(store.state.links["card_a"]?.queuedPrompts == nil)
        // The queue agtop reports is the card's queue.
        #expect(store.state.agtopQueues == ["agtop-0a1b2c3d": ["after this"]])
        let card = await host.board().cards.first { $0.id == "card_a" }
        #expect(card?.queuedPrompts.map(\.text) == ["after this"])
        #expect(card?.queuedPromptCount == 1)
    }

    @Test("send now and remove on an agtop queued message map to agtop's queue commands")
    func agtopQueueActions() async throws {
        let fake = try FakeAgtop()
        defer { fake.cleanup() }
        let (host, store, _) = makeHost(agtop: fake.adapter())
        addCard(store, id: "card_a", session: "agtop-0a1b2c3d", live: true, busy: true)
        store.dispatch(.agtopQueueRead(sessionName: "agtop-0a1b2c3d", queue: ["one", "two"]))
        try fake.setQueue(["one", "two"])
        let ids = await host.board().cards.first { $0.id == "card_a" }?.queuedPrompts.map(\.id) ?? []
        #expect(ids.count == 2)

        try await host.sendQueuedPromptNow(cardId: "card_a", promptId: ids[1])
        #expect(fake.calls().contains("ARGS session queue 0a1b2c3d send 1 --was two"))
        try fake.setQueue(["one"])
        try await host.removeQueuedPrompt(cardId: "card_a", promptId: ids[0])
        #expect(fake.calls().contains("ARGS session queue 0a1b2c3d remove 0 --was one"))

        try fake.setQueue([])
        await #expect(throws: RemoteHostError.self) {
            try await host.sendQueuedPromptNow(cardId: "card_a", promptId: ids[1])
        }
        #expect(store.state.agtopQueues.isEmpty)
    }

    @Test("interrupt sends Esc to the live session")
    func interrupt() async throws {
        let (host, store, tmux) = makeHost()
        addCard(store, id: "card_a", session: "card-a", live: true, busy: true)
        try await host.interrupt(cardId: "card_a")
        #expect(tmux.escapes == ["card-a"])
    }

    @Test("terminals: agtop opens its own UI, tmux attaches, unknown sessions are refused")
    func terminals() async throws {
        let (host, store, _) = makeHost()
        addCard(store, id: "card_a", session: "agtop-0123abcd", live: true, busy: false)
        addCard(store, id: "card_b", session: "card-b", live: true, busy: false)
        let agtop = try await host.terminalCommand(cardId: "card_a", sessionName: "agtop-0123abcd")
        #expect(Array(agtop.suffix(3)) == ["open", "0123abcd", "--solo"])
        let tmux = try await host.terminalCommand(cardId: "card_b", sessionName: "card-b")
        #expect(tmux.last?.contains("attach-session -t 'card-b'") == true)
        await #expect(throws: RemoteHostError.self) {
            _ = try await host.terminalCommand(cardId: "card_b", sessionName: "card-a")
        }
    }

    @Test("board changes yield when the store's cards change")
    func changes() async throws {
        let (host, store, _) = makeHost()
        let stream = host.boardChanges()
        try await Task.sleep(for: .milliseconds(50))
        let got = Task { () -> Bool in
            for await _ in stream { return true }
            return false
        }
        addCard(store, id: "card_a", session: "card-a", live: true, busy: false)
        let result = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { await got.value }
            group.addTask {
                try await Task.sleep(for: .seconds(3))
                return false
            }
            let first = try await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(result)
    }
}
