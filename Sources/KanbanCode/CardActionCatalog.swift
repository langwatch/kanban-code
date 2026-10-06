import AppKit
import KanbanCodeCore

/// One entry of the card actions: a button or a submenu of buttons. The card
/// context menu, the detail toolbar menu and the command palette all read the
/// same list from `CardActionCatalog`, so an action added to one is in all.
struct CardActionItem: Identifiable {
    enum Kind {
        case perform(() -> Void)
        case submenu([CardActionItem])
    }

    let id: String
    let title: String
    var icon: String?
    /// Title in the command palette, where the item stands without its menu
    /// around it. For a submenu, the prefix of its children's titles.
    var paletteTitle: String?
    var isDestructive = false
    var isDisabled = false
    var isChecked = false
    /// Draw a divider above this item inside its submenu.
    var dividerBefore = false
    /// The keyboard shortcut that runs the same action, shown in the palette.
    var shortcut: AppShortcut?
    let kind: Kind
}

/// A card action flattened for the command palette.
struct CardPaletteEntry {
    let id: String
    let title: String
    let icon: String
    let shortcut: AppShortcut?
    let run: () -> Void
}

/// What the card actions reach outside the card's own closures: the
/// clipboard, the browser, the machines, the store.
struct CardActionEnvironment {
    var copy: (String) -> Void
    var open: (URL) -> Void
    var moveCard: (_ cardId: String, _ target: String) -> Void
    var pauseMachine: (String) -> Void
    var destroyMachine: (String) -> Void
    var unarchive: (String) -> Void
    var requestAddLink: (String) -> Void
    /// Where the card can continue: this Mac, the peer masters, the ssh
    /// machines this Mac drives.
    var continueTargets: [(label: String, target: String)]
    /// Whether a machine is an ssh machine, shared and always on.
    var isSharedMachine: (String) -> Bool

    @MainActor
    static func live(for card: KanbanCodeCard) -> CardActionEnvironment {
        CardActionEnvironment(
            copy: { text in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            },
            open: { NSWorkspace.shared.open($0) },
            moveCard: { cardId, target in AppServices.moveCard(cardId, to: target) },
            pauseMachine: { AppServices.pauseMachine?($0) },
            destroyMachine: { AppServices.destroyMachine?($0) },
            unarchive: { AppComposition.shared.store.dispatch(.unarchiveCard(cardId: $0)) },
            requestAddLink: { cardId in
                NotificationCenter.default.post(
                    name: .kanbanCodeAddLink,
                    object: nil,
                    userInfo: ["cardId": cardId]
                )
            },
            continueTargets: continueTargets(for: card, state: AppComposition.shared.store.state),
            isSharedMachine: { AppServices.sshTargets[$0] != nil }
        )
    }

    static func continueTargets(for card: KanbanCodeCard, state: AppState) -> [(label: String, target: String)] {
        var out: [(String, String)] = []
        let owner = card.owner?.id
        let onMachine = card.link.remote != nil && card.link.isRemote
        if owner != nil || onMachine { out.append(("This Mac", "mac")) }
        // One entry per machine: a machine that runs a master takes the card
        // over; an ssh machine without one runs it for this Mac.
        for choice in state.machineChoices {
            if let master = choice.master {
                guard master.id != owner else { continue }
                out.append((choice.masterOnline ? choice.name : "\(choice.name) (offline)", master.id))
            } else if owner == nil, card.link.sessionLink != nil, choice.sshMachine != nil {
                if card.link.remote?.machineName == choice.name, card.link.isRemote { continue }
                out.append((choice.name, choice.name))
            }
        }
        return out
    }
}

/// Every action a card offers, in menu order. Sections are separated by
/// dividers in a menu; the palette reads them flattened.
struct CardActionCatalog {
    let card: KanbanCodeCard
    let actions: CardActionsMenuActions
    var showBranchInfo = false
    var githubBaseURL: String?
    var availableProjects: [(name: String, path: String)] = []
    var enabledAssistants: [CodingAssistant] = []
    let environment: CardActionEnvironment

