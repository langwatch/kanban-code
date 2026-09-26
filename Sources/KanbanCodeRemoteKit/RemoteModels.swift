import Foundation

/// Wire types of the Kanban Code remote control API (docs/remote-control.md).
/// The Mac app serves them, the iOS app and the kanban CLI read them.
public enum RemoteAPI {
    public static let version = 1
    public static let defaultPort = 7780
}

/// What a device may do. `full` is a phone: everything, terminals included.
/// `agent` is another agent (OpenClaw): read the board, start tasks, send
/// prompts, never a terminal or raw keys.
public enum RemoteScope: String, Codable, Sendable, CaseIterable {
    case full
    case agent
}

public struct RemoteHealth: Codable, Sendable, Equatable {
    public var app: String
    public var version: String
    public var apiVersion: Int
    public var hostName: String

    public init(app: String = "kanban-code", version: String, apiVersion: Int = RemoteAPI.version, hostName: String) {
        self.app = app
        self.version = version
        self.apiVersion = apiVersion
        self.hostName = hostName
    }
}

public struct RemoteDevice: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var scope: RemoteScope
    public var createdAt: Date
    public var lastSeenAt: Date?

    public init(id: String, name: String, scope: RemoteScope, createdAt: Date, lastSeenAt: Date? = nil) {
        self.id = id
        self.name = name
        self.scope = scope
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
    }
}

public enum RemoteColumn: String, Codable, Sendable, CaseIterable {
    case backlog
    case inProgress = "in_progress"
    case waiting = "requires_attention"
    case inReview = "in_review"
    case done
    case allSessions = "all_sessions"

    public var displayName: String {
        switch self {
        case .backlog: "Backlog"
        case .inProgress: "In Progress"
        case .waiting: "Waiting"
        case .inReview: "In Review"
        case .done: "Done"
        case .allSessions: "All Sessions"
        }
    }
}

/// Where a card's main session runs.
public enum RemoteRuntime: String, Codable, Sendable {
    case tmux
    case agtop
    /// A boxd machine.
    case machine
    /// No session attached.
    case none
}

public struct RemotePR: Codable, Sendable, Equatable {
    public var number: Int
    public var url: String?
    public var title: String?
    /// open, draft, merged, closed, or nil when unknown.
    public var status: String?

    public init(number: Int, url: String? = nil, title: String? = nil, status: String? = nil) {
        self.number = number
        self.url = url
        self.title = title
        self.status = status
    }
}

/// One terminal of a card: the main session or an extra shell.
public struct RemoteTerminal: Codable, Sendable, Equatable, Identifiable {
    public var id: String { sessionName }
    public var sessionName: String
    public var label: String
    public var isPrimary: Bool

    public init(sessionName: String, label: String, isPrimary: Bool) {
        self.sessionName = sessionName
        self.label = label
        self.isPrimary = isPrimary
    }
}

public struct RemoteCard: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var column: RemoteColumn
    public var projectPath: String?
    public var projectName: String?
    public var branch: String?
    public var worktreePath: String?
    /// claude, codex or gemini.
    public var assistant: String
    public var runtime: RemoteRuntime
    /// A live session is attached (the card can take prompts right away).
    public var isLive: Bool
    /// The assistant is in a turn right now.
    public var isBusy: Bool
    public var sessionId: String?
    public var terminals: [RemoteTerminal]
    public var prs: [RemotePR]
    public var queuedPromptCount: Int
    public var parentCardId: String?
    public var archived: Bool
    public var lastActivity: Date?
    public var updatedAt: Date

    public init(
        id: String, title: String, column: RemoteColumn, projectPath: String? = nil, projectName: String? = nil,
        branch: String? = nil, worktreePath: String? = nil, assistant: String = "claude", runtime: RemoteRuntime = .none,
        isLive: Bool = false, isBusy: Bool = false, sessionId: String? = nil, terminals: [RemoteTerminal] = [],
        prs: [RemotePR] = [], queuedPromptCount: Int = 0, parentCardId: String? = nil, archived: Bool = false,
        lastActivity: Date? = nil, updatedAt: Date
    ) {
        self.id = id
        self.title = title
        self.column = column
        self.projectPath = projectPath
        self.projectName = projectName
        self.branch = branch
        self.worktreePath = worktreePath
        self.assistant = assistant
        self.runtime = runtime
        self.isLive = isLive
        self.isBusy = isBusy
        self.sessionId = sessionId
        self.terminals = terminals
        self.prs = prs
        self.queuedPromptCount = queuedPromptCount
        self.parentCardId = parentCardId
        self.archived = archived
        self.lastActivity = lastActivity
        self.updatedAt = updatedAt
    }
}

