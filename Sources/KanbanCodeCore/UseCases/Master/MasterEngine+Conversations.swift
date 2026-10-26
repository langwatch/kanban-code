import Foundation
import KanbanCodeRemoteKit

// MARK: - Conversations (docs/conversations.md)

extension MasterEngine {
    /// The card's conversations, most recent first. A card another master
    /// owns is asked there.
    public func conversations(cardId: String) async throws -> [RemoteConversation] {
        if let owner = await ownerClient(forCard: cardId) {
            return try await Self.forwardedConversation { try await owner.conversations(cardId: cardId) }
        }
        try requireCard(cardId)
        return conversationStore.threads(cardId: cardId).map(\.summary)
    }

    /// Starts a conversation on the card: an id of two words, no title yet
    /// unless one is given, and the agent message it continues from.
    public func createConversation(cardId: String, _ request: RemoteConversationCreate,
                                   by: String = "human") async throws -> RemoteConversation {
        if let owner = await ownerClient(forCard: cardId) {
            let created = try await Self.forwardedConversation { try await owner.createConversation(cardId: cardId, request) }
            await mirrorConversations(cardId: cardId)
            return created
        }
        try requireCard(cardId)
        let existing = Set(conversationStore.threads(cardId: cardId).map(\.summary.id))
        let id = ConversationSlug.generate(existing: existing)
        let title = request.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let quote = request.quote?.trimmingCharacters(in: .whitespacesAndNewlines)
        try appendConversation(cardId: cardId, [.created(id, title: title?.isEmpty == false ? title : nil,
                                                         quote: quote?.isEmpty == false ? quote : nil, by: by)])
        guard let created = store.state.conversations[cardId]?.first(where: { $0.id == id }) else {
            throw RemoteHostError.conflict("the conversation was not written")
        }
        KanbanCodeLog.info("conversations", "card \(cardId.prefix(12)): started \(id)")
        return created
    }

    /// The conversation with its messages.
    public func conversation(cardId: String, id: String) async throws -> RemoteConversationDetail {
        if let owner = await ownerClient(forCard: cardId) {
            return try await Self.forwardedConversation { try await owner.conversation(cardId: cardId, id: id) }
        }
        try requireCard(cardId)
        guard let thread = conversationStore.threads(cardId: cardId).first(where: { $0.summary.id == id }) else {
            throw RemoteHostError.notFound("no conversation \(id) on card \(cardId)")
        }
        return thread.detail
    }

    /// Renames, marks read or archives a conversation.
    public func updateConversation(cardId: String, id: String, _ update: RemoteConversationUpdate) async throws -> RemoteConversation {
        if let owner = await ownerClient(forCard: cardId) {
            let updated = try await Self.forwardedConversation {
                try await owner.updateConversation(cardId: cardId, id: id, update)
            }
            await mirrorConversations(cardId: cardId)
            return updated
        }
        try requireCard(cardId)
        guard let current = conversationStore.threads(cardId: cardId).first(where: { $0.summary.id == id })?.summary else {
            throw RemoteHostError.notFound("no conversation \(id) on card \(cardId)")
        }
        var events: [ConversationEvent] = []
        if let title = update.title?.trimmingCharacters(in: .whitespacesAndNewlines), title != (current.title ?? "") {
            events.append(.title(id, title, by: "human"))
        }
        if update.read == true, current.unread { events.append(.read(id)) }
        if let archived = update.archived, archived != current.archived { events.append(.archived(id, archived)) }
        if !events.isEmpty { try appendConversation(cardId: cardId, events) }
        return store.state.conversations[cardId]?.first { $0.id == id } ?? current
    }

    /// The card's own log from `offset`, for a master that mirrors it.
    public func rawConversations(cardId: String, offset: Int) throws -> RemoteRawTranscript {
        conversationStore.raw(cardId: cardId, offset: offset)
    }

    /// Writes events to the log of a card this master owns and loads the
    /// result into the board at once.
    func appendConversation(cardId: String, _ events: [ConversationEvent]) throws {
        try conversationStore.append(cardId: cardId, events)
        reloadConversations(cardId: cardId)
    }

    /// Reads the card's log again, its own or the copy of its owner's.
    public func reloadConversations(cardId: String) {
        let owner = isForeign(cardId) ? store.state.links[cardId]?.ownerMachine : nil
        let summaries = conversationStore.threads(cardId: cardId, ownerMachine: owner).map(\.summary)
        store.dispatch(.conversationsLoaded(cardId: cardId, conversations: summaries))
    }

    /// Reloads every log that changed since the last pass: the CLI appends
    /// the agent's replies from the session, and the mirror copies the
    /// logs of other masters' cards.
    public func runConversationWatcher(interval: Duration = .seconds(1)) async {
        var seen: [String: ConversationLogFile] = [:]
        let conversationStore = conversationStore
        while !Task.isCancelled {
            let files = await Task.detached { conversationStore.scan() }.value
            var changed: Set<String> = []
            // A log whose card is not on the board yet (links still loading
            // at launch) stays unseen, so it loads once the card shows up.
            for file in files where seen[file.path] != file && store.state.links[file.cardId] != nil {
                seen[file.path] = file
                changed.insert(file.cardId)
            }
            for cardId in changed {
                reloadConversations(cardId: cardId)
            }
            try? await Task.sleep(for: interval)
        }
    }

    /// Copies what the owner appended to the log of a card another master
    /// owns since the last copy.
    public func mirrorConversations(cardId: String) async {
        guard let owner = store.state.links[cardId]?.ownerMachine, isForeign(cardId),
              let client = await peerClient(machineId: owner) else { return }
        let path = conversationStore.mirrorPath(cardId: cardId, machineId: owner)
        let fm = FileManager.default
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var size = ((try? fm.attributesOfItem(atPath: path))?[.size] as? Int) ?? 0
        var restarted = false
        var wrote = false
        for _ in 0..<8 {
            guard let slice = try? await client.rawConversations(cardId: cardId, offset: size) else { return }
            if slice.size < size, !restarted {
                try? fm.removeItem(atPath: path)
                size = 0
                restarted = true
                continue
            }
            if slice.data.isEmpty { break }
            Self.appendBytes(slice.data, to: path)
            wrote = true
            size += slice.data.count
            if size >= slice.size { break }
        }
        if wrote || restarted { reloadConversations(cardId: cardId) }
    }

    private nonisolated static func appendBytes(_ data: Data, to path: String) {
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: data)
            return
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    private func requireCard(_ cardId: String) throws {
        guard store.state.links[cardId] != nil else { throw RemoteHostError.notFound("no card \(cardId)") }
    }

    private nonisolated static func forwardedConversation<T: Sendable>(_ call: @Sendable () async throws -> T) async throws -> T {
        do {
            return try await call()
        } catch let error as RemoteClientError {
            throw MasterRemoteControlHost.hostError(error)
        }
    }
}
