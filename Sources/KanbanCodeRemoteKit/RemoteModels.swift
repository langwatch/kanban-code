import Foundation

/// Wire types of the Kanban Code remote control API (docs/remote-control.md).
/// The Mac app serves them, the iOS app and the kanban CLI read them.
public enum RemoteAPI {
    public static let version = 1
    public static let defaultPort = 7780

    /// What this server supports beyond version 1, listed in `RemoteHealth.features`.
    /// A client checks for a feature before using it, since an older server
    /// ignores the new fields or, for terminal control frames, types them
    /// into the terminal.
    public enum Feature {
        /// `images` on prompts and tasks.
        public static let images = "images"
        /// `queuedPrompts` on cards and `/v1/cards/{id}/queue/{promptId}`.
        public static let queue = "queue"
        /// The `scroll` terminal control frame.
        public static let terminalScroll = "terminalScroll"
        /// GET /v1/machines, and `machine` on tasks naming this master by
        /// its own name.
        public static let machines = "machines"
        /// `pinned` on cards and on `PATCH /v1/cards/{id}`, `archived: false`
        /// to unarchive, and `DELETE /v1/cards/{id}`.
        public static let cardActions = "cardActions"
        /// `POST /v1/cards/{id}/worktree/remove` and `POST /v1/cards/{id}/discover`.
        public static let worktrees = "worktrees"
        /// `/v1/cards/{id}/side-chat` (`/btw` and `/catchup`) and `human` on prompts.
        public static let sideChat = "sideChat"
        /// `GET /v1/cards/{id}/slash-commands`.
        public static let slashCommands = "slashCommands"
        /// `GET /v1/cards/search`.
        public static let cardSearch = "cardSearch"
    }

    public static let features = [Feature.images, Feature.queue, Feature.terminalScroll, Feature.machines, Feature.cardActions, Feature.worktrees, Feature.sideChat, Feature.slashCommands, Feature.cardSearch]
}

/// What a device may do. `full` is a phone: everything, terminals included.
/// `agent` is another agent (OpenClaw): read the board, start tasks, send
/// prompts, never a terminal or raw keys.
public enum RemoteScope: String, Codable, Sendable, CaseIterable {
    /// Everything, terminals included. The human's own devices.
    case full
    /// Board, tasks and prompts. Another agent.
    case agent
    /// What a paired master needs: sync, forwarding, moves, approvals. No terminal.
    case peer
    /// Card terminals only, for `kanban remote attach` on a paired master.
    case terminal

    /// Whether the device acts for the human: a device of his, or a master
    /// passing on what he did there.
    public var actsForOwner: Bool { self == .full || self == .peer }
}

public struct RemoteHealth: Codable, Sendable, Equatable {
    public var app: String
    public var version: String
    public var apiVersion: Int
    public var hostName: String
    /// `RemoteAPI.Feature` names. Missing on servers older than the list.
    public var features: [String]?

    public init(app: String = "kanban-code", version: String, apiVersion: Int = RemoteAPI.version, hostName: String,
                features: [String]? = RemoteAPI.features) {
        self.app = app
        self.version = version
        self.apiVersion = apiVersion
        self.hostName = hostName
        self.features = features
    }

    public func supports(_ feature: String) -> Bool {
        features?.contains(feature) == true
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

/// Where a card's main session runs. A rush host goes on the wire as
/// "agtop", the name rush had before it was renamed, since phones and
/// masters on older builds decode only that; "rush" is read as well.
public enum RemoteRuntime: String, Codable, Sendable {
    case tmux
    case rush = "agtop"
    /// A boxd machine.
    case machine
    /// No session attached.
    case none

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let runtime = value == "rush" ? .rush : RemoteRuntime(rawValue: value) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "Unknown runtime \(value)"))
        }
        self = runtime
    }
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

