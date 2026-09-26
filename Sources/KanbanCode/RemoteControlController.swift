import Foundation
import KanbanCodeCore
import KanbanCodeRemoteKit
import Observation

/// What a remote `POST /v1/tasks` asks the board window to create and launch.
struct RemoteLaunchRequest: Sendable {
    var projectPath: String
    var prompt: String
    var title: String?
    /// A worktree name, "" for a random one, nil for the project checkout.
    var worktree: String?
    var assistant: CodingAssistant
    var model: String?
    var launch: Bool
    /// Image files for the first prompt, already written.
    var imagePaths: [String] = []
}

/// Runs the remote control server of Settings > Remote Control and holds
/// the paired devices. The server itself runs off the main actor; this
/// controller only starts, stops and reports on it.
@MainActor
@Observable
final class RemoteControlController {
    static let shared = RemoteControlController()

    private(set) var isRunning = false
    private(set) var port = RemoteAPI.defaultPort
    private(set) var addresses: [String] = []
    private(set) var lastError: String?
    /// The Mac's Tailscale MagicDNS name, e.g. `mac.tailnet.ts.net`.
    private(set) var magicDNSName: String?
    private(set) var devices: [RemoteDevice] = []

    @ObservationIgnored let deviceStore = RemoteDeviceStore()
    @ObservationIgnored private var server: RemoteControlServer?
    @ObservationIgnored private var host: AppRemoteControlHost?
    @ObservationIgnored private var applied: RemoteControlSettings?
    @ObservationIgnored private weak var store: BoardStore?
    @ObservationIgnored private var tmux: RoutingTmuxAdapter?
    @ObservationIgnored private var settingsObserver: NSObjectProtocol?

    /// Set by the board window: creating and resuming cards runs the same
    /// launch flow as the New Task dialog and the resume button.
    @ObservationIgnored var launchTask: (@MainActor (RemoteLaunchRequest) -> String)?
    @ObservationIgnored var resumeCard: (@MainActor (String) -> Void)?

    private init() {}

    /// Wires the controller to the app's store and starts following the
    /// settings. Called once by the composition root.
    func attach(store: BoardStore, tmux: RoutingTmuxAdapter, settingsStore: SettingsStore) {
        self.store = store
        self.tmux = tmux
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .kanbanCodeSettingsChanged, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in await RemoteControlController.shared.reload(settingsStore: settingsStore) }
        }
        Task { await reload(settingsStore: settingsStore) }
    }

    func reload(settingsStore: SettingsStore) async {
        let settings = (try? await settingsStore.read())?.remoteControl ?? RemoteControlSettings()
        await apply(settings)
    }

    func apply(_ settings: RemoteControlSettings) async {
        guard settings != applied || (settings.enabled && server == nil) else {
            refreshStatus()
            return
        }
        applied = settings
        stopServer()
        port = settings.port
        guard settings.enabled else {
            refreshStatus()
            return
        }
        guard let store, let tmux else { return }
        let host = AppRemoteControlHost(store: store) { session in
            try await tmux.sendEscape(sessionName: session)
        }
        let server = RemoteControlServer(host: host, devices: deviceStore, port: settings.port)
        do {
            try await server.start()
            self.host = host
            self.server = server
            lastError = nil
        } catch {
            server.stop()
            lastError = "\(error)"
            KanbanCodeLog.warn("remote", "remote control did not start: \(error)")
        }
        refreshStatus()
        await refreshMagicDNSName()
    }

    private func stopServer() {
        server?.stop()
        server = nil
        host = nil
    }

    func refreshStatus() {
        isRunning = server?.isRunning ?? false
        addresses = server?.listeningAddresses ?? []
        if let server { port = server.port }
        devices = deviceStore.list().sorted { $0.createdAt > $1.createdAt }
    }

    func refreshMagicDNSName() async {
        magicDNSName = await Self.tailscaleDNSName()
    }

    // MARK: - Devices

    func addDevice(name: String, scope: RemoteScope) throws -> (device: RemoteDevice, token: String) {
        let (device, token) = try deviceStore.add(name: name, scope: scope)
        refreshStatus()
        return (device, token)
    }

    func revoke(deviceId: String) {
        _ = try? deviceStore.revoke(id: deviceId)
        server?.closeConnections(deviceId: deviceId)
        refreshStatus()
    }

    /// The URL a device on the tailnet reaches the server at.
    var baseURL: String {
        if let magicDNSName { return "http://\(magicDNSName):\(port)" }
        if let ip = addresses.first(where: { $0 != RemoteNetworkAddresses.loopback && !$0.contains(":") }) {
            return "http://\(ip):\(port)"
        }
        return "http://127.0.0.1:\(port)"
    }

    func pairLink(token: String) -> String {
        RemotePairLink.make(url: baseURL, token: token, name: RemoteControlServer.defaultHostName)
    }

    /// `Self.DNSName` of `tailscale status --json`, without the final dot.
    nonisolated static func tailscaleDNSName() async -> String? {
        let candidates = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale"]
        guard let tailscale = ShellCommand.findExecutable("tailscale")
                ?? candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        guard let result = try? await ShellCommand.run(tailscale, arguments: ["status", "--json"], timeout: 5),
              result.exitCode == 0,
              let json = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
              let me = json["Self"] as? [String: Any],
              let name = me["DNSName"] as? String, !name.isEmpty else { return nil }
        return name.hasSuffix(".") ? String(name.dropLast()) : name
    }
}

