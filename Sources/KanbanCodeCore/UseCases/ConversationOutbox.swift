import Foundation
import KanbanCodeRemoteKit

/// Conversation messages sent from this app wait in
/// `AppState.conversationOutbox` until the conversation's log shows them.
/// A send that failed waits in `AppState.failedPrompts` with Retry; one that
/// landed after all (its answer was lost) leaves both once the log shows it.
public enum ConversationOutbox {
    /// How long a sent message may wait for the log to show it, from when
    /// its last send ended, before it shows as failed with Retry.
    public static let unconfirmedAfter: TimeInterval = 90

    /// Whether `message` in the log is `prompt` sent from here. The owner
    /// logs it under the prompt's id. A master from before sender ids logs
    /// it under its own id, so there it is the human's message with the
    /// same text, written no earlier than the prompt (a minute of clock
    /// skew between machines allowed).
    public static func delivers(_ message: RemoteConversationMessage, _ prompt: QueuedPrompt) -> Bool {
        if message.id == prompt.id { return true }
        guard message.role == .human,
              message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                == prompt.body.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        let written = prompt.humanWrittenAt ?? .distantPast
        return message.at >= written.addingTimeInterval(-60)
    }

    /// The ids of `prompts` the log's `messages` show.
    public static func delivered(_ prompts: [QueuedPrompt], in messages: [RemoteConversationMessage]) -> [String] {
        prompts.filter { prompt in messages.contains { delivers($0, prompt) } }.map(\.id)
    }

    /// The prompts of `outbox` the log has not shown in `timeout` since
    /// their last send ended (`sentAt`, else when written), with no send of
    /// theirs running (`sending`).
    public static func unconfirmed(_ outbox: [QueuedPrompt], sending: Set<String>, sentAt: [String: Date],
                                   now: Date, timeout: TimeInterval = unconfirmedAfter) -> [QueuedPrompt] {
        outbox.filter { prompt in
            guard !sending.contains(prompt.id) else { return false }
            let since = sentAt[prompt.id] ?? prompt.humanWrittenAt ?? now
            return now.timeIntervalSince(since) >= timeout
        }
    }
}
