import Foundation
import KanbanCodeRemoteKit

/// What the remote control server asks of the app. The app implements it
/// over its store and launch flow; tests implement it with a fake.
public protocol RemoteControlHost: AnyObject, Sendable {
    func board() async -> RemoteBoard

    /// Newest `limit` messages of the card's conversation, older than
    /// `before` when given.
    func transcript(cardId: String, limit: Int, before: String?) async throws -> RemoteTranscript

    /// Creates a card and, unless `launch` is false, starts its session.
    func createTask(_ request: RemoteTaskRequest) async throws -> RemoteCard

    /// `request.images` come checked and decoded by the server as `images`.
    func sendPrompt(cardId: String, _ request: RemotePromptRequest, images: [RemotePromptImages.Decoded]) async throws

    /// Sends a queued prompt at once, interrupting the turn when one runs.
    func sendQueuedPromptNow(cardId: String, promptId: String) async throws

    /// Drops a queued prompt before it goes out.
    func removeQueuedPrompt(cardId: String, promptId: String) async throws

    func interrupt(cardId: String) async throws

    /// Starts the card's session again when it ended; a live one is left as is.
    func resume(cardId: String) async throws -> RemoteCard

    /// The command a remote terminal runs for one of the card's terminals,
    /// as argv: `agtop open <id> --solo` for agtop, `tmux attach -t <name>`
    /// for tmux.
    func terminalCommand(cardId: String, sessionName: String) async throws -> [String]

    /// Scrolls a tmux terminal's history for a remote viewer (up when
    /// `lines` is positive). agtop terminals scroll through mouse reporting
    /// instead and ignore this.
    func scrollTerminal(sessionName: String, lines: Int) async

    /// Yields whenever the board changed; the server throttles pushes.
    func boardChanges() -> AsyncStream<Void>
}

/// A host call that failed for a reason the client should see, with the
/// HTTP status it maps to.
public struct RemoteHostError: Error, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case notFound
        case badRequest
        case conflict
    }

    public let kind: Kind
    public let message: String

    public init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }

    public static func notFound(_ message: String) -> Self { .init(.notFound, message) }
    public static func badRequest(_ message: String) -> Self { .init(.badRequest, message) }
    public static func conflict(_ message: String) -> Self { .init(.conflict, message) }
}
