#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if canImport(Glibc)
import Glibc
#endif

// MARK: - Home folder mapping

/// Home folder rewriting between machines: `/Users/rchaves` on the Mac is
/// `/root` on the box. What travels (and what is hashed) has the home
/// replaced by a marker, so both copies of one file hash the same and an
/// unchanged file never bounces between machines.
public enum SyncHome {
    public static let marker = "{{KANBAN_SYNC_HOME}}"
    /// Text files larger than this travel as they are.
    static let maxRewriteBytes = 4 * 1024 * 1024

    /// `~/x` or `~` as an absolute path under `home`.
    public static func expand(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + String(path.dropFirst(1)) }
        return path
    }

    /// Whether `data` is UTF-8 text worth rewriting.
    static func isText(_ data: Data) -> Bool {
        guard data.count <= maxRewriteBytes, !data.contains(0) else { return false }
        return String(data: data, encoding: .utf8) != nil
    }

    /// `text` with every standalone occurrence of `home` replaced by the marker.
    /// An occurrence inside a longer path or name (`/x/root`, `/rootfs`) stays.
    public static func normalize(_ text: String, home: String) -> String {
        guard !home.isEmpty, text.contains(home) else { return text }
        var out = ""
        var rest = text[...]
        while let r = rest.range(of: home) {
            let before: Character? = r.lowerBound == text.startIndex ? nil : text[text.index(before: r.lowerBound)]
            let after: Character? = r.upperBound == text.endIndex ? nil : text[r.upperBound]
            let standalone = !(before.map { isNameChar($0) || $0 == "/" } ?? false)
                && !(after.map(isNameChar) ?? false)
            out += rest[..<r.lowerBound]
            out += standalone ? marker : String(text[r])
            rest = text[r.upperBound...]
        }
        out += rest
        return out
    }

    /// The marker back as this machine's home.
    public static func localize(_ text: String, home: String) -> String {
        text.replacingOccurrences(of: marker, with: home)
    }

    public static func normalize(_ data: Data, home: String) -> Data {
        guard isText(data), let text = String(data: data, encoding: .utf8), text.contains(home) else { return data }
        return Data(normalize(text, home: home).utf8)
    }

    public static func localize(_ data: Data, home: String) -> Data {
        guard isText(data), let text = String(data: data, encoding: .utf8), text.contains(marker) else { return data }
        return Data(localize(text, home: home).utf8)
    }

    private static func isNameChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "." || c == "_" || c == "-"
    }
}

// MARK: - Excludes

/// Exclude patterns of a mirror entry. `*.log` matches a name anywhere,
/// `.trash/` a folder anywhere, `a/b.txt` a path inside the entry.
public struct SyncExcludes: Sendable {
    let patterns: [String]

    public init(_ patterns: [String]) {
        self.patterns = patterns.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    public func excludes(relativePath: String, isDirectory: Bool) -> Bool {
        let name = (relativePath as NSString).lastPathComponent
        for pattern in patterns {
            var p = pattern
            if p.hasSuffix("/") {
                guard isDirectory else { continue }
                p.removeLast()
            }
            if Self.match(p, name) || Self.match(p, relativePath) { return true }
        }
        return false
    }

    static func match(_ pattern: String, _ string: String) -> Bool {
        fnmatch(pattern, string, 0) == 0
    }
}

// MARK: - Hashing

enum SyncHash {
    static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func file(_ normalized: Data, executable: Bool) -> String {
        hex(normalized) + (executable ? "+x" : "")
    }

    static func symlink(_ normalizedTarget: String) -> String {
        hex(Data(("symlink:" + normalizedTarget).utf8))
    }
}

// MARK: - Scanning

/// Walks a mirror entry on disk and brings its manifest up to date: a new
/// or edited file becomes a version made by this machine, a missing one a
/// deletion. Files whose size and modification time did not move are not
/// read again.
public struct SyncScanner: Sendable {
    public var home: String
    public var machineId: String
    public var rewriteHome: Bool
    /// Files larger than this are left out.
    public var maxFileBytes: Int = 32 * 1024 * 1024
    /// Deletions older than this are forgotten.
    public var tombstoneTTL: Double = 30 * 24 * 3600
    /// A `json` entry: each of these top-level keys of the file is a
    /// version of its own, named by the key, so the newest value of every
    /// key wins on its own.
    public var jsonKeys: [String]?

