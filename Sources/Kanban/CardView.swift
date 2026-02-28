import SwiftUI
import KanbanCore

struct CardView: View {
    let card: KanbanCard
    let isSelected: Bool
    var onSelect: () -> Void = {}
    var onResume: () -> Void = {}
    var onFork: () -> Void = {}
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
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color(.controlBackgroundColor))
                .stroke(isSelected ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
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
            Image(systemName: "play.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .requiresAttention:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
        case .inReview:
            Image(systemName: "eye.circle.fill")
                .foregroundStyle(.blue)
                .font(.caption)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .backlog:
            Image(systemName: "tray.circle.fill")
                .foregroundStyle(.secondary)
                .font(.caption)
        case .allSessions:
            Image(systemName: "circle")
                .foregroundStyle(.tertiary)
                .font(.caption)
        }
    }
}