/// The app side of the remote control API: reads the board from the store
/// and acts through the same actions and launch flow as the UI.
final class AppRemoteControlHost: RemoteControlHost, @unchecked Sendable {
    private let store: BoardStore
    /// Esc to a session, as the stop button does (agtop: its interrupt).
    private let sendEscape: @Sendable (String) async throws -> Void
    /// Runs tmux commands on the server that holds the session.
    private let runTmux: @Sendable ([[String]], String) async -> Void
    /// agtop cards queue and send through agtop itself.
    private let agtop: AgtopCliAdapter
    private let queueWatch = QueueWatchFlag()

    init(store: BoardStore,
         agtop: AgtopCliAdapter = AppServices.tmux.agtop,
         runTmux: @escaping @Sendable ([[String]], String) async -> Void = AppRemoteControlHost.runTmux(_:session:),
         sendEscape: @escaping @Sendable (String) async throws -> Void) {
        self.store = store
        self.agtop = agtop
        self.runTmux = runTmux
        self.sendEscape = sendEscape
    }

    /// The session's own tmux server: local, or the machine it runs on.
    static func runTmux(_ commands: [[String]], session: String) async {
        guard let adapter = try? AppServices.tmux.adapter(for: session) else { return }
        for command in commands {
            _ = try? await adapter.run(command)
        }
    }

    func board() async -> RemoteBoard {
        let board = await MainActor.run {
            RemoteBoardMapper.board(
                cards: store.state.cards,
                projects: store.state.configuredProjects,
                liveSessions: store.state.tmuxSessions,
                agtopQueues: store.state.agtopQueues
            )
        }
        await watchAgtopQueues()
        return board
    }

    @MainActor
    private func card(_ cardId: String) throws -> KanbanCodeCard {
        guard let card = store.state.cards.first(where: { $0.id == cardId }) else {
            throw RemoteHostError.notFound("no card \(cardId)")
        }
        return card
    }

    @MainActor
    private func remoteCard(_ cardId: String) throws -> RemoteCard {
        RemoteBoardMapper.card(try card(cardId), liveSessions: store.state.tmuxSessions, agtopQueues: store.state.agtopQueues)
    }

    func transcript(cardId: String, limit: Int, before: String?) async throws -> RemoteTranscript {
        let (path, assistant) = try await MainActor.run { () throws -> (String?, CodingAssistant) in
            let card = try card(cardId)
            return (card.link.sessionLink?.sessionPath ?? card.session?.jsonlPath, card.link.effectiveAssistant)
        }
        guard let path, FileManager.default.fileExists(atPath: path) else {
            return RemoteTranscript(cardId: cardId, messages: [])
        }
        return try await RemoteTranscriptMapper.page(cardId: cardId, limit: limit, before: before) { maxTurns in
            switch assistant {
            case .claude:
                let r = try await TranscriptReader.readTail(from: path, maxTurns: maxTurns)
                return (r.turns, r.hasMore)
            case .codex:
                let r = try await CodexSessionParser.readTail(from: path, maxTurns: maxTurns)
                return (r.turns, r.hasMore)
            default:
                let all = try await GeminiSessionStore().readTranscript(sessionPath: path)
                return (Array(all.suffix(maxTurns)), all.count > maxTurns)
            }
        }
    }