    public init(home: String, machineId: String, rewriteHome: Bool = true, jsonKeys: [String]? = nil) {
        self.home = home
        self.machineId = machineId
        self.rewriteHome = rewriteHome
        self.jsonKeys = jsonKeys
    }

    /// One file or symlink found on disk.
    struct Found {
        var kind: SyncItem.Kind
        var size: Int
        var fileMtime: Double
        var mode: Int
    }

    /// The manifest of `root` (a folder, file or symlink), from `previous`.
    /// `only` limits a folder to these top-level names.
    public func scan(
        root: String,
        excludes: SyncExcludes,
        previous: [String: SyncItem],
        only: Set<String>? = nil,
        now: Double = Date().timeIntervalSince1970
    ) -> [String: SyncItem] {
        if let jsonKeys { return scanKeys(path: root, keys: jsonKeys, previous: previous, now: now) }
        var found: [String: Found] = [:]
        collect(root: root, excludes: excludes, only: only, into: &found)

        var out: [String: SyncItem] = [:]
        for (rel, f) in found {
            let path = rel.isEmpty ? root : root + "/" + rel
            let prev = previous[rel]
            if let prev, !prev.deleted, prev.kind == f.kind, prev.size == f.size, prev.fileMtime == f.fileMtime,
               prev.mode == f.mode {
                out[rel] = prev
                continue
            }
            guard let hashed = hash(path: path, found: f) else {
                // There but not readable now: the last version stands, it
                // is not a deletion.
                if let prev { out[rel] = prev }
                continue
            }
            if let prev, !prev.deleted, prev.kind == f.kind, prev.hash == hashed.hash {
                var same = prev
                same.size = f.size
                same.fileMtime = f.fileMtime
                same.mode = f.mode
                out[rel] = same
                continue
            }
            out[rel] = SyncItem(
                kind: f.kind,
                hash: hashed.hash,
                mtime: f.fileMtime,
                origin: machineId,
                mode: f.mode,
                target: hashed.target,
                synced: prev?.synced ?? false,
                size: f.size,
                fileMtime: f.fileMtime
            )
        }
        for (rel, prev) in previous where out[rel] == nil {
            if prev.deleted {
                if now - prev.mtime < tombstoneTTL { out[rel] = prev }
                continue
            }
            // Excluded now: forget it rather than delete it everywhere.
            if isExcluded(rel: rel, excludes: excludes, only: only) { continue }
            out[rel] = SyncItem(
                kind: prev.kind, hash: "", mtime: max(now, prev.mtime), origin: machineId,
                deleted: true, mode: prev.mode, previousHash: prev.hash, synced: prev.synced
            )
        }
        return out
    }

    /// The manifest of a `json` entry: one item per named key. A key the
    /// file drops becomes a deletion of the value it had. A missing file,
    /// or one that is not a JSON object right now (caught half written),
    /// leaves every version as it was.
    func scanKeys(path: String, keys: [String], previous: [String: SyncItem], now: Double) -> [String: SyncItem] {
        let named = Set(keys)
        var out = previous.filter { named.contains($0.key) }
        guard let info = Self.lstat(path), info.kind == .file, info.size <= maxFileBytes,
              let data = FileManager.default.contents(atPath: path),
              let values = SyncJSONKeys.values(of: data, keys: keys)
        else { return out }
        for key in Set(keys).sorted() {
            let prev = out[key]
            // A version made here is newer than the one it replaces, even
            // when that one came from a peer whose clock runs ahead.
            let mtime = max(info.mtime, (prev?.mtime ?? 0) + 0.001)
            if let value = values[key] {
                let hash = SyncHash.file(rewriteHome ? SyncHome.normalize(value, home: home) : value, executable: false)
                if let prev, !prev.deleted, prev.hash == hash { continue }
                out[key] = SyncItem(
                    kind: .file, hash: hash, mtime: prev == nil ? info.mtime : mtime, origin: machineId,
                    mode: info.mode, synced: prev?.synced ?? false, size: info.size, fileMtime: info.mtime
                )
            } else if let prev {
                if prev.deleted {
                    if now - prev.mtime >= tombstoneTTL { out[key] = nil }
                    continue
                }
                out[key] = SyncItem(
                    kind: .file, hash: "", mtime: mtime, origin: machineId, deleted: true,
                    mode: prev.mode, previousHash: prev.hash, synced: prev.synced
                )
            }
        }
        return out
    }

