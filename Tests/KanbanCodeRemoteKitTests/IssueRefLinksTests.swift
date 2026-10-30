import Foundation
import Testing
@testable import KanbanCodeRemoteKit

@Suite("Issue references in chat text")
struct IssueRefLinksTests {
    @Test("owner/repo#N becomes a GitHub pull link")
    func fullReference() {
        let text = "It's added in\nlangwatch/langwatch#9200 (needs review)"
        let found = IssueRefLinks.matches(in: text)
        #expect(found.count == 1)
        #expect((text as NSString).substring(with: found[0].range) == "langwatch/langwatch#9200")
        #expect(found[0].url.absoluteString == "https://github.com/langwatch/langwatch/pull/9200")
    }

    @Test("several references, with dots and dashes in the repo")
    func several() {
        let found = IssueRefLinks.matches(in: "see langwatch/laze#45 and 0xdeafcafe/rush.go-x#6.")
        #expect(found.map(\.url.absoluteString) == [
            "https://github.com/langwatch/laze/pull/45",
            "https://github.com/0xdeafcafe/rush.go-x/pull/6",
        ])
    }

    @Test("URLs, bare #N and HTML entities are left alone")
    func ignored() {
        #expect(IssueRefLinks.matches(in: "https://github.com/langwatch/langwatch#9200").isEmpty)
        #expect(IssueRefLinks.matches(in: "fixed in #9200").isEmpty)
        #expect(IssueRefLinks.matches(in: "a&b/c#123").isEmpty)
    }
}
