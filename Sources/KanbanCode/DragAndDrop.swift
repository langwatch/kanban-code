import SwiftUI
import KanbanCodeCore

/// Shared drag state so source and target columns can communicate.
@Observable
class DragState {
    var draggingCard: KanbanCodeCard?
    var sourceColumn: KanbanCodeColumn?
    /// Card ID the cursor is currently over (merge candidate).
    var mergeTargetId: String?
    /// Drop insertion indicator for same-column reordering.
    var reorderTargetId: String?
    /// Whether to insert above (true) or below (false) the reorder target.
    var reorderAbove: Bool = true
}

/// Preference key to collect card frames within a column's coordinate space.
struct CardFramePreference: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// A column view that supports drag and drop (column move + card-to-card merge).
struct DroppableColumnView: View {
    let column: KanbanCodeColumn
    let cards: [KanbanCodeCard]
    @Binding var selectedCardId: String?
    var dragState: DragState
    var isRefreshingBacklog: Bool = false
    var onMoveCard: (String, KanbanCodeColumn) -> Void = { _, _ in }
    var onMergeCards: (String, String) -> Void = { _, _ in }   // (sourceId, targetId)
    var onReorderCard: (String, String, Bool) -> Void = { _, _, _ in }  // (cardId, targetCardId, above)
    var onRenameCard: (String, String) -> Void = { _, _ in }
    var onArchiveCard: (String) -> Void = { _ in }
    var onStartCard: (String) -> Void = { _ in }
    var onResumeCard: (String) -> Void = { _ in }
    var onForkCard: (String) -> Void = { _ in }
    var onCopyResumeCmd: (String) -> Void = { _ in }
    var onCleanupWorktree: (String) -> Void = { _ in }
    var canCleanupWorktree: (String) -> Bool = { _ in true }
    var onDeleteCard: (String) -> Void = { _ in }
    var availableProjects: [(name: String, path: String)] = []
    var onMoveToProject: (String, String) -> Void = { _, _ in }   // (cardId, projectPath)
    var onRefreshBacklog: (() -> Void)?
    var onCardClicked: (String) -> Void = { _ in }
    var onColumnBackgroundClick: (KanbanCodeColumn) -> Void = { _ in }

