import Foundation
import KanbanCodeRemoteKit

/// What the decision engine knows about one release of one secret.
public struct VaultDecisionInput: Sendable, Equatable {
    public var tier: VaultTier
    public var everyUseAsks: Bool
    /// The caller runs inside a card session the master verified.
    public var insideCard: Bool
    /// The request came over the network, not from a process on this machine.
    public var overNetwork: Bool
    /// The card holds an active lease on the secret.
    public var hasLease: Bool
    /// Releases of this secret in the rate window, this one excluded.
    public var recentReleases: Int
    /// The secret is a project's development secret without rules of its
    /// own, and the card's process runs in that project's folder.
    public var ownProjectDev: Bool

    public init(tier: VaultTier, everyUseAsks: Bool = false, insideCard: Bool, overNetwork: Bool = false, hasLease: Bool = false,
                recentReleases: Int = 0, ownProjectDev: Bool = false) {
        self.tier = tier
        self.overNetwork = overNetwork
        self.everyUseAsks = everyUseAsks
        self.insideCard = insideCard
        self.hasLease = hasLease
        self.recentReleases = recentReleases
        self.ownProjectDev = ownProjectDev
    }
}

public enum VaultVerdict: Sendable, Equatable {
    case allow(VaultDecider, String)
    /// The human decides; the text says why it came to them.
    case ask(String)
    case deny(String)
    /// The secret is judged: ask Jev, then `VaultPolicy.afterJev`.
    case consultJev
}

/// Jev's answer to "release this secret to this command?".
public struct JevVerdict: Sendable, Equatable {
    public enum Choice: String, Sendable, CaseIterable {
        case allow, ask, deny
    }

    public var choice: Choice
    /// Probability of the chosen option, 0...1.
    public var confidence: Double

    public init(choice: Choice, confidence: Double) {
        self.choice = choice
        self.confidence = confidence
    }
}

/// The release rules of the vault, as pure functions:
///
/// 1. tier never: deny.
/// 2. the request came over the network: ask, whatever the tier.
/// 3. more than `rateLimit` releases of the secret in the window: ask.
/// 4. an active card lease (and the secret allows leases): allow.
/// 5. tier open: allow. judged: allow the project's own development
///    secret, else Jev. ask: the human.
///
/// A local process outside every card session (a scheduled job, a shell)
/// follows the same tiers as a card; it holds no lease.
public enum VaultPolicy {
    /// The environment whose judged secrets a card gets in its own project
    /// without a Jev call.
    public static let developmentEnvironment = VaultSecretName.defaultEnvironment
    public static let ownProjectDevReason = "the project's own development secret"

    /// Whether `secret` is a development secret of one of `callerProjects`
    /// (the projects of the folder the calling process runs in) that the
    /// policy releases to a card on its own. Shared secrets, other
    /// environments, secrets with rules and ones that ask on every use are
    /// not; nor is any caller that is not a card.
    public static func isOwnProjectDev(_ secret: VaultSecret, caller: VaultCaller, callerProjects: [String]) -> Bool {
        // A card another master vouched for runs a command here over ssh:
        // this master read neither its session nor where it works.
        guard caller.insideCard, caller.openClawAgent == nil, caller.verifiedByPeer == nil,
              let project = secret.project, secret.environment == developmentEnvironment,
              secret.rules.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !secret.leasePolicy.everyUseAsks, secret.aws == nil
        else { return false }
        return callerProjects.contains(project)
    }

    public static let rateLimit = 20
    public static let rateWindow: TimeInterval = 5 * 60
    /// Jev must be at least this sure to allow on its own.
    public static let jevAllowConfidence = 0.6
    /// How long the human has to answer before the request is denied.
    public static let approvalTimeout: TimeInterval = 12 * 60 * 60
    public static let overNetworkReason = "the request comes over the network, not from a process on this machine"
    public static let outsideCardNote = "outside any card session"

