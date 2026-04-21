import SwiftUI
import KanbanCodeCore

struct BoardView: View {
    var store: BoardStore
    @State private var dragState = DragState()
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
    var onDiscoverCard: (String) -> Void = { _ in }
    var onCleanupWorktree: (String) -> Void = { _ in }
    var canCleanupWorktree: (String) -> Bool = { _ in true }
    var onArchiveCard: (String) -> Void = { _ in }
    var onDeleteCard: (String) -> Void = { _ in }
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

    @ViewBuilder
    private var channelsPseudoColumn: some View {
        let channels = store.state.channels
        if !channels.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
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
            .padding(.horizontal, 6)
            .frame(width: 240, alignment: .top)
        }
    }

    private var boardContent: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .top, spacing: 6) {
                    channelsPseudoColumn
                    ForEach(store.state.visibleColumns, id: \.self) { column in
                        DroppableColumnView(
                            column: column,
                            cards: store.state.cards(in: column),
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
                for col in store.state.visibleColumns {
                    if store.state.cards(in: col).contains(where: { $0.id == selectedId }) {
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
    }
}
