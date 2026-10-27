import XCTest

/// Conversations inside one card (docs/conversations.md), against the demo
/// server. `card_wait` starts with two: "Theme switch without restart",
/// unread and continued from an agent message, and an untitled one.
///
/// A conversation's composer is Main's, under the same identifiers. The
/// image test needs a photo in the simulator: `xcrun simctl addmedia booted <png>`.
final class ConversationTests: KanbanUITestCase {

    private func row(_ id: String) -> XCUIElement { app.buttons["conversation-card_wait-\(id)"] }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Opens a new conversation of `card_wait` from the compose button.
    private func startConversation() {
        openCard("card_wait")
        let compose = app.buttons["newConversation"]
        XCTAssertTrue(compose.waitForExistence(timeout: 10))
        compose.tap()
        XCTAssertTrue(app.navigationBars["New conversation"].waitForExistence(timeout: 10))
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
    }

    func testConversationsUnderTheCardOpenReplyAndArchive() throws {
        let theme = row("swift-otter")
        XCTAssertTrue(theme.waitForExistence(timeout: 15))
        XCTAssertTrue(theme.label.contains("Theme switch without restart"))
        XCTAssertTrue(theme.label.contains("unread"))
        // No waiting marker: the row shows its title and last message.
        XCTAssertFalse(theme.label.localizedCaseInsensitiveContains("waiting"))
        XCTAssertTrue(theme.label.contains("Yes. The page can observe the theme"))
        XCTAssertTrue(row("calm-heron").label.contains("New conversation"))
        XCTAssertFalse(row("calm-heron").label.contains("unread"))
        shot("80-conversations-on-board")

        theme.tap()
        XCTAssertTrue(app.navigationBars["Theme switch without restart"].waitForExistence(timeout: 10))
        XCTAssertTrue(element("conversationQuote").waitForExistence(timeout: 5))
        XCTAssertTrue(message(containing: "Should I also animate the switch").waitForExistence(timeout: 10))
        shot("81-conversation-open")

        composer.tap()
        composer.typeText("Keep it instant")
        app.buttons["send"].tap()
        XCTAssertTrue(message(containing: "Keep it instant").waitForExistence(timeout: 5))
        // Listed by the master: shown at full weight, no longer pending.
        XCTAssertTrue(waitFor(10) { !self.element("conversationPending").exists })
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

        // Opened from the board, back lands on the board, which shows it read.
        goBack()
        XCTAssertTrue(waitFor(10) { self.row("swift-otter").exists && !self.row("swift-otter").label.contains("unread") })
        XCTAssertFalse(composer.exists)
        shot("83-conversation-read-on-board")

        // A swipe from the left edge goes back to the board too.
        row("swift-otter").tap()
        XCTAssertTrue(app.navigationBars["Instant theme switch"].waitForExistence(timeout: 10))
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        XCTAssertTrue(row("swift-otter").waitForExistence(timeout: 10))
        XCTAssertFalse(composer.exists)

        // Archive takes it off the card, back on the board.
        row("swift-otter").tap()
        XCTAssertTrue(app.buttons["conversationMenu"].waitForExistence(timeout: 10))
        app.buttons["conversationMenu"].tap()
        app.buttons["conversationArchive"].tap()
        XCTAssertTrue(waitFor(10) { !self.row("swift-otter").exists })
    }

    /// Holding a conversation row offers Rename; the row and the conversation
    /// take the new title, and the title in the conversation renames too.
    func testRenameAConversationFromItsRow() throws {
        let untitled = row("calm-heron")
        XCTAssertTrue(untitled.waitForExistence(timeout: 15))
        untitled.press(forDuration: 1.0)
        let rename = app.buttons["conversationRename"]
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["conversationArchive"].exists)
        shot("90-conversation-row-menu")
        rename.tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Release notes")
        app.buttons["conversationRenameConfirm"].firstMatch.tap()
        XCTAssertTrue(waitFor(10) { self.row("calm-heron").label.contains("Release notes") })
        shot("91-conversation-renamed-row")

