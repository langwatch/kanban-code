import Foundation
import KanbanCodeRemoteKit

/// Where the images of a conversation message are in the card's transcript.
/// The conversation log keeps the image paths of the machine that sent the
/// prompt, which another machine cannot read; the transcript (or this
/// machine's copy of it) holds the images themselves on the prompt's line.
public enum ConversationTranscriptImages {
    /// The user turn that carried the human's `text` in conversation
    /// `conversationId`, the latest when it was sent more than once.
    public static func turn(for text: String, conversationId: String, in turns: [ConversationTurn]) -> ConversationTurn? {
        let wanted = normalized(text)
        guard !wanted.isEmpty else { return nil }
        var prefixMatch: ConversationTurn?
        for turn in turns.reversed() where turn.role == "user" && turn.imageCount > 0 {
            let raw = turn.contentBlocks
                .filter { if case .text = $0.kind { return true }; return false }
                .map(\.text).joined(separator: "\n")
            guard let parsed = ConversationPrompt.parse(raw), parsed.id == conversationId else { continue }
            let body = normalized(parsed.text)
            if body == wanted { return turn }
            // The session may lay images out around the text: the start is
            // enough when no turn matches in full.
            if prefixMatch == nil, body.hasPrefix(String(wanted.prefix(60))) || wanted.hasPrefix(String(body.prefix(60))) {
                prefixMatch = turn
            }
        }
        return prefixMatch
    }

    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