    @State private var isTargeted = false
    @State private var renamingCardId: String?
    @State private var cardFrames: [String: CGRect] = [:]

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(cards) { card in
                    cardRow(card)
                }
                ghostCardPlaceholder
            }
            .padding(.horizontal, 8)
            .padding(.top, 56) // space for the floating header
            .padding(.bottom, 8)
        }
        .coordinateSpace(name: "column_\(column.rawValue)")
        .onPreferenceChange(CardFramePreference.self) { cardFrames = $0 }
        .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
        .glassColumn()
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isTargeted && dragState.mergeTargetId == nil
                        ? Color.accentColor.opacity(0.5) : Color.clear,
                    lineWidth: isTargeted ? 2 : 0
                )
        )
        .overlay(alignment: .top) { columnHeader }
        .onDrop(of: [.utf8PlainText], delegate: ColumnDropDelegate(
            column: column,
            cards: cards,
            cardFrames: cardFrames,
            dragState: dragState,
            isTargeted: $isTargeted,
            onMoveCard: onMoveCard,
            onMergeCards: onMergeCards,
            onReorderCard: onReorderCard
        ))
        .simultaneousGesture(
            SpatialTapGesture(count: 2).onEnded { value in
                handleBackgroundTap(at: value.location)
            }
        )
        .animation(.easeInOut(duration: 0.15), value: isTargeted)
        .animation(.easeInOut(duration: 0.15), value: dragState.mergeTargetId)
        .animation(.easeInOut(duration: 0.15), value: dragState.reorderTargetId)
    }

    // MARK: - Extracted Subviews

    @ViewBuilder
    private func cardRow(_ card: KanbanCodeCard) -> some View {
        let isMergeTarget = dragState.mergeTargetId == card.id
        let canMerge: Bool = {
            guard let source = dragState.draggingCard, source.id != card.id else { return false }
            return Link.mergeBlocked(source: source.link, target: card.link) == nil
        }()

        // Drop indicator above this card
        if dragState.reorderTargetId == card.id && dragState.reorderAbove {
            ReorderIndicator()
        }

        CardView(
            card: card,
            isSelected: card.id == selectedCardId,
            onSelect: {
                let newId = selectedCardId == card.id ? nil : card.id
                selectedCardId = newId
                if newId != nil { onCardClicked(card.id) }
            },
            onStart: { onStartCard(card.id) },
            onResume: { onResumeCard(card.id) },
            onFork: { onForkCard(card.id) },
            onRename: {
                renamingCardId = card.id
            },
            onCopyResumeCmd: { onCopyResumeCmd(card.id) },
            onCleanupWorktree: { onCleanupWorktree(card.id) },
            canCleanupWorktree: canCleanupWorktree(card.id),
            onArchive: { onArchiveCard(card.id) },
            onDelete: { onDeleteCard(card.id) },
            availableProjects: availableProjects,
            onMoveToProject: { projectPath in onMoveToProject(card.id, projectPath) }
        )
        // Merge highlight
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isMergeTarget && canMerge ? Color.orange : Color.clear,
                    lineWidth: 2
                )
        )
        .overlay(alignment: .top) {
            if isMergeTarget && canMerge {
                Text("Merge")
                    .font(.app(.caption2).bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.orange, in: Capsule())
                    .offset(y: -10)
            }
        }
        // Report frame in column coordinate space
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: CardFramePreference.self,
                    value: [card.id: geo.frame(in: .named("column_\(column.rawValue)"))]
                )
            }
        )
        .onDrag {
            dragState.draggingCard = card
            dragState.sourceColumn = column
            return NSItemProvider(object: card.id as NSString)
        }
        .sheet(isPresented: Binding(
            get: { renamingCardId == card.id },
            set: { if !$0 { renamingCardId = nil } }
        )) {
            RenameSessionDialog(
                currentName: card.link.name ?? card.displayTitle,
                isPresented: Binding(
                    get: { renamingCardId == card.id },
                    set: { if !$0 { renamingCardId = nil } }
                ),
                onRename: { name in
                    onRenameCard(card.id, name)
                }
            )
        }

        // Drop indicator below this card
        if dragState.reorderTargetId == card.id && !dragState.reorderAbove {
            ReorderIndicator()
        }
    }

    @ViewBuilder
    private var ghostCardPlaceholder: some View {
        if isTargeted, dragState.mergeTargetId == nil,
           let dragging = dragState.draggingCard, dragState.sourceColumn != column {
            VStack(alignment: .leading, spacing: 6) {
                Text(dragging.displayTitle)
                    .font(.app(.body, weight: .medium))
                    .lineLimit(2)
                    .foregroundStyle(.primary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.3), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])))
            .opacity(0.7)
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
        }
    }

    @ViewBuilder
    private var columnHeader: some View {
        HStack {
            Text(column.displayName)
                .font(.app(.headline))
                .foregroundStyle(.primary)

            Spacer()

            if let onRefreshBacklog {
                Button {
                    onRefreshBacklog()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.app(.caption))
                        .opacity(isRefreshingBacklog ? 0 : 1)
                        .overlay {
                            if isRefreshingBacklog {
                                ProgressView()
                                    .controlSize(.mini)
                            }
                        }
                }
                .buttonStyle(.borderless)
                .help("Refresh GitHub issues")
                .disabled(isRefreshingBacklog)
            }

            Text("\(cards.count)")
                .font(.app(.caption))
                .fontWeight(.medium)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.secondary.opacity(0.2)))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
        .padding(4)
    }

    private func handleBackgroundTap(at location: CGPoint) {
        guard column.allowsBoardTaskCreation else { return }
        guard dragState.draggingCard == nil else { return }
        guard location.y >= 56 else { return }

        let tappedCard = cardFrames.values.contains { $0.contains(location) }
        guard !tappedCard else { return }

        onColumnBackgroundClick(column)
    }
}

