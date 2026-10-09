import Foundation
import KanbanCodeRemoteKit

/// How a vault secret is released (see docs/vault.md).
public enum VaultTier: String, Codable, Sendable, CaseIterable, Comparable {
    /// Released to any card session, logged.
    case open
    /// Jev reads the command and the reason against the secret's rules:
    /// allow, ask the human, or deny.
    case judged
    /// The human approves on the Mac or the phone.
    case ask
    /// Never released.
    case never

    public static func < (a: VaultTier, b: VaultTier) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }

    public var label: String {
        switch self {
        case .open: "Open"
        case .judged: "Judged by Jev"
        case .ask: "Always ask"
        case .never: "Never"
        }
    }
}

/// How long an approval for a card lasts, or that every use asks.
public struct VaultLeasePolicy: Codable, Sendable, Equatable, Hashable {
    public static let maximumLease: TimeInterval = 2 * 24 * 3600
    public static let minimumLease: TimeInterval = 60
    /// The lengths the settings offer.
    public static let presets: [TimeInterval] = [15 * 60, 3600, 8 * 3600, maximumLease]

    /// Seconds a card lease on this secret lasts, from one minute to two days.
    public var leaseSeconds: TimeInterval
    /// No leases: each release asks.
    public var everyUseAsks: Bool

    public init(leaseSeconds: TimeInterval = VaultLeasePolicy.maximumLease, everyUseAsks: Bool = false) {
        self.leaseSeconds = Self.clamped(leaseSeconds)
        self.everyUseAsks = everyUseAsks
    }

    public static func clamped(_ seconds: TimeInterval) -> TimeInterval {
        guard seconds.isFinite else { return maximumLease }
        return min(max(seconds, minimumLease), maximumLease)
    }

    /// The length a lease granted under this policy gets: a stored value
    /// outside the bounds (an edited file, an older replica) is brought
    /// back inside them.
    public var grantedSeconds: TimeInterval { Self.clamped(leaseSeconds) }

    /// Why a requested lease length is refused, nil when it is allowed.
    public static func problem(leaseSeconds seconds: TimeInterval) -> String? {
        guard seconds.isFinite, seconds >= minimumLease else { return "a lease lasts at least 1 minute" }
        guard seconds <= maximumLease else {
            return "a lease lasts at most \(AttentionCopy.duration(maximumLease))"
        }
        return nil
    }

    public static let standard = VaultLeasePolicy()
    public static let everyUse = VaultLeasePolicy(everyUseAsks: true)
}

/// One secret in the vault. The value never leaves the master except in a
/// release; every listing uses `VaultSecretInfo`.
public struct VaultSecret: Codable, Sendable, Equatable {
    /// The id: `KEY` for a shared secret, `project/environment/KEY` for a
    /// project's (see `VaultSecretName`).
    public var name: String
    public var value: String
    public var tier: VaultTier
    /// Plain-language rules Jev reads for judged releases, e.g. "only for
    /// deploys of the docs site; never to print or copy it".
    public var rules: String
    public var leasePolicy: VaultLeasePolicy
    public var tags: [String]
    public var aws: VaultAwsRole?
    /// Where it was imported from (paths, never values).
    public var sources: [String]
    public var createdAt: Date
    public var updatedAt: Date
    /// Set when deleted: the tombstone wins merges until it is older.
    public var deletedAt: Date?
    /// How approvals name it to the human, e.g. "Slack user token"; when
    /// nil, a label derived from the name.
    public var label: String?
    /// Earlier names that still resolve to this secret.
    public var aliases: [String]?
    /// The owner-only form (tiers ask and never): the value encrypted to
    /// the owner keys, with `value` left empty. Only a device or the
    /// recovery key opens it (`VaultOwnerSeal`).
    public var sealed: String?

    public init(
        name: String,
        value: String,
        tier: VaultTier,
        rules: String = "",
        leasePolicy: VaultLeasePolicy = .standard,
        tags: [String] = [],
        aws: VaultAwsRole? = nil,
        sources: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil,
        label: String? = nil,
        aliases: [String]? = nil,
        sealed: String? = nil
    ) {
        self.sealed = sealed
        self.name = name
        self.value = value
        self.tier = tier
        self.rules = rules
        self.leasePolicy = leasePolicy
        self.tags = tags
        self.aws = aws
        self.sources = sources
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.label = label
        self.aliases = aliases
    }

