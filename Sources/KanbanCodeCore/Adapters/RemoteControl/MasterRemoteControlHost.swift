import Foundation
import KanbanCodeRemoteKit
import Observation

/// The remote control API over a master engine: reads the board from its
/// store and acts through the same actions and launch flow as the Mac UI.
/// The Mac app and `kanban-code-server` both serve it.
public final class MasterRemoteControlHost: RemoteControlHost, @unchecked Sendable {
    private let engine: MasterEngine
    private let store: BoardStore
    /// Esc to a session, as the stop button does (rush: its interrupt).
    private let sendEscape: @Sendable (String) async throws -> Void
    /// Runs tmux commands on the server that holds the session.
    private let runTmux: @Sendable ([[String]], String) async -> Void
    /// rush cards queue and send through rush itself: the rush of the
    /// machine that hosts the session.
    private let rushFor: @Sendable (String) throws -> RushCliAdapter
    private let queueWatch = QueueWatchFlag()
    private let searchIndex = CardSearchIndex()
    /// How long a resume request waits for the start to succeed or fail
    /// before it answers with the card as it is. Below the clients' 30 s.
    public var resumeOutcomeWait: TimeInterval = 20

    @MainActor
    public init(engine: MasterEngine,
                rush: RushCliAdapter? = nil,
                runTmux: (@Sendable ([[String]], String) async -> Void)? = nil,
                sendEscape: (@Sendable (String) async throws -> Void)? = nil) {
        self.engine = engine
        self.store = engine.store
        let tmux = engine.tmux
        if let rush {
            self.rushFor = { _ in rush }
        } else {
            self.rushFor = { session in try tmux.rush(forSession: session) }
        }
        self.runTmux = runTmux ?? { commands, session in
            guard let adapter = try? tmux.adapter(for: session) else { return }
            for command in commands {
                _ = try? await adapter.run(command)
            }
        }
        self.sendEscape = sendEscape ?? { session in try await tmux.sendEscape(sessionName: session) }
    }

    public func board() async -> RemoteBoard {
        let board = await MainActor.run {
            RemoteBoardMapper.board(
                cards: store.state.cards,
                projects: store.state.configuredProjects,
                liveSessions: store.state.tmuxSessions,
                rushQueues: store.state.rushQueues,
                machine: store.state.localMachineIdentity,
                machineNames: store.state.peerMachineNames
            )
        }
        await watchRushQueues()
        return board
    }

    /// Searches every card of this master's store, the prompt of each
    /// included, then asks the peer masters for the cards only they know
    /// (their unclaimed All Sessions cards are not synced here).
    public func searchCards(_ request: RemoteCardSearchRequest) async -> RemoteCardSearchResult {
        let snapshot = await MainActor.run {
            (cards: store.state.cards, live: store.state.tmuxSessions, queues: store.state.rushQueues,
             machine: store.state.localMachineIdentity, names: store.state.peerMachineNames,
             peers: request.local ? [] : store.state.peerStatuses.values.compactMap { status in
                 status.machine.map { (machine: $0, online: status.online) }
             })
        }
        let local = Self.search(snapshot.cards, request, index: searchIndex) { card in
            RemoteBoardMapper.card(card, liveSessions: snapshot.live, rushQueues: snapshot.queues,
                                   machine: snapshot.machine, machineNames: snapshot.names)
        }
        guard !request.local, !snapshot.peers.isEmpty else { return local }
        var peers: [RemoteCardSearch.Peer] = []
        var offline: [String] = []
        for peer in snapshot.peers.sorted(by: { $0.machine.id < $1.machine.id }) {
            guard peer.online, let client = await engine.peerClient(machineId: peer.machine.id) else {
                offline.append(peer.machine.name)
                continue
            }
            peers.append(RemoteCardSearch.Peer(machineId: peer.machine.id, name: peer.machine.name) {
                try await client.searchCards(request.query, scope: request.scope, limit: request.limit, local: true,
                                             timeout: RemoteCardSearch.peerTimeout)
            })
        }
        return await RemoteCardSearch.fanOut(local: local, peers: peers, offline: offline, limit: request.limit)
    }