    func isExcluded(rel: String, excludes: SyncExcludes, only: Set<String>?) -> Bool {
        let parts = rel.split(separator: "/").map(String.init)
        if let only, let first = parts.first, !only.contains(first) { return true }
        for i in parts.indices {
            let sub = parts[0...i].joined(separator: "/")
            if excludes.excludes(relativePath: sub, isDirectory: i < parts.count - 1) { return true }
        }
        return false
    }

    /// The hash (and symlink target) of what is at `path` now.
    func hash(path: String, found f: Found) -> (hash: String, target: String?)? {
        switch f.kind {
        case .symlink:
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { return nil }
            let normalized = rewriteHome ? SyncHome.normalize(target, home: home) : target
            return (SyncHash.symlink(normalized), normalized)
        case .file:
            guard let data = travelling(path) else { return nil }
            return (SyncHash.file(data, executable: f.mode & 0o111 != 0), nil)
        }
    }

    /// The content a peer receives for `rel`: the file with the home
    /// marked, or for a `json` entry the value of the key `rel` names.
    public func content(root: String, rel: String) -> Data? {
        if let jsonKeys {
            guard jsonKeys.contains(rel), let data = FileManager.default.contents(atPath: root),
                  let value = SyncJSONKeys.values(of: data, keys: [rel])?[rel]
            else { return nil }
            return rewriteHome ? SyncHome.normalize(value, home: home) : value
        }
        return travelling(rel.isEmpty ? root : root + "/" + rel)
    }

    private func travelling(_ path: String) -> Data? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return rewriteHome ? SyncHome.normalize(data, home: home) : data
    }

    static func lstat(_ path: String) -> (kind: SyncItem.Kind?, isDirectory: Bool, size: Int, mtime: Double, mode: Int)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let type = attrs[.type] as? FileAttributeType
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
        switch type {
        case .typeSymbolicLink: return (.symlink, false, size, mtime, mode)
        case .typeRegular: return (.file, false, size, mtime, mode)
        case .typeDirectory: return (nil, true, size, mtime, mode)
        default: return (nil, false, size, mtime, mode)
        }
    }

    private func collect(root: String, excludes: SyncExcludes, only: Set<String>?, into found: inout [String: Found]) {
        guard let top = Self.lstat(root) else { return }
        if let kind = top.kind {
            if kind == .file && top.size > maxFileBytes { return }
            found[""] = Found(kind: kind, size: top.size, fileMtime: top.mtime, mode: top.mode)
            return
        }
        guard top.isDirectory else { return }
        walk(dir: root, rel: "", excludes: excludes, only: only, into: &found)
    }

    private func walk(dir: String, rel: String, excludes: SyncExcludes, only: Set<String>?, into found: inout [String: Found]) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        for name in names {
            let childRel = rel.isEmpty ? name : rel + "/" + name
            if rel.isEmpty, let only, !only.contains(name) { continue }
            let path = dir + "/" + name
            guard let info = Self.lstat(path) else { continue }
            if excludes.excludes(relativePath: childRel, isDirectory: info.isDirectory) { continue }
            if info.isDirectory {
                walk(dir: path, rel: childRel, excludes: excludes, only: only, into: &found)
            } else if let kind = info.kind {
                if kind == .file && info.size > maxFileBytes { continue }
                found[childRel] = Found(kind: kind, size: info.size, fileMtime: info.mtime, mode: info.mode)
            }
        }
    }
}

// MARK: - Planning

/// One step that brings this machine to a peer's newer version of a path.
public enum SyncAction: Equatable, Sendable {
    /// Write the peer's version. `keepPrevious`: the local copy never synced,
    /// so it stays as `<name>.sync-prev` (once).
    case fetch(path: String, remote: SyncItem, keepPrevious: Bool)
    /// The peer deleted the path after the local version.
    case delete(path: String, remote: SyncItem)
    /// Same content on both sides: remember the path as synced.
    case adopt(path: String, remote: SyncItem)

    public var path: String {
        switch self {
        case .fetch(let p, _, _), .delete(let p, _), .adopt(let p, _): p
        }
    }
}

