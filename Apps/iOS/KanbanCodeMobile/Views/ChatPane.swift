import SwiftUI
import KanbanCodeRemoteKit

struct ChatPane: View {
    let card: RemoteCard
    let transcript: TranscriptModel
    let board: BoardModel
    let draft: ComposerDraft
    let onResume: () -> Void
    let onInterrupt: () -> Void
    /// Starts a conversation that continues a message; nil when the master
    /// keeps no conversations.
    var onContinueInConversation: ((RemoteConversationCreate) -> Void)? = nil

    @State private var sendError: String?
    @State private var notice: String?
    @State private var sentCount = 0
    @State private var queueActions: Set<String> = []
    @FocusState private var composerFocused: Bool
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    @State private var follow = FollowState()
    /// Top of the keyboard and bottom of the chat, in window coordinates.
    @State private var keyboardTop: CGFloat?
    @State private var paneBottom: CGFloat = 0
    @State private var paneTop: CGFloat = 0
    /// The card's side chat (`/btw`, `/catchup`), made when first used.
    @State private var sideChat: SideChatController?
    @State private var sideChatCollapsed = false
    /// The message a catch-up link landed on, tinted for a moment.
    @State private var highlightedMessage: String?

    /// How much of the chat the keyboard still covers after SwiftUI made
    /// room for it: nothing, unless SwiftUI missed the suggestion bar.
    private var keyboardShortfall: CGFloat {
        guard let keyboardTop else { return 0 }
        return max(0, paneBottom - keyboardTop)
    }

    /// Whether the chat keeps to its end: from opening until the user
    /// scrolls away, and again once they scroll back to it. A class, so
    /// scrolling does not redraw the view.
    private final class FollowState {
        var followsEnd = true
        var userScrolling = false
        /// A scroll to the end waits for the next turn of the run loop.
        var scrollScheduled = false
        /// When the last scrolls to the end were made, newest last.
        var recentScrolls: [Date] = []

        /// Scrolls to the end allowed within one second. A chat that
        /// cannot reach its end (rows whose height keeps changing) then
        /// retries at this pace instead of in every layout pass.
        static let scrollsPerSecond = 30

        /// Whether another scroll to the end may be made now, counting it.
        func takeScroll(now: Date = .now) -> Bool {
            recentScrolls.removeAll { now.timeIntervalSince($0) > 1 }
            guard recentScrolls.count < Self.scrollsPerSecond else { return false }
            recentScrolls.append(now)
            return true
        }
    }

    /// Distance from the end of the conversation to the bottom of what is shown.
    private static func distanceToEnd(_ geo: ScrollGeometry) -> CGFloat {
        geo.contentSize.height + geo.contentInsets.bottom - (geo.contentOffset.y + geo.containerSize.height)
    }

    private static let bottomID = "chat-bottom"

