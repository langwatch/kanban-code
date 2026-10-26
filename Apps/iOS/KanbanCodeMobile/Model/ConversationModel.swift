import Foundation
import Observation
import KanbanCodeRemoteKit

/// A conversation of a card and where to find it.
struct ConversationRoute: Hashable, Identifiable {
    let cardId: String
    let id: String
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
            let detail = try await client.conversation(cardId: cardId, id: id)
            conversation = detail.conversation
            messages = detail.messages
            pending.removeAll { sent in Self.lists(detail.messages, sent: sent) }
            pendingImages = pendingImages.filter { id, _ in pending.contains { $0.id == id } }
            error = nil
            loadedOnce = true
            // Open on screen: what the agent wrote is read.
            if detail.conversation.unread { await markRead() }
        } catch {
            if messages.isEmpty { self.error = error.localizedDescription }
            loadedOnce = true
        }
    }

    /// Marks it read on the master, which clears it on every device; the
    /// board here shows it at once.
    func markRead() async {
        guard let client, let updated = try? await client.updateConversation(
            cardId: cardId, id: id, RemoteConversationUpdate(read: true)) else { return }
        apply(updated)
    }

    func rename(_ title: String) async throws {
        guard let client else { return }
        apply(try await client.updateConversation(cardId: cardId, id: id, RemoteConversationUpdate(title: title)))
    }

    func archive() async throws {
        guard let client else { return }
        apply(try await client.updateConversation(cardId: cardId, id: id, RemoteConversationUpdate(archived: true)))
    }

    /// Shows a message the master took before it lists it, faded. Returns its id.
    @discardableResult
    func appendPending(_ text: String, images: [Data] = []) -> String {
        let id = "pending-\(UUID().uuidString)"
        pending.append(RemoteConversationMessage(id: id, role: .human, text: text, at: .now))
        if !images.isEmpty { pendingImages[id] = images }
        return id
    }

    /// The master lists a message the human sent from here: the same text,
    /// written no earlier than a minute before it was sent (clocks differ).
    static func lists(_ messages: [RemoteConversationMessage], sent: RemoteConversationMessage) -> Bool {
        let text = sent.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return messages.contains { message in
            message.role == .human && message.text.trimmingCharacters(in: .whitespacesAndNewlines) == text
                && message.at >= sent.at.addingTimeInterval(-60)
        }
    }

    /// The new summary, here and on the card the board shows.
    private func apply(_ updated: RemoteConversation) {
        conversation = updated
        guard var card = board.card(id: cardId) else { return }
        if updated.archived {
            card.conversations.removeAll { $0.id == updated.id }
        } else if let index = card.conversations.firstIndex(where: { $0.id == updated.id }) {
            card.conversations[index] = updated
        } else {
            return
        }
        board.upsert(card)
    }
}
