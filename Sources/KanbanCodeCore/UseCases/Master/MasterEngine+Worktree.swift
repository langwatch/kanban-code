import Foundation
import KanbanCodeRemoteKit

/// A worktree removal that failed, worded with the machine it ran on.
public struct WorktreeRemovalError: Error, LocalizedError, Equatable {
    public let placement: WorktreePlacement
    /// What git (or the owning master) answered.
    public let reason: String
    public let message: String

    public init(placement: WorktreePlacement, machine: String, reason: String) {
        self.placement = placement
        self.reason = reason
        self.message = "Worktree cleanup on \(machine) failed: \(reason)"
    }

    /// An error the owning master already worded.
    init(placement: WorktreePlacement, message: String) {
        self.placement = placement
        self.reason = message
        self.message = message
    }

    public var errorDescription: String? { message }
}

// MARK: - Worktrees where the card lives

extension MasterEngine {
    /// Display name of the machine a placement points at.
    public func machineName(of placement: WorktreePlacement) -> String {
        switch placement {
        case .local:
            let name = store.state.localMachineName
            return name.isEmpty ? "this machine" : name
        case .ownerMaster(let machineId): return peerName(machineId)
        case .sshMachine(let name), .disposableMachine(let name): return name
        }
    }

    /// Removes the card's worktree on the machine that holds it, then drops
    /// the card when it was only a worktree, or the worktree from the card.
    /// A card another master owns is removed by that master. A disposable
    /// machine takes its worktree with it, so nothing runs for one.
    @discardableResult
    public func removeCardWorktree(cardId: String) async throws -> RemoteWorktreeRemoval {
        guard let link = store.state.links[cardId],
              let placement = store.state.worktreePlacement(cardId) else {
            throw WorktreeRemovalError(placement: .local, machine: machineName(of: .local), reason: "no card \(cardId)")
        }
        let machine = machineName(of: placement)
        guard let worktree = link.worktreeLink?.path, !worktree.isEmpty else {
            throw WorktreeRemovalError(placement: placement, machine: machine, reason: "the card has no worktree")
        }
        switch placement {
        case .disposableMachine:
            return RemoteWorktreeRemoval(machine: machine, cardDeleted: false)

        case .ownerMaster(let machineId):
            guard let client = await peerClient(machineId: machineId) else {
                throw WorktreeRemovalError(placement: placement, machine: machine, reason: "\(machine) is not a configured peer")
            }
            do {
                return try await client.removeWorktree(cardId: cardId)
            } catch RemoteClientError.conflict(let message) {
                throw WorktreeRemovalError(placement: placement, message: message)
            } catch {
                throw WorktreeRemovalError(placement: placement, machine: machine, reason: error.localizedDescription)
            }

        case .local:
            do {
                try await GitWorktreeAdapter().removeWorktree(path: worktree, repoRoot: link.projectPath, force: true)
            } catch let error as WorktreeError {
                if case .removeFailed(_, let message) = error {
                    throw WorktreeRemovalError(placement: placement, machine: machine, reason: Self.gitReason(message))
                }
                throw WorktreeRemovalError(placement: placement, machine: machine, reason: error.localizedDescription)
            } catch {
                throw WorktreeRemovalError(placement: placement, machine: machine, reason: error.localizedDescription)
            }

        case .sshMachine(let name):
            guard let boxdSupervisor else {
                throw WorktreeRemovalError(placement: placement, machine: machine, reason: "this master does not drive ssh machines")
            }
            guard let paths = WorktreePlacement.remotePaths(of: link) else {
                throw WorktreeRemovalError(placement: placement, machine: machine, reason: "the card has no checkout on \(name)")
            }
            let result: ShellCommand.Result
            do {
                result = try await boxdSupervisor.exec(
                    machineName: name,
                    command: WorktreePlacement.removeCommand(worktree: paths.worktree, repoRoot: paths.repoRoot),
                    timeout: 120)
            } catch {
                throw WorktreeRemovalError(placement: placement, machine: machine, reason: error.localizedDescription)
            }
            guard result.succeeded else {
                throw WorktreeRemovalError(placement: placement, machine: machine, reason: Self.gitReason(result.stderr))
            }
        }

        KanbanCodeLog.info("worktree", "Removed worktree \(worktree) of card=\(cardId.prefix(12)) on \(machine)")
        let deleted = store.state.links[cardId]?.sessionLink == nil
        if deleted {
            store.dispatch(.deleteCard(cardId: cardId))
        } else {
            store.dispatch(.unlinkFromCard(cardId: cardId, linkType: .worktree))
        }
        notifyPeers()
        return RemoteWorktreeRemoval(machine: machine, cardDeleted: deleted)
    }

    /// Re-scans the card's conversation for pushed branches and its pull
    /// requests, on the master that owns the card.
    public func discoverBranches(cardId: String) async {
        if isForeign(cardId) {
            forwardToOwner(cardId, "discover branches") { client in try await client.discoverBranches(cardId: cardId) }
            return
        }
        await platform.discoverBranches(cardId)
    }

    nonisolated static func gitReason(_ stderr: String) -> String {
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "git exited with an error" : text
    }
}
