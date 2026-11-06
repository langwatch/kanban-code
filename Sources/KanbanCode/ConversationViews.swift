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

    /// Starts a conversation and shows it; `quote` is the message it
    /// continues from, the agent's unless `quoteRole` says the human's, with
    /// the agent's answer to it in `quoteReply`.
    static func start(cardId: String, quote: String? = nil, quoteRole: RemoteConversationRole? = nil, quoteReply: String? = nil) {
        Task { @MainActor in
            do {
                let created = try await engine.createConversation(
                    cardId: cardId, RemoteConversationCreate(quote: quote, quoteRole: quoteRole, quoteReply: quoteReply))
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

    /// Opens the conversation with its rename sheet up. The open
    /// conversation shows the sheet: one on a sidebar row would be attached
    /// to every row.
    static func rename(cardId: String, conversationId: String) {
        open(cardId: cardId, conversationId: conversationId)
        ConversationRenameRequest.shared.conversationId = conversationId
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
        send(cardId: cardId, QueuedPrompt(
            body: text, sendAutomatically: true, imagePaths: imagePaths.isEmpty ? nil : imagePaths,
            humanWrittenAt: .now, conversation: conversationId))
    }

    /// Sends a failed message again under its own id, so the card's owner
    /// does not take it twice when the first send landed after all.
    static func retry(cardId: String, _ failed: FailedPrompt) {
        send(cardId: cardId, failed.prompt)
    }

    private static func send(cardId: String, _ prompt: QueuedPrompt) {
        // Shows faded in the conversation until its log has it; the send
        // itself is journalled like any chat prompt.
        store.dispatch(.conversationMessageSent(cardId: cardId, prompt: prompt))
        store.dispatch(.addQueuedPrompt(cardId: cardId, prompt: prompt, placement: .back))
        store.dispatch(.sendQueuedPrompt(cardId: cardId, promptId: prompt.id))
    }

    /// The conversation's messages, from the card's log here or the copy of
    /// its owner's, read off the main actor: a log not folded yet can take
    /// a while.
    static func messages(cardId: String, conversationId: String) async -> [RemoteConversationMessage] {
        let owner = engine.isForeign(cardId) ? store.state.links[cardId]?.ownerMachine : nil
        let conversationStore = engine.conversationStore
        return await Task.detached(priority: .userInitiated) {
            conversationStore.threads(cardId: cardId, ownerMachine: owner)
                .first { $0.summary.id == conversationId }?.messages ?? []
        }.value
    }
}

// MARK: - Drafts

/// What is typed in each conversation's composer, kept while the human
/// switches views, and where an image dropped on the window goes while a
/// conversation is open.
@MainActor @Observable
final class ConversationDrafts {
    static let shared = ConversationDrafts()

    struct Draft: Equatable {
        var text = ""
        var images: [Data] = []
    }

    private var drafts: [String: Draft] = [:]

    private static func key(_ cardId: String, _ conversationId: String) -> String { cardId + "/" + conversationId }

    func draft(cardId: String, conversationId: String) -> Draft {
        drafts[Self.key(cardId, conversationId)] ?? Draft()
    }

    func set(_ draft: Draft, cardId: String, conversationId: String) {
        drafts[Self.key(cardId, conversationId)] = draft == Draft() ? nil : draft
    }

    /// Adds an image at the end of the text, with its `[Image #N]` marker,
    /// as a paste in the composer does.
    func addImage(_ data: Data, cardId: String, conversationId: String) {
        var draft = draft(cardId: cardId, conversationId: conversationId)
        let marker = PromptImagePlaceholders.insertMarker(for: draft.images)
        draft.images.append(data)
        let separator = draft.text.isEmpty || draft.text.hasSuffix(" ") || draft.text.hasSuffix("\n") ? "" : " "
        draft.text += separator + marker
        set(draft, cardId: cardId, conversationId: conversationId)
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
                Button("Rename Conversation") {
                    ConversationActions.rename(cardId: cardId, conversationId: conversation.id)
                }
                Button(conversation.unread ? "Mark as Read" : "Mark as Unread") {
                    let markUnread = !conversation.unread
                    ConversationActions.update(cardId: cardId, conversationId: conversation.id, .init(read: !markUnread))
                    // An open conversation marks itself read again, so it closes.
                    if markUnread, openId == conversation.id { ConversationActions.open(cardId: cardId, conversationId: nil) }
                }
                Button("Archive Conversation") {
                    ConversationActions.update(cardId: cardId, conversationId: conversation.id, .init(archived: true))
                    if openId == conversation.id { ConversationActions.open(cardId: cardId, conversationId: nil) }
                }
            }
            .accessibilityIdentifier("sidebar-conversation-\(conversation.id)")
        }
    }
}