/// The JSON of a card leaves out what is false, zero or empty (`isLive`,
/// `isBusy`, `archived`, `queuedPromptCount`, `terminals`, `prs`) and nil
/// optionals; decoding reads a missing key as that default. A board of
/// thousands of cards stays small that way.
extension RemoteCard {
    private enum CodingKeys: String, CodingKey {
        case id, title, column, projectPath, projectName, branch, worktreePath, assistant, runtime
        case isLive, isBusy, sessionId, terminals, prs, queuedPromptCount, parentCardId, archived
        case lastActivity, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            title: try c.decode(String.self, forKey: .title),
            column: try c.decode(RemoteColumn.self, forKey: .column),
            projectPath: try c.decodeIfPresent(String.self, forKey: .projectPath),
            projectName: try c.decodeIfPresent(String.self, forKey: .projectName),
            branch: try c.decodeIfPresent(String.self, forKey: .branch),
            worktreePath: try c.decodeIfPresent(String.self, forKey: .worktreePath),
            assistant: try c.decodeIfPresent(String.self, forKey: .assistant) ?? "claude",
            runtime: try c.decodeIfPresent(RemoteRuntime.self, forKey: .runtime) ?? .none,
            isLive: try c.decodeIfPresent(Bool.self, forKey: .isLive) ?? false,
            isBusy: try c.decodeIfPresent(Bool.self, forKey: .isBusy) ?? false,
            sessionId: try c.decodeIfPresent(String.self, forKey: .sessionId),
            terminals: try c.decodeIfPresent([RemoteTerminal].self, forKey: .terminals) ?? [],
            prs: try c.decodeIfPresent([RemotePR].self, forKey: .prs) ?? [],
            queuedPromptCount: try c.decodeIfPresent(Int.self, forKey: .queuedPromptCount) ?? 0,
            parentCardId: try c.decodeIfPresent(String.self, forKey: .parentCardId),
            archived: try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false,
            lastActivity: try c.decodeIfPresent(Date.self, forKey: .lastActivity),
            updatedAt: try c.decode(Date.self, forKey: .updatedAt)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(column, forKey: .column)
        try c.encodeIfPresent(projectPath, forKey: .projectPath)
        try c.encodeIfPresent(projectName, forKey: .projectName)
        try c.encodeIfPresent(branch, forKey: .branch)
        try c.encodeIfPresent(worktreePath, forKey: .worktreePath)
        try c.encode(assistant, forKey: .assistant)
        try c.encode(runtime, forKey: .runtime)
        if isLive { try c.encode(true, forKey: .isLive) }
        if isBusy { try c.encode(true, forKey: .isBusy) }
        try c.encodeIfPresent(sessionId, forKey: .sessionId)
        if !terminals.isEmpty { try c.encode(terminals, forKey: .terminals) }
        if !prs.isEmpty { try c.encode(prs, forKey: .prs) }
        if queuedPromptCount != 0 { try c.encode(queuedPromptCount, forKey: .queuedPromptCount) }
        try c.encodeIfPresent(parentCardId, forKey: .parentCardId)
        if archived { try c.encode(true, forKey: .archived) }
        try c.encodeIfPresent(lastActivity, forKey: .lastActivity)
        try c.encode(updatedAt, forKey: .updatedAt)
    }
}

public struct RemoteProject: Codable, Sendable, Equatable, Identifiable {
    public var id: String { path }
    public var path: String
    public var name: String

    public init(path: String, name: String) {
        self.path = path
        self.name = name
    }
}

public struct RemoteBoard: Codable, Sendable, Equatable {
    public var cards: [RemoteCard]
    public var projects: [RemoteProject]
    public var generatedAt: Date

    public init(cards: [RemoteCard], projects: [RemoteProject], generatedAt: Date) {
        self.cards = cards
        self.projects = projects
        self.generatedAt = generatedAt
    }
}

public struct RemoteMessage: Codable, Sendable, Equatable, Identifiable {
    public enum Role: String, Codable, Sendable {
        case user
        case assistant
        /// A tool call and its result, summarised in one line.
        case tool
        case system
    }

    public var id: String
    public var role: Role
    public var text: String
    public var at: Date?

