import Foundation
import KanbanCodeRemoteKit

/// A card on the Kanban board, combining Link + Session data for display.
/// The master that runs a card, when it is not this one.
public struct CardOwner: Sendable, Equatable, Hashable {
    public let id: String
    public let name: String
    public let online: Bool

    public init(id: String, name: String, online: Bool) {
        self.id = id
        self.name = name
        self.online = online
    }
}

public struct KanbanCodeCard: Identifiable, Sendable, Equatable {
    public let id: String // link.id — stable across refreshes
    public let link: Link
    public let session: Session?
    public let activityState: ActivityState?
    /// True when an async operation is in progress on this card
    /// (terminal creating, worktree cleanup, PR discovery).
    public let isBusy: Bool
    /// True when this card's repo is affected by GitHub API rate limiting.
    public let isRateLimited: Bool
    /// Model the live session is actually running, e.g. "opus". Read from
    /// Claude's statusline, so it reflects an in-session `/model` switch that
    /// the card's own `modelOverride` knows nothing about.
    public let liveModel: String?
    /// Another master that owns and runs the card; nil for this one.
    public let owner: CardOwner?
    /// Where its assistant session stands: running, starting, moving,
    /// failed, ended. The one value every surface renders.
    public let sessionStatus: CardSessionStatus
    /// The plan usage limit its assistant stopped on, as last scanned. Check
    /// `activeUsageLimit` before showing it: it lifts on its own.
    public let usageLimit: RemoteUsageLimit?

    public init(
        link: Link,
        session: Session? = nil,
        activityState: ActivityState? = nil,
        isBusy: Bool = false,
        isRateLimited: Bool = false,
        liveModel: String? = nil,
        owner: CardOwner? = nil,
        usageLimit: RemoteUsageLimit? = nil,
        sessionStatus: CardSessionStatus? = nil
    ) {
        self.id = link.id
        self.link = link
        self.session = session
        self.activityState = activityState
        self.isBusy = isBusy
        self.isRateLimited = isRateLimited
        self.liveModel = liveModel
        self.owner = owner
        self.usageLimit = usageLimit
        self.sessionStatus = sessionStatus
            ?? CardSessionStatus.of(link: link, moving: nil, report: nil, machineState: nil)
    }

    /// The usage limit, while it holds at `now`.
    public func activeUsageLimit(at now: Date = Date()) -> RemoteUsageLimit? {
        usageLimit.flatMap { $0.isActive(at: now) ? $0 : nil }
    }

    /// Whether Claude is confirmed actively working right now (not just waiting).
    public var isActivelyWorking: Bool {
        activityState == .activelyWorking
    }

    /// Whether to show a spinner on the card: a turn, a start or a move in
    /// flight, or other work on the card.
    public var showSpinner: Bool {
        switch sessionStatus {
        case .starting, .moving: return true
        default: return isActivelyWorking || link.isLaunching == true || isBusy
        }
    }

    /// Whether the card offers its Start button: a backlog card with no
    /// session running. A live session (a rush host whose agent stopped
    /// after idling counts) needs no start.
    public var showsStartButton: Bool {
        column == .backlog && !showSpinner && !hasRunningSession
    }

    /// Whether the card's session runs: its tmux session is alive.
    public var hasRunningSession: Bool {
        switch sessionStatus {
        case .live, .machine: true
        default: false
        }
    }

    /// Best display title: link name → session display title → link fallback chain.
    public var displayTitle: String {
        if let name = link.name, !name.isEmpty { return name }
        if let session { return session.displayTitle }
        return link.displayTitle
    }

    /// Project name extracted from project path.
    public var projectName: String? {
        guard let path = link.projectPath ?? session?.projectPath else { return nil }
        return (path as NSString).lastPathComponent
    }

    /// Relative time since last activity.
    public var relativeTime: String {
        let date = link.lastActivity ?? link.updatedAt
        return Self.formatRelativeTime(date)
    }

    /// The column this card is in.
    public var column: KanbanCodeColumn { link.column }

    static func formatRelativeTime(_ date: Date) -> String {
        let interval = Date.now.timeIntervalSince(date)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        let days = Int(interval / 86400)
        if days == 1 { return "yesterday" }
        if days < 30 { return "\(days)d ago" }
        return "\(days / 30)mo ago"
    }
}
