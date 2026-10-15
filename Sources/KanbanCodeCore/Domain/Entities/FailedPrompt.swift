import Foundation

/// A prompt from a chat composer that did not reach its session, kept so the
/// chat can show why and send it again.
public struct FailedPrompt: Sendable, Equatable, Identifiable {
    public let prompt: QueuedPrompt
    /// What went wrong, as the human reads it.
    public let message: String
    public let failedAt: Date

    public var id: String { prompt.id }

    public init(prompt: QueuedPrompt, message: String, failedAt: Date = .now) {
        self.prompt = prompt
        self.message = message
        self.failedAt = failedAt
    }
}
