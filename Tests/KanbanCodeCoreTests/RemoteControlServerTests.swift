import Foundation
import KanbanCodeRemoteKit
import Testing

@testable import KanbanCodeCore

@Suite("Remote control server")
struct RemoteControlServerTests {

    @Test("health needs no token and reports the host")
    func health() async throws {
        let f = try await RemoteServerFixture()
        defer { f.shutdown() }
        let (status, data) = try await f.request("GET", "/v1/health")
        #expect(status == 200)
        let health = try JSONDecoder.remote.decode(RemoteHealth.self, from: data)
        #expect(health.hostName == "test-mac")
        #expect(health.apiVersion == RemoteAPI.version)
    }

    @Test("requests without a token or with an unknown one are refused with 401")
    func unauthorized() async throws {
        let f = try await RemoteServerFixture()
        defer { f.shutdown() }
        let (none, noneBody) = try await f.request("GET", "/v1/board")
        #expect(none == 401)
        #expect(try JSONDecoder().decode(RemoteError.self, from: noneBody).error.isEmpty == false)
        let (bad, _) = try await f.request("GET", "/v1/board", token: "kc_nope")
        #expect(bad == 401)
    }

    @Test("a revoked token is refused on its next request")
    func revokedToken() async throws {
        let f = try await RemoteServerFixture()
        defer { f.shutdown() }
        let (ok, _) = try await f.request("GET", "/v1/me", token: f.fullToken)
        #expect(ok == 200)
        try f.devices.revoke(id: f.fullDevice.id)
        let (refused, _) = try await f.request("GET", "/v1/me", token: f.fullToken)
        #expect(refused == 401)
    }

    @Test("the token may come as a query parameter")
    func queryToken() async throws {
        let f = try await RemoteServerFixture()
        defer { f.shutdown() }
        let (status, data) = try await f.request("GET", "/v1/me?token=\(f.agentToken)")
        #expect(status == 200)
        #expect(try JSONDecoder.remote.decode(RemoteDevice.self, from: data).scope == .agent)
    }

    @Test("board, card and unknown card")
    func board() async throws {
        let f = try await RemoteServerFixture()
        defer { f.shutdown() }
        let (status, data) = try await f.request("GET", "/v1/board", token: f.agentToken)
        #expect(status == 200)
        let board = try JSONDecoder.remote.decode(RemoteBoard.self, from: data)
        #expect(board.cards.map(\.id) == ["card_live", "card_idle"])
        #expect(board.projects.first?.name == "acme")

        let (cardStatus, cardData) = try await f.request("GET", "/v1/cards/card_live", token: f.agentToken)
        #expect(cardStatus == 200)
        #expect(try JSONDecoder.remote.decode(RemoteCard.self, from: cardData).title == "Fix the flaky test")

        let (missing, _) = try await f.request("GET", "/v1/cards/nope", token: f.agentToken)
        #expect(missing == 404)
        let (unknownRoute, _) = try await f.request("GET", "/v1/nothing", token: f.agentToken)
        #expect(unknownRoute == 404)
        let (wrongMethod, _) = try await f.request("DELETE", "/v1/board", token: f.agentToken)
        #expect(wrongMethod == 405)
    }

    @Test("the board is the working set unless all=1")
    func boardWorkingSet() async throws {
        let host = FakeRemoteHost(cards: FakeRemoteHost.defaultCards + [
            RemoteCard(id: "card_archived", title: "old", column: .inProgress, archived: true, updatedAt: Date()),
            RemoteCard(id: "card_session", title: "session", column: .allSessions, updatedAt: Date()),
        ])
        let f = try await RemoteServerFixture(host: host)
        defer { f.shutdown() }
        let (_, data) = try await f.request("GET", "/v1/board", token: f.agentToken)
        #expect(try JSONDecoder.remote.decode(RemoteBoard.self, from: data).cards.map(\.id) == ["card_live", "card_idle"])
        let (_, allData) = try await f.request("GET", "/v1/board?all=1", token: f.agentToken)
        #expect(try JSONDecoder.remote.decode(RemoteBoard.self, from: allData).cards.count == 4)
    }