    public var info: VaultSecretInfo {
        VaultSecretInfo(
            name: name, tier: tier, rules: rules, leasePolicy: leasePolicy, tags: tags, aws: aws,
            sources: sources, createdAt: createdAt, updatedAt: updatedAt, hasValue: !value.isEmpty || sealed != nil,
            label: label, key: key, project: project, environment: environment, aliases: aliases,
            displayLabel: displayLabel, sealed: sealed != nil ? true : nil
        )
    }

    /// Whether the value is held only in the owner-only form.
    public var isSealed: Bool { sealed != nil && value.isEmpty }

    /// The tiers whose secrets only the owner's devices open.
    public var isOwnerOnly: Bool { tier >= .ask }

    /// What a device needs to open it.
    public var unsealItem: VaultUnsealChallenge.Item? {
        sealed.map { VaultUnsealChallenge.Item(name: name, aliases: aliases, sealed: $0) }
    }

    public var parsedName: VaultSecretName { VaultSecretName(name) }
    /// The environment variable it fills.
    public var key: String { parsedName.key }
    /// Nil for a shared secret.
    public var project: String? { parsedName.project }
    /// Nil for a shared secret.
    public var environment: String? { parsedName.environment }
    /// The name and every earlier name: leases and reuse are looked up under all.
    public var allNames: [String] { [name] + (aliases ?? []) }

    /// The label approvals show: its own, or one derived from the name.
    public var displayLabel: String { AttentionCopy.secretLabel(name: name, label: label) }

    /// Secret names: letters, digits, `_ - . / :`, at most 128 characters.
    public static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 128 else { return false }
        return name.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || "_-./:".unicodeScalars.contains($0)
        }
    }
}

/// A secret as listings show it: everything but the value.
public struct VaultSecretInfo: Codable, Sendable, Equatable {
    public var name: String
    public var tier: VaultTier
    public var rules: String
    public var leasePolicy: VaultLeasePolicy
    public var tags: [String]
    public var aws: VaultAwsRole?
    public var sources: [String]
    public var createdAt: Date
    public var updatedAt: Date
    public var hasValue: Bool
    public var label: String? = nil
    public var key: String? = nil
    public var project: String? = nil
    public var environment: String? = nil
    public var aliases: [String]? = nil
    /// "label · project · environment", as approvals name it.
    public var displayLabel: String? = nil
    /// The same for two secrets holding the same value, keyed by the vault
    /// key so it says nothing about the value to anyone else.
    public var fingerprint: String? = nil
    /// The value opens only on the owner's devices.
    public var sealed: Bool? = nil
}

/// The decrypted contents of `vault.age`.
public struct VaultDocument: Codable, Sendable, Equatable {
    public var version: Int
    /// By name, tombstones included.
    public var secrets: [String: VaultSecret]
    /// The keys the owner-only secrets are encrypted to.
    public var owner: VaultOwnerSet?

    public init(version: Int = 1, secrets: [String: VaultSecret] = [:], owner: VaultOwnerSet? = nil) {
        self.version = version
        self.secrets = secrets
        self.owner = owner
    }

    public var live: [VaultSecret] {
        secrets.values.filter { $0.deletedAt == nil }.sorted { $0.name < $1.name }
    }

    /// Per name, the newer edit wins (a delete is an edit); on a tie the
    /// receiver's copy stays, so merging is idempotent.
    public func merged(with other: VaultDocument) -> VaultDocument {
        var out = self
        for (name, theirs) in other.secrets {
            if let mine = out.secrets[name], mine.updatedAt >= theirs.updatedAt { continue }
            out.secrets[name] = theirs
        }
        if let theirs = other.owner, (out.owner?.updatedAt ?? .distantPast) < theirs.updatedAt {
            out.owner = theirs
        }
        return out
    }
}

