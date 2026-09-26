import CryptoKit
import Foundation
import Network

/// A parsed HTTP/1.1 request.
struct RemoteHTTPRequest: Sendable {
    var method: String
    /// Percent-decoded path segments, "/v1/cards/x" -> ["v1", "cards", "x"].
    var segments: [String]
    var rawPath: String
    var query: [String: String]
    /// Header names lowercased.
    var headers: [String: String]
    var body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    var wantsWebSocket: Bool {
        header("upgrade")?.lowercased() == "websocket"
            && (header("connection")?.lowercased().contains("upgrade") ?? false)
    }

    var keepAlive: Bool {
        !(header("connection")?.lowercased().contains("close") ?? false)
    }
}

enum RemoteHTTPError: Error {
    case closed
    case malformed(String)
    case tooLarge
}

/// An accepted TCP connection with a read buffer. Reads come from one task
/// at a time; sends may come from any thread and keep their call order.
final class RemoteConnection: @unchecked Sendable {
    let nw: NWConnection
    private var buffer = Data()
    private let queue: DispatchQueue
    private let closedLock = NSLock()
    private var isClosed = false

    static let maxHeaderBytes = 64 * 1024
    /// Room for `RemoteImage.maxCount` images of `RemoteImage.maxBytes`, base64 encoded.
    static let maxBodyBytes = 48 * 1024 * 1024

    init(_ nw: NWConnection) {
        self.nw = nw
        self.queue = DispatchQueue(label: "kanban.remote.conn")
    }

    func start() {
        nw.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.markClosed()
            default: break
            }
        }
        nw.start(queue: queue)
    }

    var closed: Bool {
        closedLock.withLock { isClosed }
    }

    private func markClosed() {
        closedLock.withLock { isClosed = true }
    }

    func cancel() {
        markClosed()
        nw.cancel()
    }

    // MARK: Reading

    /// Appends the next chunk to the buffer. False at end of stream.
    private func receiveMore() async throws -> Bool {
        let chunk: Data? = try await withCheckedThrowingContinuation { cont in
            nw.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    cont.resume(returning: data)
                } else if let error {
                    cont.resume(throwing: error)
                } else if isComplete {
                    cont.resume(returning: nil)
                } else {
                    cont.resume(returning: Data())
                }
            }
        }
        guard let chunk else { return false }
        buffer.append(chunk)
        return true
    }

    /// Exactly `count` bytes, waiting for more as needed.
    func read(exactly count: Int) async throws -> Data {
        while buffer.count < count {
            guard try await receiveMore() else { throw RemoteHTTPError.closed }
        }
        let out = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(out)
    }

    /// The next request, or nil when the client closed the connection
    /// between requests.
    func readRequest() async throws -> RemoteHTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        var headerEnd: Range<Data.Index>?
        while true {
            headerEnd = buffer.range(of: separator)
            if headerEnd != nil { break }
            if buffer.count > Self.maxHeaderBytes { throw RemoteHTTPError.tooLarge }
            guard try await receiveMore() else {
                if buffer.isEmpty { return nil }
                throw RemoteHTTPError.closed
            }
        }
        guard let headerEnd else { return nil }
        let headData = buffer[buffer.startIndex..<headerEnd.lowerBound]
        buffer.removeSubrange(buffer.startIndex..<headerEnd.upperBound)
        buffer = Data(buffer)
        guard let head = String(data: headData, encoding: .utf8) else {
            throw RemoteHTTPError.malformed("header is not UTF-8")
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count >= 2 else { throw RemoteHTTPError.malformed("bad request line") }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let target = String(requestLine[1])
        let components = URLComponents(string: "http://localhost" + (target.hasPrefix("/") ? target : "/" + target))
        let rawPath = components?.percentEncodedPath ?? target
        let segments = rawPath.split(separator: "/", omittingEmptySubsequences: true).map {
            String($0).removingPercentEncoding ?? String($0)
        }
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }
        var body = Data()
        if let lengthText = headers["content-length"] {
            guard let length = Int(lengthText), length >= 0 else { throw RemoteHTTPError.malformed("bad content-length") }
            guard length <= Self.maxBodyBytes else { throw RemoteHTTPError.tooLarge }
            body = try await read(exactly: length)
        } else if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            body = try await readChunkedBody()
        }
        return RemoteHTTPRequest(
            method: String(requestLine[0]).uppercased(),
            segments: segments,
            rawPath: rawPath,
            query: query,
            headers: headers,
            body: body
        )
    }

    private func readLine() async throws -> String {
        let crlf = Data("\r\n".utf8)
        while true {
            if let r = buffer.range(of: crlf) {
                let line = String(data: buffer[buffer.startIndex..<r.lowerBound], encoding: .utf8) ?? ""
                buffer.removeSubrange(buffer.startIndex..<r.upperBound)
                buffer = Data(buffer)
                return line
            }
            if buffer.count > Self.maxHeaderBytes { throw RemoteHTTPError.tooLarge }
            guard try await receiveMore() else { throw RemoteHTTPError.closed }
        }
    }

    private func readChunkedBody() async throws -> Data {
        var body = Data()
        while true {
            let sizeLine = try await readLine()
            let hex = sizeLine.split(separator: ";").first.map(String.init) ?? ""
            guard let size = Int(hex.trimmingCharacters(in: .whitespaces), radix: 16) else {
                throw RemoteHTTPError.malformed("bad chunk size")
            }
            if size == 0 {
                while try await readLine() != "" {}
                return body
            }
            body.append(try await read(exactly: size))
            guard body.count <= Self.maxBodyBytes else { throw RemoteHTTPError.tooLarge }
            _ = try await read(exactly: 2)
        }
    }

    // MARK: Writing

    /// Sends bytes; sends keep the order of the calls.
    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            nw.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    func sendDetached(_ data: Data) {
        nw.send(content: data, completion: .contentProcessed { _ in })
    }
}

