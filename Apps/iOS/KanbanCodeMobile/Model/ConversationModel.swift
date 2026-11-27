import Foundation
import Observation
import KanbanCodeRemoteKit

/// A conversation of a card and where to find it.
struct ConversationRoute: Hashable, Identifiable {
    let cardId: String
    let id: String
    /// Opens with the keyboard up, to write the first message.
    var focusesComposer = false
}

/// The read holds of every conversation on this device, shared by the
/// sidebar rows and the open conversation screen (separate models).
enum ConversationReadHoldStore {
    static var holds = ConversationReadHolds()

    /// The human selected the conversation: the open view marks it read
    /// again, also when it was already the one shown.
    static func opened(board: BoardModel, cardId: String, id: String) {
        holds.opened(.init(server: board.server.id.uuidString, cardId: cardId, conversation: id))
    }
}

/// One conversation of a card (docs/conversations.md): its messages as the
/// master that owns the card keeps them, plus the ones sent from here that
/// it does not list yet.
@Observable
final class ConversationModel {
    let cardId: String
    let id: String
    let board: BoardModel
    private(set) var conversation: RemoteConversation?
    /// Oldest first, as the master lists them.
    private(set) var messages: [RemoteConversationMessage] = []
    /// Sent from here, until the master lists them.
    private(set) var pending: [RemoteConversationMessage] = []
    /// The images of each pending message, as attached here: the master's
    /// copies are paths the phone cannot read.
    private(set) var pendingImages: [String: [Data]] = [:]
    private(set) var error: String?
    private(set) var loadedOnce = false
    @ObservationIgnored private var isLoading = false

    init(cardId: String, id: String, board: BoardModel) {
        self.cardId = cardId
        self.id = id
        self.board = board
        conversation = board.card(id: cardId)?.conversations.first { $0.id == id }
    }

    /// A conversation with no connection, for previews.
    init(preview detail: RemoteConversationDetail, cardId: String, board: BoardModel) {
        self.cardId = cardId
        id = detail.conversation.id
        self.board = board
        conversation = detail.conversation
        messages = detail.messages
        loadedOnce = true
    }

    var client: RemoteClient? { board.client }

    var title: String { conversation?.displayTitle ?? "Conversation" }

    /// What the conversation shows: the master's messages, then the sent ones.
    var shown: [RemoteConversationMessage] { messages + pending }

    /// The card's session works on a message the human sent here.
    func isWorking(cardBusy: Bool) -> Bool {
        cardBusy && shown.last?.role == .human
    }

