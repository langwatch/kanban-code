import Foundation

// MARK: - Pairing

/// The `kanbancode://pair?url=<base url>&token=<token>&name=<host name>` link
/// the Mac shows as a QR code.
public struct RemotePairLink: Sendable, Equatable {
    public var baseURL: URL
    public var token: String
    public var name: String?

    public init(baseURL: URL, token: String, name: String? = nil) {
        self.baseURL = baseURL
        self.token = token
        self.name = name
    }

    /// Reads a pairing link. Surrounding whitespace is ignored. Returns nil
    /// when the scheme or host is wrong, the url is not http(s), or the
    /// token is missing.
    public static func parse(_ string: String) -> RemotePairLink? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let comps = URLComponents(string: trimmed),
              comps.scheme?.lowercased() == "kanbancode",
              comps.host?.lowercased() == "pair" else { return nil }
        let items = comps.queryItems ?? []
        func value(_ key: String) -> String? {
            items.first { $0.name == key }?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let rawURL = value("url"), let base = RemoteServerURL.normalize(rawURL),
              let token = value("token"), !token.isEmpty else { return nil }
        let name = value("name").flatMap { $0.isEmpty ? nil : $0 }
        return RemotePairLink(baseURL: base, token: token, name: name)
    }

    /// The link itself, as the Mac encodes it.
    public var url: URL {
        var comps = URLComponents()
        comps.scheme = "kanbancode"
        comps.host = "pair"
        var items = [URLQueryItem(name: "url", value: baseURL.absoluteString),
                     URLQueryItem(name: "token", value: token)]
        if let name { items.append(URLQueryItem(name: "name", value: name)) }
        comps.queryItems = items
        // `+` and `&` inside values must survive other parsers too.
        comps.percentEncodedQuery = comps.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return comps.url!
    }
}

public enum RemoteServerURL {
    /// Accepts `http(s)://host[:port][/path]` and a bare `host[:port]`
    /// (read as http). Drops a trailing slash. Nil for anything else.
    public static func normalize(_ string: String) -> URL? {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let comps = URLComponents(string: s),
              let scheme = comps.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = comps.host, !host.isEmpty else { return nil }
        return comps.url
    }
}

// MARK: - Errors

public enum RemoteClientError: Error, Sendable, Equatable, LocalizedError {
    /// 401: no token, or one the Mac does not know (revoked).
    case unauthorized(String)
    /// 403: the token's scope does not allow the call.
    case forbidden(String)
    /// 404.
    case notFound(String)
    /// 409: the card has no live session.
    case conflict(String)
    /// Any other non-2xx answer, with the server's `error` text.
    case server(status: Int, message: String)
    /// The request never got an HTTP answer.
    case transport(String)
    /// The body did not decode.
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized(let m): m.isEmpty ? "The Mac refused this device. Pair it again." : m
        case .forbidden(let m): m.isEmpty ? "This device is not allowed to do that." : m
        case .notFound(let m): m.isEmpty ? "Not found." : m
        case .conflict(let m): m.isEmpty ? "The card has no live session." : m
        case .server(let status, let m): m.isEmpty ? "The Mac answered \(status)." : m
        case .transport(let m): m
        case .decoding(let m): "Unexpected answer from the Mac: \(m)"
        }
    }

    /// Retrying will not help: the token is refused.
    public var isAuthFailure: Bool {
        switch self {
        case .unauthorized, .forbidden: true
        default: false
        }
    }

    static func from(status: Int, body: Data) -> RemoteClientError {
        let message = (try? JSONDecoder.remote.decode(RemoteError.self, from: body))?.error
            ?? String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        switch status {
        case 401: return .unauthorized(message)
        case 403: return .forbidden(message)
        case 404: return .notFound(message)
        case 409: return .conflict(message)
        default: return .server(status: status, message: message)
        }
    }
}

// MARK: - Client

/// State of the live `/v1/events` connection.
public enum RemoteConnectionState: Sendable, Equatable {
    case connecting
    case connected
    /// Lost; the next attempt starts after `retryIn` seconds.
    case reconnecting(retryIn: TimeInterval, reason: String)
}

/// Async client for every endpoint in docs/remote-control.md.
public struct RemoteClient: Sendable {
    public var baseURL: URL
    public var token: String
    public var session: URLSession

    public init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    public init(link: RemotePairLink, session: URLSession = .shared) {
        self.init(baseURL: link.baseURL, token: link.token, session: session)
    }

    // MARK: Endpoints

    public func health() async throws -> RemoteHealth {
        try await send(makeRequest("GET", "v1/health", authorized: false))
    }

    public func me() async throws -> RemoteDevice {
        try await send(makeRequest("GET", "v1/me"))
    }

    /// The working set (no archived cards, recent Done only), or every card with `all`.
    public func board(all: Bool = false) async throws -> RemoteBoard {
        try await send(makeRequest("GET", "v1/board", query: all ? [URLQueryItem(name: "all", value: "1")] : []))
    }

