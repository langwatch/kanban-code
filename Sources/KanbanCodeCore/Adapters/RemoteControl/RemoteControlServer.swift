import Foundation
import KanbanCodeRemoteKit
#if canImport(Network)
import Network
#endif
#if canImport(SystemConfiguration)
import SystemConfiguration
#endif
import Synchronization

/// The HTTP + WebSocket server of docs/remote-control.md. It listens on
/// loopback and on the Mac's Tailscale addresses, one listener per address,
/// and serves the host's board, transcripts, prompts and terminals.
///
/// Everything here runs off the main actor: Network.framework callbacks run
/// on their own queues and the host hops to the main actor itself.
public final class RemoteControlServer: Sendable {
    public struct Options: Sendable {
        public var pingInterval: TimeInterval
        /// The events socket pushes the board at most this often.
        public var pushInterval: TimeInterval
        /// How often the devices file and the bindable addresses are checked.
        public var watchInterval: TimeInterval
        public var appVersion: String
        public var hostName: String

        public init(
            pingInterval: TimeInterval = 20,
            pushInterval: TimeInterval = 1,
            watchInterval: TimeInterval = 1,
            appVersion: String = RemoteControlServer.bundleVersion,
            hostName: String = RemoteControlServer.defaultHostName
        ) {
            self.pingInterval = pingInterval
            self.pushInterval = pushInterval
            self.watchInterval = watchInterval
            self.appVersion = appVersion
            self.hostName = hostName
        }
    }

    public enum ServerError: Error, CustomStringConvertible {
        case bindFailed(String, String)

        public var description: String {
            switch self {
            case .bindFailed(let address, let reason): "could not listen on \(address): \(reason)"
            }
        }
    }

    public static var bundleVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// The Mac's computer name, as Sharing settings shows it.
    public static var defaultHostName: String {
        #if canImport(SystemConfiguration)
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.isEmpty { return name }
        #endif
        return ProcessInfo.processInfo.hostName
    }

    private struct SocketEntry {
        let deviceId: String
        let close: @Sendable () -> Void
    }

    private struct State {
        var running = false
        var port: Int
        var listeners: [String: any RemoteListener] = [:]
        var connections: [ObjectIdentifier: RemoteConnection] = [:]
        var sockets: [UUID: SocketEntry] = [:]
        #if canImport(Network)
        var pathMonitor: NWPathMonitor?
        #endif
        var watchTask: Task<Void, Never>?
    }

    public let host: any RemoteControlHost
    public let devices: RemoteDeviceStore
    /// Serves the peer sync routes (`/v1/links`, `/v1/peers`) when set.
    public let peerServer: (any PeerLinksServing)?
    /// Serves the agent sync routes (`/v1/sync/*`, `/v1/optmem/run`) when set.
    public let syncEngine: AgentSyncEngine?
    /// Serves the vault routes (`/v1/vault/*`) when set.
    public let vault: VaultService?
    /// Serves the scrubber routes (`/v1/scrub/*`) when set.
    public let scrubber: SecretScrubber?
    /// Told the card of every request the human made to a card from
    /// another device (`RemoteActivityPolicy`).
    private let activity: (@Sendable (String) async -> Void)?
    private let bindAddresses: @Sendable () -> [String]
    private let options: Options
    private let requestedPort: Int
    private let state: Mutex<State>
    private let queue = DispatchQueue(label: "kanban.remote.server")

    public init(
        host: any RemoteControlHost,
        devices: RemoteDeviceStore,
        port: Int = RemoteAPI.defaultPort,
        bindAddresses: @escaping @Sendable () -> [String] = RemoteNetworkAddresses.bindable,
        options: Options = Options(),
        peerServer: (any PeerLinksServing)? = nil,
        syncEngine: AgentSyncEngine? = nil,
        vault: VaultService? = nil,
        scrubber: SecretScrubber? = nil,
        activity: (@Sendable (String) async -> Void)? = nil
    ) {
        self.activity = activity
        self.host = host
        self.vault = vault
        self.scrubber = scrubber
        self.devices = devices
        self.peerServer = peerServer
        self.syncEngine = syncEngine
        self.requestedPort = port
        self.bindAddresses = bindAddresses
        self.options = options
        self.state = Mutex(State(port: port))
    }

    // MARK: - Lifecycle

