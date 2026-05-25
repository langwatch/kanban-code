import Foundation

/// Extracts the last assistant response from a transcript for notification content.
public enum TranscriptNotificationReader {

    /// Get the last assistant text from a transcript file (Claude JSONL format).
    /// Returns nil if the file doesn't exist or has no assistant turns.
    public static func lastAssistantText(transcriptPath: String) async -> String? {
        await lastAssistantText(transcriptPath: transcriptPath, assistant: .claude)
    }

    /// Get the last assistant text without loading the full transcript into memory.
    ///
    /// Notification hooks often fire in bursts, and active Claude transcripts can
    /// be hundreds of MB. Reading only a small tail avoids multiplying those files
    /// into many GB of transient String/JSON allocations.
    public static func lastAssistantText(transcriptPath: String, assistant: CodingAssistant) async -> String? {
        let turns: [ConversationTurn]
        switch assistant {
        case .claude:
            guard let result = try? await TranscriptReader.readTail(from: transcriptPath, maxTurns: 20) else {
                return nil
            }
            turns = result.turns
        case .codex:
            guard let result = try? await CodexSessionParser.readTail(from: transcriptPath, maxTurns: 20) else {
                return nil
            }
            turns = result.turns
        case .gemini:
            guard let parsed = try? await GeminiSessionStore().readTranscript(sessionPath: transcriptPath) else {
                return nil
            }
            turns = parsed
        }
        return lastAssistantText(from: turns)
    }

    /// Get the last assistant text from pre-parsed conversation turns.
    /// Works with turns from any session store (Claude, Gemini, etc.).
    public static func lastAssistantText(from turns: [ConversationTurn]) -> String? {
        guard let lastTurn = turns.last(where: { $0.role == "assistant" }) else { return nil }

        // Join text-only content blocks
        let textBlocks = lastTurn.contentBlocks.compactMap { block -> String? in
            if case .text = block.kind { return block.text }
            return nil
        }

        let text = textBlocks.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Get a short text preview for notification body.
    /// Mirrors claude-pushover's get_text_preview() exactly:
    /// - If first line is >= 42 chars, use it
    /// - Otherwise accumulate sentences (split by ".") until > 140 chars
    public static func textPreview(_ text: String) -> String {
        let firstLine = text.components(separatedBy: "\n").first ?? text
        if firstLine.count >= 42 {
            return firstLine
        }

        // Accumulate sentences until > 140 chars
        let sentences = text.components(separatedBy: ".")
        var accumulated = ""
        for sentence in sentences {
            if sentence.isEmpty { continue }
            if accumulated.isEmpty {
                accumulated = sentence + "."
            } else {
                accumulated += sentence + "."
            }
            if accumulated.count > 140 {
                break
            }
        }

        return accumulated.isEmpty ? firstLine : accumulated
    }
}
