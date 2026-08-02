import SwiftUI
import KanbanCodeCore

struct SubagentManagerView: View {
    var store: BoardStore
    let parentId: String
    let onOpen: (String) -> Void
    let onResume: (String) -> Void
    let onArchive: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    private var descendants: [KanbanCodeCard] {
        let ids = SubagentHierarchy.descendantIds(of: parentId, in: store.state.links)
        return store.state.cards
            .filter { ids.contains($0.id) }
            .sorted {
                let left = $0.link.lastActivity ?? $0.link.updatedAt
                let right = $1.link.lastActivity ?? $1.link.updatedAt
                if left != right { return left > right }
                return $0.id < $1.id
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Subagents")
                        .font(.title2.bold())
                    Text("Active and archived child sessions")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            if descendants.isEmpty {
                ContentUnavailableView(
                    "No Subagents",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("This card has not created any child sessions.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(descendants) { card in
                            row(card)
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 420)
    }

    private func row(_ card: KanbanCodeCard) -> some View {
        HStack(spacing: 12) {
            AssistantIcon(assistant: card.link.effectiveAssistant)
                .frame(width: 18, height: 18)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 3) {
                Text(card.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text("Depth \(SubagentHierarchy.depth(of: card.id, in: store.state.links))")
                    Text(card.id)
                    Text(card.link.effectiveAssistant.displayName)
                    if let model = card.link.modelOverride { Text(model) }
                    Text(card.relativeTime)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Text(card.link.manuallyArchived ? "Archived" : card.column.displayName)
                .font(.caption.weight(.medium))
                .foregroundStyle(card.link.manuallyArchived ? .secondary : card.column.accentColor)

            Button("Open") { onOpen(card.id) }
                .controlSize(.small)

            if card.link.manuallyArchived {
                Button("Resume") { onResume(card.id) }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Archive") { onArchive(card.id) }
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(Color(.controlBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
    }
}