    /// The port in use (the ephemeral one when started with port 0).
    public var port: Int { state.withLock { $0.port } }

    public var isRunning: Bool { state.withLock { $0.running } }

    /// Addresses listened on right now.
    public var listeningAddresses: [String] {
        state.withLock { Array($0.listeners.keys) }.sorted()
    }

    /// Binds loopback (throws when that fails), then every other address the
    /// provider returns, and keeps watching for new ones.
    public func start() async throws {
        let alreadyRunning = state.withLock { s -> Bool in
            if s.running { return true }
            s.running = true
            s.port = requestedPort
            return false
        }
        guard !alreadyRunning else { return }

        let addresses = bindAddresses()
        let first = addresses.first ?? RemoteNetworkAddresses.loopback
        do {
            let listener = try await makeListener(address: first, port: requestedPort)
            let bound = listener.port
            state.withLock {
                $0.port = bound
                $0.listeners[first] = listener
            }
        } catch {
            state.withLock { $0.running = false }
            throw error
        }
        await reconcileAddresses()

        #if canImport(Network)
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            guard let self else { return }
            Task { await self.reconcileAddresses() }
        }
        monitor.start(queue: queue)
        #endif

        let interval = options.watchInterval
        let watch = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard let self, !Task.isCancelled else { return }
                self.closeRevokedSockets()
                tick += 1
                if tick % 10 == 0 { await self.reconcileAddresses() }
            }
        }
        state.withLock {
            #if canImport(Network)
            $0.pathMonitor = monitor
            #endif
            $0.watchTask = watch
        }
        KanbanCodeLog.info("remote", "remote control listening on \(listeningAddresses.joined(separator: ", ")) port \(port)")
    }

    public func stop() {
        #if canImport(Network)
        let monitor = state.withLock { s in
            defer { s.pathMonitor = nil }
            return s.pathMonitor
        }
        monitor?.cancel()
        #endif
        let (listeners, connections, sockets, watch) = state.withLock { s in
            s.running = false
            defer {
                s.listeners = [:]
                s.connections = [:]
                s.sockets = [:]
                s.watchTask = nil
            }
            return (Array(s.listeners.values), Array(s.connections.values), Array(s.sockets.values), s.watchTask)
        }
        watch?.cancel()
        listeners.forEach { $0.cancel() }
        sockets.forEach { $0.close() }
        connections.forEach { $0.cancel() }
        KanbanCodeLog.info("remote", "remote control stopped")
    }

    /// Closes every open socket of a device. Revoking through the store does
    /// this on the next watch tick; callers that revoke can call it at once.
    public func closeConnections(deviceId: String) {
        let closers = state.withLock { s in
            s.sockets.values.filter { $0.deviceId == deviceId }.map(\.close)
        }
        closers.forEach { $0() }
    }

    private func closeRevokedSockets() {
        devices.reloadIfChanged()
        let ids = Set(state.withLock { s in s.sockets.values.map(\.deviceId) })
        for id in ids where !devices.contains(id: id) {
            closeConnections(deviceId: id)
        }
    }

    private func reconcileAddresses() async {
        let (running, port, bound) = state.withLock { ($0.running, $0.port, Set($0.listeners.keys)) }
        guard running else { return }
        let wanted = Set(bindAddresses())
        for address in bound.subtracting(wanted) where address != RemoteNetworkAddresses.loopback {
            let listener = state.withLock { $0.listeners.removeValue(forKey: address) }
            listener?.cancel()
            KanbanCodeLog.info("remote", "stopped listening on \(address)")
        }
        for address in wanted.subtracting(bound) {
            do {
                let listener = try await makeListener(address: address, port: port)
                let keep = state.withLock { s -> Bool in
                    guard s.running, s.listeners[address] == nil else { return false }
                    s.listeners[address] = listener
                    return true
                }
                if keep {
                    KanbanCodeLog.info("remote", "listening on \(address):\(port)")
                } else {
                    listener.cancel()
                }
            } catch {
                KanbanCodeLog.warn("remote", "\(error)")
            }
        }
    }

    private func makeListener(address: String, port: Int) async throws -> any RemoteListener {
        try await RemoteTransport.listen(address: address, port: port, queue: queue) { [weak self] stream in
            self?.accept(stream)
        }
    }

    // MARK: - Connections

    private func accept(_ stream: any RemoteByteStream) {
        let conn = RemoteConnection(stream)
        let accepted = state.withLock { s -> Bool in
            guard s.running else { return false }
            s.connections[ObjectIdentifier(conn)] = conn
            return true
        }
        guard accepted else {
            stream.cancel()
            return
        }
        conn.start()
        Task { [weak self] in
            await self?.serve(conn)
            _ = self?.state.withLock { $0.connections.removeValue(forKey: ObjectIdentifier(conn)) }
        }
    }

    private func serve(_ conn: RemoteConnection) async {
        defer { conn.cancel() }
        while true {
            let request: RemoteHTTPRequest
            do {
                guard let r = try await conn.readRequest() else { return }
                request = r
            } catch RemoteHTTPError.tooLarge {
                try? await conn.send(RemoteHTTPResponse.error(413, "request too large").serialized(keepAlive: false))
                return
            } catch RemoteHTTPError.malformed(let why) {
                try? await conn.send(RemoteHTTPResponse.error(400, why).serialized(keepAlive: false))
                return
            } catch {
                return
            }

            switch await route(request, peer: conn.stream.peer) {
            case .response(var response):
                if response.body.count >= RemoteGzip.minimumBytes, RemoteGzip.accepts(request),
                   let gzipped = RemoteGzip.compress(response.body) {
                    response.body = gzipped
                    response.headers.append(("Content-Encoding", "gzip"))
                    response.headers.append(("Vary", "Accept-Encoding"))
                }
                let keepAlive = request.keepAlive
                do {
                    try await conn.send(response.serialized(keepAlive: keepAlive))
                } catch {
                    return
                }
                if !keepAlive { return }
            case .events(let device):
                await serveEvents(conn, request: request, device: device)
                return
            case .terminal(let device, let argv, let session, let cols, let rows):
                await serveTerminal(conn, request: request, device: device, argv: argv, session: session, cols: cols, rows: rows)
                return
            }
        }
    }

    // MARK: - Routing

    private enum Outcome {
        case response(RemoteHTTPResponse)
        case events(RemoteDevice)
        case terminal(RemoteDevice, argv: [String], session: String, cols: Int, rows: Int)
    }

    private func token(from request: RemoteHTTPRequest) -> String? {
        if let auth = request.header("authorization") {
            let parts = auth.split(separator: " ", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "bearer" {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        if let t = request.query["token"], !t.isEmpty { return t }
        return nil
    }

    private func route(_ request: RemoteHTTPRequest, peer: RemotePeerAddress?) async -> Outcome {
        let seg = request.segments
        let method = request.method

        if seg == ["v1", "health"] {
            guard method == "GET" else { return .response(.error(405, "use GET")) }
            return .response(.json(RemoteHealth(version: options.appVersion, hostName: options.hostName)))
        }
        if seg == [".well-known", "openapi.json"] {
            guard method == "GET" else { return .response(.error(405, "use GET")) }
            return .response(.rawJSON(Data(RemoteOpenAPI.document.utf8)))
        }
        guard seg.first == "v1" else { return .response(.error(404, "no route for \(request.rawPath)")) }

        let bearer = token(from: request)
        if bearer == nil, let vault, seg.count >= 2, seg[1] == "vault", peer?.isLoopback == true,
           let response = await RemoteVaultRoutes.handle(
               method: method, rest: Array(seg.dropFirst()), query: request.query, body: request.body,
               device: nil, peer: peer, serverPort: port, vault: vault,
               cardToken: request.header("x-kanban-card-token")) {
            return .response(response)
        }
        if bearer == nil, let scrubber, peer?.isLoopback == true,
           let response = await RemoteScrubRoutes.handle(
               method: method, rest: Array(seg.dropFirst()), body: request.body, device: nil, scrubber: scrubber) {
            return .response(response)
        }
        guard let token = bearer else {
            return .response(.error(401, "missing token: send Authorization: Bearer <token>"))
        }
        guard let device = devices.authenticate(token: token) else {
            return .response(.error(401, "unknown or revoked token"))
        }
        if let refusal = RemoteScopePolicy.refusal(scope: device.scope, method: method, rest: Array(seg.dropFirst())) {
            KanbanCodeLog.warn("remote", "refused \(method) /\(seg.joined(separator: "/")) for \(device.name) (\(device.scope.rawValue) scope)")
            return .response(.error(403, refusal))
        }
        let forOwner = RemoteActivityPolicy.actsForOwner(scope: device.scope, header: request.header(RemoteActingFor.header.lowercased()))
        if forOwner, let activity, let card = RemoteActivityPolicy.card(rest: Array(seg.dropFirst())) {
            await activity(card)
        }
        // What this request forwards to another master goes for the human too.
        return await RemoteActingFor.$owner.withValue(forOwner) {
            await self.routeAuthenticated(request, device: device, peer: peer)
        }
    }

    private func routeAuthenticated(_ request: RemoteHTTPRequest, device: RemoteDevice, peer: RemotePeerAddress?) async -> Outcome {
        let seg = request.segments
        let method = request.method
        if let scrubber, let response = await RemoteScrubRoutes.handle(
            method: method, rest: Array(seg.dropFirst()), body: request.body, device: device, scrubber: scrubber) {
            return .response(response)
        }
        if let vault, let response = await RemoteVaultRoutes.handle(
            method: method, rest: Array(seg.dropFirst()), query: request.query, body: request.body,
            device: device, peer: peer, serverPort: port, vault: vault) {
            return .response(response)
        }

        do {
            let rest = Array(seg.dropFirst())
            if let peerServer,
               let response = await RemoteLinksRoutes.handle(method: method, rest: rest, query: request.query, server: peerServer) {
                return .response(response)
            }
            if let syncEngine,
               let response = await RemoteSyncRoutes.handle(
                   method: method, rest: rest, query: request.query, body: request.body, device: device, engine: syncEngine) {
                return .response(response)
            }
            if rest.first == "cli" {
                guard method == "POST" else { return .response(.error(405, "use POST")) }
                guard device.scope.actsForOwner else {
                    return .response(.error(403, "the \(device.scope.rawValue) scope cannot run commands"))
                }
                guard let body = try? JSONDecoder.remote.decode(RemoteCLIRequest.self, from: request.body) else {
                    return .response(.error(400, "body must be {\"argv\": [...], \"env\", \"images\", ...}"))
                }
                return .response(.json(try await host.runCLI(body)))
            }
            if rest.first == "attention" {
                return .response(try await routeAttention(method: method, rest: rest, body: request.body, device: device))
            }
            if rest.count >= 2, rest[0] == "channels", rest[1] == "files" {
                let path = rest.dropFirst(2).joined(separator: "/")
                switch (method, path.isEmpty) {
                case ("GET", true):
                    return .response(.json(RemoteChannelFiles(files: try await host.channelFiles())))
                case ("GET", false):
                    let offset = max(Int(request.query["offset"] ?? "") ?? 0, 0)
                    return .response(RemoteHTTPResponse(
                        status: 200, headers: [("Content-Type", "application/octet-stream")],
                        body: try await host.channelFile(path: path, offset: offset)))
                case ("PUT", false):
                    guard device.scope.actsForOwner else {
                        return .response(.error(403, "the \(device.scope.rawValue) scope cannot write channels"))
                    }
                    let created = try await host.seedChannelFile(path: path, data: request.body)
                    return .response(created ? .noContent : .error(409, "\(path) exists"))
                default:
                    return .response(.error(405, "method \(method) not allowed on \(request.rawPath)"))
                }
            }
            let id = rest.count >= 2 && rest[0] == "cards" ? rest[1] : ""
            let shape = RemoteScopePolicy.shape(rest)
            switch (method, shape) {
            case ("GET", "cards/search"):
                let scope = request.query["scope"].flatMap { $0.isEmpty ? nil : $0 }
                guard scope == nil || RemoteCardSearchScope(rawValue: scope!) != nil else {
                    return .response(.error(400, "scope must be all, older or archived"))
                }
                return .response(.json(await host.searchCards(RemoteCardSearchRequest(
                    query: request.formValue("q") ?? "",
                    scope: scope.flatMap(RemoteCardSearchScope.init(rawValue:)) ?? .all,
                    limit: Int(request.query["limit"] ?? "") ?? CardSearch.defaultLimit,
                    local: Self.isOn(request.query["local"])))))

            case ("GET", "me"):
                return .response(.json(device))

            case ("GET", "board"):
                let board = await host.board()
                return .response(.json(Self.wantsAll(request) ? board : RemoteWorkingSet.filter(board)))

            case ("PATCH", "cards/*"):
                guard let body = try? JSONDecoder.remote.decode(RemoteCardUpdate.self, from: request.body) else {
                    return .response(.error(400, "body must be {\"name\", \"column\", \"archived\", \"pinned\"}, each optional"))
                }
                return .response(.json(try await host.updateCard(cardId: id, body)))

            case ("DELETE", "cards/*"):
                try await host.deleteCard(cardId: id)
                return .response(.noContent)

            case ("GET", "cards/*"):
                guard let card = await host.board().cards.first(where: { $0.id == id }) else {
                    return .response(.error(404, "no card \(id)"))
                }
                return .response(.json(card))

            case ("GET", "cards/*/transcript"):
                let limit = min(max(Int(request.query["limit"] ?? "") ?? 50, 1), 500)
                let before = request.query["before"].flatMap { $0.isEmpty ? nil : $0 }
                return .response(.json(try await host.transcript(cardId: id, limit: limit, before: before)))

            case ("GET", "machines"):
                return .response(.json(RemoteMachineList(machines: await host.machines())))

            case ("POST", "tasks"):
                guard var body = try? JSONDecoder.remote.decode(RemoteTaskRequest.self, from: request.body) else {
                    return .response(.error(400, "body must be a RemoteTaskRequest: {\"project\", \"prompt\", ...}"))
                }
                guard !body.project.trimmingCharacters(in: .whitespaces).isEmpty else {
                    return .response(.error(400, "project is required"))
                }
                guard !body.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || body.launch == false else {
                    return .response(.error(400, "prompt is required"))
                }
                _ = try RemotePromptImages.decode(body.images)
                // An agent's task is never the human's, whatever it claims.
                if device.scope == .agent { body.human = nil }
                return .response(.json(try await host.createTask(body), status: 201))

            case ("POST", "cards/*/prompt"):
                guard let body = try? JSONDecoder.remote.decode(RemotePromptRequest.self, from: request.body) else {
                    return .response(.error(400, "body must be {\"text\": \"...\", \"mode\": \"queue\"|\"now\", \"images\": [...]}"))
                }
                let decoded = try RemotePromptImages.decode(body.images)
                guard !body.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !decoded.isEmpty else {
                    return .response(.error(400, "text or images are required"))
                }
                // Each image goes where its [Image #N] marker is in the text.
                let (text, images) = PromptImageLayout.arranged(text: body.text, images: decoded)
                var prompt = body
                prompt.text = device.scope == .agent ? CardPromptReader.markRemoteAgentMessage(text, device: device.name) : text
                // An agent's prompt is never the human's, whatever it claims.
                if device.scope == .agent { prompt.human = nil }
                try await host.sendPrompt(cardId: id, prompt, images: images)
                return .response(.noContent)

            case ("POST", "cards/*/side-chat"):
                guard let body = try? JSONDecoder.remote.decode(RemoteSideChatRequest.self, from: request.body) else {
                    return .response(.error(400, "body must be {\"kind\": \"btw\"|\"catchup\", \"question\", \"history\"}"))
                }
                return .response(.json(try await host.startSideChat(cardId: id, body), status: 201))

            case ("GET", "cards/*/side-chat/*"):
                return .response(.json(try await host.sideChatRun(cardId: id, runId: rest[3])))

            case ("GET", "cards/*/slash-commands"):
                return .response(.json(try await host.slashCommands(cardId: id)))

            case ("POST", "cards/*/pasted-image"):
                return .response(.json(try await host.storePastedImage(cardId: id, image: request.body), status: 201))

            case ("DELETE", "cards/*/side-chat/*"):
                try await host.cancelSideChat(cardId: id, runId: rest[3])
                return .response(.noContent)

            case ("POST", "cards/*/queue/*"):
                try await host.sendQueuedPromptNow(cardId: id, promptId: rest[3])
                return .response(.noContent)

            case ("PATCH", "cards/*/queue/*"):
                guard let body = try? JSONDecoder.remote.decode(RemoteQueuedPromptEdit.self, from: request.body),
                      !body.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return .response(.error(400, "body must be {\"text\": \"...\"}"))
                }
                try await host.editQueuedPrompt(cardId: id, promptId: rest[3], text: body.text)
                return .response(.noContent)

            case ("DELETE", "cards/*/queue/*"):
                try await host.removeQueuedPrompt(cardId: id, promptId: rest[3])
                return .response(.noContent)

            case ("POST", "cards/*/interrupt"):
                try await host.interrupt(cardId: id)
                return .response(.noContent)

            case ("POST", "cards/*/resume"):
                return .response(.json(try await host.resume(cardId: id)))

            case ("POST", "cards/*/move"):
                guard let body = try? JSONDecoder.remote.decode(RemoteMoveRequest.self, from: request.body),
                      !body.to.trimmingCharacters(in: .whitespaces).isEmpty else {
                    return .response(.error(400, "body must be {\"to\": \"<machine id or name>\"|\"mac\"}"))
                }
                return .response(.json(try await host.moveCard(cardId: id, to: body.to.trimmingCharacters(in: .whitespaces))))

            case ("POST", "cards/*/worktree/remove"):
                // It deletes files on the machine, uncommitted work included.
                guard device.scope.actsForOwner else {
                    return .response(.error(403, "the \(device.scope.rawValue) scope cannot remove worktrees"))
                }
                return .response(.json(try await host.removeWorktree(cardId: id)))

            case ("POST", "cards/*/discover"):
                try await host.discoverBranches(cardId: id)
                return .response(.noContent)

            case ("GET", "cards/*/handover"):
                return .response(.json(try await host.handoverInfo(cardId: id)))

            case ("GET", "cards/*/transcript/raw"):
                let offset = max(Int(request.query["offset"] ?? "") ?? 0, 0)
                let limit = min(max(Int(request.query["limit"] ?? "") ?? (4 << 20), 1), 16 << 20)
                let raw = try await host.rawTranscript(cardId: id, offset: offset, limit: limit)
                return .response(RemoteHTTPResponse(
                    status: 200,
                    headers: [("Content-Type", "application/octet-stream"), (RemoteRawTranscript.sizeHeader, String(raw.size))],
                    body: raw.data))

            case ("GET", "events"):
                guard request.wantsWebSocket else { return .response(.error(426, "WebSocket upgrade required")) }
                return .events(device)

            case ("GET", "cards/*/terminal"):
                guard device.scope == .full || device.scope == .terminal else {
                    return .response(.error(403, "the \(device.scope.rawValue) scope cannot open terminals"))
                }
                guard request.wantsWebSocket else { return .response(.error(426, "WebSocket upgrade required")) }
                var session = request.query["session"] ?? ""
                if session.isEmpty {
                    guard let card = await host.board().cards.first(where: { $0.id == id }) else {
                        return .response(.error(404, "no card \(id)"))
                    }
                    session = card.terminals.first(where: { $0.isPrimary })?.sessionName ?? card.terminals.first?.sessionName ?? ""
                }
                let argv = try await host.terminalCommand(cardId: id, sessionName: session)
                guard !argv.isEmpty else { return .response(.error(409, "card \(id) has no terminal")) }
                let cols = min(max(Int(request.query["cols"] ?? "") ?? 80, 2), 1000)
                let rows = min(max(Int(request.query["rows"] ?? "") ?? 24, 2), 1000)
                return .terminal(device, argv: argv, session: session, cols: cols, rows: rows)

            default:
                if Self.knownShapes.contains(shape) {
                    return .response(.error(405, "method \(method) not allowed on \(request.rawPath)"))
                }
                return .response(.error(404, "no route for \(method) \(request.rawPath)"))
            }
        } catch {
            return .response(Self.response(for: error))
        }
    }

    private func routeAttention(method: String, rest: [String], body: Data, device: RemoteDevice) async throws -> RemoteHTTPResponse {
        switch (method, rest.count) {
        case ("GET", 1):
            return .json(AttentionListResponse(requests: await host.attention()))
        case ("POST", 2) where rest[1] == "presence":
            guard device.scope.actsForOwner else { return .error(403, "the \(device.scope.rawValue) scope cannot report presence") }
            guard let presence = try? JSONDecoder.remote.decode(MacPresence.self, from: body) else {
                return .error(400, "body must be a MacPresence")
            }
            await host.reportPresence(presence)
            return .noContent
        case ("POST", 3) where rest[2] == "resolve":
            // An agent must never answer what it is waiting on.
            guard device.scope.actsForOwner else { return .error(403, "the \(device.scope.rawValue) scope cannot resolve attention requests") }
            guard let resolve = try? JSONDecoder.remote.decode(AttentionResolveRequest.self, from: body),
                  !resolve.resolution.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .error(400, "body must be {\"resolution\": \"...\"}")
            }
            try await host.resolveAttention(id: rest[1], resolution: resolve.resolution, by: resolve.by ?? device.name,
                                            unsealed: resolve.unsealed)
            return .noContent
        case (_, 1), (_, 2), (_, 3):
            return .error(405, "method \(method) not allowed on /v1/\(rest.joined(separator: "/"))")
        default:
            return .error(404, "no route for \(method) /v1/\(rest.joined(separator: "/"))")
        }
    }

    /// `?all=1` asks for every card instead of the working set.
    static func wantsAll(_ request: RemoteHTTPRequest) -> Bool {
        isOn(request.query["all"])
    }

    /// A query flag: present with no value, or `1`, `true`, `yes`.
    static func isOn(_ value: String?) -> Bool {
        guard let value = value?.lowercased() else { return false }
        return value == "" || value == "1" || value == "true" || value == "yes"
    }

    private static let knownShapes: Set<String> = [
        "me", "board", "machines", "cards/search", "cards/*", "cards/*/transcript", "tasks", "cards/*/prompt", "cards/*/queue/*",
        "cards/*/interrupt", "cards/*/resume", "events", "cards/*/terminal",
        "cards/*/move", "cards/*/handover", "cards/*/transcript/raw",
        "cards/*/worktree/remove", "cards/*/discover", "cards/*/side-chat", "cards/*/side-chat/*",
        "cards/*/slash-commands", "cards/*/pasted-image",
    ]

    static func response(for error: Error) -> RemoteHTTPResponse {
        if let e = error as? RemoteHostError {
            switch e.kind {
            case .notFound: return .error(404, e.message)
            case .badRequest: return .error(400, e.message)
            case .conflict: return .error(409, e.message)
            }
        }
        if let e = error as? RemoteError { return .error(400, e.error) }
        return .error(500, "\(error)")
    }

    // MARK: - WebSockets

    private func register(_ deviceId: String, close: @escaping @Sendable () -> Void) -> UUID? {
        let id = UUID()
        let ok = state.withLock { s -> Bool in
            guard s.running else { return false }
            s.sockets[id] = SocketEntry(deviceId: deviceId, close: close)
            return true
        }
        return ok ? id : nil
    }

    private func unregister(_ id: UUID) {
        _ = state.withLock { $0.sockets.removeValue(forKey: id) }
    }

    private func encodedEvent(_ event: RemoteEvent) -> String? {
        guard let data = try? JSONEncoder.remote.encode(event) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func serveEvents(_ conn: RemoteConnection, request: RemoteHTTPRequest, device: RemoteDevice) async {
        guard let handshake = RemoteWebSocketHandshake.response(for: request) else {
            try? await conn.send(RemoteHTTPResponse.error(400, "bad WebSocket upgrade").serialized(keepAlive: false))
            return
        }
        do { try await conn.send(handshake) } catch { return }
        let ws = RemoteWebSocket(connection: conn)
        guard let socketId = register(device.id, close: { ws.close(code: 1008, reason: "device revoked") }) else {
            ws.close(code: 1001, reason: "server stopping")
            return
        }
        defer { unregister(socketId) }

        let all = Self.wantsAll(request)
        let host = self.host
        let pushInterval = options.pushInterval
        let pingInterval = options.pingInterval
        let (triggers, trigger) = AsyncStream<EventTrigger>.makeStream(bufferingPolicy: .unbounded)
        let changes = host.boardChanges()
        let forwarder = Task {
            for await _ in changes { trigger.yield(.change) }
        }
        let pusher = Task { [weak self] in
            guard let self else { return }
            var tracker = RemoteBoardDeltaTracker()
            func current() async -> RemoteBoard {
                let board = await host.board()
                return all ? board : RemoteWorkingSet.filter(board)
            }
            var lastAttention = await host.attention()
            var first = tracker.fullBoard(await current())
            first.attention = lastAttention
            if let text = self.encodedEvent(first) {
                try? await ws.sendText(text)
            }
            var lastPush = Date()
            for await next in triggers {
                if Task.isCancelled { return }
                var event: RemoteEvent?
                switch next {
                case .resync:
                    event = tracker.fullBoard(await current())
                case .change:
                    let wait = pushInterval - Date().timeIntervalSince(lastPush)
                    if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                    if Task.isCancelled { return }
                    // The app signals many changes that leave the wire board as it was.
                    event = tracker.delta(await current())
                }
                let attention = await host.attention()
                if attention != lastAttention || next == .resync {
                    lastAttention = attention
                    if event == nil { event = RemoteEvent(type: .cards, upserted: [], removed: []) }
                    event?.attention = attention
                }
                guard let event, let text = self.encodedEvent(event) else { continue }
                lastPush = Date()
                do { try await ws.sendText(text) } catch { return }
            }
        }
        let pinger = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(pingInterval))
                guard !Task.isCancelled, let self, let text = self.encodedEvent(RemoteEvent(type: .ping)) else { return }
                do { try await ws.sendText(text) } catch { return }
            }
        }
        defer {
            forwarder.cancel()
            pusher.cancel()
            pinger.cancel()
            trigger.finish()
        }
        // The only client frame is {"type":"resync"}; reading also answers pings and sees the close.
        while let message = try? await ws.receive() {
            if case .text(let text) = message,
               let control = try? JSONDecoder().decode(RemoteEventsControl.self, from: Data(text.utf8)),
               control.type == .resync {
                trigger.yield(.resync)
            }
        }
    }

    private enum EventTrigger: Sendable {
        case change
        case resync
    }

    private func serveTerminal(
        _ conn: RemoteConnection, request: RemoteHTTPRequest, device: RemoteDevice,
        argv: [String], session: String, cols: Int, rows: Int
    ) async {
        guard let handshake = RemoteWebSocketHandshake.response(for: request) else {
            try? await conn.send(RemoteHTTPResponse.error(400, "bad WebSocket upgrade").serialized(keepAlive: false))
            return
        }
        do { try await conn.send(handshake) } catch { return }
        let ws = RemoteWebSocket(connection: conn)

        let process: RemotePTYProcess
        do {
            process = try RemotePTYProcess.spawn(argv: argv, cols: cols, rows: rows)
        } catch {
            KanbanCodeLog.warn("remote", "terminal spawn failed for \(argv): \(error)")
            try? await ws.sendBinary(Data("\r\n[kanban] could not start \(argv.joined(separator: " ")): \(error)\r\n".utf8))
            ws.close(code: 1011, reason: "spawn failed")
            return
        }
        KanbanCodeLog.info("remote", "terminal for \(device.name): \(argv.joined(separator: " ")) pid \(process.pid) \(cols)x\(rows)")

        guard let socketId = register(device.id, close: { ws.close(code: 1008, reason: "device revoked") }) else {
            process.terminate()
            ws.close(code: 1001, reason: "server stopping")
            return
        }
        defer { unregister(socketId) }

        process.startReading(
            onData: { data in
                // Waiting for the send keeps a slow client from buffering without bound.
                let sent = DispatchSemaphore(value: 0)
                conn.send(RemoteWebSocket.frames(opcode: .binary, payload: data)) { _ in
                    sent.signal()
                }
                _ = sent.wait(timeout: .now() + 30)
            },
            onExit: {
                ws.close(code: 1000, reason: "terminal exited")
            }
        )

        while true {
            guard let message = try? await ws.receive() else { break }
            switch message {
            case .binary(let data):
                process.write(data)
            case .text(let text):
                if let control = try? JSONDecoder().decode(RemoteTerminalControl.self, from: Data(text.utf8)) {
                    switch control.type {
                    case .resize:
                        if let c = control.cols, let r = control.rows, c > 0, r > 0 {
                            process.resize(cols: min(c, 1000), rows: min(r, 1000))
                        }
                    case .scroll:
                        if let lines = control.lines, lines != 0 {
                            await host.scrollTerminal(sessionName: session, lines: lines)
                        }
                    }
                } else {
                    process.write(Data(text.utf8))
                }
            }
        }
        process.terminate()
        ws.close()
    }
}
