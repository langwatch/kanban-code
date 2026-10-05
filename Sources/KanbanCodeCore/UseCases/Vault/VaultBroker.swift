#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import KanbanCodeRemoteKit

/// Where the vault takes a decision to the human: an attention request on
/// the master, which the Mac and the phone show until one resolves it.
public protocol VaultApprovals: Sendable {
    func raise(_ request: AttentionRequest) async
    /// The resolution once the request was resolved, nil while open.
    func resolution(of id: String) async -> (resolution: String?, by: String)?
    /// Closes a request the human did not answer here: a timeout, or one
    /// an approval elsewhere settled.
    func close(id: String, resolution: String, by: String) async
}

/// Body of `POST /v1/vault/release`.
public struct VaultReleaseRequest: Codable, Sendable, Equatable {
    /// "run", "env", "get", "hook" (a command the Bash hook wrapped), "aws".
    public var mode: String
    public var names: [String]
    /// The command the secrets are for, as the agent wrote it.
    public var command: String?
    public var reason: String?
    public var cwd: String?
    /// What the client says its card is (KANBAN_CARD_ID); only a hint.
    public var cardId: String?
    public var sessionId: String?
    /// Environment variables to fill for the project: each gets the
    /// project's own value for the environment, else the shared one.
    public var keys: [String]?
    /// Also every secret the project owns for the environment.
    public var group: Bool?
    /// The group of the nearest project up from `dir` that has secrets,
    /// for a folder without a manifest of its own.
    public var nearest: Bool?
    /// Variables the caller sets some other way; the group leaves them out.
    public var defined: [String]?
    /// The folder whose project is meant (a manifest's folder); `cwd` when nil.
    public var dir: String?
    /// The project by name, instead of the one of `dir`.
    public var project: String?
    /// "dev" when nil.
    public var environment: String?

    public init(mode: String, names: [String], command: String? = nil, reason: String? = nil, cwd: String? = nil,
                cardId: String? = nil, sessionId: String? = nil, keys: [String]? = nil, group: Bool? = nil,
                defined: [String]? = nil, dir: String? = nil, project: String? = nil, environment: String? = nil,
                nearest: Bool? = nil) {
        self.mode = mode
        self.names = names
        self.command = command
        self.reason = reason
        self.cwd = cwd
        self.cardId = cardId
        self.sessionId = sessionId
        self.keys = keys
        self.group = group
        self.defined = defined
        self.dir = dir
        self.project = project
        self.environment = environment
        self.nearest = nearest
    }
}

/// One rename of `POST /v1/vault/rename`.
public struct VaultRename: Codable, Sendable, Equatable {
    public var from: String
    public var to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

/// Body of `POST /v1/vault/rename`: new names for several secrets, in one
/// approval. The old names stay as aliases.
public struct VaultRenameRequest: Codable, Sendable, Equatable {
    public var renames: [VaultRename]
    public var reason: String?
    /// Only say what each rename would do.
    public var dryRun: Bool?

    public init(renames: [VaultRename], reason: String? = nil, dryRun: Bool? = nil) {
        self.renames = renames
        self.reason = reason
        self.dryRun = dryRun
    }
}

/// Body of `POST /v1/vault/delete`: several secrets deleted in one approval.
public struct VaultDeleteRequest: Codable, Sendable, Equatable {
    public var names: [String]
    public var reason: String?
    /// Only say what each delete would do.
    public var dryRun: Bool?

    public init(names: [String], reason: String? = nil, dryRun: Bool? = nil) {
        self.names = names
        self.reason = reason
        self.dryRun = dryRun
    }
}

/// Body of `PATCH /v1/vault/secrets`: one change to several secrets.
public struct VaultBatchEditRequest: Codable, Sendable, Equatable {
    public var names: [String]?
    /// Also every secret whose value starts with one of these.
    public var valuePrefixes: [String]?
    public var edit: VaultEditRequest

    public init(names: [String]? = nil, valuePrefixes: [String]? = nil, edit: VaultEditRequest) {
        self.names = names
        self.valuePrefixes = valuePrefixes
        self.edit = edit
    }
}

/// Body of `POST /v1/vault/request`: a lease for the card's whole task.
public struct VaultLeaseRequest: Codable, Sendable, Equatable {
    /// `NAME` or `NAME:scope`.
    public var names: [String]
    public var reason: String
    public var cardId: String?
    public var sessionId: String?

    public init(names: [String], reason: String, cardId: String? = nil, sessionId: String? = nil) {
        self.names = names
        self.reason = reason
        self.cardId = cardId
        self.sessionId = sessionId
    }
}

/// Body of `POST /v1/vault/secrets`.
public struct VaultAddRequest: Codable, Sendable, Equatable {
    public var name: String
    public var value: String
    public var tier: VaultTier?
    public var rules: String?
    public var tags: [String]?
    public var aws: VaultAwsRole?
    public var leasePolicy: VaultLeasePolicy?
    public var sources: [String]?
    public var label: String?
    /// Why the caller replaces a stored value, shown to the human.
    public var reason: String?
    /// The project that owns it; `name` is then the environment variable.
    /// "." means the project of `dir`. Nil stores a shared secret.
    public var project: String?
    /// "dev" when nil; only with a project.
    public var environment: String?
    /// The caller's folder, for project ".".
    public var dir: String?

    public init(name: String, value: String, tier: VaultTier? = nil, rules: String? = nil, tags: [String]? = nil,
                aws: VaultAwsRole? = nil, leasePolicy: VaultLeasePolicy? = nil, sources: [String]? = nil,
                label: String? = nil, reason: String? = nil, project: String? = nil, environment: String? = nil,
                dir: String? = nil) {
        self.name = name
        self.value = value
        self.tier = tier
        self.rules = rules
        self.tags = tags
        self.aws = aws
        self.leasePolicy = leasePolicy
        self.sources = sources
        self.label = label
        self.reason = reason
        self.project = project
        self.environment = environment
        self.dir = dir
    }
}

/// Answer of `POST /v1/vault/compare`: whether the secret stored under a
/// name holds a given value.
public struct VaultValueCheck: Codable, Sendable, Equatable {
    public enum Outcome: String, Codable, Sendable {
        case absent, same, different
    }

    /// The name the secret is stored under.
    public var name: String
    public var outcome: Outcome

    public init(name: String, outcome: Outcome) {
        self.name = name
        self.outcome = outcome
    }
}

extension VaultAddRequest {
    /// Whether it names a value and leaves the rest of a stored secret as it is.
    var onlyValue: Bool {
        tier == nil && rules == nil && tags == nil && aws == nil && leasePolicy == nil && sources == nil && label == nil
    }
}

/// Body of `PATCH /v1/vault/secrets/{name}`.
public struct VaultEditRequest: Codable, Sendable, Equatable {
    public var tier: VaultTier?
    public var rules: String?
    public var tags: [String]?
    public var leasePolicy: VaultLeasePolicy?
    public var aws: VaultAwsRole?
    /// An empty label clears it.
    public var label: String?
    /// Why the caller wants the change, shown to the human.
    public var reason: String?

    public init(tier: VaultTier? = nil, rules: String? = nil, tags: [String]? = nil, leasePolicy: VaultLeasePolicy? = nil,
                aws: VaultAwsRole? = nil, label: String? = nil, reason: String? = nil) {
        self.tier = tier
        self.rules = rules
        self.tags = tags
        self.leasePolicy = leasePolicy
        self.aws = aws
        self.label = label
        self.reason = reason
    }

    func apply(to s: inout VaultSecret) {
        if let tier { s.tier = tier }
        if let rules { s.rules = rules }
        if let tags { s.tags = tags }
        if let leasePolicy { s.leasePolicy = leasePolicy }
        if let aws { s.aws = aws }
        if let label { s.label = label.isEmpty ? nil : label }
    }

    var summary: String {
        var parts: [String] = []
        if let tier { parts.append("tier \(tier.rawValue)") }
        if rules != nil { parts.append("rules") }
        if tags != nil { parts.append("tags") }
        if let leasePolicy { parts.append(leasePolicy.everyUseAsks ? "every use asks" : "leases up to \(Int(leasePolicy.leaseSeconds / 3600))h") }
        if aws != nil { parts.append("AWS role") }
        if label != nil { parts.append("label") }
        return parts.joined(separator: ", ")
    }

    /// What it changes, as the headline names it: "rules", "tier"...
    var changes: [String] {
        var parts: [String] = []
        if tier != nil { parts.append("tier") }
        if rules != nil { parts.append("rules") }
        if tags != nil { parts.append("tags") }
        if leasePolicy != nil { parts.append("lease time") }
        if aws != nil { parts.append("AWS role") }
        if label != nil { parts.append("label") }
        return parts
    }

