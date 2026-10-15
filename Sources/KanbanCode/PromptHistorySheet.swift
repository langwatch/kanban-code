import KanbanCodeCore
import SwiftUI

/// One prompt as the history shows it: the last thing that happened to it, and
/// the text as it stood then.
struct PromptHistoryItem: Identifiable, Equatable {
    let id: String
    let body: String
    let sentAt: Date
    let reason: QueuedPromptJournalReason
    let imageCount: Int

    /// Collapses a card's journal into one row per prompt, newest first.
    ///
    /// A prompt is written down at every step of its life, so a message sent
    /// from the composer leaves both a queued and a sent record and an edited
    /// one leaves a record per revision. What anyone wants back is the last
    /// version of each.
    static func from(_ entries: [QueuedPromptJournalEntry]) -> [PromptHistoryItem] {
        var latest: [String: QueuedPromptJournalEntry] = [:]
        for entry in entries {
            guard let existing = latest[entry.promptId], existing.timestamp > entry.timestamp
            else {
                latest[entry.promptId] = entry
                continue
            }
        }
        return
            latest.values
            .filter { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.timestamp > $1.timestamp }
            .map {
                PromptHistoryItem(
                    id: $0.promptId,
                    body: $0.body,
                    sentAt: $0.timestamp,
                    reason: $0.reason,
                    imageCount: $0.imagePaths?.count ?? 0
                )
            }
    }

    var status: String {
        switch self.reason {
        case .sent: "Sent"
        case .queued: "Queued"
        case .edited: "Edited"
        case .removed: "Deleted"
        case .failed: "Not sent"
        }
    }
}

/// Every prompt sent to a card, from the composer or from the queue, with a way
/// to send one again.
///
/// Sending removes a prompt from the card before tmux is asked to take it, so a
/// send that fails or only half lands leaves nothing behind on the card itself.
/// This reads the journal that keeps them.
struct PromptHistorySheet: View {
    let cardId: String
    let onResend: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var items: [PromptHistoryItem] = []
    @State private var isLoading = true
    @State private var query = ""
    @State private var resentId: String?

    private var visibleItems: [PromptHistoryItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return items }
        return items.filter { $0.body.lowercased().contains(trimmed) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 640, height: 520)
        .task { await load() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "list.bullet.rectangle.portrait")
                .foregroundStyle(.secondary)
            Text("Prompt History")
                .font(.app(.headline))
            Spacer()
            TextField("Filter", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visibleItems.isEmpty {
            VStack(spacing: 6) {
                Text(items.isEmpty ? "No prompts recorded yet" : "No prompt matches that")
                    .foregroundStyle(.secondary)
                if items.isEmpty {
                    Text("Prompts sent from the composer or the queue show up here.")
                        .font(.app(.caption))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(visibleItems) { item in
                        row(item)
                    }
                }
                .padding(12)
            }
        }
    }

    private func row(_ item: PromptHistoryItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(item.status)
                    .font(.app(.caption))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                    .foregroundStyle(.secondary)
                if item.imageCount > 0 {
                    Label("\(item.imageCount)", systemImage: "photo")
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                }
                Text(item.sentAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.app(.caption))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.body, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .font(.app(.caption))
                Button {
                    onResend(item.body)
                    resentId = item.id
                } label: {
                    Label(resentId == item.id ? "Sent" : "Resend", systemImage: "arrow.uturn.left")
                }
                .buttonStyle(.borderless)
                .font(.app(.caption))
                .disabled(resentId == item.id)
            }
            SelectableMarkdownText(
                content: .plain(String(item.body.prefix(2_000))),
                appearance: .init(font: .app(.callout), foregroundColor: .labelColor)
            )
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
    }

    private func load() async {
        let entries = await QueuedPromptJournal().entries(forCard: cardId)
        items = PromptHistoryItem.from(entries)
        isLoading = false
    }
}
