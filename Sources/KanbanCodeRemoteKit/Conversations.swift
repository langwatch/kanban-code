import Foundation

// MARK: - Wire types

/// One conversation of a card (docs/conversations.md): a topic of the
/// card's chat with its own messages. The card's session stays one.
public struct RemoteConversation: Codable, Sendable, Equatable, Identifiable, Hashable {
    /// Two words joined by a dash, such as `swift-otter`.
    public var id: String
    /// Nil until the agent or the human names it.
    public var title: String?
    public var createdAt: Date
    /// When its last message was written, else when it was created.
    public var updatedAt: Date
    public var messageCount: Int
    /// Who wrote the last message.
    public var lastRole: RemoteConversationRole?
    /// The start of the last message, on one line.
    public var preview: String?
    /// The agent wrote after the human last opened it.
    public var unread: Bool
    /// The last message is the agent's: the conversation waits on the human.
    public var waiting: Bool
    public var archived: Bool
    /// The agent message a "Continue in new conversation" started from.
    public var quote: String?
    /// The agent wrote in it at least once.
    public var replied: Bool

    public init(id: String, title: String? = nil, createdAt: Date, updatedAt: Date? = nil, messageCount: Int = 0,
                lastRole: RemoteConversationRole? = nil, preview: String? = nil, unread: Bool = false,
                waiting: Bool = false, archived: Bool = false, quote: String? = nil, replied: Bool = false) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.messageCount = messageCount
        self.lastRole = lastRole
        self.preview = preview
        self.unread = unread
        self.waiting = waiting
        self.archived = archived
        self.quote = quote
        self.replied = replied
    }

    /// The title, or what a conversation without one is called.
    public var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return "New conversation"
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, updatedAt, messageCount, lastRole, preview, unread, waiting, archived, quote, replied
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        messageCount = try c.decodeIfPresent(Int.self, forKey: .messageCount) ?? 0
        lastRole = try? c.decodeIfPresent(RemoteConversationRole.self, forKey: .lastRole)
        preview = try c.decodeIfPresent(String.self, forKey: .preview)
        unread = try c.decodeIfPresent(Bool.self, forKey: .unread) ?? false
        waiting = try c.decodeIfPresent(Bool.self, forKey: .waiting) ?? false
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        quote = try c.decodeIfPresent(String.self, forKey: .quote)
        replied = try c.decodeIfPresent(Bool.self, forKey: .replied) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        if messageCount != 0 { try c.encode(messageCount, forKey: .messageCount) }
        try c.encodeIfPresent(lastRole, forKey: .lastRole)
        try c.encodeIfPresent(preview, forKey: .preview)
        if unread { try c.encode(true, forKey: .unread) }
        if waiting { try c.encode(true, forKey: .waiting) }
        if archived { try c.encode(true, forKey: .archived) }
        try c.encodeIfPresent(quote, forKey: .quote)
        if replied { try c.encode(true, forKey: .replied) }
    }
}

public enum RemoteConversationRole: String, Codable, Sendable, Hashable {
    case human
    case agent
}

public struct RemoteConversationMessage: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: String
    public var role: RemoteConversationRole
    public var text: String
    public var at: Date
    /// Paths of the images sent with the message, on the master that owns
    /// the card. Another machine shows them only when it can read them.
    public var images: [String]?

    public init(id: String, role: RemoteConversationRole, text: String, at: Date, images: [String]? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.at = at
        self.images = images?.isEmpty == true ? nil : images
    }
}

/// GET /v1/cards/{id}/conversations/{conv}
public struct RemoteConversationDetail: Codable, Sendable, Equatable {
    public var conversation: RemoteConversation
    /// Oldest first.
    public var messages: [RemoteConversationMessage]

    public init(conversation: RemoteConversation, messages: [RemoteConversationMessage]) {
        self.conversation = conversation
        self.messages = messages
    }
}

/// POST /v1/cards/{id}/conversations
public struct RemoteConversationCreate: Codable, Sendable, Equatable {
    public var title: String?
    /// The agent message the conversation continues from.
    public var quote: String?

    public init(title: String? = nil, quote: String? = nil) {
        self.title = title
        self.quote = quote
    }
}

/// PATCH /v1/cards/{id}/conversations/{conv}
public struct RemoteConversationUpdate: Codable, Sendable, Equatable {
    public var title: String?
    /// True marks it read by the human.
    public var read: Bool?
    public var archived: Bool?

    public init(title: String? = nil, read: Bool? = nil, archived: Bool? = nil) {
        self.title = title
        self.read = read
        self.archived = archived
    }
}

