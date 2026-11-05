import Foundation
import KanbanCodeRemoteKit

/// The conversation logs of the cards (docs/conversations.md): one
/// append-only JSONL per card, `conversations/<cardId>.jsonl` for the cards
/// this master owns and `peers/<machine>/conversations/<cardId>.jsonl` for
/// the copies of cards other masters own. The CLI appends to the same files.
public final class ConversationStore: @unchecked Sendable {
    public let kanbanHome: String
    private let lock = NSLock()

    public init(kanbanHome: String? = nil) {
        self.kanbanHome = kanbanHome ?? (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code")
    }

    public var directory: String { (kanbanHome as NSString).appendingPathComponent("conversations") }
    public var peersDirectory: String { (kanbanHome as NSString).appendingPathComponent("peers") }

    static func safe(_ cardId: String) -> String {
        String(cardId.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" })
    }

    /// The log of a card this master owns.
    public func path(cardId: String) -> String {
        (directory as NSString).appendingPathComponent(Self.safe(cardId) + ".jsonl")
    }

    /// The copy of the log of a card `machineId` owns.
    public func mirrorPath(cardId: String, machineId: String) -> String {
        "\(peersDirectory)/\(Self.safe(machineId))/conversations/\(Self.safe(cardId)).jsonl"
    }

    /// The copies of the card's log kept from other masters, newest first.
    func mirrors(cardId: String) -> [String] {
        let fm = FileManager.default
        let name = Self.safe(cardId) + ".jsonl"
        let machines = (try? fm.contentsOfDirectory(atPath: peersDirectory)) ?? []
        return machines
            .map { "\(peersDirectory)/\($0)/conversations/\(name)" }
            .filter { fm.fileExists(atPath: $0) }
            .sorted { modified($0) > modified($1) }
    }

    private func modified(_ path: String) -> Date {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date) ?? .distantPast
    }

    /// Where the card's log is read from: its own when the card is this
    /// master's, else the copy of the owner's. A card this master adopted
    /// reads the copy it kept until it writes its own.
    public func readPath(cardId: String, ownerMachine: String?) -> String? {
        let fm = FileManager.default
        if let ownerMachine {
            let mirror = mirrorPath(cardId: cardId, machineId: ownerMachine)
            return fm.fileExists(atPath: mirror) ? mirror : nil
        }
        let own = path(cardId: cardId)
        if fm.fileExists(atPath: own) { return own }
        return mirrors(cardId: cardId).first
    }

    public func threads(cardId: String, ownerMachine: String? = nil) -> [ConversationThread] {
        guard let path = readPath(cardId: cardId, ownerMachine: ownerMachine) else { return [] }
        return threads(atPath: path)
    }

    /// What each log folded into when it was last read, and from how many
    /// of its bytes.
    private struct Folded {
        var size: Int
        var modified: Date
        var fileNumber: Int?
        var folder: ConversationLog.Folder
        var threads: [ConversationThread]
    }

    private var folded: [String: Folded] = [:]
    private let foldLock = NSLock()

    /// The log at `path`, folded. An unchanged log is not read again, and a
    /// log that grew is read only from where the last fold stopped; one that
    /// shrank or was replaced is folded from the start. The fold runs
    /// outside the lock, so a reader on the main thread never waits on a
    /// long fold another thread is doing.
    public func threads(atPath path: String) -> [ConversationThread] {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            foldLock.lock()
            folded[path] = nil
            foldLock.unlock()
            return []
        }
        let size = (attrs[.size] as? Int) ?? 0
        let modified = (attrs[.modificationDate] as? Date) ?? .distantPast
        let fileNumber = (attrs[.systemFileNumber] as? NSNumber)?.intValue
        foldLock.lock()
        let cached = folded[path]
        foldLock.unlock()
        if let cached, cached.size == size, cached.modified == modified, cached.fileNumber == fileNumber {
            return cached.threads
        }
        var folder = ConversationLog.Folder()
        if let cached, cached.fileNumber == fileNumber, size >= cached.folder.consumed {
            folder = cached.folder
        }
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(folder.consumed))
        let data = (try? handle.readToEnd()) ?? Data()
        folder.feed(data)
        let threads = folder.threads
        foldLock.lock()
        folded[path] = Folded(size: size, modified: modified, fileNumber: fileNumber, folder: folder, threads: threads)
        foldLock.unlock()
        return threads
    }

    /// Appends events to the log of a card this master owns, as one write.
    public func append(cardId: String, _ events: [ConversationEvent]) throws {
        guard !events.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        let path = path(cardId: cardId)
        try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: path), let kept = mirrors(cardId: cardId).first {
            // The card came from another master: its log continues here.
            try? fm.copyItem(atPath: kept, toPath: path)
        }
        var data = Data()
        for event in events { data.append(event.line()) }
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == data.count else { throw CocoaError(.fileWriteUnknown) }
    }

    public func append(cardId: String, _ event: ConversationEvent) throws {
        try append(cardId: cardId, [event])
    }

    /// Bytes of the card's own log from `offset`, and its size.
    public func raw(cardId: String, offset: Int) -> RemoteRawTranscript {
        guard let path = readPath(cardId: cardId, ownerMachine: nil),
              let handle = FileHandle(forReadingAtPath: path) else {
            return RemoteRawTranscript(data: Data(), offset: offset, size: 0)
        }
        defer { try? handle.close() }
        let size = Int((try? handle.seekToEnd()) ?? 0)
        guard offset < size else { return RemoteRawTranscript(data: Data(), offset: offset, size: size) }
        try? handle.seek(toOffset: UInt64(offset))
        let data = (try? handle.read(upToCount: min(size - offset, 8 << 20))) ?? Data()
        return RemoteRawTranscript(data: data, offset: offset, size: size)
    }

    /// Size and modification time of each log there is, own and copied, by
    /// path, with the card each belongs to and the machine of a copy.
    public func scan() -> [ConversationLogFile] {
        let fm = FileManager.default
        var files: [ConversationLogFile] = []
        func add(_ dir: String, machine: String?) {
            for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where name.hasSuffix(".jsonl") {
                let path = (dir as NSString).appendingPathComponent(name)
                guard let attrs = try? fm.attributesOfItem(atPath: path) else { continue }
                files.append(ConversationLogFile(
                    path: path, cardId: String(name.dropLast(".jsonl".count)), machineId: machine,
                    size: (attrs[.size] as? Int) ?? 0,
                    modified: (attrs[.modificationDate] as? Date) ?? .distantPast))
            }
        }
        add(directory, machine: nil)
        for machine in (try? fm.contentsOfDirectory(atPath: peersDirectory)) ?? [] {
            add("\(peersDirectory)/\(machine)/conversations", machine: machine)
        }
        return files
    }
}

public struct ConversationLogFile: Sendable, Equatable {
    public var path: String
    public var cardId: String
    /// The master a copy came from; nil for this master's own log.
    public var machineId: String?
    public var size: Int
    public var modified: Date
}