    public func card(id: String) async throws -> RemoteCard {
        try await send(makeRequest("GET", "v1/cards/\(Self.escape(id))"))
    }

    public func transcript(cardId: String, limit: Int = 50, before: String? = nil) async throws -> RemoteTranscript {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let before { query.append(URLQueryItem(name: "before", value: before)) }
        return try await send(makeRequest("GET", "v1/cards/\(Self.escape(cardId))/transcript", query: query))
    }

    public func createTask(_ task: RemoteTaskRequest) async throws -> RemoteCard {
        var request = makeRequest("POST", "v1/tasks", body: task)
        if task.images?.isEmpty == false { request.timeoutInterval = 120 }
        return try await send(request)
    }

    public func sendPrompt(cardId: String, text: String, mode: RemotePromptRequest.Mode = .queue,
                           images: [RemoteImage] = []) async throws {
        var request = makeRequest("POST", "v1/cards/\(Self.escape(cardId))/prompt",
                                  body: RemotePromptRequest(text: text, mode: mode, images: images.isEmpty ? nil : images))
        if !images.isEmpty { request.timeoutInterval = 120 }
        try await sendEmpty(request)
    }

    /// Sends a queued prompt right away, interrupting the turn.
    public func sendQueuedPromptNow(cardId: String, promptId: String) async throws {
        try await sendEmpty(makeRequest("POST", "v1/cards/\(Self.escape(cardId))/queue/\(Self.escape(promptId))"))
    }

    /// Drops a queued prompt before it is sent.
    public func removeQueuedPrompt(cardId: String, promptId: String) async throws {
        try await sendEmpty(makeRequest("DELETE", "v1/cards/\(Self.escape(cardId))/queue/\(Self.escape(promptId))"))
    }

    public func interrupt(cardId: String) async throws {
        try await sendEmpty(makeRequest("POST", "v1/cards/\(Self.escape(cardId))/interrupt"))
    }

    public func resume(cardId: String) async throws -> RemoteCard {
        try await send(makeRequest("POST", "v1/cards/\(Self.escape(cardId))/resume"))
    }

    // MARK: Requests

    /// Builds the request for `path` (relative to the base URL, no leading slash).
    public func makeRequest(_ method: String, _ path: String, query: [URLQueryItem] = [],
                            authorized: Bool = true) -> URLRequest {
        var request = URLRequest(url: url(path, query: query))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if authorized { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.timeoutInterval = 30
        return request
    }

    public func makeRequest<Body: Encodable>(_ method: String, _ path: String, body: Body) -> URLRequest {
        var request = makeRequest(method, path)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder.remote.encode(body)
        return request
    }

    /// `path` resolved against the base URL, which may carry a path of its own.
    public func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        var basePath = comps.percentEncodedPath
        while basePath.hasSuffix("/") { basePath.removeLast() }
        comps.percentEncodedPath = basePath + "/" + path
        comps.queryItems = query.isEmpty ? nil : query
        return comps.url!
    }

    /// The WebSocket form of `url(_:query:)`: ws for http, wss for https.
    public func webSocketURL(_ path: String, query: [URLQueryItem] = []) -> URL {
        var comps = URLComponents(url: url(path, query: query), resolvingAgainstBaseURL: false)!
        comps.scheme = comps.scheme?.lowercased() == "https" ? "wss" : "ws"
        return comps.url!
    }

    static func escape(_ component: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        return component.addingPercentEncoding(withAllowedCharacters: allowed) ?? component
    }