/// A rename asked for from the sidebar, shown by the conversation once it
/// is open.
@MainActor @Observable
final class ConversationRenameRequest {
    static let shared = ConversationRenameRequest()
    var conversationId: String?
}

/// Renames a conversation as the human; the agent's titles no longer
/// replace it after this.
struct ConversationRenameSheet: View {
    let cardId: String
    let conversation: RemoteConversation
    @Binding var isPresented: Bool

    var body: some View {
        RenameSessionDialog(
            currentName: conversation.title ?? "",
            isPresented: $isPresented,
            heading: "Rename Conversation",
            placeholder: "Conversation title",
            onRename: { title in
                ConversationActions.update(cardId: cardId, conversationId: conversation.id, .init(title: title))
            }
        )
    }
}

// MARK: - Conversation chat

/// Where conversation images were found in each transcript, for the app's
/// life. A lookup walks the whole transcript, which can be gigabytes: a
/// conversation opened again, or another one of the same card, reuses what
/// earlier lookups found and never walks the file for the same message twice.
@MainActor
enum ConversationImageLines {
    private static var lines: [String: [String: Int]] = [:]
    private static var looked: [String: Set<String>] = [:]

    static func known(in path: String) -> (lines: [String: Int], looked: Set<String>) {
        (lines[path] ?? [:], looked[path] ?? [])
    }

    static func record(looked ids: [String], found: [String: Int], in path: String) {
        looked[path, default: []].formUnion(ids)
        lines[path, default: [:]].merge(found) { _, new in new }
    }
}

/// One conversation of the card: the human's messages and the agent's
/// replies through `kanban reply`, with its own composer. The agent's tool
/// calls and plain text stay in Main.
struct ConversationChatView: View {
    let card: KanbanCodeCard
    let conversation: RemoteConversation
    @State private var messages: [RemoteConversationMessage] = []
    /// How many of the latest messages are shown; "Show earlier messages"
    /// raises it. A conversation can hold hundreds of long replies, and
    /// every row in the stack is measured when the list scrolls to its end.
    @State private var shownCount = ConversationChatView.pageSize
    @State private var renaming = false
    @State private var focusToken = 0
    /// The transcript line of each human message whose images this machine
    /// cannot read from their paths.
    @State private var imageLines: [String: Int] = [:]
    /// The card's GitHub repo, for references written as `#123`.
    @State private var githubBaseURL: String?
    /// The links of each agent message, built off the main actor once per
    /// message rather than on every render.
    @State private var messageLinks: [String: LinkedMessage] = [:]
    /// The repo `messageLinks` were resolved against.
    @State private var linksBase: String?

    struct LinkedMessage: Equatable, Sendable {
        let textLength: Int
        let links: ChatTextLinks
    }

    private var store: BoardStore { AppComposition.shared.store }
    private var drafts: ConversationDrafts { ConversationDrafts.shared }

    private var draftText: Binding<String> {
        Binding(
            get: { drafts.draft(cardId: card.id, conversationId: conversation.id).text },
            set: { text in
                var draft = drafts.draft(cardId: card.id, conversationId: conversation.id)
                draft.text = text
                drafts.set(draft, cardId: card.id, conversationId: conversation.id)
            })
    }

    private var draftImages: Binding<[Data]> {
        Binding(
            get: { drafts.draft(cardId: card.id, conversationId: conversation.id).images },
            set: { images in
                var draft = drafts.draft(cardId: card.id, conversationId: conversation.id)
                draft.images = images
                drafts.set(draft, cardId: card.id, conversationId: conversation.id)
            })
    }

    /// Messages sent from here that the log does not show yet.
    private var pending: [QueuedPrompt] {
        let sent = store.state.conversationOutbox[card.id]?.filter { $0.conversation == conversation.id } ?? []
        let delivered = Set(ConversationOutbox.delivered(sent, in: messages))
        return sent.filter { !delivered.contains($0.id) }
    }

