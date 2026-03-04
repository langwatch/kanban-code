import Foundation

/// A GitHub pull request linked to a session via branch name.
public struct PullRequest: Identifiable, Sendable {
    public var id: Int { number }
    public let number: Int
    public let title: String
    public let state: String // "open", "closed", "merged"
    public let url: String
    public let headRefName: String // branch name
    public var reviewDecision: String? // "APPROVED", "CHANGES_REQUESTED", "REVIEW_REQUIRED", ""
    public var checksStatus: ChecksStatus
    public var unresolvedThreads: Int
    public var body: String?
    public var approvalCount: Int
    public var checkRuns: [CheckRun]
    public var firstUnresolvedThreadURL: String?
    public var mergeStateStatus: String? // CLEAN, BLOCKED, DIRTY, BEHIND, DRAFT, UNSTABLE, HAS_HOOKS, UNKNOWN

    public init(
        number: Int,
        title: String,
        state: String,
        url: String,
        headRefName: String,
        reviewDecision: String? = nil,
        checksStatus: ChecksStatus = .none,
        unresolvedThreads: Int = 0,
        body: String? = nil,
        approvalCount: Int = 0,
        checkRuns: [CheckRun] = [],
        firstUnresolvedThreadURL: String? = nil,
        mergeStateStatus: String? = nil
    ) {
        self.number = number
        self.title = title
        self.state = state
        self.url = url
        self.headRefName = headRefName
        self.reviewDecision = reviewDecision
        self.checksStatus = checksStatus
        self.unresolvedThreads = unresolvedThreads
        self.body = body
        self.approvalCount = approvalCount
        self.checkRuns = checkRuns
        self.firstUnresolvedThreadURL = firstUnresolvedThreadURL
        self.mergeStateStatus = mergeStateStatus
    }

    /// Derive unified PR status with priority ordering.
    public var status: PRStatus {
        if state == "merged" { return .merged }
        if state == "closed" { return .closed }
        if checksStatus == .fail { return .failing }
        if unresolvedThreads > 0 { return .unresolved }
        if reviewDecision == "CHANGES_REQUESTED" { return .changesRequested }
        if reviewDecision == "REVIEW_REQUIRED" || reviewDecision == "" || reviewDecision == nil {
            // Repos without required reviews return empty reviewDecision even with approvals
            if approvalCount > 0 {
                if checksStatus == .pending { return .pendingCI }
                return .approved
            }
            return .reviewNeeded
        }
        if checksStatus == .pending { return .pendingCI }
        return .approved
    }
}
