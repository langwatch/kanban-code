import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// POST /v1/cards/{id}/move: continue the card somewhere else.
public struct RemoteMoveRequest: Codable, Sendable, Equatable {
    /// A master (its machine id or name), "mac"/"local" for the master that
    /// serves the request, or a boxd/ssh machine that master drives.
    public var to: String

    public init(to: String) {
        self.to = to
    }
}

/// PATCH /v1/cards/{id}: edits of the card any master may make. Each field
/// is optional; the ones given apply in the order name, column, archived,
/// pinned.
public struct RemoteCardUpdate: Codable, Sendable, Equatable {
    public var name: String?
    public var column: RemoteColumn?
    /// true archives the card, false brings an archived card back to the
    /// board (servers listing `RemoteAPI.Feature.cardActions`).
    public var archived: Bool?
    /// Pins or unpins the card (servers listing `RemoteAPI.Feature.cardActions`).
    /// Pinning an archived card brings it back, as on the Mac.
    public var pinned: Bool?

    public init(name: String? = nil, column: RemoteColumn? = nil, archived: Bool? = nil, pinned: Bool? = nil) {
        self.name = name
        self.column = column
        self.archived = archived
        self.pinned = pinned
    }
}

/// GET /v1/cards/{id}/handover: what a master adopting the card needs from
/// the one that released it to continue the conversation.
public struct RemoteHandoverInfo: Codable, Sendable, Equatable {
    public var cardId: String
    public var sessionId: String?
    public var assistant: String
    /// The repository root on the releasing master.
    public var projectPath: String?
    /// The directory the session ran in there (a worktree or the checkout).
    public var cwd: String?
    /// `origin` of the repository, to find or clone it on the adopting master.
    public var repoUrl: String?
    /// The worktree branch, pushed to origin by the release.
    public var branch: String?
    /// Name of the worktree directory.
    public var worktreeName: String?
    /// Uncommitted changes of the worktree as a binary git diff, base64.
    public var patch: String?
    /// Size of the transcript in bytes.
    public var transcriptSize: Int
    /// For a card that never ran: the first prompt the adopting master
    /// launches it with, and the worktree to create ("" for a random name).
    public var launchPrompt: String?
    public var launchWorktree: String?
    /// The folder the conversation ran in when it ran over ssh on the
    /// adopting master's own machine: the adopter continues there, with
    /// the worktree and transcript as they are.
    public var machineCwd: String?
    /// For a repository with no `origin`: whether it has commits. Its
    /// files cannot follow to the adopting master, which can only start
    /// such a project fresh when there is nothing to bring.
    public var repoHasCommits: Bool?
    /// Set when the card is coming back: the master it was released to
    /// could not adopt it, for this reason.
    public var refusal: String?

    public init(cardId: String, sessionId: String?, assistant: String, projectPath: String?, cwd: String?,
                repoUrl: String?, branch: String?, worktreeName: String?, patch: String?, transcriptSize: Int) {
        self.cardId = cardId
        self.sessionId = sessionId
        self.assistant = assistant
        self.projectPath = projectPath
        self.cwd = cwd
        self.repoUrl = repoUrl
        self.branch = branch
        self.worktreeName = worktreeName
        self.patch = patch
        self.transcriptSize = transcriptSize
    }
}

/// A slice of a card's raw transcript file.
public struct RemoteRawTranscript: Sendable, Equatable {
    public var data: Data
    public var offset: Int
    /// Size of the whole file.
    public var size: Int

    public init(data: Data, offset: Int, size: Int) {
        self.data = data
        self.offset = offset
        self.size = size
    }

    /// Header with the file size on `GET /v1/cards/{id}/transcript/raw`.
    public static let sizeHeader = "X-Transcript-Size"
}

/// Answer of `POST /v1/cards/{id}/worktree/remove`.
public struct RemoteWorktreeRemoval: Codable, Sendable, Equatable {
    /// The machine the worktree was removed on.
    public var machine: String
    /// True when the card had no session and went with its worktree.
    public var cardDeleted: Bool

    public init(machine: String, cardDeleted: Bool) {
        self.machine = machine
        self.cardDeleted = cardDeleted
    }
}

/// Answer of `POST /v1/cards/{id}/pasted-image`.
public struct RemotePastedImage: Codable, Sendable, Equatable {
    /// The file on the master that owns the card.
    public var path: String

    public init(path: String) {
        self.path = path
    }
}

