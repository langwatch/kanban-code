import Foundation
import KanbanCodeRemoteKit
import Testing

@testable import KanbanCodeCore

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

    /// A stand-in for the older `agtop` build of rush that logs each call
    /// and answers `info` with the queue in `queue.json`.
    private struct FakeRush {
        let dir = NSTemporaryDirectory() + "kanban-remote-rush-\(UUID().uuidString)"
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
        func adapter() -> RushCliAdapter { RushCliAdapter(executable: path, scratchDirectory: "\(dir)/scratch") }
        func cleanup() { try? FileManager.default.removeItem(atPath: dir) }
    }

    private func makeHost(rush: RushCliAdapter = RushCliAdapter(executable: "/nonexistent/rush")) -> (MasterRemoteControlHost, BoardStore, SentPrompts) {
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
        let engine = MasterEngine(
            store: store,
            settingsStore: SettingsStore(basePath: dir),
            launcher: LaunchSession(tmux: tmux),
            tmux: RoutingTmuxAdapter(rush: rush),
            registry: CodingAssistantRegistry()
        )
        let host = MasterRemoteControlHost(engine: engine, rush: rush, runTmux: { commands.record($0, $1) }) { session in tmux.escape(session) }
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

    @Test("an approval that needs the device's vault key is refused without what the key unlocked")
    func approvalNeedsTheDeviceKey() async throws {
        let (host, store, _) = makeHost()
        store.dispatch(.attentionRaised(AttentionRequest(
            id: "vault_sealed", cardId: nil, kind: .vaultApproval, title: "A card wants to use the Stripe key", body: "",
            options: AttentionRequest.vaultApprovalOptions, requiresBiometry: true,
            unseal: VaultUnsealChallenge(secrets: [.init(name: "STRIPE", sealed: "AAAA")]))))
        do {
            try await host.resolveAttention(id: "vault_sealed", resolution: "Approve once", by: "phone")
            Issue.record("an approval without the unlocked value must be refused")
        } catch let error as RemoteHostError {
            #expect(error.message == AttentionAnswerCopy.needsDeviceKey)
        }
        #expect(store.state.attentionRequests["vault_sealed"]?.isOpen == true)
        let unsealed = VaultUnsealed(values: ["STRIPE": "sk"], device: "abcd")
        try await host.resolveAttention(id: "vault_sealed", resolution: "Approve once", by: "phone", unsealed: unsealed)
        #expect(store.state.attentionRequests["vault_sealed"]?.resolution == "Approve once")

        // A denial needs no key.
        store.dispatch(.attentionRaised(AttentionRequest(
            id: "vault_sealed2", cardId: nil, kind: .vaultApproval, title: "A card wants to use the Stripe key", body: "",
            options: AttentionRequest.vaultApprovalOptions,
            unseal: VaultUnsealChallenge(secrets: [.init(name: "STRIPE", sealed: "AAAA")]))))
        try await host.resolveAttention(id: "vault_sealed2", resolution: "Deny", by: "phone")
        #expect(store.state.attentionRequests["vault_sealed2"]?.resolution == "Deny")
    }

    @Test("answering a request twice with the same answer is quiet, and no refusal names the request id")
    func answeringTwice() async throws {
        let (host, store, _) = makeHost()
        store.dispatch(.attentionRaised(AttentionRequest(
            id: "vault_abc123", cardId: nil, kind: .vaultApproval, title: "A card wants AWS lw-dev access", body: "",
            options: AttentionRequest.vaultApprovalOptions)))
        try await host.resolveAttention(id: "vault_abc123", resolution: "Approve once", by: "phone")
        #expect(store.state.openAttentionRequests.isEmpty)
        // The same answer again (a second tap, a retry) changes nothing.
        try await host.resolveAttention(id: "vault_abc123", resolution: "Approve once", by: "phone")
        #expect(store.state.attentionRequests["vault_abc123"]?.resolution == "Approve once")

        do {
            try await host.resolveAttention(id: "vault_abc123", resolution: "Deny", by: "mac")
            Issue.record("a different answer to a settled request must be refused")
        } catch let error as RemoteHostError {
            #expect(error.kind == .conflict)
            #expect(error.message == "This was already answered on the phone: Approve once.")
        }
        do {
            try await host.resolveAttention(id: "vault_never", resolution: "Deny", by: "mac")
            Issue.record("an unknown request must be refused")
        } catch let error as RemoteHostError {
            #expect(error.kind == .notFound)
            #expect(!error.message.contains("vault_never"))
        }
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

    @Test("terminal scroll drives tmux copy-mode; rush is left to mouse reporting")
    func terminalScroll() async {
        let (host, _, _) = makeHost()
        await host.scrollTerminal(sessionName: "card-a", lines: 4)
        await host.scrollTerminal(sessionName: RushSessionName.name(rushId: "abcd1234"), lines: 4)
        #expect(tmuxCommands.runs.map(\.session) == ["card-a"])
        #expect(tmuxCommands.runs.first?.commands == RemoteTerminalScroll.tmuxCommands(session: "card-a", lines: 4))
    }

    @Test("a rush card sends through rush: queue lets rush queue it, now goes mid-turn, never Esc")
    func rushPrompts() async throws {
        let fake = try FakeRush()
        defer { fake.cleanup() }
        let (host, store, tmux) = makeHost(rush: fake.adapter())
        addCard(store, id: "card_a", session: "rush-0a1b2c3d", live: true, busy: true)
        try fake.setQueue(["after this"])
        try await host.sendPrompt(cardId: "card_a", RemotePromptRequest(text: "after this", mode: .queue), images: [])
        try await host.sendPrompt(cardId: "card_a", RemotePromptRequest(text: "right now", mode: .now), images: [])
        let calls = fake.calls()
        #expect(calls.contains("ARGS session send 0a1b2c3d\nSTDIN after this"))
        #expect(calls.contains("ARGS session send 0a1b2c3d --now\nSTDIN right now"))
        #expect(tmux.escapes.isEmpty)
        #expect(tmux.sent.isEmpty)
        #expect(store.state.links["card_a"]?.queuedPrompts == nil)
        // The queue rush reports is the card's queue.
        #expect(store.state.rushQueues == ["rush-0a1b2c3d": ["after this"]])
        let card = await host.board().cards.first { $0.id == "card_a" }
        #expect(card?.queuedPrompts.map(\.text) == ["after this"])
        #expect(card?.queuedPromptCount == 1)
    }

    @Test("a rush card gets the text with its [Image #N] markers and the images as files")
    func rushImageMarkers() async throws {
        let fake = try FakeRush()
        defer { fake.cleanup() }
        let (host, store, _) = makeHost(rush: fake.adapter())
        addCard(store, id: "card_a", session: "rush-0a1b2c3d", live: true, busy: false)
        let jpeg = RemotePromptImages.Decoded(bytes: Data([0xFF, 0xD8, 0xFF, 0xE0]), fileExtension: "jpg")
        try await host.sendPrompt(cardId: "card_a", RemotePromptRequest(text: "what is [Image #1] showing"), images: [jpeg])
        let calls = fake.calls()
        #expect(calls.contains("STDIN what is [Image #1] showing"))
        #expect(calls.contains("--image "))
        #expect(!calls.contains("![]("))
    }

    @Test("send now and remove on a rush queued message map to rush's queue commands")
    func rushQueueActions() async throws {
        let fake = try FakeRush()
        defer { fake.cleanup() }
        let (host, store, _) = makeHost(rush: fake.adapter())
        addCard(store, id: "card_a", session: "rush-0a1b2c3d", live: true, busy: true)
        store.dispatch(.rushQueueRead(sessionName: "rush-0a1b2c3d", queue: ["one", "two"]))
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
        #expect(store.state.rushQueues.isEmpty)
    }

    @Test("interrupt sends Esc to the live session")
    func interrupt() async throws {
        let (host, store, tmux) = makeHost()
        addCard(store, id: "card_a", session: "card-a", live: true, busy: true)
        try await host.interrupt(cardId: "card_a")
        #expect(tmux.escapes == ["card-a"])
    }

    @Test("terminals: rush opens its own UI, tmux attaches, unknown sessions are refused")
    func terminals() async throws {
        let (host, store, _) = makeHost()
        addCard(store, id: "card_a", session: "rush-0123abcd", live: true, busy: false)
        addCard(store, id: "card_b", session: "card-b", live: true, busy: false)
        let rush = try await host.terminalCommand(cardId: "card_a", sessionName: "rush-0123abcd")
        #expect(rush == RushCliAdapter.openCommand(id: "0123abcd"))
        #expect(rush.contains("open") && rush.contains("0123abcd"))
        let tmux = try await host.terminalCommand(cardId: "card_b", sessionName: "card-b")
        #expect(Array(tmux.suffix(3)) == ["attach-session", "-t", "card-b"])
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
