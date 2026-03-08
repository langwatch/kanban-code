import SwiftUI
import AppKit
import KanbanCodeCore

struct ListBoardView: View {
    var store: BoardStore
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
    var onRefreshBacklog: () -> Void = {}
    var onNewTask: () -> Void = {}
    var onCardClicked: (String) -> Void = { _ in }
    @SceneStorage("listBoardCollapsedColumns") private var collapsedColumnsRaw = ""

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
            LazyVStack(alignment: .leading, spacing: 18, pinnedViews: [.sectionHeaders]) {
                ForEach(sections, id: \.column) { section in
                    sectionView(for: section)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 52)
            .padding(.bottom, 16)
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
            onRefreshBacklog: onRefreshBacklog,
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
    let onRefreshBacklog: () -> Void
    let onToggleCollapse: () -> Void

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
        }
    }

    @ViewBuilder
    private var sectionBody: some View {
        if section.cards.isEmpty {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.primary.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.secondary.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                )
                .frame(height: 52)
                .overlay {
                    Text("No cards")
                        .font(.app(.caption))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        } else {
            VStack(spacing: 6) {
                ForEach(section.cards) { card in
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
                        onMoveToProject: { projectPath in onMoveToProject(card.id, projectPath) }
                    )
                    .id(card.id)
                }
            }
            .padding(8)
            .glassColumn()
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
        HStack(spacing: 0) {
            Button(action: onToggleCollapse) {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.app(size: 10, weight: .bold))
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        .foregroundStyle(.secondary)

                    Circle()
                        .fill(column.accentColor)
                        .frame(width: 8, height: 8)

                    Text(column.displayName)
                        .font(.app(.headline))
                        .foregroundStyle(.primary)

                    Text("\(count)")
                        .font(.app(.caption))
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.16)))
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

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
                .padding(.leading, 10)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
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

    private var supportingText: String? {
        let candidates = [
            card.link.issueLink?.title,
            card.link.prLink?.title,
            card.link.promptBody,
        ]
        return candidates.first(where: { text in
            guard let text, !text.isEmpty else { return false }
            return text != card.displayTitle
        }) ?? nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(card.column.accentColor)
                .frame(width: 9, height: 9)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(card.displayTitle)
                        .font(.app(.body, weight: .medium))
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

                if let supportingText {
                    Text(supportingText)
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 6) {
                    if let projectName = card.projectName {
                        Label(projectName, systemImage: "folder")
                            .font(.app(.caption))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if let branch = card.link.worktreeLink?.branch {
                        Label(branch, systemImage: "arrow.triangle.branch")
                            .font(.app(.caption))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if card.link.cardLabel == .session {
                        AssistantIcon(assistant: card.link.effectiveAssistant)
                            .frame(width: CGFloat(13).scaled, height: CGFloat(13).scaled)
                            .foregroundStyle(Color.primary.opacity(0.4))
                    }

                    if let tmux = card.link.tmuxLink {
                        HStack(spacing: 2) {
                            Image(systemName: "terminal")
                                .font(.app(.caption2))
                            if tmux.terminalCount > 1 {
                                Text(verbatim: "\(tmux.terminalCount)")
                                    .font(.app(size: 9, weight: .bold))
                            }
                        }
                        .foregroundStyle(.green)
                    }

                    if let primary = card.link.prLink {
                        let totalThreads = card.link.prLinks.compactMap(\.unresolvedThreads).reduce(0, +)
                        PRBadge(status: card.link.worstPRStatus, prNumber: primary.number, unresolvedThreads: totalThreads)
                    }

                    if card.isRateLimited {
                        RateLimitBadge()
                    }

                    if let issue = card.link.issueLink {
                        HStack(spacing: 2) {
                            Image(systemName: "circle.circle")
                                .font(.app(.caption2))
                            Text(verbatim: "\(issue.number)")
                                .font(.app(.caption2))
                        }
                        .foregroundStyle(.secondary)
                    }

                    if card.link.isRemote {
                        Image(systemName: "cloud")
                            .font(.app(.caption2))
                            .foregroundStyle(.teal)
                    }
                }
            }

            if card.showSpinner {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 2)
            } else if card.column == .backlog {
                Button(action: onStart) {
                    Image(systemName: "play.fill")
                        .font(.app(size: 10))
                        .foregroundStyle(Color.green.opacity(0.8))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(Color.green.opacity(0.08), in: Capsule())
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.borderless)
                .help("Start task")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.accentColor.opacity(0.32) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
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
            if !availableProjects.isEmpty {
                let currentPath = card.link.projectPath
                let otherProjects = availableProjects.filter { $0.path != currentPath }
                if !otherProjects.isEmpty {
                    Divider()
                    Menu {
                        ForEach(otherProjects, id: \.path) { project in
                            Button(project.name) {
                                onMoveToProject(project.path)
                            }
                        }
                    } label: {
                        Label("Move to Project", systemImage: "folder.badge.arrow.forward")
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
    }
}

private extension KanbanCodeColumn {
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