extension RemoteClient {
    /// POST /v1/cards/{id}/pasted-image: the master that owns the card keeps
    /// the image as a file and answers with its path there, for a paste into
    /// the card's terminal to type.
    public func uploadPastedImage(cardId: String, data: Data) async throws -> RemotePastedImage {
        var request = makeRequest("POST", "v1/cards/\(Self.escape(cardId))/pasted-image")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        request.timeoutInterval = 120
        let (body, status) = try await rawData(for: request)
        guard (200..<300).contains(status) else { throw RemoteClientError.from(status: status, body: body) }
        do {
            return try JSONDecoder.remote.decode(RemotePastedImage.self, from: body)
        } catch {
            throw RemoteClientError.decoding(String(describing: error))
        }
    }

    /// POST /v1/cards/{id}/worktree/remove: the master that owns the card
    /// removes its worktree where it lives.
    public func removeWorktree(cardId: String) async throws -> RemoteWorktreeRemoval {
        var request = makeRequest("POST", "v1/cards/\(Self.escape(cardId))/worktree/remove")
        request.timeoutInterval = 150
        let (data, status) = try await rawData(for: request)
        guard (200..<300).contains(status) else { throw RemoteClientError.from(status: status, body: data) }
        return try JSONDecoder.remote.decode(RemoteWorktreeRemoval.self, from: data)
    }

    /// POST /v1/cards/{id}/discover: the owner re-scans the card for pushed
    /// branches and pull requests.
    public func discoverBranches(cardId: String) async throws {
        var request = makeRequest("POST", "v1/cards/\(Self.escape(cardId))/discover")
        request.timeoutInterval = 120
        let (data, status) = try await rawData(for: request)
        guard (200..<300).contains(status) else { throw RemoteClientError.from(status: status, body: data) }
    }

    /// POST /v1/cards/{id}/move
    public func move(cardId: String, to target: String) async throws -> RemoteCard {
        let request = makeRequest("POST", "v1/cards/\(Self.escape(cardId))/move", body: RemoteMoveRequest(to: target))
        let (data, status) = try await rawData(for: request)
        guard (200..<300).contains(status) else { throw RemoteClientError.from(status: status, body: data) }
        return try JSONDecoder.remote.decode(RemoteCard.self, from: data)
    }

    /// PATCH /v1/cards/{id}
    public func updateCard(cardId: String, _ update: RemoteCardUpdate) async throws -> RemoteCard {
        let request = makeRequest("PATCH", "v1/cards/\(Self.escape(cardId))", body: update)
        let (data, status) = try await rawData(for: request)
        guard (200..<300).contains(status) else { throw RemoteClientError.from(status: status, body: data) }
        return try JSONDecoder.remote.decode(RemoteCard.self, from: data)
    }

    /// DELETE /v1/cards/{id}: deletes an archived card, its subagents and
    /// its conversation file.
    public func deleteCard(cardId: String) async throws {
        let request = makeRequest("DELETE", "v1/cards/\(Self.escape(cardId))")
        let (data, status) = try await rawData(for: request)
        guard (200..<300).contains(status) else { throw RemoteClientError.from(status: status, body: data) }
    }

    /// GET /v1/cards/{id}/handover
    public func handover(cardId: String) async throws -> RemoteHandoverInfo {
        let request = makeRequest("GET", "v1/cards/\(Self.escape(cardId))/handover")
        let (data, status) = try await rawData(for: request)
        guard (200..<300).contains(status) else { throw RemoteClientError.from(status: status, body: data) }
        return try JSONDecoder.remote.decode(RemoteHandoverInfo.self, from: data)
    }

    /// GET /v1/cards/{id}/transcript/raw?offset=&limit=: up to `limit`
    /// bytes of the transcript file from `offset`.
    public func rawTranscript(cardId: String, offset: Int, limit: Int = 4 << 20) async throws -> RemoteRawTranscript {
        let request = makeRequest("GET", "v1/cards/\(Self.escape(cardId))/transcript/raw", query: [
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "limit", value: String(limit)),
        ])
        var req = request
        req.timeoutInterval = 60
        let (data, response) = try await session.data(for: req)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw RemoteClientError.from(status: status, body: data) }
        let size = (http?.value(forHTTPHeaderField: RemoteRawTranscript.sizeHeader)).flatMap(Int.init) ?? offset + data.count
        return RemoteRawTranscript(data: data, offset: offset, size: size)
    }

    private func rawData(for request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
