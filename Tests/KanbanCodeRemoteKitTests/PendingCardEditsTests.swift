import Foundation
import Testing
@testable import KanbanCodeRemoteKit

@Suite("Card edits from the phone stay shown until every board has them")
struct PendingCardEditsTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func card(_ id: String = "c1", archived: Bool = false, title: String = "Task",
                      column: RemoteColumn = .waiting, pinned: Bool = false) -> RemoteCard {
        RemoteCard(id: id, title: title, column: column, archived: archived, pinned: pinned, updatedAt: t0)
    }

    private func onBoard(_ cards: [RemoteCard]) -> [String] {
        cards.filter(CardSearch.isOnBoard).map(\.id)
    }

    @Test func archivedCardStaysOffTheBoardWhenAPeerStillSendsItsOldCopy() {
        var pending = PendingCardEdits()
        let id = pending.begin(cardId: "c1", .archive, at: t0)
        pending.succeeded(id, at: t0.addingTimeInterval(1))

        // The owner dropped the archived card from its working set; the
        // peer's synced copy and a board frame read before the archive
        // still list it on the board.
        let owner = PendingCardEdits.Listing(cards: [card("c2")], receivedAt: t0.addingTimeInterval(2))
        let peer = PendingCardEdits.Listing(cards: [card("c1"), card("c2")], receivedAt: t0.addingTimeInterval(3))
        pending.settle([owner, peer], now: t0.addingTimeInterval(3))

        #expect(pending.edits.count == 1)
        #expect(onBoard(pending.apply(to: peer.cards)) == ["c2"])
    }

    @Test func archiveShowsBeforeTheMasterAnswers() {
        var pending = PendingCardEdits()
        pending.begin(cardId: "c1", .archive, at: t0)
        let stale = PendingCardEdits.Listing(cards: [card("c1")], receivedAt: t0.addingTimeInterval(5))
        pending.settle([stale], now: t0.addingTimeInterval(60))
        #expect(pending.edits.count == 1, "an edit in flight is never dropped by a board")
        #expect(onBoard(pending.apply(to: stale.cards)).isEmpty)
    }

    @Test func boardsThatCaughtUpClearTheEdit() {
        var pending = PendingCardEdits()
        let id = pending.begin(cardId: "c1", .archive, at: t0)
        pending.succeeded(id, at: t0.addingTimeInterval(1))
        let owner = PendingCardEdits.Listing(cards: [], receivedAt: t0.addingTimeInterval(2))
        let peer = PendingCardEdits.Listing(cards: [card("c1", archived: true)], receivedAt: t0.addingTimeInterval(4))
        pending.settle([owner, peer], now: t0.addingTimeInterval(4))
        #expect(pending.isEmpty)
    }

    @Test func failedRequestRollsBack() {
        var pending = PendingCardEdits()
        let id = pending.begin(cardId: "c1", .archive, at: t0)
        #expect(onBoard(pending.apply(to: [card("c1")])).isEmpty)
        pending.failed(id)
        #expect(pending.isEmpty)
        #expect(onBoard(pending.apply(to: [card("c1")])) == ["c1"])
    }

    @Test func boardStillDisagreeingAfterTheGraceWins() {
        var pending = PendingCardEdits()
        let id = pending.begin(cardId: "c1", .archive, at: t0)
        pending.succeeded(id, at: t0)
        let later = t0.addingTimeInterval(PendingCardEdits.grace + 1)
        let fresh = PendingCardEdits.Listing(cards: [card("c1")], receivedAt: later)
        pending.settle([fresh], now: later)
        #expect(pending.isEmpty, "the card was brought back elsewhere; the board is right")
    }

    @Test func offlineCacheKeepsTheEditPastTheGrace() {
        var pending = PendingCardEdits()
        let id = pending.begin(cardId: "c1", .archive, at: t0)
        pending.succeeded(id, at: t0.addingTimeInterval(1))
        let cached = PendingCardEdits.Listing(cards: [card("c1")], receivedAt: t0.addingTimeInterval(-600))
        pending.settle([cached], now: t0.addingTimeInterval(3600))
        #expect(pending.edits.count == 1)
        #expect(onBoard(pending.apply(to: cached.cards)).isEmpty)
    }

    @Test func moveRenamePinAndDeleteLayOverTheBoard() {
        var pending = PendingCardEdits()
        pending.begin(cardId: "c1", .move(.backlog), at: t0)
        pending.begin(cardId: "c1", .rename("New name"), at: t0)
        pending.begin(cardId: "c1", .pin(true), at: t0)
        pending.begin(cardId: "c2", .delete, at: t0)
        let out = pending.apply(to: [card("c1"), card("c2")])
        #expect(out.map(\.id) == ["c1"])
        #expect(out[0].column == .backlog)
        #expect(out[0].title == "New name")
        #expect(out[0].pinned && out[0].pinnedAt == t0)
        #expect(pending.deletedIds == ["c2"])
    }

    @Test func laterEditOfTheSameFieldReplacesTheEarlierOne() {
        var pending = PendingCardEdits()
        pending.begin(cardId: "c1", .move(.backlog), at: t0)
        pending.begin(cardId: "c1", .move(.inReview), at: t0.addingTimeInterval(1))
        pending.begin(cardId: "c1", .archive, at: t0)
        pending.begin(cardId: "c1", .unarchive, at: t0.addingTimeInterval(1))
        #expect(pending.edits.map(\.kind) == [.move(.inReview), .unarchive])
    }
}
