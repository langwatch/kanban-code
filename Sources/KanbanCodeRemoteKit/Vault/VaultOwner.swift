#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// A key that can open the owner-only secrets (tiers ask and never): a
/// device key whose private half stays in that device's Secure Enclave, or
/// the recovery key the owner keeps outside every machine.
public struct VaultOwnerRecipient: Codable, Sendable, Equatable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case mac, phone, recovery
    }

    public var name: String
    public var kind: Kind
    /// `age1se1...` for a device, `age1...` for the recovery key.
    public var publicKey: String
    public var addedAt: Date

    public init(name: String, kind: Kind, publicKey: String, addedAt: Date = Date()) {
        self.name = name
        self.kind = kind
        self.publicKey = publicKey
        self.addedAt = addedAt
    }

    public var id: String { fingerprint }

    /// What the owner compares between two screens: eight bytes of the
    /// key's SHA-256, in groups of four.
    public var fingerprint: String { Self.fingerprint(of: publicKey) }

    public static func fingerprint(of publicKey: String) -> String {
        let hex = SHA256.hash(data: Data(publicKey.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return stride(from: 0, to: hex.count, by: 4).map { i in
            String(hex[hex.index(hex.startIndex, offsetBy: i)..<hex.index(hex.startIndex, offsetBy: i + 4)])
        }.joined(separator: " ")
    }
}

/// The keys the owner-only secrets are encrypted to. Sealing starts once
/// there is a recovery key and at least one device.
public struct VaultOwnerSet: Codable, Sendable, Equatable {
    public var recipients: [VaultOwnerRecipient]
    public var updatedAt: Date

    public init(recipients: [VaultOwnerRecipient] = [], updatedAt: Date = Date()) {
        self.recipients = recipients
        self.updatedAt = updatedAt
    }

    public var devices: [VaultOwnerRecipient] { recipients.filter { $0.kind != .recovery } }
    public var recovery: VaultOwnerRecipient? { recipients.first { $0.kind == .recovery } }
    public var isActive: Bool { recovery != nil && !devices.isEmpty }
}

/// The owner-only form of a secret: an age file holding `{"name","value"}`,
/// base64. The name inside lets a device check it opens what it was told.
public enum VaultOwnerSeal {
    struct Payload: Codable {
        var name: String
        var value: String
    }

    public enum SealError: Error, Equatable, CustomStringConvertible {
        case notSealed
        case wrongSecret(asked: String, holds: String)
        case noRecipients

        public var description: String {
            switch self {
            case .notSealed: "not a sealed secret"
            case .wrongSecret(let asked, let holds): "the request names \(asked) but the sealed value belongs to \(holds)"
            case .noRecipients: "no owner keys to encrypt to"
            }
        }
    }

    public static func seal(name: String, value: String, to recipients: [VaultOwnerRecipient]) throws -> String {
        guard !recipients.isEmpty else { throw SealError.noRecipients }
        let keys = try recipients.map { try Age.AnyRecipient(text: $0.publicKey) }
        let plain = try JSONEncoder().encode(Payload(name: name, value: value))
        return try Age.encrypt(plain, to: keys).base64EncodedString()
    }

    public static func open(_ sealed: String, with key: any AgeP256Key) throws -> (name: String, value: String) {
        guard let file = Data(base64Encoded: sealed) else { throw SealError.notSealed }
        return try payload(Age.decrypt(file, with: key))
    }

    public static func open(_ sealed: String, recovery identity: Age.Identity) throws -> (name: String, value: String) {
        guard let file = Data(base64Encoded: sealed) else { throw SealError.notSealed }
        return try payload(Age.decrypt(file, with: identity))
    }

    private static func payload(_ plain: Data) throws -> (name: String, value: String) {
        let p = try JSONDecoder().decode(Payload.self, from: plain)
        return (p.name, p.value)
    }
}

/// What a master needs a device to do with its key before a request can be
/// approved. It rides on the attention request; all of it is ciphertext
/// and parameters, never a value.
public struct VaultUnsealChallenge: Codable, Sendable, Equatable, Hashable {
    public struct Item: Codable, Sendable, Equatable, Hashable {
        public var name: String
        /// Earlier names the sealed value may still carry inside.
        public var aliases: [String]?
        public var sealed: String

        public init(name: String, aliases: [String]? = nil, sealed: String) {
            self.name = name
            self.aliases = aliases
            self.sealed = sealed
        }
    }

    /// Short-lived AWS credentials the device mints itself, so the
    /// long-lived key never reaches the master.
    public struct AwsMint: Codable, Sendable, Equatable, Hashable {
        public var profile: String
        public var key: Item
        public var role: VaultAwsRole
        public var sessionName: String

        public init(profile: String, key: Item, role: VaultAwsRole, sessionName: String) {
            self.profile = profile
            self.key = key
            self.role = role
            self.sessionName = sessionName
        }
    }

    /// Secrets whose values the master needs back.
    public var secrets: [Item]
    public var aws: [AwsMint]
    /// Secrets the device encrypts again to `resealTo` (a device joins or
    /// leaves); only the new ciphertext goes back.
    public var reseal: [Item]
    public var resealTo: [VaultOwnerRecipient]

    public init(secrets: [Item] = [], aws: [AwsMint] = [], reseal: [Item] = [], resealTo: [VaultOwnerRecipient] = []) {
        self.secrets = secrets
        self.aws = aws
        self.reseal = reseal
        self.resealTo = resealTo
    }

    public var isEmpty: Bool { secrets.isEmpty && aws.isEmpty && reseal.isEmpty }

    /// What approving does on the device, for the detail sheet. Built from
    /// the challenge itself, not from what the master says about it.
    public var rows: [(label: String, value: String)] {
        var rows: [(String, String)] = []
        if !secrets.isEmpty {
            rows.append(("Unlocks here", secrets.map(\.name).joined(separator: "\n")))
        }
        for mint in aws {
            rows.append(("Mints here", "AWS credentials for \(mint.role.roleArn ?? "a session of \(mint.key.name)")"
                + (mint.role.policyArns.isEmpty ? "" : "\nlimited by \(mint.role.policyArns.joined(separator: ", "))")))
        }
        if !reseal.isEmpty {
            let keys = resealTo.map { "\($0.name) (\($0.kind.rawValue)) \($0.fingerprint)" }.joined(separator: "\n")
            rows.append(("Owner keys after", keys))
            rows.append(("Encrypts again", "\(reseal.count) owner-only secret\(reseal.count == 1 ? "" : "s")"))
        }
        return rows
    }
}

/// What the device hands back after biometry.
public struct VaultUnsealed: Codable, Sendable, Equatable, Hashable {
    public var values: [String: String]
    /// By AWS profile.
    public var credentials: [String: AwsProcessCredentials]
    public var resealed: [String: String]
    /// Fingerprint of the device key that did it.
    public var device: String

    public init(values: [String: String] = [:], credentials: [String: AwsProcessCredentials] = [:], resealed: [String: String] = [:], device: String) {
        self.values = values
        self.credentials = credentials
        self.resealed = resealed
        self.device = device
    }
}

/// Answers a challenge with a device key.
public enum VaultUnsealer {
    public typealias Mint = @Sendable (AwsAccessKey, VaultAwsRole, String) async throws -> AwsProcessCredentials

    public static let liveMint: Mint = { key, role, name in
        try await AwsSts(region: role.region ?? "us-east-1").longestCredentials(key: key, role: role, sessionName: name)
    }

    /// Opens one item and checks it holds the secret the request names.
    static func open(_ item: VaultUnsealChallenge.Item, key: any AgeP256Key) throws -> String {
        let (inner, value) = try VaultOwnerSeal.open(item.sealed, with: key)
        guard inner == item.name || (item.aliases ?? []).contains(inner) else {
            throw VaultOwnerSeal.SealError.wrongSecret(asked: item.name, holds: inner)
        }
        return value
    }

    public static func answer(_ challenge: VaultUnsealChallenge, key: any AgeP256Key, mint: Mint = liveMint) async throws -> VaultUnsealed {
        var out = VaultUnsealed(device: VaultOwnerRecipient.fingerprint(of: key.recipient.text))
        for item in challenge.secrets {
            out.values[item.name] = try open(item, key: key)
        }
        if !challenge.reseal.isEmpty {
            for item in challenge.reseal {
                let (inner, value) = try VaultOwnerSeal.open(item.sealed, with: key)
                out.resealed[item.name] = try VaultOwnerSeal.seal(name: inner, value: value, to: challenge.resealTo)
            }
        }
        for aws in challenge.aws {
            let longLived = try JSONDecoder().decode(AwsAccessKey.self, from: Data(try open(aws.key, key: key).utf8))
            out.credentials[aws.profile] = try await mint(longLived, aws.role, aws.sessionName)
        }
        return out
    }
}

/// A JSON-lines log where every line carries the SHA-256 of the line
/// before it (`prev`), so a removed or rewritten line shows.
public enum AuditChain {
    public static func hash(_ line: Data) -> String {
        SHA256.hash(data: line).map { String(format: "%02x", $0) }.joined()
    }

    public static func lines(of data: Data) -> [Data] {
        data.split(separator: 0x0A).map { Data($0) }
    }

    static func prev(of line: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: line) as? [String: Any])?["prev"] as? String
    }

    public struct Report: Codable, Sendable, Equatable {
        public var lines: Int
        /// Lines from before the chain existed.
        public var unchained: Int
        /// 1-based numbers of lines whose `prev` is not the line before.
        public var breaks: [Int]

        public var isIntact: Bool { breaks.isEmpty }
    }

    /// Lines written before the chain carry no `prev`; the first chained
    /// line names the hash of the last of them. After that every line
    /// must chain.
    public static func verify(_ lines: [Data]) -> Report {
        var report = Report(lines: lines.count, unchained: 0, breaks: [])
        var chained = false
        for (i, line) in lines.enumerated() {
            guard let prev = prev(of: line) else {
                if chained { report.breaks.append(i + 1) } else { report.unchained += 1 }
                continue
            }
            chained = true
            let expected = i == 0 ? "" : hash(lines[i - 1])
            if prev != expected { report.breaks.append(i + 1) }
        }
        return report
    }

    /// Appends `fields` as one line with its `prev`, creating the file 0600.
    @discardableResult
    public static func append(_ fields: [String: Any], to path: String) -> Bool {
        let existing = FileManager.default.contents(atPath: path) ?? Data()
        var object = fields
        object["prev"] = lines(of: existing).last.map(hash) ?? ""
        guard var line = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return false }
        line.append(0x0A)
        return appendRaw(line, to: path)
    }

    @discardableResult
    public static func appendRaw(_ bytes: Data, to path: String) -> Bool {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return false }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: bytes)
            return true
        } catch {
            return false
        }
    }
}