    public init(id: String, role: Role, text: String, at: Date? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.at = at
    }
}

public struct RemoteTranscript: Codable, Sendable, Equatable {
    public var cardId: String
    public var messages: [RemoteMessage]
    /// Pass as `before` to read older messages; nil at the start.
    public var olderCursor: String?

    public init(cardId: String, messages: [RemoteMessage], olderCursor: String? = nil) {
        self.cardId = cardId
        self.messages = messages
        self.olderCursor = olderCursor
    }
}

/// POST /v1/tasks
public struct RemoteTaskRequest: Codable, Sendable, Equatable {
    /// A project path, or a project name as the board lists it.
    public var project: String
    public var prompt: String
    public var name: String?
    /// A worktree name, "" for a random name, nil to run in the project checkout.
    public var worktree: String?
    public var assistant: String?
    public var model: String?
    /// false only creates the card in the backlog.
    public var launch: Bool?

    public init(project: String, prompt: String, name: String? = nil, worktree: String? = nil,
                assistant: String? = nil, model: String? = nil, launch: Bool? = nil) {
        self.project = project
        self.prompt = prompt
        self.name = name
        self.worktree = worktree
        self.assistant = assistant
        self.model = model
        self.launch = launch
    }
}

/// POST /v1/cards/{id}/prompt
public struct RemotePromptRequest: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable {
        /// Delivered when the current turn ends (sent now when idle).
        case queue
        /// Interrupts the turn and sends it now.
        case now
    }

    public var text: String
    public var mode: Mode?

    public init(text: String, mode: Mode? = nil) {
        self.text = text
        self.mode = mode
    }
}

public struct RemoteError: Codable, Sendable, Equatable, Error {
    public var error: String

    public init(_ error: String) { self.error = error }
}

/// Text frames on WS /v1/events: a whole `board` first, then `cards` deltas.
public struct RemoteEvent: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// `board` holds the whole board (the working set unless `all=1`).
        case board
        /// Changes since the last frame: `upserted` cards replace or join the
        /// board by id, `removed` ids leave it, `projects` (when present)
        /// replaces the project list.
        case cards
        /// Sent every 20 s so idle connections stay up.
        case ping
    }

    public var type: Kind
    public var board: RemoteBoard?
    public var upserted: [RemoteCard]?
    public var removed: [String]?
    public var projects: [RemoteProject]?

    public init(
        type: Kind, board: RemoteBoard? = nil, upserted: [RemoteCard]? = nil,
        removed: [String]? = nil, projects: [RemoteProject]? = nil
    ) {
        self.type = type
        self.board = board
        self.upserted = upserted
        self.removed = removed
        self.projects = projects
    }

    /// Applies a `board` or `cards` event to a board the client holds.
    public func apply(to board: inout RemoteBoard?) {
        switch type {
        case .board:
            board = self.board
        case .cards:
            guard var current = board else { return }
            let gone = Set(removed ?? [])
            current.cards.removeAll { gone.contains($0.id) }
            for card in upserted ?? [] {
                if let i = current.cards.firstIndex(where: { $0.id == card.id }) {
                    current.cards[i] = card
                } else {
                    current.cards.append(card)
                }
            }
            if let projects { current.projects = projects }
            board = current
        case .ping:
            break
        }
    }
}

/// Text frames a client sends on WS /v1/events.
public struct RemoteEventsControl: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// Asks for a whole `board` frame again.
        case resync
    }

    public var type: Kind

    public init(type: Kind) {
        self.type = type
    }
}

/// Text frames a client sends on WS /v1/cards/{id}/terminal; binary frames
/// both ways are the terminal's bytes.
public struct RemoteTerminalControl: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case resize
    }

    public var type: Kind
    public var cols: Int?
    public var rows: Int?

    public init(type: Kind, cols: Int? = nil, rows: Int? = nil) {
        self.type = type
        self.cols = cols
        self.rows = rows
    }
}

public extension JSONEncoder {
    /// Dates as ISO 8601 with fractional seconds, as the whole API uses.
    static var remote: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(RemoteDates.format(date))
        }
        return e
    }
}

public extension JSONDecoder {
    static var remote: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = RemoteDates.parse(s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad date \(s)")
            }
            return date
        }
        return d
    }
}

enum RemoteDates {
    static func format(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted))
    }

    static func parse(_ s: String) -> Date? {
        if let d = try? Date(s, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted)) {
            return d
        }
        return try? Date(s, strategy: .iso8601)
    }
}
