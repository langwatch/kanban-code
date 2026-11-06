import AppKit
import Testing

@testable import KanbanCode

@MainActor
@Suite("Conversation message links")
struct ConversationMessageLinksTests {

    private static let appearance = ChatTextAppearance(
        font: .systemFont(ofSize: 13), foregroundColor: .labelColor)

    private static func url(
        of label: String, in content: ChatTextContent, links: ChatTextLinks
    ) -> URL? {
        let attributed = ChatAttributedText.make(
            content: content, appearance: appearance, links: links, width: 600)
        let range = (attributed.string as NSString).range(of: label)
        guard range.location != NSNotFound else {
            Issue.record("label not in the rendered text: \(label)")
            return nil
        }
        return attributed.attribute(.link, at: range.location, effectiveRange: nil) as? URL
    }

    @Test("a fully qualified reference resolves without a repo")
    func qualifiedRefWithoutRepo() {
        let text = "Merged: langwatch/langwatch#9367 (e72816adca). All plans now opens"
        let links = ChatTextLinks.message(text, githubBaseURL: nil)
        #expect(links.issueRefs["langwatch/langwatch#9367"]?.absoluteString
            == "https://github.com/langwatch/langwatch/pull/9367")
        #expect(Self.url(of: "langwatch/langwatch#9367", in: .inlineMarkdown(text), links: links)?
            .absoluteString == "https://github.com/langwatch/langwatch/pull/9367")
    }

    @Test("a bare reference uses the card's repo, and stays text without one")
    func bareRef() {
        let text = "Opened #42 for it."
        #expect(ChatTextLinks.message(text, githubBaseURL: nil).issueRefs.isEmpty)
        let links = ChatTextLinks.message(text, githubBaseURL: "https://github.com/acme/app")
        #expect(links.issueRefs["#42"]?.absoluteString == "https://github.com/acme/app/pull/42")
    }

    @Test("a reference inside backticks is a link too")
    func refInCode() {
        let text = "Merged `acme/app#7` today"
        let links = ChatTextLinks.message(text, githubBaseURL: nil)
        #expect(Self.url(of: "acme/app#7", in: .inlineMarkdown(text), links: links)?
            .absoluteString == "https://github.com/acme/app/pull/7")
    }

    @Test("plain URLs become links, markdown links keep their destination")
    func urls() {
        let text = "See https://example.com/a and [#3](https://example.com/three)."
        let links = ChatTextLinks.message(text, githubBaseURL: "https://github.com/acme/app")
        #expect(links.urls)
        #expect(Self.url(of: "https://example.com/a", in: .inlineMarkdown(text), links: links)?
            .absoluteString == "https://example.com/a")
        #expect(Self.url(of: "#3", in: .inlineMarkdown(text), links: links)?
            .absoluteString == "https://example.com/three")
    }

    @Test("text with no references or URLs has no links")
    func noLinks() {
        #expect(ChatTextLinks.message("All done.", githubBaseURL: "https://github.com/acme/app").isEmpty)
    }
}
