import Foundation

// MARK: - Configuration

/// How one Settings > Sync entry keeps a path the same on every machine.
public enum SyncEntryMode: String, Codable, Sendable, CaseIterable {
    /// A git clone: cloned where missing, fast-forwarded, local commits pushed.
    case git
    /// Files and folders copied between machines, newest version of each file wins.
    case mirror
    /// Named top-level keys of a JSON file, newest version wins. The rest of
    /// the file stays each machine's own: for a settings file that also
    /// holds what belongs to one machine (logins, window state).
    case json
    /// An OptMem memory with one home machine: other machines forward writes
    /// to the home and read a mirrored copy.
    case optmem
}

/// One path Kanban Code keeps in step across the peer machines.
public struct SyncEntry: Codable, Sendable, Equatable, Identifiable, Hashable {
    /// `<mode>:<path>`, so two machines that never talked agree on the id of
    /// the same default entry.
    public var id: String { "\(mode.rawValue):\(path)" }
    public var mode: SyncEntryMode
    /// The path with `~` for the home folder, e.g. `~/.claude/CLAUDE.md`.
    public var path: String
    /// Glob patterns left out of a mirror: a name (`*.log`), a folder (`.trash/`)
    /// or a path inside the entry (`synced/`).
    public var excludes: [String]
    /// json: the top-level keys kept the same on every machine.
    public var keys: [String]
    /// The path on a machine that keeps it somewhere else, by machine name
    /// (any case) or id, e.g. `["box": "~/.config/other/config.json"]`.
    /// A machine not named here uses `path`.
    public var paths: [String: String]
    /// git: the origin to clone from on a machine that has no clone.
    public var remoteURL: String?
    /// optmem: machine name or id of the home; nil means the always-on master.
    public var home: String?
    /// optmem: `user@host` memo falls back to over ssh when the home's API does not answer.
    public var ssh: String?
    public var enabled: Bool

    public init(
        mode: SyncEntryMode,
        path: String,
        excludes: [String] = [],
        keys: [String] = [],
        paths: [String: String] = [:],
        remoteURL: String? = nil,
        home: String? = nil,
        ssh: String? = nil,
        enabled: Bool = true
    ) {
        self.mode = mode
        self.path = path
        self.excludes = excludes
        self.keys = keys
        self.paths = paths
        self.remoteURL = remoteURL
        self.home = home
        self.ssh = ssh
        self.enabled = enabled
    }

    enum CodingKeys: String, CodingKey {
        case id, mode, path, excludes, keys, paths, remoteURL, home, ssh, enabled
    }

    /// Whether the entry copies files between machines (whole, or their named keys).
    public var copiesFiles: Bool { mode == .mirror || mode == .json }

    /// The entry's path on `machine`.
    public func path(on machine: MachineIdentity) -> String {
        if let own = paths[machine.id] { return own }
        let name = machine.name.lowercased()
        return paths.first { $0.key.lowercased() == name }?.value ?? path
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decode(SyncEntryMode.self, forKey: .mode)
        path = try c.decode(String.self, forKey: .path)
        excludes = (try? c.decodeIfPresent([String].self, forKey: .excludes)) ?? []
        keys = (try? c.decodeIfPresent([String].self, forKey: .keys)) ?? []
        paths = (try? c.decodeIfPresent([String: String].self, forKey: .paths)) ?? [:]
        remoteURL = try? c.decodeIfPresent(String.self, forKey: .remoteURL)
        home = try? c.decodeIfPresent(String.self, forKey: .home)
        ssh = try? c.decodeIfPresent(String.self, forKey: .ssh)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(mode, forKey: .mode)
        try c.encode(path, forKey: .path)
        if !excludes.isEmpty { try c.encode(excludes, forKey: .excludes) }
        if !keys.isEmpty { try c.encode(keys, forKey: .keys) }
        if !paths.isEmpty { try c.encode(paths, forKey: .paths) }
        try c.encodeIfPresent(remoteURL, forKey: .remoteURL)
        try c.encodeIfPresent(home, forKey: .home)
        try c.encodeIfPresent(ssh, forKey: .ssh)
        try c.encode(enabled, forKey: .enabled)
    }
}

