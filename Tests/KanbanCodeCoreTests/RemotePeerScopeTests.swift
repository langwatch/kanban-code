import Foundation
import KanbanCodeRemoteKit
import Testing

@testable import KanbanCodeCore

@Suite("Peer and terminal scopes")
struct RemotePeerScopeTests {
    /// Every call a master makes on its peer: PeerSync, AgentSync, the
    /// vault replica and token check, attention mirroring, channels, the
    /// scrubber, and what MasterEngine forwards for a card the peer owns.
    static let peerCalls: [(String, [String])] = [
        ("GET", ["me"]), ("GET", ["board"]), ("GET", ["machines"]), ("GET", ["events"]),
        ("GET", ["links"]), ("POST", ["links", "changed"]), ("GET", ["peers"]),
        ("GET", ["sync", "state"]), ("GET", ["sync", "file"]), ("POST", ["sync", "changed"]), ("POST", ["optmem", "run"]),
        ("POST", ["cli"]), ("GET", ["channels", "files"]), ("GET", ["channels", "files", "general", "log.jsonl"]),
        ("PUT", ["channels", "files", "general", "log.jsonl"]),
        ("GET", ["attention"]), ("POST", ["attention", "presence"]), ("POST", ["attention", "att_1", "resolve"]),
        ("GET", ["vault", "replica"]), ("POST", ["vault", "replica"]), ("POST", ["vault", "card-token"]),
        ("GET", ["vault", "audit", "hashes"]), ("GET", ["vault", "audit", "mirror"]), ("POST", ["vault", "audit", "mirror"]),
        ("GET", ["scrub", "status"]), ("GET", ["scrub", "index"]), ("POST", ["scrub", "run"]), ("PUT", ["scrub", "schedule"]),
        ("POST", ["tasks"]), ("GET", ["cards", "c1"]), ("PATCH", ["cards", "c1"]), ("DELETE", ["cards", "c1"]),
        ("GET", ["cards", "c1", "transcript"]), ("GET", ["cards", "c1", "transcript", "raw"]),
        ("GET", ["cards", "c1", "handover"]), ("POST", ["cards", "c1", "prompt"]),
        ("POST", ["cards", "c1", "interrupt"]), ("POST", ["cards", "c1", "resume"]), ("POST", ["cards", "c1", "move"]),
        ("POST", ["cards", "c1", "worktree", "remove"]), ("POST", ["cards", "c1", "discover"]),
        ("POST", ["cards", "c1", "queue", "p1"]), ("PATCH", ["cards", "c1", "queue", "p1"]),
        ("DELETE", ["cards", "c1", "queue", "p1"]),
        ("POST", ["cards", "c1", "side-chat"]), ("GET", ["cards", "c1", "side-chat", "r1"]),
        ("DELETE", ["cards", "c1", "side-chat", "r1"]),
    ]

    @Test("a peer token may make every call pairing uses")
    func peerAllowed() {
        for (method, rest) in Self.peerCalls {
            #expect(RemoteScopePolicy.refusal(scope: .peer, method: method, rest: rest) == nil, "\(method) \(rest)")
        }
    }

