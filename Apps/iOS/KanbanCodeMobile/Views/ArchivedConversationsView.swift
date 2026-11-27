import SwiftUI
import UIKit
import KanbanCodeRemoteKit

/// Archived conversations, grouped by card: one card's, or every card's on
/// the boards. Each opens to read and can be unarchived. Lives inside a
/// navigation stack.
struct ArchivedConversationsList: View {
    let fleet: FleetModel
    /// One card's, or every card's when nil.
    let cardId: String?
    /// Words the title, the last message or the card's title must hold.
    var filter = ""
    @State private var groups: [ArchivedConversationGroup] = []
    @State private var loaded = false
    @State private var failures: [String] = []
    @State private var error: String?

    /// The cards to ask: the one, or every card the boards say has some.
    private var targets: [FleetCard] {
        if let cardId { return fleet.entry(cardId: cardId).map { [$0] } ?? [] }
        return fleet.cards.filter { $0.card.archivedConversationCount > 0 }
    }

    var body: some View {
        Group {
            if !loaded {
                ProgressView("Loading archived conversations")
            } else if !groups.isEmpty && shown.isEmpty {
                ContentUnavailableView.search(text: filter)
            } else if groups.isEmpty {
                ContentUnavailableView("No archived conversations", systemImage: "bubble.left.and.bubble.right",
                                       description: Text(failures.joined(separator: "\n")))
            } else {
                List {
                    ForEach(shown) { group in
                        Section {
                            ForEach(group.conversations) { conversation in
                                row(conversation, cardId: group.cardId)
                            }
                        } header: {
                            if cardId == nil { Text(group.cardTitle) }
                        } footer: {
                            if group.id == shown.last?.id, !failures.isEmpty {
                                Text(failures.joined(separator: "\n"))
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .task { await load() }
        // Back from a conversation that was unarchived there.
        .onAppear { if loaded { Task { await load() } } }
        .refreshable { await load() }
        .alert("Something went wrong", isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    /// The groups with only the conversations `filter` matches.
    private var shown: [ArchivedConversationGroup] {
        let words = filter.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return groups }
        return groups.compactMap { group in
            var group = group
            group.conversations = group.conversations.filter { conversation in
                let text = [conversation.displayTitle, conversation.preview ?? "", group.cardTitle].joined(separator: " ").lowercased()
                return words.allSatisfy(text.contains)
            }
            return group.conversations.isEmpty ? nil : group
        }
    }

    private func row(_ conversation: RemoteConversation, cardId: String) -> some View {
        NavigationLink {
            FleetConversationScreen(route: ConversationRoute(cardId: cardId, id: conversation.id), fleet: fleet)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(conversation.displayTitle)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(Self.subtitle(conversation))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .swipeActions(edge: .trailing) {
            Button("Unarchive", systemImage: "tray.and.arrow.up") {
                unarchive(conversation, cardId: cardId)
            }
            .tint(.blue)
        }
        .accessibilityIdentifier("archived-conversation-\(cardId)-\(conversation.id)")
    }

    static func subtitle(_ conversation: RemoteConversation) -> String {
        let age = conversation.updatedAt.formatted(.relative(presentation: .named))
        if let preview = conversation.preview, !preview.isEmpty { return "\(age) · \(preview)" }
        return "\(age) · \(conversation.messageCount) message\(conversation.messageCount == 1 ? "" : "s")"
    }

    /// Each card's conversations, from the master that owns the card.
    private func load() async {
        var lists: [String: [RemoteConversation]] = [:]
        var titles: [String: String] = [:]
        var failed: [String] = []
        for entry in targets {
            guard let client = entry.master.client else {
                failed.append("\(entry.machineName) is offline.")
                continue
            }
            do {
                lists[entry.id] = try await client.conversations(cardId: entry.id)
                titles[entry.id] = entry.card.title
            } catch {
                failed.append("Could not load the conversations of \(entry.card.title): \(error.localizedDescription)")
            }
        }
        groups = ArchivedConversationGroup.groups(conversations: lists, titles: titles)
        failures = Array(Set(failed)).sorted()
        loaded = true
    }

    /// Back on the card: the board lists it again, the count drops.
    private func unarchive(_ conversation: RemoteConversation, cardId: String) {
        guard let entry = fleet.entry(cardId: cardId), let client = entry.master.client else {
            error = "Could not unarchive the conversation: its machine is offline."
            return
        }
        Task {
            do {
                let updated = try await client.updateConversation(
                    cardId: cardId, id: conversation.id, RemoteConversationUpdate(archived: false))
                ConversationModel.applyArchive(updated, cardId: cardId, board: entry.master)
                for index in groups.indices where groups[index].cardId == cardId {
                    groups[index].conversations.removeAll { $0.id == conversation.id }
                }
                groups.removeAll { $0.conversations.isEmpty }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                self.error = "Could not unarchive the conversation: \(error.localizedDescription)"
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }
}

/// The archived conversations of one card, in a sheet of its own.
struct ArchivedConversationsSheet: View {
    let fleet: FleetModel
    let entry: FleetCard
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ArchivedConversationsList(fleet: fleet, cardId: entry.id)
                .navigationTitle("Archived conversations")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier("archivedConversationsDone")
                    }
                }
        }
    }
}