    var sections: [[CardActionItem]] {
        [
            showBranchInfo ? branchItems : [],
            primaryItems,
            copyItems,
            linkItems,
            discoverItems,
            cleanupItems,
            continueOnItems,
            moveToProjectItems,
            migrateItems,
            machineItems,
            archiveItems,
        ].filter { !$0.isEmpty }
    }

    /// The enabled actions, one per button, submenu children titled with
    /// their submenu's palette title.
    var paletteEntries: [CardPaletteEntry] {
        var out: [CardPaletteEntry] = []
        for item in sections.joined() where !item.isDisabled {
            switch item.kind {
            case .perform(let run):
                out.append(CardPaletteEntry(
                    id: "card-action:\(item.id)",
                    title: item.paletteTitle ?? item.title,
                    icon: item.icon ?? "square.grid.2x2",
                    shortcut: item.shortcut,
                    run: run
                ))
            case .submenu(let children):
                let prefix = item.paletteTitle ?? item.title
                for child in children where !child.isDisabled {
                    guard case .perform(let run) = child.kind else { continue }
                    let title = child.paletteTitle ?? child.title
                    out.append(CardPaletteEntry(
                        id: "card-action:\(child.id)",
                        title: "\(prefix): \(title)\(child.isChecked ? " (current)" : "")",
                        icon: child.icon ?? item.icon ?? "square.grid.2x2",
                        shortcut: child.shortcut,
                        run: run
                    ))
                }
            }
        }
        return out
    }

    private var hasSessionPath: Bool { card.link.sessionLink?.sessionPath != nil }

    private func issueURL(_ issue: IssueLink) -> String? {
        issue.url ?? githubBaseURL.map { GitRemoteResolver.issueURL(base: $0, number: issue.number) }
    }

    // MARK: - Sections

    private var branchItems: [CardActionItem] {
        var items: [CardActionItem] = []
        if let branch = card.link.worktreeLink?.branch ?? card.link.discoveredBranches?.first, !branch.isEmpty {
            var children = [
                CardActionItem(id: "branch.copy", title: "Copy Branch Name", kind: .perform { environment.copy(branch) }),
            ]
            if card.link.worktreeLink != nil, let onUnlink = actions.onUnlink {
                children.append(CardActionItem(id: "branch.unlink", title: "Unlink Branch", kind: .perform { onUnlink(.worktree) }))
            }
            items.append(CardActionItem(
                id: "branch", title: "Branch: \(branch)", icon: "arrow.triangle.branch",
                paletteTitle: "Branch \(branch)", kind: .submenu(children)
            ))
        }
        for pr in card.link.prLinks.sortedByPRNumber {
            let number = String(pr.number)
            let detail = pr.status.map { " · \($0.rawValue)" } ?? ""
            var children: [CardActionItem] = []
            if let url = resolvedPRURL(pr, githubBaseURL: githubBaseURL) {
                children.append(CardActionItem(id: "pr.\(number).open", title: "Open on GitHub", kind: .perform { environment.open(url) }))
            }
            children.append(CardActionItem(id: "pr.\(number).copyNumber", title: "Copy PR Number", kind: .perform { environment.copy("#\(number)") }))
            if let url = pr.url {
                children.append(CardActionItem(id: "pr.\(number).copyLink", title: "Copy PR Link", kind: .perform { environment.copy(url) }))
            }
            if let onUnlink = actions.onUnlink {
                children.append(CardActionItem(id: "pr.\(number).unlink", title: "Unlink PR", kind: .perform { onUnlink(.pr(number: pr.number)) }))
            }
            items.append(CardActionItem(
                id: "pr.\(number)", title: "PR: #\(number)\(detail)", icon: "arrow.triangle.pull",
                paletteTitle: "PR #\(number)", kind: .submenu(children)
            ))
        }
        if let issue = card.link.issueLink {
            let number = String(issue.number)
            var children: [CardActionItem] = []
            if let url = issueURL(issue).flatMap(URL.init(string:)) {
                children.append(CardActionItem(id: "issue.open", title: "Open on GitHub", kind: .perform { environment.open(url) }))
            }
            children.append(CardActionItem(id: "issue.copyNumber", title: "Copy Issue Number", kind: .perform { environment.copy("#\(number)") }))
            if let url = issueURL(issue) {
                children.append(CardActionItem(id: "issue.copyLink", title: "Copy Issue Link", kind: .perform { environment.copy(url) }))
            }
            if let onUnlink = actions.onUnlink {
                children.append(CardActionItem(id: "issue.unlink", title: "Unlink Issue", kind: .perform { onUnlink(.issue) }))
            }
            items.append(CardActionItem(
                id: "issue", title: "Issue: #\(number)", icon: "circle.circle",
                paletteTitle: "Issue #\(number)", kind: .submenu(children)
            ))
        }
        return items
    }