// MARK: - Log

/// One line of `~/.kanban-code/conversations/<cardId>.jsonl`.
public struct ConversationEvent: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case created, message, title, read, retracted, archived
    }

    public var type: Kind
    public var conv: String
    public var at: Date
    public var id: String?
    public var role: RemoteConversationRole?
    public var text: String?
    public var title: String?
    public var quote: String?
    /// `human` or `agent`, on `created` and `title`.
    public var by: String?
    public var archived: Bool?
    /// On `message`: paths of its images on the owner.
    public var images: [String]?

    public init(type: Kind, conv: String, at: Date = .now, id: String? = nil, role: RemoteConversationRole? = nil,
                text: String? = nil, title: String? = nil, quote: String? = nil, by: String? = nil, archived: Bool? = nil,
                images: [String]? = nil) {
        self.type = type
        self.conv = conv
        self.at = at
        self.id = id
        self.role = role
        self.text = text
        self.title = title
        self.quote = quote
        self.by = by
        self.archived = archived
        self.images = images?.isEmpty == true ? nil : images
    }

    public static func created(_ conv: String, title: String? = nil, quote: String? = nil, by: String = "human", at: Date = .now) -> Self {
        .init(type: .created, conv: conv, at: at, title: title, quote: quote, by: by)
    }

    public static func message(_ conv: String, id: String, role: RemoteConversationRole, text: String, at: Date = .now,
                               images: [String]? = nil) -> Self {
        .init(type: .message, conv: conv, at: at, id: id, role: role, text: text, images: images)
    }

    public static func title(_ conv: String, _ title: String, by: String = "human", at: Date = .now) -> Self {
        .init(type: .title, conv: conv, at: at, title: title, by: by)
    }

    public static func read(_ conv: String, at: Date = .now) -> Self {
        .init(type: .read, conv: conv, at: at)
    }

    public static func retracted(_ conv: String, id: String, at: Date = .now) -> Self {
        .init(type: .retracted, conv: conv, at: at, id: id)
    }

    public static func archived(_ conv: String, _ archived: Bool, at: Date = .now) -> Self {
        .init(type: .archived, conv: conv, at: at, archived: archived)
    }

    /// The event as one line of the log, newline included.
    public func line() -> Data {
        var data = (try? JSONEncoder.remote.encode(self)) ?? Data()
        data.append(0x0A)
        return data
    }
}

/// A conversation with its messages, as the log folds into.
public struct ConversationThread: Sendable, Equatable {
    public var summary: RemoteConversation
    /// Oldest first.
    public var messages: [RemoteConversationMessage]

    public var detail: RemoteConversationDetail { .init(conversation: summary, messages: messages) }
}

public enum ConversationLog {
    /// Folds the log into its conversations, most recent first. Lines that
    /// do not parse (a write cut short) are skipped.
    public static func fold(_ data: Data) -> [ConversationThread] {
        let decoder = JSONDecoder.remote
        var order: [String] = []
        var threads: [String: Builder] = [:]
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let event = try? decoder.decode(ConversationEvent.self, from: Data(line)) else { continue }
            if threads[event.conv] == nil {
                order.append(event.conv)
                threads[event.conv] = Builder(id: event.conv, createdAt: event.at)
            }
            threads[event.conv]!.apply(event)
        }
        return order.compactMap { threads[$0]?.thread }
            .sorted { $0.summary.updatedAt > $1.summary.updatedAt }
    }

    public static func fold(path: String) -> [ConversationThread] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        return fold(data)
    }

    private struct Builder {
        var id: String
        var createdAt: Date
        var title: String?
        var quote: String?
        var archived = false
        var readAt: Date?
        var messages: [RemoteConversationMessage] = []

        init(id: String, createdAt: Date) {
            self.id = id
            self.createdAt = createdAt
        }

        mutating func apply(_ event: ConversationEvent) {
            switch event.type {
            case .created:
                createdAt = event.at
                if let t = event.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { title = t }
                if let q = event.quote, !q.isEmpty { quote = q }
            case .message:
                guard let id = event.id, let role = event.role else { return }
                let text = event.text ?? ""
                if let index = messages.firstIndex(where: { $0.id == id }) {
                    messages[index].text = text
                    if let images = event.images { messages[index].images = images }
                } else {
                    messages.append(.init(id: id, role: role, text: text, at: event.at, images: event.images))
                }
            case .title:
                let t = event.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                title = t.isEmpty ? nil : t
            case .read:
                if readAt.map({ event.at > $0 }) ?? true { readAt = event.at }
            case .retracted:
                messages.removeAll { $0.id == event.id }
            case .archived:
                archived = event.archived ?? true
            }
        }

        var thread: ConversationThread {
            let last = messages.last
            let unread = messages.contains { message in
                message.role == .agent && (readAt.map { message.at > $0 } ?? true)
            }
            let summary = RemoteConversation(
                id: id, title: title, createdAt: createdAt, updatedAt: last?.at ?? createdAt,
                messageCount: messages.count, lastRole: last?.role, preview: last.map { ConversationLog.preview($0.text) },
                unread: unread, waiting: last?.role == .agent, archived: archived, quote: quote,
                replied: messages.contains { $0.role == .agent })
            return ConversationThread(summary: summary, messages: messages)
        }
    }

    /// The start of a message on one line.
    public static func preview(_ text: String, limit: Int = 120) -> String {
        let flat = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }
}

