import XCTest

/// Walks the main flows against a running server and saves screenshots.
///
/// Environment (pass with the TEST_RUNNER_ prefix through xcodebuild):
/// - KC_PAIR_LINK: kanbancode://pair link of the server under test
/// - KC_SHOT_DIR: directory on the Mac where screenshots are written
final class FlowTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        try launch(linkKey: "KC_PAIR_LINK")
    }

    private func launch(linkKey: String, extraEnv: [String: String] = [:]) throws {
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

    func test1Board() throws {
        let firstCard = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'card-'")).firstMatch
        XCTAssertTrue(firstCard.waitForExistence(timeout: 15))
        sleep(1)
        shot("01-board")
        app.swipeDown()
        shot("02-board-search")
    }

    func test2ChatAndSend() throws {
        openFirstCard()
        sleep(2)
        shot("03-chat")
        let composer = app.textViews["composer"].exists ? app.textViews["composer"] : app.textFields["composer"]
        guard composer.waitForExistence(timeout: 5) else {
            shot("03b-chat-not-live")
            return
        }
        composer.tap()
        composer.typeText("Also run the tests, please")
        shot("04-chat-typing")
        app.buttons["send"].tap()
        sleep(2)
        shot("05-chat-sent")
    }

    func test1bLongColumnsCollapse() throws {
        app.terminate()
        try launch(linkKey: "KC_PAIR_LINK", extraEnv: ["KANBANCODE_COLUMN_PREVIEW": "1"])
        let showAll = app.buttons["showAll-live"]
        XCTAssertTrue(showAll.waitForExistence(timeout: 15))
        XCTAssertTrue(showAll.label.hasPrefix("Show all"))
        shot("01b-board-collapsed")
        showAll.tap()
        XCTAssertTrue(app.buttons["showAll-live"].label == "Show fewer")
    }

    func test1cProjectFilter() throws {
        let filter = app.buttons["projectFilter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 15))
        XCTAssertTrue(waitEnabled(filter))
        filter.tap()
        app.buttons["acme-api"].firstMatch.tap()
        sleep(1)
        shot("01c-board-filtered")
        XCTAssertFalse(app.buttons["card-card_wait"].exists)
        XCTAssertTrue(app.buttons["card-card_agtop"].exists)
        filter.tap()
        app.buttons["All projects"].firstMatch.tap()
        XCTAssertTrue(app.buttons["card-card_wait"].waitForExistence(timeout: 5))
    }

    func test2bOlderMessages() throws {
        openCard("card_wait")
        sleep(2)
        let before = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Step 1:'")).count
        for _ in 0..<12 { app.scrollViews.firstMatch.swipeDown(velocity: .fast) }
        sleep(2)
        shot("05b-chat-older")
        XCTAssertEqual(before, 0)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Step 1:'")).firstMatch.exists
            || app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Step 2:'")).firstMatch.exists)
    }

    func test3NewTask() throws {
        let newTask = app.buttons["newTask"]
        XCTAssertTrue(newTask.waitForExistence(timeout: 15))
        XCTAssertTrue(waitEnabled(newTask))
        newTask.tap()
        let prompt = app.textViews["taskPrompt"].exists ? app.textViews["taskPrompt"] : app.textFields["taskPrompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 5))
        prompt.tap()
        prompt.typeText("Add a health check endpoint")
        app.switches["worktreeToggle"].switches.firstMatch.tap()
        shot("06-new-task")
        app.buttons["launchTask"].tap()
        sleep(3)
        shot("07-new-task-card")
    }

    func test4Terminal() throws {
        openFirstCard()
        let tabs = app.segmentedControls["cardTabs"]
        guard tabs.waitForExistence(timeout: 5) else {
            XCTFail("No terminal tab")
            return
        }
        tabs.buttons["Terminal"].tap()
        sleep(3)
        shot("08-terminal")
        app.buttons["terminalKeyboard"].tap()
        sleep(1)
        app.typeText("ls\n")
        sleep(2)
        shot("09-terminal-ls")
    }

    func test5TerminalPickerAndFullScreen() throws {
        openCard("card_busy")
        app.segmentedControls["cardTabs"].buttons["Terminal"].tap()
        let picker = app.buttons["terminalPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        sleep(2)
        shot("10-terminal-busy")
        picker.tap()
        sleep(1)
        shot("11-terminal-picker")
        app.buttons["shell"].firstMatch.tap()
        sleep(2)
        app.buttons["Full screen"].tap()
        sleep(2)
        shot("12-terminal-full-screen")
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        shot("13-terminal-landscape")
        XCUIDevice.shared.orientation = .portrait
        sleep(1)
        app.buttons["Done"].tap()
    }

    func test6ResumeNotLive() throws {
        openCard("card_codex")
        let resume = app.buttons["resumeBar"]
        guard resume.waitForExistence(timeout: 5) else {
            throw XCTSkip("card_codex is already live; restart the demo server")
        }
        sleep(1)
        shot("14-not-live")
        resume.tap()
        sleep(2)
        shot("15-resumed")
    }

    func test7AgentScopeHasNoTerminal() throws {
        try launch(linkKey: "KC_AGENT_PAIR_LINK")
        sleep(3)
        openCard("card_wait")
        sleep(1)
        XCTAssertFalse(app.segmentedControls["cardTabs"].exists)
        shot("16-agent-scope-card")
    }

    // MARK: helpers

    private func openCard(_ id: String) {
        let card = app.buttons["card-\(id)"]
        if !card.waitForExistence(timeout: 10) {
            app.swipeUp()
        }
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
    }

    private func openFirstCard() {
        let firstCard = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'card-'")).firstMatch
        XCTAssertTrue(firstCard.waitForExistence(timeout: 15))
        firstCard.tap()
    }

    private func waitEnabled(_ element: XCUIElement) -> Bool {
        let done = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: element)
        return XCTWaiter.wait(for: [done], timeout: 10) == .completed
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
