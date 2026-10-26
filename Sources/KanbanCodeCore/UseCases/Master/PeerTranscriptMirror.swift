import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import KanbanCodeRemoteKit

/// Keeps local copies of the transcripts of cards other masters own, and
/// their busy state, so their chat shows here as if they ran here.
///
/// Each copy grows by the bytes the owner appended since the last read
/// (`GET /v1/cards/{id}/transcript/raw?offset=`); a transcript that shrank
/// on the owner (a trim, a checkpoint) is copied again from the start. The
/// selected card is read every tick, the others every few ticks.
@MainActor
public final class PeerTranscriptMirror {
    private let engine: MasterEngine
    private let directory: String
    private var tick = 0
    private var inFlight: Set<String> = []

    public init(engine: MasterEngine, kanbanHome: String = (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code")) {
        self.engine = engine
        self.directory = (kanbanHome as NSString).appendingPathComponent("peers")
    }

    /// Where the copy of a session's transcript owned by `machineId` lives.
    public nonisolated static func mirrorPath(directory: String, machineId: String, sessionId: String) -> String {
        "\(directory)/\(machineId)/transcripts/\(sessionId).jsonl"
    }

    public func run(interval: Duration = .milliseconds(1500)) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: interval)
            await pass()
        }
    }

    func pass() async {
        tick += 1
        let state = engine.store.state
        let local = state.localMachineId
        guard !local.isEmpty else { return }
        let online = Set(state.peerStatuses.values.compactMap { $0.online ? $0.machine?.id : nil })
        guard !online.isEmpty else { return }

        if tick % 2 == 0 { await scanActivity(online: online) }

        for link in state.links.values {
            guard let owner = link.ownerMachine, owner != local, online.contains(owner),
                  let sessionId = link.sessionLink?.sessionId,
                  !link.manuallyArchived, link.column != .allSessions, !link.isTombstone
            else { continue }
            let selected = state.selectedCardId == link.id
            let path = Self.mirrorPath(directory: directory, machineId: owner, sessionId: sessionId)
            let hasCopy = FileManager.default.fileExists(atPath: path)
            // The selected card every tick; live ones every 4; the rest
            // once, then every 40.
            let live = link.tmuxLink != nil && link.tmuxLink?.isPrimaryDead != true
            let every = selected ? 1 : (live ? 4 : (hasCopy ? 40 : 1))
            guard tick % every == 0, !inFlight.contains(link.id) else { continue }
            inFlight.insert(link.id)
            defer { inFlight.remove(link.id) }
            await copy(cardId: link.id, owner: owner, sessionId: sessionId, path: path)
        }
        await mirrorConversations(state: state, local: local, online: online)
    }

    /// Copies the conversation logs of other masters' cards whose
    /// conversations differ from the copy here: the owner's board says so.
    private func mirrorConversations(state: AppState, local: String, online: Set<String>) async {
        for (cardId, peer) in state.peerCards {
            guard let owner = state.links[cardId]?.ownerMachine, owner != local, online.contains(owner) else { continue }
            let here = (state.conversations[cardId] ?? []).filter { !$0.archived }
            guard here != peer.conversations, !inFlight.contains("conv-" + cardId) else { continue }
            inFlight.insert("conv-" + cardId)
            defer { inFlight.remove("conv-" + cardId) }
            await engine.mirrorConversations(cardId: cardId)
        }
    }

    private func copy(cardId: String, owner: String, sessionId: String, path: String) async {
        guard let client = await engine.peerClient(machineId: owner) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var size = ((try? fm.attributesOfItem(atPath: path))?[.size] as? Int) ?? 0
        var restarted = false
        for _ in 0..<32 {
            guard let slice = try? await client.rawTranscript(cardId: cardId, offset: size) else { return }
            if slice.size < size, !restarted {
                // The owner rewrote the transcript: copy it again.
                try? fm.removeItem(atPath: path)
                size = 0
                restarted = true
                continue
            }
            if slice.data.isEmpty { break }
            append(slice.data, to: path)
            size += slice.data.count
            if size >= slice.size { break }
        }
        if fm.fileExists(atPath: path), engine.store.state.peerTranscriptPaths[sessionId] != path {
            engine.store.dispatch(.peerTranscriptMirrored(sessionId: sessionId, path: path))
        }
    }

    private func append(_ data: Data, to path: String) {
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: data)
            return
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    /// Reads the cards the online peers own: live, in a turn, queued.
    private func scanActivity(online: Set<String>) async {
        var cards: [String: PeerCardState] = [:]
        for machineId in online {
            guard let client = await engine.peerClient(machineId: machineId),
                  let board = try? await client.board() else { continue }
            let links = engine.store.state.links
            for card in board.cards where links[card.id]?.ownerMachine == machineId {
                cards[card.id] = Self.state(of: card)
            }
        }
        if engine.store.state.peerCards != cards {
            engine.store.dispatch(.peerActivityScanned(cards: cards))
        }
    }

    public nonisolated static func state(of card: RemoteCard) -> PeerCardState {
        PeerCardState(
            isLive: card.isLive,
            isBusy: card.isBusy,
            queue: card.queuedPrompts.map { QueuedPrompt(id: $0.id, body: $0.text, sendAutomatically: true) },
            status: card.sessionStatus,
            conversations: card.conversations)
    }
}