// MARK: - Prompt header

/// The header and reply line a prompt from a conversation carries into
/// the session, so the agent knows where it came from and how to answer.
public enum ConversationPrompt {
    /// How much of a quoted message goes into the header.
    public static let quoteLimit = 160

    public static func wrap(_ text: String, conversation: RemoteConversation) -> String {
        wrap(text, id: conversation.id, title: conversation.title,
             quote: conversation.replied ? nil : conversation.quote)
    }

    public static func wrap(_ text: String, id: String, title: String?, quote: String? = nil) -> String {
        if parse(text) != nil { return text }
        var header = "[conversation \(id)"
        let named = title.map { !$0.isEmpty } ?? false
        if named, let title {
            header += " \"\(title.replacingOccurrences(of: "\"", with: "'"))\""
        } else {
            header += ", new"
        }
        if let quote, !quote.isEmpty {
            let excerpt = ConversationLog.preview(quote, limit: quoteLimit).replacingOccurrences(of: "\"", with: "'")
            header += ", continues your message \"\(excerpt)\""
        }
        header += "]"
        let reply = named
            ? "(reply with: kanban reply \(id) \"<answer>\")"
            : "(reply with: kanban reply \(id) --title \"<3-6 word title>\" \"<answer>\")"
        return "\(header) \(text)\n\(reply)"
    }

    /// The conversation a prompt in the transcript was sent from, and the
    /// text the human wrote, or nil for a prompt of Main.
    public static func parse(_ prompt: String) -> (id: String, title: String?, text: String)? {
        guard prompt.hasPrefix("[conversation ") else { return nil }
        let afterTag = prompt.dropFirst("[conversation ".count)
        guard let close = headerEnd(afterTag) else { return nil }
        let inside = afterTag[..<close]
        let id = String(inside.prefix { $0 != " " && $0 != "," })
        guard ConversationSlug.isValid(id) else { return nil }
        var title: String?
        let rest = inside.dropFirst(id.count)
        if rest.hasPrefix(" \""), let end = rest.dropFirst(2).firstIndex(of: "\"") {
            title = String(rest.dropFirst(2)[..<end])
        }
        var body = String(afterTag[afterTag.index(after: close)...])
        if body.hasPrefix(" ") { body.removeFirst() }
        if let range = body.range(of: "\n(reply with: kanban reply ", options: .backwards) {
            body = String(body[..<range.lowerBound])
        }
        return (id, title, body)
    }

    /// The `]` that closes the header: the first one outside quotes.
    private static func headerEnd(_ s: Substring) -> Substring.Index? {
        var quoted = false
        for index in s.indices {
            let c = s[index]
            if c == "\"" { quoted.toggle() }
            if c == "]" && !quoted { return index }
            if c == "\n" { return nil }
        }
        return nil
    }
}

// MARK: - Ids

public enum ConversationSlug {
    /// Two words joined by a dash, unique among `existing`.
    public static func generate(existing: Set<String>, random: () -> Int = { Int.random(in: 0..<Int.max) }) -> String {
        for _ in 0..<200 {
            let slug = "\(ConversationWords.adjectives[random() % ConversationWords.adjectives.count])-\(ConversationWords.animals[random() % ConversationWords.animals.count])"
            if !existing.contains(slug) { return slug }
        }
        var n = 2
        let base = "\(ConversationWords.adjectives[0])-\(ConversationWords.animals[0])"
        while existing.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    public static func isValid(_ slug: String) -> Bool {
        !slug.isEmpty && slug.count <= 64 && slug.contains("-")
            && slug.allSatisfy { ($0.isASCII && ($0.isLowercase || $0.isNumber)) || $0 == "-" }
    }
}
