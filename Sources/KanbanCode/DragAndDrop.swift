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
    var canDropCard: (KanbanCodeCard, KanbanCodeColumn) -> Bool = { _, _ in true }
    var isRefreshingBacklog: Bool = false
    var onMoveCard: (String, KanbanCodeColumn) -> Void = { _, _ in }
    var onMergeCards: (String, String) -> Void = { _, _ in }   // (sourceId, targetId)
    var onReorderCard: (String, String, Bool) -> Void = { _, _, _ in }  // (cardId, targetCardId, above)
    var onRenameCard: (String, String) -> Void = { _, _ in }
    var onArchiveCard: (String) -> Void = { _ in }
    var onStartCard: (String) -> Void = { _ in }
    var onResumeCard: (String) -> Void = { _ in }
    var onForkCard: (String, Bool) -> Void = { _, _ in }
    var onCopyResumeCmd: (String) -> Void = { _ in }
    var onDiscoverCard: (String) -> Void = { _ in }
    var onCleanupWorktree: (String) -> Void = { _ in }
    var canCleanupWorktree: (String) -> Bool = { _ in true }
    var onDeleteCard: (String) -> Void = { _ in }
    var availableProjects: [(name: String, path: String)] = []
    var onMoveToProject: (String, String) -> Void = { _, _ in }   // (cardId, projectPath)
    var onMoveToFolder: (String) -> Void = { _ in }
    var enabledAssistants: [CodingAssistant] = []
    var onMigrateAssistant: (String, CodingAssistant) -> Void = { _, _ in }
    var onRefreshBacklog: (() -> Void)?
    var onCardClicked: (String) -> Void = { _ in }
    var onColumnBackgroundClick: (KanbanCodeColumn) -> Void = { _ in }

    @State private var isTargeted = false
    @State private var renamingCardId: String?
    @State private var cardFrames: [String: CGRect] = [:]

    private var isCollectingCardFrames: Bool {
        dragState.draggingCard != nil
    }

    private var isCurrentDropAllowed: Bool {
        guard let draggingCard = dragState.draggingCard else { return true }
        if dragState.sourceColumn == column || dragState.mergeTargetId != nil {
            return true
        }
        return canDropCard(draggingCard, column)
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(cards) { card in
                    let isMergeTarget = dragState.mergeTargetId == card.id
                    let canMerge: Bool = {
                        guard let source = dragState.draggingCard, source.id != card.id else { return false }
                        return Link.mergeBlocked(source: source.link, target: card.link) == nil
                    }()

                    // Drop indicator above this card
                    if dragState.reorderTargetId == card.id && dragState.reorderAbove {
                        ReorderIndicator()
                    }

                    cardView(for: card)
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
                    .background { cardFrameReporter(for: card) }
                    .onDrag {
                        dragState.draggingCard = card
                        dragState.sourceColumn = column
                        return NSItemProvider(object: card.id as NSString)
                    }
                    // Drop indicator below this card
                    if dragState.reorderTargetId == card.id && !dragState.reorderAbove {
                        ReorderIndicator()
                    }
                }

                // Ghost card placeholder when dragging over this column (not merging)
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
            .padding(.horizontal, 8)
            .padding(.top, 56) // space for the floating header
            .padding(.bottom, 8)
        }
        .coordinateSpace(name: "column_\(column.rawValue)")
        .onPreferenceChange(CardFramePreference.self) { frames in
            cardFrames = isCollectingCardFrames ? frames : [:]
        }
        .onChange(of: dragState.draggingCard?.id) { _, draggingId in
            if draggingId == nil { cardFrames = [:] }
        }
        .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
        .glassColumn()
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isTargeted && dragState.mergeTargetId == nil
                        ? (isCurrentDropAllowed ? Color.accentColor.opacity(0.5) : Color.red.opacity(0.55))
                        : Color.clear,
                    lineWidth: isTargeted ? 2 : 0
                )
        )
        .overlay(alignment: .topTrailing) {
            if isTargeted, dragState.mergeTargetId == nil, !isCurrentDropAllowed {
                InvalidDropBadge()
                    .padding(10)
            }
        }
        // Header pill floating on top of the column
        .overlay(alignment: .top) {
            HStack {
                Text(column.displayName)
                    .font(.app(.headline))
                    .foregroundStyle(.primary)

                Spacer()

                if let onRefreshBacklog {
                    Button {
                        onRefreshBacklog()
                    } label: {
                        if isRefreshingBacklog {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.app(.caption))
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
        .onDrop(of: [.utf8PlainText], delegate: ColumnDropDelegate(
            column: column,
            cards: cards,
            cardFrames: cardFrames,
            dragState: dragState,
            isTargeted: $isTargeted,
            canDropCard: canDropCard,
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
        .sheet(isPresented: Binding(
            get: { renamingCardId != nil && cards.contains(where: { $0.id == renamingCardId }) },
            set: { if !$0 { renamingCardId = nil } }
        )) {
            if let cardId = renamingCardId, let card = cards.first(where: { $0.id == cardId }) {
                RenameSessionDialog(
                    currentName: card.link.name ?? card.displayTitle,
                    isPresented: Binding(get: { renamingCardId != nil }, set: { if !$0 { renamingCardId = nil } }),
                    onRename: { name in onRenameCard(cardId, name) }
                )
            }
        }
    }

    @ViewBuilder
    private func cardFrameReporter(for card: KanbanCodeCard) -> some View {
        if isCollectingCardFrames {
            GeometryReader { geo in
                Color.clear.preference(
                    key: CardFramePreference.self,
                    value: [card.id: geo.frame(in: .named("column_\(column.rawValue)"))]
                )
            }
        } else {
            Color.clear
        }
    }

    private func handleBackgroundTap(at location: CGPoint) {
        guard column.allowsBoardTaskCreation else { return }
        guard dragState.draggingCard == nil else { return }
        guard location.y >= 56 else { return }

        let tappedCard = cardFrames.values.contains { $0.contains(location) }
        guard !tappedCard else { return }

        onColumnBackgroundClick(column)
    }

    private func cardView(for card: KanbanCodeCard) -> CardView {
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
            onFork: { keepWorktree in onForkCard(card.id, keepWorktree) },
            onRenameRequest: { renamingCardId = card.id },
            onCopyResumeCmd: { onCopyResumeCmd(card.id) },
            onDiscover: { onDiscoverCard(card.id) },
            onCleanupWorktree: { onCleanupWorktree(card.id) },
            canCleanupWorktree: canCleanupWorktree(card.id),
            onArchive: { onArchiveCard(card.id) },
            onDelete: { onDeleteCard(card.id) },
            availableProjects: availableProjects,
            onMoveToProject: { projectPath in onMoveToProject(card.id, projectPath) },
            onMoveToFolder: { onMoveToFolder(card.id) },
            enabledAssistants: enabledAssistants,
            onMigrateAssistant: { target in onMigrateAssistant(card.id, target) }
        )
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
    let canDropCard: (KanbanCodeCard, KanbanCodeColumn) -> Bool
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
        guard let sourceCard = dragState.draggingCard else { return nil }
        if isSameColumn || dragState.mergeTargetId != nil || canDropCard(sourceCard, column) {
            return DropProposal(operation: .move)
        }
        return nil
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
        guard canDropCard(sourceCard, column) else { return false }
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
        // Find the nearest card and whether cursor is in upper or lower half
        for (cardId, frame) in cardFrames {
            guard cardId != source.id, frame.contains(location) else { continue }

            // Check if this is a valid merge target — merge takes priority over reorder
            if let targetCard = cards.first(where: { $0.id == cardId }),
               Link.mergeBlocked(source: source.link, target: targetCard.link) == nil {
                dragState.mergeTargetId = cardId
                dragState.reorderTargetId = nil
                return
            }

            // Otherwise reorder
            let midY = frame.midY
            dragState.mergeTargetId = nil
            dragState.reorderTargetId = cardId
            dragState.reorderAbove = location.y < midY
            return
        }
        dragState.mergeTargetId = nil
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

struct InvalidDropBadge: View {
    var body: some View {
        Label("Not allowed", systemImage: "nosign")
            .font(.app(.caption2))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.red, in: Capsule())
    }
}
