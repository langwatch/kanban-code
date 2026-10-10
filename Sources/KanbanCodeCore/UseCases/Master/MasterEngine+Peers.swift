import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import KanbanCodeRemoteKit

/// A first launch this master handed to a peer: the peer adopts the card and
/// starts it with this prompt.
struct PeerLaunch: Sendable {
    var prompt: String
    var worktree: String?
}

public enum MasterPeerError: Error, LocalizedError, Equatable {
    case unknownCard(String)
    case notOwner(String)
    case unknownPeer(String)
    case peerOffline(String)
    case busy(String)
    case noProject(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unknownCard(let id): "no card \(id)"
        case .notOwner(let id): "card \(id) runs on another master"
        case .unknownPeer(let name): "no peer master \(name)"
        case .peerOffline(let name): "\(name) is offline"
        case .busy(let id): "card \(id) is launching or moving already"
        case .noProject(let url): "no project with origin \(url) here; add it in Settings"
        case .failed(let message): message
        }
    }
}

// MARK: - Peers

extension MasterEngine {
    /// The peer master `target` names: its machine id, its name, or the
    /// ssh machine it runs on (any case).
    public func peerMachine(named target: String) -> MachineIdentity? {
        store.state.peerMachine(named: target)
    }

    /// Whether `target` names this master.
    public func isLocalMachine(_ target: String) -> Bool {
        let state = store.state
        return Self.isLocalTarget(target) || target == state.localMachineId
            || (!state.localMachineName.isEmpty && target.lowercased() == state.localMachineName.lowercased())
    }

    /// Whether the peer with this machine id answered its last pull.
    public func isPeerOnline(_ machineId: String) -> Bool {
        store.state.peerStatuses.values.contains { $0.machine?.id == machineId && $0.online }
    }

