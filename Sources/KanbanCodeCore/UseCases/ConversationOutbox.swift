import Foundation
import KanbanCodeRemoteKit

/// Conversation messages sent from this app wait in
/// `AppState.conversationOutbox` until the conversation's log shows them.
public enum ConversationOutbox {
    /// Whether `message` in the log is `prompt` sent from here. A card this
    /// master owns logs it under the prompt's id. Another master logs it
    /// under its own id, so there it is the human's message with the same
    /// text, written no earlier than the prompt (a minute of clock skew
    /// between machines allowed).
    public static func delivers(_ message: RemoteConversationMessage, _ prompt: QueuedPrompt) -> Bool {
        if message.id == prompt.id { return true }
        guard message.role == .human,
              message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                == prompt.body.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        let written = prompt.humanWrittenAt ?? .distantPast
        return message.at >= written.addingTimeInterval(-60)
    }
}
