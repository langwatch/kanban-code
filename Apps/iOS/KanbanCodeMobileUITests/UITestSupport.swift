import XCTest

/// Launch, navigation and screenshot helpers shared by the UI tests.
///
/// Environment (pass with the TEST_RUNNER_ prefix through xcodebuild):
/// - KC_PAIR_LINK: kanbancode://pair link of the server under test
/// - KC_SHOT_DIR: directory on the Mac where screenshots are written
class KanbanUITestCase: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        try launch(linkKey: "KC_PAIR_LINK")
    }

    /// Launches paired with the server `linkKey` names, as primary, and with
    /// the servers `moreLinkKeys` name; every other saved server is forgotten.
    func launch(linkKey: String, moreLinkKeys: [String] = [], extraEnv: [String: String] = [:]) throws {
        let env = ProcessInfo.processInfo.environment
        let link = try XCTUnwrap(env[linkKey], "Set TEST_RUNNER_\(linkKey)")
        let more = try moreLinkKeys.map { try XCTUnwrap(env[$0], "Set TEST_RUNNER_\($0)") }
        // A leftover "Open in Kanban Code?" prompt from simctl openurl.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.buttons["Cancel"].waitForExistence(timeout: 1) { springboard.buttons["Cancel"].tap() }
        app = XCUIApplication()
        app.launchEnvironment["KANBANCODE_PAIR_LINK"] = link
        app.launchEnvironment["KANBANCODE_PAIR_LINKS"] = more.joined(separator: " ")
        app.launchEnvironment["KANBANCODE_PAIR_ONLY"] = "1"
        app.launchEnvironment.merge(extraEnv) { $1 }
        app.launch()
    }

    func openCard(_ id: String) {
        let card = app.buttons["card-\(id)"]
        if !card.waitForExistence(timeout: 10) {
            app.swipeUp()
        }
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
    }

    func openFirstCard() {
        let firstCard = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'card-'")).firstMatch
        XCTAssertTrue(firstCard.waitForExistence(timeout: 15))
        firstCard.tap()
    }

    func goBack() {
        let inBar = app.navigationBars.buttons.element(boundBy: 0)
        if inBar.exists {
            inBar.tap()
            return
        }
        // Bars shown as a vertical column at the side (a folded iPhone Duo).
        let back = app.buttons.matching(NSPredicate(format: "identifier == 'BackButton' OR label == 'Back'")).firstMatch
        if back.exists {
            back.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        }
    }

    /// The chat's message field (a text view once it grows past one line).
    var composer: XCUIElement {
        app.textViews["composer"].exists ? app.textViews["composer"] : app.textFields["composer"]
    }

    /// Message text, shown as selectable text views.
    func message(containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "(elementType == %d OR elementType == %d) AND (label CONTAINS %@ OR value CONTAINS %@)",
            XCUIElement.ElementType.textView.rawValue, XCUIElement.ElementType.staticText.rawValue, text, text
        )).firstMatch
    }

    /// Taps the conversation above the composer, right of the demo's short
    /// lines (clear of the back-swipe edge on the left and the scroll
    /// indicator on the right), by screen position: with the keyboard up, a
    /// coordinate taken from the chat's scroll view does not land on what
    /// is shown.
    func tapConversation() {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.33)).tap()
    }

    /// The composer's box with its margins, down to the keyboard or the
    /// home indicator.
    var composerBar: XCUIElement { app.otherElements["composerBar"] }

    /// Keyboard up: the card's header, tabs and title are gone and the
    /// composer sits on the keyboard. Keyboard down: they are back and the
    /// composer sits on the bottom safe area, no gap under it.
    func assertComposingLayout(keyboardUp: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let keyboard = app.keyboards.firstMatch
        let header = app.otherElements["cardHeader"]
        if keyboardUp {
            XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "no keyboard", file: file, line: line)
            XCTAssertTrue(waitFor(5) { !header.exists }, "the card header stays over the chat", file: file, line: line)
            sleep(1)
            XCTAssertFalse(app.segmentedControls["cardTabs"].exists, "the tabs stay over the chat", file: file, line: line)
            XCTAssertFalse(app.staticTexts["cardColumnTitle"].exists, "the title stays over the chat", file: file, line: line)
            XCTAssertFalse(app.buttons["newConversation"].exists, "the card's bar stays over the chat", file: file, line: line)
            // The keyboard element leaves out the suggestion bar (44 pt)
            // over it, which the composer sits on.
            let gap = keyboard.frame.minY - composerBar.frame.maxY
            XCTAssertTrue((-1...4).contains(gap) || (40...48).contains(gap),
                          "the composer is \(gap) pt off the keyboard: \(composerBar.frame) vs \(keyboard.frame)",
                          file: file, line: line)
        } else {
            if !waitFor(5, { !keyboard.exists }) { dump("keyboard-still-up") }
            XCTAssertFalse(keyboard.exists, "the keyboard is still up", file: file, line: line)
            XCTAssertTrue(header.waitForExistence(timeout: 5), "the card header did not come back", file: file, line: line)
            sleep(1)
            XCTAssertTrue(app.staticTexts["cardColumnTitle"].exists, "the title did not come back", file: file, line: line)
            // The box (send plus its 10 pt padding) stops 16 pt above the
            // bottom edge, just over the home indicator, or on the edge's
            // safe margin where there is no indicator.
            let send = app.buttons["send"].exists ? app.buttons["send"] : app.buttons["stop"]
            let gap = app.windows.firstMatch.frame.maxY - (send.frame.maxY + 10)
            XCTAssertTrue((0...20).contains(gap), "the composer is \(gap) pt off the bottom: \(send.frame)",
                          file: file, line: line)
        }
    }

    /// With the keyboard up, taps in the composer's text keep it up, and
    /// one tap on send sends: the text leaves the field and shows in the
    /// chat, and the keyboard stays.
    func assertComposerKeepsTheKeyboard(file: StaticString = #filePath, line: UInt = #line) {
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "no keyboard", file: file, line: line)
        composer.tap()
        composer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(1)
        XCTAssertTrue(keyboard.exists, "a tap in the composer put the keyboard away", file: file, line: line)
        let text = "Sent with one tap \(Int(Date().timeIntervalSince1970) % 100000)"
        composer.typeText(text)
        app.buttons["send"].tap()
        XCTAssertTrue(waitFor(10) { (self.composer.value as? String).map { $0.isEmpty || $0 == "Message" } ?? true },
                      "one tap on send did not send", file: file, line: line)
        XCTAssertTrue(message(containing: text).waitForExistence(timeout: 10), "the sent text is not in the chat",
                      file: file, line: line)
        XCTAssertTrue(keyboard.exists, "send put the keyboard away", file: file, line: line)
    }

    /// Drags the chat down, as when reading back.
    func scrollChat() {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.25))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)))
    }

    func waitFor(_ timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }

    func waitEnabled(_ element: XCUIElement) -> Bool {
        let done = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: element)
        return XCTWaiter.wait(for: [done], timeout: 10) == .completed
    }

    /// Picks the first photo of the library through + > Photos.
    func pickFirstPhoto() {
        app.buttons["attach"].tap()
        app.buttons["Photos"].firstMatch.tap()
        // The system picker: pick the first photo, then Done.
        let photo = app.images.matching(identifier: "PXGGridLayout-Info")
            .matching(NSPredicate(format: "NOT label BEGINSWITH[c] 'video'")).firstMatch
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

    /// Picks the first video of the library through + > Photos.
    func pickFirstVideo() {
        app.buttons["attach"].tap()
        app.buttons["Photos"].firstMatch.tap()
        let grid = app.images.matching(identifier: "PXGGridLayout-Info")
        XCTAssertTrue(grid.firstMatch.waitForExistence(timeout: 15))
        let close = app.buttons["Close"].firstMatch
        if close.waitForExistence(timeout: 2) { close.tap() }
        sleep(1)
        let video = grid.matching(NSPredicate(format: "label BEGINSWITH[c] 'video'")).firstMatch
        XCTAssertTrue(video.exists, "no video in the picker; add one with xcrun simctl addmedia: \(grid.allElementsBoundByIndex.map { $0.label })")
        video.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(waitEnabled(done))
        done.tap()
    }

    /// A screenshot and the element tree, for a failure CI has to explain.
    func dump(_ name: String) {
        shot("debug-\(name)")
        if let dir = ProcessInfo.processInfo.environment["KC_SHOT_DIR"] {
            try? app.debugDescription.write(toFile: dir + "/debug-\(name).txt", atomically: true, encoding: .utf8)
        }
    }

    func shot(_ name: String) {
        // A foldable has a screen per display and only one shows the app;
        // the one that is off is a black image, the smallest PNG.
        let screenshot = XCUIScreen.screens.map { $0.screenshot() }
            .max { $0.pngRepresentation.count < $1.pngRepresentation.count } ?? XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["KC_SHOT_DIR"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }
}