    func createTask(_ request: RemoteTaskRequest) async throws -> RemoteCard {
        let launch = try await MainActor.run { () throws -> RemoteLaunchRequest in
            let projects = store.state.configuredProjects
            guard let project = RemoteBoardMapper.resolveProject(request.project, in: projects) else {
                let names = projects.map(\.name).sorted().joined(separator: ", ")
                throw RemoteHostError.badRequest("unknown project \(request.project); known: \(names)")
            }
            let assistant: CodingAssistant
            if let raw = request.assistant {
                guard let parsed = CodingAssistant(rawValue: raw.lowercased()) else {
                    throw RemoteHostError.badRequest("unknown assistant \(raw); use claude, codex or gemini")
                }
                assistant = parsed
            } else {
                // The assistant the New Task dialog last used.
                let last = UserDefaults.standard.string(forKey: "selectedAssistant").flatMap(CodingAssistant.init(rawValue:))
                assistant = last.flatMap { ContentView.loadEnabledAssistants().contains($0) ? $0 : nil } ?? .claude
            }
            let title = request.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let imagePaths = try RemotePromptImages.write(
                RemotePromptImages.decode(request.images), to: RemotePromptImages.taskDirectory, prefix: "remote")
            return RemoteLaunchRequest(
                projectPath: project.path,
                prompt: request.prompt,
                title: title?.isEmpty == false ? title : nil,
                worktree: request.worktree,
                assistant: assistant,
                model: request.model,
                launch: request.launch ?? true,
                imagePaths: imagePaths
            )
        }
        let cardId = try await MainActor.run { () throws -> String in
            guard let handler = RemoteControlController.shared.launchTask else {
                throw RemoteHostError.conflict("Kanban Code has no board window open to launch the task")
            }
            return handler(launch)
        }
        for _ in 0..<30 {
            if let card = try? await MainActor.run(body: { try remoteCard(cardId) }) { return card }
            try? await Task.sleep(for: .milliseconds(100))
        }
        throw RemoteHostError.notFound("card \(cardId) was created but is not on the board yet")
    }

    /// The card's live session and whether a turn runs in it.
    @MainActor
    private func liveSession(_ cardId: String) throws -> (session: String, busy: Bool) {
        let card = try card(cardId)
        guard let session = RemoteBoardMapper.liveAssistantSession(card.link, liveSessions: store.state.tmuxSessions) else {
            throw RemoteHostError.conflict("card \(cardId) has no live session; resume it first")
        }
        return (session, card.activityState == .activelyWorking)
    }

    /// Stops the running turn so a prompt can go out now.
    private func interruptForPrompt(session: String) async throws {
        try await sendEscape(session)
        // The composer takes input again once the turn has stopped.
        try? await Task.sleep(for: .milliseconds(600))
    }

    func sendPrompt(cardId: String, _ request: RemotePromptRequest, images: [RemotePromptImages.Decoded]) async throws {
        let (session, busy) = try await MainActor.run { try liveSession(cardId) }
        let imagePaths = try RemotePromptImages.write(images, to: RemotePromptImages.promptDirectory)
        let mode = request.mode ?? .queue
        if let agtopId = AgtopSessionName.agtopId(fromName: session) {
            // agtop queues a message sent mid-turn itself, and `now` hands it
            // to Claude mid-turn; the card's own queue is not used.
            let text = PromptImageLayout.replacingMarkersWithMarkdown(in: request.text, imagePaths: imagePaths)
            try await agtop.send(id: agtopId, text: text, imagePaths: imagePaths, now: mode == .now)
            await readAgtopQueue(session: session, agtopId: agtopId)
            return
        }
        if mode == .now && busy {
            try await interruptForPrompt(session: session)
        }
        await MainActor.run {
            let prompt = QueuedPrompt(body: request.text, sendAutomatically: true,
                                      imagePaths: imagePaths.isEmpty ? nil : imagePaths)
            store.dispatch(.addQueuedPrompt(cardId: cardId, prompt: prompt, placement: .back))
            // A queued prompt on a busy card goes out when the turn ends; the
            // rest goes out now, as the chat's send button does.
            if mode == .now || !busy {
                store.dispatch(.sendQueuedPrompt(cardId: cardId, promptId: prompt.id))
            }
        }
    }

