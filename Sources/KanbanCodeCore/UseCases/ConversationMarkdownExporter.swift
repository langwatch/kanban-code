import Foundation

/// Converts native assistant transcripts into a plain message-only Markdown log.
public enum ConversationMarkdownExporter {
    public static func exportMarkdown(
        title: String,
        assistant: CodingAssistant,
        sessionId: String?,
        sessionPath: String,
        sessionStore: SessionStore
    ) async throws -> String {
        let turns: [ConversationTurn]
        switch assistant {
        case .claude:
            var streamed: [ConversationTurn] = []
            for await turn in TranscriptReader.streamAllTurns(from: sessionPath) {
                streamed.append(turn)
            }
            turns = streamed
        case .codex:
            turns = try await CodexSessionParser.readTurns(from: sessionPath)
        case .gemini:
            turns = try await sessionStore.readTranscript(sessionPath: sessionPath)
        }

        return markdown(
            title: title,
            assistant: assistant,
            sessionId: sessionId,
            turns: turns
        )
    }

    static func markdown(
        title: String,
        assistant: CodingAssistant,
        sessionId: String?,
        turns: [ConversationTurn]
    ) -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines: [String] = [
            "# \(trimmedTitle.isEmpty ? "Conversation" : trimmedTitle)",
            "",
            "_Assistant: \(assistant.displayName)_"
        ]

        if let sessionId = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !sessionId.isEmpty {
            lines.append("_Session: `\(sessionId)`_")
        }
        lines.append("")

        for turn in turns {
            guard let heading = heading(for: turn.role, assistant: assistant) else { continue }
            let text = messageText(for: turn).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            lines.append("## \(heading)")
            lines.append("")
            lines.append(text)
            lines.append("")
        }

        return lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private static func heading(for role: String, assistant: CodingAssistant) -> String? {
        switch role {
        case "user":
            return "User"
        case "assistant":
            return assistant.displayName
        default:
            return nil
        }
    }

    private static func messageText(for turn: ConversationTurn) -> String {
        let textBlocks = turn.contentBlocks.compactMap { block -> String? in
            if case .text = block.kind { return block.text }
            return nil
        }

        if !textBlocks.isEmpty {
            return textBlocks.joined(separator: "\n\n")
        }

        return turn.textPreview
    }
}
