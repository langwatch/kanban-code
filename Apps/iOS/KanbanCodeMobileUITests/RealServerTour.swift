import XCTest

/// View-only walk through a real Mac: board, one card's chat and terminal.
/// It never types, sends, interrupts or resumes. Runs only when
/// KC_REAL_PAIR_LINK and KC_REAL_CARD are set (TEST_RUNNER_ prefix).
final class RealServerTour: XCTestCase {
    func testTour() throws {
        let env = ProcessInfo.processInfo.environment
        guard let link = env["KC_REAL_PAIR_LINK"], let cardId = env["KC_REAL_CARD"] else {
            throw XCTSkip("No real server configured")
        }
        let app = XCUIApplication()
        app.launchEnvironment["KANBANCODE_PAIR_LINK"] = link
        app.launch()

        let anyCard = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'card-'")).firstMatch
        XCTAssertTrue(anyCard.waitForExistence(timeout: 20))
        sleep(3)
        shot("01-board")
        app.swipeUp()
        sleep(1)
        shot("02-board-scrolled")
        app.swipeDown()
        app.swipeDown()

        let search = app.searchFields.firstMatch
        if search.waitForExistence(timeout: 3) {
            search.tap()
            search.typeText("Kanban Chat")
        }
        let card = app.buttons["card-\(cardId)"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()
        sleep(4)
        shot("03-card-chat")
        app.scrollViews.firstMatch.swipeDown(velocity: .fast)
        sleep(2)
        shot("04-card-chat-scrolled")

        let tabs = app.segmentedControls["cardTabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 5))
        tabs.buttons["Terminal"].tap()
        sleep(4)
        shot("05-card-terminal")
    }

    private func shot(_ name: String) {
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
