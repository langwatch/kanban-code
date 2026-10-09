#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import KanbanCodeRemoteKit

/// Where the vault's age identity lives: the Keychain on the Mac, a 0600
/// file on a headless master.
public protocol VaultKeyProvider: Sendable {
    func loadIdentity() throws -> Age.Identity?
    func saveIdentity(_ identity: Age.Identity) throws
}

/// The identity in a file only its owner reads (0600).
public struct FileVaultKeyProvider: VaultKeyProvider {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    public func loadIdentity() throws -> Age.Identity? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try Age.Identity(text: String(decoding: data, as: UTF8.self))
    }

    public func saveIdentity(_ identity: Age.Identity) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let text = "# Kanban Code vault identity. Recovery: age -d -i <this file> vault.age\n# public key: \(identity.recipient.text)\n\(identity.text)\n"
        try VaultFiles.writeAtomically(Data(text.utf8), to: path, mode: 0o600)
    }
}

/// An identity held in memory, for tests.
public final class MemoryVaultKeyProvider: VaultKeyProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var identity: Age.Identity?

    public init(_ identity: Age.Identity? = nil) {
        self.identity = identity
    }

    public func loadIdentity() throws -> Age.Identity? {
        lock.withLock { identity }
    }

    public func saveIdentity(_ identity: Age.Identity) throws {
        lock.withLock { self.identity = identity }
    }
}

/// `vault.age` holds the document plus an HMAC keyed from the identity.
/// Anyone with the public key can write an age file; only a holder of the
/// identity can write one a replica merges.
enum VaultSeal {
    private struct Sealed: Codable {
        var doc: String
        var auth: String
    }

    static func authKey(_ identity: Age.Identity) -> SymmetricKey {
        Age.hkdf(ikm: identity.rawKey, salt: Data("kanban-code-vault".utf8), info: "document-auth")
    }

    static func seal(_ docJSON: Data, identity: Age.Identity) throws -> Data {
        let mac = HMAC<SHA256>.authenticationCode(for: docJSON, using: authKey(identity))
        let wrapper = Sealed(doc: docJSON.base64EncodedString(), auth: Data(mac).base64EncodedString())
        return try Age.encrypt(try JSONEncoder().encode(wrapper), to: [identity.recipient])
    }

    static func open(_ file: Data, identity: Age.Identity) throws -> VaultDocument {
        let plain = try Age.decrypt(file, with: identity)
        let wrapper = try JSONDecoder().decode(Sealed.self, from: plain)
        guard let doc = Data(base64Encoded: wrapper.doc), let auth = Data(base64Encoded: wrapper.auth),
              HMAC<SHA256>.isValidAuthenticationCode(auth, authenticating: doc, using: authKey(identity))
        else { throw VaultError.invalid("the vault file was not written by a holder of the vault key") }
        return try JSONDecoder.vault.decode(VaultDocument.self, from: doc)
    }
}