    private var primaryItems: [CardActionItem] {
        var items: [CardActionItem] = []
        if card.column == .backlog && !card.hasRunningSession {
            items.append(CardActionItem(
                id: "start", title: "Start", icon: "play.fill", paletteTitle: "Start Card",
                kind: .perform(actions.onStart)
            ))
        } else {
            items.append(CardActionItem(
                id: "resume", title: "Resume Session", icon: "play.fill",
                shortcut: .resumeAssistant, kind: .perform(actions.onResume)
            ))
        }
        items.append(CardActionItem(
            id: "fork", title: "Fork Session", icon: "arrow.branch",
            isDisabled: !hasSessionPath, kind: .perform { actions.onFork(true) }
        ))
        items.append(CardActionItem(
            id: "trim", title: "Trim Session History", icon: "scissors",
            isDisabled: !hasSessionPath, kind: .perform(actions.onTrimSession)
        ))
        if let onShowPromptHistory = actions.onShowPromptHistory {
            items.append(CardActionItem(
                id: "promptHistory", title: "Prompt History", icon: "list.bullet.rectangle.portrait",
                kind: .perform(onShowPromptHistory)
            ))
        }
        if let onShowVault = actions.onShowVault {
            items.append(CardActionItem(
                id: "vault", title: "Vault Releases", icon: "key", kind: .perform(onShowVault)
            ))
        }
        items.append(CardActionItem(
            id: "rename", title: "Rename", icon: "pencil", paletteTitle: "Rename Card",
            shortcut: .renameCard, kind: .perform(actions.onRenameRequest)
        ))
        if card.link.parentCardId == nil {
            let pinned = card.link.isPinned
            items.append(CardActionItem(
                id: "pin", title: pinned ? "Unpin Card" : "Pin Card",
                icon: pinned ? "pin.slash" : "pin",
                shortcut: .togglePin, kind: .perform { actions.onSetPinned(!pinned) }
            ))
        }
        items.append(compactSettingsItem)
        if actions.subagentCount > 0 {
            items.append(CardActionItem(
                id: "subagents", title: "See All Subagents (\(actions.subagentCount))",
                icon: "point.3.connected.trianglepath.dotted", kind: .perform(actions.onShowSubagents)
            ))
        }
        if let onCheckpoint = actions.onCheckpoint {
            items.append(CardActionItem(
                id: "checkpoint", title: "Checkpoint / Restore", icon: "clock.arrow.circlepath",
                isDisabled: !hasSessionPath, kind: .perform(onCheckpoint)
            ))
        }
        return items
    }

    private var compactSettingsItem: CardActionItem {
        let selected = card.link.selfCompactContextThresholdTokens
        let label: String
        var children: [CardActionItem] = []
        if card.link.effectiveAssistant.supportsContextThresholdSelfCompact {
            label = selected.map { "Compact Settings · \(SelfCompactPolicy.tokenLabel($0))" } ?? "Compact Settings · Global"
            children.append(CardActionItem(
                id: "compact.global", title: "Use Global Settings", isChecked: selected == nil,
                kind: .perform { actions.onSetSelfCompactContextThreshold(nil) }
            ))
            let options = Array(Set(SelfCompactPolicy.cardThresholdOptions + [selected].compactMap { $0 })).sorted()
            for (i, threshold) in options.enumerated() {
                children.append(CardActionItem(
                    id: "compact.\(threshold)", title: "\(SelfCompactPolicy.tokenLabel(threshold)) tokens",
                    isChecked: selected == threshold, dividerBefore: i == 0,
                    kind: .perform { actions.onSetSelfCompactContextThreshold(threshold) }
                ))
            }
        } else {
            label = "Compact Settings · Unavailable"
            children.append(CardActionItem(
                id: "compact.unavailable",
                title: "Per-card context thresholds are currently available for Claude sessions.",
                isDisabled: true, kind: .perform {}
            ))
        }
        return CardActionItem(
            id: "compact", title: label, icon: "arrow.triangle.2.circlepath",
            paletteTitle: "Self-Compact Threshold", kind: .submenu(children)
        )
    }

