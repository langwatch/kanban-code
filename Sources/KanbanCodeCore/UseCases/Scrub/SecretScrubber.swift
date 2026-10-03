import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import KanbanCodeRemoteKit

/// When the scrubber runs on its own: once a day at `hour:minute`, local time.
public struct ScrubSchedule: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var hour: Int
    public var minute: Int

    public init(enabled: Bool = true, hour: Int = 4, minute: Int = 30) {
        self.enabled = enabled
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
    }
}

public struct ScrubFileReport: Codable, Sendable, Equatable {
    public var path: String
    /// Replacements of values the vault already held.
    public var known: Int
    /// Replacements of values saved to the vault by this run.
    public var new: Int
    /// Written to in the last minutes: left for the next run.
    public var live: Bool?
    public var error: String?
}

/// What a run did. Names, paths and counts only, never a value.
public struct ScrubReport: Codable, Sendable, Equatable {
    public var machine: String
    public var startedAt: Date
    public var finishedAt: Date
    public var dryRun: Bool
    public var filesSeen = 0
    public var filesScanned = 0
    /// Not read: the same size and time as when the last run left them clean.
    public var filesUnchanged = 0
    public var filesLive = 0
    public var bytesScanned = 0
    /// Files with at least one secret (changed, or that would change).
    public var filesWithSecrets = 0
    public var replacements = 0
    /// Distinct values the vault did not hold (saved by a real run).
    public var newSecrets = 0
    /// Finds left in place: in a live file, cut by an escape, or in a line
    /// that would no longer parse.
    public var skipped = 0
    public var bySecret: [String: Int] = [:]
    public var byFolder: [String: Int] = [:]
    /// The files with the most finds, at most 200.
    public var files: [ScrubFileReport] = []
    public var errors: [String] = []
    public var backupPath: String?
    public var backupFiles: Int?
    public var note: String?
}

public struct ScrubStatus: Codable, Sendable, Equatable {
    public var machine: String
    public var schedule: ScrubSchedule
    public var running: Bool
    public var progress: String?
    public var nextRun: Date?
    public var lastRun: ScrubReport?
    public var lastDryRun: ScrubReport?
}

