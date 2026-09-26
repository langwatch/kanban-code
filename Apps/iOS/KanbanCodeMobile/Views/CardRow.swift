import SwiftUI
import KanbanCodeRemoteKit

/// Green while live, pulsing blue while the assistant is in a turn, grey otherwise.
struct StatusDot: View {
    let card: RemoteCard
    var size: CGFloat = 9

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay {
                if card.isBusy {
                    Circle().stroke(color.opacity(0.4), lineWidth: 3)
                        .phaseAnimator([false, true]) { view, on in
                            view.scaleEffect(on ? 1.9 : 1).opacity(on ? 0 : 1)
                        } animation: { _ in .easeOut(duration: 1.2) }
                }
            }
            .accessibilityLabel(label)
    }

    private var color: Color {
        if card.isBusy { return .blue }
        if card.isLive { return .green }
        return .gray.opacity(0.6)
    }

    private var label: String {
        if card.isBusy { return "Working" }
        if card.isLive { return "Live" }
        return "Not running"
    }
}

struct CardRow: View {
    let card: RemoteCard
    /// Names the card's column, for rows outside their column (the Live section).
    var showsColumn = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StatusDot(card: card)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 4) {
                Text(card.title.isEmpty ? "Untitled" : card.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                meta
                badges
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var meta: some View {
        let parts = [card.projectName, card.branch].compactMap { $0 }.filter { !$0.isEmpty }
        if !parts.isEmpty {
            HStack(spacing: 8) {
                if let project = card.projectName {
                    Label(project, systemImage: "folder")
                        .layoutPriority(1)
                }
                if let branch = card.branch, !branch.isEmpty {
                    Label(branch, systemImage: "arrow.triangle.branch")
                }
            }
            .labelStyle(CompactLabelStyle())
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    private var badges: some View {
        HStack(spacing: 8) {
            if showsColumn {
                Text(card.column.displayName)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color(.tertiarySystemFill), in: Capsule())
            }
            if let date = card.lastActivity {
                Text(date.relativeShort)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if card.queuedPromptCount > 0 {
                Label("\(card.queuedPromptCount) queued", systemImage: "tray.full")
                    .labelStyle(CompactLabelStyle())
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
            PRBadges(prs: card.prs)
        }
    }
}

struct PRBadge: View {
    let pr: RemotePR

    var body: some View {
        Text(verbatim: "#\(pr.number)")
            .font(.caption2.monospacedDigit().weight(.semibold))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
            .accessibilityLabel("PR \(pr.number), \(pr.status ?? "unknown")")
    }

    private var color: Color {
        switch pr.status {
        case "merged": .purple
        case "closed": .red
        case "draft": .gray
        default: .green
        }
    }
}

/// The newest PRs of a card, then "+N" for the rest.
struct PRBadges: View {
    let prs: [RemotePR]
    var limit = 2
    var linked = false

    var body: some View {
        let shown = Array(prs.sorted { $0.number > $1.number }.prefix(limit))
        HStack(spacing: 4) {
            ForEach(shown, id: \.number) { pr in
                if linked, let url = pr.url.flatMap(URL.init(string:)) {
                    Link(destination: url) { PRBadge(pr: pr) }
                } else {
                    PRBadge(pr: pr)
                }
            }
            if prs.count > shown.count {
                Text(verbatim: "+\(prs.count - shown.count)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
    }
}

struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

extension Date {
    /// "now", "5m", "3h", "2d", then a short date.
    var relativeShort: String {
        let seconds = Date.now.timeIntervalSince(self)
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        case ..<(86_400 * 7): return "\(Int(seconds / 86_400))d"
        default: return formatted(.dateTime.month(.abbreviated).day())
        }
    }
}
