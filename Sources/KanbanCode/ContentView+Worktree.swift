import SwiftUI
import KanbanCodeCore

struct WorktreeCleanupInfo: Identifiable {
    let id = UUID()
    let cardId: String
    let remotePath: String
    let localPath: String
    let errorMessage: String
}

// MARK: - Worktree Cleanup

extension ContentView {

    var activeWorktreeBranchCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for link in store.state.links.values {
            guard !link.manuallyArchived,
                  let branch = link.worktreeLink?.branch else { continue }
            counts[branch, default: 0] += 1
        }
        return counts
    }

    /// Whether this card's worktree can be cleaned up — false if another active card depends on it.
    func canCleanupWorktree(for card: KanbanCodeCard) -> Bool {
        canCleanupWorktree(
            branch: card.link.worktreeLink?.branch,
            manuallyArchived: card.link.manuallyArchived
        )
    }

    /// Whether this link's worktree can be cleaned up — false if another active card depends on it.
    func canCleanupWorktree(
        branch: String?,
        manuallyArchived: Bool,
        activeBranchCounts: [String: Int]? = nil
    ) -> Bool {
        guard let branch else { return false }
        let activeCount = (activeBranchCounts ?? activeWorktreeBranchCounts)[branch] ?? 0
        if manuallyArchived { return activeCount == 0 }
        return activeCount <= 1
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
            store.dispatch(.showDialog(.confirmMoveToProject(cardId: cardId, projectPath: folderPath, projectName: displayName)))
        } else {
            // Moving to a subfolder — use the folder-specific flow
            store.dispatch(.showDialog(.confirmMoveToFolder(cardId: cardId, folderPath: folderPath, parentProjectPath: parentProjectPath, displayName: displayName)))
        }
    }

    func cleanupWorktree(cardId: String) async {
        guard let card = store.state.cards.first(where: { $0.id == cardId }),
              let worktreePath = card.link.worktreeLink?.path,
              !worktreePath.isEmpty else { return }

        store.dispatch(.setBusy(cardId: cardId, busy: true))
        let adapter = GitWorktreeAdapter()
        do {
            try await adapter.removeWorktree(path: worktreePath, repoRoot: card.link.projectPath, force: true)
            store.dispatch(.setBusy(cardId: cardId, busy: false))
            // If card has no session, delete it entirely — it was only a worktree
            if card.link.sessionLink == nil {
                store.dispatch(.deleteCard(cardId: cardId))
            } else {
                store.dispatch(.unlinkFromCard(cardId: cardId, linkType: .worktree))
            }
        } catch {
            store.dispatch(.setBusy(cardId: cardId, busy: false))
            if let localPath = translateRemoteWorktreePath(worktreePath, projectPath: card.link.projectPath) {
                pendingWorktreeCleanup = WorktreeCleanupInfo(
                    cardId: cardId,
                    remotePath: worktreePath,
                    localPath: localPath,
                    errorMessage: error.localizedDescription
                )
            } else {
                store.dispatch(.setError("Worktree cleanup failed: \(error.localizedDescription)"))
            }
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