    private var supportsQueue: Bool { board.supports(RemoteAPI.Feature.queue) }
    /// The side chat forks a Claude Code session.
    private var supportsSideChat: Bool {
        board.supports(RemoteAPI.Feature.sideChat) && card.assistant == "claude" && card.sessionId != nil
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if transcript.olderCursor != nil {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .onAppear { Task { await transcript.loadOlder() } }
                }
                ForEach(visibleMessages) { message in
                    MessageView(message: message, loadImage: imageLoader(for: message))
                        // Touch and hold an agent message: its edit menu
                        // offers to go on with it in a conversation of its own.
                        .environment(\.selectableTextMenuItem, continueItem(for: message))
                        .background {
                            if highlightedMessage == message.id {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.accentColor.opacity(0.18))
                                    .padding(-6)
                                    .accessibilityElement()
                                    .accessibilityIdentifier("citedMessage")
                            }
                        }
                        .id(message.id)
                }
                ForEach(card.queuedPrompts) { prompt in
                    QueuedPromptView(
                        prompt: prompt,
                        isWorking: queueActions.contains(prompt.id),
                        canAct: supportsQueue && card.isLive,
                        onSendNow: { queueAction(prompt, .sendNow) },
                        onEdit: { queueAction(prompt, .edit) },
                        onDelete: { queueAction(prompt, .delete) }
                    )
                    .id("queued-\(prompt.id)")
                }
                if card.isBusy {
                    WorkingIndicator()
                }
                // The last row reaches the end of the content, so scrolling
                // to it ends at the true bottom.
                Color.clear
                    .frame(height: 12)
                    .id(Self.bottomID)
            }
            .padding(.horizontal)
            .padding(.top, 12)
            // A tap anywhere on the conversation puts the keyboard away,
            // on a button too (which still does its own thing); message
            // text reports its taps through selectableTextTap.
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { composerFocused = false })
            .environment(\.selectableTextTap) { composerFocused = false }
        }
        .scrollPosition($scrollPosition)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        // Following the end goes through scrollTo(id:), which lays out the
        // row it scrolls to. A bottom anchor for size changes instead sets
        // the offset from the estimated heights of rows the lazy stack has
        // not laid out, so after the keyboard or a new message changed the
        // size it could land where no row is drawn and show a blank chat.
        // One scrollTo can still land short: the long rows it brings on
        // screen are measured only then and push the end further down. So
        // while the chat follows its end, every change that leaves it off
        // the end scrolls again, until it is there. The scroll is made on
        // the next turn of the run loop, never inside the layout pass that
        // reported the change: a scroll made there changes the geometry
        // again within the same pass, and a chat whose end keeps moving
        // (an inset in the middle of an animation, a long row measured
        // late) would keep the main thread in that pass.
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            Self.distanceToEnd(geo).rounded()
        } action: { _, distance in
            if distance > 1 { followEnd() }
        }
        .onScrollPhaseChange { _, phase, context in
            switch phase {
            case .tracking, .interacting, .decelerating:
                follow.userScrolling = true
            case .idle:
                if follow.userScrolling {
                    follow.userScrolling = false
                    follow.followsEnd = Self.distanceToEnd(context.geometry) < 60
                }
            case .animating:
                break
            @unknown default:
                break
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .overlay { emptyState }
        // The room the folded panel takes at the top of the chat comes and
        // goes in one step. Only the panel itself animates, inside its
        // overlay: the chat's layout never follows an animated height.
        .safeAreaInset(edge: .top, spacing: 0) {
            if sideChat?.state.isOpen == true {
                Color.clear.frame(height: SideChatPanel.foldedHeight)
            }
        }
        .overlay(alignment: .top) {
            ZStack(alignment: .top) {
                if let sideChat, sideChat.state.isOpen {
                    // The reader's height is what shows above the composer and
                    // the keyboard: the panel never reaches under them.
                    GeometryReader { geo in
                        SideChatPanel(controller: sideChat, collapsed: $sideChatCollapsed,
                                      maxHeight: geo.size.height - keyboardShortfall - 12,
                                      onJump: jump(toOffset:),
                                      onSendToMain: handOff,
                                      machineName: board.machineName, machineOffline: !board.isOnline)
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: sideChat?.state.isOpen)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar
                .padding(.bottom, keyboardShortfall)
                .background(Color(.systemBackground))
        }
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY.rounded() } action: { paneBottom = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY.rounded() } action: { paneTop = $0 }
        .background {
            KeyboardTopReader { top, duration in
                if duration > 0 {
                    withAnimation(.easeOut(duration: duration)) { keyboardTop = top }
                } else {
                    keyboardTop = top
                }
            }
            .ignoresSafeArea()
        }
        .refreshable { await transcript.refresh() }
        .task(id: card.lastActivity ?? card.updatedAt) { await transcript.refresh() }
        .task(id: card.isBusy) {
            // Board events carry card changes; while a turn runs also poll
            // so streamed text shows up between them.
            while card.isBusy, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                await transcript.refresh()
            }
        }
        .task(id: card.queuedPrompts.map(\.id)) {
            transcript.dropPending(queued: queuedTexts)
            // A queued prompt that just went out lands in the transcript.
            await transcript.refresh()
        }
        .sensoryFeedback(.success, trigger: sentCount)
    }

    /// Loads the images of a sent message from the master that keeps them.
    private func imageLoader(for message: RemoteMessage) -> ((Int) async throws -> Data)? {
        guard (message.images ?? 0) > 0, let client = board.client else { return nil }
        let cardId = card.id
        return { index in
            try await RemoteImageCache.data("transcript|\(cardId)|\(message.id)|\(index)") {
                try await client.transcriptImage(cardId: cardId, messageId: message.id, index: index)
            }
        }
    }

    private func continueItem(for message: RemoteMessage) -> SelectableTextMenuItem? {
        guard let onContinueInConversation, !message.id.hasPrefix("pending-") else { return nil }
        let request: RemoteConversationCreate
        switch message.role {
        case .assistant:
            request = RemoteConversationCreate(quote: message.text)
        case .user:
            // The human's own words, without the header of the conversation
            // the prompt came from, and what the agent answered to it.
            let text = ConversationPrompt.parse(message.text)?.text ?? message.text
            request = RemoteConversationCreate(quote: text, quoteRole: .human, quoteReply: reply(to: message))
        default:
            return nil
        }
        return SelectableTextMenuItem(title: "Continue in new conversation", systemImage: "square.and.pencil") {
            onContinueInConversation(request)
        }
    }

    /// The agent's text after a human message, up to the next human
    /// message, or nil when it has not answered yet.
    private func reply(to message: RemoteMessage) -> String? {
        let messages = transcript.messages
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return nil }
        var parts: [String] = []
        for next in messages[(index + 1)...] {
            if next.role == .user { break }
            if next.role == .assistant, !next.text.isEmpty { parts.append(next.text) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    private var queuedTexts: Set<String> {
        Set(card.queuedPrompts.map { TranscriptModel.displayText($0.text, imageCount: $0.imageCount) })
    }

    /// Sent prompts that now wait in the card's queue show there instead.
    private var visibleMessages: [RemoteMessage] {
        let queued = queuedTexts
        guard !queued.isEmpty else { return transcript.messages }
        return transcript.messages.filter { !($0.id.hasPrefix("pending-") && queued.contains($0.text)) }
    }

    @ViewBuilder private var emptyState: some View {
        if transcript.messages.isEmpty && card.queuedPrompts.isEmpty {
            if let error = transcript.error {
                ContentUnavailableView {
                    Label("Cannot load the conversation", systemImage: "exclamationmark.bubble")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try again") { Task { await transcript.refresh() } }
                }
            } else if transcript.loadedOnce {
                ContentUnavailableView("No messages yet", systemImage: "bubble.left.and.bubble.right",
                                       description: Text(card.isLive ? "Send a prompt to start." : "Resume the session to talk to it."))
            } else {
                ProgressView()
            }
        }
    }

    @ViewBuilder private var bottomBar: some View {
        VStack(spacing: 6) {
            if let sendError {
                Label(sendError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("composerNotice")
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(4))
                        self.notice = nil
                    }
            }
            if card.isLive, card.sessionStatus?.kind != .machine {
                PromptComposer(card: card, board: board, draft: draft, sendError: $sendError, focused: $composerFocused,
                               maxLines: composerMaxLines, slashCommands: true, kanbanCommands: supportsSideChat,
                               onInterrupt: onInterrupt, intercept: interceptSideChat, onSent: { text, images in
                                   follow.followsEnd = true
                                   sentCount += 1
                                   transcript.appendPending(text, imageCount: images.count)
                               }) {
                    if supportsSideChat {
                        catchUpButton
                    }
                }
            } else {
                // The same status the Mac shows in the card: a start or a
                // move in flight, a failed start, a machine that is away.
                let status = card.sessionStatus
                HStack {
                    if let status, status.kind == .starting || status.kind == .moving {
                        ProgressView()
                    }
                    Text(status?.text ?? "Session not running")
                        .font(.subheadline)
                        .foregroundStyle(status?.kind == .failed ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                        .accessibilityIdentifier("sessionStatus")
                    Spacer()
                    if supportsSideChat {
                        catchUpButton
                    }
                    if status == nil || status?.canResume == true {
                        Button("Resume", systemImage: "play.fill", action: onResume)
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("resumeBar")
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
    }

    /// The most lines the composer text shows before it scrolls: eight,
    /// or fewer when the pane above the keyboard is too short for eight
    /// plus the images, the files and the button row. A composer taller than the
    /// pane draws its last line under the buttons.
    private var composerMaxLines: Int {
        let room = min(paneBottom, keyboardTop ?? paneBottom) - paneTop
        guard room > 0 else { return 8 }
        let around: CGFloat = 96 + (draft.images.isEmpty ? 0 : 70) + (draft.files.isEmpty ? 0 : 56)
        let line = UIFont.preferredFont(forTextStyle: .body).lineHeight
        return min(8, max(2, Int((room - around) / line)))
    }

    /// What happened since the human's last message, in the side chat.
    private var catchUpButton: some View {
        Button {
            runSideChat(.catchup)
        } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color(.label))
                .frame(width: 34, height: 34)
                .background(Color(.tertiarySystemFill), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Catch me up")
        .accessibilityHint("Sums up what happened since your last message.")
        .accessibilityIdentifier("catchUp")
    }

    /// `/btw` and `/catchup` open the side chat; nothing goes to the session.
    private func interceptSideChat(_ text: String) -> Bool {
        guard supportsSideChat, let command = SideChatCommand.parse(text) else { return false }
        runSideChat(command)
        return true
    }

    private func runSideChat(_ command: SideChatCommand) {
        guard let client = board.client else { return }
        let controller = sideChat ?? SideChatController(transport: .remote(client, cardId: card.id))
        sideChat = controller
        composerFocused = false
        sideChatCollapsed = false
        controller.run(command)
    }

    /// Shows the message at a transcript offset: older pages load until it
    /// is there, then the chat scrolls to it and tints it. The side chat
    /// folds so the message shows under it.
    private func jump(toOffset offset: Int) {
        withAnimation(.snappy) { sideChatCollapsed = true }
        follow.followsEnd = false
        Task {
            guard let message = await transcript.message(atOffset: offset) else { return }
            // One turn later, so rows that just loaded are laid out.
            try? await Task.sleep(for: .milliseconds(120))
            withAnimation(.snappy) {
                scrollPosition.scrollTo(id: message.id, anchor: .top)
                highlightedMessage = message.id
            }
            try? await Task.sleep(for: .seconds(3))
            if highlightedMessage == message.id {
                withAnimation(.easeOut(duration: 0.6)) { highlightedMessage = nil }
            }
        }
    }

    /// Scrolls to the end on the next turn of the run loop, when the chat
    /// follows its end. Changes reported in between share that one scroll.
    private func followEnd() {
        guard follow.followsEnd, !follow.userScrolling, !follow.scrollScheduled else { return }
        follow.scrollScheduled = true
        Task { @MainActor in
            follow.scrollScheduled = false
            guard follow.followsEnd, !follow.userScrolling, follow.takeScroll() else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                scrollPosition.scrollTo(id: Self.bottomID, anchor: .bottom)
            }
        }
    }

    /// Sends a side chat follow-up to the session. The message shows at
    /// once as a pending bubble and the composer stays free while the
    /// machine takes it. A send that fails takes the bubble away and puts
    /// the text in the composer, with what was typed there stashed.
    private func handOff(_ text: String) {
        guard !text.isEmpty, let client = board.client else { return }
        sendError = nil
        follow.followsEnd = true
        let pending = transcript.appendPending(text)
        Task {
            do {
                try await client.sendPrompt(cardId: card.id, text: text, mode: .queue, human: true)
                sentCount += 1
            } catch {
                transcript.removePending(pending)
                if !draft.isEmpty { draft.stash() }
                draft.load(text: text, images: [])
                sendError = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    private enum QueueAction { case sendNow, edit, delete }

    private func queueAction(_ prompt: RemoteQueuedPrompt, _ action: QueueAction) {
        guard let client = board.client, !queueActions.contains(prompt.id) else { return }
        queueActions.insert(prompt.id)
        sendError = nil
        Task {
            defer { queueActions.remove(prompt.id) }
            do {
                switch action {
                case .sendNow:
                    try await client.sendQueuedPromptNow(cardId: card.id, promptId: prompt.id)
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                case .delete:
                    try await client.removeQueuedPrompt(cardId: card.id, promptId: prompt.id)
                case .edit:
                    try await client.removeQueuedPrompt(cardId: card.id, promptId: prompt.id)
                    // Whatever is typed now waits in a stash.
                    draft.stash()
                    // Its images stay on the Mac, so their markers go too.
                    draft.load(text: PromptImageLayout.removingMarkers(from: prompt.text, imageCount: prompt.imageCount),
                               images: [])
                    if prompt.imageCount > 0 {
                        notice = prompt.imageCount == 1
                            ? "Its image stays on the Mac; attach it again to send it."
                            : "Its \(prompt.imageCount) images stay on the Mac; attach them again to send them."
                    }
                    composerFocused = true
                }
            } catch RemoteClientError.notFound {
                if action == .edit { notice = "Already sent." }
            } catch {
                sendError = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            await transcript.refresh()
        }
    }
}

/// A prompt waiting on the Mac for the turn to end. Touch and hold for
/// Send now, Edit and Delete.
struct QueuedPromptView: View {
    let prompt: RemoteQueuedPrompt
    let isWorking: Bool
    let canAct: Bool
    let onSendNow: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 4) {
                Text(TranscriptModel.displayText(prompt.text, imageCount: prompt.imageCount))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 18)
                            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    )
                    .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 18))
                    .contextMenu {
                        if canAct {
                            Button("Send now", systemImage: "bolt.fill", action: onSendNow)
                            Button("Edit", systemImage: "pencil", action: onEdit)
                            Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
                        }
                    }
                    .accessibilityIdentifier("queuedBubble")
                HStack(spacing: 4) {
                    if isWorking {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "clock")
                    }
                    Text("Queued")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("queuedPrompt")
    }
}

/// The camera, for a photo to attach.
struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.9) {
                parent.onImage(data)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

struct WorkingIndicator: View {
    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Working")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct MessageView: View {
    let message: RemoteMessage
    /// The bytes of the message's image at an index, from the master.
    var loadImage: ((Int) async throws -> Data)?
    @State private var expanded = false
    @State private var showsWhole = false

    /// Characters of a message shown before "Show the whole message": a
    /// pasted log or a dump runs to hundreds of KB, which the phone lays out
    /// slowly and the user rarely reads in full.
    static let shownLimit = 20_000

    /// The message as shown: cut at `shownLimit` until the user asks for all of it.
    private var text: String {
        guard !showsWhole, message.text.utf16.count > Self.shownLimit else { return message.text }
        return String(message.text.prefix(Self.shownLimit)) + "\n…"
    }

    private var isCut: Bool { !showsWhole && message.text.utf16.count > Self.shownLimit }

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
            content
            if isCut {
                Button("Show the whole message (\(message.text.count.formatted()) characters)") { showsWhole = true }
                    .font(.caption.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
                    .accessibilityIdentifier("showWholeMessage")
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch message.role {
        case .user:
            // A prompt sent from a conversation shows as the human wrote
            // it, under the name of its conversation.
            let fromConversation = ConversationPrompt.parse(text)
            if let fromConversation {
                Label(fromConversation.title ?? fromConversation.id, systemImage: "bubble.left.and.text.bubble.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .accessibilityIdentifier("promptConversation")
            }
            if let count = message.images, count > 0 {
                RemoteImageRow(count: count, load: loadImage)
            }
            // Attached files show as chips over the bubble, not as their
            // [File: /path] lines.
            let split = PromptFiles.split(fromConversation?.text ?? text)
            if !split.paths.isEmpty {
                SentFileRow(paths: split.paths)
            }
            if !split.text.isEmpty || split.paths.isEmpty {
                HStack {
                    Spacer(minLength: 48)
                    SelectableText(text: SelectableTextStyle.plain(split.text, color: .white))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Color.accentColor.opacity(message.id.hasPrefix("pending-") ? 0.5 : 0.9),
                                    in: RoundedRectangle(cornerRadius: 18))
                        .foregroundStyle(.white)
                }
            }
        case .assistant:
            MarkdownText(text: text)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.caption2)
                    Text(text)
                        .font(.caption.monospaced())
                        .lineLimit(expanded ? nil : 1)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        case .system:
            if let detail = message.detail {
                systemNote(detail: detail)
            } else {
                SelectableText(text: SelectableTextStyle.plain(text, font: .preferredFont(forTextStyle: .caption1),
                                                               color: .secondaryLabel),
                               alignment: .center)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// A note that opens to the long text behind it: a compaction and
    /// its summary.
    private func systemNote(detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                    Text(message.text)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("systemNote")
            if expanded {
                let shown = !showsWhole && detail.utf16.count > Self.shownLimit
                    ? String(detail.prefix(Self.shownLimit)) + "\n…" : detail
                SelectableText(text: SelectableTextStyle.plain(shown, font: .preferredFont(forTextStyle: .caption1),
                                                               color: .secondaryLabel))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                if detail.utf16.count > Self.shownLimit, !showsWhole {
                    Button("Show the whole text (\(detail.count.formatted()) characters)") { showsWhole = true }
                        .font(.caption.weight(.medium))
                }
            }
        }
    }
}

/// The files a sent message names, one chip each, right aligned over its
/// bubble. The files live on the machine the card runs on, so a tap copies
/// the path.
struct SentFileRow: View {
    let paths: [String]
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            ForEach(Array(paths.enumerated()), id: \.offset) { _, path in
                Button {
                    UIPasteboard.general.string = path
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.snappy) { copied = path }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: copied == path ? "checkmark" : FileIcon.symbol(for: path))
                            .font(.footnote)
                            .foregroundStyle(Color.accentColor)
                        Text(copied == path ? "Path copied" : PromptFiles.displayName(of: path))
                            .font(.footnote.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(PromptFiles.displayName(of: path))
                .accessibilityHint("Copies the file's path")
                .accessibilityIdentifier("sentFile")
            }
        }
        .padding(.leading, 48)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .task(id: copied) {
            guard copied != nil else { return }
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.snappy) { copied = nil }
        }
    }
}

/// Assistant markdown: fenced code as monospaced blocks, tables as grids,
/// headings and lists by line, inline styles through AttributedString.
struct MarkdownText: View {
    let text: String

    private enum Block: Hashable {
        case code(String)
        case heading(String)
        case paragraph(String)
        case table(MarkdownTable)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .code(let code):
                    let styled = SelectableTextStyle.plain(
                        code, font: .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular)
                    )
                    Group {
                        if Self.wrapsCode(code) {
                            SelectableText(text: styled)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(10)
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                SelectableText(text: styled, wraps: false)
                                    .padding(10)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                case .heading(let line):
                    SelectableText(text: SelectableTextStyle.markdown(line, font: .preferredFont(forTextStyle: .headline)))
                        .fixedSize(horizontal: false, vertical: true)
                case .paragraph(let para):
                    SelectableText(text: SelectableTextStyle.markdown(para))
                        .fixedSize(horizontal: false, vertical: true)
                case .table(let table):
                    MarkdownTableView(table: table)
                }
            }
        }
    }

    /// Code with a line too long to scroll sideways (minified JSON, a
    /// base64 blob) wraps: unwrapped it would be a text view hundreds of
    /// thousands of points wide.
    static func wrapsCode(_ code: String) -> Bool {
        code.split(separator: "\n", omittingEmptySubsequences: false).contains { $0.utf16.count > 2_000 }
    }

    private var blocks: [Block] {
        var out: [Block] = []
        var paragraph: [String] = []
        var code: [String]? = nil
        func flush() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.isEmpty { out.append(.paragraph(joined)) }
            paragraph = []
        }
        let lines = text.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let raw = lines[index]
            index += 1
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let lines = code {
                    out.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flush()
                    code = []
                }
                continue
            }
            if code != nil { code!.append(raw); continue }
            if let (table, lineCount) = MarkdownTable.parse(lines, at: index - 1) {
                flush()
                out.append(.table(table))
                index += lineCount - 1
                continue
            }
            if trimmed.hasPrefix("#") {
                flush()
                out.append(.heading(String(trimmed.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
            } else if trimmed.isEmpty {
                flush()
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                // A list starts its own block after a paragraph.
                if let last = paragraph.last, !last.trimmingCharacters(in: .whitespaces).hasPrefix("• ") { flush() }
                let indent = String(raw.prefix { $0 == " " })
                paragraph.append(indent + "• " + trimmed.dropFirst(2))
            } else {
                paragraph.append(raw)
            }
        }
        if let lines = code { out.append(.code(lines.joined(separator: "\n"))) }
        flush()
        return out
    }
}

#Preview("Markdown") {
    ScrollView {
        MarkdownText(text: PreviewData.messages[1].text).padding()
    }
}
