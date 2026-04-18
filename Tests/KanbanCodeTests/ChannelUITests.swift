import Testing
import SwiftUI
import AppKit
@testable import KanbanCode
import KanbanCodeCore

@Suite("Channel UI")
struct ChannelUITests {

    /// Forces a SwiftUI view through an NSHostingView layout pass so we catch
    /// runtime crashes that swift build can't surface (e.g. @ViewBuilder issues,
    /// binding traps, layout cycles).
    @MainActor
    private func hostAndLayout<V: View>(_ view: V) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
        host.layoutSubtreeIfNeeded()
        // Access `intrinsicContentSize` to ensure body has been evaluated.
        _ = host.intrinsicContentSize
    }

    @MainActor
    @Test func channelTileRendersWithUnreadBadge() {
        let ch = Channel(
            id: "ch_1",
            name: "general",
            createdAt: .now,
            createdBy: ChannelParticipant(cardId: nil, handle: "user"),
            members: [
                ChannelMember(cardId: "card_A", handle: "alice", joinedAt: .now),
                ChannelMember(cardId: nil,      handle: "user",  joinedAt: .now),
            ]
        )
        let tile = ChannelTile(
            channel: ch,
            onlineCount: 1,
            lastMessageAt: .now,
            lastMessageBody: "hello team",
            isSelected: false,
            unreadCount: 3,
            onOpen: {}
        )
        hostAndLayout(tile)
    }

    @MainActor
    @Test func channelTileRendersZeroUnread() {
        let ch = Channel(
            id: "ch_1",
            name: "general",
            createdAt: .now,
            createdBy: ChannelParticipant(cardId: nil, handle: "user"),
            members: []
        )
        let tile = ChannelTile(
            channel: ch,
            onlineCount: 0,
            lastMessageAt: nil,
            lastMessageBody: nil,
            isSelected: true,
            unreadCount: 0,
            onOpen: {}
        )
        hostAndLayout(tile)
    }

    @MainActor
    @Test func channelChatViewRendersEmpty() {
        let ch = Channel(
            id: "ch_1",
            name: "general",
            createdAt: .now,
            createdBy: ChannelParticipant(cardId: nil, handle: "user"),
            members: []
        )
        let chat = ChannelChatView(
            channel: ch,
            messages: [],
            onlineByHandle: [:],
            onSend: { _, _ in },
            onClose: {},
            draft: .constant("")
        )
        hostAndLayout(chat)
    }

    @MainActor
    @Test func channelChatViewRendersMixedMessageTypes() {
        let ch = Channel(
            id: "ch_1",
            name: "ops",
            createdAt: .now,
            createdBy: ChannelParticipant(cardId: nil, handle: "user"),
            members: []
        )
        let p = ChannelParticipant(cardId: "card_A", handle: "alice")
        let chat = ChannelChatView(
            channel: ch,
            messages: [
                ChannelMessage(id: "m1", ts: .now, from: p, body: "@alice joined", type: .join),
                ChannelMessage(id: "m2", ts: .now, from: p, body: "hi"),
                ChannelMessage(id: "m3", ts: .now, from: p, body: "@alice left",   type: .leave),
                ChannelMessage(id: "m4", ts: .now, from: ChannelParticipant(cardId: nil, handle: "user"), body: "welcome back"),
            ],
            onlineByHandle: ["alice": true, "user": true],
            onSend: { _, _ in },
            onClose: {},
            draft: .constant("")
        )
        hostAndLayout(chat)
    }

    @MainActor
    @Test func mentionQueryDetection() {
        #expect(ChatInputBar.activeMentionQuery(in: "") == nil)
        #expect(ChatInputBar.activeMentionQuery(in: "hello") == nil)
        #expect(ChatInputBar.activeMentionQuery(in: "hey @") == "")
        #expect(ChatInputBar.activeMentionQuery(in: "hey @ali") == "ali")
        #expect(ChatInputBar.activeMentionQuery(in: "@alice") == "alice")
        // Preceded by punctuation is OK (start of token after comma)
        #expect(ChatInputBar.activeMentionQuery(in: "cc:@bo") == "bo")
        // Mid-word @ is NOT a mention
        #expect(ChatInputBar.activeMentionQuery(in: "email@example") == nil)
        // Whitespace breaks the token — no active query at the end
        #expect(ChatInputBar.activeMentionQuery(in: "hi @alice ") == nil)
    }

    @MainActor
    @Test func mentionFiltering() {
        let candidates = ["alice", "bob", "alfred", "carol"]
        let all = ChatInputBar.filteredMentionMatches(query: "", candidates: candidates)
        #expect(all == candidates, "Empty query should return all candidates")
        let alMatches = ChatInputBar.filteredMentionMatches(query: "al", candidates: candidates)
        #expect(alMatches.sorted() == ["alfred", "alice"])
        #expect(ChatInputBar.filteredMentionMatches(query: "A", candidates: candidates).sorted() == ["alfred", "alice"])
        #expect(ChatInputBar.filteredMentionMatches(query: "zz", candidates: candidates).isEmpty)
    }

    @MainActor
    @Test func createChannelDialogRendersAndValidates() {
        var isPresented = true
        let binding = Binding(get: { isPresented }, set: { isPresented = $0 })
        let dialog = CreateChannelDialog(isPresented: binding, onCreate: { _ in })
        hostAndLayout(dialog)
    }

    @MainActor
    @Test func dmChatViewRendersWithMessages() {
        let other = ChannelParticipant(cardId: "card_A", handle: "alice")
        let dm = DMChatView(
            other: other,
            messages: [
                ChannelMessage(id: "m1", ts: .now, from: ChannelParticipant(cardId: nil, handle: "rchaves"), body: "hey"),
                ChannelMessage(id: "m2", ts: .now, from: other, body: "hi back"),
            ],
            onlineForOther: true,
            onSend: { _, _ in },
            onClose: {},
            draft: .constant("")
        )
        hostAndLayout(dm)
    }

    @MainActor
    @Test func dmChatViewRendersEmptyState() {
        let other = ChannelParticipant(cardId: "card_A", handle: "alice")
        let dm = DMChatView(
            other: other,
            messages: [],
            onlineForOther: false,
            draft: .constant("")
        )
        hostAndLayout(dm)
    }

    @MainActor
    @Test func channelChatViewRendersRosterWhenExpanded() {
        let ch = Channel(
            id: "ch_1",
            name: "ops",
            createdAt: .now,
            createdBy: ChannelParticipant(cardId: nil, handle: "user"),
            members: [
                ChannelMember(cardId: "card_A", handle: "alice", joinedAt: .now),
                ChannelMember(cardId: "card_B", handle: "bob",   joinedAt: .now),
                ChannelMember(cardId: nil,      handle: "user",  joinedAt: .now),
            ]
        )
        let chat = ChannelChatView(
            channel: ch,
            messages: [],
            onlineByHandle: ["alice": true, "bob": false, "user": true],
            onSend: { _, _ in },
            onClose: {},
            onCopyDMCommand: { _ in },
            draft: .constant("")
        )
        hostAndLayout(chat)
    }

}