    /// The search over this master's own cards. Only the cards that make
    /// the answer are turned into wire cards.
    static func search(_ cards: [KanbanCodeCard], _ request: RemoteCardSearchRequest, index: CardSearchIndex,
                       wire: (KanbanCodeCard) -> RemoteCard) -> RemoteCardSearchResult {
        func column(_ card: KanbanCodeCard) -> RemoteColumn { RemoteColumn(rawValue: card.link.column.rawValue) ?? .backlog }
        func activity(_ card: KanbanCodeCard) -> Date { card.link.lastActivity ?? card.link.updatedAt }
        let workingSet = request.scope == .older
            ? RemoteWorkingSet.ids(cards.map {
                RemoteWorkingSet.Member(id: $0.id, column: column($0), archived: $0.link.manuallyArchived, activity: activity($0))
            })
            : []
        let admitted = cards.filter {
            RemoteCardSearch.admits(scope: request.scope, id: $0.id, archived: $0.link.manuallyArchived,
                                    isSubagent: $0.link.parentCardId != nil, workingSet: workingSet)
        }
        let matches = index.matching(admitted, query: CardSearchQuery(request.query))
        let ranked = matches.map { card in
            (card: card, entry: CardSearch.Entry(
                id: card.id, onBoard: !card.link.manuallyArchived && card.link.column != .allSessions, activity: activity(card)))
        }.sorted { CardSearch.ranks($0.entry, before: $1.entry) }
        return RemoteCardSearchResult(cards: ranked.prefix(request.limit).map { wire($0.card) },
                                      truncated: ranked.count > request.limit)
    }

    public func machines() async -> [RemoteMachineEntry] {
        await MainActor.run { store.state.remoteMachines }
    }

    @MainActor
    private func card(_ cardId: String) throws -> KanbanCodeCard {
        guard let card = store.state.cards.first(where: { $0.id == cardId }) else {
            throw RemoteHostError.notFound("no card \(cardId)")
        }
        return card
    }

    @MainActor
    private func remoteCard(_ cardId: String) throws -> RemoteCard {
        RemoteBoardMapper.card(try card(cardId), liveSessions: store.state.tmuxSessions, rushQueues: store.state.rushQueues,
                               machine: store.state.localMachineIdentity, machineNames: store.state.peerMachineNames)
    }

    public func transcript(cardId: String, limit: Int, before: String?) async throws -> RemoteTranscript {
        if let owner = await ownerClient(cardId) {
            return try await forwarded { try await owner.transcript(cardId: cardId, limit: limit, before: before) }
        }
        let (path, assistant) = try await MainActor.run { () throws -> (String?, CodingAssistant) in
            let card = try card(cardId)
            return (card.link.sessionLink?.sessionPath ?? card.session?.jsonlPath, card.link.effectiveAssistant)
        }
        guard let path, FileManager.default.fileExists(atPath: path) else {
            return RemoteTranscript(cardId: cardId, messages: [])
        }
        return try await RemoteTranscriptMapper.page(cardId: cardId, limit: limit, before: before) { maxTurns in
            switch assistant {
            case .claude:
                let r = try await TranscriptReader.readTail(from: path, maxTurns: maxTurns)
                return (r.turns, r.hasMore)
            case .codex:
                let r = try await CodexSessionParser.readTail(from: path, maxTurns: maxTurns)
                return (r.turns, r.hasMore)
            default:
                let all = try await GeminiSessionStore().readTranscript(sessionPath: path)
                return (Array(all.suffix(maxTurns)), all.count > maxTurns)
            }
        }
    }

