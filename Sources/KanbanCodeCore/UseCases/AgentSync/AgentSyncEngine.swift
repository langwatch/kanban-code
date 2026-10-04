import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Settings > Sync at work: keeps the agent setup (git clones, mirrored
/// files, the OptMem memory) the same on every peer master.
///
/// Every machine only ever writes its own disk. It scans its entries every
/// few seconds, tells its peers when something changed, and pulls their
/// newer versions on a timer or when a peer says so. The same engine runs in
/// the Mac app and in `kanban-code-server`.
public actor AgentSyncEngine {
    public typealias Peers = @Sendable () async -> [SyncPeer]

    public struct Options: Sendable {
        public var scanInterval: Double = 5
        public var pullInterval: Double = 60
        public var gitInterval: Double = 120

        public init() {}
    }

    let home: String
    let kanbanHome: String
    public let identity: MachineIdentity
    let peers: Peers
    let transport: any SyncTransport
    let git: GitRepoSync
    let options: Options

    private(set) var config: SyncConfig
    private var configStamp: String?
    private var manifests: [String: [String: SyncItem]] = [:]
    private var lastScan: Date = .distantPast
    private var gitInfo: [String: SyncGitInfo] = [:]
    private var learnedURLs: [String: String] = [:]
    private var statuses: [String: SyncEntryStatus] = [:]
    private var lastPull: [String: Date] = [:]
    private var lastGit: Date = .distantPast
    private var pokedPeers: Set<String> = []
    private var pokedAll = false
    private var pokedGit: Set<String> = []
    private var peerNames: [String: String] = [:]
    private var optmemApplied: [String: OptmemRunResult] = [:]
    private var optmemAppliedOrder: [String] = []

    /// `$HOME` when set (Linux Foundation ignores it), else the account's home.
    public static var userHome: String {
        if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty { return home }
        return NSHomeDirectory()
    }

    public init(
        home: String = AgentSyncEngine.userHome,
        kanbanHome: String = AgentSyncEngine.userHome + "/.kanban-code",
        identity: MachineIdentity,
        peers: @escaping Peers,
        transport: any SyncTransport = HTTPSyncTransport(),
        git: GitRepoSync = GitRepoSync(),
        options: Options = Options()
    ) {
        self.home = home
        self.kanbanHome = kanbanHome
        self.identity = identity
        self.peers = peers
        self.transport = transport
        self.git = git
        self.options = options
        self.config = Self.loadConfig(kanbanHome: kanbanHome)
        self.configStamp = Self.stamp(Self.configPath(kanbanHome))
        for entry in config.entries where entry.mode != .git {
            manifests[entry.id] = Self.loadManifest(kanbanHome: kanbanHome, entryId: entry.id)
        }
        manifestBasis = Dictionary(uniqueKeysWithValues: config.entries.map { ($0.id, Self.basis($0, identity: identity)) })
        let applied = Self.loadApplied(kanbanHome: kanbanHome)
        for entry in applied {
            optmemApplied[entry.id] = entry.result
            optmemAppliedOrder.append(entry.id)
        }
    }

    // MARK: - Files

    static func configPath(_ kanbanHome: String) -> String { kanbanHome + "/sync.json" }

    static func manifestPath(_ kanbanHome: String, _ entryId: String) -> String {
        let safe = entryId.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" }
        return kanbanHome + "/sync/manifests/" + String(safe) + ".json"
    }

    static func loadConfig(kanbanHome: String) -> SyncConfig {
        guard let data = FileManager.default.contents(atPath: configPath(kanbanHome)),
              let config = try? JSONDecoder().decode(SyncConfig.self, from: data)
        else { return .defaults }
        return config
    }

    static func loadManifest(kanbanHome: String, entryId: String) -> [String: SyncItem] {
        guard let data = FileManager.default.contents(atPath: manifestPath(kanbanHome, entryId)),
              let items = try? JSONDecoder().decode([String: SyncItem].self, from: data)
        else { return [:] }
        return items
    }

    static func writeAtomically(_ data: Data, to path: String, mode: Int = 0o644) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let tmp = path + ".tmp-\(getpid())"
        guard FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: mode]) else { return }
        if rename(tmp, path) != 0 { try? FileManager.default.removeItem(atPath: tmp) }
    }

    private func saveConfig() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(config) { Self.writeAtomically(data, to: Self.configPath(kanbanHome)) }
        configStamp = Self.stamp(Self.configPath(kanbanHome))
    }

    /// Size and modification time of a file, to notice edits from outside.
    static func stamp(_ path: String) -> String? {
        guard let info = SyncScanner.lstat(path) else { return nil }
        return "\(info.size):\(info.mtime)"
    }

    /// A hand edit of `sync.json` (a box has no Settings window) counts as
    /// an edit made here now.
    private func reloadEditedConfig() async {
        let path = Self.configPath(kanbanHome)
        let current = Self.stamp(path)
        guard current != configStamp else { return }
        configStamp = current
        guard let data = FileManager.default.contents(atPath: path),
              let edited = try? JSONDecoder().decode(SyncConfig.self, from: data),
              edited.entries != config.entries
        else { return }
        KanbanCodeLog.info("sync", "sync.json edited by hand")
        await setEntries(edited.entries)
    }

    private func saveManifest(_ entryId: String) {
        guard let items = manifests[entryId], let data = try? JSONEncoder().encode(items) else { return }
        Self.writeAtomically(data, to: Self.manifestPath(kanbanHome, entryId))
    }

    // MARK: - Configuration

    public func currentConfig() -> SyncConfig { config }

    /// Settings > Sync changed the entries here: they win over every peer's.
    public func setEntries(_ entries: [SyncEntry]) async {
        config = SyncConfig(updatedAt: max(Date().timeIntervalSince1970, config.updatedAt + 0.001), entries: entries)
        saveConfig()
        dropStaleState()
        lastScan = .distantPast
        pokedAll = true
        await notifyPeers(what: "config")
    }

    private func adoptConfig(_ remote: SyncConfig, from peer: String) {
        guard remote.updatedAt > config.updatedAt, remote != config else { return }
        config = remote
        saveConfig()
        dropStaleState()
        lastScan = .distantPast
        KanbanCodeLog.info("sync", "took Settings > Sync from \(peer)")
    }

    /// What a manifest's versions were computed from, besides the files:
    /// the entry's path on this machine and its keys.
    private var manifestBasis: [String: String] = [:]

    static func basis(_ entry: SyncEntry, identity: MachineIdentity) -> String {
        entry.path(on: identity) + "\n" + entry.keys.sorted().joined(separator: "\n")
    }

    private func dropStaleState() {
        let ids = Set(config.entries.map(\.id))
        for id in statuses.keys where !ids.contains(id) { statuses[id] = nil }
        // Another path or other keys: the versions kept are of something
        // else, and a file gone from the old path is not a deletion.
        for entry in config.entries where entry.copiesFiles {
            let basis = Self.basis(entry, identity: identity)
            if let known = manifestBasis[entry.id], known != basis {
                manifests[entry.id] = [:]
                saveManifest(entry.id)
            }
            manifestBasis[entry.id] = basis
        }
        for entry in config.entries where entry.mode != .git && manifests[entry.id] == nil {
            manifests[entry.id] = Self.loadManifest(kanbanHome: kanbanHome, entryId: entry.id)
        }
    }

    // MARK: - Status

    public func entryStatuses() -> [String: SyncEntryStatus] { statuses }

    private func setStatus(_ entry: SyncEntry, _ level: SyncEntryStatus.Level, _ message: String, count: Int? = nil, synced: Bool = false) {
        var status = statuses[entry.id] ?? SyncEntryStatus(entryId: entry.id, message: message)
        status.level = level
        status.message = message
        status.count = count
        if synced { status.lastSync = Date() }
        statuses[entry.id] = status
    }

    // MARK: - Loop

    /// Pokes: a peer said its entries, a git clone or the memory changed.
    public func poke(machineId: String?, what: String?) {
        if let what, what.hasPrefix("git:") { pokedGit.insert(String(what.dropFirst(4))) }
        if let machineId { pokedPeers.insert(machineId) } else { pokedAll = true }
    }

    public func run() async {
        var tick = 0
        while !Task.isCancelled {
            await round(tick: tick)
            tick += 1
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// One pass of the loop; exposed for tests.
    public func round(tick: Int = 0) async {
        let now = Date()
        let poked = pokedAll || !pokedPeers.isEmpty || !pokedGit.isEmpty
        let scanDue = now.timeIntervalSince(lastScan) >= options.scanInterval
        let gitDue = now.timeIntervalSince(lastGit) >= options.gitInterval
        guard poked || scanDue || gitDue else { return }

        if scanDue || poked {
            await reloadEditedConfig()
            if scanAll() { await notifyPeers(what: "mirror") }
        }
        let peers = await self.peers()
        for peer in peers { peerNames[peer.machine.id] = peer.machine.name }
        let all = pokedAll
        pokedAll = false
        for peer in peers where peer.online {
            let due = now.timeIntervalSince(lastPull[peer.machine.id] ?? .distantPast) >= options.pullInterval
            if all || due || pokedPeers.contains(peer.machine.id) {
                pokedPeers.remove(peer.machine.id)
                await pull(peer)
            }
        }
        pokedPeers.removeAll()
        if !peers.contains(where: \.online) {
            for entry in config.entries where entry.enabled && entry.copiesFiles {
                let files = (manifests[entry.id] ?? [:]).values.filter { !$0.deleted }.count
                setStatus(entry, .info, peers.isEmpty ? "no peer machine yet" : "no peer online", count: files)
            }
        }
        if gitDue || !pokedGit.isEmpty {
            let only = gitDue ? nil : pokedGit
            pokedGit.removeAll()
            if gitDue { lastGit = now }
            await syncGit(only: only)
        }
        await optmemRound(peers: peers)
    }

    private func notifyPeers(what: String) async {
        for peer in await peers() where peer.online {
            await transport.notify(peer: peer, machineId: identity.id, what: what)
        }
    }

    // MARK: - Scanning

    /// The entry's path on this machine, with `~`.
    func localPath(_ entry: SyncEntry) -> String { entry.path(on: identity) }

    func root(_ entry: SyncEntry) -> String { SyncHome.expand(localPath(entry), home: home) }

    /// The entry's own excludes plus the login files, which only the login
    /// sync writes.
    func mirrorExcludes(_ entry: SyncEntry) -> SyncExcludes {
        SyncExcludes(entry.excludes + SyncConfig.loginFileExcludes(entryPath: localPath(entry)))
    }

    /// Whether `path` of a mirror is a login file (or the whole mirror is).
    func isLoginFile(_ entry: SyncEntry, path: String) -> Bool {
        if SyncConfig.isLoginFile(entryPath: localPath(entry)) { return true }
        let login = SyncExcludes(SyncConfig.loginFileExcludes(entryPath: localPath(entry)))
        return scanner(rewriteHome: false).isExcluded(rel: path, excludes: login, only: nil)
    }

    private func scanner(rewriteHome: Bool) -> SyncScanner {
        SyncScanner(home: home, machineId: identity.id, rewriteHome: rewriteHome)
    }

    /// The scanner of a mirror or `json` entry.
    private func scanner(for entry: SyncEntry) -> SyncScanner {
        SyncScanner(home: home, machineId: identity.id, rewriteHome: entry.copiesFiles,
                    jsonKeys: entry.mode == .json ? entry.keys : nil)
    }

    static let optmemTop: Set<String> = ["memory", "WAKE.md"]
    static let optmemExcludes = SyncExcludes([".lock", "*.tmp*"])

    /// Rescans every mirror (and the memory this machine is home of).
    /// Returns whether a local change appeared.
    @discardableResult
    func scanAll() -> Bool {
        lastScan = Date()
        var changed = false
        for entry in config.entries where entry.enabled {
            switch entry.mode {
            case .mirror, .json:
                if SyncConfig.isLoginFile(entryPath: localPath(entry)) { continue }
                let before = manifests[entry.id] ?? [:]
                let after = scanner(for: entry).scan(
                    root: root(entry), excludes: mirrorExcludes(entry), previous: before)
                if after != before {
                    manifests[entry.id] = after
                    saveManifest(entry.id)
                    if Self.versions(after) != Self.versions(before) { changed = true }
                }
            case .optmem:
                let before = manifests[entry.id] ?? [:]
                let after = scanOptmem(entry, previous: before)
                if after != before {
                    manifests[entry.id] = after
                    if Self.versions(after) != Self.versions(before) { changed = true }
                }
            case .git:
                break
            }
        }
        return changed
    }

    private func scanOptmem(_ entry: SyncEntry, previous: [String: SyncItem]) -> [String: SyncItem] {
        scanner(rewriteHome: false).scan(
            root: root(entry), excludes: Self.optmemExcludes, previous: previous, only: Self.optmemTop)
    }

    /// The versions of a manifest, without the local caches.
    static func versions(_ items: [String: SyncItem]) -> [String: String] {
        items.mapValues { $0.deleted ? "-" : "\($0.kind.rawValue):\($0.hash)" }
    }

    // MARK: - Serving

    /// `GET /v1/sync/state`.
    public func state() -> SyncStateResponse {
        if Date().timeIntervalSince(lastScan) > 2 { scanAll() }
        var mirrors: [String: [String: SyncItem]] = [:]
        var homes: [String] = []
        for entry in config.entries where entry.enabled {
            switch entry.mode {
            case .mirror, .json:
                mirrors[entry.id] = manifests[entry.id] ?? [:]
            case .optmem:
                if isLocalOptmemHome(entry, peers: lastPeers) {
                    homes.append(entry.id)
                    mirrors[entry.id] = manifests[entry.id] ?? [:]
                }
            case .git:
                break
            }
        }
        return SyncStateResponse(machine: identity, config: config, manifests: mirrors, git: gitInfo, optmemHome: homes)
    }

    /// `GET /v1/sync/file`: the content of one manifest file, home marked.
    public func file(entryId: String, path: String) -> Data? {
        guard let entry = config.entries.first(where: { $0.id == entryId && $0.enabled }), entry.mode != .git,
              let item = manifests[entryId]?[path], !item.deleted, item.kind == .file,
              !path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
              !entry.copiesFiles || !isLoginFile(entry, path: path)
        else { return nil }
        return scanner(for: entry).content(root: root(entry), rel: path)
    }

    // MARK: - Pulling

    private func pull(_ peer: SyncPeer) async {
        let remote: SyncStateResponse
        do {
            remote = try await transport.state(peer: peer)
        } catch {
            KanbanCodeLog.info("sync", "pull from \(peer.machine.name) failed: \(error.localizedDescription)")
            return
        }
        lastPull[peer.machine.id] = Date()
        peerNames[remote.machine.id] = remote.machine.name
        adoptConfig(remote.config, from: remote.machine.name)
        for (id, info) in remote.git {
            guard let url = info.url, !url.isEmpty, learnedURLs[id] != url else { continue }
            learnedURLs[id] = url
            // A clone missing here can start now rather than on the next timer.
            if let entry = config.entries.first(where: { $0.id == id }),
               !FileManager.default.fileExists(atPath: root(entry) + "/.git") {
                pokedGit.insert(id)
            }
        }
        scanAll()
        var changedLocally = false
        for entry in config.entries where entry.enabled && entry.copiesFiles {
            guard var theirs = remote.manifests[entry.id] else { continue }
            theirs = theirs.filter { !isLoginFile(entry, path: $0.key) }
            let (applied, failed) = await apply(
                entry: entry, actions: SyncPlanner.plan(local: manifests[entry.id] ?? [:], remote: theirs),
                peer: peer, rewriteHome: true)
            if applied > 0 { changedLocally = true }
            let files = (manifests[entry.id] ?? [:]).values.filter { !$0.deleted }.count
            if let failed {
                setStatus(entry, .warning, failed, count: files)
            } else {
                let note = applied > 0 ? "took \(applied) change\(applied == 1 ? "" : "s") from \(peer.machine.name)" : "in sync with \(peer.machine.name)"
                setStatus(entry, .ok, note, count: files, synced: true)
            }
        }
        if changedLocally {
            lastScan = .distantPast
            // The peer pulls back at once and sees its versions arrived.
            await transport.notify(peer: peer, machineId: identity.id, what: "mirror")
        }
        for entry in config.entries where entry.enabled && entry.mode == .optmem {
            guard remote.optmemHome.contains(entry.id), let theirs = remote.manifests[entry.id] else { continue }
            await follow(entry: entry, home: theirs, peer: peer)
        }
    }

    /// Runs `actions` against the disk; returns how many changed it and the
    /// first failure.
    private func apply(entry: SyncEntry, actions: [SyncAction], peer: SyncPeer, rewriteHome: Bool) async -> (Int, String?) {
        let applier = SyncApplier(home: home, rewriteHome: rewriteHome, jsonKeys: entry.mode == .json ? entry.keys : nil)
        let rootPath = root(entry)
        var applied = 0
        var failure: String?
        var missing: String?
        let planned = manifests[entry.id] ?? [:]
        for action in actions {
            switch action {
            case .adopt(let path, _):
                manifests[entry.id]?[path]?.synced = true
            case .delete(let path, let remote):
                // A settings file removed on a peer is never removed here.
                if entry.mode == .json { continue }
                guard manifests[entry.id]?[path] == planned[path] else { continue }
                manifests[entry.id, default: [:]][path] = applier.delete(root: rootPath, rel: path, remote: remote)
                applied += 1
            case .fetch(let path, let remote, let keepPrevious):
                var content: Data?
                if remote.kind == .file {
                    do {
                        content = try await transport.file(peer: peer, entryId: entry.id, path: path)
                    } catch {
                        failure = failure ?? "\(path): \(error.localizedDescription)"
                        continue
                    }
                }
                // A local edit that landed while the file travelled wins this round.
                guard manifests[entry.id]?[path] == planned[path] else { continue }
                do {
                    manifests[entry.id, default: [:]][path] = try applier.write(
                        root: rootPath, rel: path, remote: remote, content: content, keepPrevious: keepPrevious)
                    applied += 1
                } catch SyncApplyError.missing(let path) {
                    missing = missing ?? SyncApplyError.missing(path).localizedDescription
                } catch {
                    failure = failure ?? error.localizedDescription
                }
            }
        }
        if !actions.isEmpty { saveManifest(entry.id) }
        return (applied, failure ?? missing)
    }

    // MARK: - Git

    private func syncGit(only: Set<String>?) async {
        for entry in config.entries where entry.enabled && entry.mode == .git {
            if let only, !only.contains(entry.id) { continue }
            let outcome = await git.sync(path: root(entry), url: entry.remoteURL ?? learnedURLs[entry.id])
            gitInfo[entry.id] = outcome.info
            setStatus(entry, outcome.level, outcome.message, synced: outcome.level == .ok)
            if outcome.pushed { await notifyPeers(what: "git:\(entry.id)") }
        }
    }

    // MARK: - OptMem

    private var lastPeers: [SyncPeer] = []

    enum OptmemRole: Equatable {
        case home
        case follower(SyncPeer)
        case unknown(String)
    }

    /// Who keeps the memory: the machine the entry names, else the
    /// always-on master (this one when it is).
    func optmemRole(_ entry: SyncEntry, peers: [SyncPeer]) -> OptmemRole {
        if let name = entry.home?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            if name == identity.id || name.lowercased() == identity.name.lowercased() { return .home }
            if let peer = peers.first(where: { $0.matches(name) }) { return .follower(peer) }
            return .unknown("no peer named \(name)")
        }
        if identity.alwaysOn == true { return .home }
        if let peer = peers.filter({ $0.machine.alwaysOn == true }).min(by: { $0.machine.id < $1.machine.id }) {
            return .follower(peer)
        }
        return peers.isEmpty ? .home : .unknown("no always-on peer yet")
    }

    func isLocalOptmemHome(_ entry: SyncEntry, peers: [SyncPeer]) -> Bool {
        optmemRole(entry, peers: peers) == .home
    }

    static func homeConfigPath(_ root: String) -> String { root + "/home.json" }

    /// memo's forwarding config on a follower: where the home is.
    struct HomeConfig: Codable, Equatable {
        var machine: String
        var url: String
        var token: String
        var ssh: String?
        var managedBy: String = "kanban-code"
    }

    private func optmemRound(peers: [SyncPeer]) async {
        lastPeers = peers
        for entry in config.entries where entry.enabled && entry.mode == .optmem {
            let rootPath = root(entry)
            guard FileManager.default.fileExists(atPath: rootPath) else {
                setStatus(entry, .info, "no OptMem memory on this machine")
                continue
            }
            switch optmemRole(entry, peers: peers) {
            case .home:
                removeHomeConfig(rootPath)
                let count = memoryCount(manifests[entry.id]?["memory/LOG.txt"])
                setStatus(entry, .ok, "this machine is the home of the memory", count: count)
            case .unknown(let why):
                setStatus(entry, .info, why)
            case .follower(let peer):
                let spool = OptmemSpool(optmemRoot: rootPath)
                let queued = spool.pending().count
                if queued > 0, peer.online, homeConfigured(rootPath) {
                    let transport = self.transport
                    let result = await spool.replay { request in
                        try await transport.optmemRun(url: peer.url, token: peer.token, request: request)
                    }
                    if result.sent > 0 {
                        KanbanCodeLog.info("sync", "replayed \(result.sent) memo commands to \(peer.machine.name)")
                        pokedPeers.insert(peer.machine.id)
                    }
                }
                let left = spool.pending().count
                if left > 0 {
                    setStatus(entry, .warning, "\(left) memo command\(left == 1 ? "" : "s") queued until \(peer.machine.name) answers")
                } else if queued > 0 || statuses[entry.id] == nil {
                    setStatus(entry, .info, "following the memory on \(peer.machine.name)")
                }
            }
        }
    }

    private func memoryCount(_ log: SyncItem?) -> Int? {
        guard let size = log?.size else { return nil }
        return size / 320
    }

    private func homeConfigured(_ rootPath: String) -> Bool {
        FileManager.default.fileExists(atPath: Self.homeConfigPath(rootPath))
    }

    private func removeHomeConfig(_ rootPath: String) {
        let path = Self.homeConfigPath(rootPath)
        guard let data = FileManager.default.contents(atPath: path),
              let config = try? JSONDecoder().decode(HomeConfig.self, from: data),
              config.managedBy == "kanban-code"
        else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    private func writeHomeConfig(_ rootPath: String, entry: SyncEntry, peer: SyncPeer) {
        let wanted = HomeConfig(machine: peer.machine.name, url: peer.url, token: peer.token,
                                ssh: entry.ssh.flatMap { $0.isEmpty ? nil : $0 })
        let path = Self.homeConfigPath(rootPath)
        if let data = FileManager.default.contents(atPath: path),
           let current = try? JSONDecoder().decode(HomeConfig.self, from: data), current == wanted { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(wanted) else { return }
        Self.writeAtomically(data, to: path, mode: 0o600)
    }

    /// A follower copies the home's memory, one way. A home with fewer
    /// memories than this copy was never seeded: nothing is touched and
    /// memo keeps writing here until it is.
    private func follow(entry: SyncEntry, home remote: [String: SyncItem], peer: SyncPeer) async {
        let rootPath = root(entry)
        guard case .follower(let expected) = optmemRole(entry, peers: lastPeers.isEmpty ? [peer] : lastPeers),
              expected.machine.id == peer.machine.id
        else { return }
        let local = scanOptmem(entry, previous: manifests[entry.id] ?? [:])
        manifests[entry.id] = local
        let theirs = remote["memory/LOG.txt"]?.size ?? 0
        let ours = local["memory/LOG.txt"].flatMap { $0.deleted ? nil : $0.size } ?? 0
        if remote["memory/LOG.txt"] == nil || theirs < ours {
            setStatus(entry, .warning,
                      "\(peer.machine.name) has \(theirs / 320) memories and this machine \(ours / 320): seed the home from here first")
            return
        }
        writeHomeConfig(rootPath, entry: entry, peer: peer)
        let (applied, failed) = await apply(
            entry: entry, actions: SyncPlanner.follow(local: local, home: remote), peer: peer, rewriteHome: false)
        if let failed {
            setStatus(entry, .warning, failed)
        } else {
            let queued = OptmemSpool(optmemRoot: rootPath).pending().count
            if queued == 0 {
                let note = applied > 0 ? "following \(peer.machine.name), took \(applied) file\(applied == 1 ? "" : "s")" : "following \(peer.machine.name)"
                setStatus(entry, .ok, note, count: theirs / 320, synced: true)
            }
        }
    }

    /// `POST /v1/optmem/run` on the home: runs memo here and hands back what
    /// it printed. A request id seen before gets the stored answer.
    public func optmemRun(_ request: OptmemRunRequest) async -> Result<OptmemRunResult, SyncTransportError> {
        guard let entry = config.entries.first(where: { $0.enabled && $0.mode == .optmem && isLocalOptmemHome($0, peers: lastPeers) }) else {
            return .failure(.http(409, "\(identity.name) is not the OptMem home"))
        }
        if let done = optmemApplied[request.id] { return .success(done) }
        let allowed: Set<String> = ["note", "nap", "forget", "wake", "recall", "zoom"]
        guard let command = request.argv.first, allowed.contains(command) else {
            return .failure(.http(400, "memo \(request.argv.first ?? "") is not forwarded"))
        }
        let rootPath = root(entry)
        let memo = rootPath + "/memo"
        guard FileManager.default.isExecutableFile(atPath: memo) else {
            return .failure(.http(409, "no memo at \(memo)"))
        }
        var env = ShellCommand.loginEnvironment
        env["OPTMEM_NO_FORWARD"] = "1"
        env["MEMORY_DIR"] = rootPath + "/memory"
        if let date = request.date, date.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
            env["OPTMEM_NOTE_DATE"] = date
        }
        let result: OptmemRunResult
        do {
            let out = try await ShellCommand.run(memo, arguments: Array(request.argv), environment: env, timeout: 60)
            result = OptmemRunResult(status: out.exitCode, stdout: out.stdout, stderr: out.stderr)
        } catch {
            return .failure(.http(500, "memo failed: \(error)"))
        }
        let writes: Set<String> = ["note", "nap", "forget"]
        if writes.contains(command) {
            remember(request.id, result)
            let refresh = rootPath + "/refresh-wake.sh"
            if FileManager.default.isExecutableFile(atPath: refresh) {
                _ = try? await ShellCommand.run(refresh, environment: ShellCommand.loginEnvironment, timeout: 60)
            }
            manifests[entry.id] = scanOptmem(entry, previous: manifests[entry.id] ?? [:])
            await notifyPeers(what: "optmem")
        }
        return .success(result)
    }

    private static let appliedLimit = 500

    private func remember(_ id: String, _ result: OptmemRunResult) {
        optmemApplied[id] = result
        optmemAppliedOrder.append(id)
        while optmemAppliedOrder.count > Self.appliedLimit {
            optmemApplied[optmemAppliedOrder.removeFirst()] = nil
        }
        let entries = optmemAppliedOrder.compactMap { id in optmemApplied[id].map { AppliedEntry(id: id, result: $0) } }
        if let data = try? JSONEncoder().encode(entries) {
            Self.writeAtomically(data, to: kanbanHome + "/sync/optmem-applied.json")
        }
    }

    private struct AppliedEntry: Codable {
        var id: String
        var result: OptmemRunResult
    }

    private static func loadApplied(kanbanHome: String) -> [AppliedEntry] {
        guard let data = FileManager.default.contents(atPath: kanbanHome + "/sync/optmem-applied.json"),
              let entries = try? JSONDecoder().decode([AppliedEntry].self, from: data)
        else { return [] }
        return entries
    }
}
