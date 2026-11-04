import Foundation
import Testing

@testable import KanbanCodeRemoteKit

@Suite("Conversation search matching and ranking")
struct ConversationSearchTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func conversation(_ id: String, _ title: String?, preview: String? = nil, minutesAgo: Double = 0,
                             archived: Bool = false, unread: Bool = false) -> RemoteConversation {
        let at = t0.addingTimeInterval(-minutesAgo * 60)
        return RemoteConversation(id: id, title: title, createdAt: at, updatedAt: at, preview: preview,
                                  unread: unread, archived: archived)
    }

    static func entry(_ cardId: String, _ cardTitle: String, _ conversation: RemoteConversation) -> ConversationSearch.Entry {
        ConversationSearch.Entry(cardId: cardId, cardTitle: cardTitle, conversation: conversation)
    }

    static func ids(_ hits: [ConversationSearch.Hit]) -> [String] {
        hits.map(\.entry.conversation.id)
    }

    @Test("a conversation matches on its title, whatever the case or the accents")
    func titleMatch() {
        let entries = [
            Self.entry("laze", "laze", Self.conversation("brave-otter", "WhatsApp integration")),
            Self.entry("laze", "laze", Self.conversation("calm-heron", "Tracing with tempo")),
            Self.entry("laze", "laze", Self.conversation("quick-lynx", "Résumé parser")),
        ]
        #expect(Self.ids(ConversationSearch.search(entries, query: CardSearchQuery("whatsapp"))) == ["brave-otter"])
        #expect(Self.ids(ConversationSearch.search(entries, query: CardSearchQuery("TEMPO"))) == ["calm-heron"])
        #expect(Self.ids(ConversationSearch.search(entries, query: CardSearchQuery("resume"))) == ["quick-lynx"])
        #expect(ConversationSearch.search(entries, query: CardSearchQuery("whatsapp"))[0].inTitle)
        #expect(ConversationSearch.search(entries, query: CardSearchQuery("billing")).isEmpty)
    }

    @Test("an empty query lists nothing")
    func emptyQuery() {
        let entries = [Self.entry("laze", "laze", Self.conversation("brave-otter", "WhatsApp integration"))]
        #expect(ConversationSearch.search(entries, query: CardSearchQuery("   ")).isEmpty)
    }

    @Test("the card's name narrows the search but never lists all of a card's conversations by itself")
    func cardNameNarrows() {
        let entries = [
            Self.entry("laze", "laze", Self.conversation("brave-otter", "WhatsApp integration")),
            Self.entry("laze", "laze", Self.conversation("calm-heron", "Tracing with tempo")),
            Self.entry("ouve", "ouve", Self.conversation("deep-crane", "WhatsApp voice notes")),
        ]
        #expect(ConversationSearch.search(entries, query: CardSearchQuery("laze")).isEmpty)
        let hits = ConversationSearch.search(entries, query: CardSearchQuery("laze whatsapp"))
        #expect(Self.ids(hits) == ["brave-otter"])
        #expect(hits[0].inTitle)
    }

    @Test("the last message matches too, ranked after title matches")
    func previewMatch() {
        let entries = [
            Self.entry("laze", "laze", Self.conversation("brave-otter", "WhatsApp integration",
                                                         preview: "pushed the grafana dashboard", minutesAgo: 1)),
            Self.entry("laze", "laze", Self.conversation("calm-heron", "Grafana alerts", minutesAgo: 60)),
        ]
        let hits = ConversationSearch.search(entries, query: CardSearchQuery("grafana"))
        #expect(Self.ids(hits) == ["calm-heron", "brave-otter"])
        #expect(hits[0].inTitle)
        #expect(!hits[1].inTitle)
    }

    @Test("an untitled conversation never matches on its placeholder name")
    func untitled() {
        let entries = [Self.entry("laze", "laze", Self.conversation("brave-otter", nil, preview: "hello there"))]
        #expect(ConversationSearch.search(entries, query: CardSearchQuery("new conversation")).isEmpty)
        #expect(Self.ids(ConversationSearch.search(entries, query: CardSearchQuery("hello"))) == ["brave-otter"])
    }

    @Test("archived conversations only show when asked for")
    func archived() {
        let entries = [
            Self.entry("laze", "laze", Self.conversation("brave-otter", "OpenClaw migration", archived: true)),
            Self.entry("laze", "laze", Self.conversation("calm-heron", "OpenClaw cleanup")),
        ]
        #expect(Self.ids(ConversationSearch.search(entries, query: CardSearchQuery("openclaw"))) == ["calm-heron"])
        #expect(Self.ids(ConversationSearch.search(entries, query: CardSearchQuery("openclaw"), includeArchived: true))
                == ["calm-heron", "brave-otter"])
    }

    @Test("among title matches the most recent conversation comes first, live before archived")
    func ranking() {
        let entries = [
            Self.entry("a", "alpha", Self.conversation("old-one", "Deploy box", minutesAgo: 300)),
            Self.entry("b", "beta", Self.conversation("new-one", "Deploy phone", minutesAgo: 5)),
            Self.entry("c", "gamma", Self.conversation("gone-one", "Deploy server", minutesAgo: 1, archived: true)),
        ]
        let hits = ConversationSearch.search(entries, query: CardSearchQuery("deploy"), includeArchived: true)
        #expect(Self.ids(hits) == ["new-one", "old-one", "gone-one"])
    }

    @Test("a limit cuts the ranked list")
    func limit() {
        let entries = (0..<10).map { i in
            Self.entry("c", "card", Self.conversation("conv-\(i)", "Topic \(i)", minutesAgo: Double(i)))
        }
        let hits = ConversationSearch.search(entries, query: CardSearchQuery("topic"), limit: 3)
        #expect(Self.ids(hits) == ["conv-0", "conv-1", "conv-2"])
    }

    @Test("entries come only for cards that are listed, each with its card's name")
    func entries() {
        let conversations: [String: [RemoteConversation]] = [
            "laze": [Self.conversation("brave-otter", "WhatsApp integration")],
            "hidden": [Self.conversation("calm-heron", "Excluded project")],
        ]
        let entries = ConversationSearch.entries(conversations: conversations, cardTitles: ["laze": "laze"])
        #expect(entries.count == 1)
        #expect(entries.first?.cardId == "laze")
        #expect(entries.first?.cardTitle == "laze")
    }

    @Test("a hit's id is unique across cards")
    func hitIds() {
        let a = ConversationSearch.Hit(entry: Self.entry("a", "alpha", Self.conversation("same-id", "x")), inTitle: true)
        let b = ConversationSearch.Hit(entry: Self.entry("b", "beta", Self.conversation("same-id", "x")), inTitle: true)
        #expect(a.id != b.id)
        #expect(ConversationSearch.Hit.parse(id: a.id)?.cardId == "a")
        #expect(ConversationSearch.Hit.parse(id: a.id)?.conversationId == "same-id")
        #expect(ConversationSearch.Hit.parse(id: "channel:general") == nil)
    }
}