    public func createTask(_ request: RemoteTaskRequest) async throws -> RemoteCard {
        var projectPath = await MainActor.run {
            RemoteBoardMapper.resolveProject(request.project, in: store.state.configuredProjects)?.path
        }
        if projectPath == nil, let peer = await peerTaskClient(request.machine) {
            // A project this master does not know, for another master: that
            // master creates and runs the card.
            var task = request
            task.machine = "here"
            return try await forwarded { try await peer.createTask(task) }
        }
        if projectPath == nil, Self.isRepositoryURL(request.project) {
            // A peer launching here names the repository by its origin.
            do {
                projectPath = try await engine.localRepository(repoUrl: request.project, fallback: nil)
            } catch let error as MasterPeerError {
                throw Self.hostError(error)
            }
        }
        let cardId = try await MainActor.run { () throws -> String in
            guard let projectPath else {
                let names = store.state.configuredProjects.map(\.name).sorted().joined(separator: ", ")
                throw RemoteHostError.badRequest("unknown project \(request.project); known: \(names)")
            }
            let assistant: CodingAssistant
            if let raw = request.assistant {
                guard let parsed = CodingAssistant(rawValue: raw.lowercased()) else {
                    throw RemoteHostError.badRequest("unknown assistant \(raw); use claude, codex or gemini")
                }
                assistant = parsed
            } else {
                assistant = engine.platform.defaultAssistant()
            }
            let title = request.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let imagePaths = try RemotePromptImages.write(
                RemotePromptImages.decode(request.images), to: RemotePromptImages.taskDirectory, prefix: "remote")
            return engine.createRemoteTask(RemoteLaunchRequest(
                projectPath: projectPath,
                prompt: request.prompt,
                title: title?.isEmpty == false ? title : nil,
                worktree: request.worktree,
                assistant: assistant,
                model: request.model,
                launch: request.launch ?? true,
                imagePaths: imagePaths,
                machine: request.machine?.trimmingCharacters(in: .whitespacesAndNewlines),
                human: request.human == true
            ))
        }
        for _ in 0..<30 {
            if let card = try? await MainActor.run(body: { try remoteCard(cardId) }) { return card }
            try? await Task.sleep(for: .milliseconds(100))
        }
        throw RemoteHostError.notFound("card \(cardId) was created but is not on the board yet")
    }

    /// The card's live session and whether a turn runs in it.
    @MainActor
    private func liveSession(_ cardId: String) throws -> (session: String, busy: Bool) {
        let card = try card(cardId)
        guard let session = RemoteBoardMapper.liveAssistantSession(card.link, liveSessions: store.state.tmuxSessions) else {
            throw RemoteHostError.conflict("card \(cardId) has no live session; resume it first")
        }
        return (session, card.activityState == .activelyWorking)
    }

    /// Stops the running turn so a prompt can go out now.
    private func interruptForPrompt(session: String) async throws {
        try await sendEscape(session)
        // The composer takes input again once the turn has stopped.
        try? await Task.sleep(for: .milliseconds(600))
    }

    public func sendPrompt(cardId: String, _ request: RemotePromptRequest, images: [RemotePromptImages.Decoded]) async throws {
        if let owner = await ownerClient(cardId) {
            let encoded = images.map { RemoteImage(mediaType: Self.mediaType(ofExtension: $0.fileExtension), data: $0.bytes.base64EncodedString()) }
            return try await forwarded {
                try await owner.sendPrompt(cardId: cardId, text: request.text, mode: request.mode ?? .queue, images: encoded,
                                           human: request.human == true)
            }
        }
        let (session, busy) = try await MainActor.run { try liveSession(cardId) }
        let imagePaths = try RemotePromptImages.write(images, to: RemotePromptImages.promptDirectory)
        let mode = request.mode ?? .queue
        if let rushId = RushSessionName.rushId(fromName: session) {
            // rush queues a message sent mid-turn itself, and `now` hands it
            // to Claude mid-turn; the card's own queue is not used. rush
            // puts each image right after its [Image #N] marker.
            let human = request.human == true
            if human {
                let (sessionId, log) = await MainActor.run {
                    (store.state.links[cardId]?.sessionLink?.sessionId, engine.humanMessages)
                }
                log.append(cardId: cardId, HumanMessageRecord(text: request.text, sessionId: sessionId))
            }
            try await rushFor(session).send(id: rushId, text: request.text, imagePaths: imagePaths, now: mode == .now, human: human)
            await readRushQueue(session: session, rushId: rushId)
            return
        }
        if mode == .now && busy {
            try await interruptForPrompt(session: session)
        }
        await MainActor.run {
            let prompt = QueuedPrompt(body: request.text, sendAutomatically: true,
                                      imagePaths: imagePaths.isEmpty ? nil : imagePaths,
                                      humanWrittenAt: request.human == true ? .now : nil)
            store.dispatch(.addQueuedPrompt(cardId: cardId, prompt: prompt, placement: .back))
            // A queued prompt on a busy card goes out when the turn ends; the
            // rest goes out now, as the chat's send button does.
            if mode == .now || !busy {
                store.dispatch(.sendQueuedPrompt(cardId: cardId, promptId: prompt.id))
            }
        }
    }

