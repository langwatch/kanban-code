import XCTest

/// The layout at regular width (an unfolded iPhone Duo, an iPad): the board
/// in a sidebar and the open card beside it; and folding back to compact
/// width keeps the card open. Needs only the single demo master
/// (TEST_RUNNER_KC_PAIR_LINK).
///
/// Folding is asked of the host: with TEST_RUNNER_KC_FOLD_DIR set, the test
/// writes `fold` (or `unfold`) into that directory and waits for the host to
/// fold the simulator and answer with `folded` (or `unfolded`; `half` bends
/// it to 90 degrees and answers `halved`). Without it
/// the fold steps are skipped.
final class DuoLayoutTests: KanbanUITestCase {

    func test1SidebarAndCardSideBySide() throws {
        try requireRegularWidth()
        shot("duo-01-unfolded-board")

        openCard("card_wait")
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        assertSideBySide(sidebarCard: "card_rush")
        assertSidebarIsAThird(sidebarCard: "card_rush")
        XCTAssertTrue(app.staticTexts.matching(identifier: "messageTime").firstMatch.waitForExistence(timeout: 10), "no message time")
        shot("duo-02-unfolded-card")

        // Another card from the sidebar replaces the detail, the board stays.
        openCard("card_rush")
        XCTAssertTrue(waitFor(10) { self.composer.exists })
        assertSideBySide(sidebarCard: "card_wait")
        XCTAssertFalse(app.descendants(matching: .any)["noCardOpen"].exists)
        shot("duo-03-unfolded-other-card")
    }