public enum SyncPlanner {
    /// What this machine does to take every newer version from a peer. The
    /// peer pulls from this machine the same way, so a path where the local
    /// version is newer needs nothing here.
    public static func plan(local: [String: SyncItem], remote: [String: SyncItem]) -> [SyncAction] {
        var actions: [SyncAction] = []
        for path in remote.keys.sorted() {
            guard let r = remote[path] else { continue }
            guard let l = local[path] else {
                if !r.deleted { actions.append(.fetch(path: path, remote: r, keepPrevious: false)) }
                continue
            }
            if l.sameVersion(as: r) {
                if !l.synced { actions.append(.adopt(path: path, remote: r)) }
                continue
            }
            guard r.isNewer(than: l) else { continue }
            if r.deleted {
                // A peer deletes only a version it saw: one the two machines
                // agreed on, or exactly the one it deleted.
                if l.synced || (r.previousHash == l.hash && !l.deleted) {
                    actions.append(.delete(path: path, remote: r))
                }
            } else {
                actions.append(.fetch(path: path, remote: r, keepPrevious: !l.synced && !l.deleted))
            }
        }
        return actions
    }

    /// One-way copy of a home's files (the optmem memory): every path whose
    /// content differs takes the home's version, whatever its age, and a
    /// path the home does not have goes.
    public static func follow(local: [String: SyncItem], home: [String: SyncItem]) -> [SyncAction] {
        var actions: [SyncAction] = []
        for path in home.keys.sorted() {
            guard let h = home[path], !h.deleted else { continue }
            if let l = local[path], !l.deleted, l.kind == h.kind, l.hash == h.hash { continue }
            actions.append(.fetch(path: path, remote: h, keepPrevious: false))
        }
        for path in local.keys.sorted() where !(local[path]?.deleted ?? true) {
            if home[path] == nil || home[path]?.deleted == true {
                actions.append(.delete(path: path, remote: home[path] ?? SyncItem(hash: "", mtime: 0, origin: "", deleted: true)))
            }
        }
        return actions
    }
}

// MARK: - Applying

public enum SyncApplyError: Error, LocalizedError, Equatable {
    case hashMismatch(String)
    case notAFile(String)
    case missing(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .hashMismatch(let p): "\(p) changed while it was copied"
        case .notAFile(let p): "\(p) is a folder here and a file on the peer"
        case .missing(let p): "\(p) is not on this machine; its keys are set once its program creates it"
        case .failed(let m): m
        }
    }
}

/// Writes a peer's versions to disk and returns the manifest item that
/// records them.
public struct SyncApplier: Sendable {
    public var home: String
    public var rewriteHome: Bool
    /// A `json` entry: `rel` names one of these top-level keys, and only
    /// that key of the file is written.
    public var jsonKeys: [String]?

    public init(home: String, rewriteHome: Bool = true, jsonKeys: [String]? = nil) {
        self.home = home
        self.rewriteHome = rewriteHome
        self.jsonKeys = jsonKeys
    }

    static func path(root: String, rel: String) -> String {
        rel.isEmpty ? root : root + "/" + rel
    }

