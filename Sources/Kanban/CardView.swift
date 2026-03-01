import SwiftUI
import AppKit
import KanbanCore

struct CardView: View {
    let card: KanbanCard
    let isSelected: Bool
    var onSelect: () -> Void = {}
    var onStart: () -> Void = {}
    var onResume: () -> Void = {}
    var onFork: () -> Void = {}
    var onRename: () -> Void = {}
    var onCopyResumeCmd: () -> Void = {}
    var onCleanupWorktree: () -> Void = {}
    var onArchive: () -> Void = {}
    var onDelete: () -> Void = {}
    var availableProjects: [(name: String, path: String)] = []
    var onMoveToProject: (String) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Title
            Text(card.displayTitle)
                .font(.system(.body, weight: .medium))
                .lineLimit(2)
                .foregroundStyle(.primary)

            // Project + branch + link icons
            HStack(spacing: 4) {
                if let projectName = card.projectName {
                    Label(projectName, systemImage: "folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let branch = card.link.worktreeLink?.branch {
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)

            // Bottom row: badge + time + link indicators
            HStack(spacing: 6) {
                if card.link.cardLabel == .session {
                    ClawdIcon()
                        .frame(width: 14, height: 14)
                        .opacity(0.4)
                } else {
                    CardLabelBadge(label: card.link.cardLabel)
                }

                Text(card.relativeTime)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Spacer()

                // Tmux indicator (green when attached, shows count for 2+)
                if let tmux = card.link.tmuxLink {
                    HStack(spacing: 2) {
                        Image(systemName: "terminal")
                            .font(.caption2)
                            .foregroundStyle(.green)
                        if tmux.terminalCount > 1 {
                            Text(verbatim: "\(tmux.terminalCount)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.green)
                        }
                    }
                }

                // PR badge(s) — worst status across all PRs
                if let primary = card.link.prLink {
                    PRBadge(status: card.link.worstPRStatus, prNumber: primary.number)
                    if card.link.prLinks.count > 1 {
                        Text(verbatim: "+\(card.link.prLinks.count - 1)")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    let totalThreads = card.link.prLinks.compactMap(\.unresolvedThreads).reduce(0, +)
                    if totalThreads > 0 {
                        HStack(spacing: 1) {
                            Image(systemName: "bubble.left.and.exclamationmark.bubble.right")
                                .font(.system(size: 8))
                            Text(verbatim: "\(totalThreads)")
                                .font(.system(size: 9, weight: .medium))
                        }
                        .foregroundStyle(.orange)
                    }
                }

                // Issue indicator
                if let issue = card.link.issueLink {
                    HStack(spacing: 2) {
                        Image(systemName: "circle.circle")
                            .font(.caption2)
                        Text(verbatim: "\(issue.number)")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }

                // Remote execution indicator
                if card.link.isRemote {
                    Image(systemName: "cloud")
                        .font(.caption2)
                        .foregroundStyle(.teal)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topTrailing) {
            if card.isActivelyWorking {
                ProgressView()
                    .controlSize(.small)
                    .padding(6)
            } else if card.column == .backlog {
                Button(action: onStart) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.green.opacity(0.8))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(Color.green.opacity(0.08), in: Capsule())
                        .background(.ultraThinMaterial, in: Capsule())
                        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                }
                .buttonStyle(.borderless)
                .help("Start task")
                .padding(8)
            }
        }
        .background(
            isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 8)
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
            Button(action: onRename) {
                Label("Rename", systemImage: "pencil")
            }
            Button(action: onCopyResumeCmd) {
                Label("Copy Resume Command", systemImage: "doc.on.doc")
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(card.id, forType: .string)
            } label: {
                Label("Copy Card ID", systemImage: "number")
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
            if card.link.worktreeLink != nil {
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
                // Already archived — offer delete (but not for pure issues that would reappear)
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

// MARK: - Clawd Icon

/// Loads the clawd mascot PNG from the SPM bundle resource.
struct ClawdIcon: View {
    private let image: NSImage? = {
        guard let url = Bundle.module.url(forResource: "clawd@2x", withExtension: "png", subdirectory: "Resources")
                ?? Bundle.module.url(forResource: "clawd", withExtension: "png", subdirectory: "Resources") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }()

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
        }
    }
}

// MARK: - Card Label Badge

struct CardLabelBadge: View {
    let label: CardLabel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(label.rawValue)
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .foregroundStyle(colorScheme == .dark ? .black : .white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color, in: Capsule())
    }

    private var color: Color {
        switch label {
        case .session: .orange
        case .worktree: .green
        case .issue: .blue
        case .pr: .purple
        case .task: .gray
        }
    }
}
