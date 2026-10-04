import XCTest

/// Composer drafts, the keyboard, queued prompts, images, text selection
/// and terminal scrolling, against the demo server:
///
///     .build/debug/kanban-code-remote-demo --port 7790 --pair iPhone --tmux-socket kc-demo
///
/// `--tmux-socket` makes the tmux cards real tmux sessions, which the
/// terminal scroll test needs.
final class ChatAndTerminalTests: KanbanUITestCase {

    // MARK: Drafts

    func testDraftSurvivesLeavingTheCardAndRelaunching() throws {
        openCard("card_wait")
        let text = "Draft that must survive"
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        clearComposer()
        composer.tap()
        composer.typeText(text)
        goBack()
        openCard("card_wait")
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertEqual(composer.value as? String, text)

        app.terminate()
        try launch(linkKey: "KC_PAIR_LINK")
        openCard("card_wait")
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertEqual(composer.value as? String, text)
        shot("20-draft-restored")
        clearComposer()
    }

    // MARK: Keyboard

    func testComposerSitsAboveTheKeyboardAndATapPutsItAway() throws {
        openCard("card_wait")
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "no software keyboard; turn off I/O > Keyboard > Connect Hardware Keyboard")
        composer.typeText("Checking the lay")
        sleep(1)
        shot("21-keyboard-up")
        XCTAssertLessThanOrEqual(composer.frame.maxY, keyboard.frame.minY + 1,
                                 "the composer is under the keyboard: \(composer.frame) vs \(keyboard.frame)")
        XCTAssertTrue(app.buttons["send"].isHittable)

