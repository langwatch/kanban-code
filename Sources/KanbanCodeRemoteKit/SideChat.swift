import Foundation

// MARK: - Wire models

/// What a side chat run answers: a question about the session (`btw`), or
/// the catch-up since the human's last message (`catchup`).
public enum RemoteSideChatKind: String, Codable, Sendable {
    case btw
    case catchup
}

/// One finished question and answer of a side chat, sent back with a
/// follow-up so the side run sees what came before it.
public struct RemoteSideChatExchange: Codable, Sendable, Equatable {
    public var question: String
    public var answer: String

    public init(question: String, answer: String) {
        self.question = question
        self.answer = answer
    }
}

/// POST /v1/cards/{id}/side-chat
public struct RemoteSideChatRequest: Codable, Sendable, Equatable {
    public var kind: RemoteSideChatKind
    /// The question of a `btw` run; a `catchup` run has a fixed prompt.
    public var question: String?
    /// Earlier exchanges of the same side chat, oldest first.
    public var history: [RemoteSideChatExchange]?
    /// true runs a new catch-up even when the card's last one still covers
    /// the whole session.
    public var fresh: Bool?
    /// For a `btw` run that follows up on a catch-up: that catch-up's run
    /// id, so the exchange is kept with it.
    public var catchUpId: String?

    public init(kind: RemoteSideChatKind, question: String? = nil, history: [RemoteSideChatExchange]? = nil,
                fresh: Bool? = nil, catchUpId: String? = nil) {
        self.kind = kind
        self.question = question
        self.history = history
        self.fresh = fresh
        self.catchUpId = catchUpId
    }
}

/// A message of the main chat a catch-up can cite as `[m7]`.
public struct RemoteSideChatRef: Codable, Sendable, Equatable, Identifiable {
    /// The citation, such as `m7`.
    public var ref: String
    /// Byte offset of the message in the transcript file. The Mac chat
    /// names its rows by it, and a `RemoteMessage.id` starts with it.
    public var offset: Int
    /// Who wrote it: `you`, `assistant`, or the sender of a delivered message.
    public var role: String
    public var at: Date?
    public var preview: String

    public var id: String { ref }

    public init(ref: String, offset: Int, role: String, at: Date? = nil, preview: String) {
        self.ref = ref
        self.offset = offset
        self.role = role
        self.at = at
        self.preview = preview
    }

    /// The transcript offset a `RemoteMessage.id` (`<offset>.<n>`) starts with.
    public static func offset(ofMessageId id: String) -> Int? {
        Int(id.prefix { $0 != "." })
    }

    /// The loaded message this citation points at: the last text of the
    /// turn at `offset`, or the nearest message before it.
    public func message(in messages: [RemoteMessage]) -> RemoteMessage? {
        var exact: RemoteMessage?
        var nearest: RemoteMessage?
        for message in messages {
            guard let at = Self.offset(ofMessageId: message.id) else { continue }
            if at == offset {
                if exact == nil || message.role != .tool { exact = message }
            } else if at < offset {
                nearest = message
            }
        }
        return exact ?? nearest
    }

    /// Whether the cited message can be in `messages`: the oldest loaded
    /// one starts at or before it.
    public func isLoaded(in messages: [RemoteMessage]) -> Bool {
        for message in messages {
            if let at = Self.offset(ofMessageId: message.id) { return at <= offset }
        }
        return false
    }
}

/// The human's last message, where a catch-up starts.
public struct RemoteSideChatSince: Codable, Sendable, Equatable {
    public var text: String
    public var at: Date?
    /// Byte offset of the message in the transcript; nil when it has not
    /// reached the session yet (still queued).
    public var offset: Int?

    public init(text: String, at: Date? = nil, offset: Int? = nil) {
        self.text = text
        self.at = at
        self.offset = offset
    }
}

/// A side chat run and what it has answered so far.
public struct RemoteSideChatRun: Codable, Sendable, Equatable, Identifiable {
    public enum State: String, Codable, Sendable {
        case running
        case done
        case failed
    }

