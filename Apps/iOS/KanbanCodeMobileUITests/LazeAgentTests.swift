import XCTest

/// Cards show the Laze agent of their session as the first item of their
/// metadata line, and the board menu hides the cards agents created, on
/// the demo master (KC_PAIR_LINK).
final class LazeAgentTests: KanbanUITestCase {
    func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    func test1AgentLineAndHidingAgentCards() throws {
        let rush = app.buttons["card-card_rush"]
        XCTAssertTrue(app.buttons["card-card_wait"].waitForExistence(timeout: 40))
        if !rush.exists { app.swipeUp() }
        XCTAssertTrue(rush.waitForExistence(timeout: 10))
        XCTAssertTrue(rush.label.contains("Billing Helper"), "the row does not name its Laze agent: \(rush.label)")
        XCTAssertFalse(app.buttons["card-card_wait"].label.contains("Laze agent"), "a card without an agent names one")
        app.swipeDown()
        shot("laze-01-board-agent-line")

        // Hide the cards agents created: card_long and card_catchup go, the rest stay.
        XCTAssertTrue(app.buttons["card-card_long"].exists || app.buttons["card-card_catchup"].exists)
        app.buttons["boardMenu"].tap()
        let toggle = element("hideAgentCards")
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.tap()
        XCTAssertTrue(waitFor(10) { !self.app.buttons["card-card_long"].exists && !self.app.buttons["card-card_catchup"].exists },
                      "agent-created cards still show")
        XCTAssertTrue(app.buttons["card-card_wait"].exists, "a card the human created is hidden")
        shot("laze-02-agent-cards-hidden")

        // It stays across launches, and turns off again.
        app.terminate()
        try launch(linkKey: "KC_PAIR_LINK")
        XCTAssertTrue(app.buttons["card-card_wait"].waitForExistence(timeout: 40))
        XCTAssertFalse(app.buttons["card-card_long"].exists, "the filter did not stay")
        app.buttons["boardMenu"].tap()
        XCTAssertTrue(element("hideAgentCards").waitForExistence(timeout: 5))
        element("hideAgentCards").tap()
        XCTAssertTrue(app.buttons["card-card_long"].waitForExistence(timeout: 10) || app.buttons["card-card_catchup"].waitForExistence(timeout: 5))

        // The card header names the agent too.
        openCard("card_rush")
        XCTAssertTrue(element("cardLazeAgent").waitForExistence(timeout: 15), "the card header does not show the agent")
        shot("laze-03-card-header-agent")
    }
}