/// Drop delegate that handles both column-level moves and card-to-card merges.
/// Uses cursor position + stored card frames to detect merge targets.
struct ColumnDropDelegate: DropDelegate {
    let column: KanbanCodeColumn
    let cards: [KanbanCodeCard]
    let cardFrames: [String: CGRect]
    let dragState: DragState
    @Binding var isTargeted: Bool
    let onMoveCard: (String, KanbanCodeColumn) -> Void
    let onMergeCards: (String, String) -> Void
    let onReorderCard: (String, String, Bool) -> Void  // (cardId, targetCardId, above)

    private var isSameColumn: Bool {
        dragState.sourceColumn == column
    }

    func dropEntered(info: DropInfo) {
        isTargeted = true
        updateTargets(at: info.location)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateTargets(at: info.location)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
        dragState.mergeTargetId = nil
        dragState.reorderTargetId = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            dragState.draggingCard = nil
            dragState.sourceColumn = nil
            dragState.mergeTargetId = nil
            dragState.reorderTargetId = nil
            isTargeted = false
        }

        guard let sourceCard = dragState.draggingCard else { return false }

        // Check if we're merging onto a card
        if let targetId = dragState.mergeTargetId,
           let targetCard = cards.first(where: { $0.id == targetId }),
           Link.mergeBlocked(source: sourceCard.link, target: targetCard.link) == nil {
            onMergeCards(sourceCard.id, targetId)
            return true
        }

        // Same-column reorder
        if isSameColumn, let targetId = dragState.reorderTargetId, targetId != sourceCard.id {
            onReorderCard(sourceCard.id, targetId, dragState.reorderAbove)
            return true
        }

        // Otherwise, column-level move
        guard let source = dragState.sourceColumn, source != column else { return false }
        onMoveCard(sourceCard.id, column)
        return true
    }

    private func updateTargets(at location: CGPoint) {
        guard let source = dragState.draggingCard else {
            dragState.mergeTargetId = nil
            dragState.reorderTargetId = nil
            return
        }

        if isSameColumn {
            // Same-column: detect reorder position
            updateReorderTarget(at: location, source: source)
        } else {
            // Cross-column: detect merge target
            updateMergeTarget(at: location, source: source)
        }
    }

    private func updateReorderTarget(at location: CGPoint, source: KanbanCodeCard) {
        dragState.mergeTargetId = nil

        // Find the nearest card and whether cursor is in upper or lower half
        for (cardId, frame) in cardFrames {
            guard cardId != source.id, frame.contains(location) else { continue }
            let midY = frame.midY
            dragState.reorderTargetId = cardId
            dragState.reorderAbove = location.y < midY
            return
        }
        dragState.reorderTargetId = nil
    }

    private func updateMergeTarget(at location: CGPoint, source: KanbanCodeCard) {
        dragState.reorderTargetId = nil

        for (cardId, frame) in cardFrames {
            guard cardId != source.id, frame.contains(location) else { continue }
            guard let targetCard = cards.first(where: { $0.id == cardId }),
                  Link.mergeBlocked(source: source.link, target: targetCard.link) == nil else {
                dragState.mergeTargetId = nil
                return
            }
            dragState.mergeTargetId = cardId
            return
        }
        dragState.mergeTargetId = nil
    }
}

// MARK: - Reorder Drop Indicator

struct ReorderIndicator: View {
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 6, height: 6)
            Rectangle()
                .fill(Color.accentColor)
                .frame(height: 2)
            Circle()
                .fill(Color.accentColor)
                .frame(width: 6, height: 6)
        }
        .padding(.horizontal, 4)
        .transition(.opacity)
    }
}
