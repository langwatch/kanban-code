import SwiftUI
import AppKit
import KanbanCodeCore

struct ListBoardView: View {
    var store: BoardStore
    @State private var dragState = DragState()
    var onStartCard: (String) -> Void = { _ in }
    var onResumeCard: (String) -> Void = { _ in }
    var onForkCard: (String) -> Void = { _ in }
    var onCopyResumeCmd: (String) -> Void = { _ in }
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
    var onDropCard: (String, KanbanCodeColumn) -> Void = { _, _ in }
    var canDropCard: (KanbanCodeCard, KanbanCodeColumn) -> Bool = { _, _ in true }
    var onNewTask: () -> Void = {}
    var onCardClicked: (String) -> Void = { _ in }
    var onRenameCard: (String, String) -> Void = { _, _ in } // (cardId, newName)
    var inSidebar: Bool = false
    @AppStorage("listBoardCollapsedColumns") private var collapsedColumnsRaw = ""

    private var sections: [ListBoardSection] {
        ListBoardSection.make(columns: store.state.visibleColumns) { column in
            store.state.cards(in: column)
        }
    }

    private var collapsedColumns: Set<KanbanCodeColumn> {
        get { ListSectionCollapseState.decode(collapsedColumnsRaw) }
        nonmutating set { collapsedColumnsRaw = ListSectionCollapseState.encode(newValue) }
    }

    var body: some View {
        listContent
        .overlay(alignment: .bottom) { errorOverlay }
        .animation(.easeInOut(duration: 0.25), value: store.state.error != nil)
        .overlay { emptyStateOverlay }
    }

    private var listContent: some View {
        ScrollViewReader { proxy in
            scrollView(proxy: proxy)
        }
    }

