import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import KanbanCodeRemoteKit
import Synchronization

@testable import KanbanCodeCore

/// A host over an in-memory board for the remote control server tests.
final class FakeRemoteHost: RemoteControlHost {
    struct State {
        var cards: [RemoteCard]
        var prompts: [(cardId: String, request: RemotePromptRequest)] = []
        var interrupts: [String] = []
        var tasks: [RemoteTaskRequest] = []
        var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]
        var terminalCommand: [String] = ["/bin/sh", "-c", "printf ready; cat"]
        var terminalRequests: [(cardId: String, session: String)] = []
        var promptImages: [[RemotePromptImages.Decoded]] = []
        var queueSends: [String] = []
        var scrolls: [(session: String, lines: Int)] = []
        var attention: [AttentionRequest] = []
        var resolutions: [(id: String, resolution: String, by: String)] = []
        var presences: [MacPresence] = []
        var sideChats: [String: RemoteSideChatRun] = [:]
        var sideChatRequests: [RemoteSideChatRequest] = []
        var sideChatCancels: [String] = []
        var pastedImages: [(cardId: String, bytes: Data)] = []
    }

    func storePastedImage(cardId: String, image: Data) async throws -> RemotePastedImage {
        _ = try card(cardId)
        guard RemotePromptImages.fileExtension(of: image) != nil else {
            throw RemoteHostError.badRequest("the image is not PNG, JPEG, GIF or WebP")
        }
        return state.withLock { s in
            s.pastedImages.append((cardId, image))
            return RemotePastedImage(path: "/owner/images/pasted/\(s.pastedImages.count).png")
        }
    }

    func startSideChat(cardId: String, _ request: RemoteSideChatRequest) async throws -> RemoteSideChatRun {
        _ = try card(cardId)
        return state.withLock { s in
            s.sideChatRequests.append(request)
            let run = RemoteSideChatRun(id: "side_\(s.sideChatRequests.count)", cardId: cardId, kind: request.kind)
            s.sideChats[run.id] = run
            return run
        }
    }

    func sideChatRun(cardId: String, runId: String) async throws -> RemoteSideChatRun {
        guard var run = state.withLock({ $0.sideChats[runId] }), run.cardId == cardId else {
            throw RemoteHostError.notFound("no side chat run \(runId)")
        }
        run.state = .done
        run.text = "The answer"
        return run
    }

    func cancelSideChat(cardId: String, runId: String) async throws {
        state.withLock { $0.sideChatCancels.append(runId) }
    }

    func slashCommands(cardId: String) async throws -> [RemoteSlashCommand] {
        _ = try card(cardId)
        return SlashCommandCatalog.merged(assistant: .claude, sideChat: true, disk: [
            RemoteSlashCommand(name: "deploy", description: "Ship it", source: RemoteSlashCommand.Source.user),
        ])
    }

    let state: Mutex<State>

    init(cards: [RemoteCard] = FakeRemoteHost.defaultCards) {
        state = Mutex(State(cards: cards))
    }

    static let defaultCards: [RemoteCard] = [
        RemoteCard(
            id: "card_live", title: "Fix the flaky test", column: .inProgress, projectPath: "/tmp/acme", projectName: "acme",
            runtime: .tmux, isLive: true, isBusy: true, sessionId: "s1",
            terminals: [RemoteTerminal(sessionName: "acme-card_live", label: "claude", isPrimary: true)],
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        ),
        RemoteCard(id: "card_idle", title: "Ended", column: .waiting, runtime: .none, updatedAt: Date(timeIntervalSince1970: 1_800_000_000)),
    ]

    func attention() async -> [AttentionRequest] {
        state.withLock { $0.attention }
    }

    func resolveAttention(id: String, resolution: String, by: String, unsealed: VaultUnsealed?) async throws {
        let conts = try state.withLock { s -> [AsyncStream<Void>.Continuation] in
            guard s.attention.contains(where: { $0.id == id }) else { throw RemoteHostError.notFound("no attention request \(id)") }
            s.attention.removeAll { $0.id == id }
            s.resolutions.append((id, resolution, by))
            return Array(s.continuations.values)
        }
        conts.forEach { $0.yield() }
    }

    func reportPresence(_ presence: MacPresence) async {
        state.withLock { $0.presences.append(presence) }
    }

    /// Raises a request and wakes the event streams.
    func raise(_ request: AttentionRequest) {
        let conts = state.withLock { s in
            s.attention.append(request)
            return Array(s.continuations.values)
        }
        conts.forEach { $0.yield() }
    }

    func setTerminalCommand(_ argv: [String]) {
        state.withLock { $0.terminalCommand = argv }
    }

    func mutate(_ change: (inout [RemoteCard]) -> Void) {
        let conts = state.withLock { s in
            change(&s.cards)
            return Array(s.continuations.values)
        }
        conts.forEach { $0.yield() }
    }

    func board() async -> RemoteBoard {
        state.withLock { s in
            RemoteBoard(cards: s.cards, projects: [RemoteProject(path: "/tmp/acme", name: "acme")], generatedAt: Date())
        }
    }

    private func card(_ id: String) throws -> RemoteCard {
        guard let card = state.withLock({ $0.cards.first { $0.id == id } }) else {
            throw RemoteHostError.notFound("no card \(id)")
        }
        return card
    }

    func transcript(cardId: String, limit: Int, before: String?) async throws -> RemoteTranscript {
        _ = try card(cardId)
        let all = (0..<10).map { RemoteMessage(id: "m\($0)", role: $0 % 2 == 0 ? .user : .assistant, text: "message \($0)") }
        let end = before.flatMap(Int.init) ?? all.count
        let start = max(0, end - limit)
        return RemoteTranscript(cardId: cardId, messages: Array(all[start..<end]), olderCursor: start > 0 ? String(start) : nil)
    }

    func machines() async -> [RemoteMachineEntry] {
        [
            RemoteMachineEntry(id: "machine_box", name: "rchaves-platform", kind: .this, online: true, alwaysOn: true),
            RemoteMachineEntry(id: "machine_mac", name: "studio", kind: .master, online: false),
        ]
    }

    func createTask(_ request: RemoteTaskRequest) async throws -> RemoteCard {
        guard request.project == "acme" || request.project == "/tmp/acme" else {
            throw RemoteHostError.badRequest("unknown project \(request.project); known: acme")
        }
        let card = RemoteCard(
            id: "card_new_\(UUID().uuidString.prefix(6))", title: request.name ?? request.prompt, column: .inProgress,
            projectPath: "/tmp/acme", projectName: "acme", runtime: .tmux, isLive: true, updatedAt: Date()
        )
        state.withLock { $0.tasks.append(request) }
        mutate { $0.append(card) }
        return card
    }

    func sendPrompt(cardId: String, _ request: RemotePromptRequest, images: [RemotePromptImages.Decoded]) async throws {
        let card = try card(cardId)
        guard card.isLive else { throw RemoteHostError.conflict("card \(cardId) has no live session") }
        state.withLock {
            $0.prompts.append((cardId, request))
            $0.promptImages.append(images)
        }
    }

    func sendQueuedPromptNow(cardId: String, promptId: String) async throws {
        try takeQueued(cardId, promptId)
        state.withLock { $0.queueSends.append(promptId) }
    }

    func removeQueuedPrompt(cardId: String, promptId: String) async throws {
        try takeQueued(cardId, promptId)
    }

    private func takeQueued(_ cardId: String, _ promptId: String) throws {
        guard try card(cardId).queuedPrompts.contains(where: { $0.id == promptId }) else {
            throw RemoteHostError.notFound("card \(cardId) has no queued prompt \(promptId)")
        }
        mutate { cards in
            guard let i = cards.firstIndex(where: { $0.id == cardId }) else { return }
            cards[i].queuedPrompts.removeAll { $0.id == promptId }
            cards[i].queuedPromptCount = cards[i].queuedPrompts.count
        }
    }

    func scrollTerminal(sessionName: String, lines: Int) async {
        state.withLock { $0.scrolls.append((sessionName, lines)) }
    }

    func interrupt(cardId: String) async throws {
        _ = try card(cardId)
        state.withLock { $0.interrupts.append(cardId) }
    }

    func resume(cardId: String) async throws -> RemoteCard {
        _ = try card(cardId)
        mutate { cards in
            if let i = cards.firstIndex(where: { $0.id == cardId }) { cards[i].isLive = true }
        }
        return try card(cardId)
    }

    func terminalCommand(cardId: String, sessionName: String) async throws -> [String] {
        _ = try card(cardId)
        return state.withLock { s in
            s.terminalRequests.append((cardId, sessionName))
            return s.terminalCommand
        }
    }

    func boardChanges() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, cont) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        cont.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.continuations.removeValue(forKey: id) }
        }
        state.withLock { $0.continuations[id] = cont }
        return stream
    }
}

