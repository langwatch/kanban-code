import SwiftUI
import AppKit
import KanbanCodeCore
import KanbanCodeRemoteKit

// MARK: - Actions

/// What the views do with a card's conversations (docs/conversations.md):
/// all of it goes through the engine, which forwards to the master that
/// owns the card.
@MainActor
enum ConversationActions {
    static var engine: MasterEngine { AppComposition.shared.engine }
    static var store: BoardStore { AppComposition.shared.store }

    /// Starts a conversation and shows it; `quote` is the agent message it
    /// continues from.
    static func start(cardId: String, quote: String? = nil) {
        Task { @MainActor in
            do {
                let created = try await engine.createConversation(cardId: cardId, RemoteConversationCreate(quote: quote))
                store.dispatch(.selectCard(cardId: cardId))
                store.dispatch(.openConversation(cardId: cardId, conversationId: created.id))
            } catch {
                KanbanCodeLog.warn("conversations", "card \(cardId.prefix(12)): could not start a conversation: \(error)")
                store.dispatch(.setError("Could not start a conversation: \(error.localizedDescription)"))
            }
        }
    }

    static func open(cardId: String, conversationId: String?) {
        if store.state.selectedCardId != cardId { store.dispatch(.selectCard(cardId: cardId)) }
        store.dispatch(.openConversation(cardId: cardId, conversationId: conversationId))
    }

    static func update(cardId: String, conversationId: String, _ update: RemoteConversationUpdate) {
        Task { @MainActor in
            do {
                _ = try await engine.updateConversation(cardId: cardId, id: conversationId, update)
            } catch {
                KanbanCodeLog.warn("conversations", "card \(cardId.prefix(12)): update of \(conversationId) failed: \(error)")
            }
        }
    }

    /// Sends a message of the conversation through the card's queue, as the
    /// chat's send button does: the header goes on when it leaves.
    static func send(cardId: String, conversationId: String, text: String, imagePaths: [String]) {
        let prompt = QueuedPrompt(
            body: text, sendAutomatically: true, imagePaths: imagePaths.isEmpty ? nil : imagePaths,
            humanWrittenAt: .now, conversation: conversationId)
        store.dispatch(.addQueuedPrompt(cardId: cardId, prompt: prompt, placement: .back))
        store.dispatch(.sendQueuedPrompt(cardId: cardId, promptId: prompt.id))
    }

    /// The conversation's messages, from the card's log here or the copy of
    /// its owner's.
    static func messages(cardId: String, conversationId: String) -> [RemoteConversationMessage] {
        let owner = engine.isForeign(cardId) ? store.state.links[cardId]?.ownerMachine : nil
        return engine.conversationStore.threads(cardId: cardId, ownerMachine: owner)
            .first { $0.summary.id == conversationId }?.messages ?? []
    }
}

// MARK: - State dots

/// Waiting on you (orange) and unread (blue), as the sidebar and the strip show them.
struct ConversationStateDot: View {
    let conversation: RemoteConversation

    var body: some View {
        if conversation.unread {
            Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                .help(conversation.waiting ? "New reply, waiting on you" : "New reply")
        } else if conversation.waiting {
            Circle().strokeBorder(Color.orange, lineWidth: 1.5).frame(width: 7, height: 7)
                .help("Waiting on you")
        }
    }
}

// MARK: - Sidebar rows

/// A card's conversations under it in the sidebar.
struct SidebarConversationRows: View {
    let cardId: String
    let conversations: [RemoteConversation]
    let openId: String?
    let isCardSelected: Bool

    var body: some View {
        ForEach(conversations.filter { !$0.archived }) { conversation in
            let selected = isCardSelected && openId == conversation.id
            HStack(spacing: 6) {
                Image(systemName: "bubble.left")
                    .font(.app(size: 10))
                    .foregroundStyle(.tertiary)
                Text(conversation.displayTitle)
                    .font(.app(.caption, weight: conversation.unread ? .semibold : .regular))
                    .foregroundStyle(conversation.title == nil ? .secondary : .primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if conversation.waiting {
                    Text("Waiting on you")
                        .font(.app(.caption2))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
                ConversationStateDot(conversation: conversation)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
            .padding(.leading, 22)
            .onTapGesture { ConversationActions.open(cardId: cardId, conversationId: conversation.id) }
            .contextMenu {
                Button("Archive Conversation") {
                    ConversationActions.update(cardId: cardId, conversationId: conversation.id, .init(archived: true))
                    if openId == conversation.id { ConversationActions.open(cardId: cardId, conversationId: nil) }
                }
            }
            .accessibilityIdentifier("sidebar-conversation-\(conversation.id)")
        }
    }
}

// MARK: - Strip over the chat

/// Main and the card's conversations over its chat, with the compose button
/// at the right.
struct ConversationStrip: View {
    let cardId: String
    let conversations: [RemoteConversation]
    let openId: String?

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    chip(title: "Main", selected: openId == nil, conversation: nil) {
                        ConversationActions.open(cardId: cardId, conversationId: nil)
                    }
                    ForEach(conversations.filter { !$0.archived }) { conversation in
                        chip(title: conversation.displayTitle, selected: openId == conversation.id, conversation: conversation) {
                            ConversationActions.open(cardId: cardId, conversationId: conversation.id)
                        }
                    }
                }
            }
            Button {
                ConversationActions.start(cardId: cardId)
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.app(size: 14))
                    .frame(width: 28, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("New conversation")
            .accessibilityIdentifier("new-conversation")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private func chip(title: String, selected: Bool, conversation: RemoteConversation?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let conversation { ConversationStateDot(conversation: conversation) }
                Text(title).lineLimit(1)
            }
            .font(.app(.caption, weight: selected ? .semibold : .regular))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06)))
            .frame(maxWidth: 220)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Conversation chat

