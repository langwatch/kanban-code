import XCTest

/// Conversations inside one card (docs/conversations.md), against the demo
/// server. `card_wait` starts with two: "Theme switch without restart",
/// waiting on the human and unread, and an untitled one waiting on the agent.
final class ConversationTests: KanbanUITestCase {

    private var conversationComposer: XCUIElement {
        app.textViews["conversationComposer"].exists ? app.textViews["conversationComposer"] : app.textFields["conversationComposer"]
    }

    private func row(_ id: String) -> XCUIElement { app.buttons["conversation-card_wait-\(id)"] }

    func testConversationsUnderTheCardOpenReplyAndArchive() throws {
        let waiting = row("swift-otter")
        XCTAssertTrue(waiting.waitForExistence(timeout: 15))
        XCTAssertTrue(waiting.label.contains("Theme switch without restart"))
        XCTAssertTrue(waiting.label.contains("unread"))
        XCTAssertTrue(waiting.label.contains("waiting on you"))
        XCTAssertTrue(row("calm-heron").label.contains("New conversation"))
        shot("80-conversations-on-board")

        waiting.tap()
        XCTAssertTrue(app.navigationBars["Theme switch without restart"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["conversationQuote"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(message(containing: "Should I also animate the switch").waitForExistence(timeout: 10))
        shot("81-conversation-open")

        conversationComposer.tap()
        conversationComposer.typeText("Keep it instant")
        app.buttons["conversationSend"].tap()
        XCTAssertTrue(message(containing: "Keep it instant").waitForExistence(timeout: 5))
        XCTAssertTrue(message(containing: "Got it: Keep it instant").waitForExistence(timeout: 20))
        shot("82-conversation-reply")

        // Rename from the menu.
        app.buttons["conversationMenu"].tap()
        app.buttons["conversationRename"].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let old = (field.value as? String) ?? ""
        // The caret at the end of the current title.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count + 2) + "Instant theme switch")
        app.buttons["conversationRenameConfirm"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Instant theme switch"].waitForExistence(timeout: 10))

        // Back lands on the card's chat, then the board shows it read.
        goBack()
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        goBack()
        XCTAssertTrue(waitFor(10) { row("swift-otter").exists && !row("swift-otter").label.contains("unread") })
        shot("83-conversation-read-on-board")

        // Archive takes it off the card.
        row("swift-otter").tap()
        XCTAssertTrue(app.buttons["conversationMenu"].waitForExistence(timeout: 10))
        app.buttons["conversationMenu"].tap()
        app.buttons["conversationArchive"].tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        goBack()
        XCTAssertTrue(waitFor(10) { !row("swift-otter").exists })
    }

    func testComposeButtonStartsAConversation() throws {
        openCard("card_wait")
        let compose = app.buttons["newConversation"]
        XCTAssertTrue(compose.waitForExistence(timeout: 10))
        shot("84-compose-button")
        compose.tap()
        XCTAssertTrue(app.navigationBars["New conversation"].waitForExistence(timeout: 10))
        XCTAssertTrue(conversationComposer.waitForExistence(timeout: 5))
        conversationComposer.tap()
        conversationComposer.typeText("Can we harden the vault next?")
        app.buttons["conversationSend"].tap()
        XCTAssertTrue(message(containing: "Got it: Can we harden the vault next?").waitForExistence(timeout: 20))
        // The demo agent names an untitled conversation on its first reply.
        XCTAssertTrue(app.navigationBars.matching(NSPredicate(format: "identifier BEGINSWITH 'Demo topic'")).firstMatch
            .waitForExistence(timeout: 10))
        shot("85-new-conversation")
    }

    func testHoldAnAgentMessageToContinueInANewConversation() throws {
        openCard("card_wait")
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        // The demo's last agent message.
        let target = message(containing: "the tests pass")
        XCTAssertTrue(target.waitForExistence(timeout: 10))
        target.press(forDuration: 1.0)
        let item = app.menuItems["Continue in new conversation"]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        shot("86-continue-menu")
        item.tap()
        XCTAssertTrue(app.navigationBars["New conversation"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["conversationQuote"].firstMatch.waitForExistence(timeout: 5))
        shot("87-continued-conversation")
    }
}
