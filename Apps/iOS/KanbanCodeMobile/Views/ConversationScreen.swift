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
                        ConversationMessageView(message: message, pendingImages: model.pendingImages[message.id] ?? [])
                            .id(message.id)
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
                PromptComposer(card: card, board: board, draft: draft, conversation: model.id, sendError: $sendError,
                               focused: $composerFocused, maxLines: 6, onInterrupt: interrupt, onSent: { text, images in
                                   sentCount += 1
                                   model.appendPending(text, images: images)
                                   Task { await model.refresh() }
                               }) {
                    EmptyView()
                }
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

    private func interrupt() {
        guard let client = board.client else { return }
        Task {
            do {
                try await client.interrupt(cardId: model.cardId)
                UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            } catch {
                actionError = error.localizedDescription
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

/// A message of a conversation, drawn as Main draws its messages. The
/// human's images show over the bubble: the ones attached here while the
/// message is pending, then a chip per image, since the master keeps them
/// where the phone cannot read them.
struct ConversationMessageView: View {
    let message: RemoteConversationMessage
    var pendingImages: [Data] = []

    var body: some View {
        VStack(alignment: message.role == .human ? .trailing : .leading, spacing: 6) {
            if message.role == .human, !pendingImages.isEmpty || !(message.images ?? []).isEmpty {
                images
            }
            if !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                MessageView(message: RemoteMessage(id: message.id, role: message.role == .human ? .user : .assistant,
                                                   text: message.text, at: message.at))
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .human ? .trailing : .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    private var identifier: String {
        if message.role == .agent { return "conversationAgent" }
        return message.id.hasPrefix("pending-") ? "conversationPending" : "conversationHuman"
    }

    @ViewBuilder private var images: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 48)
            if !pendingImages.isEmpty {
                ForEach(Array(pendingImages.enumerated()), id: \.offset) { _, data in
                    Group {
                        if let ui = UIImage(data: data) {
                            Image(uiImage: ui).resizable().scaledToFill()
                        } else {
                            Color(.tertiarySystemFill)
                        }
                    }
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .opacity(0.5)
                    .accessibilityIdentifier("conversationPendingImage")
                }
            } else {
                ForEach(Array((message.images ?? []).enumerated()), id: \.offset) { _, _ in
                    Label("Image", systemImage: "photo")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                        .accessibilityIdentifier("conversationImage")
                }
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

/// A conversation listed under its card: its title, bold while unread, and
/// a preview of its last message.
struct ConversationRow: View {
    let conversation: RemoteConversation

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "arrow.turn.down.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.displayTitle)
                    .font(.subheadline.weight(conversation.unread ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let preview = conversation.preview, !preview.isEmpty {
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
        if let preview = conversation.preview, !preview.isEmpty { parts.append(preview) }
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
