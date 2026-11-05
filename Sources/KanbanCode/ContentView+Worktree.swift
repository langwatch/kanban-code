import SwiftUI
import KanbanCodeCore

struct WorktreeCleanupInfo: Identifiable {
    let id = UUID()
    let cardId: String
    let remotePath: String
    let localPath: String
    let errorMessage: String
}

enum WorktreeCleanupEligibility {
    /// True when cleanup will not remove a worktree another visible card still uses.
    static func canCleanup(
        branch: String?,
        cardIsStillActive: Bool,
        activeBranchCounts: [String: Int]
    ) -> Bool {
        guard let branch else { return false }
        let activeCount = activeBranchCounts[branch] ?? 0
        return cardIsStillActive ? activeCount <= 1 : activeCount == 0
    }
}

// MARK: - Worktree Cleanup

extension ContentView {

    var activeWorktreeBranchCounts: [String: Int] {
        store.state.activeWorktreeBranchCounts
    }

    /// Whether this card's worktree can be cleaned up: false when another
    /// active card depends on it, or when it goes away with its machine.
    func canCleanupWorktree(for card: KanbanCodeCard) -> Bool {
        canCleanupWorktree(
            cardId: card.id,
            branch: card.link.worktreeLink?.branch,
            manuallyArchived: card.link.manuallyArchived
        )
    }

    /// Whether this card's worktree can be cleaned up, given its branch and
    /// whether it is archived.
    func canCleanupWorktree(
        cardId: String,
        branch: String?,
        manuallyArchived: Bool,
        activeBranchCounts: [String: Int]? = nil
    ) -> Bool {
        guard store.state.worktreePlacement(cardId)?.offersCleanup ?? true else { return false }
        return WorktreeCleanupEligibility.canCleanup(
            branch: branch,
            cardIsStillActive: !manuallyArchived,
            activeBranchCounts: activeBranchCounts ?? activeWorktreeBranchCounts
        )
    }

    /// The machine a card's worktree is on, when it is not this one.
    func worktreeMachineName(cardId: String) -> String? {
        guard let placement = store.state.worktreePlacement(cardId), placement != .local else { return nil }
        return engine.machineName(of: placement)
    }

    func selectFolderForMove(cardId: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select folder to move this session to"
        panel.prompt = "Select"

        // Start in the card's current project folder if available
        if let card = store.state.cards.first(where: { $0.id == cardId }),
           let projectPath = card.link.projectPath {
            panel.directoryURL = URL(fileURLWithPath: projectPath)
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let folderPath = url.path

        // Detect if this folder is nested inside a registered project
        let parentProject = projectList
            .filter { folderPath.hasPrefix($0.path + "/") || folderPath == $0.path }
            .max(by: { $0.path.count < $1.path.count }) // longest prefix = most specific parent

        let parentProjectPath = parentProject?.path ?? folderPath
        let displayName = parentProject?.name ?? (folderPath as NSString).lastPathComponent

        if folderPath == parentProjectPath {
            // Moving to a project root — use the regular move flow
            presentDialog(.confirmMoveToProject(cardId: cardId, projectPath: folderPath, projectName: displayName))
        } else {
            // Moving to a subfolder — use the folder-specific flow
            presentDialog(.confirmMoveToFolder(cardId: cardId, folderPath: folderPath, parentProjectPath: parentProjectPath, displayName: displayName))
        }
    }

    /// Removes the card's worktree where the card lives: here, on the
    /// master that owns it, or over ssh on the machine that runs it.
    func cleanupWorktree(cardId: String) async {
        guard let card = store.state.cards.first(where: { $0.id == cardId }),
              let worktreePath = card.link.worktreeLink?.path,
              !worktreePath.isEmpty else { return }

        store.dispatch(.setBusy(cardId: cardId, busy: true))
        do {
            try await engine.removeCardWorktree(cardId: cardId)
            store.dispatch(.setBusy(cardId: cardId, busy: false))
        } catch let error as WorktreeRemovalError {
            store.dispatch(.setBusy(cardId: cardId, busy: false))
            // A mutagen card keeps its worktree on the remote host and a
            // synced copy here.
            if error.placement == .local,
               let localPath = translateRemoteWorktreePath(worktreePath, projectPath: card.link.projectPath) {
                pendingWorktreeCleanup = WorktreeCleanupInfo(
                    cardId: cardId,
                    remotePath: worktreePath,
                    localPath: localPath,
                    errorMessage: error.reason
                )
            } else {
                store.dispatch(.setError(error.localizedDescription))
            }
        } catch {
            store.dispatch(.setBusy(cardId: cardId, busy: false))
            store.dispatch(.setError("Worktree cleanup failed: \(error.localizedDescription)"))
        }
    }

    func translateRemoteWorktreePath(_ worktreePath: String, projectPath: String?) -> String? {
        let remote = store.state.globalRemoteSettings
        guard let remote else { return nil }
        guard worktreePath.hasPrefix(remote.remotePath) else { return nil }
        let suffix = String(worktreePath.dropFirst(remote.remotePath.count))
        return remote.localPath + suffix
    }

    func executeLocalWorktreeCleanup(cardId: String, localPath: String) async {
        // Reconstruct the remote path from global remote settings
        let remote = store.state.globalRemoteSettings
        let remotePath: String
        if let remote, localPath.hasPrefix(remote.localPath) {
            let suffix = String(localPath.dropFirst(remote.localPath.count))
            remotePath = remote.remotePath + suffix
        } else {
            remotePath = localPath
        }
        let info = WorktreeCleanupInfo(cardId: cardId, remotePath: remotePath, localPath: localPath, errorMessage: "")
        await executeLocalWorktreeCleanup(info)
    }

    func executeLocalWorktreeCleanup(_ info: WorktreeCleanupInfo) async {
        let remote = try? await settingsStore.read().remote

        if let remote {
            let repoRoot: String
            if let range = info.remotePath.range(of: "/.claude/worktrees/") {
                repoRoot = String(info.remotePath[..<range.lowerBound])
            } else {
                repoRoot = (info.remotePath as NSString).deletingLastPathComponent
            }

            do {
                let sshCmd = "cd '\(repoRoot)' && git worktree remove --force '\(info.remotePath)'"
                let result = try await ShellCommand.run("/usr/bin/ssh", arguments: [remote.host, sshCmd])
                if !result.succeeded {
                    KanbanCodeLog.warn("cleanup", "Remote git worktree remove failed: \(result.stderr)")
                }
            } catch {
                KanbanCodeLog.warn("cleanup", "SSH cleanup failed: \(error)")
            }
        }

        let fm = FileManager.default
        if fm.fileExists(atPath: info.localPath) {
            do {
                try fm.removeItem(atPath: info.localPath)
            } catch {
                store.dispatch(.setError("Failed to remove local copy: \(error.localizedDescription)"))
                return
            }
        }

        // Remove card if it has no session, otherwise just clear worktree link
        let card = store.state.cards.first(where: { $0.id == info.cardId })
        if card?.link.sessionLink == nil {
            store.dispatch(.deleteCard(cardId: info.cardId))
        } else {
            store.dispatch(.unlinkFromCard(cardId: info.cardId, linkType: .worktree))
        }
    }
}