        row("calm-heron").tap()
        XCTAssertTrue(app.navigationBars["Release notes"].waitForExistence(timeout: 10))
        let title = app.buttons["conversationTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "Release notes")

        // The title renames it again, prefilled with the current one.
        title.tap()
        let again = app.alerts.textFields.firstMatch
        XCTAssertTrue(again.waitForExistence(timeout: 5))
        XCTAssertEqual(again.value as? String, "Release notes")
        again.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        again.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 15) + "Release notes v2")
        app.buttons["conversationRenameConfirm"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Release notes v2"].waitForExistence(timeout: 10))
        shot("92-conversation-renamed-title")
        goBack()
        XCTAssertTrue(waitFor(10) { self.row("calm-heron").label.contains("Release notes v2") })
    }

    func testComposeButtonStartsAConversation() throws {
        openCard("card_wait")
        XCTAssertTrue(app.buttons["newConversation"].waitForExistence(timeout: 10))
        shot("84-compose-button")
        goBack()
        startConversation()
        composer.tap()
        composer.typeText("Can we harden the vault next?")
        app.buttons["send"].tap()
        XCTAssertTrue(message(containing: "Got it: Can we harden the vault next?").waitForExistence(timeout: 20))
        // The demo agent names an untitled conversation on its first reply.
        XCTAssertTrue(app.navigationBars.matching(NSPredicate(format: "identifier BEGINSWITH 'Demo topic'")).firstMatch
            .waitForExistence(timeout: 10))
        shot("85-new-conversation")
    }

    /// The human's own message continues too: the new conversation quotes it
    /// with the agent's reply, and opens ready to write in.
    func testHoldYourMessageToContinueItWithTheReply() throws {
        openCard("card_wait")
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText("Plan the theme toggle")
        app.buttons["send"].tap()
        XCTAssertTrue(message(containing: "Got it: Plan the theme toggle").waitForExistence(timeout: 20))
        // The bubble, not the reply that repeats its text.
        let mine = app.textViews.matching(NSPredicate(format: "label == %@", "Plan the theme toggle")).firstMatch
        XCTAssertTrue(mine.waitForExistence(timeout: 10))
        // The keyboard goes away first: the chat moves when it does.
        tapConversation()
        XCTAssertTrue(waitFor(5) { !self.app.keyboards.firstMatch.exists })
        mine.press(forDuration: 1.0)
        let item = app.menuItems["Continue in new conversation"]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        shot("92-continue-your-message-menu")
        item.tap()
        XCTAssertTrue(app.navigationBars["New conversation"].waitForExistence(timeout: 10))
        let quote = element("conversationQuote")
        XCTAssertTrue(quote.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Continued from your message"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["and the reply"].exists)
        XCTAssertTrue(message(containing: "Got it: Plan the theme toggle").exists)
        // The composer has the keyboard.
        XCTAssertTrue(waitFor(5) { (self.composer.value(forKey: "hasKeyboardFocus") as? Bool) == true })
        shot("93-continued-your-message")
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
        XCTAssertTrue(element("conversationQuote").waitForExistence(timeout: 5))
        shot("87-continued-conversation")
    }

    /// An image goes with the message; the phone shows a chip for it once
    /// the master lists the message, since the master keeps the file.
    func testAnImageGoesWithAConversationMessage() throws {
        startConversation()
        composer.tap()
        composer.typeText("here is the screen ")
        // The image's marker goes where the caret is, after the text.
        pickFirstPhoto()
        XCTAssertTrue(element("attachment").waitForExistence(timeout: 15))
        shot("88-conversation-attachment")
        app.buttons["send"].tap()
        XCTAssertTrue(element("conversationImage").waitForExistence(timeout: 10))
        XCTAssertTrue(message(containing: "here is the screen").waitForExistence(timeout: 5))
        XCTAssertFalse(element("attachment").exists)
        XCTAssertTrue(message(containing: "Got it:").waitForExistence(timeout: 20))
        // Listed by the master: the thumbnail comes from it, and opens full screen.
        let image = app.buttons.matching(identifier: "conversationImage").firstMatch
        XCTAssertTrue(waitFor(15) { image.exists && image.label == "Image" })
        shot("89-conversation-image-sent")
        image.tap()
        XCTAssertTrue(element("conversationImageViewer").waitForExistence(timeout: 10))
        shot("94-conversation-image-viewer")
        app.buttons["conversationImageViewerClose"].tap()
        XCTAssertTrue(waitFor(5) { !self.element("conversationImageViewer").exists })
        XCTAssertTrue(composer.exists)
    }

    /// A send the master refuses leaves the message in the composer with the
    /// error, as Main does, and nothing in the conversation.
    func testAFailedSendKeepsTheDraftAndShowsTheError() throws {
        startConversation()
        composer.tap()
        composer.typeText("Ship it [demo: fail]")
        app.buttons["send"].tap()
        let error = element("conversationSendError")
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertTrue((composer.value as? String)?.contains("Ship it [demo: fail]") == true)
        XCTAssertFalse(element("conversationHuman").exists)
        XCTAssertFalse(element("conversationPending").exists)
        shot("90-conversation-send-failed")
    }

    /// A key in the text gets the vault offer before anything is sent, as in Main.
    func testASecretInAConversationMessageOffersTheVault() throws {
        startConversation()
        composer.tap()
        composer.typeText("use key sk-proj-Qm7vT2xLp9Rk4Wn8Zb3Hc6Yd1Fg5Js0Ae_Uq-Vt8Nr2Mx for the deploy")
        app.buttons["send"].tap()
        XCTAssertTrue(element("vaultSecretOffer").waitForExistence(timeout: 10))
        XCTAssertFalse(element("conversationHuman").exists)
        shot("91-conversation-vault-offer")
        app.buttons["vaultSendAsIs"].tap()
        XCTAssertTrue(waitFor(10) { !self.element("vaultSecretOffer").exists })
        XCTAssertTrue(message(containing: "for the deploy").waitForExistence(timeout: 10))
    }
}