        // A tap on the conversation puts the keyboard away.
        tapConversation()
        XCTAssertTrue(waitFor(5) { !app.keyboards.firstMatch.exists })
        shot("22-keyboard-dismissed")
        clearComposer()
    }

    /// The composer's whole box, + and send included, sits above the
    /// keyboard and its suggestion bar, however the keyboard came up.
    func testComposerBottomRowStaysAboveTheKeyboard() throws {
        let keyboard = app.keyboards.firstMatch
        func check(_ step: String) {
            XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "\(step): no keyboard")
            sleep(1)
            let send = app.buttons["send"]
            XCTAssertTrue(send.exists, "\(step): no send button")
            XCTAssertLessThanOrEqual(send.frame.maxY, keyboard.frame.minY + 1,
                                     "\(step): send is under the keyboard: \(send.frame) vs \(keyboard.frame)")
            XCTAssertLessThanOrEqual(app.buttons["attach"].frame.maxY, keyboard.frame.minY + 1, "\(step): + is under the keyboard")
        }
        openCard("card_wait")
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        clearComposer()
        tapConversation()
        XCTAssertTrue(waitFor(5) { !keyboard.exists })

        composer.tap()
        check("first focus")
        shot("21a-keyboard-empty-composer")
        composer.typeText("Hello")
        check("typed")
        clearComposer()
        check("cleared")

        tapConversation()
        XCTAssertTrue(waitFor(5) { !keyboard.exists })
        // A tap on the box's empty space, beside the buttons.
        app.buttons["attach"].coordinate(withNormalizedOffset: CGVector(dx: 3, dy: 0.5)).tap()
        check("focus from the box")

        // Leave with the keyboard up and come back.
        goBack()
        openCard("card_wait")
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        check("after coming back")

        // Through the terminal tab and back.
        app.segmentedControls["cardTabs"].buttons["Terminal"].tap()
        sleep(1)
        app.segmentedControls["cardTabs"].buttons["Chat"].tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        check("after the terminal tab")

        // Drag the chat down a little, as if to dismiss, and let go.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.3))
        start.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.55)))
        if keyboard.exists { check("after a short drag") }
        tapConversation()
    }

    // MARK: Queued prompts

    func testQueuedPromptsMenuSendsNowEditsAndDeletes() throws {
        openCard("card_busy")
        let queued = app.descendants(matching: .any).matching(identifier: "queuedPrompt")
        let bubble = app.descendants(matching: .any).matching(identifier: "queuedBubble").firstMatch
        XCTAssertTrue(queued.firstMatch.waitForExistence(timeout: 10))
        // Busy with nothing typed: send is a stop button.
        XCTAssertTrue(app.buttons["stop"].waitForExistence(timeout: 5))

        // Edit takes it off the queue and into the composer.
        bubble.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["Send now"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Delete"].exists)
        shot("23-queued-menu")
        app.buttons["Edit"].tap()
        XCTAssertTrue(waitFor(10) { queued.count == 0 })
        XCTAssertEqual(composer.value as? String, "Also run the e2e suite once it passes")
        shot("24-queued-edit")

        // Sending it again queues it again; Delete drops it.
        app.buttons["send"].tap()
        XCTAssertTrue(waitFor(10) { queued.count == 1 })
        tapConversation()
        bubble.press(forDuration: 1.0)
        app.buttons["Delete"].tap()
        XCTAssertTrue(waitFor(10) { queued.count == 0 })

        // Send now from the menu delivers it.
        composer.tap()
        composer.typeText("Now this one")
        app.buttons["send"].tap()
        XCTAssertTrue(waitFor(10) { queued.count == 1 })
        tapConversation()
        bubble.press(forDuration: 1.0)
        app.buttons["Send now"].tap()
        XCTAssertTrue(waitFor(10) { queued.count == 0 })
        XCTAssertTrue(waitFor(10) { message(containing: "Now this one").exists })
        XCTAssertFalse(message(containing: "Also run the e2e suite").exists)
        shot("25-queued-sent")

        // Touch and hold send, then Send now: sent now, never queued.
        composer.tap()
        composer.typeText("Stop and do this instead")
        app.buttons["send"].press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["Stash"].waitForExistence(timeout: 5))
        app.buttons["Send now"].tap()
        XCTAssertTrue(waitFor(10) { message(containing: "Stop and do this instead").exists })
        XCTAssertEqual(queued.count, 0)
    }

    // MARK: Stash

    func testStashSetsAMessageAsideAndBringsItBack() throws {
        openCard("card_wait")
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        let unstash = app.buttons["unstash"]
        // Stashes are kept per card; start from none.
        for _ in 0..<5 where unstash.exists {
            clearComposer()
            unstash.tap()
            clearComposer()
        }
        XCTAssertFalse(unstash.exists)

        composer.tap()
        composer.typeText("Stashed idea")
        app.buttons["send"].press(forDuration: 1.0)
        app.buttons["Stash"].tap()
        XCTAssertTrue(unstash.waitForExistence(timeout: 5))
        XCTAssertTrue(waitFor(5) { (composer.value as? String).map { $0.isEmpty || $0 == "Message" } ?? true })
        tapConversation()
        sleep(1)
        shot("43-composer-unstash")

        // Tapping it swaps: the typed text is stashed, the stash comes back.
        composer.tap()
        composer.typeText("Current text")
        unstash.tap()
        XCTAssertEqual(composer.value as? String, "Stashed idea")
        XCTAssertTrue(unstash.exists)

        // Touch and hold lists the stashes to restore or delete.
        unstash.press(forDuration: 1.0)
        app.buttons["Current text"].firstMatch.tap()
        app.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(waitFor(5) { !unstash.exists })
        clearComposer()
    }

    // MARK: Composer

    func testComposerStates() throws {
        openCard("card_wait")
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        clearComposer()
        tapConversation()
        sleep(1)
        shot("40-composer-empty")
        XCTAssertFalse(app.buttons["send"].isEnabled)
        composer.tap()
        let tabsTop = app.segmentedControls["cardTabs"].frame.minY
        composer.typeText("First line of a longer prompt\nSecond line with more detail\nThird line\nFourth line")
        sleep(1)
        shot("41-composer-multiline-keyboard")
        XCTAssertLessThanOrEqual(app.buttons["send"].frame.maxY, app.keyboards.firstMatch.frame.minY + 1)
        // The header stays put; only the chat makes room.
        XCTAssertEqual(app.segmentedControls["cardTabs"].frame.minY, tabsTop, accuracy: 1)
        XCTAssertTrue(app.buttons["send"].isEnabled)
        tapConversation()
        XCTAssertTrue(waitFor(5) { !app.keyboards.firstMatch.exists })
        sleep(1)
        shot("42-composer-multiline")
        clearComposer()
    }

    // MARK: Images

    func testAttachAnImageFromThePhotoLibrary() throws {
        openCard("card_wait")
        let attach = app.buttons["attach"]
        XCTAssertTrue(attach.waitForExistence(timeout: 10))
        clearComposer()
        composer.tap()
        composer.typeText("Compare")
        pickFirstPhoto()
        let attachment = app.descendants(matching: .any).matching(identifier: "attachment").firstMatch
        XCTAssertTrue(attachment.waitForExistence(timeout: 15))
        // The marker goes in at the caret.
        XCTAssertEqual(composer.value as? String, "Compare [Image #1] ")
        tapConversation()
        sleep(1)
        shot("26-attachment-marker")

        // Deleting into the marker takes it whole, and its image with it.
        composer.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.95)).tap()
        composer.typeText(XCUIKeyboardKey.delete.rawValue + XCUIKeyboardKey.delete.rawValue)
        XCTAssertTrue(waitFor(5) { !attachment.exists })
        XCTAssertEqual(composer.value as? String, "Compare ")

        pickFirstPhoto()
        XCTAssertTrue(attachment.waitForExistence(timeout: 15))
        composer.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.95)).tap()
        composer.typeText("with the design")
        XCTAssertEqual(composer.value as? String, "Compare [Image #1] with the design")
        shot("26b-attachment-keyboard")
        tapConversation()
        app.buttons["send"].tap()
        XCTAssertTrue(waitFor(15) { message(containing: "Compare [Image #1] with the design").exists })
        XCTAssertFalse(message(containing: "[image]").exists)
        XCTAssertFalse(attachment.exists)
        tapConversation()
        sleep(1)
        shot("27-image-sent")
    }

    /// Picks the first photo of the library through + > Photos.
    private func pickFirstPhoto() {
        app.buttons["attach"].tap()
        app.buttons["Photos"].firstMatch.tap()
        // The system picker: pick the first photo, then Done.
        let photo = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 15), "no photos in the simulator; add one with xcrun simctl addmedia")
        // The picker's first-run privacy notice covers the grid.
        let close = app.buttons["Close"].firstMatch
        if close.waitForExistence(timeout: 2) { close.tap() }
        sleep(1)
        // The grid sits under an overlay that XCUITest counts as covering it.
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(waitEnabled(done))
        done.tap()
    }

    // MARK: Selection

    func testPartOfAMessageCanBeSelected() throws {
        openCard("card_wait")
        let done = message(containing: "The change is in place and the tests pass.")
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        // Touch and hold on "change", mid-sentence.
        done.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).press(forDuration: 1.2)
        let copy = app.menuItems["Copy"].exists ? app.menuItems["Copy"] : app.buttons["Copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "no edit menu after a long press")
        shot("28-text-selected")
        copy.tap()
        // Paste it into the composer: the app reads its own copy with no
        // paste prompt, where the test runner would get one.
        clearComposer()
        composer.tap()
        composer.press(forDuration: 1.2)
        let paste = app.menuItems["Paste"].exists ? app.menuItems["Paste"] : app.buttons["Paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        paste.tap()
        let copied = (composer.value as? String) ?? ""
        XCTAssertFalse(copied.isEmpty || copied == "Message")
        XCTAssertTrue("Done. The change is in place and the tests pass.".contains(copied.trimmingCharacters(in: .whitespaces)))
        XCTAssertLessThan(copied.count, "Done. The change is in place and the tests pass.".count,
                          "the whole message was copied, not a part: \(copied)")
        clearComposer()
    }

    // MARK: Blank chat

    func testALongChatShowsItsMessagesEveryTimeItOpens() throws {
        for round in 0..<6 {
            openCard(round.isMultiple(of: 2) ? "card_wait" : "card_busy")
            let last = message(containing: "The change is in place and the tests pass.")
            XCTAssertTrue(last.waitForExistence(timeout: 10), "round \(round): no messages")
            XCTAssertTrue(waitFor(5) { last.isHittable }, "round \(round): the last message is not on screen")
            // The keyboard shrinks the chat; the end stays drawn above it.
            composer.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            XCTAssertTrue(waitFor(5) { last.isHittable }, "round \(round): blank chat with the keyboard up")
            if round == 0 { shot("29-long-chat-keyboard") }
            tapConversation()
            XCTAssertTrue(waitFor(5) { !app.keyboards.firstMatch.exists })
            XCTAssertTrue(waitFor(5) { last.isHittable }, "round \(round): blank chat after the keyboard went away")
            goBack()
        }
    }

    /// A chat whose last two messages are very long opens at its true end,
    /// every time, and stays where the user scrolled to.
    func testAChatWithLongLastMessagesOpensAtItsEnd() throws {
        for round in 0..<4 {
            openCard("card_long")
            let end = message(containing: "End of the release notes.")
            XCTAssertTrue(end.waitForExistence(timeout: 10), "round \(round): no messages")
            XCTAssertTrue(waitFor(5) { end.isHittable }, "round \(round): the chat did not open at its end")
            sleep(1)
            XCTAssertTrue(end.isHittable, "round \(round): the chat moved off its end")
            if round == 0 { shot("50-long-chat-opened") }
            if round == 1 {
                // Scrolled up to read, it stays there.
                app.swipeDown(velocity: .slow)
                sleep(2)
                XCTAssertFalse(end.isHittable, "the chat went back to its end while reading")
                shot("51-long-chat-reading")
            }
            goBack()
        }
    }

    /// A pasted log of thousands of lines and a code block holding one line
    /// of JSON hundreds of KB long open in seconds, cut with a way to show
    /// the rest, and the app keeps answering: going back works at once.
    func testAHugeChatOpensWithoutStalling() throws {
        let card = app.buttons["card-card_huge"]
        XCTAssertTrue(app.buttons["card-card_wait"].waitForExistence(timeout: 30))
        for _ in 0..<6 where !card.isHittable { app.swipeUp() }
        let start = Date()
        card.tap()
        XCTAssertTrue(app.buttons["showWholeMessage"].firstMatch.waitForExistence(timeout: 30), "long messages are not cut")
        shot("52-huge-chat")
        goBack()
        XCTAssertTrue(app.buttons["newTask"].waitForExistence(timeout: 30), "the board did not come back")
        let took = Date().timeIntervalSince(start)
        XCTAssertLessThan(took, 30, "opening and leaving the huge chat took \(took) s")
    }

    // MARK: Terminal

    func testTerminalScrollsTmuxHistory() throws {
        openCard("card_wait")
        app.segmentedControls["cardTabs"].buttons["Terminal"].tap()
        let terminal = app.descendants(matching: .any)["terminalView"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        sleep(2)
        app.buttons["terminalKeyboard"].tap()
        sleep(1)
        app.typeText("tmux set -g mouse off; clear; seq 1 400\n")
        XCTAssertTrue(waitFor(10) { screen(terminal).contains("400") })
        app.buttons["terminalKeyboard"].tap()
        sleep(1)

        // Mouse off: the Mac drives tmux copy-mode.
        terminal.swipeDown()
        XCTAssertTrue(waitFor(10) { copyModePosition(screen(terminal)) != nil },
                      "no copy-mode after a swipe: \(screen(terminal).suffix(300))")
        shot("30-terminal-scrolled")
        terminal.swipeUp(velocity: .fast)
        terminal.swipeUp(velocity: .fast)
        XCTAssertTrue(waitFor(10) { copyModePosition(screen(terminal)) == nil }, "copy-mode did not end at the bottom")

        // Mouse on: tmux reads SGR wheel events from the phone.
        app.buttons["terminalKeyboard"].tap()
        sleep(1)
        app.typeText("tmux set -g mouse on; clear; seq 1 400\n")
        app.buttons["terminalKeyboard"].tap()
        sleep(2)
        terminal.swipeDown()
        XCTAssertTrue(waitFor(10) { copyModePosition(screen(terminal)) != nil },
                      "no copy-mode from wheel events: \(screen(terminal).suffix(300))")
        shot("31-terminal-wheel-scrolled")
        app.buttons["terminalKeyboard"].tap()
        app.typeText("q")
        app.typeText("tmux set -g mouse off; clear\n")
    }

    // MARK: Helpers

    private func clearComposer() {
        let field = composer
        // The caret goes where the tap lands: tap past the end of the text.
        // A long draft scrolls in the field, so go until it is empty.
        for _ in 0..<5 {
            guard field.exists, let value = field.value as? String, !value.isEmpty, value != "Message" else { return }
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.95)).tap()
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count + 5))
        }
    }

    private func screen(_ terminal: XCUIElement) -> String {
        (terminal.value as? String) ?? ""
    }

    /// tmux's copy-mode position, e.g. `[12/400]`, or nil outside copy-mode.
    private func copyModePosition(_ text: String) -> String? {
        text.range(of: #"\[\d+/\d+\]"#, options: .regularExpression).map { String(text[$0]) }
    }
}

