import XCTest

/// Walks the main flows against a running server and saves screenshots.
final class FlowTests: KanbanUITestCase {

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
        let composer = self.composer
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
        let before = message(containing: "Step 1:").exists
        for _ in 0..<12 { app.scrollViews.firstMatch.swipeDown(velocity: .fast) }
        sleep(2)
        shot("05b-chat-older")
        XCTAssertFalse(before)
        XCTAssertTrue(message(containing: "Step 1:").exists || message(containing: "Step 2:").exists)
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
}
