import SwiftUI
import KanbanCodeCore
import struct KanbanCodeCore.Link

struct BoardView: View {
    var store: BoardStore
    @State private var dragState = DragState()
    @State private var sidebarReorderState = SidebarReorderState()
    @State private var renamingPinnedCardId: String?
    @State private var collapsedPinnedSubagentParents: Set<String> = []
    var onOpenChannel: (String) -> Void = { _ in }
    var onNewChannel: () -> Void = {}
    var onDeleteChannel: (String) -> Void = { _ in }
    var onRenameChannel: (String) -> Void = { _ in }
    var unreadCountForChannel: (Channel) -> Int = { _ in 0 }
    var onlineCountForChannel: (Channel) -> Int = { _ in 0 }
    var onStartCard: (String) -> Void = { _ in }
    var onResumeCard: (String) -> Void = { _ in }
    var onForkCard: (String, Bool) -> Void = { _, _ in }
    var onCopyResumeCmd: (String) -> Void = { _ in }
    var onCopyConversationMarkdown: (String) -> Void = { _ in }
    let onShowSubagents: (String) -> Void
    var onTrimSession: (String) -> Void = { _ in }
    var onDiscoverCard: (String) -> Void = { _ in }
    var onCleanupWorktree: (String) -> Void = { _ in }
    var canCleanupWorktree: (String) -> Bool = { _ in true }
    var onArchiveCard: (String) -> Void = { _ in }
    var onDeleteCard: (String) -> Void = { _ in }
    let onSetCardPinned: (String, Bool) -> Void
    let onSetSelfCompactContextThreshold: (String, Int?) -> Void
    var availableProjects: [(name: String, path: String)] = []
    var onMoveToProject: (String, String) -> Void = { _, _ in }
    var onMoveToFolder: (String) -> Void = { _ in }
    var enabledAssistants: [CodingAssistant] = []
    var onMigrateAssistant: (String, CodingAssistant) -> Void = { _, _ in }
    var onRefreshBacklog: () -> Void = {}

    var canDropCard: (KanbanCodeCard, KanbanCodeColumn) -> Bool = { _, _ in true }
    var onDropCard: (String, KanbanCodeColumn) -> Void = { _, _ in }
    var onMergeCards: (String, String) -> Void = { _, _ in }   // (sourceId, targetId)
    var onNewTask: () -> Void = {}
    var onCardClicked: (String) -> Void = { _ in }
    var onColumnBackgroundClick: (KanbanCodeColumn) -> Void = { _ in }

    var body: some View {
        boardContent
    }

    private var activeSubagentsByParent: [String: [KanbanCodeCard]] {
        Dictionary(grouping: store.state.filteredCards.filter {
            $0.link.parentCardId != nil && !$0.link.manuallyArchived
        }) { $0.link.parentCardId! }
        .mapValues { cards in
            cards.sorted {
                let left = $0.link.lastActivity ?? $0.link.updatedAt
                let right = $1.link.lastActivity ?? $1.link.updatedAt
                return left == right ? $0.id < $1.id : left > right
            }
        }
    }

    private var activeSubagentCardsById: [String: KanbanCodeCard] {
        Dictionary(uniqueKeysWithValues: activeSubagentsByParent.values.flatMap { $0 }.map { ($0.id, $0) })
    }

    private var activeSubagentLinks: [String: Link] {
        Dictionary(uniqueKeysWithValues: activeSubagentCardsById.values.map { ($0.id, $0.link) })
    }