    /// A client of the peer master with this machine id, with the token
    /// this master holds for it.
    public func peerClient(machineId: String) async -> RemoteClient? {
        guard let peerSync, let peer = await peerSync.peer(forMachine: machineId),
              let url = URL(string: peer.url.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return RemoteClient(baseURL: url, token: peer.token)
    }

    /// The owner's client when another master owns the card.
    public func ownerClient(forCard cardId: String) async -> RemoteClient? {
        guard let link = store.state.links[cardId], let owner = link.ownerMachine,
              owner != store.state.localMachineId, !store.state.localMachineId.isEmpty
        else { return nil }
        return await peerClient(machineId: owner)
    }

    /// Whether another master owns the card.
    public func isForeign(_ cardId: String) -> Bool {
        guard let owner = store.state.links[cardId]?.ownerMachine else { return false }
        let local = store.state.localMachineId
        return !local.isEmpty && owner != local
    }

    /// Sends the prompt and queue actions on cards another master owns to
    /// that master, the way the phone does: the owner runs them.
    public func installForeignCardHandler() {
        store.foreignCardHandler = { [weak self] action in
            self?.handleForeignAction(action) ?? false
        }
    }

    func handleForeignAction(_ action: Action) -> Bool {
        switch action {
        case .addQueuedPrompt(let cardId, let prompt, _):
            guard isForeign(cardId) else { return false }
            forwardedPromptIds.insert(prompt.id)
            let images = (prompt.imagePaths ?? []).compactMap { path -> RemoteImage? in
                guard let data = FileManager.default.contents(atPath: path) else { return nil }
                return RemoteImage(mediaType: MasterRemoteControlHost.mediaType(ofExtension: (path as NSString).pathExtension),
                                   data: data.base64EncodedString())
            }
            forwardToOwner(cardId, "send the prompt") { client in
                try await client.sendPrompt(cardId: cardId, text: prompt.body, mode: .queue, images: images,
                                            human: prompt.isHuman)
            }
            return true
        case .sendQueuedPrompt(let cardId, let promptId):
            guard isForeign(cardId) else { return false }
            if forwardedPromptIds.remove(promptId) != nil { return true }
            forwardToOwner(cardId, "send the queued prompt") { client in
                try await client.sendQueuedPromptNow(cardId: cardId, promptId: promptId)
            }
            return true
        case .removeQueuedPrompt(let cardId, let promptId):
            guard isForeign(cardId) else { return false }
            forwardToOwner(cardId, "remove the queued prompt") { client in
                try await client.removeQueuedPrompt(cardId: cardId, promptId: promptId)
            }
            return true
        case .updateQueuedPrompt(let cardId, let promptId, let body, _):
            guard isForeign(cardId) else { return false }
            forwardToOwner(cardId, "edit the queued prompt") { client in
                try await client.editQueuedPrompt(cardId: cardId, promptId: promptId, text: body)
            }
            return true
        case .reorderQueuedPrompts(let cardId, _):
            // The owner keeps its queue in the order it was sent.
            return isForeign(cardId)
        default:
            return false
        }
    }

    /// Runs `call` on the card's owner, reporting a failure on the board.
    /// A start (`isStart`) reports on the card itself: its status bar shows
    /// the owner's answer, the way a start here shows its own.
    func forwardToOwner(_ cardId: String, _ what: String, isStart: Bool = false,
                        _ call: @escaping @Sendable (RemoteClient) async throws -> Void) {
        if isStart { store.dispatch(.cardStartReported(cardId: cardId, report: nil)) }
        Task {
            let owner = peerName(store.state.links[cardId]?.ownerMachine ?? "")
            guard let client = await ownerClient(forCard: cardId) else {
                report("Could not \(what): \(owner) is not a configured peer")
                return
            }
            do {
                try await call(client)
                // Show the owner's answer (queue, busy) without waiting for the next scan.
                if let card = try? await client.card(id: cardId) {
                    store.dispatch(.peerCardRead(cardId: cardId, state: PeerTranscriptMirror.state(of: card)))
                }
            } catch {
                report("Could not \(what) on \(owner): \(error.localizedDescription)")
            }
        }
        func report(_ message: String) {
            if isStart {
                store.dispatch(.cardStartReported(cardId: cardId, report: .failed(message)))
            } else {
                store.dispatch(.setError(message))
            }
        }
    }

    /// Stops the running turn of a card, here or on its owner.
    public func interrupt(cardId: String) {
        if isForeign(cardId) {
            forwardToOwner(cardId, "interrupt") { client in try await client.interrupt(cardId: cardId) }
            return
        }
        guard let session = store.state.links[cardId]?.tmuxLink?.sessionName else { return }
        let tmux = self.tmux
        Task { try? await tmux.sendEscape(sessionName: session) }
    }

    /// Keeps an image on the master that owns the card and returns its path
    /// there, for a paste into the card's terminal here to type.
    public func uploadPastedImage(cardId: String, data: Data) async throws -> String {
        guard let client = await ownerClient(forCard: cardId) else {
            throw MasterPeerError.unknownPeer(peerName(store.state.links[cardId]?.ownerMachine ?? "the owner"))
        }
        return try await client.uploadPastedImage(cardId: cardId, data: data).path
    }

    /// Sends an image dropped on a card another master owns to its session
    /// there, as a message of its own. False when this master owns the card.
    @discardableResult
    public func sendDroppedImage(cardId: String, png: Data) -> Bool {
        guard isForeign(cardId) else { return false }
        let image = RemoteImage(mediaType: "image/png", data: png.base64EncodedString())
        forwardToOwner(cardId, "send the image") { client in
            try await client.sendPrompt(cardId: cardId, text: "", images: [image])
        }
        return true
    }

    /// Asks the peers to pull now.
    public func notifyPeers() {
        guard let peerSync else { return }
        Task.detached { await peerSync.notifyPeers() }
    }

    // MARK: Moves

    /// Where a resume picked in the resume dialog sends a card another
    /// master owns: nil when the pick is that owner, which resumes the card
    /// where it is; "mac" or the picked machine otherwise, where the card
    /// moves and continues.
    public func movePick(forForeignCard cardId: String, runRemotely: Bool, machineChoice: BoxdMachineChoice?) -> String? {
        guard isForeign(cardId), let owner = store.state.links[cardId]?.ownerMachine else { return nil }
        guard runRemotely else { return "mac" }
        guard let name = machineChoice?.machineName, peerMachine(named: name)?.id != owner else { return nil }
        return name
    }

    /// Moves a card to `target` and reports a refusal on the card, the way
    /// a failed start is.
    public func moveCardReporting(_ cardId: String, to target: String) {
        store.dispatch(.cardStartReported(cardId: cardId, report: nil))
        Task {
            do {
                try await moveCard(cardId, to: target)
            } catch {
                let place = isLocalMachine(target) ? "this Mac" : target
                store.dispatch(.cardStartReported(
                    cardId: cardId, report: .failed("Could not move the card to \(place): \(error.localizedDescription)")))
            }
        }
    }

    /// Continues a card somewhere else. `target` is a peer master (by id or
    /// name: the card's ownership moves there), "mac"/"local" or this
    /// master's name (the card comes back here from a machine this master
    /// drives), or a boxd/ssh machine this master drives. A card another
    /// master owns is moved by its owner.
    public func moveCard(_ cardId: String, to target: String) async throws {
        guard let link = store.state.links[cardId] else { throw MasterPeerError.unknownCard(cardId) }
        if let client = await ownerClient(forCard: cardId) {
            let forwarded = isLocalMachine(target) ? store.state.localMachineId : target
            _ = try await client.move(cardId: cardId, to: forwarded)
            return
        }
        guard store.state.isOwnedLocally(link) else { throw MasterPeerError.notOwner(cardId) }
        if isLocalMachine(target) {
            if link.remote != nil, link.isRemote { moveCardToMachine(cardId, to: "local") }
            return
        }
        if let peer = peerMachine(named: target) {
            try await handover(cardId: cardId, to: peer.id)
            return
        }
        guard link.sessionLink != nil else { throw MasterPeerError.failed("card \(cardId) has no conversation to move") }
        moveCardToMachine(cardId, to: target)
    }

    /// Hands a card this master owns to a peer: its session here ends, the
    /// worktree branch goes to origin, and the card is released with
    /// `migrating` set. The peer adopts it once the release reaches it:
    /// it pulls the transcript (and uncommitted changes) from here and
    /// resumes the conversation.
    public func handover(cardId: String, to machineId: String) async throws {
        guard let link = store.state.links[cardId] else { throw MasterPeerError.unknownCard(cardId) }
        guard store.state.isOwnedLocally(link) else { throw MasterPeerError.notOwner(cardId) }
        guard link.isLaunching != true, !handoversInFlight.contains(cardId) else { throw MasterPeerError.busy(cardId) }
        guard await peerClient(machineId: machineId) != nil else { throw MasterPeerError.unknownPeer(machineId) }
        guard isPeerOnline(machineId) else { throw MasterPeerError.peerOffline(peerName(machineId)) }
        handoversInFlight.insert(cardId)
        defer { handoversInFlight.remove(cardId) }
        KanbanCodeLog.info("handover", "Releasing card=\(cardId.prefix(12)) to \(peerName(machineId))")

        // A card on a machine this master drives comes back first, so its
        // transcript here is complete.
        if let remote = link.remote, link.isRemote, let boxdSupervisor {
            let sid = link.sessionLink?.sessionId ?? link.id
            let names = (link.tmuxLink?.allSessionNames ?? []) + ["\(link.effectiveAssistant.cliCommand)-\(sid.prefix(8))"]
            await boxdSupervisor.leave(
                machineName: remote.machineName,
                sessionNames: Array(Set(names)),
                localTranscript: link.sessionLink?.sessionPath,
                remoteCwd: remote.remoteCwd)
        }
        // The conversation runs in one place only.
        for name in link.tmuxLink?.allSessionNames ?? [] {
            try? await tmux.killSession(name: name)
        }
        if link.tmuxLink != nil { try? await Task.sleep(for: .seconds(1)) }

        if let worktree = link.worktreeLink, let branch = worktree.branch, !branch.isEmpty,
           FileManager.default.fileExists(atPath: worktree.path) {
            let pushed = await Self.git(["push", "-u", "origin", "HEAD:refs/heads/\(branch)"], in: worktree.path)
            if pushed?.succeeded == true {
                KanbanCodeLog.info("handover", "Pushed \(branch) from \(worktree.path)")
            } else {
                KanbanCodeLog.warn("handover", "Push of \(branch) failed: \(pushed?.stderr.prefix(300) ?? "no git")")
            }
        }
        releasedCards[cardId] = store.state.links[cardId]
        store.dispatch(.releaseCardOwnership(cardId: cardId, to: machineId))
        guard store.state.links[cardId]?.ownerMachine == machineId else {
            throw MasterPeerError.failed("card \(cardId) could not be released")
        }
        notifyPeers()
    }

    /// Why the card cannot start here yet: it is moving here from a peer
    /// and its transcript is still on the way. The adoption starts it once
    /// the copy is done. Nil when the card can start.
    public func stillMovingHere(_ cardId: String) -> String? {
        guard let link = store.state.links[cardId], link.migrating == true, store.state.isOwnedLocally(link) else { return nil }
        let line = store.state.handoverLine(cardId: cardId) ?? "Moving here"
        return "\(line). It resumes by itself once it is here."
    }

    /// The name of the peer master with this machine id, as Settings shows it.
    public func peerDisplayName(_ machineId: String) -> String { peerName(machineId) }

    func peerName(_ machineId: String) -> String {
        store.state.peerStatuses.values.first { $0.machine?.id == machineId }?.machine?.name ?? machineId
    }

    /// Hands a card that never ran to a peer, which launches it there.
    func launchOnPeer(cardId: String, prompt: String, worktree: String?, peer: MachineIdentity) {
        pendingPeerLaunches[cardId] = PeerLaunch(prompt: prompt, worktree: worktree)
        KanbanCodeLog.info("handover", "Launching card=\(cardId.prefix(12)) on \(peer.name)")
        if store.state.links[cardId]?.column == .backlog {
            store.dispatch(.moveCard(cardId: cardId, to: .inProgress))
        }
        releasedCards[cardId] = store.state.links[cardId]
        store.dispatch(.releaseCardOwnership(cardId: cardId, to: peer.id))
        notifyPeers()
    }

    // MARK: Serving a handover

    /// What a master adopting `cardId` needs from this one.
    public func handoverInfo(cardId: String) async throws -> RemoteHandoverInfo {
        // The card as it was when this master released it: the new owner's
        // edits may already have landed here.
        guard let link = releasedCards[cardId] ?? store.state.links[cardId] else { throw MasterPeerError.unknownCard(cardId) }
        let transcript = link.sessionLink?.sessionPath
        let size = transcript.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0))?[.size] as? Int } ?? 0
        let repoRoot = link.projectPath
        let worktree = link.worktreeLink.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        var repoUrl: String?
        if let dir = worktree?.path ?? repoRoot, FileManager.default.fileExists(atPath: dir) {
            repoUrl = await Self.git(["remote", "get-url", "origin"], in: dir)
                .flatMap { $0.succeeded ? $0.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil }
        }
        var patch: String?
        if let worktree {
            if let diff = await Self.uncommittedDiff(in: worktree.path), diff.succeeded,
               !diff.stdout.isEmpty, diff.stdout.utf8.count < 20 << 20 {
                // The command runner trims the last newline, which git apply needs.
                let text = diff.stdout.hasSuffix("\n") ? diff.stdout : diff.stdout + "\n"
                patch = Data(text.utf8).base64EncodedString()
            }
        }
        KanbanCodeLog.info("handover", "Serving card=\(cardId.prefix(12)) transcript=\(transcript ?? "none") (\(size) bytes)")
        let launch = pendingPeerLaunches[cardId]
        var info = RemoteHandoverInfo(
            cardId: cardId,
            sessionId: link.sessionLink?.sessionId,
            assistant: link.effectiveAssistant.rawValue,
            projectPath: repoRoot,
            cwd: worktree?.path ?? repoRoot,
            repoUrl: repoUrl,
            branch: worktree?.branch ?? link.worktreeLink?.branch,
            worktreeName: (worktree?.path ?? link.worktreeLink?.path).map { ($0 as NSString).lastPathComponent }
                .flatMap { $0.isEmpty ? nil : $0 },
            patch: patch,
            transcriptSize: size
        )
        if repoUrl == nil, let repoRoot, FileManager.default.fileExists(atPath: repoRoot) {
            info.repoHasCommits = await Self.git(["rev-parse", "--verify", "-q", "HEAD"], in: repoRoot)?.succeeded == true
        }
        if let launch {
            info.launchPrompt = launch.prompt
            info.launchWorktree = launch.worktree
        }
        if let remote = link.remote, link.isRemote,
           let target = store.state.links[cardId]?.ownerMachine,
           store.state.sshMachine(named: remote.machineName, runningMaster: target) != nil {
            info.machineCwd = remote.remoteCwd
        }
        return info
    }

    /// A slice of the card's transcript file.
    public func rawTranscript(cardId: String, offset: Int, limit: Int) throws -> RemoteRawTranscript {
        guard let link = releasedCards[cardId] ?? store.state.links[cardId] else { throw MasterPeerError.unknownCard(cardId) }
        guard let path = link.sessionLink?.sessionPath, let handle = FileHandle(forReadingAtPath: path) else {
            return RemoteRawTranscript(data: Data(), offset: offset, size: 0)
        }
        defer { try? handle.close() }
        let size = Int((try? handle.seekToEnd()) ?? 0)
        guard offset < size else { return RemoteRawTranscript(data: Data(), offset: offset, size: size) }
        try handle.seek(toOffset: UInt64(offset))
        let data = try handle.read(upToCount: min(limit, size - offset)) ?? Data()
        if releasedCards[cardId] != nil {
            // The new owner is copying the transcript of the card it adopts.
            store.dispatch(.handoverProgress(cardId: cardId, progress: HandoverProgress(copiedBytes: offset + data.count, totalBytes: size)))
        }
        return RemoteRawTranscript(data: data, offset: offset, size: size)
    }

    // MARK: Adopting

    /// Runs until cancelled: tells the peers when cards changed here, and
    /// adopts the cards peers released to this master.
    public func runOwnershipLoop() async {
        var lastNotified = store.state.syncSeq
        var lastAttempt: [String: Date] = [:]
        var scannedVersion = -1
        var lastScan = Date.distantPast
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
            let seq = store.state.syncSeq
            if seq != lastNotified {
                lastNotified = seq
                notifyPeers()
            }
            let local = store.state.localMachineId
            guard !local.isEmpty else { continue }
            // A released card stops being served once its new owner took it.
            // The cards only need a look when they changed, or when a
            // failed adoption is due for another try.
            let version = store.state.cardInputsVersion
            guard version != scannedVersion || Date().timeIntervalSince(lastScan) >= 30 else { continue }
            scannedVersion = version
            lastScan = Date()
            for (id, _) in releasedCards where store.state.links[id]?.migrating != true {
                releasedCards[id] = nil
                pendingPeerLaunches[id] = nil
                store.dispatch(.handoverProgress(cardId: id, progress: nil))
            }
            for link in store.state.links.values where link.ownerMachine == local && link.migrating == true {
                let id = link.id
                guard !handoversInFlight.contains(id) else { continue }
                if let last = lastAttempt[id], Date().timeIntervalSince(last) < 30 { continue }
                lastAttempt[id] = Date()
                handoversInFlight.insert(id)
                Task {
                    defer { handoversInFlight.remove(id) }
                    do {
                        try await adopt(cardId: id)
                        lastAttempt[id] = nil
                    } catch {
                        store.dispatch(.handoverProgress(cardId: id, progress: nil))
                        KanbanCodeLog.warn("handover", "Adopting card=\(id.prefix(12)) failed: \(error.localizedDescription)")
                        store.dispatch(.setError("Could not take over \(link.name ?? id): \(error.localizedDescription)"))
                    }
                }
            }
        }
    }

    /// Takes over a card a peer released to this master: its repository
    /// and worktree here, its transcript, then its session.
    func adopt(cardId: String) async throws {
        guard let link = store.state.links[cardId] else { throw MasterPeerError.unknownCard(cardId) }
        guard let from = link.ownerRev?.machine, from != store.state.localMachineId,
              let client = await peerClient(machineId: from)
        else { throw MasterPeerError.unknownPeer(link.ownerRev?.machine ?? "the releasing master") }
        KanbanCodeLog.info("handover", "Adopting card=\(cardId.prefix(12)) from \(peerName(from))")
        let info = try await client.handover(cardId: cardId)
        let assistant = CodingAssistant(rawValue: info.assistant) ?? link.effectiveAssistant

        let repoRoot = try await localRepository(repoUrl: info.repoUrl, fallback: info.projectPath, hasCommits: info.repoHasCommits ?? true)
        var cwd = repoRoot
        var worktreeLink: WorktreeLink?
        // A card that ran over ssh on this very machine continues in the
        // folder it ran in, uncommitted work included.
        let machineCwd = info.machineCwd.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        if let machineCwd, info.sessionId != nil {
            cwd = machineCwd
            if let branch = info.branch, machineCwd.contains("/.claude/worktrees/") {
                worktreeLink = WorktreeLink(path: machineCwd, branch: branch)
            }
            KanbanCodeLog.info("handover", "Card=\(cardId.prefix(12)) ran on this machine over ssh, continuing in \(machineCwd)")
        } else if info.sessionId != nil, let name = info.worktreeName, let branch = info.branch {
            worktreeLink = try await Self.checkoutWorktree(repoRoot: repoRoot, name: name, branch: branch)
            cwd = worktreeLink!.path
            if let patch = info.patch, let data = Data(base64Encoded: patch), !data.isEmpty {
                try await Self.applyPatch(data, in: cwd)
            }
        }

        var sessionLink: SessionLink?
        if let sessionId = info.sessionId {
            guard assistant == .claude else { throw MasterPeerError.failed("only Claude conversations move between masters") }
            // An empty transcript would replace the conversation with nothing.
            guard info.transcriptSize > 0 else {
                throw MasterPeerError.failed("\(peerName(from)) has no transcript for this card yet")
            }
            let path = transcriptPath(cwd: cwd, sessionId: sessionId)
            var raw = await Self.mirroredPrefix(
                at: PeerTranscriptMirror.mirrorPath(
                    directory: (platform.kanbanHome as NSString).appendingPathComponent("peers"),
                    machineId: from, sessionId: sessionId),
                size: info.transcriptSize, cardId: cardId, client: client) ?? Data()
            if !raw.isEmpty {
                KanbanCodeLog.info("handover", "Transcript \(sessionId.prefix(8)): \(raw.count) of \(info.transcriptSize) bytes taken from the mirror here")
            }
            store.dispatch(.handoverProgress(cardId: cardId, progress: HandoverProgress(copiedBytes: raw.count, totalBytes: info.transcriptSize)))
            while raw.count < info.transcriptSize {
                let slice = try await client.rawTranscript(cardId: cardId, offset: raw.count)
                if slice.data.isEmpty { break }
                raw.append(slice.data)
                store.dispatch(.handoverProgress(cardId: cardId, progress: HandoverProgress(copiedBytes: raw.count, totalBytes: info.transcriptSize)))
            }
            var mappings: [PathMapping] = []
            if let old = info.cwd, old != cwd { mappings.append(PathMapping(from: old, to: cwd)) }
            if let old = info.projectPath, old != repoRoot, old != info.cwd { mappings.append(PathMapping(from: old, to: repoRoot)) }
            let incomingLines = raw.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
            if machineCwd != nil, BoxdLaunchPlanner.lineCount(ofFileAt: path) >= incomingLines {
                // The session wrote this file here; the releasing master's copy
                // is a mirror of it.
                KanbanCodeLog.info("handover", "Transcript \(sessionId.prefix(8)) already here at \(path), kept")
            } else {
                try Self.writeTranscript(raw, to: path, rewriter: TranscriptPathRewriter(mappings))
                KanbanCodeLog.info("handover", "Transcript \(sessionId.prefix(8)) copied (\(raw.count) bytes) to \(path)")
            }
            sessionLink = SessionLink(sessionId: sessionId, sessionPath: path)
        }

        store.dispatch(.adoptCard(cardId: cardId, sessionLink: sessionLink, worktreeLink: worktreeLink, projectPath: repoRoot))
        guard store.state.links[cardId]?.migrating == nil else { throw MasterPeerError.failed("card \(cardId) could not be adopted") }
        notifyPeers()

        if sessionLink != nil {
            resume(
                cardId: cardId,
                runRemotely: false,
                skipPermissions: platform.skipPermissions(),
                commandOverride: nil,
                assistant: assistant,
                keepSelection: true
            )
        } else if let prompt = info.launchPrompt {
            let isGitRepo = FileManager.default.fileExists(atPath: (repoRoot as NSString).appendingPathComponent(".git"))
            launch(
                cardId: cardId,
                prompt: prompt,
                projectPath: repoRoot,
                worktreeName: isGitRepo && assistant.supportsWorktree ? info.launchWorktree : nil,
                runRemotely: false,
                skipPermissions: platform.skipPermissions(),
                assistant: assistant,
                modelOverride: link.modelOverride,
                keepSelection: true
            )
        }
    }

    /// The repository with origin `repoUrl` here: a configured project, or
    /// a clone next to the others where this master may clone.
    func localRepository(repoUrl: String?, fallback: String?, hasCommits: Bool = true) async throws -> String {
        guard let repoUrl, let wanted = Self.normalizedRepoURL(repoUrl) else {
            if let fallback, FileManager.default.fileExists(atPath: fallback) { return fallback }
            guard let fallback else { throw MasterPeerError.noProject("unknown") }
            return try await unpublishedRepository(named: (fallback as NSString).lastPathComponent, origin: fallback, hasCommits: hasCommits)
        }
        var candidates = store.state.configuredProjects.map(\.effectiveRepoRoot)
        let cloneDir = (platform.projectsDirectory as NSString).appendingPathComponent(Self.repoName(of: repoUrl))
        candidates.append(cloneDir)
        for dir in candidates where FileManager.default.fileExists(atPath: dir) {
            let origin = await Self.git(["remote", "get-url", "origin"], in: dir)
            if let out = origin?.stdout, origin?.succeeded == true, Self.normalizedRepoURL(out) == wanted {
                await addProjectIfMissing(dir)
                return dir
            }
        }
        guard platform.clonesMissingProjects else { throw MasterPeerError.noProject(repoUrl) }
        guard !FileManager.default.fileExists(atPath: cloneDir) else {
            throw MasterPeerError.failed("\(cloneDir) exists and is not a clone of \(repoUrl)")
        }
        try? FileManager.default.createDirectory(atPath: platform.projectsDirectory, withIntermediateDirectories: true)
        KanbanCodeLog.info("handover", "Cloning \(repoUrl) into \(cloneDir)")
        let clone = await Self.git(["clone", repoUrl, cloneDir], in: platform.projectsDirectory, timeout: 1200)
        guard clone?.succeeded == true else {
            throw MasterPeerError.failed("git clone \(repoUrl) failed: \(clone?.stderr.prefix(300) ?? "no git")")
        }
        await addProjectIfMissing(cloneDir)
        return cloneDir
    }

    /// The folder here for a project that has no `origin` on the master
    /// that released the card: the one of the same name in the projects
    /// directory, created as a new repository when the project has no
    /// commits to bring.
    private func unpublishedRepository(named name: String, origin: String, hasCommits: Bool) async throws -> String {
        let dir = (platform.projectsDirectory as NSString).appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dir) {
            await addProjectIfMissing(dir)
            return dir
        }
        guard platform.clonesMissingProjects else { throw MasterPeerError.noProject(origin) }
        guard !hasCommits else {
            throw MasterPeerError.failed("\(name) has no git remote, so its files cannot follow here; give it a remote, or copy it to \(dir)")
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        KanbanCodeLog.info("handover", "Starting \(name) as a new repository in \(dir)")
        guard await Self.git(["init"], in: dir)?.succeeded == true else {
            throw MasterPeerError.failed("git init in \(dir) failed")
        }
        await addProjectIfMissing(dir)
        return dir
    }

    private func addProjectIfMissing(_ path: String) async {
        guard !store.state.configuredProjects.contains(where: { $0.effectiveRepoRoot == path || $0.path == path }) else { return }
        try? await settingsStore.addProject(Project(path: path))
        await store.loadSettingsAndCache()
    }

    /// `github.com/owner/repo` for the ssh and https forms of a remote.
    nonisolated static func normalizedRepoURL(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix(".git") { s.removeLast(4) }
        if let range = s.range(of: "://") {
            s = String(s[range.upperBound...])
            if let at = s.firstIndex(of: "@"), at < (s.firstIndex(of: "/") ?? s.endIndex) {
                s = String(s[s.index(after: at)...])
            }
        } else if let at = s.firstIndex(of: "@"), let colon = s.firstIndex(of: ":"), at < colon {
            s = String(s[s.index(after: at)..<colon]) + "/" + String(s[s.index(after: colon)...])
        }
        return s.lowercased()
    }

    nonisolated static func repoName(of url: String) -> String {
        var name = (url.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).lastPathComponent
        if name.hasSuffix(".git") { name.removeLast(4) }
        if let colon = name.lastIndex(of: ":") { name = String(name[name.index(after: colon)...]) }
        return name.isEmpty ? "repo" : name
    }

    /// The worktree `name` of `repoRoot` on `branch`, from origin when the
    /// branch is not here yet.
    nonisolated static func checkoutWorktree(repoRoot: String, name: String, branch: String) async throws -> WorktreeLink {
        let path = "\(repoRoot)/.claude/worktrees/\(name)"
        if FileManager.default.fileExists(atPath: path) {
            // What this worktree held from an earlier stay here is older than
            // what comes now; it is stashed, not lost.
            if let dirty = await git(["status", "--porcelain"], in: path), !dirty.stdout.isEmpty {
                // Unstaged first: an intent-to-add entry makes the stash fail.
                _ = await git(["reset", "-q"], in: path)
                let stash = await git(["stash", "push", "--include-untracked", "-m", "kanban handover \(ISO8601DateFormatter().string(from: Date()))"], in: path)
                if stash?.succeeded == true {
                    KanbanCodeLog.info("handover", "Stashed earlier changes of worktree \(name)")
                } else {
                    KanbanCodeLog.warn("handover", "Could not stash earlier changes of worktree \(name): \(stash?.stderr.prefix(300) ?? "no git")")
                }
            }
            _ = await git(["fetch", "origin", branch], in: path)
            if await git(["merge", "--ff-only", "origin/\(branch)"], in: path)?.succeeded != true {
                KanbanCodeLog.warn("handover", "Worktree \(name) did not fast-forward to origin/\(branch)")
            }
            return WorktreeLink(path: path, branch: branch)
        }
        try? FileManager.default.createDirectory(atPath: "\(repoRoot)/.claude/worktrees", withIntermediateDirectories: true)
        _ = await git(["fetch", "origin", branch], in: repoRoot)
        let hasLocal = await git(["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], in: repoRoot)?.succeeded == true
        let hasRemote = await git(["show-ref", "--verify", "--quiet", "refs/remotes/origin/\(branch)"], in: repoRoot)?.succeeded == true
        let arguments: [String]
        if hasLocal {
            arguments = ["worktree", "add", path, branch]
        } else if hasRemote {
            arguments = ["worktree", "add", "--track", "-b", branch, path, "origin/\(branch)"]
        } else {
            arguments = ["worktree", "add", "-b", branch, path]
        }
        guard let result = await git(arguments, in: repoRoot), result.succeeded else {
            throw MasterPeerError.failed("git worktree add \(name) failed")
        }
        if hasLocal, hasRemote {
            _ = await git(["merge", "--ff-only", "origin/\(branch)"], in: path)
        }
        return WorktreeLink(path: path, branch: branch)
    }

    /// Everything uncommitted in a worktree, new files included, as a
    /// binary diff against HEAD. Built in a copy of the index, so the
    /// worktree's own index is left as it was.
    nonisolated static func uncommittedDiff(in dir: String) async -> ShellCommand.Result? {
        guard let indexPath = await git(["rev-parse", "--git-path", "index"], in: dir), indexPath.succeeded else { return nil }
        let source = indexPath.stdout.hasPrefix("/") ? indexPath.stdout : (dir as NSString).appendingPathComponent(indexPath.stdout)
        let temp = NSTemporaryDirectory() + "kanban-handover-index-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: temp) }
        if FileManager.default.fileExists(atPath: source) {
            try? FileManager.default.copyItem(atPath: source, toPath: temp)
        }
        var env = ShellCommand.loginEnvironment
        env["GIT_INDEX_FILE"] = temp
        _ = await git(["add", "-A"], in: dir, environment: env)
        return await git(["diff", "--cached", "--no-color", "--no-ext-diff", "--binary", "HEAD"], in: dir, environment: env)
    }

    nonisolated static func applyPatch(_ patch: Data, in dir: String) async throws {
        let file = NSTemporaryDirectory() + "kanban-handover-\(UUID().uuidString).patch"
        try patch.write(to: URL(fileURLWithPath: file))
        defer { try? FileManager.default.removeItem(atPath: file) }
        let result = await git(["apply", "--binary", "--whitespace=nowarn", file], in: dir)
        if result?.succeeded != true {
            KanbanCodeLog.warn("handover", "Uncommitted changes did not apply in \(dir): \(result?.stderr.prefix(300) ?? "no git")")
        }
    }

    /// The bytes of the local mirror of a peer's transcript, when they are
    /// the start of the transcript that peer serves now: the adoption then
    /// copies only the rest. The mirror's last bytes are compared with the
    /// peer's at the same offset.
    static func mirroredPrefix(at path: String, size: Int, cardId: String, client: RemoteClient) async -> Data? {
        guard let mirror = FileManager.default.contents(atPath: path), !mirror.isEmpty, mirror.count <= size else { return nil }
        let tail = min(mirror.count, 64 << 10)
        let offset = mirror.count - tail
        guard let slice = try? await client.rawTranscript(cardId: cardId, offset: offset, limit: tail),
              slice.data == mirror.suffix(tail) else { return nil }
        return mirror
    }

    /// Writes a transcript line by line with its paths rewritten.
    nonisolated static func writeTranscript(_ raw: Data, to path: String, rewriter: TranscriptPathRewriter) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var out = Data()
        out.reserveCapacity(raw.count + 4096)
        for line in raw.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
            if line.isEmpty { continue }
            let text = String(decoding: line, as: UTF8.self)
            out.append(contentsOf: Array(rewriter.rewriteLine(text).utf8))
            out.append(UInt8(ascii: "\n"))
        }
        try out.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    nonisolated static func git(_ arguments: [String], in dir: String, timeout: TimeInterval = 120,
                                environment: [String: String]? = nil) async -> ShellCommand.Result? {
        let git = ShellCommand.findExecutable("git") ?? "/usr/bin/git"
        return try? await ShellCommand.run(git, arguments: ["-c", "color.ui=false", "-c", "core.pager=cat"] + arguments,
                                           currentDirectory: dir, environment: environment, timeout: timeout)
    }
}