    func refresh() async {
        guard let client, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            // Unstructured, so a view that goes away mid-load does not
            // cancel it (see TranscriptModel.refresh).
            let (cardId, id) = (cardId, id)
            let detail = try await Task { try await client.conversation(cardId: cardId, id: id) }.value
            conversation = detail.conversation
            messages = detail.messages
            pending.removeAll { sent in Self.lists(detail.messages, sent: sent) }
            pendingImages = pendingImages.filter { id, _ in pending.contains { $0.id == id } }
            error = nil
            loadedOnce = true
            // Open on screen: what the agent wrote is read, unless the
            // human marked it unread while it stayed open.
            if ConversationReadHoldStore.holds.shouldMarkRead(holdKey, unread: detail.conversation.unread) {
                await markRead()
            }
        } catch where TranscriptModel.isCancellation(error) {
            // The view that asked went away; the one that replaces it loads again.
            return
        } catch {
            if messages.isEmpty { self.error = error.localizedDescription }
            loadedOnce = true
        }
    }

    /// Marks it read on the master, which clears it on every device; the
    /// board here shows it at once.
    func markRead() async {
        try? await setRead()
    }

    /// The bytes of a sent message's image, from the master that keeps it.
    func image(messageId: String, index: Int) async throws -> Data {
        guard let client else { throw URLError(.notConnectedToInternet) }
        let (cardId, id) = (cardId, id)
        return try await RemoteImageCache.data("conversation|\(cardId)|\(id)|\(messageId)|\(index)") {
            try await client.conversationImage(cardId: cardId, id: id, messageId: messageId, index: index)
        }
    }

    func rename(_ title: String) async throws {
        guard let client else { return }
        apply(try await client.updateConversation(cardId: cardId, id: id, RemoteConversationUpdate(title: title)))
    }

    /// Marks it unread on the master until it is opened again or sent in;
    /// an open view of it leaves it unread meanwhile.
    func markUnread() async throws {
        guard let client else { return }
        ConversationReadHoldStore.holds.markedUnread(holdKey)
        do {
            apply(try await client.updateConversation(cardId: cardId, id: id, RemoteConversationUpdate(read: false)))
        } catch {
            ConversationReadHoldStore.holds.released(holdKey)
            throw error
        }
    }

    /// As `markRead`, reporting a failure.
    func setRead() async throws {
        guard let client else { return }
        ConversationReadHoldStore.holds.released(holdKey)
        apply(try await client.updateConversation(cardId: cardId, id: id, RemoteConversationUpdate(read: true)))
    }

    /// Where the human marks it unread from (its row, its own menu) and the
    /// open view of it share this key.
    var holdKey: ConversationReadHolds.Key {
        .init(server: board.server.id.uuidString, cardId: cardId, conversation: id)
    }

    /// Shown anew: the open view marks it read again.
    func opened() {
        ConversationReadHoldStore.holds.opened(holdKey)
    }

    /// The human sent in it: the open view marks it read again.
    func interacted() {
        ConversationReadHoldStore.holds.interacted(holdKey)
    }

    func archive() async throws {
        try await setArchived(true)
    }

    func setArchived(_ archived: Bool) async throws {
        guard let client else { return }
        apply(try await client.updateConversation(cardId: cardId, id: id, RemoteConversationUpdate(archived: archived)))
    }

    /// Shows a message the master took before it lists it, faded. Returns its id.
    /// `sentId` is the id it was sent under, the one the master logs it by.
    @discardableResult
    func appendPending(_ text: String, images: [Data] = [], id sentId: String? = nil) -> String {
        let id = Self.pendingPrefix + (sentId ?? UUID().uuidString)
        pending.removeAll { $0.id == id }
        pending.append(RemoteConversationMessage(id: id, role: .human, text: text, at: .now))
        if !images.isEmpty { pendingImages[id] = images }
        return id
    }

    /// What a pending message's id starts with, before the id it was sent under.
    static let pendingPrefix = "pending-"

    /// The master lists a message the human sent from here: under the id
    /// it was sent with, or, from a master that logs its own ids, the same
    /// text written no earlier than a minute before it was sent (clocks
    /// differ).
    static func lists(_ messages: [RemoteConversationMessage], sent: RemoteConversationMessage) -> Bool {
        if sent.id.hasPrefix(pendingPrefix) {
            let sentId = String(sent.id.dropFirst(pendingPrefix.count))
            if messages.contains(where: { $0.id == sentId }) { return true }
        }
        let text = sent.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return messages.contains { message in
            message.role == .human && message.text.trimmingCharacters(in: .whitespacesAndNewlines) == text
                && message.at >= sent.at.addingTimeInterval(-60)
        }
    }

    /// The new summary, here and on the card the board shows.
    private func apply(_ updated: RemoteConversation) {
        let wasArchived = conversation?.archived
        conversation = updated
        Self.applyArchive(updated, cardId: cardId, board: board, wasArchived: wasArchived)
    }

    /// The card the board shows after `updated` changed: an archived one
    /// leaves its open conversations and adds to its archived count, an
    /// unarchived one comes back. `wasArchived` nil means unknown, read
    /// from what the card lists.
    static func applyArchive(_ updated: RemoteConversation, cardId: String, board: BoardModel, wasArchived: Bool? = nil) {
        guard var card = board.card(id: cardId) else { return }
        let listed = card.conversations.firstIndex { $0.id == updated.id }
        let before = wasArchived ?? (listed == nil)
        if updated.archived {
            card.conversations.removeAll { $0.id == updated.id }
            if !before { card.archivedConversationCount += 1 }
        } else if let listed {
            card.conversations[listed] = updated
        } else {
            card.conversations.append(updated)
            card.conversations.sort { $0.updatedAt > $1.updatedAt }
            if before { card.archivedConversationCount = max(0, card.archivedConversationCount - 1) }
        }
        board.upsert(card)
    }
}