    @ViewBuilder
    private var channelsPseudoColumn: some View {
        let channels = store.state.channels
        let pinnedCards = store.state.pinnedCards
        let descendantCounts = SubagentHierarchy.descendantCounts(in: store.state.links)
        if !channels.isEmpty || !pinnedCards.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if !channels.isEmpty {
                    // Subtle header so the column reads as "Channels" without competing with real columns.
                    HStack(spacing: 6) {
                        Text("Channels")
                            .font(.app(.caption, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .textCase(.uppercase)
                        Spacer(minLength: 0)
                        Button(action: onNewChannel) {
                            Image(systemName: "plus")
                                .font(.app(.caption))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("New chat channel")
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 2)

                    ForEach(channels) { ch in
                        let msgs = store.state.channelMessages[ch.name]
                        let last = msgs?.last
                        SidebarReorderableRow(
                            item: .channel(ch.id),
                            reorderState: sidebarReorderState,
                            onMove: reorderChannel
                        ) {
                            ChannelTile(
                                channel: ch,
                                onlineCount: onlineCountForChannel(ch),
                                lastMessageAt: last?.ts,
                                lastMessageBody: last?.body,
                                isSelected: store.state.selectedChannelName == ch.name,
                                unreadCount: unreadCountForChannel(ch),
                                onOpen: { onOpenChannel(ch.name) },
                                onDelete: { onDeleteChannel(ch.name) },
                                onRename: { onRenameChannel(ch.name) }
                            )
                        }
                    }
                    if channels.count > 1 {
                        SidebarReorderEndTarget(
                            kind: .channel(""),
                            reorderState: sidebarReorderState,
                            onMove: reorderChannel
                        )
                    }
                }

                if !pinnedCards.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "pin.fill")
                        Text("Pinned")
                        Spacer(minLength: 0)
                        Text("\(pinnedCards.count)")
                    }
                    .font(.app(.caption, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .padding(.horizontal, 10)
                    .padding(.top, channels.isEmpty ? 2 : 6)

                    ForEach(pinnedCards) { card in
                        SidebarReorderableRow(
                            item: .pinnedCard(card.id),
                            reorderState: sidebarReorderState,
                            onMove: reorderPinnedCard
                        ) {
                            pinnedCardView(for: card, descendantCounts: descendantCounts)
                        }
                        ForEach(visiblePinnedSubagents(for: card.id)) { row in
                            if let child = activeSubagentCardsById[row.cardId] {
                                pinnedCardView(for: child, descendantCounts: descendantCounts)
                                    .padding(.leading, CGFloat(row.depth * 16))
                            }
                        }
                    }
                    if pinnedCards.count > 1 {
                        SidebarReorderEndTarget(
                            kind: .pinnedCard(""),
                            reorderState: sidebarReorderState,
                            onMove: reorderPinnedCard
                        )
                    }
                }
            }
            .padding(.horizontal, 6)
            .frame(width: 240, alignment: .top)
        }
    }

    private func reorderChannel(_ channelId: String, _ targetChannelId: String?, _ above: Bool) {
        store.dispatch(.reorderChannel(channelId: channelId, targetChannelId: targetChannelId, above: above))
    }

    private func reorderPinnedCard(_ cardId: String, _ targetCardId: String?, _ above: Bool) {
        store.dispatch(.reorderPinnedCard(cardId: cardId, targetCardId: targetCardId, above: above))
    }