    public func sendQueuedPromptNow(cardId: String, promptId: String) async throws {
        if let owner = await ownerClient(cardId) {
            return try await forwarded { try await owner.sendQueuedPromptNow(cardId: cardId, promptId: promptId) }
        }
        if RemoteBoardMapper.isRushPromptId(promptId) {
            try await rushQueueAction(cardId: cardId, promptId: promptId, send: true)
            return
        }
        let (session, busy) = try await MainActor.run { () throws -> (String, Bool) in
            try queuedPrompt(cardId, promptId)
            return try liveSession(cardId)
        }
        if busy { try await interruptForPrompt(session: session) }
        await MainActor.run {
            // Once the turn stops the queue may send it on its own.
            guard (try? queuedPrompt(cardId, promptId)) != nil else { return }
            store.dispatch(.sendQueuedPrompt(cardId: cardId, promptId: promptId))
        }
    }

    public func removeQueuedPrompt(cardId: String, promptId: String) async throws {
        if let owner = await ownerClient(cardId) {
            return try await forwarded { try await owner.removeQueuedPrompt(cardId: cardId, promptId: promptId) }
        }
        if RemoteBoardMapper.isRushPromptId(promptId) {
            try await rushQueueAction(cardId: cardId, promptId: promptId, send: false)
            return
        }
        try await MainActor.run {
            try queuedPrompt(cardId, promptId)
            store.dispatch(.removeQueuedPrompt(cardId: cardId, promptId: promptId))
        }
    }

    public func editQueuedPrompt(cardId: String, promptId: String, text: String) async throws {
        if let owner = await ownerClient(cardId) {
            return try await forwarded { try await owner.editQueuedPrompt(cardId: cardId, promptId: promptId, text: text) }
        }
        if RemoteBoardMapper.isRushPromptId(promptId) {
            // rush has no edit: the old message leaves the queue and the new
            // text joins it (a busy host queues what it is sent).
            try await rushQueueAction(cardId: cardId, promptId: promptId, send: false)
            let session = try await MainActor.run { try liveSession(cardId).session }
            guard let rushId = RushSessionName.rushId(fromName: session) else { return }
            try await rushFor(session).send(id: rushId, text: text)
            await readRushQueue(session: session, rushId: rushId)
            return
        }
        try await MainActor.run {
            let prompt = try queuedPrompt(cardId, promptId)
            store.dispatch(.updateQueuedPrompt(cardId: cardId, promptId: promptId, body: text,
                                               sendAutomatically: prompt.sendAutomatically))
        }
    }

    // MARK: Channels home

    public func runCLI(_ request: RemoteCLIRequest) async throws -> RemoteCLIResult {
        await engine.runCLI(request)
    }

    public func channelFiles() async throws -> [RemoteChannelFile] {
        let home = await MainActor.run { engine.platform.kanbanHome }
        return MasterEngine.listChannelFiles(home: home)
    }

    public func channelFile(path: String, offset: Int) async throws -> Data {
        let home = await MainActor.run { engine.platform.kanbanHome }
        return try MasterEngine.readChannelFile(home: home, relative: path, offset: offset)
    }

