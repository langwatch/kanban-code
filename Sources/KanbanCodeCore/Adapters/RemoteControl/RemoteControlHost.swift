import Foundation
import KanbanCodeRemoteKit

/// What the remote control server asks of the app. The app implements it
/// over its store and launch flow; tests implement it with a fake.
public protocol RemoteControlHost: AnyObject, Sendable {
    func board() async -> RemoteBoard

    /// Newest `limit` messages of the card's conversation, older than
    /// `before` when given.
    func transcript(cardId: String, limit: Int, before: String?) async throws -> RemoteTranscript

    /// The machines a task can run on, this master first.
    func machines() async -> [RemoteMachineEntry]

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
    /// as argv: `rush open <id>` for rush (`agtop open <id> --solo` for agtop), `tmux attach -t <name>`
    /// for tmux.
    func terminalCommand(cardId: String, sessionName: String) async throws -> [String]

    /// Scrolls a tmux terminal's history for a remote viewer (up when
    /// `lines` is positive). rush terminals scroll through mouse reporting
    /// instead and ignore this.
    func scrollTerminal(sessionName: String, lines: Int) async

    /// Yields whenever the board changed; the server throttles pushes.
    func boardChanges() -> AsyncStream<Void>

    /// Up to `limit` bytes of the card's transcript file from `offset`, for
    /// a master that mirrors or adopts the card.
    func rawTranscript(cardId: String, offset: Int, limit: Int) async throws -> RemoteRawTranscript

    /// What a master adopting the card needs to continue it.
    func handoverInfo(cardId: String) async throws -> RemoteHandoverInfo

    /// Renames, moves or archives the card. These are shared edits: they
    /// apply here whichever master owns the card, and sync to the others.
    func updateCard(cardId: String, _ update: RemoteCardUpdate) async throws -> RemoteCard

    /// Deletes an archived card; a card still on the board is refused (409).
    func deleteCard(cardId: String) async throws

    /// Continues the card elsewhere: another master (ownership moves there),
    /// a machine this master drives, or back here.
    func moveCard(cardId: String, to target: String) async throws -> RemoteCard

    /// Removes the card's worktree on the machine that holds it and drops
    /// the worktree from the card (the card itself when it has no session).
    func removeWorktree(cardId: String) async throws -> RemoteWorktreeRemoval

    /// Re-scans the card for pushed branches and pull requests.
    func discoverBranches(cardId: String) async throws

    /// Replaces the text of a queued prompt.
    func editQueuedPrompt(cardId: String, promptId: String, text: String) async throws

    /// Runs a `kanban channel|dm` command another master handed over.
    func runCLI(_ request: RemoteCLIRequest) async throws -> RemoteCLIResult

    /// The files of `channels/`, for the masters that mirror them.
    func channelFiles() async throws -> [RemoteChannelFile]
    func channelFile(path: String, offset: Int) async throws -> Data
    /// Creates a file of `channels/` that does not exist yet; false when it does.
    func seedChannelFile(path: String, data: Data) async throws -> Bool

    /// Open attention requests, oldest first.
    func attention() async -> [AttentionRequest]

    /// Answers an attention request in its session (or for the vault) and
    /// clears it on every device. `by` names the device acting.
    /// `unsealed` is what the device opened with its own vault key.
    func resolveAttention(id: String, resolution: String, by: String, unsealed: VaultUnsealed?) async throws

    /// Presence the Mac reported, for the escalation of the requests here.
    func reportPresence(_ presence: MacPresence) async

    /// Starts a side chat run for the card (`/btw`, `/catchup`): it reads
    /// the session and writes nothing into it.
    func startSideChat(cardId: String, _ request: RemoteSideChatRequest) async throws -> RemoteSideChatRun
    /// The run and its answer so far.
    func sideChatRun(cardId: String, runId: String) async throws -> RemoteSideChatRun
    func cancelSideChat(cardId: String, runId: String) async throws

    /// What the card's chat composer offers after `/`.
    func slashCommands(cardId: String) async throws -> [RemoteSlashCommand]
}

extension RemoteControlHost {
    public func machines() async -> [RemoteMachineEntry] { [] }

    public func rawTranscript(cardId: String, offset: Int, limit: Int) async throws -> RemoteRawTranscript {
        throw RemoteHostError.notFound("this host does not serve raw transcripts")
    }

    public func handoverInfo(cardId: String) async throws -> RemoteHandoverInfo {
        throw RemoteHostError.notFound("this host does not hand cards over")
    }

    public func moveCard(cardId: String, to target: String) async throws -> RemoteCard {
        throw RemoteHostError.notFound("this host does not move cards")
    }

    public func updateCard(cardId: String, _ update: RemoteCardUpdate) async throws -> RemoteCard {
        throw RemoteHostError.notFound("this host does not edit cards")
    }

    public func deleteCard(cardId: String) async throws {
        throw RemoteHostError.notFound("this host does not delete cards")
    }

    public func removeWorktree(cardId: String) async throws -> RemoteWorktreeRemoval {
        throw RemoteHostError.notFound("this host does not remove worktrees")
    }

    public func discoverBranches(cardId: String) async throws {
        throw RemoteHostError.notFound("this host does not discover branches")
    }

    public func editQueuedPrompt(cardId: String, promptId: String, text: String) async throws {
        throw RemoteHostError.notFound("this host does not edit queued prompts")
    }

    public func runCLI(_ request: RemoteCLIRequest) async throws -> RemoteCLIResult {
        throw RemoteHostError.notFound("this host does not run commands for other masters")
    }

    public func channelFiles() async throws -> [RemoteChannelFile] {
        throw RemoteHostError.notFound("this host does not serve channels")
    }

    public func channelFile(path: String, offset: Int) async throws -> Data {
        throw RemoteHostError.notFound("this host does not serve channels")
    }

    public func seedChannelFile(path: String, data: Data) async throws -> Bool {
        throw RemoteHostError.notFound("this host does not serve channels")
    }

    public func attention() async -> [AttentionRequest] { [] }

    public func resolveAttention(id: String, resolution: String, by: String) async throws {
        try await resolveAttention(id: id, resolution: resolution, by: by, unsealed: nil)
    }

    public func resolveAttention(id: String, resolution: String, by: String, unsealed: VaultUnsealed?) async throws {
        throw RemoteHostError.notFound("this host has no attention requests")
    }

    public func reportPresence(_ presence: MacPresence) async {}

    public func startSideChat(cardId: String, _ request: RemoteSideChatRequest) async throws -> RemoteSideChatRun {
        throw RemoteHostError.notFound("this host has no side chat")
    }

    public func sideChatRun(cardId: String, runId: String) async throws -> RemoteSideChatRun {
        throw RemoteHostError.notFound("this host has no side chat")
    }

    public func cancelSideChat(cardId: String, runId: String) async throws {
        throw RemoteHostError.notFound("this host has no side chat")
    }

    public func slashCommands(cardId: String) async throws -> [RemoteSlashCommand] { [] }
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
