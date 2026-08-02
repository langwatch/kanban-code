import SwiftUI
import KanbanCodeCore

struct ColumnView: View {
    let column: KanbanCodeColumn
    let cards: [KanbanCodeCard]
    @Binding var selectedCardId: String?
    let onCopyConversationMarkdown: (String) -> Void
    let onSetCardPinned: (String, Bool) -> Void
    let onSetSelfCompactContextThreshold: (String, Int?) -> Void
    let onShowSubagents: (String) -> Void

    var body: some View {
        // Card list with header pill overlaid on top
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(cards) { card in
                    CardView(
                        card: card,
                        isSelected: card.id == selectedCardId,
                        onCopyConversationMarkdown: { onCopyConversationMarkdown(card.id) },
                        subagentCount: 0,
                        activeDirectSubagentCount: 0,
                        onShowSubagents: { onShowSubagents(card.id) },
                        onSetPinned: { isPinned in onSetCardPinned(card.id, isPinned) },
                        onSetSelfCompactContextThreshold: { threshold in
                            onSetSelfCompactContextThreshold(card.id, threshold)
                        },
                        onSelect: {
                            if selectedCardId == card.id {
                                selectedCardId = nil
                            } else {
                                selectedCardId = card.id
                            }
                        }
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 44) // space for the floating header
            .padding(.bottom, 8)
        }
        .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
        .background(Color(.windowBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
        // Header pill floating on top of the column
        .overlay(alignment: .top) {
            HStack {
                Text(column.displayName)
                    .font(.app(.headline))
                    .foregroundStyle(.primary)

                Spacer()

                Text("\(cards.count)")
                    .font(.app(.caption))
                    .fontWeight(.medium)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.2)))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(4)
        }
    }
}