    func sendQueuedPromptNow(cardId: String, promptId: String) async throws {
        if promptId.hasPrefix("agtop-") {
            try await agtopQueueAction(cardId: cardId, promptId: promptId, send: true)
            return
        }
        let (session, busy) = try await MainActor.run { () throws -> (String, Bool) in
            try queuedPrompt(cardId, promptId)
            return try liveSession(cardId)
        }
        if busy { try await interruptForPrompt(session: session) }
        await MainActor.run {
            // Once the turn stops the queue may send it on its own.
            guard (try? queuedPrompt(cardId, promptId)) != nil else { return }
            store.dispatch(.sendQueuedPrompt(cardId: cardId, promptId: promptId))
        }
    }

    func removeQueuedPrompt(cardId: String, promptId: String) async throws {
        if promptId.hasPrefix("agtop-") {
            try await agtopQueueAction(cardId: cardId, promptId: promptId, send: false)
            return
        }
        try await MainActor.run {
            try queuedPrompt(cardId, promptId)
            store.dispatch(.removeQueuedPrompt(cardId: cardId, promptId: promptId))
        }
    }

    @MainActor
    @discardableResult
    private func queuedPrompt(_ cardId: String, _ promptId: String) throws -> QueuedPrompt {
        guard let prompt = try card(cardId).link.queuedPrompts?.first(where: { $0.id == promptId }) else {
            throw RemoteHostError.notFound("card \(cardId) has no queued prompt \(promptId); it may have been sent already")
        }
        return prompt
    }

    // MARK: agtop queue

    /// Sends now, or drops, a message queued in the card's agtop host.
    private func agtopQueueAction(cardId: String, promptId: String, send: Bool) async throws {
        let (session, queue) = try await MainActor.run { () throws -> (String, [String]) in
            let (session, _) = try liveSession(cardId)
            return (session, store.state.agtopQueues[session] ?? [])
        }
        guard let agtopId = AgtopSessionName.agtopId(fromName: session) else {
            throw RemoteHostError.notFound("card \(cardId) has no queued prompt \(promptId)")
        }
        // The queue as the phone saw it may be older than agtop's.
        var current = queue
        if RemoteBoardMapper.agtopQueueIndex(of: promptId, in: current) == nil,
           let info = try? await agtop.info(id: agtopId) {
            current = info.queue
        }
        guard let index = RemoteBoardMapper.agtopQueueIndex(of: promptId, in: current) else {
            await readAgtopQueue(session: session, agtopId: agtopId)
            throw RemoteHostError.notFound("card \(cardId) has no queued prompt \(promptId); it may have been sent already")
        }
        do {
            if send {
                try await agtop.sendQueued(id: agtopId, index: index, was: current[index])
            } else {
                try await agtop.removeQueued(id: agtopId, index: index, was: current[index])
            }
        } catch let error as AgtopCommandFailed where error.message.contains("already been sent") {
            await readAgtopQueue(session: session, agtopId: agtopId)
            throw RemoteHostError.notFound("card \(cardId) has no queued prompt \(promptId); it was sent already")
        }
        await readAgtopQueue(session: session, agtopId: agtopId)
    }

    /// Reads one agtop host's queue into the store, then keeps watching
    /// while any host has something queued.
    private func readAgtopQueue(session: String, agtopId: String) async {
        guard let info = try? await agtop.info(id: agtopId) else { return }
        await MainActor.run { store.dispatch(.agtopQueueRead(sessionName: session, queue: info.queue)) }
        await watchAgtopQueues()
    }

    /// While an agtop host has messages queued, reads its queue every two
    /// seconds, so they leave the phone when agtop sends them. The session
    /// scan also reads them, but only as often as the board reconciles.
    private func watchAgtopQueues() async {
        let queued = await MainActor.run { !store.state.agtopQueues.isEmpty }
        guard queued, queueWatch.claim() else { return }
        Task { [weak self] in
            defer { self?.queueWatch.release() }
            while let self, !Task.isCancelled {
                let sessions = await MainActor.run { Array(self.store.state.agtopQueues.keys) }
                if sessions.isEmpty { return }
                try? await Task.sleep(for: .seconds(2))
                for session in sessions {
                    guard let id = AgtopSessionName.agtopId(fromName: session) else { continue }
                    let queue = (try? await self.agtop.info(id: id))?.queue ?? []
                    await MainActor.run { self.store.dispatch(.agtopQueueRead(sessionName: session, queue: queue)) }
                }
            }
        }
    }

