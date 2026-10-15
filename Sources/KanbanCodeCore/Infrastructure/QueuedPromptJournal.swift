import Foundation

/// Why a queued prompt was written to the journal.
public enum QueuedPromptJournalReason: String, Codable, Sendable {
    case queued
    case edited
    case sent
    case removed
    /// The send did not reach the session.
    case failed
}

public struct QueuedPromptJournalEntry: Codable, Sendable {
    public let timestamp: Date
    public let cardId: String
    public let promptId: String
    public let reason: QueuedPromptJournalReason
    public let body: String
    public let imagePaths: [String]?
    public let sendAutomatically: Bool

    public init(
        timestamp: Date = .now,
        cardId: String,
        promptId: String,
        reason: QueuedPromptJournalReason,
        body: String,
        imagePaths: [String]?,
        sendAutomatically: Bool
    ) {
        self.timestamp = timestamp
        self.cardId = cardId
        self.promptId = promptId
        self.reason = reason
        self.body = body
        self.imagePaths = imagePaths
        self.sendAutomatically = sendAutomatically
    }
}

/// An append-only record of everything that passed through a card's prompt
/// queue, at `~/.kanban-code/queued-prompts.jsonl`.
///
/// Sending a queued prompt deletes it from the card and persists that deletion
/// alongside the send, so a send that fails or only partly lands takes the text
/// with it. Nothing else on disk ever held a body: the card's own file no
/// longer has it, the hook log records only ids and timestamps, and the app log
/// keeps the first forty characters. This is the copy to go back to.
public actor QueuedPromptJournal {
    private let filePath: String
    private let sizeLimit: Int
    private let encoder: JSONEncoder

    public init(basePath: String? = nil, sizeLimit: Int = 32 * 1024 * 1024) {
        let base = basePath ?? (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code")
        self.filePath = (base as NSString).appendingPathComponent("queued-prompts.jsonl")
        self.sizeLimit = sizeLimit

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
    }

    public func append(_ entry: QueuedPromptJournalEntry) {
        guard var data = try? self.encoder.encode(entry) else { return }
        data.append(0x0A)

        let url = URL(fileURLWithPath: self.filePath)
        let directory = (self.filePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true)

        guard let handle = try? FileHandle(forWritingTo: url) else {
            try? data.write(to: url)
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)

        self.trimIfNeeded()
    }

    /// Everything recorded for a card, oldest first.
    public func entries(forCard cardId: String) -> [QueuedPromptJournalEntry] {
        self.allEntries().filter { $0.cardId == cardId }
    }

    public func allEntries() -> [QueuedPromptJournalEntry] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: self.filePath)) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).compactMap {
            try? decoder.decode(QueuedPromptJournalEntry.self, from: Data($0))
        }
    }

    /// Drops the oldest half once the file passes its limit. A prompt is worth
    /// keeping, but not at the cost of a file that grows without end.
    private func trimIfNeeded() {
        let attributes = try? FileManager.default.attributesOfItem(atPath: self.filePath)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard size > self.sizeLimit else { return }

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: self.filePath)) else { return }
        let lines = data.split(separator: 0x0A)
        guard lines.count > 1 else { return }
        let kept = lines.suffix(lines.count / 2)
        var out = Data()
        for line in kept {
            out.append(contentsOf: line)
            out.append(0x0A)
        }
        try? out.write(to: URL(fileURLWithPath: self.filePath), options: .atomic)
    }
}