    /// The proposed values, one line each, for the detail sheet.
    var changeLines: [String] {
        var lines: [String] = []
        if let tier { lines.append("Tier: \(tier.label)") }
        if let rules { lines.append("Rules: \(rules.isEmpty ? "(none)" : rules)") }
        if let tags { lines.append("Tags: \(tags.isEmpty ? "(none)" : tags.joined(separator: ", "))") }
        if let leasePolicy {
            lines.append(leasePolicy.everyUseAsks ? "Lease time: every use asks" : "Lease time: \(AttentionCopy.duration(leasePolicy.leaseSeconds))")
        }
        if let aws { lines.append("AWS role: \(aws.roleArn ?? "none (session token)") from \(aws.sourceSecret)") }
        if let label { lines.append("Label: \(label.isEmpty ? "(derived from the name)" : label)") }
        return lines
    }
}

/// What a vault route answers: granted (with values), pending (poll
/// `GET /v1/vault/pending/{id}`), or denied.
public struct VaultResponse: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case granted, pending, denied
    }

    public var status: Status
    public var message: String
    public var id: String?
    public var values: [String: String]?
    /// Names a hook-wrapped command went on without.
    public var skipped: [String]?
    public var credentials: AwsProcessCredentials?
    public var card: String?
    /// Values by environment variable, for the `keys` and the group of a release.
    public var env: [String: String]?
    /// What was asked for (a name or an environment variable) -> the
    /// secret it resolved to; a dry-run rename: old name -> its outcome.
    public var resolved: [String: String]?

    public init(status: Status, message: String, id: String? = nil, values: [String: String]? = nil,
                skipped: [String]? = nil, credentials: AwsProcessCredentials? = nil, card: String? = nil,
                env: [String: String]? = nil, resolved: [String: String]? = nil) {
        self.status = status
        self.message = message
        self.id = id
        self.values = values
        self.skipped = skipped
        self.credentials = credentials
        self.card = card
        self.env = env
        self.resolved = resolved
    }

    static func denied(_ message: String) -> VaultResponse { .init(status: .denied, message: message) }
}