/// A master: a machine that runs sessions and serves this API. With several
/// masters (a Mac and an always-on box), every card belongs to one of them.
public struct RemoteMachine: Codable, Sendable, Equatable, Hashable, Identifiable {
    /// Stable id, `~/.kanban-code/machine.json` on the master.
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// One machine a task can run on, as GET /v1/machines lists it.
public struct RemoteMachineEntry: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// The master serving the list; a task runs here when it names no machine.
        case this
        /// Another master: a task sent there is handed over and owned by it.
        case master
        /// An ssh machine this master drives, with no master of its own.
        case ssh
    }

    /// The master's machine id; nil for a plain ssh machine.
    public var id: String?
    /// The name `machine` of POST /v1/tasks accepts.
    public var name: String
    public var kind: Kind
    /// Whether the master answered its last pull; nil when unknown (ssh).
    public var online: Bool?
    /// A master that runs all the time (`kanban-code-server`).
    public var alwaysOn: Bool?

    public init(id: String? = nil, name: String, kind: Kind, online: Bool? = nil, alwaysOn: Bool? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.online = online
        self.alwaysOn = alwaysOn
    }
}

/// GET /v1/machines
public struct RemoteMachineList: Codable, Sendable, Equatable {
    public var machines: [RemoteMachineEntry]

    public init(machines: [RemoteMachineEntry]) { self.machines = machines }
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
    /// The prompts waiting for the turn to end, oldest first.
    public var queuedPrompts: [RemoteQueuedPrompt]
    public var parentCardId: String?
    public var archived: Bool
    /// Pinned to the top of the board.
    public var pinned: Bool
    public var lastActivity: Date?
    public var updatedAt: Date
    /// The master that owns the card and runs its session. Prompts, the
    /// transcript and terminals of the card go to that master. Nil on a
    /// server from before several masters.
    public var machineId: String?
    /// Display name of `machineId`, when the serving master knows it.
    public var machineName: String?
    /// A start of the session in flight or failed, a move to another
    /// master, or a machine that is not connected: what the card shows in
    /// place of its resume button. Nil when the session runs or ended.
    public var sessionStatus: RemoteSessionStatus?

    public init(
        id: String, title: String, column: RemoteColumn, projectPath: String? = nil, projectName: String? = nil,
        branch: String? = nil, worktreePath: String? = nil, assistant: String = "claude", runtime: RemoteRuntime = .none,
        isLive: Bool = false, isBusy: Bool = false, sessionId: String? = nil, terminals: [RemoteTerminal] = [],
        prs: [RemotePR] = [], queuedPromptCount: Int = 0, queuedPrompts: [RemoteQueuedPrompt] = [],
        parentCardId: String? = nil, archived: Bool = false, pinned: Bool = false,
        lastActivity: Date? = nil, updatedAt: Date, machineId: String? = nil, machineName: String? = nil,
        sessionStatus: RemoteSessionStatus? = nil
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
        self.queuedPrompts = queuedPrompts
        self.parentCardId = parentCardId
        self.archived = archived
        self.pinned = pinned
        self.lastActivity = lastActivity
        self.updatedAt = updatedAt
        self.machineId = machineId
        self.machineName = machineName
        self.sessionStatus = sessionStatus
    }
}

/// Where the session of a card stands when it neither simply runs nor
/// simply ended. Every client shows `text` where the resume button goes.
public struct RemoteSessionStatus: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// A launch or resume is in flight; `text` is its step.
        case starting
        /// The card moves to another master; `text` says where and how far.
        case moving
        /// The session runs on a machine that is not connected.
        case machine
        /// The last start failed; `text` says why.
        case failed
    }

    public var kind: Kind
    public var text: String
    /// Whether a resume is the way on (a failed start, a paused machine).
    public var canResume: Bool

    public init(kind: Kind, text: String, canResume: Bool = false) {
        self.kind = kind
        self.text = text
        self.canResume = canResume
    }
}