/// One conversation of the card: the human's messages and the agent's
/// replies through `kanban reply`, with its own composer. The agent's tool
/// calls and plain text stay in Main.
struct ConversationChatView: View {
    let card: KanbanCodeCard
    let conversation: RemoteConversation
    @State private var messages: [RemoteConversationMessage] = []
    @State private var draft = ""
    @State private var draftImages: [Data] = []
    @State private var renaming = false
    @State private var newTitle = ""

    private var isWorking: Bool {
        card.activityState == .activelyWorking && messages.last?.role != .agent
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if let quote = conversation.quote {
                            quoteBlock(quote)
                        }
                        if messages.isEmpty && conversation.quote == nil {
                            Text("A new conversation with this card's agent. It shares the session with Main; the agent answers here with kanban reply.")
                                .font(.app(.callout))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .multilineTextAlignment(.center)
                                .padding(.top, 40)
                        }
                        ForEach(messages) { message in
                            ConversationMessageRow(message: message, cardId: card.id)
                                .id(message.id)
                        }
                        if isWorking {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Working, see Main for the details")
                                    .font(.app(.caption))
                                    .foregroundStyle(.secondary)
                            }
                            .id("working")
                        }
                    }
                    .frame(maxWidth: chatMaxWidth)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: messages.count) {
                    if let last = messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
                .onAppear {
                    if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            ChatInputBar(
                assistant: card.link.effectiveAssistant,
                isReady: true,
                cardId: card.id,
                placeholderOverride: "Message \(conversation.displayTitle)",
                userMessageHistory: messages.filter { $0.role == .human }.reversed().map(\.text),
                onSend: { text, images in
                    ConversationActions.send(cardId: card.id, conversationId: conversation.id, text: text, imagePaths: images)
                },
                text: $draft,
                pastedImages: $draftImages
            )
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: "\(card.id)/\(conversation.id)/\(conversation.updatedAt.timeIntervalSince1970)/\(conversation.messageCount)") {
            messages = ConversationActions.messages(cardId: card.id, conversationId: conversation.id)
            if conversation.unread {
                ConversationActions.update(cardId: card.id, conversationId: conversation.id, .init(read: true))
            }
        }
        .sheet(isPresented: $renaming) {
            RenameSessionDialog(
                currentName: conversation.title ?? "",
                isPresented: $renaming,
                onRename: { title in
                    ConversationActions.update(cardId: card.id, conversationId: conversation.id, .init(title: title))
                }
            )
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .foregroundStyle(.secondary)
            Text(conversation.displayTitle)
                .font(.app(.headline))
                .lineLimit(1)
            Text(conversation.id)
                .font(.app(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
            if conversation.waiting {
                Text("Waiting on you")
                    .font(.app(.caption))
                    .foregroundStyle(.orange)
            }
            Spacer()
            Button("Rename") {
                newTitle = conversation.title ?? ""
                renaming = true
            }
            .buttonStyle(.borderless)
            .font(.app(.caption))
            Button("Archive") {
                ConversationActions.update(cardId: card.id, conversationId: conversation.id, .init(archived: true))
                ConversationActions.open(cardId: card.id, conversationId: nil)
            }
            .buttonStyle(.borderless)
            .font(.app(.caption))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func quoteBlock(_ quote: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Continued from")
                .font(.app(.caption))
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.secondary.opacity(0.4)).frame(width: 3)
                ChatText(content: .markdown(quote), appearance: .init(font: .systemFont(ofSize: NSFont.systemFontSize), foregroundColor: .secondaryLabelColor, lineSpacing: 0), lineLimit: 12)
            }
        }
    }
}

private struct ConversationMessageRow: View {
    let message: RemoteConversationMessage
    let cardId: String

    var body: some View {
        if message.role == .human {
            HStack {
                Spacer(minLength: 60)
                Text(message.text)
                    .font(.app(.body))
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 18).fill(Color.accentColor.opacity(0.15)))
                    .frame(maxWidth: userBubbleMaxWidth, alignment: .trailing)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ChatText(
                    content: message.text.containsBlockMarkdown ? .markdown(message.text) : .inlineMarkdown(message.text),
                    appearance: .init(font: .systemFont(ofSize: NSFont.systemFontSize + 1), foregroundColor: .labelColor, lineSpacing: 0))
                Text(message.at.formatted(date: .omitted, time: .shortened))
                    .font(.app(.caption2))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contextMenu {
                Button("Continue in New Conversation") {
                    ConversationActions.start(cardId: cardId, quote: message.text)
                }
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.text, forType: .string)
                }
            }
        }
    }
}
