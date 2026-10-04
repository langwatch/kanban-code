import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import KanbanCodeRemoteKit

/// What the scrubber does with a key in a vendor's format that the vault
/// does not hold.
/// What one manual run does differently from the schedule: its own
/// patterns mode, and vendors whose keys it leaves in place.
public struct ScrubOnce: Codable, Sendable, Equatable {
    public var patterns: ScrubPatterns
    /// Vendor names as the finds are named: `LANGWATCH_API_KEY`.
    public var except: Set<String>

    public init(patterns: ScrubPatterns, except: Set<String> = []) {
        self.patterns = patterns
        self.except = except
    }

    var note: String {
        let left = except.isEmpty ? "" : ", except \(except.sorted().joined(separator: ", "))"
        return "one-off run: patterns \(patterns.rawValue)\(left); the schedule is unchanged"
    }
}

public enum ScrubPatterns: String, Codable, Sendable, CaseIterable {
    /// Left alone: only values the vault holds are replaced.
    case off
    /// Saved and replaced everywhere when the human typed it into a chat;
    /// a key that only an agent or a tool wrote is left alone.
    case typed
    /// Saved and replaced wherever it is.
    case on
}

/// The scrubber's settings: when it runs on its own (once a day at
/// `hour:minute`, local time) and what it reads beyond the standard files.
public struct ScrubSchedule: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var hour: Int
    public var minute: Int
    /// Extra files and folders to read, with `~` for the home folder, so
    /// one list fits every master. A path missing on a machine is skipped there.
    public var paths: [String]
    public var patterns: ScrubPatterns

    public init(enabled: Bool = true, hour: Int = 4, minute: Int = 30, paths: [String] = [], patterns: ScrubPatterns = .typed) {
        self.patterns = patterns
        self.enabled = enabled
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
        var seen = Set<String>()
        self.paths = paths.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    enum CodingKeys: String, CodingKey { case enabled, hour, minute, paths, patterns }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
                  hour: try c.decodeIfPresent(Int.self, forKey: .hour) ?? 4,
                  minute: try c.decodeIfPresent(Int.self, forKey: .minute) ?? 30,
                  paths: try c.decodeIfPresent([String].self, forKey: .paths) ?? [],
                  patterns: Self.patterns(in: c))
    }

    /// The mode by name; a file of an older build holds true or false.
    private static func patterns(in c: KeyedDecodingContainer<CodingKeys>) -> ScrubPatterns {
        if let mode = try? c.decodeIfPresent(ScrubPatterns.self, forKey: .patterns) { return mode }
        if let flag = try? c.decodeIfPresent(Bool.self, forKey: .patterns) { return flag ? .on : .off }
        return .typed
    }

    /// A path as the list keeps it: under the home folder it starts with `~`.
    public static func portable(_ path: String, home: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix(home + "/") ? "~" + trimmed.dropFirst(home.count) : trimmed
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
    /// A run stops changing files when the disk has less than this free.
    static let freeDiskFloor = 1 << 30

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
        let clean = ScrubSchedule(enabled: schedule.enabled, hour: schedule.hour, minute: schedule.minute,
                                  paths: schedule.paths.map { ScrubSchedule.portable($0, home: home) },
                                  patterns: schedule.patterns)
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
    public func start(dryRun: Bool, once: ScrubOnce? = nil) -> Bool {
        guard !running else { return false }
        running = true
        progress = "starting"
        Task.detached(priority: .utility) { _ = await self.run(dryRun: dryRun, claimed: true, once: once) }
        return true
    }

    /// Writes back what the runs of the last week replaced in `paths`
    /// (every file when nil). Nothing happens while a run is in progress.
    public func restore(paths: [String]?) -> (files: Int, errors: [String]) {
        guard !running else { return (0, ["a run is in progress"]) }
        let wanted = paths.map { Set($0.map { SyncHome.expand($0, home: home) }) }
        let result = ScrubBackup.restore(root: backupsDirectory, paths: wanted)
        KanbanCodeLog.info("scrub", "restored \(result.files) files from the backups, \(result.errors.count) errors")
        return result
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
    public func run(dryRun: Bool, targets: ScrubTargets? = nil, now: Date = Date(), claimed: Bool = false,
                    once: ScrubOnce? = nil) async -> ScrubReport {
        var report = ScrubReport(machine: machine, startedAt: now, finishedAt: now, dryRun: dryRun)
        report.note = once?.note
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
        let settings = schedule()
        // A one-off run takes its own patterns mode and reads every file;
        // the schedule and what the scheduled runs know stay as they are.
        let patterns = once?.patterns ?? settings.patterns
        let scanner = ScrubScanner(entries: entries, key: key, patterns: patterns, except: once?.except ?? [])
        var state = loadState()
        let known = once == nil && state.generation == scanner.generation ? state.files : [:]
        let files = (targets ?? ScrubTargets.standard(home: home, kanbanHome: kanbanHome, extra: settings.paths)).files()
        let typedText = patterns == .typed ? ScrubTypedText(home: home, kanbanHome: kanbanHome) : nil
        report.filesSeen = files.count

        // Scan.
        let window = liveWindow
        var plans: [ScrubFilePlan] = []
        var clean: [String: String] = [:]
        var pending: [ScrubTargets.File] = []
        var unchanged: [ScrubTargets.File] = []
        for file in files {
            if known[file.path] == file.stamp {
                report.filesUnchanged += 1
                clean[file.path] = file.stamp
                unchanged.append(file)
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
                group.addTask(priority: .utility) {
                    ScrubFilePlan.scan(file, scanner: scanner, now: now, liveWindow: window, typedText: typedText)
                }
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
        if patterns == .typed {
            // Only a key the human typed somewhere is taken, and then in every file.
            let typed = plans.reduce(into: Set<String>()) { $0.formUnion($1.typed) }
            plans = plans.compactMap { plan in
                var plan = plan
                plan.matches.removeAll { $0.newValue.map { !typed.contains($0) } ?? false }
                if plan.matches.isEmpty {
                    if !plan.live, plan.error == nil { clean[plan.file.path] = plan.file.stamp }
                    return nil
                }
                return plan
            }
            // Files the last run left clean were not read: they may hold the key too.
            var byName: [String: String] = [:]
            for plan in plans {
                for m in plan.matches { if let value = m.newValue { byName[m.name] = value } }
            }
            let entries = byName.compactMap { name, value in
                key.fingerprint(name: name, tag: key.tagHex(value), bytes: Array(value.utf8))
            }
            if !entries.isEmpty, !unchanged.isEmpty {
                progress = "looking for \(entries.count) typed keys in \(unchanged.count) unchanged files"
                let only = ScrubScanner(entries: entries, key: key, patterns: .off)
                var next = 0
                await withTaskGroup(of: ScrubFilePlan.self) { group in
                    func add() {
                        guard next < unchanged.count else { return }
                        let file = unchanged[next]
                        next += 1
                        group.addTask(priority: .utility) { ScrubFilePlan.scan(file, scanner: only, now: now, liveWindow: window) }
                    }
                    for _ in 0..<width { add() }
                    for await var plan in group {
                        add()
                        guard !plan.matches.isEmpty else { continue }
                        for i in plan.matches.indices { plan.matches[i].newValue = byName[plan.matches[i].name] }
                        plans.append(plan)
                    }
                }
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
        if !dryRun, plans.contains(where: { !$0.live }) {
            backup = ScrubBackup(root: backupsDirectory, day: Self.day(now))
            report.backupPath = backup?.directory
        }
        var done = 0
        var outOfDisk = false
        for plan in plans {
            done += 1
            if done % 50 == 0 { progress = "\(dryRun ? "counted" : "cleaned") \(done) of \(plans.count) files" }
            // A run never takes the disk below the floor: what is left waits for the next one.
            if !dryRun, !plan.live, !outOfDisk,
               let free = (try? FileManager.default.attributesOfFileSystem(forPath: kanbanHome))?[.systemFreeSize] as? Int,
               free < Self.freeDiskFloor {
                outOfDisk = true
                report.errors.append("stopped at file \(done) of \(plans.count): less than 1 GB of disk free")
            }
            if outOfDisk, !plan.live {
                clean[plan.file.path] = nil
                report.skipped += plan.matches.count
                continue
            }
            var entry = ScrubFileReport(path: plan.file.path, known: 0, new: 0, live: plan.live ? true : nil)
            var applied = plan.matches
            if !dryRun {
                clean[plan.file.path] = nil
                if plan.live {
                    applied = []
                } else {
                    let wanted = plan.matches.filter { !unsaved.contains($0.name) }
                    let result = plan.apply(wanted, scanner: scanner, backup: backup)
                    applied = result.applied
                    entry.error = result.error
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
        // Times are checked again at the end.
        if !dryRun {
            var moved = 0
            for plan in plans where !plan.live {
                if let now = (try? FileManager.default.attributesOfItem(atPath: plan.file.path))?[.modificationDate] as? Date,
                   abs(now.timeIntervalSince(plan.file.modified)) >= 1, now > plan.file.modified,
                   (try? FileManager.default.attributesOfItem(atPath: plan.file.path))?[.size] as? Int == plan.file.size {
                    moved += 1
                    _ = ScrubFilePlan.restoreTime(plan.file.path, to: plan.file.modified)
                }
            }
            if moved > 0 { KanbanCodeLog.warn("scrub", "put the modification time back on \(moved) files at the end of the run") }
        }
        if let backup, backup.files > 0 {
            report.backupFiles = backup.files
        } else {
            report.backupPath = nil
        }
        report.files.sort { ($0.known + $0.new, $1.path) > ($1.known + $1.new, $0.path) }
        report.files = Array(report.files.prefix(200))
        if report.errors.count > 50 { report.errors = Array(report.errors.prefix(50)) + ["and \(report.errors.count - 50) more"] }

        if !dryRun, once == nil {
            state.files = clean
            // What the vault holds now, the saved finds included.
            if let (entries, key) = await index.current() {
                state.generation = ScrubScanner(entries: entries, key: key, patterns: settings.patterns).generation
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
        // A dry run describes the files as they were before the next real run.
        if !report.dryRun { try? FileManager.default.removeItem(atPath: "\(directory)/last-dry-run.json") }
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
    /// Kanban's own stores, and the `extra` paths of the settings.
    public static func standard(home: String, kanbanHome: String, extra: [String] = []) -> ScrubTargets {
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
        let sessions = home + "/.config/rush/sessions"
        roots += ((try? FileManager.default.contentsOfDirectory(atPath: sessions)) ?? []).map { "\(sessions)/\($0)/human.jsonl" }
        roots += [home + "/Library/Caches/rush", home + "/.cache/rush"]
        let kanban = (try? FileManager.default.contentsOfDirectory(atPath: kanbanHome)) ?? []
        roots += kanban.filter { $0.hasPrefix("links.json") }.map { kanbanHome + "/" + $0 }
        roots += ["human-messages", "logs", "channels", "chat-drafts", "peers", "context", "commands", "hook-events.jsonl"]
            .map { kanbanHome + "/" + $0 }
        roots += extra.map { SyncHome.expand($0, home: home) }.filter { $0.hasPrefix("/") }
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

/// Tells the text the human typed from what an agent or a tool wrote:
/// Kanban's record of his messages and rush's `human.jsonl` hold only his
/// text (docs/side-chat.md). A transcript never counts on its own, since a
/// prompt an agent wrote reads there the same as one he typed.
struct ScrubTypedText: Sendable {
    let kanbanRecords: String
    let rushSessions: String

    init(home: String, kanbanHome: String) {
        kanbanRecords = ((kanbanHome + "/human-messages") as NSString).resolvingSymlinksInPath + "/"
        rushSessions = ((home + "/.config/rush/sessions") as NSString).resolvingSymlinksInPath + "/"
    }

    func isRecord(_ path: String) -> Bool {
        path.hasPrefix(kanbanRecords) || (path.hasPrefix(rushSessions) && path.hasSuffix("/human.jsonl"))
    }

    /// The values of the new finds in `matches` that sit in a record's text.
    func typedKeys(in buf: UnsafeRawBufferPointer, matches: [ScrubMatch], path: String, kind: ScrubFileKind) -> Set<String> {
        guard kind == .jsonl, isRecord(path), matches.contains(where: { $0.newValue != nil }) else { return [] }
        var out = Set<String>()
        var lineEnd = -1
        var text: String?
        for m in matches {
            guard let value = m.newValue else { continue }
            if m.offset >= lineEnd {
                var start = m.offset
                while start > 0, buf[start - 1] != 0x0A { start -= 1 }
                lineEnd = m.offset + m.length
                while lineEnd < buf.count, buf[lineEnd] != 0x0A { lineEnd += 1 }
                let line = Data(UnsafeRawBufferPointer(rebasing: buf[start..<lineEnd]))
                text = ((try? JSONSerialization.jsonObject(with: line)) as? [String: Any])?["text"] as? String
            }
            if let text, text.contains(value) { out.insert(value) }
        }
        return out
    }
}

/// The secrets found in one file, and how they are replaced.
struct ScrubFilePlan: Sendable {
    var file: ScrubTargets.File
    var kind: ScrubFileKind
    var matches: [ScrubMatch] = []
    var live = false
    var error: String?
    /// New keys of this file that sit in text the human typed.
    var typed: Set<String> = []

    static func scan(_ file: ScrubTargets.File, scanner: ScrubScanner, now: Date, liveWindow: TimeInterval,
                     typedText: ScrubTypedText? = nil) -> ScrubFilePlan {
        var plan = ScrubFilePlan(file: file, kind: ScrubFileKind.of(path: file.path))
        plan.live = now.timeIntervalSince(file.modified) < liveWindow
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: file.path), options: .alwaysMapped) else {
            // A file deleted since it was listed (a rotated log) is not an error.
            if FileManager.default.fileExists(atPath: file.path) { plan.error = "could not be read" }
            return plan
        }
        data.withUnsafeBytes { buf in
            // A file with a zero byte at its start is not text.
            if buf.prefix(1024).contains(0) { return }
            plan.matches = scanner.scan(buf)
            if let typedText { plan.typed = typedText.typedKeys(in: buf, matches: plan.matches, path: file.path, kind: plan.kind) }
        }
        return plan
    }

    /// Writes the references over the values, in place: each changed line
    /// keeps its length, so the file keeps its size, its inode and the
    /// offset of every line, and a process appending to it loses nothing.
    /// The modification time is put back.
    func apply(_ wanted: [ScrubMatch], scanner: ScrubScanner, backup: ScrubBackup? = nil) -> (applied: [ScrubMatch], error: String?) {
        guard !wanted.isEmpty else { return ([], nil) }
        var before = stat()
        guard lstat(file.path, &before) == 0, Int(before.st_size) == file.size else { return ([], "changed since it was scanned") }
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
                // Only the bytes of each value are written, so a copy-on-write
                // backup shares every other block of the file.
                for m in done {
                    patches.append((lineStart + m.offset, Array(bytes[m.offset..<(m.offset + m.length)])))
                    var m = m
                    m.offset += lineStart
                    applied.append(m)
                }
            }
        }
        guard !patches.isEmpty else { return ([], stale ? "changed since it was scanned" : nil) }
        // macOS inflates a transparently compressed file when it is opened
        // for writing, so it needs room for its full size until it is
        // compressed again below.
        let compressed = Self.isCompressed(file.path)
        if compressed, let free = (try? FileManager.default.attributesOfFileSystem(forPath: file.path))?[.systemFreeSize] as? Int,
           free < SecretScrubber.freeDiskFloor + file.size {
            return ([], "left alone: not enough free disk to rewrite a compressed file")
        }
        if kind == .json, data.count <= 512 << 20, (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil {
            var copy = Data(data)
            for patch in patches { copy.replaceSubrange(patch.offset..<(patch.offset + patch.bytes.count), with: patch.bytes) }
            guard (try? JSONSerialization.jsonObject(with: copy, options: [.fragmentsAllowed])) != nil else {
                return ([], "left alone: it would no longer parse as JSON")
            }
        }
        if let backup {
            let old = data.withUnsafeBytes { buf in
                patches.map { (offset: $0.offset, bytes: Array(buf[$0.offset..<($0.offset + $0.bytes.count)])) }
            }
            if let failure = backup.add(file.path, ranges: old) { return ([], "not changed, the backup failed: \(failure)") }
        }
        let fd = open(file.path, O_RDWR)
        guard fd >= 0 else { return ([], "could not be opened for writing") }
        var times = Self.times(of: before)
        var failure: String?
        for patch in patches {
            let written = patch.bytes.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, off_t(patch.offset)) }
            if written != patch.bytes.count {
                failure = "a write failed part way: \(String(cString: strerror(errno)))"
                break
            }
        }
        fsync(fd)
        futimens(fd, &times)
        close(fd)
        if compressed { Self.recompress(file.path, times: times) }
        return (applied, failure)
    }

    static func times(of s: stat) -> [timespec] {
        #if canImport(Darwin)
        return [s.st_atimespec, s.st_mtimespec]
        #else
        return [s.st_atim, s.st_mtim]
        #endif
    }

    /// Whether the file is stored with APFS transparent compression.
    static func isCompressed(_ path: String) -> Bool {
        #if canImport(Darwin)
        var s = stat()
        return lstat(path, &s) == 0 && s.st_flags & UInt32(UF_COMPRESSED) != 0
        #else
        return false
        #endif
    }

    /// Compresses a file again after a write inflated it: a compressed
    /// copy takes its place, with the same times. Left inflated when the
    /// copy fails or differs in size.
    static func recompress(_ path: String, times: [timespec]) {
        #if canImport(Darwin)
        let copy = path + ".scrub-tmp"
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["--hfsCompression", path, copy]
        ditto.standardOutput = FileHandle.nullDevice
        ditto.standardError = FileHandle.nullDevice
        var original = stat(), made = stat()
        guard (try? ditto.run()) != nil else { return }
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0, lstat(path, &original) == 0, lstat(copy, &made) == 0,
              made.st_size == original.st_size else {
            unlink(copy)
            return
        }
        var times = times
        utimensat(AT_FDCWD, copy, &times, 0)
        if rename(copy, path) != 0 { unlink(copy) }
        #endif
    }

    /// Puts a file's modification time back when it moved after the run
    /// wrote it; false when it could not.
    static func restoreTime(_ path: String, to modified: Date) -> Bool {
        guard let now = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return false }
        if abs(now.timeIntervalSince(modified)) < 1 { return true }
        return (try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path)) != nil
    }
}

/// The bytes a run replaced, under `scrub-backups/<day>/ranges.jsonl`: one
/// line per replaced value with the file, the offset and the bytes that were
/// there. It is all a restore needs, since a run changes nothing else, and
/// it takes a few bytes per value whatever the size of the file.
final class ScrubBackup {
    let directory: String
    private(set) var files = 0
    static let fileName = "ranges.jsonl"

    struct Entry: Codable {
        /// The file.
        var p: String
        /// Offset of the bytes in it.
        var o: Int
        /// The bytes that were there, base64.
        var b: String
    }

    init(root: String, day: String) {
        directory = root + "/" + day
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// Records what a file held at each range, before the file is written.
    /// Returns why it failed, or nil.
    func add(_ path: String, ranges: [(offset: Int, bytes: [UInt8])]) -> String? {
        var lines = Data()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        for range in ranges {
            guard let line = try? encoder.encode(Entry(p: path, o: range.offset, b: Data(range.bytes).base64EncodedString())) else {
                return "could not be encoded"
            }
            lines.append(line)
            lines.append(0x0A)
        }
        let fd = open(directory + "/" + Self.fileName, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { return "could not open \(Self.fileName)" }
        defer { close(fd) }
        let written = lines.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == lines.count, fsync(fd) == 0 else { return "could not write \(Self.fileName)" }
        files += 1
        return nil
    }

    /// Writes the recorded bytes back into `paths` (every file when nil),
    /// from every backup folder under `root`. A file shorter than a range
    /// needs is left alone. Returns the files restored and what failed.
    static func restore(root: String, paths: Set<String>?) -> (files: Int, errors: [String]) {
        var byFile: [String: [(offset: Int, bytes: Data)]] = [:]
        let days = ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).sorted()
        for day in days {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: "\(root)/\(day)/\(fileName)"), options: .alwaysMapped) else { continue }
            for line in data.split(separator: 0x0A) {
                guard let entry = try? JSONDecoder().decode(Entry.self, from: line), paths?.contains(entry.p) ?? true,
                      let bytes = Data(base64Encoded: entry.b) else { continue }
                byFile[entry.p, default: []].append((entry.o, bytes))
            }
        }
        var restored = 0
        var errors: [String] = []
        for (path, ranges) in byFile.sorted(by: { $0.key < $1.key }) {
            let compressed = ScrubFilePlan.isCompressed(path)
            let fd = open(path, O_RDWR)
            guard fd >= 0 else { errors.append("\(path): could not be opened"); continue }
            var before = stat()
            guard fstat(fd, &before) == 0, ranges.allSatisfy({ $0.offset + $0.bytes.count <= Int(before.st_size) }) else {
                close(fd)
                errors.append("\(path): shorter than it was, left alone")
                continue
            }
            var failed = false
            for range in ranges {
                let n = range.bytes.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, off_t(range.offset)) }
                if n != range.bytes.count { failed = true }
            }
            fsync(fd)
            var times = ScrubFilePlan.times(of: before)
            futimens(fd, &times)
            close(fd)
            if compressed { ScrubFilePlan.recompress(path, times: times) }
            if failed { errors.append("\(path): a write failed") } else { restored += 1 }
        }
        for path in paths ?? [] where byFile[path] == nil { errors.append("\(path): no backup holds it") }
        return (restored, errors)
    }
}
