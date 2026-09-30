import Testing
@testable import KanbanCode
import KanbanCodeCore

@Suite("Card Drop Intent")
struct CardDropIntentTests {
    @Test("Fresh backlog cards start when dropped into In Progress")
    func backlogCardStarts() {
        let card = KanbanCodeCard(
            link: Link(
                id: "card_backlog",
                name: "Fix login bug",
                projectPath: "/test/project",
                column: .backlog,
                source: .manual
            )
        )

        #expect(CardDropIntent.resolve(card, to: .inProgress) == .start)
    }

    @Test("Cards without pull requests cannot be dropped into In Review")
    func cardWithoutPRCannotMoveToReview() {
        let card = KanbanCodeCard(
            link: Link(
                id: "card_waiting",
                name: "Needs review",
                projectPath: "/test/project",
                column: .waiting,
                source: .manual
            )
        )

        #expect(
            CardDropIntent.resolve(card, to: .inReview)
                == .invalid("Cannot move to In Review - card has no pull request")
        )
    }

    @Test("Cards with an open pull request can be dropped into Done")
    func cardWithOpenPRMovesToDone() {
        let card = KanbanCodeCard(
            link: Link(
                id: "card_review",
                name: "Open PR",
                projectPath: "/test/project",
                column: .inReview,
                source: .manual,
                prLinks: [PRLink(number: 42, title: "Open PR")]
            )
        )

        #expect(CardDropIntent.resolve(card, to: .done) == .move)
    }

    /// Work merged into main locally never has a PR, and Done is where it goes.
    @Test("Cards without any pull request can be dropped into Done")
    func cardWithoutPRMovesToDone() {
        let card = KanbanCodeCard(
            link: Link(
                id: "card_local",
                name: "Merged locally",
                projectPath: "/test/project",
                column: .waiting,
                source: .manual
            )
        )

        #expect(CardDropIntent.resolve(card, to: .done) == .move)
    }

    @Test("Archived cards can be restored to Backlog")
    func archivedCardMovesBackToBacklog() {
        let card = KanbanCodeCard(
            link: Link(
                id: "card_archived",
                name: "Archived",
                projectPath: "/test/project",
                column: .allSessions,
                manuallyArchived: true,
                source: .manual
            )
        )

        #expect(CardDropIntent.resolve(card, to: .backlog) == .move)
    }
}
