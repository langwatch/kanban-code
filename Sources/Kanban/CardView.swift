import SwiftUI
import KanbanCore

struct CardView: View {
    let card: KanbanCard
    let isSelected: Bool
    var onSelect: () -> Void = {}
    var onResume: () -> Void = {}
    var onFork: () -> Void = {}
    var onRename: () -> Void = {}
    var onCopyResumeCmd: () -> Void = {}
    var onArchive: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Title
            Text(card.displayTitle)
                .font(.system(.body, weight: .medium))
                .lineLimit(2)
                .foregroundStyle(.primary)

            // Project + branch
            HStack(spacing: 4) {
                if let projectName = card.projectName {
                    Label(projectName, systemImage: "folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let branch = card.link.worktreeBranch {
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)

            // Bottom row: time + status
            HStack {
                Text(card.relativeTime)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Spacer()

                if card.link.sessionNumber != nil {
                    Text("#\(card.link.sessionNumber!)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                statusIcon
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topTrailing) {
            if card.isActivelyWorking {
                ProgressView()
                    .controlSize(.small)
                    .padding(6)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
                .stroke(isSelected ? Color.accentColor.opacity(0.4) : Color.primary.opacity(0.06), lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .contextMenu {
            Button(action: onResume) {
                Label("Resume Session", systemImage: "play.fill")
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
            Divider()
            if let pr = card.link.githubPR {
                Button(action: {}) {
                    Label("Open PR #\(pr)", systemImage: "arrow.up.right.square")
                }
            }
            Divider()
            Button(action: onArchive) {
                Label("Archive", systemImage: "archivebox")
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch card.link.column {
        case .inProgress:
            Circle()
                .fill(.green)
                .frame(width: 8, height: 8)
        case .requiresAttention:
            Circle()
                .fill(.orange)
                .frame(width: 8, height: 8)
        case .inReview:
            Circle()
                .fill(.blue)
                .frame(width: 8, height: 8)
        case .done:
            Circle()
                .fill(.green.opacity(0.6))
                .frame(width: 8, height: 8)
        case .backlog:
            Circle()
                .fill(.secondary.opacity(0.5))
                .frame(width: 8, height: 8)
        case .allSessions:
            Circle()
                .fill(.tertiary)
                .frame(width: 6, height: 6)
        }
    }
}
