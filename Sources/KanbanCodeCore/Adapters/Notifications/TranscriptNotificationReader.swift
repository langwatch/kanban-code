import Foundation

/// Extracts the last assistant response from a transcript for notification content.
public enum TranscriptNotificationReader {

    /// Get the last assistant text from a transcript file (Claude JSONL format).
    /// Returns nil if the file doesn't exist or has no assistant turns.
    public static func lastAssistantText(transcriptPath: String) async -> String? {
        guard let turns = try? await TranscriptReader.readTurns(from: transcriptPath) else {
            return nil
        }
        return lastAssistantText(from: turns)
    }

    /// Get the last assistant text from pre-parsed conversation turns.
    /// Works with turns from any session store (Claude, Gemini, etc.).
    public static func lastAssistantText(from turns: [ConversationTurn]) -> String? {
        // Find the last assistant turn with text content
        let assistantTurns = turns.filter { $0.role == "assistant" }
        guard let lastTurn = assistantTurns.last else { return nil }

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