/// An approval for one card to use a secret until `expiresAt`.
public struct VaultLease: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var cardId: String
    public var secret: String
    public var scope: String?
    public var reason: String?
    public var grantedAt: Date
    public var expiresAt: Date
    /// "human:<device>" for approvals.
    public var grantedBy: String

    public init(id: String = KSUID.generate(prefix: "lease"), cardId: String, secret: String, scope: String? = nil,
                reason: String? = nil, grantedAt: Date = Date(), expiresAt: Date, grantedBy: String) {
        self.id = id
        self.cardId = cardId
        self.secret = secret
        self.scope = scope
        self.reason = reason
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
        self.grantedBy = grantedBy
    }

    public func isActive(at now: Date) -> Bool { expiresAt > now }
}

/// Who decided a release.
public enum VaultDecider: String, Codable, Sendable {
    case lease
    case tier
    case jev
    case human
    case rule
    case timeout
    /// AWS credentials the card already holds, handed to it again.
    case reuse
    /// Credentials or a value a device unlocked earlier and the master
    /// still holds for its window.
    case held
}

public enum VaultOutcome: String, Codable, Sendable {
    case allowed
    case denied
    /// Waiting on the human.
    case asked
    /// A hook-wrapped command went on without a secret that needs approval.
    case skipped
}

/// One line of the append-only audit log (`vault/audit.jsonl`).
public struct VaultAuditEntry: Codable, Sendable, Equatable {
    public var at: Date
    public var machine: String
    public var cardId: String?
    public var sessionId: String?
    public var secret: String
    public var tier: VaultTier?
    public var outcome: VaultOutcome
    public var decider: VaultDecider
    /// What the release was for: "run", "env", "get", "aws", "lease", "add", "edit".
    public var action: String
    public var command: String?
    public var reason: String?
    /// Why it was decided so (Jev's choice, the rule that fired).
    public var detail: String?
    public var requestId: String?
    /// When the card lease a human approval gave ends.
    public var leaseUntil: Date?
    /// What the owner wrote for the caller when refusing the request.
    public var note: String?
    /// SHA-256 of the line before this one in the log.
    public var prev: String?

    public init(at: Date = Date(), machine: String, cardId: String?, sessionId: String? = nil, secret: String,
                tier: VaultTier?, outcome: VaultOutcome, decider: VaultDecider, action: String,
                command: String? = nil, reason: String? = nil, detail: String? = nil, requestId: String? = nil,
                leaseUntil: Date? = nil, note: String? = nil) {
        self.note = note
        self.at = at
        self.machine = machine
        self.cardId = cardId
        self.sessionId = sessionId
        self.secret = secret
        self.tier = tier
        self.outcome = outcome
        self.decider = decider
        self.action = action
        self.command = command
        self.reason = reason
        self.detail = detail
        self.requestId = requestId
        self.leaseUntil = leaseUntil
    }
}

/// The process asking for a secret, as the master verified it.
public struct VaultCaller: Codable, Sendable, Equatable {
    /// The card whose session the process runs in, when the master found
    /// it in the process ancestry (a tmux pane or a rush-hosted
    /// assistant of that card).
    public var cardId: String?
    /// The card the client claimed (KANBAN_CARD_ID), shown to the human
    /// when it could not be verified.
    public var claimedCardId: String?
    public var sessionId: String?
    public var pid: Int?
    /// Executable names from the caller up to launchd/init.
    public var ancestry: [String]
    /// Not on loopback: a device over the tailnet.
    public var remoteDevice: String?
    /// The calling process's working directory, as the master read it.
    public var cwd: String?
    /// The card was found by the session token the caller sent, not by
    /// its process ancestry (a detached process).
    public var byToken: Bool?
    /// The master that issued the session token and vouched for the card,
    /// when the card runs there and the caller here (a command over ssh).
    public var verifiedByPeer: String?
    /// The card's title as that master gave it.
    public var peerTitle: String?
    /// The command lines of the caller and its parents, the caller first,
    /// as the master read them from the system. Set for a caller outside
    /// every card.
    public var commandLines: [String]?