/// Replaces secrets in this machine's transcripts and stores with
/// `{{vault:NAME}}` references (docs/vault.md, "Scrubber"). It runs on every
/// master over that master's own files, daily and on demand.
public actor SecretScrubber {
    public let vault: VaultService
    public let home: String
    public let kanbanHome: String
    public let machine: String
    let index: ScrubIndexStore
    private let peers: @Sendable () async -> [PeerConfig]
    private var running = false
    private var progress: String?
    private var lastScheduledDay: String?

    /// A file written this recently belongs to a session in progress.
    public var liveWindow: TimeInterval = 600
    public static let backupDays = 7

    public init(vault: VaultService, home: String = NSHomeDirectory(), kanbanHome: String? = nil, machine: String,
                peers: @escaping @Sendable () async -> [PeerConfig] = { [] }) {
        self.vault = vault
        self.home = home
        self.kanbanHome = kanbanHome ?? vault.kanbanHome
        self.machine = machine
        self.peers = peers
        index = ScrubIndexStore(store: vault.store)
    }

    var directory: String { kanbanHome + "/scrub" }
    var backupsDirectory: String { kanbanHome + "/scrub-backups" }
    private var schedulePath: String { directory + "/schedule.json" }
    private var statePath: String { directory + "/state.json" }

    // MARK: - Schedule

    public func schedule() -> ScrubSchedule {
        FileManager.default.contents(atPath: schedulePath).flatMap { try? JSONDecoder().decode(ScrubSchedule.self, from: $0) }
            ?? ScrubSchedule()
    }

    /// Saves the schedule; `share` also sends it to the peer masters, so
    /// one setting covers every machine.
    public func setSchedule(_ schedule: ScrubSchedule, share: Bool) async {
        let clean = ScrubSchedule(enabled: schedule.enabled, hour: schedule.hour, minute: schedule.minute)
        if let data = try? JSONEncoder().encode(clean) {
            try? VaultFiles.writeAtomically(data, to: schedulePath, mode: 0o600)
        }
        guard share, let body = try? JSONEncoder().encode(clean) else { return }
        for peer in await peers() where peer.enabled {
            _ = try? await Self.call(peer, "PUT", "/v1/scrub/schedule", body: body)
        }
    }

    public func status() -> ScrubStatus {
        let s = schedule()
        return ScrubStatus(machine: machine, schedule: s, running: running, progress: progress,
                           nextRun: s.enabled ? Self.nextRun(s, after: Date()) : nil,
                           lastRun: report(named: "last-run"), lastDryRun: report(named: "last-dry-run"))
    }

    /// The status of each enabled peer master, by peer name.
    public func peerStatuses() async -> [String: ScrubStatus] {
        var out: [String: ScrubStatus] = [:]
        for peer in await peers() where peer.enabled {
            if let data = try? await Self.call(peer, "GET", "/v1/scrub/status"),
               let status = try? JSONDecoder.remote.decode(ScrubStatus.self, from: data) {
                out[peer.name] = status
            }
        }
        return out
    }

    /// Brings in the fingerprints the peer masters hold: a value set on
    /// one master is sealed before the others ever see it in plain.
    func mergePeerIndexes() async {
        for peer in await peers() where peer.enabled {
            if let data = try? await Self.call(peer, "GET", "/v1/scrub/index"),
               let theirs = try? JSONDecoder.vault.decode(ScrubIndexStore.Index.self, from: data) {
                await index.merge(theirs)
            }
        }
    }

    public func exportIndex() async -> Data? {
        try? JSONEncoder.vault.encode(await index.export())
    }

    /// Starts a run on every enabled peer master.
    public func runOnPeers(dryRun: Bool) async {
        let body = Data("{\"dryRun\":\(dryRun)}".utf8)
        for peer in await peers() where peer.enabled {
            _ = try? await Self.call(peer, "POST", "/v1/scrub/run", body: body)
        }
    }

    private static func call(_ peer: PeerConfig, _ method: String, _ path: String, body: Data? = nil) async throws -> Data {
        guard let url = URL(string: peer.url.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = method
        request.setValue("Bearer \(peer.token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    static func nextRun(_ schedule: ScrubSchedule, after now: Date, calendar: Calendar = .current) -> Date? {
        var parts = DateComponents()
        parts.hour = schedule.hour
        parts.minute = schedule.minute
        return calendar.nextDate(after: now, matching: parts, matchingPolicy: .nextTime)
    }

    private static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// The daily loop: runs once the day's time has passed, and deletes
    /// backups past their week.
    public func runSchedule() async {
        await index.startObserving()
        _ = await index.current()
        // A machine that has never run waits for the time itself: its first
        // run is not started by a restart that happens to come after it.
        lastScheduledDay = (report(named: "last-run")?.startedAt).map(Self.day) ?? Self.day(Date())
        while !Task.isCancelled {
            purgeBackups()
            let s = schedule()
            let now = Date()
            let parts = Calendar.current.dateComponents([.hour, .minute], from: now)
            let due = (parts.hour ?? 0, parts.minute ?? 0) >= (s.hour, s.minute)
            if s.enabled, due, lastScheduledDay != Self.day(now) {
                lastScheduledDay = Self.day(now)
                _ = await run(dryRun: false)
            }
            try? await Task.sleep(for: .seconds(60))
        }
    }

    // MARK: - Run

    /// Starts a run in the background; false when one is in progress.
    @discardableResult
    public func start(dryRun: Bool) -> Bool {
        guard !running else { return false }
        running = true
        progress = "starting"
        Task.detached(priority: .utility) { _ = await self.run(dryRun: dryRun, claimed: true) }
        return true
    }

    private struct State: Codable {
        var generation = ""
        var firstRealRunAt: Date?
        /// Path to "size:mtime" of files the last run left clean.
        var files: [String: String] = [:]
    }

    private func loadState() -> State {
        FileManager.default.contents(atPath: statePath).flatMap { try? JSONDecoder.remote.decode(State.self, from: $0) } ?? State()
    }

    private func report(named name: String) -> ScrubReport? {
        FileManager.default.contents(atPath: "\(directory)/\(name).json")
            .flatMap { try? JSONDecoder.remote.decode(ScrubReport.self, from: $0) }
    }

    private func setProgress(_ text: String?) {
        progress = text
    }

    @discardableResult
    public func run(dryRun: Bool, targets: ScrubTargets? = nil, now: Date = Date(), claimed: Bool = false) async -> ScrubReport {
        var report = ScrubReport(machine: machine, startedAt: now, finishedAt: now, dryRun: dryRun)
        guard claimed || !running else {
            report.note = "a run is in progress"
            return report
        }
        running = true
        progress = "reading the vault index"
        defer {
            running = false
            progress = nil
        }
        await index.startObserving()
        await mergePeerIndexes()
        guard let (entries, key) = await index.current() else {
            report.note = "this machine has no vault key: nothing was scanned"
            return finish(report)
        }
        let scanner = ScrubScanner(entries: entries, key: key)
        var state = loadState()
        let known = state.generation == scanner.generation ? state.files : [:]
        let files = (targets ?? ScrubTargets.standard(home: home, kanbanHome: kanbanHome)).files()
        report.filesSeen = files.count

        // Scan.
        let window = liveWindow
        var plans: [ScrubFilePlan] = []
        var clean: [String: String] = [:]
        var pending: [ScrubTargets.File] = []
        for file in files {
            if known[file.path] == file.stamp {
                report.filesUnchanged += 1
                clean[file.path] = file.stamp
            } else {
                pending.append(file)
            }
        }
        let width = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
        var next = 0
        await withTaskGroup(of: ScrubFilePlan.self) { group in
            func add() {
                guard next < pending.count else { return }
                let file = pending[next]
                next += 1
                group.addTask(priority: .utility) { ScrubFilePlan.scan(file, scanner: scanner, now: now, liveWindow: window) }
            }
            for _ in 0..<width { add() }
            var done = 0
            for await plan in group {
                done += 1
                if done % 200 == 0 { setProgress("scanned \(done) of \(pending.count) files") }
                report.filesScanned += 1
                report.bytesScanned += plan.file.size
                if plan.live { report.filesLive += 1 }
                if let error = plan.error { report.errors.append("\(plan.file.path): \(error)") }
                if plan.matches.isEmpty {
                    if !plan.live, plan.error == nil { clean[plan.file.path] = plan.file.stamp }
                } else {
                    plans.append(plan)
                }
                add()
            }
        }
        plans.sort { $0.file.path < $1.file.path }

        // New finds go to the vault before any file changes.
        var fresh: [String: String] = [:]
        for plan in plans where dryRun || !plan.live {
            for m in plan.matches { if let value = m.newValue { fresh[m.name] = value } }
        }
        report.newSecrets = fresh.count
        var unsaved = Set<String>()
        if !dryRun, !fresh.isEmpty {
            progress = "saving \(fresh.count) new secrets to the vault"
            for (name, value) in fresh.sorted(by: { $0.key < $1.key }) {
                let secret = VaultSecret(
                    name: name, value: value, tier: .ask,
                    rules: "Found in a local transcript by the scrubber. Rename it or delete it once you know what it is.",
                    tags: ["scrubbed"], sources: ["scrubber:\(machine)"])
                do {
                    try await vault.store.upsert(secret)
                    await index.record(name: name, value: value)
                } catch {
                    unsaved.insert(name)
                    report.errors.append("could not save \(name): \(error)")
                }
            }
            await vault.replica?.poke()
        }

        // Apply.
        let firstRun = state.firstRealRunAt == nil
        var backup: ScrubBackup?
        if !dryRun, firstRun, plans.contains(where: { !$0.live }) {
            backup = ScrubBackup(root: backupsDirectory, day: Self.day(now))
            report.backupPath = backup?.directory
        }
        var done = 0
        for plan in plans {
            done += 1
            if done % 50 == 0 { progress = "\(dryRun ? "counted" : "cleaned") \(done) of \(plans.count) files" }
            var entry = ScrubFileReport(path: plan.file.path, known: 0, new: 0, live: plan.live ? true : nil)
            var applied = plan.matches
            if !dryRun {
                if plan.live {
                    applied = []
                } else {
                    let wanted = plan.matches.filter { !unsaved.contains($0.name) }
                    if let backup, let failure = backup.add(plan.file.path) {
                        entry.error = "not changed, the backup failed: \(failure)"
                        applied = []
                    } else {
                        let result = plan.apply(wanted, scanner: scanner)
                        applied = result.applied
                        entry.error = result.error
                    }
                    if applied.count == plan.matches.count {
                        // The file keeps its size and time, so it reads as clean next time.
                        clean[plan.file.path] = plan.file.stamp
                    }
                }
            }
            entry.known = applied.filter { $0.newValue == nil }.count
            entry.new = applied.count - entry.known
            report.skipped += plan.matches.count - applied.count
            if let error = entry.error { report.errors.append("\(plan.file.path): \(error)") }
            guard !applied.isEmpty || plan.live || entry.error != nil else { continue }
            if !applied.isEmpty { report.filesWithSecrets += 1 }
            report.replacements += applied.count
            for m in applied { report.bySecret[m.name, default: 0] += 1 }
            let folder = ScrubTargets.folder(of: plan.file.path, home: home)
            report.byFolder[folder, default: 0] += applied.count
            report.files.append(entry)
        }
        report.backupFiles = backup?.count
        backup?.writeManifest()
        report.files.sort { ($0.known + $0.new, $1.path) > ($1.known + $1.new, $0.path) }
        report.files = Array(report.files.prefix(200))
        if report.errors.count > 50 { report.errors = Array(report.errors.prefix(50)) + ["and \(report.errors.count - 50) more"] }

        if !dryRun {
            state.files = clean
            // What the vault holds now, the saved finds included.
            if let (entries, key) = await index.current() {
                state.generation = ScrubScanner(entries: entries, key: key).generation
            }
            if firstRun { state.firstRealRunAt = now }
            if let data = try? JSONEncoder.remote.encode(state) {
                try? VaultFiles.writeAtomically(data, to: statePath, mode: 0o600)
            }
        }
        return finish(report)
    }

    private func finish(_ report: ScrubReport) -> ScrubReport {
        var report = report
        report.finishedAt = Date()
        let name = report.dryRun ? "last-dry-run" : "last-run"
        let encoder = JSONEncoder.remote
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(report) {
            try? VaultFiles.writeAtomically(data, to: "\(directory)/\(name).json", mode: 0o600)
        }
        let seconds = Int(report.finishedAt.timeIntervalSince(report.startedAt))
        KanbanCodeLog.info("scrub", "\(report.dryRun ? "dry run" : "run") in \(seconds)s: \(report.filesScanned) files scanned, "
            + "\(report.filesUnchanged) unchanged, \(report.filesLive) live, \(report.replacements) replacements in "
            + "\(report.filesWithSecrets) files, \(report.newSecrets) new secrets, \(report.skipped) skipped, \(report.errors.count) errors"
            + (report.note.map { " (\($0))" } ?? ""))
        return report
    }

    // MARK: - Backups

    /// Backups hold the secrets the run removed, so they go after a week.
    func purgeBackups(now: Date = Date()) {
        let fm = FileManager.default
        guard let days = try? fm.contentsOfDirectory(atPath: backupsDirectory) else { return }
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        for day in days {
            guard let date = f.date(from: String(day.prefix(10))),
                  now.timeIntervalSince(date) > Double(Self.backupDays + 1) * 86_400 else { continue }
            try? fm.removeItem(atPath: backupsDirectory + "/" + day)
            KanbanCodeLog.info("scrub", "deleted the backup of \(day)")
        }
    }
}

/// The files a run reads.
public struct ScrubTargets: Sendable {
    public struct File: Sendable, Equatable {
        public var path: String
        public var size: Int
        public var modified: Date
        var stamp: String { "\(size):\(modified.timeIntervalSince1970)" }
    }

    /// Folders read whole, and single files.
    public var roots: [String]
    /// Paths (or folders) never read.
    public var excluded: [String]

    public init(roots: [String], excluded: [String] = []) {
        self.roots = roots
        self.excluded = excluded
    }

    /// Transcripts and histories of Claude Code (the default config folder
    /// and every rush account's), Codex sessions, rush's drafts and cache,
    /// Kanban's own stores, and the OptMem memory.
    public static func standard(home: String, kanbanHome: String) -> ScrubTargets {
        var roots: [String] = []
        var configs = [home + "/.claude"]
        let accounts = home + "/.config/rush/claude"
        for name in (try? FileManager.default.contentsOfDirectory(atPath: accounts)) ?? [] {
            configs.append(accounts + "/" + name)
        }
        for config in configs {
            roots += ["projects", "history.jsonl", "paste-cache"].map { config + "/" + $0 }
        }
        roots += ["sessions", "archived_sessions", "history.jsonl"].map { home + "/.codex/" + $0 }
        roots += ["drafts.json", "drafts.json.bak", "box-drafts"].map { home + "/.config/rush/" + $0 }
        roots += [home + "/Library/Caches/rush", home + "/.cache/rush"]
        let kanban = (try? FileManager.default.contentsOfDirectory(atPath: kanbanHome)) ?? []
        roots += kanban.filter { $0.hasPrefix("links.json") }.map { kanbanHome + "/" + $0 }
        roots += ["human-messages", "logs", "channels", "chat-drafts", "peers", "context", "commands", "hook-events.jsonl"]
            .map { kanbanHome + "/" + $0 }
        roots += [home + "/.optmem/memory", home + "/.optmem/WAKE.md", home + "/.optmem/spool", home + "/.optmem/audit"]
        return ScrubTargets(roots: roots, excluded: [kanbanHome + "/vault", kanbanHome + "/scrub", kanbanHome + "/scrub-backups"])
    }

    private static let skippedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "pdf", "zip", "gz", "tgz", "zst", "age", "sqlite", "db",
        "sqlite-wal", "sqlite-shm", "lock", "pid", "sock", "tmp", "mp4", "mov", "wav", "bin",
    ]

    /// Every regular file under the roots, each once (rush accounts link to
    /// the same folders), symlinks followed at the root only.
    public func files() -> [File] {
        let fm = FileManager.default
        var seen = Set<String>()
        var out: [File] = []
        func add(_ path: String) {
            guard !excluded.contains(where: { path == $0 || path.hasPrefix($0 + "/") }),
                  !Self.skippedExtensions.contains((path as NSString).pathExtension.lowercased()),
                  let attrs = try? fm.attributesOfItem(atPath: path), attrs[.type] as? FileAttributeType == .typeRegular,
                  let size = attrs[.size] as? Int, size >= ScrubIndex.minimumLength,
                  let modified = attrs[.modificationDate] as? Date, seen.insert(path).inserted else { return }
            out.append(File(path: path, size: size, modified: modified))
        }
        for root in roots {
            let resolved = (root as NSString).resolvingSymlinksInPath
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: resolved, isDirectory: &isDirectory) else { continue }
            guard isDirectory.boolValue else {
                add(resolved)
                continue
            }
            guard let walker = fm.enumerator(atPath: resolved) else { continue }
            for case let relative as String in walker {
                add(resolved + "/" + relative)
            }
        }
        return out
    }

    /// The folder a report groups a file under: two levels below home.
    static func folder(of path: String, home: String) -> String {
        guard path.hasPrefix(home + "/") else { return (path as NSString).deletingLastPathComponent }
        let parts = path.dropFirst(home.count + 1).split(separator: "/")
        return "~/" + parts.prefix(min(2, max(parts.count - 1, 1))).joined(separator: "/")
    }
}