    /// A waiting time in words: "12 hours", "90 minutes", "1 hour".
    public static func span(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes >= 60, minutes % 60 == 0 {
            let hours = minutes / 60
            return hours == 1 ? "1 hour" : "\(hours) hours"
        }
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    public static func decide(_ input: VaultDecisionInput, rateLimit: Int = VaultPolicy.rateLimit) -> VaultVerdict {
        if input.tier == .never {
            return .deny("this secret is never released")
        }
        if input.overNetwork {
            return .ask(overNetworkReason)
        }
        if input.recentReleases >= rateLimit {
            return .ask("released \(input.recentReleases) times in the last \(Int(rateWindow / 60)) minutes")
        }
        if input.hasLease && !input.everyUseAsks {
            return .allow(.lease, "the card holds a lease")
        }
        switch input.tier {
        case .open: return .allow(.tier, input.insideCard ? "open tier" : "open tier, \(outsideCardNote)")
        case .judged: return input.ownProjectDev ? .allow(.rule, ownProjectDevReason) : .consultJev
        case .ask: return .ask(input.everyUseAsks ? "every use of this secret asks" : "this secret always asks")
        case .never: return .deny("this secret is never released")
        }
    }

    /// Turns Jev's answer into a verdict. No answer (Jev unreachable, an
    /// error, a timeout) goes to the human: the vault never allows on a
    /// failure.
    public static func afterJev(_ verdict: JevVerdict?, insideCard: Bool = true) -> VaultVerdict {
        guard let verdict else { return .ask("Jev could not be reached") }
        switch verdict.choice {
        case .allow:
            if verdict.confidence >= jevAllowConfidence {
                let allowed = "Jev allowed (\(percent(verdict.confidence)))"
                return .allow(.jev, insideCard ? allowed : "\(allowed), \(outsideCardNote)")
            }
            return .ask("Jev was unsure (\(percent(verdict.confidence)) allow)")
        case .ask:
            return .ask("Jev asked for a human (\(percent(verdict.confidence)))")
        case .deny:
            return .deny("Jev denied it against the secret's rules (\(percent(verdict.confidence)))")
        }
    }

    /// The options the human gets: no card lease for secrets that ask on
    /// every use, nor for callers outside a card.
    public static func approvalOptions(everyUseAsks: Bool, insideCard: Bool,
                                       leaseSeconds: TimeInterval = VaultLeasePolicy.maximumLease) -> [String] {
        let all = AttentionRequest.vaultApprovalOptions(leaseSeconds: leaseSeconds)
        if everyUseAsks || !insideCard { return Array(all.dropFirst()) }
        return all
    }

    /// The length of the lease one approval gives on `policies`: the
    /// shortest of them, so the card never keeps a secret for longer than
    /// the option the human picked said.
    public static func leaseSeconds(for policies: [VaultLeasePolicy]) -> TimeInterval {
        policies.map(\.grantedSeconds).min() ?? VaultLeasePolicy.maximumLease
    }

    public enum Approval: Equatable, Sendable {
        case lease
        case once
        case deny
    }

    /// Reads the human's resolution; anything unrecognised denies.
    public static func approval(from resolution: String?) -> Approval {
        guard let resolution else { return .deny }
        if AttentionRequest.isVaultLeaseOption(resolution) { return .lease }
        if resolution == AttentionRequest.vaultApprovalOptions[1] { return .once }
        let lower = resolution.lowercased()
        if lower.hasPrefix("approve for") || lower == "lease" { return .lease }
        if lower.hasPrefix("approve") || lower == "once" || lower == "allow" { return .once }
        return .deny
    }

    private static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

/// Releases per secret in a sliding window, in memory.
public struct VaultRateCounter: Sendable {
    private var events: [String: [Date]] = [:]
    public let window: TimeInterval

    public init(window: TimeInterval = VaultPolicy.rateWindow) {
        self.window = window
    }

    public func count(_ secret: String, now: Date) -> Int {
        (events[secret] ?? []).filter { now.timeIntervalSince($0) < window }.count
    }

    public mutating func record(_ secret: String, at now: Date) {
        var list = (events[secret] ?? []).filter { now.timeIntervalSince($0) < window }
        list.append(now)
        events[secret] = list
    }

    public mutating func reset(_ secret: String) {
        events[secret] = nil
    }
}
