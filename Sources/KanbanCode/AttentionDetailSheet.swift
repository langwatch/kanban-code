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
    /// The refused request whose sheet stays up for the note to the agent.
    @State private var notingId: String?

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
                guard let shown = shownId, !isOpen(shown), shown != notingId else {
                    waiting = waiting.filter(isOpen)
                    return
                }
                KanbanCodeLog.info("attention", "Closed the detail sheet of \(shown): settled or gone")
                shownId = nil
            }
            .onChange(of: shownId) {
                if shownId != notingId { notingId = nil }
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
                if let request = store.state.attentionRequests[target.id], request.isOpen || notingId == request.id {
                    AttentionDetailSheet(
                        request: request,
                        cardName: request.cardId.flatMap { id in store.state.cards.first { $0.id == id }?.displayTitle },
                        waitingAfter: AttentionSheetQueue.waitingCount(waiting, isOpen: isOpen),
                        onNoting: { notingId = $0 ? request.id : nil },
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
    /// Keeps the sheet up after a refusal (true) for the note field, or
    /// lets it close with its request again (false).
    var onNoting: (Bool) -> Void = { _ in }
    let onClose: () -> Void
    @State private var busy: String?
    /// Why the last answer was not taken.
    @State private var failure: String?
    /// Set once the request was refused here: the sheet asks for the note.
    @State private var note: DenialNotePacer?

    var body: some View {
        if let note {
            DenialNoteView(requestId: request.id, title: AttentionCopy.notification(for: request, cardName: cardName).title,
                           pacer: note, onClose: onClose)
        } else {
            details
        }
    }

    private var details: some View {
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
        // A refused vault request is refused at once; the sheet then
        // offers a note for the agent, and the vault holds the refusal
        // for it.
        let takesNote = request.kind == .vaultApproval && AttentionCopy.isDenial(option)
        if takesNote { onNoting(true) }
        Task { @MainActor in
            defer { busy = nil }
            switch await MacVaultDevice.answer(request, option: option, noteFollows: takesNote) {
            case .cancelled:
                if takesNote { onNoting(false) }
            case .failed(let problem):
                // A request settled elsewhere closes on its own state change.
                failure = problem
                if takesNote { onNoting(false) }
            case .sent:
                if takesNote {
                    note = DenialNotePacer()
                } else {
                    onClose()
                }
            }
        }
    }

    static func isNegative(_ option: String) -> Bool {
        let lower = option.lowercased()
        return lower.hasPrefix("deny") || lower.hasPrefix("no")
    }
}

/// Shown after a vault request was refused: an optional note that goes to
/// the agent with the refusal. The vault holds the refusal while this is
/// up; Send, Skip, closing the sheet or the countdown release it.
private struct DenialNoteView: View {
    let requestId: String
    let title: String
    @State var pacer: DenialNotePacer
    let onClose: () -> Void
    @State private var text = ""
    @State private var sending = false
    @State private var failure: String?
    /// The refusal was released from here, with or without a note.
    @State private var released = false
    @FocusState private var focused: Bool

    private var cleaned: String? { DenialNote.clean(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "xmark.octagon.fill")
                    .font(.title2)
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Denied")
                        .font(.title3.weight(.semibold))
                    Text(title)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            TextField("Tell the agent why (optional)", text: $text, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(send)
                .onChange(of: text) {
                    if text.count > DenialNote.limit { text = String(text.prefix(DenialNote.limit)) }
                    guard !text.isEmpty, pacer.typed() else { return }
                    let id = requestId
                    Task { _ = await AppServices.noteAttention?(id, nil, true) }
                }

            if let failure {
                Label("Not sent: \(failure)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let left = max(0, Int(pacer.deadline.timeIntervalSince(context.date).rounded(.up)))
                    Text("The agent hears of the denial in \(left)s, or when you send or skip.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Skip") { finish() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(sending)
                Button(sending ? "Sending..." : "Send", action: send)
                    .keyboardShortcut(.defaultAction)
                    .disabled(sending || cleaned == nil)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { focused = true }
        .task(id: pacer.deadline) {
            // The vault releases the refusal at the deadline on its own.
            let wait = pacer.deadline.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled, !sending else { return }
            released = true
            onClose()
        }
        .onDisappear {
            guard !released else { return }
            released = true
            let id = requestId
            Task { _ = await AppServices.noteAttention?(id, nil, false) }
        }
    }

    private func send() {
        guard let note = cleaned, !sending else { return }
        sending = true
        failure = nil
        let id = requestId
        Task { @MainActor in
            let problem = await AppServices.noteAttention?(id, note, false)
            sending = false
            if let problem {
                failure = problem
            } else {
                released = true
                finish()
            }
        }
    }

    /// Closes the sheet; a refusal still held is released without a note.
    private func finish() {
        onClose()
    }
}
