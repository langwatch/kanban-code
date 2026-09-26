import Foundation
import KanbanCodeRemoteKit
import Network
import SystemConfiguration
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
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.isEmpty { return name }
        return ProcessInfo.processInfo.hostName
    }

    private struct SocketEntry {
        let deviceId: String
        let close: @Sendable () -> Void
    }

    private struct State {
        var running = false
        var port: Int
        var listeners: [String: NWListener] = [:]
        var connections: [ObjectIdentifier: RemoteConnection] = [:]
        var sockets: [UUID: SocketEntry] = [:]
        var pathMonitor: NWPathMonitor?
        var watchTask: Task<Void, Never>?
    }

    public let host: any RemoteControlHost
    public let devices: RemoteDeviceStore
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
        options: Options = Options()
    ) {
        self.host = host
        self.devices = devices
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
            let bound = Int(listener.port?.rawValue ?? UInt16(requestedPort))
            state.withLock {
                $0.port = bound
                $0.listeners[first] = listener
            }
        } catch {
            state.withLock { $0.running = false }
            throw error
        }
        await reconcileAddresses()

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            guard let self else { return }
            Task { await self.reconcileAddresses() }
        }
        monitor.start(queue: queue)

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
            $0.pathMonitor = monitor
            $0.watchTask = watch
        }
        KanbanCodeLog.info("remote", "remote control listening on \(listeningAddresses.joined(separator: ", ")) port \(port)")
    }

    public func stop() {
        let (listeners, connections, sockets, monitor, watch) = state.withLock { s in
            s.running = false
            defer {
                s.listeners = [:]
                s.connections = [:]
                s.sockets = [:]
                s.pathMonitor = nil
                s.watchTask = nil
            }
            return (Array(s.listeners.values), Array(s.connections.values), Array(s.sockets.values), s.pathMonitor, s.watchTask)
        }
        watch?.cancel()
        monitor?.cancel()
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

    private func makeListener(address: String, port: Int) async throws -> NWListener {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host(address),
            port: NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? .any
        )
        let listener: NWListener
        do {
            listener = try NWListener(using: params)
        } catch {
            throw ServerError.bindFailed(address, "\(error)")
        }
        listener.newConnectionHandler = { [weak self] nw in
            self?.accept(nw)
        }
        let resumed = Mutex(false)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                let result: Result<Void, Error>?
                switch state {
                case .ready: result = .success(())
                case .failed(let error): result = .failure(ServerError.bindFailed(address, "\(error)"))
                case .cancelled: result = .failure(ServerError.bindFailed(address, "cancelled"))
                case .waiting(let error): result = .failure(ServerError.bindFailed(address, "\(error)"))
                default: result = nil
                }
                guard let result else { return }
                let first = resumed.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                if first {
                    if case .failure = result { listener.cancel() }
                    cont.resume(with: result)
                }
            }
            listener.start(queue: queue)
        }
        return listener
    }

    // MARK: - Connections

    private func accept(_ nw: NWConnection) {
        let conn = RemoteConnection(nw)
        let accepted = state.withLock { s -> Bool in
            guard s.running else { return false }
            s.connections[ObjectIdentifier(conn)] = conn
            return true
        }
        guard accepted else {
            nw.cancel()
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

            switch await route(request) {
            case .response(let response):
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
            case .terminal(let device, let argv, let cols, let rows):
                await serveTerminal(conn, request: request, device: device, argv: argv, cols: cols, rows: rows)
                return
            }
        }
    }

    // MARK: - Routing

    private enum Outcome {
        case response(RemoteHTTPResponse)
        case events(RemoteDevice)
        case terminal(RemoteDevice, argv: [String], cols: Int, rows: Int)
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

    private func route(_ request: RemoteHTTPRequest) async -> Outcome {
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

        guard let token = token(from: request) else {
            return .response(.error(401, "missing token: send Authorization: Bearer <token>"))
        }
        guard let device = devices.authenticate(token: token) else {
            return .response(.error(401, "unknown or revoked token"))
        }

        do {
            let rest = Array(seg.dropFirst())
            let id = rest.count >= 2 && rest[0] == "cards" ? rest[1] : ""
            let shape = rest.enumerated().map { $0.offset == 1 && rest[0] == "cards" ? "*" : $0.element }.joined(separator: "/")
            switch (method, shape) {
            case ("GET", "me"):
                return .response(.json(device))

            case ("GET", "board"):
                let board = await host.board()
                return .response(.json(Self.wantsAll(request) ? board : RemoteWorkingSet.filter(board)))

            case ("GET", "cards/*"):
                guard let card = await host.board().cards.first(where: { $0.id == id }) else {
                    return .response(.error(404, "no card \(id)"))
                }
                return .response(.json(card))

            case ("GET", "cards/*/transcript"):
                let limit = min(max(Int(request.query["limit"] ?? "") ?? 50, 1), 500)
                let before = request.query["before"].flatMap { $0.isEmpty ? nil : $0 }
                return .response(.json(try await host.transcript(cardId: id, limit: limit, before: before)))

            case ("POST", "tasks"):
                guard let body = try? JSONDecoder.remote.decode(RemoteTaskRequest.self, from: request.body) else {
                    return .response(.error(400, "body must be a RemoteTaskRequest: {\"project\", \"prompt\", ...}"))
                }
                guard !body.project.trimmingCharacters(in: .whitespaces).isEmpty else {
                    return .response(.error(400, "project is required"))
                }
                guard !body.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || body.launch == false else {
                    return .response(.error(400, "prompt is required"))
                }
                return .response(.json(try await host.createTask(body), status: 201))

            case ("POST", "cards/*/prompt"):
                guard let body = try? JSONDecoder.remote.decode(RemotePromptRequest.self, from: request.body) else {
                    return .response(.error(400, "body must be {\"text\": \"...\", \"mode\": \"queue\"|\"now\"}"))
                }
                guard !body.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return .response(.error(400, "text is required"))
                }
                try await host.sendPrompt(cardId: id, body)
                return .response(.noContent)

            case ("POST", "cards/*/interrupt"):
                try await host.interrupt(cardId: id)
                return .response(.noContent)

            case ("POST", "cards/*/resume"):
                return .response(.json(try await host.resume(cardId: id)))

            case ("GET", "events"):
                guard request.wantsWebSocket else { return .response(.error(426, "WebSocket upgrade required")) }
                return .events(device)

            case ("GET", "cards/*/terminal"):
                guard device.scope == .full else {
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
                return .terminal(device, argv: argv, cols: cols, rows: rows)

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

    /// `?all=1` asks for every card instead of the working set.
    static func wantsAll(_ request: RemoteHTTPRequest) -> Bool {
        guard let value = request.query["all"]?.lowercased() else { return false }
        return value == "" || value == "1" || value == "true" || value == "yes"
    }

    private static let knownShapes: Set<String> = [
        "me", "board", "cards/*", "cards/*/transcript", "tasks", "cards/*/prompt",
        "cards/*/interrupt", "cards/*/resume", "events", "cards/*/terminal",
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
        let changes = host.boardChanges()
        let pusher = Task { [weak self] in
            guard let self else { return }
            var sent = await host.board()
            if !all { sent = RemoteWorkingSet.filter(sent) }
            if let text = self.encodedEvent(RemoteEvent(type: .board, board: sent)) {
                try? await ws.sendText(text)
            }
            var lastPush = Date()
            for await _ in changes {
                let wait = pushInterval - Date().timeIntervalSince(lastPush)
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                if Task.isCancelled { return }
                var board = await host.board()
                if !all { board = RemoteWorkingSet.filter(board) }
                // The app signals many changes that leave the wire board as it was.
                guard board.cards != sent.cards || board.projects != sent.projects else { continue }
                lastPush = Date()
                sent = board
                guard let text = self.encodedEvent(RemoteEvent(type: .board, board: board)) else { continue }
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
            pusher.cancel()
            pinger.cancel()
        }
        // Client frames carry nothing; reading keeps pings answered and sees the close.
        while let message = try? await ws.receive() {
            _ = message
        }
    }

    private func serveTerminal(
        _ conn: RemoteConnection, request: RemoteHTTPRequest, device: RemoteDevice,
        argv: [String], cols: Int, rows: Int
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

        let nw = conn.nw
        process.startReading(
            onData: { data in
                // Waiting for the send keeps a slow client from buffering without bound.
                let sent = DispatchSemaphore(value: 0)
                nw.send(content: RemoteWebSocket.frames(opcode: .binary, payload: data), completion: .contentProcessed { _ in
                    sent.signal()
                })
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
                if let control = try? JSONDecoder().decode(RemoteTerminalControl.self, from: Data(text.utf8)),
                   control.type == .resize, let c = control.cols, let r = control.rows, c > 0, r > 0 {
                    process.resize(cols: min(c, 1000), rows: min(r, 1000))
                } else {
                    process.write(Data(text.utf8))
                }
            }
        }
        process.terminate()
        ws.close()
    }
}
