#if canImport(FoundationNetworking)
import Foundation
import FoundationNetworking
import Glibc
import Synchronization

/// A WebSocket client for the server tests where URLSessionWebSocketTask has
/// no transport (swift-corelibs-foundation needs a libcurl built with
/// WebSockets). Same surface as the task the tests use on Apple platforms.
final class RawTestWebSocket: @unchecked Sendable {
    enum Message: Sendable {
        case string(String)
        case data(Data)
    }

    enum CloseCode {
        case normalClosure
        case goingAway
    }

    struct Closed: Error {}

    private struct Mailbox {
        var messages: [Message] = []
        var waiters: [UUID: CheckedContinuation<Message, Error>] = [:]
        var closed = false
    }

    private let fd: Int32
    private let mailbox = Mutex(Mailbox())
    private let sendLock = NSLock()
    private(set) var response: HTTPURLResponse?

    init(port: Int, path: String, token: String?) {
        fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port)).bigEndian
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            close(fd)
            finish()
            return
        }
        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        var head = "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
        head += "Sec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n"
        if let token { head += "Authorization: Bearer \(token)\r\n" }
        head += "\r\n"
        writeAll(Data(head.utf8))

        var buffer = Data()
        let separator = Data("\r\n\r\n".utf8)
        while buffer.range(of: separator) == nil {
            guard let chunk = readChunk() else {
                close(fd)
                finish()
                return
            }
            buffer.append(chunk)
        }
        let end = buffer.range(of: separator)!
        let statusLine = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
        let status = Int(statusLine.split(separator: " ").dropFirst().first ?? "") ?? 0
        response = HTTPURLResponse(url: URL(string: "ws://127.0.0.1:\(port)\(path)")!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)
        guard status == 101 else {
            close(fd)
            finish()
            return
        }
        let rest = Data(buffer[end.upperBound...])
        let reader = Thread { [self] in readLoop(initial: rest) }
        reader.start()
    }

    // MARK: Receiving

    func receive() async throws -> Message {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Message, Error>) in
                mailbox.withLock { box in
                    if !box.messages.isEmpty {
                        cont.resume(returning: box.messages.removeFirst())
                    } else if box.closed {
                        cont.resume(throwing: Closed())
                    } else if Task.isCancelled {
                        cont.resume(throwing: CancellationError())
                    } else {
                        box.waiters[id] = cont
                    }
                }
            }
        } onCancel: {
            let waiter = mailbox.withLock { $0.waiters.removeValue(forKey: id) }
            waiter?.resume(throwing: CancellationError())
        }
    }

    private func deliver(_ message: Message) {
        let waiter = mailbox.withLock { box -> CheckedContinuation<Message, Error>? in
            if let (id, cont) = box.waiters.first {
                box.waiters.removeValue(forKey: id)
                return cont
            }
            box.messages.append(message)
            return nil
        }
        waiter?.resume(returning: message)
    }

    private func finish() {
        let waiters = mailbox.withLock { box -> [CheckedContinuation<Message, Error>] in
            box.closed = true
            defer { box.waiters = [:] }
            return Array(box.waiters.values)
        }
        waiters.forEach { $0.resume(throwing: Closed()) }
    }

    private func readChunk() -> Data? {
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        let n = buf.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
        return n > 0 ? Data(buf[0..<n]) : nil
    }

    private func readLoop(initial: Data) {
        var buffer = initial
        var fragments = Data()
        var fragmentOpcode: UInt8 = 0
        func need(_ count: Int) -> Bool {
            while buffer.count < count {
                guard let chunk = readChunk() else { return false }
                buffer.append(chunk)
            }
            return true
        }
        while true {
            guard need(2) else { break }
            let b0 = buffer[buffer.startIndex], b1 = buffer[buffer.startIndex + 1]
            let fin = b0 & 0x80 != 0
            let opcode = b0 & 0x0F
            var length = Int(b1 & 0x7F)
            var offset = 2
            if length == 126 {
                guard need(4) else { break }
                length = Int(buffer[buffer.startIndex + 2]) << 8 | Int(buffer[buffer.startIndex + 3])
                offset = 4
            } else if length == 127 {
                guard need(10) else { break }
                length = (2..<10).reduce(0) { $0 << 8 | Int(buffer[buffer.startIndex + $1]) }
                offset = 10
            }
            guard need(offset + length) else { break }
            let payload = Data(buffer[(buffer.startIndex + offset)..<(buffer.startIndex + offset + length)])
            buffer = Data(buffer[(buffer.startIndex + offset + length)...])
            switch opcode {
            case 0x8:
                sendFrame(opcode: 0x8, payload: payload.prefix(2))
                finish()
                close(fd)
                return
            case 0x9:
                sendFrame(opcode: 0xA, payload: payload)
            case 0xA:
                break
            default:
                if opcode != 0 { fragmentOpcode = opcode }
                fragments.append(payload)
                if fin {
                    deliver(fragmentOpcode == 0x1 ? .string(String(decoding: fragments, as: UTF8.self)) : .data(fragments))
                    fragments = Data()
                }
            }
        }
        finish()
        close(fd)
    }

    // MARK: Sending

    func send(_ message: Message) async throws {
        guard !mailbox.withLock({ $0.closed }) else { throw Closed() }
        switch message {
        case .string(let s): sendFrame(opcode: 0x1, payload: Data(s.utf8))
        case .data(let d): sendFrame(opcode: 0x2, payload: d)
        }
    }

    func cancel(with code: CloseCode, reason: Data?) {
        sendFrame(opcode: 0x8, payload: Data([0x03, 0xE8]))
        shutdown(fd, Int32(SHUT_RDWR))
        finish()
    }

    private func sendFrame(opcode: UInt8, payload: Data) {
        var frame = Data([0x80 | opcode])
        if payload.count < 126 {
            frame.append(0x80 | UInt8(payload.count))
        } else if payload.count <= 0xFFFF {
            frame.append(0x80 | 126)
            frame.append(contentsOf: [UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)])
        } else {
            frame.append(0x80 | 127)
            frame.append(contentsOf: (0..<8).reversed().map { UInt8((payload.count >> ($0 * 8)) & 0xFF) })
        }
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        frame.append(contentsOf: mask)
        frame.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        sendLock.withLock { writeAll(frame) }
    }

    private func writeAll(_ data: Data) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Glibc.send(fd, raw.baseAddress! + offset, raw.count - offset, Int32(MSG_NOSIGNAL))
                if n <= 0 { return }
                offset += n
            }
        }
    }
}
#endif