/// Decides every release of the vault: the policy, Jev, leases, the
/// human, the audit log. Shared by the Mac app and the headless server.
public actor VaultBroker {
    public let store: VaultStore
    public let jev: (any JevJudging)?
    public let approvals: (any VaultApprovals)?
    public let machine: String
    public let cardTitle: @Sendable (String) async -> String?
    /// A card's recent prompts for Jev, nil when its transcript is not here.
    public let cardPrompts: @Sendable (String) async -> CardPrompts?
    public let sts: @Sendable (AwsAccessKey, VaultAwsRole, String) async throws -> AwsProcessCredentials
    /// How long a hook-wrapped command reuses Jev's allow for the same card.
    public var hookReuse: TimeInterval = 10 * 60
    public var approvalTimeout: TimeInterval = VaultPolicy.approvalTimeout
    public var pollInterval: TimeInterval = 0.3
    /// How long an approved result that was not fetched stays for the caller that
    /// asked: a `credential_process` or a tool call often gives up before
    /// the human answers, and its next call takes the answer.
    public var unclaimedResultLifetime: TimeInterval = 10 * 60
    /// How long a fetched result stays for other callers waiting on the
    /// same request.
    public var claimedResultLifetime: TimeInterval = 30
    /// AWS credentials a card got are handed to it again while they are
    /// valid for longer than this.
    public var awsReuseMargin: TimeInterval = 15 * 60
    /// The vault projects of a folder, the most specific first.
    public var projectsOf: @Sendable (String?) -> [String] = { VaultProjects.candidates(forPath: $0) }

    /// One secret a release hands out, and what the caller asked for.
    struct Wanted: Sendable {
        var secret: VaultSecret
        /// A secret name (or an earlier name of it), or an environment variable.
        var requested: String
        /// Asked for as an environment variable: answered in `env`.
        var asEnv: Bool
    }

    struct LeaseWant: Codable, Sendable, Equatable {
        var name: String
        var scope: String?
    }

    enum PendingAction: Codable, Sendable, Equatable {
        case release(VaultReleaseRequest, [String])
        case lease([LeaseWant], reason: String)
        case add(VaultAddRequest)
        case edit([String], VaultEditRequest)
        case delete(String)
        case rename([VaultRename])
        case deleteMany([String])
        /// The keys the owner-only secrets are encrypted to, after the change.
        case owner([VaultOwnerRecipient])
    }

    private struct Pending: Sendable {
        var action: PendingAction
        var caller: VaultCaller
        var result: VaultResponse?
        var createdAt: Date
        var everyUseAsks: Bool
        var request: AttentionRequest
        /// The open request whose answer this one takes: the human sees
        /// one question for everything that asks the same thing.
        var joinedTo: String?
        /// When a caller first fetched the result.
        var claimedAt: Date?
    }

    /// AWS credentials handed to a card, kept in memory until they expire.
    private struct IssuedAws: Sendable {
        var credentials: AwsProcessCredentials
        var expiresAt: Date
        var issuedAt: Date
        var role: VaultAwsRole
        var secretUpdatedAt: Date
    }

    /// An open request as `pending.age` keeps it, so a restart of the
    /// master asks again and the caller's poll still finds it.
    struct SavedPending: Codable, Sendable {
        var id: String
        var action: PendingAction
        var caller: VaultCaller
        var createdAt: Date
        var everyUseAsks: Bool
        var request: AttentionRequest
        var joinedTo: String?
    }

    /// A value a device unlocked for a card lease, kept in memory for the
    /// lease's time. A restart forgets it and the next use asks again.
    private struct HeldValue: Sendable {
        var value: String
        var until: Date
    }

    static let lockedWhy = "it opens only with your Touch ID or Face ID"
    static let mintWhy = "its long-lived AWS key opens only with your Touch ID or Face ID"

    private var pending: [String: Pending] = [:]
    private var held: [String: HeldValue] = [:]
    /// What a device unlocked for a request, until the request settles.
    private var delivered: [String: VaultUnsealed] = [:]
    /// Credentials a device minted for a profile, in memory until they expire.
    private var awsHeld: [String: IssuedAws] = [:]
    private var awsIssued: [String: IssuedAws] = [:]
    private var hookAllows: [String: Date] = [:]
    private var restoring: Task<Void, Never>?

    public init(
        store: VaultStore,
        jev: (any JevJudging)?,
        approvals: (any VaultApprovals)?,
        machine: String,
        cardTitle: @escaping @Sendable (String) async -> String? = { _ in nil },
        cardPrompts: @escaping @Sendable (String) async -> CardPrompts? = { _ in nil },
        sts: @escaping @Sendable (AwsAccessKey, VaultAwsRole, String) async throws -> AwsProcessCredentials = { key, role, name in
            try await AwsSts(region: "us-east-1").credentials(key: key, role: role, sessionName: name)
        }
    ) {
        self.store = store
        self.jev = jev
        self.approvals = approvals
        self.machine = machine
        self.cardTitle = cardTitle
        self.cardPrompts = cardPrompts
        self.sts = sts
    }

    public func configure(approvalTimeout: TimeInterval? = nil, pollInterval: TimeInterval? = nil,
                          projectsOf: (@Sendable (String?) -> [String])? = nil,
                          unclaimedResultLifetime: TimeInterval? = nil, claimedResultLifetime: TimeInterval? = nil) {
        if let approvalTimeout { self.approvalTimeout = approvalTimeout }
        if let pollInterval { self.pollInterval = pollInterval }
        if let projectsOf { self.projectsOf = projectsOf }
        if let unclaimedResultLifetime { self.unclaimedResultLifetime = unclaimedResultLifetime }
        if let claimedResultLifetime { self.claimedResultLifetime = claimedResultLifetime }
    }

    // MARK: - Resolution

    /// The secrets a release asks for: the named ones as they are, each
    /// environment variable from the project (its own value for the
    /// environment, else the shared one), and the project's group.
    func wanted(for req: VaultReleaseRequest) async throws -> [Wanted] {
        var out: [Wanted] = []
        for name in req.names {
            guard let s = try await store.secret(name) else {
                throw VaultError.notFound("no secret named \(name) in the vault (add it: kv add \(name))")
            }
            out.append(Wanted(secret: s, requested: name, asEnv: false))
        }
        let keys = req.keys ?? []
        guard !keys.isEmpty || req.group == true else { return out }
        let projects = req.project.map { [$0] } ?? projectsOf(req.dir ?? req.cwd)
        let environment = req.environment ?? VaultSecretName.defaultEnvironment
        var seen = Set<String>()
        for key in keys where seen.insert(key).inserted {
            guard let s = try await store.resolve(key: key, projects: projects, environment: environment) else {
                let scope = projects.first.map { "for \($0) (\(environment)) nor a shared one" } ?? "in the vault"
                throw VaultError.notFound("no secret \(key) \(scope) (add it: kv set \(key))")
            }
            out.append(Wanted(secret: s, requested: key, asEnv: true))
        }
        if req.group == true {
            let skip = seen.union(req.defined ?? [])
            for s in try await store.group(projects: projects, environment: environment, nearest: req.nearest == true)
            where !skip.contains(s.key) {
                out.append(Wanted(secret: s, requested: s.key, asEnv: true))
            }
        }
        return out
    }

    /// What a release would hand out, names only: requested -> secret name.
    public func resolve(_ req: VaultReleaseRequest) async -> VaultResponse {
        do {
            let wanted = try await wanted(for: req)
            return VaultResponse(status: .granted, message: "resolved",
                                 resolved: Dictionary(wanted.map { ($0.requested, $0.secret.name) }) { first, _ in first })
        } catch let error as VaultError {
            if case .notFound(let why) = error { return .denied(why) }
            return .denied("the vault is locked on this machine: \(error)")
        } catch {
            return .denied("the vault is locked on this machine: \(error)")
        }
    }

    /// The values of the allowed secrets, under what the caller asked for.
    private func answer(_ wanted: [Wanted], allowed: Set<String>, unlocked: [String: String] = [:])
        -> (values: [String: String], env: [String: String]) {
        var values: [String: String] = [:]
        var env: [String: String] = [:]
        for w in wanted where allowed.contains(w.secret.name) {
            let value = w.secret.isSealed ? (unlocked[w.secret.name] ?? "") : w.secret.value
            if w.asEnv { env[w.requested] = value } else { values[w.requested] = value }
        }
        return (values, env)
    }

    // MARK: - Owner-only values

    /// The value a device unlocked for a lease on `name`, while it lasts.
    private func heldValue(_ s: VaultSecret, now: Date) -> String? {
        for name in s.allNames {
            guard let h = held[name] else { continue }
            if h.until > now { return h.value }
            held[name] = nil
        }
        return nil
    }

    /// The credentials a device minted for a profile, while they stay
    /// valid for a while and the profile is as it was.
    private func heldAws(_ s: VaultSecret, now: Date) -> IssuedAws? {
        guard let role = s.aws, !s.leasePolicy.everyUseAsks, let issued = awsHeld[s.name] else { return nil }
        guard issued.role == role, issued.secretUpdatedAt == s.updatedAt, issued.expiresAt.timeIntervalSince(now) > awsReuseMargin else {
            awsHeld[s.name] = nil
            return nil
        }
        return issued
    }

    /// The sealed long-lived key of an AWS profile, when only a device can
    /// mint its credentials.
    private func sealedSource(of s: VaultSecret) async -> VaultSecret? {
        guard let role = s.aws, let source = (try? await store.secret(role.sourceSecret)) ?? nil, source.isSealed else { return nil }
        return source
    }

    /// Whether handing out `s` first needs a device: its sealed value, or
    /// credentials only the device can mint.
    private func needsDevice(_ s: VaultSecret, now: Date) async -> String? {
        if s.aws != nil {
            guard await sealedSource(of: s) != nil, heldAws(s, now: now) == nil else { return nil }
            return Self.mintWhy
        }
        return s.isSealed && heldValue(s, now: now) == nil ? Self.lockedWhy : nil
    }

    /// What the answering device has to do with its key for `action`.
    private func challenge(for action: PendingAction, secrets: [VaultSecret], caller: VaultCaller, now: Date) async -> VaultUnsealChallenge {
        var out = VaultUnsealChallenge()
        switch action {
        case .release, .lease:
            for s in secrets {
                if let role = s.aws {
                    guard let source = await sealedSource(of: s), let item = source.unsealItem, heldAws(s, now: now) == nil else { continue }
                    out.aws.append(.init(profile: s.name, key: item, role: role, sessionName: "kanban-\(caller.cardId ?? "outside")"))
                } else if s.isSealed, heldValue(s, now: now) == nil, let item = s.unsealItem {
                    out.secrets.append(item)
                }
            }
        case .edit(_, let edit):
            if let tier = edit.tier, tier < .ask {
                for s in secrets where s.isSealed { if let item = s.unsealItem { out.secrets.append(item) } }
            }
        case .owner(let recipients):
            let sealed = ((try? await store.sealedItems()) ?? [])
            if !sealed.isEmpty {
                out.reseal = sealed
                out.resealTo = recipients
            }
        case .add, .delete, .deleteMany, .rename:
            break
        }
        return out
    }

    /// What the device unlocked for an open request. The request settles
    /// with it once its attention request is resolved.
    public func deliver(id: String, unsealed: VaultUnsealed) {
        guard let p = pending[id], p.result == nil else { return }
        delivered[p.joinedTo ?? id] = unsealed
    }

    // MARK: - Release

    public func release(_ req: VaultReleaseRequest, caller: VaultCaller, now: Date = Date()) async -> VaultResponse {
        let hook = req.mode == "hook"
        guard !req.names.isEmpty || !(req.keys ?? []).isEmpty || req.group == true else {
            return .denied("name at least one secret")
        }
        let wanted: [Wanted]
        do {
            wanted = try await self.wanted(for: req)
        } catch let error as VaultError {
            if case .notFound(let why) = error { return .denied(why) }
            return .denied("the vault is locked on this machine: \(error)")
        } catch {
            return .denied("the vault is locked on this machine: \(error)")
        }
        var known = Set<String>()
        let secrets = wanted.map(\.secret).filter { known.insert($0.name).inserted }
        let callerProjects = projectsOf(caller.cwd)

        if req.mode == "aws", secrets.count == 1, let reused = await reusedAws(secrets[0], req: req, caller: caller, now: now) {
            return reused
        }

        var allowed: [(VaultSecret, VaultDecider, String)] = []
        var asks: [(VaultSecret, String)] = []
        var denies: [(VaultSecret, String)] = []
        var judged: [VaultSecret] = []
        for s in secrets {
            if req.mode == "get" && (s.tier == .ask || s.leasePolicy.everyUseAsks) {
                denies.append((s, "kv get never prints a secret that asks; use kv run"))
                continue
            }
            if req.mode != "aws" && s.aws != nil {
                denies.append((s, "\(s.name) is an AWS profile: use kv aws"))
                continue
            }
            let verdict = await verdict(for: s, req: req, caller: caller, callerProjects: callerProjects, now: now)
            switch verdict {
            case .allow(let by, let why): allowed.append((s, by, why))
            case .ask(let why): asks.append((s, why))
            case .deny(let why): denies.append((s, why))
            case .consultJev: judged.append(s)
            }
        }
        for (s, answer) in await judge(judged, req: req, caller: caller) {
            switch answer {
            case .allow(let by, let why):
                allowed.append((s, by, why))
                if req.mode == "hook" { hookAllows[Self.reuseKey(caller, s)] = now }
            case .ask(let why): asks.append((s, why))
            case .deny(let why): denies.append((s, why))
            case .consultJev: asks.append((s, "Jev was not consulted"))
            }
        }

        // An owner-only value, or AWS credentials from a sealed key, come
        // from a device even when the policy allows the release.
        var unlocked: [String: String] = [:]
        var free: [(VaultSecret, VaultDecider, String)] = []
        for entry in allowed {
            let s = entry.0
            if let why = await needsDevice(s, now: now) {
                asks.append((s, why))
            } else {
                if s.isSealed, let value = heldValue(s, now: now) { unlocked[s.name] = value }
                free.append(entry)
            }
        }
        allowed = free

        // A hook-wrapped command goes on without what it was not given:
        // that is a skip, not a refusal of anything the agent asked for.
        for (s, why) in denies {
            await audit(s, req: req, caller: caller, outcome: hook ? .skipped : .denied,
                        decider: why.hasPrefix("Jev") ? .jev : .rule, detail: why)
        }

        if hook {
            for (s, why) in asks {
                await audit(s, req: req, caller: caller, outcome: .skipped, decider: .rule, detail: why)
            }
            for (s, by, why) in allowed {
                await audit(s, req: req, caller: caller, outcome: .allowed, decider: by, detail: why)
            }
            let given = answer(wanted, allowed: Set(allowed.map(\.0.name)), unlocked: unlocked)
            let left = (asks.map(\.0.name) + denies.map(\.0.name)).sorted()
            let skipped = wanted.filter { left.contains($0.secret.name) }.map(\.requested).sorted()
            let message = left.isEmpty ? "released" : "went on without \(left.joined(separator: ", ")) (kv request \(left.joined(separator: " ")) --reason \"...\" to ask for them)"
            return VaultResponse(status: .granted, message: message, values: given.values, skipped: skipped, card: caller.cardId,
                                 env: given.env, resolved: Dictionary(wanted.map { ($0.requested, $0.secret.name) }) { first, _ in first })
        }

        if !denies.isEmpty {
            // Jev's verdict carries no explanation: the rules it read are the why.
            let lines = denies.map { s, why in
                why.hasPrefix("Jev") && !s.rules.isEmpty ? "\(s.name): \(why). Its rules: \(s.rules)" : "\(s.name): \(why)"
            }.joined(separator: "\n  ")
            return .denied("denied:\n  \(lines)")
        }
        if asks.isEmpty {
            return await grant(allowed.map { ($0.0, $0.1, $0.2) }, wanted: wanted, req: req, caller: caller, now: now,
                               unlocked: unlocked)
        }
        return await ask(
            action: .release(req, asks.map(\.0.name)),
            secrets: asks.map(\.0), whys: asks.map(\.1), caller: caller,
            command: req.command, reason: req.reason, now: now
        )
    }

    private func verdict(for s: VaultSecret, req: VaultReleaseRequest, caller: VaultCaller, callerProjects: [String],
                         now: Date) async -> VaultVerdict {
        let lease = caller.cardId.flatMap { _ in caller.insideCard ? caller.cardId : nil }
        var hasLease = false
        if let card = lease {
            for name in s.allNames where !hasLease {
                hasLease = await store.activeLease(cardId: card, secret: name, now: now) != nil
            }
        }
        let reusing = req.mode == "hook" && caller.remoteDevice == nil
            && (hookAllows[Self.reuseKey(caller, s)].map { now.timeIntervalSince($0) < hookReuse } ?? false)
        let input = VaultDecisionInput(
            tier: s.tier, everyUseAsks: s.leasePolicy.everyUseAsks, insideCard: caller.insideCard,
            overNetwork: caller.remoteDevice != nil,
            // Hook-wrapped commands load the env on every Bash call: that
            // volume is ambient, so it neither counts nor trips the limit.
            hasLease: hasLease, recentReleases: req.mode == "hook" ? 0 : await store.recentReleases(s.name, now: now),
            ownProjectDev: VaultPolicy.isOwnProjectDev(s, caller: caller, callerProjects: callerProjects)
        )
        let first = VaultPolicy.decide(input)
        guard first == .consultJev else { return first }
        if reusing { return .allow(.jev, caller.insideCard ? "reused Jev's allow for this card" : "reused Jev's allow for this caller") }
        return .consultJev
    }

    /// Under which a hook-wrapped command reuses Jev's allow: the card, or
    /// for a caller outside a card what it claims and where it runs.
    private static func reuseKey(_ caller: VaultCaller, _ s: VaultSecret) -> String {
        "\(principalKey(caller))|\(s.name)"
    }

    /// Asks Jev about the judged secrets: one question per distinct rules
    /// text, naming every secret under those rules. The answer is the
    /// verdict of each of them.
    private func judge(_ secrets: [VaultSecret], req: VaultReleaseRequest, caller: VaultCaller) async -> [(VaultSecret, VaultVerdict)] {
        guard !secrets.isEmpty else { return [] }
        guard let jev else { return secrets.map { ($0, VaultPolicy.afterJev(nil)) } }
        let title = await principalTitle(of: caller)
        // Only a session the master matched to a card is read: a claimed id
        // must not borrow another card's prompts.
        var prompts: CardPrompts?
        if let card = caller.cardId, caller.insideCard, VaultCaller.openClawAgent(principal: card) == nil {
            prompts = await cardPrompts(card)
        }
        var byRules: [(rules: String, indexes: [Int])] = []
        for (i, s) in secrets.enumerated() {
            if let at = byRules.firstIndex(where: { $0.rules == s.rules }) {
                byRules[at].indexes.append(i)
            } else {
                byRules.append((s.rules, [i]))
            }
        }
        return await withTaskGroup(of: ([Int], VaultVerdict).self) { group in
            for (rules, indexes) in byRules {
                let names = indexes.map { secrets[$0].name }
                let question = JevReleaseQuestion(
                    secrets: names, rules: rules, command: req.command ?? "(no command given)",
                    reason: req.reason, cardTitle: title, cwd: req.cwd, prompts: prompts,
                    processChain: caller.insideCard ? nil : caller.processChain, outsideCard: !caller.insideCard
                )
                let subject = "\(names.joined(separator: ", ")) for \(caller.cardId ?? "outside")"
                let evidence = prompts.map { "\($0.typed.count + $0.earlier.count) prompts entered in the card, \($0.delivered.count) from other senders" }
                    ?? "no card transcript"
                group.addTask {
                    let verdict = await jev.judge(question)
                    let answer = verdict.map { "\($0.choice.rawValue) \(Int(($0.confidence * 100).rounded()))%" } ?? "no answer"
                    KanbanCodeLog.info("vault", "Jev on \(subject): \(answer) (\(evidence))")
                    return (indexes, VaultPolicy.afterJev(verdict, insideCard: !question.outsideCard))
                }
            }
            var out = [(VaultSecret, VaultVerdict)?](repeating: nil, count: secrets.count)
            for await (indexes, verdict) in group {
                for i in indexes { out[i] = (secrets[i], verdict) }
            }
            return out.compactMap { $0 }
        }
    }

    /// The credentials this card already got for the profile, while they
    /// stay valid for a while: the card holds them for their whole hour, so
    /// handing them over again releases nothing new. No new decision, no
    /// STS call, and it does not count toward the rate limit. Tools that
    /// run `credential_process` on every call (kubectl through `aws eks
    /// get-token`, terraform providers) ask many times a minute.
    private func reusedAws(_ s: VaultSecret, req: VaultReleaseRequest, caller: VaultCaller, now: Date) async -> VaultResponse? {
        guard caller.insideCard, let card = caller.cardId, let role = s.aws,
              s.tier != .never, !s.leasePolicy.everyUseAsks else { return nil }
        let key = "\(card)|\(s.name)"
        guard let issued = awsIssued[key] else { return nil }
        guard issued.role == role, issued.secretUpdatedAt == s.updatedAt,
              issued.expiresAt.timeIntervalSince(now) > awsReuseMargin else {
            if issued.expiresAt <= now || issued.role != role || issued.secretUpdatedAt != s.updatedAt { awsIssued[key] = nil }
            return nil
        }
        let minutes = Int(issued.expiresAt.timeIntervalSince(now) / 60)
        await audit(s, req: req, caller: caller, outcome: .allowed, decider: .reuse,
                    detail: "the credentials this card got \(Int(now.timeIntervalSince(issued.issuedAt) / 60)) min ago, valid for \(minutes) more")
        return VaultResponse(status: .granted, message: "released", credentials: issued.credentials, card: card)
    }

    /// Drops what the vault remembers of AWS credentials handed out, so the
    /// next `kv aws` is decided again.
    public func forgetIssuedAws() {
        awsIssued = [:]
        awsHeld = [:]
    }

    /// Drops every value and credential a device unlocked that is still
    /// held in memory.
    public func forgetHeld() {
        held = [:]
        awsHeld = [:]
    }

    private func grant(_ allowed: [(VaultSecret, VaultDecider, String)], wanted: [Wanted], req: VaultReleaseRequest,
                       caller: VaultCaller, now: Date, requestId: String? = nil, unlocked: [String: String] = [:],
                       minted: [String: AwsProcessCredentials] = [:]) async -> VaultResponse {
        if req.mode == "aws" {
            guard let s = allowed.first?.0, let role = s.aws else { return .denied("not an AWS profile") }
            let credentials: AwsProcessCredentials
            var note: String?
            if let fresh = minted[s.name] {
                credentials = fresh
                if !s.leasePolicy.everyUseAsks, let expires = fresh.expiresAt {
                    awsHeld[s.name] = IssuedAws(credentials: fresh, expiresAt: expires, issuedAt: now, role: role, secretUpdatedAt: s.updatedAt)
                }
                note = "minted on the device"
            } else if await sealedSource(of: s) != nil {
                guard let kept = heldAws(s, now: now) else {
                    return .denied("\(s.name): its credentials are minted on Rogerio's Mac or phone, and none are held; ask again")
                }
                credentials = kept.credentials
                note = "credentials a device minted \(Int(now.timeIntervalSince(kept.issuedAt) / 60)) min ago"
            } else {
                do {
                    guard let source = try await store.secret(role.sourceSecret) else {
                        return .denied("the AWS key \(role.sourceSecret) is not in the vault")
                    }
                    let key = try JSONDecoder().decode(AwsAccessKey.self, from: Data(source.value.utf8))
                    credentials = try await sts(key, role, "kanban-\(caller.cardId ?? "outside")")
                } catch {
                    return .denied("STS failed: \(error)")
                }
            }
            for (s, by, why) in allowed {
                await store.recordRelease(s.name, now: now)
                await audit(s, req: req, caller: caller, outcome: .allowed, decider: by,
                            detail: [why, note].compactMap { $0 }.joined(separator: ", "), requestId: requestId)
            }
            if caller.insideCard, let card = caller.cardId, let expires = credentials.expiresAt {
                awsIssued["\(card)|\(s.name)"] = IssuedAws(credentials: credentials, expiresAt: expires, issuedAt: now,
                                                           role: role, secretUpdatedAt: s.updatedAt)
            }
            return VaultResponse(status: .granted, message: "released", id: requestId, credentials: credentials, card: caller.cardId)
        }
        let missing = allowed.map(\.0).filter { $0.isSealed && unlocked[$0.name] == nil }
        guard missing.isEmpty else {
            return .denied("\(missing.map(\.name).joined(separator: ", ")): approved, but not unlocked on a device. Ask again; Rogerio answers in Kanban Code on his Mac or phone")
        }
        for (s, by, why) in allowed {
            await store.recordRelease(s.name, now: now)
            await audit(s, req: req, caller: caller, outcome: .allowed, decider: by, detail: why, requestId: requestId)
        }
        let given = answer(wanted, allowed: Set(allowed.map(\.0.name)), unlocked: unlocked)
        return VaultResponse(status: .granted, message: "released", id: requestId, values: given.values, card: caller.cardId,
                             env: given.env, resolved: Dictionary(wanted.map { ($0.requested, $0.secret.name) }) { first, _ in first })
    }

    /// A card's title, or "OpenClaw agent <id>" for an OpenClaw principal.
    private func principalTitle(of caller: VaultCaller) async -> String? {
        guard let card = caller.cardId else { return nil }
        if let title = await principalTitle(card) { return title }
        return caller.peerTitle
    }

    private func principalTitle(_ id: String) async -> String? {
        if let agent = VaultCaller.openClawAgent(principal: id) { return "OpenClaw agent \(agent)" }
        return await cardTitle(id)
    }

    // MARK: - Leases

    public func requestLease(_ req: VaultLeaseRequest, caller: VaultCaller, now: Date = Date()) async -> VaultResponse {
        guard let card = caller.cardId, caller.insideCard else {
            return .denied("leases are for card sessions: run kv request from inside a Kanban card")
        }
        var wanted: [LeaseWant] = []
        var secrets: [VaultSecret] = []
        for raw in req.names {
            let (name, scope) = Self.splitScope(raw)
            guard let s = (try? await store.secret(name)) ?? nil else {
                return .denied("no secret named \(name) in the vault")
            }
            if s.tier == .never { return .denied("\(name) is never released") }
            if s.leasePolicy.everyUseAsks { return .denied("every use of \(name) asks; no lease is possible, use kv run") }
            if await store.activeLease(cardId: card, secret: s.name, now: now) == nil {
                wanted.append(LeaseWant(name: s.name, scope: scope))
                secrets.append(s)
            }
        }
        guard !wanted.isEmpty else {
            return VaultResponse(status: .granted, message: "the card already holds leases on all of them", card: card)
        }
        return await ask(
            action: .lease(wanted, reason: req.reason), secrets: secrets,
            whys: secrets.map { _ in "lease for the card's task" }, caller: caller,
            command: nil, reason: req.reason, now: now, leaseOnly: true
        )
    }

    public static func splitScope(_ raw: String) -> (String, String?) {
        // AWS profile names carry colons themselves (aws:lw-prod:read):
        // only a trailing ":scope" after a known secret splits.
        guard let colon = raw.lastIndex(of: ":"), !raw.hasPrefix("aws:") else { return (raw, nil) }
        let scope = String(raw[raw.index(after: colon)...])
        return scope.isEmpty ? (raw, nil) : (String(raw[..<colon]), scope)
    }

    // MARK: - Admin

    /// Adds a secret. A new name is added at once; replacing a value
    /// someone else stored needs the human unless `trusted`. A request
    /// that carries only the value the secret already holds changes
    /// nothing and asks nothing.
    public func add(_ req: VaultAddRequest, caller: VaultCaller, trusted: Bool, now: Date = Date()) async -> VaultResponse {
        guard let name = storedName(for: req) else {
            return .denied("no project for this folder: give --project <name>, or leave the project out for a shared secret")
        }
        guard VaultSecret.isValidName(name) else {
            return .denied("secret names use letters, digits and _ - . / : only")
        }
        let existing = (try? await store.secret(name)) ?? nil
        if let existing, req.onlyValue, await compare(req).outcome == .same {
            return VaultResponse(status: .granted, message: "\(existing.name) already holds this value")
        }
        if existing != nil && !trusted {
            return await ask(action: .add(req), secrets: [existing!], whys: ["replacing a stored value always asks"], caller: caller,
                             command: nil, reason: req.reason, now: now, leaseOnly: false, admin: true)
        }
        return await apply(.add(req), caller: caller, now: now)
    }

    /// How the value of `req` compares with the secret stored under its
    /// name, without writing anything: a composer asks this before it
    /// offers to replace a secret. A sealed value cannot be read here, so
    /// it always answers `different`.
    public func compare(_ req: VaultAddRequest) async -> VaultValueCheck {
        guard let name = storedName(for: req), let existing = (try? await store.secret(name)) ?? nil else {
            return VaultValueCheck(name: storedName(for: req) ?? req.name, outcome: .absent)
        }
        let same = existing.sealed == nil && !existing.value.isEmpty && existing.value == req.value
        return VaultValueCheck(name: existing.name, outcome: same ? .same : .different)
    }

    /// The name an add stores under: `project/environment/KEY` when it
    /// names a project ("." is the project of the caller's folder), else
    /// the name as given.
    func storedName(for req: VaultAddRequest) -> String? {
        guard let given = req.project, !given.isEmpty else { return req.name }
        let project = given == "." ? projectsOf(req.dir).first : given
        guard let project else { return nil }
        return VaultSecretName(key: req.name, project: project, environment: req.environment).canonical
    }

    /// New names for several secrets, in one approval; the old names stay
    /// as aliases. A dry run answers what each rename would do.
    public func rename(_ req: VaultRenameRequest, caller: VaultCaller, trusted: Bool, now: Date = Date()) async -> VaultResponse {
        guard !req.renames.isEmpty else { return .denied("name at least one rename") }
        var outcomes: [String: String] = [:]
        var secrets: [VaultSecret] = []
        var todo: [VaultRename] = []
        do {
            for r in req.renames {
                guard VaultSecret.isValidName(r.to) else { return .denied("secret names use letters, digits and _ - . / : (got \(r.to))") }
                let outcome = try await store.renameOutcome(from: r.from, to: r.to)
                outcomes[r.from] = outcome.rawValue
                if outcome == .rename || outcome == .merge, let s = try await store.secret(r.from) {
                    secrets.append(s)
                    todo.append(r)
                }
            }
        } catch {
            return .denied("the vault is locked on this machine: \(error)")
        }
        if req.dryRun == true {
            return VaultResponse(status: .granted, message: "dry run", resolved: outcomes)
        }
        guard !todo.isEmpty else { return VaultResponse(status: .granted, message: "nothing to rename", resolved: outcomes) }
        if !trusted {
            return await ask(action: .rename(todo), secrets: secrets, whys: secrets.map { _ in "renaming a secret always asks" },
                             caller: caller, command: nil, reason: req.reason, now: now, leaseOnly: false, admin: true)
        }
        return await apply(.rename(todo), caller: caller, now: now)
    }

    /// `unsealed` is what this machine's own key opened, for a trusted
    /// edit that lowers a sealed secret's tier.
    public func edit(_ name: String, _ req: VaultEditRequest, caller: VaultCaller, trusted: Bool, unsealed: VaultUnsealed? = nil,
                     now: Date = Date()) async -> VaultResponse {
        guard let s = (try? await store.secret(name)) ?? nil else { return .denied("no secret named \(name)") }
        if !trusted {
            return await ask(action: .edit([name], req), secrets: [s], whys: ["changing a secret always asks"], caller: caller,
                             command: nil, reason: req.reason, now: now, leaseOnly: false, admin: true)
        }
        return await apply(.edit([name], req), caller: caller, now: now, unsealed: unsealed)
    }

    /// What a device has to open before `edit` can apply to `name`: the
    /// sealed value, when the edit lowers the tier below ask.
    public func editChallenge(_ name: String, _ req: VaultEditRequest) async -> VaultUnsealChallenge {
        guard let s = (try? await store.secret(name)) ?? nil else { return VaultUnsealChallenge() }
        return await challenge(for: .edit([s.name], req), secrets: [s], caller: VaultCaller(), now: Date())
    }

    // MARK: - Owner keys

    /// What a device has to encrypt again before the owner keys become
    /// `recipients`.
    public func ownerChallenge(_ recipients: [VaultOwnerRecipient]) async -> VaultUnsealChallenge {
        await challenge(for: .owner(recipients), secrets: [], caller: VaultCaller(), now: Date())
    }

    /// Changes the keys the owner-only secrets are encrypted to. With
    /// sealed secrets in the vault, a device that already holds a key
    /// encrypts each of them again to the new keys.
    public func setOwnerKeys(_ recipients: [VaultOwnerRecipient], caller: VaultCaller, trusted: Bool, unsealed: VaultUnsealed? = nil,
                             reason: String? = nil, now: Date = Date()) async -> VaultResponse {
        for r in recipients {
            guard (try? Age.AnyRecipient(text: r.publicKey)) != nil else { return .denied("\(r.name): not an age public key") }
        }
        guard Set(recipients.map(\.publicKey)).count == recipients.count else { return .denied("the same key twice") }
        if !trusted {
            return await ask(action: .owner(recipients), secrets: [], whys: ["changing the owner keys always asks"], caller: caller,
                             command: nil, reason: reason, now: now, leaseOnly: false, admin: true)
        }
        return await apply(.owner(recipients), caller: caller, now: now, unsealed: unsealed)
    }

    /// One more key for the owner-only secrets: a device that wants to
    /// answer approvals. The human compares its fingerprint and approves
    /// on a device that already holds a key.
    public func enrol(_ recipient: VaultOwnerRecipient, caller: VaultCaller, now: Date = Date()) async -> VaultResponse {
        let current = ((try? await store.owner()) ?? nil)?.recipients ?? []
        if current.contains(where: { $0.publicKey == recipient.publicKey }) {
            return VaultResponse(status: .granted, message: "\(recipient.name) already holds an owner key (\(recipient.fingerprint))")
        }
        return await setOwnerKeys(current + [recipient], caller: caller, trusted: false,
                                  reason: "Let \(recipient.name) unlock the owner-only secrets", now: now)
    }

    /// The same change to several secrets, in one approval: the names given
    /// plus every secret whose value starts with one of `valuePrefixes`
    /// (matched here on the master; values never leave it).
    public func editMany(_ request: VaultBatchEditRequest, caller: VaultCaller, trusted: Bool, now: Date = Date()) async -> VaultResponse {
        var wanted = Set(request.names ?? [])
        let prefixes = (request.valuePrefixes ?? []).filter { !$0.isEmpty }
        var secrets: [VaultSecret] = []
        do {
            if !prefixes.isEmpty {
                for info in try await store.list() {
                    if let s = try await store.secret(info.name), prefixes.contains(where: { s.value.hasPrefix($0) }) {
                        wanted.insert(s.name)
                    }
                }
            }
            for name in wanted.sorted() {
                guard let s = try await store.secret(name) else { return .denied("no secret named \(name)") }
                secrets.append(s)
            }
        } catch {
            return .denied("the vault is locked on this machine: \(error)")
        }
        guard !secrets.isEmpty else { return .denied("no secret matches") }
        let names = secrets.map(\.name)
        if !trusted {
            return await ask(action: .edit(names, request.edit), secrets: secrets,
                             whys: secrets.map { _ in "changing a secret always asks" }, caller: caller,
                             command: nil, reason: request.edit.reason, now: now, leaseOnly: false, admin: true)
        }
        return await apply(.edit(names, request.edit), caller: caller, now: now)
    }

    public func delete(_ name: String, caller: VaultCaller, trusted: Bool, reason: String? = nil, now: Date = Date()) async -> VaultResponse {
        guard let s = (try? await store.secret(name)) ?? nil else { return .denied("no secret named \(name)") }
        if !trusted {
            return await ask(action: .delete(name), secrets: [s], whys: ["deleting a secret always asks"], caller: caller,
                             command: nil, reason: reason, now: now, leaseOnly: false, admin: true)
        }
        return await apply(.delete(name), caller: caller, now: now)
    }

    /// Deletes several secrets in one approval. A dry run answers what
    /// each name would do: "delete", or "missing" for a name not in the vault.
    public func deleteMany(_ req: VaultDeleteRequest, caller: VaultCaller, trusted: Bool, now: Date = Date()) async -> VaultResponse {
        guard !req.names.isEmpty else { return .denied("name at least one secret") }
        var outcomes: [String: String] = [:]
        var secrets: [VaultSecret] = []
        var seen = Set<String>()
        do {
            for name in req.names {
                guard let s = try await store.secret(name) else {
                    outcomes[name] = "missing"
                    continue
                }
                outcomes[name] = s.name == name ? "delete" : "delete \(s.name) (\(name) is an earlier name of it)"
                if seen.insert(s.name).inserted { secrets.append(s) }
            }
        } catch {
            return .denied("the vault is locked on this machine: \(error)")
        }
        if req.dryRun == true {
            return VaultResponse(status: .granted, message: "dry run", resolved: outcomes)
        }
        guard !secrets.isEmpty else { return VaultResponse(status: .granted, message: "nothing to delete", resolved: outcomes) }
        let names = secrets.map(\.name)
        if !trusted {
            return await ask(action: .deleteMany(names), secrets: secrets, whys: secrets.map { _ in "deleting a secret always asks" },
                             caller: caller, command: nil, reason: req.reason, now: now, leaseOnly: false, admin: true)
        }
        return await apply(.deleteMany(names), caller: caller, now: now)
    }

    private func apply(_ action: PendingAction, caller: VaultCaller, now: Date, by: VaultDecider = .rule, requestId: String? = nil,
                       unsealed: VaultUnsealed? = nil) async -> VaultResponse {
        do {
            switch action {
            case .add(let req):
                guard let wantedName = storedName(for: req) else { return .denied("no project for this folder") }
                let existing = try await store.secret(wantedName)
                let name = existing?.name ?? wantedName
                let secret = VaultSecret(
                    name: name, value: req.value,
                    tier: req.tier ?? existing?.tier ?? .judged,
                    rules: req.rules ?? existing?.rules ?? "",
                    leasePolicy: req.leasePolicy ?? existing?.leasePolicy ?? .standard,
                    tags: req.tags ?? existing?.tags ?? [],
                    aws: req.aws ?? existing?.aws,
                    sources: Array(Set((existing?.sources ?? []) + (req.sources ?? []))).sorted(),
                    createdAt: existing?.createdAt ?? now,
                    label: req.label.flatMap { $0.isEmpty ? nil : $0 } ?? existing?.label,
                    aliases: existing?.aliases
                )
                try await store.upsert(secret, now: now)
                await store.append(VaultAuditEntry(at: now, machine: machine, cardId: caller.cardId, sessionId: caller.sessionId,
                                                   secret: name, tier: secret.tier, outcome: .allowed, decider: by,
                                                   action: existing == nil ? "add" : "replace", requestId: requestId))
                return VaultResponse(status: .granted, message: existing == nil ? "added \(name)" : "replaced \(name)", id: requestId)
            case .edit(let names, let req):
                for name in names {
                    try await store.update(name, unsealedValue: unsealed?.values[name], now: now) { req.apply(to: &$0) }
                    await store.append(VaultAuditEntry(at: now, machine: machine, cardId: caller.cardId, sessionId: caller.sessionId,
                                                       secret: name, tier: req.tier, outcome: .allowed, decider: by,
                                                       action: "edit", detail: req.summary, requestId: requestId))
                }
                return VaultResponse(status: .granted, message: "changed \(names.joined(separator: ", ")): \(req.summary)", id: requestId)
            case .delete(let name):
                try await store.delete(name, now: now)
                await store.append(VaultAuditEntry(at: now, machine: machine, cardId: caller.cardId, sessionId: caller.sessionId,
                                                   secret: name, tier: nil, outcome: .allowed, decider: by,
                                                   action: "delete", requestId: requestId))
                return VaultResponse(status: .granted, message: "deleted \(name)", id: requestId)
            case .deleteMany(let names):
                var outcomes: [String: String] = [:]
                var done = 0
                for name in names {
                    guard try await store.secret(name) != nil else {
                        outcomes[name] = "missing"
                        continue
                    }
                    try await store.delete(name, now: now)
                    outcomes[name] = "deleted"
                    done += 1
                    await store.append(VaultAuditEntry(at: now, machine: machine, cardId: caller.cardId, sessionId: caller.sessionId,
                                                       secret: name, tier: nil, outcome: .allowed, decider: by,
                                                       action: "delete", requestId: requestId))
                }
                return VaultResponse(status: .granted, message: "deleted \(done) of \(names.count) secrets", id: requestId,
                                     resolved: outcomes)
            case .rename(let renames):
                var outcomes: [String: String] = [:]
                var done = 0
                for r in renames {
                    let outcome = try await store.rename(from: r.from, to: r.to, now: now)
                    outcomes[r.from] = outcome.rawValue
                    guard outcome == .rename || outcome == .merge else { continue }
                    done += 1
                    await store.append(VaultAuditEntry(at: now, machine: machine, cardId: caller.cardId, sessionId: caller.sessionId,
                                                       secret: r.to, tier: nil, outcome: .allowed, decider: by, action: "rename",
                                                       detail: outcome == .merge ? "merged \(r.from) into it" : "was \(r.from)",
                                                       requestId: requestId))
                }
                return VaultResponse(status: .granted, message: "renamed \(done) of \(renames.count) secrets", id: requestId,
                                     resolved: outcomes)
            case .owner(let recipients):
                let before = try await store.owner()?.recipients ?? []
                try await store.setOwner(recipients, resealed: unsealed?.resealed ?? [:], now: now)
                let counts = try await store.ownerCounts()
                let added = recipients.filter { r in !before.contains { $0.publicKey == r.publicKey } }
                let removed = before.filter { r in !recipients.contains { $0.publicKey == r.publicKey } }
                let change = (added.map { "added \($0.name) \($0.fingerprint)" } + removed.map { "removed \($0.name) \($0.fingerprint)" })
                    .joined(separator: ", ")
                await store.append(VaultAuditEntry(at: now, machine: machine, cardId: caller.cardId, sessionId: caller.sessionId,
                                                   secret: Self.ownerKeysName, tier: nil, outcome: .allowed, decider: by, action: "owner",
                                                   detail: [change, unsealed.map { "encrypted again by key \($0.device)" }]
                                                       .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "; "),
                                                   requestId: requestId))
                return VaultResponse(status: .granted, message: "owner keys: \(recipients.map(\.name).joined(separator: ", ")); \(counts.sealed) secrets sealed", id: requestId)
            case .release, .lease:
                return .denied("not an admin action")
            }
        } catch {
            return .denied("\(error)")
        }
    }

    // MARK: - Asking the human

    private func ask(action: PendingAction, secrets: [VaultSecret], whys: [String], caller: VaultCaller,
                     command: String?, reason: String?, now: Date, leaseOnly: Bool = false, admin: Bool = false) async -> VaultResponse {
        guard let approvals else {
            return .denied("needs a human approval, and this master cannot ask for one")
        }
        let title = await principalTitle(of: caller)
        let everyUse = secrets.contains { $0.leasePolicy.everyUseAsks }
        let key = Self.joinKey(action, caller: caller)

        // The answer to this same request, given after its caller stopped
        // waiting: this call takes it.
        if let done = pending.first(where: {
            $0.value.claimedAt == nil && $0.value.result?.status == .granted
                && Self.joinKey($0.value.action, caller: $0.value.caller) == key && Self.sameShape($0.value.action, action)
        }), let result = done.value.result {
            claim(done.key, now: now)
            return result
        }

        // A request for the same thing is still open: no second question.
        if let open = pending.first(where: {
            $0.value.result == nil && $0.value.joinedTo == nil && Self.joinKey($0.value.action, caller: $0.value.caller) == key
        }) {
            let waiting = waitingMessage(caller: caller, title: title, reason: open.value.request.vault?.reason)
            if let same = pending.first(where: {
                $0.value.result == nil && ($0.key == open.key || $0.value.joinedTo == open.key) && Self.sameShape($0.value.action, action)
            }) {
                return VaultResponse(status: .pending, message: waiting, id: same.key, card: caller.cardId)
            }
            let joinedId = KSUID.generate(prefix: "vault")
            pending[joinedId] = Pending(action: action, caller: caller, result: nil, createdAt: now, everyUseAsks: everyUse,
                                        request: open.value.request, joinedTo: open.key)
            await persist()
            return VaultResponse(status: .pending, message: waiting, id: joinedId, card: caller.cardId)
        }

        let id = KSUID.generate(prefix: "vault")
        var options = VaultPolicy.approvalOptions(everyUseAsks: everyUse || admin, insideCard: caller.insideCard)
        if leaseOnly { options = [AttentionRequest.vaultApprovalOptions[0], AttentionRequest.vaultApprovalOptions[2]] }
        let details = approvalDetails(action: action, secrets: secrets, whys: whys, caller: caller, title: title,
                                      command: command, reason: reason, options: options)
        let challenge = await challenge(for: action, secrets: secrets, caller: caller, now: now)
        let request = AttentionRequest(
            id: id,
            cardId: caller.openClawAgent == nil ? caller.cardId : nil,
            kind: .vaultApproval,
            title: AttentionCopy.vaultHeadline(details),
            body: AttentionCopy.vaultBody(details),
            options: options,
            createdAt: now,
            requiresBiometry: admin || !challenge.isEmpty || secrets.contains { $0.tier >= .ask },
            sessionId: caller.sessionId,
            vault: details,
            unseal: challenge.isEmpty ? nil : challenge
        )
        pending[id] = Pending(action: action, caller: caller, result: nil, createdAt: now, everyUseAsks: everyUse, request: request)
        await persist()
        for (s, why) in zip(secrets, whys) {
            await store.append(VaultAuditEntry(at: now, machine: machine, cardId: caller.cardId, sessionId: caller.sessionId,
                                               secret: s.name, tier: s.tier, outcome: .asked, decider: .rule,
                                               action: actionName(action), command: command, reason: reason,
                                               detail: caller.auditNote.map { "\(why), \($0)" } ?? why, requestId: id))
        }
        await approvals.raise(request)
        Task { await self.waitForHuman(id: id) }
        return VaultResponse(status: .pending, message: waitingMessage(caller: caller, title: title, reason: reason),
                             id: id, card: caller.cardId)
    }

    private func waitingMessage(caller: VaultCaller, title: String?, reason: String?) -> String {
        var waitingOn = caller.insideCard
            ? "Waiting for Rogerio's approval on his phone or Mac (\(caller.openClawAgent == nil ? "card " : "")\(title ?? caller.cardId ?? "?"))"
            : "Waiting for Rogerio's approval on his phone or Mac (this process is not in a Kanban card session)"
        waitingOn += ", up to \(VaultPolicy.span(approvalTimeout))"
        if AttentionCopy.usableReason(reason) == nil {
            waitingOn += ". He sees no reason from you; next time: \(AttentionCopy.reasonGuidance)"
        }
        return waitingOn
    }

    /// Who asks, as far as joining goes: the verified card, or for a
    /// caller outside a card what it claims and where it runs.
    static func principalKey(_ caller: VaultCaller) -> String {
        if caller.insideCard, let card = caller.cardId { return "card:\(card)" }
        return "outside:\(caller.claimedCardId ?? "")|\(caller.remoteDevice ?? "")|\(caller.cwd ?? "")"
    }

    /// Two requests with the same key are one question to the human: the
    /// same caller, the same kind of action, the same secrets.
    static func joinKey(_ action: PendingAction, caller: VaultCaller) -> String {
        let what: String
        switch action {
        case .release(let req, let asked):
            what = "release|\(req.mode)|\(asked.sorted().joined(separator: ","))"
        case .lease(let wanted, _):
            what = "lease|\(wanted.map { "\($0.name):\($0.scope ?? "")" }.sorted().joined(separator: ","))"
        case .add(var req):
            req.reason = nil
            what = "add|\(digest(req))"
        case .edit(let names, var req):
            req.reason = nil
            what = "edit|\(names.sorted().joined(separator: ","))|\(digest(req))"
        case .delete(let name):
            what = "delete|\(name)"
        case .deleteMany(let names):
            what = "delete|\(names.sorted().joined(separator: ","))"
        case .rename(let renames):
            what = "rename|\(renames.map { "\($0.from)>\($0.to)" }.sorted().joined(separator: ","))"
        case .owner(let recipients):
            what = "owner|\(recipients.map(\.publicKey).sorted().joined(separator: ","))"
        }
        return principalKey(caller) + "|" + what
    }

    private static func digest<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: (try? encoder.encode(value)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }

    /// Two actions of one question that also get the same answer, so their
    /// callers can wait on one id. Releases differ in what each caller
    /// gets back; the command and the reason do not count.
    static func sameShape(_ a: PendingAction, _ b: PendingAction) -> Bool {
        switch (a, b) {
        case (.release(var x, let askedX), .release(var y, let askedY)):
            for clear in [\VaultReleaseRequest.command, \.reason, \.sessionId, \.cardId] as [WritableKeyPath<VaultReleaseRequest, String?>] {
                x[keyPath: clear] = nil
                y[keyPath: clear] = nil
            }
            return x == y && Set(askedX) == Set(askedY)
        case (.release, _), (_, .release):
            return false
        default:
            return true
        }
    }

    /// What the detail sheet shows for a request about to be raised.
    private func approvalDetails(action: PendingAction, secrets: [VaultSecret], whys: [String], caller: VaultCaller,
                                 title: String?, command: String?, reason: String?, options: [String]) -> VaultApprovalDetails {
        var kind: VaultApprovalDetails.Action
        var mode: String?
        var cwd: String?
        var changes: [String] = []
        var changeLines: [String] = []
        switch action {
        case .release(let req, _):
            kind = req.mode == "aws" ? .aws : .use
            mode = req.mode
            cwd = req.cwd
        case .lease:
            kind = .lease
        case .add:
            kind = .replace
        case .edit(_, let req):
            kind = .edit
            changes = req.changes
            changeLines = req.changeLines
        case .delete, .deleteMany:
            kind = .delete
        case .rename(let renames):
            kind = .edit
            changes = ["name"]
            changeLines = renames.prefix(400).map { "\($0.from) -> \($0.to)" }
        case .owner(let recipients):
            kind = .ownerKeys
            changeLines = recipients.map { "\($0.name) (\($0.kind.rawValue)): \($0.fingerprint)" }
        }
        let origin: VaultApprovalDetails.Origin =
            caller.openClawAgent != nil ? .openClaw : (caller.insideCard ? .card : .outside)
        let offersLease = options.contains(AttentionRequest.vaultApprovalOptions[0])
        return VaultApprovalDetails(
            action: kind,
            origin: origin,
            principal: caller.openClawAgent ?? (caller.insideCard ? (title ?? caller.cardId) : nil),
            secrets: secrets.map {
                .init(name: $0.name, label: $0.displayLabel, tier: $0.tier.label, everyUseAsks: $0.leasePolicy.everyUseAsks)
            },
            mode: mode,
            changes: changes,
            changeLines: changeLines,
            whys: Array(Set(whys)).sorted(),
            command: command.map { String($0.prefix(2000)) },
            cwd: cwd,
            reason: reason,
            leaseSeconds: offersLease ? secrets.map(\.leasePolicy.leaseSeconds).min() : nil,
            claimedCardId: caller.insideCard ? nil : caller.claimedCardId,
            remoteDevice: caller.remoteDevice,
            ancestry: caller.ancestry,
            cardOrigin: caller.peerOrigin
        )
    }

    private func actionName(_ action: PendingAction) -> String {
        switch action {
        case .release(let req, _): req.mode
        case .lease: "lease"
        case .add: "replace"
        case .edit: "edit"
        case .delete, .deleteMany: "delete"
        case .rename: "rename"
        case .owner: "owner"
        }
    }

    static let ownerKeysName = "owner-keys"

    private func waitForHuman(id: String) async {
        guard let approvals, let started = pending[id]?.createdAt else { return }
        while Date().timeIntervalSince(started) < approvalTimeout {
            if let answer = await approvals.resolution(of: id) {
                await settle(id: id, approval: VaultPolicy.approval(from: answer.resolution), by: answer.by)
                return
            }
            try? await Task.sleep(for: .seconds(pollInterval))
        }
        await approvals.close(id: id, resolution: "Deny", by: "timeout")
        await settle(id: id, approval: .deny, by: "timeout")
    }

    private func settle(id: String, approval: VaultPolicy.Approval, by: String) async {
        guard let p = pending[id], p.result == nil, p.joinedTo == nil else { return }
        let now = Date()
        let unsealed = delivered.removeValue(forKey: id)
        // A yes past the rate limit starts the count again: the human saw
        // the volume and allowed it.
        if approval != .deny, case .release(_, let asked) = p.action {
            for name in asked { await store.resetReleases(name) }
        }
        var leasedTo: String?
        if approval == .lease, case .release(let req, let asked) = p.action,
           let card = p.caller.cardId, p.caller.insideCard, !p.everyUseAsks {
            for name in asked {
                let policy = ((try? await store.secret(name)) ?? nil)?.leasePolicy ?? .standard
                try? await store.grantLease(VaultLease(cardId: card, secret: name, reason: req.reason, grantedAt: now,
                                                       expiresAt: now.addingTimeInterval(policy.leaseSeconds), grantedBy: "human:\(by)"))
                if let value = unsealed?.values[name] { held[name] = HeldValue(value: value, until: now.addingTimeInterval(policy.leaseSeconds)) }
            }
            leasedTo = card
        }
        if approval != .deny, case .lease(let wanted, _) = p.action {
            for want in wanted {
                guard let value = unsealed?.values[want.name] else { continue }
                let policy = ((try? await store.secret(want.name)) ?? nil)?.leasePolicy ?? .standard
                held[want.name] = HeldValue(value: value, until: now.addingTimeInterval(policy.leaseSeconds))
            }
            for (profile, credentials) in unsealed?.credentials ?? [:] {
                guard let s = (try? await store.secret(profile)) ?? nil, let role = s.aws, !s.leasePolicy.everyUseAsks,
                      let expires = credentials.expiresAt else { continue }
                awsHeld[s.name] = IssuedAws(credentials: credentials, expiresAt: expires, issuedAt: now, role: role, secretUpdatedAt: s.updatedAt)
            }
        }
        if approval != .deny, case .lease = p.action { leasedTo = p.caller.cardId }

        let joined = pending.filter { $0.value.joinedTo == id && $0.value.result == nil }.map(\.key).sorted()
        for member in [id] + joined {
            guard let m = pending[member], m.result == nil else { continue }
            pending[member]?.result = await outcome(of: m, id: member, approval: approval, by: by, now: now, unsealed: unsealed)
            expireResult(member, after: unclaimedResultLifetime)
        }
        await persist()
        if let leasedTo { await settleCovered(card: leasedTo, by: by, now: now) }
    }

    /// What one waiting request gets for the human's answer.
    private func outcome(of p: Pending, id: String, approval: VaultPolicy.Approval, by: String, now: Date,
                         unsealed: VaultUnsealed? = nil) async -> VaultResponse {
        switch (approval, p.action) {
        case (.deny, _):
            let timedOut = by == "timeout"
            let message = timedOut
                ? "No answer in \(VaultPolicy.span(approvalTimeout)), so it was denied. Ask again with a reason: kv request NAME --reason \"...\""
                : "Rogerio denied it."
            for name in names(of: p.action) {
                await store.append(VaultAuditEntry(at: now, machine: machine, cardId: p.caller.cardId, sessionId: p.caller.sessionId,
                                                   secret: name, tier: nil, outcome: .denied, decider: timedOut ? .timeout : .human,
                                                   action: actionName(p.action), detail: "by \(by)", requestId: id))
            }
            return VaultResponse(status: .denied, message: message, id: id, card: p.caller.cardId)

        case (_, .release(let req, let asked)):
            let wanted = (try? await self.wanted(for: req)) ?? []
            var allowed: [(VaultSecret, VaultDecider, String)] = []
            var known = Set<String>()
            let covered = by == Self.coveredByLease
            var unlocked = unsealed?.values ?? [:]
            for s in wanted.map(\.secret) where known.insert(s.name).inserted {
                let wasAsked = asked.contains(s.name)
                let decider: VaultDecider = wasAsked ? (covered ? .lease : .human) : .tier
                var why = wasAsked ? (covered ? "the card got a lease while this waited" : "approved by \(by)") : "allowed with the request"
                if s.isSealed, unlocked[s.name] != nil, let device = unsealed?.device { why += ", unlocked by key \(device)" }
                if s.isSealed, unlocked[s.name] == nil, let value = heldValue(s, now: now) { unlocked[s.name] = value }
                allowed.append((s, decider, why))
            }
            return await grant(allowed, wanted: wanted, req: req, caller: p.caller, now: now, requestId: id,
                               unlocked: unlocked, minted: unsealed?.credentials ?? [:])

        case (_, .lease(let wanted, let reason)):
            guard let card = p.caller.cardId else { return .denied("no card to lease to") }
            for want in wanted {
                let (name, scope) = (want.name, want.scope)
                if by != Self.coveredByLease {
                    let policy = ((try? await store.secret(name)) ?? nil)?.leasePolicy ?? .standard
                    try? await store.grantLease(VaultLease(cardId: card, secret: name, scope: scope, reason: reason, grantedAt: now,
                                                           expiresAt: now.addingTimeInterval(policy.leaseSeconds), grantedBy: "human:\(by)"))
                }
                await store.append(VaultAuditEntry(at: now, machine: machine, cardId: card, sessionId: p.caller.sessionId,
                                                   secret: name, tier: nil, outcome: .allowed, decider: by == Self.coveredByLease ? .lease : .human,
                                                   action: "lease", reason: reason, detail: "by \(by)", requestId: id))
            }
            return VaultResponse(status: .granted, message: "leased \(wanted.map(\.name).joined(separator: ", ")) to the card", id: id, card: card)

        case (_, let action):
            return await apply(action, caller: p.caller, now: now, by: .human, requestId: id, unsealed: unsealed)
        }
    }

    static let coveredByLease = "lease"

    /// After a card got a lease: every other open request of that card
    /// whose secrets its leases now cover is settled as approved, and its
    /// attention request closed, so the human is not asked what he just
    /// answered.
    private func settleCovered(card: String, by: String, now: Date) async {
        let open = pending.filter { $0.value.result == nil && $0.value.joinedTo == nil }.sorted { $0.value.createdAt < $1.value.createdAt }
        for (otherId, other) in open {
            guard other.caller.insideCard, other.caller.cardId == card, !other.everyUseAsks else { continue }
            let asked: [String]
            switch other.action {
            case .release(_, let names): asked = names
            case .lease(let wanted, _): asked = wanted.map(\.name)
            default: continue
            }
            var covered = !asked.isEmpty
            for name in asked where covered {
                covered = await store.activeLease(cardId: card, secret: name, now: now) != nil
            }
            guard covered, pending[otherId]?.result == nil else { continue }
            await settle(id: otherId, approval: .once, by: Self.coveredByLease)
            await approvals?.close(id: otherId, resolution: AttentionRequest.vaultApprovalOptions[0], by: by)
        }
    }

    /// Forgets a result after `seconds`: values do not linger.
    private func expireResult(_ id: String, after seconds: TimeInterval) {
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            self.forgetUnclaimed(id)
        }
    }

    private func forgetUnclaimed(_ id: String) {
        if pending[id]?.result != nil, pending[id]?.claimedAt == nil { pending[id] = nil }
    }

    /// Marks a result as fetched; it goes shortly after, once the other
    /// callers waiting on the same id had their turn.
    private func claim(_ id: String, now: Date) {
        guard pending[id]?.claimedAt == nil else { return }
        pending[id]?.claimedAt = now
        let grace = claimedResultLifetime
        Task {
            try? await Task.sleep(for: .seconds(grace))
            self.forget(id)
        }
    }

    /// Writes the open requests to `pending.age`. Settled ones are left
    /// out: a result can carry secret values, and its caller polls it
    /// within a second or two.
    private func persist() async {
        let open = pending.filter { $0.value.result == nil }.map { id, p in
            SavedPending(id: id, action: p.action, caller: p.caller, createdAt: p.createdAt,
                         everyUseAsks: p.everyUseAsks, request: p.request, joinedTo: p.joinedTo)
        }.sorted { $0.createdAt < $1.createdAt }
        do {
            try await store.savePending(open.isEmpty ? nil : try JSONEncoder.vault.encode(open))
        } catch {
            KanbanCodeLog.warn("vault", "could not save the open vault requests: \(error)")
        }
    }

    /// Picks up the requests that were open when the master stopped: raises
    /// their attention requests again and waits for the answer, from the
    /// original creation time, so the timeout is the same as without the
    /// restart. Runs once; a poll waits for it, so a caller polling right
    /// after the master came back still finds its request.
    public func restore() async {
        if restoring == nil { restoring = Task { await self.restoreSaved() } }
        await restoring?.value
    }

    private func restoreSaved() async {
        guard let approvals, let data = await store.loadPending() else { return }
        let saved: [SavedPending]
        do {
            saved = try JSONDecoder.vault.decode([SavedPending].self, from: data)
        } catch {
            KanbanCodeLog.warn("vault", "could not read the open vault requests: \(error)")
            return
        }
        var restored = 0
        let savedIds = Set(saved.map(\.id))
        for s in saved.sorted(by: { $0.createdAt < $1.createdAt }) where pending[s.id] == nil {
            // Asks once for what several saved requests ask alike.
            var joinedTo = s.joinedTo.flatMap { savedIds.contains($0) ? $0 : nil }
            if joinedTo == nil {
                let key = Self.joinKey(s.action, caller: s.caller)
                joinedTo = pending.first(where: {
                    $0.value.joinedTo == nil && Self.joinKey($0.value.action, caller: $0.value.caller) == key
                })?.key
            }
            pending[s.id] = Pending(action: s.action, caller: s.caller, result: nil, createdAt: s.createdAt,
                                    everyUseAsks: s.everyUseAsks, request: s.request, joinedTo: joinedTo)
            restored += 1
            guard joinedTo == nil else { continue }
            await approvals.raise(s.request)
            let id = s.id
            Task { await self.waitForHuman(id: id) }
        }
        if restored > 0 { KanbanCodeLog.info("vault", "restored \(restored) open vault request(s)") }
    }

    private func forget(_ id: String) {
        pending[id] = nil
    }

    private func names(of action: PendingAction) -> [String] {
        switch action {
        case .release(_, let asked): asked
        case .lease(let wanted, _): wanted.map(\.name)
        case .add(let req): [req.name]
        case .edit(let names, _): names
        case .delete(let name): [name]
        case .deleteMany(let names): names
        case .rename(let renames): renames.map(\.from)
        case .owner: [Self.ownerKeysName]
        }
    }

    /// The result of a pending request: still pending, or its outcome,
    /// which goes shortly after the first fetch.
    public func poll(id: String) async -> VaultResponse {
        await restore()
        guard let p = pending[id] else {
            return VaultResponse(status: .denied, message: "no pending vault request \(id) (it expired or was already answered)", id: id)
        }
        guard let result = p.result else {
            return VaultResponse(status: .pending, message: "still waiting for Rogerio's approval", id: id, card: p.caller.cardId)
        }
        claim(id, now: Date())
        return result
    }

    // MARK: - Audit

    private func audit(_ s: VaultSecret, req: VaultReleaseRequest, caller: VaultCaller, outcome: VaultOutcome,
                       decider: VaultDecider, detail: String?, requestId: String? = nil) async {
        await store.append(VaultAuditEntry(
            at: Date(), machine: machine, cardId: caller.cardId ?? caller.claimedCardId.map { "unverified:\($0)" },
            sessionId: caller.sessionId ?? req.sessionId, secret: s.name, tier: s.tier, outcome: outcome, decider: decider,
            action: req.mode, command: req.command.map { String($0.prefix(2000)) }, reason: req.reason,
            detail: caller.auditNote.map { [detail, $0].compactMap { $0 }.joined(separator: ", ") } ?? detail,
            requestId: requestId
        ))
    }
}
