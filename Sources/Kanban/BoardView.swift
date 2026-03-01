import SwiftUI
import KanbanCore

struct BoardView: View {
    var store: BoardStore
    var onStartCard: (String) -> Void = { _ in }
    var onResumeCard: (String) -> Void = { _ in }
    var onForkCard: (String) -> Void = { _ in }
    var onCopyResumeCmd: (String) -> Void = { _ in }
    var onCleanupWorktree: (String) -> Void = { _ in }
    var onDeleteCard: (String) -> Void = { _ in }
    var availableProjects: [(name: String, path: String)] = []
    var onMoveToProject: (String, String) -> Void = { _, _ in }
    var onRefreshBacklog: () -> Void = {}

    var onNewTask: () -> Void = {}

    var body: some View {
        boardContent
    }

    private var boardContent: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .top, spacing: 6) {
                    ForEach(store.state.visibleColumns, id: \.self) { column in
                        DroppableColumnView(
                            column: column,
                            cards: store.state.cards(in: column),
                            selectedCardId: Binding(
                                get: { store.state.selectedCardId },
                                set: { store.dispatch(.selectCard(cardId: $0)) }
                            ),
                            isRefreshingBacklog: store.state.isRefreshingBacklog,
                            onMoveCard: { cardId, targetColumn in
                                store.dispatch(.moveCard(cardId: cardId, to: targetColumn))
                            },
                            onRenameCard: { cardId, name in
                                store.dispatch(.renameCard(cardId: cardId, name: name))
                            },
                            onArchiveCard: { cardId in
                                store.dispatch(.archiveCard(cardId: cardId))
                            },
                            onStartCard: onStartCard,
                            onResumeCard: onResumeCard,
                            onForkCard: onForkCard,
                            onCopyResumeCmd: onCopyResumeCmd,
                            onCleanupWorktree: onCleanupWorktree,
                            onDeleteCard: onDeleteCard,
                            availableProjects: availableProjects,
                            onMoveToProject: onMoveToProject,
                            onRefreshBacklog: column == .backlog ? onRefreshBacklog : nil
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
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .lineLimit(2)
                    Spacer()
                    Button("Dismiss") { store.dispatch(.setError(nil)) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: store.state.error != nil)
        // Empty board hint
        .overlay {
            if store.state.filteredCards.isEmpty && !store.state.isLoading {
                VStack(spacing: 12) {
                    if let projectPath = store.state.selectedProjectPath {
                        let name = store.state.configuredProjects.first(where: { $0.path == projectPath })?.name
                            ?? (projectPath as NSString).lastPathComponent
                        Text("No sessions yet for \(name)")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No sessions found")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    Text("Create a new task or start a Claude session to get going.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                    Button(action: onNewTask) {
                        Label("New Task", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
    }
}
