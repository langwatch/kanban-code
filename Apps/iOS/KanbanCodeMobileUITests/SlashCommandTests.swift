import XCTest

/// The list of commands over the composer while a `/name` is typed,
/// against the demo server.
final class SlashCommandTests: KanbanUITestCase {
    private var list: XCUIElement { app.scrollViews["slashCommandList"] }

    private func clearComposer() {
        guard let text = composer.value as? String, !text.isEmpty, text != "Message" else { return }
        composer.tap()
        composer.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: text.count))
    }

    func testTheListFiltersWhileTypingAndATapCompletes() throws {
        openCard("card_wait")
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        clearComposer()
        composer.tap()

        composer.typeText("/")
        XCTAssertTrue(app.buttons["slash-catchup"].waitForExistence(timeout: 5))
        shot("70-slash-all")
        XCTAssertTrue(waitFor(5) { app.buttons["slash-btw"].exists })
        XCTAssertTrue(waitFor(5) { app.buttons["slash-compact"].exists })

        composer.typeText("cat")
        XCTAssertTrue(waitFor(5) { app.buttons["slash-catalog:search"].exists && !app.buttons["slash-btw"].exists })
        XCTAssertTrue(app.buttons["slash-catchup"].exists)
        shot("71-slash-filtered")

        app.buttons["slash-catchup"].tap()
        XCTAssertTrue(waitFor(5) { (composer.value as? String) == "/catchup " })
        XCTAssertTrue(waitFor(5) { !app.buttons["slash-catchup"].exists })
        shot("72-slash-completed")

        // A plain message shows no list.
        clearComposer()
        composer.typeText("see /catchup")
        XCTAssertFalse(app.buttons["slash-catchup"].exists)
        clearComposer()
    }
}