/// The JSON of a card leaves out what is false, zero or empty (`isLive`,
/// `isBusy`, `archived`, `queuedPromptCount`, `queuedPrompts`, `terminals`, `prs`) and nil
/// optionals; decoding reads a missing key as that default. A board of
/// thousands of cards stays small that way.
extension RemoteCard {
    private enum CodingKeys: String, CodingKey {
        case id, title, column, projectPath, projectName, branch, worktreePath, assistant, runtime
        case isLive, isBusy, sessionId, terminals, prs, queuedPromptCount, queuedPrompts, parentCardId, archived, pinned
        case lastActivity, updatedAt, machineId, machineName, sessionStatus
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
            queuedPrompts: try c.decodeIfPresent([RemoteQueuedPrompt].self, forKey: .queuedPrompts) ?? [],
            parentCardId: try c.decodeIfPresent(String.self, forKey: .parentCardId),
            archived: try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false,
            pinned: try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false,
            lastActivity: try c.decodeIfPresent(Date.self, forKey: .lastActivity),
            updatedAt: try c.decode(Date.self, forKey: .updatedAt),
            machineId: try c.decodeIfPresent(String.self, forKey: .machineId),
            machineName: try c.decodeIfPresent(String.self, forKey: .machineName),
            // A kind this client does not know yet reads as no status.
            sessionStatus: (try? c.decodeIfPresent(RemoteSessionStatus.self, forKey: .sessionStatus)) ?? nil
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
        if !queuedPrompts.isEmpty { try c.encode(queuedPrompts, forKey: .queuedPrompts) }
        try c.encodeIfPresent(parentCardId, forKey: .parentCardId)
        if archived { try c.encode(true, forKey: .archived) }
        if pinned { try c.encode(true, forKey: .pinned) }
        try c.encodeIfPresent(lastActivity, forKey: .lastActivity)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(machineId, forKey: .machineId)
        try c.encodeIfPresent(machineName, forKey: .machineName)
        try c.encodeIfPresent(sessionStatus, forKey: .sessionStatus)
    }
}

/// A prompt waiting on a card for its turn to end.
public struct RemoteQueuedPrompt: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var text: String
    public var imageCount: Int

    public init(id: String, text: String, imageCount: Int = 0) {
        self.id = id
        self.text = text
        self.imageCount = imageCount
    }

    private enum CodingKeys: String, CodingKey { case id, text, imageCount }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        imageCount = try c.decodeIfPresent(Int.self, forKey: .imageCount) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(text, forKey: .text)
        if imageCount != 0 { try c.encode(imageCount, forKey: .imageCount) }
    }
}

/// An image sent with a prompt or a task: PNG, JPEG, GIF or WebP bytes,
/// base64 encoded.
public struct RemoteImage: Codable, Sendable, Equatable {
    /// Largest image the server takes, decoded.
    public static let maxBytes = 5 * 1024 * 1024
    /// Most images in one prompt or task.
    public static let maxCount = 6

    /// `image/png`, `image/jpeg`, `image/gif` or `image/webp`.
    public var mediaType: String
    /// Base64 of the image bytes.
    public var data: String

    public init(mediaType: String, data: String) {
        self.mediaType = mediaType
        self.data = data
    }

    public init(bytes: Data, mediaType: String) {
        self.init(mediaType: mediaType, data: bytes.base64EncodedString())
    }

    public var bytes: Data? { Data(base64Encoded: data, options: .ignoreUnknownCharacters) }
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
    /// The master serving this board. Its board may also list cards other
    /// masters own (synced from them); `RemoteCard.machineId` tells.
    public var machine: RemoteMachine?

