import SwiftUI
import KanbanCodeCore
import KanbanCodeRemoteKit

extension Notification.Name {
    /// Shows the list of every open attention request.
    static let kanbanCodeShowAttentionList = Notification.Name("kanbanCodeShowAttentionList")
}

/// The "decisions waiting on you" row at the top of the board sidebar,
/// shown only while requests are open. One request opens its detail sheet,
/// several open the list.
struct AttentionSidebarBanner: View {
    let summary: AttentionBannerSummary

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Image(systemName: "bell.badge.fill")
                    .font(.app(.body))
                    .foregroundStyle(.orange)
                Text(summary.title)
                    .font(.app(.body, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.app(.caption, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.orange.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.orange.opacity(0.3), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(summary.count == 1 ? "Open the request" : "Open the list of requests")
        .accessibilityIdentifier("attentionBanner")
    }

    private func open() {
        switch summary.target {
        case .request(let id):
            KanbanCodeLog.info("attention", "Sidebar banner opened \(id)")
            NotificationCenter.default.post(name: .kanbanCodeShowAttention, object: nil, userInfo: ["id": id])
        case .list(let ids):
            KanbanCodeLog.info("attention", "Sidebar banner opened the list of \(ids.count) requests")
            NotificationCenter.default.post(name: .kanbanCodeShowAttentionList, object: nil)
        }
    }
}

/// Every open attention request, oldest first. Picking one shows its
/// details and answers in place; closing them comes back to the list.
struct AttentionListSheet: View {
    let store: BoardStore
    /// Keeps the shown request up after a refusal, for the note.
    let onNoting: (String?) -> Void
    let onClose: () -> Void
    @State private var selectedId: String?
    @State private var notingId: String?

    private var open: [AttentionRequest] { store.state.openAttentionRequests }

    var body: some View {
        Group {
            if let id = selectedId, let request = store.state.attentionRequests[id], request.isOpen || notingId == id {
                AttentionDetailSheet(
                    request: request,
                    cardName: AttentionListSheet.cardName(request, in: store.state),
                    onNoting: { noting in
                        notingId = noting ? id : nil
                        onNoting(notingId)
                    },
                    onClose: { back() }
                )
            } else {
                AttentionRequestList(
                    requests: open,
                    cardName: { AttentionListSheet.cardName($0, in: store.state) },
                    onPick: { selectedId = $0 },
                    onClose: onClose
                )
            }
        }
        .onChange(of: open.map(\.id)) {
            // A request answered elsewhere leaves its details for the list.
            if let id = selectedId, id != notingId, store.state.attentionRequests[id]?.isOpen != true {
                back()
            }
        }
    }

    private func back() {
        selectedId = nil
        notingId = nil
        onNoting(nil)
        if open.isEmpty { onClose() }
    }

    static func cardName(_ request: AttentionRequest, in state: AppState) -> String? {
        request.cardId.flatMap { id in state.cards.first { $0.id == id }?.displayTitle }
    }
}

/// The rows of `AttentionListSheet`, apart from the store for previews.
struct AttentionRequestList: View {
    let requests: [AttentionRequest]
    let cardName: (AttentionRequest) -> String?
    let onPick: (String) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "bell.badge.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                Text(AttentionBannerSummary(open: requests)?.title ?? "No decisions waiting on you")
                    .font(.title3.weight(.semibold))
            }

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(requests, id: \.id) { request in
                        row(request)
                    }
                }
            }
            .frame(maxHeight: 380)

            HStack {
                Spacer()
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func row(_ request: AttentionRequest) -> some View {
        let name = cardName(request)
        let title = AttentionCopy.notification(for: request, cardName: name).title
        // The title names the card already for most kinds.
        let subtitle = name.map { title.contains($0) ? Self.age(request.createdAt) : "\($0) · \(Self.age(request.createdAt))" }
            ?? "No card · \(Self.age(request.createdAt))"
        return Button { onPick(request.id) } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: Self.symbol(request.kind))
                    .font(.app(.body))
                    .foregroundStyle(.tint)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.app(.body, weight: .medium))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle)
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.app(.caption, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    static func symbol(_ kind: AttentionRequest.Kind) -> String {
        switch kind {
        case .question: "questionmark.bubble"
        case .planApproval: "list.bullet.clipboard"
        case .permission: "hand.raised"
        case .vaultApproval: "key"
        }
    }

    static func age(_ date: Date, now: Date = Date()) -> String {
        let secs = now.timeIntervalSince(date)
        switch secs {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(secs / 60))m ago"
        case ..<86400: return "\(Int(secs / 3600))h ago"
        default: return "\(Int(secs / 86400))d ago"
        }
    }
}
