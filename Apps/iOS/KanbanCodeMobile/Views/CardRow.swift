import SwiftUI
import KanbanCodeRemoteKit

/// Green while live, pulsing blue while the assistant is in a turn, grey otherwise.
struct StatusDot: View {
    let card: RemoteCard
    var size: CGFloat = 9
    /// The card's machine cannot be reached, so its state is unknown.
    var unknown = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay {
                if card.isBusy && !unknown {
                    Circle().stroke(color.opacity(0.4), lineWidth: 3)
                        .phaseAnimator([false, true]) { view, on in
                            view.scaleEffect(on ? 1.9 : 1).opacity(on ? 0 : 1)
                        } animation: { _ in .easeOut(duration: 1.2) }
                }
            }
            .accessibilityLabel(label)
    }

    private var color: Color {
        if unknown { return .gray.opacity(0.6) }
        if card.sessionStatus?.kind == .failed { return .red }
        if card.pausedLine() != nil { return .orange }
        if card.isBusy { return .blue }
        if card.isLive { return .green }
        return .gray.opacity(0.6)
    }

    private var label: String {
        if unknown { return "Machine offline" }
        if card.sessionStatus?.kind == .moving { return "Moving" }
        if card.sessionStatus?.kind == .failed { return "Failed to start" }
        if let paused = card.pausedLine() { return paused }
        if card.isBusy { return "Working" }
        if card.isLive { return "Live" }
        return "Not running"
    }
}

struct CardRow: View {
    let card: RemoteCard
    /// Names the card's column, for rows outside their column (the Live section).
    var showsColumn = false
    /// The machine that runs the card, shown when there are several.
    var machine: String? = nil
    /// That machine cannot be reached: the card shows as last seen.
    var machineOffline = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StatusDot(card: card, unknown: machineOffline)
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

    /// Project, machine and branch. The project stays whole; the machine
    /// and then the branch truncate.
    @ViewBuilder private var meta: some View {
        let project = card.projectName.flatMap { $0.isEmpty ? nil : $0 }
        let branch = card.branch.flatMap { $0.isEmpty ? nil : $0 }
        if project != nil || branch != nil || machine != nil {
            HStack(spacing: 8) {
                if let project {
                    Label(project, systemImage: "folder")
                        .layoutPriority(2)
                }
                if let machine {
                    MachineLabel(name: machine, offline: machineOffline)
                        .layoutPriority(1)
                }
                if let branch {
                    Label(branch, systemImage: "arrow.triangle.branch")
                }
            }
            .labelStyle(CompactLabelStyle())
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    /// Chips under the title. They never make the row wider than the list:
    /// PR chips collapse to "+N".
    private var badges: some View {
        ViewThatFits(in: .horizontal) {
            badgeRow(prLimit: 2)
            badgeRow(prLimit: 1)
            badgeRow(prLimit: 0)
        }
    }

    private func badgeRow(prLimit: Int) -> some View {
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
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(.secondary)
            }
            if card.pausedLine() != nil {
                Label("Usage limit", systemImage: "pause.circle.fill")
                    .labelStyle(CompactLabelStyle())
                    .font(.caption2)
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(.orange)
            }
            if card.queuedPromptCount > 0 {
                Label("\(card.queuedPromptCount) queued", systemImage: "tray.full")
                    .labelStyle(CompactLabelStyle())
                    .font(.caption2)
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
            PRBadges(prs: card.prs, limit: prLimit)
        }
    }
}

/// The machine a card runs on, in the grey of the project and branch,
/// with "offline" while it cannot be reached. Truncates with an ellipsis.
struct MachineLabel: View {
    let name: String
    var offline = false

    var body: some View {
        Label {
            Text(offline ? "\(name), offline" : name)
                .truncationMode(.tail)
        } icon: {
            Image(systemName: Self.icon(for: name))
        }
        .accessibilityElement(children: .combine)
    }

    /// A laptop for a Mac, a server for anything else.
    static func icon(for name: String) -> String {
        name.localizedCaseInsensitiveContains("mac") ? "laptopcomputer" : "server.rack"
    }
}

/// A master's name and whether it can be reached: "Offline since 10:32".
struct MachineStatusLine: View {
    let master: BoardModel

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(master.machineName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Text(Self.status(master))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch master.link {
        case .live, .offline: .green
        case .connecting: .yellow
        case .reconnecting: .gray
        case .refused: .red
        }
    }

    static func status(_ master: BoardModel) -> String {
        switch master.link {
        case .live, .offline:
            return "Online"
        case .refused:
            return "Refused this phone. Pair it again."
        case .connecting, .reconnecting:
            guard let since = master.offlineSince else { return "Connecting" }
            let cards = master.board == nil ? "" : ", cards as last seen"
            return "Offline since \(since.offlineSinceText)\(cards)"
        }
    }
}

extension Date {
    /// "22:41" today, "Mon 22:41" this week, then a date.
    var offlineSinceText: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) { return formatted(date: .omitted, time: .shortened) }
        if let days = calendar.dateComponents([.day], from: self, to: .now).day, days < 7 {
            return formatted(.dateTime.weekday(.abbreviated).hour().minute())
        }
        return formatted(.dateTime.month(.abbreviated).day().hour().minute())
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

/// The newest PRs of a card, at most two, then "+N" for the rest.
///
/// No ForEach here: while a row's status dot pulses, SwiftUI lays the row
/// out on its async render thread and calls ForEach content closures there.
/// Those closures are main-actor isolated in this target, so the runtime
/// isolation check traps (EXC_BREAKPOINT in `closure #1 in closure #2 in
/// PRBadges.body.getter`).
struct PRBadges: View {
    let prs: [RemotePR]
    /// 0, 1 or 2.
    var limit = 2
    var linked = false

    var body: some View {
        let shown = Self.shown(prs, limit: limit)
        HStack(spacing: 4) {
            if let first = shown.first { badge(first) }
            if shown.count > 1 { badge(shown[1]) }
            if prs.count > shown.count {
                Text(verbatim: "+\(prs.count - shown.count)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
    }

    /// The newest `limit` PRs, at most two.
    static func shown(_ prs: [RemotePR], limit: Int) -> [RemotePR] {
        Array(prs.sorted { $0.number > $1.number }.prefix(min(max(limit, 0), 2)))
    }

    @ViewBuilder private func badge(_ pr: RemotePR) -> some View {
        if linked, let url = pr.url.flatMap(URL.init(string:)) {
            Link(destination: url) { PRBadge(pr: pr) }
        } else {
            PRBadge(pr: pr)
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