/// The secrets found in one file, and how they are replaced.
struct ScrubFilePlan: Sendable {
    var file: ScrubTargets.File
    var kind: ScrubFileKind
    var matches: [ScrubMatch] = []
    var live = false
    var error: String?

    static func scan(_ file: ScrubTargets.File, scanner: ScrubScanner, now: Date, liveWindow: TimeInterval) -> ScrubFilePlan {
        var plan = ScrubFilePlan(file: file, kind: ScrubFileKind.of(path: file.path))
        plan.live = now.timeIntervalSince(file.modified) < liveWindow
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: file.path), options: .alwaysMapped) else {
            plan.error = "could not be read"
            return plan
        }
        data.withUnsafeBytes { buf in
            // A file with a zero byte at its start is not text.
            if buf.prefix(1024).contains(0) { return }
            plan.matches = scanner.scan(buf)
        }
        return plan
    }

    /// Writes the references over the values, in place: each changed line
    /// keeps its length, so the file keeps its size, its inode and the
    /// offset of every line, and a process appending to it loses nothing.
    /// The modification time is put back.
    func apply(_ wanted: [ScrubMatch], scanner: ScrubScanner) -> (applied: [ScrubMatch], error: String?) {
        guard !wanted.isEmpty else { return ([], nil) }
        let fd = open(file.path, O_RDWR)
        guard fd >= 0 else { return ([], "could not be opened for writing") }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, Int(before.st_size) == file.size else { return ([], "changed since it was scanned") }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: file.path), options: .alwaysMapped), data.count == file.size else {
            return ([], "could not be read")
        }
        var patches: [(offset: Int, bytes: [UInt8])] = []
        var applied: [ScrubMatch] = []
        var stale = false
        data.withUnsafeBytes { buf in
            var i = 0
            while i < wanted.count {
                let first = wanted[i]
                var lineStart = first.offset
                while lineStart > 0, buf[lineStart - 1] != 0x0A { lineStart -= 1 }
                var lineEnd = first.offset + first.length
                while lineEnd < buf.count, buf[lineEnd] != 0x0A { lineEnd += 1 }
                if lineEnd < buf.count { lineEnd += 1 }
                var inLine: [ScrubMatch] = []
                while i < wanted.count, wanted[i].offset < lineEnd {
                    var m = wanted[i]
                    i += 1
                    guard m.offset + m.length <= lineEnd else { continue }
                    // The bytes must still be the value that was found.
                    let slice = UnsafeRawBufferPointer(rebasing: buf[m.offset..<(m.offset + m.length)])
                    if let value = m.newValue {
                        guard slice.elementsEqual(value.utf8) else { stale = true; continue }
                    } else if scanner.scan(slice).first?.length != m.length {
                        stale = true
                        continue
                    }
                    m.offset -= lineStart
                    inLine.append(m)
                }
                let line = UnsafeRawBufferPointer(rebasing: buf[lineStart..<lineEnd])
                guard let (bytes, done) = ScrubRewriter.rewrite(line: line, matches: inLine, kind: kind) else { continue }
                if kind == .jsonl, ScrubRewriter.isJSON(line), !bytes.withUnsafeBytes(ScrubRewriter.isJSON) { continue }
                patches.append((lineStart, bytes))
                applied += done.map { m in
                    var m = m
                    m.offset += lineStart
                    return m
                }
            }
        }
        guard !patches.isEmpty else { return ([], stale ? "changed since it was scanned" : nil) }
        if kind == .json, data.count <= 512 << 20, (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil {
            var copy = Data(data)
            for patch in patches { copy.replaceSubrange(patch.offset..<(patch.offset + patch.bytes.count), with: patch.bytes) }
            guard (try? JSONSerialization.jsonObject(with: copy, options: [.fragmentsAllowed])) != nil else {
                return ([], "left alone: it would no longer parse as JSON")
            }
        }
        for patch in patches {
            let written = patch.bytes.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, off_t(patch.offset)) }
            guard written == patch.bytes.count else { return (applied, "a write failed part way: \(String(cString: strerror(errno)))") }
        }
        fsync(fd)
        #if canImport(Darwin)
        var times = [before.st_atimespec, before.st_mtimespec]
        #else
        var times = [before.st_atim, before.st_mtim]
        #endif
        futimens(fd, &times)
        return (applied, nil)
    }
}