/// Settings > Sync, kept in `~/.kanban-code/sync.json`. The copy with the
/// newest `updatedAt` wins across machines, so the box follows the entries
/// edited on the Mac.
public struct SyncConfig: Codable, Sendable, Equatable {
    /// Seconds since 1970 of the last edit; 0 for the untouched defaults.
    public var updatedAt: Double
    public var entries: [SyncEntry]

    public init(updatedAt: Double = 0, entries: [SyncEntry]) {
        self.updatedAt = updatedAt
        self.entries = entries
    }

    /// Never synced by a mirror: backups, temp files, per-machine settings,
    /// logs, and the credentials the login sync already carries.
    public static let defaultExcludes = [
        "*.bak*", "*.tmp", "settings.local.json", ".credentials.json", ".trash/", "*.log",
        "*.sync-prev", ".DS_Store",
    ]

    /// Exclude patterns, relative to a mirror at `entryPath` (`~/...`), for
    /// the login files the login sync owns. A mirror never carries them,
    /// whatever its excludes say: two mechanisms writing one login make the
    /// copies fight.
    public static func loginFileExcludes(entryPath: String) -> [String] {
        var root = entryPath
        while root.count > 1, root.hasSuffix("/") { root.removeLast() }
        return AssistantLoginKind.allCases.compactMap { kind in
            let file = "~/" + kind.remoteRelativePath
            if root == "~" { return kind.remoteRelativePath }
            guard file.hasPrefix(root + "/") else { return nil }
            return String(file.dropFirst(root.count + 1))
        }
    }

    /// Whether the mirror at `entryPath` is itself a login file.
    public static func isLoginFile(entryPath: String) -> Bool {
        AssistantLoginKind.allCases.contains { "~/" + $0.remoteRelativePath == entryPath }
    }

    public static let defaults = SyncConfig(entries: [
        SyncEntry(mode: .git, path: "~/Projects/skills"),
        SyncEntry(mode: .git, path: "~/Projects/skills-private"),
        SyncEntry(mode: .mirror, path: "~/.claude/CLAUDE.md", excludes: defaultExcludes),
        SyncEntry(mode: .mirror, path: "~/.claude/settings.json", excludes: defaultExcludes),
        SyncEntry(mode: .mirror, path: "~/.claude/commands", excludes: defaultExcludes),
        SyncEntry(mode: .mirror, path: "~/.claude/agents", excludes: defaultExcludes),
        // `synced/` is Claude's own per-account copy of claude.ai skills.
        SyncEntry(mode: .mirror, path: "~/.claude/skills", excludes: defaultExcludes + ["synced/"]),
        SyncEntry(mode: .mirror, path: "~/.codex/config.toml", excludes: defaultExcludes),
        SyncEntry(mode: .mirror, path: "~/.codex/AGENTS.md", excludes: defaultExcludes),
        SyncEntry(mode: .mirror, path: "~/.codex/skills", excludes: defaultExcludes + [".system/"]),
        SyncEntry(mode: .mirror, path: "~/.optmem/memo", excludes: defaultExcludes),
        SyncEntry(mode: .mirror, path: "~/.optmem/refresh-wake.sh", excludes: defaultExcludes),
        SyncEntry(mode: .optmem, path: "~/.optmem"),
    ])
}

// MARK: - Manifest

