import Foundation
import Testing
@testable import KanbanCode

@Suite("BrowserDevTools")
struct BrowserDevToolsTests {

    // MARK: - Eruda initialization script

    @Test("Initialization script calls eruda.init with shadow DOM enabled")
    func initScriptContainsErudaInit() {
        let script = ErudaScript.initializationScript
        #expect(script.contains("eruda.init"))
        #expect(script.contains("useShadowDom"))
        #expect(script.contains("true"))
    }

    @Test("Initialization script hides the default Eruda entry button")
    func initScriptHidesEntryButton() {
        let script = ErudaScript.initializationScript
        // After init, the floating gear button should be hidden
        #expect(script.contains("eruda.hide"))
    }

    @Test("Initialization script guards against double-init")
    func initScriptGuardsDoubleInit() {
        let script = ErudaScript.initializationScript
        // Should check if eruda is already initialized before calling init again
        #expect(script.contains("typeof eruda") || script.contains("window.eruda"))
    }

    // MARK: - Toggle scripts

    @Test("Show script calls eruda.show()")
    func showScript() {
        let script = ErudaScript.showScript
        #expect(script.contains("eruda.show()"))
    }

    @Test("Hide script calls eruda.hide()")
    func hideScript() {
        let script = ErudaScript.hideScript
        #expect(script.contains("eruda.hide()"))
    }

    @Test("Toggle script for visible state produces hide")
    func toggleWhenVisible() {
        let script = ErudaScript.toggleScript(currentlyVisible: true)
        #expect(script.contains("eruda.hide()"))
    }

    @Test("Toggle script for hidden state produces show")
    func toggleWhenHidden() {
        let script = ErudaScript.toggleScript(currentlyVisible: false)
        #expect(script.contains("eruda.show()"))
    }

    // MARK: - Bundle loading

    @Test("Eruda script file exists in app resources bundle")
    func erudaScriptFileExists() {
        let url = Bundle.appResources.url(forResource: "eruda.min", withExtension: "js")
        #expect(url != nil, "eruda.min.js must be present in Resources/")
    }

    @Test("Eruda script file is non-empty")
    func erudaScriptFileNonEmpty() throws {
        let url = try #require(Bundle.appResources.url(forResource: "eruda.min", withExtension: "js"))
        let data = try Data(contentsOf: url)
        #expect(data.count > 1000, "eruda.min.js should be a substantial JS file")
    }

    @Test("Full injection script combines eruda library and init call")
    func fullInjectionScript() throws {
        let script = try ErudaScript.fullInjectionScript()
        // Should contain the eruda library code
        #expect(script.count > 1000, "Full script should include the eruda library")
        // Should end with initialization
        #expect(script.contains("eruda.init"))
    }
}
