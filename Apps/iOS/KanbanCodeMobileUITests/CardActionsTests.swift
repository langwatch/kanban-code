import XCTest

/// Touch and hold a card on the board for its actions, against the demo
/// master (KC_PAIR_LINK). The tests change the demo's cards, so restart it
/// before running the class again.
final class CardActionsTests: KanbanUITestCase {
    /// Scrolls the board until the card's row can be touched.
    @discardableResult
    func row(_ id: String) -> XCUIElement {
        let card = app.buttons["card-\(id)"]
        // Any card: a scrolled list holds only the rows near the screen.
        let anyCard = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'card-'")).firstMatch
        XCTAssertTrue(anyCard.waitForExistence(timeout: 40))
        // Clear of the search field floating over the bottom of the list.
        let limit = app.windows.firstMatch.frame.height * 0.75
        for _ in 0..<8 where !card.isHittable || card.frame.maxY > limit { app.swipeUp(velocity: .slow) }
        // Let the scroll settle: a press on a moving list is a tap.
        sleep(2)
        XCTAssertTrue(card.isHittable, "card \(id) not on screen")
        return card
    }

    func menuItem(_ title: String) -> XCUIElement {
        app.collectionViews.buttons[title].firstMatch
    }

    func test1MenuRenamesPinsAndMovesACard() throws {
        row("card_backlog").press(forDuration: 1.0)
        XCTAssertTrue(menuItem("Copy Card ID").waitForExistence(timeout: 15))
        shot("act-01-menu")
        for title in ["Start", "Rename", "Pin", "Move to", "Copy Card ID", "Archive"] {
            XCTAssertTrue(menuItem(title).waitForExistence(timeout: 15), "no \(title) in the menu")
        }
        XCTAssertFalse(menuItem("Delete Card").exists, "a card on the board offers Delete")

        menuItem("Rename").tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        // Caret at the end, then erase the old title before typing the new one.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        let old = (field.value as? String) ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count + 5))
        field.typeText("Migration guide, renamed")
        shot("act-02-rename")
        app.alerts.buttons["Rename"].tap()
        XCTAssertTrue(waitFor(10) {
            let label = self.app.buttons["card-card_backlog"].label
            return label.contains("Migration guide, renamed") && !label.contains("Write the")
        },
                      app.buttons["card-card_backlog"].label)

        row("card_backlog").press(forDuration: 1.0)
        XCTAssertTrue(menuItem("Pin").waitForExistence(timeout: 15))
        menuItem("Pin").tap()
        sleep(1)
        row("card_backlog").press(forDuration: 1.0)
        XCTAssertTrue(menuItem("Unpin").waitForExistence(timeout: 15), "the card did not show as pinned")
        menuItem("Move to").tap()
        XCTAssertTrue(menuItem("Waiting").waitForExistence(timeout: 15))
        XCTAssertFalse(menuItem("In Review").exists, "In Review offered for a card without a PR")
        shot("act-03-move-to")
        menuItem("Waiting").tap()
        sleep(1)
        row("card_backlog").press(forDuration: 1.0)
        menuItem("Move to").tap()
        XCTAssertTrue(menuItem("Backlog").waitForExistence(timeout: 15), "the card did not move to Waiting")
        XCTAssertFalse(menuItem("Waiting").exists)
        app.tap()
    }

    func test2ArchivingALiveCardAsksFirst() throws {
        row("card_wait").press(forDuration: 1.0)
        XCTAssertTrue(menuItem("Archive").waitForExistence(timeout: 15))
        menuItem("Archive").tap()
        let alert = app.alerts["Archive this card?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 15))
        shot("act-04-archive-confirm")
        alert.buttons["Cancel"].tap()
        sleep(1)
        XCTAssertTrue(app.buttons["card-card_wait"].exists, "cancel archived the card")
    }

    func test3ArchiveUnarchiveAndDelete() throws {
        row("card_done").press(forDuration: 1.0)
        XCTAssertTrue(menuItem("Archive").waitForExistence(timeout: 15))
        XCTAssertFalse(menuItem("Open PR #398").exists, "a PR without a link offers Open")
        menuItem("Archive").tap()
        XCTAssertTrue(waitFor(10) { !self.app.buttons["card-card_done"].exists }, "the archived card stayed on the board")

        openArchived()
        let archived = app.descendants(matching: .any)["archived-card_done"].firstMatch
        XCTAssertTrue(archived.waitForExistence(timeout: 10))
        shot("act-05-archived")
        archived.press(forDuration: 1.0)
        XCTAssertTrue(menuItem("Delete Card").waitForExistence(timeout: 15))
        shot("act-06-archived-menu")
        menuItem("Bring back to board").tap()
        XCTAssertTrue(waitFor(10) { !archived.exists }, "unarchived card still listed")
        app.buttons["archivedDone"].tap()
        row("card_done")

        row("card_done").press(forDuration: 1.0)
        menuItem("Archive").tap()
        XCTAssertTrue(waitFor(10) { !self.app.buttons["card-card_done"].exists })
        openArchived()
        XCTAssertTrue(archived.waitForExistence(timeout: 10))
        archived.press(forDuration: 1.0)
        menuItem("Delete Card").tap()
        let alert = app.alerts["Delete this card?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 15))
        shot("act-07-delete-confirm")
        alert.buttons["Delete"].tap()
        XCTAssertTrue(waitFor(10) { !archived.exists }, "deleted card still listed")
        shot("act-08-deleted")
        app.buttons["archivedDone"].tap()
        XCTAssertTrue(app.buttons["boardMenu"].waitForExistence(timeout: 15))
        XCTAssertTrue(waitFor(10) { !self.app.buttons["archivedDone"].exists })
        XCTAssertFalse(app.buttons["card-card_done"].exists)
    }

    private func openArchived() {
        app.buttons["boardMenu"].tap()
        XCTAssertTrue(app.buttons["showArchived"].waitForExistence(timeout: 15))
        app.buttons["showArchived"].tap()
    }
}