enum VaultFiles {
    static func writeAtomically(_ data: Data, to path: String, mode: Int) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let tmp = dir + "/.\((path as NSString).lastPathComponent).\(UUID().uuidString).tmp"
        guard FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: mode]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(tmp, path) == 0 else {
            unlink(tmp)
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

public enum VaultError: Error, Equatable, CustomStringConvertible {
    case locked(String)
    case notFound(String)
    case invalid(String)

    public var description: String {
        switch self {
        case .locked(let why), .notFound(let why), .invalid(let why): why
        }
    }
}

/// The vault of one master, under `<kanban home>/vault/`:
///
///   vault.age     the secrets, age-encrypted to the vault identity
///   leases.json   card leases (names and dates, no values)
///   audit.jsonl   append-only release log of this machine, each line
///                 naming the hash of the one before
///   audit-mirror/ the logs of the peer masters, as they pushed them
///
/// Every master holding the identity can open the same `vault.age`; the
/// replicas converge with `VaultDocument.merged`.
public actor VaultStore {
    public let directory: String
    public let keys: any VaultKeyProvider
    private var document: VaultDocument?
    private var identity: Age.Identity?
    private var leases: [VaultLease]?
    private var rate = VaultRateCounter()
    private var lastAuditHash: String?
    /// Called after a line was added to the audit log.
    private var onAudit: (@Sendable () -> Void)?

    public init(directory: String, keys: any VaultKeyProvider) {
        self.directory = directory
        self.keys = keys
    }

    public static func defaultDirectory(kanbanHome: String) -> String {
        (kanbanHome as NSString).appendingPathComponent("vault")
    }

    var vaultPath: String { directory + "/vault.age" }
    var leasesPath: String { directory + "/leases.json" }
    var auditPath: String { directory + "/audit.jsonl" }
    var pendingPath: String { directory + "/pending.age" }
    var mirrorDirectory: String { directory + "/audit-mirror" }
    /// The file as it was before the first owner-only secret was sealed.
    var preSealBackupPath: String { directory + "/backup-before-owner-seal/vault.age" }

    // MARK: - Identity

    /// Creates the identity when the vault has none yet and no vault file
    /// exists (a file without its key must not be overwritten).
    @discardableResult
    public func ensureIdentity() throws -> Age.Identity {
        if let identity { return identity }
        if let loaded = try keys.loadIdentity() {
            identity = loaded
            return loaded
        }
        guard !FileManager.default.fileExists(atPath: vaultPath) else {
            throw VaultError.locked("vault.age exists but this machine has no vault key: import it first")
        }
        let fresh = Age.Identity.generate()
        try keys.saveIdentity(fresh)
        identity = fresh
        return fresh
    }

    /// The identity, or nil when this machine has none (it then keeps the
    /// encrypted replica without opening it).
    public func currentIdentity() -> Age.Identity? {
        if let identity { return identity }
        identity = try? keys.loadIdentity()
        return identity
    }

    public func importIdentity(_ new: Age.Identity) throws {
        if FileManager.default.fileExists(atPath: vaultPath), let data = FileManager.default.contents(atPath: vaultPath) {
            _ = try Age.decrypt(data, with: new)
        }
        try keys.saveIdentity(new)
        identity = new
        document = nil
    }

    public var isUnlocked: Bool { currentIdentity() != nil }

    // MARK: - Document

    func load() throws -> VaultDocument {
        if let document { return document }
        guard let data = FileManager.default.contents(atPath: vaultPath) else {
            let empty = VaultDocument()
            document = empty
            return empty
        }
        guard let identity = currentIdentity() else {
            throw VaultError.locked("this machine has no vault key")
        }
        let decoded = try VaultSeal.open(data, identity: identity)
        document = decoded
        return decoded
    }

    /// Called with each document about to be saved, before its owner-only
    /// values are sealed: the one moment this master holds them in plain.
    private var saveObserver: (@Sendable (VaultDocument) -> Void)?

    public func observeSaves(_ observer: @escaping @Sendable (VaultDocument) -> Void) {
        saveObserver = observer
    }

    private func save(_ unsealedDoc: VaultDocument) throws {
        let identity = try ensureIdentity()
        saveObserver?(unsealedDoc)
        let doc = try sealingOwnerOnly(unsealedDoc)
        if doc.secrets.values.contains(where: { $0.sealed != nil }), !(document?.secrets.values.contains { $0.sealed != nil } ?? false),
           !FileManager.default.fileExists(atPath: preSealBackupPath), let current = FileManager.default.contents(atPath: vaultPath) {
            try VaultFiles.writeAtomically(current, to: preSealBackupPath, mode: 0o600)
        }
        let plain = try JSONEncoder.vault.encode(doc)
        let sealed = try VaultSeal.seal(plain, identity: identity)
        try VaultFiles.writeAtomically(sealed, to: vaultPath, mode: 0o600)
        // What is on disk, dates at the file's millisecond precision.
        document = try JSONDecoder.vault.decode(VaultDocument.self, from: plain)
    }

    /// With owner keys in place, a secret of tier ask or never keeps its
    /// value only encrypted to them; one below those tiers never keeps the
    /// owner-only form.
    private func sealingOwnerOnly(_ doc: VaultDocument) throws -> VaultDocument {
        var out = doc
        let owner = doc.owner.flatMap { $0.isActive ? $0 : nil }
        for (name, s) in doc.secrets where s.deletedAt == nil {
            if s.isOwnerOnly, !s.value.isEmpty, let owner {
                var sealed = s
                sealed.sealed = try VaultOwnerSeal.seal(name: s.name, value: s.value, to: owner.recipients)
                sealed.value = ""
                // The sealed copy must win over the plain one on every replica.
                if document?.secrets[name]?.sealed == nil { sealed.updatedAt = s.updatedAt.addingTimeInterval(0.001) }
                out.secrets[name] = sealed
            } else if !s.isOwnerOnly, s.sealed != nil {
                guard !s.value.isEmpty else {
                    throw VaultError.locked("\(name) is owner-only: lowering its tier needs its value from a device")
                }
                out.secrets[name]?.sealed = nil
            } else if !s.value.isEmpty, s.sealed != nil {
                // A new value replaces the sealed one.
                out.secrets[name]?.sealed = nil
            }
        }
        return out
    }

    // MARK: - Owner keys

    public func owner() throws -> VaultOwnerSet? {
        try load().owner
    }

    /// Sets the owner keys. Becoming active seals every ask and never
    /// secret that still holds a plain value.
    public func setOwner(_ recipients: [VaultOwnerRecipient], resealed: [String: String] = [:], now: Date = Date()) throws {
        var doc = try load()
        let sealedNames = doc.live.filter { $0.sealed != nil }.map(\.name)
        let missing = sealedNames.filter { resealed[$0] == nil }
        guard missing.isEmpty || doc.owner?.recipients.map(\.publicKey) == recipients.map(\.publicKey) else {
            throw VaultError.locked("changing the owner keys needs \(missing.count) sealed secret(s) encrypted again by a device")
        }
        doc.owner = VaultOwnerSet(recipients: recipients, updatedAt: max(now, (doc.owner?.updatedAt ?? .distantPast).addingTimeInterval(0.001)))
        for (name, sealed) in resealed {
            guard var s = doc.secrets[name], s.deletedAt == nil, s.sealed != nil else { continue }
            s.sealed = sealed
            s.updatedAt = max(now, s.updatedAt.addingTimeInterval(0.001))
            doc.secrets[name] = s
        }
        try save(doc)
    }

    /// How many ask and never secrets are sealed, and how many still wait
    /// for owner keys.
    public func ownerCounts() throws -> (sealed: Int, plain: Int) {
        let live = try load().live.filter(\.isOwnerOnly)
        return (live.filter { $0.sealed != nil }.count, live.filter { $0.sealed == nil && !$0.value.isEmpty }.count)
    }

    /// Every sealed secret, as a device needs it to encrypt it again.
    public func sealedItems() throws -> [VaultUnsealChallenge.Item] {
        try load().live.compactMap(\.unsealItem)
    }

    /// Seals what is still plain, e.g. after a merge with a replica that
    /// did not know the owner keys yet. Returns how many it sealed.
    @discardableResult
    public func sealPending() throws -> Int {
        let doc = try load()
        guard doc.owner?.isActive == true else { return 0 }
        let plain = doc.live.filter { $0.isOwnerOnly && $0.sealed == nil && !$0.value.isEmpty }.count
        if plain > 0 { try save(doc) }
        return plain
    }

    /// Every live secret, or those of one project (`project` nil lists all).
    public func list(project: String? = nil) throws -> [VaultSecretInfo] {
        let key = currentIdentity().map(VaultSeal.authKey)
        return try load().live.filter { project == nil || $0.project == project }.map { s in
            var info = s.info
            if let key, !s.value.isEmpty {
                let mac = HMAC<SHA256>.authenticationCode(for: Data(("fingerprint:" + s.value).utf8), using: key)
                info.fingerprint = Data(mac).prefix(8).map { String(format: "%02x", $0) }.joined()
            }
            return info
        }
    }

    /// The secret stored under `name`, or the one that carried that name
    /// before it was renamed.
    public func secret(_ name: String) throws -> VaultSecret? {
        let doc = try load()
        if let s = doc.secrets[name], s.deletedAt == nil { return s }
        return doc.live.first { $0.aliases?.contains(name) == true }
    }

    /// The value a project gets for an environment variable: its own for
    /// the environment, from the most specific project first, else the
    /// shared one.
    public func resolve(key: String, projects: [String], environment: String) throws -> VaultSecret? {
        for project in projects {
            if let s = try secret(VaultSecretName(key: key, project: project, environment: environment).canonical) { return s }
        }
        return try secret(key)
    }

    /// A project's own secrets for an environment: those of the first of
    /// `projects`, or with `nearest` those of the most specific one that
    /// has any.
    public func group(projects: [String], environment: String, nearest: Bool = false) throws -> [VaultSecret] {
        let live = try load().live
        for project in nearest ? projects : Array(projects.prefix(1)) {
            let own = live.filter { $0.project == project && $0.environment == environment }
            if !own.isEmpty { return own }
        }
        return []
    }

    /// Adds or replaces a secret; `updatedAt` is stamped now.
    public func upsert(_ secret: VaultSecret, now: Date = Date()) throws {
        guard VaultSecret.isValidName(secret.name) else {
            throw VaultError.invalid("secret names use letters, digits and _ - . / : (got \(secret.name))")
        }
        var doc = try load()
        var s = secret
        if let existing = doc.secrets[s.name], existing.deletedAt == nil {
            s.createdAt = existing.createdAt
        }
        s.updatedAt = max(now, (doc.secrets[s.name]?.updatedAt ?? .distantPast).addingTimeInterval(0.001))
        s.deletedAt = nil
        doc.secrets[s.name] = s
        try save(doc)
    }

    /// Edits what a secret is without touching its value. Moving a sealed
    /// secret below tier ask needs `unsealedValue`, which a device opened.
    public func update(_ name: String, unsealedValue: String? = nil, now: Date = Date(), _ edit: (inout VaultSecret) -> Void) throws {
        guard var s = try secret(name) else { throw VaultError.notFound("no secret \(name)") }
        let stored = s.name
        edit(&s)
        s.name = stored
        if s.isSealed, !s.isOwnerOnly {
            guard let unsealedValue else {
                throw VaultError.locked("\(stored) is owner-only: lowering its tier needs an approval on the Mac or the phone")
            }
            s.value = unsealedValue
            s.sealed = nil
        }
        try upsert(s, now: now)
    }

    /// What a rename would do, without doing it.
    public enum RenameOutcome: String, Codable, Sendable {
        /// The secret gets the new name.
        case rename
        /// The new name already holds the same value: the two become one.
        case merge
        /// The new name holds another value: nothing changes.
        case conflict
        case missing
        /// Already under that name.
        case same
    }

    public func renameOutcome(from: String, to: String) throws -> RenameOutcome {
        let doc = try load()
        guard let old = doc.secrets[from], old.deletedAt == nil else {
            return doc.live.contains { $0.name == to && $0.aliases?.contains(from) == true } ? .same : .missing
        }
        if from == to { return .same }
        guard let target = doc.secrets[to], target.deletedAt == nil else { return .rename }
        // Two sealed values cannot be compared here.
        if target.sealed != nil || old.sealed != nil { return .conflict }
        return target.value == old.value && target.aws == old.aws ? .merge : .conflict
    }

    /// Gives a secret a new name. The old name stays as an alias, so
    /// references to it keep resolving; its own entry becomes a tombstone,
    /// which wins on every replica. When the new name already holds the
    /// same value the two merge: the stricter tier, both sources and both
    /// sets of aliases. A different value there is a conflict and nothing
    /// changes.
    @discardableResult
    public func rename(from: String, to: String, now: Date = Date()) throws -> RenameOutcome {
        let outcome = try renameOutcome(from: from, to: to)
        guard outcome == .rename || outcome == .merge else { return outcome }
        guard VaultSecret.isValidName(to) else {
            throw VaultError.invalid("secret names use letters, digits and _ - . / : (got \(to))")
        }
        var doc = try load()
        guard var old = doc.secrets[from] else { return .missing }
        var new = old
        new.name = to
        if outcome == .merge, let target = doc.secrets[to] {
            new = target
            new.tier = max(target.tier, old.tier)
            if new.rules.isEmpty { new.rules = old.rules }
            if old.leasePolicy.everyUseAsks { new.leasePolicy.everyUseAsks = true }
            new.leasePolicy.leaseSeconds = min(target.leasePolicy.leaseSeconds, old.leasePolicy.leaseSeconds)
            new.sources = Array(Set(target.sources + old.sources)).sorted()
            new.tags = Array(Set(target.tags + old.tags)).sorted()
            new.createdAt = min(target.createdAt, old.createdAt)
            new.label = target.label ?? old.label
        }
        var aliases = (new.aliases ?? []) + [from] + (old.aliases ?? [])
        aliases = aliases.filter { $0 != to }
        new.aliases = Array(Set(aliases)).sorted()
        new.deletedAt = nil
        new.updatedAt = max(now, (doc.secrets[to]?.updatedAt ?? .distantPast).addingTimeInterval(0.001))
        old.value = ""
        old.sealed = nil
        old.aliases = nil
        old.deletedAt = now
        old.updatedAt = max(now, old.updatedAt.addingTimeInterval(0.001))
        doc.secrets[to] = new
        doc.secrets[from] = old
        try save(doc)
        // Leases follow the secret to its new name.
        let leases = loadLeases()
        if leases.contains(where: { $0.secret == from }) {
            try saveLeases(leases.map { lease in
                var lease = lease
                if lease.secret == from { lease.secret = to }
                return lease
            })
        }
        return outcome
    }

    public func delete(_ name: String, now: Date = Date()) throws {
        guard var s = try secret(name) else { throw VaultError.notFound("no secret \(name)") }
        var doc = try load()
        s.value = ""
        s.sealed = nil
        s.aliases = nil
        s.deletedAt = now
        s.updatedAt = max(now, s.updatedAt.addingTimeInterval(0.001))
        doc.secrets[s.name] = s
        try save(doc)
    }

    // MARK: - Replica

    /// The encrypted file as it is on disk, for a replica.
    public func encryptedBlob() -> Data? {
        FileManager.default.contents(atPath: vaultPath)
    }

    /// Merges another replica's file into this one. Returns whether this
    /// vault changed, and whether the other side lacks something this one has.
    @discardableResult
    public func mergeReplica(_ blob: Data) throws -> (changedHere: Bool, otherIsBehind: Bool) {
        guard let identity = currentIdentity() else {
            // Without the key the newest blob is kept as is, still encrypted.
            if FileManager.default.contents(atPath: vaultPath) != blob {
                try VaultFiles.writeAtomically(blob, to: vaultPath, mode: 0o600)
                return (true, false)
            }
            return (false, false)
        }
        let theirs = try VaultSeal.open(blob, identity: identity)
        let mine = try load()
        let merged = mine.merged(with: theirs)
        let changed = merged != mine
        if changed { try save(merged) }
        // What is on disk, with anything the merge brought in plain sealed.
        let current = try load()
        return (changed, theirs.merged(with: current) != theirs)
    }

    // MARK: - Leases

    private func loadLeases() -> [VaultLease] {
        if let leases { return leases }
        let loaded = FileManager.default.contents(atPath: leasesPath)
            .flatMap { try? JSONDecoder.vault.decode([VaultLease].self, from: $0) } ?? []
        leases = loaded
        return loaded
    }

    private func saveLeases(_ list: [VaultLease]) throws {
        leases = list
        try VaultFiles.writeAtomically(try JSONEncoder.vault.encode(list), to: leasesPath, mode: 0o600)
    }

    public func activeLease(cardId: String, secret: String, now: Date = Date()) -> VaultLease? {
        loadLeases().first { $0.cardId == cardId && $0.secret == secret && $0.isActive(at: now) }
    }

    public func activeLeases(cardId: String? = nil, now: Date = Date()) -> [VaultLease] {
        loadLeases().filter { $0.isActive(at: now) && (cardId == nil || $0.cardId == cardId) }
            .sorted { $0.grantedAt > $1.grantedAt }
    }

    public func grantLease(_ lease: VaultLease) throws {
        let now = Date()
        var list = loadLeases().filter { $0.isActive(at: now) && !($0.cardId == lease.cardId && $0.secret == lease.secret) }
        var capped = lease
        capped.expiresAt = min(lease.expiresAt, lease.grantedAt.addingTimeInterval(VaultLeasePolicy.maximumLease))
        list.append(capped)
        try saveLeases(list)
    }

    public func revokeLease(id: String) throws {
        try saveLeases(loadLeases().filter { $0.id != id })
    }

    // MARK: - Open requests

    /// Stores the broker's open requests, age-encrypted to the vault
    /// identity (an add carries the new value); nil removes the file.
    public func savePending(_ json: Data?) throws {
        guard let json else {
            unlink(pendingPath)
            return
        }
        let identity = try ensureIdentity()
        try VaultFiles.writeAtomically(try Age.encrypt(json, to: [identity.recipient]), to: pendingPath, mode: 0o600)
    }

    public func loadPending() -> Data? {
        guard let data = FileManager.default.contents(atPath: pendingPath), let identity = currentIdentity() else { return nil }
        return try? Age.decrypt(data, with: identity)
    }

    // MARK: - Rate

    /// The distinct callers that took `secret` in the rate window, `excluding` one.
    public func recentReleases(_ secret: String, excluding caller: String? = nil, now: Date = Date()) -> Int {
        rate.count(secret, excluding: caller, now: now)
    }

    public func recordRelease(_ secret: String, caller: String, now: Date = Date()) {
        rate.record(secret, caller: caller, at: now)
    }

    /// Starts the count of a secret's releases again.
    public func resetReleases(_ secret: String) {
        rate.reset(secret)
    }

    // MARK: - Audit

    /// Adds a line to the audit log. It carries the hash of the line
    /// before it, so a removed or changed line breaks the chain.
    public func append(_ entry: VaultAuditEntry) {
        var entry = entry
        entry.command = withoutValues(entry.command)
        entry.reason = withoutValues(entry.reason)
        entry.detail = withoutValues(entry.detail)
        entry.prev = lastAuditLineHash()
        guard var line = try? JSONEncoder.vaultLine.encode(entry) else { return }
        let hash = AuditChain.hash(line)
        line.append(0x0A)
        guard AuditChain.appendRaw(line, to: auditPath) else { return }
        lastAuditHash = hash
        onAudit?()
    }

    /// Shortest value the audit log looks for in a command: anything
    /// shorter is too likely to be an ordinary word.
    static let auditValueMinimum = 12

    /// `text` with every value this vault can read replaced by a
    /// `{{vault:NAME}}` reference, so the audit log never holds a secret
    /// a command carried in plain. Owner-only values are not readable here.
    func withoutValues(_ text: String?) -> String? {
        guard var out = text, !out.isEmpty, let doc = document ?? (try? load()) else { return text }
        let known = doc.live.filter { $0.value.count >= Self.auditValueMinimum }
            .sorted { ($0.value.count, $1.name) > ($1.value.count, $0.name) }
        for s in known where out.contains(s.value) {
            out = out.replacingOccurrences(of: s.value, with: "{{vault:\(s.name)}}")
        }
        return out
    }

    private func lastAuditLineHash() -> String {
        if let lastAuditHash { return lastAuditHash }
        let hash = AuditChain.lines(of: FileManager.default.contents(atPath: auditPath) ?? Data()).last.map(AuditChain.hash) ?? ""
        lastAuditHash = hash
        return hash
    }

    public func onAuditAppend(_ handler: @escaping @Sendable () -> Void) {
        onAudit = handler
    }

    /// The audit log's raw lines, oldest first.
    public func auditLines() -> [Data] {
        AuditChain.lines(of: FileManager.default.contents(atPath: auditPath) ?? Data())
    }

    // MARK: - Audit mirrors

    static func mirrorFileName(_ machine: String) -> String {
        let safe = machine.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII || "-_.".unicodeScalars.contains($0) ? Character($0) : "-" }
        let name = String(safe).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return (name.isEmpty ? "unknown" : String(name.prefix(80))) + ".jsonl"
    }

    func mirrorPath(_ machine: String) -> String {
        mirrorDirectory + "/" + Self.mirrorFileName(machine)
    }

    public func mirrorLines(machine: String) -> [Data] {
        AuditChain.lines(of: FileManager.default.contents(atPath: mirrorPath(machine)) ?? Data())
    }

    /// The machines whose logs are mirrored here.
    public func mirroredMachines() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: mirrorDirectory)) ?? [])
            .filter { $0.hasSuffix(".jsonl") }.map { String($0.dropLast(6)) }.sorted()
    }

    /// Where a peer's mirror stands: how many lines, and the hash of the last.
    public func mirrorTail(machine: String) -> VaultAuditMirrorTail {
        let lines = mirrorLines(machine: machine)
        return VaultAuditMirrorTail(count: lines.count, lastHash: lines.last.map(AuditChain.hash))
    }

    /// Adds a peer's audit lines to its mirror here. Lines are only ever
    /// added: a line that does not follow the mirror's last one is kept
    /// too, and shows as a break when the mirror is checked.
    public func appendMirror(machine: String, lines: [String]) -> VaultAuditMirrorTail {
        var known = Set(mirrorLines(machine: machine).map(AuditChain.hash))
        var bytes = Data()
        for text in lines {
            let line = Data(text.utf8)
            guard !line.isEmpty, !line.contains(0x0A), known.insert(AuditChain.hash(line)).inserted else { continue }
            bytes.append(line)
            bytes.append(0x0A)
        }
        if !bytes.isEmpty { AuditChain.appendRaw(bytes, to: mirrorPath(machine)) }
        return mirrorTail(machine: machine)
    }

    /// The releases a human approved, on this machine and on the peers
    /// mirrored here: those since `since`, and older ones whose card lease
    /// still runs at `now`. Newest first.
    public func approvals(since: Date, now: Date = Date()) -> [VaultAuditEntry] {
        let lines = auditLines() + mirroredMachines().flatMap { mirrorLines(machine: $0) }
        // The logs hold tens of thousands of ambient releases: decode only the human ones.
        let human = Data("\"decider\":\"human\"".utf8)
        return lines.filter { $0.range(of: human) != nil }
            .compactMap { try? JSONDecoder.vault.decode(VaultAuditEntry.self, from: $0) }
            .filter { $0.outcome == .allowed && $0.decider == .human && ($0.at >= since || ($0.leaseUntil ?? .distantPast) > now) }
            .sorted { $0.at > $1.at }
    }

    /// Uses of a secret that only the owner managing the vault makes;
    /// they ask by design and are left out of `askSummary`.
    static let ownerActions: Set<String> = ["add", "edit", "rm", "rename", "tier", "owner"]

    /// Per secret, the requests since `since` that reached a human, on this
    /// machine and the peers mirrored here, most asked first.
    public func askSummary(since: Date, limit: Int = 3) -> [VaultAskSummary] {
        let lines = auditLines() + mirroredMachines().flatMap { mirrorLines(machine: $0) }
        let asked = Data("\"outcome\":\"asked\"".utf8), human = Data("\"decider\":\"human\"".utf8),
            timeout = Data("\"decider\":\"timeout\"".utf8)
        let entries = lines
            .filter { $0.range(of: asked) != nil || $0.range(of: human) != nil || $0.range(of: timeout) != nil }
            .compactMap { try? JSONDecoder.vault.decode(VaultAuditEntry.self, from: $0) }
            .filter { $0.at >= since && !Self.ownerActions.contains($0.action) }
        // One request is one ask per secret, whatever lines it left.
        var requests: [String: [VaultAuditEntry]] = [:]
        for e in entries {
            let key = e.secret + "|" + (e.requestId ?? "\(e.at.timeIntervalSince1970)|\(e.cardId ?? "")")
            requests[key, default: []].append(e)
        }
        func top(_ texts: [String]) -> [VaultAskSummary.Count] {
            Dictionary(grouping: texts.filter { !$0.isEmpty }, by: { $0 })
                .map { VaultAskSummary.Count(text: $0.key, count: $0.value.count) }
                .sorted { $0.count != $1.count ? $0.count > $1.count : $0.text < $1.text }
                .prefix(limit).map { $0 }
        }
        return Dictionary(grouping: requests.values, by: { $0[0].secret }).map { secret, asks in
            let firsts = asks.map { group in group.first { $0.outcome == .asked } ?? group[0] }
            let refusals: [VaultAuditEntry] = asks.flatMap { $0 }.filter { $0.decider == .human && $0.outcome == .denied }
            let notes: [String] = refusals.compactMap(\.note)
            return VaultAskSummary(
                secret: secret,
                asks: asks.count,
                approved: asks.filter { $0.contains { $0.decider == .human && $0.outcome == .allowed } }.count,
                denied: asks.filter { $0.contains { ($0.decider == .human && $0.outcome == .denied) || $0.decider == .timeout } }.count,
                outsideCard: asks.filter { $0.contains { $0.cardId == nil || $0.cardId?.hasPrefix("unverified:") == true } }.count,
                lastAt: asks.flatMap { $0 }.map(\.at).max() ?? since,
                reasons: top(firsts.compactMap(\.reason)),
                why: top(firsts.compactMap { $0.detail.map(Self.askCause) }),
                commands: top(firsts.compactMap(\.command)),
                notes: top(notes)
            )
        }.sorted { $0.asks != $1.asks ? $0.asks > $1.asks : $0.secret < $1.secret }
    }

    /// An ask's detail without the calling process chain.
    static func askCause(_ detail: String) -> String {
        detail.components(separatedBy: ", called by:").first ?? detail
    }

    /// Newest first.
    public func log(limit: Int = 200, cardId: String? = nil, secret: String? = nil) -> [VaultAuditEntry] {
        guard let data = FileManager.default.contents(atPath: auditPath) else { return [] }
        var out: [VaultAuditEntry] = []
        for line in data.split(separator: 0x0A).reversed() {
            guard let entry = try? JSONDecoder.vault.decode(VaultAuditEntry.self, from: Data(line)) else { continue }
            if let cardId, entry.cardId != cardId { continue }
            if let secret, entry.secret != secret { continue }
            out.append(entry)
            if out.count >= limit { break }
        }
        return out
    }
}

extension JSONEncoder {
    static var vault: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(VaultDates.format(date))
        }
        e.outputFormatting = [.sortedKeys]
        return e
    }

    static var vaultLine: JSONEncoder { vault }
}

extension JSONDecoder {
    static var vault: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let text = try c.decode(String.self)
            guard let date = VaultDates.parse(text) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad date \(text)")
            }
            return date
        }
        return d
    }
}

/// ISO 8601 with milliseconds, the format of the remote API.
enum VaultDates {
    static func format(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    static func parse(_ text: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: text) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: text)
    }
}