    private var copyItems: [CardActionItem] {
        var items: [CardActionItem] = [
            CardActionItem(
                id: "copy.resumeCommand", title: "Copy Resume Command", icon: "doc.on.doc",
                kind: .perform(actions.onCopyResumeCmd)
            ),
            CardActionItem(
                id: "copy.conversation", title: "Copy Whole Conversation as Markdown", icon: "text.page",
                isDisabled: !hasSessionPath && card.session?.jsonlPath == nil,
                kind: .perform(actions.onCopyConversationMarkdown)
            ),
            CardActionItem(
                id: "copy.cardId", title: "Copy Card ID", icon: "number",
                kind: .perform { [id = card.id] in environment.copy(id) }
            ),
        ]
        if let sessionId = card.link.sessionLink?.sessionId {
            items.append(CardActionItem(id: "copy.sessionId", title: "Copy Session ID", icon: "desktopcomputer", kind: .perform { environment.copy(sessionId) }))
        }
        if let sessionPath = card.link.sessionLink?.sessionPath {
            items.append(CardActionItem(id: "copy.sessionPath", title: "Copy Session .jsonl Path", icon: "doc.text", kind: .perform { environment.copy(sessionPath) }))
        }
        if let tmux = card.link.tmuxLink?.sessionName {
            items.append(CardActionItem(id: "copy.tmux", title: "Copy Tmux Command", icon: "terminal", kind: .perform { environment.copy("tmux attach -t \(tmux)") }))
        }
        if let projectPath = card.link.projectPath {
            items.append(CardActionItem(id: "copy.projectPath", title: "Copy Project Path", icon: "folder.badge.gearshape", kind: .perform { environment.copy(projectPath) }))
        }
        if let worktreePath = card.link.worktreeLink?.path, !worktreePath.isEmpty {
            items.append(CardActionItem(id: "copy.worktreePath", title: "Copy Worktree Path", icon: "folder", kind: .perform { environment.copy(worktreePath) }))
        }
        return items
    }

    private var linkItems: [CardActionItem] {
        var items: [CardActionItem] = []
        for pr in card.link.prLinks.sortedByPRNumber {
            let url = resolvedPRURL(pr, githubBaseURL: githubBaseURL)
            items.append(CardActionItem(
                id: "open.pr.\(pr.number)", title: "Open PR #\(String(pr.number))", icon: "arrow.up.right.square",
                kind: .perform { if let url { environment.open(url) } }
            ))
        }
        if let issue = card.link.issueLink {
            let url = issueURL(issue).flatMap(URL.init(string:))
            items.append(CardActionItem(
                id: "open.issue", title: "Open Issue #\(String(issue.number))", icon: "arrow.up.right.square",
                kind: .perform { if let url { environment.open(url) } }
            ))
        }
        let cardId = card.id
        items.append(CardActionItem(
            id: "addLink", title: "Add Link", icon: "plus",
            kind: .perform {
                if let onAddLink = actions.onAddLink { onAddLink() } else { environment.requestAddLink(cardId) }
            }
        ))
        return items
    }

    private var discoverItems: [CardActionItem] {
        guard let onDiscover = actions.onDiscover,
              card.link.sessionLink != nil || card.link.worktreeLink != nil else { return [] }
        return [CardActionItem(
            id: "discover", title: "Discover Branches & PRs", icon: "arrow.triangle.pull",
            kind: .perform(onDiscover)
        )]
    }