    private var transcriptPath: String? {
        ConversationExportCommand.transcriptPath(for: card.link, kanbanHome: nil)
    }

    /// Human messages with images whose paths are not on this machine.
    private var unreadableImageMessageIds: [String] {
        messages.filter { message in
            message.role == .human && (message.images ?? []).contains { !FileManager.default.isReadableFile(atPath: $0) }
        }.map(\.id)
    }

    /// Resolves the links of the agent messages that have none yet, or of
    /// all of them when the repo changed.
    private func linkMessages() async {
        let base = githubBaseURL
        let known = linksBase == base ? messageLinks : [:]
        let wanted = messages
            .filter { $0.role == .agent && known[$0.id]?.textLength != $0.text.utf16.count }
            .map { (id: $0.id, text: $0.text) }
        guard !wanted.isEmpty || linksBase != base else { return }
        let built = await Task.detached(priority: .userInitiated) {
            var built: [String: LinkedMessage] = [:]
            for message in wanted {
                built[message.id] = LinkedMessage(
                    textLength: message.text.utf16.count,
                    links: ChatTextLinks.message(message.text, githubBaseURL: base))
            }
            return built
        }.value
        guard !Task.isCancelled, base == githubBaseURL else { return }
        messageLinks = known.merging(built) { _, new in new }
        linksBase = base
    }

    /// Finds those messages' prompts in the transcript, so their images load
    /// from there as Main's do.
    private func locateImages() async {
        guard let path = transcriptPath else { return }
        let known = ConversationImageLines.known(in: path)
        imageLines.merge(known.lines) { _, new in new }
        let wanted = unreadableImageMessageIds.filter { imageLines[$0] == nil && !known.looked.contains($0) }
        guard !wanted.isEmpty else { return }
        let wantedSet = Set(wanted)
        let lookups = messages.filter { wantedSet.contains($0.id) }.map { (id: $0.id, text: $0.text) }
        let conversationId = conversation.id
        // Detached and cancellable: a transcript can be gigabytes, and the
        // task restarts whenever the wanted ids change.
        let reader = Task.detached(priority: .utility) {
            try? ConversationTranscriptImages.lines(for: lookups, conversationId: conversationId, inTranscriptAt: path)
        }
        let found = await withTaskCancellationHandler {
            await reader.value
        } onCancel: {
            reader.cancel()
        }
        guard !Task.isCancelled, let found else { return }
        ConversationImageLines.record(looked: wanted, found: found, in: path)
        imageLines.merge(found) { _, new in new }
    }

    /// Prompts of this card still in its queue: the session has not taken them.
    private var queuedIds: Set<String> {
        Set((card.link.queuedPrompts ?? []).map(\.id))
    }

    /// Failed sends, but for one the log shows: it landed after all.
    private var failed: [FailedPrompt] {
        let failed = store.state.failedPrompts[card.id]?.filter { $0.prompt.conversation == conversation.id } ?? []
        let delivered = Set(ConversationOutbox.delivered(failed.map(\.prompt), in: messages))
        return failed.filter { !delivered.contains($0.id) }
    }

    private var isWorking: Bool {
        card.activityState == .activelyWorking && messages.last?.role != .agent
    }

    static let pageSize = 80

    private var shownMessages: ArraySlice<RemoteConversationMessage> {
        messages.suffix(shownCount)
    }

    /// Why the agent will not answer for now: its plan's usage limit.
    private var pausedLine: String? {
        card.activeUsageLimit()?.pausedLine(assistant: card.link.effectiveAssistant.displayName)
    }