    public var id: String
    public var cardId: String
    public var kind: RemoteSideChatKind
    public var state: State
    /// The answer so far; the whole answer once `state` is `done`.
    public var text: String
    public var error: String?
    /// For a catch-up: the message it starts from and the messages it can cite.
    public var since: RemoteSideChatSince?
    public var refs: [RemoteSideChatRef]?
    /// When the answer ended.
    public var finishedAt: Date?
    /// true for a catch-up made earlier and returned again because the
    /// session has no message after the last one it covers.
    public var reopened: Bool?
    /// The follow-ups asked in the side chat of a reopened catch-up.
    public var followUps: [RemoteSideChatExchange]?

    public init(id: String, cardId: String, kind: RemoteSideChatKind, state: State = .running, text: String = "",
                error: String? = nil, since: RemoteSideChatSince? = nil, refs: [RemoteSideChatRef]? = nil,
                finishedAt: Date? = nil, reopened: Bool? = nil, followUps: [RemoteSideChatExchange]? = nil) {
        self.id = id
        self.cardId = cardId
        self.kind = kind
        self.state = state
        self.text = text
        self.error = error
        self.since = since
        self.refs = refs
        self.finishedAt = finishedAt
        self.reopened = reopened
        self.followUps = followUps
    }
}

// MARK: - Composer commands

/// `/btw <question>` and `/catchup` typed in a chat composer.
public enum SideChatCommand: Equatable, Sendable {
    case btw(String)
    case catchup

    /// The command `text` is, or nil when it is a prompt for the session.
    /// `/btw` alone opens the side chat with nothing asked yet.
    public static func parse(_ text: String) -> SideChatCommand? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let word = trimmed.prefix { !$0.isWhitespace }.lowercased()
        let rest = trimmed.dropFirst(word.count).trimmingCharacters(in: .whitespacesAndNewlines)
        switch word {
        case "/btw": return .btw(rest)
        case "/catchup", "/catch-up": return rest.isEmpty ? .catchup : nil
        default: return nil
        }
    }
}

// MARK: - Catch-up answer

/// A catch-up as the side model wrote it: sections of short items, each
/// citing the messages it comes from.
public struct CatchUpSummary: Equatable, Sendable {
    public struct Item: Equatable, Sendable, Identifiable {
        public var id: Int
        public var text: String
        /// Citations such as `m7`, in the order given.
        public var refs: [String]

        public init(id: Int, text: String, refs: [String]) {
            self.id = id
            self.text = text
            self.refs = refs
        }
    }

    public struct Section: Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var items: [Item]

        public init(id: String, title: String, items: [Item]) {
            self.id = id
            self.title = title
            self.items = items
        }
    }

    public var sections: [Section]
    /// The agent's final report of the main task, linked on its own.
    public var report: Item?

    public init(sections: [Section], report: Item? = nil) {
        self.sections = sections
        self.report = report
    }

    /// The order and titles of the sections, by id.
    public static let order: [(id: String, title: String)] = [
        ("asked", "What you asked"),
        ("status", "Where it stands"),
        ("facts", "Key facts"),
        ("waiting", "Waiting on you"),
        ("blocked", "Blocked or failed"),
        ("other", "What else happened"),
    ]

    public static func title(forSection id: String) -> String {
        order.first { $0.id == id }?.title ?? id.prefix(1).uppercased() + id.dropFirst()
    }

    /// The catch-up as markdown, citations in brackets: what a follow-up
    /// and the main chat are given.
    public var markdown: String {
        var lines: [String] = []
        func cite(_ item: Item) -> String {
            item.refs.isEmpty ? item.text : item.text + " " + item.refs.map { "[\($0)]" }.joined(separator: " ")
        }
        for section in sections where !section.items.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines.append("**\(section.title)**")
            for item in section.items { lines.append("- " + cite(item)) }
        }
        if let report {
            if !lines.isEmpty { lines.append("") }
            lines.append(cite(report))
        }
        return lines.joined(separator: "\n")
    }
}