/// An HTTP response ready to write.
struct RemoteHTTPResponse: Sendable {
    var status: Int
    var headers: [(String, String)] = []
    var body: Data = Data()

    static func json<T: Encodable>(_ value: T, status: Int = 200) -> RemoteHTTPResponse {
        let data = (try? JSONEncoder.remote.encode(value)) ?? Data("{}".utf8)
        return RemoteHTTPResponse(status: status, headers: [("Content-Type", "application/json; charset=utf-8")], body: data)
    }

    static func rawJSON(_ data: Data, status: Int = 200) -> RemoteHTTPResponse {
        RemoteHTTPResponse(status: status, headers: [("Content-Type", "application/json; charset=utf-8")], body: data)
    }

    static func error(_ status: Int, _ message: String) -> RemoteHTTPResponse {
        json(RemoteErrorBody(error: message), status: status)
    }

    static let noContent = RemoteHTTPResponse(status: 204)

    func serialized(keepAlive: Bool) -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        return out
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 101: "Switching Protocols"
        case 200: "OK"
        case 201: "Created"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 409: "Conflict"
        case 413: "Payload Too Large"
        case 426: "Upgrade Required"
        case 500: "Internal Server Error"
        default: "Status"
        }
    }
}

struct RemoteErrorBody: Codable, Sendable {
    var error: String
}

enum RemoteWebSocketHandshake {
    static let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    static func accept(key: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((key + guid).utf8))
        return Data(digest).base64EncodedString()
    }

    /// The 101 response for a valid upgrade request, nil when it is not one.
    static func response(for request: RemoteHTTPRequest) -> Data? {
        guard request.wantsWebSocket, let key = request.header("sec-websocket-key"), !key.isEmpty else { return nil }
        let head = "HTTP/1.1 101 Switching Protocols\r\n"
            + "Upgrade: websocket\r\n"
            + "Connection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(accept(key: key))\r\n\r\n"
        return Data(head.utf8)
    }
}
