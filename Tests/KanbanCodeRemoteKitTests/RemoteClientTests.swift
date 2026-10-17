import Testing
import Foundation
@testable import KanbanCodeRemoteKit

@Suite("remote pair links")
struct RemotePairLinkTests {
    @Test("A link from the Mac's QR code parses")
    func parses() throws {
        let link = try #require(RemotePairLink.parse(
            "kanbancode://pair?url=http%3A%2F%2F100.101.1.2%3A7780&token=kc_abc123&name=Studio"))
        #expect(link.baseURL.absoluteString == "http://100.101.1.2:7780")
        #expect(link.token == "kc_abc123")
        #expect(link.name == "Studio")
    }

    @Test("Unencoded urls, whitespace and a trailing slash are tolerated")
    func tolerant() throws {
        let link = try #require(RemotePairLink.parse(
            "  kanbancode://pair?url=https://mac.tail1.ts.net:7780/&token=kc_x \n"))
        #expect(link.baseURL.absoluteString == "https://mac.tail1.ts.net:7780")
        #expect(link.name == nil)
    }

    @Test("Wrong scheme, missing token or a non-http url are refused")
    func refuses() {
        #expect(RemotePairLink.parse("https://pair?url=http://a:1&token=t") == nil)
        #expect(RemotePairLink.parse("kanbancode://pair?url=http://a:1") == nil)
        #expect(RemotePairLink.parse("kanbancode://pair?url=ftp://a&token=t") == nil)
        #expect(RemotePairLink.parse("kanbancode://open?url=http://a:1&token=t") == nil)
        #expect(RemotePairLink.parse("") == nil)
    }

    @Test("A link survives a round trip, + in the token included")
    func roundTrip() throws {
        let link = RemotePairLink(baseURL: URL(string: "http://127.0.0.1:7780")!, token: "kc_a+b&c", name: "My Mac")
        let back = try #require(RemotePairLink.parse(link.url.absoluteString))
        #expect(back == link)
    }

    @Test("Bare host and port read as http")
    func bareHost() {
        #expect(RemoteServerURL.normalize("100.64.0.1:7780")?.absoluteString == "http://100.64.0.1:7780")
        #expect(RemoteServerURL.normalize("not a url with spaces") == nil)
    }
}

@Suite("remote client requests")
struct RemoteClientRequestTests {
    let client = RemoteClient(baseURL: URL(string: "http://127.0.0.1:7780")!, token: "kc_t")

    @Test("Requests carry the bearer token, except health")
    func auth() {
        let board = client.makeRequest("GET", "v1/board")
        #expect(board.url?.absoluteString == "http://127.0.0.1:7780/v1/board")
        #expect(board.value(forHTTPHeaderField: "Authorization") == "Bearer kc_t")
        #expect(client.makeRequest("GET", "v1/health", authorized: false)
            .value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("A base url with a path keeps it")
    func basePath() {
        let c = RemoteClient(baseURL: URL(string: "https://mac.ts.net/kanban/")!, token: "t")
        #expect(c.url("v1/board").absoluteString == "https://mac.ts.net/kanban/v1/board")
        #expect(c.webSocketURL("v1/events").absoluteString == "wss://mac.ts.net/kanban/v1/events")
    }

    @Test("Card ids are escaped and queries encoded")
    func escaping() {
        let url = client.url("v1/cards/\(RemoteClient.escape("a/b c"))/transcript",
                             query: [URLQueryItem(name: "limit", value: "50"), URLQueryItem(name: "before", value: "x&y")])
        #expect(url.absoluteString == "http://127.0.0.1:7780/v1/cards/a%2Fb%20c/transcript?limit=50&before=x%26y")
    }

    @Test("Prompt bodies are JSON with the mode")
    func promptBody() throws {
        let req = client.makeRequest("POST", "v1/cards/c1/prompt", body: RemotePromptRequest(text: "hi", mode: .now))
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try JSONDecoder.remote.decode(RemotePromptRequest.self, from: try #require(req.httpBody))
        #expect(body == RemotePromptRequest(text: "hi", mode: .now))
    }

    @Test("Terminal sockets use ws and pass session and size")
    func terminalURL() {
        let url = client.webSocketURL("v1/cards/c1/terminal", query: [
            URLQueryItem(name: "session", value: "card-1"),
            URLQueryItem(name: "cols", value: "80"), URLQueryItem(name: "rows", value: "24"),
        ])
        #expect(url.absoluteString == "ws://127.0.0.1:7780/v1/cards/c1/terminal?session=card-1&cols=80&rows=24")
    }

    @Test("all=1 reaches the board and the events socket")
    func allCards() {
        #expect(client.webSocketURL("v1/events", query: [URLQueryItem(name: "all", value: "1")]).absoluteString
            == "ws://127.0.0.1:7780/v1/events?all=1")
        #expect(RemoteClient.resyncFrame == #"{"type":"resync"}"#)
    }

    @Test("Error bodies map to typed errors")
    func errors() {
        let body = Data(#"{"error":"scope agent cannot open terminals"}"#.utf8)
        #expect(RemoteClientError.from(status: 403, body: body) == .forbidden("scope agent cannot open terminals"))
        #expect(RemoteClientError.from(status: 401, body: Data()) == .unauthorized(""))
        #expect(RemoteClientError.from(status: 409, body: body).isAuthFailure == false)
        #expect(RemoteClientError.from(status: 500, body: Data("boom".utf8)) == .server(status: 500, message: "boom"))
    }
}

@Suite("remote events reconnect")
struct RemoteReconnectDelayTests {
    @Test("the wait between reconnects doubles from 1 s and stops at 5 s")
    func delaysCapAtFiveSeconds() {
        var delay: TimeInterval = 1
        var waits: [TimeInterval] = [delay]
        for _ in 0..<5 {
            delay = RemoteClient.nextReconnectDelay(after: delay)
            waits.append(delay)
        }
        #expect(waits == [1, 2, 4, 5, 5, 5])
    }
}

@Suite("remote reachability")
struct RemoteReachabilityTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test("one failure does not make a master offline; failures spanning the grace do")
    func offlineOnlyAfterGrace() {
        var reach = RemoteReachability(grace: 45)
        #expect(!reach.isOffline(at: t0))
        reach.failed(at: t0)
        #expect(!reach.isOffline(at: t0))
        reach.failed(at: t0.addingTimeInterval(30))
        #expect(!reach.isOffline(at: t0.addingTimeInterval(44)))
        #expect(reach.isOffline(at: t0.addingTimeInterval(45)))
        #expect(reach.offlineAt == t0.addingTimeInterval(45))
    }

    @Test("an answer starts the grace over")
    func answerResets() {
        var reach = RemoteReachability(grace: 45)
        reach.failed(at: t0)
        reach.answered()
        #expect(reach.failingSince == nil && reach.offlineAt == nil)
        reach.failed(at: t0.addingTimeInterval(40))
        #expect(!reach.isOffline(at: t0.addingTimeInterval(60)))
        #expect(reach.isOffline(at: t0.addingTimeInterval(85)))
    }

    @Test("the events socket outlasts a late ping, and the grace outlasts a reconnect round")
    func timingsLeaveRoom() {
        let masterPingInterval: TimeInterval = 20
        #expect(RemoteClient.eventsIdleTimeout >= masterPingInterval * 2)
        #expect(RemoteReachability.defaultGrace > RemoteClient.maxReconnectDelay * 4)
        #expect(RemoteClient(baseURL: URL(string: "http://h:7780")!, token: "t")
            .webSocketRequest(URL(string: "ws://h:7780/v1/cards/c/terminal")!).timeoutInterval == 30)
    }
}