/// Reads a catch-up answer: one JSON object per line
/// (`{"section": "facts", "text": "...", "refs": ["m7"]}`), or one JSON
/// document with `sections`. Lines that do not parse are skipped, so an
/// answer still streaming shows what has arrived.
public enum CatchUpParser {
    /// The summary, or nil when nothing in `text` parses (the caller then
    /// shows the text as markdown).
    public static func parse(_ text: String) -> CatchUpSummary? {
        let body = strippingFences(text)
        if let document = parseDocument(body) { return document }
        var bySection: [String: [CatchUpSummary.Item]] = [:]
        var seen: [String] = []
        var report: CatchUpSummary.Item?
        var next = 0
        for line in body.split(whereSeparator: \.isNewline) {
            guard let object = jsonObject(String(line)),
                  let section = (object["section"] as? String)?.lowercased(),
                  let item = item(from: object, id: next) else { continue }
            next += 1
            if section == "report" {
                report = item
                continue
            }
            if bySection[section] == nil { seen.append(section) }
            bySection[section, default: []].append(item)
        }
        return summary(bySection: bySection, seen: seen, report: report)
    }

    private static func parseDocument(_ body: String) -> CatchUpSummary? {
        guard let start = body.firstIndex(of: "{"), let end = body.lastIndex(of: "}"), start < end,
              let object = jsonObject(String(body[start...end])),
              let sections = object["sections"] as? [[String: Any]] else { return nil }
        var bySection: [String: [CatchUpSummary.Item]] = [:]
        var seen: [String] = []
        var next = 0
        for section in sections {
            guard let id = ((section["id"] ?? section["section"]) as? String)?.lowercased() else { continue }
            for raw in section["items"] as? [[String: Any]] ?? [] {
                guard let item = item(from: raw, id: next) else { continue }
                next += 1
                if bySection[id] == nil { seen.append(id) }
                bySection[id, default: []].append(item)
            }
        }
        // The report is an item, or only the id of its message.
        var report = (object["report"] as? [String: Any]).flatMap { raw -> CatchUpSummary.Item? in
            var raw = raw
            if raw["text"] == nil { raw["text"] = raw["label"] ?? "Full report" }
            if raw["refs"] == nil, let ref = raw["ref"] { raw["refs"] = [ref] }
            return item(from: raw, id: next)
        }
        if report == nil, let ref = object["report"].flatMap(normalizedRef) {
            report = CatchUpSummary.Item(id: next, text: "Full report", refs: [ref])
        }
        return summary(bySection: bySection, seen: seen, report: report)
    }

    private static func summary(bySection: [String: [CatchUpSummary.Item]], seen: [String],
                                report: CatchUpSummary.Item?) -> CatchUpSummary? {
        guard !bySection.isEmpty || report != nil else { return nil }
        let known = CatchUpSummary.order.map(\.id)
        let ids = known.filter { bySection[$0] != nil } + seen.filter { !known.contains($0) }
        let sections = ids.map {
            CatchUpSummary.Section(id: $0, title: CatchUpSummary.title(forSection: $0), items: bySection[$0] ?? [])
        }
        return CatchUpSummary(sections: sections, report: report)
    }

    private static func item(from object: [String: Any], id: Int) -> CatchUpSummary.Item? {
        guard let raw = object["text"] as? String else { return nil }
        var refs: [String] = []
        for value in object["refs"] as? [Any] ?? [] {
            if let ref = normalizedRef(value), !refs.contains(ref) { refs.append(ref) }
        }
        // A citation left in the text reads as a link too.
        let (text, inline) = extractingCitations(from: raw)
        for ref in inline where !refs.contains(ref) { refs.append(ref) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return CatchUpSummary.Item(id: id, text: trimmed, refs: refs)
    }

    /// `m7` from `m7`, `[m7]`, `M7` or the number 7.
    static func normalizedRef(_ value: Any) -> String? {
        if let number = value as? Int { return "m\(number)" }
        guard let string = value as? String else { return nil }
        let core = string.trimmingCharacters(in: CharacterSet(charactersIn: "[] \t")).lowercased()
        let digits = core.hasPrefix("m") ? core.dropFirst() : Substring(core)
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        return "m" + digits
    }

    /// Takes `[m7]` citations out of `text`.
    public static func extractingCitations(from text: String) -> (text: String, refs: [String]) {
        var out = ""
        var refs: [String] = []
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "[") {
            guard let close = rest[open...].firstIndex(of: "]") else { break }
            let inside = rest[rest.index(after: open)..<close]
            if inside.count <= 8, inside.lowercased().hasPrefix("m"), let ref = normalizedRef(String(inside)) {
                out += rest[..<open]
                // The space before a citation goes with it.
                if out.hasSuffix(" ") { out.removeLast() }
                if !refs.contains(ref) { refs.append(ref) }
            } else {
                out += rest[...close]
            }
            rest = rest[rest.index(after: close)...]
        }
        out += rest
        return (out, refs)
    }

