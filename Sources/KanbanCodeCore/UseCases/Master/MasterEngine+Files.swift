import Foundation
import KanbanCodeRemoteKit

/// Files attached to a card's prompt that are not images. Each goes to the
/// machine where the card's assistant runs, and the prompt names its path
/// there (`PromptFiles.line`).
extension MasterEngine {
    /// Where the card's assistant runs, for a file attached to its prompt.
    public func promptFileRoute(cardId: String) -> TerminalImageRoute {
        guard let link = store.state.links[cardId] else { return .local }
        if isForeign(cardId), let owner = link.ownerMachine {
            return .peer(machineId: owner, cardId: cardId)
        }
        let machine = link.tmuxLink?.allSessionNames.lazy
            .compactMap { self.boxdSupervisor?.registry.machine(forSession: $0) }
            .first
        return machine.map { .machine($0) } ?? .local
    }

    /// Puts a file of this machine where the card's assistant runs and
    /// returns its path there.
    public func attachPromptFile(
        cardId: String, fileURL: URL,
        progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }
    ) async throws -> String {
        switch promptFileRoute(cardId: cardId) {
        case .peer(let machineId, _):
            guard let client = await ownerClient(forCard: cardId) else {
                throw MasterPeerError.unknownPeer(peerName(machineId))
            }
            return try await client.uploadPromptFile(cardId: cardId, fileURL: fileURL, progress: progress)
        case .machine(let machine):
            guard let boxdSupervisor else { throw BoxdSupervisorError.notConnected(machine) }
            return try await boxdSupervisor.uploadPromptFile(machineName: machine, localPath: fileURL.path, progress: progress)
        case .local:
            let size = (try? PromptFileReader.size(of: fileURL)) ?? 0
            let home = platform.kanbanHome
            let path = try await Task.detached {
                try PromptFileStore.importLocal(fileURL, kanbanHome: home)
            }.value
            progress(size, size)
            return path
        }
    }

    /// One chunk of a file uploaded through the remote API for a card this
    /// master owns. Once the file is whole and the card's session runs on
    /// a machine this master drives, it goes on to that machine.
    public func receivePromptFileChunk(cardId: String, _ chunk: RemotePromptFileChunk) async throws -> RemotePromptFile {
        let home = platform.kanbanHome
        let stored = try await Task.detached {
            try PromptFileStore.receive(chunk, kanbanHome: home)
        }.value
        guard stored.isComplete, case .machine(let machine) = promptFileRoute(cardId: cardId), let boxdSupervisor else {
            return stored
        }
        let remotePath = try await boxdSupervisor.uploadPromptFile(machineName: machine, localPath: stored.path)
        try? FileManager.default.removeItem(atPath: (stored.path as NSString).deletingLastPathComponent)
        return RemotePromptFile(path: remotePath, received: stored.received, size: stored.size)
    }
}