    @Test("big responses are gzipped for clients that accept it")
    func gzip() async throws {
        let many = (0..<300).map { i in
            RemoteCard(id: "card_\(i)", title: "Card number \(i) with a title", column: .inProgress,
                       projectPath: "/Users/me/Projects/acme", updatedAt: Date())
        }
        let f = try await RemoteServerFixture(host: FakeRemoteHost(cards: many))
        defer { f.shutdown() }
        var req = URLRequest(url: URL(string: f.base + "/v1/board")!)
        req.setValue("Bearer \(f.agentToken)", forHTTPHeaderField: "Authorization")
        req.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")
        let (data, response) = try await f.session.data(for: req)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.value(forHTTPHeaderField: "Content-Encoding") == "gzip")
        #expect(try JSONDecoder.remote.decode(RemoteBoard.self, from: data).cards.count == 300)

        // A small body goes out as it is.
        var small = URLRequest(url: URL(string: f.base + "/v1/me")!)
        small.setValue("Bearer \(f.agentToken)", forHTTPHeaderField: "Authorization")
        let (_, smallResponse) = try await f.session.data(for: small)
        #expect((smallResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Encoding") == nil)
    }

    @Test("gzip output is a valid gzip stream")
    func gzipFormat() throws {
        let text = String(repeating: "kanban code remote control ", count: 2000)
        let gz = try #require(RemoteGzip.compress(Data(text.utf8)))
        #expect(gz.count < text.utf8.count / 5)
        let dir = NSTemporaryDirectory() + "gzip-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try gz.write(to: URL(fileURLWithPath: dir + "/x.gz"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-dc", dir + "/x.gz"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(String(decoding: out, as: UTF8.self) == text)
        #expect(RemoteGzip.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test("transcript pages with limit and cursor")
    func transcript() async throws {
        let f = try await RemoteServerFixture()
        defer { f.shutdown() }
        let (status, data) = try await f.request("GET", "/v1/cards/card_live/transcript?limit=4", token: f.agentToken)
        #expect(status == 200)
        let page = try JSONDecoder.remote.decode(RemoteTranscript.self, from: data)
        #expect(page.messages.map(\.id) == ["m6", "m7", "m8", "m9"])
        let cursor = try #require(page.olderCursor)
        let (_, olderData) = try await f.request("GET", "/v1/cards/card_live/transcript?limit=4&before=\(cursor)", token: f.agentToken)
        let older = try JSONDecoder.remote.decode(RemoteTranscript.self, from: olderData)
        #expect(older.messages.map(\.id) == ["m2", "m3", "m4", "m5"])
    }

    @Test("creating a task returns 201 with the card; an unknown project is a 400")
    func tasks() async throws {
        let f = try await RemoteServerFixture()
        defer { f.shutdown() }
        let body = try JSONEncoder.remote.encode(RemoteTaskRequest(project: "acme", prompt: "fix it", worktree: ""))
        let (status, data) = try await f.request("POST", "/v1/tasks", token: f.agentToken, body: body)
        #expect(status == 201)
        let card = try JSONDecoder.remote.decode(RemoteCard.self, from: data)
        #expect(card.title == "fix it")
        #expect(f.host.state.withLock { $0.tasks.first?.worktree } == "")

        let bad = try JSONEncoder.remote.encode(RemoteTaskRequest(project: "zzz", prompt: "x"))
        let (badStatus, badData) = try await f.request("POST", "/v1/tasks", token: f.agentToken, body: bad)
        #expect(badStatus == 400)
        #expect(try JSONDecoder().decode(RemoteError.self, from: badData).error.contains("known: acme"))

        let (garbage, _) = try await f.request("POST", "/v1/tasks", token: f.agentToken, body: Data("{".utf8))
        #expect(garbage == 400)
    }

    @Test("prompt, interrupt and resume reach the host")
    func promptInterruptResume() async throws {
        let f = try await RemoteServerFixture()
        defer { f.shutdown() }
        let prompt = try JSONEncoder.remote.encode(RemotePromptRequest(text: "also run the tests", mode: .queue))
        let (status, _) = try await f.request("POST", "/v1/cards/card_live/prompt", token: f.agentToken, body: prompt)
        #expect(status == 204)
        #expect(f.host.state.withLock { $0.prompts.first?.request.text } == "also run the tests")

        let (conflict, _) = try await f.request("POST", "/v1/cards/card_idle/prompt", token: f.agentToken, body: prompt)
        #expect(conflict == 409)

        let (empty, _) = try await f.request("POST", "/v1/cards/card_live/prompt", token: f.agentToken, body: Data(#"{"text":"  "}"#.utf8))
        #expect(empty == 400)

        let (interrupt, _) = try await f.request("POST", "/v1/cards/card_live/interrupt", token: f.agentToken)
        #expect(interrupt == 204)
        #expect(f.host.state.withLock { $0.interrupts } == ["card_live"])

        let (resume, resumeData) = try await f.request("POST", "/v1/cards/card_idle/resume", token: f.agentToken)
        #expect(resume == 200)
        #expect(try JSONDecoder.remote.decode(RemoteCard.self, from: resumeData).isLive)
    }

    @Test("keep-alive serves several requests on one connection")
    func keepAlive() async throws {
        let f = try await RemoteServerFixture()
        defer { f.shutdown() }
        for _ in 0..<5 {
            let (status, _) = try await f.request("GET", "/v1/board", token: f.agentToken)
            #expect(status == 200)
        }
    }

    @Test("openapi document is valid JSON")
    func openAPI() async throws {
        let f = try await RemoteServerFixture()
        defer { f.shutdown() }
        let (status, data) = try await f.request("GET", "/.well-known/openapi.json")
        #expect(status == 200)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["openapi"] as? String == "3.1.0")
        let paths = try #require(json["paths"] as? [String: Any])
        #expect(paths["/v1/tasks"] != nil)
    }

    @Test("events: the board on connect, a new board after a change, and pings")
    func events() async throws {
        let f = try await RemoteServerFixture()
        defer { f.shutdown() }
        let ws = f.webSocket("/v1/events", token: f.agentToken)
        defer { ws.cancel(with: .normalClosure, reason: nil) }

        let first = try decodeEvent(try await withTimeout(5) { try await ws.receive() })
        #expect(first.type == .board)
        #expect(first.board?.cards.count == 2)

        f.host.mutate { cards in cards[0].column = .waiting }
        var sawChange = false
        var sawPing = false
        let deadline = Date().addingTimeInterval(5)
        while (!sawChange || !sawPing) && Date() < deadline {
            let event = try decodeEvent(try await withTimeout(5) { try await ws.receive() })
            if event.type == .ping { sawPing = true }
            if event.type == .cards {
                #expect(event.upserted?.map(\.id) == ["card_live"])
                #expect(event.removed == [])
                if event.upserted?.first?.column == .waiting { sawChange = true }
            }
        }
        #expect(sawChange)
        #expect(sawPing)
    }

    @Test("events: a card leaving the working set is removed, resync sends the whole board")
    func eventsRemovedAndResync() async throws {
        let f = try await RemoteServerFixture()
        defer { f.shutdown() }
        let ws = f.webSocket("/v1/events", token: f.agentToken)
        defer { ws.cancel(with: .normalClosure, reason: nil) }
        var board: RemoteBoard?
        try decodeEvent(try await withTimeout(5) { try await ws.receive() }).apply(to: &board)
        #expect(board?.cards.count == 2)

        f.host.mutate { cards in cards[1].archived = true }
        var event = try decodeEvent(try await withTimeout(5) { try await ws.receive() })
        while event.type == .ping { event = try decodeEvent(try await withTimeout(5) { try await ws.receive() }) }
        #expect(event.type == .cards)
        #expect(event.removed == ["card_idle"])
        #expect(event.upserted == [])
        event.apply(to: &board)
        #expect(board?.cards.map(\.id) == ["card_live"])

        try await ws.send(.string(#"{"type":"resync"}"#))
        event = try decodeEvent(try await withTimeout(5) { try await ws.receive() })
        while event.type == .ping { event = try decodeEvent(try await withTimeout(5) { try await ws.receive() }) }
        #expect(event.type == .board)
        #expect(event.board?.cards.map(\.id) == ["card_live"])
    }

    @Test("events with all=1 keeps archived cards")
    func eventsAll() async throws {
        let f = try await RemoteServerFixture()
        defer { f.shutdown() }
        f.host.mutate { cards in cards[1].archived = true }
        let ws = f.webSocket("/v1/events?all=1", token: f.agentToken)
        defer { ws.cancel(with: .normalClosure, reason: nil) }
        let first = try decodeEvent(try await withTimeout(5) { try await ws.receive() })
        #expect(first.board?.cards.count == 2)
    }

    @Test("events pushes at most once per push interval")
    func eventsThrottle() async throws {
        let f = try await RemoteServerFixture()
        defer { f.shutdown() }
        let ws = f.webSocket("/v1/events", token: f.agentToken)
        defer { ws.cancel(with: .normalClosure, reason: nil) }
        _ = try await withTimeout(5) { try await ws.receive() }
        let start = Date()
        for i in 0..<20 {
            f.host.mutate { cards in cards[0].title = "t\(i)" }
            try await Task.sleep(for: .milliseconds(20))
        }
        var boards: [Date] = []
        while Date().timeIntervalSince(start) < 1.2 {
            guard let message = try? await withTimeout(0.5, { try await ws.receive() }) else { break }
            if try decodeEvent(message).type == .cards { boards.append(Date()) }
        }
        // 20 changes over ~0.4 s with a 0.2 s interval: a handful of pushes, never 20.
        #expect(boards.count >= 1)
        #expect(boards.count <= 5)
    }

    @Test("an agent token cannot open a terminal")
    func agentTerminal() async throws {
        let f = try await RemoteServerFixture()
        defer { f.shutdown() }
        let (status, data) = try await f.request("GET", "/v1/cards/card_live/terminal", token: f.agentToken)
        #expect(status == 403)
        #expect(try JSONDecoder().decode(RemoteError.self, from: data).error.contains("agent"))

        let ws = f.webSocket("/v1/cards/card_live/terminal", token: f.agentToken)
        await #expect(throws: (any Error).self) { _ = try await withTimeout(5) { try await ws.receive() } }
        #expect((ws.response as? HTTPURLResponse)?.statusCode == 403)
    }

    @Test("terminal: bytes both ways, resize reaches the pty, the primary session by default")
    func terminal() async throws {
        let host = FakeRemoteHost()
        host.setTerminalCommand([
            "/bin/sh", "-c",
            #"stty -echo; printf ready; while IFS= read -r line; do if [ "$line" = size ]; then echo "size:$(stty size)"; else echo "got:$line"; fi; done"#,
        ])
        let f = try await RemoteServerFixture(host: host)
        defer { f.shutdown() }
        let ws = f.webSocket("/v1/cards/card_live/terminal?cols=90&rows=30", token: f.fullToken)
        defer { ws.cancel(with: .normalClosure, reason: nil) }
        let output = TerminalOutput(ws)

        try await output.waitFor("ready")
        try await ws.send(.data(Data("size\n".utf8)))
        try await output.waitFor("size:30 90")
        try await ws.send(.data(Data("hello\n".utf8)))
        try await output.waitFor("got:hello")
        try await ws.send(.string(#"{"type":"resize","cols":120,"rows":40}"#))
        try await Task.sleep(for: .milliseconds(100))
        try await ws.send(.data(Data("size\n".utf8)))
        try await output.waitFor("size:40 120")
        #expect(host.state.withLock { $0.terminalRequests.first?.session } == "acme-card_live")
    }

    @Test("terminal: a big output arrives whole")
    func terminalBigOutput() async throws {
        let host = FakeRemoteHost()
        host.setTerminalCommand(["/bin/sh", "-c", #"stty -echo; head -c 300000 /dev/zero | tr '\000' x; printf END; cat"#])
        let f = try await RemoteServerFixture(host: host)
        defer { f.shutdown() }
        let ws = f.webSocket("/v1/cards/card_live/terminal", token: f.fullToken)
        defer { ws.cancel(with: .normalClosure, reason: nil) }
        let output = TerminalOutput(ws)
        try await output.waitFor("END", timeout: 10)
        #expect(output.text.filter { $0 == "x" }.count == 300_000)
    }

    @Test("terminal: closing the socket kills the process; the process exiting closes the socket")
    func terminalLifecycle() async throws {
        let host = FakeRemoteHost()
        let marker = "remote-test-\(UUID().uuidString.prefix(8))"
        host.setTerminalCommand(["/bin/sh", "-c", "printf 'pid:%s;' $$; exec sleep 300 # \(marker)"])
        let f = try await RemoteServerFixture(host: host)
        defer { f.shutdown() }
        let ws = f.webSocket("/v1/cards/card_live/terminal", token: f.fullToken)
        let output = TerminalOutput(ws)
        try await output.waitFor(";")
        let pidText = output.text.components(separatedBy: "pid:").last?.components(separatedBy: ";").first ?? ""
        let pid = try #require(Int32(pidText))
        #expect(kill(pid, 0) == 0)
        ws.cancel(with: .normalClosure, reason: nil)
        let deadline = Date().addingTimeInterval(5)
        while kill(pid, 0) == 0 && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(kill(pid, 0) != 0)

        host.setTerminalCommand(["/bin/sh", "-c", "printf bye"])
        let ws2 = f.webSocket("/v1/cards/card_live/terminal", token: f.fullToken)
        let output2 = TerminalOutput(ws2)
        try await output2.waitFor("bye")
        try await output2.waitForClose()
    }

    @Test("revoking a device closes its open sockets")
    func revokeClosesSockets() async throws {
        let host = FakeRemoteHost()
        host.setTerminalCommand(["/bin/sh", "-c", "printf ready; exec cat"])
        let f = try await RemoteServerFixture(host: host)
        defer { f.shutdown() }
        let events = f.webSocket("/v1/events", token: f.fullToken)
        _ = try await withTimeout(5) { try await events.receive() }
        let term = f.webSocket("/v1/cards/card_live/terminal", token: f.fullToken)
        let output = TerminalOutput(term)
        try await output.waitFor("ready")

        // Another process (the CLI) rewrites the file: the server notices.
        let other = RemoteDeviceStore(path: f.devices.path)
        try other.revoke(id: f.fullDevice.id)

        try await output.waitForClose()
        let closed = try await withTimeout(5) { () -> Bool in
            while true {
                do { _ = try await events.receive() } catch { return true }
            }
        }
        #expect(closed)
        let (status, _) = try await f.request("GET", "/v1/me", token: f.fullToken)
        #expect(status == 401)
    }

    @Test("stop closes the listener")
    func stop() async throws {
        let f = try await RemoteServerFixture()
        let port = f.server.port
        f.server.stop()
        defer { f.shutdown() }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/health")!)
        req.timeoutInterval = 2
        await #expect(throws: (any Error).self) { _ = try await f.session.data(for: req) }
    }
}

/// Collects a terminal socket's bytes in the background.
final class TerminalOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var closed = false

    init(_ ws: URLSessionWebSocketTask) {
        Task { [self] in
            while true {
                do {
                    let message = try await ws.receive()
                    lock.withLock {
                        switch message {
                        case .data(let d): buffer.append(d)
                        case .string(let s): buffer.append(Data(s.utf8))
                        @unknown default: break
                        }
                    }
                } catch {
                    lock.withLock { closed = true }
                    return
                }
            }
        }
    }

    var text: String { lock.withLock { String(decoding: buffer, as: UTF8.self) } }
    var isClosed: Bool { lock.withLock { closed } }

    func waitFor(_ needle: String, timeout: Double = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !text.contains(needle) {
            guard Date() < deadline else {
                Issue.record("timed out waiting for \(needle); got \(text.suffix(200).debugDescription)")
                throw TimeoutError()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func waitForClose(timeout: Double = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !isClosed {
            guard Date() < deadline else {
                Issue.record("socket did not close")
                throw TimeoutError()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
