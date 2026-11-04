import Foundation

/// A message the human typed and sent himself from a Kanban chat composer
/// (Mac or iOS), recorded when he wrote it.
public struct HumanMessageRecord: Codable, Sendable, Equatable {
    /// When he wrote it: for a queued prompt, when it joined the queue.
    public var at: Date
    public var text: String
    /// The session it was written for.
    public var sessionId: String?

    public init(at: Date = .now, text: String, sessionId: String? = nil) {
        self.at = at
        self.text = text
        self.sessionId = sessionId
    }
}

/// Kanban's own record of the human's messages, one file per card at
/// `~/.kanban-code/human-messages/<cardId>.jsonl`, newest last.
///
/// The chat is the only place that knows a message was typed by the human:
/// in the transcript it reads the same as one an agent delivered.
public final class HumanMessageLog: @unchecked Sendable {
    private let directory: String
    private let lock = NSLock()
    /// A card's file is cut back to the newest `keep` once it holds twice that.
    static let keep = 200

    public init(kanbanHome: String? = nil) {
        let home = kanbanHome ?? (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code")
        self.directory = (home as NSString).appendingPathComponent("human-messages")
    }

    private func path(_ cardId: String) -> String {
        let safe = String(cardId.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" })
        return (directory as NSString).appendingPathComponent(safe + ".jsonl")
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public func append(cardId: String, _ record: HumanMessageRecord) {
        guard !record.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = try? Self.encoder.encode(record) else { return }
        lock.lock()
        defer { lock.unlock() }
        let file = path(cardId)
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        var records = readLocked(file)
        if records.last == record { return }
        if records.count >= Self.keep * 2 {
            records = Array(records.suffix(Self.keep - 1)) + [record]
            let lines = records.compactMap { try? Self.encoder.encode($0) }.compactMap { String(data: $0, encoding: .utf8) }
            try? (lines.joined(separator: "\n") + "\n").write(toFile: file, atomically: true, encoding: .utf8)
            return
        }
        guard let handle = FileHandle(forWritingAtPath: file) else {
            try? (data + Data([0x0A])).write(to: URL(fileURLWithPath: file))
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data + Data([0x0A]))
    }

    /// The card's record, oldest first.
    public func read(cardId: String) -> [HumanMessageRecord] {
        lock.lock()
        defer { lock.unlock() }
        return readLocked(path(cardId))
    }

    private func readLocked(_ file: String) -> [HumanMessageRecord] {
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            try? Self.decoder.decode(HumanMessageRecord.self, from: Data($0.utf8))
        }
    }
}

/// A human message as `rush session human <id> --json` prints it.
public struct RushHumanMessage: Decodable, Sendable, Equatable {
    public var at: String?
    public var text: String
    /// The transcript record's uuid, when rush knows it.
    public var uuid: String?

    public init(at: String? = nil, text: String, uuid: String? = nil) {
        self.at = at
        self.text = text
        self.uuid = uuid
    }
}

/// The last message the human typed and sent himself, and where the
/// session's catch-up starts.
public struct LastHumanMessage: Sendable, Equatable {
    public var text: String
    /// When he wrote it.
    public var at: Date?
    /// Byte offset of its record in the transcript; nil while it still
    /// waits in a queue.
    public var offset: Int?
    /// Byte offset of the first record he has not seen: his message, or,
    /// for a prompt that waited in a queue, the first record written after
    /// he queued it.
    public var scopeStart: Int

    public init(text: String, at: Date?, offset: Int?, scopeStart: Int) {
        self.text = text
        self.at = at
        self.offset = offset
        self.scopeStart = scopeStart
    }
}

/// Finds the human's last message in a Claude Code transcript.
///
/// The records of the harnesses decide: rush's own record for a rush
/// session whose rush keeps one, together with Kanban's record, which also
/// tells when a queued prompt was written. A user record with a delivery marker (`kanban send`, a DM,
/// a channel, a remote agent, a self-compact follow-up), a task
/// notification or a harness wrapper is never his. Where no record covers
/// the session, the user records left after that are taken as typed.
public enum HumanMessageFinder {
    /// How far a record's time and the transcript's may differ and still
    /// be the same message.
    static let clockSlack: TimeInterval = 5
    /// How far back from the end of the transcript his last message is
    /// looked for. A session can run for weeks without one, and walking a
    /// gigabyte of it took two minutes: a message further back than this is
    /// too old to catch up from anyway.
    public static let scanBytes = 32 << 20

    /// - Parameters:
    ///   - record: Kanban's record for the card, oldest first.
    ///   - rushRecord: rush's record of the session, or nil when the
    ///     session is not on rush or its rush keeps none.
    ///   - queuedTexts: prompts waiting in the card's queue now.
    public static func find(
        transcriptPath: String,
        sessionId: String? = nil,
        record: [HumanMessageRecord] = [],
        rushRecord: [RushHumanMessage]? = nil,
        queuedTexts: [String] = [],
        now: Date = .now,
        scanBytes: Int = scanBytes
    ) -> LastHumanMessage? {
        let size = ((try? FileManager.default.attributesOfItem(atPath: transcriptPath))?[.size] as? Int) ?? 0
        let record = record.filter { $0.sessionId == nil || sessionId == nil || $0.sessionId == sessionId }
        let rush = (rushRecord ?? []).isEmpty ? nil : rushRecord

        var found: (offset: Int, text: String, at: Date?)?
        try? TranscriptReader.scanRecordsBackwards(filePath: transcriptPath) { offset, line in
            if size - offset > scanBytes { return true }
            guard line.contains("\"user\""), !line.contains("\"toolUseResult\""),
                  let obj = jsonObject(line),
                  case .typed(let text)? = CardPromptReader.entry(record: obj) else { return false }
            // A session with a rush record: the message is in it, or in
            // Kanban's own (what its chat sent through a rush that marks nothing).
            if let rush, !rush.contains(where: { matches($0, uuid: obj["uuid"] as? String, text: text) }),
               !record.contains(where: { sameText($0.text, text) }) {
                return false
            }
            found = (offset, text, timestamp(of: obj))
            return true
        }

        // A prompt he wrote that has not reached the session yet.
        if let newest = record.last,
           found.map({ !sameText($0.text, newest.text) && newest.at > ($0.at ?? .distantPast) }) ?? true,
           queuedTexts.contains(where: { sameText($0, newest.text) }) || now.timeIntervalSince(newest.at) < 60 {
            let start = firstOffset(writtenSince: newest.at, in: transcriptPath, before: size) ?? size
            return LastHumanMessage(text: newest.text, at: newest.at, offset: nil, scopeStart: start)
        }

        guard let found else { return nil }
        var message = LastHumanMessage(text: found.text, at: found.at, offset: found.offset, scopeStart: found.offset)
        // Written earlier than it was delivered: what happened while it
        // waited in the queue is news to him too.
        let delivered = found.at ?? now
        if let written = record.last(where: { sameText($0.text, found.text) && $0.at <= delivered.addingTimeInterval(clockSlack) }),
           written.at < delivered.addingTimeInterval(-clockSlack) {
            message.at = written.at
            if let earlier = firstOffset(writtenSince: written.at, in: transcriptPath, before: found.offset) {
                message.scopeStart = min(earlier, found.offset)
            }
        }
        return message
    }

    /// Offset of the oldest record before `end` written at or after `date`.
    static func firstOffset(writtenSince date: Date, in path: String, before end: Int) -> Int? {
        var first: Int?
        try? TranscriptReader.scanRecordsBackwards(filePath: path, from: end) { offset, line in
            guard let at = timestamp(inLine: line) else { return false }
            if at < date { return true }
            first = offset
            return false
        }
        return first
    }

    static func matches(_ message: RushHumanMessage, uuid: String?, text: String) -> Bool {
        if let id = message.uuid, !id.isEmpty, let uuid, id == uuid { return true }
        return sameText(message.text, text)
    }

    /// Whether two prompts are the same message. The session may re-space
    /// a prompt and put image markers around it, so whitespace compares as
    /// one space and one text may be the start of the other.
    public static func sameText(_ a: String, _ b: String) -> Bool {
        let a = normalized(a), b = normalized(b)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        let (short, long) = a.count < b.count ? (a, b) : (b, a)
        return short.count >= 24 && long.hasPrefix(short)
    }

    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func timestamp(of obj: [String: Any]) -> Date? {
        (obj["timestamp"] as? String).flatMap(parseDate)
    }

    /// The record's `timestamp` without parsing the whole line.
    static func timestamp(inLine line: String) -> Date? {
        guard let key = line.range(of: "\"timestamp\":\"") else { return nil }
        let rest = line[key.upperBound...]
        guard let close = rest.firstIndex(of: "\"") else { return nil }
        return parseDate(String(rest[..<close]))
    }

    public static func parseDate(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}
