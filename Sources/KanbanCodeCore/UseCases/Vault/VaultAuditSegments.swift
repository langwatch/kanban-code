import Foundation
import KanbanCodeRemoteKit

/// Where a log's current segment starts: the hash of the last archived
/// line, which its first line names as `prev`, and the archived segments,
/// oldest first. Kept next to the log as `<log>.head`.
public struct VaultAuditHead: Codable, Sendable, Equatable {
    public var lastHash: String
    /// Segment names in `audit-archive/`, without extension.
    public var archived: [String]
}

/// Open-tier hook releases of one card, session and secret held back
/// within a window.
struct AuditFold: Sendable {
    var windowStart: Date
    var count = 0
    var firstAt: Date?
    var last: VaultAuditEntry?
}

/// What is known of a peer's mirror without reading it again.
struct MirrorState: Sendable {
    var lastHash: String?
    var count: Int
    var size: UInt64
    /// The first 64 bits of the hash of each line of the current segment,
    /// read only when a pushed line does not follow the last one.
    var known: Set<UInt64>?
}

/// Segments of the audit logs: the current one is `audit.jsonl` (or
/// `audit-mirror/<machine>.jsonl`); past `auditSegmentLimit` it moves to
/// `audit-archive/<base>-<stamp>.jsonl`, is gzipped there in the
/// background, and its human decisions are copied to
/// `audit-archive/<base>.decisions.jsonl` for the approval and ask views.
/// The chain runs on across segments through the `.head` file.
extension VaultStore {
    var archiveDirectory: String { directory + "/audit-archive" }

    // MARK: - Folding

    static func isFoldable(_ entry: VaultAuditEntry) -> Bool {
        entry.action == "hook" && entry.outcome == .allowed && entry.decider == .tier && entry.tier == .open
            && entry.requestId == nil
    }

    static func foldKey(_ entry: VaultAuditEntry) -> String {
        [entry.cardId ?? "", entry.sessionId ?? "", entry.secret].joined(separator: "|")
    }

    func sweepFolds(now: Date) {
        guard !folds.isEmpty, now.timeIntervalSince(lastFoldSweep) >= min(30, auditFoldWindow) else { return }
        flushFolds(now: now)
    }

    /// Writes the counted line of every fold whose window ended (all of
    /// them with `all`).
    public func flushFolds(now: Date = Date(), all: Bool = false) {
        lastFoldSweep = now
        let due = folds.filter { all || now.timeIntervalSince($0.value.windowStart) >= auditFoldWindow }
        for (key, _) in due.sorted(by: { $0.value.windowStart < $1.value.windowStart }) {
            flushFold(key)
        }
    }

    func flushFold(_ key: String) {
        guard let fold = folds.removeValue(forKey: key), fold.count > 0, var last = fold.last else { return }
        let first = fold.firstAt ?? last.at
        last.repeats = fold.count
        last.firstAt = first
        last.detail = (last.detail.map { $0 + ", " } ?? "")
            + "\(fold.count) uses from \(VaultDates.format(first)) to \(VaultDates.format(last.at)), the last one shown"
        write(last)
    }

    func setAuditLimits(foldWindow: TimeInterval? = nil, segmentLimit: UInt64? = nil) {
        if let foldWindow { auditFoldWindow = foldWindow }
        if let segmentLimit { auditSegmentLimit = segmentLimit }
    }

    // MARK: - Heads and archives

    static func fileSize(_ path: String) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    func head(of path: String) -> VaultAuditHead? {
        FileManager.default.contents(atPath: path + ".head").flatMap { try? JSONDecoder().decode(VaultAuditHead.self, from: $0) }
    }

    /// The file of an archived segment: gzipped, or still plain while it is
    /// being compressed.
    func archivePath(_ name: String) -> String {
        let plain = archiveDirectory + "/" + name + ".jsonl"
        return FileManager.default.fileExists(atPath: plain) ? plain : plain + ".gz"
    }

    static func mirrorArchiveBase(_ machine: String) -> String {
        "mirror-" + String(mirrorFileName(machine).dropLast(6))
    }

    /// The archived segments of this machine's log (or of a mirror),
    /// oldest first, and the hash the current segment follows.
    public func archivedSegments(mirror machine: String? = nil) -> (paths: [String], head: String?) {
        let path = machine.map { mirrorPath($0) } ?? auditPath
        guard let head = head(of: path) else { return ([], nil) }
        let paths = head.archived.map(archivePath).filter { FileManager.default.fileExists(atPath: $0) }
        return (paths, head.lastHash.isEmpty ? nil : head.lastHash)
    }