struct TimeoutError: Error {}

func withTimeout<T: Sendable>(_ seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw TimeoutError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

/// A running server on an ephemeral loopback port with its own devices file.
final class RemoteServerFixture: Sendable {
    let host: FakeRemoteHost
    let devices: RemoteDeviceStore
    let server: RemoteControlServer
    let dir: String
    let fullToken: String
    let agentToken: String
    let fullDevice: RemoteDevice
    let session: URLSession

    init(host: FakeRemoteHost = FakeRemoteHost(), vault: VaultService? = nil) async throws {
        dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("remote-control-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        self.host = host
        devices = RemoteDeviceStore(path: dir + "/devices.json")
        let full = try devices.add(name: "iPhone", scope: .full)
        let agent = try devices.add(name: "openclaw", scope: .agent)
        fullToken = full.token
        fullDevice = full.0
        agentToken = agent.token
        server = RemoteControlServer(
            host: host, devices: devices, port: 0, bindAddresses: { [RemoteNetworkAddresses.loopback] },
            options: .init(pingInterval: 0.4, pushInterval: 0.2, watchInterval: 0.1, appVersion: "test", hostName: "test-mac"),
            vault: vault
        )
        try await server.start()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        session = URLSession(configuration: config)
    }

    func shutdown() {
        server.stop()
        session.invalidateAndCancel()
        try? FileManager.default.removeItem(atPath: dir)
    }

    var base: String { "http://127.0.0.1:\(server.port)" }

    func request(_ method: String, _ path: String, token: String? = nil, body: Data? = nil) async throws -> (Int, Data) {
        var req = URLRequest(url: URL(string: base + path)!)
        req.httpMethod = method
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: req)
        return ((response as! HTTPURLResponse).statusCode, data)
    }

    func webSocket(_ path: String, token: String?) -> TestWebSocket {
        #if canImport(FoundationNetworking)
        return RawTestWebSocket(port: server.port, path: path, token: token)
        #else
        var req = URLRequest(url: URL(string: "ws://127.0.0.1:\(server.port)" + path)!)
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let task = session.webSocketTask(with: req)
        task.resume()
        return task
        #endif
    }
}

#if canImport(FoundationNetworking)
typealias TestWebSocket = RawTestWebSocket
#else
typealias TestWebSocket = URLSessionWebSocketTask
extension URLSessionWebSocketTask: @retroactive @unchecked Sendable {}
#endif

func decodeEvent(_ message: TestWebSocket.Message) throws -> RemoteEvent {
    switch message {
    case .string(let s): return try JSONDecoder.remote.decode(RemoteEvent.self, from: Data(s.utf8))
    case .data(let d): return try JSONDecoder.remote.decode(RemoteEvent.self, from: d)
    @unknown default: throw TimeoutError()
    }
}
