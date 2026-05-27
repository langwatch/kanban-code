import Testing
@testable import KanbanCodeCore

@Suite("ConversationMarkdownExporter")
struct ConversationMarkdownExporterTests {
    @Test("Exports only user and assistant text blocks")
    func exportsOnlyMessageText() {
        let turns = [
            ConversationTurn(
                index: 0,
                lineNumber: 1,
                role: "user",
                textPreview: "Please fix it",
                contentBlocks: [
                    ContentBlock(kind: .text, text: "Please fix it")
                ]
            ),
            ConversationTurn(
                index: 1,
                lineNumber: 2,
                role: "assistant",
                textPreview: "tool",
                contentBlocks: [
                    ContentBlock(kind: .toolUse(name: "Bash", input: ["cmd": "swift test"]), text: "Bash(cmd: swift test)"),
                    ContentBlock(kind: .toolResult(toolName: "Bash"), text: "Build output"),
                    ContentBlock(kind: .thinking, text: "private reasoning")
                ]
            ),
            ConversationTurn(
                index: 2,
                lineNumber: 3,
                role: "assistant",
                textPreview: "Done",
                contentBlocks: [
                    ContentBlock(kind: .text, text: "Done")
                ]
            ),
            ConversationTurn(
                index: 3,
                lineNumber: 4,
                role: "system",
                textPreview: "hidden",
                contentBlocks: [
                    ContentBlock(kind: .text, text: "hidden")
                ]
            )
        ]

        let markdown = ConversationMarkdownExporter.markdown(
            title: "Fix Login",
            assistant: .claude,
            sessionId: "session-1",
            turns: turns
        )

        #expect(markdown.contains("# Fix Login"))
        #expect(markdown.contains("_Assistant: Claude Code_"))
        #expect(markdown.contains("_Session: `session-1`_"))
        #expect(markdown.contains("## User\n\nPlease fix it"))
        #expect(markdown.contains("## Claude Code\n\nDone"))
        #expect(!markdown.contains("swift test"))
        #expect(!markdown.contains("Build output"))
        #expect(!markdown.contains("private reasoning"))
        #expect(!markdown.contains("hidden"))
    }

    @Test("Falls back to textPreview for legacy empty-block turns")
    func textPreviewFallback() {
        let markdown = ConversationMarkdownExporter.markdown(
            title: "",
            assistant: .codex,
            sessionId: nil,
            turns: [
                ConversationTurn(index: 0, lineNumber: 1, role: "assistant", textPreview: "Legacy reply")
            ]
        )

        #expect(markdown.contains("# Conversation"))
        #expect(markdown.contains("## Codex CLI\n\nLegacy reply"))
    }
}
