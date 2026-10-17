import Foundation

/// When a master that was answering counts as offline: only after every
/// attempt to reach it has failed for `grace`. A loaded host answers late,
/// a phone waking up needs a moment before its tunnel carries traffic, and
/// one dropped socket or timed out pull says nothing about the master
/// itself, so a single failure never flips it offline.
public struct RemoteReachability: Sendable, Equatable {
    /// Long enough for a deploy restart, a stalled loaded host and a phone
    /// tunnel coming back, short enough that a master that is really gone
    /// shows it within a minute.
    public static let defaultGrace: TimeInterval = 45

    public let grace: TimeInterval
    /// The first failure since the master last answered, nil while it answers.
    public private(set) var failingSince: Date?

    public init(grace: TimeInterval = RemoteReachability.defaultGrace) {
        self.grace = grace
    }

    public mutating func answered() {
        failingSince = nil
    }

    /// Records a failed attempt; the first one starts the grace.
    public mutating func failed(at now: Date = .now) {
        if failingSince == nil { failingSince = now }
    }

    public func isOffline(at now: Date = .now) -> Bool {
        guard let failingSince else { return false }
        return now.timeIntervalSince(failingSince) >= grace
    }

    /// When the grace runs out, nil while the master answers.
    public var offlineAt: Date? {
        failingSince?.addingTimeInterval(grace)
    }
}
