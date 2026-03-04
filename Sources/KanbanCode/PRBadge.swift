import SwiftUI
import KanbanCodeCore

/// Displays a PR number in a colored pill badge.
/// When status is known, the color reflects the status. When nil, uses purple.
struct PRBadge: View {
    let status: PRStatus?
    let prNumber: Int
    var unresolvedThreads: Int = 0

    var body: some View {
        HStack(spacing: 3) {
            if status == .approved {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
            }
            Text(verbatim: "#\(prNumber)")
                .font(.system(size: 10, weight: .medium, design: .rounded))
            if unresolvedThreads > 0 {
                HStack(spacing: 1) {
                    Image(systemName: "bubble.left")
                        .font(.system(size: 7))
                    Text(verbatim: "\(unresolvedThreads)")
                        .font(.system(size: 9, weight: .medium))
                }
                .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Capsule().fill(badgeColor.opacity(0.15)))
        .foregroundStyle(badgeColor)
    }

    private var badgeColor: Color {
        guard let status else { return .purple }
        return switch status {
        case .failing: .red
        case .unresolved: .orange
        case .changesRequested: .orange
        case .reviewNeeded: .blue
        case .pendingCI: .yellow
        case .approved: .green
        case .merged: .purple
        case .closed: .secondary
        }
    }
}