    public func seedChannelFile(path: String, data: Data) async throws -> Bool {
        let home = await MainActor.run { engine.platform.kanbanHome }
        let created = try MasterEngine.seedChannelFile(home: home, relative: path, data: data)
        if created { await MainActor.run { store.dispatch(.refreshChannels) } }
        return created
    }

    @MainActor
    @discardableResult
    private func queuedPrompt(_ cardId: String, _ promptId: String) throws -> QueuedPrompt {
        guard let prompt = try card(cardId).link.queuedPrompts?.first(where: { $0.id == promptId }) else {
            throw RemoteHostError.notFound("card \(cardId) has no queued prompt \(promptId); it may have been sent already")
        }
        return prompt
    }

    // MARK: rush queue

    /// Sends now, or drops, a message queued in the card's rush host.
    private func rushQueueAction(cardId: String, promptId: String, send: Bool) async throws {
        let (session, queue) = try await MainActor.run { () throws -> (String, [String]) in
            let (session, _) = try liveSession(cardId)
            return (session, store.state.rushQueues[session] ?? [])
        }
        guard let rushId = RushSessionName.rushId(fromName: session) else {
            throw RemoteHostError.notFound("card \(cardId) has no queued prompt \(promptId)")
        }
        // The queue as the phone saw it may be older than rush's.
        var current = queue
        if RemoteBoardMapper.rushQueueIndex(of: promptId, in: current) == nil,
           let info = try? await rushFor(session).info(id: rushId) {
            current = info.queue
        }
        guard let index = RemoteBoardMapper.rushQueueIndex(of: promptId, in: current) else {
            await readRushQueue(session: session, rushId: rushId)
            throw RemoteHostError.notFound("card \(cardId) has no queued prompt \(promptId); it may have been sent already")
        }
        do {
            if send {
                try await rushFor(session).sendQueued(id: rushId, index: index, was: current[index])
            } else {
                try await rushFor(session).removeQueued(id: rushId, index: index, was: current[index])
            }
        } catch let error as RushCommandFailed where error.message.contains("already been sent") {
            await readRushQueue(session: session, rushId: rushId)
            throw RemoteHostError.notFound("card \(cardId) has no queued prompt \(promptId); it was sent already")
        }
        await readRushQueue(session: session, rushId: rushId)
    }

    /// Reads one rush host's queue into the store, then keeps watching
    /// while any host has something queued.
    private func readRushQueue(session: String, rushId: String) async {
        guard let info = try? await rushFor(session).info(id: rushId) else { return }
        await MainActor.run { store.dispatch(.rushQueueRead(sessionName: session, queue: info.queue)) }
        await watchRushQueues()
    }

    /// While a rush host has messages queued, reads its queue every two
    /// seconds, so they leave the phone when rush sends them. The session
    /// scan also reads them, but only as often as the board reconciles.
    private func watchRushQueues() async {
        let queued = await MainActor.run { !store.state.rushQueues.isEmpty }
        guard queued, queueWatch.claim() else { return }
        Task { [weak self] in
            defer { self?.queueWatch.release() }
            while let self, !Task.isCancelled {
                let sessions = await MainActor.run { Array(self.store.state.rushQueues.keys) }
                if sessions.isEmpty { return }
                try? await Task.sleep(for: .seconds(2))
                for session in sessions {
                    guard let id = RushSessionName.rushId(fromName: session) else { continue }
                    let queue = (try? await self.rushFor(session).info(id: id))?.queue ?? []
                    await MainActor.run { self.store.dispatch(.rushQueueRead(sessionName: session, queue: queue)) }
                }
            }
        }
    }

    public func scrollTerminal(sessionName: String, lines: Int) async {
        guard !RushSessionName.isRush(sessionName) else { return }
        await runTmux(RemoteTerminalScroll.tmuxCommands(session: sessionName, lines: lines), sessionName)
    }

    public func attention() async -> [AttentionRequest] {
        await MainActor.run { store.state.openAttentionRequests }
    }

    public func resolveAttention(id: String, resolution: String, by: String, unsealed: VaultUnsealed?) async throws {
        try await engine.resolveAttention(id: id, resolution: resolution, by: by, unsealed: unsealed)
    }

