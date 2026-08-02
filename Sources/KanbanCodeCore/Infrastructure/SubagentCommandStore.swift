import Foundation

public enum SubagentCommandOperation: String, Codable, Sendable {
    case spawn
    case fork
    case archive
    case resume
    /// Card-level, not subagent-level: the CLI cannot append to a card's prompt
    /// queue itself because the running app owns links.json.
    case enqueuePrompt
    /// Point a card at a different transcript, for when reconciliation left it on
    /// a stale session. Also a links.json write, so also the app's to make.
    case relinkSession
    /// Record a model switch so resuming the card does not undo it.
    case setModel
    /// Retune a card's compaction schedule when the work turns out bigger or
    /// smaller than the goal it was spawned with.
    case setContextThreshold
}

public struct SubagentCommandRequest: Codable, Sendable, Equatable {
    public let id: String
    public let operation: SubagentCommandOperation
    public let createdAt: String
    public let parentCardId: String
    public let cardId: String?
    /// Card whose transcript a fork copies. Absent means the requesting parent.
    public let sourceCardId: String?
    /// Child card name, which also becomes its chat handle.
    public let name: String?
    public let prompt: String?
    public let assistant: CodingAssistant?
    public let model: String?
    public let contextThresholdTokens: Int?
    /// Transcript a relink points the card at.
    public let sessionId: String?
    public let sessionPath: String?

    public init(
        id: String,
        operation: SubagentCommandOperation,
        createdAt: String,
        parentCardId: String,
        cardId: String? = nil,
        sourceCardId: String? = nil,
        name: String? = nil,
        prompt: String? = nil,
        assistant: CodingAssistant? = nil,
        model: String? = nil,
        contextThresholdTokens: Int? = nil,
        sessionId: String? = nil,
        sessionPath: String? = nil
    ) {
        self.id = id
        self.operation = operation
        self.createdAt = createdAt
        self.parentCardId = parentCardId
        self.cardId = cardId
        self.sourceCardId = sourceCardId
        self.name = name
        self.prompt = prompt
        self.assistant = assistant
        self.model = model
        self.contextThresholdTokens = contextThresholdTokens
        self.sessionId = sessionId
        self.sessionPath = sessionPath
    }
}

public struct SubagentCommandResponse: Codable, Sendable, Equatable {
    public let id: String
    public let ok: Bool
    public let cardId: String?
    public let error: String?

    public init(id: String, ok: Bool, cardId: String? = nil, error: String? = nil) {
        self.id = id
        self.ok = ok
        self.cardId = cardId
        self.error = error
    }
}

/// Filesystem mailbox used by the CLI to ask the running app to perform
/// stateful card operations through BoardStore's serialized reducer.
public actor SubagentCommandStore {
    private let baseURL: URL
    private let fileManager: FileManager
    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    public init(baseURL: URL? = nil, fileManager: FileManager = .default) {
        self.baseURL = baseURL ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".kanban-code/commands", isDirectory: true)
        self.fileManager = fileManager
    }

    public func pendingRequestIds() throws -> [String] {
        try ensureDirectories()
        return try fileManager.contentsOfDirectory(
            at: inboxURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" }
        .map { $0.deletingPathExtension().lastPathComponent }
        .sorted()
    }

    /// Claims a request by atomically moving it out of the inbox. A duplicate
    /// deep link therefore cannot execute the operation twice.
    public func claim(id: String) throws -> SubagentCommandRequest? {
        try ensureDirectories()
        let source = inboxURL.appendingPathComponent("\(id).json")
        let claimed = processingURL.appendingPathComponent("\(id).json")
        guard fileManager.fileExists(atPath: source.path) else { return nil }
        guard !fileManager.fileExists(atPath: claimed.path) else { return nil }
        do {
            try fileManager.moveItem(at: source, to: claimed)
        } catch {
            // Multiple app windows can observe the same inbox entry before one
            // of their mailbox actors moves it. Losing that atomic claim race
            // means another processor owns the request, not that the command
            // failed. It must not overwrite the eventual successful response.
            if !fileManager.fileExists(atPath: source.path)
                || fileManager.fileExists(atPath: claimed.path) {
                return nil
            }
            throw error
        }
        do {
            let request = try decoder.decode(SubagentCommandRequest.self, from: Data(contentsOf: claimed))
            guard request.id == id else {
                throw SubagentCommandStoreError.requestIdMismatch(expected: id, actual: request.id)
            }
            return request
        } catch {
            try? fileManager.removeItem(at: claimed)
            throw error
        }
    }

    public func respond(_ response: SubagentCommandResponse) throws {
        try ensureDirectories()
        let finalURL = responsesURL.appendingPathComponent("\(response.id).json")
        let temporaryURL = responsesURL.appendingPathComponent("\(response.id).json.tmp")
        try encoder.encode(response).write(to: temporaryURL, options: .atomic)
        if fileManager.fileExists(atPath: finalURL.path) {
            try fileManager.removeItem(at: finalURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: finalURL)
        try? fileManager.removeItem(at: processingURL.appendingPathComponent("\(response.id).json"))
    }

    /// A request left in processing means the app exited before it could answer.
    /// Report the interruption instead of silently stranding the waiting CLI or
    /// replaying an operation that may already have changed state.
    public func recoverInterruptedRequests() throws -> Int {
        try ensureDirectories()
        let files = try fileManager.contentsOfDirectory(
            at: processingURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }

        var recovered = 0
        for file in files {
            do {
                let request = try decoder.decode(
                    SubagentCommandRequest.self,
                    from: Data(contentsOf: file)
                )
                try respond(SubagentCommandResponse(
                    id: request.id,
                    ok: false,
                    error: "Kanban Code restarted while processing this subagent command. Inspect existing child cards before retrying."
                ))
                recovered += 1
            } catch {
                try? fileManager.removeItem(at: file)
            }
        }
        return recovered
    }

    private var inboxURL: URL { baseURL.appendingPathComponent("inbox", isDirectory: true) }
    private var processingURL: URL { baseURL.appendingPathComponent("processing", isDirectory: true) }
    private var responsesURL: URL { baseURL.appendingPathComponent("responses", isDirectory: true) }

    private func ensureDirectories() throws {
        for directory in [inboxURL, processingURL, responsesURL] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}

public enum SubagentCommandStoreError: LocalizedError {
    case requestIdMismatch(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .requestIdMismatch(let expected, let actual):
            "Subagent command id mismatch: expected \(expected), received \(actual)"
        }
    }
}