    /// Writes `remote` at `rel`. `content` is the peer's normalized bytes
    /// (unused for a symlink).
    public func write(root: String, rel: String, remote: SyncItem, content: Data?, keepPrevious: Bool) throws -> SyncItem {
        if jsonKeys != nil {
            guard let content else { throw SyncApplyError.failed("no content for \(rel) in \(root)") }
            guard SyncHash.file(content, executable: false) == remote.hash else { throw SyncApplyError.hashMismatch(root) }
            let value = rewriteHome ? SyncHome.localize(content, home: home) : content
            return try writeKey(path: root, key: rel, value: value, remote: remote, keepPrevious: keepPrevious)
        }
        let fm = FileManager.default
        let path = Self.path(root: root, rel: rel)
        let parent = (path as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)

        let existing = SyncScanner.lstat(path)
        if existing?.isDirectory == true { throw SyncApplyError.notAFile(path) }
        if keepPrevious, existing != nil {
            let prev = path + ".sync-prev"
            if SyncScanner.lstat(prev) == nil {
                try fm.copyItem(atPath: path, toPath: prev)
            }
        }

        switch remote.kind {
        case .symlink:
            let target = remote.target.map { rewriteHome ? SyncHome.localize($0, home: home) : $0 } ?? ""
            if existing != nil { try fm.removeItem(atPath: path) }
            try fm.createSymbolicLink(atPath: path, withDestinationPath: target)
        case .file:
            guard let content else { throw SyncApplyError.failed("no content for \(path)") }
            let hash = SyncHash.file(content, executable: remote.mode & 0o111 != 0)
            guard hash == remote.hash else { throw SyncApplyError.hashMismatch(path) }
            let local = rewriteHome ? SyncHome.localize(content, home: home) : content
            let tmp = parent + "/.\((path as NSString).lastPathComponent).sync-tmp-\(getpid())"
            guard fm.createFile(atPath: tmp, contents: local, attributes: [.posixPermissions: remote.mode]) else {
                throw SyncApplyError.failed("cannot write \(tmp)")
            }
            try? fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: remote.mtime)], ofItemAtPath: tmp)
            if existing?.kind == .symlink { try fm.removeItem(atPath: path) }
            guard rename(tmp, path) == 0 else {
                try? fm.removeItem(atPath: tmp)
                throw SyncApplyError.failed("cannot move \(tmp) to \(path): \(String(cString: strerror(errno)))")
            }
        }

        var item = remote
        item.synced = true
        if let now = SyncScanner.lstat(path) {
            item.size = now.size
            item.fileMtime = now.mtime
            item.mode = now.mode
        }
        return item
    }

    /// Sets `key` of the JSON file at `path` to `value`, or removes it when
    /// `value` is nil. Every other key keeps its bytes and the file its
    /// permissions. Written through a temp file and a rename, and dropped
    /// when the file's program saved it meanwhile: that save stands and the
    /// next round merges into it.
    func writeKey(path: String, key: String, value: Data?, remote: SyncItem, keepPrevious: Bool) throws -> SyncItem {
        let fm = FileManager.default
        let existing = SyncScanner.lstat(path)
        guard existing?.kind == .file, let current = fm.contents(atPath: path) else { throw SyncApplyError.missing(path) }
        var projection = Data("{".utf8)
        if let value {
            guard let rawKey = try? JSONSerialization.data(withJSONObject: [key]) else { throw SyncApplyError.failed("bad key \(key)") }
            projection.append(rawKey.dropFirst().dropLast())
            projection.append(Data(":".utf8))
            projection.append(value)
        }
        projection.append(Data("}".utf8))
        guard let merged = SyncJSONKeys.merge(into: current, keys: [key], from: projection) else {
            throw SyncApplyError.failed("\(path) is not a JSON object")
        }
        if merged != current {
            if keepPrevious, SyncScanner.lstat(path + ".sync-prev") == nil {
                try fm.copyItem(atPath: path, toPath: path + ".sync-prev")
            }
            let parent = (path as NSString).deletingLastPathComponent
            let tmp = parent + "/.\((path as NSString).lastPathComponent).sync-tmp-\(getpid())"
            guard fm.createFile(atPath: tmp, contents: merged, attributes: [.posixPermissions: existing?.mode ?? 0o600]) else {
                throw SyncApplyError.failed("cannot write \(tmp)")
            }
            let now = SyncScanner.lstat(path)
            guard now?.size == existing?.size, now?.mtime == existing?.mtime else {
                try? fm.removeItem(atPath: tmp)
                throw SyncApplyError.hashMismatch(path)
            }
            guard rename(tmp, path) == 0 else {
                try? fm.removeItem(atPath: tmp)
                throw SyncApplyError.failed("cannot move \(tmp) to \(path): \(String(cString: strerror(errno)))")
            }
        }
        var item = remote
        item.synced = true
        if let now = SyncScanner.lstat(path) {
            item.size = now.size
            item.fileMtime = now.mtime
            if !remote.deleted { item.mode = now.mode }
        }
        return item
    }

    /// Removes `key` from the JSON file at `path`, as a peer removed it.
    public func deleteKey(path: String, key: String, remote: SyncItem) throws -> SyncItem {
        try writeKey(path: path, key: key, value: nil, remote: remote, keepPrevious: false)
    }

    /// Deletes `rel` and the folders it leaves empty, up to `root`.
    public func delete(root: String, rel: String, remote: SyncItem) -> SyncItem {
        let fm = FileManager.default
        let path = Self.path(root: root, rel: rel)
        if let info = SyncScanner.lstat(path), !info.isDirectory {
            try? fm.removeItem(atPath: path)
        }
        var dir = (path as NSString).deletingLastPathComponent
        while dir.count > root.count, dir.hasPrefix(root + "/") {
            guard let left = try? fm.contentsOfDirectory(atPath: dir), left.isEmpty else { break }
            try? fm.removeItem(atPath: dir)
            dir = (dir as NSString).deletingLastPathComponent
        }
        var item = remote
        item.synced = true
        item.size = nil
        item.fileMtime = nil
        return item
    }
}
