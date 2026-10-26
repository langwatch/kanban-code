import SwiftUI
import KanbanCodeRemoteKit

/// A conversation of a card of the merged board, through the master that
/// owns the card.
struct FleetConversationScreen: View {
    let route: ConversationRoute
    let fleet: FleetModel

    var body: some View {
        if let entry = fleet.entry(cardId: route.cardId) {
            ConversationScreen(route: route, board: entry.master)
                .id(entry.master.server.id)
        } else {
            ContentUnavailableView("Card not found", systemImage: "questionmark.square.dashed",
                                   description: Text("It may have been deleted on its machine."))
        }
    }
}

/// One conversation of a card: the human's messages and the agent's
/// replies to them, and a composer that sends to the card's session with
/// the conversation named.
struct ConversationScreen: View {
    let board: BoardModel
    @State private var model: ConversationModel
    @State private var draft: ComposerDraft
    @State private var sendError: String?
    @State private var actionError: String?
    @State private var sentCount = 0
    @State private var isResuming = false
    @State private var renaming = false
    @State private var newTitle = ""
    @FocusState private var composerFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private static let bottomID = "conversation-bottom"

    init(route: ConversationRoute, board: BoardModel, model: ConversationModel? = nil) {
        self.board = board
        _model = State(initialValue: model ?? ConversationModel(cardId: route.cardId, id: route.id, board: board))
        // Its own draft, apart from the card's main chat.
        _draft = State(initialValue: board.client == nil
                       ? ComposerDraft(preview: "")
                       : ComposerDraft(server: board.server.id, cardId: "\(route.cardId)#conversation-\(route.id)"))
    }

    private var card: RemoteCard? { board.card(id: model.cardId) }

