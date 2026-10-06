import Foundation

/// Keeps a valid session token in every rush host of this master's cards.
///
/// rush starts a host's assistant again from the environment saved with the
/// host (a message to a resting or stopped host, `rush open`, the rush view),
/// so a host whose saved environment has no token, or one this master never
/// issued, runs without one however often it wakes. The master reads the
/// token of each host's running assistant; when it is missing or not the
/// card's, the host is started again with `rush session start --resume` and
/// a fresh token once it rests, which also replaces its saved environment.
public struct RushTokenKeeper: Sendable {
    /// A host restarted for its token is not restarted again before this.
    public static let retryAfter: TimeInterval = 10 * 60
    /// Restarts of one host that still came back without a valid token
    /// before the keeper leaves it alone.
    public static let maxRefreshes = 3

    /// How a host that rests gets its fresh token.
    public enum Refresh: Equatable, Sendable {
        /// The host process ended between turns: `rush session start --resume`.
        case start
        /// The host process runs with its assistant resting (an older rush):
        /// `rush session stop` first.
        case stopThenStart
    }

    /// Hosts whose running assistant had no valid token, by host id.
    public private(set) var missing: Set<String> = []
    private var refreshes: [String: (count: Int, at: Date)] = [:]

    public init() {}

    /// Records what the running assistant of host `hostId`, which belongs
    /// to `cardId`, carries: `tokenCard` is the card its token was issued
    /// for, nil when it has none or one this master does not know.
    public mutating func observe(hostId: String, cardId: String, tokenCard: String?) {
        if tokenCard == cardId {
            missing.remove(hostId)
            refreshes[hostId] = nil
        } else {
            missing.insert(hostId)
        }
    }

    /// How a host could be restarted now, or nil while that would cut into
    /// its work: a turn, a question, a queued message, an assistant still
    /// running (with the shells it started), or a host the human stopped.
    public static func refresh(of host: RushSessionInfo) -> Refresh? {
        guard host.queue.isEmpty, host.claudePid == nil, host.state != "stopped" else { return nil }
        if !host.alive { return host.sleeping ? .start : nil }
        return host.state == "idle" ? .stopThenStart : nil
    }

    /// The hosts to restart with a fresh token now, out of `hosts` (this
    /// master's card hosts, as rush lists them). Each is counted as
    /// restarted; it stays clear until its assistant is read again.
    public mutating func due(_ hosts: [RushSessionInfo], now: Date = Date()) -> [(host: RushSessionInfo, refresh: Refresh)] {
        let listed = Set(hosts.map(\.id))
        missing.formIntersection(listed)
        refreshes = refreshes.filter { listed.contains($0.key) }
        var out: [(host: RushSessionInfo, refresh: Refresh)] = []
        for host in hosts where missing.contains(host.id) {
            guard let refresh = Self.refresh(of: host) else { continue }
            let last = refreshes[host.id]
            if let last, last.count >= Self.maxRefreshes || now.timeIntervalSince(last.at) < Self.retryAfter { continue }
            refreshes[host.id] = ((last?.count ?? 0) + 1, now)
            missing.remove(host.id)
            out.append((host, refresh))
        }
        return out
    }
}
