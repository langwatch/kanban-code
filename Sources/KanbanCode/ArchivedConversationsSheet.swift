import SwiftUI
import KanbanCodeCore
import KanbanCodeRemoteKit

extension Notification.Name {
    /// Shows the archived conversations: userInfo["cardId"] for one card's,
    /// none for every card's.
    static let kanbanCodeShowArchivedConversations = Notification.Name("kanbanCodeShowArchivedConversations")
}

/// Presents the archived conversations sheet the card menu or the View
/// menu asks for.
struct ArchivedConversationsPresenter: ViewModifier {
    let store: BoardStore
    @State private var target: ArchivedConversationsTarget?

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .kanbanCodeShowArchivedConversations).receive(on: RunLoop.main)) { note in
                target = ArchivedConversationsTarget(cardId: note.userInfo?["cardId"] as? String)
            }
            .sheet(item: $target) { target in
                ArchivedConversationsSheet(
                    groups: store.state.archivedConversationGroups(cardId: target.cardId),
                    singleCard: target.cardId != nil,
                    onOpen: { cardId, id in
                        self.target = nil
                        KanbanCodeLog.info("conversations", "card \(cardId.prefix(12)): opened archived \(id)")
                        ConversationActions.open(cardId: cardId, conversationId: id)
                    },
                    onUnarchive: { cardId, id in
                        KanbanCodeLog.info("conversations", "card \(cardId.prefix(12)): unarchived \(id)")
                        ConversationActions.update(cardId: cardId, conversationId: id, .init(archived: false))
                    },
                    onClose: { self.target = nil }
                )
            }
    }
}

private struct ArchivedConversationsTarget: Identifiable {
    let cardId: String?
    var id: String { cardId ?? "all" }
}

/// Archived conversations grouped by card, each to open or unarchive.
struct ArchivedConversationsSheet: View {
    let groups: [ArchivedConversationGroup]
    /// Lists one card's: its title heads the sheet instead of each group.
    let singleCard: Bool
    let onOpen: (_ cardId: String, _ conversationId: String) -> Void
    let onUnarchive: (_ cardId: String, _ conversationId: String) -> Void
    let onClose: () -> Void

    private var title: String {
        if singleCard, let group = groups.first { return "Archived conversations of \(group.cardTitle)" }
        return "Archived conversations"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "archivebox")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
            }

            if groups.isEmpty {
                Text("No archived conversations.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(groups) { group in
                            VStack(alignment: .leading, spacing: 6) {
                                if !singleCard {
                                    Text(group.cardTitle)
                                        .font(.app(.caption, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .textCase(.uppercase)
                                        .lineLimit(1)
                                }
                                ForEach(group.conversations) { conversation in
                                    row(conversation, cardId: group.cardId)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 440)
            }

            HStack {
                Spacer()
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func row(_ conversation: RemoteConversation, cardId: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "bubble.left")
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.displayTitle)
                    .font(.app(.body, weight: .medium))
                    .lineLimit(1)
                Text(subtitle(conversation))
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Unarchive") { onUnarchive(cardId, conversation.id) }
                .accessibilityIdentifier("unarchive-conversation-\(conversation.id)")
            Button("Open") { onOpen(cardId, conversation.id) }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("open-archived-conversation-\(conversation.id)")
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    private func subtitle(_ conversation: RemoteConversation) -> String {
        let count = "\(conversation.messageCount) message\(conversation.messageCount == 1 ? "" : "s")"
        let age = SearchRelativeTime.text(since: conversation.updatedAt)
        if let preview = conversation.preview, !preview.isEmpty { return "\(age) · \(preview)" }
        return "\(age) · \(count)"
    }
}
