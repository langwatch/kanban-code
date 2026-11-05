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
    /// unless one is given, and the message it continues from.
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
        let reply = request.quoteReply?.trimmingCharacters(in: .whitespacesAndNewlines)
        try appendConversation(cardId: cardId, [.created(id, title: title?.isEmpty == false ? title : nil,
                                                         quote: quote?.isEmpty == false ? quote : nil, by: by,
                                                         quoteRole: request.quoteRole, quoteReply: reply)])
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

    /// Image `index` of a human message, from the path the log keeps for it
    /// on this master. Only paths the log names are read.
    public func conversationImage(cardId: String, id: String, messageId: String, index: Int) async throws -> Data {
        if let owner = await ownerClient(forCard: cardId) {
            return try await Self.forwardedConversation {
                try await owner.conversationImage(cardId: cardId, id: id, messageId: messageId, index: index)
            }
        }
        try requireCard(cardId)
        guard let thread = conversationStore.threads(cardId: cardId).first(where: { $0.summary.id == id }) else {
            throw RemoteHostError.notFound("no conversation \(id) on card \(cardId)")
        }
        guard let message = thread.messages.first(where: { $0.id == messageId }),
              let images = message.images, images.indices.contains(index),
              case let path = images[index],
              let data = FileManager.default.contents(atPath: path) else {
            throw RemoteHostError.notFound("no image \(index + 1) on message \(messageId)")
        }
        return data
    }

    /// Renames, marks read or unread, or archives a conversation.
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
        if update.read == false, !current.unread { events.append(.unread(id)) }
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
    /// The store reads only what was appended since its last fold, so this
    /// is cheap right after a write of this master's.
    public func reloadConversations(cardId: String) {
        let owner = isForeign(cardId) ? store.state.links[cardId]?.ownerMachine : nil
        applyConversations(cardId: cardId, threads: conversationStore.threads(cardId: cardId, ownerMachine: owner))
    }

    /// Reads the card's log again off the main actor: a log first read, or
    /// one another master appended to, can take a long fold.
    public func reloadConversationsInBackground(cardId: String) async {
        let owner = isForeign(cardId) ? store.state.links[cardId]?.ownerMachine : nil
        let conversationStore = conversationStore
        let threads = await Task.detached(priority: .utility) {
            conversationStore.threads(cardId: cardId, ownerMachine: owner)
        }.value
        applyConversations(cardId: cardId, threads: threads)
    }

    private func applyConversations(cardId: String, threads: [ConversationThread]) {
        store.dispatch(.conversationsLoaded(cardId: cardId, conversations: threads.map(\.summary)))
        settleSentMessages(cardId: cardId, threads: threads)
    }

    /// Takes the messages sent from here that the log now shows out of the
    /// outbox, and out of the failed ones: a send whose answer was lost
    /// landed after all.
    func settleSentMessages(cardId: String, threads: [ConversationThread]) {
        let sent = (store.state.conversationOutbox[cardId] ?? [])
            + (store.state.failedPrompts[cardId] ?? []).map(\.prompt).filter { $0.conversation != nil }
        guard !sent.isEmpty else { return }
        var delivered: [String] = []
        for thread in threads {
            delivered += ConversationOutbox.delivered(sent.filter { $0.conversation == thread.summary.id }, in: thread.messages)
        }
        if !delivered.isEmpty {
            store.dispatch(.conversationMessagesDelivered(cardId: cardId, promptIds: delivered))
        }
    }

    /// Shows as failed, with Retry, each sent message the log has not shown
    /// in `ConversationOutbox.unconfirmedAfter`, instead of a spinner that
    /// never ends. Retry sends it under the same id, so the owner does not
    /// take it twice if it landed.
    public func failUnconfirmedMessages(now: Date = .now) {
        let state = store.state
        for (cardId, outbox) in state.conversationOutbox {
            for prompt in ConversationOutbox.unconfirmed(outbox, sending: conversationSends,
                                                         sentAt: state.conversationSentAt, now: now) {
                let owner = isForeign(cardId) ? peerName(state.links[cardId]?.ownerMachine ?? "") : nil
                let message = owner.map { "\($0) did not confirm it" } ?? "the conversation did not record it"
                KanbanCodeLog.warn("conversations", "card \(cardId.prefix(12)): message \(prompt.id) unconfirmed: \(message)")
                store.dispatch(.promptSendFailed(cardId: cardId, prompt: prompt, message: message))
            }
        }
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
                await reloadConversationsInBackground(cardId: cardId)
            }
            failUnconfirmedMessages()
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
            let data = slice.data
            await Task.detached(priority: .utility) { Self.appendBytes(data, to: path) }.value
            wrote = true
            size += slice.data.count
            if size >= slice.size { break }
        }
        if wrote || restarted { await reloadConversationsInBackground(cardId: cardId) }
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