    public init(cardId: String? = nil, claimedCardId: String? = nil, sessionId: String? = nil, pid: Int? = nil,
                ancestry: [String] = [], remoteDevice: String? = nil, cwd: String? = nil, byToken: Bool? = nil,
                verifiedByPeer: String? = nil, peerTitle: String? = nil, commandLines: [String]? = nil) {
        self.commandLines = commandLines
        self.verifiedByPeer = verifiedByPeer
        self.peerTitle = peerTitle
        self.cardId = cardId
        self.claimedCardId = claimedCardId
        self.sessionId = sessionId
        self.pid = pid
        self.ancestry = ancestry
        self.remoteDevice = remoteDevice
        self.cwd = cwd
        self.byToken = byToken
    }

    public var insideCard: Bool { cardId != nil && remoteDevice == nil }

    /// How the caller reached this machine from the card's own, for the
    /// human: "via ssh from <machine>" when sshd is in its process chain.
    public var peerOrigin: String? {
        guard let machine = verifiedByPeer else { return nil }
        let overSsh = ancestry.contains { $0.hasPrefix("sshd") }
        return overSsh ? "via ssh from \(machine)" : "from \(machine)"
    }

    /// How the audit log says the card was found.
    public var tokenNote: String? {
        guard byToken == true else { return nil }
        return verifiedByPeer.map { "by session token, verified by \($0)" } ?? "by session token"
    }

    /// The caller's process chain on one line, for the audit log and Jev:
    /// "kv run X -- job.sh <- bash -c job.sh <- systemd".
    public var processChain: String? {
        guard let lines = commandLines?.filter({ !$0.isEmpty }), !lines.isEmpty else { return nil }
        return String(lines.joined(separator: " <- ").prefix(700))
    }

    /// What the audit log adds about who asked: how a card was found, or
    /// the process chain of a caller outside every card.
    public var auditNote: String? {
        if let tokenNote { return tokenNote }
        guard !insideCard, remoteDevice == nil else { return nil }
        return processChain.map { "called by: \($0)" }
    }

    /// The OpenClaw agent behind `cardId` when the caller is an OpenClaw
    /// agent rather than a card ("openclaw:<agent>"). Those get the tiers
    /// and leases of a card session under that id.
    public var openClawAgent: String? { cardId.flatMap(VaultCaller.openClawAgent(principal:)) }

    public static let openClawPrefix = "openclaw:"

    public static func openClawPrincipal(agent: String) -> String { openClawPrefix + agent }

    public static func openClawAgent(principal: String) -> String? {
        principal.hasPrefix(openClawPrefix) ? String(principal.dropFirst(openClawPrefix.count)) : nil
    }
}

/// How often one secret reached a human in a period, and why: the input
/// for deciding which secrets to re-tier, scope or drop from a manifest.
public struct VaultAskSummary: Codable, Sendable, Equatable {
    public struct Count: Codable, Sendable, Equatable {
        public var text: String
        public var count: Int

        public init(text: String, count: Int) {
            self.text = text
            self.count = count
        }
    }

    public var secret: String
    /// Requests for it that a human had to answer.
    public var asks: Int
    public var approved: Int
    /// Denied by the human or left to time out.
    public var denied: Int
    /// Asks whose caller was not a verified card session.
    public var outsideCard: Int
    public var lastAt: Date
    /// The reasons the callers gave, most common first.
    public var reasons: [Count]
    /// Why the vault asked (the tier, Jev's answer, the rate limit), most common first.
    public var why: [Count]
    /// The commands that asked, most common first.
    public var commands: [Count]
    /// What the owner wrote when refusing, most common first.
    public var notes: [Count]?

    public init(secret: String, asks: Int, approved: Int, denied: Int, outsideCard: Int, lastAt: Date,
                reasons: [Count], why: [Count], commands: [Count], notes: [Count]? = nil) {
        self.notes = notes
        self.secret = secret
        self.asks = asks
        self.approved = approved
        self.denied = denied
        self.outsideCard = outsideCard
        self.lastAt = lastAt
        self.reasons = reasons
        self.why = why
        self.commands = commands
    }
}
