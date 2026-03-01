import Foundation

/// Determines which Kanban column a link should be in based on its state.
/// Respects manual overrides — if the user dragged a card to a column, keep it there.
public enum AssignColumn {

    /// Assign a column to a link based on current state signals.
    public static func assign(
        link: Link,
        activityState: ActivityState? = nil,
        hasPR: Bool = false,
        allPRsDone: Bool = false,
        hasWorktree: Bool = false
    ) -> KanbanColumn {
        // Archive always wins
        if link.manuallyArchived {
            return .allSessions
        }

        // Actively working always shows in progress, regardless of PR state or manual drag
        if activityState == .activelyWorking {
            return .inProgress
        }

        // Terminal PR state
        if allPRsDone {
            return .done
        }

        // Manual drag override (non-terminal)
        if link.manualOverrides.column {
            return link.column
        }

        // PR exists and session not actively working → inReview
        // This skips Waiting when addressing review feedback: Claude stops → goes directly to In Review
        if hasPR, let state = activityState,
           state == .needsAttention || state == .idleWaiting || state == .ended || state == .stale {
            return .inReview
        }

        // Activity-based assignment
        if let state = activityState {
            switch state {
            case .activelyWorking:
                return .inProgress // Already handled above, but keep for exhaustive switch
            case .needsAttention:
                return .waiting
            case .idleWaiting:
                // Claude is idle/waiting for user — that's Waiting, not In Progress.
                // Only .activelyWorking should keep a card in In Progress.
                return .waiting
            case .ended:
                if hasWorktree { return .waiting }
                // No worktree: fall through to recency check below
            case .stale:
                break // No hook data: fall through to recency check below
            }
        }

        // GitHub issue source without a session yet → backlog
        if link.source == .githubIssue && link.sessionLink == nil {
            return .backlog
        }

        // Manual task without a session yet → backlog
        // BUT if tmuxLink is set and NOT shell-only, it's being actively launched → stay in progress
        if link.source == .manual && link.sessionLink == nil {
            if link.tmuxLink != nil && link.tmuxLink?.isShellOnly != true {
                KanbanLog.info("assign-column", "Manual card \(link.id.prefix(12)) has tmuxLink → inProgress (launching)")
                return .inProgress
            }
            return .backlog
        }

        // Live tmux session → at least waiting (never allSessions)
        // A card with an active tmux session is still in-flight, even if
        // we haven't received hook data yet.
        if hasWorktree {
            return .waiting
        }

        // Recently active (within 24h) → waiting
        // These sessions are recent but not confirmed active by hooks/polling.
        // In Progress is reserved for hook-confirmed actively working sessions.
        // User can triage from here: drag to All Sessions to archive, or resume.
        if let lastActivity = link.lastActivity {
            let hoursSinceActivity = Date.now.timeIntervalSince(lastActivity) / 3600
            if hoursSinceActivity < 24 {
                return .waiting
            }
        }

        // Default: allSessions
        return .allSessions
    }
}
