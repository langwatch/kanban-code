import Foundation

/// The "decisions waiting on you" row at the top of the board sidebar:
/// what it says and what a click opens. Built from the open requests in
/// the state, the same ones the attention center counts for the Dock
/// badge, including requests that belong to no card.
public struct AttentionBannerSummary: Equatable, Sendable {
    /// What a click on the banner opens.
    public enum Target: Equatable, Sendable {
        /// The detail sheet of the one open request.
        case request(String)
        /// The list of every open request, oldest first.
        case list([String])
    }

    public let count: Int
    public let target: Target

    public var title: String {
        count == 1 ? "1 decision waiting on you" : "\(count) decisions waiting on you"
    }

    /// Nil when nothing waits, so the banner is not shown.
    public init?(open: [AttentionRequest]) {
        guard let first = open.first else { return nil }
        count = open.count
        target = open.count == 1 ? .request(first.id) : .list(open.map(\.id))
    }
}

extension AppState {
    /// The sidebar banner for the open attention requests, nil when none.
    public var attentionBanner: AttentionBannerSummary? {
        AttentionBannerSummary(open: openAttentionRequests)
    }
}