/// The last known version of one file or symlink of a mirror, as this
/// machine sees it. A version is its content hash; `mtime` and `origin`
/// order two different versions (newest wins, origin breaks a tie).
public struct SyncItem: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case file, symlink
    }

    public var kind: Kind
    /// SHA-256 of the content with the home folder replaced by a marker (so
    /// the Mac and Linux copies of one file hash the same), plus `+x` when
    /// executable. Empty for a deletion.
    public var hash: String
    /// When this version was made: the file's modification time, or the
    /// moment the deletion was seen.
    public var mtime: Double
    /// Machine id that made this version.
    public var origin: String
    public var deleted: Bool
    /// Permission bits.
    public var mode: Int
    /// Symlink target with the home folder replaced by the marker.
    public var target: String?
    /// A deletion: the hash of the version that was deleted, so a peer
    /// holding exactly that version deletes it even if it never synced it.
    public var previousHash: String?
    /// This path matched a peer's version at least once. A path that never
    /// did keeps its local copy as `<name>.sync-prev` when a peer's newer
    /// version replaces it, and is never deleted by a peer.
    public var synced: Bool
    /// Size and modification time of the file on this disk when it was last
    /// hashed, to skip hashing unchanged files.
    public var size: Int?
    public var fileMtime: Double?

    public init(
        kind: Kind = .file,
        hash: String,
        mtime: Double,
        origin: String,
        deleted: Bool = false,
        mode: Int = 0o644,
        target: String? = nil,
        previousHash: String? = nil,
        synced: Bool = false,
        size: Int? = nil,
        fileMtime: Double? = nil
    ) {
        self.kind = kind
        self.hash = hash
        self.mtime = mtime
        self.origin = origin
        self.deleted = deleted
        self.mode = mode
        self.target = target
        self.previousHash = previousHash
        self.synced = synced
        self.size = size
        self.fileMtime = fileMtime
    }

    /// Same content (or both deleted), whatever made it.
    public func sameVersion(as other: SyncItem) -> Bool {
        deleted == other.deleted && (deleted || (kind == other.kind && hash == other.hash))
    }

    /// Whether this version beats `other`: newer, or as new and made by the
    /// machine with the larger id, so every machine picks the same winner.
    public func isNewer(than other: SyncItem) -> Bool {
        if mtime != other.mtime { return mtime > other.mtime }
        return origin > other.origin
    }
}

// MARK: - Wire format

/// A git entry as its machine sees it.
public struct SyncGitInfo: Codable, Sendable, Equatable {
    public var url: String?
    public var head: String?
    public var branch: String?

    public init(url: String? = nil, head: String? = nil, branch: String? = nil) {
        self.url = url
        self.head = head
        self.branch = branch
    }
}

/// Body of `GET /v1/sync/state`: everything a peer needs to pull.
public struct SyncStateResponse: Codable, Sendable, Equatable {
    public var machine: MachineIdentity
    public var config: SyncConfig
    /// Mirror manifests (and the optmem memory on its home), by entry id.
    public var manifests: [String: [String: SyncItem]]
    public var git: [String: SyncGitInfo]
    /// optmem entry ids this machine is the home of.
    public var optmemHome: [String]

    public init(
        machine: MachineIdentity,
        config: SyncConfig,
        manifests: [String: [String: SyncItem]],
        git: [String: SyncGitInfo],
        optmemHome: [String]
    ) {
        self.machine = machine
        self.config = config
        self.manifests = manifests
        self.git = git
        self.optmemHome = optmemHome
    }
}

/// Body of `POST /v1/optmem/run`: one memo command a non-home machine forwards.
public struct OptmemRunRequest: Codable, Sendable, Equatable {
    /// Unique per command, so a replay after a lost answer runs it once.
    public var id: String
    /// memo's arguments, e.g. `["note", "..."]`.
    public var argv: [String]
    /// The day the command was typed (`YYYY-MM-DD`): a note replayed later keeps it.
    public var date: String?

    public init(id: String, argv: [String], date: String? = nil) {
        self.id = id
        self.argv = argv
        self.date = date
    }
}

/// What memo printed on the home.
public struct OptmemRunResult: Codable, Sendable, Equatable {
    public var status: Int32
    public var stdout: String
    public var stderr: String

    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

// MARK: - Status

/// How one entry is doing on this machine, for Settings > Sync.
public struct SyncEntryStatus: Sendable, Equatable {
    public enum Level: String, Sendable {
        case ok, info, warning, error
    }

    public var entryId: String
    public var level: Level
    public var message: String
    public var lastSync: Date?
    /// Files (mirror) or memories waiting to replay (optmem).
    public var count: Int?

    public init(entryId: String, level: Level = .info, message: String, lastSync: Date? = nil, count: Int? = nil) {
        self.entryId = entryId
        self.level = level
        self.message = message
        self.lastSync = lastSync
        self.count = count
    }
}