    func scrollTerminal(sessionName: String, lines: Int) async {
        guard !AgtopSessionName.isAgtop(sessionName) else { return }
        await runTmux(RemoteTerminalScroll.tmuxCommands(session: sessionName, lines: lines), sessionName)
    }

    func interrupt(cardId: String) async throws {
        let session = try await MainActor.run { () throws -> String in
            let card = try card(cardId)
            guard let session = RemoteBoardMapper.liveAssistantSession(card.link, liveSessions: store.state.tmuxSessions) else {
                throw RemoteHostError.conflict("card \(cardId) has no live session")
            }
            return session
        }
        try await sendEscape(session)
    }

    func resume(cardId: String) async throws -> RemoteCard {
        let current = try await MainActor.run { try remoteCard(cardId) }
        if current.isLive { return current }
        try await MainActor.run { () throws -> Void in
            guard let handler = RemoteControlController.shared.resumeCard else {
                throw RemoteHostError.conflict("Kanban Code has no board window open to resume the card")
            }
            handler(cardId)
        }
        try? await Task.sleep(for: .milliseconds(200))
        return try await MainActor.run { try remoteCard(cardId) }
    }

    func terminalCommand(cardId: String, sessionName: String) async throws -> [String] {
        try await MainActor.run { () throws -> [String] in
            let card = try card(cardId)
            let names = card.link.tmuxLink?.allSessionNames ?? []
            guard names.contains(sessionName) else {
                throw RemoteHostError.notFound("card \(cardId) has no terminal \(sessionName)")
            }
            guard store.state.tmuxSessions.contains(sessionName) || AppServices.machine(forSession: sessionName) != nil else {
                throw RemoteHostError.conflict("terminal \(sessionName) is not running; resume the card first")
            }
            return Self.command(forSession: sessionName)
        }
    }

    /// The command a remote viewer runs, the same way the card's own
    /// terminal decides it: agtop's own UI for agtop, an attach otherwise.
    @MainActor
    static func command(forSession sessionName: String) -> [String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        if let machine = AppServices.machine(forSession: sessionName) {
            let script = TerminalCache.remoteAttachScript(
                boxd: AppServices.boxdPath,
                machine: machine,
                session: sessionName,
                readyMarker: AppServices.remoteReadyMarkerPath(for: sessionName)
            )
            return [shell, "-l", "-c", script]
        }
        if let agtopId = AgtopSessionName.agtopId(fromName: sessionName) {
            return [AgtopCliAdapter.findExecutable() ?? "agtop", "open", agtopId, "--solo"]
        }
        return [shell, "-l", "-c", TerminalCache.attachScript(tmux: TerminalCache.tmuxPath, session: sessionName)]
    }

    func boardChanges() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let store = self.store
        let alive = BoardChangeFlag()
        continuation.onTermination = { _ in alive.stop() }
        Task { @MainActor in
            Self.observe(store: store, continuation: continuation, alive: alive)
        }
        return stream
    }

    /// Yields once per change of the cards, the live sessions or the
    /// projects, re-arming the observation each time.
    @MainActor
    private static func observe(store: BoardStore, continuation: AsyncStream<Void>.Continuation, alive: BoardChangeFlag) {
        guard alive.isAlive else { return }
        withObservationTracking {
            _ = store.state.cards
            _ = store.state.tmuxSessions
            _ = store.state.agtopQueues
            _ = store.state.configuredProjects
        } onChange: {
            continuation.yield()
            Task { @MainActor in observe(store: store, continuation: continuation, alive: alive) }
        }
    }
}

private final class BoardChangeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var alive = true

    var isAlive: Bool { lock.withLock { alive } }
    func stop() { lock.withLock { alive = false } }
}

/// One agtop queue watcher at a time.
private final class QueueWatchFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false

    /// True when the caller should start the watcher.
    func claim() -> Bool {
        lock.withLock {
            if running { return false }
            running = true
            return true
        }
    }

    func release() { lock.withLock { running = false } }
}