    private static func strippingFences(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
            .joined(separator: "\n")
    }

    private static func jsonObject(_ text: String) -> [String: Any]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

// MARK: - Side chat state

/// A side chat as its panel shows it: the questions asked, the answers so
/// far, and whether the panel is open. Changed only through `apply`.
public struct SideChatState: Equatable, Sendable {
    public struct Entry: Equatable, Sendable, Identifiable {
        /// Local until the run starts, then the run's id.
        public var id: String
        public var kind: RemoteSideChatKind
        public var question: String
        public var answer: String
        public var isRunning: Bool
        public var error: String?
        /// The failure was the machine not answering (asleep, off the
        /// network), not something the machine said.
        public var unreachable: Bool
        public var since: RemoteSideChatSince?
        public var refs: [RemoteSideChatRef]
        /// A catch-up made earlier, shown again.
        public var reopened: Bool
        public var finishedAt: Date?

        public init(id: String, kind: RemoteSideChatKind, question: String, answer: String = "", isRunning: Bool = true,
                    error: String? = nil, since: RemoteSideChatSince? = nil, refs: [RemoteSideChatRef] = [],
                    reopened: Bool = false, finishedAt: Date? = nil, unreachable: Bool = false) {
            self.unreachable = unreachable
            self.id = id
            self.kind = kind
            self.question = question
            self.answer = answer
            self.isRunning = isRunning
            self.error = error
            self.since = since
            self.refs = refs
            self.reopened = reopened
            self.finishedAt = finishedAt
        }

        /// The catch-up of this entry, when its answer parses as one.
        public var catchUp: CatchUpSummary? {
            kind == .catchup ? CatchUpParser.parse(answer) : nil
        }

        /// The answer as text: a catch-up reads as its markdown.
        public var answerText: String {
            catchUp?.markdown ?? answer.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        public func ref(_ citation: String) -> RemoteSideChatRef? {
            refs.first { $0.ref == citation }
        }

        /// What a reopened catch-up says about its age: "From 14:02, nothing
        /// new since", with the day when it is not today's.
        public func reopenedNote(now: Date = .now, timeZone: TimeZone = .current) -> String? {
            guard reopened else { return nil }
            guard let finishedAt else { return "Nothing new since this catch-up" }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = calendar.isDate(finishedAt, inSameDayAs: now) ? "HH:mm" : "MMM d, HH:mm"
            return "From \(formatter.string(from: finishedAt)), nothing new since"
        }
    }

    public enum Event: Equatable, Sendable {
        /// The human asked: the entry shows at once, waiting.
        case asked(localId: String, kind: RemoteSideChatKind, question: String)
        /// The run started; its id replaces the local one.
        case started(localId: String, run: RemoteSideChatRun)
        /// More of the answer, or its end.
        case progress(RemoteSideChatRun)
        case failed(id: String, message: String, unreachable: Bool = false)
        /// A failed question leaves, to be asked again.
        case removed(id: String)
        /// The panel opens with nothing asked (`/btw` alone).
        case opened
        /// The panel closes and the side chat is forgotten.
        case dismissed
    }

    public var entries: [Entry] = []
    public var isOpen = false

    public init() {}

    public static let catchUpQuestion = "Catch me up"

    public var isRunning: Bool { entries.contains(where: \.isRunning) }

    /// The question that failed last, which Retry asks again.
    public var failedEntry: Entry? {
        guard let last = entries.last, last.error != nil, !last.isRunning else { return nil }
        return last
    }

    /// The run id of the catch-up this side chat holds: what a follow-up
    /// is kept with.
    public var catchUpId: String? {
        entries.last { $0.kind == .catchup && !$0.isRunning && $0.error == nil && !$0.id.hasPrefix("local-") }?.id
    }

