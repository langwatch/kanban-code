import Foundation
import KanbanCodeRemoteKit
import Testing

@testable import KanbanCodeCore

@Suite("Remote card search")
struct RemoteCardSearchTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func card(_ id: String, _ title: String, _ column: RemoteColumn = .waiting, archived: Bool = false,
                     parent: String? = nil, minutesAgo: Double = 0, machineId: String? = nil) -> RemoteCard {
        RemoteCard(id: id, title: title, column: column, parentCardId: parent, archived: archived,
                   lastActivity: t0.addingTimeInterval(-minutesAgo * 60), updatedAt: t0, machineId: machineId)
    }

    static let cards: [RemoteCard] = [
        card("live", "Export report", .inProgress, minutesAgo: 1),
        card("arch", "Export invoices to Parquet", .allSessions, archived: true, minutesAgo: 900),
        card("sub", "Export helper", .allSessions, archived: true, parent: "arch", minutesAgo: 950),
        card("sessions", "export scratch", .allSessions, minutesAgo: 800),
    ] + (0..<32).map { card("done\($0)", "Export batch \($0)", .done, minutesAgo: Double(100 + $0)) }

    @Test("scope all searches every card, older only the ones outside the working set, archived the archive")
    func scopes() {
        let all = RemoteCardSearch.search(Self.cards, RemoteCardSearchRequest(query: "export", limit: 200))
        #expect(all.cards.count == 36)
        #expect(all.cards.first?.id == "live")
        #expect(!all.truncated)

        let older = RemoteCardSearch.search(Self.cards, RemoteCardSearchRequest(query: "export", scope: .older))
        #expect(older.cards.map(\.id) == ["done30", "done31", "sessions", "arch", "sub"])

        let archived = RemoteCardSearch.search(Self.cards, RemoteCardSearchRequest(query: "", scope: .archived))
        #expect(archived.cards.map(\.id) == ["arch"])

        let cut = RemoteCardSearch.search(Self.cards, RemoteCardSearchRequest(query: "export", limit: 5))
        #expect(cut.cards.count == 5)
        #expect(cut.truncated)
        #expect(RemoteCardSearchRequest(query: "x", limit: 5000).limit == CardSearch.maxLimit)
        #expect(RemoteCardSearchRequest(query: "x", limit: 0).limit == 1)
    }

    @Test("the working set ids are the ones the board filter keeps")
    func workingSetIds() {
        let members = Self.cards.map {
            RemoteWorkingSet.Member(id: $0.id, column: $0.column, archived: $0.archived, activity: $0.lastActivity ?? $0.updatedAt)
        }
        #expect(RemoteWorkingSet.ids(members) == Set(RemoteWorkingSet.filter(Self.cards).map(\.id)))
    }

    @Test("a master's own search reads the first lines of the prompt, the name, branches and pull requests")
    func masterSearch() {
        let prompt = "Export the invoices to Parquet\nKeep the CSV path\n\n" + (0..<20).map { "filler line \($0)" }.joined(separator: "\n")
            + "\nzebra at the very end"
        let links = [
            Link(id: "card_prompt", name: "Billing exports", projectPath: "/p/acme-api", column: .allSessions,
                 manuallyArchived: true, promptBody: prompt),
            Link(id: "card_pr", name: "Speed up search", projectPath: "/p/acme-api", column: .done,
                 prLinks: [PRLink(number: 412, title: "perf: faster index")], discoveredBranches: ["perf/index"]),
        ]
        let cards = links.map { KanbanCodeCard(link: $0) }
        let index = CardSearchIndex()
        func ids(_ query: String, _ scope: RemoteCardSearchScope = .all) -> [String] {
            MasterRemoteControlHost.search(cards, RemoteCardSearchRequest(query: query, scope: scope), index: index) {
                RemoteBoardMapper.card($0, liveSessions: [])
            }.cards.map(\.id)
        }
        #expect(ids("parquet") == ["card_prompt"])
        #expect(ids("PARQUET billing") == ["card_prompt"])
        #expect(ids("zebra") == [])
        #expect(ids("#412") == ["card_pr"])
        #expect(ids("faster index") == ["card_pr"])
        #expect(ids("perf/index") == ["card_pr"])
        #expect(ids("acme-api") == ["card_pr", "card_prompt"])
        #expect(ids("acme-api", .older) == ["card_prompt"])
        #expect(ids("", .archived) == ["card_prompt"])

        // A card that changed is read again; an unchanged one comes from the index.
        var renamed = links[0]
        renamed.name = "Ledger exports"
        renamed.updatedAt = renamed.updatedAt.addingTimeInterval(1)
        let after = MasterRemoteControlHost.search([KanbanCodeCard(link: renamed)], RemoteCardSearchRequest(query: "ledger"),
                                                   index: index) { RemoteBoardMapper.card($0, liveSessions: []) }
        #expect(after.cards.map(\.title) == ["Ledger exports"])
    }

    @Test("a search over 2,500 cards stays fast once the cards are indexed")
    func cost() {
        let cards = (0..<2500).map { i in
            KanbanCodeCard(link: Link(id: "card_\(i)", name: "Task number \(i) for the billing service", projectPath: "/p/acme",
                                      column: .allSessions, promptBody: String(repeating: "Some prompt text. ", count: 20)))
        }
        let index = CardSearchIndex()
        _ = index.matching(cards, query: CardSearchQuery("warm"))
        let started = Date()
        for word in ["b", "bi", "bil", "bill", "billing 24"] {
            _ = MasterRemoteControlHost.search(cards, RemoteCardSearchRequest(query: word, scope: .older), index: index) {
                RemoteBoardMapper.card($0, liveSessions: [])
            }
        }
        #expect(Date().timeIntervalSince(started) < 1.0)
    }

    @Test("peers are asked together; a peer that is off, late or failing is named and does not hold the answer")
    func fanOut() async {
        let local = RemoteCardSearchResult(cards: [Self.card("mine", "x", machineId: "machine_box")])
        let peers = [
            RemoteCardSearch.Peer(machineId: "machine_mac", name: "mac") {
                RemoteCardSearchResult(cards: [Self.card("theirs", "x", .allSessions, machineId: "machine_mac")])
            },
            RemoteCardSearch.Peer(machineId: "machine_slow", name: "slow") {
                try await Task.sleep(for: .seconds(30))
                return RemoteCardSearchResult(cards: [Self.card("late", "x")])
            },
            RemoteCardSearch.Peer(machineId: "machine_down", name: "down") {
                throw RemoteClientError.transport("connection refused")
            },
            RemoteCardSearch.Peer(machineId: "machine_old", name: "old") {
                throw RemoteClientError.notFound("no card search")
            },
        ]
        let started = Date()
        let result = await RemoteCardSearch.fanOut(local: local, peers: peers, offline: ["asleep"], limit: 50, timeout: 0.3)
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(result.cards.map(\.id) == ["mine", "theirs"])
        #expect(Set(result.unreachable) == ["asleep", "slow", "down"])

        let alone = await RemoteCardSearch.fanOut(local: local, peers: [], offline: ["asleep"], limit: 50)
        #expect(alone.cards.map(\.id) == ["mine"])
        #expect(alone.unreachable == ["asleep"])
    }

    @Test("the route answers the phone and an agent, reads q, scope and limit, and is refused without a token")
    func route() async throws {
        let f = try await RemoteServerFixture(host: FakeRemoteHost(cards: Self.cards + [Self.card("cpp", "Port to C++", .waiting)]))
        defer { f.shutdown() }
        for token in [f.fullToken, f.agentToken] {
            let (status, data) = try await f.request("GET", "/v1/cards/search?q=parquet%20EXPORT", token: token)
            #expect(status == 200)
            #expect(try JSONDecoder.remote.decode(RemoteCardSearchResult.self, from: data).cards.map(\.id) == ["arch"])
        }
        // A form-encoded query: plus is a space, %2B a plus.
        let form = try JSONDecoder.remote.decode(RemoteCardSearchResult.self, from:
            try await f.request("GET", "/v1/cards/search?q=parquet+invoices", token: f.fullToken).1)
        #expect(form.cards.map(\.id) == ["arch"])
        #expect(try JSONDecoder.remote.decode(RemoteCardSearchResult.self, from:
            try await f.request("GET", "/v1/cards/search?q=c%2B%2B", token: f.fullToken).1).cards.map(\.id) == ["cpp"])

        let older = try JSONDecoder.remote.decode(RemoteCardSearchResult.self, from:
            try await f.request("GET", "/v1/cards/search?q=export&scope=older&limit=2&local=1", token: f.fullToken).1)
        #expect(older.cards.map(\.id) == ["done30", "done31"])
        #expect(older.truncated)
        #expect(try await f.request("GET", "/v1/cards/search?q=x&scope=nope", token: f.fullToken).0 == 400)
        #expect(try await f.request("GET", "/v1/cards/search?q=x").0 == 401)
        #expect(try await f.request("POST", "/v1/cards/search?q=x", token: f.fullToken).0 == 405)

        let client = RemoteClient(baseURL: URL(string: f.base)!, token: f.fullToken, session: f.session)
        let viaClient = try await client.searchCards("Export scratch", scope: .older, limit: 10, local: true, timeout: 5)
        #expect(viaClient.cards.map(\.id) == ["sessions"])
        #expect(try await client.searchCards("c++ port").cards.map(\.id) == ["cpp"])
        let health = try JSONDecoder.remote.decode(RemoteHealth.self, from: try await f.request("GET", "/v1/health").1)
        #expect(health.features?.contains(RemoteAPI.Feature.cardSearch) == true)
    }

    @Test("a peer token may search, a terminal token may not, and a search holds no machine awake")
    func scopeAndActivity() async throws {
        #expect(RemoteScopePolicy.shape(["cards", "search"]) == "cards/search")
        #expect(RemoteScopePolicy.refusal(scope: .peer, method: "GET", rest: ["cards", "search"]) == nil)
        #expect(RemoteScopePolicy.refusal(scope: .peer, method: "POST", rest: ["cards", "search"]) != nil)
        #expect(RemoteScopePolicy.refusal(scope: .terminal, method: "GET", rest: ["cards", "search"]) != nil)
        #expect(RemoteActivityPolicy.card(rest: ["cards", "search"]) == nil)
        #expect(RemoteActivityPolicy.card(rest: ["cards", "c1", "transcript"]) == "c1")

        let f = try await RemoteServerFixture(host: FakeRemoteHost(cards: Self.cards))
        defer { f.shutdown() }
        let peer = try f.devices.add(name: "box", scope: .peer).token
        let terminal = try f.devices.add(name: "box terminals", scope: .terminal).token
        #expect(try await f.request("GET", "/v1/cards/search?q=parquet", token: peer).0 == 200)
        #expect(try await f.request("GET", "/v1/cards/search?q=parquet", token: terminal).0 == 403)
    }
}