    var body: some View {
        // Read here, in the view's own body, so a change to either redraws
        // it: a send that fails or is confirmed changes only the store.
        let pending = self.pending
        let failed = self.failed
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if let quote = conversation.quote {
                            quoteBlock(quote, label: conversation.quotesHuman ? "Continued from your message" : "Continued from")
                            if conversation.quotesHuman, let reply = conversation.quoteReply {
                                quoteBlock(reply, label: "and the reply")
                            }
                        }
                        if messages.isEmpty && conversation.quote == nil {
                            Text("A new conversation with this card's agent. It shares the session with Main; the agent answers here with kanban reply.")
                                .font(.app(.callout))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .multilineTextAlignment(.center)
                                .padding(.top, 40)
                        }
                        if messages.count > shownCount {
                            Button("Show earlier messages") {
                                shownCount += Self.pageSize
                            }
                            .buttonStyle(.borderless)
                            .font(.app(.caption))
                            .frame(maxWidth: .infinity, alignment: .center)
                        }
                        ForEach(shownMessages) { message in
                            ConversationMessageRow(message: message, cardId: card.id,
                                                   links: messageLinks[message.id]?.links ?? ChatTextLinks(),
                                                   waiting: queuedIds.contains(message.id),
                                                   transcript: imageLines[message.id].map { (transcriptPath, $0) })
                                .id(message.id)
                        }
                        ForEach(pending, id: \.id) { prompt in
                            PendingConversationBubble(prompt: prompt)
                                .id(prompt.id)
                        }
                        ForEach(failed) { failed in
                            HStack {
                                Spacer(minLength: 0)
                                FailedPromptBubble(
                                    failed: failed,
                                    onRetry: { ConversationActions.retry(cardId: card.id, failed) },
                                    onEdit: {
                                        store.dispatch(.dismissFailedPrompt(cardId: card.id, promptId: failed.id))
                                        drafts.set(.init(text: failed.prompt.body,
                                                         images: (failed.prompt.imagePaths ?? []).compactMap { FileManager.default.contents(atPath: $0) }),
                                                   cardId: card.id, conversationId: conversation.id)
                                        focusToken += 1
                                    },
                                    onDiscard: { store.dispatch(.dismissFailedPrompt(cardId: card.id, promptId: failed.id)) }
                                )
                                .frame(maxWidth: userBubbleMaxWidth, alignment: .trailing)
                            }
                            .id(failed.id)
                        }
                        if let pausedLine {
                            UsageLimitLine(text: pausedLine)
                                .id("paused")
                        } else if isWorking {
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
                // One scroll for a message landing and its pending bubble
                // going away, which come in the same update.
                .onChange(of: pending.last?.id ?? messages.last?.id) { previous, last in
                    guard let last else { return }
                    // The first load jumps to the end; later ones glide.
                    if previous == nil {
                        proxy.scrollTo(last, anchor: .bottom)
                    } else {
                        withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
                .onAppear {
                    if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .task(id: unreadableImageMessageIds) { await locateImages() }
            ChatInputBar(
                assistant: card.link.effectiveAssistant,
                isReady: true,
                cardId: card.id,
                placeholderOverride: "Message \(conversation.displayTitle)",
                userMessageHistory: messages.filter { $0.role == .human }.reversed().map(\.text),
                focusRequestToken: focusToken,
                onSend: { text, images in
                    ConversationActions.send(cardId: card.id, conversationId: conversation.id, text: text, imagePaths: images)
                },
                fileDraftKey: PromptFileDrafts.conversationKey(cardId: card.id, conversationId: conversation.id),
                text: draftText,
                pastedImages: draftImages
            )
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: "\(card.id)/\(conversation.id)/\(conversation.updatedAt.timeIntervalSince1970)/\(conversation.messageCount)") {
            let loaded = await ConversationActions.messages(cardId: card.id, conversationId: conversation.id)
            guard !Task.isCancelled else { return }
            if loaded != messages { messages = loaded }
            await linkMessages()
            let sent = ((store.state.conversationOutbox[card.id] ?? []) + (store.state.failedPrompts[card.id] ?? []).map(\.prompt))
                .filter { $0.conversation == conversation.id }
            let delivered = ConversationOutbox.delivered(sent, in: messages)
            if !delivered.isEmpty {
                store.dispatch(.conversationMessagesDelivered(cardId: card.id, promptIds: delivered))
            }
            if conversation.unread {
                ConversationActions.update(cardId: card.id, conversationId: conversation.id, .init(read: true))
            }
        }
        .task(id: card.link.projectPath) {
            let base: String? = if let projectPath = card.link.projectPath {
                await GitRemoteResolver.shared.githubBaseURL(for: projectPath)
            } else {
                nil
            }
            guard !Task.isCancelled else { return }
            githubBaseURL = base
            await linkMessages()
        }
        .onAppear { focusToken += 1 }
        .onChange(of: ConversationRenameRequest.shared.conversationId, initial: true) { _, requested in
            guard requested == conversation.id else { return }
            ConversationRenameRequest.shared.conversationId = nil
            renaming = true
        }
        .onChange(of: conversation.id) {
            focusToken += 1
            shownCount = Self.pageSize
            messages = []
        }
        .sheet(isPresented: $renaming) {
            ConversationRenameSheet(cardId: card.id, conversation: conversation, isPresented: $renaming)
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
            Spacer()
            Button("Rename") {
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

    private func quoteBlock(_ quote: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
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
    /// GitHub references and URLs in the message, opened with a plain click.
    var links = ChatTextLinks()
    /// Logged but not taken by the session yet: faded, as the chat shows a
    /// message going out.
    var waiting = false
    /// The transcript and the line holding this message's images, when
    /// their paths are not on this machine.
    var transcript: (path: String?, line: Int)?

    var body: some View {
        if message.role == .human {
            HStack {
                Spacer(minLength: 60)
                let split = PromptFiles.split(message.text)
                VStack(alignment: .trailing, spacing: 6) {
                    ConversationImageStrip(paths: message.images ?? [], transcript: transcript)
                    SentFileChips(paths: split.paths)
                    if !split.text.isEmpty {
                        Text(split.text)
                            .font(.app(.body))
                            .textSelection(.enabled)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 18).fill(Color.accentColor.opacity(0.15)))
                    }
                }
                .opacity(waiting ? 0.5 : 1)
                .overlay(alignment: .leading) {
                    if waiting {
                        ProgressView().controlSize(.small).opacity(0.5).offset(x: -24)
                    }
                }
                .frame(maxWidth: userBubbleMaxWidth, alignment: .trailing)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ChatText(
                    content: message.text.containsBlockMarkdown ? .markdown(message.text) : .inlineMarkdown(message.text),
                    appearance: .init(font: .systemFont(ofSize: NSFont.systemFontSize + 1), foregroundColor: .labelColor, lineSpacing: 0),
                    links: links)
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

/// A message sent from here that the log does not show yet, faded with a
/// spinner as the chat's pending message is.
private struct PendingConversationBubble: View {
    let prompt: QueuedPrompt

    var body: some View {
        HStack {
            Spacer(minLength: 60)
            let split = PromptFiles.split(prompt.body)
            VStack(alignment: .trailing, spacing: 6) {
                ConversationImageStrip(paths: prompt.imagePaths ?? [])
                SentFileChips(paths: split.paths)
                if !split.text.isEmpty {
                    Text(split.text)
                        .font(.app(.body))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 18))
                }
            }
            .opacity(0.5)
            .overlay(alignment: .leading) {
                ProgressView()
                    .controlSize(.small)
                    .opacity(0.5)
                    .offset(x: -24)
            }
            .frame(maxWidth: userBubbleMaxWidth, alignment: .trailing)
        }
    }
}

/// The images of a message: thumbnails when this machine can read them,
/// otherwise the chat's image chips, which load from the transcript on hover.
private struct ConversationImageStrip: View {
    let paths: [String]
    var transcript: (path: String?, line: Int)? = nil

    var body: some View {
        if !paths.isEmpty {
            HStack(spacing: 6) {
                ForEach(Array(paths.enumerated()), id: \.offset) { index, path in
                    if let image = NSImage(contentsOfFile: path) {
                        ImageThumbnail(image: image, path: path)
                    } else {
                        LazyImageChip(index: index, sessionPath: transcript?.path, byteOffset: transcript?.line ?? 0)
                    }
                }
            }
        }
    }
}

/// A readable image: a thumbnail that previews larger on hover and opens on
/// click.
private struct ImageThumbnail: View {
    let image: NSImage
    let path: String
    @State private var hovering = false

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
            .popover(isPresented: $hovering) {
                let size = image.size
                let scale = min(1.0, min(600.0 / max(size.width, 1), 400.0 / max(size.height, 1)))
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size.width * scale, height: size.height * scale)
                    .padding(4)
            }
            .help((path as NSString).lastPathComponent)
    }
}

/// A card's agent stopped on its plan's usage limit: shown where "Working"
/// would be, so a message sent meanwhile does not look like it is being
/// worked on.
struct UsageLimitLine: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.app(.caption))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