/// Compressed copies of the files the first run changes, under
/// `scrub-backups/<day>/`, with a manifest of where each came from.
final class ScrubBackup {
    let directory: String
    private var manifest: [String: String] = [:]
    var count: Int { manifest.count }

    init(root: String, day: String) {
        directory = root + "/" + day
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// Copies a file in, gzipped. Returns why it failed, or nil.
    func add(_ path: String) -> String? {
        let name = String(format: "%05d-", manifest.count) + (path as NSString).lastPathComponent + ".gz"
        let target = directory + "/" + name
        guard FileManager.default.createFile(atPath: target, contents: nil, attributes: [.posixPermissions: 0o600]),
              let output = FileHandle(forWritingAtPath: target) else { return "could not create \(name)" }
        defer { try? output.close() }
        let gzip = Process()
        gzip.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        gzip.arguments = ["gzip", "-c", "--", path]
        gzip.standardOutput = output
        gzip.standardError = FileHandle.nullDevice
        do {
            try gzip.run()
            gzip.waitUntilExit()
        } catch {
            return "gzip did not start"
        }
        guard gzip.terminationStatus == 0 else {
            try? FileManager.default.removeItem(atPath: target)
            return "gzip exited \(gzip.terminationStatus)"
        }
        manifest[name] = path
        return nil
    }

    func writeManifest() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(manifest) else { return }
        try? VaultFiles.writeAtomically(data, to: directory + "/manifest.json", mode: 0o600)
    }
}