    /// The run to poll, when one is under way and has started.
    public var runningId: String? { entries.last(where: \.isRunning)?.id }

    /// Finished exchanges, oldest first: what a follow-up carries.
    public var history: [RemoteSideChatExchange] {
        entries.compactMap { entry in
            let answer = entry.answerText
            guard !entry.isRunning, entry.error == nil, !answer.isEmpty else { return nil }
            return RemoteSideChatExchange(question: entry.question, answer: answer)
        }
    }

    public mutating func apply(_ event: Event) {
        switch event {
        case .asked(let localId, let kind, let question):
            // A question that failed leaves when the next one is asked.
            entries.removeAll { $0.error != nil && $0.answer.isEmpty }
            entries.append(Entry(id: localId, kind: kind, question: question))
            isOpen = true
        case .started(let localId, let run):
            // A reopened catch-up that already shows takes the place of
            // its earlier copy, follow-ups included.
            entries.removeAll { $0.id == run.id || $0.id.hasPrefix(run.id + "/") }
            guard let index = entries.firstIndex(where: { $0.id == localId }) else { return }
            entries[index].id = run.id
            merge(run, at: index)
            let followUps = (run.followUps ?? []).enumerated().map { number, exchange in
                Entry(id: "\(run.id)/\(number)", kind: .btw, question: exchange.question, answer: exchange.answer,
                      isRunning: false)
            }
            entries.insert(contentsOf: followUps, at: index + 1)
        case .progress(let run):
            guard let index = entries.firstIndex(where: { $0.id == run.id }) else { return }
            merge(run, at: index)
        case .failed(let id, let message, let unreachable):
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
            entries[index].isRunning = false
            entries[index].error = message
            entries[index].unreachable = unreachable
        case .removed(let id):
            entries.removeAll { $0.id == id }
        case .opened:
            isOpen = true
        case .dismissed:
            entries = []
            isOpen = false
        }
    }

    private mutating func merge(_ run: RemoteSideChatRun, at index: Int) {
        entries[index].answer = run.text
        entries[index].isRunning = run.state == .running
        entries[index].error = run.state == .failed ? (run.error ?? "The side chat failed.") : nil
        if let since = run.since { entries[index].since = since }
        if let refs = run.refs { entries[index].refs = refs }
        entries[index].reopened = run.reopened == true
        entries[index].finishedAt = run.finishedAt
    }
}

// MARK: - A machine that does not answer

public enum SideChatFailure {
    /// What the panel says when the card's machine cannot be reached.
    public static func offlineMessage(machine: String) -> String {
        let name = machine.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(name.isEmpty ? "The machine" : name) is offline. It may be asleep."
    }

    /// Whether `error` means the request got no answer from the machine: a
    /// timeout, a refused or lost connection. An answer with an error
    /// status is the machine speaking, so it is not.
    public static func isUnreachable(_ error: any Error) -> Bool {
        if let error = error as? RemoteClientError {
            if case .transport = error { return true }
            return false
        }
        return error is URLError
    }

    /// What an entry's failure reads as: the offline line when the machine
    /// did not answer or is known to be offline, else the error itself.
    public static func text(for entry: SideChatState.Entry, machine: String, machineOffline: Bool) -> String? {
        guard let error = entry.error else { return nil }
        return entry.unreachable || machineOffline ? offlineMessage(machine: machine) : error
    }
}

// MARK: - Bringing a side chat into the main chat

public enum SideChatHandoff {
    /// The prompt that continues a side chat in the main chat: the human's
    /// reply first, then the side chat as context for the main agent.
    public static func mainChatPrompt(reply: String, entries: [SideChatState.Entry]) -> String {
        let reply = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines: [String] = [reply, "", "---",
                               "Context for the message above: a side chat I had about this session. "
                                   + "You did not see it; it ran apart from this conversation."]
        for entry in entries {
            let answer = entry.answerText
            guard entry.error == nil, !answer.isEmpty else { continue }
            lines.append("")
            lines.append("I asked: " + entry.question)
            lines.append("The side chat answered:")
            lines.append(answer)
        }
        return lines.joined(separator: "\n")
    }
}
