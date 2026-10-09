import LocalAuthentication
import SwiftUI
import KanbanCodeRemoteKit

/// The decisions agents wait on, across every master, with their answers.
struct AttentionListView: View {
    let fleet: FleetModel
    /// Opens the card of a request on the board.
    var openCard: (String) -> Void = { _ in }
    /// Request the sheet scrolls to, from a notification link.
    var focusId: String?
    @Environment(\.dismiss) private var dismiss
    @State private var freeText: [String: String] = [:]
    /// Requests whose detail page is open.
    @State private var detailPath: [String] = []

    var body: some View {
        NavigationStack(path: $detailPath) {
            Group {
                if fleet.attention.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing waiting on you", systemImage: "checkmark.circle")
                    } description: {
                        Text("Questions, plans and approvals from your agents show here.")
                    }
                } else {
                    ScrollViewReader { proxy in
                        List {
                            if let note = fleet.answers.note {
                                Text(note)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .accessibilityIdentifier("attention-note")
                            }
                            ForEach(fleet.attention) { item in
                                row(item)
                                    .id(item.id)
                                    .accessibilityIdentifier("attention-\(item.id)")
                            }
                        }
                        .listStyle(.insetGrouped)
                        .onAppear {
                            guard let focusId else { return }
                            proxy.scrollTo(focusId, anchor: .top)
                            // A vault request opens on its details, as the Mac does.
                            if fleet.attention.first(where: { $0.id == focusId })?.request.vault != nil {
                                detailPath = [focusId]
                            }
                        }
                    }
                }
            }
            .navigationDestination(for: String.self) { id in
                if let item = fleet.attention.first(where: { $0.id == id }) {
                    AttentionDetailView(item: item, sending: fleet.answers.sending[item.id], error: fleet.answers.errors[item.id],
                                        answer: { answer(item, $0) }, openCard: { cardId in
                        dismiss()
                        openCard(cardId)
                    })
                } else {
                    ContentUnavailableView("Already answered", systemImage: "checkmark.circle")
                }
            }
            .navigationTitle("Needs you")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onDisappear { fleet.clearAttentionNote() }
            .sheet(item: Binding(get: { fleet.denialNote }, set: { fleet.denialNote = $0 })) { target in
                DenialNoteSheet(target: target, onGone: { fleet.denialNote = nil })
                    .presentationDetents([.medium])
            }
        }
    }

    @ViewBuilder
    private func row(_ item: FleetModel.FleetAttention) -> some View {
        let request = item.request
        let sending = fleet.answers.sending[request.id]
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: Self.symbol(request.kind))
                        .foregroundStyle(.tint)
                    Text(request.title).font(.headline)
                    Spacer()
                    Text(request.createdAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !request.body.isEmpty {
                    Text(request.body)
                        .font(.callout)
                        .textSelection(.enabled)
                        .lineLimit(14)
                }
                if let error = fleet.answers.errors[request.id] {
                    Label("Not sent: \(error)", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("attention-\(request.id)-error")
                }
            }
            .padding(.vertical, 4)

            if request.vault != nil {
                NavigationLink(value: request.id) {
                    Label("Details", systemImage: "info.circle")
                }
                .accessibilityIdentifier("attention-\(request.id)-details")
            }

            ForEach(Array(request.options.enumerated()), id: \.offset) { index, option in
                Button {
                    answer(item, option)
                } label: {
                    HStack {
                        Text(option)
                            .foregroundStyle(Self.isNegative(option) ? .red : .primary)
                        Spacer()
                        if sending == option {
                            Text("Sending...").font(.footnote).foregroundStyle(.secondary)
                            ProgressView()
                        } else if AttentionAnswerGate.need(for: request, option: option) != .nothing {
                            Image(systemName: "faceid").foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(sending != nil)
                .accessibilityIdentifier("attention-\(request.id)-option-\(index)")
            }

            if request.kind == .question {
                HStack {
                    TextField("Answer in your own words", text: Binding(
                        get: { freeText[request.id] ?? "" },
                        set: { freeText[request.id] = $0 }))
                    Button("Send") {
                        let text = (freeText[request.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty { answer(item, text) }
                    }
                    .disabled(sending != nil || (freeText[request.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            if let cardId = request.cardId {
                Button {
                    dismiss()
                    openCard(cardId)
                } label: {
                    Label("Open card", systemImage: "arrow.up.forward.square")
                }
            }
        } header: {
            Text(item.cardName ?? item.master.machineName)
        }
    }

    private func answer(_ item: FleetModel.FleetAttention, _ resolution: String) {
        let id = item.request.id
        Task { @MainActor in
            await fleet.answer(item, resolution) {
                await Self.authenticate(reason: "\(resolution): \(item.request.title)")
            }
            guard fleet.answers.settled.contains(id) else { return }
            freeText[id] = nil
            detailPath.removeAll { $0 == id }
        }
    }

    /// Face ID, or the passcode when Face ID is unavailable.
    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }

    static func symbol(_ kind: AttentionRequest.Kind) -> String {
        switch kind {
        case .question: "questionmark.bubble"
        case .planApproval: "list.bullet.clipboard"
        case .permission: "hand.raised"
        case .vaultApproval: "key"
        }
    }

    static func isNegative(_ option: String) -> Bool {
        let lower = option.lowercased()
        return lower.hasPrefix("deny") || lower.hasPrefix("no")
    }
}

/// The "Needs you" row at the top of the board.
struct AttentionBanner: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: "bell.badge.fill")
                    .foregroundStyle(.orange)
                Text(count == 1 ? "1 decision waiting on you" : "\(count) decisions waiting on you")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityIdentifier("attentionBanner")
    }
}

/// Everything about a vault request: card, secrets, command, why the vault
/// asks, the lease it would grant, with the answers.
struct AttentionDetailView: View {
    let item: FleetModel.FleetAttention
    /// The option being sent, while an answer is on its way.
    let sending: String?
    /// Why the last answer was not sent.
    let error: String?
    let answer: (String) -> Void
    let openCard: (String) -> Void

    var body: some View {
        let request = item.request
        List {
            Section {
                Text(request.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                ForEach((request.vault?.rows(cardName: item.cardName) ?? [])
                    + (request.unseal?.rows ?? []).map { VaultApprovalDetails.Row($0.label, $0.value) }, id: \.self) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(row.value)
                            .font(row.monospaced ? .system(.callout, design: .monospaced) : .callout)
                            .textSelection(.enabled)
                    }
                }
            }
            Section {
                if let error {
                    Label("Not sent: \(error)", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                ForEach(Array(request.options.enumerated()), id: \.offset) { index, option in
                    Button {
                        answer(option)
                    } label: {
                        HStack {
                            Text(option)
                                .foregroundStyle(AttentionListView.isNegative(option) ? .red : .primary)
                            Spacer()
                            if sending == option {
                                Text("Sending...").font(.footnote).foregroundStyle(.secondary)
                                ProgressView()
                            } else if AttentionAnswerGate.need(for: request, option: option) != .nothing {
                                Image(systemName: "faceid").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(sending != nil)
                    .accessibilityIdentifier("attention-detail-\(request.id)-option-\(index)")
                }
                if let cardId = request.cardId {
                    Button {
                        openCard(cardId)
                    } label: {
                        Label("Open card", systemImage: "arrow.up.forward.square")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(item.cardName ?? "Vault request")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Shown after a vault request was refused: an optional note that goes to
/// the agent with the refusal. The vault holds the refusal while this is
/// up; Send, Skip, closing the sheet or the countdown release it.
struct DenialNoteSheet: View {
    let target: FleetModel.DenialNoteTarget
    /// Runs when the sheet went away, however it was closed.
    let onGone: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pacer: DenialNotePacer
    @State private var text = ""
    @State private var sending = false
    @State private var failure: String?
    /// The refusal was released from here, with or without a note.
    @State private var released = false
    @FocusState private var focused: Bool

    init(target: FleetModel.DenialNoteTarget, onGone: @escaping () -> Void) {
        self.target = target
        self.onGone = onGone
        _pacer = State(initialValue: target.pacer)
    }

    private var cleaned: String? { DenialNote.clean(text) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Tell the agent why (optional)", text: $text, axis: .vertical)
                        .lineLimit(3...6)
                        .focused($focused)
                        .accessibilityIdentifier("denial-note-field")
                        .onChange(of: text) {
                            if text.count > DenialNote.limit { text = String(text.prefix(DenialNote.limit)) }
                            guard !text.isEmpty, pacer.typed() else { return }
                            let target = target
                            Task { try? await target.master.noteAttention(id: target.id, note: nil, typing: true) }
                        }
                } header: {
                    Text("Denied: \(target.title)")
                } footer: {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let left = max(0, Int(pacer.deadline.timeIntervalSince(context.date).rounded(.up)))
                        Text("The agent hears of the denial in \(left)s, or when you send or skip.")
                    }
                }
                if let failure {
                    Label("Not sent: \(failure)", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("Denied")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") { dismiss() }
                        .disabled(sending)
                        .accessibilityIdentifier("denial-note-skip")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(sending ? "Sending..." : "Send", action: send)
                        .disabled(sending || cleaned == nil)
                        .accessibilityIdentifier("denial-note-send")
                }
            }
        }
        .onAppear { focused = true }
        .task(id: pacer.deadline) {
            // The vault releases the refusal at the deadline on its own.
            let wait = pacer.deadline.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled, !sending else { return }
            released = true
            dismiss()
        }
        .onDisappear {
            onGone()
            guard !released else { return }
            released = true
            let target = target
            Task { try? await target.master.noteAttention(id: target.id, note: nil) }
        }
    }

    private func send() {
        guard let note = cleaned, !sending else { return }
        sending = true
        failure = nil
        Task { @MainActor in
            do {
                try await target.master.noteAttention(id: target.id, note: note)
                released = true
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
            sending = false
        }
    }
}