    private var cleanupItems: [CardActionItem] {
        guard let onCleanupWorktree = actions.onCleanupWorktree,
              card.link.worktreeLink != nil, actions.canCleanupWorktree else { return [] }
        return [CardActionItem(
            id: "cleanupWorktree", title: "Cleanup Worktree", icon: "trash",
            isDestructive: true, kind: .perform(onCleanupWorktree)
        )]
    }

    private var continueOnItems: [CardActionItem] {
        let targets = environment.continueTargets
        guard !targets.isEmpty, card.link.sessionLink != nil || card.owner != nil else { return [] }
        let cardId = card.id
        let children = targets.map { item in
            CardActionItem(id: "continueOn.\(item.target)", title: item.label, kind: .perform {
                environment.moveCard(cardId, item.target)
            })
        }
        return [CardActionItem(
            id: "continueOn", title: "Continue on", icon: "arrow.right.arrow.left.circle",
            kind: .submenu(children)
        )]
    }

    private var moveToProjectItems: [CardActionItem] {
        guard card.link.sessionLink != nil else { return [] }
        let otherProjects = availableProjects.filter { $0.path != card.link.projectPath }
        var children = otherProjects.map { project in
            CardActionItem(id: "moveToProject.\(project.path)", title: project.name, kind: .perform {
                actions.onMoveToProject(project.path)
            })
        }
        children.append(CardActionItem(
            id: "moveToProject.folder", title: "Select Folder...", dividerBefore: !otherProjects.isEmpty,
            kind: .perform(actions.onMoveToFolder)
        ))
        return [CardActionItem(
            id: "moveToProject", title: "Move to Project", icon: "folder", kind: .submenu(children)
        )]
    }

    private var migrateItems: [CardActionItem] {
        guard card.link.sessionLink != nil else { return [] }
        let targets = enabledAssistants.filter { $0 != card.link.effectiveAssistant }
        guard !targets.isEmpty else { return [] }
        let children = targets.map { target in
            CardActionItem(id: "migrate.\(target.rawValue)", title: target.displayName, kind: .perform {
                actions.onMigrateAssistant(target)
            })
        }
        return [CardActionItem(
            id: "migrate", title: "Migrate to Assistant", icon: "arrow.triangle.swap", kind: .submenu(children)
        )]
    }

    private var machineItems: [CardActionItem] {
        guard let remote = card.link.remote, remote.mode == .boxd,
              !environment.isSharedMachine(remote.machineName) else { return [] }
        let cardId = card.id
        var items: [CardActionItem] = []
        if remote.pausedReason == nil, card.link.tmuxLink != nil {
            items.append(CardActionItem(
                id: "machine.stop", title: "Stop Machine \(remote.machineName)", icon: "stop.circle",
                kind: .perform { environment.pauseMachine(cardId) }
            ))
        }
        if card.link.tmuxLink == nil || remote.pausedReason != nil {
            items.append(CardActionItem(
                id: "machine.destroy", title: "Destroy Machine \(remote.machineName)", icon: "xmark.icloud",
                isDestructive: true, kind: .perform { environment.destroyMachine(cardId) }
            ))
        }
        return items
    }

    private var archiveItems: [CardActionItem] {
        let delete = CardActionItem(
            id: "delete", title: "Delete Card", icon: "trash", isDestructive: true,
            shortcut: .deleteCard, kind: .perform(actions.onDelete)
        )
        if card.link.manuallyArchived {
            let cardId = card.id
            var items = [CardActionItem(
                id: "unarchive", title: "Unarchive", icon: "tray.and.arrow.up", paletteTitle: "Unarchive Card",
                kind: .perform { environment.unarchive(cardId) }
            )]
            if card.link.source != .githubIssue { items.append(delete) }
            return items
        }
        if let onArchive = actions.onArchive {
            return [CardActionItem(
                id: "archive", title: "Archive", icon: "archivebox", paletteTitle: "Archive Card",
                shortcut: .archiveCard, kind: .perform(onArchive)
            )]
        }
        return [delete]
    }
}
