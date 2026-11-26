import Testing
@testable import KanbanCodeRemoteKit

@Suite("An open conversation marked unread stays unread until opened again or sent in")
struct ConversationReadHoldsTests {
    private let key = ConversationReadHolds.Key(server: "s1", cardId: "c1", conversation: "v1")
    private let other = ConversationReadHolds.Key(server: "s1", cardId: "c1", conversation: "v2")

    @Test func openConversationMarksAgentRepliesRead() {
        let holds = ConversationReadHolds()
        #expect(holds.shouldMarkRead(key, unread: true))
        #expect(!holds.shouldMarkRead(key, unread: false))
    }

    @Test func markedUnreadStaysUnreadThroughRefreshes() {
        var holds = ConversationReadHolds()
        holds.markedUnread(key)
        // Every refresh of the open view, and new agent replies, find it unread.
        for _ in 0..<5 {
            #expect(!holds.shouldMarkRead(key, unread: true))
        }
        // Other conversations still mark themselves read.
        #expect(holds.shouldMarkRead(other, unread: true))
    }

    @Test func openingAgainMarksRead() {
        var holds = ConversationReadHolds()
        holds.markedUnread(key)
        holds.opened(key)
        #expect(holds.shouldMarkRead(key, unread: true))
    }

    @Test func sendingMarksRead() {
        var holds = ConversationReadHolds()
        holds.markedUnread(key)
        holds.interacted(key)
        #expect(holds.shouldMarkRead(key, unread: true))
    }

    @Test func markReadOrFailedMarkUnreadReleases() {
        var holds = ConversationReadHolds()
        holds.markedUnread(key)
        holds.released(key)
        #expect(!holds.isHeld(key))
        #expect(holds.shouldMarkRead(key, unread: true))
    }

    @Test func sameConversationOnAnotherMasterIsSeparate() {
        var holds = ConversationReadHolds()
        holds.markedUnread(key)
        let elsewhere = ConversationReadHolds.Key(server: "s2", cardId: "c1", conversation: "v1")
        #expect(holds.shouldMarkRead(elsewhere, unread: true))
    }
}