    func test2FoldingKeepsTheCardOpen() throws {
        try requireRegularWidth()
        let env = ProcessInfo.processInfo.environment
        guard let foldDir = env["KC_FOLD_DIR"] else {
            throw XCTSkip("no TEST_RUNNER_KC_FOLD_DIR: this device cannot be folded from the test")
        }
        openCard("card_wait")
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText("Draft across the fold")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.2)).tap()

        try ask(host: foldDir, "fold", answer: "folded")
        sleep(2)
        // Compact width: one stack, the card on top of the board, with a
        // way back and the same draft.
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertEqual(composer.value as? String, "Draft across the fold")
        XCTAssertFalse(app.buttons["card-card_rush"].isHittable)
        if let dir = env["KC_SHOT_DIR"] {
            try? app.debugDescription.write(toFile: dir + "/duo-04-folded-card.txt", atomically: true, encoding: .utf8)
        }
        // The keyboard comes back with the composer's focus; put it away.
        if app.keyboards.firstMatch.exists { app.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.35)).tap() }
        shot("duo-04-folded-card")

        goBack()
        XCTAssertTrue(app.buttons["card-card_rush"].waitForExistence(timeout: 10))
        shot("duo-05-folded-board")

        openCard("card_wait")
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        try ask(host: foldDir, "unfold", answer: "unfolded")
        sleep(2)
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        assertSideBySide(sidebarCard: "card_rush")
        assertSidebarIsAThird(sidebarCard: "card_rush")
        shot("duo-06-unfolded-again")
        clearDraft()
    }

    /// Half open (90 degrees, held like a book) the inner display is still
    /// one screen: the sidebar keeps its width from the left edge and the
    /// card fills the rest, across the fold.
    func test3HalfOpenIsStillOneScreen() throws {
        try requireRegularWidth()
        guard let foldDir = ProcessInfo.processInfo.environment["KC_FOLD_DIR"] else {
            throw XCTSkip("no TEST_RUNNER_KC_FOLD_DIR: this device cannot be folded from the test")
        }
        openCard("card_wait")
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        clearDraft()
        try ask(host: foldDir, "half", answer: "halved")
        sleep(2)
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        dismissKeyboard()
        assertSideBySide(sidebarCard: "card_rush")
        assertSidebarIsAThird(sidebarCard: "card_rush")
        shot("duo-07-half-open-card")
        try ask(host: foldDir, "unfold", answer: "unfolded")
    }

    /// Unfolded and folded, typing gives the chat the whole height, and a
    /// tap on the chat or a scroll of the
    /// board or the chat puts the keyboard away.
    func test4TypingGivesTheChatTheWholeScreen() throws {
        try requireRegularWidth()
        openCard("card_wait")
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        clearDraft()
        assertComposingLayout(keyboardUp: false)
        shot("duo-08-composer-on-the-bottom")
        composer.tap()
        sleep(2)
        shot("duo-09-typing-unfolded")
        assertComposingLayout(keyboardUp: true)
        assertComposerKeepsTheKeyboard()
        shot("duo-10-sent-one-tap")
        tapChatAboveComposer()
        assertComposingLayout(keyboardUp: false)

        composer.tap()
        assertComposingLayout(keyboardUp: true)
        // Scrolling the board, from its top row: a row under the keyboard
        // would swipe-type into the composer instead.
        let row = app.buttons["card-card_busy"]
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 2.2)))
        assertComposingLayout(keyboardUp: false)

        composer.tap()
        assertComposingLayout(keyboardUp: true)
        scrollChat()
        assertComposingLayout(keyboardUp: false)

        guard let foldDir = ProcessInfo.processInfo.environment["KC_FOLD_DIR"] else { return }
        try ask(host: foldDir, "fold", answer: "folded")
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        sleep(2)
        assertComposingLayout(keyboardUp: false)
        composer.tap()
        sleep(2)
        shot("duo-14-typing-folded")
        assertComposingLayout(keyboardUp: true)
        tapChatAboveComposer()
        assertComposingLayout(keyboardUp: false)
        try ask(host: foldDir, "unfold", answer: "unfolded")
    }

    /// Going to the home screen or the app switcher and back keeps the
    /// sidebar beside the open card.
    func test5SidebarSurvivesTheBackground() throws {
        try requireRegularWidth()
        openCard("card_wait")
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        assertSideBySide(sidebarCard: "card_rush")
        for round in 1...2 {
            XCUIDevice.shared.press(.home)
            sleep(3)
            app.activate()
            XCTAssertTrue(composer.waitForExistence(timeout: 10), "round \(round): the card closed")
            sleep(1)
            assertSideBySide(sidebarCard: "card_rush")
        }
        shot("duo-11-back-from-background")
    }

    /// Held upright (taller than wide) the sidebar lies over the card, as
    /// on an iPad in portrait: picking a card hides it.
    func test6UprightSidebarHidesOnPick() throws {
        try requireRegularWidth()
        let start = XCUIDevice.shared.orientation
        defer { XCUIDevice.shared.orientation = start }
        let window = app.windows.firstMatch
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait, .landscapeRight] {
            XCUIDevice.shared.orientation = orientation
            sleep(2)
            if window.frame.height > window.frame.width { break }
        }
        guard window.frame.height > window.frame.width else { throw XCTSkip("the display does not turn upright") }

        let rush = app.buttons["card-card_rush"]
        if !(rush.waitForExistence(timeout: 5) && rush.isHittable) { showSidebar() }
        XCTAssertTrue(rush.isHittable, "the sidebar does not show")
        shot("duo-12-upright-sidebar")
        openCard("card_wait")
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertTrue(waitFor(5) { !rush.exists || !rush.isHittable }, "the sidebar stays over the card")
        XCTAssertTrue(composer.isHittable, "the card is not on screen")
        shot("duo-13-upright-card")

        showSidebar()
        XCTAssertTrue(rush.waitForExistence(timeout: 5) && rush.isHittable, "the sidebar button does not show it")
        rush.tap()
        XCTAssertTrue(waitFor(5) { !app.buttons["card-card_wait"].exists || !app.buttons["card-card_wait"].isHittable },
                      "the sidebar stays over the second card")
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
    }

    /// A tap on the chat just above the composer, placed from the composer
    /// itself: a tap placed from the app's frame lands elsewhere on the
    /// Duo, which has a window per display.
    private func tapChatAboveComposer() {
        composerBar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: -40)).tap()
    }

    private func showSidebar() {
        let toggle = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'sidebar' OR identifier CONTAINS[c] 'sidebar'")).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "no sidebar button")
        toggle.tap()
        sleep(1)
    }

    // MARK: Helpers

    /// At regular width nothing is selected at launch, so the detail column
    /// shows its placeholder next to the board.
    private func requireRegularWidth() throws {
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'card-'")).firstMatch
            .waitForExistence(timeout: 15))
        let placeholder = app.descendants(matching: .any)["noCardOpen"]
        if placeholder.waitForExistence(timeout: 3) { return }
        shot("duo-00-compact-board")
        // A Duo that boots folded: unfold it when the host can.
        if let foldDir = ProcessInfo.processInfo.environment["KC_FOLD_DIR"] {
            try ask(host: foldDir, "unfold", answer: "unfolded")
            if placeholder.waitForExistence(timeout: 10) { return }
        }
        throw XCTSkip("compact width: the board is a single stack here")
    }

    /// The sidebar's card and the open card's composer are both on screen,
    /// the composer to the right of the sidebar.
    private func assertSideBySide(sidebarCard: String, file: StaticString = #filePath, line: UInt = #line) {
        let row = app.buttons["card-\(sidebarCard)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), file: file, line: line)
        XCTAssertTrue(row.isHittable, "the sidebar is not on screen", file: file, line: line)
        XCTAssertTrue(composer.isHittable, "the card is not on screen", file: file, line: line)
        XCTAssertGreaterThanOrEqual(composer.frame.minX, row.frame.maxX - 1,
                                    "the card is not beside the sidebar", file: file, line: line)
    }

    /// The board has the system sidebar width, a third of the display or
    /// less, and the card gets the rest: one screen, not two halves.
    private func assertSidebarIsAThird(sidebarCard: String, file: StaticString = #filePath, line: UInt = #line) {
        let width = app.windows.firstMatch.frame.width
        XCTAssertLessThanOrEqual(app.buttons["card-\(sidebarCard)"].frame.maxX, width * 0.36,
                                 "the sidebar takes more than a third", file: file, line: line)
        XCTAssertLessThanOrEqual(composer.frame.minX, width * 0.4,
                                 "the card does not start after the sidebar", file: file, line: line)
        XCTAssertFalse(app.staticTexts["Cannot load the conversation"].exists,
                       "the card lost its conversation", file: file, line: line)
    }

    private func ask(host dir: String, _ request: String, answer: String) throws {
        let base = URL(fileURLWithPath: dir)
        let reply = base.appendingPathComponent(answer)
        try? FileManager.default.removeItem(at: reply)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try Data().write(to: base.appendingPathComponent(request))
        XCTAssertTrue(waitFor(90) { FileManager.default.fileExists(atPath: reply.path) },
                      "the host did not answer \(request) with \(answer)")
    }

    /// A tap on the card's title bar takes the composer's focus away.
    private func dismissKeyboard() {
        if app.keyboards.firstMatch.exists { app.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: 0.07)).tap() }
    }

    private func clearDraft() {
        guard let value = composer.value as? String, !value.isEmpty, value != "Message" else { return }
        // Tap at the end of the text so the deletes reach all of it.
        composer.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.25)).tap()
        composer.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count + 2))
        dismissKeyboard()
        XCTAssertTrue(waitFor(5) { (self.composer.value as? String).map { $0.isEmpty || $0 == "Message" } ?? true },
                      "the draft is still there")
    }
}