/// The record a device keeps of the vault requests answered on it.
public struct VaultDeviceApprovals: Sendable {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    public struct Entry: Codable, Sendable, Equatable, Identifiable {
        public var at: String
        public var requestId: String
        public var resolution: String
        public var title: String
        public var master: String?
        public var unlocked: [String]?
        public var awsRole: String?
        public var resealedTo: [String]?
        public var error: String?
        public var prev: String?

        public var id: String { requestId + at }
    }

    public func record(_ request: AttentionRequest, resolution: String, error: String? = nil, now: Date = Date()) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var fields: [String: Any] = [
            "at": formatter.string(from: now), "requestId": request.id, "resolution": resolution, "title": request.title,
        ]
        if let master = request.machineId { fields["master"] = master }
        if let challenge = request.unseal, error == nil, !AttentionCopy.isDenial(resolution) {
            if !challenge.secrets.isEmpty { fields["unlocked"] = challenge.secrets.map(\.name) }
            if !challenge.aws.isEmpty { fields["awsRole"] = challenge.aws.map { $0.role.roleArn ?? "session of \($0.key.name)" }.joined(separator: ", ") }
            if !challenge.reseal.isEmpty { fields["resealedTo"] = challenge.resealTo.map(\.fingerprint) }
        }
        if let error { fields["error"] = error }
        AuditChain.append(fields, to: path)
    }

    /// Newest first.
    public func entries(limit: Int = 500) -> [Entry] {
        let lines = AuditChain.lines(of: FileManager.default.contents(atPath: path) ?? Data())
        return lines.suffix(limit).reversed().compactMap { try? JSONDecoder().decode(Entry.self, from: $0) }
    }

    public func report() -> AuditChain.Report {
        AuditChain.verify(AuditChain.lines(of: FileManager.default.contents(atPath: path) ?? Data()))
    }

    public func requestIds() -> Set<String> {
        Set(entries(limit: .max).filter { $0.error == nil && !AttentionCopy.isDenial($0.resolution) }.map(\.requestId))
    }
}

