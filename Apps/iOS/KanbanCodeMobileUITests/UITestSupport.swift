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

    func launch(linkKey: String, extraEnv: [String: String] = [:]) throws {
        let env = ProcessInfo.processInfo.environment
        let link = try XCTUnwrap(env[linkKey], "Set TEST_RUNNER_\(linkKey)")
        // A leftover "Open in Kanban Code?" prompt from simctl openurl.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.buttons["Cancel"].waitForExistence(timeout: 1) { springboard.buttons["Cancel"].tap() }
        app = XCUIApplication()
        app.launchEnvironment["KANBANCODE_PAIR_LINK"] = link
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
        app.navigationBars.buttons.element(boundBy: 0).tap()
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

    func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
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