    /// The summary the board carries, which changes when the agent writes.
    private var summary: RemoteConversation? {
        card?.conversations.first { $0.id == model.id }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let quote = model.conversation?.quote, !quote.isEmpty {
                        QuotedMessage(text: quote)
                    }
                    ForEach(model.shown) { message in
                        MessageView(message: RemoteMessage(id: message.id, role: message.role == .human ? .user : .assistant,
                                                           text: message.text, at: message.at))
                            .id(message.id)
                            .accessibilityIdentifier(message.role == .human ? "conversationHuman" : "conversationAgent")
                    }
                    if model.isWorking(cardBusy: card?.isBusy == true) {
                        WorkingIndicator()
                            .accessibilityIdentifier("conversationWorking")
                    }
                    Color.clear
                        .frame(height: 12)
                        .id(Self.bottomID)
                }
                .padding(.horizontal)
                .padding(.top, 12)
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded { composerFocused = false })
                .environment(\.selectableTextTap) { composerFocused = false }
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .overlay { emptyState }
            .onChange(of: model.shown.last?.id) { _, _ in
                withAnimation(.snappy) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar
                .background(Color(.systemBackground))
        }
        .navigationTitle(model.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .sensoryFeedback(.success, trigger: sentCount)
        .refreshable { await model.refresh() }
        // Board events carry the summary: a reply, a title, a read on
        // another device.
        .task(id: summary) { await model.refresh() }
        .task {
            // Between board events, while it is open.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                await model.refresh()
            }
        }
        .alert("Rename conversation", isPresented: $renaming) {
            TextField("Title", text: $newTitle)
                .accessibilityIdentifier("conversationTitleField")
            Button("Cancel", role: .cancel) {}
            Button("Rename") { rename() }
                .accessibilityIdentifier("conversationRenameConfirm")
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { actionError != nil }, set: { if !$0 { actionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
    }

    @ViewBuilder private var emptyState: some View {
        if model.shown.isEmpty && model.conversation?.quote == nil {
            if let error = model.error {
                ContentUnavailableView {
                    Label("Cannot load the conversation", systemImage: "exclamationmark.bubble")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try again") { Task { await model.refresh() } }
                }
            } else if model.loadedOnce || board.client == nil {
                ContentUnavailableView("New conversation", systemImage: "bubble.left.and.text.bubble.right",
                                       description: Text("Messages here go to the same session, under this topic."))
            } else {
                ProgressView()
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Rename", systemImage: "pencil") {
                    newTitle = model.conversation?.title ?? ""
                    renaming = true
                }
                .accessibilityIdentifier("conversationRename")
                Button("Archive", systemImage: "archivebox", role: .destructive) { archive() }
                    .accessibilityIdentifier("conversationArchive")
            } label: {
                Label("Conversation", systemImage: "ellipsis.circle")
            }
            .disabled(board.client == nil || !board.isOnline)
            .accessibilityIdentifier("conversationMenu")
        }
    }

    @ViewBuilder private var bottomBar: some View {
        VStack(spacing: 6) {
            if let sendError {
                Label(sendError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("conversationSendError")
            }
            if let card, card.isLive, card.sessionStatus?.kind != .machine {
                composer
            } else {
                HStack {
                    Text(card?.sessionStatus?.text ?? "Session not running")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if card != nil, card?.sessionStatus == nil || card?.sessionStatus?.canResume == true {
                        Button("Resume", systemImage: "play.fill", action: resume)
                            .buttonStyle(.borderedProminent)
                            .disabled(isResuming || board.client == nil)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: Binding(get: { draft.text }, set: { draft.text = $0 }), axis: .vertical)
                .lineLimit(1...6)
                .focused($composerFocused)
                .padding(.horizontal, 6)
                .padding(.vertical, 7)
                .accessibilityIdentifier("conversationComposer")
            let enabled = !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(enabled ? Color(.systemBackground) : Color(.tertiaryLabel))
                    .frame(width: 34, height: 34)
                    .background(enabled ? Color(.label) : Color(.tertiarySystemFill), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .accessibilityLabel("Send")
            .accessibilityHint(card?.isBusy == true ? "Sends when this turn ends." : "")
            .accessibilityIdentifier("conversationSend")
        }
        .padding(8)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color(.separator).opacity(0.5), lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .onTapGesture { composerFocused = true }
    }

    /// Sends what is typed to the card's session, in this conversation. It
    /// shows at once as a pending message and the composer is free while
    /// the machine takes it. A send that fails takes the message away and
    /// puts its text back in the composer, with what was typed since stashed.
    private func send() {
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let client = board.client else { return }
        sendError = nil
        draft.clear()
        let pending = model.appendPending(text)
        Task {
            do {
                try await client.sendPrompt(cardId: model.cardId, text: text, mode: .queue, human: true,
                                            conversation: model.id)
                sentCount += 1
                await model.refresh()
            } catch {
                model.removePending(pending)
                if !draft.isEmpty { draft.stash() }
                draft.load(text: text, images: [])
                sendError = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    private func rename() {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != model.conversation?.title else { return }
        Task {
            do {
                try await model.rename(title)
            } catch {
                actionError = "Could not rename the conversation: \(error.localizedDescription)"
            }
        }
    }

    private func archive() {
        Task {
            do {
                try await model.archive()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                dismiss()
            } catch {
                actionError = "Could not archive the conversation: \(error.localizedDescription)"
            }
        }
    }

    private func resume() {
        guard let client = board.client, !isResuming else { return }
        isResuming = true
        Task {
            defer { isResuming = false }
            do {
                board.upsert(try await client.resume(cardId: model.cardId))
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
}

/// The agent message a conversation continues from, at its top.
struct QuotedMessage: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Continued from", systemImage: "arrowshape.turn.up.left")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            MarkdownText(text: expanded || text.count <= 600 ? text : String(text.prefix(600)) + "…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if text.count > 600 {
                Button(expanded ? "Show less" : "Show all") {
                    withAnimation(.snappy) { expanded.toggle() }
                }
                .font(.caption.weight(.medium))
            }
        }
        .padding(.leading, 12)
        .padding(.vertical, 8)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.orange.opacity(0.7))
                .frame(width: 3)
        }
        .background(Color(.secondarySystemBackground).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("conversationQuote")
    }
}

/// A conversation listed under its card: its title, unread with a blue dot
/// and bold, and "Waiting on you" while the agent's message is the last.
struct ConversationRow: View {
    let conversation: RemoteConversation

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "arrow.turn.down.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Circle()
                .fill(conversation.unread ? Color.blue : Color.clear)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.displayTitle)
                    .font(.subheadline.weight(conversation.unread ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if conversation.waiting {
                    HStack(spacing: 4) {
                        Circle().fill(Color.orange).frame(width: 6, height: 6)
                        Text("Waiting on you")
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.orange)
                } else if let preview = conversation.preview, !preview.isEmpty {
                    Text(preview)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Text(conversation.updatedAt.relativeShort)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize()
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.leading, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = ["Conversation", conversation.displayTitle]
        if conversation.unread { parts.append("unread") }
        if conversation.waiting { parts.append("waiting on you") }
        return parts.joined(separator: ", ")
    }
}

#Preview("Conversation") {
    let board = BoardModel(preview: PreviewData.board)
    let detail = PreviewData.conversationDetail
    NavigationStack {
        ConversationScreen(route: ConversationRoute(cardId: "c1", id: detail.conversation.id), board: board,
                           model: ConversationModel(preview: detail, cardId: "c1", board: board))
    }
}