    public func reportPresence(_ presence: MacPresence) async {
        await engine.attentionCenter?.reportPresence(presence)
    }

    // MARK: Side chat

    public func startSideChat(cardId: String, _ request: RemoteSideChatRequest) async throws -> RemoteSideChatRun {
        try await engine.startSideChat(cardId: cardId, request)
    }

    public func sideChatRun(cardId: String, runId: String) async throws -> RemoteSideChatRun {
        try await engine.sideChatRun(cardId: cardId, runId: runId)
    }

    public func cancelSideChat(cardId: String, runId: String) async throws {
        await engine.cancelSideChat(cardId: cardId, runId: runId)
    }

    public func slashCommands(cardId: String) async throws -> [RemoteSlashCommand] {
        try await engine.slashCommands(cardId: cardId)
    }

    public func interrupt(cardId: String) async throws {
        if let owner = await ownerClient(cardId) {
            return try await forwarded { try await owner.interrupt(cardId: cardId) }
        }
        let session = try await MainActor.run { () throws -> String in
            let card = try card(cardId)
            guard let session = RemoteBoardMapper.liveAssistantSession(card.link, liveSessions: store.state.tmuxSessions) else {
                throw RemoteHostError.conflict("card \(cardId) has no live session")
            }
            return session
        }
        try await sendEscape(session)
    }

    public func resume(cardId: String) async throws -> RemoteCard {
        if let owner = await ownerClient(cardId) {
            return try await forwarded { try await owner.resume(cardId: cardId) }
        }
        let (current, running, rushSession) = try await MainActor.run { () throws -> (RemoteCard, Bool, String?) in
            if let moving = engine.stillMovingHere(cardId) { throw RemoteHostError.conflict(moving) }
            // A session this master just started is not in the last tmux
            // scan yet: a second resume would start it over.
            let card = try card(cardId)
            let running: Bool = switch card.sessionStatus {
            case .live, .starting: true
            default: false
            }
            // A rush card reads as live while its host rests between turns
            // or until the next scan sees it stopped; rush says whether the
            // host runs.
            var rushSession: String?
            if case .live = card.sessionStatus, let name = card.link.tmuxLink?.sessionName, RushSessionName.isRush(name) {
                rushSession = name
            }
            return (try remoteCard(cardId), running, rushSession)
        }
        if let alive = await rushHostAlive(rushSession) {
            if alive { return current }
        } else if current.isLive || running {
            return current
        }
        await MainActor.run { engine.resumeRemoteCard(cardId) }
        // The caller may be another master or a phone that shows nothing of
        // this board: a start that fails is its answer, not a line in a log
        // here. A start still running after the wait answers with the card.
        let deadline = Date().addingTimeInterval(resumeOutcomeWait)
        repeat {
            try? await Task.sleep(for: .milliseconds(200))
            let (failure, launching) = await MainActor.run {
                (store.state.startFailure(cardId), store.state.links[cardId]?.isLaunching == true)
            }
            if let failure { throw RemoteHostError.conflict(failure) }
            if !launching { break }
        } while Date() < deadline
        return try await MainActor.run { try remoteCard(cardId) }
    }

    /// Whether the host of rush session `name` runs, false for a host rush
    /// does not know; nil when there is no such session or rush could not
    /// be asked.
    private func rushHostAlive(_ name: String?) async -> Bool? {
        guard let name, let id = RushSessionName.rushId(fromName: name),
              let rush = try? rushFor(name) else { return nil }
        do {
            return try await rush.info(id: id)?.alive ?? false
        } catch {
            return nil
        }
    }