    private var boardContent: some View {
        let descendantCounts = SubagentHierarchy.descendantCounts(in: store.state.links)
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .top, spacing: 6) {
                    channelsPseudoColumn
                        .id("channels")
                    ForEach(store.state.visibleColumns, id: \.self) { column in
                        DroppableColumnView(
                            column: column,
                            cards: store.state.unpinnedCards(in: column),
                            selectedCardId: Binding(
                                get: { store.state.selectedCardId },
                                set: { store.dispatch(.selectCard(cardId: $0)) }
                            ),
                            dragState: dragState,
                            canDropCard: canDropCard,
                            isRefreshingBacklog: store.state.isRefreshingBacklog,
                            onMoveCard: { cardId, targetColumn in
                                onDropCard(cardId, targetColumn)
                            },
                            onMergeCards: { sourceId, targetId in
                                onMergeCards(sourceId, targetId)
                            },
                            onReorderCard: { cardId, targetCardId, above in
                                store.dispatch(.reorderCard(cardId: cardId, targetCardId: targetCardId, above: above))
                            },
                            onRenameCard: { cardId, name in
                                store.dispatch(.renameCard(cardId: cardId, name: name))
                            },
                            onArchiveCard: { cardId in
                                onArchiveCard(cardId)
                            },
                            onStartCard: onStartCard,
                            onResumeCard: onResumeCard,
                            onForkCard: onForkCard,
                            onCopyResumeCmd: onCopyResumeCmd,
                            onCopyConversationMarkdown: onCopyConversationMarkdown,
                            onShowSubagents: onShowSubagents,
                            subagentsByParent: activeSubagentsByParent,
                            descendantCounts: descendantCounts,
                            onTrimSession: onTrimSession,
                            onSetCardPinned: onSetCardPinned,
                            onSetSelfCompactContextThreshold: onSetSelfCompactContextThreshold,
                            onDiscoverCard: onDiscoverCard,
                            onCleanupWorktree: onCleanupWorktree,
                            canCleanupWorktree: canCleanupWorktree,
                            onDeleteCard: onDeleteCard,
                            availableProjects: availableProjects,
                            onMoveToProject: onMoveToProject,
                            onMoveToFolder: onMoveToFolder,
                            enabledAssistants: enabledAssistants,
                            onMigrateAssistant: onMigrateAssistant,
                            onRefreshBacklog: column == .backlog ? onRefreshBacklog : nil,
                            onCardClicked: onCardClicked,
                            onColumnBackgroundClick: onColumnBackgroundClick
                        )
                        .id(column)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 52)
                .padding(.bottom, 16)
            }
            .onChange(of: store.state.selectedCardId) {
                // Scroll to the column containing the selected card
                guard let selectedId = store.state.selectedCardId else { return }
                let rootId = SubagentHierarchy.rootId(of: selectedId, in: store.state.links)
                if store.state.pinnedCards.contains(where: { $0.id == rootId }) {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo("channels", anchor: .leading)
                    }
                    return
                }
                for col in store.state.visibleColumns {
                    if store.state.cards(in: col).contains(where: { $0.id == rootId }) {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(col, anchor: .center)
                        }
                        break
                    }
                }
            }
        }
        // Error banner at bottom
        .overlay(alignment: .bottom) {
            if let error = store.state.error {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.app(.title3))
                        .foregroundStyle(.orange.opacity(0.7))
                    Text(error)
                        .font(.app(.body, weight: .medium))
                        .lineLimit(2)
                    Spacer()
                    Button("Dismiss") {
                        store.dispatch(.setError(nil))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: store.state.error != nil)
        // Empty board hint
        .overlay {
            if store.state.filteredCards.isEmpty && !store.state.isLoading {
                VStack(spacing: 12) {
                    if let projectPath = store.state.selectedProjectPath {
                        let name = store.state.configuredProjects.first(where: { $0.path == projectPath })?.name
                            ?? (projectPath as NSString).lastPathComponent
                        Text("No sessions yet for \(name)")
                            .font(.app(.title3))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No sessions found")
                            .font(.app(.title3))
                            .foregroundStyle(.secondary)
                    }
                    Text("Create a new task or start an assistant session to get going.")
                        .font(.app(.caption))
                        .foregroundStyle(.tertiary)

                    Button(action: onNewTask) {
                        Label("New Task  \(AppShortcut.newTask.displayString)", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { renamingPinnedCardId != nil },
            set: { if !$0 { renamingPinnedCardId = nil } }
        )) {
            if let cardId = renamingPinnedCardId,
               let card = store.state.filteredCards.first(where: { $0.id == cardId }) {
                RenameSessionDialog(
                    currentName: card.link.name ?? card.displayTitle,
                    isPresented: Binding(
                        get: { renamingPinnedCardId != nil },
                        set: { if !$0 { renamingPinnedCardId = nil } }
                    ),
                    onRename: { name in store.dispatch(.renameCard(cardId: cardId, name: name)) }
                )
            }
        }
    }

    private func pinnedCardView(
        for card: KanbanCodeCard,
        descendantCounts: [String: Int]
    ) -> CardView {
        CardView(
            card: card,
            isSelected: card.id == store.state.selectedCardId,
            onCopyConversationMarkdown: { onCopyConversationMarkdown(card.id) },
            subagentCount: descendantCounts[card.id] ?? 0,
            activeDirectSubagentCount: activeSubagentsByParent[card.id]?.count ?? 0,
            onShowSubagents: { onShowSubagents(card.id) },
            subagentsExpanded: !collapsedPinnedSubagentParents.contains(card.id),
            onToggleSubagents: { togglePinnedSubagents(card.id) },
            onSetPinned: { isPinned in onSetCardPinned(card.id, isPinned) },
            onSetSelfCompactContextThreshold: { threshold in
                onSetSelfCompactContextThreshold(card.id, threshold)
            },
            onSelect: {
                let newId = store.state.selectedCardId == card.id ? nil : card.id
                store.dispatch(.selectCard(cardId: newId))
                if newId != nil { onCardClicked(card.id) }
            },
            onStart: { onStartCard(card.id) },
            onResume: { onResumeCard(card.id) },
            onFork: { keepWorktree in onForkCard(card.id, keepWorktree) },
            onRenameRequest: { renamingPinnedCardId = card.id },
            onCopyResumeCmd: { onCopyResumeCmd(card.id) },
            onTrimSession: { onTrimSession(card.id) },
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

    private func visiblePinnedSubagents(for parentId: String) -> [SubagentHierarchyRow] {
        SubagentHierarchy.visibleDescendants(
            of: parentId,
            in: activeSubagentLinks,
            collapsedParentIds: collapsedPinnedSubagentParents
        )
    }

    private func togglePinnedSubagents(_ cardId: String) {
        if collapsedPinnedSubagentParents.contains(cardId) {
            collapsedPinnedSubagentParents.remove(cardId)
        } else {
            collapsedPinnedSubagentParents.insert(cardId)
        }
    }
}
