import Foundation

/// Determines which Kanban column a link should be in based on its state.
/// Respects manual overrides — if the user dragged a card to a column, keep it there.
public enum AssignColumn {

    /// Assign a column to a link based on current state signals.
    public static func assign(
        link: Link,
        activityState: ActivityState? = nil,
        hasPR: Bool = false,
        prMerged: Bool = false,
        hasWorktree: Bool = false
    ) -> KanbanColumn {
        // Manual override always wins
        if link.manualOverrides.column {
            return link.column
        }

        // Manually archived → allSessions
        if link.manuallyArchived {
            return .allSessions
        }

        // PR merged → done
        if prMerged {
            return .done
        }

        // PR exists and session idle → inReview
        if hasPR, let state = activityState,
           state == .idleWaiting || state == .ended || state == .stale {
            return .inReview
        }

        // Activity-based assignment
        if let state = activityState {
            switch state {
            case .activelyWorking:
                return .inProgress
            case .needsAttention:
                return .requiresAttention
            case .idleWaiting:
                if hasWorktree { return .inProgress }
                // No worktree: fall through to recency check below
            case .ended:
                if hasWorktree { return .requiresAttention }
                // No worktree: fall through to recency check below
            case .stale:
                break // No hook data: fall through to recency check below
            }
        }

        // GitHub issue source without a session yet → backlog
        if link.source == .githubIssue && link.sessionPath == nil {
            return .backlog
        }

        // Manual task without a session yet → backlog
        if link.source == .manual && link.sessionPath == nil {
            return .backlog
        }

        // Recently active (within 24h) → requiresAttention
        // These sessions are recent but not confirmed active by hooks/polling.
        // In Progress is reserved for hook-confirmed actively working sessions.
        // User can triage from here: drag to All Sessions to archive, or resume.
        if let lastActivity = link.lastActivity {
            let hoursSinceActivity = Date.now.timeIntervalSince(lastActivity) / 3600
            if hoursSinceActivity < 24 {
                return .requiresAttention
            }
        }

        // Default: allSessions
        return .allSessions
    }
}