    private func data(for request: URLRequest) async throws -> (Data, Int) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw RemoteClientError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw RemoteClientError.transport("No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw RemoteClientError.from(status: http.statusCode, body: data)
        }
        return (data, http.statusCode)
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, _) = try await data(for: request)
        do {
            return try JSONDecoder.remote.decode(T.self, from: data)
        } catch {
            throw RemoteClientError.decoding(String(describing: error))
        }
    }

    private func sendEmpty(_ request: URLRequest) async throws {
        _ = try await data(for: request)
    }

    // MARK: Events

    /// Board updates from `WS /v1/events`: a whole `board` on every
    /// (re)connect, then `cards` deltas to fold in with `RemoteEvent.apply(to:)`.
    /// A delta that arrives before the connection's first board is dropped and
    /// a resync asked for, so every delta applies to a whole board. Reconnects
    /// with exponential backoff (1 s doubling to 30 s) on any drop, and
    /// finishes with an error only when the token is refused. `onState`
    /// reports the connection.
    public func events(all: Bool = false,
                       onState: (@Sendable (RemoteConnectionState) -> Void)? = nil) -> AsyncThrowingStream<RemoteEvent, Error> {
        let request = webSocketRequest(webSocketURL("v1/events", query: all ? [URLQueryItem(name: "all", value: "1")] : []))
        let session = self.session
        return AsyncThrowingStream { continuation in
            let task = Task {
                var delay: TimeInterval = 1
                while !Task.isCancelled {
                    onState?(.connecting)
                    let socket = session.webSocketTask(with: request)
                    socket.resume()
                    var gotFrame = false
                    var gotBoard = false
                    var reason = "Connection lost"
                    do {
                        while !Task.isCancelled {
                            let message = try await socket.receive()
                            if !gotFrame {
                                gotFrame = true
                                delay = 1
                                onState?(.connected)
                            }
                            let data: Data
                            switch message {
                            case .string(let s): data = Data(s.utf8)
                            case .data(let d): data = d
                            @unknown default: continue
                            }
                            guard let event = try? JSONDecoder.remote.decode(RemoteEvent.self, from: data) else { continue }
                            switch event.type {
                            case .board:
                                gotBoard = true
                            case .cards where !gotBoard:
                                try? await socket.send(.string(Self.resyncFrame))
                                continue
                            default:
                                break
                            }
                            continuation.yield(event)
                        }
                    } catch {
                        if let authError = Self.handshakeError(socket) {
                            socket.cancel(with: .goingAway, reason: nil)
                            continuation.finish(throwing: authError)
                            return
                        }
                        reason = error.localizedDescription
                    }
                    socket.cancel(with: .goingAway, reason: nil)
                    if Task.isCancelled { break }
                    onState?(.reconnecting(retryIn: delay, reason: reason))
                    try? await Task.sleep(for: .seconds(delay))
                    delay = min(delay * 2, 30)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static let resyncFrame: String = {
        let data = (try? JSONEncoder.remote.encode(RemoteEventsControl(type: .resync))) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }()

    // MARK: Terminal

    /// Opens `WS /v1/cards/{id}/terminal`. Needs a `full` token.
    public func terminal(cardId: String, session sessionName: String? = nil, cols: Int, rows: Int) -> RemoteTerminalConnection {
        var query: [URLQueryItem] = []
        if let sessionName { query.append(URLQueryItem(name: "session", value: sessionName)) }
        query.append(URLQueryItem(name: "cols", value: String(cols)))
        query.append(URLQueryItem(name: "rows", value: String(rows)))
        let request = webSocketRequest(webSocketURL("v1/cards/\(Self.escape(cardId))/terminal", query: query))
        return RemoteTerminalConnection(task: session.webSocketTask(with: request))
    }

    public func webSocketRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        return request
    }

    /// A refused handshake shows up as a failed receive; the HTTP status
    /// tells a revoked token apart from a dropped network.
    static func handshakeError(_ task: URLSessionWebSocketTask) -> RemoteClientError? {
        guard let http = task.response as? HTTPURLResponse else { return nil }
        switch http.statusCode {
        case 401: return .unauthorized("")
        case 403: return .forbidden("")
        default: return nil
        }
    }
}

/// One viewer of a card's terminal. Binary frames carry bytes both ways;
/// a text frame resizes the pseudo-terminal on the Mac.
public final class RemoteTerminalConnection: @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    /// The terminal's output. Finishes when the socket closes, with an error
    /// when it drops or is refused.
    public let output: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation

    init(task: URLSessionWebSocketTask) {
        self.task = task
        (output, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        task.resume()
        let continuation = self.continuation
        Task { [task] in
            do {
                while true {
                    switch try await task.receive() {
                    case .data(let d): continuation.yield(d)
                    case .string(let s): continuation.yield(Data(s.utf8))
                    @unknown default: break
                    }
                }
            } catch {
                if let authError = RemoteClient.handshakeError(task) {
                    continuation.finish(throwing: authError)
                } else if task.closeCode == .normalClosure || task.closeCode == .goingAway {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: RemoteClientError.transport(error.localizedDescription))
                }
            }
        }
    }

    /// Keystrokes to the terminal.
    public func send(_ bytes: Data) {
        task.send(.data(bytes)) { _ in }
    }

    public func send(_ text: String) {
        send(Data(text.utf8))
    }

    public func resize(cols: Int, rows: Int) {
        sendControl(RemoteTerminalControl(type: .resize, cols: cols, rows: rows))
    }

    /// Scrolls a tmux terminal's history on the Mac: up when `lines` is
    /// positive. Only for a server that lists `RemoteAPI.Feature.terminalScroll`;
    /// an older one types the frame into the terminal.
    public func scroll(lines: Int) {
        guard lines != 0 else { return }
        sendControl(RemoteTerminalControl(type: .scroll, lines: lines))
    }

    private func sendControl(_ control: RemoteTerminalControl) {
        guard let data = try? JSONEncoder.remote.encode(control) else { return }
        task.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }

    /// Ends this viewer. The session on the Mac keeps running.
    public func close() {
        task.cancel(with: .normalClosure, reason: nil)
        continuation.finish()
    }

    deinit {
        task.cancel(with: .normalClosure, reason: nil)
    }
}
