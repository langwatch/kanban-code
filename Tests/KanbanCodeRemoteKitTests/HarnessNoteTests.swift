import Foundation
import Testing
@testable import KanbanCodeRemoteKit

@Suite("Harness notes")
struct HarnessNoteTests {
    static let summary = """
        This session is being continued from a previous conversation that ran out of context. \
        The summary below covers the earlier portion of the conversation.

        Summary:
        1. Primary Request and Intent: fix the export.

        Continue the conversation from where it left off without asking the user any further questions.
        """

    @Test("a compaction summary is a note that reads Conversation compacted")
    func compactionSummary() {
        #expect(HarnessNote.classify(Self.summary) == .compactionSummary)
        #expect(HarnessNote.classify("\n  " + Self.summary) == .compactionSummary)
        #expect(HarnessNote.compactionSummary.title == "Conversation compacted")
    }

    @Test("the /compact command is a note, with its instructions and without the echo of its name")
    func compactCommand() {
        #expect(HarnessNote.classify("/compact") == .compactCommand("/compact"))
        #expect(HarnessNote.classify("/compact\n\ncompact") == .compactCommand("/compact"))
        #expect(HarnessNote.classify("/compact keep the PR list ") == .compactCommand("/compact keep the PR list"))
        #expect(HarnessNote.compactCommand("/compact keep the PR list").title == "/compact keep the PR list")
    }

    @Test("what the human wrote stays a message")
    func messages() {
        #expect(HarnessNote.classify("fix it") == nil)
        #expect(HarnessNote.classify("/compacted is not a command") == nil)
        #expect(HarnessNote.classify("run /compact when you are done") == nil)
        #expect(HarnessNote.classify("/clear") == nil)
        #expect(HarnessNote.classify("He said: This session is being continued from a previous conversation") == nil)
        #expect(HarnessNote.classify("") == nil)
    }

    @Test("a message without detail decodes, and detail round trips")
    func detailOnTheWire() throws {
        let old = try JSONDecoder().decode(RemoteMessage.self, from: Data(#"{"id":"1.0","role":"system","text":"Interrupted"}"#.utf8))
        #expect(old.detail == nil)
        let note = RemoteMessage(id: "2.0", role: .system, text: HarnessNote.compactedTitle, detail: Self.summary)
        let back = try JSONDecoder().decode(RemoteMessage.self, from: JSONEncoder().encode(note))
        #expect(back == note)
    }
}