    private func scrollView(proxy: ScrollViewProxy) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(sections, id: \.column) { section in
                    sectionView(for: section)
                }
            }
            .padding(.top, inSidebar ? 0 : 52)
        }
        .onChange(of: store.state.selectedCardId) {
            guard let selectedId = store.state.selectedCardId else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(selectedId, anchor: .center)
            }
        }
    }

    private func sectionView(for section: ListBoardSection) -> some View {
        ListBoardSectionView(
            section: section,
            selectedCardId: store.state.selectedCardId,
            isCollapsed: collapsedColumns.contains(section.column),
            isRefreshingBacklog: store.state.isRefreshingBacklog,
            availableProjects: availableProjects,
            dragState: dragState,
            onSelectCard: handleCardSelection,
            onStartCard: onStartCard,
            onResumeCard: onResumeCard,
            onForkCard: onForkCard,
            onCopyResumeCmd: onCopyResumeCmd,
            onCleanupWorktree: onCleanupWorktree,
            canCleanupWorktree: canCleanupWorktree,
            onArchiveCard: onArchiveCard,
            onDeleteCard: onDeleteCard,
            onMoveToProject: onMoveToProject,
            onMoveToFolder: onMoveToFolder,
            enabledAssistants: enabledAssistants,
            onMigrateAssistant: onMigrateAssistant,
            onRefreshBacklog: onRefreshBacklog,
            onMoveCard: onDropCard,
            canDropCard: canDropCard,
            onReorderCard: { cardId, targetCardId, above in
                store.dispatch(.reorderCard(cardId: cardId, targetCardId: targetCardId, above: above))
            },
            onRenameCard: onRenameCard,
            onToggleCollapse: { toggleCollapse(for: section.column) }
        )
    }

    private func handleCardSelection(_ cardId: String) {
        let newId = store.state.selectedCardId == cardId ? nil : cardId
        store.dispatch(.selectCard(cardId: newId))
        if newId != nil { onCardClicked(cardId) }
    }

    private func toggleCollapse(for column: KanbanCodeColumn) {
        withAnimation(.easeInOut(duration: 0.2)) {
            var updated = collapsedColumns
            if updated.contains(column) {
                updated.remove(column)
            } else {
                updated.insert(column)
            }
            collapsedColumns = updated
        }
    }

    @ViewBuilder
    private var errorOverlay: some View {
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

    @ViewBuilder
    private var emptyStateOverlay: some View {
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
                Text("Create a new task or start a Claude session to get going.")
                    .font(.app(.caption))
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

private struct ListBoardSectionView: View {
    let section: ListBoardSection
    let selectedCardId: String?
    let isCollapsed: Bool
    let isRefreshingBacklog: Bool
    let availableProjects: [(name: String, path: String)]
    let dragState: DragState
    let onSelectCard: (String) -> Void
    let onStartCard: (String) -> Void
    let onResumeCard: (String) -> Void
    let onForkCard: (String) -> Void
    let onCopyResumeCmd: (String) -> Void
    let onCleanupWorktree: (String) -> Void
    let canCleanupWorktree: (String) -> Bool
    let onArchiveCard: (String) -> Void
    let onDeleteCard: (String) -> Void
    let onMoveToProject: (String, String) -> Void
    let onMoveToFolder: (String) -> Void
    let enabledAssistants: [CodingAssistant]
    let onMigrateAssistant: (String, CodingAssistant) -> Void
    let onRefreshBacklog: () -> Void
    let onMoveCard: (String, KanbanCodeColumn) -> Void
    let canDropCard: (KanbanCodeCard, KanbanCodeColumn) -> Bool
    let onReorderCard: (String, String, Bool) -> Void
    let onRenameCard: (String, String) -> Void
    let onToggleCollapse: () -> Void

    @State private var isTargeted = false
    @State private var cardFrames: [String: CGRect] = [:]

    private var isCurrentDropAllowed: Bool {
        guard let draggingCard = dragState.draggingCard else { return true }
        if dragState.sourceColumn == section.column {
            return true
        }
        return canDropCard(draggingCard, section.column)
    }

    var body: some View {
        Section {
            if !isCollapsed {
                sectionBody
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        } header: {
            ListSectionHeader(
                column: section.column,
                count: section.cards.count,
                isCollapsed: isCollapsed,
                isRefreshingBacklog: isRefreshingBacklog,
                onRefreshBacklog: section.column == .backlog ? onRefreshBacklog : nil,
                onToggleCollapse: onToggleCollapse
            )
            .overlay(alignment: .topTrailing) {
                if isTargeted, !isCurrentDropAllowed {
                    InvalidDropBadge()
                        .padding(10)
                }
            }
            .overlay(
                Rectangle()
                    .fill(
                        isTargeted
                            ? (isCurrentDropAllowed ? Color.accentColor.opacity(0.15) : Color.red.opacity(0.15))
                            : Color.clear
                    )
            )
            .onDrop(of: [.utf8PlainText], delegate: ListSectionDropDelegate(
                column: section.column,
                cardFrames: cardFrames,
                dragState: dragState,
                isTargeted: $isTargeted,
                canDropCard: canDropCard,
                onMoveCard: onMoveCard,
                onReorderCard: onReorderCard
            ))
        }
    }

    @ViewBuilder
    private var sectionBody: some View {
        if section.cards.isEmpty {
            HStack {
                Text("No cards")
                    .font(.app(.caption))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .overlay(
                Rectangle()
                    .fill(
                        isTargeted
                            ? (isCurrentDropAllowed ? Color.accentColor.opacity(0.15) : Color.red.opacity(0.15))
                            : Color.clear
                    )
            )
            .coordinateSpace(name: "list_section_\(section.column.rawValue)")
            .onPreferenceChange(CardFramePreference.self) { cardFrames = $0 }
            .onDrop(of: [.utf8PlainText], delegate: ListSectionDropDelegate(
                column: section.column,
                cardFrames: cardFrames,
                dragState: dragState,
                isTargeted: $isTargeted,
                canDropCard: canDropCard,
                onMoveCard: onMoveCard,
                onReorderCard: onReorderCard
            ))
        } else {
            VStack(spacing: 4) {
                ForEach(section.cards) { card in
                    if dragState.reorderTargetId == card.id && dragState.reorderAbove {
                        ReorderIndicator()
                    }
                    ListCardRowView(
                        card: card,
                        isSelected: card.id == selectedCardId,
                        onSelect: { onSelectCard(card.id) },
                        onStart: { onStartCard(card.id) },
                        onResume: { onResumeCard(card.id) },
                        onFork: { onForkCard(card.id) },
                        onCopyResumeCmd: { onCopyResumeCmd(card.id) },
                        onCleanupWorktree: { onCleanupWorktree(card.id) },
                        canCleanupWorktree: canCleanupWorktree(card.id),
                        onArchive: { onArchiveCard(card.id) },
                        onDelete: { onDeleteCard(card.id) },
                        availableProjects: availableProjects,
                        onMoveToProject: { projectPath in onMoveToProject(card.id, projectPath) },
                        onMoveToFolder: { onMoveToFolder(card.id) },
                        enabledAssistants: enabledAssistants,
                        onMigrateAssistant: { target in onMigrateAssistant(card.id, target) },
                        onRename: { name in onRenameCard(card.id, name) }
                    )
                    .opacity(dragState.draggingCard?.id == card.id ? 0.65 : 1)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: CardFramePreference.self,
                                value: [card.id: geo.frame(in: .named("list_section_\(section.column.rawValue)"))]
                            )
                        }
                    )
                    .onDrag {
                        dragState.draggingCard = card
                        dragState.sourceColumn = section.column
                        return NSItemProvider(object: card.id as NSString)
                    }
                    .id(card.id)
                    if dragState.reorderTargetId == card.id && !dragState.reorderAbove {
                        ReorderIndicator()
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
            .coordinateSpace(name: "list_section_\(section.column.rawValue)")
            .onPreferenceChange(CardFramePreference.self) { cardFrames = $0 }
            .onDrop(of: [.utf8PlainText], delegate: ListSectionDropDelegate(
                column: section.column,
                cardFrames: cardFrames,
                dragState: dragState,
                isTargeted: $isTargeted,
                canDropCard: canDropCard,
                onMoveCard: onMoveCard,
                onReorderCard: onReorderCard
            ))
        }
    }
}

private struct ListSectionHeader: View {
    let column: KanbanCodeColumn
    let count: Int
    let isCollapsed: Bool
    let isRefreshingBacklog: Bool
    let onRefreshBacklog: (() -> Void)?
    let onToggleCollapse: () -> Void

    var body: some View {
        Button(action: onToggleCollapse) {
            HStack(spacing: 8) {
                Circle()
                    .fill(column.accentColor)
                    .frame(width: 8, height: 8)

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

                Text("\(count)")
                    .font(.app(.caption))
                    .fontWeight(.medium)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.2)))
                    .foregroundStyle(.secondary)

                Image(systemName: "chevron.right")
                    .font(.app(size: 10, weight: .bold))
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

private struct ListSectionDropDelegate: DropDelegate {
    let column: KanbanCodeColumn
    let cardFrames: [String: CGRect]
    let dragState: DragState
    @Binding var isTargeted: Bool
    let canDropCard: (KanbanCodeCard, KanbanCodeColumn) -> Bool
    let onMoveCard: (String, KanbanCodeColumn) -> Void
    let onReorderCard: (String, String, Bool) -> Void

    private var isSameSection: Bool {
        dragState.sourceColumn == column
    }

    func dropEntered(info: DropInfo) {
        isTargeted = true
        updateReorderTarget(at: info.location)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateReorderTarget(at: info.location)
        guard let draggingCard = dragState.draggingCard else { return nil }
        if isSameSection || canDropCard(draggingCard, column) {
            return DropProposal(operation: .move)
        }
        return nil
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
        dragState.reorderTargetId = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            dragState.draggingCard = nil
            dragState.sourceColumn = nil
            dragState.reorderTargetId = nil
            isTargeted = false
        }

        guard let sourceCard = dragState.draggingCard else { return false }

        if isSameSection, let targetId = dragState.reorderTargetId, targetId != sourceCard.id {
            onReorderCard(sourceCard.id, targetId, dragState.reorderAbove)
            return true
        }

        guard let sourceColumn = dragState.sourceColumn, sourceColumn != column else { return false }
        guard canDropCard(sourceCard, column) else { return false }
        onMoveCard(sourceCard.id, column)
        return true
    }

    private func updateReorderTarget(at location: CGPoint) {
        guard isSameSection, let sourceCard = dragState.draggingCard else {
            dragState.reorderTargetId = nil
            return
        }

        for (cardId, frame) in cardFrames {
            guard cardId != sourceCard.id, frame.contains(location) else { continue }
            dragState.reorderTargetId = cardId
            dragState.reorderAbove = location.y < frame.midY
            return
        }
        dragState.reorderTargetId = nil
    }
}

private struct ListCardRowView: View {
    let card: KanbanCodeCard
    let isSelected: Bool
    var onSelect: () -> Void = {}
    var onStart: () -> Void = {}
    var onResume: () -> Void = {}
    var onFork: () -> Void = {}
    var onCopyResumeCmd: () -> Void = {}
    var onCleanupWorktree: () -> Void = {}
    var canCleanupWorktree: Bool = true
    var onArchive: () -> Void = {}
    var onDelete: () -> Void = {}
    var availableProjects: [(name: String, path: String)] = []
    var onMoveToProject: (String) -> Void = { _ in }
    var onMoveToFolder: () -> Void = {}
    var enabledAssistants: [CodingAssistant] = []
    var onMigrateAssistant: (CodingAssistant) -> Void = { _ in }
    var onRename: (String) -> Void = { _ in } // newName
    @State private var showRename = false
    @State private var renameText = ""

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                // Row 1: title + badge + time
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(card.displayTitle)
                        .font(.app(.subheadline))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if card.link.cardLabel != .session {
                        CardLabelBadge(label: card.link.cardLabel)
                    }

                    Spacer()

                    Text(card.relativeTime)
                        .font(.app(.caption))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                // Row 2: metadata badges
                HStack(spacing: 6) {
                    CardBadgesRow(card: card)

                    if let projectName = card.projectName {
                        Label(projectName, systemImage: "folder")
                            .font(.app(.caption2))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if let branch = card.link.worktreeLink?.branch {
                        Label(branch, systemImage: "arrow.triangle.branch")
                            .font(.app(.caption2))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            if card.showSpinner {
                ProgressView()
                    .controlSize(.small)
            } else if card.column == .backlog {
                Button(action: onStart) {
                    Image(systemName: "play.fill")
                        .font(.app(size: 10))
                        .foregroundStyle(Color.green.opacity(0.8))
                }
                .buttonStyle(.borderless)
                .help("Start task")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color(.controlBackgroundColor).opacity(0.4))
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture { onSelect() }
        .contextMenu {
            if card.column == .backlog {
                Button(action: onStart) {
                    Label("Start", systemImage: "play.fill")
                }
            }
            if card.column != .backlog {
                Button(action: onResume) {
                    Label("Resume Session", systemImage: "play.fill")
                }
            }
            Button(action: onFork) {
                Label("Fork Session", systemImage: "arrow.branch")
            }
            Button {
                renameText = card.link.name ?? card.displayTitle
                showRename = true
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button(action: onCopyResumeCmd) {
                Label("Copy Resume Command", systemImage: "doc.on.doc")
            }
            Divider()
            ForEach(card.link.prLinks, id: \.number) { pr in
                Button {
                    if let url = pr.url.flatMap({ URL(string: $0) }) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Open PR #\(pr.number)", systemImage: "arrow.up.right.square")
                }
            }
            if let issue = card.link.issueLink {
                Button {
                    if let url = issue.url.flatMap({ URL(string: $0) }) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Open Issue #\(issue.number)", systemImage: "arrow.up.right.square")
                }
            }
            if card.link.worktreeLink != nil, canCleanupWorktree {
                Divider()
                Button(role: .destructive, action: onCleanupWorktree) {
                    Label("Cleanup Worktree", systemImage: "trash")
                }
            }
            if card.link.sessionLink != nil {
                let currentPath = card.link.projectPath
                let otherProjects = availableProjects.filter { $0.path != currentPath }
                Divider()
                Menu {
                    ForEach(otherProjects, id: \.path) { project in
                        Button(project.name) {
                            onMoveToProject(project.path)
                        }
                    }
                    if !otherProjects.isEmpty {
                        Divider()
                    }
                    Button("Select Folder...") {
                        onMoveToFolder()
                    }
                } label: {
                    Label("Move to Project", systemImage: "folder.badge.arrow.forward")
                }
            }
            if card.link.sessionLink != nil {
                let migrationTargets = enabledAssistants.filter { $0 != card.link.effectiveAssistant }
                if !migrationTargets.isEmpty {
                    Divider()
                    Menu {
                        ForEach(migrationTargets, id: \.rawValue) { target in
                            Button(target.displayName) {
                                onMigrateAssistant(target)
                            }
                        }
                    } label: {
                        Label("Migrate to Assistant", systemImage: "arrow.triangle.swap")
                    }
                }
            }
            Divider()
            if card.link.manuallyArchived {
                if card.link.source != .githubIssue {
                    Button(role: .destructive, action: onDelete) {
                        Label("Delete Card", systemImage: "trash")
                    }
                }
            } else {
                Button(action: onArchive) {
                    Label("Archive", systemImage: "archivebox")
                }
            }
        }
        .alert("Rename", isPresented: $showRename) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                onRename(renameText.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }
}

extension KanbanCodeColumn {
    var accentColor: Color {
        switch self {
        case .backlog: .gray
        case .inProgress: .green
        case .waiting: .orange
        case .inReview: .blue
        case .done: .purple
        case .allSessions: .secondary
        }
    }
}