    public func terminalCommand(cardId: String, sessionName: String) async throws -> [String] {
        try await MainActor.run { () throws -> [String] in
            let card = try card(cardId)
            if let owner = card.link.ownerMachine, owner != store.state.localMachineId, !store.state.localMachineId.isEmpty {
                if let command = engine.platform.peerTerminalCommand(owner, cardId, sessionName) { return command }
                throw RemoteHostError.conflict("card \(cardId) runs on \(engine.peerName(owner)); open its terminal there")
            }
            let names = card.link.tmuxLink?.allSessionNames ?? []
            guard names.contains(sessionName) else {
                throw RemoteHostError.notFound("card \(cardId) has no terminal \(sessionName)")
            }
            guard store.state.tmuxSessions.contains(sessionName) || engine.platform.machineForSession(sessionName) != nil else {
                throw RemoteHostError.conflict("terminal \(sessionName) is not running; resume the card first")
            }
            return engine.platform.terminalCommand(sessionName) ?? Self.localCommand(forSession: sessionName)
        }
    }

    // MARK: Moves and handovers

    public func rawTranscript(cardId: String, offset: Int, limit: Int) async throws -> RemoteRawTranscript {
        try await MainActor.run {
            do {
                return try engine.rawTranscript(cardId: cardId, offset: offset, limit: limit)
            } catch let error as MasterPeerError {
                throw Self.hostError(error)
            }
        }
    }

    public func handoverInfo(cardId: String) async throws -> RemoteHandoverInfo {
        do {
            return try await engine.handoverInfo(cardId: cardId)
        } catch let error as MasterPeerError {
            throw Self.hostError(error)
        }
    }