    /// Moves the segment at `path` to the archive and starts a new one
    /// after `lastHash`. The head is written first: a crash between the
    /// two leaves a chain break, never a lost line.
    func archiveSegment(path: String, base: String, lastHash: String) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: archiveDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let name = base + "-" + formatter.string(from: Date())
        var head = head(of: path) ?? VaultAuditHead(lastHash: "", archived: [])
        head.lastHash = lastHash
        head.archived.append(name)
        guard let data = try? JSONEncoder().encode(head), (try? data.write(to: URL(fileURLWithPath: path + ".head"), options: .atomic)) != nil else { return }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path + ".head")
        let pending = archiveDirectory + "/" + name + ".jsonl"
        guard (try? fm.moveItem(atPath: path, toPath: pending)) != nil else { return }
        let decisions = archiveDirectory + "/" + base + ".decisions.jsonl"
        DispatchQueue.global(qos: .background).async { Self.compress(pending: pending, decisions: decisions) }
    }

    /// Segments a previous run moved to the archive but did not compress.
    func resumeArchives() {
        guard !archivesResumed else { return }
        archivesResumed = true
        let names = (try? FileManager.default.contentsOfDirectory(atPath: archiveDirectory)) ?? []
        for name in names where name.hasSuffix(".jsonl") && !name.hasSuffix(".decisions.jsonl") {
            guard let dash = name.dropLast(6).range(of: "-20", options: .backwards) else { continue }
            let base = String(name[..<dash.lowerBound])
            let pending = archiveDirectory + "/" + name
            let decisions = archiveDirectory + "/" + base + ".decisions.jsonl"
            DispatchQueue.global(qos: .background).async { Self.compress(pending: pending, decisions: decisions) }
        }
    }

    static func isDecision(_ line: Data) -> Bool {
        decisionMarkers.contains { line.range(of: $0) != nil }
    }

    static let decisionMarkers = ["\"decider\":\"human\"", "\"outcome\":\"asked\"", "\"decider\":\"timeout\""].map { Data($0.utf8) }

    /// Copies the human decisions of an archived segment aside, then
    /// gzips it (`gzip` replaces the file only once the copy is whole).
    static func compress(pending: String, decisions: String) {
        var picked = Data()
        forEachLine(inFileAt: pending) { line in
            if isDecision(line) { picked.append(line); picked.append(0x0A) }
            return true
        }
        if !picked.isEmpty { AuditChain.appendRaw(picked, to: decisions) }
        let gzip = Process()
        gzip.executableURL = URL(fileURLWithPath: gzipPath)
        gzip.arguments = ["-f", pending]
        do {
            try gzip.run()
            gzip.waitUntilExit()
        } catch {
            KanbanCodeLog.info("vault", "could not gzip \(pending): \(error.localizedDescription)")
        }
    }

    static var gzipPath: String {
        ["/usr/bin/gzip", "/bin/gzip"].first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/gzip"
    }

    /// Calls `body` with each non-empty line of a JSON-lines file, plain or
    /// gzipped, oldest first, in blocks; stops when `body` returns false.
    public static func forEachLine(inFileAt path: String, blockSize: Int = 1 << 20, _ body: (Data) -> Bool) {
        let handle: FileHandle
        var gunzip: Process?
        if path.hasSuffix(".gz") {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: gzipPath)
            process.arguments = ["-dc", path]
            process.standardOutput = pipe
            guard (try? process.run()) != nil else { return }
            gunzip = process
            handle = pipe.fileHandleForReading
        } else {
            guard let file = FileHandle(forReadingAtPath: path) else { return }
            handle = file
        }
        defer {
            try? handle.close()
            if let gunzip {
                if gunzip.isRunning { gunzip.terminate() }
                gunzip.waitUntilExit()
            }
        }
        var current = Data()
        while let block = try? handle.read(upToCount: blockSize), !block.isEmpty {
            var from = block.startIndex
            while let newline = block[from...].firstIndex(of: 0x0A) {
                current.append(block[from..<newline])
                if !current.isEmpty, !body(current) { return }
                current = Data()
                from = block.index(after: newline)
            }
            current.append(block[from...])
        }
        if !current.isEmpty { _ = body(current) }
    }

    /// The lines of an archived segment after the one hashed `hash`, or nil
    /// when it has no such line.
    static func archivedLines(after hash: String, in path: String) -> [Data]? {
        if !path.hasSuffix(".gz") { return lines(after: hash, inFileAt: path) }
        var after: [Data]?
        forEachLine(inFileAt: path) { line in
            if after != nil { after?.append(line) } else if AuditChain.hash(line) == hash { after = [] }
            return true
        }
        return after
    }

    // MARK: - Mirrors

    static func lineKey(_ hash: String) -> UInt64 {
        UInt64(hash.prefix(16), radix: 16) ?? 0
    }

    static func lineKeys(ofFileAt path: String) -> Set<UInt64> {
        var keys = Set<UInt64>()
        forEachLine(inFileAt: path) { keys.insert(lineKey(AuditChain.hash($0))); return true }
        return keys
    }

    /// The mirror's tail, read again only when its file changed size behind
    /// this store's back.
    func mirrorState(_ machine: String) -> MirrorState {
        let path = mirrorPath(machine)
        let size = Self.fileSize(path)
        if let state = mirrorStates[machine], state.size == size { return state }
        let tail = Self.tail(ofFileAt: path)
        let headHash = head(of: path)?.lastHash
        let state = MirrorState(lastHash: tail.last.map(AuditChain.hash) ?? (headHash?.isEmpty == false ? headHash : nil),
                                count: tail.count, size: size, known: nil)
        mirrorStates[machine] = state
        return state
    }

    /// Lines with a human decision, an ask or a timeout: the current
    /// segments of this machine and the mirrors, and what archived segments
    /// held of them.
    func decisionLines() -> [Data] {
        var lines = auditLines() + mirroredMachines().flatMap { mirrorLines(machine: $0) }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: archiveDirectory)) ?? [])
            .filter { $0.hasSuffix(".decisions.jsonl") }.sorted()
        var seen = Set<String>()
        for name in names {
            let data = FileManager.default.contents(atPath: archiveDirectory + "/" + name) ?? Data()
            for line in AuditChain.lines(of: data) where seen.insert(AuditChain.hash(line)).inserted {
                lines.append(line)
            }
        }
        return lines
    }
}
