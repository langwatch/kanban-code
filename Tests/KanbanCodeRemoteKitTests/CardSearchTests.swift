import Foundation
import Testing

@testable import KanbanCodeRemoteKit

@Suite("Card search matching and ranking")
struct CardSearchTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func card(_ id: String, _ title: String, _ column: RemoteColumn = .waiting, archived: Bool = false,
                     project: String? = nil, branch: String? = nil, prs: [RemotePR] = [], minutesAgo: Double = 0,
                     machineId: String? = nil) -> RemoteCard {
        RemoteCard(id: id, title: title, column: column, projectName: project, branch: branch, prs: prs,
                   archived: archived, lastActivity: t0.addingTimeInterval(-minutesAgo * 60), updatedAt: t0,
                   machineId: machineId)
    }

    @Test("every word must be found, in any field, whatever the case or the accents")
    func matching() {
        let card = Self.card("c1", "Résumé parser for the Careers page", project: "acme-web", branch: "feat/cv-upload",
                             prs: [RemotePR(number: 8321, title: "feat: parse uploads")])
        #expect(CardSearchQuery("resume").matches(card))
        #expect(CardSearchQuery("RESUME careers").matches(card))
        #expect(CardSearchQuery("parser acme").matches(card))
        #expect(CardSearchQuery("cv-upload").matches(card))
        #expect(CardSearchQuery("#8321").matches(card))
        #expect(CardSearchQuery("8321 resume").matches(card))
        #expect(CardSearchQuery("parse uploads").matches(card))
        #expect(!CardSearchQuery("resume billing").matches(card))
        #expect(!CardSearchQuery("#832199").matches(card))
        #expect(CardSearchQuery("   ").isEmpty)
        #expect(CardSearchQuery("").matches(card))
    }

    @Test("an accented query finds unaccented text, and extra text counts")
    func foldingBothSides() {
        let card = Self.card("c1", "Migracao do banco")
        #expect(CardSearchQuery("migração").matches(card))
        #expect(!CardSearchQuery("parquet").matches(card))
        #expect(CardSearchQuery("parquet").matches(card, extra: ["Export the invoices to Parquet files"]))
    }

    @Test("board cards come first, then the most recently active")
    func ranking() {
        let cards = [
            Self.card("old-archived", "x", .allSessions, archived: true, minutesAgo: 1),
            Self.card("sessions", "x", .allSessions, minutesAgo: 2),
            Self.card("board-old", "x", .done, minutesAgo: 500),
            Self.card("board-new", "x", .waiting, minutesAgo: 20),
            Self.card("archived-in-column", "x", .inProgress, archived: true, minutesAgo: 3),
        ]
        #expect(CardSearch.search(cards, query: CardSearchQuery("x")).map(\.id)
            == ["board-new", "board-old", "old-archived", "sessions", "archived-in-column"])
    }

    @Test("answers of several masters merge to one card each, the owner's copy kept, and are cut to the limit")
    func merging() {
        let local = RemoteCardSearchResult(cards: [
            Self.card("shared", "stale copy", .waiting, minutesAgo: 10, machineId: "machine_mac"),
            Self.card("mine", "mine", .waiting, minutesAgo: 5, machineId: "machine_box"),
        ])
        let peer = RemoteCardSearchResult(cards: [
            Self.card("shared", "owner copy", .waiting, minutesAgo: 10, machineId: "machine_mac"),
            Self.card("mine", "peer's stale copy", .waiting, minutesAgo: 5, machineId: "machine_box"),
            Self.card("only-there", "session", .allSessions, minutesAgo: 1, machineId: "machine_mac"),
        ], truncated: true)
        let merged = CardSearch.merge(local: local, peers: [("machine_mac", peer)], unreachable: ["gpu"], limit: 10)
        #expect(merged.cards.map(\.id) == ["mine", "shared", "only-there"])
        #expect(merged.cards.map(\.title) == ["mine", "owner copy", "session"])
        #expect(merged.truncated)
        #expect(merged.unreachable == ["gpu"])
        let cut = CardSearch.merge(local: local, peers: [], unreachable: [], limit: 1)
        #expect(cut.cards.map(\.id) == ["mine"])
        #expect(cut.truncated)
    }

    @Test("a result leaves out truncated and unreachable when they say nothing")
    func coding() throws {
        let plain = try JSONEncoder.remote.encode(RemoteCardSearchResult(cards: []))
        #expect(String(decoding: plain, as: UTF8.self) == #"{"cards":[]}"#)
        let full = RemoteCardSearchResult(cards: [], truncated: true, unreachable: ["mac"])
        #expect(try JSONDecoder.remote.decode(RemoteCardSearchResult.self, from: JSONEncoder.remote.encode(full)) == full)
        #expect(try JSONDecoder.remote.decode(RemoteCardSearchResult.self, from: plain) == RemoteCardSearchResult(cards: []))
    }
}