    @Test("a peer token is refused terminals, secrets and any route not listed")
    func peerRefused() {
        let refused: [(String, [String])] = [
            ("POST", ["scrub", "restore"]),
            ("GET", ["cards", "c1", "terminal"]),
            ("POST", ["vault", "release"]), ("POST", ["vault", "aws"]), ("POST", ["vault", "request"]),
            ("GET", ["vault", "secrets"]), ("POST", ["vault", "secrets"]), ("PATCH", ["vault", "secrets", "X"]),
            ("DELETE", ["vault", "secrets", "X"]), ("POST", ["vault", "delete"]), ("POST", ["vault", "rename"]),
            ("GET", ["vault", "log"]), ("GET", ["vault", "pending", "p1"]), ("POST", ["vault", "owner", "enrol"]),
            ("POST", ["exec"]), ("POST", ["shell"]), ("GET", ["cards", "c1", "anything-new"]),
        ]
        for (method, rest) in refused {
            #expect(RemoteScopePolicy.refusal(scope: .peer, method: method, rest: rest) != nil, "\(method) \(rest)")
        }
        #expect(RemoteScopePolicy.refusal(scope: .peer, method: "GET", rest: ["cards", "c1", "terminal"])
            == "the peer scope cannot open terminals")
    }

    @Test("a terminal token opens terminals and nothing that changes a card")
    func terminalScope() {
        #expect(RemoteScopePolicy.refusal(scope: .terminal, method: "GET", rest: ["cards", "c1", "terminal"]) == nil)
        #expect(RemoteScopePolicy.refusal(scope: .terminal, method: "GET", rest: ["board"]) == nil)
        for (method, rest) in Self.peerCalls where !["me", "board"].contains(rest[0]) && !(method == "GET" && rest == ["cards", "c1"]) {
            #expect(RemoteScopePolicy.refusal(scope: .terminal, method: method, rest: rest) != nil, "\(method) \(rest)")
        }
    }

    @Test("full and agent scopes are not narrowed by the lists")
    func otherScopes() {
        #expect(RemoteScopePolicy.refusal(scope: .full, method: "GET", rest: ["cards", "c1", "terminal"]) == nil)
        #expect(RemoteScopePolicy.refusal(scope: .agent, method: "POST", rest: ["tasks"]) == nil)
    }

    @Test("the server serves a peer what it forwards and refuses it a terminal")
    func serverPeer() async throws {
        let f = try await RemoteServerFixture()
        defer { f.shutdown() }
        let peer = try f.devices.add(name: "box", scope: .peer).token

        #expect(try await f.request("GET", "/v1/board", token: peer).0 == 200)
        let prompt = Data(#"{"text":"also run the tests","mode":"queue"}"#.utf8)
        #expect(try await f.request("POST", "/v1/cards/card_live/prompt", token: peer, body: prompt).0 == 204)
        // What a master forwards is what the human typed there: not marked as another sender's.
        #expect(f.host.state.withLock { $0.prompts.first?.request.text } == "also run the tests")
        // Past the scope check: the body is what is refused.
        #expect(try await f.request("POST", "/v1/attention/presence", token: peer, body: Data("{}".utf8)).0 == 400)
        #expect(try await f.request("POST", "/v1/attention/att_1/resolve", token: peer, body: Data("{}".utf8)).0 == 400)
        #expect(try await f.request("POST", "/v1/cards/card_live/interrupt", token: peer).0 == 204)

        let (terminal, body) = try await f.request("GET", "/v1/cards/card_live/terminal", token: peer)
        #expect(terminal == 403)
        #expect(String(decoding: body, as: UTF8.self).contains("cannot open terminals"))
        #expect(try await f.request("GET", "/v1/vault/secrets", token: peer).0 == 403)
        #expect(try await f.request("POST", "/v1/vault/release", token: peer, body: Data("{}".utf8)).0 == 403)
    }

    @Test("the server lets a terminal token reach the terminal route only")
    func serverTerminal() async throws {
        let f = try await RemoteServerFixture()
        defer { f.shutdown() }
        let terminal = try f.devices.add(name: "mac terminals", scope: .terminal).token
        // Past the scope check: the route then asks for the WebSocket upgrade.
        #expect(try await f.request("GET", "/v1/cards/card_live/terminal", token: terminal).0 == 426)
        #expect(try await f.request("GET", "/v1/board", token: terminal).0 == 200)
        let prompt = Data(#"{"text":"hello","mode":"queue"}"#.utf8)
        #expect(try await f.request("POST", "/v1/cards/card_live/prompt", token: terminal, body: prompt).0 == 403)
        #expect(try await f.request("POST", "/v1/cards/card_live/interrupt", token: terminal).0 == 403)
        #expect(f.host.state.withLock { $0.prompts.isEmpty })
    }
}
