import Testing
@testable import KanbanCodeCore

@Suite("Prompt Image Layout")
struct PromptImageLayoutTests {
    @Test("parts split text around image markers")
    func partsSplitTextAroundMarkers() {
        let parts = PromptImageLayout.parts(
            in: "before [Image #1] middle [Image #2] after",
            imageCount: 2
        )
        #expect(parts == [
            .init(text: "before "),
            .init(text: "", imageIndex: 0),
            .init(text: " middle "),
            .init(text: "", imageIndex: 1),
            .init(text: " after"),
        ])
    }

    @Test("invalid markers stay as text")
    func invalidMarkersStayText() {
        let parts = PromptImageLayout.parts(in: "a [Image #3] b", imageCount: 1)
        #expect(parts == [.init(text: "a [Image #3] b")])
    }

    @Test("markdown replacement keeps image position")
    func markdownReplacementKeepsPosition() {
        let text = PromptImageLayout.replacingMarkersWithMarkdown(
            in: "a [Image #1] b",
            imagePaths: ["/tmp/x.png"]
        )
        #expect(text == "a ![](/tmp/x.png) b")
    }

    @Test("markdown replacement appends legacy images when no marker exists")
    func markdownReplacementAppendsLegacyImages() {
        let text = PromptImageLayout.replacingMarkersWithMarkdown(
            in: "a",
            imagePaths: ["/tmp/x.png"]
        )
        #expect(text == "a\n![](/tmp/x.png)")
    }
}