/// Body of `GET /v1/vault/owner`.
public struct VaultOwnerStatus: Codable, Sendable, Equatable {
    public struct Key: Codable, Sendable, Equatable, Identifiable {
        public var id: String { fingerprint }
        public var name: String
        public var kind: String
        public var fingerprint: String
        public var addedAt: Date

        public init(name: String, kind: String, fingerprint: String, addedAt: Date) {
            self.name = name
            self.kind = kind
            self.fingerprint = fingerprint
            self.addedAt = addedAt
        }
    }

    /// Sealing is on: a recovery key and at least one device.
    public var active: Bool
    public var keys: [Key]
    /// Ask and never secrets held only encrypted to the owner keys.
    public var sealed: Int
    /// Ask and never secrets still readable with the machine key.
    public var plain: Int

    public init(active: Bool, keys: [Key], sealed: Int, plain: Int) {
        self.active = active
        self.keys = keys
        self.sealed = sealed
        self.plain = plain
    }
}

/// Body of `POST /v1/vault/owner/enrol`.
public struct VaultEnrolRequest: Codable, Sendable {
    public var name: String
    public var kind: VaultOwnerRecipient.Kind
    public var publicKey: String

    public init(name: String, kind: VaultOwnerRecipient.Kind, publicKey: String) {
        self.name = name
        self.kind = kind
        self.publicKey = publicKey
    }
}
