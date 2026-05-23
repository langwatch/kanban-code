import Foundation

/// Updates a link's column based on current activity state, PR status, and worktree existence.
/// Wraps AssignColumn with persistence via CoordinationStore.
public enum UpdateCardColumn {

    /// Update a single link's column assignment.
    /// PR state is read directly from `link.prLinks`.
    public static func update(
        link: inout Link,
        activityState: ActivityState?,
        hasWorktree: Bool
    ) {
        let hasPR = !link.prLinks.isEmpty
        let allPRsDone = link.allPRsDone

        let newColumn = AssignColumn.assign(
            link: link,
            activityState: activityState,
            hasPR: hasPR,
            allPRsDone: allPRsDone,
            hasWorktree: hasWorktree
        )

        // If an archived card becomes live again, clear the archive flag so it
        // stays in waiting (not allSessions) once work stops. Require a live
        // tmux/worktree signal so stale activity does not unarchive old cards.
        if link.manuallyArchived && newColumn == .inProgress && hasWorktree {
            link.manuallyArchived = false
        }

        if newColumn != link.column {
            link.column = newColumn
            link.updatedAt = .now
        }
    }
}