    public init(cards: [RemoteCard], projects: [RemoteProject], generatedAt: Date, machine: RemoteMachine? = nil) {
        self.cards = cards
        self.projects = projects
        self.generatedAt = generatedAt
        self.machine = machine
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
    /// The long text behind a `system` note, shown when the note is
    /// opened: the summary of a compaction.
    public var detail: String?

    public init(id: String, role: Role, text: String, at: Date? = nil, detail: String? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.at = at
        self.detail = detail
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
    public var images: [RemoteImage]?
    /// Where the card runs: "mac" for the Mac itself, or the name of a
    /// machine (an ssh machine or a boxd machine). nil follows the project
    /// default, as the New Task dialog would.
    public var machine: String?
    /// true when the human typed the prompt himself in the app. Ignored
    /// from an agent-scope device.
    public var human: Bool?

    public init(project: String, prompt: String, name: String? = nil, worktree: String? = nil,
                assistant: String? = nil, model: String? = nil, launch: Bool? = nil, images: [RemoteImage]? = nil,
                machine: String? = nil, human: Bool? = nil) {
        self.project = project
        self.prompt = prompt
        self.name = name
        self.worktree = worktree
        self.assistant = assistant
        self.model = model
        self.launch = launch
        self.images = images
        self.machine = machine
        self.human = human
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

    /// May be empty when `images` has some.
    public var text: String
    public var mode: Mode?
    public var images: [RemoteImage]?
    /// True when the human typed and sent this himself in a chat composer.
    /// Prompts from agents, scripts and other cards leave it out.
    public var human: Bool?

    public init(text: String, mode: Mode? = nil, images: [RemoteImage]? = nil, human: Bool? = nil) {
        self.text = text
        self.mode = mode
        self.images = images
        self.human = human
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
    /// Every open attention request, on `board` frames and on the `cards`
    /// frame after the list changed; absent when it did not change.
    public var attention: [AttentionRequest]?

    public init(
        type: Kind, board: RemoteBoard? = nil, upserted: [RemoteCard]? = nil,
        removed: [String]? = nil, projects: [RemoteProject]? = nil,
        attention: [AttentionRequest]? = nil
    ) {
        self.type = type
        self.board = board
        self.upserted = upserted
        self.removed = removed
        self.projects = projects
        self.attention = attention
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
        /// Scrolls a tmux terminal's history by `lines`: up when positive,
        /// down when negative. Only when the server lists
        /// `RemoteAPI.Feature.terminalScroll`.
        case scroll
    }

    public var type: Kind
    public var cols: Int?
    public var rows: Int?
    public var lines: Int?

    public init(type: Kind, cols: Int? = nil, rows: Int? = nil, lines: Int? = nil) {
        self.type = type
        self.cols = cols
        self.rows = rows
        self.lines = lines
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

// MARK: - Vault

/// One entry of `GET /v1/vault/secrets`; only the name is read here.
public struct RemoteVaultSecretName: Codable, Sendable, Equatable {
    public var name: String
    public init(name: String) { self.name = name }
}

/// Body of `POST /v1/vault/secrets` and `POST /v1/vault/compare`. Without a
/// tier or rules a stored secret keeps its own.
public struct RemoteVaultAddRequest: Codable, Sendable, Equatable {
    public var name: String
    public var value: String
    public var tier: String?
    public var rules: String?
    /// Why a stored value is replaced, shown to the human who approves it.
    public var reason: String?
    public init(name: String, value: String, tier: String? = nil, rules: String? = nil, reason: String? = nil) {
        self.name = name
        self.value = value
        self.tier = tier
        self.rules = rules
        self.reason = reason
    }
}

/// Answer of `POST /v1/vault/compare`: `absent`, `same` or `different`.
public struct RemoteVaultValueCheck: Codable, Sendable, Equatable {
    public var name: String
    public var outcome: String
    public init(name: String, outcome: String) {
        self.name = name
        self.outcome = outcome
    }
}

/// The vault's answer: `granted`, `pending` (asked the human) or `denied`.
public struct RemoteVaultResponse: Codable, Sendable, Equatable {
    public var status: String
    public var message: String
    public var id: String?
    public init(status: String, message: String, id: String? = nil) {
        self.status = status
        self.message = message
        self.id = id
    }
}
