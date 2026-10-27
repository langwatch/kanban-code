import Foundation
import KanbanCodeRemoteKit
import Testing

@testable import KanbanCodeCore

private final class SentTexts: TmuxManagerPort, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [String] = []
    var sent: [String] { lock.withLock { _sent } }
    private func record(_ text: String) { lock.withLock { _sent.append(text) } }

    func listSessions() async throws -> [TmuxSession] { [] }
    func createSession(name: String, path: String, command: String?) async throws {}
    func killSession(name: String) async throws {}
    func findSessionForWorktree(sessions: [TmuxSession], worktreePath: String, branch: String?) -> TmuxSession? { nil }
    func sendPrompt(to sessionName: String, text: String) async throws { record(text) }
    func pastePrompt(to sessionName: String, text: String) async throws { record(text) }
    func pasteText(to sessionName: String, text: String) async throws {}
    func submitPrompt(to sessionName: String) async throws {}
    func capturePane(sessionName: String) async throws -> String { "" }
    func sendBracketedPaste(to sessionName: String) async throws {}
    func isAvailable() async -> Bool { true }
}

@Suite("Conversations: log")
struct ConversationLogTests {
    private func log(_ events: [ConversationEvent]) -> Data {
        events.reduce(into: Data()) { $0.append($1.line()) }
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("the log folds into conversations, most recent first, with unread and waiting")
    func fold() {
        let data = log([
            .created("swift-otter", at: t0),
            .created("calm-heron", at: t0.addingTimeInterval(1)),
            .message("swift-otter", id: "m1", role: .human, text: "can we harden the vault?", at: t0.addingTimeInterval(2)),
            .message("swift-otter", id: "m2", role: .agent, text: "Yes.\nStarting with leases.", at: t0.addingTimeInterval(3)),
            .title("swift-otter", "Vault hardening", by: "agent", at: t0.addingTimeInterval(3)),
        ])
        let threads = ConversationLog.fold(data)
        #expect(threads.map(\.summary.id) == ["swift-otter", "calm-heron"])
        let otter = threads[0].summary
        #expect(otter.title == "Vault hardening")
        #expect(otter.messageCount == 2)
        #expect(otter.waiting)
        #expect(otter.unread)
        #expect(otter.replied)
        #expect(otter.preview == "Yes. Starting with leases.")
        #expect(threads[1].summary.displayTitle == "New conversation")
        #expect(!threads[1].summary.waiting)
    }

    @Test("a conversation continued from the user's message keeps the quote's role and reply")
    func humanQuoteFold() throws {
        let threads = ConversationLog.fold(log([
            .created("calm-heron", quote: "Use a 15 min lease.", at: t0, quoteRole: .human, quoteReply: "Done."),
            .created("swift-otter", at: t0.addingTimeInterval(1), quoteRole: .human, quoteReply: "ignored"),
        ]))
        let heron = try #require(threads.first { $0.summary.id == "calm-heron" }).summary
        #expect(heron.quotesHuman)
        #expect(heron.quoteReply == "Done.")
        let otter = try #require(threads.first { $0.summary.id == "swift-otter" }).summary
        #expect(otter.quoteRole == nil)
        let decoded = try JSONDecoder().decode(RemoteConversation.self, from: JSONEncoder().encode(heron))
        #expect(decoded.quoteRole == .human)
        #expect(decoded.quoteReply == "Done.")
    }

    @Test("a title the human gives wins over the agent's later titles until the human clears it")
    func humanTitleWins() {
        var events: [ConversationEvent] = [
            .created("swift-otter", title: "Agent plan", by: "agent", at: t0),
            .title("swift-otter", "My plan", by: "human", at: t0.addingTimeInterval(1)),
            .title("swift-otter", "Agent again", by: "agent", at: t0.addingTimeInterval(2)),
        ]
        #expect(ConversationLog.fold(log(events))[0].summary.title == "My plan")
        events.append(.title("swift-otter", "", by: "human", at: t0.addingTimeInterval(3)))
        events.append(.title("swift-otter", "Agent after clear", by: "agent", at: t0.addingTimeInterval(4)))
        #expect(ConversationLog.fold(log(events))[0].summary.title == "Agent after clear")
        let named = log([
            .created("calm-heron", title: "Named at start", at: t0),
            .title("calm-heron", "Agent", by: "agent", at: t0.addingTimeInterval(1)),
        ])
        #expect(ConversationLog.fold(named)[0].summary.title == "Named at start")
    }

    @Test("a conversation message's images are found on its prompt's line in the transcript")
    func imagesInTranscript() {
        func user(_ line: Int, _ text: String, images: Int) -> ConversationTurn {
            ConversationTurn(index: line, lineNumber: line, role: "user", textPreview: text,
                             contentBlocks: [.init(kind: .text, text: text)], imageCount: images)
        }
        let sent = ConversationPrompt.wrap("isn't it odd? [Image #1]\nsecond line", id: "smart-tiger", title: "Stop button")
        let turns = [
            user(10, ConversationPrompt.wrap("isn't it odd? [Image #1]\nsecond line", id: "cosy-koala", title: nil), images: 1),
            user(20, sent, images: 1),
            user(30, "isn't it odd? [Image #1]", images: 1),
        ]
        #expect(ConversationTranscriptImages.turn(for: "isn't it odd? [Image #1]\nsecond line", conversationId: "smart-tiger", in: turns)?.lineNumber == 20)
        #expect(ConversationTranscriptImages.turn(for: "isn't it odd? [Image #1]  second line", conversationId: "smart-tiger", in: turns)?.lineNumber == 20)
        #expect(ConversationTranscriptImages.turn(for: "something else", conversationId: "smart-tiger", in: turns) == nil)
        #expect(ConversationTranscriptImages.turn(for: "isn't it odd?", conversationId: "calm-heron", in: turns) == nil)
    }

    @Test("read clears unread but not waiting; a human answer clears waiting")
    func readAndWaiting() {
        var events: [ConversationEvent] = [
            .created("swift-otter", at: t0),
            .message("swift-otter", id: "m1", role: .agent, text: "Decide on the lease length", at: t0.addingTimeInterval(1)),
            .read("swift-otter", at: t0.addingTimeInterval(2)),
        ]
        var summary = ConversationLog.fold(log(events))[0].summary
        #expect(!summary.unread)
        #expect(summary.waiting)
        events.append(.message("swift-otter", id: "m2", role: .human, text: "1 hour", at: t0.addingTimeInterval(3)))
        summary = ConversationLog.fold(log(events))[0].summary
        #expect(!summary.waiting)
        #expect(summary.lastRole == .human)
    }

    @Test("an edited queued prompt replaces its text; a removed one leaves")
    func editAndRetract() {
        let threads = ConversationLog.fold(log([
            .created("swift-otter", at: t0),
            .message("swift-otter", id: "p1", role: .human, text: "first draft", at: t0),
            .message("swift-otter", id: "p2", role: .human, text: "second", at: t0.addingTimeInterval(1)),
            .message("swift-otter", id: "p1", role: .human, text: "edited", at: t0.addingTimeInterval(2)),
            .retracted("swift-otter", id: "p2", at: t0.addingTimeInterval(3)),
        ]))
        #expect(threads[0].messages.map(\.text) == ["edited"])
    }

    @Test("a line cut short is skipped and archived conversations are marked")
    func brokenLineAndArchive() {
        var data = log([.created("swift-otter", at: t0), .archived("swift-otter", true, at: t0)])
        data.append(Data("{\"type\":\"message\",\"conv\":\"swift".utf8))
        let threads = ConversationLog.fold(data)
        #expect(threads.count == 1)
        #expect(threads[0].summary.archived)
    }

    @Test("the CLI's log lines parse")
    func cliLines() {
        let text = """
        {"type":"created","conv":"brave-otter","at":"2026-10-26T10:00:00.000Z","by":"agent"}
        {"type":"message","conv":"brave-otter","id":"msg_1","role":"agent","text":"Which region?","at":"2026-10-26T10:00:01.000Z"}

        """
        let threads = ConversationLog.fold(Data(text.utf8))
        #expect(threads.first?.summary.waiting == true)
        #expect(threads.first?.messages.first?.text == "Which region?")
    }
}

@Suite("Conversations: prompt header")
struct ConversationPromptTests {
    @Test("an untitled conversation asks for a title")
    func untitled() {
        let wrapped = ConversationPrompt.wrap("can we harden the vault next?", id: "swift-otter", title: nil)
        #expect(wrapped == """
        [conversation swift-otter, new] can we harden the vault next?
        (reply with: kanban reply swift-otter --title "<3-6 word title>" "<answer>")
        """)
    }

    @Test("a titled conversation names its title")
    func titled() {
        let wrapped = ConversationPrompt.wrap("ok, do it", id: "swift-otter", title: "Vault hardening")
        #expect(wrapped == """
        [conversation swift-otter "Vault hardening"] ok, do it
        (reply with: kanban reply swift-otter "<answer>")
        """)
    }

    @Test("a pop-off quotes the start of the agent message until the agent replies")
    func quote() {
        var conversation = RemoteConversation(id: "calm-heron", createdAt: .now, quote: "The lease tiers are open, ask and his-only.")
        #expect(ConversationPrompt.wrap("more on this", conversation: conversation)
            .hasPrefix("[conversation calm-heron, new, continues your message \"The lease tiers are open, ask and his-only.\"] more on this"))
        conversation.replied = true
        #expect(!ConversationPrompt.wrap("more", conversation: conversation).contains("continues"))
    }

    @Test("continuing the user's own message names it, and the agent's reply when there is one")
    func humanQuote() {
        let withReply = ConversationPrompt.wrap("why?", id: "calm-heron", title: nil,
                                                quote: "Use a 15 min lease.", quoteRole: .human,
                                                quoteReply: "Done, the \"ask\" tier is set.")
        #expect(withReply.hasPrefix(
            "[conversation calm-heron, new, continues the user's message \"Use a 15 min lease.\" and your reply \"Done, the 'ask' tier is set.\"] why?"))
        #expect(ConversationPrompt.parse(withReply)?.text == "why?")
        let alone = ConversationPrompt.wrap("why?", id: "calm-heron", title: nil, quote: "Use a 15 min lease.", quoteRole: .human)
        #expect(alone.hasPrefix("[conversation calm-heron, new, continues the user's message \"Use a 15 min lease.\"] why?"))
    }

    @Test("a wrapped prompt parses back, and is never wrapped twice")
    func parse() {
        let wrapped = ConversationPrompt.wrap("line one\nline two", id: "swift-otter", title: "Vault [x] hardening")
        let parsed = ConversationPrompt.parse(wrapped)
        #expect(parsed?.id == "swift-otter")
        #expect(parsed?.title == "Vault [x] hardening")
        #expect(parsed?.text == "line one\nline two")
        #expect(ConversationPrompt.wrap(wrapped, id: "swift-otter", title: "Vault") == wrapped)
        #expect(ConversationPrompt.parse("plain prompt") == nil)
    }

    @Test("ids are two words and unique on the card")
    func slugs() {
        var seen: Set<String> = []
        for _ in 0..<300 {
            let slug = ConversationSlug.generate(existing: seen)
            #expect(ConversationSlug.isValid(slug))
            #expect(!seen.contains(slug))
            seen.insert(slug)
        }
    }
}

@Suite("Conversations: reducer")
struct ConversationReducerTests {
    private func state(conversations: [RemoteConversation] = []) -> AppState {
        let state = AppState()
        var link = Link(id: "card_1", name: "a card", projectPath: "/tmp/project")
        link.tmuxLink = TmuxLink(sessionName: "claude-abc")
        state.links[link.id] = link
        if !conversations.isEmpty { state.conversations["card_1"] = conversations }
        return state
    }

    @Test("a queued prompt of a conversation shows in it at once, as typed")
    func queuedShows() {
        var s = state()
        let prompt = QueuedPrompt(id: "p1", body: "hello", humanWrittenAt: .now, conversation: "swift-otter")
        let effects = Reducer.reduce(state: &s, action: .addQueuedPrompt(cardId: "card_1", prompt: prompt, placement: .back))
        let appended = effects.compactMap { effect -> [ConversationEvent]? in
            if case .appendConversationEvents(_, let events) = effect { return events }
            return nil
        }.flatMap { $0 }
        #expect(appended.count == 1)
        #expect(appended.first?.type == .message)
        #expect(appended.first?.text == "hello")
        #expect(appended.first?.id == "p1")
        #expect(s.links["card_1"]?.queuedPrompts?.first?.body == "hello")
    }

    @Test("a prompt of a conversation leaves with the header, journalled that way")
    func sendWraps() {
        var s = state(conversations: [RemoteConversation(id: "swift-otter", title: "Vault hardening", createdAt: .now)])
        let prompt = QueuedPrompt(id: "p1", body: "ok, do it", humanWrittenAt: .now, conversation: "swift-otter")
        _ = Reducer.reduce(state: &s, action: .addQueuedPrompt(cardId: "card_1", prompt: prompt, placement: .back))
        let effects = Reducer.reduce(state: &s, action: .sendQueuedPrompt(cardId: "card_1", promptId: "p1"))
        let expected = ConversationPrompt.wrap("ok, do it", id: "swift-otter", title: "Vault hardening")
        var sent: String?
        var journalled: String?
        for effect in effects {
            if case .sendPromptToTmux(_, let body, _, _) = effect { sent = body }
            if case .journalQueuedPrompt(_, let p, .sent) = effect { journalled = p.body }
        }
        #expect(sent == expected)
        #expect(journalled == expected)
    }

    @Test("removing a queued prompt of a conversation takes it out of the conversation")
    func removeRetracts() {
        var s = state()
        let prompt = QueuedPrompt(id: "p1", body: "never mind", conversation: "swift-otter")
        _ = Reducer.reduce(state: &s, action: .addQueuedPrompt(cardId: "card_1", prompt: prompt, placement: .back))
        let effects = Reducer.reduce(state: &s, action: .removeQueuedPrompt(cardId: "card_1", promptId: "p1"))
        let retracted = effects.contains { effect in
            if case .appendConversationEvents(_, let events) = effect { return events.contains { $0.type == .retracted && $0.id == "p1" } }
            return false
        }
        #expect(retracted)
    }

    @Test("a loaded log replaces the card's conversations; an empty one clears them")
    func loaded() {
        var s = state()
        let c = RemoteConversation(id: "swift-otter", createdAt: .now)
        _ = Reducer.reduce(state: &s, action: .conversationsLoaded(cardId: "card_1", conversations: [c]))
        #expect(s.conversations["card_1"] == [c])
        _ = Reducer.reduce(state: &s, action: .conversationsLoaded(cardId: "card_1", conversations: []))
        #expect(s.conversations["card_1"] == nil)
    }
}

@Suite("Conversations: remote host")
@MainActor
struct ConversationHostTests {
    private func makeHost() -> (MasterRemoteControlHost, MasterEngine, BoardStore, SentTexts, String) {
        let tmux = SentTexts()
        let dir = NSTemporaryDirectory() + "kanban-conversations-\(UUID().uuidString)"
        let store = BoardStore(
            effectHandler: EffectHandler(
                coordinationStore: CoordinationStore(basePath: dir),
                tmuxAdapter: tmux,
                queuedPromptJournal: QueuedPromptJournal(basePath: dir),
                humanMessageLog: HumanMessageLog(kanbanHome: dir),
                conversationStore: ConversationStore(kanbanHome: dir)
            ),
            discovery: ClaudeCodeSessionDiscovery(),
            coordinationStore: CoordinationStore(basePath: dir)
        )
        var platform = MasterPlatform()
        platform.kanbanHome = dir
        let engine = MasterEngine(
            store: store, settingsStore: SettingsStore(basePath: dir), launcher: LaunchSession(tmux: tmux),
            tmux: RoutingTmuxAdapter(rush: RushCliAdapter(executable: "/nonexistent/rush")),
            registry: CodingAssistantRegistry(), platform: platform)
        let host = MasterRemoteControlHost(engine: engine, rush: RushCliAdapter(executable: "/nonexistent/rush"),
                                           runTmux: { _, _ in }) { _ in }
        let link = Link(id: "card_a", name: "Card", projectPath: "/tmp/acme", column: .inProgress,
                        sessionLink: SessionLink(sessionId: "sid-a"), tmuxLink: TmuxLink(sessionName: "card-a"))
        store.dispatch(.createManualTask(link))
        store.dispatch(.tmuxLivenessScanned(live: ["card-a"]))
        return (host, engine, store, tmux, dir)
    }

    private func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<100 where !condition() { try? await Task.sleep(for: .milliseconds(20)) }
    }

    @Test("a sent message waits in the outbox until the log has it, a failed one leaves it, images are logged")
    func outboxAndImages() async throws {
        let (_, engine, store, _, dir) = makeHost()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let conv = try await engine.createConversation(cardId: "card_a", RemoteConversationCreate(), by: "human")
        let prompt = QueuedPrompt(body: "look [Image #1]", sendAutomatically: true, imagePaths: ["/tmp/acme/one.png"],
                                  humanWrittenAt: .now, conversation: conv.id)
        store.dispatch(.conversationMessageSent(cardId: "card_a", prompt: prompt))
        #expect(store.state.conversationOutbox["card_a"]?.map(\.id) == [prompt.id])

        store.dispatch(.addQueuedPrompt(cardId: "card_a", prompt: prompt, placement: .back))
        await waitFor { (store.state.conversations["card_a"]?.first?.messageCount ?? 0) > 0 }
        let logged = try #require(engine.conversationStore.threads(cardId: "card_a", ownerMachine: nil).first?.messages.first)
        #expect(logged.images == ["/tmp/acme/one.png"])
        #expect(ConversationOutbox.delivers(logged, prompt))
        store.dispatch(.conversationMessagesDelivered(cardId: "card_a", promptIds: [prompt.id]))
        #expect(store.state.conversationOutbox["card_a"] == nil)

        let lost = QueuedPrompt(body: "a long prompt", sendAutomatically: true, humanWrittenAt: .now, conversation: conv.id)
        store.dispatch(.conversationMessageSent(cardId: "card_a", prompt: lost))
        store.dispatch(.promptSendFailed(cardId: "card_a", prompt: lost, message: "peer offline"))
        #expect(store.state.conversationOutbox["card_a"] == nil)
        #expect(store.state.failedPrompts["card_a"]?.first?.prompt.conversation == conv.id)
    }

    @Test("a message logged by another master is the one sent here when the human's text matches and it is not older")
    func outboxMatchesForwardedMessages() {
        let written = Date(timeIntervalSince1970: 1_800_000_000)
        let prompt = QueuedPrompt(body: "ship it\n", sendAutomatically: true, humanWrittenAt: written, conversation: "swift-otter")
        #expect(ConversationOutbox.delivers(.init(id: "msg_owner", role: .human, text: "ship it", at: written.addingTimeInterval(2)), prompt))
        #expect(!ConversationOutbox.delivers(.init(id: "msg_owner", role: .agent, text: "ship it", at: written.addingTimeInterval(2)), prompt))
        #expect(!ConversationOutbox.delivers(.init(id: "msg_old", role: .human, text: "ship it", at: written.addingTimeInterval(-3600)), prompt))
        #expect(!ConversationOutbox.delivers(.init(id: "msg_other", role: .human, text: "hold it", at: written), prompt))
    }

    @Test("the sidebar highlights the card row with Main open, and only the conversation row with a conversation open")
    func oneHighlightedRow() async throws {
        let (_, _, store, _, dir) = makeHost()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        store.dispatch(.selectCard(cardId: "card_a"))
        #expect(store.state.highlightsCardRow("card_a"))
        store.dispatch(.openConversation(cardId: "card_a", conversationId: "swift-otter"))
        #expect(!store.state.highlightsCardRow("card_a"))
        store.dispatch(.openConversation(cardId: "card_a", conversationId: nil))
        #expect(store.state.highlightsCardRow("card_a"))
        #expect(!store.state.highlightsCardRow("card_b"))
    }

    @Test("a log on disk loads once its card reaches the board, even when the watcher saw it first")
    func watcherLoadsLogsOfCardsThatArriveLater() async throws {
        let (_, engine, store, _, dir) = makeHost()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try engine.conversationStore.append(cardId: "card_late", [.created("calm-heron", title: "Later", by: "human")])
        let watcher = Task { await engine.runConversationWatcher(interval: .milliseconds(20)) }
        defer { watcher.cancel() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.state.conversations["card_late"] == nil)

        store.dispatch(.createManualTask(Link(id: "card_late", name: "Late", projectPath: "/tmp/acme", column: .inProgress)))
        await waitFor { store.state.conversations["card_late"] != nil }
        #expect(store.state.conversations["card_late"]?.first?.title == "Later")
    }

    @Test("a conversation continued from the user's message sends a header naming it and the reply")
    func continuedFromHumanMessage() async throws {
        let (host, _, _, tmux, dir) = makeHost()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let created = try await host.createConversation(
            cardId: "card_a", RemoteConversationCreate(quote: "Use a 15 min lease.", quoteRole: .human, quoteReply: "  Done.  "))
        #expect(created.quotesHuman)
        #expect(created.quoteReply == "Done.")
        try await host.sendPrompt(cardId: "card_a", RemotePromptRequest(text: "why?", human: true, conversation: created.id), images: [])
        await waitFor { !tmux.sent.isEmpty }
        #expect(tmux.sent.first?.contains("continues the user's message \"Use a 15 min lease.\" and your reply \"Done.\"]") == true)
    }

    @Test("a rename through the API is the human's: the agent's later title does not replace it")
    func renameThroughApi() async throws {
        let (host, engine, _, _, dir) = makeHost()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let created = try await host.createConversation(cardId: "card_a", RemoteConversationCreate())
        let renamed = try await host.updateConversation(cardId: "card_a", conversationId: created.id, .init(title: "My plan"))
        #expect(renamed.title == "My plan")
        let logPath = engine.conversationStore.path(cardId: "card_a")
        let handle = try #require(FileHandle(forWritingAtPath: logPath))
        handle.seekToEndOfFile()
        handle.write(ConversationEvent.title(created.id, "Agent plan", by: "agent").line())
        try handle.close()
        let thread = try #require(engine.conversationStore.threads(cardId: "card_a", ownerMachine: nil).first)
        #expect(thread.summary.title == "My plan")
    }

    @Test("a message's image is served from the path the log keeps, and only that path")
    func imageOfAMessage() async throws {
        let (host, engine, store, _, dir) = makeHost()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let image = (dir as NSString).appendingPathComponent("shot.png")
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        try bytes.write(to: URL(fileURLWithPath: image))
        let conv = try await engine.createConversation(cardId: "card_a", RemoteConversationCreate(), by: "human")
        let prompt = QueuedPrompt(body: "look [Image #1]", sendAutomatically: true, imagePaths: [image],
                                  humanWrittenAt: .now, conversation: conv.id)
        store.dispatch(.addQueuedPrompt(cardId: "card_a", prompt: prompt, placement: .back))
        await waitFor { (store.state.conversations["card_a"]?.first?.messageCount ?? 0) > 0 }
        let message = try #require(engine.conversationStore.threads(cardId: "card_a", ownerMachine: nil).first?.messages.first)
        #expect(try await host.conversationImage(cardId: "card_a", conversationId: conv.id, messageId: message.id, index: 0) == bytes)
        await #expect(throws: RemoteHostError.self) {
            _ = try await host.conversationImage(cardId: "card_a", conversationId: conv.id, messageId: message.id, index: 1)
        }
        await #expect(throws: RemoteHostError.self) {
            _ = try await host.conversationImage(cardId: "card_a", conversationId: conv.id, messageId: "msg_other", index: 0)
        }
        #expect(RemotePromptImages.mimeType(of: bytes) == "image/png")
        #expect(RemotePromptImages.mimeType(of: Data([0xFF, 0xD8, 0xFF, 0xE0])) == "image/jpeg")
    }

    @Test("start a conversation, send in it, the agent replies through the log, the human reads it")
    func roundTrip() async throws {
        let (host, engine, store, tmux, dir) = makeHost()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let created = try await host.createConversation(cardId: "card_a", RemoteConversationCreate())
        #expect(ConversationSlug.isValid(created.id))
        #expect(created.title == nil)

        try await host.sendPrompt(cardId: "card_a", RemotePromptRequest(text: "can we harden the vault?", human: true,
                                                                       conversation: created.id), images: [])
        await waitFor { !tmux.sent.isEmpty }
        #expect(tmux.sent == [ConversationPrompt.wrap("can we harden the vault?", id: created.id, title: nil)])
        await waitFor { store.state.conversations["card_a"]?.first?.messageCount == 1 }

        // The agent answers with the CLI: a line appended to the same log.
        let logPath = engine.conversationStore.path(cardId: "card_a")
        let reply = ConversationEvent.message(created.id, id: "msg_r", role: .agent, text: "Yes, starting with leases.")
        let title = ConversationEvent.title(created.id, "Vault hardening", by: "agent")
        let handle = try #require(FileHandle(forWritingAtPath: logPath))
        try handle.seekToEnd()
        try handle.write(contentsOf: title.line() + reply.line())
        try handle.close()
        engine.reloadConversations(cardId: "card_a")

        let summary = try #require(store.state.conversations["card_a"]?.first)
        #expect(summary.title == "Vault hardening")
        #expect(summary.waiting)
        #expect(summary.unread)
        let board = await host.board()
        #expect(board.cards.first { $0.id == "card_a" }?.conversations.first?.waiting == true)

        let detail = try await host.conversation(cardId: "card_a", conversationId: created.id)
        #expect(detail.messages.map(\.role) == [.human, .agent])
        #expect(detail.messages.first?.text == "can we harden the vault?")

        let read = try await host.updateConversation(cardId: "card_a", conversationId: created.id,
                                                     RemoteConversationUpdate(read: true))
        #expect(!read.unread)
        #expect(read.waiting)

        // The next prompt carries the title the agent set.
        try await host.sendPrompt(cardId: "card_a", RemotePromptRequest(text: "go", conversation: created.id), images: [])
        await waitFor { tmux.sent.count == 2 }
        #expect(tmux.sent.last == ConversationPrompt.wrap("go", id: created.id, title: "Vault hardening"))
    }

    @Test("a prompt for a conversation the card does not have is refused")
    func unknownConversation() async {
        let (host, _, _, tmux, dir) = makeHost()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        await #expect(throws: RemoteHostError.self) {
            try await host.sendPrompt(cardId: "card_a", RemotePromptRequest(text: "hi", conversation: "no-such"), images: [])
        }
        #expect(tmux.sent.isEmpty)
    }

    @Test("the raw log serves from an offset, for the mirror")
    func raw() async throws {
        let (host, _, _, _, dir) = makeHost()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        _ = try await host.createConversation(cardId: "card_a", RemoteConversationCreate(title: "One"))
        let whole = try await host.rawConversations(cardId: "card_a", offset: 0)
        #expect(whole.size == whole.data.count)
        let tail = try await host.rawConversations(cardId: "card_a", offset: whole.size)
        #expect(tail.data.isEmpty)
        #expect(ConversationLog.fold(whole.data).first?.summary.title == "One")
    }
}

/// A paste that takes a while, recording whether two ran at once.
private final class SlowPaste: TmuxManagerPort, @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var _overlapped = false
    private var _order: [String] = []

    var overlapped: Bool { lock.lock(); defer { lock.unlock() }; return _overlapped }
    var order: [String] { lock.lock(); defer { lock.unlock() }; return _order }

    private func begin(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        active += 1
        if active > 1 { _overlapped = true }
        _order.append(text)
    }

    private func end() {
        lock.lock(); defer { lock.unlock() }
        active -= 1
    }

    private func slow(_ text: String) async {
        begin(text)
        try? await Task.sleep(for: .milliseconds(80))
        end()
    }

    func listSessions() async throws -> [TmuxSession] { [] }
    func createSession(name: String, path: String, command: String?) async throws {}
    func killSession(name: String) async throws {}
    func findSessionForWorktree(sessions: [TmuxSession], worktreePath: String, branch: String?) -> TmuxSession? { nil }
    func sendPrompt(to sessionName: String, text: String) async throws { await slow(text) }
    func pastePrompt(to sessionName: String, text: String) async throws { await slow(text) }
    func pasteText(to sessionName: String, text: String) async throws {}
    func submitPrompt(to sessionName: String) async throws {}
    func capturePane(sessionName: String) async throws -> String { "" }
    func sendBracketedPaste(to sessionName: String) async throws {}
    func isAvailable() async -> Bool { true }
}

@Suite("Prompts to one session")
struct OnePromptAtATimeTests {
    @Test("Prompts sent at once to a session are pasted one after the other, in order")
    func serialPerSession() async {
        let tmux = SlowPaste()
        let handler = EffectHandler(
            coordinationStore: CoordinationStore(basePath: NSTemporaryDirectory() + "kanban-serial-\(UUID().uuidString)"),
            tmuxAdapter: tmux
        )
        await withTaskGroup(of: Void.self) { group in
            for text in ["first", "second", "third"] {
                group.addTask {
                    await handler.execute(.sendPromptToTmux(sessionName: "claude-1", promptBody: text, assistant: .claude),
                                          dispatch: { _ in })
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        #expect(!tmux.overlapped)
        #expect(tmux.order == ["first", "second", "third"])
    }
}