/// Markdown tables in assistant messages, against the demo server's
/// `card_table`.
final class MarkdownTableTests: KanbanUITestCase {
    func testTablesShowAsGridsAndAWideOneScrollsOnItsOwn() throws {
        openCard("card_table")
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        let tables = app.descendants(matching: .any).matching(identifier: "markdownTable")
        XCTAssertTrue(tables.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(message(containing: "Say the word").waitForExistence(timeout: 5))

        // Cells are text of their own, with no pipes and no separator row.
        XCTAssertTrue(message(containing: "Old links.json backups").exists)
        XCTAssertFalse(message(containing: "|---").exists)
        XCTAssertFalse(message(containing: "| What").exists)
        // An escaped pipe is in its cell.
        XCTAssertTrue(message(containing: "a | b branches").exists)
        let suffix = ProcessInfo.processInfo.environment["KC_SHOT_SUFFIX"] ?? ""
        shot("73-table-three-columns\(suffix)")

        // The seven-column table is above; it scrolls sideways alone.
        app.swipeDown()
        let wide = app.scrollViews["markdownTableScroll"]
        XCTAssertTrue(wide.waitForExistence(timeout: 5))
        XCTAssertTrue(message(containing: "du -sh * | sort -h").exists)
        shot("74-table-wide\(suffix)")
        wide.swipeLeft()
        XCTAssertTrue(waitFor(5) { self.message(containing: "Rebuilt on the next build").isHittable })
        shot("75-table-wide-scrolled\(suffix)")
    }
}