    public func updateCard(cardId: String, _ update: RemoteCardUpdate) async throws -> RemoteCard {
        try await MainActor.run { () throws -> RemoteCard in
            if update.pinned != nil, try card(cardId).link.parentCardId != nil {
                throw RemoteHostError.conflict("card \(cardId) is a subagent; pin its parent")
            }
            if let name = update.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                store.dispatch(.renameCard(cardId: cardId, name: name))
            }
            if let column = update.column, let target = KanbanCodeColumn(rawValue: column.rawValue) {
                store.dispatch(.moveCard(cardId: cardId, to: target))
            }
            switch update.archived {
            case true?: store.dispatch(.archiveCard(cardId: cardId))
            case false?: store.dispatch(.unarchiveCard(cardId: cardId))
            case nil: break
            }
            if let pinned = update.pinned {
                store.dispatch(.setCardPinned(cardId: cardId, isPinned: pinned))
            }
            return try remoteCard(cardId)
        }
    }

    /// Deletes an archived card the way the Mac's Delete Card does: with its
    /// subagents, its sessions and its conversation file. A card on the
    /// board is archived first, as on the Mac.
    public func deleteCard(cardId: String) async throws {
        try await MainActor.run { () throws -> Void in
            let link = try card(cardId).link
            guard link.manuallyArchived else {
                throw RemoteHostError.conflict("card \(cardId) is on the board; archive it before deleting it")
            }
            guard link.source != .githubIssue else {
                throw RemoteHostError.conflict("card \(cardId) is a GitHub issue; it stays archived")
            }
            store.dispatch(.deleteCard(cardId: cardId))
        }
    }

    public func removeWorktree(cardId: String) async throws -> RemoteWorktreeRemoval {
        _ = try await MainActor.run { try card(cardId) }
        do {
            return try await engine.removeCardWorktree(cardId: cardId)
        } catch let error as WorktreeRemovalError {
            throw RemoteHostError.conflict(error.message)
        }
    }

    public func storePastedImage(cardId: String, image: Data) async throws -> RemotePastedImage {
        if let owner = await ownerClient(cardId) {
            return try await forwarded { try await owner.uploadPastedImage(cardId: cardId, data: image) }
        }
        let home = try await MainActor.run {
            _ = try card(cardId)
            return engine.platform.kanbanHome
        }
        return RemotePastedImage(path: try PastedImages.store(image, kanbanHome: home))
    }

    public func discoverBranches(cardId: String) async throws {
        if let owner = await ownerClient(cardId) {
            return try await forwarded { try await owner.discoverBranches(cardId: cardId) }
        }
        _ = try await MainActor.run { try card(cardId) }
        await engine.discoverBranches(cardId: cardId)
    }

    public func moveCard(cardId: String, to target: String) async throws -> RemoteCard {
        do {
            try await engine.moveCard(cardId, to: target)
        } catch let error as MasterPeerError {
            throw Self.hostError(error)
        } catch let error as RemoteClientError {
            throw Self.hostError(error)
        }
        try? await Task.sleep(for: .milliseconds(200))
        return try await MainActor.run { try remoteCard(cardId) }
    }

    // MARK: Cards another master owns

    /// The owner's client when another master owns the card: calls about
    /// the card go there.
    private func ownerClient(_ cardId: String) async -> RemoteClient? {
        await engine.ownerClient(forCard: cardId)
    }

    /// A client of the peer master `machine` names, when it names one.
    private func peerTaskClient(_ machine: String?) async -> RemoteClient? {
        guard let machine = machine?.trimmingCharacters(in: .whitespacesAndNewlines), !machine.isEmpty else { return nil }
        let peer = await MainActor.run { engine.isLocalMachine(machine) ? nil : engine.peerMachine(named: machine) }
        guard let peer else { return nil }
        return await engine.peerClient(machineId: peer.id)
    }

    /// Runs a call on the owner, turning its answer into this server's.
    private func forwarded<T>(_ call: () async throws -> T) async throws -> T {
        do {
            return try await call()
        } catch let error as RemoteClientError {
            throw Self.hostError(error)
        }
    }

    static func hostError(_ error: RemoteClientError) -> RemoteHostError {
        switch error {
        case .notFound(let m): .notFound(m)
        case .conflict(let m): .conflict(m)
        default: .conflict("the owning master answered: \(error.localizedDescription)")
        }
    }

    static func hostError(_ error: MasterPeerError) -> RemoteHostError {
        switch error {
        case .unknownCard, .unknownPeer: .notFound(error.localizedDescription)
        case .noProject: .badRequest(error.localizedDescription)
        default: .conflict(error.localizedDescription)
        }
    }

    /// `git@host:owner/repo(.git)` or `https://host/owner/repo(.git)`.
    static func isRepositoryURL(_ value: String) -> Bool {
        let v = value.trimmingCharacters(in: .whitespaces)
        return v.hasPrefix("git@") || v.hasPrefix("ssh://") || ((v.hasPrefix("https://") || v.hasPrefix("http://")) && v.contains("/"))
    }

    static func mediaType(ofExtension ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        default: "image/png"
        }
    }

    /// The command a viewer runs for a session of this master: rush's own
    /// UI for rush, a tmux attach otherwise.
    public static func localCommand(forSession sessionName: String) -> [String] {
        if let rushId = RushSessionName.rushId(fromName: sessionName) {
            return RushCliAdapter.openCommand(id: rushId)
        }
        return [ShellCommand.findExecutable("tmux") ?? "tmux", "attach-session", "-t", sessionName]
    }

    public func boardChanges() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let store = self.store
        let alive = BoardChangeFlag()
        continuation.onTermination = { _ in alive.stop() }
        Task { @MainActor in
            Self.observe(store: store, continuation: continuation, alive: alive)
        }
        return stream
    }

    /// Yields once per change of the cards, the live sessions or the
    /// projects, re-arming the observation each time.
    @MainActor
    private static func observe(store: BoardStore, continuation: AsyncStream<Void>.Continuation, alive: BoardChangeFlag) {
        guard alive.isAlive else { return }
        withObservationTracking {
            _ = store.state.cards
            _ = store.state.tmuxSessions
            _ = store.state.rushQueues
            _ = store.state.configuredProjects
            _ = store.state.peerStatuses
            _ = store.state.attentionRequests
        } onChange: {
            continuation.yield()
            Task { @MainActor in observe(store: store, continuation: continuation, alive: alive) }
        }
    }
}

private final class BoardChangeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var alive = true

    var isAlive: Bool { lock.withLock { alive } }
    func stop() { lock.withLock { alive = false } }
}

/// One rush queue watcher at a time.
private final class QueueWatchFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false

    /// True when the caller should start the watcher.
    func claim() -> Bool {
        lock.withLock {
            if running { return false }
            running = true
            return true
        }
    }

    func release() { lock.withLock { running = false } }
}
