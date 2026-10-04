import XCTest

/// Search finds cards the phone does not hold (archived, All Sessions,
/// older Done) on the demo master (KC_PAIR_LINK), opens them and brings
/// them back. The tests change the demo's cards, so restart it before
/// running the class again.
final class CardSearchTests: KanbanUITestCase {
    func menuItem(_ title: String) -> XCUIElement {
        app.collectionViews.buttons[title].firstMatch
    }

    func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    func test1BoardSearchFindsAnArchivedCardOpensItAndBringsItBack() throws {
        XCTAssertTrue(app.buttons["card-card_wait"].waitForExistence(timeout: 40))
        XCTAssertFalse(app.buttons["card-card_old"].exists, "an archived card is on the board")
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText("PARQUET invoices")
        let found = element("older-card_old")
        XCTAssertTrue(found.waitForExistence(timeout: 15), "the archived card was not found")
        XCTAssertTrue(app.staticTexts["Archived and older"].exists || app.staticTexts["ARCHIVED AND OLDER"].exists)
        XCTAssertFalse(app.buttons["card-card_wait"].exists, "a card that does not match is listed")
        shot("search-01-board-results")

        found.tap()
        let bringBack = app.buttons["bringBack"]
        XCTAssertTrue(bringBack.waitForExistence(timeout: 15), "an archived card has no Bring back to board")
        XCTAssertTrue(message(containing: "Step 30: checked part 30").waitForExistence(timeout: 15),
                      "the archived card's conversation does not show")
        shot("search-02-archived-card")
        bringBack.tap()
        XCTAssertTrue(waitFor(15) { !bringBack.exists }, "the card still shows as archived")
        shot("search-03-brought-back")

        goBack()
        sleep(2)
        shot("search-04-on-board")
        XCTAssertTrue(app.buttons["card-card_old"].waitForExistence(timeout: 15), "the card is not on the board")
        XCTAssertFalse(found.exists, "the card is still listed as archived")
    }

    func test2ArchivedScreenSearchesAndBringsBackFromTheMenu() throws {
        XCTAssertTrue(app.buttons["card-card_wait"].waitForExistence(timeout: 40))
        XCTAssertFalse(app.buttons["card-card_older"].exists)
        app.buttons["boardMenu"].tap()
        XCTAssertTrue(app.buttons["showArchived"].waitForExistence(timeout: 15))
        app.buttons["showArchived"].tap()
        let listed = element("archived-card_older")
        XCTAssertTrue(listed.waitForExistence(timeout: 15))
        shot("search-05-archived-list")

        let field = app.searchFields["Search archived and older cards"]
        XCTAssertTrue(field.waitForExistence(timeout: 15), "the archived cards screen has no search field")
        field.tap()
        // The title has accents; the search does not need them.
        field.typeText("resume parser")
        XCTAssertTrue(waitFor(15) { listed.exists && !self.element("archived-card_done").exists })
        sleep(1)
        shot("search-06-archived-search")

        listed.press(forDuration: 1.0)
        XCTAssertTrue(menuItem("Bring back to board").waitForExistence(timeout: 15))
        shot("search-07-archived-menu")
        menuItem("Bring back to board").tap()
        XCTAssertTrue(waitFor(15) { !listed.exists }, "the card brought back is still listed")
        shot("search-08-archived-after")

        // The search covers the bar: closing it shows Done again.
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(app.buttons["archivedDone"].waitForExistence(timeout: 10))
        XCTAssertFalse(listed.exists, "the card brought back is in the archive list")
        app.buttons["archivedDone"].tap()
        // The backlog is below the fold, and a list only holds the rows near the screen.
        let card = app.buttons["card-card_older"]
        for _ in 0..<8 where !card.exists || !card.isHittable { app.swipeUp(velocity: .slow) }
        shot("search-09-board-after")
        XCTAssertTrue(card.exists, "the card is not on the board")
    }
}
