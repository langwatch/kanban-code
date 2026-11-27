import Testing
@testable import KanbanCodeRemoteKit

@Suite("Navigation history")
struct NavigationHistoryTests {
    @Test func backAndForwardWalkTheOpenedCards() {
        var history = NavigationHistory<String>()
        history.record(from: nil, to: "a")
        history.record(from: "a", to: "b")
        history.record(from: "b", to: "c")
        #expect(history.canGoBack(from: "c"))
        #expect(!history.canGoForward(from: "c"))

        #expect(history.back(from: "c") == "b")
        #expect(history.back(from: "b") == "a")
        #expect(!history.canGoBack(from: "a"))
        #expect(history.back(from: "a") == nil)

        #expect(history.forward(from: "a") == "b")
        #expect(history.forward(from: "b") == "c")
        #expect(history.forward(from: "c") == nil)
    }

    @Test func openingANewCardClearsForward() {
        var history = NavigationHistory<String>()
        history.record(from: "a", to: "b")
        #expect(history.back(from: "b") == "a")
        #expect(history.canGoForward(from: "a"))
        history.record(from: "a", to: "c")
        #expect(!history.canGoForward(from: "c"))
        #expect(history.back(from: "c") == "a")
    }

    @Test func skipsCardsThatAreGone() {
        var history = NavigationHistory<String>()
        history.record(from: "a", to: "b")
        history.record(from: "b", to: "c")
        let gone: Set = ["b"]
        #expect(history.canGoBack(from: "c") { !gone.contains($0) })
        #expect(history.back(from: "c") { !gone.contains($0) } == "a")
        #expect(!history.canGoBack(from: "a") { !gone.contains($0) })
    }

    @Test func noRecordWhenNothingChangedAndTheStackIsCapped() {
        var history = NavigationHistory<Int>(limit: 3)
        history.record(from: 1, to: 1)
        #expect(history.backStack.isEmpty)
        for i in 0..<10 { history.record(from: i, to: i + 1) }
        #expect(history.backStack == [7, 8, 9])
    }

    @Test func closingACardKeepsItForBack() {
        var history = NavigationHistory<String>()
        history.record(from: "a", to: nil)
        #expect(history.back(from: nil) == "a")
        #expect(!history.canGoForward(from: "a"))
    }
}
