import SwiftUI
import KanbanCodeCore
import KanbanCodeRemoteKit

extension Notification.Name {
    /// Shows the detail sheet of an attention request; userInfo["id"].
    static let kanbanCodeShowAttention = Notification.Name("kanbanCodeShowAttention")
}

/// Presents the detail sheet of the attention request a notification click
/// or the attention center names, over the board. Requests arriving while a
/// sheet is up wait in line, one sheet at a time. A request answered
/// elsewhere, withdrawn or timed out closes its sheet and the next open one
/// follows.
struct AttentionDetailPresenter: ViewModifier {
    let store: BoardStore
    @State private var shownId: String?
    @State private var waiting: [String] = []

    private func isOpen(_ id: String) -> Bool {
        store.state.attentionRequests[id]?.isOpen == true
    }

    private var openIds: [String] {
        store.state.openAttentionRequests.map(\.id)
    }

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .kanbanCodeShowAttention).receive(on: RunLoop.main)) { note in
                guard let id = note.userInfo?["id"] as? String, isOpen(id) else { return }
                if shownId == nil {
                    shownId = id
                } else {
                    waiting = AttentionSheetQueue.adding(id, to: waiting, shown: shownId)
                }
            }
            .onChange(of: openIds) {
                guard let shown = shownId, !isOpen(shown) else {
                    waiting = waiting.filter(isOpen)
                    return
                }
                KanbanCodeLog.info("attention", "Closed the detail sheet of \(shown): settled or gone")
                shownId = nil
            }
            .onChange(of: shownId) {
                guard shownId == nil, !waiting.isEmpty else { return }
                Task { @MainActor in
                    // Lets the closing sheet finish before the next one opens.
                    try? await Task.sleep(for: .milliseconds(350))
                    guard shownId == nil else { return }
                    shownId = AttentionSheetQueue.current(shown: nil, waiting: &waiting, isOpen: isOpen)
                }
            }
            .sheet(item: Binding(
                get: { shownId.map(AttentionSheetTarget.init) },
                set: { shownId = $0?.id }
            )) { target in
                if let request = store.state.attentionRequests[target.id], request.isOpen {
                    AttentionDetailSheet(
                        request: request,
                        cardName: request.cardId.flatMap { id in store.state.cards.first { $0.id == id }?.displayTitle },
                        waitingAfter: AttentionSheetQueue.waitingCount(waiting, isOpen: isOpen),
                        onClose: { shownId = nil }
                    )
                } else {
                    // Only for the moment before the state change closes it.
                    SettledAttentionSheet(onClose: { shownId = nil })
                }
            }
    }
}

/// Stands in for a request that was settled while its sheet opened.
private struct SettledAttentionSheet: View {
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("This request was already answered or withdrawn.")
            HStack {
                Spacer()
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear(perform: onClose)
    }
}

private struct AttentionSheetTarget: Identifiable {
    let id: String
}

/// Everything about one attention request, with its answers: for a vault
/// request the card, the secrets, the command, why the vault asks and the
/// lease it would grant.
struct AttentionDetailSheet: View {
    let request: AttentionRequest
    let cardName: String?
    var waitingAfter: Int = 0
    let onClose: () -> Void
    @State private var busy: String?
    /// Why the last answer was not taken.
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: request.kind == .vaultApproval ? "key.fill" : "bell.badge")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text(AttentionCopy.notification(for: request, cardName: cardName).title)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 8) {
                    ForEach(rows, id: \.self) { row in
                        GridRow {
                            Text(row.label)
                                .foregroundStyle(.secondary)
                                .gridColumnAlignment(.trailing)
                            Text(row.value)
                                .font(row.monospaced ? .system(.body, design: .monospaced) : .body)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 380)

            if waitingAfter > 0 {
                Label("\(waitingAfter) more request\(waitingAfter == 1 ? "" : "s") waiting after this one", systemImage: "tray.full")
                    .foregroundStyle(.secondary)
            }

            if let failure {
                Label("Not sent: \(failure)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                ForEach(Array(request.options.reversed()), id: \.self) { option in
                    Button {
                        answer(option)
                    } label: {
                        HStack(spacing: 4) {
                            if busy == option { ProgressView().controlSize(.small) }
                            Text(busy == option ? "Sending..." : option)
                        }
                    }
                    .disabled(busy != nil)
                    .tint(Self.isNegative(option) ? .red : nil)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private var rows: [VaultApprovalDetails.Row] {
        if let vault = request.vault {
            return vault.rows(cardName: cardName) + (request.unseal?.rows ?? []).map { .init($0.label, $0.value) }
        }
        var rows: [VaultApprovalDetails.Row] = []
        if let cardName { rows.append(.init("Card", cardName)) }
        if !request.body.isEmpty { rows.append(.init(request.title, request.body)) }
        return rows
    }

    private func answer(_ option: String) {
        guard busy == nil else { return }
        busy = option
        failure = nil
        let request = request
        Task { @MainActor in
            defer { busy = nil }
            switch await MacVaultDevice.answer(request, option: option) {
            case .cancelled:
                return
            case .failed(let problem):
                // A request settled elsewhere closes on its own state change.
                failure = problem
            case .sent:
                onClose()
            }
        }
    }

    static func isNegative(_ option: String) -> Bool {
        let lower = option.lowercased()
        return lower.hasPrefix("deny") || lower.hasPrefix("no")
    }
}
